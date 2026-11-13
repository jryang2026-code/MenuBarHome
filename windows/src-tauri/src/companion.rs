use super::*;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex};
use std::time::Instant;

const COMPANION_DIR_NAME: &str = "MenuBarMijia";
const SNAPSHOT_FILE_NAME: &str = "raycast-snapshot.json";
const IPC_ENDPOINT_FILE_NAME: &str = "ipc-endpoint.json";
const MAX_SNAPSHOT_BYTES: usize = 4 * 1024 * 1024;
const MAX_OPEN_URL_BYTES: usize = 4096;
const MAX_HTTP_REQUEST_BYTES: usize = 8192;
const MAX_PENDING_URLS: usize = 32;
const IPC_SECRET_HEADER: &str = "x-menubarhome-secret";
const IPC_OPEN_URL_ROUTE: &str = "/open-url";
const IPC_ACTIVATE_ROUTE: &str = "/activate";
/// A whole request (headers **and** body) must arrive inside this budget, so a client that drips
/// one byte per second cannot pin a handler thread.
const IPC_CONNECTION_DEADLINE_MS: u64 = 1500;
const IPC_CLIENT_WRITE_TIMEOUT_MS: u64 = 500;
/// Bounded fan-out: slow clients may never starve a real forward. Beyond this, a connection is
/// closed immediately instead of being queued behind the others.
const MAX_CONCURRENT_IPC_CLIENTS: usize = 4;
/// A second launch waits this long in total for the primary instance to publish `ipc-endpoint.json`.
#[cfg(not(test))]
const STARTUP_FORWARD_TOTAL_TIMEOUT_MS: u64 = 2000;
#[cfg(not(test))]
const STARTUP_FORWARD_ATTEMPT_TIMEOUT_MS: u64 = 350;
#[cfg(not(test))]
const STARTUP_FORWARD_POLL_INTERVAL_MS: u64 = 60;
/// `Local\` scopes the mutex to the signed-in session, so a second Windows user is not blocked.
#[cfg(all(windows, not(test)))]
const SINGLE_INSTANCE_MUTEX_NAME: &str = r"Local\MenuBarHome.SingleInstance.Mutex";
#[cfg(all(windows, not(test)))]
const WIN32_ERROR_ALREADY_EXISTS: u32 = 183;

static SNAPSHOT_IO_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static SNAPSHOT_TMP_SEQ: AtomicU64 = AtomicU64::new(1);
static WEBVIEW_URL_LISTENER_READY: AtomicBool = AtomicBool::new(false);
static PENDING_OPEN_URLS: LazyLock<Mutex<Vec<String>>> = LazyLock::new(|| Mutex::new(Vec::new()));
static ACTIVE_IPC_OWNERSHIP: LazyLock<Mutex<Option<(u16, String)>>> =
    LazyLock::new(|| Mutex::new(None));
/// Handle of the session single-instance mutex, kept until the process exits so the object and the
/// name stay alive for as long as this instance runs.
#[cfg(all(windows, not(test)))]
static SINGLE_INSTANCE_HANDLE: AtomicUsize = AtomicUsize::new(0);

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

/// What a second launch asks the running primary instance to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum IpcRequest {
    /// A `menumijia://` protocol activation carrying the URL to run.
    OpenUrl(String),
    /// A plain second launch: reveal and focus the main panel without any URL.
    Activate,
}

const HTTP_200: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
const HTTP_400: &[u8] = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const HTTP_403: &[u8] = b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const HTTP_404: &[u8] = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const HTTP_408: &[u8] = b"HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const HTTP_413: &[u8] = b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const HTTP_503: &[u8] = b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

fn respond(stream: &mut TcpStream, status: &'static [u8]) {
    let _ = stream.write_all(status);
    let _ = stream.flush();
}

