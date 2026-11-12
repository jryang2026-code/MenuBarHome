use super::*;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const COMPANION_DIR_NAME: &str = "MenuBarMijia";
const SNAPSHOT_FILE_NAME: &str = "raycast-snapshot.json";
const IPC_ENDPOINT_FILE_NAME: &str = "ipc-endpoint.json";
const MAX_SNAPSHOT_BYTES: usize = 4 * 1024 * 1024;
const MAX_OPEN_URL_BYTES: usize = 4096;
const MAX_HTTP_REQUEST_BYTES: usize = 8192;
const MAX_PENDING_URLS: usize = 32;
const IPC_SECRET_HEADER: &str = "x-menubarhome-secret";

static SNAPSHOT_IO_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static SNAPSHOT_TMP_SEQ: AtomicU64 = AtomicU64::new(1);
static WEBVIEW_URL_LISTENER_READY: AtomicBool = AtomicBool::new(false);
static PENDING_OPEN_URLS: LazyLock<Mutex<Vec<String>>> = LazyLock::new(|| Mutex::new(Vec::new()));
static ACTIVE_IPC_OWNERSHIP: LazyLock<Mutex<Option<(u16, String)>>> =
    LazyLock::new(|| Mutex::new(None));

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct IpcEndpoint {
    pub(crate) port: u16,
    pub(crate) secret: String,
    pub(crate) pid: u32,
}

pub(crate) fn companion_local_dir_from_env(
    local_app_data: Option<std::ffi::OsString>,
    user_profile: Option<std::ffi::OsString>,
) -> Option<PathBuf> {
    if let Some(local) = local_app_data.filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(local).join(COMPANION_DIR_NAME));
    }
    let home = user_profile.filter(|v| !v.is_empty())?;
    Some(
        PathBuf::from(home)
            .join("AppData")
            .join("Local")
            .join(COMPANION_DIR_NAME),
    )
}

pub(crate) fn companion_local_dir() -> Option<PathBuf> {
    companion_local_dir_from_env(
        std::env::var_os("LOCALAPPDATA"),
        std::env::var_os("USERPROFILE"),
    )
}

fn ensure_confined_companion_dir(dir: &Path) -> Result<(), String> {
    if dir.file_name().and_then(|n| n.to_str()) != Some(COMPANION_DIR_NAME) {
        return Err("快照目录必须位于 MenuBarMijia 下".to_string());
    }
    Ok(())
}

fn write_atomic_file(dir: &Path, file_name: &str, prefix: &str, bytes: &[u8]) -> Result<PathBuf, String> {
    ensure_confined_companion_dir(dir)?;
    std::fs::create_dir_all(dir).map_err(|err| format!("创建伴侣目录失败：{err}"))?;
    let seq = SNAPSHOT_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let staging = dir.join(format!(".{prefix}.tmp-{}-{seq}", std::process::id()));
    let target = dir.join(file_name);
    let write_res = (|| -> std::io::Result<()> {
        let mut file = std::fs::File::create(&staging)?;
        file.write_all(bytes)?;
        file.sync_all()
    })();
    if let Err(err) = write_res {
        let _ = std::fs::remove_file(&staging);
        return Err(format!("写入临时文件失败：{err}"));
    }
    if let Err(err) = std::fs::rename(&staging, &target) {
        let _ = std::fs::remove_file(&staging);
        return Err(format!("原子替换文件失败：{err}"));
    }
    Ok(target)
}

pub(crate) fn write_snapshot_in_dir(dir: &Path, contents: &str) -> Result<PathBuf, String> {
    if contents.trim().is_empty() {
        return Err("快照内容不能为空".to_string());
    }
    if contents.len() > MAX_SNAPSHOT_BYTES {
        return Err("快照体积超出安全上限".to_string());
    }
    write_atomic_file(dir, SNAPSHOT_FILE_NAME, "raycast-snapshot", contents.as_bytes())
}

