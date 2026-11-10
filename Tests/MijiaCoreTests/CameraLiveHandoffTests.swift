import Testing
@testable import MijiaCore

struct CameraLiveHandoffTests {
    @Test("A warm playback is dropped when the camera is pinned to the other source")
    func warmPlaybackRejectsABackendHandoff() {
        let parked = CameraWarmIdentity(entityID: "miot:cam-a:2", backend: .xiaomiCloud, pinnedBackend: nil)
        let pinned = CameraWarmIdentity(
            entityID: "camera.yard",
            backend: .homeAssistant,
            pinnedBackend: .homeAssistant
        )
        #expect(parked.matches(parked))
        #expect(!parked.matches(pinned))

        let sameCard = CameraWarmIdentity(entityID: "miot:cam-a:2", backend: .xiaomiCloud, pinnedBackend: .homeAssistant)
        #expect(!parked.matches(sameCard))
    }

    @Test("A warm playback is not reused after one dead read once a frame was shown")
    func deadReadAfterAFrameRejectsWarmReuse() {
        #expect(!CameraPlaybackReconnect.ended(framesDecoded: 4, alreadyHadFrame: true))
        #expect(!CameraPlaybackReconnect.ended(framesDecoded: 0, alreadyHadFrame: false))
        #expect(CameraPlaybackReconnect.ended(framesDecoded: 0, alreadyHadFrame: true))

        let dead = CameraPlaybackTerminalFailure.reason(detail: nil)
        #expect(!CameraWarmReuse.accepts(failure: dead, identityMatches: true))
        #expect(CameraWarmReuse.accepts(failure: nil, identityMatches: true))
        #expect(!CameraWarmReuse.accepts(failure: nil, identityMatches: false))
    }

    @Test("A stream that ends without an error detail is still a terminal failure")
    func nilDetailIsATerminalFailure() {
        #expect(CameraPlaybackTerminalFailure.reason(detail: nil) == CameraPlaybackTerminalFailure.unnamed)
        #expect(CameraPlaybackTerminalFailure.reason(detail: "  ") == CameraPlaybackTerminalFailure.unnamed)
        #expect(CameraPlaybackTerminalFailure.reason(detail: "timeout") == "timeout")
    }

    @Test("Reopening one camera still stops the other warm cameras")
    func closeSkipsOnlyTheCameraThatWasReopened() {
        #expect(CameraCloseRelease.shouldStop(deviceID: "cam-a", activeDeviceID: "cam-a", generationMatches: true))
        #expect(!CameraCloseRelease.shouldStop(deviceID: "cam-a", activeDeviceID: "cam-a", generationMatches: false))
        #expect(CameraCloseRelease.shouldStop(deviceID: "cam-b", activeDeviceID: "cam-a", generationMatches: false))
    }

    @Test("Maximize remembers the small frame, and a later resize starts from that frame")
    func maximizedFrameDoesNotBecomeTheStoredFrame() {
        let small = CameraWindowFrame(x: 100, y: 200, width: 360, height: 244)
        let screen = CameraWindowFrame(x: 0, y: 0, width: 1440, height: 900)
        #expect(CameraWindowFrames.frameToRemember(isMaximized: true, saved: small, current: screen) == small)
        #expect(CameraWindowFrames.frameToRemember(isMaximized: false, saved: nil, current: small) == small)
        #expect(CameraWindowFrames.anchorBeforeSizeToggle(isMaximized: true, saved: small, current: screen) == small)
        #expect(CameraWindowFrames.anchorBeforeSizeToggle(isMaximized: false, saved: nil, current: small) == small)
    }

    @Test("Picture in Picture teardown keeps a restore that stop already requested")
    func pipInvalidateDoesNotTurnRestoreIntoAClose() {
        #expect(!PictureInPictureCloseDecision.clearRestoreOnInvalidate(restoreAlreadyRequested: true))
        #expect(PictureInPictureCloseDecision.clearRestoreOnInvalidate(restoreAlreadyRequested: false))
        #expect(!PictureInPictureCloseDecision.shouldClosePanel(restoreRequested: true))
        #expect(PictureInPictureCloseDecision.shouldClosePanel(restoreRequested: false))
    }
}