fn post_to_endpoint(endpoint: &IpcEndpoint, route: &str, body: &[u8], timeout: Duration) -> bool {
    if endpoint.port == 0 || endpoint.secret.is_empty() {
        return false;
    }
    let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, timeout) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let request = format!(
        "POST {route} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n{IPC_SECRET_HEADER}: {}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
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

pub(crate) fn forward_url_to_endpoint(
    endpoint: &IpcEndpoint,
    url: &str,
    timeout: Duration,
) -> bool {
    let Some(clean_url) = sanitize_menumijia_url(url) else {
        return false;
    };
    post_to_endpoint(endpoint, IPC_OPEN_URL_ROUTE, clean_url.as_bytes(), timeout)
}

pub(crate) fn forward_activate_to_endpoint(endpoint: &IpcEndpoint, timeout: Duration) -> bool {
    post_to_endpoint(endpoint, IPC_ACTIVATE_ROUTE, b"", timeout)
}

/// Hands this launch over to the instance that already owns the session mutex.
///
/// A just-started primary may not have written `ipc-endpoint.json` yet, so the endpoint is polled
/// until `total_timeout` runs out. The retry is what makes a double-click right after login land
/// on the real instance instead of dying on a missing file.
pub(crate) fn forward_to_primary_instance(
    dir: &Path,
    startup_url: Option<&str>,
    total_timeout: Duration,
    attempt_timeout: Duration,
    poll_interval: Duration,
) -> bool {
    let deadline = Instant::now() + total_timeout;
    loop {
        if let Some(endpoint) = read_ipc_endpoint(dir) {
            let delivered = match startup_url {
                Some(url) => forward_url_to_endpoint(&endpoint, url, attempt_timeout),
                None => forward_activate_to_endpoint(&endpoint, attempt_timeout),
            };
            if delivered {
                return true;
            }
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(poll_interval);
    }
}

fn queue_pending_open_url(url: String) {
    if let Ok(mut guard) = PENDING_OPEN_URLS.lock() {
        if guard.len() >= MAX_PENDING_URLS {
            guard.remove(0);
        }
        guard.push(url);
    }
}

/// `true` when this process took the session mutex (i.e. it is the primary instance).
///
/// `CreateMutexW` reports an existing object through `ERROR_ALREADY_EXISTS`, which is the only
/// signal Windows gives a second copy of the same executable. The handle is kept for the life of
/// the process: dropping it would release the name and let a third launch become "primary".
#[cfg(all(windows, not(test)))]
fn acquire_single_instance() -> bool {
    #[link(name = "kernel32")]
    extern "system" {
        fn CreateMutexW(
            lp_mutex_attributes: *const std::ffi::c_void,
            b_initial_owner: i32,
            lp_name: *const u16,
        ) -> isize;
        fn GetLastError() -> u32;
        fn CloseHandle(h_object: isize) -> i32;
    }

    let name: Vec<u16> = SINGLE_INSTANCE_MUTEX_NAME
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    if handle == 0 {
        // The mutex could not be created at all (e.g. a restricted desktop). Refusing to start
        // would leave the user with no app, so fall through as the primary instance.
        return true;
    }
    if unsafe { GetLastError() } == WIN32_ERROR_ALREADY_EXISTS {
        unsafe {
            let _ = CloseHandle(handle);
        }
        return false;
    }
    SINGLE_INSTANCE_HANDLE.store(handle as usize, Ordering::SeqCst);
    true
}

#[cfg(all(not(windows), not(test)))]
fn acquire_single_instance() -> bool {
    true
}

/// Real startup path: claim the single-instance mutex, or hand the launch over and exit.
///
/// Runs only outside unit tests, because both branches either exit the process or hold a real
/// kernel object.
#[cfg(not(test))]
fn claim_single_instance_or_forward(startup_url: Option<&str>) -> bool {
    if acquire_single_instance() {
        return true;
    }
    if let Some(dir) = companion_local_dir() {
        // Best effort: a failed forward still exits, because a second tray instance would
        // overwrite `ipc-endpoint.json` and race the primary on the snapshot and timers.
        let _ = forward_to_primary_instance(
            &dir,
            startup_url,
            Duration::from_millis(STARTUP_FORWARD_TOTAL_TIMEOUT_MS),
            Duration::from_millis(STARTUP_FORWARD_ATTEMPT_TIMEOUT_MS),
            Duration::from_millis(STARTUP_FORWARD_POLL_INTERVAL_MS),
        );
    }
    false
}

pub(crate) fn try_forward_startup_url_and_exit() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let startup_url = extract_menumijia_arg(&args);
    #[cfg(not(test))]
    {
        if !claim_single_instance_or_forward(startup_url.as_deref()) {
            std::process::exit(0);
        }
    }
    // The primary instance reads its own launch URL directly; a stale `ipc-endpoint.json` from a
    // previous run is never trusted as a forwarding target.
    if let Some(url) = startup_url {
        queue_pending_open_url(url);
    }
}

/// Parsed and authorized request head. Authorization happens the moment the head is complete, so
/// an unauthenticated client never gets to stream a body into the only handler.
struct AuthorizedHead {
    request: AuthorizedRequest,
    content_length: usize,
}

enum AuthorizedRequest {
    OpenUrl,
    Activate,
}

impl AuthorizedHead {
    fn into_request(self, body: &str) -> Option<IpcRequest> {
        match self.request {
            AuthorizedRequest::OpenUrl => sanitize_menumijia_url(body).map(IpcRequest::OpenUrl),
            AuthorizedRequest::Activate => {
                if self.content_length == 0 {
                    Some(IpcRequest::Activate)
                } else {
                    None
                }
            }
        }
    }
}

fn parse_content_length(head: &str) -> Option<usize> {
    let mut found: Option<usize> = None;
    for line in head.lines().skip(1) {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if name.eq_ignore_ascii_case("transfer-encoding") {
            // Chunked bodies would let a client drip forever without a usable Content-Length.
            return None;
        }
        if !name.eq_ignore_ascii_case("content-length") {
            continue;
        }
        let parsed = value.trim().parse::<usize>().ok()?;
        if found.is_some_and(|existing| existing != parsed) {
            return None;
        }
        found = Some(parsed);
    }
    Some(found.unwrap_or(0))
}

/// Returns the authorized head, or the status line to answer with.
fn authorize_request_head(head: &str, expected_secret: &str) -> Result<AuthorizedHead, &'static [u8]> {
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or("");
    let route = if request_line.starts_with(&format!("POST {IPC_OPEN_URL_ROUTE} HTTP/1.")) {
        AuthorizedRequest::OpenUrl
    } else if request_line.starts_with(&format!("POST {IPC_ACTIVATE_ROUTE} HTTP/1.")) {
        AuthorizedRequest::Activate
    } else {
        return Err(HTTP_404);
    };

    let mut provided_secret: Option<&str> = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case(IPC_SECRET_HEADER) {
                provided_secret = Some(value.trim());
            }
        }
    }
    let Some(candidate) = provided_secret else {
        return Err(HTTP_403);
    };
    if !constant_time_secret_matches(expected_secret, candidate) {
        return Err(HTTP_403);
    }

    let Some(content_length) = parse_content_length(head) else {
        return Err(HTTP_400);
    };
    if content_length > MAX_OPEN_URL_BYTES {
        return Err(HTTP_413);
    }
    if matches!(route, AuthorizedRequest::Activate) && content_length != 0 {
        return Err(HTTP_400);
    }
    Ok(AuthorizedHead {
        request: route,
        content_length,
    })
}

