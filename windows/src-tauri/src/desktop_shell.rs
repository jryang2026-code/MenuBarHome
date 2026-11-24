use super::*;
use std::path::Path;

const RUN_SUBKEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const STARTUP_APPROVED_RUN_SUBKEY: &str =
    r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
const RUN_VALUE_NAME: &str = "MenuBarHome";
const MAX_TRAY_TOOLTIP_UTF16_UNITS: usize = 120;
const ALLOWED_PROVIDER_ENV_VARS: &[&str] = &[
    "OPENROUTER_API_KEY",
    "TYPESAFE_API_KEY",
    "JEV_API_KEY",
    "DEEPSEEK_API_KEY",
    "SILICONFLOW_API_KEY",
    "DASHSCOPE_API_KEY",
    "ZHIPU_API_KEY",
    "GLM_API_KEY",
    "MOONSHOT_API_KEY",
    "KIMI_API_KEY",
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GROQ_API_KEY",
];

pub(crate) fn read_allowed_provider_env_var_with<F>(name: &str, reader: F) -> Option<String>
where
    F: FnOnce(&str) -> Option<String>,
{
    let trimmed_name = name.trim();
    if !ALLOWED_PROVIDER_ENV_VARS.contains(&trimmed_name) {
        return None;
    }
    let raw = reader(trimmed_name)?;
    let trimmed_val = raw.trim();
    if trimmed_val.is_empty() {
        return None;
    }
    Some(trimmed_val.to_string())
}

#[tauri::command]
pub(crate) fn get_env_var(name: String) -> Option<String> {
    read_allowed_provider_env_var_with(&name, |key| std::env::var(key).ok())
}

pub(crate) fn format_launch_at_login_value(exe_path: &Path) -> Result<String, String> {
    let raw = exe_path
        .to_str()
        .ok_or_else(|| "可执行文件路径包含无效字符".to_string())?;
    if raw.is_empty() || raw.contains('"') || raw.contains('\0') || raw.contains('\r') || raw.contains('\n') {
        return Err("可执行文件路径格式不安全".to_string());
    }
    Ok(format!("\"{raw}\" {}", crate::companion::AUTOSTART_ARG))
}

/// Interprets a `REG_BINARY` value from `Explorer\StartupApproved\Run`.
/// Windows marks Task Manager-disabled entries with an odd first byte (typically `0x03`)
/// and enabled entries with an even first byte (typically `0x02`). Missing or empty values
/// mean Windows has not disabled the `Run` entry.
pub(crate) fn is_startup_approved_enabled(raw_bytes: Option<&[u8]>) -> bool {
    match raw_bytes {
        Some([first, ..]) => first % 2 == 0,
        _ => true,
    }
}

#[cfg(windows)]
fn wide_null(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

#[cfg(windows)]
fn delete_registry_value_if_present(subkey: &str, value_name: &str) -> Result<(), String> {
    use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegDeleteValueW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE,
    };

    let subkey_wide = wide_null(subkey);
    let value_wide = wide_null(value_name);
    let mut hkey: HKEY = std::ptr::null_mut();
    let open_status = unsafe {
        RegOpenKeyExW(HKEY_CURRENT_USER, subkey_wide.as_ptr(), 0, KEY_SET_VALUE, &mut hkey)
    };
    if open_status == ERROR_FILE_NOT_FOUND {
        return Ok(());
    }
    if open_status != 0 {
        return Err(format!("打开开机自启注册表项失败（Win32 错误码 {open_status}）"));
    }
    let del_status = unsafe { RegDeleteValueW(hkey, value_wide.as_ptr()) };
    unsafe { let _ = RegCloseKey(hkey); }
    if del_status != 0 && del_status != ERROR_FILE_NOT_FOUND {
        return Err(format!("移除开机自启注册表值失败（Win32 错误码 {del_status}）"));
    }
    Ok(())
}

