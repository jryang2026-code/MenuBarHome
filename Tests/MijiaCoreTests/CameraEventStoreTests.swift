import Foundation
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
}
