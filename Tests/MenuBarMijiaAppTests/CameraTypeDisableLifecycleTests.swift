import AppKit
import Foundation
import StateTestSupport
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor CameraTypeRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor CameraTypeProvider: HomeProvider {
    let recorder: CameraTypeRecorder

    init(recorder: CameraTypeRecorder) {
        self.recorder = recorder
    }

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { $0.finish() }
    }

    func execute(_ command: DeviceCommand) async throws {
        await recorder.record("execute")
    }

    func refreshNow() async {}

    func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality,
        channel: Int
    ) async throws -> CameraStreamSource {
        await recorder.record("resolve:\(device.id)")
        let url = URL(string: "http://127.0.0.1:9/api/stream.mp4?src=cam_raw_\(device.id)&mp4")!
        return .liveMP4(url, mjpegFallback: nil, ptz: nil)
    }

    func stopCameraStream(for device: SmartDevice) async {
        await recorder.record("stop:\(device.id)")
    }
}

/// Frozen clock for the warm-stream lifetime: sleepers wake only on `advance`, and a cancelled
/// sleeper leaves at once.
private final class FrozenClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Duration = .zero
    private var nextID = 0
    private var sleepers: [Int: (deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    guard !Task.isCancelled else { return true }
                    sleepers[id] = (now + duration, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let entry = lock.withLock { sleepers.removeValue(forKey: id) }
            entry?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            now += duration
            let ready = sleepers.filter { $0.value.deadline <= now }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// Parks the bridge shutdown until the test opens it.
private final class ShutdownGate: Sendable {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releasedContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        (released, releasedContinuation) = AsyncStream<Void>.makeStream()
    }

    func park() async {
        enteredContinuation.yield()
        enteredContinuation.finish()
        for await _ in released { break }
    }

    func waitUntilParked() async {
        for await _ in entered { break }
    }

    func open() {
        releasedContinuation.yield()
        releasedContinuation.finish()
    }
}

/// P3c-CM in the panel: closing the camera type clears frames and warm streams, lets each original
/// session stop, then stops the helper; a reopen waits for that and starts one stream on demand.
@Suite("Camera type disable lifecycle", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct CameraTypeDisableLifecycleTests {
    private static func camera(_ id: String) -> SmartDevice {
        SmartDevice(
            id: id, name: "摄像机 \(id)", roomId: "living", roomName: "客厅",
            model: "chuangmi.camera.061a01", isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.\(id)", isOn: true))
        )
    }

    private static func setCamera(_ enabled: Bool, in store: HomeStore) {
        var selection = store.capabilitySelection
        if enabled { selection.enabledCategories.insert(.camera) } else { selection.enabledCategories.remove(.camera) }
        store.capabilitySelection = selection
    }

    private static func makeRig(_ suite: String) throws -> (CameraLivePanelController, HomeStore, CameraTypeRecorder, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let recorder = CameraTypeRecorder()
        let store = HomeStore(provider: CameraTypeProvider(recorder: recorder), defaultsSuiteName: suite)
        store.devices = [camera("cam-a"), camera("cam-b")]
        let controller = CameraLivePanelController()
        controller.presentsActively = false
        controller.frameDefaults = defaults
        controller.install(with: store)
        return (controller, store, recorder, defaults)
    }

    @Test("Closing the camera type clears frames and warm streams, stops each session, then the helper; nothing returns after the warm window")
    func closingReleasesEverythingInOrder() async throws {
        let suite = "MenuBarMijiaTests.CameraTypeClose.\(UUID().uuidString)"
        let (controller, store, recorder, defaults) = try Self.makeRig(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = FrozenClock()
        controller.warmExpirySleep = { try await clock.sleep(for: $0) }
        controller.bridgeShutdownOverride = { await recorder.record("shutdown") }
        defer {
            controller.closePanel()
            controller.bridgeShutdownOverride = nil
        }

        controller.present(device: Self.camera("cam-a"))
        try await awaitState { controller.streamSource != nil }
        controller.present(device: Self.camera("cam-b"))
        #expect(controller.warmPlaybackCount == 1)
        #expect(controller.activeDeviceId == "cam-b")

        Self.setCamera(false, in: store)
        #expect(controller.warmPlaybackCount == 0)
        #expect(controller.activeDeviceId == nil)
        #expect(controller.streamSource == nil)
        #expect(controller.snapshotImage == nil)
        #expect(!controller.hasLiveVideoFrame)
        #expect(!controller.isLoadingStream)
        #expect(controller.errorMessage == nil)
        #expect(controller.panelWindow?.isVisible != true)
        #expect(clock.sleeperCount == 0)

        try await #require(controller.cameraTypeShutdownTask).value
        let released = await recorder.events
        #expect(released == ["resolve:cam-a", "stop:cam-a", "stop:cam-b", "shutdown"])
        #expect(controller.cameraTypeShutdownTask == nil)

        clock.advance(by: .seconds(120))
        #expect(controller.pendingStopCount == 0)
        #expect(controller.warmPlaybackCount == 0)
        #expect(await recorder.events.count == 4)
    }

    @Test("A quick close and reopen waits for the helper to stop and starts one stream")
    func reopenWaitsForTheRelease() async throws {
        let suite = "MenuBarMijiaTests.CameraTypeReopen.\(UUID().uuidString)"
        let (controller, store, recorder, defaults) = try Self.makeRig(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = ShutdownGate()
        controller.bridgeShutdownOverride = {
            await recorder.record("shutdown-begin")
            await gate.park()
            await recorder.record("shutdown-end")
        }
        defer {
            controller.closePanel()
            controller.bridgeShutdownOverride = nil
        }

        controller.present(device: Self.camera("cam-a"))
        try await awaitState { controller.streamSource != nil }

        Self.setCamera(false, in: store)
        Self.setCamera(true, in: store)
        controller.present(device: Self.camera("cam-a"))
        #expect(controller.isLoadingStream)

        await gate.waitUntilParked()
        gate.open()
        try await awaitState { controller.streamSource != nil }

        #expect(await recorder.events == [
            "resolve:cam-a", "stop:cam-a", "shutdown-begin", "shutdown-end", "resolve:cam-a"
        ])
        #expect(controller.activeDeviceId == "cam-a")
        #expect(controller.warmPlaybackCount == 0)
        #expect(!(await recorder.events.contains("execute")))
    }
}
