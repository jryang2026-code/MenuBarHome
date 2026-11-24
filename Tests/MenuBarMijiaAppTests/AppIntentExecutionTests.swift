import AppIntents
import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
struct AppIntentExecutionTests {
    private static let lamp = SmartDevice(
        id: "test-lamp", name: "Test lamp", roomId: "study", roomName: "Study",
        model: "test.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.test", isOn: false))
    )
    private static let scene = HomeScene(id: "test-scene", name: "Test scene", entityId: "scene.test")

    @Test("External actions wait for the first snapshot, including an empty home")
    func firstSnapshot() async throws {
        let suite = "test.intent.snapshot.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = ControlledIntentProvider()
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        var returned = false
        let waiting = Task {
            try await store.waitForTestSnapshot()
            returned = true
        }
        await Task.yield()
        #expect(!returned)
        await provider.sendSnapshot(SynthesizedHome())
        try await waiting.value
        #expect(returned)
        #expect(store.devices.isEmpty)
        #expect(store.hasReceivedInitialSnapshot)
    }

    @Test("Missing initial data times out instead of looking like an empty home")
    func snapshotTimeout() async throws {
        let suite = "test.intent.timeout.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: ControlledIntentProvider(), defaultsSuiteName: suite)
        await #expect(throws: HomeProviderError.self) {
            try await store.waitForInitialSnapshot(timeout: .milliseconds(10))
        }
    }

    @Test("Device intent waits for provider rejection and reports rollback")
    func rejectedToggle() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.toggle.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider()
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(devices: [Self.lamp]))
            try await store.waitForTestSnapshot()
            let intent = ToggleDeviceIntent()
            intent.device = DeviceEntity(device: Self.lamp)
            var returned = false
            let invocation = Task {
                let message = try await intent.execute(in: store)
                returned = true
                return message
            }
            await provider.waitForCommand(1)
            #expect(await provider.commandCount == 1)
            #expect(store.waitingDeviceIds.contains("test-lamp"))
            #expect(store.devices.first?.isActiveOn == false)
            #expect(!returned)
            await provider.complete(failing: true)
            let message = try await invocation.value
            #expect(message == "Test lamp failed to respond")
            #expect(store.devices.first?.isActiveOn == false)
            #expect(store.waitingDeviceIds.isEmpty)
        }
    }

    @Test("Scene intent reports provider failure and only reports success after acknowledgment")
    func sceneResult() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.scene.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider()
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(scenes: [Self.scene]))
            try await store.waitForTestSnapshot()
            let intent = RunSceneIntent()
            intent.scene = SceneEntity(scene: Self.scene)
            let failed = Task { try await intent.execute(in: store) }
            await provider.waitForCommand(1)
            #expect(await provider.commandCount == 1)
            await provider.complete(failing: true)
            let failedMessage = try await failed.value
            #expect(failedMessage == "Scene \"Test scene\" failed")
            let succeeded = Task { try await intent.execute(in: store) }
            await provider.waitForCommand(2)
            #expect(await provider.commandCount == 2)
            await provider.complete(failing: false)
            let succeededMessage = try await succeeded.value
            #expect(succeededMessage == "Activated scene: Test scene")
        }
    }

    @Test("Momentary button device intent reports Triggered instead of Turned off (#100)")
    func momentaryButtonIntentResult() async throws {
        let wolDevice = SmartDevice(
            id: "wol_pc", name: "Study PC", roomId: "study", roomName: "Study",
            model: "Wake on LAN", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "button.wake_on_lan_pc", isOn: false))
        )
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.wol.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider()
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            // A momentary plug button is a hazard category, so the app-issued confirmation must be
            // approved for this Shortcuts-path test (#143).
            store.manualControlConfirmationHandler = { _ in true }
            await provider.sendSnapshot(SynthesizedHome(devices: [wolDevice]))
            try await store.waitForTestSnapshot()
            let intent = ToggleDeviceIntent()
            intent.device = DeviceEntity(device: wolDevice)
            let succeeded = Task { try await intent.execute(in: store) }
            await provider.waitForCommand(1)
            #expect(await provider.commandCount == 1)
            await provider.complete(failing: false)
            let succeededMessage = try await succeeded.value
            #expect(succeededMessage == "Triggered Study PC")
        }
    }

    @Test("Shortcuts answer an ambiguous 关灯 without sending any device command")
    func ambiguousBareCategoryStaysHandsOff() async throws {
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let suite = "test.intent.bare.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let ceiling = SmartDevice(
                id: "study_ceiling", name: "书房吸顶灯", roomId: "study", roomName: "书房",
                model: "yeelink.light.ceiling20", isOnline: true,
                kind: .light(LightSpec(entityId: "light.study_ceiling", isOn: true))
            )
            let desk = SmartDevice(
                id: "study_desk", name: "书房台灯", roomId: "study", roomName: "书房",
                model: "yeelink.light.lamp4", isOnline: true,
                kind: .light(LightSpec(entityId: "light.study_desk", isOn: true))
            )
            let provider = ControlledIntentProvider()
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            let intent = AskAssistantIntent()
            intent.text = "关灯"
            await provider.sendSnapshot(SynthesizedHome(devices: [ceiling, desk]))
            try await store.waitForTestSnapshot()

            let message = try await intent.execute(in: store)
            #expect(message == "开着：书房吸顶灯、书房台灯。请说出房间或设备名")
            #expect(await provider.commandCount == 0)
            #expect(store.scheduledCommands.isEmpty)
            #expect(store.devices.allSatisfy { $0.isActiveOn })
        }
    }

    @Test("URLCommandHandler runs trusted bridgeToken silently without stealing focus, while preserving hazard confirmation")
    func urlCommandHandlerBridgeTokenAndHazardGate() async throws {
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let desk = SmartDevice(
                id: "study_desk", name: "书房台灯", roomId: "study", roomName: "书房",
                model: "yeelink.light.lamp4", isOnline: true,
                kind: .light(LightSpec(
                    entityId: "light.study_desk",
                    isOn: false,
                    brightnessPercent: 80,
                    colorTempKelvin: 4000,
                    minKelvin: 2700,
                    maxKelvin: 6500
                ))
            )
            let heater = SmartDevice(
                id: "bath_heater", name: "浴室取暖器插座", roomId: "bath", roomName: "卫生间",
                model: "chuangmi.plug.212a01", isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.bath_heater", isOn: false))
            )
            let provider = ControlledIntentProvider(autoComplete: true)
            let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
            defer { store.stop() }
            await provider.sendSnapshot(SynthesizedHome(devices: [desk, heater]))
            try await store.waitForTestSnapshot()

            let handler = URLCommandHandler()
            var externalAlertsCount = 0
            var windowOpenCount = 0
            var manualHazardConfirmCount = 0
            handler.confirmationHandler = { _ in
                externalAlertsCount += 1
                return false
            }
            handler.windowVisibilityHandler = {
                windowOpenCount += 1
            }
            store.manualControlConfirmationHandler = { _ in
                manualHazardConfirmCount += 1
                return false
            }

            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)

            // 1. Untrusted link without token triggers external URL confirmation and is rejected
            let untrustedURL = try #require(URL(string: "menumijia://toggle?device=study_desk&id=untrusted-1"))
            await handler.handle(untrustedURL, in: store)
            #expect(externalAlertsCount == 1)
            #expect(windowOpenCount == 0)
            #expect(store.lastRaycastCommandFeedback?.requestId == "untrusted-1")
            #expect(store.lastRaycastCommandFeedback?.isError == true)

            // 2. Trusted link with valid bridgeToken skips external URL confirmation and does NOT open window
            let trustedToggleURL = try #require(
                URL(string: "menumijia://toggle?device=study_desk&token=\(token)&id=trusted-toggle-1")
            )
            await handler.handle(trustedToggleURL, in: store)
            #expect(externalAlertsCount == 1) // unchanged
            #expect(windowOpenCount == 0) // did not steal Raycast focus
            #expect(store.devices.first(where: { $0.id == "study_desk" })?.isActiveOn == true)
            #expect(store.lastRaycastCommandFeedback?.requestId == "trusted-toggle-1")
            #expect(store.lastRaycastCommandFeedback?.isError == false)

            // 3. Trusted built-in quick action (`quick:softNightLight`) executes and records feedback
            let quickURL = try #require(
                URL(string: "menumijia://scene?name=quick:softNightLight&token=\(token)&id=trusted-quick-1")
            )
            await handler.handle(quickURL, in: store)
            #expect(windowOpenCount == 0)
            #expect(store.lastRaycastCommandFeedback?.requestId == "trusted-quick-1")
            #expect(store.lastRaycastCommandFeedback?.isError == false)

            // 4. High-risk device (`bath_heater`) STILL requires ManualControlPolicy confirmation even with valid bridgeToken
            let hazardURL = try #require(
                URL(string: "menumijia://toggle?device=bath_heater&token=\(token)&id=trusted-hazard-1")
            )
            await handler.handle(hazardURL, in: store)
            #expect(externalAlertsCount == 1) // URL link alert skipped
            #expect(manualHazardConfirmCount == 1) // Manual hazard confirmation enforced!
            #expect(store.devices.first(where: { $0.id == "bath_heater" })?.isActiveOn == false)
            #expect(store.lastRaycastCommandFeedback?.requestId == "trusted-hazard-1")
            #expect(store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.lastRaycastCommandFeedback?.message.contains("已取消") == true)
        }
    }

    @Test("URLCommandHandler and SceneQuery normalize repeated whitespace in scene names (#31f)")
    func sceneWhitespaceNormalizationInURLAndAppIntents() async throws {
        let suite = "test.scene.whitespace.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = ControlledIntentProvider(autoComplete: true)
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        let spacedScene = HomeScene(id: "sc_movie", name: "  Movie   Night  ", entityId: "scene.movie_night")
        await provider.sendSnapshot(SynthesizedHome(scenes: [spacedScene]))
        try await store.waitForTestSnapshot()

        store.setRaycastIntegration(enabled: true)
        let token = try #require(store.raycastBridgeToken)
        let handler = URLCommandHandler()
        let url = try #require(
            URL(string: "menumijia://scene?name=Movie%20Night&token=\(token)&id=ws-scene-1")
        )
        await handler.handle(url, in: store)
        #expect(await provider.commandCount == 1)
        #expect(store.lastRaycastCommandFeedback?.requestId == "ws-scene-1")
        #expect(store.lastRaycastCommandFeedback?.isError == false)
    }

    @Test("Shortcuts AskAssistantIntent reports screen lock message instead of unexecuted plan reply")
    func askAssistantIntentReportsScreenLockInsteadOfOriginalPlan() async throws {
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let suite = "test.intent.screenlock.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let heater = SmartDevice(
                id: "bath_heater", name: "浴室取暖器插座", roomId: "bath", roomName: "卫生间",
                model: "chuangmi.plug.212a01", isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.bath_heater", isOn: false))
            )
            let provider = ControlledIntentProvider(autoComplete: true)
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(devices: [heater, Self.lamp]))
            try await store.waitForTestSnapshot()

            store.manualControlConfirmationHandler = { _ in
                store.setScreenLocked(true)
                return true
            }

            let hazardIntent = AskAssistantIntent()
            hazardIntent.text = "打开浴室取暖器插座"
            let hazardReply = try await hazardIntent.execute(in: store)
            #expect(hazardReply == store.screenLockBlockedMessage)
            #expect(await provider.commandCount == 0)

            let lowRiskIntent = AskAssistantIntent()
            lowRiskIntent.text = "打开Test lamp"
            let lowRiskReply = try await lowRiskIntent.execute(in: store)
            #expect(lowRiskReply == store.screenLockBlockedMessage)
            #expect(await provider.commandCount == 0)
        }
    }

    @Test("ToggleDeviceIntent returns capability-disabled reason instead of not-found when Xiaomi account is turned off")
    func toggleDeviceIntentReportsDisabledXiaomiAccountInsteadOfNotFound() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let cn = MiAccount(session: MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn"
        ))
        let de = MiAccount(session: MiSession(
            userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de"
        ))
        MiSessionStore.saveAccounts([cn, de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let provider = ControlledIntentProvider(autoComplete: true)
        let store = HomeStore(provider: provider, credentialVault: vault, defaults: defaults)
        let cnLamp = SmartDevice(
            id: "cn-lamp", name: "客厅台灯", roomId: "\(cn.id)/living", roomName: "客厅",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "miot:cn-lamp:2", isOn: true)),
            accountId: cn.id, accountLabel: cn.maskedUserId
        )
        let dePlug = SmartDevice(
            id: "de-plug", name: "书房插座", roomId: "\(de.id)/study", roomName: "书房",
            model: "cuco.plug.v3", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:de-plug:2", isOn: false)),
            accountId: de.id, accountLabel: de.maskedUserId
        )
        await provider.sendSnapshot(SynthesizedHome(devices: [cnLamp, dePlug]))
        try await store.waitForTestSnapshot()

        let entityBeforeDisable = DeviceEntity(device: cnLamp)
        _ = store.setMiAccountEnabled(
            false, id: cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration
        )

        let intent = ToggleDeviceIntent()
        intent.device = entityBeforeDisable

        let zhReply = try await L10n.$overrideLanguage.withValue(.zhHans) {
            try await intent.execute(in: store)
        }
        #expect(zhReply == "该米家账号已停用")

        let enReply = try await L10n.$overrideLanguage.withValue(.en) {
            try await intent.execute(in: store)
        }
        #expect(enReply == "This Xiaomi account is turned off")
        #expect(await provider.commandCount == 0)

        // Genuinely nonexistent device still reports not-found.
        let missingIntent = ToggleDeviceIntent()
        missingIntent.device = DeviceEntity(device: SmartDevice(
            id: "never-existed", name: "幽灵灯", roomId: "r", roomName: "客厅",
            model: "test.light", isOnline: true,
            kind: .light(LightSpec(entityId: "light.ghost", isOn: false))
        ))
        let missingReply = try await L10n.$overrideLanguage.withValue(.zhHans) {
            try await missingIntent.execute(in: store)
        }
        #expect(missingReply == "找不到可控设备「幽灵灯」")
    }

    @Test("UnsupportedDeviceScanner scopes ScanContext and scan sessions strictly to enabledMiAccounts")
    func unsupportedDeviceScannerUsesOnlyEnabledMiAccounts() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let cn = MiAccount(session: MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn"
        ))
        let de = MiAccount(session: MiSession(
            userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de"
        ))
        MiSessionStore.saveAccounts([cn, de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        let bothEnabledContext = UnsupportedDeviceScanner.ScanContext(store: store)
        #expect(bothEnabledContext.miAccountIds == [cn.id, de.id])

        _ = store.setMiAccountEnabled(false, id: cn.id)
        let oneDisabledContext = UnsupportedDeviceScanner.ScanContext(store: store)
        #expect(oneDisabledContext.miAccountIds == [de.id])
        #expect(oneDisabledContext != bothEnabledContext)

        _ = store.setMiAccountEnabled(false, id: de.id)
        let allDisabledContext = UnsupportedDeviceScanner.ScanContext(store: store)
        #expect(allDisabledContext.miAccountIds.isEmpty)

        // With all accounts disabled, `scan(store:)` performs zero cloud requests and completes cleanly with no error.
        let scanner = UnsupportedDeviceScanner.shared
        scanner.reset()
        defer { scanner.reset() }
        await scanner.scan(store: store)
        #expect(scanner.devices.isEmpty)
        #expect(scanner.errorMessage == nil)
        #expect(scanner.lastScannedAt != nil)
    }

    // MARK: - Parameterized intents (#575)

    @Test("Brightness intent sends the exact percentage through the URL control path")
    func brightnessIntentUsesTheWriteGate() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.brightness.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider(autoComplete: true)
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(devices: [Self.lamp]))
            try await store.waitForTestSnapshot()

            let intent = SetBrightnessIntent()
            intent.device = DeviceEntity(device: Self.lamp)
            intent.percent = 35
            let message = try await intent.execute(in: store)
            #expect(message == "Set Test lamp brightness to 35%")
            #expect(await provider.commandCount == 1)
            #expect(store.devices.first?.isActiveOn == true)
        }
    }

    @Test("Brightness intent rejects an out-of-range value instead of forwarding it")
    func brightnessIntentRejectsOutOfRange() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.brightness.range.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider(autoComplete: true)
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(devices: [Self.lamp]))
            try await store.waitForTestSnapshot()

            // `inclusiveRange` stops a Shortcut from sending this, but a stale or hand-edited one can.
            #expect(IntentParameterBounds.brightnessPercent(250) == nil)
            #expect(IntentParameterBounds.brightnessPercent(-1) == nil)
            #expect(IntentParameterBounds.brightnessPercent(0) == 0)
            #expect(IntentParameterBounds.brightnessPercent(100) == 100)

            let intent = SetBrightnessIntent()
            intent.device = DeviceEntity(device: Self.lamp)
            intent.percent = 250
            let message = try await intent.execute(in: store)
            #expect(message == "Brightness must be between 0 and 100")
            #expect(await provider.commandCount == 0)
        }
    }

    @Test("Brightness intent keeps the screen-lock block")
    func brightnessIntentRespectsScreenLock() async throws {
        let suite = "test.intent.brightness.lock.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = ControlledIntentProvider(autoComplete: true)
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        await provider.sendSnapshot(SynthesizedHome(devices: [Self.lamp]))
        try await store.waitForTestSnapshot()
        store.setScreenLocked(true)

        let intent = SetBrightnessIntent()
        intent.device = DeviceEntity(device: Self.lamp)
        intent.percent = 40
        let message = try await intent.execute(in: store)
        #expect(message == store.screenLockBlockedMessage)
        #expect(await provider.commandCount == 0)
    }

    @Test("Colour temperature intent validates the kelvin range and sends the clamped value")
    func colorTemperatureIntentBounds() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.colortemp.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider(autoComplete: true)
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(devices: [Self.lamp]))
            try await store.waitForTestSnapshot()

            #expect(IntentParameterBounds.colorTemperatureKelvin(999) == nil)
            #expect(IntentParameterBounds.colorTemperatureKelvin(20_001) == nil)
            #expect(IntentParameterBounds.colorTemperatureKelvin(4_000) == 4_000)

            let rejected = SetColorTemperatureIntent()
            rejected.device = DeviceEntity(device: Self.lamp)
            rejected.kelvin = 500
            #expect(try await rejected.execute(in: store) == "Colour temperature must be between 1000 and 20000 K")
            #expect(await provider.commandCount == 0)

            let accepted = SetColorTemperatureIntent()
            accepted.device = DeviceEntity(device: Self.lamp)
            accepted.kelvin = 4_000
            #expect(try await accepted.execute(in: store) == "Set Test lamp colour temperature to 4000K")
            #expect(await provider.commandCount == 1)
        }
    }

    @Test("Quick action intent executes through the same bulk-write path as the panel")
    func quickActionIntentRunsThroughTheStore() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.quickaction.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider(autoComplete: true)
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            let onLamp = SmartDevice(
                id: "test-lamp-on", name: "Test lamp", roomId: "study", roomName: "Study",
                model: "test.light", isOnline: true,
                kind: .light(LightSpec(entityId: "light.test", isOn: true, brightnessPercent: 60))
            )
            await provider.sendSnapshot(SynthesizedHome(devices: [onLamp]))
            try await store.waitForTestSnapshot()

            let intent = RunQuickActionIntent()
            intent.action = QuickActionEntity(scene: .lightsOff)
            let message = try await intent.execute(in: store)
            #expect(message == "Executed \"All Lights Off\"")
            #expect(await provider.commandCount == 1)
            #expect(store.devices.first?.isActiveOn == false)

            // A saved shortcut whose raw value no longer resolves reports it instead of crashing.
            let stale = RunQuickActionIntent()
            stale.action = QuickActionEntity(id: "removed-action", name: "Removed")
            #expect(try await stale.execute(in: store) == "Unsupported quick action")
        }
    }

    // MARK: - Focus filter (#575)

    @Test("A quiet Focus filter stores its profile and never silences hazards or the doorbell")
    func focusFilterProfileMapping() throws {
        let suite = "test.focus.filter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let profile = MenuBarHomeFocusFilter.applyProfile(
            suppressNonSafetyNotifications: true,
            focusModeName: "睡眠",
            defaults: defaults
        )
        #expect(profile.isEnabled)
        #expect(profile.focusModeName == "睡眠")
        #expect(FocusFilterStorage.load(defaults: defaults) == profile)

        let ordinary = NotificationDeliveryPolicy.resolve(
            for: .externalAction,
            isFocusActive: true,
            focusFilter: profile
        )
        #expect(ordinary.isSuppressed)

        let hazard = SafetyAlert(id: "sensor:gas:device:1", deviceId: "device", title: "", body: "")
        let hazardPolicy = NotificationDeliveryPolicy.resolve(
            for: .safetyAlert(hazard),
            isFocusActive: true,
            focusFilter: profile
        )
        #expect(!hazardPolicy.isSuppressed)
        #expect(hazardPolicy.interruptionLevel == .timeSensitive)

        let doorbell = NotificationDeliveryPolicy.resolve(
            for: .doorbell,
            isFocusActive: true,
            focusFilter: profile
        )
        #expect(!doorbell.isSuppressed)

        let loud = MenuBarHomeFocusFilter.applyProfile(
            suppressNonSafetyNotifications: false,
            focusModeName: "工作",
            defaults: defaults
        )
        #expect(!loud.suppressNonSafetyNotifications)
        #expect(loud.focusModeName == "工作")
        #expect(
            !NotificationDeliveryPolicy.resolve(
                for: .externalAction,
                isFocusActive: true,
                focusFilter: loud
            ).isSuppressed
        )
    }

    @Test("MenuBarHomeFocusFilter.currentQueryResult maps active, notFound, and unexpected errors")
    func focusFilterCurrentQueryResult() async {
        let sleepIntent = MenuBarHomeFocusFilter()
        sleepIntent.suppressNonSafetyNotifications = true
        sleepIntent.focusModeName = "  睡眠  "
        _ = sleepIntent.displayRepresentation

        let active = await MenuBarHomeFocusFilter.currentQueryResult(timeout: nil) {
            sleepIntent
        }
        #expect(
            active == .active(
                FocusFilterProfile(
                    isEnabled: true,
                    suppressNonSafetyNotifications: true,
                    focusModeName: "睡眠"
                )
            )
        )

        let notFound = await MenuBarHomeFocusFilter.currentQueryResult(timeout: nil) {
            throw SetFocusFilterIntentError.notFound
        }
        #expect(notFound == .notFound)

        let unavailable = await MenuBarHomeFocusFilter.currentQueryResult(timeout: nil) {
            throw SetFocusFilterIntentError.missingParameterValue
        }
        #expect(unavailable == .unavailable)
    }

    @Test("A Focus start action waits for the snapshot and refuses an unknown quick action")
    func focusStartAction() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.focus.start.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider(autoComplete: true)
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            let onLamp = SmartDevice(
                id: "test-lamp-on", name: "Test lamp", roomId: "study", roomName: "Study",
                model: "test.light", isOnline: true,
                kind: .light(LightSpec(entityId: "light.test", isOn: true))
            )
            await provider.sendSnapshot(SynthesizedHome(devices: [onLamp]))
            try await store.waitForTestSnapshot()

            let message = await MenuBarHomeFocusFilter.runStartAction(
                QuickActionEntity(scene: .lightsOff),
                in: store
            )
            #expect(message == "Executed \"All Lights Off\"")
            #expect(await provider.commandCount == 1)

            let unknown = await MenuBarHomeFocusFilter.runStartAction(
                QuickActionEntity(id: "removed-action", name: "Removed"),
                in: store
            )
            #expect(unknown == nil)
        }
    }

    // MARK: - Spotlight index (#575)

    @Test("A Spotlight result carries names only, never the entity id")
    func spotlightItemHidesIdentifiers() throws {
        let entry = SpotlightIndexEntry(
            kind: .device,
            entityId: "did_1234567890",
            title: "客厅顶灯",
            roomName: "客厅",
            keywords: ["客厅顶灯", "客厅"],
            domainIdentifier: "menubarmijia.xiaomiCloud"
        )
        let item = SpotlightIndexer.searchableItem(for: entry)
        let visible = ([item.attributeSet.title ?? "", item.attributeSet.contentDescription ?? ""]
            + (item.attributeSet.keywords ?? [])).joined(separator: " | ")
        #expect(!visible.contains("did_1234567890"))
        #expect(item.attributeSet.title == "客厅顶灯")
        #expect(item.uniqueIdentifier == entry.itemIdentifier)
        #expect(item.domainIdentifier == "menubarmijia.xiaomiCloud")
        let url = try #require(item.attributeSet.contentURL)
        #expect(AppURLParser.parse(url) == .focus(deviceId: "did_1234567890"))
    }

    @Test("Index passes delete what left the home and clear the index when the plan empties")
    func spotlightIndexerBookkeeping() async throws {
        let indexer = SpotlightIndexer()
        var passes: [SpotlightIndexer.Pass] = []
        indexer.writePass = { pass in
            passes.append(pass)
            return true
        }

        let lamp = SpotlightIndexEntry(
            kind: .device, entityId: "lamp", title: "Lamp", roomName: "Study",
            keywords: [], domainIdentifier: "menubarmijia.homeAssistant"
        )
        let scene = SpotlightIndexEntry(
            kind: .scene, entityId: "movie", title: "Movie", roomName: "",
            keywords: [], domainIdentifier: "menubarmijia.homeAssistant"
        )

        await indexer.apply([lamp, scene], signature: "one")
        await indexer.apply([lamp], signature: "two")
        await indexer.apply([], signature: "three")

        #expect(passes.count == 3)
        #expect(passes[0].items.count == 2)
        #expect(passes[1].removals == [scene.itemIdentifier])
        #expect(!passes[1].clearsAll)
        #expect(passes[2].clearsAll)
        #expect(passes[2].items.isEmpty)
    }

    @Test("Signing out clears the whole index immediately instead of waiting for the debounce")
    func spotlightIndexerClearsOnSignOut() async throws {
        let indexer = SpotlightIndexer()
        indexer.debounce = .seconds(30)
        var passes: [SpotlightIndexer.Pass] = []
        indexer.writePass = { pass in
            passes.append(pass)
            return true
        }

        let entry = SpotlightIndexEntry(
            kind: .scene, entityId: "movie", title: "Movie", roomName: "",
            keywords: [], domainIdentifier: "menubarmijia.homeAssistant"
        )
        await indexer.apply([entry], signature: "one")
        #expect(passes.count == 1)

        indexer.handle(.clearNow)
        await waitUntil { passes.count == 2 }
        #expect(passes.last?.clearsAll == true)
        #expect(passes.last?.items.isEmpty == true)
    }

    @Test("Hiding a device refreshes the plan immediately instead of waiting for a poll")
    func hidingADeviceRefreshesTheSpotlightPlan() async throws {
        let suite = "test.spotlight.hidden.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = ControlledIntentProvider(autoComplete: true)
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        await provider.sendSnapshot(SynthesizedHome(devices: [Self.lamp]))
        try await store.waitForTestSnapshot()

        var plans: [[SpotlightIndexEntry]] = []
        store.onSpotlightIndexUpdate = { update in
            if case .plan(let entries) = update { plans.append(entries) }
        }
        store.spotlightIndexEnabled = true
        #expect(plans.last?.contains { $0.entityId == Self.lamp.id } == true)

        store.hiddenDeviceIds.insert(Self.lamp.id)
        #expect(plans.last?.contains { $0.entityId == Self.lamp.id } == false)

        store.hiddenDeviceIds.remove(Self.lamp.id)
        #expect(plans.last?.contains { $0.entityId == Self.lamp.id } == true)
    }

    @Test("A refused index write is retried instead of being remembered as applied")
    func spotlightIndexerRetriesFailedWrites() async throws {
        let indexer = SpotlightIndexer()
        var passes: [SpotlightIndexer.Pass] = []
        var succeeded = false
        indexer.writePass = { pass in
            passes.append(pass)
            return succeeded
        }

        let lamp = SpotlightIndexEntry(
            kind: .device, entityId: "lamp", title: "Lamp", roomName: "Study",
            keywords: [], domainIdentifier: "menubarmijia.homeAssistant"
        )
        let signature = SpotlightIndexPlan.contentSignature(of: [lamp])
        // The first pass is refused, so the same plan must not look "already indexed".
        await indexer.apply([lamp], signature: signature)
        #expect(passes.count == 1)

        succeeded = true
        await indexer.apply([lamp], signature: signature)
        #expect(passes.count == 2)

        // Now that the write succeeded, an unchanged plan is skipped by `accept`: it schedules
        // nothing, so the debounce has nothing to flush.
        indexer.accept([lamp])
        #expect(await indexer.flushPending() == false)
        #expect(passes.count == 2)
    }

    @Test("A stale quick-action identifier still resolves so the intent can report it")
    func staleQuickActionResolves() async throws {
        let query = QuickActionEntityQuery()
        let resolved = try await query.entities(for: ["lightsOff", "removed-action"])
        #expect(resolved.map(\.id) == ["lightsOff", "removed-action"])
        #expect(resolved.last?.name == "removed-action")
    }

    @Test("An unchanged snapshot never rewrites the index")
    func spotlightIndexerSkipsUnchangedPlan() async throws {
        let indexer = SpotlightIndexer()
        var written = 0
        indexer.writePass = { _ in
            written += 1
            return true
        }

        let entry = SpotlightIndexEntry(
            kind: .device, entityId: "lamp", title: "Lamp", roomName: "Study",
            keywords: [], domainIdentifier: "menubarmijia.homeAssistant"
        )
        // The debounce is driven by `flushPending()` instead of the wall clock: a loaded runner has
        // no timer left to lose a race against.
        indexer.accept([entry])
        #expect(await indexer.flushPending() == true)
        #expect(written == 1)

        // A poll that only changed a reading produces the same plan, so nothing is scheduled.
        indexer.accept([entry])
        #expect(await indexer.flushPending() == false)
        #expect(written == 1)

        let renamed = SpotlightIndexEntry(
            kind: .device, entityId: "lamp", title: "Desk Lamp", roomName: "Study",
            keywords: [], domainIdentifier: "menubarmijia.homeAssistant"
        )
        indexer.accept([renamed])
        #expect(await indexer.flushPending() == true)
        #expect(written == 2)
    }
}

