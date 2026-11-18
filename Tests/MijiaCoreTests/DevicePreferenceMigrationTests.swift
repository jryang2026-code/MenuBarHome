import Foundation
import Testing
@testable import MijiaCore

/// #24：双端历史偏好不能因配对卡换规范 ID 而孤立——孤儿一侧的隐藏、收藏、别名、磁贴偏好
/// 合并到胜出的规范卡上；隐藏优先保持隐藏，迁移幂等且不覆盖用户明确设置。
@MainActor
struct DevicePreferenceMigrationTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.prefmigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func setAliases(_ aliases: [String: String], defaults: UserDefaults) {
        let raw = String(data: try! JSONEncoder().encode(aliases), encoding: .utf8)!
        defaults.set(raw, forKey: ViewPreferenceKeys.deviceAliases)
    }

    private func aliases(defaults: UserDefaults) -> [String: String] {
        guard let raw = defaults.string(forKey: ViewPreferenceKeys.deviceAliases),
              let decoded = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) else {
            return [:]
        }
        return decoded
    }

    private func setTileSizes(_ sizes: [String: String], defaults: UserDefaults) {
        let raw = String(data: try! JSONEncoder().encode(sizes), encoding: .utf8)!
        defaults.set(raw, forKey: ViewPreferenceKeys.tileSizes)
    }

    private func tileSizes(defaults: UserDefaults) -> [String: String] {
        guard let raw = defaults.string(forKey: ViewPreferenceKeys.tileSizes),
              let decoded = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) else {
            return [:]
        }
        return decoded
    }

    @Test("Hidden wins over visible, and the canonical card stays visible when the orphan was (#24)")
    func hiddenPreferenceMerges() {
        let defaults = makeDefaults()
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)

        let outcome = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(outcome.hidden)
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111", "ha-light-a"])

        let untouched = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-b", orphanedID: "222000222", defaults: defaults
        )
        #expect(!untouched.hidden)
        #expect(!untouched.changed)
    }

    @Test("A favorited orphan keeps the card starred and inherits its position in the order (#24)")
    func favoritePreferenceMerges() {
        let defaults = makeDefaults()
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        defaults.set(["a", "111000111", "b"], forKey: ViewPreferenceKeys.favoriteOrder)

        let outcome = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(outcome.favorite)
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.favoriteDeviceIds) == ["111000111", "ha-light-a"])
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.favoriteOrder) == ["a", "111000111", "ha-light-a", "b"])
    }

    @Test("An alias merges only when the canonical side has none of its own (#24)")
    func aliasMergesWithoutOverwriting() {
        let defaults = makeDefaults()
        setAliases(["111000111": "门厅筒灯"], defaults: defaults)

        let copied = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(copied.alias)
        #expect(aliases(defaults: defaults)["ha-light-a"] == "门厅筒灯")

        // An explicit alias on the canonical side is never overwritten.
        setAliases(["ha-light-b": "客厅主灯", "222000222": "旧名字"], defaults: defaults)
        let preserved = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-b", orphanedID: "222000222", defaults: defaults
        )
        #expect(!preserved.alias)
        #expect(aliases(defaults: defaults)["ha-light-b"] == "客厅主灯")
    }

    @Test("Tile sizes merge per page and never overwrite the canonical side (#24)")
    func tileSizesMergePerScope() {
        let defaults = makeDefaults()
        setTileSizes(["mi_page|111000111": "half", "111000111": "full"], defaults: defaults)

        let outcome = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(outcome.tileSize)
        let sizes = tileSizes(defaults: defaults)
        #expect(sizes["mi_page|ha-light-a"] == "half")
        #expect(sizes["ha-light-a"] == "full")

        // An explicit size on the canonical side keeps its own value.
        setTileSizes(["mi_page|ha-light-b": "hero", "mi_page|222000222": "half"], defaults: defaults)
        let preserved = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-b", orphanedID: "222000222", defaults: defaults
        )
        #expect(!preserved.tileSize)
        #expect(tileSizes(defaults: defaults)["mi_page|ha-light-b"] == "hero")
    }

    @Test("Running the adoption twice changes nothing the second time (#24)")
    func adoptionIsIdempotent() {
        let defaults = makeDefaults()
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        setAliases(["111000111": "门厅筒灯"], defaults: defaults)
        setTileSizes(["mi_page|111000111": "half"], defaults: defaults)

        let first = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(first.changed)
        func preferenceSnapshot() -> [String] {
            [
                defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds)?.joined(separator: ",") ?? "",
                defaults.stringArray(forKey: ViewPreferenceKeys.favoriteDeviceIds)?.joined(separator: ",") ?? "",
                defaults.stringArray(forKey: ViewPreferenceKeys.favoriteOrder)?.joined(separator: ",") ?? "",
                defaults.string(forKey: ViewPreferenceKeys.deviceAliases) ?? "",
                defaults.string(forKey: ViewPreferenceKeys.tileSizes) ?? "",
            ]
        }
        let afterFirst = preferenceSnapshot()

        let second = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(!second.changed, "A second merge after the first adoption is a no-op")
        #expect(preferenceSnapshot() == afterFirst)
    }

    // MARK: - Store wiring

    private func pairableLight(id: String, did: String, room: String) -> SmartDevice {
        SmartDevice(
            id: id, name: "筒灯", roomId: room, roomName: "客厅",
            model: "yeelink.light.spot1", isOnline: true,
            kind: .light(LightSpec(entityId: "light.\(id)", isOn: true))
        )
    }

    private func pairableHome(id: String, did: String) -> SynthesizedHome {
        var home = SynthesizedHome(devices: [pairableLight(id: id, did: did, room: "living_room")])
        home.deviceIdentities = [
            id: DeviceSourceIdentity(
                dids: [did], model: "yeelink.light.spot1", name: "筒灯", roomName: "客厅", kindTag: .light
            )
        ]
        return home
    }

    @Test("A dual-source snapshot merges the orphaned side's preferences onto the canonical card (#24)")
    func storeMergesOrphanedPreferencesOnSnapshot() async throws {
        let suite = "test.prefadoption.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // HA-side history (a favorite) plus Mi-side history (hidden, an alias, a tile): both sides
        // are known, so the canonical id stays the HA id and the Mi id's prefs must merge onto it.
        defaults.set(["ha-light-a"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        defaults.set(["ha-light-a"], forKey: ViewPreferenceKeys.favoriteOrder)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        setAliases(["111000111": "门厅筒灯"], defaults: defaults)
        setTileSizes(["mi_page|111000111": "half"], defaults: defaults)

        let haMock = MockHomeProvider(snapshot: pairableHome(id: "ha-light-a", did: "111000111"))
        let miHome = pairableHome(id: "111000111", did: "111000111")
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            provider: HomeStore.makeComposite(homeAssistant: haMock, xiaomiCloud: miMock, defaults: defaults),
            defaultsSuiteName: suite
        )
        // The first merged snapshot may still be HA-only (the Mi event lands a beat later), and
        // pairing — the thing that carries the adoption — only happens once both sides arrived.
        try await store.waitForTestSnapshot()
        await waitUntil { store.pairedDeviceIDs.contains("ha-light-a") }

        #expect(store.devices.map(\.id) == ["ha-light-a"])
        #expect(store.hiddenDeviceIds.contains("ha-light-a"), "Hidden wins even though the HA side had starred it")
        #expect(store.favoriteDeviceIds.contains("ha-light-a"))
        #expect(store.devices.first?.name == "门厅筒灯", "The Mi-side alias survives the canonical switch")
        #expect(tileSizes(defaults: defaults)["mi_page|ha-light-a"] == "half")

        // The orphaned entries stay on disk so returning to a single-source Mi home still works.
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds)?.contains("111000111") == true)
        #expect(aliases(defaults: defaults)["111000111"] == "门厅筒灯")

        // A second snapshot of the same pair must not duplicate or rewrite anything.
        let devicesAfterFirst = store.devices
        await miMock.updateSnapshot(miHome)
        try await store.waitForTestSnapshot()
        #expect(store.devices.map(\.id) == ["ha-light-a"])
        #expect(store.hiddenDeviceIds == ["111000111", "ha-light-a"])
        #expect(store.favoriteDeviceIds == ["ha-light-a"])
        #expect(store.devices == devicesAfterFirst)
    }
}
