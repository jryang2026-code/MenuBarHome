use crate::camera::base64_encode;
use crate::companion::companion_local_dir;
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) const DEFAULT_RETENTION_MS: i64 = 7 * 24 * 60 * 60 * 1000;
pub(crate) const DEFAULT_MAX_EVENTS: usize = 500;
pub(crate) const MAX_SNAPSHOT_BYTES: usize = 2 * 1024 * 1024;
pub(crate) const MAX_TOTAL_SNAPSHOT_BYTES: u64 = 64 * 1024 * 1024;
const CAMERA_EVENTS_SUBDIR: &str = "CameraEvents";
const EVENTS_FILE_NAME: &str = "events.json";

static STORE_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static STAGING_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum CameraEventKind {
    Doorbell,
    Motion,
    Person,
    Package,
}

impl CameraEventKind {
    pub(crate) fn parse(raw: &str) -> Option<Self> {
        match raw.trim() {
            "doorbell" => Some(Self::Doorbell),
            "motion" => Some(Self::Motion),
            "person" => Some(Self::Person),
            "package" => Some(Self::Package),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct CameraEventRecord {
    pub(crate) id: String,
    #[serde(rename = "cameraID")]
    pub(crate) camera_id: String,
    pub(crate) kind: CameraEventKind,
    pub(crate) timestamp: String,
    #[serde(rename = "snapshotFile", skip_serializing_if = "Option::is_none")]
    pub(crate) snapshot_file: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct StoreLimits {
    pub(crate) retention_ms: i64,
    pub(crate) max_events: usize,
    pub(crate) max_snapshot_bytes: usize,
    pub(crate) max_total_snapshot_bytes: u64,
}

impl Default for StoreLimits {
    fn default() -> Self {
        Self {
            retention_ms: DEFAULT_RETENTION_MS,
            max_events: DEFAULT_MAX_EVENTS,
            max_snapshot_bytes: MAX_SNAPSHOT_BYTES,
            max_total_snapshot_bytes: MAX_TOTAL_SNAPSHOT_BYTES,
        }
    }
}

pub(crate) fn camera_events_dir() -> Result<PathBuf, String> {
    let base = companion_local_dir().ok_or_else(|| "应用数据目录不可用".to_string())?;
    Ok(base.join(CAMERA_EVENTS_SUBDIR))
}

pub(crate) fn is_safe_camera_id(id: &str) -> bool {
    let trimmed = id.trim();
    !trimmed.is_empty()
        && trimmed.len() <= 256
        && trimmed == id
        && !trimmed.contains("://")
        && !trimmed.chars().any(|c| c.is_control() || c.is_whitespace())
}

pub(crate) fn is_safe_event_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

pub(crate) fn is_safe_snapshot_filename(name: &str) -> bool {
    if name.is_empty() || name.len() > 128 {
        return false;
    }
    if name.contains('/')
        || name.contains('\\')
        || name.contains("..")
        || name.contains("://")
        || name.contains(':')
        || name.contains('?')
        || name.contains('#')
        || name.contains('@')
    {
        return false;
    }
    let lower = name.to_ascii_lowercase();
    if !lower.starts_with("snapshot-") || !(lower.ends_with(".jpeg") || lower.ends_with(".jpg")) {
        return false;
    }
    name.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

fn generate_uuid_v4() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| "生成事件 ID 失败".to_string())?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

fn now_epoch_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Converts days since 1970-01-01 to (year, month, day) in the proleptic Gregorian calendar.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = y + if m <= 2 { 1 } else { 0 };
    (y, m as u32, d as u32)
}

/// Converts (year, month, day) to days since 1970-01-01.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = y - if m <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let m = m as u64;
    let d = d as u64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + (doe as i64) - 719_468
}

pub(crate) fn format_iso8601_utc(epoch_ms: i64) -> String {
    let secs = epoch_ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = sod / 3600;
    let minute = (sod % 3600) / 60;
    let second = sod % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

pub(crate) fn parse_iso8601_utc(raw: &str) -> Option<i64> {
    let s = raw.trim();
    if s.len() < 20 || !s.ends_with('Z') {
        return None;
    }
    let bytes = s.as_bytes();
    if bytes[4] != b'-' || bytes[7] != b'-' || (bytes[10] != b'T' && bytes[10] != b't') || bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let year: i64 = s.get(0..4)?.parse().ok()?;
    let month: u32 = s.get(5..7)?.parse().ok()?;
    let day: u32 = s.get(8..10)?.parse().ok()?;
    let hour: i64 = s.get(11..13)?.parse().ok()?;
    let minute: i64 = s.get(14..16)?.parse().ok()?;
    let second: i64 = s.get(17..19)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || !(0..24).contains(&hour) || !(0..60).contains(&minute) || !(0..60).contains(&second) {
        return None;
    }
    let frac = &s[19..s.len() - 1];
    let millis: i64 = if frac.is_empty() {
        0
    } else if let Some(digits) = frac.strip_prefix('.') {
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let mut padded = [b'0'; 3];
        for (i, b) in digits.bytes().take(3).enumerate() {
            padded[i] = b;
        }
        std::str::from_utf8(&padded).ok()?.parse().ok()?
    } else {
        return None;
    };
    let days = days_from_civil(year, month, day);
    let secs = days.checked_mul(86_400)? + hour * 3600 + minute * 60 + second;
    secs.checked_mul(1000)?.checked_add(millis)
}

pub(crate) fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    let clean: Vec<u8> = input
        .bytes()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    if clean.is_empty() {
        return Err("快照数据为空".to_string());
    }
    let mut out = Vec::with_capacity((clean.len() * 3) / 4);
    let mut buf: u32 = 0;
    let mut bits: u8 = 0;
    let mut saw_pad = false;
    for b in clean {
        if b == b'=' {
            saw_pad = true;
            continue;
        }
        if saw_pad {
            return Err("无效的 Base64 快照数据".to_string());
        }
        let val = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return Err("无效的 Base64 快照数据".to_string()),
        };
        buf = (buf << 6) | (val as u32);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xff) as u8);
        }
    }
    if out.is_empty() {
        return Err("快照数据为空".to_string());
    }
    Ok(out)
}

