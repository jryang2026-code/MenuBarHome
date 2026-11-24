import Foundation
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct ProcessSupervisorTests {
    @Test func crashesBackOffThenOpenUntilExplicitStop() async throws {
        let harness = Harness()
        var events = harness.events.makeAsyncIterator()
        await harness.supervisor.start(harness.launch)
        #expect(await events.next() == .running)

        for seconds in [1, 2, 4, 8] {
            let child = try #require(harness.lastChild)
            child.exit()
            #expect(await events.next() == .backingOff(.seconds(seconds)))
            #expect(await events.next() == .running)
            #expect(harness.lastChild?.pid == child.pid + 1)
        }
        try #require(harness.lastChild).exit()
        #expect(await events.next() == .circuitOpen)
        let launches = harness.launchCount
        await harness.supervisor.start(harness.launch)
        #expect(await harness.supervisor.waitForRunningPID() == nil)
        #expect(harness.launchCount == launches)

        await harness.supervisor.stop()
        #expect(await events.next() == .stopped)
        await harness.supervisor.start(harness.launch)
        #expect(await events.next() == .running)
        try #require(harness.lastChild).exit()
        #expect(await events.next() == .backingOff(.seconds(1)))
        #expect(await events.next() == .running)
        await harness.supervisor.stop()
    }

    @Test func stableRunResetsBackoffAndTheRollingWindowExpires() async throws {
        let harness = Harness()
        var events = harness.events.makeAsyncIterator()
        await harness.supervisor.start(harness.launch)
        #expect(await events.next() == .running)

        for seconds in [1, 2, 4, 8] {
            try #require(harness.lastChild).exit()
            #expect(await events.next() == .backingOff(.seconds(seconds)))
            #expect(await events.next() == .running)
        }
        harness.advance(by: .seconds(120))
        try #require(harness.lastChild).exit()
        #expect(await events.next() == .backingOff(.seconds(16)))
        #expect(await events.next() == .running)

        harness.advance(by: .seconds(300))
        try #require(harness.lastChild).exit()
        #expect(await events.next() == .backingOff(.seconds(1)))
        #expect(await events.next() == .running)
        await harness.supervisor.stop()
    }

    @Test func stopCancelsPendingLaunchAfterStartFailure() async {
        let (entered, entering) = AsyncStream<Void>.makeStream()
        let (resume, resuming) = AsyncStream<Void>.makeStream()
        let (events, continuation) = AsyncStream<ProcessSupervisor.State>.makeStream()
        let clock = ProcessSupervisor.TimeSource(now: { .zero }, sleepUntil: { deadline in
            #expect(deadline == .milliseconds(800))
            entering.yield()
            for await _ in resume { break }
        })
        let supervisor = ProcessSupervisor(
            clock: clock, jitter: { $0 * 0.8 }, onStateChange: { continuation.yield($0) }
        )
        await supervisor.start { _ in throw CocoaError(.executableLoad) }
        var observed = events.makeAsyncIterator()
        #expect(await observed.next() == .backingOff(.milliseconds(800)))
        for await _ in entered { break }
        await supervisor.stop()
        resuming.yield()
        resuming.finish()
        entering.finish()
        #expect(await observed.next() == .stopped)
        #expect(await supervisor.waitForRunningPID() == nil)
    }

    @Test func orphanRequiresPrivateRecordAndMatchingProcessIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = SupervisedProcessPIDFile(url: directory.appendingPathComponent("helper.pid"))
        let recorded = SupervisedProcessIdentity(
            pid: Int32.max, executablePath: "/Applications/OurHelper", startSeconds: 100, startMicroseconds: 42
        )
        let matching = SupervisedProcessIdentity.Snapshot(identity: recorded, parentPID: 1)
        #expect(marker.orphan { _ in matching } == nil)
        try marker.write(recorded)
        #expect(marker.orphan { $0 == recorded.pid ? matching : nil } == recorded)
        #expect(marker.orphan { _ in nil } == nil)
        #expect(marker.orphan { _ in .init(identity: recorded, parentPID: 2) } == nil)
        let reusedPID = SupervisedProcessIdentity(
            pid: recorded.pid, executablePath: recorded.executablePath, startSeconds: 100, startMicroseconds: 43
        )
        #expect(marker.orphan { _ in .init(identity: reusedPID, parentPID: 1) } == nil)
        let otherBinary = SupervisedProcessIdentity(
            pid: recorded.pid, executablePath: "/usr/local/bin/OtherHelper", startSeconds: 100, startMicroseconds: 42
        )
        #expect(marker.orphan { _ in .init(identity: otherBinary, parentPID: 1) } == nil)

        let link = directory.appendingPathComponent("untrusted.pid")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: marker.url)
        #expect(SupervisedProcessPIDFile(url: link).orphan { _ in matching } == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.url.path)
        #expect(marker.orphan { _ in matching } == nil)
    }

    private final class FakeChild: @unchecked Sendable {
        let pid: Int32
        private let lock = NSLock()
        private var running = true
        private let onExit: @Sendable () -> Void

        init(pid: Int32, onExit: @escaping @Sendable () -> Void) {
            self.pid = pid
            self.onExit = onExit
        }

        func exit() {
            lock.withLock { running = false }
            onExit()
        }

        var handle: ProcessSupervisor.Child {
            ProcessSupervisor.Child(pid: pid, isRunning: { self.lock.withLock { self.running } }, stop: self.exit)
        }
    }

    private final class FakeRuntime: @unchecked Sendable {
        let lock = NSLock()
        var now: Duration = .zero
        var launchCount = 0
        var lastChild: FakeChild?
    }

    private struct Harness {
        private let runtime = FakeRuntime()
        let events: AsyncStream<ProcessSupervisor.State>
        let supervisor: ProcessSupervisor

        init() {
            let (events, continuation) = AsyncStream<ProcessSupervisor.State>.makeStream()
            self.events = events
            let clock = ProcessSupervisor.TimeSource(
                now: { [runtime] in runtime.lock.withLock { runtime.now } },
                sleepUntil: { [runtime] deadline in
                    runtime.lock.withLock { runtime.now = max(runtime.now, deadline) }
                }
            )
            supervisor = ProcessSupervisor(clock: clock, jitter: { $0 }, onStateChange: { continuation.yield($0) })
        }

        var launchCount: Int { runtime.lock.withLock { runtime.launchCount } }
        var lastChild: FakeChild? { runtime.lock.withLock { runtime.lastChild } }

        func advance(by duration: Duration) {
            runtime.lock.withLock { runtime.now += duration }
        }

        func launch(onExit: @escaping @Sendable () -> Void) -> ProcessSupervisor.Child {
            runtime.lock.withLock {
                runtime.launchCount += 1
                let child = FakeChild(pid: Int32(runtime.launchCount), onExit: onExit)
                runtime.lastChild = child
                return child.handle
            }
        }
    }
}
