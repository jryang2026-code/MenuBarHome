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
use std::sync::{LazyLock, Mutex};
use std::thread::JoinHandle;
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
            crate::network_monitor::notify_system_resume(&context.app);
            emit_to_panel(&context.app, SYSTEM_WAKE_SCRIPT);
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

// ---------------------------------------------------------------------------
// Camera / microphone usage (`CapabilityAccessManager\ConsentStore`) and
// fullscreen / presentation / quiet-hours (`SHQueryUserNotificationState`).
// Privacy invariant: only booleans ever leave Rust — never app names or paths.
// ---------------------------------------------------------------------------

const CONSENT_STORE_WEBCAM: &str =
    r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam";
const CONSENT_STORE_MICROPHONE: &str =
    r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
const FOCUS_ON_SCRIPT: &str =
    "window.dispatchEvent(new CustomEvent('menumijia:focus-mode',{detail:{enabled:true}}))";
const FOCUS_OFF_SCRIPT: &str =
    "window.dispatchEvent(new CustomEvent('menumijia:focus-mode',{detail:{enabled:false}}))";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MediaCaptureStatus {
    pub camera_in_use: bool,
    pub microphone_in_use: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConsentStoreEntry {
    pub subkey_name: String,
    pub last_used_time_start: Option<u64>,
    pub last_used_time_stop: Option<u64>,
}

/// Excludes MenuBarHome itself and its bundled `go2rtc` helper so viewing a home camera inside
/// our own tray app never triggers "camera in use" automation rules.
pub(crate) fn is_self_media_consumer(subkey_name: &str, self_exe_name: Option<&str>) -> bool {
    let tail = subkey_name
        .split(['#', '\\', '/'])
        .rfind(|part| !part.is_empty())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if tail.is_empty() {
        return false;
    }
    if matches!(
        tail.as_str(),
        "go2rtc"
            | "go2rtc.exe"
            | "menubarhome"
            | "menubarhome.exe"
            | "menubarmijia"
            | "menubarmijia.exe"
            | "menubarmijia-windows"
            | "menubarmijia-windows.exe"
    ) || tail.starts_with("com.jryang.menubarmijia")
        || tail.starts_with("menubarhome_")
        || tail.starts_with("menubarmijia_")
    {
        return true;
    }
    if let Some(exe) = self_exe_name
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase)
    {
        if tail == exe {
            return true;
        }
    }
    false
}

/// A `CapabilityAccessManager` subkey represents an active capture session when Windows has
/// recorded a non-zero start timestamp (`LastUsedTimeStart > 0`) and `LastUsedTimeStop == 0`.
pub(crate) fn is_consent_entry_active(
    entry: &ConsentStoreEntry,
    self_exe_name: Option<&str>,
) -> bool {
    if is_self_media_consumer(&entry.subkey_name, self_exe_name) {
        return false;
    }
    matches!(
        (entry.last_used_time_start, entry.last_used_time_stop),
        (Some(start), Some(0)) if start > 0
    )
}

pub(crate) fn any_media_consumer_active(
    entries: &[ConsentStoreEntry],
    self_exe_name: Option<&str>,
) -> bool {
    entries
        .iter()
        .any(|entry| is_consent_entry_active(entry, self_exe_name))
}

pub(crate) fn media_capture_event_script(status: MediaCaptureStatus) -> String {
    format!(
        "window.dispatchEvent(new CustomEvent('menumijia:media-capture',{{detail:{{cameraInUse:{},microphoneInUse:{}}}}}))",
        status.camera_in_use, status.microphone_in_use
    )
}

/// Maps `QUERY_USER_NOTIFICATION_STATE` (`shellapi.h`) into the Focus / fullscreen boolean:
/// - `2` (`QUNS_BUSY`), `3` (`QUNS_RUNNING_D3D_FULL_SCREEN`), `4` (`QUNS_PRESENTATION_MODE`),
///   `6` (`QUNS_QUIET_TIME`) => `true`
/// - `1` (`QUNS_NOT_PRESENT`, screen locked/away), `5` (`QUNS_ACCEPTS_NOTIFICATIONS`),
///   `7` (`QUNS_APP`) => `false`
pub(crate) fn is_notification_state_busy(state: i32) -> bool {
    matches!(state, 2 | 3 | 4 | 6)
}

