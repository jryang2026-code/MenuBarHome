use serde::Serialize;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum InputSource { Dp1, Dp2, Hdmi1, Hdmi2, UsbC, Custom(u16) }

impl InputSource {
    pub fn from_raw(v: u16) -> Self { match v { 0x0f => Self::Dp1, 0x10 => Self::Dp2, 0x11 => Self::Hdmi1, 0x12 => Self::Hdmi2, 0x1b => Self::UsbC, x => Self::Custom(x) } }
    pub fn raw_value(self) -> u16 { match self { Self::Dp1 => 0x0f, Self::Dp2 => 0x10, Self::Hdmi1 => 0x11, Self::Hdmi2 => 0x12, Self::UsbC => 0x1b, Self::Custom(x) => x } }
}

pub const REDMI_DEFAULT_INPUT_SOURCES: [u16; 5] = [0x0f, 0x10, 0x11, 0x12, 0x1b];

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DdcDisplayMetadata {
    pub id: String, pub name: String, pub manufacturer: String, pub model: String, pub is_redmi_or_xiaomi: bool,
    pub brightness_percent: Option<u8>, pub brightness_max: Option<u32>, pub volume_percent: Option<u8>, pub volume_max: Option<u32>, pub is_muted: Option<bool>,
    pub input_source: Option<u16>, pub supported_input_sources: Vec<u16>,
    pub supports_brightness: bool, pub supports_volume: bool, pub supports_mute: bool, pub supports_input_source: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedCapabilities { pub vcp_codes: Vec<u8>, pub input_sources: Vec<InputSource>, pub model: Option<String> }
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RawVcpState { pub brightness: Option<(u32, u32)>, pub volume: Option<(u32, u32)>, pub mute: Option<u32>, pub input_source: Option<u32> }

static VCP_MAX_CACHE: LazyLock<Mutex<HashMap<(String, u8), u32>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

pub fn validate_vcp(code: u8) -> Result<u8, String> {
    if code == 0xd6 { return Err("forbidden VCP code 0xD6".into()); }
    match code { 0x10 | 0x60 | 0x62 | 0x8d => Ok(code), _ => Err(format!("unsupported VCP code 0x{code:02X}")) }
}

pub fn vcp_to_percent(current: u32, max: u32) -> Option<u8> {
    (max > 0 && current <= max).then(|| ((u64::from(current) * 100 + u64::from(max) / 2) / u64::from(max)).min(100) as u8)
}

pub fn scale_percent_to_vcp(percent: u8, max_value: Option<u32>) -> Result<u32, String> {
    if percent > 100 { return Err("percent must be 0..100".into()); }
    Ok(((u64::from(max_value.filter(|&m| m > 0).unwrap_or(100)) * u64::from(percent) + 50) / 100) as u32)
}

fn find_section_body<'a>(caps: &'a str, tag: &str) -> Option<&'a str> {
    let lower = caps.to_ascii_lowercase();
    let (bytes, needle) = (lower.as_bytes(), tag.as_bytes());
    for i in 0..bytes.len().saturating_sub(needle.len()) {
        if &bytes[i..i + needle.len()] == needle && (i == 0 || !bytes[i - 1].is_ascii_alphanumeric()) {
            let mut j = i + needle.len();
            while bytes.get(j).is_some_and(u8::is_ascii_whitespace) { j += 1; }
            if bytes.get(j) == Some(&b'(') {
                let (start, mut depth) = (j + 1, 1usize);
                for k in start..bytes.len() {
                    if bytes[k] == b'(' { depth += 1; } else if bytes[k] == b')' { depth -= 1; if depth == 0 { return Some(&caps[start..k]); } }
                }
                return Some(&caps[start..]);
            }
        }
    }
    None
}

