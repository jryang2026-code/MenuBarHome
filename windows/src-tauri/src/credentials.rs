use super::*;

const CREDENTIAL_SERVICE: &str = "com.jryang.menubarmijia";
const CREDENTIAL_NAMES: &[&str] = &["mi_session", "ha_token", "assistant_api_key"];

/// Fixed credential names only: this must not become a generic key/value store (#28).
pub(crate) fn allowed_credential_name(name: &str) -> Result<&str, String> {
    if CREDENTIAL_NAMES.contains(&name) {
        return Ok(name);
    }
    if let Some(suffix) = name.strip_prefix("assistant_api_key_") {
        if !suffix.is_empty()
            && suffix.len() <= 48
            && suffix
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return Ok(name);
        }
    }
    if let Some(suffix) = name.strip_prefix("mi_session_") {
        if !suffix.is_empty()
            && suffix.len() <= 64
            && suffix
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
        {
            return Ok(name);
        }
    }
    if let Some(suffix) = name.strip_prefix("generic-camera:") {
        if !suffix.is_empty()
            && suffix.len() <= 64
            && suffix
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return Ok(name);
        }
    }
    Err(format!("不允许的凭据名称：{name}"))
}

pub(crate) fn credential_entry(name: &str) -> Result<keyring::Entry, String> {
    let name = allowed_credential_name(name)?;
    keyring::Entry::new(CREDENTIAL_SERVICE, name)
        .map_err(|error| format!("无法打开 Windows 凭据管理器：{error}"))
}

/// Extracts the Xiaomi slot id from a keyring target name (#228).
///
/// keyring 3.x saves a Generic credential under the target name `{user}.{service}`, so the only
/// shape accepted here is `mi_session_<slotId>.com.jryang.menubarmijia`. The slot id must satisfy
/// the same whitelist the TypeScript side uses; anything else is another credential and is ignored.
/// This command returns names only and must never turn into a generic key/value store (#28).
fn mi_account_slot_from_target(target: &str) -> Option<String> {
    let suffix = format!(".{CREDENTIAL_SERVICE}");
    let name = target.strip_suffix(suffix.as_str())?;
    let slot = name.strip_prefix("mi_session_")?;
    if slot.is_empty()
        || slot.len() > 48
        || !slot
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    Some(slot.to_string())
}

fn credential_target_string(target: *const u16) -> String {
    if target.is_null() {
        return String::new();
    }
    let mut len = 0usize;
    // Target names are short; the cap only guards against a pathological pointer.
    while len < 4096 && unsafe { *target.add(len) } != 0 {
        len += 1;
    }
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(target, len) })
}

#[tauri::command]
pub(crate) async fn secure_store_list_mi_account_slots() -> Result<Vec<String>, String> {
    // `CredEnumerateW` blocks while Windows walks the credential set. Keep it off the async
    // runtime; a failed join is an enumeration failure, and the caller must then leave the account
    // index untouched instead of rebuilding it from a partial scan (fail-closed, #228).
    tauri::async_runtime::spawn_blocking(enumerate_mi_account_slots)
        .await
        .map_err(|error| format!("无法枚举 Windows 凭据：{error}"))?
}

fn enumerate_mi_account_slots() -> Result<Vec<String>, String> {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND};
    use windows_sys::Win32::Security::Credentials::{CredEnumerateW, CredFree, CREDENTIALW};

    // Target names are `{user}.{service}`, so a prefix filter still matches every slot of ours.
    let filter: Vec<u16> = "mi_session_*".encode_utf16().chain(std::iter::once(0)).collect();
    let mut count: u32 = 0;
    let mut credentials: *mut *mut CREDENTIALW = std::ptr::null_mut();
    let ok = unsafe { CredEnumerateW(filter.as_ptr(), 0, &mut count, &mut credentials) };
    if ok == 0 {
        let code = unsafe { GetLastError() };
        if code == ERROR_NOT_FOUND {
            return Ok(Vec::new());
        }
        return Err(format!("无法枚举 Windows 凭据：{code}"));
    }
    let mut slots: Vec<String> = Vec::new();
    unsafe {
        if !credentials.is_null() {
            for index in 0..count as usize {
                let credential = *credentials.add(index);
                if credential.is_null() {
                    continue;
                }
                let slot = mi_account_slot_from_target(&credential_target_string((*credential).TargetName));
                if let Some(slot) = slot {
                    if !slots.contains(&slot) {
                        slots.push(slot);
                    }
                }
            }
            CredFree(credentials as *const std::ffi::c_void);
        }
    }
    slots.sort();
    Ok(slots)
}

#[tauri::command]
pub(crate) fn secure_store_get(name: String) -> Result<Option<String>, String> {
    let entry = credential_entry(&name)?;
    match entry.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(format!("读取 Windows 凭据失败：{error}")),
    }
}

#[tauri::command]
pub(crate) fn secure_store_set(name: String, value: String) -> Result<(), String> {
    if value.is_empty() {
        return secure_store_delete(name);
    }
    let entry = credential_entry(&name)?;
    entry
        .set_password(&value)
        .map_err(|error| format!("写入 Windows 凭据失败：{error}"))
}

#[tauri::command]
pub(crate) fn secure_store_delete(name: String) -> Result<(), String> {
    let entry = credential_entry(&name)?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(format!("删除 Windows 凭据失败：{error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_only_whitelisted_mi_account_slots_from_credential_targets() {
        let target = |slot: &str| format!("mi_session_{slot}.com.jryang.menubarmijia");
        assert_eq!(
            mi_account_slot_from_target(&target("mi_cn_10001")).as_deref(),
            Some("mi_cn_10001")
        );
        assert_eq!(
            mi_account_slot_from_target(&target("mi_sg.user-2_ok")),
            None
        );
        assert_eq!(
            mi_account_slot_from_target("mi_session.com.jryang.menubarmijia"),
            None
        );
        assert_eq!(mi_account_slot_from_target(&target("")), None);
        assert_eq!(mi_account_slot_from_target(&target("a/b")), None);
        assert_eq!(
            mi_account_slot_from_target(&target(&"a".repeat(49))),
            None
        );
        assert_eq!(
            mi_account_slot_from_target("mi_session_slot.other.service"),
            None
        );
        assert_eq!(
            mi_account_slot_from_target("ha_token.com.jryang.menubarmijia"),
            None
        );
    }

    #[test]
    fn allows_constrained_secondary_xiaomi_credential_slots() {
        assert_eq!(
            allowed_credential_name("mi_session_cn_10001").ok(),
            Some("mi_session_cn_10001")
        );
        assert_eq!(
            allowed_credential_name("mi_session_sg.user-2_ok").ok(),
            Some("mi_session_sg.user-2_ok")
        );
        assert!(allowed_credential_name("mi_session_").is_err());
        assert!(allowed_credential_name("mi_session_a/b").is_err());
        assert!(allowed_credential_name(&format!("mi_session_{}", "a".repeat(65))).is_err());
    }

    #[test]
    fn allows_constrained_generic_camera_credential_targets() {
        let uuid = "11111111-1111-4111-8111-111111111111";
        let target = format!("generic-camera:{uuid}");
        assert_eq!(allowed_credential_name(&target).ok(), Some(target.as_str()));
        assert!(allowed_credential_name("generic-camera:").is_err());
        assert!(allowed_credential_name("generic-camera:../other").is_err());
        assert!(allowed_credential_name("generic-camera:a:b").is_err());
        assert!(allowed_credential_name("generic-camera:a b").is_err());
        assert!(allowed_credential_name(&format!("generic-camera:{}", "a".repeat(65))).is_err());
    }
}
