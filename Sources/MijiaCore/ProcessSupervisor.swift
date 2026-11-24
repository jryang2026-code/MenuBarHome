import Foundation

/// Supervises one child at a time. Call stop before replacing its launch configuration.
actor ProcessSupervisor {
    struct Child: Sendable {
        let pid: Int32
        let isRunning: @Sendable () -> Bool
        let stop: @Sendable () async -> Void
    }

    struct TimeSource: Sendable {
        let now: @Sendable () -> Duration
        let sleepUntil: @Sendable (Duration) async throws -> Void

        static var continuous: Self {
            let origin = ContinuousClock.now
            return Self(now: { origin.duration(to: .now) }, sleepUntil: { deadline in
                try await ContinuousClock().sleep(until: origin + deadline)
            })
        }
    }

    enum State: Equatable, Sendable {
        case stopped
        case running
        case backingOff(Duration)
        case circuitOpen
    }

    typealias Launcher = @Sendable (_ onExit: @escaping @Sendable () -> Void) throws -> Child

    private enum Phase {
        case stopped
        case running(Child, id: UUID, since: Duration)
        case backingOff(Task<Void, Never>)
        case circuitOpen
        case stopping(Task<Void, Never>)
    }

    private let clock: TimeSource
    private let jitter: @Sendable (Duration) -> Duration
    private let onStateChange: @Sendable (State) -> Void
    private var phase = Phase.stopped
    private var launcher: Launcher?
    private var failures: [Duration] = []
    private var consecutiveFailures = 0
    private(set) var state = State.stopped {
        didSet { if state != oldValue { onStateChange(state) } }
    }

    init(
        clock: TimeSource = .continuous,
        jitter: @escaping @Sendable (Duration) -> Duration = { $0 * Double.random(in: 0.8...1.2) },
        onStateChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.clock = clock
        self.jitter = jitter
        self.onStateChange = onStateChange
    }

    func start(_ launch: @escaping Launcher) {
        guard !Task.isCancelled, case .stopped = phase else { return }
        launcher = launch
        launchChild()
    }

    var currentPID: Int32? {
        guard case .running(let child, let id, _) = phase else { return nil }
        guard child.isRunning() else {
            exited(id)
            return nil
        }
        return child.pid
    }

    func waitForRunningPID() async -> Int32? {
        while !Task.isCancelled {
            if let pid = currentPID { return pid }
            guard case .backingOff(let retry) = phase else { break }
            await retry.value
        }
        return nil
    }

    /// An explicit stop resets the circuit. Repeated start requests cannot bypass an open circuit.
    @discardableResult
    func stop(ifRunningPID expectedPID: Int32? = nil) async -> Bool {
        if let expectedPID, currentPID != expectedPID { return false }
        if case .stopping(let stopping) = phase {
            await stopping.value
            finishStop(stopping)
            return true
        }

        let child: Child?
        switch phase {
        case .running(let running, _, _):
            child = running
        case .backingOff(let retry):
            retry.cancel()
            child = nil
        default:
            child = nil
        }

        launcher = nil
        resetFailures()
        if let child {
            let stopping = Task { await child.stop() }
            phase = .stopping(stopping)
            await stopping.value
            finishStop(stopping)
        } else {
            phase = .stopped
            state = .stopped
        }
        return true
    }

    private func finishStop(_ task: Task<Void, Never>) {
        guard case .stopping(task) = phase else { return }
        phase = .stopped
        state = .stopped
    }

    private func launchChild() {
        guard let launcher else { return }
        let id = UUID()
        do {
            let child = try launcher { [weak self] in
                Task { await self?.exited(id) }
            }
            phase = .running(child, id: id, since: clock.now())
            state = .running
        } catch {
            failed(at: clock.now())
        }
    }

    private func exited(_ id: UUID) {
        guard case .running(_, id, let since) = phase else { return }
        let now = clock.now()
        if now - since >= .seconds(300) { resetFailures() }
        failed(at: now)
    }

    private func resetFailures() {
        failures.removeAll()
        consecutiveFailures = 0
    }

    private func failed(at now: Duration) {
        failures.removeAll { now - $0 >= .seconds(120) }
        failures.append(now)
        if failures.count >= 5 {
            phase = .circuitOpen
            state = .circuitOpen
            return
        }

        let delay = min(jitter(.seconds(1 << min(consecutiveFailures, 6))), .seconds(60))
        consecutiveFailures = min(consecutiveFailures + 1, 6)
        let retry = Task { [weak self, clock] in
            do {
                try await clock.sleepUntil(now + delay)
                await self?.retryLaunch()
            } catch is CancellationError {
                // stop() owns the state transition when it cancels a retry.
            } catch {
                await self?.retryClockFailed()
            }
        }
        phase = .backingOff(retry)
        state = .backingOff(delay)
    }

    private func retryLaunch() {
        guard !Task.isCancelled else { return }
        launchChild()
    }

    private func retryClockFailed() {
        guard !Task.isCancelled else { return }
        phase = .circuitOpen
        state = .circuitOpen
    }
}

