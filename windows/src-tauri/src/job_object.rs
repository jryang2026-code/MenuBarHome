//! Binds managed helper daemons (`go2rtc.exe` and its spawned `ffmpeg` child) to a Windows Job
//! Object with hard resource quotas (per-process and job-wide committed memory limits, CPU rate
//! hard cap, active process cap, `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, and
//! `JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION`) so a runaway or crashing helper cannot OOM,
//! burn CPU, fork-bomb, hang on an unhandled-exception dialog, or leak orphaned processes.

/// Default per-process committed memory limit (128 MiB, Roadmap P1-8 / Report 10 §4.5).
pub(crate) const DEFAULT_PROCESS_MEMORY_BYTES: usize = 128 * 1024 * 1024;
/// Default aggregate job committed memory limit (192 MiB, Report 10 §4.5).
pub(crate) const DEFAULT_JOB_MEMORY_BYTES: usize = 192 * 1024 * 1024;
/// Default hard CPU cap as a percentage of total CPU cycles (20%, `CpuRate = 2000`).
pub(crate) const DEFAULT_CPU_RATE_PERCENT: u8 = 20;
/// Default active process cap (`go2rtc.exe` + 1 `ffmpeg` child = 2).
pub(crate) const DEFAULT_ACTIVE_PROCESS_LIMIT: u32 = 2;

const MIN_PROCESS_MEMORY_BYTES: usize = 16 * 1024 * 1024;
const CPU_RATE_SCALE_PER_PERCENT: u32 = 100;
const MIN_CPU_RATE_PERCENT: u8 = 1;
const MAX_CPU_RATE_PERCENT: u8 = 100;
const MEMORY_BREACH_THRESHOLD_PERCENT: usize = 95;

// Win32 `JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags` constants (`winnt.h`).
pub(crate) const JOB_OBJECT_LIMIT_ACTIVE_PROCESS: u32 = 0x0000_0008;
pub(crate) const JOB_OBJECT_LIMIT_PROCESS_MEMORY: u32 = 0x0000_0100;
pub(crate) const JOB_OBJECT_LIMIT_JOB_MEMORY: u32 = 0x0000_0200;
pub(crate) const JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION: u32 = 0x0000_0400;
pub(crate) const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;

// Win32 `JOBOBJECT_CPU_RATE_CONTROL_INFORMATION.ControlFlags` constants (`winnt.h`).
pub(crate) const JOB_OBJECT_CPU_RATE_CONTROL_ENABLE: u32 = 0x0000_0001;
pub(crate) const JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP: u32 = 0x0000_0004;

// Common Windows NTSTATUS exit codes for memory/quota/unhandled-exception termination.
const STATUS_ACCESS_VIOLATION: u32 = 0xC000_0005;
const STATUS_NO_MEMORY: u32 = 0xC000_0017;
const STATUS_QUOTA_EXCEEDED: u32 = 0xC000_0044;
const STATUS_STACK_OVERFLOW: u32 = 0xC000_00FD;
const STATUS_COMMITMENT_LIMIT: u32 = 0xC000_012D;
const STATUS_STACK_BUFFER_OVERRUN: u32 = 0xC000_0409;

/// Configurable hard resource limits applied to a managed Windows Job Object.
///
/// Both `go2rtc.exe` and its child `ffmpeg` process inherit the same Job Object. Report 10 §4.5
/// specifies 128 MiB per-process / 192 MiB job-wide, 20% CPU hard cap, and 2 active processes as
/// the default camera helper quota; callers may supply a custom struct when a workload requires
/// different bounds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct JobHardLimits {
    pub(crate) process_memory_bytes: usize,
    pub(crate) job_memory_bytes: Option<usize>,
    pub(crate) cpu_rate_percent: u8,
    pub(crate) active_process_limit: u32,
}

