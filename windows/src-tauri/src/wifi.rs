//! Reads the currently connected Wi-Fi network through the native WLAN API.
//!
//! Windows 11 24H2 and later gate SSID reads behind the Location permission; a
//! denied grant surfaces as an API error or an empty SSID. The command
//! therefore reports three distinct "no SSID" outcomes — not connected,
//! permission denied, unknown — so the automation layer can fail closed on
//! "cannot know" instead of misreading it as "not connected", mirroring
//! `MacHardwareProbe.currentWiFi()` on macOS (`isAuthorized == false` means
//! "cannot know" and must never be treated as "not connected").

use serde::Serialize;

/// Result of probing the current WLAN connection for the automation engine.
///
/// Serialized behind a `state` tag; `ssid` is only present when connected.
/// The variants match `windowsWifiProbeState` in `windows/src/core/automationEngine.ts`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub(crate) enum WifiCurrentStatus {
    /// Associated with a WLAN whose SSID could be decoded.
    Connected {
        ssid: String,
    },
    /// Queried successfully; the machine is not associated with any WLAN.
    NotConnected,
    /// Location permission denied: the SSID cannot be known.
    NoPermission,
    /// Any other failure (no usable adapter, WLAN service down, hidden network…).
    Unknown,
}

/// Decodes raw SSID octets into a string, losslessly when the bytes are valid
/// UTF-8 and lossily otherwise. Never panics: malformed length fields are
/// clamped by the caller and invalid sequences become U+FFFD.
pub(crate) fn decode_ssid_bytes(raw: &[u8]) -> String {
    // Trailing NUL padding is a driver artifact; the declared length should
    // already exclude it, but some adapters pad anyway.
    let end = raw.iter().rposition(|byte| *byte != 0).map_or(0, |index| index + 1);
    String::from_utf8_lossy(&raw[..end]).into_owned()
}

/// Pure mapping from a queried interface state and decoded SSID to a status.
///
/// An association without a readable SSID (hidden network) means the network
/// name cannot be known, which must never read as "not connected".
pub(crate) fn status_from_connection_state(is_connected: bool, ssid: Option<String>) -> WifiCurrentStatus {
    match (is_connected, ssid) {
        (true, Some(ssid)) if !ssid.is_empty() => WifiCurrentStatus::Connected { ssid },
        (true, _) => WifiCurrentStatus::Unknown,
        (false, _) => WifiCurrentStatus::NotConnected,
    }
}

/// Maps a WLAN API error code to a status. Access denied is the Windows 11
/// 24H2+ Location-permission refusal; anything else stays "cannot know".
#[cfg(windows)]
pub(crate) fn status_from_query_error(error: u32) -> WifiCurrentStatus {
    use windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED;
    if error == ERROR_ACCESS_DENIED {
        WifiCurrentStatus::NoPermission
    } else {
        WifiCurrentStatus::Unknown
    }
}

/// Queries one interface's current connection and maps it to a status.
#[cfg(windows)]
unsafe fn query_interface_status(
    handle: windows_sys::Win32::Foundation::HANDLE,
    interface_guid: &windows_sys::Win32::Foundation::GUID,
) -> WifiCurrentStatus {
    use core::ffi::c_void;
    use windows_sys::Win32::NetworkManagement::WiFi::{
        WlanFreeMemory, WlanQueryInterface, WLAN_CONNECTION_ATTRIBUTES,
        wlan_intf_opcode_current_connection, wlan_interface_state_connected,
    };

    let mut data_size: u32 = 0;
    let mut data: *mut c_void = std::ptr::null_mut();
    let mut opcode_value_type: windows_sys::Win32::NetworkManagement::WiFi::WLAN_OPCODE_VALUE_TYPE = 0;
    let error = WlanQueryInterface(
        handle,
        interface_guid,
        wlan_intf_opcode_current_connection,
        std::ptr::null(),
        &mut data_size,
        &mut data,
        &mut opcode_value_type,
    );
    if error != 0 {
        return status_from_query_error(error);
    }
    if data.is_null() || (data_size as usize) < core::mem::size_of::<WLAN_CONNECTION_ATTRIBUTES>() {
        if !data.is_null() {
            WlanFreeMemory(data as *const c_void);
        }
        return WifiCurrentStatus::Unknown;
    }
    let attributes = &*(data as *const WLAN_CONNECTION_ATTRIBUTES);
    let ssid_field = &attributes.wlanAssociationAttributes.dot11Ssid;
    let length = core::cmp::min(ssid_field.uSSIDLength, ssid_field.ucSSID.len() as u32) as usize;
    let ssid = decode_ssid_bytes(&ssid_field.ucSSID[..length]);
    let status = status_from_connection_state(
        attributes.isState == wlan_interface_state_connected,
        Some(ssid),
    );
    // `ssid` is an owned string, so no borrow can outlive the free below.
    WlanFreeMemory(data as *const c_void);
    status
}