pub fn parse_capabilities(caps: &str) -> ParsedCapabilities {
    let mut out = ParsedCapabilities { model: find_section_body(caps, "model").map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned), ..Default::default() };
    let Some(body) = find_section_body(caps, "vcp") else { return out; };
    let (mut depth, mut feature, mut tok) = (0usize, None::<u8>, String::new());
    let flush = |tok: &mut String, d: usize, feat: &mut Option<u8>, out: &mut ParsedCapabilities| {
        if tok.is_empty() { return; }
        if d == 0 {
            *feat = u8::from_str_radix(tok, 16).ok();
            if let Some(c) = *feat { if !out.vcp_codes.contains(&c) { out.vcp_codes.push(c); } }
        } else if d == 1 && *feat == Some(0x60) {
            if let Ok(raw) = u16::from_str_radix(tok, 16) { let s = InputSource::from_raw(raw); if !out.input_sources.contains(&s) { out.input_sources.push(s); } }
        }
        tok.clear();
    };
    for ch in body.chars() {
        match ch {
            '(' => { flush(&mut tok, depth, &mut feature, &mut out); depth += 1; }
            ')' => { flush(&mut tok, depth, &mut feature, &mut out); depth = depth.saturating_sub(1); if depth == 0 { feature = None; } }
            c if c.is_ascii_whitespace() => flush(&mut tok, depth, &mut feature, &mut out),
            c => tok.push(c),
        }
    }
    flush(&mut tok, depth, &mut feature, &mut out);
    out
}

pub fn parse_input_sources(caps: &str) -> Vec<InputSource> { parse_capabilities(caps).input_sources }

pub fn is_redmi_or_xiaomi(manufacturer: &str, model: &str) -> bool {
    let m: String = model.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_uppercase()).collect();
    ["XMI", "RED"].iter().any(|x| manufacturer.eq_ignore_ascii_case(x))
        || ["REDMIG27U", "G27U", "RMMNT", "A27U", "G27"].iter().any(|x| m == *x || m.starts_with(x))
}

pub fn extract_manufacturer_from_device_path(path: &str) -> Option<String> {
    let pnp = path.to_ascii_uppercase().split("DISPLAY#").nth(1)?.split('#').next()?.to_owned();
    (pnp.len() >= 3 && pnp.as_bytes()[..3].iter().all(|b| b.is_ascii_alphabetic())).then(|| pnp[..3].to_owned())
}

pub fn decode_edid_manufacturer(raw: u16) -> Option<String> {
    let be = raw.swap_bytes();
    let [c1, c2, c3] = [((be >> 10) & 0x1f) as u8, ((be >> 5) & 0x1f) as u8, (be & 0x1f) as u8];
    [c1, c2, c3].iter().all(|c| (1..=26).contains(c)).then(|| format!("{}{}{}", (b'A' + c1 - 1) as char, (b'A' + c2 - 1) as char, (b'A' + c3 - 1) as char))
}

pub fn is_generic_monitor_name(name: &str) -> bool {
    matches!(name.trim().to_ascii_lowercase().as_str(),
        "" | "generic pnp monitor" | "generic monitor" | "generic non-pnp monitor" | "通用即插即用监视器" | "通用监视器" | "一般 pnp 監視器")
}

pub fn choose_display_name(friendly: &str, physical_desc: &str, caps_model: Option<&str>, fallback: &str) -> String {
    let cm = caps_model.unwrap_or("");
    [friendly, cm, physical_desc].iter().map(|s| s.trim()).find(|s| !is_generic_monitor_name(s))
        .or_else(|| [friendly, physical_desc, cm, fallback].iter().map(|s| s.trim()).find(|s| !s.is_empty()))
        .unwrap_or(fallback).to_owned()
}

pub fn is_internal_display_technology(tech: i32) -> bool {
    crate::system_events::is_internal_output_technology(tech) || tech == 6 // LVDS internal panel
}