/// Reads one request inside a single wall-clock budget for the whole connection.
///
/// The head is authorized before any body byte is accepted, and every `read` is bounded by the
/// time left, so a client trickling one byte per second is closed instead of parking the thread.
fn handle_ipc_client(
    mut stream: TcpStream,
    expected_secret: &str,
    on_request: &(dyn Fn(IpcRequest) + Send + Sync),
) {
    let deadline = Instant::now() + Duration::from_millis(IPC_CONNECTION_DEADLINE_MS);
    let _ = stream.set_write_timeout(Some(Duration::from_millis(IPC_CLIENT_WRITE_TIMEOUT_MS)));

    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    let mut authorized: Option<AuthorizedHead> = None;
    let mut header_end: Option<usize> = None;

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            respond(&mut stream, HTTP_408);
            return;
        }
        if stream.set_read_timeout(Some(remaining)).is_err() {
            respond(&mut stream, HTTP_400);
            return;
        }
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if buf.len() + n > MAX_HTTP_REQUEST_BYTES {
                    respond(&mut stream, HTTP_413);
                    return;
                }
                buf.extend_from_slice(&chunk[..n]);
                if header_end.is_none() {
                    let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") else {
                        continue;
                    };
                    let Ok(head) = std::str::from_utf8(&buf[..pos]) else {
                        respond(&mut stream, HTTP_400);
                        return;
                    };
                    match authorize_request_head(head, expected_secret) {
                        Ok(parsed) => {
                            header_end = Some(pos + 4);
                            authorized = Some(parsed);
                        }
                        Err(status) => {
                            respond(&mut stream, status);
                            return;
                        }
                    }
                }
                let Some(end) = header_end else {
                    continue;
                };
                let needed = authorized.as_ref().map_or(0, |head| head.content_length);
                if buf.len() >= end + needed {
                    break;
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                respond(&mut stream, HTTP_408);
                return;
            }
        }
    }

    let (Some(end), Some(head)) = (header_end, authorized) else {
        respond(&mut stream, HTTP_400);
        return;
    };
    // A client that closed mid-body leaves fewer bytes than it announced; the body is then
    // untrustworthy, so nothing is dispatched.
    let Some(body_end) = end.checked_add(head.content_length) else {
        respond(&mut stream, HTTP_400);
        return;
    };
    if buf.len() < body_end {
        respond(&mut stream, HTTP_400);
        return;
    }
    let body = std::str::from_utf8(&buf[end..body_end]).unwrap_or("");
    let Some(request) = head.into_request(body) else {
        respond(&mut stream, HTTP_400);
        return;
    };
    // Dispatch before acknowledging: a 200 means the primary instance took the request, so the
    // launcher's "did the forward land?" answer is not a guess about a later event.
    on_request(request);
    respond(&mut stream, HTTP_200);
}