impl JobHardLimits {
    pub(crate) const fn camera_default() -> Self {
        Self {
            process_memory_bytes: DEFAULT_PROCESS_MEMORY_BYTES,
            job_memory_bytes: Some(DEFAULT_JOB_MEMORY_BYTES),
            cpu_rate_percent: DEFAULT_CPU_RATE_PERCENT,
            active_process_limit: DEFAULT_ACTIVE_PROCESS_LIMIT,
        }
    }
}

/// Validated, Win32-ready limit values derived from [`JobHardLimits`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ComputedJobLimits {
    pub(crate) extended_limit_flags: u32,
    pub(crate) process_memory_limit: usize,
    pub(crate) job_memory_limit: usize,
    pub(crate) active_process_limit: u32,
    pub(crate) cpu_control_flags: u32,
    pub(crate) cpu_rate: u32,
}

/// Peak memory counters queried from a live Job Object before its handle is closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct JobUsageSnapshot {
    pub(crate) peak_process_memory_bytes: usize,
    pub(crate) peak_job_memory_bytes: usize,
}

/// Converts a percentage (`1..=100`, clamped) into Win32 `CpuRate` units (cycles per 10,000).
pub(crate) fn compute_cpu_rate(percent: u8) -> u32 {
    let clamped = percent.clamp(MIN_CPU_RATE_PERCENT, MAX_CPU_RATE_PERCENT);
    u32::from(clamped) * CPU_RATE_SCALE_PER_PERCENT
}

/// Pure calculation of Win32 Job Object extended-limit and CPU-rate fields from [`JobHardLimits`].
pub(crate) fn compute_job_limits(limits: JobHardLimits) -> ComputedJobLimits {
    let process_memory_limit = limits.process_memory_bytes.max(MIN_PROCESS_MEMORY_BYTES);
    let active_process_limit = limits.active_process_limit.max(1);
    let mut extended_limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
        | JOB_OBJECT_LIMIT_PROCESS_MEMORY
        | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    let job_memory_limit = match limits.job_memory_bytes {
        Some(job_mem) => {
            extended_limit_flags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
            job_mem.max(process_memory_limit)
        }
        None => 0,
    };
    let cpu_control_flags =
        JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
    let cpu_rate = compute_cpu_rate(limits.cpu_rate_percent);
    ComputedJobLimits {
        extended_limit_flags,
        process_memory_limit,
        job_memory_limit,
        active_process_limit,
        cpu_control_flags,
        cpu_rate,
    }
}

fn bytes_to_mib(bytes: usize) -> usize {
    bytes / (1024 * 1024)
}

fn format_exit_code(exit_code: Option<i32>) -> String {
    match exit_code {
        Some(code) => {
            let raw = code as u32;
            if raw >= 0x8000_0000 {
                format!("0x{raw:08X}")
            } else {
                format!("{code}")
            }
        }
        None => "未知".to_string(),
    }
}