pub(crate) fn focus_mode_event_script(enabled: bool) -> &'static str {
    if enabled {
        FOCUS_ON_SCRIPT
    } else {
        FOCUS_OFF_SCRIPT
    }
}

fn encode_wide_nul(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn current_exe_file_name() -> Option<String> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
}

fn read_reg_qword(
    parent: windows_sys::Win32::System::Registry::HKEY,
    subkey_wide: &[u16],
    value_wide: &[u16],
) -> Option<u64> {
    use windows_sys::Win32::System::Registry::{RegGetValueW, RRF_RT_REG_QWORD};

    let mut value: u64 = 0;
    let mut size: u32 = std::mem::size_of::<u64>() as u32;
    let status = unsafe {
        RegGetValueW(
            parent,
            subkey_wide.as_ptr(),
            value_wide.as_ptr(),
            RRF_RT_REG_QWORD,
            std::ptr::null_mut(),
            (&mut value as *mut u64).cast(),
            &mut size,
        )
    };
    if status == 0 && size == std::mem::size_of::<u64>() as u32 {
        Some(value)
    } else {
        None
    }
}

fn scan_consent_key_children(
    parent: windows_sys::Win32::System::Registry::HKEY,
    skip_non_packaged: bool,
    self_exe: Option<&str>,
) -> bool {
    use windows_sys::Win32::Foundation::ERROR_NO_MORE_ITEMS;
    use windows_sys::Win32::System::Registry::RegEnumKeyExW;

    let start_wide = encode_wide_nul("LastUsedTimeStart");
    let stop_wide = encode_wide_nul("LastUsedTimeStop");
    let mut name_buf = vec![0u16; 512];
    let mut index: u32 = 0;

    loop {
        let mut name_len: u32 = name_buf.len() as u32;
        let status = unsafe {
            RegEnumKeyExW(
                parent,
                index,
                name_buf.as_mut_ptr(),
                &mut name_len,
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        index += 1;
        if status == ERROR_NO_MORE_ITEMS {
            break;
        }
        if status != 0 || name_len == 0 {
            continue;
        }
        let subkey_name = String::from_utf16_lossy(&name_buf[..name_len as usize]);
        if skip_non_packaged && subkey_name.eq_ignore_ascii_case("NonPackaged") {
            continue;
        }
        if is_self_media_consumer(&subkey_name, self_exe) {
            continue;
        }
        let mut subkey_wide = Vec::with_capacity(name_len as usize + 1);
        subkey_wide.extend_from_slice(&name_buf[..name_len as usize]);
        subkey_wide.push(0);
        let entry = ConsentStoreEntry {
            subkey_name,
            last_used_time_start: read_reg_qword(parent, &subkey_wide, &start_wide),
            last_used_time_stop: read_reg_qword(parent, &subkey_wide, &stop_wide),
        };
        if is_consent_entry_active(&entry, self_exe) {
            return true;
        }
    }
    false
}

fn read_consent_store_in_use(subkey_path: &str, self_exe: Option<&str>) -> bool {
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_READ,
    };

    let path_wide = encode_wide_nul(subkey_path);
    let mut root: HKEY = std::ptr::null_mut();
    if unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, path_wide.as_ptr(), 0, KEY_READ, &mut root) } != 0 {
        return false;
    }
    let packaged_active = scan_consent_key_children(root, true, self_exe);
    if packaged_active {
        unsafe { let _ = RegCloseKey(root); }
        return true;
    }
    let non_packaged_wide = encode_wide_nul("NonPackaged");
    let mut non_packaged: HKEY = std::ptr::null_mut();
    let desktop_active = if unsafe {
        RegOpenKeyExW(root, non_packaged_wide.as_ptr(), 0, KEY_READ, &mut non_packaged)
    } == 0
    {
        let active = scan_consent_key_children(non_packaged, false, self_exe);
        unsafe { let _ = RegCloseKey(non_packaged); }
        active
    } else {
        false
    };
    unsafe { let _ = RegCloseKey(root); }
    desktop_active
}

