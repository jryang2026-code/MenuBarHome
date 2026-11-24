//! Windows 11 native theme detection, system accent color, taskbar tray icon adaptation,
//! and DWM system backdrop helpers (P1-4).
//!
//! Design invariants (verified against reports 07 & 11):
//! * Builds `< 22621` or `EnableTransparency == 0` never apply `DWMWA_SYSTEMBACKDROP_TYPE`
//!   and never fall back to legacy `SetWindowCompositionAttribute(ACCENT_ENABLE_ACRYLICBLURBEHIND)`.
//! * The Fluent two-island flyout never receives DWM Acrylic (`DWMSBT_TRANSIENTWINDOW`) because
//!   DWM renders across the entire HWND rectangle, including the inter-island gap and outer padding.
//! * Classic single-card flyout on Build >= 22621 with transparency enabled removes its 16 px CSS
//!   shadow padding and uses native DWM shadow + `DWMWCP_ROUND` + `DWMSBT_TRANSIENTWINDOW`, always
//!   clearing to `DWMSBT_NONE` whenever hidden to prevent ghost acrylic artifacts.
//! * Settings window on Build >= 22621 with transparency enabled uses `DWMSBT_MAINWINDOW` (Mica).
//! * `AppsUseLightTheme` (panel/settings scheme) and `SystemUsesLightTheme` (taskbar tray icon)
//!   are read independently from `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`.

use crate::window::PanelTheme;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, RwLock};
use tauri::{AppHandle, Manager, WebviewWindow};

/// First Windows 11 22H2 build where `DWMWA_SYSTEMBACKDROP_TYPE` is supported without drag jank.
pub(crate) const WIN11_22H2_BUILD: u32 = 22_621;

