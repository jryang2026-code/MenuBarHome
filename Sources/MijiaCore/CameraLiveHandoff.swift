import Foundation

/// What a warm playback was opened against. Restoring it after a pin or a backend
/// switch would show the stream the previous source already released.
public struct CameraWarmIdentity: Equatable, Sendable {
    public var entityID: String?
    public var backend: HomeBackend
    public var pinnedBackend: HomeBackend?

    public init(entityID: String?, backend: HomeBackend, pinnedBackend: HomeBackend?) {
        self.entityID = entityID
        self.backend = backend
        self.pinnedBackend = pinnedBackend
    }

    public func matches(_ other: CameraWarmIdentity) -> Bool {
        entityID == other.entityID && backend == other.backend && pinnedBackend == other.pinnedBackend
    }
}

/// Whether a parked live session can be attached again. A nil failure is the
/// only healthy state. One dead read after a frame has to set that failure,
/// or the window paints the frozen last frame for the rest of the warm period.
public enum CameraWarmReuse {
    public static func accepts(failure: String?, identityMatches: Bool) -> Bool {
        identityMatches && failure == nil
    }
}

/// What one fMP4 read means for the reconnect loop.
public enum CameraPlaybackReconnect {
    /// After a picture has been shown, a read that decodes nothing is the end
    /// of the session. The relay is gone, and another retry would leave
    /// `failure` nil while the last frame stays on screen.
    public static func ended(framesDecoded: Int, alreadyHadFrame: Bool) -> Bool {
        framesDecoded == 0 && alreadyHadFrame
    }
}

/// A playback that ran out of frames is finished even when the player reports no detail.
public enum CameraPlaybackTerminalFailure {
    public static let unnamed = "stream ended"

    public static func reason(detail: String?) -> String {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unnamed : trimmed
    }
}

/// Closing the window stops every parked camera except the one the user just reopened.
public enum CameraCloseRelease {
    public static func shouldStop(deviceID: String, activeDeviceID: String?, generationMatches: Bool) -> Bool {
        if generationMatches { return true }
        return deviceID != activeDeviceID
    }
}

public struct CameraWindowFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum CameraWindowFrames {
    /// The rect written to defaults. A maximized window stores the small frame, not the screen.
    public static func frameToRemember(
        isMaximized: Bool,
        saved: CameraWindowFrame?,
        current: CameraWindowFrame
    ) -> CameraWindowFrame? {
        if isMaximized { return saved }
        return current
    }

    /// Double-click and the expand control resize from the pre-maximize frame.
    public static func anchorBeforeSizeToggle(
        isMaximized: Bool,
        saved: CameraWindowFrame?,
        current: CameraWindowFrame
    ) -> CameraWindowFrame {
        if isMaximized, let saved { return saved }
        return current
    }
}

/// `stop()` asks Picture in Picture to come back. A later invalidate must not turn that into a close.
public enum PictureInPictureCloseDecision {
    public static func clearRestoreOnInvalidate(restoreAlreadyRequested: Bool) -> Bool {
        !restoreAlreadyRequested
    }

    public static func shouldClosePanel(restoreRequested: Bool) -> Bool {
        !restoreRequested
    }
}
