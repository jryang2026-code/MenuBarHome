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
        guard let name = event.snapshotFile, Self.isSafeSnapshotFilename(name) else { return nil }
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
                try JSONEncoder.cameraEvent.encode(events).write(to: eventsURL, options: .atomic)
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

    /// Records an event, rejecting camera IDs that could carry a URL, credentials, or control
    /// characters. Mirrors Windows `CameraEventStore.record` by returning `nil` when rejected.
    @discardableResult
    public func record(
        cameraID: String,
        kind: CameraEvent.Kind,
        timestamp: Date? = nil,
        snapshotData: Data? = nil
    ) -> CameraEvent? {
        guard Self.isSafeCameraId(cameraID) else { return nil }
        return lock.withLock {
            let now = timestamp ?? clock()
            let snapshotFile = snapshotData.map { _ in "snapshot-\(UUID().uuidString).jpeg" }
            let event = CameraEvent(cameraID: cameraID, kind: kind, timestamp: now, snapshotFile: snapshotFile)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let snapshotData, let snapshotFile {
                    try snapshotData.write(to: directory.appendingPathComponent(snapshotFile), options: .atomic)
                }
                events.insert(event, at: 0)
                pruneLocked(now: clock())
                try JSONEncoder.cameraEvent.encode(events).write(to: eventsURL, options: .atomic)
            } catch {
                if let snapshotFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(snapshotFile)) }
            }
            return event
        }
    }

    private func load() {
        lock.withLock {
            let rawEvents = (try? Data(contentsOf: eventsURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any] ?? []
            // One corrupt row must not erase the whole retention window: sanitize each element
            // independently, exactly like Windows `sanitizeCameraEventRecord`.
            events = rawEvents.compactMap(Self.sanitize)
            pruneLocked(now: clock())
        }
    }

    /// Mirrors Windows `sanitizeCameraEventRecord`: unsafe fields are dropped, never persisted into
    /// the in-memory history. A non-object row (including a bare JSON string) is simply skipped.
    static func sanitize(_ raw: Any) -> CameraEvent? {
        guard let object = raw as? [String: Any],
              let rawID = object["id"] as? String,
              let id = sanitizedID(rawID),
              let cameraID = object["cameraID"] as? String, isSafeCameraId(cameraID),
              let rawKind = object["kind"] as? String,
              let kind = CameraEvent.Kind(rawValue: rawKind),
              let rawTimestamp = object["timestamp"] as? String,
              let timestamp = parseTimestamp(rawTimestamp) else { return nil }
        let snapshotFile: String?
        switch object["snapshotFile"] {
        case let name as String:
            snapshotFile = isSafeSnapshotFilename(name) ? name : nil
        default:
            snapshotFile = nil
        }
        return CameraEvent(id: id, cameraID: cameraID, kind: kind, timestamp: timestamp, snapshotFile: snapshotFile)
    }

    private static func sanitizedID(_ raw: String) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar.value == 45 || scalar.value == 95
              }) else { return nil }
        return UUID(uuidString: trimmed)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = fractional.date(from: trimmed) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        wholeSeconds.timeZone = TimeZone(secondsFromGMT: 0)
        return wholeSeconds.date(from: trimmed)
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let kept = Array(events.filter { $0.timestamp >= cutoff }.prefix(limit))
        let removed = events.filter { !kept.contains($0) }
        events = kept
        for event in removed {
            if let name = event.snapshotFile, Self.isSafeSnapshotFilename(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Windows `isSafeCameraId`: no blanks, URLs, whitespace, or control characters.
    static func isSafeCameraId(_ cameraID: String) -> Bool {
        let trimmed = cameraID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256, trimmed == cameraID,
              !trimmed.contains("://") else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x1f && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    /// Windows `isSafeSnapshotFilename`, including Windows separators and drive letters so a
    /// crafted record cannot escape the event directory on either platform.
    static func isSafeSnapshotFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        for forbidden in ["..", "/", "\\", "://", ":", "?", "#", "@"] {
            if name.contains(forbidden) { return false }
        }
        let lower = name.lowercased()
        let stem: Substring
        if lower.hasPrefix("snapshot-"), lower.hasSuffix(".jpeg") {
            stem = name.dropFirst("snapshot-".count).dropLast(".jpeg".count)
        } else if lower.hasPrefix("snapshot-"), lower.hasSuffix(".jpg") {
            stem = name.dropFirst("snapshot-".count).dropLast(".jpg".count)
        } else {
            return false
        }
        guard !stem.isEmpty else { return false }
        return stem.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar.value == 46 || scalar.value == 95 || scalar.value == 45
        }
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
