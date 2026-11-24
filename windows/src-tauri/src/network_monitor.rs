//! OS-level Windows network topology monitor and reconnect backoff policy (P0-4).
//!
//! Subscribes to the three Win32 IP Helper change notifications
//! (`NotifyIpInterfaceChange`, `NotifyUnicastIpAddressChange`, `NotifyRouteChange2`),
//! coalesces bursts over ~1.2 s (capped at 2 s), computes a coarse network fingerprint
//! (default-route interface LUIDs + preferred routable unicast addresses), and emits a
//! single recovery signal only when the fingerprint actually changes.
//!
//! System resume notifications from `system_events.rs` funnel through `notify_system_resume`
//! so sleep/wake and Wi-Fi/VPN switches share the same recovery path:
//! 1. Immediately drop and reset the persistent Home Assistant WebSocket and its backoff.
//! 2. Clear cached miIO LAN sessions so stale IPs/stamps are re-handshaked.
//! 3. Dispatch `menumijia:network-changed` to the webview so TS LAN health cooldowns reset
//!    and the cloud/HA poller refreshes immediately.

use futures_util::future::{select, Either};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::pin::pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};
use tokio::sync::mpsc;

pub(crate) const NETWORK_CHANGE_DEBOUNCE: Duration = Duration::from_millis(1_200);
pub(crate) const NETWORK_CHANGE_MAX_DELAY: Duration = Duration::from_millis(2_000);
const RESUME_DEDUP_WINDOW: Duration = Duration::from_millis(500);

/// Segmented reconnect backoff schedule in seconds:
/// fast retries (`1s -> 2s -> 4s -> 8s`) followed by away-from-home slow probes
/// (`30s -> 60s -> 120s -> 300s`).
pub(crate) const BACKOFF_SEGMENTS_SECS: &[u64] = &[1, 2, 4, 8, 30, 60, 120, 300];
pub(crate) const MAX_BACKOFF_SECS: u64 = 300;

const NETWORK_CHANGED_SCRIPT: &str =
    "window.dispatchEvent(new CustomEvent('menumijia:network-changed',{detail:{reason:'network'}}))";
const RESUME_NETWORK_SCRIPT: &str =
    "window.dispatchEvent(new CustomEvent('menumijia:network-changed',{detail:{reason:'resume'}}))";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NetworkEventKind {
    NetworkChanged,
    SystemResume,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DefaultRouteEntry {
    pub(crate) interface_luid: u64,
    pub(crate) is_ipv6: bool,
    pub(crate) metric: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UnicastAddressEntry {
    pub(crate) interface_luid: u64,
    pub(crate) address: IpAddr,
    pub(crate) preferred: bool,
}

/// Coarse topology snapshot that ignores transient interface noise (tentative DAD,
/// link-local, loopback, non-default route churn) while detecting default-route swaps,
/// Wi-Fi/VPN changes, DHCP address changes, and offline/online transitions.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct NetworkFingerprint {
    pub(crate) default_ipv4_interface: Option<u64>,
    pub(crate) default_ipv6_interface: Option<u64>,
    pub(crate) addresses: Vec<(u64, IpAddr)>,
}

pub(crate) fn is_routable_unicast(addr: IpAddr) -> bool {
    match addr {
        IpAddr::V4(v4) => {
            !v4.is_loopback() && !v4.is_unspecified() && !v4.is_link_local() && !v4.is_multicast()
        }
        IpAddr::V6(v6) => {
            let seg0 = v6.segments()[0];
            let is_link_local = (seg0 & 0xffc0) == 0xfe80;
            !v6.is_loopback() && !v6.is_unspecified() && !is_link_local && !v6.is_multicast()
        }
    }
}

pub(crate) fn compute_fingerprint(
    routes: &[DefaultRouteEntry],
    unicasts: &[UnicastAddressEntry],
) -> NetworkFingerprint {
    let best_default = |want_v6: bool| -> Option<u64> {
        routes
            .iter()
            .filter(|r| r.is_ipv6 == want_v6 && r.interface_luid != 0)
            .min_by_key(|r| (r.metric, r.interface_luid))
            .map(|r| r.interface_luid)
    };

    let default_ipv4_interface = best_default(false);
    let default_ipv6_interface = best_default(true);

    let mut addresses: Vec<(u64, IpAddr)> = unicasts
        .iter()
        .filter(|u| u.preferred && u.interface_luid != 0 && is_routable_unicast(u.address))
        .map(|u| (u.interface_luid, u.address))
        .collect();
    addresses.sort_unstable();
    addresses.dedup();

    NetworkFingerprint {
        default_ipv4_interface,
        default_ipv6_interface,
        addresses,
    }
}

/// Returns `true` only when a previously captured baseline differs from `current`.
/// The initial baseline capture returns `false` so startup never fires a spurious change.
pub(crate) fn fingerprint_changed(
    previous: Option<&NetworkFingerprint>,
    current: &NetworkFingerprint,
) -> bool {
    previous.is_some_and(|prev| prev != current)
}

/// Pure bounded burst debouncer: extends the quiet window on each event while
/// guaranteeing a flush no later than `burst_started + max_delay`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct BurstDebouncer {
    debounce: Duration,
    max_delay: Duration,
    burst_started_at: Option<Instant>,
    next_fire_at: Option<Instant>,
}

