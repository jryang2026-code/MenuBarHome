use crate::job_object::ManagedCameraProcess;
use ring::digest::{digest, SHA256};
use serde_json::Value;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{LazyLock, Mutex};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

struct TvBridgeProcess {
    process: ManagedCameraProcess,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

static TV_BRIDGE: LazyLock<Mutex<Option<TvBridgeProcess>>> =
    LazyLock::new(|| Mutex::new(None));

fn validate_regular_file(path: &Path, label: &str) -> Result<(), String> {
    let metadata = fs::metadata(path).map_err(|error| format!("{label} 不可读取：{error}"))?;
    if !metadata.is_file() {
        return Err(format!("{label} 必须是普通文件"));
    }
    Ok(())
}

fn verify_sha256(path: &Path, expected: &str) -> Result<(), String> {
    let bytes = fs::read(path).map_err(|error| format!("读取二进制失败：{error}"))?;
    let actual = digest(&SHA256, &bytes);
    let actual = actual.as_ref().iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    if actual.eq_ignore_ascii_case(expected.trim()) {
        Ok(())
    } else {
        Err("二进制 SHA-256 校验失败".to_string())
    }
}

fn data_and_manifest_paths(binary_path: &Path) -> Result<(PathBuf, PathBuf), String> {
    let data_dir = std::env::var_os("MBH_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("LOCALAPPDATA")
                .map(|local| PathBuf::from(local).join("MenuBarHome").join("TVBridge"))
                .unwrap_or_else(|| std::env::temp_dir().join("menubarhome-tv-bridge"))
        });
    let data_dir = std::path::absolute(data_dir)
        .map_err(|error| format!("无法解析 MBH_DATA_DIR：{error}"))?;
    fs::create_dir_all(&data_dir).map_err(|error| format!("创建 MBH_DATA_DIR 失败：{error}"))?;
    let manifest_path = std::env::var_os("MBH_MANIFEST_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            binary_path
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join("adapter-manifest.json")
        });
    let manifest_path = std::path::absolute(manifest_path)
        .map_err(|error| format!("无法解析 MBH_MANIFEST_PATH：{error}"))?;
    validate_regular_file(&manifest_path, "adapter-manifest.json")?;
    let manifest = fs::read_to_string(&manifest_path)
        .map_err(|error| format!("读取 adapter-manifest.json 失败：{error}"))?;
    serde_json::from_str::<Value>(&manifest)
        .map_err(|error| format!("解析 adapter-manifest.json 失败：{error}"))?;
    Ok((data_dir, manifest_path))
}

fn kill_process(state: &mut Option<TvBridgeProcess>) {
    state.take();
}

fn parse_rpc_frame(frame: &str, kind: &str) -> Result<Value, String> {
    if frame.as_bytes().len() > MAX_FRAME_BYTES {
        return Err(format!("{kind}帧超过 8 MiB 限制"));
    }
    if frame.bytes().any(|byte| byte == b'\r' || byte == b'\n') {
        return Err(format!("{kind}帧必须是单行 NDJSON"));
    }
    serde_json::from_str(frame).map_err(|error| format!("{kind}帧不是合法 JSON：{error}"))
}

fn validate_request(frame: &str) -> Result<String, String> {
    let value = parse_rpc_frame(frame, "请求")?;
    if value.get("jsonrpc") != Some(&Value::String("2.0".to_string())) {
        return Err("请求帧必须使用 JSON-RPC 2.0".to_string());
    }
    value
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| "请求帧 id 必须是字符串".to_string())
}

fn prepare_request(frame: Value) -> Result<(String, String), String> {
    let frame_json = match frame {
        Value::String(text) => text,
        value => serde_json::to_string(&value)
            .map_err(|error| format!("序列化 TV bridge 请求失败：{error}"))?,
    };
    let request_id = validate_request(&frame_json)?;
    Ok((frame_json, request_id))
}

fn validate_response(frame: &[u8], request_id: &str) -> Result<String, String> {
    if frame.len() > MAX_FRAME_BYTES {
        return Err("响应帧超过 8 MiB 限制".to_string());
    }
    let text = std::str::from_utf8(frame).map_err(|_| "响应帧不是 UTF-8".to_string())?;
    let value = parse_rpc_frame(text.trim_end_matches(['\r', '\n']), "响应")?;
    if value.get("jsonrpc") != Some(&Value::String("2.0".to_string())) {
        return Err("响应帧必须使用 JSON-RPC 2.0".to_string());
    }
    if value.get("id").and_then(Value::as_str) != Some(request_id) {
        return Err("响应帧 id 与请求不匹配".to_string());
    }
    Ok(text.trim_end_matches(['\r', '\n']).to_string())
}

fn read_limited_line(reader: &mut BufReader<ChildStdout>) -> io::Result<Vec<u8>> {
    let mut line = Vec::new();
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            break;
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let take = newline.map_or(buffer.len(), |index| index + 1);
        if line.len().saturating_add(take) > MAX_FRAME_BYTES + 1 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "响应帧超过 8 MiB 限制"));
        }
        line.extend_from_slice(&buffer[..take]);
        reader.consume(take);
        if newline.is_some() {
            break;
        }
    }
    Ok(line)
}

