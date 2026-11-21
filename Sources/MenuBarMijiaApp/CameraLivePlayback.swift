import Foundation
import MijiaCore

/// One native P2P playback session. The player and its reconnect loop outlive the SwiftUI
/// surface, so switching to another camera can keep this session warm and reattach it later
/// without renegotiating the camera's single P2P connection.
@MainActor
final class CameraLivePlayback {
    let deviceID: String
    let lensID: String
    let source: CameraStreamSource
    let player: CameraLiveVideoPlayer

    private(set) var hasFrame = false
    private(set) var isPaused = false
    private(set) var failure: String?
    private let url: URL
    private let mjpegFallback: URL?
    private var task: Task<Void, Never>?

    var stallTimeout: Duration = .seconds(15)
    var watchdogInterval: Duration = .seconds(1)
    var stablePlaybackThreshold: Duration = .seconds(10)
    var reconnectBackoff: Duration = .milliseconds(400)
    var failureBackoff: Duration = .milliseconds(900)
    var maxFailedAttempts = 4
    var maxReconnectAttempts = 6

    var onFirstFrame: (@MainActor () -> Void)?
    var onFallback: (@MainActor (URL) -> Void)?
    var onFailure: (@MainActor (String?) -> Void)?
    var onWatchdogTick: (@MainActor () -> Void)?

    init?(deviceID: String, lensID: String, source: CameraStreamSource) {
        guard case .liveMP4(let url, let mjpegFallback, _) = source else { return nil }
        self.deviceID = deviceID
        self.lensID = lensID
        self.source = source
        self.url = url
        self.mjpegFallback = mjpegFallback
        self.player = CameraLiveVideoPlayer()
        player.onFirstFrame = { [weak self] in
            guard let self, self.task != nil else { return }
            self.hasFrame = true
            self.onFirstFrame?()
        }
        player.onPlaybackPauseChanged = { [weak self] paused in
            guard let self, self.task != nil else { return }
            let resumed = self.isPaused && !paused
            self.isPaused = paused
            if resumed {
                self.player.touchLastFrameTimestamp()
            }
        }
    }

    private static func nanosecondsToDuration(_ ns: UInt64) -> Duration {
        .nanoseconds(Int64(clamping: ns))
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            var failedAttempts = 0
            var reconnectAttempts = 0
            while !Task.isCancelled {
                guard let self else { return }
                let attemptStartedUptimeNs = max(DispatchTime.now().uptimeNanoseconds, 1)
                self.player.resetFrameTimestamps()
                self.isPaused = false
                let stallTimeout = self.stallTimeout
                let pollInterval = self.watchdogInterval
                let watchdog = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pollInterval)
                        guard !Task.isCancelled, let self else { return }
                        if self.isPaused {
                            self.onWatchdogTick?()
                            continue
                        }
                        let timestamps = self.player.decodedFrameTimestamps()
                        let referenceNs = timestamps.lastFrameUptimeNs != 0
                            ? timestamps.lastFrameUptimeNs
                            : attemptStartedUptimeNs
                        let nowNs = DispatchTime.now().uptimeNanoseconds
                        if nowNs >= referenceNs,
                           Self.nanosecondsToDuration(nowNs - referenceNs) >= stallTimeout {
                            self.onWatchdogTick?()
                            self.player.stop(failure: "stream stalled")
                            return
                        }
                        self.onWatchdogTick?()
                    }
                }
                let outcome = await self.player.play(url: self.url)
                watchdog.cancel()
                guard !Task.isCancelled else { return }

                let timestamps = self.player.decodedFrameTimestamps()
                let sustainedPlayback: Bool
                if outcome.framesDecoded >= 2,
                   timestamps.firstFrameUptimeNs != 0,
                   timestamps.lastFrameUptimeNs >= timestamps.firstFrameUptimeNs,
                   Self.nanosecondsToDuration(timestamps.lastFrameUptimeNs - timestamps.firstFrameUptimeNs) >= self.stablePlaybackThreshold {
                    sustainedPlayback = true
                } else {
                    sustainedPlayback = false
                }

                if outcome.framesDecoded > 0 {
                    if sustainedPlayback {
                        failedAttempts = 0
                        reconnectAttempts = 0
                    } else {
                        failedAttempts += 1
                        reconnectAttempts += 1
                    }
                    if failedAttempts >= self.maxFailedAttempts || reconnectAttempts >= self.maxReconnectAttempts {
                        self.pauseAfterFailure(outcome.failure)
                        return
                    }
                    try? await Task.sleep(for: self.reconnectBackoff)
                    continue
                }

                if CameraPlaybackReconnect.ended(
                    framesDecoded: outcome.framesDecoded,
                    alreadyHadFrame: self.hasFrame
                ) {
                    self.pauseAfterFailure(outcome.failure)
                    return
                }

                failedAttempts += 1
                reconnectAttempts += 1
                if failedAttempts >= 2, !self.hasFrame, let mjpegFallback = self.mjpegFallback {
                    self.player.stop()
                    self.task = nil
                    self.failure = "mjpeg fallback"
                    self.onFallback?(mjpegFallback)
                    return
                }
                if failedAttempts >= self.maxFailedAttempts || reconnectAttempts >= self.maxReconnectAttempts {
                    self.pauseAfterFailure(outcome.failure)
                    return
                }
                try? await Task.sleep(for: self.failureBackoff)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player.stop()
        player.resetFrameTimestamps()
        hasFrame = false
        isPaused = false
        failure = nil
    }

    private func pauseAfterFailure(_ detail: String?) {
        task = nil
        player.stop()
        player.resetFrameTimestamps()
        hasFrame = false
        isPaused = false
        failure = CameraPlaybackTerminalFailure.reason(detail: detail)
        onFailure?(detail)
    }
}