pub(crate) fn remove_snapshot_in_dir(dir: &Path) -> Result<(), String> {
    ensure_confined_companion_dir(dir)?;
    let target = dir.join(SNAPSHOT_FILE_NAME);
    match std::fs::remove_file(&target) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(format!("移除 Raycast 快照失败：{err}")),
    }
}

#[tauri::command]
pub(crate) fn write_raycast_snapshot(contents: String) -> Result<(), String> {
    let _guard = SNAPSHOT_IO_LOCK
        .lock()
        .map_err(|_| "快照写入锁不可用".to_string())?;
    let dir = companion_local_dir().ok_or_else(|| "无法定位 LOCALAPPDATA 目录".to_string())?;
    write_snapshot_in_dir(&dir, &contents).map(|_| ())
}

#[tauri::command]
pub(crate) fn remove_raycast_snapshot() -> Result<(), String> {
    let _guard = SNAPSHOT_IO_LOCK
        .lock()
        .map_err(|_| "快照写入锁不可用".to_string())?;
    let Some(dir) = companion_local_dir() else {
        return Ok(());
    };
    remove_snapshot_in_dir(&dir)
}

pub(crate) fn sanitize_menumijia_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > MAX_OPEN_URL_BYTES {
        return None;
    }
    if trimmed.bytes().any(|b| b == b'\r' || b == b'\n' || b == 0) {
        return None;
    }
    let prefix = trimmed.get(..10)?;
    if !prefix.eq_ignore_ascii_case("menumijia:") {
        return None;
    }
    Some(trimmed.to_string())
}

pub(crate) fn extract_menumijia_arg<I, S>(args: I) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    for arg in args {
        if let Some(valid) = sanitize_menumijia_url(arg.as_ref()) {
            return Some(valid);
        }
    }
    None
}

fn generate_hex_secret() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| "无法生成安全随机密钥".to_string())?;
    let mut out = String::with_capacity(64);
    for b in bytes {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{b:02x}");
    }
    Ok(out)
}

#[inline(never)]
pub(crate) fn constant_time_secret_matches(expected: &str, candidate: &str) -> bool {
    let lhs = expected.as_bytes();
    let rhs = candidate.trim().as_bytes();
    if lhs.is_empty() || lhs.len() != rhs.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (a, b) in lhs.iter().zip(rhs.iter()) {
        diff |= std::hint::black_box(*a ^ *b);
    }
    std::hint::black_box(diff) == 0
}

pub(crate) fn read_ipc_endpoint(dir: &Path) -> Option<IpcEndpoint> {
    let raw = std::fs::read_to_string(dir.join(IPC_ENDPOINT_FILE_NAME)).ok()?;
    let endpoint: IpcEndpoint = serde_json::from_str(&raw).ok()?;
    if endpoint.port == 0 || endpoint.secret.len() < 32 {
        return None;
    }
    Some(endpoint)
}

pub(crate) fn write_ipc_endpoint(dir: &Path, endpoint: &IpcEndpoint) -> Result<PathBuf, String> {
    let body = serde_json::to_vec(endpoint).map_err(|err| err.to_string())?;
    write_atomic_file(dir, IPC_ENDPOINT_FILE_NAME, "ipc-endpoint", &body)
}

pub(crate) fn forward_url_to_endpoint(
    endpoint: &IpcEndpoint,
    url: &str,
    timeout: Duration,
) -> bool {
    let Some(clean_url) = sanitize_menumijia_url(url) else {
        return false;
    };
    if endpoint.port == 0 || endpoint.secret.is_empty() {
        return false;
    }
    let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, timeout) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let body = clean_url.as_bytes();
    let request = format!(
        "POST /open-url HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-MenuBarHome-Secret: {}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        endpoint.port,
        endpoint.secret,
        body.len()
    );
    if stream.write_all(request.as_bytes()).is_err() || stream.write_all(body).is_err() {
        return false;
    }
    let _ = stream.flush();
    let mut resp = [0u8; 128];
    let Ok(n) = stream.read(&mut resp) else {
        return false;
    };
    let head = std::str::from_utf8(&resp[..n]).unwrap_or("");
    head.starts_with("HTTP/1.1 200") || head.starts_with("HTTP/1.0 200")
}

