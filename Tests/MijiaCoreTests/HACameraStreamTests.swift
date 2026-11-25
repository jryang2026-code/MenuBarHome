import Foundation
import Testing
@testable import MijiaCore

struct HACameraStreamTests {
    private func camera(stream: String? = nil, snapshot: String? = nil) -> SmartDevice {
        SmartDevice(
            id: "ha-cam", name: "门口", roomId: "door", roomName: "门口", model: "generic.camera", isOnline: true,
            kind: .camera(CameraSpec(entityId: "switch.door_cam", isOn: true, streamEntityId: stream, snapshotPath: snapshot))
        )
    }

    @Test("Without HLS, an HA camera entity plays as MJPEG instead of 1 fps snapshots")
    func cameraEntityFallsBackToMJPEG() async throws {
        let provider = HAWebSocketProvider(baseURLString: "http://192.168.1.10:8123", token: "t", onAddressSuggestion: nil)
        let source = try await provider.resolveCameraStream(
            for: camera(stream: "camera.door", snapshot: "/api/camera_proxy/camera.door?token=abc123")
        )
        #expect(source == .mjpeg(URL(string: "http://192.168.1.10:8123/api/camera_proxy_stream/camera.door?token=abc123")!))
    }

    @Test("A non-proxy snapshot path still plays as snapshots")
    func plainSnapshotStaysSnapshot() async throws {
        let provider = HAWebSocketProvider(baseURLString: "http://192.168.1.10:8123", token: "t", onAddressSuggestion: nil)
        let source = try await provider.resolveCameraStream(for: camera(snapshot: "/local/door.jpg"))
        #expect(source == .snapshot(URL(string: "http://192.168.1.10:8123/local/door.jpg")!))
    }

    @Test("A camera with no HA video still reports the 404 with a Mi sign-in hint")
    func noVideoThrows404() async {
        let provider = HAWebSocketProvider(baseURLString: "http://192.168.1.10:8123", token: "t", onAddressSuggestion: nil)
        do {
            _ = try await provider.resolveCameraStream(for: camera())
            Issue.record("expected a 404")
        } catch HomeProviderError.serviceCallFailed(let code, _) {
            #expect(code == 404)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Mi sign-in is offered only for an HA camera with no video and no Mi account")
    func miSignInOffer() {
        let bare = CameraSpec(entityId: "switch.cam", isOn: true)
        #expect(bare.offersMiSignInForVideo(backend: .homeAssistant, hasMiSource: false))
        #expect(!bare.offersMiSignInForVideo(backend: .homeAssistant, hasMiSource: true))
        #expect(!bare.offersMiSignInForVideo(backend: .xiaomiCloud, hasMiSource: false))
        let streaming = CameraSpec(entityId: "switch.cam", isOn: true, streamEntityId: "camera.cam")
        #expect(!streaming.offersMiSignInForVideo(backend: .homeAssistant, hasMiSource: false))
        let snapshot = CameraSpec(entityId: "switch.cam", isOn: true, snapshotPath: "/api/camera_proxy/camera.cam?token=t")
        #expect(!snapshot.offersMiSignInForVideo(backend: .homeAssistant, hasMiSource: false))
    }

    @Test("resolveStreamURL allows same-origin relative and absolute HA URLs and blocks cross-origin or malformed targets")
    func resolveStreamURLEnforcesSameOrigin() {
        let base = "http://192.168.1.10:8123"
        #expect(HAWebSocketProvider.resolveStreamURL(pathOrURL: "/api/hls/abc/master_playlist.m3u8", baseURLString: base) == URL(string: "\(base)/api/hls/abc/master_playlist.m3u8"))
        #expect(HAWebSocketProvider.resolveStreamURL(pathOrURL: "\(base)/api/camera_proxy/camera.door?token=t", baseURLString: base) == URL(string: "\(base)/api/camera_proxy/camera.door?token=t"))
        #expect(HAWebSocketProvider.resolveStreamURL(pathOrURL: "https://ha.example.com:443/local/door.jpg", baseURLString: "https://ha.example.com/") == URL(string: "https://ha.example.com:443/local/door.jpg"))
        for blocked in [
            "http://127.0.0.1:8080/admin", "http://169.254.169.254/latest/meta-data/",
            "http://[64:ff9b::127.0.0.1]:8123/stream.m3u8", "https://attacker.example/evil.m3u8",
            "http://192.168.1.10:9999/api/hls/abc/master_playlist.m3u8", "https://192.168.1.10:8123/api/hls/abc/master_playlist.m3u8",
            "http://user:pass@192.168.1.10:8123/api/hls/abc/master_playlist.m3u8",
            "//attacker.example/evil.m3u8", "file:///etc/passwd", "rtsp://192.168.1.10/live",
        ] {
            #expect(HAWebSocketProvider.resolveStreamURL(pathOrURL: blocked, baseURLString: base) == nil, "\(blocked)")
        }
        #expect(HAWebSocketProvider.resolveStreamURL(pathOrURL: "/api/hls/abc/master_playlist.m3u8", baseURLString: "") == nil)
    }

    @Test("resolveCameraStream rejects prohibited HA host literals and cross-origin HLS responses", .timeLimit(.minutes(1)))
    func resolveCameraStreamBlocksProhibitedAndCrossOriginTargets() async throws {
        for base in ["http://127.0.0.1:8123", "http://169.254.169.254:8123", "http://[64:ff9b::127.0.0.1]:8123"] {
            let provider = HAWebSocketProvider(baseURLString: base, token: "t", onAddressSuggestion: nil)
            await #expect(throws: HAEndpointResolutionError.prohibitedAddress) {
                _ = try await provider.resolveCameraStream(for: camera(snapshot: "/api/camera_proxy/camera.door?token=abc"))
            }
        }
        for (replyURL, expected) in [
            ("http://169.254.169.254/latest/meta-data/master.m3u8", nil as URL?),
            ("/api/hls/token123/master_playlist.m3u8", URL(string: "http://192.168.1.10:8123/api/hls/token123/master_playlist.m3u8")),
        ] {
            let socket = FixtureSocket(
                root: ["camera/stream": .object(["url": .string(replyURL)])],
                compressedSnapshot: ["id": .number(4), "type": .string("event"), "event": .object([:])]
            )
            let provider = HAWebSocketProvider(baseURLString: "http://192.168.1.10:8123", token: "t", rediscover: { _ in [] }, allowsToken: { _ in true })
            await provider.setTestSeams(connectOverride: nil, webSocketFactory: { _ in socket })
            var events = provider.events().makeAsyncIterator()
            while let event = await events.next() { if case .snapshotUpdated = event { break } }
            if let expected {
                #expect(try await provider.resolveCameraStream(for: camera(stream: "camera.door")) == .hls(expected))
            } else {
                do {
                    _ = try await provider.resolveCameraStream(for: camera(stream: "camera.door"))
                    Issue.record("Cross-origin camera/stream HLS URL should not be returned")
                } catch HomeProviderError.serviceCallFailed(let code, _) { #expect(code == 404) }
            }
            await provider.shutdown()
        }
    }
}