#[cfg(windows)]
pub(crate) fn read_startup_approved_bytes(
    subkey: &str,
    value_name: &str,
) -> Result<Option<Vec<u8>>, String> {
    use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_MORE_DATA};
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_BINARY};

    let subkey_wide = wide_null(subkey);
    let value_wide = wide_null(value_name);
    let mut buf = vec![0u8; 32];
    let mut size: u32 = buf.len() as u32;
    let mut status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            subkey_wide.as_ptr(),
            value_wide.as_ptr(),
            RRF_RT_REG_BINARY,
            std::ptr::null_mut(),
            buf.as_mut_ptr() as *mut core::ffi::c_void,
            &mut size,
        )
    };
    if status == ERROR_MORE_DATA && size > 0 {
        buf.resize(size as usize, 0);
        status = unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                subkey_wide.as_ptr(),
                value_wide.as_ptr(),
                RRF_RT_REG_BINARY,
                std::ptr::null_mut(),
                buf.as_mut_ptr() as *mut core::ffi::c_void,
                &mut size,
            )
        };
    }
    if status == 0 {
        buf.truncate(size as usize);
        return Ok(Some(buf));
    }
    if status == ERROR_FILE_NOT_FOUND {
        return Ok(None);
    }
    Err(format!("读取开机自启审批状态失败（Win32 错误码 {status}）"))
}

#[cfg(windows)]
pub(crate) fn apply_run_registry_entry(
    subkey: &str,
    value_name: &str,
    exe_path: Option<&Path>,
) -> Result<(), String> {
    use windows_sys::Win32::System::Registry::{RegCloseKey, RegCreateKeyW, HKEY, HKEY_CURRENT_USER};

    let Some(path) = exe_path else {
        return delete_registry_value_if_present(subkey, value_name);
    };
    let formatted = format_launch_at_login_value(path)?;
    let subkey_wide = wide_null(subkey);
    let mut hkey: HKEY = std::ptr::null_mut();
    let status = unsafe { RegCreateKeyW(HKEY_CURRENT_USER, subkey_wide.as_ptr(), &mut hkey) };
    if status != 0 {
        return Err(format!("打开开机自启注册表项失败（Win32 错误码 {status}）"));
    }
    let res = crate::companion::set_reg_sz_value(hkey, Some(value_name), &formatted);
    unsafe { let _ = RegCloseKey(hkey); }
    res
}

#[cfg(windows)]
pub(crate) fn apply_launch_at_login_entries(
    run_subkey: &str,
    approved_subkey: &str,
    value_name: &str,
    exe_path: Option<&Path>,
) -> Result<(), String> {
    apply_run_registry_entry(run_subkey, value_name, exe_path)?;
    // Clear any Task Manager disabled marker when enabling, and clean up stale entries when disabling.
    delete_registry_value_if_present(approved_subkey, value_name)
}

#[cfg(windows)]
pub(crate) fn has_run_registry_entry(subkey: &str, value_name: &str) -> Result<bool, String> {
    use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_SZ};

    let subkey_wide = wide_null(subkey);
    let value_wide = wide_null(value_name);
    let mut size: u32 = 0;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            subkey_wide.as_ptr(),
            value_wide.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    };
    if status == 0 {
        return Ok(size > 2);
    }
    if status == ERROR_FILE_NOT_FOUND {
        return Ok(false);
    }
    Err(format!("读取开机自启注册表项失败（Win32 错误码 {status}）"))
}

#[cfg(windows)]
pub(crate) fn is_launch_at_login_enabled(
    run_subkey: &str,
    approved_subkey: &str,
    value_name: &str,
) -> Result<bool, String> {
    if !has_run_registry_entry(run_subkey, value_name)? {
        return Ok(false);
    }
    let approved = read_startup_approved_bytes(approved_subkey, value_name)?;
    Ok(is_startup_approved_enabled(approved.as_deref()))
}

#[tauri::command]
pub(crate) fn get_launch_at_login() -> Result<bool, String> {
    is_launch_at_login_enabled(RUN_SUBKEY, STARTUP_APPROVED_RUN_SUBKEY, RUN_VALUE_NAME)
}

/// Immediately writes or deletes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MenuBarHome`
/// and clears `Explorer\StartupApproved\Run\MenuBarHome` when the user toggles Launch at Login (Coding Standard #3).
#[tauri::command]
pub(crate) fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    if enabled {
        let exe = std::env::current_exe().map_err(|err| format!("无法获取当前程序路径：{err}"))?;
        apply_launch_at_login_entries(
            RUN_SUBKEY,
            STARTUP_APPROVED_RUN_SUBKEY,
            RUN_VALUE_NAME,
            Some(&exe),
        )
    } else {
        apply_launch_at_login_entries(
            RUN_SUBKEY,
            STARTUP_APPROVED_RUN_SUBKEY,
            RUN_VALUE_NAME,
            None,
        )
    }
}