pub fn build_display_metadata(
    id: String, friendly_name: &str, physical_desc: &str, manufacturer: &str, caps_raw: Option<&str>, vcp: &RawVcpState,
) -> DdcDisplayMetadata {
    let caps = caps_raw.map(parse_capabilities).unwrap_or_default();
    let has_vcp = !caps.vcp_codes.is_empty();
    let name = choose_display_name(friendly_name, physical_desc, caps.model.as_deref(), "");
    let model = caps.model.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| name.clone());
    let mfr = manufacturer.trim().to_owned();
    let is_redmi = is_redmi_or_xiaomi(&mfr, &model) || is_redmi_or_xiaomi(&mfr, &name);
    let (brightness_percent, brightness_max) = vcp.brightness.map_or((None, None), |(c, m)| (vcp_to_percent(c, m), (m > 0).then_some(m)));
    let supports_brightness = brightness_percent.is_some() || (has_vcp && caps.vcp_codes.contains(&0x10));
    let (raw_vol, raw_vmax) = vcp.volume.map_or((None, None), |(c, m)| (vcp_to_percent(c, m), (m > 0).then_some(m)));
    let (supports_volume, volume_percent, volume_max) = if has_vcp && !caps.vcp_codes.contains(&0x62) { (false, None, None) }
        else if has_vcp { (true, raw_vol, raw_vmax) } else { (raw_vol.is_some(), raw_vol, raw_vmax) };
    let raw_muted = vcp.mute.and_then(|v| match v & 0xff { 1 => Some(true), 2 => Some(false), _ => None });
    let supports_mute = if has_vcp { caps.vcp_codes.contains(&0x8d) || supports_volume } else { supports_volume || raw_muted.is_some() };
    let supported_input_sources: Vec<u16> = if !caps.input_sources.is_empty() { caps.input_sources.iter().map(|s| s.raw_value()).collect() }
        else if is_redmi { REDMI_DEFAULT_INPUT_SOURCES.to_vec() } else { vec![] };
    let input_source = vcp.input_source.map(|raw| {
        let (full, low) = ((raw & 0xffff) as u16, (raw & 0xff) as u16);
        if full > 0xff && !supported_input_sources.contains(&full) && supported_input_sources.contains(&low) { low } else { full }
    });
    let supports_input_source = !supported_input_sources.is_empty();
    DdcDisplayMetadata {
        id, name, manufacturer: mfr, model, is_redmi_or_xiaomi: is_redmi, brightness_percent, brightness_max,
        volume_percent, volume_max, is_muted: if supports_mute { raw_muted } else { None },
        input_source, supported_input_sources, supports_brightness, supports_volume, supports_mute, supports_input_source,
    }
}

