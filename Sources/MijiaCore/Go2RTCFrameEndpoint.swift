import Foundation

/// Builds the go2rtc still-frame URL for a stream that is already playing (#10).
///
/// `frame.jpeg` asks the producer go2rtc already holds for its next frame. A doorbell thumbnail
/// therefore only reuses a live view that is on screen; it never asks for a stream by name, which
/// would make go2rtc open a new P2P session to the camera.
public enum Go2RTCFrameEndpoint {
    /// `/api/frame.jpeg?src=<stream>` for a go2rtc playback URL (`stream.mp4`, `stream.mjpeg`,
    /// `stream.m3u8`). Returns nil for Home Assistant proxies, custom HLS URLs and demo cards,
    /// which carry no `src` the local bridge would recognise.
    public static func frameJPEGURL(fromPlaybackURL url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let source = components.queryItems?.first(where: { $0.name == "src" })?.value,
              !source.isEmpty else {
            return nil
        }
        var frame = components
        frame.path = "/api/frame.jpeg"
        // `stream.mp4` adds `&mp4`; frame.jpeg takes the source only.
        frame.queryItems = [URLQueryItem(name: "src", value: source)]
        return frame.url
    }
}
