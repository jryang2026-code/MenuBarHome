import Foundation

/// Redirect decision policy shared by Home Assistant `URLSession`s and MJPEG stream readers.
/// Allows only same-origin HTTP(S) redirects without userinfo whose destination passes address validation.
public enum HARedirectPolicy {
    public static func allowedRedirectRequest(
        originalURL: URL?, responseURL: URL?, newRequest: URLRequest
    ) async -> URLRequest? {
        guard let target = validatedTarget(originalURL: originalURL, responseURL: responseURL, newRequest: newRequest) else {
            return nil
        }
        do {
            try await HAPlaintextConsent.validateConnectionAddress(target)
            return newRequest
        } catch {
            return nil
        }
    }

    static func allowedRedirectRequest(
        originalURL: URL?, responseURL: URL?, newRequest: URLRequest, resolve: (String) throws -> [String]
    ) -> URLRequest? {
        guard let target = validatedTarget(originalURL: originalURL, responseURL: responseURL, newRequest: newRequest) else {
            return nil
        }
        return (try? HAPlaintextConsent.validateConnectionAddress(target, resolve: resolve)) != nil ? newRequest : nil
    }

    private static func validatedTarget(originalURL: URL?, responseURL: URL?, newRequest: URLRequest) -> URL? {
        guard let target = newRequest.url,
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let base = originalURL ?? responseURL,
              HAPlaintextConsent.hasSameOrigin(target, as: base, allowWebSocketSchemes: true) else {
            return nil
        }
        if let responseURL, !HAPlaintextConsent.hasSameOrigin(target, as: responseURL, allowWebSocketSchemes: true) {
            return nil
        }
        return target
    }
}

/// Reusable `URLSessionTaskDelegate` that blocks cross-origin and unvalidated HTTP 3xx redirects.
public final class HARedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = HARedirectBlockingDelegate()

    public override init() { super.init() }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalURL = task.originalRequest?.url
        let responseURL = response.url
        nonisolated(unsafe) let complete = completionHandler
        Task {
            complete(await HARedirectPolicy.allowedRedirectRequest(
                originalURL: originalURL, responseURL: responseURL, newRequest: request
            ))
        }
    }
}
