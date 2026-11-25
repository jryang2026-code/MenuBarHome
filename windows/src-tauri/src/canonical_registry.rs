use crate::companion::{companion_local_dir, write_atomic_file};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::Mutex;
use tauri::WebviewWindow;

const PRIMARY: &str = "canonical-devices.json";
const BACKUPS: [&str; 2] = ["canonical-devices.json.1.bak", "canonical-devices.json.2.bak"];
const MAX_BYTES: u64 = 4 * 1024 * 1024;
static REGISTRY_REVISION: Mutex<u64> = Mutex::new(0);

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Registry {
    assignments: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    orphaned_at: BTreeMap<String, u64>,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    explicitly_deleted: BTreeSet<String>,
}

fn read_copy(dir: &Path, name: &str) -> Option<Registry> {
    let file = std::fs::File::open(dir.join(name)).ok()?;
    if file.metadata().ok()?.len() > MAX_BYTES {
        return None;
    }
    serde_json::from_reader(file).ok()
}

fn read_registry(dir: &Path) -> Option<Registry> {
    [PRIMARY].into_iter().chain(BACKUPS).find_map(|name| read_copy(dir, name))
}

fn write_copy(dir: &Path, name: &str, value: &Registry) -> Result<(), String> {
    let bytes = serde_json::to_vec(value).map_err(|err| err.to_string())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err("Device identity registry exceeds its size limit".into());
    }
    write_atomic_file(dir, name, "canonical-registry", &bytes)?;
    Ok(())
}

fn save_registry(dir: &Path, next: &Registry) -> Result<(), String> {
    let previous = read_copy(dir, PRIMARY);
    if previous.as_ref() == Some(next) {
        return Ok(());
    }

    let valid: Vec<_> = previous.into_iter()
        .chain(BACKUPS.into_iter().filter_map(|name| read_copy(dir, name)))
        .take(BACKUPS.len())
        .collect();
    for (name, mut value) in BACKUPS.into_iter().zip(valid).rev() {
        value.assignments.retain(|_, id| !next.explicitly_deleted.contains(id));
        value.orphaned_at.retain(|id, _| !next.explicitly_deleted.contains(id));
        value.explicitly_deleted.extend(next.explicitly_deleted.iter().cloned());
        write_copy(dir, name, &value)?;
    }
    write_copy(dir, PRIMARY, next)
}

#[derive(Serialize)]
pub(crate) struct RegistryLoad {
    registry: Option<Registry>,
    revision: u64,
}

#[tauri::command]
pub(crate) fn load_canonical_registry() -> Result<RegistryLoad, String> {
    let revision = REGISTRY_REVISION.lock().map_err(|err| err.to_string())?;
    let dir = companion_local_dir().ok_or("Cannot locate the device identity registry directory")?;
    Ok(RegistryLoad { registry: read_registry(&dir), revision: *revision })
}

#[tauri::command]
pub(crate) fn save_canonical_registry(
    window: WebviewWindow,
    registry: Registry,
    revision: u64,
) -> Result<bool, String> {
    if window.label() != "main" {
        return Err("Only the panel can save the device identity registry".into());
    }
    let current = REGISTRY_REVISION.lock().map_err(|err| err.to_string())?;
    if revision != *current {
        return Ok(false);
    }
    let dir = companion_local_dir().ok_or("Cannot locate the device identity registry directory")?;
    save_registry(&dir, &registry)?;
    Ok(true)
}

#[tauri::command]
pub(crate) fn clear_canonical_registry() -> Result<(), String> {
    let mut revision = REGISTRY_REVISION.lock().map_err(|err| err.to_string())?;
    let dir = companion_local_dir().ok_or("Cannot locate the device identity registry directory")?;
    let empty = Registry::default();
    // Fence off writes queued before the explicit reset, including those from another webview.
    *revision += 1;
    for name in BACKUPS.into_iter().chain([PRIMARY]) {
        write_copy(&dir, name, &empty)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovers_newest_valid_copy_and_rotates_only_two_backups() {
        let root = std::env::temp_dir().join(format!(
            "menubarhome-canonical-registry-{}",
            std::process::id(),
        ));
        let dir = root.join("MenuBarMijia");
        for id in ["one", "two", "three", "four"] {
            save_registry(&dir, &Registry {
                assignments: [("did:lamp".into(), id.into())].into(),
                ..Registry::default()
            }).unwrap();
        }
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 3);
        std::fs::write(dir.join(PRIMARY), b"{\"assignments\":42}").unwrap();
        assert_eq!(read_registry(&dir).unwrap().assignments["did:lamp"], "three");
        std::fs::write(dir.join(BACKUPS[0]), b"truncated").unwrap();
        assert_eq!(read_registry(&dir).unwrap().assignments["did:lamp"], "two");
        std::fs::remove_dir_all(root).unwrap();
    }
}
