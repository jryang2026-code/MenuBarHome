use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum InputSource { Dp1, Dp2, Hdmi1, Hdmi2, UsbC, Custom(u16) }

impl InputSource {
    pub fn from_raw(v: u16) -> Self { match v { 0x0f => Self::Dp1, 0x10 => Self::Dp2, 0x11 => Self::Hdmi1, 0x12 => Self::Hdmi2, 0x1b => Self::UsbC, x => Self::Custom(x) } }
}

pub fn validate_vcp(code: u8) -> Result<u8, String> {
    if code == 0xd6 { return Err("forbidden VCP code 0xD6".into()); }
    match code { 0x10 | 0x60 | 0x62 | 0x8d => Ok(code), _ => Err(format!("unsupported VCP code 0x{code:02X}")) }
}

pub fn parse_input_sources(caps: &str) -> Vec<InputSource> {
    let Some(start) = caps.to_ascii_lowercase().find("vcp(") else { return vec![] };
    let tail = &caps[start + 4..];
    let Some(feature) = tail.find("60") else { return vec![] };
    let tail = &tail[feature + 2..];
    let Some(open) = tail.find('(') else { return vec![] };
    let Some(close) = tail[open + 1..].find(')') else { return vec![] };
    tail[open + 1..open + 1 + close].split_whitespace().filter_map(|x| u16::from_str_radix(x, 16).ok()).map(InputSource::from_raw).collect()
}

pub fn is_redmi_or_xiaomi(manufacturer: &str, model: &str) -> bool {
    let m = model.to_ascii_uppercase().replace([' ', '-', '_'], "");
    ["XMI", "RED"].iter().any(|x| manufacturer.eq_ignore_ascii_case(x))
        || ["REDMIG27U", "G27U", "RMMNT", "A27U", "G27"].iter().any(|x| m == *x || m.starts_with(x))
}

#[cfg(windows)]
mod platform {
    use super::*;
        use windows_sys::Win32::Devices::Display::*;
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::Graphics::Gdi::{HDC, HMONITOR};

    pub struct PhysicalMonitors(Vec<PHYSICAL_MONITOR>);
    impl Drop for PhysicalMonitors {
        fn drop(&mut self) { unsafe { DestroyPhysicalMonitors(self.0.len() as u32, self.0.as_mut_ptr()); } }
    }

    pub fn set_vcp(monitor: HANDLE, code: u8, value: u32) -> Result<(), String> {
        validate_vcp(code)?;
        if unsafe { SetVCPFeature(monitor, code, value as u32) } == 0 { Err("SetVCPFeature failed".into()) } else { Ok(()) }
    }

    pub fn list_displays() -> Result<Vec<String>, String> {
        unsafe extern "system" fn collect(monitor: HMONITOR, _: HDC, _: *mut windows_sys::Win32::Foundation::RECT, data: isize) -> i32 {
            let ids = &mut *(data as *mut Vec<String>);
            ids.push(format!("{}", monitor as usize));
            1
        }
        let mut ids = Vec::new();
        unsafe { windows_sys::Win32::Graphics::Gdi::EnumDisplayMonitors(std::ptr::null_mut(), std::ptr::null(), Some(collect), &mut ids as *mut _ as isize); }
        Ok(ids)
    }

    pub fn set_on_display(id: &str, code: u8, value: u32) -> Result<(), String> {
        let raw = id.parse::<usize>().map_err(|_| "invalid display id".to_string())?;
        if raw == 0 { return Err("invalid display id".to_string()); }
        let known = list_displays()?.iter().any(|candidate| candidate == id);
        if !known { return Err("display id is not currently enumerated".to_string()); }
        let monitors = monitors_for(raw as HMONITOR)?;
        for monitor in &monitors.0 { set_vcp(monitor.hPhysicalMonitor, code, value)?; }
        Ok(())
    }

    #[allow(dead_code)]
    pub fn monitors_for(hmonitor: HMONITOR) -> Result<PhysicalMonitors, String> {
        let mut count = 0;
        if unsafe { GetNumberOfPhysicalMonitorsFromHMONITOR(hmonitor, &mut count) } == 0 { return Err("monitor enumeration failed".into()); }
        let mut monitors = vec![unsafe { std::mem::zeroed() }; count as usize];
        if unsafe { GetPhysicalMonitorsFromHMONITOR(hmonitor, count, monitors.as_mut_ptr()) } == 0 { return Err("monitor enumeration failed".into()); }
        Ok(PhysicalMonitors(monitors))
    }
}

#[cfg(not(windows))]
fn platform_list_displays() -> Result<Vec<String>, String> { Ok(vec![]) }
#[cfg(windows)]
fn platform_list_displays() -> Result<Vec<String>, String> { platform::list_displays() }

#[cfg(not(windows))]
fn platform_set(_id: &str, _code: u8, _value: u32) -> Result<(), String> { Err("DDC display transport unavailable".into()) }
#[cfg(windows)]
fn platform_set(id: &str, code: u8, value: u32) -> Result<(), String> { platform::set_on_display(id, code, value) }

#[tauri::command]
pub fn ddc_list_displays() -> Result<Vec<String>, String> { platform_list_displays() }

#[tauri::command]
pub fn ddc_set_brightness(display_id: String, percent: u8) -> Result<(), String> { if percent > 100 { return Err("percent must be 0..100".into()) } ; platform_set(&display_id, 0x10, percent as u32) }
#[tauri::command]
pub fn ddc_set_input_source(display_id: String, source: u16) -> Result<(), String> { platform_set(&display_id, 0x60, source as u32) }
#[tauri::command]
pub fn ddc_set_volume(display_id: String, percent: u8) -> Result<(), String> { if percent > 100 { return Err("percent must be 0..100".into()) } ; platform_set(&display_id, 0x62, percent as u32) }
#[tauri::command]
pub fn ddc_set_mute(display_id: String, muted: bool) -> Result<(), String> { platform_set(&display_id, 0x8d, if muted { 1 } else { 2 }) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn guard_rejects_power() { assert!(validate_vcp(0xd6).is_err()); }
    #[test] fn parses_redmi_inputs() { assert_eq!(parse_input_sources("vcp(10 60(0F 10 11 12 1B) 62)"), vec![InputSource::Dp1, InputSource::Dp2, InputSource::Hdmi1, InputSource::Hdmi2, InputSource::UsbC]); }
    #[test] fn detects_redmi() { assert!(is_redmi_or_xiaomi("RED", "G27U")); }
}