pub(crate) fn interpret_input_desktop_probe(opened: bool, switch_succeeded: bool) -> bool {
    !opened || !switch_succeeded
}

#[cfg(windows)]
fn probe_workstation_locked() -> bool {
    const DESKTOP_SWITCHDESKTOP: u32 = 0x0100;
    #[link(name = "user32")]
    extern "system" {
        fn OpenInputDesktop(dw_flags: u32, f_inherit: i32, dw_desired_access: u32) -> isize;
        fn SwitchDesktop(h_desktop: isize) -> i32;
        fn CloseDesktop(h_desktop: isize) -> i32;
    }
    unsafe {
        let desktop = OpenInputDesktop(0, 0, DESKTOP_SWITCHDESKTOP);
        if desktop == 0 {
            return interpret_input_desktop_probe(false, false);
        }
        let switched = SwitchDesktop(desktop);
        let _ = CloseDesktop(desktop);
        interpret_input_desktop_probe(true, switched != 0)
    }
}

#[tauri::command]
pub(crate) fn is_workstation_locked() -> bool {
    probe_workstation_locked()
}

fn sanitize_tooltip_summary(raw: Option<&str>) -> Option<String> {
    let cleaned: String = raw?
        .chars()
        .map(|ch| if ch == '\r' || ch == '\n' || ch == '\t' { ' ' } else { ch })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.to_string())
}

fn clamp_utf16_units(text: &str, max_units: usize) -> String {
    if text.encode_utf16().count() <= max_units {
        return text.to_string();
    }
    let mut out = String::new();
    let mut used = 0usize;
    let budget = max_units.saturating_sub(1);
    for ch in text.chars() {
        let units = ch.len_utf16();
        if used + units > budget {
            out.push('…');
            break;
        }
        out.push(ch);
        used += units;
    }
    out
}

pub(crate) fn format_tray_tooltip(
    shortcut_label: Option<&str>,
    live_summary: Option<&str>,
) -> String {
    let clean_shortcut = shortcut_label.map(str::trim).filter(|s| !s.is_empty());
    let clean_summary = sanitize_tooltip_summary(live_summary);
    let raw = match (clean_summary.as_deref(), clean_shortcut) {
        (Some(summary), Some(label)) => format!("MenuBarHome · {summary} ({label})"),
        (Some(summary), None) => format!("MenuBarHome · {summary}"),
        (None, Some(label)) => format!("MenuBarHome · 菜单栏米家 ({label})"),
        (None, None) => "MenuBarHome · 菜单栏米家".to_string(),
    };
    clamp_utf16_units(&raw, MAX_TRAY_TOOLTIP_UTF16_UNITS)
}

#[tauri::command]
pub(crate) fn set_tray_tooltip(app: AppHandle, summary: Option<String>) -> Result<(), String> {
    let clean_summary = sanitize_tooltip_summary(summary.as_deref());
    let shortcut_label = {
        let mut guard = TRAY_AND_HOTKEY_STATE
            .write()
            .map_err(|_| "托盘状态不可用".to_string())?;
        guard.live_summary = clean_summary.clone();
        guard.shortcut_label.clone()
    };
    let Some(tray) = app.tray_by_id("main-tray") else {
        return Ok(());
    };
    let tooltip = format_tray_tooltip(shortcut_label.as_deref(), clean_summary.as_deref());
    tray.set_tooltip(Some(tooltip))
        .map_err(|err| err.to_string())
}

pub(crate) fn escape_toast_xml(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\r' | '\n' | '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

const TOAST_URL_PREFIX: &str = "menumijia://notification/";

#[derive(Clone, Copy, Default, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ToastKind {
    #[default]
    Safety,
    Doorbell,
    Leak,
    Smoke,
    Gas,
}

impl ToastKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Safety => "safety",
            Self::Doorbell => "doorbell",
            Self::Leak => "leak",
            Self::Smoke => "smoke",
            Self::Gas => "gas",
        }
    }

    fn is_hazard(self) -> bool {
        matches!(self, Self::Leak | Self::Smoke | Self::Gas)
    }
}

fn is_valid_toast_device_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id != "."
        && id != ".."
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:@-".contains(&b))
}

