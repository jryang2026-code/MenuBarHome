import Foundation
import KeychainTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

/// P2b-M app-layer tests: Shortcuts/App Intents, `menumijia://` URLCommandHandler,
/// `UnsupportedDeviceScanner`, `CameraLivePanelController` teardown, and HA disable confirmation copy.
@Suite(.serialized)
@MainActor
struct HAConnectionAppGateTests {
    private static let haURL = "http://192.168.1.60:8123"
    private static let haScope = "ha:\(haURL)"
    private static let haToken = "ha-app-test-token"

    private static func makeSuite() -> String {
        "com.jryang1997.MenuBarMijia.ha-app-gate.\(UUID().uuidString)"
    }

    private actor AsyncGate {
        private var entered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var callCount = 0

        func enterAndWait() async {
            callCount += 1
            if !entered {
                entered = true
                let waiters = enteredWaiters
                enteredWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            if released { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { continuation in
                if entered {
                    continuation.resume()
                } else {
                    enteredWaiters.append(continuation)
                }
            }
        }

        func release() {
            guard !released else { return }
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private static func makeHAStore(suite: String, snapshot: SynthesizedHome) throws -> (HomeStore, MockHomeProvider, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set(haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken(haToken, defaults: defaults, vault: vault)
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaultsSuiteName: suite, credentialVault: vault)
        return (store, mock, defaults)
    }

    // MARK: - 1. App Intents (ToggleDeviceIntent & RunSceneIntent)

    @Test("App Intents reject disabled HA devices and scenes with distinct copy and zero writes")
    func appIntentsRejectDisabledHADevicesAndScenes() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let haLamp = SmartDevice(
            id: "ha-lamp-1",
            name: "书房台灯",
            roomId: "ha-study",
            roomName: "书房",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study_desk", isOn: true))
        )
        let movieScene = HomeScene(id: "scene.cinema", name: "家庭影院", entityId: "scene.cinema")
        var snapshot = SynthesizedHome(devices: [haLamp], scenes: [movieScene])
        snapshot.isInitialLoadComplete = true

        let (store, mock, _) = try Self.makeHAStore(suite: suite, snapshot: snapshot)
        try await store.waitForTestSnapshot()
        #expect(store.visibleScenes.map(\.id) == ["scene.cinema"])

        _ = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(store.visibleScenes.isEmpty)
        let commandsBefore = await mock.executedCommands.count

        // ToggleDeviceIntent: disabled HA device vs unknown device.
        let toggleDisabled = ToggleDeviceIntent()
        toggleDisabled.device = DeviceEntity(device: haLamp)
        let disabledDeviceReply = try await toggleDisabled.execute(in: store)
        #expect(disabledDeviceReply == "Home Assistant 已停用")

        let toggleMissing = ToggleDeviceIntent()
        toggleMissing.device = DeviceEntity(device: SmartDevice(
            id: "ghost-device",
            name: "不存在的灯",
            roomId: "r",
            roomName: "书房",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.ghost", isOn: false))
        ))
        let missingDeviceReply = try await toggleMissing.execute(in: store)
        #expect(missingDeviceReply.contains("找不到可控设备"))

        // RunSceneIntent: known disabled HA scene vs unknown scene.
        let runDisabledScene = RunSceneIntent()
        runDisabledScene.scene = SceneEntity(scene: movieScene)
        let disabledSceneReply = try await runDisabledScene.execute(in: store)
        #expect(disabledSceneReply == "Home Assistant 已停用")

        let runUnknownScene = RunSceneIntent()
        runUnknownScene.scene = SceneEntity(scene: HomeScene(id: "scene.unknown", name: "未知场景", entityId: "scene.unknown"))
        let unknownSceneReply = try await runUnknownScene.execute(in: store)
        #expect(unknownSceneReply.contains("找不到场景"))

        #expect(await mock.executedCommands.count == commandsBefore)
    }

    // MARK: - 2. URLCommandHandler (`menumijia://` Pre-Modal & Mid-Modal Generation Race)

    @Test("URLCommandHandler blocks menumijia:// toggle, power, and scene links before confirmation and if HA is disabled mid-modal")
    func urlCommandHandlerBlocksDisabledHAAndMidModalDisable() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let haLamp = SmartDevice(
            id: "ha-lamp-1",
            name: "客厅灯",
            roomId: "ha-living",
            roomName: "客厅",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let movieScene = HomeScene(id: "scene.movie", name: "观影模式", entityId: "scene.movie")
        var snapshot = SynthesizedHome(devices: [haLamp], scenes: [movieScene])
        snapshot.isInitialLoadComplete = true

        let (store, mock, _) = try Self.makeHAStore(suite: suite, snapshot: snapshot)
        try await store.waitForTestSnapshot()

        let handler = URLCommandHandler()
        var promptCount = 0
        handler.windowVisibilityHandler = {}
        handler.confirmationHandler = { _ in
            promptCount += 1
            return true
        }

        // 1. Disable HA BEFORE link arrives -> 0 confirmation prompts, "Home Assistant 已停用", 0 writes!
        _ = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        let commandsBefore = await mock.executedCommands.count

        let toggleURL = try #require(URL(string: "menumijia://toggle?device=ha-lamp-1&request_id=req-1"))
        await handler.handle(toggleURL, in: store)
        #expect(promptCount == 0)
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        let powerURL = try #require(URL(string: "menumijia://power?device=ha-lamp-1&state=off&request_id=req-2"))
        await handler.handle(powerURL, in: store)
        #expect(promptCount == 0)
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        let sceneURL = try #require(URL(string: "menumijia://scene?name=scene.movie&request_id=req-3"))
        await handler.handle(sceneURL, in: store)
        #expect(promptCount == 0)
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        let missingSceneURL = try #require(URL(string: "menumijia://scene?name=scene.never_existed&request_id=req-4"))
        await handler.handle(missingSceneURL, in: store)
        #expect(promptCount == 0)
        #expect(store.toastNotice?.message != "Home Assistant 已停用")
        #expect(await mock.executedCommands.count == commandsBefore)

        // 2. Re-enable HA, then disable HA INSIDE confirmationHandler mid-modal -> 0 writes!
        _ = store.setHAConnectionEnabled(true)
        store.devices = [haLamp]
        store.scenes = [movieScene]
        handler.confirmationHandler = { _ in
            promptCount += 1
            _ = store.setHAConnectionEnabled(
                false,
                pauseConfirmed: true,
                expectedGeneration: store.capabilityGeneration
            )
            return true
        }
        await handler.handle(sceneURL, in: store)
        #expect(promptCount == 1)
        #expect(store.toastNotice?.message == "Home Assistant 已停用")
        #expect(await mock.executedCommands.count == commandsBefore)
    }

    // MARK: - 3. UnsupportedDeviceScanner (Disabled HA & Mid-Flight Disable)

    @Test("UnsupportedDeviceScanner skips disabled Home Assistant and drops in-flight HA scan findings when disabled mid-scan")
    func unsupportedDeviceScannerSkipsDisabledHAAndDropsMidFlightScan() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        var snapshot = SynthesizedHome(devices: [])
        snapshot.isInitialLoadComplete = true
        let (store, _, _) = try Self.makeHAStore(suite: suite, snapshot: snapshot)

        let scanner = UnsupportedDeviceScanner.shared
        scanner.reset()
        defer {
            scanner.homeAssistantScanOverride = nil
            scanner.reset()
        }

        let scanGate = AsyncGate()
        scanner.homeAssistantScanOverride = { _, _, _ in
            await scanGate.enterAndWait()
            return [UnsupportedDevice(id: "ha-unsupported-1", name: "扫地机", model: "roborock.s8", reason: .unsupportedEntities)]
        }

        // 1. Start scan while HA is enabled, then disable HA mid-flight: late result must be dropped!
        let midFlightTask = Task {
            await scanner.scan(store: store)
        }
        await scanGate.waitUntilEntered()
        #expect(await scanGate.callCount == 1)

        _ = store.setHAConnectionEnabled(false)
        await scanGate.release()
        await midFlightTask.value

        #expect(scanner.devices.isEmpty)
        #expect(scanner.errorMessage == nil)

        // 2. Scanning while HA is disabled makes ZERO calls to `homeAssistantScanOverride`!
        await scanner.scan(store: store)
        #expect(await scanGate.callCount == 1)
        #expect(scanner.devices.isEmpty)

        // 3. Re-enabling HA and scanning records findings; disabling HA invalidates cached context!
        _ = store.setHAConnectionEnabled(true)
        await scanner.scan(store: store)
        #expect(await scanGate.callCount == 2)
        #expect(scanner.devices.map(\.id) == ["ha-unsupported-1"])

        _ = store.setHAConnectionEnabled(false)
        scanner.invalidateIfContextChanged(for: store)
        #expect(scanner.devices.isEmpty)
    }

    // MARK: - 4. CameraLivePanelController Teardown & Confirmation Copy

    @Test("CameraLivePanelController tears down active HA camera on disable and HADisableConnectionConfirmation renders exact copy")
    func cameraTeardownAndConfirmationCopy() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let haCam = SmartDevice(
            id: "ha-cam-1",
            name: "门廊摄像头",
            roomId: "ha-porch",
            roomName: "玄关",
            model: "ha.camera",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.porch", isOn: true))
        )
        let haScene = HomeScene(id: "scene.movie", name: "观影模式", entityId: "scene.movie")
        var snapshot = SynthesizedHome(devices: [haCam], scenes: [haScene])
        snapshot.isInitialLoadComplete = true
        let (store, _, defaults) = try Self.makeHAStore(suite: suite, snapshot: snapshot)
        try await store.waitForTestSnapshot()

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        store.assistantNow = { now }
        let futureTimer = ScheduledCommand(
            reply: "10 分钟后开启观影模式",
            fireDate: now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "scene.movie", operation: .activateScene)], reply: "开启观影模式", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope]
        )
        ScheduledCommand.save([futureTimer], to: defaults)
        store.restoreScheduledCommands(now: now)
        AutomationRuleStore(defaults: defaults).save([
            AutomationRule(trigger: .away, action: .devices(ids: ["ha-cam-1"], isOn: false), isEnabled: true),
        ])

        let controller = CameraLivePanelController()
        controller.presentsActively = false
        controller.frameDefaults = defaults
        controller.install(with: store)
        defer { controller.closePanel() }

        controller.present(device: haCam)
        #expect(controller.activeDeviceId == "ha-cam-1")

        let previewGen = store.capabilityGeneration
        let preview = store.previewSetHAConnectionEnabled(false)
        #expect(preview.disposition == .requiresPauseConfirmation)

        let confirmation = HADisableConnectionConfirmation(
            itemsToPause: preview.itemsToPause,
            generation: previewGen
        )
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(confirmation.title == "停用 Home Assistant 连接？")
            #expect(confirmation.confirmButtonTitle == "暂停这些项并关闭")
            #expect(confirmation.messageText.contains("10 分钟后开启观影模式"))
            #expect(confirmation.messageText.contains("门廊摄像头"))
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(confirmation.confirmButtonTitle == "Pause These & Turn Off")
        }

        let commit = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: confirmation.generation,
            expectedPauseItemKeys: confirmation.pauseItemKeys
        )
        #expect(commit.disposition == .requiresPauseConfirmation)
        #expect(!store.isHAConnectionEnabled)
        #expect(controller.activeDeviceId == nil)
        #expect(!controller.isVisible)
    }
}