fn queue_pending_open_url(url: String) {
    if let Ok(mut guard) = PENDING_OPEN_URLS.lock() {
        if guard.len() >= MAX_PENDING_URLS {
            guard.remove(0);
        }
        guard.push(url);
    }
}

pub(crate) fn try_forward_startup_url_and_exit() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(startup_url) = extract_menumijia_arg(&args) else {
        return;
    };
    if let Some(dir) = companion_local_dir() {
        if let Some(endpoint) = read_ipc_endpoint(&dir) {
            if forward_url_to_endpoint(&endpoint, &startup_url, Duration::from_millis(450)) {
                std::process::exit(0);
            }
        }
    }
    queue_pending_open_url(startup_url);
}

fn handle_ipc_client(
    mut stream: TcpStream,
    expected_secret: &str,
    on_url: &(dyn Fn(String) + Send + Sync),
) {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(1500)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(1500)));

    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    let mut header_end: Option<usize> = None;
    let mut content_length: usize = 0;

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if buf.len() + n > MAX_HTTP_REQUEST_BYTES {
                    let _ = stream.write_all(b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    return;
                }
                buf.extend_from_slice(&chunk[..n]);
                if header_end.is_none() {
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let end = pos + 4;
                        header_end = Some(end);
                        let head_str = match std::str::from_utf8(&buf[..pos]) {
                            Ok(s) => s,
                            Err(_) => {
                                let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                                return;
                            }
                        };
                        for line in head_str.lines().skip(1) {
                            if let Some((name, val)) = line.split_once(':') {
                                if name.trim().eq_ignore_ascii_case("content-length") {
                                    content_length = val.trim().parse::<usize>().unwrap_or(0);
                                }
                            }
                        }
                        if content_length > MAX_OPEN_URL_BYTES {
                            let _ = stream.write_all(b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                            return;
                        }
                    }
                }
                if let Some(end) = header_end {
                    if buf.len() >= end + content_length {
                        break;
                    }
                }
            }
            Err(_) => break,
        }
    }

    let Some(end) = header_end else {
        let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    let Ok(head_str) = std::str::from_utf8(&buf[..end - 4]) else {
        let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    let mut lines = head_str.lines();
    let request_line = lines.next().unwrap_or("");
    if !request_line.starts_with("POST /open-url HTTP/1.") {
        let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }

    let mut provided_secret: Option<&str> = None;
    for line in lines {
        if let Some((name, val)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case(IPC_SECRET_HEADER) {
                provided_secret = Some(val.trim());
            }
        }
    }
    let Some(secret_candidate) = provided_secret else {
        let _ = stream.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    if !constant_time_secret_matches(expected_secret, secret_candidate) {
        let _ = stream.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }

    let body_end = (end + content_length).min(buf.len());
    let body_str = std::str::from_utf8(&buf[end..body_end]).unwrap_or("");
    let Some(valid_url) = sanitize_menumijia_url(body_str) else {
        let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };

    let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    let _ = stream.flush();
    on_url(valid_url);
}

pub(crate) fn spawn_ipc_server_in_dir<F>(
    dir: &Path,
    stop_flag: Option<std::sync::Arc<AtomicBool>>,
    on_url: F,
) -> Result<IpcEndpoint, String>
where
    F: Fn(String) + Send + Sync + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|err| format!("绑定本地单实例监听端口失败：{err}"))?;
    let port = listener
        .local_addr()
        .map_err(|err| format!("读取本地单实例端口失败：{err}"))?
        .port();
    let secret = generate_hex_secret()?;
    let endpoint = IpcEndpoint {
        port,
        secret: secret.clone(),
        pid: std::process::id(),
    };
    write_ipc_endpoint(dir, &endpoint)?;

    if stop_flag.is_some() {
        let _ = listener.set_nonblocking(true);
    }

    std::thread::spawn(move || {
        loop {
            if stop_flag
                .as_ref()
                .is_some_and(|flag| flag.load(Ordering::SeqCst))
            {
                break;
            }
            match listener.accept() {
                Ok((stream, peer)) => {
                    if !peer.ip().is_loopback() {
                        continue;
                    }
                    let _ = stream.set_nonblocking(false);
                    handle_ipc_client(stream, &secret, &on_url);
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(15));
                }
                Err(_) => break,
            }
        }
    });

    Ok(endpoint)
}

