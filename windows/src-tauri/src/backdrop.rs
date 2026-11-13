//! Native window backdrop policy (§1.4).
//!
//! Because the Win11 `Win+N` + `Win+A` two-island flyout renders two distinct `8px`-rounded floating
//! islands separated by a `12px` transparent desktop gap (and slides out from / into the taskbar edge),
//! enabling a rectangular HWND-wide DWM backdrop (`DWMSBT_MAINWINDOW` / `DWMSBT_TRANSIENTWINDOW`) would
//! paint an opaque/blurred rectangular slab across both the `12px` inter-island gap and the outer margin
//! while animating. `apply` therefore explicitly keeps the HWND backdrop clear (`DWMSBT_NONE` = `1` on
//! Win11 22H2+) and returns `false` so each `.win-island` paints its own Fluent 2 Acrylic surface, stroke,
//! and elevation shadow cleanly. `backdrop_for` remains available as the pure build/transparency classifier.
#![allow(dead_code)]

use super::*;

#[cfg(windows)]
use tauri::window::{Effect, EffectsBuilder};
#[cfg(windows)]
use windows_sys::Win32::System::Registry::{
    RegGetValueW, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_DWORD, RRF_RT_REG_SZ,
};

/// Windows 11 22H2, the first build with `DWMWA_SYSTEMBACKDROP_TYPE`.
const MICA_MIN_BUILD: u32 = 22621;
/// Windows 11 21H2, where Acrylic exists only through the composition-attribute path.
const ACRYLIC_MIN_BUILD: u32 = 22000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Backdrop {
    /// Wallpaper-tinted system backdrop.
    Mica,
    /// Translucent blur: the 21H2 path, or the fallback when Mica is refused.
    Acrylic,
    /// No material; the panel keeps its own near-solid fill.
    None,
}

/// Which material this machine can actually paint. `transparency` is the user's "Transparency
/// effects" switch: with it off Windows draws its own backdrops opaque, so the panel has to stay
/// solid instead of fading over an unblurred desktop.
pub(crate) fn backdrop_for(build: u32, transparency: bool) -> Backdrop {
    if !transparency {
        return Backdrop::None;
    }
    if build >= MICA_MIN_BUILD {
        Backdrop::Mica
    } else if build >= ACRYLIC_MIN_BUILD {
        Backdrop::Acrylic
    } else {
        Backdrop::None
    }
}

/// Clears any HWND-wide DWM backdrop so the `12px` gap between the Top (`Win+N`) and Bottom (`Win+A`)
/// islands and the taskbar slide transition stay transparent to the desktop.
#[cfg(windows)]
pub(crate) fn apply(window: &WebviewWindow) -> bool {
    const DWMSBT_NONE_KIND: i32 = 1;
    if os_build() >= MICA_MIN_BUILD {
        let _ = set_system_backdrop(window, DWMSBT_NONE_KIND);
    }
    false
}

#[cfg(not(windows))]
pub(crate) fn apply(_window: &WebviewWindow) -> bool {
    false
}

#[cfg(windows)]
fn material(window: &WebviewWindow, plan: Backdrop) -> bool {
    use windows_sys::Win32::Graphics::Dwm::{DWMSBT_MAINWINDOW, DWMSBT_TRANSIENTWINDOW};

    match plan {
        Backdrop::None => false,
        Backdrop::Mica => {
            set_system_backdrop(window, DWMSBT_MAINWINDOW as i32)
                || set_system_backdrop(window, DWMSBT_TRANSIENTWINDOW as i32)
        }
        // 21H2 has no DWM backdrop attribute, and the composition-attribute path reports nothing, so
        // it is trusted only where the build gate above already promised Acrylic.
        Backdrop::Acrylic => {
            set_system_backdrop(window, DWMSBT_TRANSIENTWINDOW as i32) || {
                let _ = window.set_effects(EffectsBuilder::new().effect(Effect::Acrylic).build());
                true
            }
        }
    }
}

/// `DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, …)`; only `S_OK` means the compositor
/// took it, which is the one answer the panel may rely on.
#[cfg(windows)]
fn set_system_backdrop(window: &WebviewWindow, kind: i32) -> bool {
    use std::ffi::c_void;
    use windows_sys::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_SYSTEMBACKDROP_TYPE};

    let Ok(hwnd) = window.hwnd() else { return false };
    let result = unsafe {
        DwmSetWindowAttribute(
            hwnd.0 as *mut c_void,
            DWMWA_SYSTEMBACKDROP_TYPE as u32,
            std::ptr::addr_of!(kind).cast::<c_void>(),
            std::mem::size_of::<i32>() as u32,
        )
    };
    result == 0
}

/// `CurrentBuild` from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` (REG_SZ), e.g. `19045`.
#[cfg(windows)]
fn os_build() -> u32 {
    let mut buffer = [0u16; 16];
    let mut size = std::mem::size_of_val(&buffer) as u32;
    let subkey = wide("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
    let name = wide("CurrentBuild");
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            subkey.as_ptr(),
            name.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buffer.as_mut_ptr().cast(),
            &mut size,
        )
    };
    if status != 0 {
        // Unreadable: treat it as a build without a backdrop rather than guessing upwards.
        return 0;
    }
    String::from_utf16_lossy(&buffer)
        .trim_end_matches('\0')
        .parse()
        .unwrap_or(0)
}

/// `EnableTransparency` from `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`.
/// A missing value means Windows' default, which is on.
#[cfg(windows)]
fn transparency_enabled() -> bool {
    let mut value: u32 = 1;
    let mut size = std::mem::size_of::<u32>() as u32;
    let subkey = wide("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    let name = wide("EnableTransparency");
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            subkey.as_ptr(),
            name.as_ptr(),
            RRF_RT_REG_DWORD,
            std::ptr::null_mut(),
            (&raw mut value).cast(),
            &mut size,
        )
    };
    status != 0 || value != 0
}

#[cfg(windows)]
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_build_without_the_material_stays_solid() {
        // Windows 10 22H2: the regression the review caught — `set_effects` said yes, DWM never could.
        assert_eq!(backdrop_for(19045, true), Backdrop::None);
        assert_eq!(backdrop_for(0, true), Backdrop::None);
    }

    #[test]
    fn the_build_picks_mica_then_acrylic() {
        assert_eq!(backdrop_for(22000, true), Backdrop::Acrylic);
        assert_eq!(backdrop_for(22620, true), Backdrop::Acrylic);
        assert_eq!(backdrop_for(22621, true), Backdrop::Mica);
        assert_eq!(backdrop_for(26100, true), Backdrop::Mica);
    }

    #[test]
    fn the_transparency_switch_turns_every_material_off() {
        for build in [19045, 22000, 22621, 26100] {
            assert_eq!(backdrop_for(build, false), Backdrop::None);
        }
    }
}
