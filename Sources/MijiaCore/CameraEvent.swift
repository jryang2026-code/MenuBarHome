import Foundation

/// A camera activity captured locally from an already parsed provider event.
public struct CameraEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case doorbell
        case motion
        case person
        case package
    }

    public let id: UUID
    public let cameraID: String
    public let kind: Kind
    public let timestamp: Date
    /// A relative filename owned by `CameraEventStore`, never a URL or credential.
    public let snapshotFile: String?

    public init(id: UUID = UUID(), cameraID: String, kind: Kind, timestamp: Date, snapshotFile: String? = nil) {
        self.id = id
        self.cameraID = cameraID
        self.kind = kind
        self.timestamp = timestamp
        self.snapshotFile = snapshotFile
    }
}

/// Small, file-backed event history. The bounds are enforced on every write and load.
public final class CameraEventStore: @unchecked Sendable {
    public typealias Clock = @Sendable () -> Date
    public static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60
    public static let defaultLimit = 500

    private let directory: URL
    private let eventsURL: URL
    private let retention: TimeInterval
    private let limit: Int
    private let clock: Clock
    private let lock = NSLock()
    private var events: [CameraEvent] = []

    public init(
        directory: URL? = nil,
        retention: TimeInterval = CameraEventStore.defaultRetention,
        limit: Int = CameraEventStore.defaultLimit,
        clock: @escaping Clock = Date.init
    ) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MenuBarHome", isDirectory: true)
            .appendingPathComponent("CameraEvents", isDirectory: true))
        self.directory = base
        self.eventsURL = base.appendingPathComponent("events.json")
        self.retention = max(0, retention)
        self.limit = max(1, limit)
        self.clock = clock
        load()
    }

    public func allEvents() -> [CameraEvent] {
        lock.withLock { events }
    }

    public func latestEvent(for cameraID: String) -> CameraEvent? {
        lock.withLock { events.first { $0.cameraID == cameraID } }
    }

    public func snapshotData(for event: CameraEvent) -> Data? {
        guard let name = event.snapshotFile, Self.isSafeFilename(name) else { return nil }
        return lock.withLock { try? Data(contentsOf: directory.appendingPathComponent(name)) }
    }

    @discardableResult
    public func attachSnapshot(_ data: Data, to event: CameraEvent) -> CameraEvent? {
        lock.withLock {
            guard let index = events.firstIndex(where: { $0.id == event.id && $0.snapshotFile == nil }) else { return nil }
            let name = "snapshot-\(event.id.uuidString).jpeg"
            let updated = CameraEvent(id: event.id, cameraID: event.cameraID, kind: event.kind, timestamp: event.timestamp, snapshotFile: name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                events[index] = updated
                try persistLocked()
                return updated
            } catch {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                return nil
            }
        }
    }

    public func clear() {
        lock.withLock {
            events.removeAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @discardableResult
    public func record(
        cameraID: String,
        kind: CameraEvent.Kind,
        timestamp: Date? = nil,
        snapshotData: Data? = nil
    ) -> CameraEvent {
        lock.withLock {
            let now = timestamp ?? clock()
            let snapshotFile = snapshotData.map { _ in "snapshot-\(UUID().uuidString).jpeg" }
            let event = CameraEvent(cameraID: cameraID, kind: kind, timestamp: now, snapshotFile: snapshotFile)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let snapshotData, let snapshotFile {
                    try snapshotData.write(to: directory.appendingPathComponent(snapshotFile), options: .atomic)
                }
                events.insert(event, at: 0)
                pruneLocked(now: now)
                try persistLocked()
            } catch {
                if let snapshotFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(snapshotFile)) }
            }
            return event
        }
    }

    private func persistLocked() throws {
        try JSONEncoder.cameraEvent.encode(events).write(to: eventsURL, options: .atomic)
    }

    private func load() {
        lock.withLock {
            events = (try? Data(contentsOf: eventsURL)).flatMap { try? JSONDecoder.cameraEvent.decode([CameraEvent].self, from: $0) } ?? []
            pruneLocked(now: clock())
        }
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let kept = Array(events.filter { $0.timestamp >= cutoff }.prefix(limit))
        let removed = events.filter { !kept.contains($0) }
        events = kept
        for event in removed {
            if let name = event.snapshotFile, Self.isSafeFilename(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    private static func isSafeFilename(_ name: String) -> Bool {
        name == URL(fileURLWithPath: name).lastPathComponent && !name.isEmpty
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

private extension JSONEncoder {
    static var cameraEvent: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var cameraEvent: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
