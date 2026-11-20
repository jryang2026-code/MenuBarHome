//! Binds managed helper daemons (`go2rtc.exe`) to a Windows Job Object with
//! `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` so an abnormal parent crash or Task Manager termination
//! never leaves an orphaned streaming process holding loopback ports and temporary credentials.

#[cfg(windows)]
mod imp {
    use core::ffi::c_void;
    use std::os::windows::io::AsRawHandle;

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

    pub(super) fn bind_child(child: &std::process::Child) -> Result<Job, String> {
        let job = Job(create_kill_on_close_job()?);
        let assigned = unsafe { AssignProcessToJobObject(job.0, child.as_raw_handle() as isize) };
        if assigned == 0 {
            // Read `GetLastError` before another Win32 call could overwrite it.
            return Err(assign_failure_message(last_error_code()));
        }
        Ok(job)
    }

    pub(crate) struct Job(isize);

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

        #[test]
        fn kill_on_close_job_initializes_on_windows() {
            assert!(create_kill_on_close_job().map(Job).is_ok());
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
    #[cfg(windows)]
    job: Option<imp::Job>,
}

impl ManagedCameraProcess {
    pub(crate) fn bind(child: std::process::Child) -> Result<Self, String> {
        #[cfg(windows)]
        let job = match imp::bind_child(&child) {
            Ok(job) => Some(job),
            Err(error) => {
                let mut child = child;
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        Ok(Self {
            child,
            #[cfg(windows)]
            job,
        })
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