/// Decrements the active-client counter on every exit path, including a panic in the handler.
struct ClientSlot(Arc<AtomicUsize>);

impl Drop for ClientSlot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

pub(crate) fn spawn_ipc_server_in_dir<F>(
    dir: &Path,
    stop_flag: Option<Arc<AtomicBool>>,
    on_request: F,
) -> Result<IpcEndpoint, String>
where
    F: Fn(IpcRequest) + Send + Sync + 'static,
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

    let on_request = Arc::new(on_request);
    let active_clients = Arc::new(AtomicUsize::new(0));
    let clients_for_accept = active_clients.clone();

    std::thread::spawn(move || loop {
        if stop_flag
            .as_ref()
            .is_some_and(|flag| flag.load(Ordering::SeqCst))
        {
            break;
        }
        match listener.accept() {
            Ok((mut stream, peer)) => {
                if !peer.ip().is_loopback() {
                    continue;
                }
                let _ = stream.set_nonblocking(false);
                // Bounded fan-out: a shelf of slow clients must never starve a real forward.
                if clients_for_accept.fetch_add(1, Ordering::SeqCst) >= MAX_CONCURRENT_IPC_CLIENTS {
                    clients_for_accept.fetch_sub(1, Ordering::SeqCst);
                    respond(&mut stream, HTTP_503);
                    continue;
                }
                let slot = ClientSlot(clients_for_accept.clone());
                let handler = on_request.clone();
                let client_secret = secret.clone();
                std::thread::spawn(move || {
                    let _slot = slot;
                    handle_ipc_client(stream, &client_secret, handler.as_ref());
                });
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(15));
            }
            // A transient accept failure (a client that reset before accept, a brief resource
            // shortage) must not end forwarding for the rest of the session: second launches
            // would then exit without reaching this instance.
            Err(_) => std::thread::sleep(Duration::from_millis(50)),
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

/// A plain second launch (no `menumijia://` argument) asks the running instance to come forward.
///
/// The panel is revealed first so it works even before the webview registers its listener; the
/// event afterwards lets the page repaint with fresh state.
fn dispatch_activate_to_webview(app: &AppHandle) {
    show_panel_for_url(app.clone());
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval("window.dispatchEvent(new CustomEvent('menumijia:activate'))");
    }
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

#[cfg(all(test, windows))]
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

fn register_url_scheme() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|err| format!("无法读取当前程序路径：{err}"))?;
    register_url_scheme_under_root(r"Software\Classes\menumijia", &exe)
}

