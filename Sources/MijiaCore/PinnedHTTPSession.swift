import Foundation
import os
import PinnedHTTP

final class PinnedHTTPSession: Sendable {
    private struct State {
        var invalidated = false
        var active: [UUID: Transfer] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func invalidateAndCancel() {
        state.withLock {
            $0.invalidated = true
            for transfer in $0.active.values {
                transfer.cancel()
            }
            $0.active.removeAll()
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let id = UUID()
        let transfer = Transfer()
        let registered = state.withLock {
            guard !$0.invalidated else { return false }
            $0.active[id] = transfer
            return true
        }
        guard registered else { throw CancellationError() }
        defer { state.withLock { _ = $0.active.removeValue(forKey: id) } }

        let timeout = min(request.timeoutInterval, timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard transfer.begin(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    transfer.finish(Result { try transfer.run(request, timeout: timeout) })
                }
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    // libcurl invokes the buffer callbacks synchronously on the worker. Cancellation alone is shared.
    private final class Transfer: @unchecked Sendable {
        typealias Reply = CheckedContinuation<(Data, URLResponse), any Error>
        private let completion = OSAllocatedUnfairLock(initialState: (cancelled: false, reply: nil as Reply?))
        private(set) var data = Data()
        private(set) var headers: [String: String] = [:]

        func begin(_ reply: Reply) -> Bool {
            let started = completion.withLock {
                guard !$0.cancelled else { return false }
                $0.reply = reply
                return true
            }
            if !started { reply.resume(throwing: CancellationError()) }
            return started
        }

        func cancel() {
            let reply = completion.withLock {
                let pending = $0.reply
                $0 = (true, nil)
                return pending
            }
            reply?.resume(throwing: CancellationError())
        }

        func finish(_ result: Result<(Data, URLResponse), any Error>) {
            let reply = completion.withLock {
                let pending = $0.reply
                $0.reply = nil
                return pending
            }
            reply?.resume(with: result)
        }

        var isCancelled: Bool { completion.withLock { $0.cancelled } }

        func run(_ request: URLRequest, timeout: TimeInterval) throws -> (Data, URLResponse) {
            if isCancelled { throw CancellationError() }
            guard let url = request.url else { throw URLError(.badURL) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            let endpoint = try ResolvedEndpoint(url: url)
            var headerList: UnsafeMutablePointer<curl_slist>?
            defer { curl_slist_free_all(headerList) }
            for (key, value) in request.allHTTPHeaderFields ?? [:] {
                if ["host", "content-length", "transfer-encoding", "connection", "upgrade"].contains(key.lowercased()) {
                    continue
                }
                guard !key.contains(where: \.isNewline), !value.contains(where: \.isNewline),
                      let updated = curl_slist_append(headerList, "\(key): \(value)") else {
                    throw URLError(.badURL)
                }
                headerList = updated
            }

            let context = Unmanaged.passUnretained(self).toOpaque()
            var status = 0
            for address in endpoint.addresses {
                if isCancelled { throw CancellationError() }
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let milliseconds = remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000
                guard milliseconds > 0 else { throw URLError(.timedOut) }
                let numeric = address.contains(":") ? "[\(address)]" : address
                // The empty source host and port match the original URL unconditionally.
                let pin = "::\(numeric):\(endpoint.port)"
                let call: (UnsafeRawBufferPointer?) -> CURLcode = { body in
                    mbh_pinned_http(
                        endpoint.url.absoluteString, request.httpMethod ?? "GET", pin, headerList,
                        body?.baseAddress, body?.count ?? 0, Int(milliseconds), context,
                        { bytes, count, context in
                            guard let bytes, let context else { return 0 }
                            let transfer = Unmanaged<Transfer>.fromOpaque(context).takeUnretainedValue()
                            guard transfer.data.count + count <= 16 * 1024 * 1024 else { return 0 }
                            transfer.data.append(UnsafeRawBufferPointer(start: bytes, count: count).bindMemory(to: UInt8.self))
                            return count
                        },
                        { bytes, count, context in
                            guard let bytes, let context else { return 0 }
                            let transfer = Unmanaged<Transfer>.fromOpaque(context).takeUnretainedValue()
                            let line = String(
                                decoding: UnsafeRawBufferPointer(start: bytes, count: count).bindMemory(to: UInt8.self),
                                as: UTF8.self
                            )
                            if line.hasPrefix("HTTP/") {
                                transfer.headers.removeAll()
                            } else if let colon = line.firstIndex(of: ":") {
                                let key = line[..<colon].lowercased()
                                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                                transfer.headers[key] = value
                            }
                            return count
                        },
                        { context in
                            guard let context else { return 1 }
                            return Unmanaged<Transfer>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                        },
                        &status
                    )
                }
                let result = request.httpBody.map { $0.withUnsafeBytes { call($0) } } ?? call(nil)
                if isCancelled { throw CancellationError() }
                // Retry only a failed TCP connect. A service write may already have reached HA after that.
                if result == CURLE_COULDNT_CONNECT { continue }
                guard result == CURLE_OK,
                      let response = HTTPURLResponse(url: endpoint.url, statusCode: status,
                                                     httpVersion: nil, headerFields: headers) else {
                    if result == CURLE_OPERATION_TIMEDOUT { throw URLError(.timedOut) }
                    throw HomeProviderError.networkError(String(cString: curl_easy_strerror(result)))
                }
                return (data, response)
            }
            throw URLError(.cannotConnectToHost)
        }
    }
}
