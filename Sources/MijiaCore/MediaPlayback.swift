import Foundation

/// What a TV reports it is playing, read from Home Assistant `media_player.*` attributes.
public struct MediaPlaybackState: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case playing, paused, buffering, idle, off
    }

    public var state: Status
    public var title: String?
    public var subtitle: String?
    public var appName: String?
    /// HA-relative `entity_picture` (`/api/media_player_proxy/…?token=…`); fetched only from the HA origin.
    public var artworkURL: String?
    public var durationSec: Double?
    public var positionSec: Double?
    public var positionUpdatedAt: Date?
    public var playbackRate: Double
    public var canPlayPause: Bool
    public var canSeek: Bool
    public var canSkipTrack: Bool

    public init(
        state: Status,
        title: String? = nil,
        subtitle: String? = nil,
        appName: String? = nil,
        artworkURL: String? = nil,
        durationSec: Double? = nil,
        positionSec: Double? = nil,
        positionUpdatedAt: Date? = nil,
        playbackRate: Double? = nil,
        canPlayPause: Bool = false,
        canSeek: Bool = false,
        canSkipTrack: Bool = false
    ) {
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.appName = appName
        self.artworkURL = artworkURL
        self.durationSec = durationSec
        self.positionSec = positionSec
        self.positionUpdatedAt = positionUpdatedAt
        self.playbackRate = playbackRate ?? (state == .playing ? 1.0 : 0.0)
        self.canPlayPause = canPlayPause
        self.canSeek = canSeek
        self.canSkipTrack = canSkipTrack
    }

    /// The drawer shows Now Playing only when there is something to name or control.
    public var hasContent: Bool {
        guard state != .off else { return false }
        return title != nil || appName != nil || state == .playing || state == .paused
    }

    public enum ProgressStyle: Equatable, Sendable {
        case seekable, readOnly, hidden
    }

    /// Never invents a bar: no known duration means no bar at all.
    public var progressStyle: ProgressStyle {
        guard let durationSec, durationSec > 0, positionSec != nil else { return .hidden }
        return canSeek ? .seekable : .readOnly
    }

    /// `clamp(anchor + elapsed × rate, 0, duration)`; only a playing item advances.
    public func extrapolatedPosition(at now: Date) -> Double? {
        guard let positionSec else { return nil }
        var position = positionSec
        if state == .playing, let anchor = positionUpdatedAt {
            let elapsed = max(0, now.timeIntervalSince(anchor))
            position += elapsed * playbackRate
        }
        let upper = durationSec.flatMap { $0 > 0 ? $0 : nil } ?? .greatestFiniteMagnitude
        return min(max(position, 0), upper)
    }

    // HA `MediaPlayerEntityFeature` bits.
    public static let featurePause = 1
    public static let featureSeek = 2
    public static let featurePreviousTrack = 16
    public static let featureNextTrack = 32
    public static let featurePlay = 16384

    /// Builds from a `media_player.*` state; nil when the entity reports nothing to show.
    public static func fromHomeAssistant(
        state rawState: String,
        attributes: [String: JSONValue],
        parseDate: (JSONValue?) -> Date?
    ) -> MediaPlaybackState? {
        let status: Status = switch rawState.lowercased() {
        case "playing": .playing
        case "paused": .paused
        case "buffering": .buffering
        case "off", "standby", "unavailable", "unknown": .off
        default: .idle
        }
        func text(_ key: String) -> String? {
            guard let raw = attributes[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }
        func seconds(_ key: String) -> Double? {
            guard let value = attributes[key]?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return value
        }
        let features = attributes["supported_features"]?.intValue ?? 0
        let playback = MediaPlaybackState(
            state: status,
            title: text("media_title"),
            subtitle: text("media_artist") ?? text("media_series_title") ?? text("media_album_name"),
            appName: text("app_name"),
            artworkURL: text("entity_picture"),
            durationSec: seconds("media_duration"),
            positionSec: seconds("media_position"),
            positionUpdatedAt: parseDate(attributes["media_position_updated_at"]),
            canPlayPause: features & (featurePause | featurePlay) != 0,
            canSeek: features & featureSeek != 0,
            canSkipTrack: features & (featureNextTrack | featurePreviousTrack) != 0
        )
        return playback.hasContent ? playback : nil
    }
}

/// The keys the TV remote pad can send. Closed so no free-form command reaches a TV.
public enum TVRemoteKey: String, CaseIterable, Codable, Sendable {
    case up, down, left, right, select, back, home, menu
    case volumeUp, volumeDown, mute, source

    /// The Home Assistant `remote.send_command` name most TV integrations accept.
    public var homeAssistantCommand: String {
        switch self {
        case .up: "UP"
        case .down: "DOWN"
        case .left: "LEFT"
        case .right: "RIGHT"
        case .select: "ENTER"
        case .back: "BACK"
        case .home: "HOME"
        case .menu: "MENU"
        case .volumeUp: "VOLUME_UP"
        case .volumeDown: "VOLUME_DOWN"
        case .mute: "MUTE"
        case .source: "INPUT"
        }
    }

    /// MIoT action short names a Xiaomi TV spec may publish for this key.
    public var miotActionNames: [String] {
        switch self {
        case .up: ["up", "press-up", "key-up"]
        case .down: ["down", "press-down", "key-down"]
        case .left: ["left", "press-left", "key-left"]
        case .right: ["right", "press-right", "key-right"]
        case .select: ["ok", "confirm", "select", "enter", "press-ok"]
        case .back: ["back", "return", "press-back"]
        case .home: ["home", "press-home", "go-home"]
        case .menu: ["menu", "press-menu"]
        case .volumeUp: ["volume-up"]
        case .volumeDown: ["volume-down"]
        case .mute: ["mute-on", "mute"]
        case .source: ["input", "source", "switch-input"]
        }
    }
}

/// Keeps a dragged seek bar from snapping back to the TV's stale position while the seek lands.
public struct MediaSeekGuard: Equatable, Sendable {
    public static let holdSeconds: TimeInterval = 2.0
    public private(set) var isDragging = false
    public private(set) var previewSec: Double?
    public private(set) var pendingTargetSec: Double?
    public private(set) var pendingUntil: Date?

    public init() {}

    public mutating func beginDrag(at positionSec: Double) {
        isDragging = true
        previewSec = positionSec
    }

    public mutating func updateDrag(to positionSec: Double) {
        guard isDragging else { return }
        previewSec = positionSec
    }

    /// Ends the drag and returns the single seek target to send.
    public mutating func endDrag(now: Date) -> Double? {
        guard isDragging, let target = previewSec else { return nil }
        isDragging = false
        previewSec = nil
        pendingTargetSec = target
        pendingUntil = now.addingTimeInterval(Self.holdSeconds)
        return target
    }

    public mutating func cancelPending() {
        pendingTargetSec = nil
        pendingUntil = nil
    }

    /// What the bar shows: the drag preview, the just-sent target while it lands, or the TV's position.
    public func displayedPosition(remote: Double?, at now: Date) -> Double? {
        if isDragging { return previewSec }
        if let target = pendingTargetSec, let until = pendingUntil, now < until { return target }
        return remote
    }
}