fn cache_vcp_max(id: &str, code: u8, max: Option<u32>) {
    if let (Some(max), Ok(mut c)) = (max.filter(|&m| m > 0), VCP_MAX_CACHE.lock()) { c.insert((id.to_owned(), code), max); }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use windows_sys::Win32::Devices::Display::*;
    use windows_sys::Win32::Foundation::{HANDLE, RECT};
    use windows_sys::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW};

    pub struct PhysicalMonitors(Vec<PHYSICAL_MONITOR>);
    impl Drop for PhysicalMonitors {
        fn drop(&mut self) { unsafe { DestroyPhysicalMonitors(self.0.len() as u32, self.0.as_mut_ptr()); } }
    }
    struct TargetInfo { friendly_name: String, manufacturer: String, is_internal: bool }

    fn utf16_str(s: &[u16]) -> String { String::from_utf16_lossy(&s[..s.iter().position(|&c| c == 0).unwrap_or(s.len())]).trim().to_owned() }

    fn query_targets_by_gdi() -> HashMap<String, Vec<TargetInfo>> {
        let (mut by_gdi, mut pc, mut mc): (HashMap<String, Vec<TargetInfo>>, u32, u32) = (HashMap::new(), 0, 0);
        if unsafe { GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut pc, &mut mc) } != 0 { return by_gdi; }
        let (mut paths, mut modes) = (vec![unsafe { std::mem::zeroed::<DISPLAYCONFIG_PATH_INFO>() }; pc as usize], vec![unsafe { std::mem::zeroed::<DISPLAYCONFIG_MODE_INFO>() }; mc as usize]);
        if unsafe { QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut pc, paths.as_mut_ptr(), &mut mc, modes.as_mut_ptr(), std::ptr::null_mut()) } != 0 { return by_gdi; }
        for path in &paths[..pc as usize] {
            if path.flags & 1 == 0 { continue; }
            let mut src: DISPLAYCONFIG_SOURCE_DEVICE_NAME = unsafe { std::mem::zeroed() };
            src.header = DISPLAYCONFIG_DEVICE_INFO_HEADER { r#type: DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, size: std::mem::size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32, adapterId: path.sourceInfo.adapterId, id: path.sourceInfo.id };
            if unsafe { DisplayConfigGetDeviceInfo(&mut src.header) } != 0 { continue; }
            let gdi = utf16_str(&src.viewGdiDeviceName);
            if gdi.is_empty() { continue; }
            let mut tgt: DISPLAYCONFIG_TARGET_DEVICE_NAME = unsafe { std::mem::zeroed() };
            tgt.header = DISPLAYCONFIG_DEVICE_INFO_HEADER { r#type: DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, size: std::mem::size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32, adapterId: path.targetInfo.adapterId, id: path.targetInfo.id };
            let got = unsafe { DisplayConfigGetDeviceInfo(&mut tgt.header) } == 0;
            let tech = if got { tgt.outputTechnology } else { path.targetInfo.outputTechnology };
            let friendly_name = if got { utf16_str(&tgt.monitorFriendlyDeviceName) } else { String::new() };
            let manufacturer = if got { extract_manufacturer_from_device_path(&utf16_str(&tgt.monitorDevicePath)).or_else(|| decode_edid_manufacturer(tgt.edidManufactureId)).unwrap_or_default() } else { String::new() };
            by_gdi.entry(gdi).or_default().push(TargetInfo { friendly_name, manufacturer, is_internal: is_internal_display_technology(tech) });
        }
        by_gdi
    }

    fn monitor_gdi_name(h: HMONITOR) -> Option<String> {
        let mut info: MONITORINFOEXW = unsafe { std::mem::zeroed() };
        info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        (unsafe { GetMonitorInfoW(h, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) } != 0).then(|| utf16_str(&info.szDevice)).filter(|s| !s.is_empty())
    }

    fn enumerate_hmonitors() -> Vec<HMONITOR> {
        unsafe extern "system" fn collect(m: HMONITOR, _: HDC, _: *mut RECT, data: isize) -> i32 { (&mut *(data as *mut Vec<HMONITOR>)).push(m); 1 }
        let mut out = Vec::new();
        unsafe { EnumDisplayMonitors(std::ptr::null_mut(), std::ptr::null(), Some(collect), &mut out as *mut _ as isize); }
        out
    }

    pub fn get_vcp(monitor: HANDLE, code: u8) -> Option<(u32, u32)> {
        validate_vcp(code).ok()?;
        let (mut vct, mut cur, mut max): (MC_VCP_CODE_TYPE, u32, u32) = (0, 0, 0);
        (unsafe { GetVCPFeatureAndVCPFeatureReply(monitor, code, &mut vct, &mut cur, &mut max) } != 0).then_some((cur, max))
    }

    fn read_capabilities(monitor: HANDLE) -> Option<String> {
        let mut len = 0u32;
        if unsafe { GetCapabilitiesStringLength(monitor, &mut len) } == 0 || len == 0 || len > 8192 { return None; }
        let mut buf = vec![0u8; len as usize];
        if unsafe { CapabilitiesRequestAndCapabilitiesReply(monitor, buf.as_mut_ptr(), len) } == 0 { return None; }
        Some(String::from_utf8_lossy(&buf[..buf.iter().position(|&b| b == 0).unwrap_or(buf.len())]).into_owned())
    }

    pub fn set_vcp(monitor: HANDLE, code: u8, value: u32) -> Result<(), String> {
        validate_vcp(code)?;
        if unsafe { SetVCPFeature(monitor, code, value as u32) } == 0 { Err("SetVCPFeature failed".into()) } else { Ok(()) }
    }

    pub fn monitors_for(hmonitor: HMONITOR) -> Result<PhysicalMonitors, String> {
        let mut count = 0;
        if unsafe { GetNumberOfPhysicalMonitorsFromHMONITOR(hmonitor, &mut count) } == 0 { return Err("monitor enumeration failed".into()); }
        let mut monitors = vec![unsafe { std::mem::zeroed() }; count as usize];
        if unsafe { GetPhysicalMonitorsFromHMONITOR(hmonitor, count, monitors.as_mut_ptr()) } == 0 { return Err("monitor enumeration failed".into()); }
        Ok(PhysicalMonitors(monitors))
    }

    pub fn list_displays() -> Result<Vec<DdcDisplayMetadata>, String> {
        let targets_by_gdi = query_targets_by_gdi();
        let (mut results, mut valid_ids) = (Vec::new(), Vec::new());
        for h in enumerate_hmonitors() {
            let targets = monitor_gdi_name(h).and_then(|n| targets_by_gdi.get(&n));
            if targets.is_some_and(|l| !l.is_empty() && l.iter().all(|t| t.is_internal)) { continue; }
            let pref = targets.and_then(|l| l.iter().find(|t| !t.is_internal && !is_generic_monitor_name(&t.friendly_name)).or_else(|| l.iter().find(|t| !t.is_internal)));
            let id = format!("{}", h as usize);
            let Ok(phys) = monitors_for(h) else { continue; };
            let Some(first) = phys.0.first() else { continue; };
            let (handle, desc_buf) = (first.hPhysicalMonitor, first.szPhysicalMonitorDescription); // packed(1): copy by value
            let vcp = RawVcpState { brightness: get_vcp(handle, 0x10), volume: get_vcp(handle, 0x62), mute: get_vcp(handle, 0x8d).map(|(c, _)| c), input_source: get_vcp(handle, 0x60).map(|(c, _)| c) };
            let meta = build_display_metadata(id.clone(), pref.map_or("", |t| t.friendly_name.as_str()), &utf16_str(&desc_buf), pref.map_or("", |t| t.manufacturer.as_str()), read_capabilities(handle).as_deref(), &vcp);
            cache_vcp_max(&id, 0x10, meta.brightness_max);
            cache_vcp_max(&id, 0x62, meta.volume_max);
            valid_ids.push(id);
            results.push(meta);
        }
        if let Ok(mut c) = VCP_MAX_CACHE.lock() { c.retain(|(id, _), _| valid_ids.iter().any(|v| v == id)); }
        Ok(results)
    }

    fn live_hmonitor(id: &str) -> Result<HMONITOR, String> {
        let raw = id.parse::<usize>().ok().filter(|&v| v != 0).ok_or_else(|| "invalid display id".to_string())?;
        enumerate_hmonitors().into_iter().find(|&h| h as usize == raw).ok_or_else(|| "display id is not currently enumerated".to_string())
    }

    pub fn set_on_display(id: &str, code: u8, value: u32) -> Result<(), String> {
        validate_vcp(code)?;
        for m in &monitors_for(live_hmonitor(id)?)?.0 { set_vcp(m.hPhysicalMonitor, code, value)?; }
        Ok(())
    }

    pub fn set_percent_on_display(id: &str, code: u8, percent: u8) -> Result<(), String> {
        validate_vcp(code)?;
        if percent > 100 { return Err("percent must be 0..100".into()); }
        let cached = VCP_MAX_CACHE.lock().ok().and_then(|c| c.get(&(id.to_owned(), code)).copied());
        for m in &monitors_for(live_hmonitor(id)?)?.0 {
            let h = m.hPhysicalMonitor;
            let max = cached.or_else(|| get_vcp(h, code).and_then(|(_, mx)| (mx > 0).then(|| { cache_vcp_max(id, code, Some(mx)); mx })));
            set_vcp(h, code, scale_percent_to_vcp(percent, max)?)?;
        }
        Ok(())
    }
}