fn write_atomic_bytes(dir: &Path, file_name: &str, bytes: &[u8]) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("创建摄像机事件目录失败：{e}"))?;
    let seq = STAGING_SEQ.fetch_add(1, Ordering::Relaxed);
    let staging = dir.join(format!(".{file_name}.tmp-{}-{seq}", std::process::id()));
    let target = dir.join(file_name);
    let write_res = (|| -> std::io::Result<()> {
        let mut f = std::fs::File::create(&staging)?;
        f.write_all(bytes)?;
        f.sync_all()
    })();
    if let Err(err) = write_res {
        let _ = std::fs::remove_file(&staging);
        return Err(format!("写入摄像机事件文件失败：{err}"));
    }
    if target.exists() {
        let _ = std::fs::remove_file(&target);
    }
    if let Err(err) = std::fs::rename(&staging, &target) {
        let _ = std::fs::remove_file(&staging);
        return Err(format!("替换摄像机事件文件失败：{err}"));
    }
    Ok(())
}

fn sanitize_record(val: serde_json::Value) -> Option<CameraEventRecord> {
    let mut rec: CameraEventRecord = serde_json::from_value(val).ok()?;
    if !is_safe_event_id(&rec.id) || !is_safe_camera_id(&rec.camera_id) {
        return None;
    }
    parse_iso8601_utc(&rec.timestamp)?;
    if let Some(ref file) = rec.snapshot_file {
        if !is_safe_snapshot_filename(file) {
            rec.snapshot_file = None;
        }
    }
    Some(rec)
}

