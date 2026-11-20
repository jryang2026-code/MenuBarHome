import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #20: the Raycast/CLI links land on the same handler as hand-written ones, so the bridge token, the
/// confirmation sheet, the high-risk gate and the command feedback have to hold for them too.
@MainActor
struct URLCommandHandlerTests {
    private static let lamp = SmartDevice(
        id: "dev_lamp",
        name: "Study Lamp",
        roomId: "study",
        roomName: "Study",
        model: "test.light",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 80))
    )
    private static let airConditioner = SmartDevice(
        id: "dev_ac",
        name: "Study AC",
        roomId: "study",
        roomName: "Study",
        model: "test.aircondition",
        isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.ac",
            isOn: true,
            hvacMode: "cool",
            availableModes: ["off", "cool"],
            targetTemperature: 25
        ))
    )

    private static func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let suite = "test.urlhandler.\(UUID().uuidString)"
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "study", name: "Study", sortOrder: 0)],
            devices: [lamp, airConditioner]
        ))
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        return (store, provider)
    }

    private static let chineseLamp = SmartDevice(
        id: "dev_lamp",
        name: "台灯",
        roomId: "study",
        roomName: "Study",
        model: "test.light",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 80))
    )

    private static func makeBlockedStore(
        devices: [SmartDevice]? = nil
    ) async throws -> (HomeStore, MockHomeProvider) {
        let suite = "test.urlhandler.blocked.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "study", name: "Study", sortOrder: 0)],
            devices: devices ?? [lamp]
        ))
        let expired = MiSession(
            userId: "1234567890",
            cUserId: "cu",
            ssecurity: "s",
            serviceToken: "tok",
            expiresAt: Date().addingTimeInterval(-60)
        )
        #expect(MiSessionStore.save(expired, defaults: defaults))
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        return (store, provider)
    }

    private static func url(_ raw: String) throws -> URL {
        try #require(URL(string: raw))
    }

    @Test("A power link carrying the bridge token skips the sheet and reports its result")
    func trustedPowerLinkSkipsTheSheet() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()
            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)

            let handler = URLCommandHandler()
            var asked = false
            handler.confirmationHandler = { _ in
                asked = true
                return false
            }

            let link = try Self.url("menumijia://power?device=dev_lamp&on=false&id=cli-1&token=\(token)")
            await handler.handle(link, in: store)

            #expect(!asked, "a trusted companion link must not show the confirmation sheet")
            #expect(store.devices.first { $0.id == "dev_lamp" }?.isActiveOn == false)
            #expect(await provider.executedCommands.count == 1)
            #expect(store.lastRaycastCommandFeedback?.requestId == "cli-1")
            #expect(store.lastRaycastCommandFeedback?.isError == false)
            #expect(store.lastRaycastCommandFeedback?.message.contains("Turned off") == true)
        }
    }

    @Test("An ask link while expired shows its failure, then restores the scan toast")
    func askLinkRestoresScanToast() async throws {
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let (store, provider) = try await Self.makeBlockedStore(devices: [Self.chineseLamp])
            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)
            let lamp = try #require(store.devices.first)
            #expect(store.togglePrimary(lamp) == nil)
            #expect(store.toastNotice?.persistent == true)

            let handler = URLCommandHandler()
            let link = try Self.url(
                "menumijia://ask?text=%E5%85%B3%E7%81%AF&id=cli-ask&token=\(token)"
            )
            await handler.handle(link, in: store)

            #expect(store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.lastRaycastCommandFeedback?.message == "台灯 未响应")
            // The assistant failure is shown; the scan prompt waits behind it and returns.
            #expect(store.toastNotice?.message == "台灯 未响应")
            #expect(store.toastNotice?.persistent == false)
            store.dismissToast()
            #expect(store.toastNotice?.message == "米家登录已过期")
            #expect(store.toastNotice?.persistent == true)
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("A power link shows its refusal, then restores a suspended scan toast")
    func blockedPowerLinkRestoresScanToast() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeBlockedStore()
            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)
            // An earlier Mi tap left the toast on screen before the link arrives, so the refusal
            // does not create a new id for a previous-toast-id check to notice.
            let lamp = try #require(store.devices.first)
            #expect(store.togglePrimary(lamp) == nil)
            #expect(store.toastNotice?.persistent == true)

            let handler = URLCommandHandler()
            let link = try Self.url(
                "menumijia://power?device=dev_lamp&on=false&id=cli-blocked-power&token=\(token)"
            )
            await handler.handle(link, in: store)

            #expect(store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.lastRaycastCommandFeedback?.message == "Xiaomi Home session expired")
            #expect(store.toastNotice?.message == "Xiaomi Home session expired")
            #expect(store.toastNotice?.persistent == false)
            store.dismissToast()
            #expect(store.toastNotice?.persistent == true)
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("An untrusted ordinary link names the device and the value, and a refusal sends nothing")
    func untrustedLinkAsksWithTheExactValue() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()
            // Integration off: ordinary links without a token still ask for confirmation.
            #expect(store.raycastBridgeToken == nil)

            let handler = URLCommandHandler()
            var prompt: String?
            handler.confirmationHandler = { description in
                prompt = description
                return false
            }

            let link = try Self.url("menumijia://brightness?device=dev_lamp&percent=40&id=cli-2")
            await handler.handle(link, in: store)

            let sheet = try #require(prompt)
            #expect(sheet.contains("Study Lamp"))
            #expect(sheet.contains("40%"))
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.lastRaycastCommandFeedback?.message.contains("Cancelled") == true)
        }
    }

    @Test("Two blocked URL toggles in a row both report the expired session")
    func consecutiveBlockedTogglesReportSession() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeBlockedStore()
            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)
            let handler = URLCommandHandler()

            for index in 1...2 {
                let link = try Self.url(
                    "menumijia://toggle?device=dev_lamp&id=cli-toggle-\(index)&token=\(token)"
                )
                await handler.handle(link, in: store)
                #expect(store.lastRaycastCommandFeedback?.isError == true)
                #expect(
                    store.lastRaycastCommandFeedback?.message == "Xiaomi Home session expired",
                    "toggle \(index) must name the expired session, not a device failure"
                )
            }
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("A focus link opens the panel on the device without asking and without sending a command")
    func focusLinkOpensThePanel() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()

            let handler = URLCommandHandler()
            var asked = false
            handler.confirmationHandler = { _ in
                asked = true
                return false
            }
            var windowShown = 0
            handler.windowVisibilityHandler = { windowShown += 1 }

            let link = try Self.url("menumijia://focus?device=dev_ac&id=cli-3")
            await handler.handle(link, in: store)

            #expect(!asked, "showing a drawer is navigation, not a device control")
            #expect(store.expandedDeviceId == "dev_ac")
            #expect(windowShown == 1)
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.lastRaycastCommandFeedback?.isError == false)
        }
    }

    // MARK: - P6a-M Companion Integration Toggle & Revocation

    @Test("Disabled companion rejects token-bearing commands without downgrading, while ordinary links keep working")
    func disabledCompanionRejectsCompanionLinksButKeepsOrdinaryLinks() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("p6am-dis-\(UUID().uuidString)", isDirectory: true)
            let snapshotURL = tempDir.appendingPathComponent("raycast-snapshot.json")
            defer { try? FileManager.default.removeItem(at: tempDir) }
            store.raycastSnapshotTestURL = snapshotURL

            #expect(!store.companionIntegrationEnabled)
            // Even with direct URL control enabled, token-bearing companion commands must be rejected.
            store.userDefaults.set(true, forKey: URLDirectControl.allowDirectControlKey)
            let handler = URLCommandHandler()
            var prompts = 0, windows = 0
            handler.confirmationHandler = { _ in prompts += 1; return true }
            handler.windowVisibilityHandler = { windows += 1 }
            let staleToken = String(repeating: "a", count: 32)
            for raw in ["menumijia://toggle?device=dev_lamp&id=d1&token=\(staleToken)",
                        "menumijia://power?device=dev_lamp&on=false&id=d2&token=\(staleToken)",
                        "menumijia://focus?device=dev_ac&id=d3&token=\(staleToken)",
                        "menubarhome://ask?text=turn%20off&id=d4&token=\(staleToken)"] {
                await handler.handle(try Self.url(raw), in: store)
            }
            #expect(prompts == 0 && windows == 0 && store.expandedDeviceId == nil)
            #expect(await provider.executedCommands.isEmpty); #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
            #expect(store.toastNotice?.message == HomeStore.companionDisabledMessage)

            // Ordinary link without `token=` still obeys existing direct-control / confirmation policy.
            await handler.handle(try Self.url("menumijia://power?device=dev_lamp&on=false&id=ord-off"), in: store)
            #expect(await provider.executedCommands.count == 1)
            #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        }
    }

    @Test("Revoked bridge token is rejected without downgrading to an ordinary link, even with allow_url_direct_control")
    func revokedBridgeTokenNeverDowngrades() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()
            #expect(store.setCompanionIntegrationEnabled(true))
            let revokedToken = try #require(store.raycastBridgeToken)
            #expect(store.disconnectCompanionIntegration() && store.setCompanionIntegrationEnabled(true))
            #expect(try #require(store.raycastBridgeToken) != revokedToken)

            store.userDefaults.set(true, forKey: URLDirectControl.allowDirectControlKey)
            let handler = URLCommandHandler()
            var prompts = 0
            handler.confirmationHandler = { _ in prompts += 1; return true }
            handler.windowVisibilityHandler = {}

            await handler.handle(try Self.url("menumijia://power?device=dev_lamp&on=false&id=old-1&token=\(revokedToken)"), in: store)
            #expect(prompts == 0); #expect(await provider.executedCommands.isEmpty)
            #expect(store.lastRaycastCommandFeedback?.requestId == "old-1" && store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.toastNotice?.message == HomeStore.companionInvalidTokenMessage)

            await handler.handle(try Self.url("menumijia://power?device=dev_lamp&on=false&id=ord-1"), in: store)
            #expect(prompts == 0); #expect(await provider.executedCommands.count == 1)
        }
    }

    @Test("Queued companion commands invalidated by disable or enqueued while disabled never execute after re-enabling")
    func queuedCommandsCannotRunAfterDisableAndReenable() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let heater = SmartDevice(
                id: "dev_heater", name: "Bathroom Heater", roomId: "study", roomName: "Study",
                model: "chuangmi.plug.212a01", isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: false))
            )
            let suite = "test.urlhandler.queue.\(UUID().uuidString)"
            let provider = MockHomeProvider(snapshot: SynthesizedHome(
                rooms: [RoomArea(id: "study", name: "Study", sortOrder: 0)],
                devices: [Self.lamp, heater]
            ))
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            try await store.waitForTestSnapshot()

            let handler = URLCommandHandler()
            handler.windowVisibilityHandler = {}
            store.onCompanionIntegrationChanged = { if !$0 { handler.invalidatePendingCommands() } }

            // Enqueued while disabled -> dropped immediately and never runs after enabling.
            let dummyToken = String(repeating: "b", count: 32)
            handler.enqueue([try Self.url("menumijia://power?device=dev_lamp&on=false&id=off-q1&token=\(dummyToken)")], in: store)
            await handler.waitForDrainForTesting()
            #expect(store.setCompanionIntegrationEnabled(true)); #expect(await provider.executedCommands.isEmpty)

            // Enqueued while enabled -> disabling + re-enabling mid-confirmation invalidates both commands.
            let activeToken = try #require(store.raycastBridgeToken)
            store.manualControlConfirmationHandler = { _ in
                #expect(store.setCompanionIntegrationEnabled(false) && store.setCompanionIntegrationEnabled(true))
                return true
            }
            handler.enqueue([
                try Self.url("menumijia://power?device=dev_heater&on=true&id=q-1&token=\(activeToken)"),
                try Self.url("menumijia://power?device=dev_lamp&on=false&id=q-2&token=\(activeToken)")
            ], in: store)
            await handler.waitForDrainForTesting()
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("Persistence failure rolls back the switch so UI state and command acceptance never disagree")
    func persistenceFailureRollsBackSwitchAndKeepsCommandsConsistent() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()
            #expect(store.setCompanionIntegrationEnabled(true))
            let token = try #require(store.raycastBridgeToken)
            store.userDefaults.set(Data("corrupt".utf8), forKey: CapabilitySelectionStore.storageKey)
            #expect(store.setCompanionIntegrationEnabled(false) == false)
            #expect(store.companionIntegrationEnabled && store.raycastBridgeToken == token)

            let handler = URLCommandHandler()
            handler.windowVisibilityHandler = {}
            await handler.handle(try Self.url("menumijia://power?device=dev_lamp&on=false&id=rb-1&token=\(token)"), in: store)
            #expect(await provider.executedCommands.count == 1)
        }
    }

    @Test("Companion integration UI copy ships in zh-Hans, zh-Hant, and English")
    func companionCopyShipsInThreeLanguages() {
        for language in [AppLanguage.zhHans, AppLanguage.zhHant, AppLanguage.en] {
            L10n.$overrideLanguage.withValue(language) {
                #expect(!CompanionSettingsCopy.toggleTitle.isEmpty && !CompanionSettingsCopy.scopeHint.isEmpty && !CompanionSettingsCopy.copiedToast.isEmpty)
                if language == .zhHant {
                    #expect(CompanionSettingsCopy.toggleTitle == "外部快捷工具與伴生整合（Raycast / CLI / MCP）")
                    #expect(CompanionSettingsCopy.copyConfigButton == "複製設定" && CompanionSettingsCopy.checkButton == "檢查" && CompanionSettingsCopy.disconnectButton == "斷開")
                } else if language == .en {
                    #expect(CompanionSettingsCopy.copyConfigButton == "Copy Config" && CompanionSettingsCopy.checkButton == "Check" && CompanionSettingsCopy.disconnectButton == "Disconnect")
                }
            }
        }
    }
}