fn read_media_capture_status() -> MediaCaptureStatus {
    let self_exe = current_exe_file_name();
    let self_ref = self_exe.as_deref();
    MediaCaptureStatus {
        camera_in_use: read_consent_store_in_use(CONSENT_STORE_WEBCAM, self_ref),
        microphone_in_use: read_consent_store_in_use(CONSENT_STORE_MICROPHONE, self_ref),
    }
}

/// One-shot camera/microphone capture snapshot for baseline priming.
#[tauri::command]
pub(crate) fn media_capture_status() -> MediaCaptureStatus {
    read_media_capture_status()
}

fn read_focus_mode_active() -> Option<bool> {
    use windows_sys::Win32::Foundation::S_OK;
    use windows_sys::Win32::UI::Shell::{
        SHQueryUserNotificationState, QUERY_USER_NOTIFICATION_STATE,
    };

    let mut state: QUERY_USER_NOTIFICATION_STATE = 0;
    let hr = unsafe { SHQueryUserNotificationState(&mut state) };
    if hr != S_OK {
        return None;
    }
    Some(is_notification_state_busy(state))
}

/// One-shot fullscreen / presentation / quiet-hours snapshot (`SHQueryUserNotificationState`).
#[tauri::command]
pub(crate) fn focus_mode_status() -> Option<bool> {
    read_focus_mode_active()
}

struct SendHandle(windows_sys::Win32::Foundation::HANDLE);
unsafe impl Send for SendHandle {}
impl SendHandle {
    fn as_raw(&self) -> windows_sys::Win32::Foundation::HANDLE {
        self.0
    }
}

struct MediaWatcherHandle {
    stop_event: SendHandle,
    join: Option<JoinHandle<()>>,
}

struct FocusWatcherHandle {
    thread_id: u32,
    join: Option<JoinHandle<()>>,
}

struct FocusWatcherShared {
    app: AppHandle,
    last_busy: Option<bool>,
}

static MEDIA_WATCHER: LazyLock<Mutex<Option<MediaWatcherHandle>>> = LazyLock::new(|| Mutex::new(None));
static FOCUS_WATCHER: LazyLock<Mutex<Option<FocusWatcherHandle>>> = LazyLock::new(|| Mutex::new(None));
static FOCUS_WATCHER_SHARED: LazyLock<Mutex<Option<FocusWatcherShared>>> =
    LazyLock::new(|| Mutex::new(None));

