//! Single-process exit supervision, exponential backoff with jitter, circuit breaking,
//! and verifiable Windows process identity checks for the managed `go2rtc` helper (#424).

use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Go2RtcConfigRelativeFiles {
    config: String,
    owner: String,
    pid: String,
    log: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Go2RtcConfigSpec {
    schema_version: u32,
    relative_files: Go2RtcConfigRelativeFiles,
    forbidden_ports: Vec<u16>,
    allowed_modules: Vec<String>,
}

/// Single cross-platform source of truth for go2rtc module allow-list,
/// forbidden default ports, and relative config file names (#446).
static GO2RTC_CONFIG_SPEC: LazyLock<Go2RtcConfigSpec> = LazyLock::new(|| {
    let spec: Go2RtcConfigSpec =
        serde_json::from_str(include_str!("../../../Shared/go2rtcConfig.json"))
            .expect("Shared/go2rtcConfig.json must be valid JSON");
    assert_eq!(spec.schema_version, 1, "unsupported go2rtcConfig schemaVersion");
    spec
});

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Go2RtcPaths {
    pub(crate) bin_dir: PathBuf,
    pub(crate) config_file: PathBuf,
    pub(crate) owner_file: PathBuf,
    pub(crate) pid_file: PathBuf,
    pub(crate) log_file: PathBuf,
}

impl Go2RtcPaths {
    pub(crate) fn from_bin_dir(bin_dir: PathBuf) -> Self {
        let files = &GO2RTC_CONFIG_SPEC.relative_files;
        Self {
            config_file: bin_dir.join(&files.config),
            owner_file: bin_dir.join(&files.owner),
            pid_file: bin_dir.join(&files.pid),
            log_file: bin_dir.join(&files.log),
            bin_dir,
        }
    }

    pub(crate) fn discover() -> Result<Self, String> {
        let local = std::env::var("LOCALAPPDATA")
            .map_err(|_| "无法读取 LOCALAPPDATA 目录".to_string())?;
        Ok(Self::from_bin_dir(
            Path::new(&local).join("MenuBarMijia").join("bin"),
        ))
    }
}

pub(crate) fn go2rtc_allowed_modules() -> &'static [String] {
    &GO2RTC_CONFIG_SPEC.allowed_modules
}

pub(crate) fn go2rtc_forbidden_ports() -> &'static [u16] {
    &GO2RTC_CONFIG_SPEC.forbidden_ports
}

pub(crate) fn yaml_double_quoted(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' | '\r' => {}
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
}

pub(crate) fn is_acceptable_go2rtc_listen(value: &str) -> bool {
    let Some(port_text) = value.strip_prefix("127.0.0.1:") else {
        return false;
    };
    let Ok(port) = port_text.parse::<u16>() else {
        return false;
    };
    port > 0
        && !go2rtc_forbidden_ports().contains(&port)
        && value == format!("127.0.0.1:{port}")
}

pub(crate) fn sanitized_go2rtc_listen(value: &str) -> String {
    if is_acceptable_go2rtc_listen(value) {
        value.to_string()
    } else {
        "127.0.0.1:9".to_string()
    }
}

/// Renders `go2rtc.yaml` using the shared `app.modules` allow-list so macOS and
/// Windows generate identical security boundaries without leaking credentials
/// into supervisor diagnostics or event history (#446).
pub(crate) fn render_go2rtc_config(
    api_listen: &str,
    rtsp_listen: &str,
    username: &str,
    password: &str,
    nonce: &str,
    ffmpeg_bin: &str,
) -> String {
    let modules = go2rtc_allowed_modules()
        .iter()
        .map(|module| format!("    - {module}"))
        .collect::<Vec<_>>()
        .join("\n");
    let ffmpeg = yaml_double_quoted(ffmpeg_bin);
    let api = sanitized_go2rtc_listen(api_listen);
    let rtsp = sanitized_go2rtc_listen(rtsp_listen);
    format!(
        "app:\n  modules:\n{modules}\napi:\n  listen: {api}\n  username: {user}\n  password: {password}\n  local_auth: true\nrtsp:\n  listen: {rtsp}\nwebrtc:\n  listen: \"\"\nlog:\n  level: info\n  ffmpeg: error\nffmpeg:\n  bin: {ffmpeg}\nexec:\n  allow_paths:\n    - {ffmpeg}\nmenubarmijia:\n  nonce: {nonce}\n",
        user = yaml_double_quoted(username),
        password = yaml_double_quoted(password),
        nonce = yaml_double_quoted(nonce),
    )
}