/// Classifies a helper exit into a sanitized diagnostic message without URLs or credentials.
pub(crate) fn classify_helper_exit_reason(
    exit_code: Option<i32>,
    limits: ComputedJobLimits,
    usage: Option<JobUsageSnapshot>,
) -> String {
    let code_label = format_exit_code(exit_code);
    let raw_code = exit_code.map(|code| code as u32);
    let proc_limit_mib = bytes_to_mib(limits.process_memory_limit);
    let job_limit_mib = bytes_to_mib(limits.job_memory_limit);

    if matches!(raw_code, Some(STATUS_COMMITMENT_LIMIT | STATUS_NO_MEMORY)) {
        return format!(
            "go2rtc 子进程因超出内存硬限中止（退出码 {code_label}，单进程上限 {proc_limit_mib} MB）"
        );
    }

    if raw_code == Some(STATUS_QUOTA_EXCEEDED) {
        return format!(
            "go2rtc 子进程因超出 Job Object 配额中止（退出码 {code_label}，活动进程上限 {}）",
            limits.active_process_limit
        );
    }

    if let Some(snapshot) = usage {
        if limits.job_memory_limit > 0
            && snapshot.peak_job_memory_bytes
                >= limits
                    .job_memory_limit
                    .saturating_mul(MEMORY_BREACH_THRESHOLD_PERCENT)
                    / 100
        {
            return format!(
                "go2rtc 进程组峰值内存触及硬限并退出（峰值 {} MB / 上限 {job_limit_mib} MB，退出码 {code_label}）",
                bytes_to_mib(snapshot.peak_job_memory_bytes)
            );
        }
        if snapshot.peak_process_memory_bytes
            >= limits
                .process_memory_limit
                .saturating_mul(MEMORY_BREACH_THRESHOLD_PERCENT)
                / 100
        {
            return format!(
                "go2rtc 单进程峰值内存触及硬限并退出（峰值 {} MB / 上限 {proc_limit_mib} MB，退出码 {code_label}）",
                bytes_to_mib(snapshot.peak_process_memory_bytes)
            );
        }
    }

    if let Some(raw) = raw_code {
        if matches!(
            raw,
            STATUS_ACCESS_VIOLATION | STATUS_STACK_OVERFLOW | STATUS_STACK_BUFFER_OVERRUN
        ) || (0xC000_0000..=0xCFFF_FFFF).contains(&raw)
        {
            return format!("go2rtc 子进程发生未处理异常中止（退出码 {code_label}）");
        }
    }

    format!("go2rtc 子进程异常退出（退出码 {code_label}）")
}

/// Emits a sanitized Job Object diagnostic line to the Windows debug output stream.
pub(crate) fn log_sanitized_reason(reason: &str) {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Diagnostics::Debug::OutputDebugStringW;

        let line: Vec<u16> = format!("[MenuBarHome][job_object] {reason}\n")
            .encode_utf16()
            .chain([0])
            .collect();
        unsafe { OutputDebugStringW(line.as_ptr()) };
    }
    #[cfg(not(windows))]
    {
        let _ = reason;
    }
}

