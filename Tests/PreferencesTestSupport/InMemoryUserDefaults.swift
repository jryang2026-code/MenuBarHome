import Foundation

/// Keeps test preferences independent of the process defaults and the macOS preferences daemon.
public final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    public override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }
}