impl BurstDebouncer {
    pub(crate) fn new(debounce: Duration, max_delay: Duration) -> Self {
        Self {
            debounce,
            max_delay: max_delay.max(debounce),
            burst_started_at: None,
            next_fire_at: None,
        }
    }

    pub(crate) fn record_event(&mut self, now: Instant) -> Instant {
        let started = *self.burst_started_at.get_or_insert(now);
        let max_deadline = started + self.max_delay;
        let deadline = (now + self.debounce).min(max_deadline);
        self.next_fire_at = Some(deadline);
        deadline
    }

    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        self.next_fire_at
    }

    pub(crate) fn take_if_ready(&mut self, now: Instant) -> bool {
        if self.next_fire_at.is_some_and(|at| now >= at) {
            self.burst_started_at = None;
            self.next_fire_at = None;
            true
        } else {
            false
        }
    }
}

/// Computes the segmented reconnect backoff delay for `consecutive_failures` (1-indexed)
/// with `±25%` jitter controlled by `jitter_unit` in `[0.0, 1.0]`, clamped to `MAX_BACKOFF_SECS`.
pub(crate) fn segmented_backoff_delay(consecutive_failures: u32, jitter_unit: f64) -> Duration {
    if consecutive_failures == 0 {
        return Duration::ZERO;
    }
    let idx = (consecutive_failures.saturating_sub(1) as usize).min(BACKOFF_SEGMENTS_SECS.len() - 1);
    let base_ms = BACKOFF_SEGMENTS_SECS[idx] * 1_000;
    let clamped_unit = jitter_unit.clamp(0.0, 1.0);
    let multiplier = 0.75 + 0.5 * clamped_unit;
    let jittered_ms = ((base_ms as f64) * multiplier).round() as u64;
    Duration::from_millis(jittered_ms.min(MAX_BACKOFF_SECS * 1_000))
}

/// Stateful segmented backoff tracker for Home Assistant reconnects.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ReconnectBackoff {
    consecutive_failures: u32,
    ready_at: Instant,
}

impl ReconnectBackoff {
    pub(crate) fn new(now: Instant) -> Self {
        Self {
            consecutive_failures: 0,
            ready_at: now,
        }
    }

    #[cfg(test)]
    pub(crate) fn consecutive_failures(&self) -> u32 {
        self.consecutive_failures
    }

    pub(crate) fn ready_at(&self) -> Instant {
        self.ready_at
    }

    pub(crate) fn remaining(&self, now: Instant) -> Duration {
        self.ready_at.saturating_duration_since(now)
    }

    pub(crate) fn record_failure(&mut self, now: Instant, jitter_unit: f64) -> Duration {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let delay = segmented_backoff_delay(self.consecutive_failures, jitter_unit);
        self.ready_at = now + delay;
        delay
    }

    pub(crate) fn reset(&mut self, now: Instant) {
        self.consecutive_failures = 0;
        self.ready_at = now;
    }
}

/// Pure deduplicator for back-to-back Windows resume broadcasts
/// (`PBT_APMRESUMEAUTOMATIC` + `PBT_APMRESUMESUSPEND`).
pub(crate) fn should_emit_resume(
    last_resume: &mut Option<Instant>,
    now: Instant,
    window: Duration,
) -> bool {
    if last_resume.is_some_and(|prev| now.saturating_duration_since(prev) < window) {
        return false;
    }
    *last_resume = Some(now);
    true
}