#[cfg(all(windows, not(test)))]
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
#[cfg(all(windows, not(test)))]
const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;
#[cfg(all(windows, not(test)))]
const DWMWCP_DEFAULT: i32 = 0;
#[cfg(all(windows, not(test)))]
const DWMWCP_ROUND: i32 = 2;
#[cfg(all(windows, not(test)))]
const DWMSBT_NONE: i32 = 1;
#[cfg(all(windows, not(test)))]
const DWMSBT_MAINWINDOW: i32 = 2;
#[cfg(all(windows, not(test)))]
const DWMSBT_TRANSIENTWINDOW: i32 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BackdropKind {
    None,
    Mica,
    TransientAcrylic,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WinAccentPalette {
    pub accent: String,
    pub accent_hover: String,
    pub accent_pressed: String,
    pub text_on_accent: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WinThemeSnapshot {
    pub windows_build: u32,
    pub supports_system_backdrop: bool,
    pub apps_use_light_theme: bool,
    pub system_uses_light_theme: bool,
    pub enable_transparency: bool,
    pub accent_dark: Option<WinAccentPalette>,
    pub accent_light: Option<WinAccentPalette>,
}

impl Default for WinThemeSnapshot {
    fn default() -> Self {
        Self {
            windows_build: 0,
            supports_system_backdrop: false,
            apps_use_light_theme: false,
            system_uses_light_theme: false,
            enable_transparency: false,
            accent_dark: None,
            accent_light: None,
        }
    }
}

static CACHED_THEME: LazyLock<RwLock<WinThemeSnapshot>> =
    LazyLock::new(|| RwLock::new(WinThemeSnapshot::default()));
static THEME_WATCHER_STARTED: AtomicBool = AtomicBool::new(false);

pub(crate) fn parse_windows_build(raw: &str) -> Option<u32> {
    raw.trim().parse::<u32>().ok().filter(|&build| build > 0)
}

pub(crate) const fn supports_system_backdrop(build: u32, enable_transparency: bool) -> bool {
    build >= WIN11_22H2_BUILD && enable_transparency
}

pub(crate) const fn classic_uses_native_chrome(
    theme: PanelTheme,
    supports_backdrop: bool,
) -> bool {
    matches!(theme, PanelTheme::Classic) && supports_backdrop
}

pub(crate) const fn desired_panel_backdrop(
    theme: PanelTheme,
    supports_backdrop: bool,
    visible: bool,
) -> BackdropKind {
    if !visible {
        return BackdropKind::None;
    }
    match theme {
        PanelTheme::Classic if supports_backdrop => BackdropKind::TransientAcrylic,
        PanelTheme::Classic | PanelTheme::Fluent => BackdropKind::None,
    }
}

pub(crate) const fn desired_settings_backdrop(supports_backdrop: bool) -> BackdropKind {
    if supports_backdrop {
        BackdropKind::Mica
    } else {
        BackdropKind::None
    }
}

pub(crate) fn format_hex_rgb(r: u8, g: u8, b: u8) -> String {
    format!("#{r:02x}{g:02x}{b:02x}")
}

fn srgb_channel_linear(channel: u8) -> f64 {
    let c = f64::from(channel) / 255.0;
    if c <= 0.03928 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

/// Picks dark or white foreground text for an accent fill using WCAG relative luminance.
pub(crate) fn contrast_text_for_rgb(r: u8, g: u8, b: u8) -> &'static str {
    let luminance = 0.2126 * srgb_channel_linear(r)
        + 0.7152 * srgb_channel_linear(g)
        + 0.0722 * srgb_channel_linear(b);
    if luminance > 0.36 {
        "#0c1117"
    } else {
        "#ffffff"
    }
}

pub(crate) fn palette_from_colors(
    primary: (u8, u8, u8),
    hover: (u8, u8, u8),
    pressed: (u8, u8, u8),
) -> WinAccentPalette {
    WinAccentPalette {
        accent: format_hex_rgb(primary.0, primary.1, primary.2),
        accent_hover: format_hex_rgb(hover.0, hover.1, hover.2),
        accent_pressed: format_hex_rgb(pressed.0, pressed.1, pressed.2),
        text_on_accent: contrast_text_for_rgb(primary.0, primary.1, primary.2).to_string(),
    }
}

fn mix_rgb(base: (u8, u8, u8), target: (u8, u8, u8), weight: f64) -> (u8, u8, u8) {
    let blend = |a: u8, b: u8| -> u8 {
        (f64::from(a) * (1.0 - weight) + f64::from(b) * weight)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    (
        blend(base.0, target.0),
        blend(base.1, target.1),
        blend(base.2, target.2),
    )
}

/// Fallback accent palette from `HKCU\Software\Microsoft\Windows\DWM\AccentColor` (`0xAABBGGRR`).
pub(crate) fn palette_from_abgr_dword(abgr: u32, dark_scheme: bool) -> WinAccentPalette {
    let base = (
        (abgr & 0xff) as u8,
        ((abgr >> 8) & 0xff) as u8,
        ((abgr >> 16) & 0xff) as u8,
    );
    if dark_scheme {
        let primary = mix_rgb(base, (255, 255, 255), 0.32);
        let hover = mix_rgb(base, (255, 255, 255), 0.44);
        let pressed = mix_rgb(base, (255, 255, 255), 0.20);
        palette_from_colors(primary, hover, pressed)
    } else {
        let primary = mix_rgb(base, (0, 0, 0), 0.10);
        let hover = base;
        let pressed = mix_rgb(base, (0, 0, 0), 0.22);
        palette_from_colors(primary, hover, pressed)
    }
}

/// Adapts the bundled tray icon RGBA buffer for dark vs light Windows taskbars
/// (`SystemUsesLightTheme`).
///
/// The bundled icon has a dark neutral rounded frame, white house silhouette, and warm orange
/// toggle pill. On a light taskbar (`system_uses_light_theme == true`) it already has high
/// contrast; on a dark taskbar we invert neutral (low-chroma) pixels so the outer badge becomes
/// crisp light grey/white while preserving the saturated orange indicator pill.
pub(crate) fn adapt_tray_icon_rgba(rgba: &[u8], system_uses_light_theme: bool) -> Vec<u8> {
    if system_uses_light_theme {
        return rgba.to_vec();
    }
    let mut out = rgba.to_vec();
    for px in out.chunks_exact_mut(4) {
        let (r, g, b, a) = (px[0], px[1], px[2], px[3]);
        if a == 0 {
            continue;
        }
        let max_c = r.max(g).max(b);
        let min_c = r.min(g).min(b);
        if max_c.saturating_sub(min_c) < 28 {
            px[0] = 255 - r;
            px[1] = 255 - g;
            px[2] = 255 - b;
        }
    }
    out
}

pub(crate) fn current_theme_snapshot() -> WinThemeSnapshot {
    CACHED_THEME
        .read()
        .map(|guard| guard.clone())
        .unwrap_or_default()
}

pub(crate) fn current_supports_system_backdrop() -> bool {
    current_theme_snapshot().supports_system_backdrop
}

#[tauri::command]
pub(crate) fn win_theme_state() -> WinThemeSnapshot {
    refresh_cached_snapshot()
}

#[cfg(all(windows, not(test)))]
fn wide_null(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[cfg(all(windows, not(test)))]
fn read_hkcu_dword(subkey: &str, value_name: &str) -> Option<u32> {
    use windows_sys::Win32::System::Registry::{
        RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD,
    };

    let subkey_wide = wide_null(subkey);
    let value_wide = wide_null(value_name);
    let mut out: u32 = 0;
    let mut size: u32 = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            subkey_wide.as_ptr(),
            value_wide.as_ptr(),
            RRF_RT_REG_DWORD,
            std::ptr::null_mut(),
            &mut out as *mut u32 as *mut core::ffi::c_void,
            &mut size,
        )
    };
    (status == 0).then_some(out)
}

#[cfg(all(windows, not(test)))]
fn read_windows_build() -> u32 {
    use windows_sys::Win32::System::Registry::{
        RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ,
    };

    let subkey_wide = wide_null(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
    let value_wide = wide_null("CurrentBuildNumber");
    let mut buf = [0u16; 32];
    let mut size: u32 = (buf.len() * std::mem::size_of::<u16>()) as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            subkey_wide.as_ptr(),
            value_wide.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buf.as_mut_ptr() as *mut core::ffi::c_void,
            &mut size,
        )
    };
    if status != 0 || size < 2 {
        return 0;
    }
    let units = (size as usize / 2).min(buf.len());
    let len = buf[..units]
        .iter()
        .position(|&c| c == 0)
        .unwrap_or(units);
    let text = String::from_utf16_lossy(&buf[..len]);
    parse_windows_build(&text).unwrap_or(0)
}

#[cfg(all(windows, not(test)))]
fn read_ui_settings_accents() -> Option<(WinAccentPalette, WinAccentPalette)> {
    use windows::UI::ViewManagement::{UIColorType, UISettings};

    let settings = UISettings::new().ok()?;
    let accent = settings.GetColorValue(UIColorType::Accent).ok()?;
    let light1 = settings.GetColorValue(UIColorType::AccentLight1).ok()?;
    let light2 = settings.GetColorValue(UIColorType::AccentLight2).ok()?;
    let light3 = settings.GetColorValue(UIColorType::AccentLight3).ok()?;
    let dark1 = settings.GetColorValue(UIColorType::AccentDark1).ok()?;
    let dark2 = settings.GetColorValue(UIColorType::AccentDark2).ok()?;

    let dark_palette = palette_from_colors(
        (light2.R, light2.G, light2.B),
        (light3.R, light3.G, light3.B),
        (light1.R, light1.G, light1.B),
    );
    let light_palette = palette_from_colors(
        (dark1.R, dark1.G, dark1.B),
        (accent.R, accent.G, accent.B),
        (dark2.R, dark2.G, dark2.B),
    );
    Some((dark_palette, light_palette))
}

#[cfg(all(windows, not(test)))]
fn probe_live_snapshot() -> WinThemeSnapshot {
    const PERSONALIZE: &str = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    const DWM_KEY: &str = r"Software\Microsoft\Windows\DWM";

    let windows_build = read_windows_build();
    let apps_use_light_theme = read_hkcu_dword(PERSONALIZE, "AppsUseLightTheme")
        .map(|v| v != 0)
        .unwrap_or(false);
    let system_uses_light_theme = read_hkcu_dword(PERSONALIZE, "SystemUsesLightTheme")
        .map(|v| v != 0)
        .unwrap_or(apps_use_light_theme);
    let enable_transparency = read_hkcu_dword(PERSONALIZE, "EnableTransparency")
        .map(|v| v != 0)
        .unwrap_or(true);

    let (accent_dark, accent_light) = match read_ui_settings_accents() {
        Some((d, l)) => (Some(d), Some(l)),
        None => match read_hkcu_dword(DWM_KEY, "AccentColor") {
            Some(abgr) => (
                Some(palette_from_abgr_dword(abgr, true)),
                Some(palette_from_abgr_dword(abgr, false)),
            ),
            None => (None, None),
        },
    };

    WinThemeSnapshot {
        windows_build,
        supports_system_backdrop: supports_system_backdrop(windows_build, enable_transparency),
        apps_use_light_theme,
        system_uses_light_theme,
        enable_transparency,
        accent_dark,
        accent_light,
    }
}

#[cfg(any(not(windows), test))]
fn probe_live_snapshot() -> WinThemeSnapshot {
    current_theme_snapshot()
}

pub(crate) fn refresh_cached_snapshot() -> WinThemeSnapshot {
    let snapshot = probe_live_snapshot();
    if let Ok(mut guard) = CACHED_THEME.write() {
        *guard = snapshot.clone();
    }
    snapshot
}

#[cfg(all(windows, not(test)))]
pub(crate) fn apply_window_corner_preference(window: &WebviewWindow, rounded: bool) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute;

    let Ok(raw_hwnd) = window.hwnd() else {
        return;
    };
    let hwnd = (raw_hwnd.0 as usize) as HWND;
    let pref: i32 = if rounded { DWMWCP_ROUND } else { DWMWCP_DEFAULT };
    unsafe {
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &pref as *const i32 as *const core::ffi::c_void,
            std::mem::size_of::<i32>() as u32,
        );
    }
}

