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

/// Home Assistant `remote.send_command` key-naming dialect per TV ecosystem.
public enum HARemoteProfile: String, CaseIterable, Codable, Sendable {
    case appleTV, androidTV, sonyBravia, roku, generic

    /// Deterministically picks an ecosystem dialect from HA registry metadata and entity clues.
    public static func infer(
        platform: String? = nil, manufacturer: String? = nil, model: String? = nil,
        identifiers: [[String]]? = nil, entityId: String? = nil, friendlyName: String? = nil
    ) -> HARemoteProfile {
        func domainProfile(_ raw: String?) -> HARemoteProfile? {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "apple_tv", "appletv": return .appleTV
            case "androidtv_remote", "androidtv", "android_tv", "android_tv_remote", "google_tv": return .androidTV
            case "braviatv", "bravia_tv", "sony_bravia", "sony_bravia_psk": return .sonyBravia
            case "roku": return .roku
            default: return nil
            }
        }
        if let hit = domainProfile(platform) { return hit }
        for pair in identifiers ?? [] { if let hit = domainProfile(pair.first) { return hit } }
        let mfg = manufacturer?.lowercased() ?? ""
        let text = [mfg, model?.lowercased() ?? "", entityId?.lowercased() ?? "", friendlyName?.lowercased() ?? ""].joined(separator: " ")
        if text.contains("apple_tv") || text.contains("appletv") || text.contains("apple tv") || (mfg.contains("apple") && text.contains("tv")) {
            return .appleTV
        }
        if ["androidtv", "android_tv", "android tv", "google_tv", "google tv", "shield", "chromecast"].contains(where: text.contains) {
            return .androidTV
        }
        if text.contains("bravia") || text.contains("sony") { return .sonyBravia }
        if text.contains("roku") { return .roku }
        return .generic
    }
}

/// The keys the TV remote pad can send. Closed so no free-form command reaches a TV.
public enum TVRemoteKey: String, CaseIterable, Codable, Sendable {
    case up, down, left, right, select, back, home, menu
    case volumeUp, volumeDown, mute, source

    private static let haCommandTable: [HARemoteProfile: [TVRemoteKey: String]] = [
        .appleTV: [.up: "up", .down: "down", .left: "left", .right: "right", .select: "select", .back: "menu", .home: "home", .menu: "menu", .volumeUp: "volume_up", .volumeDown: "volume_down", .mute: "mute", .source: "top_menu"],
        .androidTV: [.up: "DPAD_UP", .down: "DPAD_DOWN", .left: "DPAD_LEFT", .right: "DPAD_RIGHT", .select: "DPAD_CENTER", .back: "BACK", .home: "HOME", .menu: "MENU", .volumeUp: "VOLUME_UP", .volumeDown: "VOLUME_DOWN", .mute: "MUTE", .source: "TV_INPUT"],
        .sonyBravia: [.up: "Up", .down: "Down", .left: "Left", .right: "Right", .select: "Confirm", .back: "Return", .home: "Home", .menu: "Options", .volumeUp: "VolumeUp", .volumeDown: "VolumeDown", .mute: "Mute", .source: "Input"],
        .roku: [.up: "Up", .down: "Down", .left: "Left", .right: "Right", .select: "Select", .back: "Back", .home: "Home", .menu: "Info", .volumeUp: "VolumeUp", .volumeDown: "VolumeDown", .mute: "VolumeMute", .source: "Input"],
        .generic: [.up: "UP", .down: "DOWN", .left: "LEFT", .right: "RIGHT", .select: "ENTER", .back: "BACK", .home: "HOME", .menu: "MENU", .volumeUp: "VOLUME_UP", .volumeDown: "VOLUME_DOWN", .mute: "MUTE", .source: "INPUT"],
    ]

    /// Default generic Home Assistant `remote.send_command` name.
    public var homeAssistantCommand: String { homeAssistantCommand(for: .generic) }

    /// Ecosystem-adapted Home Assistant `remote.send_command` key name.
    public func homeAssistantCommand(for profile: HARemoteProfile) -> String {
        Self.haCommandTable[profile]?[self] ?? Self.haCommandTable[.generic]![self]!
    }

    /// MIoT action short names a Xiaomi TV spec may publish for this key (priority order; verified against `miot-spec.org`).
    public var miotActionNames: [String] {
        switch self {
        case .up: ["press-up", "up", "key-up"]
        case .down: ["press-down", "down", "key-down"]
        case .left: ["press-left", "left", "key-left"]
        case .right: ["press-right", "right", "key-right"]
        case .select: ["press-ok", "ok", "confirm", "press-confirm", "select", "enter"]
        case .back: ["press-back", "back", "return", "press-return"]
        case .home: ["press-home", "home", "go-home"]
        case .menu: ["press-menu", "menu", "press-settings"]
        case .volumeUp: ["press-volume-up", "volume-up", "key-volume-up"]
        case .volumeDown: ["press-volume-down", "volume-down", "key-volume-down"]
        case .mute: ["press-mute", "mute", "mute-on", "toggle-mute"]
        case .source: ["press-source", "press-input", "input", "source", "switch-input"]
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
