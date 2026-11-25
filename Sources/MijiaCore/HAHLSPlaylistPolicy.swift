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
/// Validates every playlist URI same-origin and rewrites it fail-closed onto the session's
/// authenticated `127.0.0.1:<port>/<token>/...` loopback relay so `AVPlayer` fetches standard HTTP
/// while never bypassing origin, DNS, or redirect checks.
public enum HAHLSPlaylistPolicy {
    public static let maxPlaylistBytes = 2 * 1024 * 1024
    public static let tokenHexLength = 32

    public struct RelayBase: Equatable, Sendable {
        public let port: UInt16
        public let token: String

        public init?(port: UInt16, token: String) {
            guard port > 0, Self.isValidToken(token) else { return nil }
            self.port = port
            self.token = token
        }

        public static func isValidToken(_ token: String) -> Bool {
            token.utf8.count == tokenHexLength && token.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
            }
        }

        public var originString: String {
            "http://127.0.0.1:\(port)"
        }
    }

    private static let playlistMIMETypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl",
        "vnd.apple.mpegurl",
    ]

    private static let disallowedTags: Set<String> = [
        "#EXT-X-DEFINE",
        "#EXT-X-CONTENT-STEERING",
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
    ]

    /// Maps a validated same-origin upstream URL onto `http://127.0.0.1:<port>/<token><path>[?<query>]`.
    public static func relayURL(
        for upstreamURL: URL,
        allowedOrigin: URL,
        relay: RelayBase
    ) -> URL? {
        guard HAPlaintextConsent.hasSameOrigin(upstreamURL, as: allowedOrigin),
              let components = URLComponents(url: upstreamURL, resolvingAgainstBaseURL: true),
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return nil
        }
        let rawPath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard rawPath.hasPrefix("/") else { return nil }
        let normalizedPath = removeDotSegments(rawPath)
        guard isValidPercentEncodedPath(normalizedPath) else { return nil }
        if let query = components.percentEncodedQuery, !isValidPercentEncodedQuery(query) {
            return nil
        }
        var relayComponents = URLComponents()
        relayComponents.scheme = "http"
        relayComponents.host = "127.0.0.1"
        relayComponents.port = Int(relay.port)
        relayComponents.percentEncodedPath = "/\(relay.token)\(normalizedPath)"
        relayComponents.percentEncodedQuery = components.percentEncodedQuery
        guard let url = relayComponents.url,
              !url.absoluteString.contains("\""),
              !url.absoluteString.contains("\\") else {
            return nil
        }
        return url
    }

    /// Verifies the 128-bit random token path prefix in constant time and maps an incoming
    /// loopback HTTP request target back to a same-origin upstream URL on `originURL`.
    public static func upstreamURL(
        forRequestTarget target: String,
        expectedToken: String,
        originURL: URL
    ) -> URL? {
        guard RelayBase.isValidToken(expectedToken),
              target.hasPrefix("/"),
              target.utf8.allSatisfy({ byte in
                  byte >= 0x21 && byte <= 0x7E && byte != 0x22 && byte != 0x23 && byte != 0x5C
              }) else {
            return nil
        }

        let rawPath: String
        let rawQuery: String?
        if let queryIndex = target.firstIndex(of: "?") {
            rawPath = String(target[..<queryIndex])
            rawQuery = String(target[target.index(after: queryIndex)...])
        } else {
            rawPath = target
            rawQuery = nil
        }

        let expectedPrefix = Array("/\(expectedToken)/".utf8)
        let pathBytes = Array(rawPath.utf8)
        guard pathBytes.count >= expectedPrefix.count else { return nil }
        var diff: UInt8 = 0
        for index in 0..<expectedPrefix.count {
            diff |= pathBytes[index] ^ expectedPrefix[index]
        }
        guard diff == 0 else { return nil }

        let upstreamPath = String(rawPath.dropFirst(expectedToken.count + 1))
        guard upstreamPath.hasPrefix("/"),
              isValidPercentEncodedPath(upstreamPath) else {
            return nil
        }
        if let rawQuery, !isValidPercentEncodedQuery(rawQuery) {
            return nil
        }

        guard var originComponents = URLComponents(url: originURL, resolvingAgainstBaseURL: true),
              let scheme = originComponents.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              originComponents.user == nil,
              originComponents.password == nil,
              originComponents.fragment == nil,
              let host = originComponents.host, !host.isEmpty else {
            return nil
        }
        originComponents.percentEncodedPath = upstreamPath
        originComponents.percentEncodedQuery = rawQuery
        originComponents.fragment = nil
        guard let mapped = originComponents.url,
              HAPlaintextConsent.hasSameOrigin(mapped, as: originURL) else {
            return nil
        }
        return mapped
    }

    public static func looksLikePlaylistURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }

    public static func isPlaylistMIME(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        return playlistMIMETypes.contains(normalized)
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
        if isPlaylistMIME(mimeType) {
            return true
        }
        return hasEXTM3UPrefix(data)
    }

    /// Parses an HTTP `Content-Range: bytes start-end/total` (or `/*`) header safely without overflow.
    public static func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.contains("\r"),
              !raw.contains("\n") else {
            return nil
        }
        guard raw.count >= 6, raw.prefix(6).lowercased() == "bytes " else { return nil }
        let spec = trimASCIIWhitespace(String(raw.dropFirst(6)))
        let slashParts = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard slashParts.count == 2 else { return nil }
        let rangeParts = slashParts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard rangeParts.count == 2,
              isASCIIUnsignedDigits(rangeParts[0]),
              isASCIIUnsignedDigits(rangeParts[1]),
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        let (endExclusive, overflow) = end.addingReportingOverflow(1)
        guard !overflow else { return nil }
        let totalToken = slashParts[1]
        if totalToken == "*" {
            return (start, end, nil)
        }
        guard isASCIIUnsignedDigits(totalToken),
              let total = Int64(totalToken),
              total >= endExclusive else {
            return nil
        }
        return (start, end, total)
    }

    public static func formatContentRange(start: Int64, end: Int64, total: Int64?) -> String {
        "bytes \(start)-\(end)/\(total.map(String.init) ?? "*")"
    }

    /// Returns `true` only when a `206` `Content-Range` covers the entire resource starting at byte 0.
    public static func isCompleteFromZeroContentRange(_ header: String?, expectedByteCount: Int) -> Bool {
        guard expectedByteCount > 0,
              let parsed = parseContentRange(header) else {
            return false
        }
        let expected = Int64(expectedByteCount)
        let (endExclusive, overflow) = parsed.end.addingReportingOverflow(1)
        return !overflow && parsed.start == 0 && endExclusive == expected && parsed.total == expected
    }

    /// Validates and canonicalizes a single HTTP byte-range header (`bytes=start-end`, `bytes=start-`, `bytes=-suffix`).
    public static func sanitizedRangeHeader(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard !raw.contains("\r"), !raw.contains("\n") else { return nil }
        let trimmed = trimASCIIWhitespace(raw)
        guard trimmed.count >= 7, trimmed.prefix(6).lowercased() == "bytes=" else { return nil }
        let spec = String(trimmed.dropFirst(6))
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let lhs = parts[0]
        let rhs = parts[1]
        if !lhs.isEmpty && !rhs.isEmpty {
            guard isASCIIUnsignedDigits(lhs),
                  isASCIIUnsignedDigits(rhs),
                  let start = Int64(lhs),
                  let end = Int64(rhs),
                  start >= 0,
                  end >= start,
                  !end.addingReportingOverflow(1).overflow else {
                return nil
            }
            return "bytes=\(start)-\(end)"
        } else if !lhs.isEmpty {
            guard isASCIIUnsignedDigits(lhs),
                  let start = Int64(lhs),
                  start >= 0 else {
                return nil
            }
            return "bytes=\(start)-"
        } else if !rhs.isEmpty {
            guard isASCIIUnsignedDigits(rhs),
                  let suffix = Int64(rhs),
                  suffix > 0 else {
                return nil
            }
            return "bytes=-\(suffix)"
        }
        return nil
    }

    /// Strips control characters and rejects header-injection attempts on relayed HTTP header values.
    public static func sanitizedHeaderValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = trimASCIIWhitespace(raw)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              trimmed.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            return nil
        }
        return trimmed
    }

    /// Validates and rewrites every URI reference in an M3U8 playlist fail-closed onto `relay`.
    /// Splits lines on `\r\n`, `\n`, and bare `\r` to match AVFoundation, handles both quoted and
    /// unquoted `URI=` / `*-URI=` tag attributes, and rejects `#EXT-X-DEFINE`,
    /// `#EXT-X-CONTENT-STEERING`, and `X-ASSET-LIST` interstitial asset lists.
    public static func rewritePlaylist(
        data: Data,
        playlistURL: URL,
        allowedOrigin: URL,
        relay: RelayBase
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
                    rewritten.append(try rewriteTagLine(
                        trimmed,
                        playlistURL: playlistURL,
                        allowedOrigin: allowedOrigin,
                        relay: relay
                    ))
                } else {
                    rewritten.append(trimmed)
                }
            } else {
                let target = try rewriteURIReference(
                    trimmed,
                    playlistURL: playlistURL,
                    allowedOrigin: allowedOrigin,
                    relay: relay
                )
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
        allowedOrigin: URL,
        relay: RelayBase
    ) throws -> String {
        guard let colon = line.firstIndex(of: ":") else {
            let upper = line.uppercased()
            if disallowedTags.contains(upper) { throw HAHLSPlaylistError.disallowedTag }
            if uriBearingTags.contains(upper) { throw HAHLSPlaylistError.malformedTag }
            return line
        }
        let tagName = String(line[..<colon])
        let upperTag = trimASCIIWhitespace(tagName).uppercased()
        if disallowedTags.contains(upperTag) {
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
            allowedOrigin: allowedOrigin,
            relay: relay
        )
        return "\(tagName):\(rewrittenPayload)"
    }

    private static func rewriteAttributeList(
        _ payload: String,
        playlistURL: URL,
        allowedOrigin: URL,
        relay: RelayBase
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
            if upperKey == "X-ASSET-LIST" {
                throw HAHLSPlaylistError.disallowedTag
            }
            if upperKey == "URI" || upperKey.hasSuffix("-URI") {
                guard !value.isEmpty, !value.hasPrefix("'"), !value.hasSuffix("'") else {
                    throw HAHLSPlaylistError.invalidURI
                }
                let rewritten = try rewriteURIReference(
                    value,
                    playlistURL: playlistURL,
                    allowedOrigin: allowedOrigin,
                    relay: relay
                )
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
        allowedOrigin: URL,
        relay: RelayBase
    ) throws -> URL {
        guard !rawURI.isEmpty else {
            throw HAHLSPlaylistError.invalidURI
        }
        for scalar in rawURI.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\\" || scalar == "\"" || scalar == "#"
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
        guard let relayed = relayURL(for: resolved, allowedOrigin: allowedOrigin, relay: relay) else {
            throw HAHLSPlaylistError.invalidURI
        }
        return relayed
    }

    private static func isASCIIUnsignedDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }

    private static func isRFC3986PChar(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, // 0-9
             0x41...0x5A, // A-Z
             0x61...0x7A, // a-z
             0x2D, 0x2E, 0x5F, 0x7E, // - . _ ~
             0x21, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D, // sub-delims
             0x3A, 0x40: // : @
            return true
        default:
            return false
        }
    }

    private static func isValidPercentEncoded(_ string: String, allowByte: (UInt8) -> Bool) -> Bool {
        let bytes = Array(string.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x25 { // '%'
                guard i + 2 < bytes.count, isHexDigit(bytes[i + 1]), isHexDigit(bytes[i + 2]) else {
                    return false
                }
                i += 3
            } else if allowByte(b) {
                i += 1
            } else {
                return false
            }
        }
        return true
    }

    private static func isValidPercentEncodedPath(_ path: String) -> Bool {
        isValidPercentEncoded(path) { isRFC3986PChar($0) || $0 == 0x2F } // '/'
    }

    private static func isValidPercentEncodedQuery(_ query: String) -> Bool {
        isValidPercentEncoded(query) { isRFC3986PChar($0) || $0 == 0x2F || $0 == 0x3F } // '/' '?'
    }

    /// RFC 3986 §5.2.4 dot-segment removal on an already percent-encoded absolute path.
    private static func removeDotSegments(_ path: String) -> String {
        guard path.contains("/.") else { return path }
        let endsWithSlash = path.hasSuffix("/") || path.hasSuffix("/.") || path.hasSuffix("/..")
        var output: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty || segment == "." {
                continue
            } else if segment == ".." {
                if !output.isEmpty {
                    output.removeLast()
                }
            } else {
                output.append(segment)
            }
        }
        if output.isEmpty {
            return "/"
        }
        let joined = "/" + output.joined(separator: "/")
        return endsWithSlash ? joined + "/" : joined
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