#[cfg(any(not(windows), test))]
pub(crate) fn apply_window_corner_preference(_window: &WebviewWindow, _rounded: bool) {}

#[cfg(all(windows, not(test)))]
pub(crate) fn apply_window_backdrop(window: &WebviewWindow, kind: BackdropKind) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::Graphics::Dwm::{
        DwmExtendFrameIntoClientArea, DwmSetWindowAttribute,
    };
    use windows_sys::Win32::UI::Controls::MARGINS;

    let Ok(raw_hwnd) = window.hwnd() else {
        return;
    };
    let hwnd = (raw_hwnd.0 as usize) as HWND;
    let backdrop_type: i32 = match kind {
        BackdropKind::None => DWMSBT_NONE,
        BackdropKind::Mica => DWMSBT_MAINWINDOW,
        BackdropKind::TransientAcrylic => DWMSBT_TRANSIENTWINDOW,
    };
    unsafe {
        if !matches!(kind, BackdropKind::None) {
            let margins = MARGINS {
                cxLeftWidth: -1,
                cxRightWidth: -1,
                cyTopHeight: -1,
                cyBottomHeight: -1,
            };
            let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);
        }
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            &backdrop_type as *const i32 as *const core::ffi::c_void,
            std::mem::size_of::<i32>() as u32,
        );
    }
}