#[cfg(test)]
pub(crate) fn parse_toast_activation(url: &str) -> Option<&str> {
    let (kind, id) = url.strip_prefix(TOAST_URL_PREFIX)?.split_once('/')?;
    if !matches!(kind, "safety" | "doorbell" | "leak" | "smoke" | "gas")
        || !is_valid_toast_device_id(id)
    {
        return None;
    }
    Some(id)
}

fn format_windows_toast_xml(
    title: &str,
    body: &str,
    kind: ToastKind,
    device_id: Option<&str>,
) -> Result<String, String> {
    let clean_title = escape_toast_xml(&clamp_utf16_units(title.trim(), 120));
    let clean_body = escape_toast_xml(&clamp_utf16_units(body.trim(), 240));
    if clean_title.is_empty() && clean_body.is_empty() {
        return Err("通知标题与内容不能为空".to_string());
    }
    let scenario = if kind.is_hazard() { " scenario=\"alarm\"" } else { "" };
    let activation = device_id
        .filter(|id| is_valid_toast_device_id(id))
        .map(|id| format!(" activationType=\"protocol\" launch=\"{TOAST_URL_PREFIX}{}/{id}\"", kind.as_str()))
        .unwrap_or_default();
    Ok(format!(
        "<toast{scenario}{activation}><visual><binding template=\"ToastGeneric\"><text>{clean_title}</text><text>{clean_body}</text></binding></visual></toast>"
    ))
}

#[cfg(any(windows, test))]
const LEGACY_TOAST_AUMID: &str = "com.jryang.menubarmijia";

#[cfg(any(windows, test))]
pub(crate) const WINDOWS_TOAST_POWERSHELL_SCRIPT: &str =
    "$ErrorActionPreference = 'Stop'; \
     [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; \
     [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null; \
     $doc = New-Object Windows.Data.Xml.Dom.XmlDocument; \
     $doc.LoadXml([string]$env:MMB_TOAST_XML); \
     $toast = [Windows.UI.Notifications.ToastNotification]::new($doc); \
     $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier([string]$env:MMB_TOAST_AUMID); \
     if ([int]$notifier.Setting -ne 0) { throw 'Windows toast notifications are disabled' }; \
     $notifier.Show($toast)";

#[cfg(any(windows, test))]
fn powershell_toast_aumid(aumid: &str, winrt_result: Option<Result<(), ()>>) -> Option<&str> {
    match winrt_result {
        Some(Ok(())) => None,
        Some(Err(())) => Some(aumid),
        None => Some(LEGACY_TOAST_AUMID),
    }
}

#[cfg(any(windows, test))]
fn powershell_toast_command(aumid: &str, xml: &str) -> std::process::Command {
    let mut command = std::process::Command::new("powershell.exe");
    command
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            WINDOWS_TOAST_POWERSHELL_SCRIPT,
        ])
        .env("MMB_TOAST_XML", xml)
        .env("MMB_TOAST_AUMID", aumid);
    command
}

#[cfg(windows)]
fn is_toast_registered(aumid: &str) -> bool {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CLASSES_ROOT, RRF_RT_REG_SZ};

    let key: Vec<u16> = format!("AppUserModelId\\{aumid}").encode_utf16().chain([0]).collect();
    let value: Vec<u16> = "CustomActivator".encode_utf16().chain([0]).collect();
    let mut size = 0;
    let status = unsafe {
        RegGetValueW(
            HKEY_CLASSES_ROOT,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    };
    status == 0 && size > 2
}

#[cfg(windows)]
fn show_winrt_toast(aumid: &str, xml: &str, kind: ToastKind) -> windows::core::Result<()> {
    use windows::core::HSTRING;
    use windows::Data::Xml::Dom::XmlDocument;
    use windows::UI::Notifications::{
        NotificationSetting, ToastNotification, ToastNotificationManager, ToastNotificationPriority,
    };
    use windows::Win32::System::WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED};
    use windows_sys::Win32::Foundation::E_ACCESSDENIED;

    unsafe { RoInitialize(RO_INIT_MULTITHREADED)? };
    let result = (|| {
        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(aumid))?;
        let setting = notifier.Setting()?;
        if setting != NotificationSetting::Enabled {
            return Err(windows::core::Error::new(
                windows::core::HRESULT(E_ACCESSDENIED),
                format!("Windows toast notifications are disabled (setting {})", setting.0),
            ));
        }
        let doc = XmlDocument::new()?;
        doc.LoadXml(&HSTRING::from(xml))?;
        let toast = ToastNotification::CreateToastNotification(&doc)?;
        if kind.is_hazard() {
            toast.SetPriority(ToastNotificationPriority::High)?;
        }
        notifier.Show(&toast)
    })();
    unsafe { RoUninitialize() };
    result
}