fn load_raw_events(dir: &Path) -> Vec<CameraEventRecord> {
    let path = dir.join(EVENTS_FILE_NAME);
    let Ok(bytes) = std::fs::read(&path) else {
        return Vec::new();
    };
    let Ok(serde_json::Value::Array(items)) = serde_json::from_slice(&bytes) else {
        return Vec::new();
    };
    items.into_iter().filter_map(sanitize_record).collect()
}

fn prune_events_and_files(
    dir: &Path,
    events: &mut Vec<CameraEventRecord>,
    now_ms: i64,
    limits: &StoreLimits,
) {
    let cutoff_ms = now_ms.saturating_sub(limits.retention_ms.max(0));
    let max_events = limits.max_events.max(1);
    let mut kept = Vec::with_capacity(events.len().min(max_events));
    let mut removed_files = Vec::new();

    for ev in events.drain(..) {
        let ts_ms = parse_iso8601_utc(&ev.timestamp).unwrap_or(i64::MIN);
        if ts_ms >= cutoff_ms && kept.len() < max_events {
            kept.push(ev);
        } else if let Some(name) = ev.snapshot_file {
            if is_safe_snapshot_filename(&name) {
                removed_files.push(name);
            }
        }
    }

    // Enforce total snapshot disk budget by dropping oldest snapshots first.
    let mut total_bytes: u64 = 0;
    for ev in &mut kept {
        let drop_name = ev.snapshot_file.as_deref().and_then(|name| {
            let size = std::fs::metadata(dir.join(name)).map(|m| m.len()).unwrap_or(0);
            if total_bytes.saturating_add(size) > limits.max_total_snapshot_bytes {
                Some(name.to_string())
            } else {
                total_bytes = total_bytes.saturating_add(size);
                None
            }
        });
        if let Some(name) = drop_name {
            removed_files.push(name);
            ev.snapshot_file = None;
        }
    }

    for name in removed_files {
        let _ = std::fs::remove_file(dir.join(name));
    }

    // Clean up any orphaned snapshot-*.jpeg files left on disk.
    let referenced: HashSet<&str> = kept
        .iter()
        .filter_map(|e| e.snapshot_file.as_deref())
        .collect();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if is_safe_snapshot_filename(name) && !referenced.contains(name) {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
    }

    *events = kept;
}

fn save_events(dir: &Path, events: &[CameraEventRecord]) -> Result<(), String> {
    let json = serde_json::to_vec(events).map_err(|e| format!("序列化摄像机事件失败：{e}"))?;
    write_atomic_bytes(dir, EVENTS_FILE_NAME, &json)
}

pub(crate) fn load_events_in_dir(
    dir: &Path,
    now_ms: i64,
    limits: &StoreLimits,
) -> Result<Vec<CameraEventRecord>, String> {
    let mut events = load_raw_events(dir);
    let before = events.len();
    prune_events_and_files(dir, &mut events, now_ms, limits);
    if events.len() != before && dir.join(EVENTS_FILE_NAME).exists() {
        let _ = save_events(dir, &events);
    }
    Ok(events)
}

pub(crate) fn record_event_in_dir(
    dir: &Path,
    camera_id: &str,
    kind: CameraEventKind,
    timestamp_ms: i64,
    now_ms: i64,
    snapshot_bytes: Option<&[u8]>,
    limits: &StoreLimits,
) -> Result<CameraEventRecord, String> {
    if !is_safe_camera_id(camera_id) {
        return Err("无效的摄像机标识".to_string());
    }
    if let Some(bytes) = snapshot_bytes {
        if bytes.is_empty() || bytes.len() > limits.max_snapshot_bytes {
            return Err("摄像机快照大小超出限制".to_string());
        }
    }
    let id = generate_uuid_v4()?;
    let snapshot_file = if let Some(bytes) = snapshot_bytes {
        let name = format!("snapshot-{id}.jpeg");
        write_atomic_bytes(dir, &name, bytes)?;
        Some(name)
    } else {
        None
    };

    let record = CameraEventRecord {
        id,
        camera_id: camera_id.to_string(),
        kind,
        timestamp: format_iso8601_utc(timestamp_ms),
        snapshot_file: snapshot_file.clone(),
    };

    let mut events = load_raw_events(dir);
    events.insert(0, record.clone());
    prune_events_and_files(dir, &mut events, now_ms, limits);
    if let Err(err) = save_events(dir, &events) {
        if let Some(name) = snapshot_file {
            let _ = std::fs::remove_file(dir.join(name));
        }
        return Err(err);
    }
    Ok(events.into_iter().find(|e| e.id == record.id).unwrap_or(record))
}