fn start_media_watcher(app: AppHandle) {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegNotifyChangeKeyValue, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_NOTIFY,
        KEY_READ, REG_NOTIFY_CHANGE_LAST_SET, REG_NOTIFY_CHANGE_NAME,
    };
    use windows_sys::Win32::System::Threading::{CreateEventW, WaitForMultipleObjects, INFINITE};

    let mut guard = match MEDIA_WATCHER.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if guard.is_some() {
        return;
    }
    let stop_raw: HANDLE =
        unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
    if stop_raw.is_null() {
        return;
    }
    let stop_for_thread = SendHandle(stop_raw);
    let join = std::thread::Builder::new()
        .name("mbh-media-watch".to_string())
        .spawn(move || {
            let stop_event = stop_for_thread.as_raw();
            let webcam_event = unsafe { CreateEventW(std::ptr::null(), 0, 0, std::ptr::null()) };
            let mic_event = unsafe { CreateEventW(std::ptr::null(), 0, 0, std::ptr::null()) };
            let webcam_path = encode_wide_nul(CONSENT_STORE_WEBCAM);
            let mic_path = encode_wide_nul(CONSENT_STORE_MICROPHONE);
            let mut webcam_key: HKEY = std::ptr::null_mut();
            let mut mic_key: HKEY = std::ptr::null_mut();
            let mut last = read_media_capture_status();

            let open_key = |path: &[u16]| -> HKEY {
                let mut k: HKEY = std::ptr::null_mut();
                if unsafe {
                    RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, KEY_READ | KEY_NOTIFY, &mut k)
                } == 0
                {
                    k
                } else {
                    std::ptr::null_mut()
                }
            };

            loop {
                if webcam_key.is_null() {
                    webcam_key = open_key(&webcam_path);
                }
                if mic_key.is_null() {
                    mic_key = open_key(&mic_path);
                }
                let mut wait_handles: [HANDLE; 3] = [stop_event, std::ptr::null_mut(), std::ptr::null_mut()];
                let mut count: u32 = 1;
                let filter = REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET;
                if !webcam_key.is_null() && !webcam_event.is_null() {
                    if unsafe { RegNotifyChangeKeyValue(webcam_key, 1, filter, webcam_event, 1) } == 0 {
                        wait_handles[count as usize] = webcam_event;
                        count += 1;
                    } else {
                        unsafe { let _ = RegCloseKey(webcam_key); }
                        webcam_key = std::ptr::null_mut();
                    }
                }
                if !mic_key.is_null() && !mic_event.is_null() {
                    if unsafe { RegNotifyChangeKeyValue(mic_key, 1, filter, mic_event, 1) } == 0 {
                        wait_handles[count as usize] = mic_event;
                        count += 1;
                    } else {
                        unsafe { let _ = RegCloseKey(mic_key); }
                        mic_key = std::ptr::null_mut();
                    }
                }
                // Zero-polling wait whenever at least one ConsentStore key is open; if neither
                // exists yet on a fresh Windows profile, back off for 30 s before retrying open.
                let timeout = if count > 1 { INFINITE } else { 30_000 };
                let waited = unsafe { WaitForMultipleObjects(count, wait_handles.as_ptr(), 0, timeout) };
                if waited == WAIT_OBJECT_0 {
                    break;
                }
                let current = read_media_capture_status();
                if current != last {
                    last = current;
                    emit_to_panel(&app, &media_capture_event_script(current));
                }
            }

            if !webcam_key.is_null() {
                unsafe { let _ = RegCloseKey(webcam_key); }
            }
            if !mic_key.is_null() {
                unsafe { let _ = RegCloseKey(mic_key); }
            }
            if !webcam_event.is_null() {
                unsafe { let _ = CloseHandle(webcam_event); }
            }
            if !mic_event.is_null() {
                unsafe { let _ = CloseHandle(mic_event); }
            }
        })
        .ok();

    if let Some(join) = join {
        *guard = Some(MediaWatcherHandle {
            stop_event: SendHandle(stop_raw),
            join: Some(join),
        });
    } else {
        unsafe { let _ = CloseHandle(stop_raw); }
    }
}

fn stop_media_watcher() {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::SetEvent;

    let handle = MEDIA_WATCHER.lock().ok().and_then(|mut g| g.take());
    if let Some(mut handle) = handle {
        unsafe { let _ = SetEvent(handle.stop_event.0); }
        if let Some(join) = handle.join.take() {
            let _ = join.join();
        }
        unsafe { let _ = CloseHandle(handle.stop_event.0); }
    }
}

unsafe extern "system" fn on_foreground_win_event(
    _hook: windows_sys::Win32::UI::Accessibility::HWINEVENTHOOK,
    _event: u32,
    _hwnd: windows_sys::Win32::Foundation::HWND,
    _id_object: i32,
    _id_child: i32,
    _id_event_thread: u32,
    _dwms_event_time: u32,
) {
    let Some(busy) = read_focus_mode_active() else {
        return;
    };
    let app_to_emit = FOCUS_WATCHER_SHARED.lock().ok().and_then(|mut guard| {
        let state = guard.as_mut()?;
        if state.last_busy == Some(busy) {
            return None;
        }
        state.last_busy = Some(busy);
        Some(state.app.clone())
    });
    if let Some(app) = app_to_emit {
        emit_to_panel(&app, focus_mode_event_script(busy));
    }
}

