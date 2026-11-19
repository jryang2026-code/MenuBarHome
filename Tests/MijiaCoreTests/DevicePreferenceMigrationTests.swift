import Foundation
import Testing
@testable import MijiaCore

/// #24：双端历史偏好不能因配对卡换规范 ID 而孤立——孤儿一侧的隐藏、收藏、别名、磁贴偏好
/// 合并到胜出的规范卡上；隐藏优先保持隐藏，迁移幂等且不覆盖用户明确设置。
@MainActor
@Suite(.serialized)
struct DevicePreferenceMigrationTests {
    /// A brand-new UUID suite holds nothing to clear, so it is never cleared before the test writes:
    /// `removePersistentDomain` is applied asynchronously by cfprefsd and, with hundreds of suites
    /// racing on a loaded runner, the clear lands *after* the test's own `set` and wipes the keys it
    /// just wrote (#24 flake). Each test drops its domain with a `defer` at the end instead.
    private func makeSuiteDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "test.prefmigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    /// What a new process decodes from the persisted suite: the property-list object graph
    /// (`NSDictionary` / `NSArray`) handed to a fresh `UserDefaults` instance. The in-process
    /// defaults cache keeps the original Swift values, so only this shape proves a relaunch still
    /// reads the adoption ledger (#24).
    private func relaunchedSuite(suite: String, from defaults: UserDefaults) throws -> (defaults: UserDefaults, suite: String) {
        let domain = try #require(defaults.persistentDomain(forName: suite))
        let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let persisted = try #require(decoded as? [String: Any])
        let restartedSuite = "test.prefmigration.relaunch.\(UUID().uuidString)"
        let restarted = try #require(UserDefaults(suiteName: restartedSuite))
        for (key, value) in persisted {
            restarted.set(value, forKey: key)
        }
        return (restarted, restartedSuite)
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
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
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
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
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
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
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
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
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
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
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

    @Test("Edits made after the adoption stick: the orphan never re-applies them (#24)")
    func userEditsAfterAdoptionStick() {
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteOrder)
        setAliases(["111000111": "门厅筒灯"], defaults: defaults)
        setTileSizes(["mi_page|111000111": "half"], defaults: defaults)
        _ = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults)