struct IpHelperCallbackContext {
    notify_tx: mpsc::UnboundedSender<()>,
}

static NETWORK_MONITOR_INSTALLED: AtomicBool = AtomicBool::new(false);
static LAST_RESUME_AT: Mutex<Option<Instant>> = Mutex::new(None);

fn signal_from_callback(context: *const core::ffi::c_void) {
    let Some(ctx) = (unsafe { (context as *const IpHelperCallbackContext).as_ref() }) else {
        return;
    };
    let _ = ctx.notify_tx.send(());
}

unsafe extern "system" fn on_ip_interface_change(
    caller_context: *const core::ffi::c_void,
    _row: *const windows_sys::Win32::NetworkManagement::IpHelper::MIB_IPINTERFACE_ROW,
    _notification_type: windows_sys::Win32::NetworkManagement::IpHelper::MIB_NOTIFICATION_TYPE,
) {
    signal_from_callback(caller_context);
}

unsafe extern "system" fn on_unicast_address_change(
    caller_context: *const core::ffi::c_void,
    _row: *const windows_sys::Win32::NetworkManagement::IpHelper::MIB_UNICASTIPADDRESS_ROW,
    _notification_type: windows_sys::Win32::NetworkManagement::IpHelper::MIB_NOTIFICATION_TYPE,
) {
    signal_from_callback(caller_context);
}

unsafe extern "system" fn on_route_change(
    caller_context: *const core::ffi::c_void,
    _row: *const windows_sys::Win32::NetworkManagement::IpHelper::MIB_IPFORWARD_ROW2,
    _notification_type: windows_sys::Win32::NetworkManagement::IpHelper::MIB_NOTIFICATION_TYPE,
) {
    signal_from_callback(caller_context);
}

fn sockaddr_inet_to_ip(
    addr: &windows_sys::Win32::Networking::WinSock::SOCKADDR_INET,
) -> Option<IpAddr> {
    use windows_sys::Win32::Networking::WinSock::{AF_INET, AF_INET6};

    let family = unsafe { addr.si_family };
    if family == AF_INET {
        let raw = unsafe { addr.Ipv4.sin_addr.S_un.S_addr };
        Some(IpAddr::V4(Ipv4Addr::from(raw.to_ne_bytes())))
    } else if family == AF_INET6 {
        let bytes = unsafe { addr.Ipv6.sin6_addr.u.Byte };
        Some(IpAddr::V6(Ipv6Addr::from(bytes)))
    } else {
        None
    }
}

fn capture_windows_network_fingerprint() -> Option<NetworkFingerprint> {
    use windows_sys::Win32::Foundation::NO_ERROR;
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        FreeMibTable, GetIpForwardTable2, GetUnicastIpAddressTable, MIB_IPFORWARD_TABLE2,
        MIB_UNICASTIPADDRESS_TABLE,
    };
    use windows_sys::Win32::Networking::WinSock::{AF_INET6, AF_UNSPEC};

    // `NL_DAD_STATE::IpDadStatePreferred == 4` in Win32 `nldef.h`.
    const IP_DAD_STATE_PREFERRED: i32 = 4;

    let mut routes = Vec::new();
    let mut route_table: *mut MIB_IPFORWARD_TABLE2 = std::ptr::null_mut();
    let route_status = unsafe { GetIpForwardTable2(AF_UNSPEC, &mut route_table) };
    if route_status != NO_ERROR || route_table.is_null() {
        return None;
    }
    unsafe {
        let count = (*route_table).NumEntries as usize;
        let rows = std::slice::from_raw_parts((*route_table).Table.as_ptr(), count);
        for row in rows {
            if row.DestinationPrefix.PrefixLength == 0 {
                let is_ipv6 = row.DestinationPrefix.Prefix.si_family == AF_INET6;
                routes.push(DefaultRouteEntry {
                    interface_luid: row.InterfaceLuid.Value,
                    is_ipv6,
                    metric: row.Metric,
                });
            }
        }
        FreeMibTable(route_table.cast());
    }

    let mut unicasts = Vec::new();
    let mut unicast_table: *mut MIB_UNICASTIPADDRESS_TABLE = std::ptr::null_mut();
    let unicast_status = unsafe { GetUnicastIpAddressTable(AF_UNSPEC, &mut unicast_table) };
    if unicast_status != NO_ERROR || unicast_table.is_null() {
        return None;
    }
    unsafe {
        let count = (*unicast_table).NumEntries as usize;
        let rows = std::slice::from_raw_parts((*unicast_table).Table.as_ptr(), count);
        for row in rows {
            if let Some(address) = sockaddr_inet_to_ip(&row.Address) {
                unicasts.push(UnicastAddressEntry {
                    interface_luid: row.InterfaceLuid.Value,
                    address,
                    preferred: row.DadState == IP_DAD_STATE_PREFERRED,
                });
            }
        }
        FreeMibTable(unicast_table.cast());
    }

    Some(compute_fingerprint(&routes, &unicasts))
}

