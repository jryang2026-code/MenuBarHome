import Foundation

public enum HAHLSPlaylistError: Error, Equatable, Sendable {
    case invalidEncoding
    case oversizedPlaylist
    case missingHeader
    case disallowedTag
    case malformedTag
    case invalidURI
    case crossOriginURI
}

/// Pure-Foundation HLS playlist boundary policy shared by macOS playback and Linux core tests.
/// Rewrites every playlist URI reference to a custom internal scheme so `AVPlayer` cannot bypass
/// `AVAssetResourceLoaderDelegate` for cross-origin, loopback, metadata, or redirecting sub-requests.
public enum HAHLSPlaylistPolicy {
    public static let httpProxyScheme = "menubarhome-hls-http"
    public static let httpsProxyScheme = "menubarhome-hls-https"
    public static let maxPlaylistBytes = 2 * 1024 * 1024

    private static let playlistMIMETypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl",
        "vnd.apple.mpegurl",
    ]

    private static let uriBearingTags: Set<String> = [
        "#EXT-X-KEY",
        "#EXT-X-SESSION-KEY",
        "#EXT-X-MAP",
        "#EXT-X-MEDIA",
        "#EXT-X-I-FRAME-STREAM-INF",
        "#EXT-X-PART",
        "#EXT-X-PRELOAD-HINT",
        "#EXT-X-RENDITION-REPORT",
        "#EXT-X-SESSION-DATA",
        "#EXT-X-CONTENT-STEERING",
    ]

    public static func proxiedURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              components.user == nil,
              components.password == nil,
              let host = components.host, !host.isEmpty else {
            return nil
        }
        switch scheme {
        case "http":
            components.scheme = httpProxyScheme
        case "https":
            components.scheme = httpsProxyScheme
        default:
            return nil
        }
        return components.url
    }

    public static func originalURL(from proxiedURL: URL) -> URL? {
        guard var components = URLComponents(url: proxiedURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              components.user == nil,
              components.password == nil,
              let host = components.host, !host.isEmpty else {
            return nil
        }
        switch scheme {
        case httpProxyScheme:
            components.scheme = "http"
        case httpsProxyScheme:
            components.scheme = "https"
        default:
            return nil
        }
        return components.url
    }

    public static func looksLikePlaylistURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }

    public static func isPlaylistResponse(
        requestURL: URL,
        responseURL: URL?,
        mimeType: String?,
        data: Data
    ) -> Bool {
        if looksLikePlaylistURL(requestURL) || responseURL.map(looksLikePlaylistURL) == true {
            return true
        }
        if let mimeType {
            let normalized = mimeType
                .split(separator: ";", maxSplits: 1)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            if playlistMIMETypes.contains(normalized) {
                return true
            }
        }
        return hasEXTM3UPrefix(data)
    }

    /// Parses an HTTP `Content-Range: bytes start-end/total` (or `/*`) header.
    public static func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let lower = raw.lowercased()
        guard lower.hasPrefix("bytes ") else { return nil }
        let spec = raw.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let slashParts = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard slashParts.count == 2 else { return nil }
        let rangeParts = slashParts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]),
              start >= 0, end >= start else {
            return nil
        }
        let totalToken = slashParts[1]
        if totalToken == "*" {
            return (start, end, nil)
        }
        guard let total = Int64(totalToken), end < total else { return nil }
        return (start, end, total)
    }

    /// Validates and rewrites every URI reference in an M3U8 playlist fail-closed.
    /// Splits lines on `\r\n`, `\n`, and bare `\r` to match AVFoundation, handles both quoted and
    /// unquoted `URI=` / `*-URI=` tag attributes, and rejects `#EXT-X-DEFINE` variable substitution.
    public static func rewritePlaylist(
        data: Data,
        playlistURL: URL,
        allowedOrigin: URL
    ) throws -> Data {
        guard data.count <= maxPlaylistBytes else {
            throw HAHLSPlaylistError.oversizedPlaylist
        }
        guard !data.contains(0), var text = String(data: data, encoding: .utf8) else {
            throw HAHLSPlaylistError.invalidEncoding
        }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        guard let playlistScheme = playlistURL.scheme?.lowercased(),
              playlistScheme == "http" || playlistScheme == "https",
              HAPlaintextConsent.hasSameOrigin(playlistURL, as: allowedOrigin) else {
            throw HAHLSPlaylistError.crossOriginURI
        }

        let lines = try splitLines(text)
        guard let firstNonEmpty = lines.first(where: { !trimASCIIWhitespace($0).isEmpty }),
              trimASCIIWhitespace(firstNonEmpty) == "#EXTM3U" else {
            throw HAHLSPlaylistError.missingHeader
        }

        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = trimASCIIWhitespace(line)
            if trimmed.isEmpty {
                rewritten.append("")
            } else if trimmed.hasPrefix("#") {
                if trimmed.uppercased().hasPrefix("#EXT") {
                    rewritten.append(try rewriteTagLine(trimmed, playlistURL: playlistURL, allowedOrigin: allowedOrigin))
                } else {
                    rewritten.append(trimmed)
                }
            } else {
                let target = try rewriteURIReference(trimmed, playlistURL: playlistURL, allowedOrigin: allowedOrigin)
                rewritten.append(target.absoluteString)
            }
        }

        return Data((rewritten.joined(separator: "\n") + "\n").utf8)
    }

    private static func hasEXTM3UPrefix(_ data: Data) -> Bool {
        var idx = data.startIndex
        if data.count >= 3,
           data[idx] == 0xEF,
           data[data.index(idx, offsetBy: 1)] == 0xBB,
           data[data.index(idx, offsetBy: 2)] == 0xBF {
            idx = data.index(idx, offsetBy: 3)
        }
        while idx < data.endIndex {
            let byte = data[idx]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                idx = data.index(after: idx)
            } else {
                break
            }
        }
        let header: [UInt8] = [0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55] // #EXTM3U
        guard data.distance(from: idx, to: data.endIndex) >= header.count else { return false }
        for offset in 0..<header.count {
            var byte = data[data.index(idx, offsetBy: offset)]
            if byte >= 0x61 && byte <= 0x7A { byte -= 0x20 }
            if byte != header[offset] { return false }
        }
        let afterIdx = data.index(idx, offsetBy: header.count)
        if afterIdx == data.endIndex { return true }
        let next = data[afterIdx]
        return next == 0x0A || next == 0x0D || next == 0x20 || next == 0x09
    }

    private static func splitLines(_ text: String) throws -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        var pending: UnicodeScalar?
        while let scalar = pending ?? iterator.next() {
            pending = nil
            if scalar == "\r" {
                lines.append(String(current))
                current.removeAll(keepingCapacity: true)
                if let next = iterator.next(), next != "\n" {
                    pending = next
                }
            } else if scalar == "\n" {
                lines.append(String(current))
                current.removeAll(keepingCapacity: true)
            } else if (scalar.value < 0x20 && scalar != "\t")
                || scalar.value == 0x7F
                || scalar == "\u{0085}"
                || scalar == "\u{2028}"
                || scalar == "\u{2029}" {
                throw HAHLSPlaylistError.invalidEncoding
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty || lines.isEmpty {
            lines.append(String(current))
        }
        return lines
    }

    private static func rewriteTagLine(
        _ line: String,
        playlistURL: URL,
        allowedOrigin: URL
    ) throws -> String {
        guard let colon = line.firstIndex(of: ":") else {
            let upper = line.uppercased()
            if upper == "#EXT-X-DEFINE" { throw HAHLSPlaylistError.disallowedTag }
            if uriBearingTags.contains(upper) { throw HAHLSPlaylistError.malformedTag }
            return line
        }
        let tagName = String(line[..<colon])
        let upperTag = tagName.uppercased()
        if upperTag == "#EXT-X-DEFINE" {
            throw HAHLSPlaylistError.disallowedTag
        }
        if upperTag == "#EXTINF" {
            return line
        }
        let payload = String(line[line.index(after: colon)...])
        if !payload.contains("=") {
            if uriBearingTags.contains(upperTag) {
                throw HAHLSPlaylistError.malformedTag
            }
            return line
        }
        let rewrittenPayload = try rewriteAttributeList(
            payload,
            playlistURL: playlistURL,
            allowedOrigin: allowedOrigin
        )
        return "\(tagName):\(rewrittenPayload)"
    }

    private static func rewriteAttributeList(
        _ payload: String,
        playlistURL: URL,
        allowedOrigin: URL
    ) throws -> String {
        var index = payload.startIndex
        let end = payload.endIndex
        var parts: [String] = []

        func skipHorizontalSpace() {
            while index < end && (payload[index] == " " || payload[index] == "\t") {
                index = payload.index(after: index)
            }
        }

        while index < end {
            skipHorizontalSpace()
            if index == end { break }

            let keyStart = index
            while index < end && payload[index] != "=" && payload[index] != "," && payload[index] != "\"" {
                index = payload.index(after: index)
            }
            guard index < end, payload[index] == "=" else {
                throw HAHLSPlaylistError.malformedTag
            }
            let trimmedKey = trimASCIIWhitespace(String(payload[keyStart..<index]))
            guard !trimmedKey.isEmpty else {
                throw HAHLSPlaylistError.malformedTag
            }

            index = payload.index(after: index) // skip '='
            skipHorizontalSpace()
            guard index < end else {
                throw HAHLSPlaylistError.malformedTag
            }

            let value: String
            let preserved: String
            if payload[index] == "\"" {
                index = payload.index(after: index) // skip opening '"'
                let valueStart = index
                while index < end && payload[index] != "\"" {
                    index = payload.index(after: index)
                }
                guard index < end, payload[index] == "\"" else {
                    throw HAHLSPlaylistError.malformedTag
                }
                value = String(payload[valueStart..<index])
                index = payload.index(after: index) // skip closing '"'
                skipHorizontalSpace()
                if index < end {
                    guard payload[index] == "," else {
                        throw HAHLSPlaylistError.malformedTag
                    }
                    index = payload.index(after: index)
                }
                preserved = "\(trimmedKey)=\"\(value)\""
            } else {
                let valueStart = index
                while index < end && payload[index] != "," {
                    if payload[index] == "\"" {
                        throw HAHLSPlaylistError.malformedTag
                    }
                    index = payload.index(after: index)
                }
                value = trimASCIIWhitespace(String(payload[valueStart..<index]))
                if index < end {
                    index = payload.index(after: index) // skip ','
                }
                preserved = "\(trimmedKey)=\(value)"
            }

            let upperKey = trimmedKey.uppercased()
            if upperKey == "URI" || upperKey.hasSuffix("-URI") {
                guard !value.isEmpty, !value.hasPrefix("'"), !value.hasSuffix("'") else {
                    throw HAHLSPlaylistError.invalidURI
                }
                let rewritten = try rewriteURIReference(value, playlistURL: playlistURL, allowedOrigin: allowedOrigin)
                parts.append("\(trimmedKey)=\"\(rewritten.absoluteString)\"")
            } else {
                parts.append(preserved)
            }
        }

        guard !parts.isEmpty else {
            throw HAHLSPlaylistError.malformedTag
        }
        return parts.joined(separator: ",")
    }

    private static func rewriteURIReference(
        _ rawURI: String,
        playlistURL: URL,
        allowedOrigin: URL
    ) throws -> URL {
        guard !rawURI.isEmpty else {
            throw HAHLSPlaylistError.invalidURI
        }
        for scalar in rawURI.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\\" || scalar == "\""
                || scalar.value < 0x20 || scalar.value == 0x7F {
                throw HAHLSPlaylistError.invalidURI
            }
        }
        guard let resolved = URL(string: rawURI, relativeTo: playlistURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw HAHLSPlaylistError.invalidURI
        }
        guard HAPlaintextConsent.hasSameOrigin(resolved, as: allowedOrigin) else {
            throw HAHLSPlaylistError.crossOriginURI
        }
        guard let proxied = proxiedURL(from: resolved) else {
            throw HAHLSPlaylistError.invalidURI
        }
        return proxied
    }

    private static func trimASCIIWhitespace(_ text: String) -> String {
        var start = text.startIndex
        var end = text.endIndex
        while start < end && (text[start] == " " || text[start] == "\t") {
            start = text.index(after: start)
        }
        while end > start {
            let prev = text.index(before: end)
            if text[prev] == " " || text[prev] == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(text[start..<end])
    }
}