#[cfg(windows)]
mod imp {
    use super::{ComputedJobLimits, JobUsageSnapshot};
    use core::ffi::c_void;
    use std::os::windows::io::AsRawHandle;

    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: i32 = 9;
    const JOB_OBJECT_CPU_RATE_CONTROL_INFORMATION_CLASS: i32 = 15;

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectBasicLimitInformation {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectExtendedLimitInformation {
        basic_limit_information: JobObjectBasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectCpuRateControlInformation {
        control_flags: u32,
        cpu_rate: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> isize;
        fn SetInformationJobObject(
            job: isize,
            info_class: i32,
            info: *const c_void,
            info_len: u32,
        ) -> i32;
        fn QueryInformationJobObject(
            job: isize,
            info_class: i32,
            info: *mut c_void,
            info_len: u32,
            return_len: *mut u32,
        ) -> i32;
        fn AssignProcessToJobObject(job: isize, process: isize) -> i32;
        fn CloseHandle(handle: isize) -> i32;
    }

    /// `GetLastError` code of the Win32 call that just failed.
    fn last_error_code() -> Option<i32> {
        std::io::Error::last_os_error().raw_os_error()
    }

    fn win32_error_text(code: Option<i32>) -> String {
        match code {
            Some(code) => format!(
                "{}（Win32 错误码 {code}）",
                std::io::Error::from_raw_os_error(code)
            ),
            None => "无法读取 Win32 错误码".to_string(),
        }
    }

    fn create_hard_limited_job(computed: ComputedJobLimits) -> Result<isize, String> {
        unsafe {
            let job = CreateJobObjectW(core::ptr::null(), core::ptr::null());
            if job == 0 {
                return Err(format!(
                    "创建 Job Object 失败：{}",
                    win32_error_text(last_error_code())
                ));
            }

            let mut info = JobObjectExtendedLimitInformation::default();
            info.basic_limit_information.limit_flags = computed.extended_limit_flags;
            info.basic_limit_information.active_process_limit = computed.active_process_limit;
            info.process_memory_limit = computed.process_memory_limit;
            info.job_memory_limit = computed.job_memory_limit;

            let configured_limits = SetInformationJobObject(
                job,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                (&info as *const JobObjectExtendedLimitInformation).cast::<c_void>(),
                core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
            );
            if configured_limits == 0 {
                let detail = win32_error_text(last_error_code());
                let _ = CloseHandle(job);
                return Err(format!("设置 Job Object 内存与进程硬限失败：{detail}"));
            }

            let cpu_info = JobObjectCpuRateControlInformation {
                control_flags: computed.cpu_control_flags,
                cpu_rate: computed.cpu_rate,
            };
            let configured_cpu = SetInformationJobObject(
                job,
                JOB_OBJECT_CPU_RATE_CONTROL_INFORMATION_CLASS,
                (&cpu_info as *const JobObjectCpuRateControlInformation).cast::<c_void>(),
                core::mem::size_of::<JobObjectCpuRateControlInformation>() as u32,
            );
            if configured_cpu == 0 {
                let detail = win32_error_text(last_error_code());
                let _ = CloseHandle(job);
                return Err(format!("设置 Job Object CPU 硬限失败：{detail}"));
            }

            Ok(job)
        }
    }

    pub(super) fn bind_child(
        child: &std::process::Child,
        computed: ComputedJobLimits,
    ) -> Result<Job, String> {
        let job = Job(create_hard_limited_job(computed)?);
        let assigned = unsafe { AssignProcessToJobObject(job.0, child.as_raw_handle() as isize) };
        if assigned == 0 {
            // Read `GetLastError` before another Win32 call could overwrite it.
            return Err(assign_failure_message(last_error_code()));
        }
        Ok(job)
    }

    pub(crate) struct Job(isize);

    impl Job {
        pub(super) fn query_usage(&self) -> Option<JobUsageSnapshot> {
            let mut info = JobObjectExtendedLimitInformation::default();
            let mut return_len = 0u32;
            let ok = unsafe {
                QueryInformationJobObject(
                    self.0,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    (&mut info as *mut JobObjectExtendedLimitInformation).cast::<c_void>(),
                    core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
                    &mut return_len,
                )
            };
            if ok == 0 {
                return None;
            }
            Some(JobUsageSnapshot {
                peak_process_memory_bytes: info.peak_process_memory_used,
                peak_job_memory_bytes: info.peak_job_memory_used,
            })
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            unsafe { CloseHandle(self.0) };
        }
    }

    /// Pure mapping so the fail-closed error path is unit-testable without a live child process.
    fn assign_failure_message(code: Option<i32>) -> String {
        format!(
            "将子进程加入 Job Object 失败：{}",
            win32_error_text(code)
        )
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::job_object::{
            compute_job_limits, JobHardLimits, DEFAULT_ACTIVE_PROCESS_LIMIT,
            DEFAULT_JOB_MEMORY_BYTES, DEFAULT_PROCESS_MEMORY_BYTES,
            JOB_OBJECT_CPU_RATE_CONTROL_ENABLE, JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP,
            JOB_OBJECT_LIMIT_ACTIVE_PROCESS, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
            JOB_OBJECT_LIMIT_JOB_MEMORY, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOB_OBJECT_LIMIT_PROCESS_MEMORY,
        };

        #[test]
        fn hard_limited_job_initializes_and_queries_back_limits_on_windows() {
            let computed = compute_job_limits(JobHardLimits::camera_default());
            let job = Job(create_hard_limited_job(computed).expect("create hard-limited job"));

            let mut queried_ext = JobObjectExtendedLimitInformation::default();
            let mut return_len = 0u32;
            let ext_ok = unsafe {
                QueryInformationJobObject(
                    job.0,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    (&mut queried_ext as *mut JobObjectExtendedLimitInformation).cast::<c_void>(),
                    core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
                    &mut return_len,
                )
            };
            assert_ne!(ext_ok, 0, "QueryInformationJobObject extended limits");
            let flags = queried_ext.basic_limit_information.limit_flags;
            assert_ne!(flags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, 0);
            assert_ne!(flags & JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION, 0);
            assert_ne!(flags & JOB_OBJECT_LIMIT_PROCESS_MEMORY, 0);
            assert_ne!(flags & JOB_OBJECT_LIMIT_JOB_MEMORY, 0);
            assert_ne!(flags & JOB_OBJECT_LIMIT_ACTIVE_PROCESS, 0);
            assert_eq!(
                queried_ext.basic_limit_information.active_process_limit,
                DEFAULT_ACTIVE_PROCESS_LIMIT
            );
            assert_eq!(
                queried_ext.process_memory_limit,
                DEFAULT_PROCESS_MEMORY_BYTES
            );
            assert_eq!(queried_ext.job_memory_limit, DEFAULT_JOB_MEMORY_BYTES);

            let mut queried_cpu = JobObjectCpuRateControlInformation::default();
            let mut cpu_return_len = 0u32;
            let cpu_ok = unsafe {
                QueryInformationJobObject(
                    job.0,
                    JOB_OBJECT_CPU_RATE_CONTROL_INFORMATION_CLASS,
                    (&mut queried_cpu as *mut JobObjectCpuRateControlInformation).cast::<c_void>(),
                    core::mem::size_of::<JobObjectCpuRateControlInformation>() as u32,
                    &mut cpu_return_len,
                )
            };
            assert_ne!(cpu_ok, 0, "QueryInformationJobObject CPU rate control");
            assert_eq!(
                queried_cpu.control_flags
                    & (JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP),
                JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP
            );
            assert_eq!(queried_cpu.cpu_rate, 2000);
            assert!(job.query_usage().is_some());
        }

        #[test]
        fn custom_job_limits_without_job_memory_cap_initializes_on_windows() {
            let computed = compute_job_limits(JobHardLimits {
                process_memory_bytes: 256 * 1024 * 1024,
                job_memory_bytes: None,
                cpu_rate_percent: 35,
                active_process_limit: 3,
            });
            let job = Job(create_hard_limited_job(computed).expect("create custom job"));
            let mut queried_ext = JobObjectExtendedLimitInformation::default();
            let mut return_len = 0u32;
            let ok = unsafe {
                QueryInformationJobObject(
                    job.0,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    (&mut queried_ext as *mut JobObjectExtendedLimitInformation).cast::<c_void>(),
                    core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
                    &mut return_len,
                )
            };
            assert_ne!(ok, 0);
            assert_eq!(
                queried_ext.basic_limit_information.limit_flags & JOB_OBJECT_LIMIT_JOB_MEMORY,
                0
            );
            assert_eq!(queried_ext.process_memory_limit, 256 * 1024 * 1024);
            assert_eq!(queried_ext.basic_limit_information.active_process_limit, 3);
        }

        #[test]
        fn assign_failure_message_carries_the_win32_error_code() {
            let denied = assign_failure_message(Some(5));
            assert!(denied.contains("Win32 错误码 5"), "{denied}");
            assert!(denied.contains("Job Object"), "{denied}");
            let unknown = assign_failure_message(None);
            assert!(unknown.contains("无法读取 Win32 错误码"), "{unknown}");
        }
    }
}

pub(crate) struct ManagedCameraProcess {
    pub(crate) child: std::process::Child,
    limits: ComputedJobLimits,
    #[cfg(windows)]
    job: Option<imp::Job>,
}

impl ManagedCameraProcess {
    pub(crate) fn bind(child: std::process::Child) -> Result<Self, String> {
        Self::bind_with_limits(child, JobHardLimits::camera_default())
    }

    pub(crate) fn bind_with_limits(
        child: std::process::Child,
        limits: JobHardLimits,
    ) -> Result<Self, String> {
        let computed = compute_job_limits(limits);
        #[cfg(windows)]
        let job = match imp::bind_child(&child, computed) {
            Ok(job) => Some(job),
            Err(error) => {
                log_sanitized_reason(&error);
                let mut child = child;
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        Ok(Self {
            child,
            limits: computed,
            #[cfg(windows)]
            job,
        })
    }

    pub(crate) fn inspect_exit_reason(&self, exit_code: Option<i32>) -> String {
        #[cfg(windows)]
        let usage = self.job.as_ref().and_then(|job| job.query_usage());
        #[cfg(not(windows))]
        let usage = None;
        classify_helper_exit_reason(exit_code, self.limits, usage)
    }
}

impl Drop for ManagedCameraProcess {
    fn drop(&mut self) {
        #[cfg(windows)]
        drop(self.job.take());
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::process_supervisor::{ExitDecision, SupervisorCore};
    use std::time::Duration;

    #[test]
    fn camera_default_limits_match_p1_8_hard_quotas() {
        let computed = compute_job_limits(JobHardLimits::camera_default());
        assert_eq!(computed.process_memory_limit, 128 * 1024 * 1024);
        assert_eq!(computed.job_memory_limit, 192 * 1024 * 1024);
        assert_eq!(computed.active_process_limit, 2);
        assert_eq!(computed.cpu_rate, 2000);
        assert_eq!(
            computed.cpu_control_flags,
            JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP
        );
        assert_eq!(
            computed.extended_limit_flags,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
                | JOB_OBJECT_LIMIT_PROCESS_MEMORY
                | JOB_OBJECT_LIMIT_JOB_MEMORY
                | JOB_OBJECT_LIMIT_ACTIVE_PROCESS
        );
    }

    #[test]
    fn compute_cpu_rate_clamps_to_valid_win32_range() {
        assert_eq!(compute_cpu_rate(0), 100);
        assert_eq!(compute_cpu_rate(1), 100);
        assert_eq!(compute_cpu_rate(20), 2000);
        assert_eq!(compute_cpu_rate(100), 10_000);
        assert_eq!(compute_cpu_rate(255), 10_000);
    }

    #[test]
    fn compute_job_limits_clamps_floor_and_job_memory_ordering() {
        let clamped_floor = compute_job_limits(JobHardLimits {
            process_memory_bytes: 0,
            job_memory_bytes: Some(1024),
            cpu_rate_percent: 0,
            active_process_limit: 0,
        });
        assert_eq!(clamped_floor.process_memory_limit, MIN_PROCESS_MEMORY_BYTES);
        assert_eq!(clamped_floor.job_memory_limit, MIN_PROCESS_MEMORY_BYTES);
        assert_eq!(clamped_floor.active_process_limit, 1);
        assert_eq!(clamped_floor.cpu_rate, 100);

        let raised_proc = compute_job_limits(JobHardLimits {
            process_memory_bytes: 256 * 1024 * 1024,
            job_memory_bytes: Some(192 * 1024 * 1024),
            cpu_rate_percent: 25,
            active_process_limit: 2,
        });
        assert_eq!(raised_proc.process_memory_limit, 256 * 1024 * 1024);
        assert_eq!(raised_proc.job_memory_limit, 256 * 1024 * 1024);
        assert_eq!(raised_proc.cpu_rate, 2500);

        let without_job_cap = compute_job_limits(JobHardLimits {
            process_memory_bytes: 128 * 1024 * 1024,
            job_memory_bytes: None,
            cpu_rate_percent: 20,
            active_process_limit: 2,
        });
        assert_eq!(without_job_cap.job_memory_limit, 0);
        assert_eq!(
            without_job_cap.extended_limit_flags & JOB_OBJECT_LIMIT_JOB_MEMORY,
            0
        );
    }

    #[test]
    fn classify_helper_exit_reason_identifies_oom_quota_exceptions_and_never_leaks_secrets() {
        let limits = compute_job_limits(JobHardLimits::camera_default());

        let oom = classify_helper_exit_reason(Some(STATUS_COMMITMENT_LIMIT as i32), limits, None);
        assert!(oom.contains("超出内存硬限"), "{oom}");
        assert!(oom.contains("0xC000012D"), "{oom}");
        assert!(oom.contains("128 MB"), "{oom}");

        let no_mem = classify_helper_exit_reason(Some(STATUS_NO_MEMORY as i32), limits, None);
        assert!(no_mem.contains("超出内存硬限"), "{no_mem}");

        let quota = classify_helper_exit_reason(Some(STATUS_QUOTA_EXCEEDED as i32), limits, None);
        assert!(quota.contains("配额"), "{quota}");
        assert!(quota.contains("0xC0000044"), "{quota}");

        let peak_proc = classify_helper_exit_reason(
            Some(2),
            limits,
            Some(JobUsageSnapshot {
                peak_process_memory_bytes: 126 * 1024 * 1024,
                peak_job_memory_bytes: 140 * 1024 * 1024,
            }),
        );
        assert!(peak_proc.contains("单进程峰值内存触及硬限"), "{peak_proc}");
        assert!(peak_proc.contains("126 MB / 上限 128 MB"), "{peak_proc}");

        let peak_job = classify_helper_exit_reason(
            Some(2),
            limits,
            Some(JobUsageSnapshot {
                peak_process_memory_bytes: 100 * 1024 * 1024,
                peak_job_memory_bytes: 190 * 1024 * 1024,
            }),
        );
        assert!(peak_job.contains("进程组峰值内存触及硬限"), "{peak_job}");
        assert!(peak_job.contains("190 MB / 上限 192 MB"), "{peak_job}");

        let av = classify_helper_exit_reason(Some(STATUS_ACCESS_VIOLATION as i32), limits, None);
        assert!(av.contains("未处理异常"), "{av}");
        assert!(av.contains("0xC0000005"), "{av}");

        let generic = classify_helper_exit_reason(Some(1), limits, None);
        assert!(generic.contains("退出码 1"), "{generic}");

        for msg in [oom, no_mem, quota, peak_proc, peak_job, av, generic] {
            assert!(!msg.contains("http://"), "{msg}");
            assert!(!msg.contains("rtsp://"), "{msg}");
            assert!(!msg.contains("xiaomi://"), "{msg}");
            assert!(!msg.contains("password"), "{msg}");
            assert!(!msg.contains("token"), "{msg}");
        }
    }

    #[test]
    fn supervisor_treats_job_limit_kill_as_crash_with_backoff_and_circuit_breaker() {
        let limits = compute_job_limits(JobHardLimits::camera_default());
        let mut core = SupervisorCore::new();
        let identity = |d: Duration| d;
        let oom_code = Some(STATUS_COMMITMENT_LIMIT as i32);

        for attempt in 1..=5u32 {
            let start_t = Duration::from_secs(u64::from(attempt) * 10);
            core.mark_started(1000 + attempt, start_t);
            let reason = classify_helper_exit_reason(oom_code, limits, None);
            let decision = core.record_exit(
                start_t + Duration::from_secs(2),
                oom_code,
                Some(reason.clone()),
                identity,
            );
            let diag = core.diagnostics();
            assert_eq!(diag.last_exit_code, oom_code);
            assert_eq!(diag.last_error.as_deref(), Some(reason.as_str()));
            if attempt < 5 {
                assert_eq!(
                    decision,
                    ExitDecision::RestartAfter(Duration::from_secs(1u64 << (attempt - 1)))
                );
                assert!(core.is_backing_off());
            } else {
                assert_eq!(decision, ExitDecision::OpenCircuit);
                assert!(core.is_circuit_open());
                assert!(core.check_can_start().is_err());
            }
        }

        core.explicit_stop();
        assert!(core.check_can_start().is_ok());
    }
}
