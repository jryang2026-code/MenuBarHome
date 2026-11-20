import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

/// P3b-M app-layer entries: `menumijia://` links and Shortcuts refuse a closed Home Assistant type
/// with 「该设备类型已关闭」 before any confirmation, and write nothing.
@Suite(.serialized)
@MainActor
struct HATypePruneAppGateTests {
    private static let hiddenPlug = SmartDevice(
        id: "dev_plug", name: "阳台取暖器", roomId: "balcony", roomName: "阳台",
        model: "ha.switch", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.balcony_heater", isOn: true))
    )

    private static func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set("http://192.168.1.60:8123", forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken("ha-token", defaults: defaults, vault: vault)
        var snapshot = SynthesizedHome()
        snapshot.isInitialLoadComplete = true
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        var selection = store.capabilitySelection
        selection.enabledCategories.remove(.plug)
        store.capabilitySelection = selection
        let scope = store.homeAssistantScopeIdentifier
        store.handleProviderEvent(.haTypePruneChanged(MiotTypePruneReport(
            scope: scope,
            hiddenIndexedDevices: [CapabilityIndexedDevice(
                id: hiddenPlug.id, name: hiddenPlug.name, category: .plug,
                connection: .homeAssistant, sourceScope: scope,
                isSourceAvailable: true, upstreamHiddenOrDisabled: false, participatesInAllOff: false,
                safetySignals: [], readKeys: ["switch.balcony_heater"], safetyReadKeys: ["switch.balcony_heater"]
            )],
            hiddenDeviceIds: [hiddenPlug.id],
            safetyDevices: []
        )))
        return (store, mock)
    }

    @Test("URL links and Shortcuts refuse a closed Home Assistant type before confirming, with zero writes")
    func urlAndShortcutsRefuseAClosedType() async throws {
        let (store, mock) = try await Self.makeStore()
        let closed = ControlTargetRejectionReason.categoryDisabled(.plug).userMessage

        let handler = URLCommandHandler()
        var prompts = 0
        handler.windowVisibilityHandler = {}
        handler.confirmationHandler = { _ in prompts += 1; return true }
        for link in ["menumijia://toggle?device=dev_plug&request_id=r1", "menumijia://power?device=dev_plug&state=off&request_id=r2"] {
            store.dismissToast()
            await handler.handle(try #require(URL(string: link)), in: store)
            #expect(store.toastNotice?.message == closed)
        }
        #expect(prompts == 0)

        let toggle = ToggleDeviceIntent()
        toggle.device = DeviceEntity(device: Self.hiddenPlug)
        #expect(try await toggle.execute(in: store) == closed)

        #expect(await mock.executedCommands.isEmpty)
    }
}