fn dispatch_open_url_to_webview(app: &AppHandle, url: String) {
    if WEBVIEW_URL_LISTENER_READY.load(Ordering::SeqCst) {
        if let Some(window) = app.get_webview_window("main") {
            if let Ok(json_url) = serde_json::to_string(&url) {
                let script = format!(
                    "window.dispatchEvent(new CustomEvent('menumijia:open-url', {{ detail: {json_url} }}))"
                );
                if window.eval(&script).is_ok() {
                    return;
                }
            }
        }
    }
    queue_pending_open_url(url);
}

#[tauri::command]
pub(crate) fn drain_pending_open_urls() -> Vec<String> {
    WEBVIEW_URL_LISTENER_READY.store(true, Ordering::SeqCst);
    match PENDING_OPEN_URLS.lock() {
        Ok(mut guard) => std::mem::take(&mut *guard),
        Err(_) => Vec::new(),
    }
}

#[tauri::command]
pub(crate) fn show_panel_for_url(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        position_popover(&window, None);
        let _ = window.show();
        let _ = window.set_focus();
    }
}

pub(crate) fn format_protocol_open_command(exe_path: &Path) -> Result<String, String> {
    let raw = exe_path
        .to_str()
        .ok_or_else(|| "可执行文件路径包含无效字符".to_string())?;
    if raw.is_empty() || raw.contains('"') || raw.contains('\0') || raw.contains('\r') || raw.contains('\n') {
        return Err("可执行文件路径格式不安全".to_string());
    }
    Ok(format!("\"{raw}\" \"%1\""))
}

