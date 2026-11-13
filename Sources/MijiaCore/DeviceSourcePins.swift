import Foundation

/// A per-card source override for merged Home Assistant + Xiaomi Cloud devices (#111).
/// Stored by canonical card id so the choice survives source handoffs and relaunches.
public enum DeviceSourcePinStorage {
    public static func load(defaults: UserDefaults) -> [String: HomeBackend] {
        let raw = defaults.dictionary(forKey: ViewPreferenceKeys.pinnedDeviceSources) as? [String: String] ?? [:]
        return raw.reduce(into: [:]) { result, entry in
            guard let backend = HomeBackend(rawValue: entry.value), backend != .demo else { return }
            result[entry.key] = backend
        }
    }

    public static func save(_ pins: [String: HomeBackend], defaults: UserDefaults) {
        let raw = pins.reduce(into: [String: String]()) { result, entry in
            guard entry.value != .demo else { return }
            result[entry.key] = entry.value.rawValue
        }
        if raw.isEmpty {
            defaults.removeObject(forKey: ViewPreferenceKeys.pinnedDeviceSources)
        } else {
            defaults.set(raw, forKey: ViewPreferenceKeys.pinnedDeviceSources)
        }
    }
}

extension HomeBackend {
    /// Compact source name for the panel status line and card menu; `title` is used by Settings.
    public var shortTitle: String {
        switch self {
        case .homeAssistant: return "Home Assistant"
        case .xiaomiCloud: return L10n.tr("米家云端", "Xiaomi Cloud")
        case .demo: return L10n.tr("演示模式", "Demo Mode")
        }
    }
}

/// Thread-safe in-memory store for per-card source pins so `DualSourceHomeProvider` always reads
/// the same pin state the UI shows, even if `UserDefaults` persistence fails or lags.
public final class DeviceSourcePinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: HomeBackend]

    public init(_ initial: [String: HomeBackend] = [:]) {
        self.pins = initial
    }

    public func get() -> [String: HomeBackend] {
        lock.lock()
        defer { lock.unlock() }
        return pins
    }

    public func set(_ next: [String: HomeBackend]) {
        lock.lock()
        pins = next
        lock.unlock()
    }
}

/// Recomputes a dual-source merge without polling either backend, so a source pin takes effect
/// immediately after the card menu writes it (#111).
public protocol DualSourceRecomputing: Sendable {
    func requestRecompute()
}