extension ProcessSupervisor {
    /// Consolidated go2rtc config paths, module allow-list, and YAML rendering (#446).
    /// Must stay identical to `Shared/go2rtcConfig.json` and Windows `process_supervisor.rs`.
    /// Never persists or logs credentials in event history or supervisor state.
    enum Go2RTCConfig {
        static let configFileName = "go2rtc.yaml"
        static let ownerFileName = "go2rtc.owner"
        static let pidFileName = "go2rtc.pid"
        static let logFileName = "go2rtc.log"
        static let forbiddenListenPorts: Set<UInt16> = [1984, 8554, 8555]
        static let allowedModules: [String] = [
            "api",
            "ws",
            "http",
            "rtsp",
            "webrtc",
            "mp4",
            "hls",
            "mjpeg",
            "exec",
            "ffmpeg",
            "xiaomi",
        ]

        struct Paths: Equatable, Sendable {
            let binDirectory: URL
            var configFile: URL { binDirectory.appendingPathComponent(Go2RTCConfig.configFileName) }
            var ownerFile: URL { binDirectory.appendingPathComponent(Go2RTCConfig.ownerFileName) }
            var pidFile: URL { binDirectory.appendingPathComponent(Go2RTCConfig.pidFileName) }
            var logFile: URL { binDirectory.appendingPathComponent(Go2RTCConfig.logFileName) }

            init(binDirectory: URL) {
                self.binDirectory = binDirectory
            }

            static func discover() -> Paths {
                let appSupport = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MenuBarMijia/bin", isDirectory: true)
                return Paths(binDirectory: appSupport)
            }
        }

        static func isAcceptableListen(_ value: String) -> Bool {
            let prefix = "127.0.0.1:"
            guard value.hasPrefix(prefix),
                  let port = UInt16(value.dropFirst(prefix.count)),
                  port > 0,
                  !forbiddenListenPorts.contains(port) else {
                return false
            }
            return value == "127.0.0.1:\(port)"
        }

        static func sanitizedListen(_ value: String) -> String {
            isAcceptableListen(value) ? value : "127.0.0.1:9"
        }

        static func yamlDoubleQuoted(_ value: String) -> String {
            var out = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\\":
                    out += "\\\\"
                case "\"":
                    out += "\\\""
                case "\n", "\r":
                    continue
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
            out += "\""
            return out
        }

        /// `app.modules` restricts go2rtc to the exact modules MenuBarHome uses (`exec` stays
        /// enabled because go2rtc's `ffmpeg:` source delegates to `exec:`, bounded by
        /// `exec.allow_paths`, while `echo`, `expr`, `debug`, `ngrok`, etc. stay disabled).
        /// `webrtc: listen: ""` keeps go2rtc from opening port 8555. `local_auth` is required
        /// because v1.9.15 skips Basic auth for every loopback request when it is false.
        static func renderConfig(
            apiListen: String,
            rtspListen: String,
            username: String,
            password: String,
            nonce: String,
            ffmpegBin: String
        ) -> String {
            let moduleLines = allowedModules.map { "    - \($0)" }.joined(separator: "\n")
            let ffmpeg = yamlDoubleQuoted(ffmpegBin)
            let api = sanitizedListen(apiListen)
            let rtsp = sanitizedListen(rtspListen)
            return """
            app:
              modules:
            \(moduleLines)
            api:
              listen: \(api)
              username: \(yamlDoubleQuoted(username))
              password: \(yamlDoubleQuoted(password))
              local_auth: true
            rtsp:
              listen: \(rtsp)
            webrtc:
              listen: ""
            log:
              level: info
              ffmpeg: error
            ffmpeg:
              bin: \(ffmpeg)
            exec:
              allow_paths:
                - \(ffmpeg)
            menubarmijia:
              nonce: \(yamlDoubleQuoted(nonce))
            """
        }
    }
}
