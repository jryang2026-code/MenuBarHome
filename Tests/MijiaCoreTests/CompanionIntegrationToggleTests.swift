import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

/// P6a-M: companion integration toggle, revocation, copy-config, read-only check,
/// disconnect, upgrade defaults, and persistence-failure rollback.
@Suite(.timeLimit(.minutes(5)))
@MainActor
struct CompanionIntegrationToggleTests {
    private static let lamp = SmartDevice(
        id: "dev_lamp", name: "客厅灯", roomId: "living", roomName: "客厅",
        model: "yeelink.light.ceiling", isOnline: true,
        kind: .light(LightSpec(entityId: "light.living", isOn: true, brightnessPercent: 80))
    )
    private static let movieScene = HomeScene(id: "scene.movie", name: "观影模式", entityId: "scene.movie", iconName: "film.fill")

    private static func makeStore(
        defaults: UserDefaults = InMemoryUserDefaults(),
        vault: CredentialVault? = CredentialVault(storage: MemoryVaultStorage().storage)
    ) async throws -> HomeStore {
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(
                rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 0)], devices: [lamp], scenes: [movieScene]
            )),
            credentialVault: vault, defaults: defaults
        )
        try await store.waitForTestSnapshot()
        return store
    }

    @Test("Fresh installs default off, upgraded users default on, and uncertain identity stays fail-closed")
    func installDefaultsAndUncertainFallback() async throws {
        let fresh = try await Self.makeStore()
        #expect(fresh.capabilityResolutionMode == .freshInstall && !fresh.companionIntegrationEnabled && fresh.raycastBridgeToken == nil)

        let upgradedDefaults = InMemoryUserDefaults()
        upgradedDefaults.set(true, forKey: "has_completed_onboarding")
        let upgraded = try await Self.makeStore(defaults: upgradedDefaults)
        #expect(upgraded.capabilityResolutionMode == .legacyPreserved && upgraded.companionIntegrationEnabled && upgraded.raycastBridgeToken != nil)

        let legacyRaycastDefaults = InMemoryUserDefaults()
        legacyRaycastDefaults.set(true, forKey: RaycastSnapshotExporter.integrationEnabledKey)
        let legacyRaycast = try await Self.makeStore(defaults: legacyRaycastDefaults)
        #expect(legacyRaycast.capabilityResolutionMode == .legacyPreserved && legacyRaycast.companionIntegrationEnabled)

        let mem = MemoryVaultStorage(); mem.readResult = .unavailable
        let uncertainDefaults = InMemoryUserDefaults(); uncertainDefaults.set(true, forKey: "has_completed_onboarding")
        let uncertain = try await Self.makeStore(defaults: uncertainDefaults, vault: CredentialVault(storage: mem.storage))
        #expect(uncertain.isIdentityUncertain && uncertain.companionIntegrationEnabled)
        #expect(uncertain.setCompanionIntegrationEnabled(false) == false && uncertain.companionIntegrationEnabled)
    }

    @Test("Persistence failure rolls back the switch and keeps token and snapshot intact")
    func persistenceFailureRollsBack() async throws {
        let defaults = InMemoryUserDefaults(); defaults.set(true, forKey: "has_completed_onboarding")
        let store = try await Self.makeStore(defaults: defaults)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("p6am-rb-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = tempDir.appendingPathComponent("raycast-snapshot.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        store.raycastSnapshotTestURL = snapshotURL
        store.exportRaycastSnapshotIfNeeded()

        let tokenBefore = try #require(store.raycastBridgeToken)
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        defaults.set(Data("corrupt".utf8), forKey: CapabilitySelectionStore.storageKey)
        #expect(store.setCompanionIntegrationEnabled(false) == false)
        #expect(store.companionIntegrationEnabled && store.raycastBridgeToken == tokenBefore)
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    @Test("Copy config, read-only check, and disconnect work without touching external configs")
    func copyConfigCheckAndDisconnect() async throws {
        let store = try await Self.makeStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("p6am-act-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = tempDir.appendingPathComponent("raycast-snapshot.json")
        let externalConfigURL = tempDir.appendingPathComponent("external-client-config.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let externalOriginal = Data("{\"untouched\":true}".utf8)
        try externalOriginal.write(to: externalConfigURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        store.raycastSnapshotTestURL = snapshotURL

        #expect(store.checkCompanionIntegrationStatus().status == .disabled)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

        #expect(store.setCompanionIntegrationEnabled(true))
        let firstToken = try #require(store.raycastBridgeToken)
        let ready = store.checkCompanionIntegrationStatus()
        #expect(ready.status == .ready && ready.snapshotPresent && ready.tokenMatches && ready.permissionsOwnerOnly)
        #expect(ready.exportedDeviceCount == 1 && ready.exportedSceneCount == 1)

        let configText = store.companionMCPConfigurationJSON(mcpCommandPath: "/opt/MenuBarHome/scripts/mijia-mcp")
        #expect(!configText.contains(firstToken))
        let json = try #require(JSONSerialization.jsonObject(with: Data(configText.utf8)) as? [String: Any])
        let entry = try #require((json["mcpServers"] as? [String: Any])?["menubarhome"] as? [String: Any])
        #expect(entry["command"] as? String == "/opt/MenuBarHome/scripts/mijia-mcp")
        #expect((entry["env"] as? [String: String])?["MENUBARMIJIA_SNAPSHOT_PATH"] == snapshotURL.path)

        var stale = store.buildRaycastSnapshot(); stale.bridgeToken = String(repeating: "0", count: 32)
        try RaycastSnapshotExporter.write(stale, to: snapshotURL)
        let staleReport = store.checkCompanionIntegrationStatus()
        #expect(staleReport.status == .needsAttention && !staleReport.tokenMatches)

        store.recordRaycastCommandFeedback(requestId: "r1", command: "toggle:dev_lamp", message: "ok")
        #expect(store.disconnectCompanionIntegration())
        #expect(!store.companionIntegrationEnabled && store.raycastBridgeToken == nil && store.lastRaycastCommandFeedback == nil)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(URLDirectControl.isRejectedCompanionToken(firstToken, expectedToken: store.raycastBridgeToken))
        #expect(try Data(contentsOf: externalConfigURL) == externalOriginal)

        #expect(store.setCompanionIntegrationEnabled(true))
        let secondToken = try #require(store.raycastBridgeToken)
        #expect(secondToken != firstToken && URLDirectControl.isRejectedCompanionToken(firstToken, expectedToken: secondToken))
        #expect(!URLDirectControl.isRejectedCompanionToken(nil, expectedToken: secondToken))
    }

    @Test("Stale coalesced exports and invalidated background writes never recreate a removed snapshot")
    func staleExportsAreDropped() async throws {
        let store = try await Self.makeStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("p6am-exp-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = tempDir.appendingPathComponent("raycast-snapshot.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        store.raycastSnapshotTestURL = snapshotURL
        let gate = ScheduledCommandTestSupport.SleepGate()
        store.raycastExportSleep = { _ in if !Task.isCancelled { await gate.sleep() } }

        #expect(store.setCompanionIntegrationEnabled(true))
        try FileManager.default.removeItem(at: snapshotURL)
        store.lastExportedRaycastSnapshot = nil

        store.scheduleRaycastSnapshotExport()
        try await awaitState { gate.waiting == 1 }
        let parkedTask = store.raycastExportTask
        #expect(store.setCompanionIntegrationEnabled(false))
        gate.release()
        await parkedTask?.value
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

        let bgURL = tempDir.appendingPathComponent("bg-snapshot.json")
        let staleGen = RaycastSnapshotExporter.currentExportGeneration(for: bgURL)
        _ = RaycastSnapshotExporter.invalidateExports(for: bgURL)
        RaycastSnapshotExporter.writeInBackground(store.buildRaycastSnapshot(), to: bgURL, generation: staleGen)
        RaycastSnapshotExporter.flushBackgroundQueue()
        #expect(!FileManager.default.fileExists(atPath: bgURL.path))
    }

    @Test("Core companion status and error messages localize in zh-Hans, zh-Hant, and English")
    func coreMessagesShipInThreeLanguages() async throws {
        let store = try await Self.makeStore()
        for language in [AppLanguage.zhHans, AppLanguage.zhHant, AppLanguage.en] {
            L10n.$overrideLanguage.withValue(language) {
                let disabled = HomeStore.companionDisabledMessage, invalid = HomeStore.companionInvalidTokenMessage
                let report = store.checkCompanionIntegrationStatus()
                #expect(!disabled.isEmpty && !invalid.isEmpty && !report.summary.isEmpty)
                if language == .zhHant {
                    #expect(disabled == "外部伴生整合已關閉，已拒絕伴生指令")
                    #expect(invalid == "伴生權杖已失效，請重新取得最新本機快照後重試")
                    #expect(report.summary == "伴生整合已關閉，目前不匯出快照並拒絕伴生指令；一般外部連結仍依安全與提醒設定執行")
                } else if language == .en {
                    #expect(disabled.contains("Companion integration is turned off") && invalid.contains("Companion token is invalid"))
                }
            }
        }
    }
}