fn on_network_or_resume_event(app: &AppHandle, kind: NetworkEventKind) {
    // 1. Immediately drop and reset the persistent HA WebSocket and clear reconnect backoff.
    app.state::<crate::home_assistant::HaConnections>()
        .handle_network_or_resume();

    // 2. Clear cached miIO LAN sessions so stale IPs/stamps are re-probed.
    app.state::<crate::miio::MiIOState>()
        .reset_for_network_change();

    // 3. Notify the webview so TS LAN cooldowns reset and the cloud/HA poller refreshes immediately.
    if let Some(window) = app.get_webview_window("main") {
        let script = match kind {
            NetworkEventKind::NetworkChanged => NETWORK_CHANGED_SCRIPT,
            NetworkEventKind::SystemResume => RESUME_NETWORK_SCRIPT,
        };
        let _ = window.eval(script);
    }
}

/// Called from `system_events.rs` when Windows fires `PBT_APMRESUMEAUTOMATIC` or
/// `PBT_APMRESUMESUSPEND`. Deduplicates rapid paired broadcasts.
pub(crate) fn notify_system_resume(app: &AppHandle) {
    let should_emit = {
        let mut guard = LAST_RESUME_AT.lock().unwrap_or_else(|e| e.into_inner());
        should_emit_resume(&mut guard, Instant::now(), RESUME_DEDUP_WINDOW)
    };
    if should_emit {
        on_network_or_resume_event(app, NetworkEventKind::SystemResume);
    }
}

async fn run_network_monitor_loop(app: AppHandle, mut rx: mpsc::UnboundedReceiver<()>) {
    let mut baseline = tauri::async_runtime::spawn_blocking(capture_windows_network_fingerprint)
        .await
        .ok()
        .flatten();
    let mut debouncer = BurstDebouncer::new(NETWORK_CHANGE_DEBOUNCE, NETWORK_CHANGE_MAX_DELAY);

    loop {
        let next_deadline = debouncer.next_deadline();
        let sleep = async move {
            match next_deadline {
                Some(at) => tokio::time::sleep_until(tokio::time::Instant::from_std(at)).await,
                None => std::future::pending::<()>().await,
            }
        };

        match select(pin!(rx.recv()), pin!(sleep)).await {
            Either::Left((signal, _)) => {
                if signal.is_none() {
                    break;
                }
                debouncer.record_event(Instant::now());
            }
            Either::Right(_) => {
                if debouncer.take_if_ready(Instant::now()) {
                    if let Ok(Some(current)) =
                        tauri::async_runtime::spawn_blocking(capture_windows_network_fingerprint)
                            .await
                    {
                        if fingerprint_changed(baseline.as_ref(), &current) {
                            baseline = Some(current);
                            on_network_or_resume_event(&app, NetworkEventKind::NetworkChanged);
                        } else if baseline.is_none() {
                            baseline = Some(current);
                        }
                    }
                }
            }
        }
    }
}

