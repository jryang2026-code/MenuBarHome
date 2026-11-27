import Foundation

/// Closed desktop ambient signals allowed in AI prompts/suggestions. Free-text OS strings
/// (calendar/window/app titles, Wi-Fi SSIDs, Focus labels) are excluded by type (ADR-0015).
public enum DesktopAmbientSignal: String, CaseIterable, Codable, Hashable, Sendable {
    case inMeeting, externalDisplayConnected, focusActive, lateNightWork, mediaPlaying

    public var promptTag: String {
        switch self {
        case .inMeeting: "会议中"
        case .externalDisplayConnected: "外接显示器"
        case .focusActive: "专注模式"
        case .lateNightWork: "深夜办公"
        case .mediaPlaying: "媒体播放中"
        }
    }
}

public struct DesktopAmbientContext: Codable, Equatable, Sendable {
    public var inMeeting, externalDisplayConnected, focusActive, lateNightWork, mediaPlaying: Bool
    public static let empty = DesktopAmbientContext()
    public init(inMeeting: Bool = false, externalDisplayConnected: Bool = false, focusActive: Bool = false, lateNightWork: Bool = false, mediaPlaying: Bool = false) {
        self.inMeeting = inMeeting; self.externalDisplayConnected = externalDisplayConnected
        self.focusActive = focusActive; self.lateNightWork = lateNightWork; self.mediaPlaying = mediaPlaying
    }
    public var activeSignals: [DesktopAmbientSignal] {
        let pairs: [(Bool, DesktopAmbientSignal)] = [
            (inMeeting, .inMeeting), (externalDisplayConnected, .externalDisplayConnected),
            (focusActive, .focusActive), (lateNightWork, .lateNightWork), (mediaPlaying, .mediaPlaying),
        ]
        return pairs.compactMap { $0.0 ? $0.1 : nil }
    }
    public var hasActiveSignals: Bool { !activeSignals.isEmpty }
    public var promptSummary: String { activeSignals.isEmpty ? "" : "桌面情境：" + activeSignals.map(\.promptTag).joined(separator: "、") }
    public var signatureToken: String { activeSignals.map(\.rawValue).joined(separator: ",") }
    /// Projects `MacContextSnapshot` to booleans only, discarding calendar titles, Wi-Fi SSIDs, and Focus names.
    public static func from(macSnapshot s: MacContextSnapshot, externalDisplayCount: Int = 0, mediaPlaying: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> DesktopAmbientContext {
        DesktopAmbientContext(
            inMeeting: (s.isCameraUsageAvailable && s.cameraInUse) || (s.isMicrophoneUsageAvailable && s.microphoneInUse),
            externalDisplayConnected: externalDisplayCount > 0, focusActive: s.isFocusActive == true,
            lateNightWork: s.isUserPresent && LateNightWindow(startHour: 23, endHour: 6).contains(now, calendar: calendar), mediaPlaying: mediaPlaying
        )
    }
    public static func mergeIntoEnvironment(_ environment: String, desktop: DesktopAmbientContext) -> String {
        let tag = desktop.promptSummary; guard !tag.isEmpty else { return environment }
        let trimmed = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? tag : (trimmed.contains(tag) ? trimmed : "\(trimmed)；\(tag)")
    }
}
