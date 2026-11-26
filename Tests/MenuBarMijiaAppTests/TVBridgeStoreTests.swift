import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// The optional TV bridge: silent while off, secrets only in the Keychain slot, built-in TVs win a
/// duplicate, panel writes reach `control.execute`, and turning it off stops the process.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TVBridgeStoreTests {
    @MainActor final class Harness {
        let suite = "test.tv-bridge.\(UUID().uuidString)"
        let defaults: UserDefaults
        var secrets: [String: String] = [:]
        var managersMade = 0
        let transport: MockTVBridgeTransport

        init(snapshot: String = #"{"capturedAt":"now","devices":[{"nativeId":"tv-a","name":"卧室电视","online":true,"state":"on","volume":20,"muted":false}]}"#) {
            defaults = UserDefaults(suiteName: suite)!
            transport = MockTVBridgeTransport { frame in
                switch frame.method {
                case "snapshot": TVBridgeFrame(id: frame.id, result: Data(snapshot.utf8))
                default: TVBridgeFrame(id: frame.id, result: Data("{}".utf8))
                }
            }
        }

        func makeStore() -> TVBridgeStore {
            TVBridgeStore(
                defaults: defaults,
                secrets: .init(
                    load: { [unowned self] in self.secrets[$0] },
                    save: { [unowned self] value, slot in
                        self.secrets[slot] = value.isEmpty ? nil : value
                        return true
                    }
                ),
                binaryCandidates: { [] },
                makeManager: { [unowned self] config, credentials in
                    self.managersMade += 1
                    return TVBridgePluginManager(
                        config: config, transport: self.transport, credentialResolver: { credentials[$0] }
                    )
                }
            )
        }

        func methods() async -> [String] { await transport.requests.compactMap(\.method) }

        deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func enabledStore(_ harness: Harness) -> TVBridgeStore {
        let store = harness.makeStore()
        store.setEnabled(true)
        store.setBinaryPath("/usr/local/bin/mbh-tv-bridge")
        store.addDevice(name: "卧室电视", roomName: "卧室", driver: .kodi_jsonrpc, host: "192.168.1.9",
                        port: nil, macAddress: nil, secret: nil)
        return store
    }

    @Test("Off by default: no manager, no RPC, no rows, even when the panel opens")
    func offByDefault() async {
        let harness = Harness()
        let store = harness.makeStore()
        #expect(!store.isEnabled)
        #expect(store.status == .disabled)
        store.pollingContextChanged(PollingContext(panelVisible: true))
        #expect(store.refresh() == nil)
        await #expect(throws: TVBridgeError.disabled) {
            try await store.execute(.mediaPlayPause(entityId: "adapter:com.menubarhome.tv-bridge:tv-a"))
        }
        await store.waitForPendingWork()
        #expect(harness.managersMade == 0)
        #expect(await harness.methods().isEmpty)
        #expect(store.devices.isEmpty)
    }

    @Test("A pairing secret goes to its own Keychain slot; the saved config holds only the slot name")
    func secretsStayInKeychainSlot() throws {
        let harness = Harness()
        let store = harness.makeStore()
        store.setEnabled(true)
        #expect(store.addDevice(name: "Sony", roomName: "客厅", driver: .sony_bravia, host: "192.168.1.2",
                                port: 80, macAddress: nil, secret: "psk-sony-1234"))
        #expect(store.addDevice(name: "LG", roomName: "书房", driver: .lg_webos, host: "192.168.1.3",
                                port: nil, macAddress: nil, secret: "lg-client-key"))
        let slots = store.config.devices.compactMap(\.credentialSlot)
        #expect(slots.count == 2)
        #expect(Set(slots).count == 2)
        #expect(slots.allSatisfy { $0.hasPrefix("tvBridge.cred.") })
        #expect(harness.secrets[slots[0]] == "psk-sony-1234")
        #expect(harness.secrets[slots[1]] == "lg-client-key")

        let saved = try #require(harness.defaults.data(forKey: TVBridgeConfig.userDefaultsKey))
        let raw = try #require(String(data: saved, encoding: .utf8))
        #expect(!raw.contains("psk-sony-1234"))
        #expect(!raw.contains("lg-client-key"))
        let dump = harness.defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!dump.contains("psk-sony-1234"))

        store.removeDevice(nativeId: store.config.devices[0].nativeId)
        #expect(harness.secrets[slots[0]] == nil)
        #expect(harness.secrets[slots[1]] == "lg-client-key")
    }

    @Test("A driver without a pairing step never stores a secret")
    func noSecretForOpenDrivers() {
        let harness = Harness()
        let store = harness.makeStore()
        store.addDevice(name: "Kodi", roomName: "", driver: .kodi_jsonrpc, host: "192.168.1.4",
                        port: nil, macAddress: nil, secret: "ignored")
        #expect(store.config.devices.first?.credentialSlot == nil)
        #expect(harness.secrets.isEmpty)
    }

    @Test("A built-in TV with the same id or name keeps its card; the bridge never takes it over")
    func builtInWins() {
        let spec = TVSpec(mediaEntityId: "media_player.tv", state: "on", volumePercent: 10)
        let builtIn = SmartDevice(id: "media_player.tv", name: "客厅 电视", roomId: "r", roomName: "客厅",
                                  model: "tv", isOnline: true, kind: .tv(spec))
        let duplicate = SmartDevice(id: "adapter:com.menubarhome.tv-bridge:a", name: "客厅电视", roomId: "r",
                                    roomName: "客厅", model: "tv", isOnline: true, kind: .tv(spec))
        let unique = SmartDevice(id: "adapter:com.menubarhome.tv-bridge:b", name: "卧室电视", roomId: "r",
                                 roomName: "卧室", model: "tv", isOnline: true, kind: .tv(spec))
        let rows = HomeStore.nonHijackingAdapterRows([duplicate, unique], builtIn: [builtIn])
        #expect(rows.map(\.id) == [unique.id])
    }

    @Test("Opening the panel snapshots the bridge and adds routable TV rows to the home")
    func panelOpenRefreshes() async throws {
        let harness = Harness()
        let store = enabledStore(harness)
        let home = HomeStore(provider: SilentProvider(), defaultsSuiteName: harness.suite + ".home")
        defer { UserDefaults.standard.removePersistentDomain(forName: harness.suite + ".home") }
        store.attach(to: home)
        #expect(await harness.methods().isEmpty)

        store.pollingContextChanged(PollingContext(panelVisible: true))
        await store.waitForPendingWork()
        #expect(await harness.methods() == ["initialize", "snapshot"])
        #expect(store.status == .running)
        let row = try #require(home.adapterDevices.first)
        #expect(row.id == "adapter:com.menubarhome.tv-bridge:tv-a")
        #expect(home.devices.contains { $0.id == row.id })
        guard case .tv(let spec) = row.kind else { Issue.record("not a TV"); return }
        #expect(spec.mediaEntityId == row.id)
        #expect(spec.muteSwitchEntityId == row.id + "#mute")
    }

    @Test("Drawer and card commands map to bridge verbs and reach control.execute")
    func commandRouting() async throws {
        let id = "adapter:com.menubarhome.tv-bridge:tv-a"
        #expect(TVBridgeStore.bridgeCommand(for: .pressButton(entityId: id + "#power.on"))! == (id, .power(true)))
        #expect(TVBridgeStore.bridgeCommand(for: .pressButton(entityId: id + "#power.off"))! == (id, .power(false)))
        #expect(TVBridgeStore.bridgeCommand(for: .setSwitch(entityId: id + "#mute", isOn: true))! == (id, .setMute(true)))
        #expect(TVBridgeStore.bridgeCommand(for: .mediaSetVolume(entityId: id, volumeLevel: 0.4))! == (id, .setVolume(0.4)))
        #expect(TVBridgeStore.bridgeCommand(for: .mediaSelectSource(entityId: id, source: "HDMI 1"))! == (id, .selectSource("HDMI 1")))
        #expect(TVBridgeStore.bridgeCommand(for: .mediaSeek(entityId: id, positionSec: 42))! == (id, .seek(42)))
        #expect(TVBridgeStore.bridgeCommand(for: .remoteSendKey(entityId: id, key: .up))! == (id, .remoteKey("up")))
        #expect(TVBridgeStore.bridgeCommand(for: .mediaPlayPause(entityId: "media_player.tv")) == nil)

        let harness = Harness()
        let store = enabledStore(harness)
        let home = HomeStore(provider: SilentProvider(), defaultsSuiteName: harness.suite + ".home")
        defer { UserDefaults.standard.removePersistentDomain(forName: harness.suite + ".home") }
        store.attach(to: home)
        let handler = try #require(home.adapterCommandHandler)
        try await handler(.mediaNextTrack(entityId: id))
        let execute = try #require(await harness.transport.requests.last { $0.method == "control.execute" })
        let params = try #require(try JSONSerialization.jsonObject(with: execute.params ?? Data()) as? [String: Any])
        #expect(params["nativeId"] as? String == "tv-a")
        #expect(params["verb"] as? String == "media.next")
    }

    @Test("Turning the bridge off shuts the process down and clears the panel rows")
    func disableShutsDown() async throws {
        let harness = Harness()
        let store = enabledStore(harness)
        let home = HomeStore(provider: SilentProvider(), defaultsSuiteName: harness.suite + ".home")
        defer { UserDefaults.standard.removePersistentDomain(forName: harness.suite + ".home") }
        store.attach(to: home)
        await store.refresh()?.value
        #expect(!home.adapterDevices.isEmpty)

        store.setEnabled(false)
        await store.waitForPendingWork()
        #expect(await harness.methods().last == "shutdown")
        #expect(await harness.transport.closeCount == 1)
        #expect(home.adapterDevices.isEmpty)
        #expect(store.devices.isEmpty)
        #expect(store.status == .disabled)
        #expect(TVBridgeConfig.load(from: harness.defaults).isEnabled == false)
    }

    @Test("Without a binary the status says so and nothing is launched")
    func missingBinary() async {
        let harness = Harness()
        let store = harness.makeStore()
        store.setEnabled(true)
        #expect(store.status == .missingBinary)
        #expect(store.refresh() == nil)
        #expect(harness.managersMade == 0)
    }
}

private actor SilentProvider: HomeProvider {
    nonisolated func events() -> AsyncStream<HomeProviderEvent> { AsyncStream { _ in } }
    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}
}