/// Registers the three Win32 IP Helper change callbacks once per process and spawns
/// the debounced fingerprint monitor task.
pub(crate) fn install_network_monitor(app: AppHandle) -> bool {
    use windows_sys::Win32::Foundation::{HANDLE, NO_ERROR, WIN32_ERROR};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        NotifyIpInterfaceChange, NotifyRouteChange2, NotifyUnicastIpAddressChange,
    };
    use windows_sys::Win32::Networking::WinSock::AF_UNSPEC;

    if NETWORK_MONITOR_INSTALLED.swap(true, Ordering::SeqCst) {
        return true;
    }

    let (notify_tx, notify_rx) = mpsc::unbounded_channel();
    let context: *const core::ffi::c_void =
        Box::into_raw(Box::new(IpHelperCallbackContext { notify_tx })).cast();

    // Process-lifetime registrations (mirrors `system_events.rs`).
    let mut iface_handle: HANDLE = std::ptr::null_mut();
    let iface_status: WIN32_ERROR = unsafe {
        NotifyIpInterfaceChange(
            AF_UNSPEC,
            Some(on_ip_interface_change),
            context,
            0,
            &mut iface_handle,
        )
    };

    let mut unicast_handle: HANDLE = std::ptr::null_mut();
    let unicast_status: WIN32_ERROR = unsafe {
        NotifyUnicastIpAddressChange(
            AF_UNSPEC,
            Some(on_unicast_address_change),
            context,
            0,
            &mut unicast_handle,
        )
    };

    let mut route_handle: HANDLE = std::ptr::null_mut();
    let route_status: WIN32_ERROR = unsafe {
        NotifyRouteChange2(
            AF_UNSPEC,
            Some(on_route_change),
            context,
            0,
            &mut route_handle,
        )
    };

    let any_registered =
        iface_status == NO_ERROR || unicast_status == NO_ERROR || route_status == NO_ERROR;
    if any_registered {
        tauri::async_runtime::spawn(run_network_monitor_loop(app, notify_rx));
    }
    iface_status == NO_ERROR && unicast_status == NO_ERROR && route_status == NO_ERROR
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v4(a: u8, b: u8, c: u8, d: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(a, b, c, d))
    }

    fn v6(s: &str) -> IpAddr {
        IpAddr::V6(s.parse::<Ipv6Addr>().unwrap())
    }

    #[test]
    fn fingerprint_ignores_noise_and_detects_default_route_or_address_changes() {
        let routes = vec![
            DefaultRouteEntry { interface_luid: 20, is_ipv6: false, metric: 35 },
            DefaultRouteEntry { interface_luid: 10, is_ipv6: false, metric: 25 },
        ];
        let unicasts = vec![
            UnicastAddressEntry { interface_luid: 10, address: v4(192, 168, 1, 50), preferred: true },
            // Noise: loopback, link-local, tentative, unspecified.
            UnicastAddressEntry { interface_luid: 1, address: v4(127, 0, 0, 1), preferred: true },
            UnicastAddressEntry { interface_luid: 10, address: v4(169, 254, 10, 1), preferred: true },
            UnicastAddressEntry { interface_luid: 10, address: v6("fe80::1"), preferred: true },
            UnicastAddressEntry { interface_luid: 10, address: v4(192, 168, 1, 99), preferred: false },
            UnicastAddressEntry { interface_luid: 10, address: v4(0, 0, 0, 0), preferred: true },
        ];

        let fp1 = compute_fingerprint(&routes, &unicasts);
        assert_eq!(fp1.default_ipv4_interface, Some(10));
        assert_eq!(fp1.default_ipv6_interface, None);
        assert_eq!(fp1.addresses, vec![(10, v4(192, 168, 1, 50))]);

        // Initial baseline does not emit a change.
        assert!(!fingerprint_changed(None, &fp1));
        assert!(!fingerprint_changed(Some(&fp1), &fp1));

        // Reordering input or adding tentative/link-local entries does not change fingerprint.
        let mut noisy_unicasts = unicasts.clone();
        noisy_unicasts.reverse();
        noisy_unicasts.push(UnicastAddressEntry {
            interface_luid: 20,
            address: v6("fe80::2"),
            preferred: true,
        });
        let fp1_noisy = compute_fingerprint(&routes, &noisy_unicasts);
        assert!(!fingerprint_changed(Some(&fp1), &fp1_noisy));

        // VPN takes over default route with lower metric -> fingerprint changes.
        let mut vpn_routes = routes.clone();
        vpn_routes.push(DefaultRouteEntry { interface_luid: 99, is_ipv6: false, metric: 5 });
        let fp_vpn = compute_fingerprint(&vpn_routes, &unicasts);
        assert_eq!(fp_vpn.default_ipv4_interface, Some(99));
        assert!(fingerprint_changed(Some(&fp1), &fp_vpn));

        // DHCP assigns a new IP on the same Wi-Fi interface -> fingerprint changes.
        let dhcp_unicasts = vec![
            UnicastAddressEntry { interface_luid: 10, address: v4(10, 0, 0, 42), preferred: true },
        ];
        let fp_dhcp = compute_fingerprint(&routes, &dhcp_unicasts);
        assert!(fingerprint_changed(Some(&fp1), &fp_dhcp));
    }

    #[test]
    fn burst_debouncer_coalesces_events_and_caps_at_max_delay() {
        let t0 = Instant::now();
        let mut debouncer = BurstDebouncer::new(
            Duration::from_millis(1_200),
            Duration::from_millis(2_000),
        );
        assert_eq!(debouncer.next_deadline(), None);

        // First event sets deadline at t0 + 1200ms.
        let d1 = debouncer.record_event(t0);
        assert_eq!(d1, t0 + Duration::from_millis(1_200));
        assert!(!debouncer.take_if_ready(t0 + Duration::from_millis(1_199)));

        // Second event at t0 + 600ms pushes deadline to t0 + 1800ms.
        let d2 = debouncer.record_event(t0 + Duration::from_millis(600));
        assert_eq!(d2, t0 + Duration::from_millis(1_800));

        // Third event at t0 + 1500ms is capped at t0 + 2000ms (max_delay).
        let d3 = debouncer.record_event(t0 + Duration::from_millis(1_500));
        assert_eq!(d3, t0 + Duration::from_millis(2_000));

        assert!(!debouncer.take_if_ready(t0 + Duration::from_millis(1_999)));
        assert!(debouncer.take_if_ready(t0 + Duration::from_millis(2_000)));
        assert_eq!(debouncer.next_deadline(), None);
        assert!(!debouncer.take_if_ready(t0 + Duration::from_millis(2_500)));
    }

    #[test]
    fn segmented_backoff_ramps_to_300s_and_resets_on_network_change() {
        // Midpoint jitter (0.5) => 1.0x multiplier.
        assert_eq!(segmented_backoff_delay(0, 0.5), Duration::ZERO);
        let expected_secs = [1, 2, 4, 8, 30, 60, 120, 300, 300, 300];
        for (i, &secs) in expected_secs.iter().enumerate() {
            assert_eq!(
                segmented_backoff_delay((i + 1) as u32, 0.5),
                Duration::from_secs(secs),
                "attempt {}",
                i + 1
            );
        }

        // Jitter stays within ±25% and never exceeds 300s.
        assert_eq!(segmented_backoff_delay(1, 0.0), Duration::from_millis(750));
        assert_eq!(segmented_backoff_delay(1, 1.0), Duration::from_millis(1_250));
        assert_eq!(segmented_backoff_delay(8, 0.0), Duration::from_secs(225));
        assert_eq!(segmented_backoff_delay(8, 1.0), Duration::from_secs(300));

        let t0 = Instant::now();
        let mut backoff = ReconnectBackoff::new(t0);
        assert_eq!(backoff.remaining(t0), Duration::ZERO);
        for _ in 0..8 {
            backoff.record_failure(t0, 0.5);
        }
        assert_eq!(backoff.consecutive_failures(), 8);
        assert_eq!(backoff.remaining(t0), Duration::from_secs(300));

        // Network change resets backoff immediately to 0.
        let t1 = t0 + Duration::from_secs(5);
        backoff.reset(t1);
        assert_eq!(backoff.consecutive_failures(), 0);
        assert_eq!(backoff.remaining(t1), Duration::ZERO);
    }

    #[test]
    fn resume_deduplicator_collapses_paired_power_broadcasts() {
        let t0 = Instant::now();
        let mut last = None;
        assert!(should_emit_resume(&mut last, t0, RESUME_DEDUP_WINDOW));
        assert!(!should_emit_resume(&mut last, t0 + Duration::from_millis(50), RESUME_DEDUP_WINDOW));
        assert!(should_emit_resume(&mut last, t0 + Duration::from_millis(600), RESUME_DEDUP_WINDOW));
    }
}
