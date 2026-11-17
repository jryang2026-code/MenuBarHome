//! Binds managed helper daemons (`go2rtc.exe`) to a Windows Job Object with
//! `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` so an abnormal parent crash or Task Manager termination
//! never leaves an orphaned streaming process holding loopback ports and temporary credentials.

#[cfg(windows)]
mod imp {
    use core::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    use std::sync::OnceLock;

    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: i32 = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;

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

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> isize;
        fn SetInformationJobObject(
            job: isize,
            info_class: i32,
            info: *const c_void,
            info_len: u32,
        ) -> i32;
        fn AssignProcessToJobObject(job: isize, process: isize) -> i32;
        fn CloseHandle(handle: isize) -> i32;
    }

    /// Cached like the previous `OnceLock<Option<_>>`, but the failure reason is kept so every
    /// later spawn fails closed with a diagnostic instead of continuing without the guarantee.
    static KILL_ON_CLOSE_JOB: OnceLock<Result<isize, String>> = OnceLock::new();

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

    pub(crate) fn ensure_kill_on_close_job() -> Result<isize, String> {
        KILL_ON_CLOSE_JOB
            .get_or_init(create_kill_on_close_job)
            .clone()
    }

    fn create_kill_on_close_job() -> Result<isize, String> {
        unsafe {
            let job = CreateJobObjectW(core::ptr::null(), core::ptr::null());
            if job == 0 {
                return Err(format!(
                    "创建 Job Object 失败：{}",
                    win32_error_text(last_error_code())
                ));
            }
            let mut info = JobObjectExtendedLimitInformation::default();
            info.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let configured = SetInformationJobObject(
                job,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                (&info as *const JobObjectExtendedLimitInformation).cast::<c_void>(),
                core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
            );
            if configured == 0 {
                let detail = win32_error_text(last_error_code());
                let _ = CloseHandle(job);
                return Err(format!("设置 Job Object KILL_ON_JOB_CLOSE 失败：{detail}"));
            }
            Ok(job)
        }
    }

    pub(crate) fn bind_child(child: &std::process::Child) -> Result<(), String> {
        let job = ensure_kill_on_close_job()?;
        let assigned = unsafe { AssignProcessToJobObject(job, child.as_raw_handle() as isize) };
        if assigned == 0 {
            // Read `GetLastError` before another Win32 call could overwrite it.
            return Err(assign_failure_message(last_error_code()));
        }
        Ok(())
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

        #[test]
        fn kill_on_close_job_initializes_on_windows() {
            assert!(ensure_kill_on_close_job().is_ok());
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

/// Binding failure must reach the caller: without the job the "app exit kills go2rtc" guarantee is
/// gone, so the caller terminates the just-spawned child instead of running without it.
pub(crate) fn bind_child_to_kill_on_close_job(child: &std::process::Child) -> Result<(), String> {
    #[cfg(windows)]
    {
        imp::bind_child(child)
    }
    #[cfg(not(windows))]
    {
        let _ = child;
        Ok(())
    }
}