pub(crate) fn start_companion_runtime(app: AppHandle) {
    if !cfg!(test) && !cfg!(debug_assertions) {
        let _ = register_url_scheme();
    }
    let Some(dir) = companion_local_dir() else {
        return;
    };
    let app_for_ipc = app.clone();
    if let Ok(endpoint) = spawn_ipc_server_in_dir(&dir, None, move |request| match request {
        IpcRequest::OpenUrl(url) => dispatch_open_url_to_webview(&app_for_ipc, url),
        // A bare second launch: bringing the panel forward is the whole request.
        IpcRequest::Activate => dispatch_activate_to_webview(&app_for_ipc),
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

    fn scratch_dir(label: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!("mbm-companion-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        base
    }

    fn read_status_line(stream: &mut TcpStream) -> String {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(2500)));
        let mut buf = [0u8; 128];
        match stream.read(&mut buf) {
            Ok(0) | Err(_) => String::new(),
            Ok(n) => String::from_utf8_lossy(&buf[..n])
                .lines()
                .next()
                .unwrap_or("")
                .to_string(),
        }
    }

    fn request_head(secret: Option<&str>, route: &str, content_length: usize) -> String {
        let mut head = format!(
            "POST {route} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {content_length}\r\nConnection: close\r\n"
        );
        if let Some(secret) = secret {
            head.push_str(&format!("{IPC_SECRET_HEADER}: {secret}\r\n"));
        }
        head.push_str("\r\n");
        head
    }

    fn send_raw(endpoint: &IpcEndpoint, raw: &str) -> String {
        let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
        let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(1000))
            .expect("connect to the loopback IPC endpoint");
        let _ = stream.set_write_timeout(Some(Duration::from_millis(1000)));
        stream
            .write_all(raw.as_bytes())
            .expect("write the raw request");
        let _ = stream.flush();
        read_status_line(&mut stream)
    }

    #[test]
    fn snapshot_write_and_remove_stay_atomic_and_confined() {
        let base = scratch_dir("snap");
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
        let base = scratch_dir("ipc");
        let dir = base.join("MenuBarMijia");
        let received: Arc<Mutex<Vec<IpcRequest>>> = Arc::new(Mutex::new(Vec::new()));
        let received_sink = received.clone();
        let stop = Arc::new(AtomicBool::new(false));

        let endpoint = spawn_ipc_server_in_dir(&dir, Some(stop.clone()), move |request| {
            received_sink.lock().unwrap().push(request);
        })
        .expect("spawn loopback IPC server");

        let persisted = read_ipc_endpoint(&dir).expect("read ipc-endpoint.json");
        assert_eq!(persisted, endpoint);

        let wrong = IpcEndpoint {
            secret: "cd".repeat(32),
            ..endpoint.clone()
        };
        assert!(
            !forward_url_to_endpoint(&wrong, "menumijia://focus", Duration::from_millis(400)),
            "mismatched secret must be rejected with 403"
        );
        assert!(received.lock().unwrap().is_empty());

        assert!(
            !forward_url_to_endpoint(&endpoint, "https://example.com/not-menumijia", Duration::from_millis(400)),
            "non-menumijia scheme must be rejected"
        );

        let url = format!("menumijia://power?device=light.desk&on=true&token={}", "ab".repeat(32));
        assert!(
            forward_url_to_endpoint(&endpoint, &url, Duration::from_millis(400)),
            "valid secret and menumijia URL must succeed"
        );
        assert!(
            forward_activate_to_endpoint(&endpoint, Duration::from_millis(400)),
            "a bare second launch must reach the primary instance"
        );
        stop.store(true, Ordering::SeqCst);

        let got = received.lock().unwrap().clone();
        assert_eq!(got, vec![IpcRequest::OpenUrl(url), IpcRequest::Activate]);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn an_unauthenticated_head_is_refused_before_its_body_is_accepted() {
        let base = scratch_dir("unauth");
        let dir = base.join("MenuBarMijia");
        let received: Arc<Mutex<Vec<IpcRequest>>> = Arc::new(Mutex::new(Vec::new()));
        let received_sink = received.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let endpoint = spawn_ipc_server_in_dir(&dir, Some(stop.clone()), move |request| {
            received_sink.lock().unwrap().push(request);
        })
        .expect("spawn loopback IPC server");

        // The head announces a body the client never sends: authorization is decided from the head
        // alone, so the 403 arrives without waiting for those bytes.
        let status = send_raw(&endpoint, &request_head(None, IPC_OPEN_URL_ROUTE, 64));
        assert_eq!(status, "HTTP/1.1 403 Forbidden");
        assert!(received.lock().unwrap().is_empty(), "an unauthorized head dispatches nothing");

        let unknown = send_raw(&endpoint, &request_head(Some(endpoint.secret.as_str()), "/open-url-evil", 0));
        assert_eq!(unknown, "HTTP/1.1 404 Not Found");
        stop.store(true, Ordering::SeqCst);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_slow_drip_client_is_closed_with_408() {
        let base = scratch_dir("drip");
        let dir = base.join("MenuBarMijia");
        let stop = Arc::new(AtomicBool::new(false));
        let endpoint = spawn_ipc_server_in_dir(&dir, Some(stop.clone()), |_request| {})
            .expect("spawn loopback IPC server");

        let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
        let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(1000))
            .expect("connect dripper");
        // A head that never terminates: the handler must stop waiting on its own deadline.
        stream
            .write_all(b"POST /open-url HTTP/1.1\r\nHost: 127.0.0.1\r\n")
            .expect("write a partial head");
        let _ = stream.flush();

        let started = Instant::now();
        assert_eq!(read_status_line(&mut stream), "HTTP/1.1 408 Request Timeout");
        assert!(
            started.elapsed() < Duration::from_millis(IPC_CONNECTION_DEADLINE_MS + 1500),
            "the whole-connection deadline bounded the wait"
        );
        stop.store(true, Ordering::SeqCst);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn an_oversized_content_length_is_refused_with_413() {
        let base = scratch_dir("oversize");
        let dir = base.join("MenuBarMijia");
        let received: Arc<Mutex<Vec<IpcRequest>>> = Arc::new(Mutex::new(Vec::new()));
        let received_sink = received.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let endpoint = spawn_ipc_server_in_dir(&dir, Some(stop.clone()), move |request| {
            received_sink.lock().unwrap().push(request);
        })
        .expect("spawn loopback IPC server");

        let status = send_raw(
            &endpoint,
            &request_head(Some(endpoint.secret.as_str()), IPC_OPEN_URL_ROUTE, MAX_OPEN_URL_BYTES * 4),
        );
        assert_eq!(status, "HTTP/1.1 413 Payload Too Large");
        assert!(received.lock().unwrap().is_empty());
        stop.store(true, Ordering::SeqCst);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn the_activate_route_needs_the_secret_and_takes_no_body() {
        let base = scratch_dir("activate");
        let dir = base.join("MenuBarMijia");
        let received: Arc<Mutex<Vec<IpcRequest>>> = Arc::new(Mutex::new(Vec::new()));
        let received_sink = received.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let endpoint = spawn_ipc_server_in_dir(&dir, Some(stop.clone()), move |request| {
            received_sink.lock().unwrap().push(request);
        })
        .expect("spawn loopback IPC server");

        assert_eq!(
            send_raw(&endpoint, &request_head(None, IPC_ACTIVATE_ROUTE, 0)),
            "HTTP/1.1 403 Forbidden",
            "revealing the panel is as secret-gated as opening a URL"
        );
        assert_eq!(
            send_raw(&endpoint, &request_head(Some(endpoint.secret.as_str()), IPC_ACTIVATE_ROUTE, 2)),
            "HTTP/1.1 400 Bad Request",
            "an activate request carries no body"
        );
        assert!(received.lock().unwrap().is_empty());

        assert_eq!(
            send_raw(&endpoint, &request_head(Some(endpoint.secret.as_str()), IPC_ACTIVATE_ROUTE, 0)),
            "HTTP/1.1 200 OK"
        );
        assert_eq!(received.lock().unwrap().clone(), vec![IpcRequest::Activate]);
        stop.store(true, Ordering::SeqCst);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn extra_concurrent_clients_are_shed_with_503() {
        let base = scratch_dir("shed");
        let dir = base.join("MenuBarMijia");
        let stop = Arc::new(AtomicBool::new(false));
        let endpoint = spawn_ipc_server_in_dir(&dir, Some(stop.clone()), |_request| {})
            .expect("spawn loopback IPC server");
        let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));

        // Occupy every handler slot with a client that never completes its head.
        let mut held = Vec::new();
        for _ in 0..MAX_CONCURRENT_IPC_CLIENTS {
            let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(1000))
                .expect("connect a held client");
            stream
                .write_all(b"POST /open-url HTTP/1.1\r\nHost: 127.0.0.1\r\n")
                .expect("write a partial head");
            let _ = stream.flush();
            held.push(stream);
        }
        std::thread::sleep(Duration::from_millis(400));

        // The accept loop is a separate thread, so give it a few tries to see all held clients
        // before the excess one is judged.
        let mut status = String::new();
        for _ in 0..4 {
            match TcpStream::connect_timeout(&addr, Duration::from_millis(1000)) {
                Ok(mut extra) => {
                    status = read_status_line(&mut extra);
                    if status == "HTTP/1.1 503 Service Unavailable" {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(err) => panic!("connect the excess client: {err}"),
            }
        }
        assert_eq!(
            status, "HTTP/1.1 503 Service Unavailable",
            "a shelf of slow clients must never starve a real forward"
        );
        stop.store(true, Ordering::SeqCst);
        drop(held);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn forward_to_primary_instance_retries_until_the_endpoint_appears() {
        let base = scratch_dir("forward");
        let dir = base.join("MenuBarMijia");
        let received: Arc<Mutex<Vec<IpcRequest>>> = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let stop_for_server = stop.clone();
        let dir_for_server = dir.clone();
        let received_sink = received.clone();
        // A primary instance that is still starting: `ipc-endpoint.json` lands well after the
        // second launch begins its poll.
        let server = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(400));
            spawn_ipc_server_in_dir(&dir_for_server, Some(stop_for_server), move |request| {
                received_sink.lock().unwrap().push(request);
            })
            .expect("late IPC server")
        });

        assert!(
            forward_to_primary_instance(
                &dir,
                Some("menumijia://focus"),
                Duration::from_millis(4000),
                Duration::from_millis(350),
                Duration::from_millis(50),
            ),
            "the retry loop must land on the endpoint that appears later"
        );
        let _endpoint = server.join().expect("server thread");
        assert_eq!(
            received.lock().unwrap().clone(),
            vec![IpcRequest::OpenUrl("menumijia://focus".to_string())]
        );

        stop.store(true, Ordering::SeqCst);
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