#[cfg(any(not(windows), test))]
pub(crate) fn apply_window_backdrop(_window: &WebviewWindow, _kind: BackdropKind) {}

pub(crate) fn apply_tray_icon_for_theme(app: &AppHandle, system_uses_light_theme: bool) {
    let Some(tray) = app.tray_by_id("main-tray") else {
        return;
    };
    let Some(base_icon) = app.default_window_icon() else {
        return;
    };
    let adapted = adapt_tray_icon_rgba(base_icon.rgba(), system_uses_light_theme);
    let image = tauri::image::Image::new_owned(adapted, base_icon.width(), base_icon.height());
    let _ = tray.set_icon(Some(image));
}

#[cfg(all(windows, not(test)))]
fn broadcast_theme_change(app: &AppHandle) {
    let prev = current_theme_snapshot();
    let next = refresh_cached_snapshot();
    if next == prev {
        return;
    }
    let app_clone = app.clone();
    let next_for_ui = next.clone();
    let _ = app.run_on_main_thread(move || {
        if next_for_ui.system_uses_light_theme != prev.system_uses_light_theme {
            apply_tray_icon_for_theme(&app_clone, next_for_ui.system_uses_light_theme);
        }
        if let Some(main_win) = app_clone.get_webview_window("main") {
            let visible = main_win.is_visible().unwrap_or(false);
            crate::window::sync_main_window_chrome(&main_win, visible);
        }
        if let Some(settings_win) = app_clone.get_webview_window("settings") {
            crate::window::sync_settings_window_chrome(&settings_win);
        }
        if let Ok(json) = serde_json::to_string(&next_for_ui) {
            let script = format!(
                "window.dispatchEvent(new CustomEvent('menumijia:win-theme-changed', {{ detail: {json} }}))"
            );
            for label in ["main", "settings"] {
                if let Some(win) = app_clone.get_webview_window(label) {
                    let _ = win.eval(&script);
                }
            }
        }
    });
}