#[cfg(windows)]
fn encode_wide_nul(text: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(text)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[cfg(windows)]
pub(crate) fn set_reg_sz_value(
    hkey: windows_sys::Win32::System::Registry::HKEY,
    value_name: Option<&str>,
    value_data: &str,
) -> Result<(), String> {
    use windows_sys::Win32::System::Registry::{RegSetValueExW, REG_SZ};
    let name_wide = value_name.map(encode_wide_nul);
    let data_wide = encode_wide_nul(value_data);
    let status = unsafe {
        RegSetValueExW(
            hkey,
            name_wide.as_ref().map_or(std::ptr::null(), |v| v.as_ptr()),
            0,
            REG_SZ,
            data_wide.as_ptr() as *const u8,
            (data_wide.len() * std::mem::size_of::<u16>()) as u32,
        )
    };
    if status != 0 {
        return Err(format!("写入注册表键值失败（Win32 错误码 {status}）"));
    }
    Ok(())
}

#[cfg(windows)]
pub(crate) fn register_url_scheme_under_root(
    classes_subkey: &str,
    exe_path: &Path,
) -> Result<(), String> {
    use windows_sys::Win32::System::Registry::{RegCloseKey, RegCreateKeyW, HKEY, HKEY_CURRENT_USER};
    let command = format_protocol_open_command(exe_path)?;
    let root_wide = encode_wide_nul(classes_subkey);
    let mut root_key: HKEY = std::ptr::null_mut();
    let status = unsafe { RegCreateKeyW(HKEY_CURRENT_USER, root_wide.as_ptr(), &mut root_key) };
    if status != 0 {
        return Err(format!("创建协议注册表项失败（Win32 错误码 {status}）"));
    }
    let root_res = (|| {
        set_reg_sz_value(root_key, None, "URL:MenuBarHome Protocol")?;
        set_reg_sz_value(root_key, Some("URL Protocol"), "")
    })();
    unsafe {
        let _ = RegCloseKey(root_key);
    }
    root_res?;

    let cmd_subkey = format!("{classes_subkey}\\shell\\open\\command");
    let cmd_wide = encode_wide_nul(&cmd_subkey);
    let mut cmd_key: HKEY = std::ptr::null_mut();
    let cmd_status = unsafe { RegCreateKeyW(HKEY_CURRENT_USER, cmd_wide.as_ptr(), &mut cmd_key) };
    if cmd_status != 0 {
        return Err(format!("创建协议打开命令注册表项失败（Win32 错误码 {cmd_status}）"));
    }
    let cmd_res = set_reg_sz_value(cmd_key, None, &command);
    unsafe {
        let _ = RegCloseKey(cmd_key);
    }
    cmd_res
}

#[cfg(windows)]
pub(crate) fn unregister_url_scheme_under_root(classes_subkey: &str) -> Result<(), String> {
    use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows_sys::Win32::System::Registry::{RegDeleteKeyW, HKEY_CURRENT_USER};
    let suffixes = [
        format!("{classes_subkey}\\shell\\open\\command"),
        format!("{classes_subkey}\\shell\\open"),
        format!("{classes_subkey}\\shell"),
        classes_subkey.to_string(),
    ];
    for path in suffixes {
        let wide = encode_wide_nul(&path);
        let status = unsafe { RegDeleteKeyW(HKEY_CURRENT_USER, wide.as_ptr()) };
        if status != 0 && status != ERROR_FILE_NOT_FOUND {
            return Err(format!("删除协议注册表项失败（Win32 错误码 {status}）"));
        }
    }
    Ok(())
}

#[cfg(not(windows))]
pub(crate) fn register_url_scheme_under_root(
    _classes_subkey: &str,
    exe_path: &Path,
) -> Result<(), String> {
    let _ = format_protocol_open_command(exe_path)?;
    Ok(())
}

#[cfg(not(windows))]
pub(crate) fn unregister_url_scheme_under_root(_classes_subkey: &str) -> Result<(), String> {
    Ok(())
}

#[tauri::command]
pub(crate) fn register_url_scheme() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|err| format!("无法读取当前程序路径：{err}"))?;
    register_url_scheme_under_root(r"Software\Classes\menumijia", &exe)
}

#[tauri::command]
pub(crate) fn unregister_url_scheme() -> Result<(), String> {
    unregister_url_scheme_under_root(r"Software\Classes\menumijia")
}

pub(crate) fn start_companion_runtime(app: AppHandle) {
    #[cfg(not(test))]
    {
        let _ = register_url_scheme();
    }
    let Some(dir) = companion_local_dir() else {
        return;
    };
    let app_for_ipc = app.clone();
    if let Ok(endpoint) = spawn_ipc_server_in_dir(&dir, None, move |url| {
        dispatch_open_url_to_webview(&app_for_ipc, url);
    }) {
        if let Ok(mut guard) = ACTIVE_IPC_OWNERSHIP.lock() {
            *guard = Some((endpoint.port, endpoint.secret));
        }
    }
}

