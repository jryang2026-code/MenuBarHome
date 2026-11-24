import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

/// #29: the one-click feedback link is built from a live store that knows device names, room names,
/// a device DID and the Home Assistant host, and none of them may reach the issue URL.
@Suite(.serialized)
@MainActor
struct FeedbackDiagnosticsComposerTests {
    private static let deviceName = "客厅空调-Zhang"
    private static let roomName = "主卧-张三"
    private static let did = "700123456"
    private static let model = "ha.climate.700123456"
    private static let host = "192.168.1.60"
    private static let token = "ha-token-secret-value"

    private static func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set("http://\(host):8123", forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken(token, defaults: defaults, vault: vault)

        var snapshot = SynthesizedHome(devices: [
            SmartDevice(
                id: did, name: deviceName, roomId: "room-1", roomName: roomName,
                model: model, isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.living_room", isOn: true))
            ),
            SmartDevice(
                id: "dev-offline", name: "阳台取暖器", roomId: "room-1", roomName: roomName,
                model: "ha.switch", isOnline: false,
                kind: .plug(PlugSpec(switchEntityId: "switch.balcony", isOn: false))
            ),
        ])
        snapshot.isInitialLoadComplete = true
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    @Test("A store full of names, a DID, a LAN host and a token leaves no trace in the link")
    func linkCarriesNoIdentifiers() async throws {
        let (store, _) = try await Self.makeStore()
        #expect(store.devices.count == 2)

        let diagnostics = FeedbackDiagnosticsComposer.make(
            store: store,
            appVersion: "1.5.0",
            osVersion: "Version 27.2.1 (Build 26B131)",
            errorTimestamps: [],
            crashCount: 0,
            transport: nil
        )
        let text = diagnostics.text
        let url = try #require(diagnostics.issueURL())
        let decoded = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
            .removingPercentEncoding ?? ""

        for secret in [Self.deviceName, Self.roomName, Self.did, Self.model, Self.host, Self.token] {
            #expect(!text.contains(secret), "block leaked \(secret)")
            #expect(!url.absoluteString.contains(secret), "URL leaked \(secret)")
            #expect(!decoded.contains(secret), "prefilled query leaked \(secret)")
        }
    }

    @Test("The block reports how many devices each source carries, and which one is online")
    func linkCountsDevicesPerSource() async throws {
        let (store, _) = try await Self.makeStore()

        let diagnostics = FeedbackDiagnosticsComposer.make(
            store: store,
            appVersion: "1.5.0",
            osVersion: "Version 27.2.1",
            errorTimestamps: [],
            crashCount: 0,
            transport: nil
        )

        #expect(diagnostics.backends.count == 1)
        let source = try #require(diagnostics.backends.first)
        #expect(source.label == HomeBackend.homeAssistant.title)
        #expect(source.deviceCount == 2)
        #expect(source.onlineDeviceCount == 1)
        #expect(diagnostics.backendOption == FeedbackBackendOption.homeAssistant)
        #expect(diagnostics.text.contains("ERRORSx") == false)
    }

    @Test("Counted errors and crash reports reach the block as codes, without their times")
    func signalsStayCounts() async throws {
        let (store, _) = try await Self.makeStore()

        let diagnostics = FeedbackDiagnosticsComposer.make(
            store: store,
            appVersion: "1.5.0",
            osVersion: "Version 27.2.1",
            errorTimestamps: [
                Date(timeIntervalSince1970: 1_800_000_000),
                Date(timeIntervalSince1970: 1_800_000_600),
            ],
            crashCount: 2,
            transport: DiagnosticsReportBuilder.TransportSummary(
                lanDeviceCount: 0,
                cloudDeviceCount: 2,
                cooldownDeviceCount: 1,
                blockedDeviceCount: 0,
                isLocalNetworkBlocked: true
            )
        )

        let text = diagnostics.text
        #expect(text.contains("ERRORSx2"))
        #expect(text.contains("CRASHESx2"))
        #expect(text.contains("LAN_COOLDOWNx1"))
        #expect(text.contains("CLOUD_FALLBACKx2"))
        #expect(text.contains("TCC_LOCAL_NETWORKx1"))
        #expect(!text.contains("1_800_000_000"))
        #expect(diagnostics.issueURL()?.absoluteString.count ?? .max <= FeedbackDiagnostics.maxURLLength)
    }
}
