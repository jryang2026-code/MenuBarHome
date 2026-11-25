import Foundation

/// One writer generation per live composite. An outgoing provider may still be
/// draining events while its replacement loads the registry.
final class CanonicalDeviceRegistryFile: @unchecked Sendable {
    static let live: CanonicalDeviceRegistryFile? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        .map { CanonicalDeviceRegistryFile(url: $0.appendingPathComponent("MenuBarMijia/canonical-devices.json")) }

    private let url: URL
    private let lock = NSLock()
    private var generation = 0

    init(url: URL) { self.url = url }

    func open(legacy: [String: String]) -> (CanonicalDeviceRegistry, @Sendable (CanonicalDeviceRegistry) -> Void) {
        lock.withLock {
            generation += 1
            let owner = generation
            let registry = copies().first?.registry ?? CanonicalDeviceRegistry(assignments: legacy)
            return (registry, { registry in
                self.lock.withLock {
                    guard self.generation == owner else { return }
                    try? self.write(registry)
                }
            })
        }
    }

    private var backupURLs: [URL] {
        (1...2).map { url.appendingPathExtension("\($0).bak") }
    }

    private func copies() -> [(registry: CanonicalDeviceRegistry, data: Data)] {
        ([url] + backupURLs).compactMap { location in
            guard let data = try? Data(contentsOf: location),
                  let registry = try? JSONDecoder().decode(CanonicalDeviceRegistry.self, from: data)
            else { return nil }
            return (registry, data)
        }
    }

    private func write(_ registry: CanonicalDeviceRegistry) throws {
        let valid = copies()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (backup, copy) in zip(backupURLs, valid).reversed() {
            var previous = copy.registry
            for id in registry.explicitlyDeleted { previous.forget(id) }
            let data = previous == copy.registry ? copy.data : try JSONEncoder().encode(previous)
            try data.write(to: backup, options: .atomic)
        }
        try JSONEncoder().encode(registry).write(to: url, options: .atomic)
    }
}