        // The user unhides, unstars, clears the alias and resets the tile on the merged card. The
        // orphaned entries stay on disk for a later single-source home.
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteOrder)
        setAliases(["111000111": "门厅筒灯"], defaults: defaults)
        setTileSizes(["mi_page|111000111": "half"], defaults: defaults)

        let again = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults)
        #expect(again == .none, "A pair already adopted is never merged again")
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111"])
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.favoriteDeviceIds) == ["111000111"])
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.favoriteOrder) == ["111000111"])
        #expect(aliases(defaults: defaults)["ha-light-a"] == nil)
        #expect(tileSizes(defaults: defaults)["mi_page|ha-light-a"] == nil)
    }

    @Test("An adoption with nothing to copy still counts, so a later cleared alias is not refilled (#24)")
    func emptyAdoptionStillCounts() {
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        setAliases(["ha-light-b": "客厅主灯", "222000222": "旧名字"], defaults: defaults)
        let first = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-b", orphanedID: "222000222", defaults: defaults)
        #expect(!first.changed)

        setAliases(["222000222": "旧名字"], defaults: defaults)
        _ = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-b", orphanedID: "222000222", defaults: defaults)
        #expect(aliases(defaults: defaults)["ha-light-b"] == nil, "Clearing the canonical alias is the user's call")
    }

    @Test("A crash between the preference writes and the ledger write stays idempotent (#24)")
    func crashBeforeLedgerWriteIsIdempotent() {
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteOrder)
        _ = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults)
        // The ledger is written last; losing only that write is what a crash can leave behind.
        defaults.removeObject(forKey: ViewPreferenceKeys.adoptedPreferencePairs)

        let rerun = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults)
        #expect(!rerun.changed)
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111", "ha-light-a"])
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.favoriteOrder) == ["111000111", "ha-light-a"])

        // The rerun recorded the pair, so the user's unhide after the restart sticks.
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        _ = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults)
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111"])
    }

    @Test("A relaunch decodes the persisted adoption ledger and keeps the user's edits (#24)")
    func persistedLedgerSurvivesARelaunch() throws {
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        _ = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults)
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111", "ha-light-a"])

        // The user unhides the merged card. The orphaned entry stays on disk for a Mi-only home.
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)

        let relaunched = try relaunchedSuite(suite: suite, from: defaults)
        defer { UserDefaults.standard.removePersistentDomain(forName: relaunched.suite) }
        let again = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: relaunched.defaults
        )
        #expect(again == .none, "The ledger written before the relaunch must still be readable")
        #expect(relaunched.defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111"])
    }

    @Test("Bookkeeping that cannot be read never re-applies preferences the user cleared (#24)")
    func unreadableLedgerNeverReapplies() {
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        // A damaged or foreign ledger: present, but not pairs this build can name. Treating it as
        // empty would merge the still-stored orphan entries and undo the user's edits.
        defaults.set(["ha-light-a": 42], forKey: ViewPreferenceKeys.adoptedPreferencePairs)

        let outcome = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(outcome == .none, "An unreadable ledger is not permission to merge again")
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111"])
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.favoriteDeviceIds) == ["111000111"])
        #expect(defaults.object(forKey: ViewPreferenceKeys.adoptedPreferencePairs) as? [String: Int] == ["ha-light-a": 42])
    }

    @Test("A ledger written by the previous build still counts and is upgraded on the next merge (#24)")
    func legacyDictionaryLedgerStillCounts() {
        let (defaults, suite) = makeSuiteDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        // The shape the first version of this fix wrote: canonical id -> orphaned ids.
        defaults.set(["ha-light-a": ["111000111"]], forKey: ViewPreferenceKeys.adoptedPreferencePairs)

        let first = DevicePreferenceMigrator.adopt(
            canonicalID: "ha-light-a", orphanedID: "111000111", defaults: defaults
        )
        #expect(first == .none)
        #expect(defaults.stringArray(forKey: ViewPreferenceKeys.hiddenDeviceIds) == ["111000111"])

        // A new pair migrates the record to the shape a relaunch always reads back.
        _ = DevicePreferenceMigrator.adopt(canonicalID: "ha-light-b", orphanedID: "222000222", defaults: defaults)
        let stored = defaults.object(forKey: ViewPreferenceKeys.adoptedPreferencePairs) as? [String]
        #expect(stored?.count == 2)
        #expect(stored?.contains { $0.hasSuffix("111000111") } == true)
        #expect(stored?.contains { $0.hasSuffix("222000222") } == true)
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
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
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
        defer { store.stop() }
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

    @Test("Unhiding or unstarring the merged card sticks across snapshots and a relaunch (#24)")
    func storeKeepsUserEditsAfterAdoption() async throws {
        let suite = "test.prefadoption.edits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // HA-side history (a tile) and Mi-side history (hidden, starred): the HA id stays canonical.
        setTileSizes(["ha_page|ha-light-a": "half"], defaults: defaults)
        defaults.set(["111000111"], forKey: ViewPreferenceKeys.hiddenDeviceIds)
        defaults.set(["111000111", "other"], forKey: ViewPreferenceKeys.favoriteDeviceIds)
        defaults.set(["111000111", "other"], forKey: ViewPreferenceKeys.favoriteOrder)

        let miHome = pairableHome(id: "111000111", did: "111000111")
        let haMock = MockHomeProvider(snapshot: pairableHome(id: "ha-light-a", did: "111000111"))
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            provider: HomeStore.makeComposite(homeAssistant: haMock, xiaomiCloud: miMock, defaults: defaults),
            defaultsSuiteName: suite
        )
        defer { store.stop() }
        try await store.waitForTestSnapshot()
        await waitUntil { store.pairedDeviceIDs.contains("ha-light-a") }
        #expect(store.hiddenDeviceIds.contains("ha-light-a"))
        #expect(store.favoriteDeviceIds.contains("ha-light-a"))

        store.hiddenDeviceIds.remove("ha-light-a")
        store.favoriteDeviceIds.remove("ha-light-a")
        store.favoriteOrder.removeAll { $0 == "ha-light-a" }

        let generation = store.snapshotGeneration
        await miMock.updateSnapshot(miHome)
        await waitUntil { store.snapshotGeneration > generation }
        #expect(store.pairedDeviceIDs.contains("ha-light-a"))
        #expect(!store.hiddenDeviceIds.contains("ha-light-a"), "The orphan's hidden flag must not come back")
        #expect(!store.favoriteDeviceIds.contains("ha-light-a"), "The orphan's star must not come back")
        #expect(!store.favoriteOrder.contains("ha-light-a"))

        // A relaunch decodes the persisted suite (property-list object graph) into a fresh defaults
        // instance and must not redo the finished adoption either.
        let persisted = try relaunchedSuite(suite: suite, from: defaults)
        defer { UserDefaults.standard.removePersistentDomain(forName: persisted.suite) }
        let relaunched = HomeStore(
            provider: HomeStore.makeComposite(
                homeAssistant: MockHomeProvider(snapshot: pairableHome(id: "ha-light-a", did: "111000111")),
                xiaomiCloud: MockHomeProvider(snapshot: miHome),
                defaults: persisted.defaults
            ),
            defaultsSuiteName: persisted.suite
        )
        defer { relaunched.stop() }
        try await relaunched.waitForTestSnapshot()
        await waitUntil { relaunched.pairedDeviceIDs.contains("ha-light-a") }
        #expect(!relaunched.hiddenDeviceIds.contains("ha-light-a"))
        #expect(!relaunched.favoriteDeviceIds.contains("ha-light-a"))
    }
}