private actor ControlledIntentProvider: HomeProvider {
    nonisolated let stream: AsyncStream<HomeProviderEvent>
    private let continuation: AsyncStream<HomeProviderEvent>.Continuation
    private let autoComplete: Bool
    private var pending: CheckedContinuation<Void, any Error>?
    private var commandWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var commandCount = 0

    init(autoComplete: Bool = false) {
        self.autoComplete = autoComplete
        (stream, continuation) = AsyncStream.makeStream()
    }

    nonisolated func events() -> AsyncStream<HomeProviderEvent> { stream }
    func refreshNow() async {}

    func sendSnapshot(_ home: SynthesizedHome) {
        continuation.yield(.snapshotUpdated(home))
    }

    func waitForCommand(_ count: Int) async {
        guard commandCount < count || pending == nil else { return }
        await withCheckedContinuation { commandWaiters.append((count, $0)) }
    }

    func execute(_ command: DeviceCommand) async throws {
        commandCount += 1
        if autoComplete {
            return
        }
        try await withCheckedThrowingContinuation { cont in
            pending = cont
            let ready = commandWaiters.filter { $0.count <= commandCount }
            commandWaiters.removeAll { $0.count <= commandCount }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func complete(failing: Bool) {
        if failing {
            pending?.resume(throwing: HomeProviderError.networkError("Test rejection"))
        } else {
            pending?.resume()
        }
        pending = nil
    }
}
