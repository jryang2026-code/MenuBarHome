import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct CameraEventStoreTests {
    final class TestClock: @unchecked Sendable {
        var value: Date
        init(_ value: Date) { self.value = value }
    }
    @Test("Camera events expire by clock and retain snapshots")
    func retentionAndSnapshotCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camera-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = CameraEventStore(directory: root, retention: 100, limit: 2, clock: { clock.value })
        let first = store.record(cameraID: "cam-a", kind: .doorbell, snapshotData: Data([1, 2, 3]))
        #expect(store.snapshotData(for: first) == Data([1, 2, 3]))
        _ = store.record(cameraID: "cam-b", kind: .motion)
        _ = store.record(cameraID: "cam-c", kind: .person)
        #expect(store.allEvents().count == 2)
        #expect(store.snapshotData(for: first) == nil)
        clock.value += 101
        _ = store.record(cameraID: "cam-d", kind: .motion)
        #expect(store.allEvents().count == 1)
        #expect(store.latestEvent(for: "cam-d") != nil)
    }

    @Test("Camera event metadata never exposes URLs as snapshot references")
    func snapshotReferenceIsRelative() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camera-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraEventStore(directory: root, clock: { Date(timeIntervalSince1970: 1) })
        let event = store.record(cameraID: "cam", kind: .doorbell, snapshotData: Data([9]))
        #expect(event.snapshotFile?.contains("://") == false)
        #expect(event.snapshotFile?.contains("/") == false)
    }

    private static func camera(_ id: String) -> SmartDevice {
        SmartDevice(
            id: id, name: id, roomId: "door", roomName: "门口",
            model: "chuangmi.camera.061a01", isOnline: true,
            kind: .camera(CameraSpec(entityId: "miot:\(id):2", isOn: true))
        )
    }

    /// #455: the still wall reads the same list the panel does, so a hidden camera never shows a
    /// still, and a camera that already recorded an event keeps its tile ahead of a quiet one.
    @Test("The still wall keeps a hidden camera out and orders eventful cameras first")
    @MainActor
    func stillWallUsesVisibleEventfulCameras() async throws {
        let cameras = ["cam-a", "cam-b", "cam-c", "cam-d", "cam-e", "cam-f", "cam-g"].map(Self.camera)
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: cameras))
        let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        store.hiddenDeviceIds = ["cam-a", "cam-b"]
        store.cameraEventStore.record(cameraID: "cam-e", kind: .motion)
        store.cameraEventStore.record(cameraID: "cam-d", kind: .doorbell)

        // The hidden pair never shows, the two with a still lead in list order, and cam-g falls off
        // the 2x2 wall.
        #expect(store.cameraStillWallCameras().map(\.id) == ["cam-d", "cam-e", "cam-c", "cam-f"])
    }
}
