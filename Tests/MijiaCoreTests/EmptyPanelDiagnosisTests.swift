import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

@Suite("EmptyPanelDiagnosis", .timeLimit(.minutes(1)))
struct EmptyPanelDiagnosisTests {
    private struct GoldenFile: Decodable {
        let version: Int
        let cases: [GoldenCase]
    }

    private struct GoldenInput: Decodable {
        let isDemoMode: Bool
        let sessionState: MiAccountSessionState
        let homeCount: Int
        let deviceCount: Int
        let lastSyncOutcome: EmptyPanelSyncOutcome
        let region: String
        let hasOtherHomesWithDevices: Bool
    }

    private struct GoldenCase: Decodable {
        let id: String
        let input: GoldenInput
        let expectedReason: EmptyPanelReason?
        let expectedAction: EmptyPanelSuggestedAction?
    }

    @Test("Matches every case in empty_panel_diagnosis_golden.json")
    func matchesGoldenCorpus() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/empty_panel_diagnosis_golden.json")
        let data = try Data(contentsOf: fixtureURL)
        let golden = try JSONDecoder().decode(GoldenFile.self, from: data)
        #expect(golden.version == 1)
        #expect(!golden.cases.isEmpty)

        for item in golden.cases {
            let reason = EmptyPanelDiagnosis.diagnose(EmptyPanelDiagnosisInput(
                isDemoMode: item.input.isDemoMode,
                sessionState: item.input.sessionState,
                homeCount: item.input.homeCount,
                deviceCount: item.input.deviceCount,
                lastSyncOutcome: item.input.lastSyncOutcome,
                region: item.input.region,
                hasOtherHomesWithDevices: item.input.hasOtherHomesWithDevices
            ))
            #expect(reason == item.expectedReason, "Case \(item.id): expected reason \(String(describing: item.expectedReason)), got \(String(describing: reason))")
            #expect(reason?.suggestedAction == item.expectedAction, "Case \(item.id): expected action \(String(describing: item.expectedAction)), got \(String(describing: reason?.suggestedAction))")
        }
    }

    @MainActor
    @Test("HomeStore.emptyPanelDiagnosis covers demo, devices present, selected empty home, and all 5 Mi empty reasons")
    func homeStoreEmptyPanelDiagnosis() {
        let store = HomeStore(provider: MockHomeProvider(), defaults: InMemoryUserDefaults())

        // Demo mode never diagnoses even when devices are empty.
        store.homeBackend = .demo
        store.devices = []
        store.homes = []
        store.hasReceivedInitialSnapshot = true
        #expect(store.emptyPanelDiagnosis == nil)

        // Signed-in Mi Cloud account on cn with 0 homes and 0 devices -> noHomes.
        let session = MiSession(
            userId: "1234567890",
            cUserId: "c-uid",
            ssecurity: "ssec",
            serviceToken: "tok",
            region: "cn"
        )
        store.homeBackend = .xiaomiCloud
        store.miAccounts = [MiAccount(session: session)]
        store.miSessionMaskedUserId = session.maskedUserId
        store.miCloudRegion = .cn
        store.connectionStatus = .connected
        store.hasReceivedInitialSnapshot = true
        store.homes = []
        store.devices = []
        #expect(store.emptyPanelDiagnosis == .noHomes)

        // Overseas region with 0 homes -> possibleWrongRegion.
        store.miCloudRegion = .sg
        #expect(store.emptyPanelDiagnosis == .possibleWrongRegion)

        // Homes present but 0 devices -> homesWithoutDevices.
        store.miCloudRegion = .cn
        store.homes = [HomeOption(id: "h1", name: "我的家", deviceCount: 0)]
        #expect(store.emptyPanelDiagnosis == .homesWithoutDevices)

        // Selected home is empty while another home has devices -> nil (handled by Show All Homes banner).
        store.homes = [
            HomeOption(id: "h1", name: "空家", deviceCount: 0),
            HomeOption(id: "h2", name: "老家", deviceCount: 3),
        ]
        store.selectedMiHomeId = "h1"
        #expect(store.emptyPanelDiagnosis == nil)
        store.selectedMiHomeId = nil

        // Sync failure (disconnected without expired session) -> syncFailed.
        store.connectionStatus = .disconnected("network timeout")
        #expect(store.emptyPanelDiagnosis == .syncFailed)

        // Expired session -> sessionReauthRequired.
        let expiredSession = MiSession(
            userId: "1234567890",
            cUserId: "c-uid",
            ssecurity: "ssec",
            serviceToken: "tok",
            region: "cn",
            expiresAt: Date().addingTimeInterval(-60)
        )
        store.miAccounts = [MiAccount(session: expiredSession)]
        store.miSessionExpiresAt = expiredSession.expiresAt
        #expect(store.emptyPanelDiagnosis == .sessionReauthRequired)

        // Normal user with >= 1 device -> nil (zero change).
        store.devices = [
            SmartDevice(
                id: "dev-1",
                name: "客厅灯",
                roomId: "r1",
                roomName: "客厅",
                model: "yeelink.light.ceiling22",
                isOnline: true,
                kind: .light(.init(entityId: "did-1", isOn: true))
            )
        ]
        #expect(store.emptyPanelDiagnosis == nil)
    }
}