fn start_focus_watcher(app: AppHandle) {
    use windows_sys::Win32::System::Threading::GetCurrentThreadId;
    use windows_sys::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        DispatchMessageW, GetMessageW, PeekMessageW, TranslateMessage, EVENT_SYSTEM_FOREGROUND,
        MSG, PM_NOREMOVE, WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS,
    };

    let mut guard = match FOCUS_WATCHER.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if guard.is_some() {
        return;
    }
    if let Ok(mut shared) = FOCUS_WATCHER_SHARED.lock() {
        *shared = Some(FocusWatcherShared {
            app,
            last_busy: read_focus_mode_active(),
        });
    }
    let (tx, rx) = std::sync::mpsc::sync_channel::<u32>(1);
    let join = std::thread::Builder::new()
        .name("mbh-focus-watch".to_string())
        .spawn(move || {
            let mut msg: MSG = unsafe { std::mem::zeroed() };
            // Force creation of this thread's message queue before publishing its thread ID so
            // `PostThreadMessageW(WM_QUIT)` on stop can never race ahead of queue creation.
            unsafe {
                PeekMessageW(&mut msg, std::ptr::null_mut(), 0, 0, PM_NOREMOVE);
            }
            let hook = unsafe {
                SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    std::ptr::null_mut(),
                    Some(on_foreground_win_event),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
                )
            };
            let tid = unsafe { GetCurrentThreadId() };
            let _ = tx.send(tid);
            if hook.is_null() {
                return;
            }
            while unsafe { GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) } > 0 {
                unsafe {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
            unsafe {
                let _ = UnhookWinEvent(hook);
            }
        })
        .ok();

    if let Some(join) = join {
        let thread_id = rx.recv().unwrap_or(0);
        *guard = Some(FocusWatcherHandle {
            thread_id,
            join: Some(join),
        });
    }
}

fn stop_focus_watcher() {
    use windows_sys::Win32::UI::WindowsAndMessaging::{PostThreadMessageW, WM_QUIT};

    if let Ok(mut shared) = FOCUS_WATCHER_SHARED.lock() {
        *shared = None;
    }
    let handle = FOCUS_WATCHER.lock().ok().and_then(|mut g| g.take());
    if let Some(mut handle) = handle {
        if handle.thread_id != 0 {
            unsafe {
                let _ = PostThreadMessageW(handle.thread_id, WM_QUIT, 0, 0);
            }
        }
        if let Some(join) = handle.join.take() {
            let _ = join.join();
        }
    }
}

/// Starts or stops the on-demand camera/mic registry watcher and foreground fullscreen hook.
/// Both remain off unless an enabled automation rule actually listens for them.
#[tauri::command]
pub(crate) fn set_system_event_watchers(app: AppHandle, media_capture: bool, focus_mode: bool) {
    if media_capture {
        start_media_watcher(app.clone());
    } else {
        stop_media_watcher();
    }
    if focus_mode {
        start_focus_watcher(app);
    } else {
        stop_focus_watcher();
    }
}

