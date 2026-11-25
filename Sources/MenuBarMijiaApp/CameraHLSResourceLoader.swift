import AVFoundation
import Foundation
import MijiaCore
import UniformTypeIdentifiers

enum CameraHLSPlayerFactory {
    /// Routes non-managed / remote HLS streams through `CameraHLSResourceLoader` so every
    /// sub-playlist, segment, init map, and key request stays same-origin, address-validated,
    /// and redirect-blocked. Managed/explicit loopback streams keep direct `AVPlayerItem(url:)`.
    static func makePlayerItem(
        url: URL,
        allowsLoopback: Bool
    ) -> (item: AVPlayerItem, loader: CameraHLSResourceLoader?)? {
        guard HAPlaintextConsent.allowsImmediatePlaybackURL(url, allowsLoopback: allowsLoopback) else {
            return nil
        }
        if allowsLoopback {
            return (AVPlayerItem(url: url), nil)
        }
        guard let proxiedURL = HAHLSPlaylistPolicy.proxiedURL(from: url) else {
            return nil
        }
        let loader = CameraHLSResourceLoader(originURL: url)
        let asset = AVURLAsset(url: proxiedURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (AVPlayerItem(asset: asset), loader)
    }
}

private struct SendableLoadingRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
}

/// Hardened `AVAssetResourceLoaderDelegate` for HA/remote HLS playback.
/// Validates origin and DNS on every request, blocks redirects via `HARedirectBlockingDelegate`,
/// and rewrites M3U8 playlist URIs fail-closed onto `menubarhome-hls-http(s)`.
final class CameraHLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    struct LoadedResource: Equatable, Sendable {
        let data: Data
        let contentType: String
        let contentLength: Int64
        let isByteRangeAccessSupported: Bool
        let isPlaylist: Bool
    }

    let queue = DispatchQueue(label: "com.menubarhome.camera-hls-loader")
    let originURL: URL

    private let session: URLSession
    private let ownsSession: Bool
    private let validateAddress: @Sendable (URL) async throws -> Void
    private let lock = NSLock()
    private var isInvalidated = false
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        originURL: URL,
        session: URLSession? = nil,
        validateAddress: @escaping @Sendable (URL) async throws -> Void = { try await HAPlaintextConsent.validateConnectionAddress($0) }
    ) {
        self.originURL = originURL
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [:]
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg, delegate: HARedirectBlockingDelegate.shared, delegateQueue: nil)
            self.ownsSession = true
        }
        self.validateAddress = validateAddress
        super.init()
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    func invalidate() {
        let tasksToCancel: [Task<Void, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            isInvalidated = true
            let current = Array(activeTasks.values)
            activeTasks.removeAll()
            return current
        }()
        for task in tasksToCancel {
            task.cancel()
        }
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxiedURL = loadingRequest.request.url,
              HAHLSPlaylistPolicy.originalURL(from: proxiedURL) != nil else {
            loadingRequest.finishLoading(with: URLError(.unsupportedURL))
            return true
        }
        let dataRequest = loadingRequest.dataRequest
        let requestedOffset = dataRequest?.requestedOffset ?? 0
        let requestedLength = dataRequest?.requestedLength
        let requestsToEnd = dataRequest?.requestsAllDataToEndOfResource ?? true
        let wantsData = dataRequest != nil
        let requestID = ObjectIdentifier(loadingRequest)
        let box = SendableLoadingRequest(value: loadingRequest)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.loadResource(
                    proxiedURL: proxiedURL,
                    requestedOffset: requestedOffset,
                    requestedLength: requestedLength,
                    requestsAllDataToEnd: requestsToEnd
                )
                try Task.checkCancellation()
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.removeActiveTask(for: requestID)
                    guard !self.isLoaderInvalidated(), !box.value.isCancelled else { return }
                    if let info = box.value.contentInformationRequest {
                        info.contentType = loaded.contentType
                        info.contentLength = loaded.contentLength
                        info.isByteRangeAccessSupported = loaded.isByteRangeAccessSupported
                    }
                    if wantsData {
                        box.value.dataRequest?.respond(with: loaded.data)
                    }
                    box.value.finishLoading()
                }
            } catch {
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.removeActiveTask(for: requestID)
                    guard !self.isLoaderInvalidated(), !box.value.isCancelled else { return }
                    box.value.finishLoading(with: error)
                }
            }
        }

        let cancelledImmediately: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if isInvalidated { return true }
            activeTasks[requestID] = task
            return false
        }()
        if cancelledImmediately {
            task.cancel()
            loadingRequest.finishLoading(with: CancellationError())
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let task = removeActiveTask(for: ObjectIdentifier(loadingRequest))
        task?.cancel()
    }

    func loadResource(
        proxiedURL: URL,
        requestedOffset: Int64 = 0,
        requestedLength: Int? = nil,
        requestsAllDataToEnd: Bool = true
    ) async throws -> LoadedResource {
        try Task.checkCancellation()
        guard let realURL = HAHLSPlaylistPolicy.originalURL(from: proxiedURL) else {
            throw URLError(.unsupportedURL)
        }
        guard HAPlaintextConsent.hasSameOrigin(realURL, as: originURL) else {
            throw HAHLSPlaylistError.crossOriginURI
        }
        try await validateAddress(realURL)
        try Task.checkCancellation()

        let rangeHeader = Self.rangeHeader(
            for: realURL,
            originURL: originURL,
            requestedOffset: requestedOffset,
            requestedLength: requestedLength,
            requestsAllDataToEnd: requestsAllDataToEnd
        )
        var (data, http, finalURL) = try await fetchValidated(realURL: realURL, rangeHeader: rangeHeader)

        let isPlaylist = HAHLSPlaylistPolicy.isPlaylistResponse(
            requestURL: realURL,
            responseURL: finalURL,
            mimeType: http.mimeType,
            data: data
        )
        if isPlaylist, http.statusCode == 206 {
            // Unexpected partial response for an extensionless playlist: refetch full body once without Range.
            try await validateAddress(realURL)
            try Task.checkCancellation()
            (data, http, finalURL) = try await fetchValidated(realURL: realURL, rangeHeader: nil)
            guard http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
        }

        if isPlaylist {
            let rewritten = try HAHLSPlaylistPolicy.rewritePlaylist(
                data: data,
                playlistURL: finalURL,
                allowedOrigin: originURL
            )
            let slice = try Self.slice(
                rewritten,
                offset: requestedOffset,
                length: requestedLength,
                toEnd: requestsAllDataToEnd
            )
            return LoadedResource(
                data: slice,
                contentType: UTType.m3uPlaylist.identifier,
                contentLength: Int64(rewritten.count),
                isByteRangeAccessSupported: false,
                isPlaylist: true
            )
        }

        let contentType = Self.contentTypeIdentifier(mimeType: http.mimeType, url: finalURL)
        if http.statusCode == 206 {
            guard let parsedRange = HAHLSPlaylistPolicy.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  parsedRange.start == requestedOffset else {
                throw URLError(.badServerResponse)
            }
            let totalLength = parsedRange.total ?? (parsedRange.end + 1)
            return LoadedResource(
                data: data,
                contentType: contentType,
                contentLength: totalLength,
                isByteRangeAccessSupported: true,
                isPlaylist: false
            )
        }

        let slice = try Self.slice(
            data,
            offset: requestedOffset,
            length: requestedLength,
            toEnd: requestsAllDataToEnd
        )
        let supportsRange = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
        return LoadedResource(
            data: slice,
            contentType: contentType,
            contentLength: Int64(data.count),
            isByteRangeAccessSupported: supportsRange,
            isPlaylist: false
        )
    }

    private func fetchValidated(
        realURL: URL,
        rangeHeader: String?
    ) async throws -> (Data, HTTPURLResponse, URL) {
        var request = URLRequest(url: realURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let expectedStatus = http.statusCode == 200 || (rangeHeader != nil && http.statusCode == 206)
        guard expectedStatus else {
            throw URLError(.badServerResponse)
        }
        let finalURL = http.url ?? realURL
        guard HAPlaintextConsent.hasSameOrigin(finalURL, as: originURL) else {
            throw HAHLSPlaylistError.crossOriginURI
        }
        return (data, http, finalURL)
    }

    private func isLoaderInvalidated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isInvalidated
    }

    @discardableResult
    private func removeActiveTask(for id: ObjectIdentifier) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks.removeValue(forKey: id)
    }

    private static func rangeHeader(
        for url: URL,
        originURL: URL,
        requestedOffset: Int64,
        requestedLength: Int?,
        requestsAllDataToEnd: Bool
    ) -> String? {
        if url == originURL || HAHLSPlaylistPolicy.looksLikePlaylistURL(url) {
            return nil
        }
        if requestedOffset > 0 {
            if requestsAllDataToEnd || requestedLength == nil {
                return "bytes=\(requestedOffset)-"
            }
            if let length = requestedLength, length > 0 {
                let (endExclusive, overflow) = requestedOffset.addingReportingOverflow(Int64(length))
                if overflow {
                    return "bytes=\(requestedOffset)-"
                }
                return "bytes=\(requestedOffset)-\(endExclusive - 1)"
            }
            return nil
        }
        if !requestsAllDataToEnd, let length = requestedLength, length > 0, length < Int.max {
            return "bytes=0-\(Int64(length) - 1)"
        }
        return nil
    }

    private static func slice(
        _ data: Data,
        offset: Int64,
        length: Int?,
        toEnd: Bool
    ) throws -> Data {
        guard offset >= 0, offset <= Int64(data.count) else {
            throw URLError(.cannotDecodeRawData)
        }
        let start = Int(offset)
        if toEnd || length == nil {
            return data.subdata(in: start..<data.count)
        }
        let count = max(0, length ?? 0)
        let (sum, overflow) = start.addingReportingOverflow(count)
        let end = overflow ? data.count : min(data.count, sum)
        return data.subdata(in: start..<end)
    }

    private static func contentTypeIdentifier(mimeType: String?, url: URL) -> String {
        let normalizedMIME = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        switch normalizedMIME {
        case "video/mp2t":
            return UTType.mpeg2TransportStream.identifier
        case "video/mp4", "video/iso.segment":
            return UTType.mpeg4Movie.identifier
        case "audio/mp4":
            return UTType.mpeg4Audio.identifier
        case "audio/aac":
            return "public.aac-audio"
        case "application/octet-stream", nil, "":
            break
        case let mime?:
            if let uti = UTType(mimeType: mime), !uti.isDynamic {
                return uti.identifier
            }
        }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let uti = UTType(filenameExtension: ext), !uti.isDynamic {
            return uti.identifier
        }
        return UTType.data.identifier
    }
}