pub(crate) fn attach_snapshot_in_dir(
    dir: &Path,
    event_id: &str,
    snapshot_bytes: &[u8],
    now_ms: i64,
    limits: &StoreLimits,
) -> Result<Option<CameraEventRecord>, String> {
    if !is_safe_event_id(event_id) {
        return Ok(None);
    }
    if snapshot_bytes.is_empty() || snapshot_bytes.len() > limits.max_snapshot_bytes {
        return Err("摄像机快照大小超出限制".to_string());
    }
    let mut events = load_raw_events(dir);
    let Some(idx) = events
        .iter()
        .position(|e| e.id == event_id && e.snapshot_file.is_none())
    else {
        return Ok(None);
    };
    let name = format!("snapshot-{event_id}.jpeg");
    write_atomic_bytes(dir, &name, snapshot_bytes)?;
    events[idx].snapshot_file = Some(name.clone());
    let updated_id = events[idx].id.clone();
    prune_events_and_files(dir, &mut events, now_ms, limits);
    if let Err(err) = save_events(dir, &events) {
        let _ = std::fs::remove_file(dir.join(name));
        return Err(err);
    }
    Ok(events.into_iter().find(|e| e.id == updated_id))
}

pub(crate) fn read_snapshot_in_dir(
    dir: &Path,
    snapshot_file: &str,
    limits: &StoreLimits,
) -> Result<Option<String>, String> {
    if !is_safe_snapshot_filename(snapshot_file) {
        return Ok(None);
    }
    let path = dir.join(snapshot_file);
    let Ok(bytes) = std::fs::read(&path) else {
        return Ok(None);
    };
    if bytes.is_empty() || bytes.len() > limits.max_snapshot_bytes {
        return Ok(None);
    }
    Ok(Some(base64_encode(&bytes)))
}

pub(crate) fn clear_events_in_dir(dir: &Path) -> Result<(), String> {
    if dir.exists() {
        let _ = std::fs::remove_dir_all(dir);
    }
    Ok(())
}

#[tauri::command]
pub(crate) fn camera_events_load() -> Result<Vec<CameraEventRecord>, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "摄像机事件存储锁不可用".to_string())?;
    let dir = camera_events_dir()?;
    load_events_in_dir(&dir, now_epoch_ms(), &StoreLimits::default())
}

#[tauri::command]
pub(crate) fn camera_events_record(
    camera_id: String,
    kind: String,
    timestamp_ms: Option<i64>,
    snapshot_base64: Option<String>,
) -> Result<CameraEventRecord, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "摄像机事件存储锁不可用".to_string())?;
    let parsed_kind =
        CameraEventKind::parse(&kind).ok_or_else(|| "未知的摄像机事件类型".to_string())?;
    let decoded = match snapshot_base64 {
        Some(ref b64) if !b64.trim().is_empty() => Some(base64_decode(b64)?),
        _ => None,
    };
    let dir = camera_events_dir()?;
    let now = now_epoch_ms();
    record_event_in_dir(
        &dir,
        &camera_id,
        parsed_kind,
        timestamp_ms.unwrap_or(now),
        now,
        decoded.as_deref(),
        &StoreLimits::default(),
    )
}

