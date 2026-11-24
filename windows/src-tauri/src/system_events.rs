//! System power, display and sleep signals for the Windows automation engine (macOS parity).
//!
//! macOS reads these from IOKit.ps (power source and battery), `CGGetActiveDisplayList` (external
//! displays) and `NSWorkspace` / `CGDisplayIsAsleep` notifications (`AutomationEngine.swift`).
//! Windows has no equivalent single API, so this module splits the work by what each signal can
//! actually promise:
//!
//! * **Power / battery** — `GetSystemPowerStatus` returns `ACLineStatus`, `BatteryFlag` and
//!   `BatteryLifePercent` in one call. It has no change notification that a tray app can rely on,
//!   so the front end polls it on the macOS cadence (`systemContextPoll.ts`, 10 s).
//! * **External displays** — `QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS)` marks each active path's
//!   `outputTechnology`; `DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL` (and the older embedded
//!   variants) is the Windows spelling of `CGDisplayIsBuiltin`. Counting only the non-internal
//!   paths keeps a closed laptop lid with an external monitor attached from looking like an unplug
//!   (the exact case `activeExternalDisplayCount()` documents on macOS). Also polled.
//! * **Sleep and display power** — polling cannot see either in time, because the machine stops
//!   running our timers. `PowerRegisterSuspendResumeNotification` and
//!   `PowerSettingRegisterNotification(GUID_CONSOLE_DISPLAY_STATE)` are registered as
//!   `DEVICE_NOTIFY_CALLBACK` recipients, so the callback fires on a power-manager thread before
//!   suspend and whenever the console display turns on, off or dims. No window procedure
//!   subclassing is involved: the Tauri window's message loop is never touched.
//!
//! The callback forwards each signal into the webview as a `menumijia:` DOM event, matching the
//! existing `menumijia:open-url` / `menumijia:activate` bridge in `companion.rs`. The front end
//! turns them into `systemSleep` / `systemWake` / `displayPowerChanged` engine events.

use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager};

const ACLINE_STATUS_OFFLINE: u8 = 0;
const ACLINE_STATUS_ONLINE: u8 = 1;
const BATTERY_FLAG_NO_BATTERY: u8 = 128;
const BATTERY_PERCENT_UNKNOWN: u8 = 255;

/// `DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL` (`0x8000_0000`, Windows 10 1607+).
const OUTPUT_TECHNOLOGY_INTERNAL: i32 = i32::MIN;
/// `DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED` / `..._UDI_EMBEDDED`: pre-1607 spelling
/// of an internal panel.
const OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED: i32 = 11;
const OUTPUT_TECHNOLOGY_UDI_EMBEDDED: i32 = 14;
/// `DISPLAYCONFIG_PATH_ACTIVE` in `DISPLAYCONFIG_PATH_INFO.flags` (no windows-sys constant).
const PATH_ACTIVE_FLAG: u32 = 0x1;

const SYSTEM_SLEEP_SCRIPT: &str =
    "window.dispatchEvent(new CustomEvent('menumijia:system-sleep'))";
const SYSTEM_WAKE_SCRIPT: &str = "window.dispatchEvent(new CustomEvent('menumijia:system-wake'))";
const DISPLAY_OFF_SCRIPT: &str =
    "window.dispatchEvent(new CustomEvent('menumijia:display-power',{detail:{asleep:true}}))";