/// Enumerates WLAN interfaces and returns the status of the first connected
/// one; when several are connected, a definite SSID wins over an error.
#[cfg(windows)]
unsafe fn enum_interfaces_status(handle: windows_sys::Win32::Foundation::HANDLE) -> WifiCurrentStatus {
    use core::ffi::c_void;
    use windows_sys::Win32::NetworkManagement::WiFi::{
        WlanEnumInterfaces, WlanFreeMemory, WLAN_INTERFACE_INFO_LIST,
        wlan_interface_state_connected,
    };

    let mut list: *mut WLAN_INTERFACE_INFO_LIST = std::ptr::null_mut();
    let error = WlanEnumInterfaces(handle, std::ptr::null(), &mut list);
    if error != 0 {
        return status_from_query_error(error);
    }
    if list.is_null() {
        return WifiCurrentStatus::Unknown;
    }
    let count = (*list).dwNumberOfItems;
    let first = (*list).InterfaceInfo.as_ptr();
    // `InterfaceInfo` is declared `[WLAN_INTERFACE_INFO; 1]` but the OS
    // allocation holds `dwNumberOfItems` contiguous entries.
    let mut fallback: Option<WifiCurrentStatus> = None;
    let mut status = WifiCurrentStatus::NotConnected;
    for index in 0..count as usize {
        let info = &*first.add(index);
        if info.isState != wlan_interface_state_connected {
            continue;
        }
        match query_interface_status(handle, &info.InterfaceGuid) {
            connected @ WifiCurrentStatus::Connected { .. } => {
                status = connected;
                break;
            }
            other => {
                fallback = Some(other);
            }
        }
    }
    WlanFreeMemory(list as *const c_void);
    if let Some(fallback) = fallback {
        return fallback;
    }
    status
}

#[cfg(windows)]
fn read_current_wifi() -> WifiCurrentStatus {
    use core::ffi::c_void;
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::NetworkManagement::WiFi::{WlanCloseHandle, WlanOpenHandle};

    // Nothing is allocated before this succeeds, so the early return cannot leak.
    unsafe {
        let mut negotiated_version: u32 = 0;
        let mut handle: HANDLE = std::ptr::null_mut();
        // Client version 2 is the Vista+ contract; the OS reports what it
        // granted in `negotiated_version`.
        if WlanOpenHandle(2, std::ptr::null::<c_void>(), &mut negotiated_version, &mut handle) != 0 {
            return WifiCurrentStatus::Unknown;
        }
        let status = enum_interfaces_status(handle);
        // Every path after a successful open funnels through here, so the
        // handle is always closed and the interface list always freed.
        WlanCloseHandle(handle, std::ptr::null::<c_void>());
        status
    }
}

#[cfg(not(windows))]
fn read_current_wifi() -> WifiCurrentStatus {
    WifiCurrentStatus::Unknown
}

/// Reads the current WLAN SSID for the automation engine's Wi-Fi conditions.
///
/// Returns one of four states — connected (with SSID), not connected,
/// permission denied, unknown — so a denied Location grant on Windows 11 24H2+
/// is never misread as "not connected" (macOS `MacHardwareProbe.currentWiFi()`
/// semantics).
#[tauri::command]
pub(crate) fn wifi_current() -> WifiCurrentStatus {
    read_current_wifi()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_ssid_bytes_lossily_and_trims_nul_padding() {
        assert_eq!(decode_ssid_bytes(b"Home_5G"), "Home_5G");
        // Chinese SSID encoded as UTF-8 round-trips exactly.
        let chinese = "客厅网络".as_bytes().to_vec();
        assert_eq!(decode_ssid_bytes(&chinese), "客厅网络");
        // Invalid UTF-8 becomes U+FFFD instead of panicking.
        assert_eq!(decode_ssid_bytes(&[0x48, 0xFF, 0x6F]), "H\u{FFFD}o");
        // Trailing NUL padding from sloppy drivers is dropped.
        let padded = b"Home_5G\0\0\0".to_vec();
        assert_eq!(decode_ssid_bytes(&padded), "Home_5G");
        // All-NUL or empty reports decode to an empty string.
        assert_eq!(decode_ssid_bytes(&[0, 0, 0]), "");
        assert_eq!(decode_ssid_bytes(&[]), "");
        // SSIDs may legitimately contain spaces; they are preserved here.
        assert_eq!(decode_ssid_bytes(b"My Wifi "), "My Wifi ");
    }

    #[test]
    fn maps_connection_states_to_the_four_statuses() {
        assert_eq!(
            status_from_connection_state(true, Some("Home_5G".to_string())),
            WifiCurrentStatus::Connected { ssid: "Home_5G".to_string() }
        );
        // Connected with an empty SSID report (hidden network) cannot know the
        // name and must not read as "not connected".
        assert_eq!(status_from_connection_state(true, Some(String::new())), WifiCurrentStatus::Unknown);
        assert_eq!(status_from_connection_state(true, None), WifiCurrentStatus::Unknown);
        assert_eq!(status_from_connection_state(false, None), WifiCurrentStatus::NotConnected);
    }

    #[cfg(windows)]
    #[test]
    fn maps_query_errors_to_permission_or_unknown() {
        use windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED;
        assert_eq!(status_from_query_error(ERROR_ACCESS_DENIED), WifiCurrentStatus::NoPermission);
        assert_eq!(status_from_query_error(1163), WifiCurrentStatus::Unknown); // ERROR_SERVICE_NOT_ACTIVE
        assert_eq!(status_from_query_error(0), WifiCurrentStatus::Unknown);
    }

    #[test]
    fn serializes_with_the_state_tag_and_camel_case_names() {
        assert_eq!(
            serde_json::to_value(WifiCurrentStatus::Connected { ssid: "Home".to_string() }).unwrap(),
            serde_json::json!({ "state": "connected", "ssid": "Home" })
        );
        assert_eq!(
            serde_json::to_value(WifiCurrentStatus::NotConnected).unwrap(),
            serde_json::json!({ "state": "notConnected" })
        );
        assert_eq!(
            serde_json::to_value(WifiCurrentStatus::NoPermission).unwrap(),
            serde_json::json!({ "state": "noPermission" })
        );
        assert_eq!(
            serde_json::to_value(WifiCurrentStatus::Unknown).unwrap(),
            serde_json::json!({ "state": "unknown" })
        );
    }
}