#[tauri::command]
pub(crate) fn camera_events_attach_snapshot(
    event_id: String,
    snapshot_base64: String,
) -> Result<Option<CameraEventRecord>, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "摄像机事件存储锁不可用".to_string())?;
    let decoded = base64_decode(&snapshot_base64)?;
    let dir = camera_events_dir()?;
    attach_snapshot_in_dir(&dir, &event_id, &decoded, now_epoch_ms(), &StoreLimits::default())
}

#[tauri::command]
pub(crate) fn camera_events_read_snapshot(snapshot_file: String) -> Result<Option<String>, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "摄像机事件存储锁不可用".to_string())?;
    let dir = camera_events_dir()?;
    read_snapshot_in_dir(&dir, &snapshot_file, &StoreLimits::default())
}

#[tauri::command]
pub(crate) fn camera_events_clear() -> Result<(), String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "摄像机事件存储锁不可用".to_string())?;
    let dir = camera_events_dir()?;
    clear_events_in_dir(&dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_test_dir(tag: &str) -> PathBuf {
        let seq = STAGING_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "menubarhome-camera-events-{tag}-{}-{seq}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn retention_limit_and_snapshot_cleanup_match_macos() {
        let dir = temp_test_dir("retention");
        let limits = StoreLimits {
            retention_ms: 100_000,
            max_events: 2,
            max_snapshot_bytes: 1024,
            max_total_snapshot_bytes: 4096,
        };
        let t0 = 1_700_000_000_000i64;
        let first = record_event_in_dir(
            &dir,
            "cam-a",
            CameraEventKind::Doorbell,
            t0,
            t0,
            Some(&[0xff, 0xd8, 0xff, 0xd9]),
            &limits,
        )
        .expect("record first");
        let first_file = first.snapshot_file.clone().expect("snapshot file");
        assert!(dir.join(&first_file).exists());
        assert!(read_snapshot_in_dir(&dir, &first_file, &limits)
            .expect("read")
            .is_some());

        let _ = record_event_in_dir(&dir, "cam-b", CameraEventKind::Motion, t0 + 1000, t0 + 1000, None, &limits)
            .expect("record second");
        let _ = record_event_in_dir(&dir, "cam-c", CameraEventKind::Person, t0 + 2000, t0 + 2000, None, &limits)
            .expect("record third");

        let loaded = load_events_in_dir(&dir, t0 + 2000, &limits).expect("load");
        assert_eq!(loaded.len(), 2);
        assert!(!dir.join(&first_file).exists(), "evicted snapshot must be deleted");

        let _ = record_event_in_dir(
            &dir,
            "cam-d",
            CameraEventKind::Package,
            t0 + 200_000,
            t0 + 200_000,
            None,
            &limits,
        )
        .expect("record fourth");
        let after_expire = load_events_in_dir(&dir, t0 + 200_000, &limits).expect("load");
        assert_eq!(after_expire.len(), 1);
        assert_eq!(after_expire[0].camera_id, "cam-d");

        clear_events_in_dir(&dir).expect("clear");
        assert!(!dir.exists());
    }

    #[test]
    fn disk_budget_evicts_oldest_snapshots_and_rejects_oversized() {
        let dir = temp_test_dir("budget");
        let limits = StoreLimits {
            retention_ms: DEFAULT_RETENTION_MS,
            max_events: 10,
            max_snapshot_bytes: 16,
            max_total_snapshot_bytes: 20,
        };
        let t0 = 1_700_000_000_000i64;
        assert!(record_event_in_dir(
            &dir,
            "cam-a",
            CameraEventKind::Doorbell,
            t0,
            t0,
            Some(&[1u8; 32]),
            &limits,
        )
        .is_err());

        let e1 = record_event_in_dir(&dir, "cam-a", CameraEventKind::Doorbell, t0, t0, Some(&[1u8; 12]), &limits)
            .expect("e1");
        let e2 = record_event_in_dir(&dir, "cam-b", CameraEventKind::Motion, t0 + 1000, t0 + 1000, Some(&[2u8; 12]), &limits)
            .expect("e2");
        let loaded = load_events_in_dir(&dir, t0 + 1000, &limits).expect("load");
        assert_eq!(loaded.len(), 2);
        assert!(loaded[0].snapshot_file.is_some());
        assert!(loaded[1].snapshot_file.is_none());
        assert!(dir.join(e2.snapshot_file.unwrap()).exists());
        assert!(!dir.join(e1.snapshot_file.unwrap()).exists());
        let _ = clear_events_in_dir(&dir);
    }

    #[test]
    fn malformed_json_and_unsafe_paths_are_rejected_without_losing_valid_records() {
        let dir = temp_test_dir("malformed");
        std::fs::create_dir_all(&dir).expect("mkdir");
        let now_ms = parse_iso8601_utc("2026-11-24T12:00:00Z").expect("ts");
        let mixed = r#"[
            {"id":"good-1","cameraID":"cam-front","kind":"doorbell","timestamp":"2026-11-24T11:00:00Z","snapshotFile":"snapshot-good-1.jpeg"},
            {"id":"good-2","cameraID":"cam-back","kind":"motion","timestamp":"2026-11-24T11:30:00Z","snapshotFile":"rtsp://user:pass@192.0.2.1/live"},
            {"id":"bad-url","cameraID":"rtsp://user:pass@192.0.2.1/live","kind":"doorbell","timestamp":"2026-11-24T11:00:00Z"},
            {"id":"bad-kind","cameraID":"cam-front","kind":"unknown","timestamp":"2026-11-24T11:00:00Z"},
            "corrupt-entry"
        ]"#;
        std::fs::write(dir.join(EVENTS_FILE_NAME), mixed).expect("write");
        let loaded = load_events_in_dir(&dir, now_ms, &StoreLimits::default()).expect("load");
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].id, "good-1");
        assert_eq!(loaded[0].snapshot_file.as_deref(), Some("snapshot-good-1.jpeg"));
        assert_eq!(loaded[1].id, "good-2");
        assert_eq!(loaded[1].snapshot_file, None, "URL snapshotFile must be stripped");

        assert!(read_snapshot_in_dir(&dir, "../events.json", &StoreLimits::default())
            .expect("safe")
            .is_none());
        assert!(!is_safe_snapshot_filename("rtsp://user:pass@192.0.2.1/stream"));
        assert!(!is_safe_camera_id("http://192.0.2.1/cam"));
        let _ = clear_events_in_dir(&dir);
    }

    #[test]
    fn attach_snapshot_and_base64_round_trip() {
        let dir = temp_test_dir("attach");
        let t0 = 1_700_000_000_000i64;
        let ev = record_event_in_dir(&dir, "cam-a", CameraEventKind::Doorbell, t0, t0, None, &StoreLimits::default())
            .expect("record");
        assert!(ev.snapshot_file.is_none());
        let payload = b"\xff\xd8\xff\xe0test-jpeg";
        let updated = attach_snapshot_in_dir(&dir, &ev.id, payload, t0 + 1000, &StoreLimits::default())
            .expect("attach")
            .expect("updated");
        let file = updated.snapshot_file.expect("file");
        let b64 = read_snapshot_in_dir(&dir, &file, &StoreLimits::default())
            .expect("read")
            .expect("b64");
        assert_eq!(base64_decode(&b64).expect("decode"), payload);
        let _ = clear_events_in_dir(&dir);
    }

    #[test]
    fn iso8601_round_trip_handles_leap_year() {
        let ms = parse_iso8601_utc("2024-02-29T23:59:59Z").expect("parse leap");
        assert_eq!(format_iso8601_utc(ms), "2024-02-29T23:59:59Z");
        assert!(parse_iso8601_utc("not-a-date").is_none());
    }
}