pub(crate) const BACKOFF_MAX_SHIFT: u32 = 6;
pub(crate) const BACKOFF_CAP: Duration = Duration::from_secs(60);
pub(crate) const BREAKER_WINDOW: Duration = Duration::from_secs(120);
pub(crate) const BREAKER_THRESHOLD: usize = 5;
pub(crate) const STABLE_RESET_DURATION: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SupervisorDiagnostics {
    pub(crate) state: String,
    pub(crate) consecutive_failures: u32,
    pub(crate) recent_failures: usize,
    pub(crate) next_retry_ms: Option<u64>,
    pub(crate) last_exit_code: Option<i32>,
    pub(crate) last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SupervisorPhase {
    Stopped,
    Running { pid: u32, started_at: Duration },
    BackingOff { retry_after: Duration, attempt: u32 },
    CircuitOpen { recent_failures: usize },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExitDecision {
    RestartAfter(Duration),
    OpenCircuit,
}

/// Pure, synchronous state machine for single-process supervision.
pub(crate) struct SupervisorCore {
    phase: SupervisorPhase,
    recent_failures: VecDeque<Duration>,
    consecutive_failures: u32,
    last_exit_code: Option<i32>,
    last_error: Option<String>,
}

impl SupervisorCore {
    pub(crate) fn new() -> Self {
        Self {
            phase: SupervisorPhase::Stopped,
            recent_failures: VecDeque::new(),
            consecutive_failures: 0,
            last_exit_code: None,
            last_error: None,
        }
    }

    pub(crate) fn phase(&self) -> &SupervisorPhase {
        &self.phase
    }

    pub(crate) fn is_circuit_open(&self) -> bool {
        matches!(self.phase, SupervisorPhase::CircuitOpen { .. })
    }

    pub(crate) fn is_backing_off(&self) -> bool {
        matches!(self.phase, SupervisorPhase::BackingOff { .. })
    }

    pub(crate) fn check_can_start(&self) -> Result<(), String> {
        if self.is_circuit_open() {
            return Err(
                "本地流媒体服务 go2rtc 多次异常退出，已触发熔断保护，请关闭摄像机或点击重新连接以重置"
                    .to_string(),
            );
        }
        Ok(())
    }

    pub(crate) fn mark_started(&mut self, pid: u32, now: Duration) {
        self.phase = SupervisorPhase::Running {
            pid,
            started_at: now,
        };
        self.last_error = None;
    }

    pub(crate) fn record_exit<F>(
        &mut self,
        now: Duration,
        exit_code: Option<i32>,
        error: Option<String>,
        jitter: F,
    ) -> ExitDecision
    where
        F: Fn(Duration) -> Duration,
    {
        if let SupervisorPhase::Running { started_at, .. } = self.phase {
            if now.saturating_sub(started_at) >= STABLE_RESET_DURATION {
                self.consecutive_failures = 0;
                self.recent_failures.clear();
            }
        }
        self.last_exit_code = exit_code;
        self.last_error = error;
        self.record_failure(now, jitter)
    }

    pub(crate) fn record_launch_failure<F>(
        &mut self,
        now: Duration,
        error: String,
        jitter: F,
    ) -> ExitDecision
    where
        F: Fn(Duration) -> Duration,
    {
        self.last_error = Some(error);
        self.record_failure(now, jitter)
    }

    fn record_failure<F>(&mut self, now: Duration, jitter: F) -> ExitDecision
    where
        F: Fn(Duration) -> Duration,
    {
        while let Some(&oldest) = self.recent_failures.front() {
            if now.saturating_sub(oldest) >= BREAKER_WINDOW {
                self.recent_failures.pop_front();
            } else {
                break;
            }
        }
        self.recent_failures.push_back(now);
        if self.recent_failures.len() >= BREAKER_THRESHOLD {
            self.phase = SupervisorPhase::CircuitOpen {
                recent_failures: self.recent_failures.len(),
            };
            return ExitDecision::OpenCircuit;
        }
        let base_secs = 1u64 << self.consecutive_failures.min(BACKOFF_MAX_SHIFT);
        let delay = jitter(Duration::from_secs(base_secs)).min(BACKOFF_CAP);
        self.consecutive_failures = (self.consecutive_failures + 1).min(BACKOFF_MAX_SHIFT);
        self.phase = SupervisorPhase::BackingOff {
            retry_after: delay,
            attempt: self.consecutive_failures,
        };
        ExitDecision::RestartAfter(delay)
    }

    /// Explicit stop cancels any retry state and resets the circuit breaker.
    pub(crate) fn explicit_stop(&mut self) {
        self.phase = SupervisorPhase::Stopped;
        self.recent_failures.clear();
        self.consecutive_failures = 0;
        self.last_exit_code = None;
        self.last_error = None;
    }

    pub(crate) fn diagnostics(&self) -> SupervisorDiagnostics {
        let (state, next_retry_ms) = match self.phase {
            SupervisorPhase::Stopped => ("stopped", None),
            SupervisorPhase::Running { .. } => ("running", None),
            SupervisorPhase::BackingOff { retry_after, .. } => (
                "backingOff",
                Some(retry_after.as_millis().min(u64::MAX as u128) as u64),
            ),
            SupervisorPhase::CircuitOpen { .. } => ("circuitOpen", None),
        };
        SupervisorDiagnostics {
            state: state.to_string(),
            consecutive_failures: self.consecutive_failures,
            recent_failures: self.recent_failures.len(),
            next_retry_ms,
            last_exit_code: self.last_exit_code,
            last_error: self.last_error.clone(),
        }
    }
}

/// Applies +-20% jitter to `base`, clamped to `[100ms, 60s]`.
pub(crate) fn default_jitter(base: Duration) -> Duration {
    let mut bytes = [0u8; 2];
    let ratio = if SystemRandom::new().fill(&mut bytes).is_ok() {
        let sample = u16::from_le_bytes(bytes);
        0.80 + (f64::from(sample) / f64::from(u16::MAX)) * 0.40
    } else {
        1.0
    };
    let secs = (base.as_secs_f64() * ratio).max(0.1);
    Duration::from_secs_f64(secs).min(BACKOFF_CAP)
}

pub(crate) trait MonotonicClock: Send + Sync {
    fn now(&self) -> Duration;
    fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()> + Send + '_>>;
}

pub(crate) struct SystemMonotonicClock {
    origin: Instant,
}

impl SystemMonotonicClock {
    pub(crate) fn new() -> Self {
        Self {
            origin: Instant::now(),
        }
    }
}

impl MonotonicClock for SystemMonotonicClock {
    fn now(&self) -> Duration {
        self.origin.elapsed()
    }

    fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()> + Send + '_>> {
        Box::pin(tokio::time::sleep(duration))
    }
}

pub(crate) trait SupervisedChild: Send + Sync {
    fn pid(&self) -> u32;
    fn wait_exit(&self) -> Pin<Box<dyn Future<Output = Option<i32>> + Send + '_>>;
    fn stop(&self);
}

pub(crate) type BoxedChild = Box<dyn SupervisedChild>;
pub(crate) type ProcessLauncher =
    Arc<dyn Fn() -> Pin<Box<dyn Future<Output = Result<BoxedChild, String>> + Send>> + Send + Sync>;

/// Generic single-process async supervisor with injectable monotonic clock, jitter, and launcher.
#[allow(dead_code)]
pub(crate) struct AsyncProcessSupervisor<C: MonotonicClock + 'static> {
    clock: Arc<C>,
    jitter: Arc<dyn Fn(Duration) -> Duration + Send + Sync>,
    core: Arc<Mutex<SupervisorCore>>,
    stop_token: Mutex<Option<CancellationToken>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

#[allow(dead_code)]
impl<C: MonotonicClock + 'static> AsyncProcessSupervisor<C> {
    pub(crate) fn new<F>(clock: Arc<C>, jitter: F) -> Self
    where
        F: Fn(Duration) -> Duration + Send + Sync + 'static,
    {
        Self {
            clock,
            jitter: Arc::new(jitter),
            core: Arc::new(Mutex::new(SupervisorCore::new())),
            stop_token: Mutex::new(None),
            task: Mutex::new(None),
        }
    }

    pub(crate) fn diagnostics(&self) -> SupervisorDiagnostics {
        self.core
            .lock()
            .map(|guard| guard.diagnostics())
            .unwrap_or_else(|_| SupervisorDiagnostics {
                state: "stopped".to_string(),
                consecutive_failures: 0,
                recent_failures: 0,
                next_retry_ms: None,
                last_exit_code: None,
                last_error: None,
            })
    }

    pub(crate) fn start(
        &self,
        launcher: ProcessLauncher,
        external_cancel: CancellationToken,
    ) -> Result<(), String> {
        {
            let guard = self
                .core
                .lock()
                .map_err(|_| "进程监督器状态不可用".to_string())?;
            guard.check_can_start()?;
            if !matches!(guard.phase(), SupervisorPhase::Stopped) {
                return Ok(());
            }
        }
        let token = CancellationToken::new();
        if let Ok(mut guard) = self.stop_token.lock() {
            if let Some(prev) = guard.replace(token.clone()) {
                prev.cancel();
            }
        }

        let clock = Arc::clone(&self.clock);
        let jitter = Arc::clone(&self.jitter);
        let core = Arc::clone(&self.core);

        let handle = tokio::spawn(async move {
            loop {
                if token.is_cancelled() || external_cancel.is_cancelled() {
                    break;
                }
                let Some(launch_result) = token
                    .run_until_cancelled(external_cancel.run_until_cancelled(launcher()))
                    .await
                    .flatten()
                else {
                    break;
                };

                let decision = match launch_result {
                    Ok(child) => {
                        let pid = child.pid();
                        if let Ok(mut guard) = core.lock() {
                            guard.mark_started(pid, clock.now());
                        }
                        let Some(exit_outcome) = token
                            .run_until_cancelled(
                                external_cancel.run_until_cancelled(child.wait_exit()),
                            )
                            .await
                            .flatten()
                        else {
                            child.stop();
                            break;
                        };
                        if token.is_cancelled() || external_cancel.is_cancelled() {
                            break;
                        }
                        let Ok(mut guard) = core.lock() else {
                            break;
                        };
                        guard.record_exit(clock.now(), exit_outcome, None, |d| jitter(d))
                    }
                    Err(error) => {
                        if token.is_cancelled() || external_cancel.is_cancelled() {
                            break;
                        }
                        let Ok(mut guard) = core.lock() else {
                            break;
                        };
                        guard.record_launch_failure(clock.now(), error, |d| jitter(d))
                    }
                };

                match decision {
                    ExitDecision::OpenCircuit => break,
                    ExitDecision::RestartAfter(delay) => {
                        if token
                            .run_until_cancelled(
                                external_cancel.run_until_cancelled(clock.sleep(delay)),
                            )
                            .await
                            .flatten()
                            .is_none()
                        {
                            break;
                        }
                    }
                }
            }
        });

        if let Ok(mut guard) = self.task.lock() {
            *guard = Some(handle);
        }
        Ok(())
    }

    pub(crate) async fn stop(&self) {
        if let Ok(mut guard) = self.stop_token.lock() {
            if let Some(token) = guard.take() {
                token.cancel();
            }
        }
        let handle = self.task.lock().ok().and_then(|mut guard| guard.take());
        if let Some(handle) = handle {
            let _ = handle.await;
        }
        if let Ok(mut guard) = self.core.lock() {
            guard.explicit_stop();
        }
    }
}