#[cfg(all(windows, not(test)))]
fn watch_hkcu_key(app: AppHandle, subkey: &'static str) {
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegNotifyChangeKeyValue, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_NOTIFY,
        KEY_READ, REG_NOTIFY_CHANGE_LAST_SET,
    };

    std::thread::spawn(move || {
        let subkey_wide = wide_null(subkey);
        loop {
            let mut hkey: HKEY = std::ptr::null_mut();
            let open_status = unsafe {
                RegOpenKeyExW(
                    HKEY_CURRENT_USER,
                    subkey_wide.as_ptr(),
                    0,
                    KEY_NOTIFY | KEY_READ,
                    &mut hkey,
                )
            };
            if open_status != 0 || hkey.is_null() {
                std::thread::sleep(std::time::Duration::from_secs(5));
                continue;
            }
            loop {
                let status = unsafe {
                    RegNotifyChangeKeyValue(
                        hkey,
                        0,
                        REG_NOTIFY_CHANGE_LAST_SET,
                        std::ptr::null_mut(),
                        0,
                    )
                };
                if status != 0 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(250));
                broadcast_theme_change(&app);
            }
            unsafe {
                let _ = RegCloseKey(hkey);
            }
        }
    });
}

pub(crate) fn init_win_theme(app: AppHandle) -> WinThemeSnapshot {
    let snapshot = refresh_cached_snapshot();
    #[cfg(all(windows, not(test)))]
    if !THEME_WATCHER_STARTED.swap(true, Ordering::SeqCst) {
        watch_hkcu_key(
            app.clone(),
            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
        );
        watch_hkcu_key(app, r"Software\Microsoft\Windows\DWM");
    }
    #[cfg(any(not(windows), test))]
    let _ = app;
    snapshot
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_build_and_backdrop_gating_respect_22621_and_transparency() {
        assert_eq!(parse_windows_build("22621"), Some(22_621));
        assert_eq!(parse_windows_build(" 26100\0"), None);
        assert_eq!(parse_windows_build(" 26100 "), Some(26_100));
        assert_eq!(parse_windows_build("0"), None);
        assert_eq!(parse_windows_build(""), None);

        assert!(!supports_system_backdrop(19_045, true));
        assert!(!supports_system_backdrop(22_000, true));
        assert!(!supports_system_backdrop(22_621, false));
        assert!(supports_system_backdrop(22_621, true));
        assert!(supports_system_backdrop(26_100, true));
    }

    #[test]
    fn backdrop_policy_never_applies_acrylic_to_fluent_or_hidden_windows() {
        // Classic visible on Win11 22H2+ with transparency -> TransientAcrylic
        assert_eq!(
            desired_panel_backdrop(PanelTheme::Classic, true, true),
            BackdropKind::TransientAcrylic
        );
        // Classic hidden -> MUST clear to None (EarTrumpet ghost acrylic guard)
        assert_eq!(
            desired_panel_backdrop(PanelTheme::Classic, true, false),
            BackdropKind::None
        );
        // Classic on Win10 / <22621 or transparency disabled -> None
        assert_eq!(
            desired_panel_backdrop(PanelTheme::Classic, false, true),
            BackdropKind::None
        );
        // Fluent two-island -> NEVER Acrylic even when visible on Win11 22H2+
        assert_eq!(
            desired_panel_backdrop(PanelTheme::Fluent, true, true),
            BackdropKind::None
        );
        assert!(!classic_uses_native_chrome(PanelTheme::Fluent, true));
        assert!(classic_uses_native_chrome(PanelTheme::Classic, true));
        assert!(!classic_uses_native_chrome(PanelTheme::Classic, false));

        // Settings window -> Mica on 22621+ with transparency, else None
        assert_eq!(desired_settings_backdrop(true), BackdropKind::Mica);
        assert_eq!(desired_settings_backdrop(false), BackdropKind::None);
    }

    #[test]
    fn accent_palette_computes_hex_and_wcag_contrast_text() {
        let dark = palette_from_colors((0x60, 0xcd, 0xff), (0x70, 0xd3, 0xff), (0x4e, 0xc2, 0xf7));
        assert_eq!(dark.accent, "#60cdff");
        assert_eq!(dark.accent_hover, "#70d3ff");
        assert_eq!(dark.accent_pressed, "#4ec2f7");
        assert_eq!(dark.text_on_accent, "#0c1117");

        let light = palette_from_colors((0x00, 0x5f, 0xb8), (0x18, 0x6e, 0xc0), (0x00, 0x54, 0xa3));
        assert_eq!(light.accent, "#005fb8");
        assert_eq!(light.text_on_accent, "#ffffff");

        // Fallback ABGR dword (0xFF_B8_5F_00 -> R=0x00, G=0x5F, B=0xB8)
        let fallback_dark = palette_from_abgr_dword(0xffb8_5f00, true);
        let fallback_light = palette_from_abgr_dword(0xffb8_5f00, false);
        assert!(fallback_dark.accent.starts_with('#'));
        assert_eq!(fallback_dark.accent.len(), 7);
        assert_eq!(fallback_light.text_on_accent, "#ffffff");
    }

    #[test]
    fn tray_icon_adaptation_inverts_neutrals_on_dark_taskbar_and_preserves_accent_and_light() {
        let sample = vec![
            24, 24, 28, 255, // dark neutral shell
            245, 245, 245, 255, // white neutral house
            255, 149, 0, 255, // saturated orange pill
            10, 10, 10, 0, // transparent pixel
        ];
        assert_eq!(adapt_tray_icon_rgba(&sample, true), sample);

        let dark_taskbar = adapt_tray_icon_rgba(&sample, false);
        assert_eq!(&dark_taskbar[0..4], &[231, 231, 227, 255]);
        assert_eq!(&dark_taskbar[4..8], &[10, 10, 10, 255]);
        assert_eq!(&dark_taskbar[8..12], &[255, 149, 0, 255]);
        assert_eq!(&dark_taskbar[12..16], &[10, 10, 10, 0]);
    }
}
