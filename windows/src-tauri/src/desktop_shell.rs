use super::*;
use std::path::Path;

const RUN_SUBKEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
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
    Ok(format!("\"{raw}\""))
}

#[cfg(windows)]
pub(crate) fn apply_run_registry_entry(
    subkey: &str,
    value_name: &str,
    exe_path: Option<&Path>,
) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegCreateKeyW, RegDeleteValueW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER,
        KEY_SET_VALUE,
    };

    let subkey_wide: Vec<u16> = std::ffi::OsStr::new(subkey)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let value_wide: Vec<u16> = std::ffi::OsStr::new(value_name)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();

    if let Some(path) = exe_path {
        let formatted = format_launch_at_login_value(path)?;
        let mut hkey: HKEY = std::ptr::null_mut();
        let status = unsafe { RegCreateKeyW(HKEY_CURRENT_USER, subkey_wide.as_ptr(), &mut hkey) };
        if status != 0 {
            return Err(format!("打开开机自启注册表项失败（Win32 错误码 {status}）"));
        }
        let res = crate::companion::set_reg_sz_value(hkey, Some(value_name), &formatted);
        unsafe {
            let _ = RegCloseKey(hkey);
        }
        res
    } else {
        let mut hkey: HKEY = std::ptr::null_mut();
        let open_status = unsafe {
            RegOpenKeyExW(
                HKEY_CURRENT_USER,
                subkey_wide.as_ptr(),
                0,
                KEY_SET_VALUE,
                &mut hkey,
            )
        };
        if open_status == ERROR_FILE_NOT_FOUND {
            return Ok(());
        }
        if open_status != 0 {
            return Err(format!("打开开机自启注册表项失败（Win32 错误码 {open_status}）"));
        }
        let del_status = unsafe { RegDeleteValueW(hkey, value_wide.as_ptr()) };
        unsafe {
            let _ = RegCloseKey(hkey);
        }
        if del_status != 0 && del_status != ERROR_FILE_NOT_FOUND {
            return Err(format!("移除开机自启注册表值失败（Win32 错误码 {del_status}）"));
        }
        Ok(())
    }
}

#[cfg(not(windows))]
pub(crate) fn apply_run_registry_entry(
    _subkey: &str,
    _value_name: &str,
    exe_path: Option<&Path>,
) -> Result<(), String> {
    if let Some(path) = exe_path {
        let _ = format_launch_at_login_value(path)?;
    }
    Ok(())
}

#[cfg(windows)]
pub(crate) fn has_run_registry_entry(subkey: &str, value_name: &str) -> Result<bool, String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_SZ};

    let subkey_wide: Vec<u16> = std::ffi::OsStr::new(subkey)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let value_wide: Vec<u16> = std::ffi::OsStr::new(value_name)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
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

#[cfg(not(windows))]
pub(crate) fn has_run_registry_entry(_subkey: &str, _value_name: &str) -> Result<bool, String> {
    Err("非 Windows 平台不支持注册表自启查询".to_string())
}

#[tauri::command]
pub(crate) fn get_launch_at_login() -> Result<bool, String> {
    has_run_registry_entry(RUN_SUBKEY, RUN_VALUE_NAME)
}

/// Immediately writes or deletes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MenuBarHome`
/// when the user toggles Launch at Login (Coding Standard #3).
#[tauri::command]
pub(crate) fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    if enabled {
        let exe = std::env::current_exe().map_err(|err| format!("无法获取当前程序路径：{err}"))?;
        apply_run_registry_entry(RUN_SUBKEY, RUN_VALUE_NAME, Some(&exe))
    } else {
        apply_run_registry_entry(RUN_SUBKEY, RUN_VALUE_NAME, None)
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

#[cfg(not(windows))]
fn probe_workstation_locked() -> bool {
    false
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

pub(crate) fn format_windows_toast_xml(title: &str, body: &str) -> Result<String, String> {
    let clean_title = escape_toast_xml(&clamp_utf16_units(title.trim(), 120));
    let clean_body = escape_toast_xml(&clamp_utf16_units(body.trim(), 240));
    if clean_title.is_empty() && clean_body.is_empty() {
        return Err("通知标题与内容不能为空".to_string());
    }
    Ok(format!(
        "<toast><visual><binding template=\"ToastGeneric\"><text>{clean_title}</text><text>{clean_body}</text></binding></visual></toast>"
    ))
}

#[tauri::command]
pub(crate) fn send_desktop_notification(title: String, body: String) -> Result<(), String> {
    let xml = format_windows_toast_xml(&title, &body)?;
    #[cfg(windows)]
    {
        let script = format!(
            "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; \
             [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null; \
             $doc = New-Object Windows.Data.Xml.Dom.XmlDocument; \
             $doc.LoadXml('{}'); \
             $toast = [Windows.UI.Notifications.ToastNotification]::new($doc); \
             [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('com.jryang.menubarmijia').Show($toast)",
            xml.replace('\'', "''")
        );
        let status = std::process::Command::new("powershell.exe")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-Command",
                &script,
            ])
            .creation_flags(crate::CREATE_NO_WINDOW)
            .status()
            .map_err(|err| format!("启动系统通知失败：{err}"))?;
        if !status.success() {
            return Err("系统通知发送失败".to_string());
        }
    }
    #[cfg(not(windows))]
    {
        let _ = xml;
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
    fn launch_at_login_formats_quoted_exe_and_cleans_up_registry_entry() {
        let val = format_launch_at_login_value(Path::new(r"C:\Apps\MenuBarHome\MenuBarHome.exe"))
            .expect("quoted launch value");
        assert_eq!(val, r#""C:\Apps\MenuBarHome\MenuBarHome.exe""#);
        assert!(format_launch_at_login_value(Path::new(r#"C:\bad"path\app.exe"#)).is_err());

        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::System::Registry::{RegDeleteKeyW, HKEY_CURRENT_USER};

            let subkey = format!(r"Software\MenuBarHomeTestRun-{}", std::process::id());
            assert_eq!(has_run_registry_entry(&subkey, "MenuBarHome"), Ok(false));
            apply_run_registry_entry(
                &subkey,
                "MenuBarHome",
                Some(Path::new(r"C:\Apps\MenuBarHome\MenuBarHome.exe")),
            )
            .expect("write test Run entry");
            assert_eq!(has_run_registry_entry(&subkey, "MenuBarHome"), Ok(true));
            apply_run_registry_entry(&subkey, "MenuBarHome", None)
                .expect("delete test Run entry");
            assert_eq!(has_run_registry_entry(&subkey, "MenuBarHome"), Ok(false));
            apply_run_registry_entry(&subkey, "MenuBarHome", None)
                .expect("idempotent delete missing Run entry");

            let wide: Vec<u16> = std::ffi::OsStr::new(&subkey)
                .encode_wide()
                .chain(std::iter::once(0))
                .collect();
            unsafe {
                let _ = RegDeleteKeyW(HKEY_CURRENT_USER, wide.as_ptr());
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
        let xml = format_windows_toast_xml("门铃 <前门> & 告警", "点击 '查看' \"画面\"\n第二行")
            .expect("valid toast xml");
        assert!(xml.contains("&lt;前门&gt; &amp; 告警"));
        assert!(xml.contains("&apos;查看&apos; &quot;画面&quot; 第二行"));
        assert!(format_windows_toast_xml("   ", "\n\t").is_err());
    }
}