/// Verifiable process identity: PID alone is insufficient because Windows recycles PIDs quickly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProcessIdentity {
    pub(crate) pid: u32,
    pub(crate) executable_path: String,
    pub(crate) creation_time_100ns: u64,
}

pub(crate) fn normalize_windows_path(path: &str) -> String {
    let trimmed = path.trim();
    let stripped = trimmed
        .strip_prefix(r"\\?\")
        .or_else(|| trimmed.strip_prefix(r"\??\"))
        .unwrap_or(trimmed);
    stripped.replace('/', "\\").to_ascii_lowercase()
}

/// Returns true only when PID, non-zero creation timestamp, and normalized executable path all match.
pub(crate) fn matches_process_identity(
    expected: &ProcessIdentity,
    actual: &ProcessIdentity,
) -> bool {
    expected.pid != 0
        && expected.pid == actual.pid
        && expected.creation_time_100ns != 0
        && expected.creation_time_100ns == actual.creation_time_100ns
        && !expected.executable_path.trim().is_empty()
        && normalize_windows_path(&expected.executable_path)
            == normalize_windows_path(&actual.executable_path)
}

#[cfg(windows)]
mod win32_process {
    use super::{matches_process_identity, ProcessIdentity};
    use core::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    const PROCESS_TERMINATE: u32 = 0x0001;
    const SYNCHRONIZE: u32 = 0x0010_0000;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const STILL_ACTIVE: u32 = 259;
    const WAIT_OBJECT_0: u32 = 0x0000_0000;
    const INFINITE: u32 = 0xFFFF_FFFF;

    #[repr(C)]
    #[derive(Default)]
    struct FileTime {
        dw_low_date_time: u32,
        dw_high_date_time: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn OpenProcess(access: u32, inherit: i32, pid: u32) -> isize;
        fn GetExitCodeProcess(handle: isize, code: *mut u32) -> i32;
        fn GetProcessTimes(
            handle: isize,
            creation: *mut FileTime,
            exit: *mut FileTime,
            kernel: *mut FileTime,
            user: *mut FileTime,
        ) -> i32;
        fn QueryFullProcessImageNameW(
            handle: isize,
            flags: u32,
            exe_name: *mut u16,
            size: *mut u32,
        ) -> i32;
        fn TerminateProcess(handle: isize, code: u32) -> i32;
        fn GetCurrentProcess() -> isize;
        fn DuplicateHandle(
            source_process: isize,
            source_handle: isize,
            target_process: isize,
            target_handle: *mut isize,
            desired_access: u32,
            inherit_handle: i32,
            options: u32,
        ) -> i32;
        fn CreateEventW(
            attributes: *const c_void,
            manual_reset: i32,
            initial_state: i32,
            name: *const u16,
        ) -> isize;
        fn SetEvent(event: isize) -> i32;
        fn WaitForMultipleObjects(
            count: u32,
            handles: *const isize,
            wait_all: i32,
            milliseconds: u32,
        ) -> u32;
        fn CloseHandle(handle: isize) -> i32;
    }

    struct OwnedHandle(isize);

    unsafe impl Send for OwnedHandle {}
    unsafe impl Sync for OwnedHandle {}

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            if self.0 != 0 {
                unsafe {
                    let _ = CloseHandle(self.0);
                }
            }
        }
    }

    fn inspect_handle(handle: isize, pid: u32) -> Option<ProcessIdentity> {
        if handle == 0 || pid == 0 {
            return None;
        }
        unsafe {
            let mut exit_code = 0u32;
            if GetExitCodeProcess(handle, &mut exit_code) == 0 || exit_code != STILL_ACTIVE {
                return None;
            }
            let mut creation = FileTime::default();
            let mut exit = FileTime::default();
            let mut kernel = FileTime::default();
            let mut user = FileTime::default();
            if GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) == 0 {
                return None;
            }
            let creation_time_100ns = ((creation.dw_high_date_time as u64) << 32)
                | (creation.dw_low_date_time as u64);
            if creation_time_100ns == 0 {
                return None;
            }
            let mut buf = vec![0u16; 32_768];
            let mut len = buf.len() as u32;
            if QueryFullProcessImageNameW(handle, 0, buf.as_mut_ptr(), &mut len) == 0 || len == 0 {
                return None;
            }
            let executable_path = String::from_utf16_lossy(&buf[..len as usize]);
            Some(ProcessIdentity {
                pid,
                executable_path,
                creation_time_100ns,
            })
        }
    }

    pub(crate) fn inspect_process_identity(pid: u32) -> Option<ProcessIdentity> {
        if pid == 0 {
            return None;
        }
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if handle == 0 {
            return None;
        }
        let _guard = OwnedHandle(handle);
        inspect_handle(handle, pid)
    }

    pub(crate) fn inspect_child_identity(child: &std::process::Child) -> Option<ProcessIdentity> {
        inspect_handle(child.as_raw_handle() as isize, child.id())
    }

    pub(crate) fn current_process_identity() -> Option<ProcessIdentity> {
        inspect_process_identity(std::process::id())
    }

    /// Opens a single handle, verifies executable path and creation time against `expected`,
    /// and terminates that exact process handle only if all checks pass.
    pub(crate) fn verify_and_terminate_process(expected: &ProcessIdentity) -> bool {
        if expected.pid == 0 || expected.creation_time_100ns == 0 {
            return false;
        }
        let handle = unsafe {
            OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE,
                0,
                expected.pid,
            )
        };
        if handle == 0 {
            return false;
        }
        let _guard = OwnedHandle(handle);
        let Some(actual) = inspect_handle(handle, expected.pid) else {
            return false;
        };
        if !matches_process_identity(expected, &actual) {
            return false;
        }
        unsafe { TerminateProcess(handle, 1) != 0 }
    }

    /// Cancels a blocking `ProcessExitWaiter` immediately when the parent stops the child.
    #[derive(Clone)]
    pub(crate) struct ProcessExitCancel {
        stop_event: Arc<OwnedHandle>,
        cancelled: Arc<AtomicBool>,
    }

    impl ProcessExitCancel {
        pub(crate) fn cancel(&self) {
            if !self.cancelled.swap(true, Ordering::SeqCst) {
                unsafe {
                    let _ = SetEvent(self.stop_event.0);
                }
            }
        }
    }

    /// Blocks on a duplicated process handle + cancel event without holding `GO2RTC_PROCESS`.
    pub(crate) struct ProcessExitWaiter {
        dup_process: OwnedHandle,
        stop_event: Arc<OwnedHandle>,
        cancelled: Arc<AtomicBool>,
    }

    impl ProcessExitWaiter {
        pub(crate) fn from_child(
            child: &std::process::Child,
        ) -> Result<(Self, ProcessExitCancel), String> {
            let mut dup: isize = 0;
            let ok = unsafe {
                let current = GetCurrentProcess();
                DuplicateHandle(
                    current,
                    child.as_raw_handle() as isize,
                    current,
                    &mut dup,
                    SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                    0,
                    0,
                )
            };
            if ok == 0 || dup == 0 {
                return Err("复制 go2rtc 进程监听句柄失败".to_string());
            }
            let dup_process = OwnedHandle(dup);
            let event = unsafe { CreateEventW(core::ptr::null(), 1, 0, core::ptr::null()) };
            if event == 0 {
                return Err("创建 go2rtc 退出监听事件失败".to_string());
            }
            let stop_event = Arc::new(OwnedHandle(event));
            let cancelled = Arc::new(AtomicBool::new(false));
            let cancel = ProcessExitCancel {
                stop_event: Arc::clone(&stop_event),
                cancelled: Arc::clone(&cancelled),
            };
            Ok((
                Self {
                    dup_process,
                    stop_event,
                    cancelled,
                },
                cancel,
            ))
        }

        /// Returns `None` if explicitly cancelled, or `Some(exit_code)` when the child exits.
        pub(crate) fn wait_blocking(self) -> Option<Option<i32>> {
            let handles = [self.dup_process.0, self.stop_event.0];
            let waited = unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, INFINITE) };
            if waited == WAIT_OBJECT_0 && !self.cancelled.load(Ordering::SeqCst) {
                let mut code = 0u32;
                let ok = unsafe { GetExitCodeProcess(self.dup_process.0, &mut code) };
                let exit_code = (ok != 0 && code != STILL_ACTIVE).then_some(code as i32);
                Some(exit_code)
            } else {
                None
            }
        }
    }
}

