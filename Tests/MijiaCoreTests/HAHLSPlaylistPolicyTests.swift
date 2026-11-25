import Foundation
import Testing
@testable import MijiaCore

struct HAHLSPlaylistPolicyTests {
    private let originURL = URL(string: "http://192.168.1.10:8123/api/hls/tok/master_playlist.m3u8")!
    private let mediaPlaylistURL = URL(string: "http://192.168.1.10:8123/api/hls/tok/playlist.m3u8")!

    @Test("Rewrites valid same-origin master and media playlists including relative paths, maps, keys, parts, and BOM")
    func rewritesValidSameOriginPlaylists() throws {
        let master = "\u{FEFF}#EXTM3U\r\n"
            + "#EXT-X-VERSION:7\r\n"
            + "#EXT-X-INDEPENDENT-SEGMENTS\r\n"
            + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Main\",URI=\"audio/index.m3u8\"\r\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS=\"avc1.64001f,mp4a.40.2\",AUDIO=\"aud\"\r\n"
            + "playlist.m3u8?v=1\r\n"

        let rewrittenMaster = try String(
            decoding: HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data(master.utf8),
                playlistURL: originURL,
                allowedOrigin: originURL
            ),
            as: UTF8.self
        )
        #expect(!rewrittenMaster.contains("\r"))
        #expect(rewrittenMaster.contains("URI=\"menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/audio/index.m3u8\""))
        #expect(rewrittenMaster.contains("\nmenubarhome-hls-http://192.168.1.10:8123/api/hls/tok/playlist.m3u8?v=1\n"))
        #expect(rewrittenMaster.contains("CODECS=\"avc1.64001f,mp4a.40.2\""))