const DISPLAY_ON_SCRIPT: &str =
    "window.dispatchEvent(new CustomEvent('menumijia:display-power',{detail:{asleep:false}}))";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SystemPowerStatus {
    /// `None` only while Windows reports an unknown AC line status; never guessed.
    pub on_external_power: Option<bool>,
    /// `None` on a machine without a battery or while the charge level is unknown, so a low
    /// battery rule can never fire on a desktop.
    pub battery_percent: Option<i32>,
    pub has_battery: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RawPowerStatus {
    pub ac_line_status: u8,
    pub battery_flag: u8,
    pub battery_life_percent: u8,
}

/// Turns one `SYSTEM_POWER_STATUS` reading into automation-safe values.
///
/// A desktop reports `BatteryFlag == 128` (no system battery) with `BatteryLifePercent == 255`
/// (unknown). It is treated as permanently on AC power with no battery, because a machine with no
/// battery has no battery source and must never look like it just unplugged. `BatteryFlag == 255`
/// is *not* "no battery" — Windows uses it for "charging state unknown" — so it keeps the battery
/// and only drops the charge percentage.
pub(crate) fn interpret_power_status(raw: RawPowerStatus) -> SystemPowerStatus {
    let has_battery = raw.battery_flag != BATTERY_FLAG_NO_BATTERY;
    let on_external_power = if has_battery {
        match raw.ac_line_status {
            ACLINE_STATUS_ONLINE => Some(true),
            ACLINE_STATUS_OFFLINE => Some(false),
            _ => None,
        }
    } else {
        Some(true)
    };
    let battery_percent = if has_battery
        && raw.battery_life_percent != BATTERY_PERCENT_UNKNOWN
        && raw.battery_life_percent <= 100
    {
        Some(i32::from(raw.battery_life_percent))
    } else {
        None
    };
    SystemPowerStatus {
        on_external_power,
        battery_percent,
        has_battery,
    }
}

pub(crate) fn is_internal_output_technology(technology: i32) -> bool {
    technology == OUTPUT_TECHNOLOGY_INTERNAL
        || technology == OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED
        || technology == OUTPUT_TECHNOLOGY_UDI_EMBEDDED
}

/// Counts active display paths that are not the built-in panel. `(is_active, outputTechnology)`
/// pairs come straight from `QueryDisplayConfig`; the tuple keeps the count testable off Windows.
pub(crate) fn count_external_displays(paths: &[(bool, i32)]) -> u32 {
    paths
        .iter()
        .filter(|(is_active, technology)| *is_active && !is_internal_output_technology(*technology))
        .count() as u32
}

fn read_power_status() -> Option<SystemPowerStatus> {
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

    let mut status: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
    if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
        return None;
    }
    Some(interpret_power_status(RawPowerStatus {
        ac_line_status: status.ACLineStatus,
        battery_flag: status.BatteryFlag,
        battery_life_percent: status.BatteryLifePercent,
    }))
}

/// `GetSystemPowerStatus` for the poll in `systemContextPoll.ts`.
#[tauri::command]
pub(crate) fn system_power_status() -> Option<SystemPowerStatus> {
    read_power_status()
}

#[tauri::command]
pub(crate) fn awake_time_ms() -> Option<u64> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::WindowsProgramming::QueryUnbiasedInterruptTime;
        let mut ticks = 0;
        // The API writes one u64 of 100-nanosecond ticks and excludes suspend/hibernation.
        let ok = unsafe { QueryUnbiasedInterruptTime(&mut ticks) } != 0;
        unbiased_ticks_to_ms(ok, ticks)
    }
    #[cfg(not(windows))]
    None
}

#[cfg(any(windows, test))]
fn unbiased_ticks_to_ms(ok: bool, ticks: u64) -> Option<u64> {
    ok.then_some(ticks / 10_000)
}

fn read_external_display_count() -> Option<u32> {
    use windows_sys::Win32::Devices::Display::{
        GetDisplayConfigBufferSizes, QueryDisplayConfig, DISPLAYCONFIG_MODE_INFO,
        DISPLAYCONFIG_PATH_INFO, QDC_ONLY_ACTIVE_PATHS,
    };

    let mut path_count: u32 = 0;
    let mut mode_count: u32 = 0;
    let size_status = unsafe {
        GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count)
    };
    if size_status != 0 {
        return None;
    }
    // A live topology change between the size query and the read (plugging a monitor in) makes
    // QueryDisplayConfig fail; the next 10 s poll picks up the new layout.
    let zero_path: DISPLAYCONFIG_PATH_INFO = unsafe { std::mem::zeroed() };
    let zero_mode: DISPLAYCONFIG_MODE_INFO = unsafe { std::mem::zeroed() };
    let mut paths = vec![zero_path; path_count as usize];
    let mut modes = vec![zero_mode; mode_count as usize];
    let status = unsafe {
        QueryDisplayConfig(
            QDC_ONLY_ACTIVE_PATHS,
            &mut path_count,
            paths.as_mut_ptr(),
            &mut mode_count,
            modes.as_mut_ptr(),
            std::ptr::null_mut(),
        )
    };
    if status != 0 {
        return None;
    }
    paths.truncate(path_count as usize);
    let active: Vec<(bool, i32)> = paths
        .iter()
        .map(|path| {
            (
                path.flags & PATH_ACTIVE_FLAG != 0,
                path.targetInfo.outputTechnology,
            )
        })
        .collect();
    Some(count_external_displays(&active))
}