pub(crate) fn shutdown_companion_runtime() {
    let owned = ACTIVE_IPC_OWNERSHIP.lock().ok().and_then(|mut g| g.take());
    let Some((port, secret)) = owned else {
        return;
    };
    let Some(dir) = companion_local_dir() else {
        return;
    };
    if let Some(current) = read_ipc_endpoint(&dir) {
        if current.port == port && constant_time_secret_matches(&secret, &current.secret) {
            let _ = std::fs::remove_file(dir.join(IPC_ENDPOINT_FILE_NAME));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn snapshot_write_and_remove_stay_atomic_and_confined() {
        let base = std::env::temp_dir().join(format!("mbm-companion-snap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let dir = base.join("MenuBarMijia");

        let payload_one = r#"{"schemaVersion":1,"devices":[],"scenes":[],"quickActions":[]}"#;
        let path = write_snapshot_in_dir(&dir, payload_one).expect("write initial snapshot");
        assert_eq!(std::fs::read_to_string(&path).expect("read initial"), payload_one);

        let payload_two = r#"{"schemaVersion":1,"bridgeToken":"tok","devices":[],"scenes":[],"quickActions":[]}"#;
        write_snapshot_in_dir(&dir, payload_two).expect("overwrite snapshot atomically");
        assert_eq!(std::fs::read_to_string(&path).expect("read replaced"), payload_two);

        let leftovers = std::fs::read_dir(&dir)
            .expect("list companion dir")
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .count();
        assert_eq!(leftovers, 0, "staging files must not remain after atomic write");

        remove_snapshot_in_dir(&dir).expect("remove snapshot");
        assert!(!path.exists());
        remove_snapshot_in_dir(&dir).expect("remove missing snapshot is idempotent");

        let wrong_dir = base.join("OtherFolder");
        assert!(write_snapshot_in_dir(&wrong_dir, payload_one).is_err());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn loopback_ipc_authenticates_secret_and_forwards_menumijia_urls() {
        let base = std::env::temp_dir().join(format!("mbm-companion-ipc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let dir = base.join("MenuBarMijia");
        let received: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let received_sink = received.clone();
        let stop = Arc::new(AtomicBool::new(false));

        let endpoint = spawn_ipc_server_in_dir(&dir, Some(stop.clone()), move |url| {
            received_sink.lock().unwrap().push(url);
        })
        .expect("spawn loopback IPC server");

        let persisted = read_ipc_endpoint(&dir).expect("read ipc-endpoint.json");
        assert_eq!(persisted, endpoint);

        let wrong = IpcEndpoint {
            secret: "0".repeat(64),
            ..endpoint.clone()
        };
        assert!(
            !forward_url_to_endpoint(&wrong, "menumijia://toggle?name=desk", Duration::from_millis(400)),
            "mismatched secret must be rejected with 403"
        );
        assert!(received.lock().unwrap().is_empty());

        assert!(
            !forward_url_to_endpoint(&endpoint, "https://example.com/not-menumijia", Duration::from_millis(400)),
            "non-menumijia scheme must be rejected"
        );

        assert!(
            forward_url_to_endpoint(
                &endpoint,
                "menumijia://power?id=light.desk&state=on&token=abc&request_id=req-1",
                Duration::from_millis(400)
            ),
            "valid secret and menumijia URL must succeed"
        );
        stop.store(true, Ordering::SeqCst);

        let got = received.lock().unwrap().clone();
        assert_eq!(
            got,
            vec!["menumijia://power?id=light.desk&state=on&token=abc&request_id=req-1".to_string()]
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn url_arg_extraction_and_protocol_registry_roundtrip() {
        assert_eq!(
            extract_menumijia_arg(["--flag", "MENUMIJIA://focus", "other"]),
            Some("MENUMIJIA://focus".to_string())
        );
        assert_eq!(extract_menumijia_arg(["https://example.com"]), None);
        assert_eq!(sanitize_menumijia_url("menumijia://toggle?name=lamp\r\nInjected: 1"), None);

        let cmd = format_protocol_open_command(Path::new(r"C:\Program Files\MenuBarHome\MenuBarHome.exe"))
            .expect("format exe open command");
        assert_eq!(cmd, r#""C:\Program Files\MenuBarHome\MenuBarHome.exe" "%1""#);
        assert!(format_protocol_open_command(Path::new(r#"C:\bad"quote\app.exe"#)).is_err());

        #[cfg(windows)]
        {
            let subkey = format!(r"Software\Classes\menumijia-test-{}", std::process::id());
            let _ = unregister_url_scheme_under_root(&subkey);
            register_url_scheme_under_root(
                &subkey,
                Path::new(r"C:\Program Files\MenuBarHome\MenuBarHome.exe"),
            )
            .expect("register test protocol under HKCU");
            unregister_url_scheme_under_root(&subkey).expect("unregister test protocol");
            unregister_url_scheme_under_root(&subkey).expect("idempotent unregister");
        }
    }
}
