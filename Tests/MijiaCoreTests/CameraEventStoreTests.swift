import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct CameraEventStoreTests {
    final class TestClock: @unchecked Sendable {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private struct CameraEventGolden: Decodable {
        let schemaVersion: Int
        let retentionSeconds: TimeInterval
        let maxEvents: Int
        let stillWallLimit: Int
        let stillRefreshCooldownSeconds: TimeInterval
        let allowedKinds: [String]
        let validRecords: [ValidRecord]
        let malformedRecords: [MalformedRecord]
        let unsafeSnapshotFilenames: [String]
        let stillWallSelectionCase: StillWallCase
    }

    private struct ValidRecord: Codable {
        let id: String
        let cameraID: String
        let kind: String
        let timestamp: String
        let snapshotFile: String?
    }

    private struct MalformedRecord: Decodable {
        let reason: String
        let record: JSONValue
    }

    private struct StillWallCase: Decodable {
        let visibleCameraIds: [String]
        let eventfulCameraIds: [String]
        let limit: Int
        let expectedOrder: [String]
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("camera-events-\(UUID().uuidString)")
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = fractional.date(from: text) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        wholeSeconds.timeZone = TimeZone(secondsFromGMT: 0)
        return wholeSeconds.date(from: text)
    }

    private static func store(root: URL, eventsJSON: Data, clock: @escaping CameraEventStore.Clock) throws -> CameraEventStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try eventsJSON.write(to: root.appendingPathComponent("events.json"))
        return CameraEventStore(directory: root, clock: clock)
    }

    private static func recordJSON(
        id: String,
        cameraID: String,
        kind: String,
        timestamp: String,
        snapshotFile: String? = nil
    ) -> [String: Any] {
        var record: [String: Any] = [
            "id": id, "cameraID": cameraID, "kind": kind, "timestamp": timestamp
        ]
        if let snapshotFile { record["snapshotFile"] = snapshotFile }
        return record
    }

    @Test("Cross-platform camera event golden JSON corpus matches Swift CameraEventStore")
    @MainActor
    func cameraEventGoldenCorpusParity() throws {
        let fixtureURL = try GoldenCorpusTests.locateGoldenFixture("Tests/Fixtures/camera_event_golden.json")
        let corpus = try JSONDecoder().decode(CameraEventGolden.self, from: Data(contentsOf: fixtureURL))
        let clockDate = try #require(Self.date("2026-11-26T00:00:00Z"))
        let clock: CameraEventStore.Clock = { clockDate }

        #expect(corpus.schemaVersion == 1)
        #expect(CameraEventStore.defaultRetention == corpus.retentionSeconds)
        #expect(CameraEventStore.defaultLimit == corpus.maxEvents)
        #expect(corpus.stillWallLimit == 4)
        // The still-frame capture throttle is Windows-only; the corpus still pins its contract.
        #expect(corpus.stillRefreshCooldownSeconds == 60)
        #expect(Set(CameraEvent.Kind.allCases.map(\.rawValue)) == Set(corpus.allowedKinds))

        for record in corpus.validRecords {
            let root = Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try Self.store(
                root: root,
                eventsJSON: JSONEncoder().encode([record]),
                clock: clock
            )
            let event = try #require(store.allEvents().first, "\(record.id)")
            #expect(event.id.uuidString == record.id, "\(record.id)")
            #expect(event.cameraID == record.cameraID, "\(record.id)")
            #expect(event.kind.rawValue == record.kind, "\(record.id)")
            #expect(event.timestamp == Self.date(record.timestamp), "\(record.id)")
            #expect(event.snapshotFile == record.snapshotFile, "\(record.id)")
        }

        for entry in corpus.malformedRecords {
            let root = Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try Self.store(
                root: root,
                eventsJSON: JSONEncoder().encode([entry.record]),
                clock: clock
            )
            #expect(store.allEvents().isEmpty, "\(entry.reason)")
        }

        for unsafe in corpus.unsafeSnapshotFilenames {
            #expect(!CameraEventStore.isSafeSnapshotFilename(unsafe), "\(unsafe)")
        }

        let wall = corpus.stillWallSelectionCase
        let eventful = Set(wall.eventfulCameraIds)
        let ordered = HomeStore.stillWallCameras(
            from: wall.visibleCameraIds.map(Self.camera),
            limit: wall.limit,
            hasEvent: { eventful.contains($0) }
        )
        #expect(ordered.map(\.id) == wall.expectedOrder)
    }

    @Test("A single corrupted record does not erase the rest of the history")
    func corruptedRecordPreservesValidHistory() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(Self.date("2026-11-26T00:00:00Z"))
        let firstID = UUID().uuidString
        let lastID = UUID().uuidString
        let unsafeSnapshotID = UUID().uuidString
        let raw: [Any] = [
            Self.recordJSON(id: firstID, cameraID: "cam-front", kind: "doorbell", timestamp: "2026-11-24T10:00:00Z"),
            "corrupt-line",
            Self.recordJSON(
                id: UUID().uuidString,
                cameraID: "rtsp://admin:secret@192.0.2.10/live",
                kind: "motion",
                timestamp: "2026-11-24T09:00:00Z"
            ),
            Self.recordJSON(id: lastID, cameraID: "cam-back", kind: "motion", timestamp: "2026-11-24T08:00:00Z"),
            Self.recordJSON(
                id: unsafeSnapshotID,
                cameraID: "cam-porch",
                kind: "package",
                timestamp: "2026-11-24T07:00:00Z",
                snapshotFile: "..\\secret.jpeg"
            ),
        ]
        let store = try Self.store(
            root: root,
            eventsJSON: try JSONSerialization.data(withJSONObject: raw),
            clock: { now }
        )

        let events = store.allEvents()
        #expect(events.map(\.id.uuidString) == [firstID, lastID, unsafeSnapshotID])
        #expect(events.allSatisfy { !$0.cameraID.contains("secret") })
        #expect(events.last?.snapshotFile == nil, "unsafe snapshot filename must be stripped, not persisted")
    }

    @Test("Credential-bearing camera IDs are rejected")
    func rejectsCredentialBearingCameraID() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraEventStore(directory: root, clock: { Date(timeIntervalSince1970: 100) })

        for invalid in ["rtsp://admin:secret@192.168.1.10/stream", "", "   ", " cam ", "cam\nx"] {
            #expect(store.record(cameraID: invalid, kind: .doorbell) == nil, "\(invalid)")
        }
        #expect(store.allEvents().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("events.json").path))
        #expect(store.record(cameraID: "cam-front", kind: .motion) != nil)
        #expect(store.allEvents().count == 1)
    }

    @Test("Windows-style snapshot paths cannot escape the event directory")
    func rejectsUnsafeSnapshotFilenames() throws {
        let unsafeNames = [
            "", "../secret.jpeg", "..\\secret.jpeg", "/tmp/snapshot-1.jpeg",
            "C:\\Users\\test\\snapshot-1.jpeg", "rtsp://user:pass@192.0.2.10/stream",
            "http://192.0.2.10/api/frame.jpeg?token=abc", "snapshot-1.jpeg?token=abc",
            "snapshot-1.png", "random.txt",
        ]
        for name in unsafeNames {
            #expect(!CameraEventStore.isSafeSnapshotFilename(name), "\(name)")
        }

        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(Self.date("2026-11-26T00:00:00Z"))
        let unsafeEvent = CameraEvent(
            id: UUID(),
            cameraID: "cam-front",
            kind: .doorbell,
            timestamp: now,
            snapshotFile: "C:\\Users\\test\\snapshot-1.jpeg"
        )
        let store = CameraEventStore(directory: root, clock: { now })
        #expect(store.snapshotData(for: unsafeEvent) == nil)
    }

    @Test("Camera events expire by clock and retain snapshots")
    func retentionAndSnapshotCleanup() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = CameraEventStore(directory: root, retention: 100, limit: 2, clock: { clock.value })
        let first = try #require(store.record(cameraID: "cam-a", kind: .doorbell, snapshotData: Data([1, 2, 3])))
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
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraEventStore(directory: root, clock: { Date(timeIntervalSince1970: 1) })
        let event = try #require(store.record(cameraID: "cam", kind: .doorbell, snapshotData: Data([9])))
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
