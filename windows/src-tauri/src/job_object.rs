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

    static KILL_ON_CLOSE_JOB: OnceLock<Option<isize>> = OnceLock::new();

    pub(crate) fn ensure_kill_on_close_job() -> Option<isize> {
        *KILL_ON_CLOSE_JOB.get_or_init(|| unsafe {
            let job = CreateJobObjectW(core::ptr::null(), core::ptr::null());
            if job == 0 {
                return None;
            }
            let mut info = JobObjectExtendedLimitInformation::default();
            info.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                job,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                (&info as *const JobObjectExtendedLimitInformation).cast::<c_void>(),
                core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
            );
            if ok == 0 {
                let _ = CloseHandle(job);
                return None;
            }
            Some(job)
        })
    }

    pub(crate) fn bind_child(child: &std::process::Child) {
        if let Some(job) = ensure_kill_on_close_job() {
            unsafe {
                let _ = AssignProcessToJobObject(job, child.as_raw_handle() as isize);
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn kill_on_close_job_initializes_on_windows() {
            assert!(ensure_kill_on_close_job().is_some());
        }
    }
}

pub(crate) fn bind_child_to_kill_on_close_job(child: &std::process::Child) {
    #[cfg(windows)]
    imp::bind_child(child);
    #[cfg(not(windows))]
    let _ = child;
}