/// Number of active displays that are not the built-in panel, for `externalDisplayChanged`.
#[tauri::command]
pub(crate) fn external_display_count() -> Option<u32> {
    read_external_display_count()
}

struct PowerNotifyContext {
    app: AppHandle,
}

static POWER_NOTIFICATIONS_INSTALLED: AtomicBool = AtomicBool::new(false);

fn is_console_display_state(setting: &windows_sys::core::GUID) -> bool {
    use windows_sys::Win32::System::SystemServices::GUID_CONSOLE_DISPLAY_STATE;
    // `windows_sys::core::GUID` only derives Copy/Clone, so compare the fields.
    setting.data1 == GUID_CONSOLE_DISPLAY_STATE.data1
        && setting.data2 == GUID_CONSOLE_DISPLAY_STATE.data2
        && setting.data3 == GUID_CONSOLE_DISPLAY_STATE.data3
        && setting.data4 == GUID_CONSOLE_DISPLAY_STATE.data4
}

fn emit_to_panel(app: &AppHandle, script: &str) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval(script);
    }
}

unsafe extern "system" fn on_power_broadcast(
    context: *const core::ffi::c_void,
    kind: u32,
    setting: *const core::ffi::c_void,
) -> u32 {
    use windows_sys::Win32::System::Power::POWERBROADCAST_SETTING;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        PBT_APMRESUMEAUTOMATIC, PBT_APMRESUMESUSPEND, PBT_APMSUSPEND, PBT_POWERSETTINGCHANGE,
    };

    let Some(context) = (unsafe { (context as *const PowerNotifyContext).as_ref() }) else {
        return 0;
    };
    match kind {
        PBT_APMSUSPEND => emit_to_panel(&context.app, SYSTEM_SLEEP_SCRIPT),
        PBT_APMRESUMEAUTOMATIC | PBT_APMRESUMESUSPEND => {
            emit_to_panel(&context.app, SYSTEM_WAKE_SCRIPT)
        }
        PBT_POWERSETTINGCHANGE if !setting.is_null() => {
            let broadcast = unsafe { &*(setting as *const POWERBROADCAST_SETTING) };
            if broadcast.DataLength >= 1 && is_console_display_state(&broadcast.PowerSetting) {
                // 0 = off, 1 = on, 2 = dimmed; a dimmed display is still awake.
                let script = if broadcast.Data[0] == 0 {
                    DISPLAY_OFF_SCRIPT
                } else {
                    DISPLAY_ON_SCRIPT
                };
                emit_to_panel(&context.app, script);
            }
        }
        _ => {}
    }
    0
}

/// Registers the suspend/resume and console-display callbacks once per process.
///
/// Both take a `DEVICE_NOTIFY_CALLBACK` recipient, so no window handle or `SetWindowSubclass` is
/// needed and the Tauri message loop stays untouched. The returned flag says whether both
/// registrations succeeded; the parameter block is intentionally leaked because Windows keeps
/// reading it for the lifetime of the registration.
pub(crate) fn install_power_notifications(app: AppHandle) -> bool {
    use windows_sys::Win32::Foundation::{HANDLE, WIN32_ERROR};
    use windows_sys::Win32::System::Power::{
        PowerRegisterSuspendResumeNotification, PowerSettingRegisterNotification,
        DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS,
    };
    use windows_sys::Win32::System::SystemServices::GUID_CONSOLE_DISPLAY_STATE;
    use windows_sys::Win32::UI::WindowsAndMessaging::DEVICE_NOTIFY_CALLBACK;

    if POWER_NOTIFICATIONS_INSTALLED.swap(true, Ordering::SeqCst) {
        return true;
    }
    let params: &'static DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS =
        Box::leak(Box::new(DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
            Callback: Some(on_power_broadcast),
            Context: Box::into_raw(Box::new(PowerNotifyContext { app })).cast(),
        }));
    let recipient: HANDLE = (params as *const DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS) as HANDLE;
    // The powrprof registrations hand back an opaque `HPOWERNOTIFY`; both are process-lifetime
    // registrations, so the handles are only kept alive for the call itself.
    let mut suspend_handle: *mut core::ffi::c_void = std::ptr::null_mut();
    let suspend_status: WIN32_ERROR = unsafe {
        PowerRegisterSuspendResumeNotification(
            DEVICE_NOTIFY_CALLBACK,
            recipient,
            &mut suspend_handle,
        )
    };
    let mut display_handle: *mut core::ffi::c_void = std::ptr::null_mut();
    let display_status: WIN32_ERROR = unsafe {
        PowerSettingRegisterNotification(
            &GUID_CONSOLE_DISPLAY_STATE,
            DEVICE_NOTIFY_CALLBACK,
            recipient,
            &mut display_handle,
        )
    };
    suspend_status == 0 && display_status == 0
}

