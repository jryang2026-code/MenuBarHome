import Foundation

/// Keeps test preferences independent of the process defaults and the macOS preferences daemon.
public final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        store(value, forKey: defaultName)
    }

    /// Removes from the dictionary directly instead of delegating to `set(nil, forKey:)`. A call to
    /// `set` from inside the subclass goes through `UserDefaults`' own setter, which on Linux
    /// re-enters `removeObject` and never returns: the first caller to remove a key froze the whole
    /// `linux-core` test process until the job was cancelled (#302).
    public override func removeObject(forKey defaultName: String) {
        store(nil, forKey: defaultName)
    }

    private func store(_ value: Any?, forKey defaultName: String) {
        lock.withLock {
            if let value {
                values[defaultName] = value
            } else {
                values.removeValue(forKey: defaultName)
            }
        }
    }
}