        let media = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:3",
            "#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"720@0\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=key.bin?k=1,IV=0x01",
            "#EXT-X-KEY:METHOD=NONE",
            "#EXT-X-PART:DURATION=0.5,URI=\"/api/hls/tok/part0.m4s\",INDEPENDENT=YES",
            "#EXTINF:2.0,Camera Feed",
            "http://192.168.1.10:8123/api/hls/tok/seg0.m4s",
            "#EXTINF:2.0,",
            "../shared/seg1.m4s",
            "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"part1.m4s\"",
        ].joined(separator: "\n")

        let rewrittenMedia = try String(
            decoding: HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data(media.utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            ),
            as: UTF8.self
        )
        #expect(rewrittenMedia.contains("#EXT-X-MAP:URI=\"menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/init.mp4\",BYTERANGE=\"720@0\""))
        #expect(rewrittenMedia.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/key.bin?k=1\",IV=0x01"))
        #expect(rewrittenMedia.contains("#EXT-X-KEY:METHOD=NONE"))
        #expect(rewrittenMedia.contains("#EXT-X-PART:DURATION=0.5,URI=\"menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/part0.m4s\",INDEPENDENT=YES"))
        #expect(rewrittenMedia.contains("\nmenubarhome-hls-http://192.168.1.10:8123/api/hls/tok/seg0.m4s\n"))
        #expect(rewrittenMedia.contains("\nmenubarhome-hls-http://192.168.1.10:8123/api/hls/shared/seg1.m4s\n"))
        #expect(rewrittenMedia.contains("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"menubarhome-hls-http://192.168.1.10:8123/api/hls/tok/part1.m4s\""))
    }

    @Test("Handles bare CR line endings identically to AVFoundation and rejects smuggled cross-origin URIs")
    func handlesBareCarriageReturnLineEndings() throws {
        let safeBareCR = "#EXTM3U\r#EXTINF:2.0,\rseg0.ts\r"
        let rewritten = try String(
            decoding: HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data(safeBareCR.utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            ),
            as: UTF8.self
        )
        #expect(!rewritten.contains("\r"))
        #expect(rewritten == "#EXTM3U\n#EXTINF:2.0,\nmenubarhome-hls-http://192.168.1.10:8123/api/hls/tok/seg0.ts\n")

        let smuggledBareCR = "#EXTM3U\n#EXTINF:2.0,\rhttp://169.254.169.254/latest/meta-data/\nseg0.ts\n"
        #expect(throws: HAHLSPlaylistError.crossOriginURI) {
            _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data(smuggledBareCR.utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            )
        }
    }

    @Test("Rejects cross-origin, loopback, metadata, userinfo, and unquoted/malformed URI attributes fail-closed")
    func rejectsCrossOriginAndMalformedPlaylists() {
        let crossOriginPayloads = [
            "#EXTM3U\n#EXTINF:2.0,\nhttp://127.0.0.1:8080/secret.ts\n",
            "#EXTM3U\n#EXTINF:2.0,\nhttp://169.254.169.254/latest/meta-data/\n",
            "#EXTM3U\n#EXTINF:2.0,\n//attacker.example/evil.ts\n",
            "#EXTM3U\n#EXTINF:2.0,\nhttps://192.168.1.10:8123/api/hls/tok/seg0.ts\n",
            "#EXTM3U\n#EXTINF:2.0,\nhttp://user:pass@192.168.1.10:8123/api/hls/tok/seg0.ts\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://169.254.169.254/key\"\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=http://127.0.0.1:8080/key,IV=0x1\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,uri=http://attacker.example/key\n",
            "#EXTM3U\n#EXT-X-MAP:URI=\"http://127.0.0.1:8080/init.mp4\"\n",
            "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"a\",URI=\"https://evil.example/a.m3u8\"\n",
            "#EXTM3U\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,URI=\"http://127.0.0.1/iframe.m3u8\"\n",
            "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://evil.example/steer\"\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"ok.key\",URI=\"http://127.0.0.1/evil.key\"\n",
        ]
        for payload in crossOriginPayloads {
            #expect(throws: HAHLSPlaylistError.crossOriginURI, "expected cross-origin rejection for:\n\(payload)") {
                _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                    data: Data(payload.utf8),
                    playlistURL: mediaPlaylistURL,
                    allowedOrigin: originURL
                )
            }
        }

        let invalidURIPayloads = [
            "#EXTM3U\n#EXTINF:2.0,\nfile:///etc/passwd\n",
            "#EXTM3U\n#EXTINF:2.0,\nmenubarhome-hls-http://192.168.1.10:8123/api/hls/tok/seg0.ts\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"data:text/plain;base64,AAAA\"\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI='http://127.0.0.1/key'\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"\"\n",
            "#EXTM3U\n#EXTINF:2.0,\nhttp:\\\\169.254.169.254\\meta\n",
        ]
        for payload in invalidURIPayloads {
            #expect(throws: HAHLSPlaylistError.invalidURI, "expected invalidURI for:\n\(payload)") {
                _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                    data: Data(payload.utf8),
                    playlistURL: mediaPlaylistURL,
                    allowedOrigin: originURL
                )
            }
        }

        #expect(throws: HAHLSPlaylistError.disallowedTag) {
            _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data("#EXTM3U\n#EXT-X-DEFINE:NAME=\"h\",VALUE=\"169.254.169.254\"\nhttp://{$h}/x\n".utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            )
        }
        #expect(throws: HAHLSPlaylistError.malformedTag) {
            _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"unterminated.key\n".utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            )
        }
        #expect(throws: HAHLSPlaylistError.malformedTag) {
            _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"ok.key\"garbage\n".utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            )
        }
        #expect(throws: HAHLSPlaylistError.missingHeader) {
            _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data("seg0.ts\n".utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            )
        }
        #expect(throws: HAHLSPlaylistError.invalidEncoding) {
            _ = try HAHLSPlaylistPolicy.rewritePlaylist(
                data: Data("#EXTM3U\n\0seg0.ts\n".utf8),
                playlistURL: mediaPlaylistURL,
                allowedOrigin: originURL
            )
        }
    }

    @Test("Proxy scheme round-trips HTTP(S) URLs, detects spoofed extensionless playlists, and parses Content-Range")
    func schemeMappingDetectionAndContentRange() throws {
        let httpsURL = try #require(URL(string: "https://ha.example.com:8443/api/hls/abc/master.m3u8?token=1"))
        let proxied = try #require(HAHLSPlaylistPolicy.proxiedURL(from: httpsURL))
        #expect(proxied.scheme == HAHLSPlaylistPolicy.httpsProxyScheme)
        #expect(HAHLSPlaylistPolicy.originalURL(from: proxied) == httpsURL)

        let withUserInfo = try #require(URL(string: "http://user:pass@192.168.1.10:8123/master.m3u8"))
        #expect(HAHLSPlaylistPolicy.proxiedURL(from: withUserInfo) == nil)

        // Extensionless URL with application/octet-stream still detected via #EXTM3U body sniffing.
        let extensionless = try #require(URL(string: "http://192.168.1.10:8123/api/hls/stream"))
        #expect(HAHLSPlaylistPolicy.isPlaylistResponse(
            requestURL: extensionless,
            responseURL: extensionless,
            mimeType: "application/octet-stream",
            data: Data("\u{FEFF}#EXTM3U\nseg0.ts\n".utf8)
        ))
        #expect(HAHLSPlaylistPolicy.isPlaylistResponse(
            requestURL: extensionless,
            responseURL: extensionless,
            mimeType: "application/x-mpegurl; charset=utf-8",
            data: Data("not-extm3u".utf8)
        ))
        #expect(!HAHLSPlaylistPolicy.isPlaylistResponse(
            requestURL: try #require(URL(string: "http://192.168.1.10:8123/api/hls/seg0.ts")),
            responseURL: nil,
            mimeType: "video/mp2t",
            data: Data([0x47, 0x40, 0x11, 0x10])
        ))

        let range = try #require(HAHLSPlaylistPolicy.parseContentRange("bytes 0-1023/4096"))
        #expect(range.start == 0 && range.end == 1023 && range.total == 4096)
        let openTotal = try #require(HAHLSPlaylistPolicy.parseContentRange("bytes 10-19/*"))
        #expect(openTotal.start == 10 && openTotal.end == 19 && openTotal.total == nil)
        #expect(HAHLSPlaylistPolicy.parseContentRange("bytes 20-10/100") == nil)
        #expect(HAHLSPlaylistPolicy.parseContentRange("bytes 0-100/100") == nil)
    }
}