#[cfg(not(windows))] fn platform_list_displays() -> Result<Vec<DdcDisplayMetadata>, String> { Ok(vec![]) }
#[cfg(windows)] fn platform_list_displays() -> Result<Vec<DdcDisplayMetadata>, String> { platform::list_displays() }
#[cfg(not(windows))] fn platform_set(_id: &str, code: u8, _v: u32) -> Result<(), String> { validate_vcp(code)?; Err("DDC display transport unavailable".into()) }
#[cfg(windows)] fn platform_set(id: &str, code: u8, value: u32) -> Result<(), String> { platform::set_on_display(id, code, value) }
#[cfg(not(windows))] fn platform_set_percent(_id: &str, code: u8, p: u8) -> Result<(), String> { validate_vcp(code)?; let _ = scale_percent_to_vcp(p, None)?; Err("DDC display transport unavailable".into()) }
#[cfg(windows)] fn platform_set_percent(id: &str, code: u8, p: u8) -> Result<(), String> { platform::set_percent_on_display(id, code, p) }

#[tauri::command] pub fn ddc_list_displays() -> Result<Vec<DdcDisplayMetadata>, String> { platform_list_displays() }
#[tauri::command] pub fn ddc_set_brightness(display_id: String, percent: u8) -> Result<(), String> { platform_set_percent(&display_id, 0x10, percent) }
#[tauri::command] pub fn ddc_set_input_source(display_id: String, source: u16) -> Result<(), String> { platform_set(&display_id, 0x60, source as u32) }
#[tauri::command] pub fn ddc_set_volume(display_id: String, percent: u8) -> Result<(), String> { platform_set_percent(&display_id, 0x62, percent) }
#[tauri::command] pub fn ddc_set_mute(display_id: String, muted: bool) -> Result<(), String> { platform_set(&display_id, 0x8d, if muted { 1 } else { 2 }) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn guard_rejects_power() { assert!(validate_vcp(0xd6).is_err()); assert_eq!(validate_vcp(0x10), Ok(0x10)); }
    #[test] fn parses_redmi_and_nested_caps() {
        assert_eq!(parse_input_sources("vcp(10 60(0F 10 11 12 1B) 62)"), vec![InputSource::Dp1, InputSource::Dp2, InputSource::Hdmi1, InputSource::Hdmi2, InputSource::UsbC]);
        let nested = parse_capabilities("(prot(monitor)model(DELL U2723QE)vcp(10 14(05 60) 60(0F 11 1B 11) 8D(01 02)))");
        assert_eq!((nested.model.as_deref(), &nested.vcp_codes, &nested.input_sources), (Some("DELL U2723QE"), &vec![0x10, 0x14, 0x60, 0x8d], &vec![InputSource::Dp1, InputSource::Hdmi1, InputSource::UsbC]));
        assert!(parse_input_sources("vcp(10 60 8D(01 02))").is_empty());
    }
    #[test] fn detects_redmi_and_manufacturer() {
        assert!(is_redmi_or_xiaomi("RED", "G27U") && is_redmi_or_xiaomi("", "Redmi G27U") && !is_redmi_or_xiaomi("DEL", "U2723QE"));
        assert_eq!(extract_manufacturer_from_device_path(r"\\?\DISPLAY#XMI2701#5&1234&0&UID256#{guid}"), Some("XMI".into()));
        assert_eq!(decode_edid_manufacturer(0xa961), Some("XMI".into()));
    }
    #[test] fn scales_vcp_percentages() {
        assert_eq!((vcp_to_percent(128, 255), vcp_to_percent(101, 100)), (Some(50), None));
        assert_eq!((scale_percent_to_vcp(50, Some(255)), scale_percent_to_vcp(100, Some(65535)), scale_percent_to_vcp(75, None)), (Ok(128), Ok(65535), Ok(75)));
        assert!(scale_percent_to_vcp(101, Some(255)).is_err());
    }
    #[test] fn speakerless_monitor_hides_volume_and_redmi_defaults_inputs() {
        let dell = build_display_metadata("65537".into(), "DELL U2723QE", "Generic PnP Monitor", "DEL", Some("(model(U2723QE)vcp(10 60(0F 11 1B)))"),
            &RawVcpState { brightness: Some((153, 255)), volume: Some((0, 100)), mute: Some(2), input_source: Some(0x1b) });
        assert_eq!((dell.name.as_str(), dell.is_redmi_or_xiaomi, dell.brightness_percent, dell.brightness_max), ("DELL U2723QE", false, Some(60), Some(255)));
        assert!(!dell.supports_volume && dell.volume_percent.is_none() && !dell.supports_mute && dell.supported_input_sources == vec![0x0f, 0x11, 0x1b]);
        let redmi = build_display_metadata("65539".into(), "", "Redmi G27U", "RED", None,
            &RawVcpState { brightness: Some((80, 100)), volume: Some((40, 100)), mute: Some(1), input_source: Some(0x0111) });
        assert!(redmi.is_redmi_or_xiaomi && redmi.supports_volume && redmi.is_muted == Some(true) && redmi.input_source == Some(0x11) && redmi.supported_input_sources == REDMI_DEFAULT_INPUT_SOURCES);
        assert!(is_internal_display_technology(i32::MIN) && is_internal_display_technology(11) && is_internal_display_technology(6) && !is_internal_display_technology(10));
    }
}