#[tauri::command]
pub(crate) fn tv_bridge_start(binary_path: String, expected_sha256: Option<String>) -> Result<(), String> {
    let binary_path = std::path::absolute(binary_path)
        .map_err(|error| format!("无法解析 TV bridge 二进制路径：{error}"))?;
    validate_regular_file(&binary_path, "TV bridge 二进制")?;
    if let Some(expected) = expected_sha256.as_deref() {
        verify_sha256(&binary_path, expected)?;
    }
    let (data_dir, manifest_path) = data_and_manifest_paths(&binary_path)?;
    let mut guard = TV_BRIDGE.lock().map_err(|_| "TV bridge 状态不可用".to_string())?;
    kill_process(&mut guard);

    let mut command = Command::new(&binary_path);
    command
        .current_dir(&data_dir)
        .env_clear()
        .env("MBH_DATA_DIR", &data_dir)
        .env("MBH_MANIFEST_PATH", &manifest_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for name in ["SYSTEMROOT", "PATH"] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    #[cfg(windows)]
    command.creation_flags(0x0800_0000);

    let mut child = command.spawn().map_err(|error| format!("启动 TV bridge 失败：{error}"))?;
    let stdin = match child.stdin.take() {
        Some(stdin) => stdin,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err("TV bridge stdin 不可用".to_string());
        }
    };
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err("TV bridge stdout 不可用".to_string());
        }
    };
    let process = ManagedCameraProcess::bind(child)?;
    *guard = Some(TvBridgeProcess { process, stdin, stdout: BufReader::new(stdout) });
    Ok(())
}

#[tauri::command]
pub(crate) fn tv_bridge_request(frame: Value) -> Result<String, String> {
    let (frame_json, request_id) = prepare_request(frame)?;
    let mut guard = TV_BRIDGE.lock().map_err(|_| "TV bridge 状态不可用".to_string())?;
    let write_result = {
        let bridge = guard.as_mut().ok_or_else(|| "TV bridge 尚未启动".to_string())?;
        writeln!(bridge.stdin, "{frame_json}").and_then(|_| bridge.stdin.flush())
    };
    if let Err(error) = write_result {
        kill_process(&mut guard);
        return Err(format!("写入 TV bridge 失败：{error}"));
    }
    let response = match {
        let bridge = guard.as_mut().expect("TV bridge state was checked above");
        read_limited_line(&mut bridge.stdout)
    } {
        Ok(line) if !line.is_empty() && line.ends_with(b"\n") => line,
        Ok(_) => {
            kill_process(&mut guard);
            return Err("TV bridge 已关闭 stdout".to_string());
        }
        Err(error) => {
            kill_process(&mut guard);
            return Err(format!("读取 TV bridge 响应失败：{error}"));
        }
    };
    match validate_response(&response, &request_id) {
        Ok(response) => Ok(response),
        Err(error) => {
            kill_process(&mut guard);
            Err(error)
        }
    }
}

#[tauri::command]
pub(crate) fn tv_bridge_shutdown() -> Result<(), String> {
    let mut guard = TV_BRIDGE.lock().map_err(|_| "TV bridge 状态不可用".to_string())?;
    kill_process(&mut guard);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn prepares_rpc_requests_from_objects_and_strings() {
        let object = serde_json::json!({"jsonrpc": "2.0", "id": "x", "method": "list"});
        let (frame, id) = prepare_request(object.clone()).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&frame).unwrap(), object);
        assert_eq!(id, "x");

        let raw = r#"{ "jsonrpc": "2.0", "id": "y" }"#;
        assert_eq!(
            prepare_request(Value::String(raw.to_string())).unwrap(),
            (raw.to_string(), "y".to_string())
        );
        assert!(prepare_request(serde_json::json!({"jsonrpc": "2.0", "id": 1})).is_err());
        assert!(prepare_request(Value::String(format!("{raw}\n"))).is_err());
    }

    #[test]
    fn frame_limit_and_rpc_validation_are_enforced() {
        assert!(validate_request(&format!(r#"{{"jsonrpc":"2.0","id":"x","params":"{}"}}"#, "a".repeat(MAX_FRAME_BYTES))).is_err());
        assert_eq!(validate_request(r#"{"jsonrpc":"2.0","id":"x"}"#).unwrap(), "x");
        assert!(validate_request(r#"{"jsonrpc":"1.0","id":"x"}"#).is_err());
        assert!(validate_request(r#"{"jsonrpc":"2.0","id":1}"#).is_err());
        assert_eq!(validate_response(br#"{"jsonrpc":"2.0","id":"x"}
"#, "x").unwrap(), r#"{"jsonrpc":"2.0","id":"x"}"#);
        assert!(validate_response(br#"{"jsonrpc":"2.0","id":"y"}
"#, "x").is_err());
    }

    #[test]
    fn sha256_matches_and_rejects_mismatch() {
        let path = std::env::temp_dir().join(format!("mbh-tv-bridge-{}", std::process::id()));
        let mut file = fs::File::create(&path).unwrap();
        file.write_all(b"bridge").unwrap();
        let expected = digest(&SHA256, b"bridge");
        let hex = expected.as_ref().iter().map(|byte| format!("{byte:02X}")).collect::<String>();
        assert!(verify_sha256(&path, &hex).is_ok());
        assert!(verify_sha256(&path, "00").is_err());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn shutdown_is_idempotent_when_empty() {
        tv_bridge_shutdown().unwrap();
        tv_bridge_shutdown().unwrap();
    }
}
