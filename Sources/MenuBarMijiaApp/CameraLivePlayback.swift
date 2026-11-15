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
    private(set) var lastFrameAt: ContinuousClock.Instant?
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
            self.lastFrameAt = ContinuousClock.now
            self.onFirstFrame?()
        }
        player.onFrameDecoded = { [weak self] _ in
            guard let self, self.task != nil else { return }
            self.lastFrameAt = ContinuousClock.now
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            var failedAttempts = 0
            var reconnectAttempts = 0
            while !Task.isCancelled {
                guard let self else { return }
                let attemptStartedAt = ContinuousClock.now
                self.lastFrameAt = nil
                let stallTimeout = self.stallTimeout
                let pollInterval = self.watchdogInterval
                let watchdog = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pollInterval)
                        guard !Task.isCancelled, let self else { return }
                        let reference = self.lastFrameAt ?? attemptStartedAt
                        if ContinuousClock.now - reference >= stallTimeout {
                            self.player.stop(failure: "stream stalled")
                            return
                        }
                    }
                }
                let outcome = await self.player.play(url: self.url)
                watchdog.cancel()
                guard !Task.isCancelled else { return }

                let sustainedPlayback = outcome.framesDecoded > 0
                    && (ContinuousClock.now - attemptStartedAt) >= self.stablePlaybackThreshold

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
        hasFrame = false
        lastFrameAt = nil
        failure = nil
    }

    private func pauseAfterFailure(_ detail: String?) {
        task = nil
        player.stop()
        hasFrame = false
        lastFrameAt = nil
        failure = CameraPlaybackTerminalFailure.reason(detail: detail)
        onFailure?(detail)
    }
}