#[tauri::command]
pub(crate) async fn send_desktop_notification(
    app: AppHandle,
    title: String,
    body: String,
    kind: Option<ToastKind>,
    device_id: Option<String>,
) -> Result<(), String> {
    let kind = kind.unwrap_or_default();
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Diagnostics::Debug::OutputDebugStringW;

        let aumid = app.config().identifier.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let use_winrt =
                !cfg!(debug_assertions) && !tauri::is_dev() && is_toast_registered(&aumid);
            let activation_device_id = if use_winrt { device_id.as_deref() } else { None };
            let xml = format_windows_toast_xml(&title, &body, kind, activation_device_id)?;
            let winrt_result = use_winrt.then(|| {
                show_winrt_toast(&aumid, &xml, kind).map_err(|err| {
                    let message: Vec<u16> = format!("WinRT 系统通知发送失败，尝试 PowerShell：{err}\n")
                        .encode_utf16()
                        .chain([0])
                        .collect();
                    unsafe { OutputDebugStringW(message.as_ptr()) };
                })
            });
            let Some(fallback_aumid) = powershell_toast_aumid(&aumid, winrt_result) else {
                return Ok(());
            };
            let status = powershell_toast_command(fallback_aumid, &xml)
                .creation_flags(crate::CREATE_NO_WINDOW)
                .status()
                .map_err(|err| format!("启动系统通知失败：{err}"))?;
            if !status.success() {
                return Err("系统通知发送失败".to_string());
            }
            Ok(())
        })
        .await
        .map_err(|err| format!("启动系统通知失败：{err}"))??;
    }
    #[cfg(not(windows))]
    {
        let _ = (app, format_windows_toast_xml(&title, &body, kind, device_id.as_deref())?);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workstation_lock_probe_interpretation_covers_all_desktop_states() {
        assert!(interpret_input_desktop_probe(false, false));
        assert!(interpret_input_desktop_probe(true, false));
        assert!(!interpret_input_desktop_probe(true, true));
    }

    #[test]
    fn tray_tooltip_formats_live_summary_and_bounds_win32_utf16_length() {
        assert_eq!(
            format_tray_tooltip(Some("Alt+M"), None),
            "MenuBarHome · 菜单栏米家 (Alt+M)"
        );
        assert_eq!(
            format_tray_tooltip(None, None),
            "MenuBarHome · 菜单栏米家"
        );
        assert_eq!(
            format_tray_tooltip(Some("Alt+M"), Some("24.5°C 52% · 3 台开启")),
            "MenuBarHome · 24.5°C 52% · 3 台开启 (Alt+M)"
        );
        let huge = "客厅温湿度传感器 ".repeat(20);
        let clamped = format_tray_tooltip(Some("Alt+M"), Some(&huge));
        assert!(clamped.encode_utf16().count() <= MAX_TRAY_TOOLTIP_UTF16_UNITS);
    }

    #[test]
    fn startup_approved_binary_parser_matches_windows_task_manager_semantics() {
        // Missing or empty StartupApproved value means enabled by default.
        assert!(is_startup_approved_enabled(None));
        assert!(is_startup_approved_enabled(Some(&[])));
        // Even first byte (0x02 / 0x06) means approved / enabled.
        assert!(is_startup_approved_enabled(Some(&[0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])));
        assert!(is_startup_approved_enabled(Some(&[0x06, 0, 0, 0])));
        // Odd first byte (0x03 / 0x01 / 0x07) means disabled by Task Manager.
        assert!(!is_startup_approved_enabled(Some(&[0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])));
        assert!(!is_startup_approved_enabled(Some(&[0x01])));
        assert!(!is_startup_approved_enabled(Some(&[0x07, 0x01, 0x02])));
    }

    #[test]
    fn launch_at_login_formats_quoted_exe_and_cleans_up_registry_entry() {
        let val = format_launch_at_login_value(Path::new(r"C:\Apps\MenuBarHome\MenuBarHome.exe"))
            .expect("quoted launch value");
        assert_eq!(val, r#""C:\Apps\MenuBarHome\MenuBarHome.exe" --autostart"#);
        assert!(format_launch_at_login_value(Path::new(r#"C:\bad"path\app.exe"#)).is_err());

        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::System::Registry::{
                RegCloseKey, RegCreateKeyW, RegDeleteKeyW, RegSetValueExW, HKEY,
                HKEY_CURRENT_USER, REG_BINARY,
            };

            let run_subkey = format!(r"Software\MenuBarHomeTestRun-{}", std::process::id());
            let approved_subkey =
                format!(r"Software\MenuBarHomeTestApproved-{}", std::process::id());
            assert_eq!(
                is_launch_at_login_enabled(&run_subkey, &approved_subkey, "MenuBarHome"),
                Ok(false)
            );
            apply_launch_at_login_entries(
                &run_subkey,
                &approved_subkey,
                "MenuBarHome",
                Some(Path::new(r"C:\Apps\MenuBarHome\MenuBarHome.exe")),
            )
            .expect("write test Run entry");
            assert_eq!(
                is_launch_at_login_enabled(&run_subkey, &approved_subkey, "MenuBarHome"),
                Ok(true)
            );

            // Simulate Task Manager disabling the entry via StartupApproved\Run = 0x03...
            let approved_wide: Vec<u16> = std::ffi::OsStr::new(&approved_subkey)
                .encode_wide()
                .chain(std::iter::once(0))
                .collect();
            let val_wide: Vec<u16> = std::ffi::OsStr::new("MenuBarHome")
                .encode_wide()
                .chain(std::iter::once(0))
                .collect();
            let mut hkey: HKEY = std::ptr::null_mut();
            assert_eq!(
                unsafe { RegCreateKeyW(HKEY_CURRENT_USER, approved_wide.as_ptr(), &mut hkey) },
                0
            );
            let disabled_bytes: [u8; 12] = [0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
            assert_eq!(
                unsafe {
                    RegSetValueExW(
                        hkey,
                        val_wide.as_ptr(),
                        0,
                        REG_BINARY,
                        disabled_bytes.as_ptr(),
                        disabled_bytes.len() as u32,
                    )
                },
                0
            );
            unsafe {
                let _ = RegCloseKey(hkey);
            }
            assert_eq!(
                is_launch_at_login_enabled(&run_subkey, &approved_subkey, "MenuBarHome"),
                Ok(false)
            );

            // Re-enabling clears StartupApproved\Run so autostart actually takes effect again.
            apply_launch_at_login_entries(
                &run_subkey,
                &approved_subkey,
                "MenuBarHome",
                Some(Path::new(r"C:\Apps\MenuBarHome\MenuBarHome.exe")),
            )
            .expect("re-enable clears StartupApproved");
            assert_eq!(
                is_launch_at_login_enabled(&run_subkey, &approved_subkey, "MenuBarHome"),
                Ok(true)
            );

            apply_launch_at_login_entries(&run_subkey, &approved_subkey, "MenuBarHome", None)
                .expect("delete test Run entry");
            assert_eq!(
                is_launch_at_login_enabled(&run_subkey, &approved_subkey, "MenuBarHome"),
                Ok(false)
            );
            apply_launch_at_login_entries(&run_subkey, &approved_subkey, "MenuBarHome", None)
                .expect("idempotent delete missing Run entry");

            for key in [&run_subkey, &approved_subkey] {
                let wide: Vec<u16> = std::ffi::OsStr::new(key)
                    .encode_wide()
                    .chain(std::iter::once(0))
                    .collect();
                unsafe {
                    let _ = RegDeleteKeyW(HKEY_CURRENT_USER, wide.as_ptr());
                }
            }
        }
    }

    #[test]
    fn provider_env_var_reader_allowlists_known_keys_and_trims_values() {
        assert_eq!(
            read_allowed_provider_env_var_with("OPENROUTER_API_KEY", |_| Some(
                "  sk-or-test-123  ".to_string()
            )),
            Some("sk-or-test-123".to_string())
        );
        assert_eq!(
            read_allowed_provider_env_var_with("  GEMINI_API_KEY  ", |_| Some(
                "AIza-test".to_string()
            )),
            Some("AIza-test".to_string())
        );
        assert_eq!(
            read_allowed_provider_env_var_with("OPENROUTER_API_KEY", |_| Some("   ".to_string())),
            None
        );
        assert_eq!(
            read_allowed_provider_env_var_with("PATH", |_| Some("/usr/bin".to_string())),
            None
        );
        assert_eq!(
            read_allowed_provider_env_var_with("AWS_SECRET_ACCESS_KEY", |_| Some(
                "secret".to_string()
            )),
            None
        );
    }

    #[test]
    fn windows_toast_xml_escapes_entities_and_rejects_empty_payloads() {
        let xml = format_windows_toast_xml(
            "门铃 <前门> & 告警",
            "点击 '查看' \"画面\"\n第二行",
            ToastKind::Doorbell,
            Some("camera.front_door"),
        )
        .expect("valid toast xml");
        assert!(xml.contains("&lt;前门&gt; &amp; 告警"));
        assert!(xml.contains("&apos;查看&apos; &quot;画面&quot; 第二行"));
        assert!(xml.contains("activationType=\"protocol\" launch=\"menumijia://notification/doorbell/camera.front_door\""));
        assert!(!xml.contains("scenario="));
        let curly = format_windows_toast_xml(
            "小明’s 传感器’; calc.exe; #",
            "‘注入测试’ ‚ ‛ <toast>",
            ToastKind::Smoke,
            Some("invalid/id"),
        )
        .expect("curly single quotes toast xml");
        assert!(curly.contains("小明’s 传感器’; calc.exe; #"));
        assert!(curly.contains("&lt;toast&gt;"));
        assert!(curly.contains("scenario=\"alarm\""));
        assert!(!curly.contains("launch="));
        assert!(WINDOWS_TOAST_POWERSHELL_SCRIPT.contains("$doc.LoadXml([string]$env:MMB_TOAST_XML)"));
        assert!(!WINDOWS_TOAST_POWERSHELL_SCRIPT.contains("{}"));
        assert!(format_windows_toast_xml("   ", "\n\t", ToastKind::Safety, None).is_err());
    }

    #[test]
    fn windows_toast_fallback_uses_registered_or_legacy_aumid() {
        let registered = "example.registered";
        assert_eq!(powershell_toast_aumid(registered, Some(Ok(()))), None);

        let xml = format_windows_toast_xml("漏水", "厨房", ToastKind::Leak, Some("sensor.leak"))
            .expect("valid alarm xml");
        for (winrt_result, expected_aumid) in [
            (Some(Err(())), registered),
            (None, "com.jryang.menubarmijia"),
        ] {
            let aumid = powershell_toast_aumid(registered, winrt_result).expect("fallback aumid");
            let command = powershell_toast_command(aumid, &xml);
            let env: std::collections::HashMap<_, _> = command.get_envs().collect();
            assert_eq!(
                env[std::ffi::OsStr::new("MMB_TOAST_AUMID")],
                Some(std::ffi::OsStr::new(expected_aumid)),
            );
            assert_eq!(
                env[std::ffi::OsStr::new("MMB_TOAST_XML")],
                Some(std::ffi::OsStr::new(&xml)),
            );
        }
    }

    #[test]
    fn toast_activation_accepts_only_known_kinds_and_bounded_device_ids() {
        for kind in ["safety", "doorbell", "leak", "smoke", "gas"] {
            let id = "homeAssistant:binary_sensor.leak-1";
            assert_eq!(parse_toast_activation(&format!("{TOAST_URL_PREFIX}{kind}/{id}")), Some(id));
        }
        for suffix in ["toggle/1", "gas/", "gas/..", "gas/a/b", "gas/a?b", "gas/a#b", "gas/a%2Fb", "gas/a ", "gas/门铃", "gas/a\""] {
            assert_eq!(parse_toast_activation(&format!("{TOAST_URL_PREFIX}{suffix}")), None);
        }
        let max_id = "a".repeat(128);
        assert_eq!(parse_toast_activation(&format!("{TOAST_URL_PREFIX}leak/{max_id}")), Some(max_id.as_str()));
        assert_eq!(parse_toast_activation(&format!("{TOAST_URL_PREFIX}leak/{max_id}a")), None);
    }
}
