#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct SupervisedProcessIdentity: Codable, Equatable {
    let pid: Int32
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    struct Snapshot: Equatable {
        let identity: SupervisedProcessIdentity
        let parentPID: Int32
    }

    /// Immutable process-birth identity (`pid`, start timestamp, parent PID, effective UID) that
    /// survives `execve()` image replacement (e.g. macOS `/bin/sh` exec'ing `/bin/bash` via
    /// `/private/var/select/sh` or `#!/usr/bin/env` wrappers) while still rejecting PID reuse.
    struct Birth: Equatable, Sendable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let parentPID: Int32

        static func capture(pid: Int32) -> Self? {
            #if canImport(Darwin)
            guard pid > 1 else { return nil }
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == geteuid() else { return nil }
            return Self(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec,
                parentPID: Int32(info.pbi_ppid)
            )
            #else
            return nil
            #endif
        }
    }

    static func snapshot(pid: Int32) -> Snapshot? {
        #if canImport(Darwin)
        guard pid > 1 else { return nil }
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        var before = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, size) == size,
              before.pbi_uid == geteuid() else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              let end = buffer.firstIndex(of: 0) else { return nil }
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              after.pbi_start_tvsec == before.pbi_start_tvsec,
              after.pbi_start_tvusec == before.pbi_start_tvusec,
              after.pbi_uid == before.pbi_uid else { return nil }
        return Snapshot(
            identity: Self(
                pid: pid,
                executablePath: String(decoding: buffer[..<end], as: UTF8.self),
                startSeconds: after.pbi_start_tvsec,
                startMicroseconds: after.pbi_start_tvusec
            ),
            parentPID: Int32(after.pbi_ppid)
        )
        #else
        return nil
        #endif
    }
}

/// A private record written by the launcher. Path, process start time, and UID must still
/// match when cleaning up a reparented child, including before escalating the signal.
struct SupervisedProcessPIDFile: Sendable {
    let url: URL

    func write(_ identity: SupervisedProcessIdentity) throws {
        try JSONEncoder().encode(identity).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func liveProcess(
        inspect: (Int32) -> SupervisedProcessIdentity.Snapshot? = SupervisedProcessIdentity.snapshot
    ) -> SupervisedProcessIdentity.Snapshot? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0,
              (1...4096).contains(info.st_size),
              let data = try? file.read(upToCount: 4096),
              let saved = try? JSONDecoder().decode(SupervisedProcessIdentity.self, from: data),
              saved.pid > 1,
              saved.pid != getpid(),
              let current = inspect(saved.pid),
              current.identity == saved else { return nil }
        return current
    }

    func orphan(
        inspect: (Int32) -> SupervisedProcessIdentity.Snapshot? = SupervisedProcessIdentity.snapshot
    ) -> SupervisedProcessIdentity? {
        guard let current = liveProcess(inspect: inspect), current.parentPID == 1 else { return nil }
        return current.identity
    }

    func cleanOrphan() async -> Bool {
        guard let saved = orphan() else { return false }
        await SupervisedProcess.terminate(pid: saved.pid) {
            orphan() == saved
        }
        return orphan() != saved
    }
}

enum SupervisedProcess {
    static func launch(
        _ process: Process,
        pidFile: SupervisedProcessPIDFile,
        onExit: @escaping @Sendable () -> Void,
        register: (Int32) throws -> Void,
        gracefulExit: @escaping @Sendable () async -> Void
    ) throws -> ProcessSupervisor.Child {
        process.terminationHandler = { _ in onExit() }
        try process.run()
        let pid = process.processIdentifier
        let identity = SupervisedProcessIdentity.snapshot(pid: pid)?.identity
        do {
            #if canImport(Darwin)
            guard let identity,
                  URL(fileURLWithPath: identity.executablePath).resolvingSymlinksInPath().path
                    == process.executableURL?.resolvingSymlinksInPath().path else {
                throw CocoaError(.executableLoad)
            }
            try pidFile.write(identity)
            #endif
            try register(pid)
        } catch {
            if process.isRunning {
                process.terminate()
                if let identity, SupervisedProcessIdentity.snapshot(pid: pid)?.identity == identity {
                    _ = kill(pid, SIGKILL)
                }
            }
            throw error
        }
        return ProcessSupervisor.Child(pid: pid, isRunning: { process.isRunning }, stop: {
            if process.isRunning { await gracefulExit() }
            await terminate(pid: pid) {
                guard process.isRunning else { return false }
                #if canImport(Darwin)
                return SupervisedProcessIdentity.snapshot(pid: pid)?.identity == identity
                #else
                return true
                #endif
            }
        })
    }

    static func terminate(pid: Int32, whileOwned: () -> Bool) async {
        guard whileOwned() else { return }
        _ = kill(pid, SIGTERM)
        for _ in 0..<20 {
            guard whileOwned() else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard whileOwned() else { return }
        _ = kill(pid, SIGKILL)
        for _ in 0..<20 {
            guard whileOwned() else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