#[cfg(test)]
mod tests {
    #[test]
    fn converts_awake_ticks_to_whole_milliseconds() {
        assert_eq!(super::unbiased_ticks_to_ms(true, 150_009_999), Some(15_000));
        assert_eq!(super::unbiased_ticks_to_ms(false, 0), None);
    }

    use super::*;

    fn status(ac_line_status: u8, battery_flag: u8, battery_life_percent: u8) -> SystemPowerStatus {
        interpret_power_status(RawPowerStatus {
            ac_line_status,
            battery_flag,
            battery_life_percent,
        })
    }

    #[test]
    fn desktop_without_a_battery_stays_on_ac_with_unknown_charge() {
        let desktop = status(ACLINE_STATUS_ONLINE, BATTERY_FLAG_NO_BATTERY, BATTERY_PERCENT_UNKNOWN);
        assert_eq!(desktop.on_external_power, Some(true));
        assert_eq!(desktop.battery_percent, None);
        assert!(!desktop.has_battery);

        // Some VMs report "no battery" together with an offline AC line; a desktop must not look
        // like it just switched to battery power.
        let vm = status(ACLINE_STATUS_OFFLINE, BATTERY_FLAG_NO_BATTERY, 42);
        assert_eq!(vm.on_external_power, Some(true));
        assert_eq!(vm.battery_percent, None);
    }

    #[test]
    fn laptop_reports_ac_charging_and_discharging() {
        assert_eq!(
            status(ACLINE_STATUS_ONLINE, 8, 42),
            SystemPowerStatus {
                on_external_power: Some(true),
                battery_percent: Some(42),
                has_battery: true,
            }
        );
        assert_eq!(
            status(ACLINE_STATUS_OFFLINE, 2, 18),
            SystemPowerStatus {
                on_external_power: Some(false),
                battery_percent: Some(18),
                has_battery: true,
            }
        );
    }

    #[test]
    fn unknown_ac_line_or_charge_level_is_never_guessed() {
        // `BatteryFlag == 255` means "charging state unknown", not "no battery".
        let unknown = status(255, 255, 255);
        assert_eq!(
            unknown.on_external_power, None,
            "an unknown AC state must not invent a transition"
        );
        assert_eq!(unknown.battery_percent, None);
        assert!(unknown.has_battery);

        assert_eq!(status(ACLINE_STATUS_ONLINE, 8, 120).battery_percent, None);
    }

    #[test]
    fn counts_only_active_non_internal_display_paths() {
        let laptop_with_one_external = [(true, OUTPUT_TECHNOLOGY_INTERNAL), (true, 10)];
        assert_eq!(count_external_displays(&laptop_with_one_external), 1);

        // A closed lid takes the internal panel off the active list; the external stays.
        assert_eq!(count_external_displays(&[(true, 5)]), 1);
        assert_eq!(count_external_displays(&[(true, 10), (true, 6)]), 2);
        let embedded = [
            (true, OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED),
            (true, OUTPUT_TECHNOLOGY_UDI_EMBEDDED),
        ];
        assert_eq!(count_external_displays(&embedded), 0);
        assert_eq!(
            count_external_displays(&[(false, 10), (true, OUTPUT_TECHNOLOGY_INTERNAL)]),
            0
        );
    }
}
