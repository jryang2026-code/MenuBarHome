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