#[cfg(windows)]
pub(crate) use win32_process::{
    current_process_identity, inspect_child_identity, inspect_process_identity,
    verify_and_terminate_process, ProcessExitCancel, ProcessExitWaiter,
};

#[cfg(not(windows))]
#[allow(dead_code)]
pub(crate) fn inspect_process_identity(_pid: u32) -> Option<ProcessIdentity> {
    None
}

#[cfg(not(windows))]
#[allow(dead_code)]
pub(crate) fn inspect_child_identity(_child: &std::process::Child) -> Option<ProcessIdentity> {
    None
}

#[cfg(not(windows))]
#[allow(dead_code)]
pub(crate) fn current_process_identity() -> Option<ProcessIdentity> {
    None
}

#[cfg(not(windows))]
#[allow(dead_code)]
pub(crate) fn verify_and_terminate_process(_expected: &ProcessIdentity) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU32;
    use tokio::sync::{oneshot, Notify};

    struct FakeClockInner {
        now: Duration,
        waiters: Vec<(Duration, oneshot::Sender<()>)>,
    }

    struct FakeClock {
        inner: Mutex<FakeClockInner>,
        waiter_registered: Notify,
    }

    impl FakeClock {
        fn new() -> Self {
            Self {
                inner: Mutex::new(FakeClockInner {
                    now: Duration::ZERO,
                    waiters: Vec::new(),
                }),
                waiter_registered: Notify::new(),
            }
        }

        fn advance(&self, delta: Duration) {
            let to_wake = {
                let mut guard = self.inner.lock().unwrap();
                guard.now += delta;
                let now = guard.now;
                let mut ready = Vec::new();
                let mut remaining = Vec::new();
                for (deadline, tx) in guard.waiters.drain(..) {
                    if deadline <= now {
                        ready.push(tx);
                    } else {
                        remaining.push((deadline, tx));
                    }
                }
                guard.waiters = remaining;
                ready
            };
            for tx in to_wake {
                let _ = tx.send(());
            }
        }

        async fn wait_for_sleeper(&self) {
            loop {
                if !self.inner.lock().unwrap().waiters.is_empty() {
                    return;
                }
                self.waiter_registered.notified().await;
            }
        }
    }

    impl MonotonicClock for FakeClock {
        fn now(&self) -> Duration {
            self.inner.lock().unwrap().now
        }

        fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()> + Send + '_>> {
            let (tx, rx) = oneshot::channel();
            {
                let mut guard = self.inner.lock().unwrap();
                let deadline = guard.now + duration;
                if deadline <= guard.now {
                    let _ = tx.send(());
                } else {
                    guard.waiters.push((deadline, tx));
                }
            }
            self.waiter_registered.notify_waiters();
            Box::pin(async move {
                let _ = rx.await;
            })
        }
    }

    struct FakeChild {
        pid: u32,
        exit_rx: Mutex<Option<oneshot::Receiver<Option<i32>>>>,
        stopped: Arc<AtomicBool>,
    }

    impl SupervisedChild for FakeChild {
        fn pid(&self) -> u32 {
            self.pid
        }

        fn wait_exit(&self) -> Pin<Box<dyn Future<Output = Option<i32>> + Send + '_>> {
            let rx = self.exit_rx.lock().unwrap().take();
            Box::pin(async move {
                match rx {
                    Some(rx) => rx.await.ok().flatten(),
                    None => None,
                }
            })
        }

        fn stop(&self) {
            self.stopped.store(true, Ordering::SeqCst);
        }
    }

    #[test]
    fn pure_backoff_doubles_caps_at_60s_and_trips_breaker_on_fifth_failure_in_two_minutes() {
        let mut core = SupervisorCore::new();
        let identity = |d: Duration| d;

        core.mark_started(101, Duration::from_secs(0));
        assert_eq!(
            core.record_exit(Duration::from_secs(5), Some(1), None, identity),
            ExitDecision::RestartAfter(Duration::from_secs(1))
        );
        core.mark_started(102, Duration::from_secs(6));
        assert_eq!(
            core.record_exit(Duration::from_secs(10), Some(1), None, identity),
            ExitDecision::RestartAfter(Duration::from_secs(2))
        );
        core.mark_started(103, Duration::from_secs(12));
        assert_eq!(
            core.record_exit(Duration::from_secs(15), Some(1), None, identity),
            ExitDecision::RestartAfter(Duration::from_secs(4))
        );
        core.mark_started(104, Duration::from_secs(19));
        assert_eq!(
            core.record_exit(Duration::from_secs(20), Some(1), None, identity),
            ExitDecision::RestartAfter(Duration::from_secs(8))
        );
        core.mark_started(105, Duration::from_secs(28));
        assert_eq!(
            core.record_exit(Duration::from_secs(30), Some(1), None, identity),
            ExitDecision::OpenCircuit
        );
        assert!(core.is_circuit_open());
        assert!(core.check_can_start().is_err());

        // Explicit stop resets the circuit breaker and backoff count.
        core.explicit_stop();
        assert!(!core.is_circuit_open());
        assert!(core.check_can_start().is_ok());
        core.mark_started(106, Duration::from_secs(31));
        assert_eq!(
            core.record_exit(Duration::from_secs(32), Some(2), None, identity),
            ExitDecision::RestartAfter(Duration::from_secs(1))
        );
    }

    #[test]
    fn pure_backoff_caps_at_60s_and_resets_after_five_minutes_stable_run() {
        let mut core = SupervisorCore::new();
        let identity = |d: Duration| d;
        // Space failures 40s apart so the 120s window never holds 5 failures simultaneously.
        let expected_secs = [1, 2, 4, 8, 16, 32, 60, 60];
        let mut t = Duration::ZERO;
        for secs in expected_secs {
            core.mark_started(200, t);
            t += Duration::from_secs(40);
            assert_eq!(
                core.record_exit(t, Some(1), None, identity),
                ExitDecision::RestartAfter(Duration::from_secs(secs))
            );
        }

        // Now run stably for 5 minutes (300s): backoff resets to 1s.
        core.mark_started(201, t);
        t += Duration::from_secs(300);
        assert_eq!(
            core.record_exit(t, Some(1), None, identity),
            ExitDecision::RestartAfter(Duration::from_secs(1))
        );
    }

    #[test]
    fn default_jitter_stays_within_bounds_and_cap() {
        for _ in 0..32 {
            let d = default_jitter(Duration::from_secs(10));
            assert!(d >= Duration::from_secs(8) && d <= Duration::from_secs(12), "{d:?}");
            let capped = default_jitter(Duration::from_secs(64));
            assert!(capped <= BACKOFF_CAP, "{capped:?}");
        }
    }

    #[test]
    fn process_identity_requires_pid_path_and_creation_time() {
        let expected = ProcessIdentity {
            pid: 4242,
            executable_path: r"C:\Users\Alice\AppData\Local\MenuBarMijia\bin\go2rtc.exe"
                .to_string(),
            creation_time_100ns: 133_500_000_000_000_000,
        };
        let matching_verbatim = ProcessIdentity {
            pid: 4242,
            executable_path: r"\\?\c:\users\alice\appdata\local\menubarmijia\bin\go2rtc.exe"
                .to_string(),
            creation_time_100ns: 133_500_000_000_000_000,
        };
        assert!(matches_process_identity(&expected, &matching_verbatim));

        // Recycled PID with a different creation time must be rejected.
        let different_time = ProcessIdentity {
            creation_time_100ns: expected.creation_time_100ns + 1,
            ..matching_verbatim.clone()
        };
        assert!(!matches_process_identity(&expected, &different_time));

        // Recycled PID with a different executable path must be rejected.
        let different_path = ProcessIdentity {
            executable_path: r"C:\Windows\System32\notepad.exe".to_string(),
            ..matching_verbatim.clone()
        };
        assert!(!matches_process_identity(&expected, &different_path));

        // Zero creation time (unverifiable) must be rejected.
        let zero_time = ProcessIdentity {
            creation_time_100ns: 0,
            ..expected.clone()
        };
        assert!(!matches_process_identity(&zero_time, &zero_time));
    }

    #[test]
    fn async_supervisor_restarts_opens_breaker_resets_after_stable_run_and_cancels() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build test runtime");

        rt.block_on(async {
            let clock = Arc::new(FakeClock::new());
            let supervisor = AsyncProcessSupervisor::new(Arc::clone(&clock), |d| d);

            let launches = Arc::new(AtomicU32::new(0));
            let exit_senders: Arc<Mutex<Vec<oneshot::Sender<Option<i32>>>>> =
                Arc::new(Mutex::new(Vec::new()));
            let launch_notify = Arc::new(Notify::new());

            let launcher: ProcessLauncher = {
                let launches = Arc::clone(&launches);
                let exit_senders = Arc::clone(&exit_senders);
                let launch_notify = Arc::clone(&launch_notify);
                Arc::new(move || {
                    let launches = Arc::clone(&launches);
                    let exit_senders = Arc::clone(&exit_senders);
                    let launch_notify = Arc::clone(&launch_notify);
                    Box::pin(async move {
                        let pid = 1000 + launches.fetch_add(1, Ordering::SeqCst);
                        let (tx, rx) = oneshot::channel();
                        exit_senders.lock().unwrap().push(tx);
                        launch_notify.notify_waiters();
                        Ok(Box::new(FakeChild {
                            pid,
                            exit_rx: Mutex::new(Some(rx)),
                            stopped: Arc::new(AtomicBool::new(false)),
                        }) as BoxedChild)
                    })
                })
            };

            let cancel = CancellationToken::new();
            supervisor
                .start(Arc::clone(&launcher), cancel.clone())
                .expect("initial start");

            // Wait for launch #1, then crash 5 times within 2 minutes -> circuit opens.
            for expected_attempt in 1..=5u32 {
                while launches.load(Ordering::SeqCst) < expected_attempt {
                    launch_notify.notified().await;
                }
                clock.advance(Duration::from_secs(1));
                let tx = exit_senders.lock().unwrap().pop().expect("exit sender");
                let _ = tx.send(Some(1));
                if expected_attempt < 5 {
                    clock.wait_for_sleeper().await;
                    assert_eq!(supervisor.diagnostics().state, "backingOff");
                    let expected_delay = Duration::from_secs(1u64 << (expected_attempt - 1));
                    assert_eq!(
                        supervisor.diagnostics().next_retry_ms,
                        Some(expected_delay.as_millis() as u64)
                    );
                    clock.advance(expected_delay);
                }
            }

            // Give the 5th exit a tick to settle into circuitOpen.
            for _ in 0..10 {
                if supervisor.diagnostics().state == "circuitOpen" {
                    break;
                }
                tokio::task::yield_now().await;
            }
            assert_eq!(supervisor.diagnostics().state, "circuitOpen");
            assert!(supervisor
                .start(Arc::clone(&launcher), cancel.clone())
                .is_err());

            // Explicit stop resets the circuit breaker.
            supervisor.stop().await;
            assert_eq!(supervisor.diagnostics().state, "stopped");

            // Start again, run stably for 5 minutes, crash -> delay resets to 1s, then cancel during backoff.
            let cancel2 = CancellationToken::new();
            supervisor
                .start(Arc::clone(&launcher), cancel2.clone())
                .expect("restart after explicit stop");
            while launches.load(Ordering::SeqCst) < 6 {
                launch_notify.notified().await;
            }
            clock.advance(Duration::from_secs(300));
            let tx = exit_senders.lock().unwrap().pop().expect("exit sender");
            let _ = tx.send(Some(2));
            clock.wait_for_sleeper().await;
            assert_eq!(supervisor.diagnostics().state, "backingOff");
            assert_eq!(supervisor.diagnostics().next_retry_ms, Some(1000));

            // External cancellation aborts the pending restart without spawning another child.
            cancel2.cancel();
            clock.advance(Duration::from_secs(10));
            tokio::task::yield_now().await;
            assert_eq!(launches.load(Ordering::SeqCst), 6);
        });
    }

    #[test]
    fn go2rtc_config_spec_loads_shared_allowlist_and_paths() {
        let modules = go2rtc_allowed_modules();
        assert!(modules.iter().any(|m| m == "api"));
        assert!(modules.iter().any(|m| m == "xiaomi"));
        assert!(modules.iter().any(|m| m == "exec"));
        assert!(modules.iter().any(|m| m == "ffmpeg"));
        assert!(!modules.iter().any(|m| matches!(m.as_str(), "echo" | "expr" | "debug")));

        let paths = Go2RtcPaths::from_bin_dir(PathBuf::from(r"C:\MenuBarMijia\bin"));
        assert_eq!(paths.config_file, PathBuf::from(r"C:\MenuBarMijia\bin\go2rtc.yaml"));
        assert_eq!(paths.owner_file, PathBuf::from(r"C:\MenuBarMijia\bin\go2rtc.owner"));
        assert_eq!(paths.pid_file, PathBuf::from(r"C:\MenuBarMijia\bin\go2rtc.pid"));
        assert_eq!(paths.log_file, PathBuf::from(r"C:\MenuBarMijia\bin\go2rtc.log"));

        let rendered = render_go2rtc_config(
            "127.0.0.1:43123",
            "127.0.0.1:43124",
            "muser0001",
            "mpass0001",
            "mnonce0001",
            "C:/bin/ffmpeg-silent.exe",
        );
        assert!(rendered.starts_with("app:\n  modules:\n    - api\n"));
        assert!(rendered.contains("    - exec\n"));
        assert!(!rendered.contains("    - echo\n"));
    }
}
