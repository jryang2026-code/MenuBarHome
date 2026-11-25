import Foundation
import MijiaCore
import UniformTypeIdentifiers
import UserNotifications

/// Snapshot attachment for a doorbell notification (#10).
///
/// The picture is all-or-nothing inside a 2.5 s budget: a notification must never wait longer than
/// three seconds, and a missing picture is fine. Nothing here opens a camera stream of its own —
/// Home Assistant cards answer through their snapshot proxy, and a Xiaomi card only contributes a
/// frame while the live window is already pulling it from the local bridge.
@MainActor
enum DoorbellNotificationThumbnail {
    /// Whole fetch, file write included. The notification is posted when this returns.
    static let budget: Duration = .seconds(2.5)
    /// The doorbell popup needs a moment to resolve and start its stream before a frame exists.
    static let retryInterval: Duration = .milliseconds(200)
    private static let requestTimeout: TimeInterval = 1.2
    private static let staleFileAge: TimeInterval = 600
    private static let filePrefix = "menubarhome-doorbell-"

    struct Picture {
        let attachment: UNNotificationAttachment
        /// Deleted by the caller once the system has copied the picture into the request.
        let fileURL: URL
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func snapshotData(for device: SmartDevice, store: HomeStore) async -> Data? {
        guard let picture = await picture(for: device, store: store) else { return nil }
        defer { try? FileManager.default.removeItem(at: picture.fileURL) }
        return try? Data(contentsOf: picture.fileURL)
    }

    static func picture(for device: SmartDevice, store: HomeStore) async -> Picture? {
        guard case .camera = device.kind else { return nil }
        let deadline = ContinuousClock.now + budget
        var triedSnapshotProxy = false
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if !triedSnapshotProxy, let url = snapshotProxyURL(for: device, store: store) {
                // One attempt on the card's own snapshot path; retrying a dead HA proxy inside the
                // budget would only double the wait.
                triedSnapshotProxy = true
                if let data = await fetchJPEGData(
                    with: snapshotProxyRequest(for: url, store: store),
                    validateHAEndpoint: HAPlaintextConsent.matchesServerOrigin(url, serverBaseURL: store.serverURLString),
                    until: deadline
                ) {
                    return writePicture(from: data)
                }
            }
            if let url = CameraLivePanelController.shared.runningFrameJPEGURL(forDeviceId: device.id),
               let data = await fetchJPEGData(
                   with: XiaomiCameraBridge.authorizedURLRequest(for: url),
                   until: deadline
               ) {
                return writePicture(from: data)
            }
            guard awaitsPopupStream(device: device) else { return nil }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .milliseconds(50) else { break }
            try? await Task.sleep(for: min(retryInterval, remaining))
        }
        return nil
    }

    /// True while the ring's own popup may still start the stream this fetch is waiting for.
    private static func awaitsPopupStream(device: SmartDevice) -> Bool {
        CameraLivePanelController.shared.activeDeviceId == device.id
    }

    private static func snapshotProxyURL(for device: SmartDevice, store: HomeStore) -> URL? {
        guard case .camera(let spec) = device.kind,
              let path = spec.snapshotPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return HAWebSocketProvider.resolveStreamURL(pathOrURL: path, baseURLString: store.serverURLString)
    }

    private static func snapshotProxyRequest(for url: URL, store: HomeStore) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        components?.queryItems = items + [
            URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        var request = URLRequest(url: components?.url ?? url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = requestTimeout
        // The snapshot proxy normally carries its own `token=`; for a plain URL this adds the same
        // bearer header the live window uses, under the plaintext-consent rules.
        if url.query?.contains("token=") != true,
           HAPlaintextConsent.matchesServerOrigin(url, serverBaseURL: store.serverURLString),
           HAPlaintextConsent.allowsToken(to: url.absoluteString, defaults: store.userDefaults) {
            let token = store.loadHAToken().trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    /// The download is raced against the remaining budget, so a slow camera cannot push the
    /// notification past its deadline; a cancelled download simply yields no picture.
    private static func fetchJPEGData(
        with request: URLRequest, validateHAEndpoint: Bool = false, until deadline: ContinuousClock.Instant
    ) async -> Data? {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return nil }
        let session = self.session
        let response = await withTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask {
                do {
                    if validateHAEndpoint, let url = request.url {
                        try await HAPlaintextConsent.validateConnectionAddress(url)
                    }
                    return try await session.data(for: request)
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: remaining)
                return nil
            }
            var result: (Data, URLResponse)?
            while let next = await group.next() {
                if let next { result = next }
                group.cancelAll()
                break
            }
            return result
        }
        guard let (data, rawResponse) = response,
              let http = rawResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 1024,
              data[data.startIndex] == 0xFF,
              data[data.startIndex + 1] == 0xD8 else {
            return nil
        }
        return data
    }

    private static func writePicture(from data: Data) -> Picture? {
        let directory = FileManager.default.temporaryDirectory
        removeStaleFiles(in: directory)
        let fileURL = directory.appendingPathComponent("\(filePrefix)\(UUID().uuidString).jpg")
        do {
            try data.write(to: fileURL, options: [.atomic])
            let attachment = try UNNotificationAttachment(
                identifier: "doorbell-snapshot",
                url: fileURL,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.jpeg.identifier]
            )
            return Picture(attachment: attachment, fileURL: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    /// A crashed run can leave a picture the system already copied; only the fresh ones matter.
    private static func removeStaleFiles(in directory: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-staleFileAge)
        for name in names where name.hasPrefix(filePrefix) {
            let url = directory.appendingPathComponent(name)
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
