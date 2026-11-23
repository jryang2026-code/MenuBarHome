import Foundation
import Testing
@testable import MijiaCore

/// #10: the still-frame URL is derived from a live playback URL, never from a bare stream name.
struct Go2RTCFrameEndpointTests {
    private func bridgeURL(path: String, query: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 18554
        components.user = "user"
        components.password = "bridge-token"
        components.path = path
        components.percentEncodedQuery = query
        return components.url!
    }

    @Test("A go2rtc mp4 playback becomes a frame.jpeg on the same bridge")
    func mp4Playback() {
        let playback = bridgeURL(path: "/api/stream.mp4", query: "src=cam_raw_abc123&mp4")
        let frame = Go2RTCFrameEndpoint.frameJPEGURL(fromPlaybackURL: playback)

        #expect(frame?.path == "/api/frame.jpeg")
        #expect(frame?.query == "src=cam_raw_abc123", "the mp4 flag is dropped, the source is kept")
        #expect(frame?.host == "127.0.0.1")
        #expect(frame?.port == 18554)
        #expect(frame?.user == "user")
        #expect(frame?.password == "bridge-token", "the basic-auth credentials reach the frame request")
    }

    @Test("MJPEG and HLS playbacks keep the source")
    func otherPlaybackShapes() {
        let mjpeg = bridgeURL(path: "/api/stream.mjpeg", query: "src=cam_mjpeg_abc")
        #expect(Go2RTCFrameEndpoint.frameJPEGURL(fromPlaybackURL: mjpeg)?.query == "src=cam_mjpeg_abc")

        let hls = bridgeURL(path: "/api/stream.m3u8", query: "src=cam_raw_abc")
        #expect(Go2RTCFrameEndpoint.frameJPEGURL(fromPlaybackURL: hls)?.query == "src=cam_raw_abc")
    }

    @Test("Home Assistant proxies, custom HLS URLs and demo cards have no local frame endpoint")
    func foreignSources() {
        #expect(Go2RTCFrameEndpoint.frameJPEGURL(fromPlaybackURL: URL(string: "http://ha.local:8123/api/camera_proxy/camera.door?token=abc")!) == nil)
        #expect(Go2RTCFrameEndpoint.frameJPEGURL(fromPlaybackURL: URL(string: "https://camera.example/live.m3u8")!) == nil)
        #expect(Go2RTCFrameEndpoint.frameJPEGURL(fromPlaybackURL: bridgeURL(path: "/api/stream.mp4", query: "src=&mp4")) == nil)
    }
}
