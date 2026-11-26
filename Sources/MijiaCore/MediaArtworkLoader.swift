import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches a TV's Now Playing cover from the Home Assistant origin only, with a small LRU cache.
/// The access token travels in the `Authorization` header, never in the URL, cache key or logs.
public actor MediaArtworkLoader {
    public static let shared = MediaArtworkLoader()

    private let capacity: Int
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private let session: URLSession

    public init(capacity: Int = 24) {
        self.capacity = max(1, capacity)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: HARedirectBlockingDelegate.shared, delegateQueue: nil)
    }

    /// The request for an `entity_picture`, or nil when it points anywhere but the HA server.
    /// HA's `/api/media_player_proxy/…?token=…` already carries an entity access token, so the
    /// bearer is added only when the path has none and the plaintext-consent check allows it.
    public static func request(
        artworkPath: String, serverBaseURL: String, bearerToken: String?, allowsBearer: Bool
    ) -> URLRequest? {
        guard let url = HAWebSocketProvider.resolveStreamURL(pathOrURL: artworkPath, baseURLString: serverBaseURL) else {
            return nil
        }
        var request = URLRequest(url: url)
        let hasEntityToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "token" } == true
        let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hasEntityToken, allowsBearer, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// SHA-256 of origin + path, so the entity token in `?token=` never sits in the cache.
    public static func cacheKey(artworkPath: String, serverBaseURL: String) -> String {
        let raw = "\(HAWebSocketProvider.normalizeBaseURL(serverBaseURL))|\(artworkPath)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func cached(_ key: String) -> Data? {
        guard let data = cache[key] else { return nil }
        touch(key)
        return data
    }

    public func store(_ data: Data, for key: String) {
        cache[key] = data
        touch(key)
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    public func load(artworkPath: String, serverBaseURL: String, bearerToken: String?, allowsBearer: Bool) async -> Data? {
        let key = Self.cacheKey(artworkPath: artworkPath, serverBaseURL: serverBaseURL)
        if let hit = cached(key) { return hit }
        guard let request = Self.request(
            artworkPath: artworkPath, serverBaseURL: serverBaseURL,
            bearerToken: bearerToken, allowsBearer: allowsBearer
        ), let url = request.url else { return nil }
        do {
            try await HAPlaintextConsent.validateConnectionAddress(url)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !data.isEmpty, data.count <= 4 * 1024 * 1024 else { return nil }
            store(data, for: key)
            return data
        } catch {
            return nil
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
