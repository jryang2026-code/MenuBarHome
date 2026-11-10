import Foundation
@testable import MijiaCore

/// In-memory stand-in for the vault's single Keychain item. Counts reads and writes so a test
/// can prove how often macOS would have been asked.
public final class MemoryVaultStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?
    private var _readResult: CredentialVault.Storage.ReadResult?
    private var _writeSucceeds = true
    private var _reads = 0
    private var _writes = 0

    public init(blob: Data? = nil) { self.blob = blob }

    /// Overrides what a read returns (for example `.unavailable` for a declined prompt).
    public var readResult: CredentialVault.Storage.ReadResult? {
        get { locked { _readResult } }
        set { locked { _readResult = newValue } }
    }
    public var writeSucceeds: Bool {
        get { locked { _writeSucceeds } }
        set { locked { _writeSucceeds = newValue } }
    }
    public var reads: Int { locked { _reads } }
    public var writes: Int { locked { _writes } }
    public var rawBlob: Data? { locked { blob } }
    public var storedItems: [String: Data]? { rawBlob.flatMap(CredentialVault.decode) }

    public var storage: CredentialVault.Storage {
        CredentialVault.Storage(
            read: { [self] in
                locked {
                    _reads += 1
                    if let override = _readResult { return override }
                    return blob.map { .found($0) } ?? .notFound
                }
            },
            write: { [self] data in
                locked {
                    _writes += 1
                    guard _writeSucceeds else { return false }
                    blob = data
                    return true
                }
            }
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