pub(crate) fn shutdown_system_event_watchers() {
    stop_media_watcher();
    stop_focus_watcher();
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

    #[test]
    fn consent_store_decodes_active_sessions_and_excludes_self_processes() {
        let zoom_active = ConsentStoreEntry {
            subkey_name: "C:#Program Files#Zoom#bin#Zoom.exe".to_string(),
            last_used_time_start: Some(133_700_000_000_000_000),
            last_used_time_stop: Some(0),
        };
        let zoom_stopped = ConsentStoreEntry {
            subkey_name: "C:#Program Files#Zoom#bin#Zoom.exe".to_string(),
            last_used_time_start: Some(133_700_000_000_000_000),
            last_used_time_stop: Some(133_700_001_000_000_000),
        };
        let never_used = ConsentStoreEntry {
            subkey_name: "Microsoft.WindowsCamera_8wekyb3d8bbwe".to_string(),
            last_used_time_start: Some(0),
            last_used_time_stop: Some(0),
        };
        let missing_stop = ConsentStoreEntry {
            subkey_name: "Microsoft.WindowsCamera_8wekyb3d8bbwe".to_string(),
            last_used_time_start: Some(133_700_000_000_000_000),
            last_used_time_stop: None,
        };
        let own_go2rtc = ConsentStoreEntry {
            subkey_name: "C:#Users#Alice#AppData#Local#MenuBarHome#go2rtc.exe".to_string(),
            last_used_time_start: Some(133_700_000_000_000_000),
            last_used_time_stop: Some(0),
        };
        let own_app = ConsentStoreEntry {
            subkey_name: "C:#Program Files#MenuBarHome#MenuBarHome.exe".to_string(),
            last_used_time_start: Some(133_700_000_000_000_000),
            last_used_time_stop: Some(0),
        };
        let renamed_self = ConsentStoreEntry {
            subkey_name: "D:#Dev#custom-tray-host.exe".to_string(),
            last_used_time_start: Some(133_700_000_000_000_000),
            last_used_time_stop: Some(0),
        };

        assert!(is_consent_entry_active(&zoom_active, Some("MenuBarHome.exe")));
        assert!(!is_consent_entry_active(&zoom_stopped, Some("MenuBarHome.exe")));
        assert!(!is_consent_entry_active(&never_used, Some("MenuBarHome.exe")));
        assert!(!is_consent_entry_active(&missing_stop, Some("MenuBarHome.exe")));
        assert!(!is_consent_entry_active(&own_go2rtc, Some("MenuBarHome.exe")));
        assert!(!is_consent_entry_active(&own_app, Some("MenuBarHome.exe")));
        assert!(!is_consent_entry_active(&renamed_self, Some("custom-tray-host.exe")));
        assert!(!any_media_consumer_active(&[own_go2rtc, own_app, zoom_stopped], Some("MenuBarHome.exe")));
        assert!(any_media_consumer_active(&[never_used, zoom_active], Some("MenuBarHome.exe")));
    }

    #[test]
    fn notification_state_decoding_matches_shell_constants() {
        use windows_sys::Win32::UI::Shell::{
            QUNS_ACCEPTS_NOTIFICATIONS, QUNS_APP, QUNS_BUSY, QUNS_NOT_PRESENT,
            QUNS_PRESENTATION_MODE, QUNS_QUIET_TIME, QUNS_RUNNING_D3D_FULL_SCREEN,
        };
        assert!(!is_notification_state_busy(QUNS_NOT_PRESENT));
        assert!(is_notification_state_busy(QUNS_BUSY));
        assert!(is_notification_state_busy(QUNS_RUNNING_D3D_FULL_SCREEN));
        assert!(is_notification_state_busy(QUNS_PRESENTATION_MODE));
        assert!(!is_notification_state_busy(QUNS_ACCEPTS_NOTIFICATIONS));
        assert!(is_notification_state_busy(QUNS_QUIET_TIME));
        assert!(!is_notification_state_busy(QUNS_APP));
        assert!(!is_notification_state_busy(99));
    }

    #[test]
    fn emitted_dom_scripts_contain_only_booleans() {
        let script = media_capture_event_script(MediaCaptureStatus {
            camera_in_use: true,
            microphone_in_use: false,
        });
        assert_eq!(
            script,
            "window.dispatchEvent(new CustomEvent('menumijia:media-capture',{detail:{cameraInUse:true,microphoneInUse:false}}))"
        );
        assert_eq!(focus_mode_event_script(true), FOCUS_ON_SCRIPT);
        assert_eq!(focus_mode_event_script(false), FOCUS_OFF_SCRIPT);
    }
}
