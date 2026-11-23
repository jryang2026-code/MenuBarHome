import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HAConnectionDisableTests {
    private static let haURL = "http://192.168.1.50:8123"
    private static let haScope = "ha:http://192.168.1.50:8123"
    private static let haToken = "ha-long-lived-secret-token"
    private static let miSession = MiSession(
        userId: "10010001",
        cUserId: "c-cn",
        ssecurity: "ssec-cn",
        serviceToken: "tok-cn",
        region: "cn"
    )
    private static let miAccount = MiAccount(session: miSession)

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

    private actor StubHARuntimeProvider: HomeProvider {
        private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
        private var initialSnapshot: SynthesizedHome?
        private(set) var shutdownCalls = 0
        private(set) var refreshCalls = 0
        private(set) var executedCommands: [DeviceCommand] = []
        private(set) var cameraResolveCalls: [String] = []
        private(set) var sensorHistoryCalls: [String] = []
        private var shutdownHook: (@Sendable () async -> Void)?

        init(initialSnapshot: SynthesizedHome? = nil) {
            self.initialSnapshot = initialSnapshot
        }

        func setShutdownHook(_ hook: (@Sendable () async -> Void)?) {
            shutdownHook = hook
        }

        func setInitialSnapshot(_ snapshot: SynthesizedHome?) {
            initialSnapshot = snapshot
        }

        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            AsyncStream { continuation in
                Task { await self.attach(continuation) }
            }
        }

        private func attach(_ continuation: AsyncStream<HomeProviderEvent>.Continuation) {
            self.continuation = continuation
            continuation.yield(.statusChanged(.connected))
            if let snapshot = initialSnapshot {
                continuation.yield(.snapshotUpdated(snapshot))
            }
        }

        func emit(_ event: HomeProviderEvent) {
            continuation?.yield(event)
        }

        func execute(_ command: DeviceCommand) async throws {
            executedCommands.append(command)
        }

        func refreshNow() async {
            refreshCalls += 1
        }

        func fetchSensorHistory(deviceId: String, window: SensorHistoryWindow, now: Date) async -> [SensorHistorySample] {
            sensorHistoryCalls.append(deviceId)
            return []
        }

        func resolveCameraStream(
            for device: SmartDevice,
            quality: XiaomiCameraStreamQuality,
            channel: Int
        ) async throws -> CameraStreamSource {
            cameraResolveCalls.append(device.id)
            return .hls(URL(string: "http://192.168.1.50:8123/api/hls/master.m3u8")!)
        }

        func shutdown() async {
            if let hook = shutdownHook {
                await hook()
            }
            shutdownCalls += 1
            continuation?.finish()
            continuation = nil
        }
    }

    private static func seedHAConfig(_ defaults: UserDefaults, _ vault: CredentialVault, url: String = haURL) {
        defaults.set(url, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken(haToken, defaults: defaults, vault: vault)
    }

    private static func makeLoadedSnapshot(devices: [SmartDevice] = [], scenes: [HomeScene] = []) -> SynthesizedHome {
        var snapshot = SynthesizedHome(devices: devices, scenes: scenes)
        snapshot.isInitialLoadComplete = true
        return snapshot
    }

    private static func makeLight(
        id: String,
        name: String,
        roomId: String = "living",
        roomName: String = "客厅",
        model: String = "ha.light",
        entityId: String,
        isOn: Bool = true,
        brightness: Int? = nil,
        accountId: String? = nil
    ) -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: roomId,
            roomName: roomName,
            model: model,
            isOnline: true,
            kind: .light(LightSpec(entityId: entityId, isOn: isOn, brightnessPercent: brightness)),
            accountId: accountId
        )
    }

    private static func makeTimer(
        reply: String,
        fireDate: Date,
        targetId: String,
        operation: IntentOperation = .power(false),
        scope: String = haScope,
        scopes: [String]? = nil
    ) -> ScheduledCommand {
        ScheduledCommand(
            reply: reply,
            fireDate: fireDate,
            plan: IntentPlan(intents: [DeviceIntent(targetId: targetId, operation: operation)], reply: reply, source: .local),
            sourceScope: scope,
            sourceScopes: scopes ?? [scope]
        )
    }

    @Test("Legacy upgrade, unknown JSON preservation, uncertain vault fallback, panelHealth, and demo switch")
    func legacyUpgradeFallbackPanelHealthAndDemoSwitch() async throws {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedHAConfig(defaults, vault)

        let first = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        #expect(first.hasHASource && first.isHAConnectionEnabled && first.hasEnabledHASource)
        #expect(first.activeBackends == [.homeAssistant])
        #expect(first.activeConnectionScopes == [Self.haScope])
        #expect(CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))

        let rawData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        var json = try #require(try JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        json["futureTopLevelFlag"] = "keep-ha-future"
        json["enabledFeatures"] = ((json["enabledFeatures"] as? [String]) ?? []) + ["future.ha.feature"]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: CapabilitySelectionStore.storageKey)

        first.haPlaintextPrompt = .declined("http://203.0.113.9:8123")
        #expect(first.setHAConnectionEnabled(false).disposition == .allowed)
        #expect(!first.isHAConnectionEnabled && !first.hasEnabledHASource && first.hasHASource)
        #expect(first.activeBackends.isEmpty && first.activeConnectionScopes.isEmpty)
        #expect(first.allConfiguredSourcesTurnedOff && first.haPlaintextPrompt == nil)

        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(first.panelHealth == .blocked(reason: "连接已停用 · 点此重新启用", action: .openConnectionSettings))
            #expect(first.serverHostSummary.contains("已停用"))
        }

        let updatedData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let updatedJSON = try #require(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        #expect(updatedJSON["futureTopLevelFlag"] as? String == "keep-ha-future")
        #expect((updatedJSON["enabledFeatures"] as? [String])?.contains("future.ha.feature") == true)
        #expect((updatedJSON["disabledConnections"] as? [String])?.contains("home-assistant") == true)

        let second = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        #expect(second.hasHASource && !second.isHAConnectionEnabled)

        mem.readResult = .unavailable
        let fallbackAfterDisable = HomeStore(
            provider: MockHomeProvider(),
            credentialVault: CredentialVault(storage: mem.storage),
            defaults: defaults
        )
        #expect(fallbackAfterDisable.capabilityResolutionMode == .uncertainFallback)
        fallbackAfterDisable.hasHASource = true
        #expect(!fallbackAfterDisable.isHAConnectionEnabled)

        let unmigratedDefaults = InMemoryUserDefaults()
        let unmigratedMem = MemoryVaultStorage()
        Self.seedHAConfig(unmigratedDefaults, CredentialVault(storage: unmigratedMem.storage))
        unmigratedMem.readResult = .unavailable
        let fallbackBeforeMigration = HomeStore(
            provider: MockHomeProvider(),
            credentialVault: CredentialVault(storage: unmigratedMem.storage),
            defaults: unmigratedDefaults
        )
        #expect(!CapabilitySelectionStore.hasCompletedMigration(defaults: unmigratedDefaults))
        #expect(fallbackBeforeMigration.capabilityResolutionMode == .uncertainFallback)

        let dualDefaults = InMemoryUserDefaults()
        let dualVault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(dualDefaults, dualVault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: dualDefaults, vault: dualVault)
        let dualStore = HomeStore(provider: MockHomeProvider(), credentialVault: dualVault, defaults: dualDefaults)
        dualStore.miAccountStatuses = [Self.miAccount.id: .connected]
        dualStore.sourceStatuses = [.xiaomiCloud: .connected, .homeAssistant: .disconnected("LAN down")]
        dualStore.connectedBackends = [.xiaomiCloud]
        dualStore.connectionStatus = .connected
        #expect(dualStore.setHAConnectionEnabled(false).disposition == .allowed)
        #expect(dualStore.activeBackends == [.xiaomiCloud] && dualStore.activeConnectionScopes == [Self.miAccount.id])
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(dualStore.panelHealth == .ok)
            #expect(dualStore.dualSourceStatusSummary == "米家云已连接（HA 已停用）")
        }

        first.switchBackend(.demo)
        try await awaitState { first.hasReceivedInitialSnapshot }
        #expect(first.homeBackend == .demo && !first.allConfiguredSourcesTurnedOff)
        #expect(first.connectionStatus == .connected && first.scenes.count == 2 && !first.devices.isEmpty)
    }

    @Test("Disabling HA awaits shutdown, clears runtime state, drops late events, short-circuits reads during slow teardown, and reopens gate on re-enable")
    func runtimeTeardownLateEventsSlowShutdownAndReenableGate() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let haLight = Self.makeLight(id: "ha-light", name: "客厅射灯", roomId: "ha-living", entityId: "light.living_spot")
        let haCam = SmartDevice(
            id: "ha-cam",
            name: "门廊摄像头",
            roomId: "ha-porch",
            roomName: "玄关",
            model: "ha.camera",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.porch", isOn: true))
        )
        let haSensor = SmartDevice(
            id: "ha-sensor",
            name: "客厅传感器",
            roomId: "ha-living",
            roomName: "客厅",
            model: "ha.sensor",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 24.0, humidity: 48))
        )
        let haScene = HomeScene(id: "scene.movie", name: "观影模式", entityId: "scene.movie")
        var initialHAHome = SynthesizedHome(
            rooms: [RoomArea(id: "ha-living", name: "客厅")],
            devices: [haLight, haCam, haSensor],
            environmentReadings: [EnvironmentReading(id: "ha-env", label: "客厅环境", roomName: "客厅", temperature: 24.5, humidity: 50)],
            scenes: [haScene]
        )
        initialHAHome.isInitialLoadComplete = true

        let miPlug = MiDeviceRecord(did: "mi-plug", name: "书房插座", model: "cuco.plug.v3", isOnline: true)
        let miApi = StubMiCloudAPI(
            devices: [miPlug],
            rooms: [MiRoom(id: "r-study", name: "书房", dids: ["mi-plug"], homeId: "h1", homeName: "我的家")],
            values: [MiotFixtures.key("mi-plug", 2, 1): .bool(false)]
        )

        let haStub = StubHARuntimeProvider(initialSnapshot: initialHAHome)
        let replacementHAStub = StubHARuntimeProvider(initialSnapshot: initialHAHome)
        let shutdownGate = AsyncGate()
        await haStub.setShutdownHook { await shutdownGate.enterAndWait() }

        let discoveryGate = AsyncGate()
        var createdHAProviders = 0
        let store = HomeStore(
            provider: nil,
            credentialVault: vault,
            miAccountsProviderFactory: { accounts in
                MiAccountsProvider(
                    accounts: accounts,
                    apiFactory: { _ in miApi },
                    specSource: StubSpecSource(),
                    pollInterval: .seconds(60),
                    followUpDelay: .seconds(30)
                )
            },
            haProviderFactory: { _, _ in
                createdHAProviders += 1
                return createdHAProviders == 1 ? haStub : replacementHAStub
            },
            defaults: defaults
        )
        store.haLANDiscoverer = { _ in
            await discoveryGate.enterAndWait()
            return [HADiscoveredInstance(baseURL: "http://192.168.1.99:8123", locationName: "NAS HA", version: "2026.4", uuid: "u-99")]
        }
        defer {
            _ = store.disconnectHomeAssistant()
            _ = store.logoutMiAccount()
        }

        var disabledCameraCallbacks: [Set<String>] = []
        store.onHAConnectionDisabled = { disabledCameraCallbacks.append($0) }
        var doorbellResponses: [DoorbellResponse] = []
        store.onDoorbellRing = { doorbellResponses.append($0) }

        try await awaitState {
            Set(store.devices.map(\.id)) == ["ha-light", "ha-cam", "ha-sensor", "mi-plug"]
                && store.scenes.map(\.id) == ["scene.movie"]
        }
        let dual = try #require(store.activeDualProvider)

        _ = try await store.resolveCameraStream(for: "ha-cam")
        #expect(await haStub.cameraResolveCalls.count == 1)

        store.pendingHAAddressSuggestion = HADiscoveredInstance(baseURL: "http://192.168.1.88:8123", locationName: "Other HA", version: "2026.4", uuid: "u-88")
        store.haPlaintextPrompt = .asking("http://203.0.113.5:8123")
        store.localNetworkBlocks.insert(.homeAssistant)
        store.assistantSuggestions = [
            AssistantSuggestion(id: "sug-ha", title: "开启观影模式", intents: [DeviceIntent(targetId: "scene.movie", operation: .activateScene)])
        ]

        let inFlightDiscovery = Task { await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false) }
        await discoveryGate.waitUntilEntered()

        let disableVerdict = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(disableVerdict.disposition == .requiresPauseConfirmation)
        #expect(!store.isHAConnectionEnabled && store.isDisablingHAConnection)
        #expect(disabledCameraCallbacks == [["ha-light", "ha-cam", "ha-sensor"]])
        #expect(store.scenes.isEmpty && store.visibleScenes.isEmpty)
        #expect(store.pendingHAAddressSuggestion == nil && store.haPlaintextPrompt == nil)
        #expect(!store.localNetworkBlocks.contains(.homeAssistant) && store.assistantSuggestions.isEmpty)
        #expect(!store.shouldAutoDiscoverHomeAssistantOnLAN)

        await shutdownGate.waitUntilEntered()
        let haRefreshBefore = await haStub.refreshCalls
        let historyDuringShutdown = await dual.fetchSensorHistory(deviceId: "ha-sensor", window: .last24Hours, now: Date())
        let streamDuringShutdown = try? await dual.resolveCameraStream(for: haCam, quality: .sd, channel: 0)
        #expect(historyDuringShutdown.isEmpty && streamDuringShutdown == nil)
        #expect(await haStub.refreshCalls == haRefreshBefore)
        #expect(await haStub.sensorHistoryCalls.isEmpty)

        await haStub.emit(.snapshotUpdated(initialHAHome))
        await haStub.emit(.localNetworkPermissionChanged([.homeAssistant]))
        await haStub.emit(.doorbellRang(DoorbellRing(deviceId: "ha-cam", entityId: "event.porch_bell", firedAt: "2026-04-20T12:00:00Z")))
        store.handleProviderEvent(.doorbellRang(DoorbellRing(deviceId: "ha-cam", entityId: "event.porch_bell_2", firedAt: "2026-04-20T12:00:01Z")))
        store.handleProviderEvent(.localNetworkPermissionChanged([.homeAssistant]))
        store.askHAPlaintext(Self.haURL)
        store.offerHAAddress(HADiscoveredInstance(baseURL: "http://192.168.1.77:8123", locationName: "Late HA", version: "2026.4", uuid: "u-77"))

        await discoveryGate.release()
        #expect((await inFlightDiscovery.value).isEmpty && store.discoveredHAInstances.isEmpty)

        await shutdownGate.release()
        await store.providerShutdownTask?.value
        if let teardownTask = store.capabilityTeardownTask { await teardownTask.value }
        #expect(await haStub.shutdownCalls == 1 && !store.isDisablingHAConnection)

        #expect(store.devices.map(\.id) == ["mi-plug"] && doorbellResponses.isEmpty)
        await #expect(throws: CapabilityControlBlockedError.self) {
            _ = try await store.resolveCameraStream(for: "ha-cam")
        }

        store.manualControlConfirmationHandler = { _ in true }
        let liveMiPlug = try #require(store.devices.first { $0.id == "mi-plug" })
        _ = await store.togglePrimary(liveMiPlug)?.value
        await waitUntil { await miApi.setPropsCalls.count == 1 }

        let reenabled = store.setHAConnectionEnabled(true)
        #expect(reenabled.disposition == .allowed && store.isHAConnectionEnabled)
        await store.providerShutdownTask?.value
        try await awaitState { store.devices.contains { $0.id == "ha-sensor" } }
        #expect(createdHAProviders == 2)
        try await dual.execute(.setLightPower(entityId: "light.living_spot", isOn: false))
        #expect(await replacementHAStub.executedCommands == [.setLightPower(entityId: "light.living_spot", isOn: false)])
        #expect(await haStub.executedCommands.isEmpty)
    }

    @Test("HA disable previews timers, automations, and quick actions, enforces M2/M3, and revalidates on fresh snapshot without silent overdue execution")
    func referencePreviewPauseAtomicCommitAndFreshSnapshotRevalidation() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)

        let haLight = Self.makeLight(id: "ha-light", name: "客厅主灯", roomId: "ha-living", entityId: "light.living_main")
        let haVanished = Self.makeLight(id: "ha-vanished", name: "走廊夜灯", roomId: "ha-hall", roomName: "走廊", entityId: "light.hall_night")
        let movieScene = HomeScene(id: "scene.movie", name: "观影模式", entityId: "scene.movie")
        let initialHome = Self.makeLoadedSnapshot(devices: [haLight, haVanished], scenes: [movieScene])

        final class ClockBox: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_760_000_000) }
        let clock = ClockBox()
        let haStub = StubHARuntimeProvider(initialSnapshot: initialHome)
        let store = HomeStore(provider: nil, credentialVault: vault, haProviderFactory: { _, _ in haStub }, defaults: defaults)
        defer { _ = store.disconnectHomeAssistant() }
        store.assistantNow = { clock.now }
        let timerGate = ScheduledCommandTestSupport.SleepGate()
        store.assistantSleep = { _ in await timerGate.sleep() }
        defer { store.scheduledTasks.values.forEach { $0.cancel() } }

        try await awaitState { Set(store.devices.map(\.id)) == ["ha-light", "ha-vanished"] }

        let futureDeviceTimer = Self.makeTimer(reply: "关闭客厅主灯", fireDate: clock.now.addingTimeInterval(600), targetId: "ha-light")
        let expiringSceneTimer = Self.makeTimer(reply: "开启观影模式", fireDate: clock.now.addingTimeInterval(60), targetId: "scene.movie", operation: .activateScene)
        let alreadyMissedTimer = Self.makeTimer(reply: "刚才关闭客厅主灯", fireDate: clock.now.addingTimeInterval(-30), targetId: "ha-light")
        let foreignHATimer = Self.makeTimer(reply: "关闭走廊夜灯", fireDate: clock.now.addingTimeInterval(600), targetId: "ha-vanished", scope: "mi:other-account")
        ScheduledCommand.save([futureDeviceTimer, expiringSceneTimer, alreadyMissedTimer, foreignHATimer], to: defaults)
        store.restoreScheduledCommands(now: clock.now)
        #expect(store.scheduledCommands.count == 2 && store.missedScheduledCommands.count == 1 && store.foreignScheduledCommands.count == 1)

        let deviceRule = AutomationRule(trigger: .away, action: .devices(ids: ["ha-light"], isOn: false), isEnabled: true)
        let sceneRule = AutomationRule(trigger: .back, action: .scene(sceneId: "scene.movie"), isEnabled: true)
        let vanishedRule = AutomationRule(trigger: .systemSleep, action: .devices(ids: ["ha-vanished"], isOn: false), isEnabled: true)
        let ruleStore = AutomationRuleStore(defaults: defaults)
        ruleStore.save([deviceRule, sceneRule, vanishedRule])

        let previewGen = store.capabilityGeneration
        let preview = store.previewSetHAConnectionEnabled(false)
        #expect(preview.disposition == .requiresPauseConfirmation)
        #expect(Set(preview.itemsToPause.map(\.kind)) == [.waitingTimer, .missedTimer, .foreignTimer, .automationRule, .quickAction])
        let initialKeys = Set(preview.itemsToPause.map(\.pauseKey))

        #expect(store.setHAConnectionEnabled(false, pauseConfirmed: false).disposition == .requiresPauseConfirmation)
        #expect(store.isHAConnectionEnabled && store.scheduledTasks.count == 2)
        #expect(store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: previewGen - 1).disposition == .blocked)

        let validSelectionBytes = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        defaults.set(Data("{corrupt".utf8), forKey: CapabilitySelectionStore.storageKey)
        #expect(store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration).disposition == .blocked)
        #expect(store.isHAConnectionEnabled && store.pausedScheduledCommands.isEmpty)
        defaults.set(validSelectionBytes, forKey: CapabilitySelectionStore.storageKey)

        let extraTimer = Self.makeTimer(reply: "打开客厅主灯", fireDate: clock.now.addingTimeInterval(300), targetId: "ha-light", operation: .power(true))
        store.scheduledCommands.append(extraTimer)
        ScheduledCommand.save(store.scheduledCommands + store.missedScheduledCommands + store.foreignScheduledCommands, to: defaults)
        let m3Verdict = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration, expectedPauseItemKeys: initialKeys)
        #expect(m3Verdict.disposition == .requiresPauseConfirmation && store.isHAConnectionEnabled)
        _ = store.cancelScheduledCommands(id: extraTimer.id)

        let freshPreview = store.previewSetHAConnectionEnabled(false)
        let confirmed = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration,
            expectedPauseItemKeys: Set(freshPreview.itemsToPause.map(\.pauseKey))
        )
        #expect(confirmed.disposition == .requiresPauseConfirmation && !store.isHAConnectionEnabled)
        #expect(store.scheduledCommands.isEmpty && store.missedScheduledCommands.isEmpty && store.foreignScheduledCommands.isEmpty)
        #expect(store.pausedScheduledCommands.count == 4 && ruleStore.load().allSatisfy { !$0.isEnabled })
        await store.providerShutdownTask?.value

        clock.now = clock.now.addingTimeInterval(120)
        let reconnectedHome = Self.makeLoadedSnapshot(devices: [haLight], scenes: [movieScene])
        await haStub.setInitialSnapshot(nil)

        #expect(store.setHAConnectionEnabled(true).disposition == .allowed)
        #expect(store.isHAConnectionEnabled && store.pendingRevalidationScopes.contains(Self.haScope))

        store.handleProviderEvent(.statusChanged(.disconnected("Reconnecting")))
        store.reconcileReenabledScopesAfterSnapshot(Self.makeLoadedSnapshot())
        #expect(store.pendingRevalidationScopes.contains(Self.haScope) && store.pausedScheduledCommands.count == 4)

        store.handleProviderEvent(.statusChanged(.connected))
        store.handleProviderEvent(.snapshotUpdated(reconnectedHome))

        #expect(store.pendingRevalidationScopes.isEmpty && store.pausedScheduledCommands.isEmpty)
        #expect(store.scheduledCommands.map(\.id) == [futureDeviceTimer.id])
        #expect(Set(store.missedScheduledCommands.map(\.id)) == Set([expiringSceneTimer.id, alreadyMissedTimer.id]))
        #expect(await haStub.executedCommands.isEmpty)

        let rulesAfter = Dictionary(uniqueKeysWithValues: ruleStore.load().map { ($0.id, $0) })
        #expect(rulesAfter[deviceRule.id]?.isEnabled == true && rulesAfter[sceneRule.id]?.isEnabled == true)
        #expect(rulesAfter[vanishedRule.id]?.isEnabled == false && rulesAfter[vanishedRule.id]?.pausedCapabilities.isEmpty == true)
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_760_000_000)

        var now: Date { lock.withLock { date } }
        func advance(by seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    @Test("Only a fresh snapshot from the original HA URL restores its paused references")
    func pausedHAReferencesStayBoundAcrossAddressChangesAndRestart() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        let otherURL = "http://192.168.1.51:8123"
        let otherScope = ConnectionRemovalStore.haScope(serverURL: otherURL)
        let light = Self.makeLight(id: "ha-light", name: "Hall", entityId: "light.hall")
        let scene = HomeScene(id: "scene.movie", name: "Movie", entityId: "scene.movie")
        var snapshot = Self.makeLoadedSnapshot(devices: [light], scenes: [scene])
        snapshot.homeAssistantScope = Self.haScope
        var otherSnapshot = Self.makeLoadedSnapshot(devices: [light], scenes: [scene])
        otherSnapshot.homeAssistantScope = otherScope
        let stub = StubHARuntimeProvider()
        var store = HomeStore(provider: nil, credentialVault: vault, haProviderFactory: { _, _ in stub }, defaults: defaults)
        let clock = TestClock()
        let timerGate = ScheduledCommandTestSupport.SleepGate()
        store.assistantNow = { clock.now }
        store.assistantSleep = { _ in await timerGate.sleep() }
        defer { store.scheduledTasks.values.forEach { $0.cancel() } }
        store.handleProviderEvent(.statusChanged(.connected))
        store.handleProviderEvent(.snapshotUpdated(snapshot))

        let timer = Self.makeTimer(reply: "Turn off hall light", fireDate: clock.now.addingTimeInterval(60), targetId: light.id)
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands(now: clock.now)
        let deviceRule = AutomationRule(trigger: .away, action: .devices(ids: [light.id], isOn: false), isEnabled: true)
        let sceneRule = AutomationRule(trigger: .back, action: .scene(sceneId: scene.id), isEnabled: true)
        let quickRule = AutomationRule(trigger: .away, action: .quickAction(.lightsOff), isEnabled: true)
        let rules = store.automationRuleStore
        rules.save([deviceRule, sceneRule, quickRule])
        disableHAAndPauseReferences(in: store)
        #expect(rules.load().allSatisfy { !$0.isEnabled && $0.pausedScopes == [Self.haScope] })
        #expect(store.pausedQuickActionIDs.contains(QuickAction.lightsOff.rawValue))
        #expect(store.pausedScheduledCommands.map(\.command.id) == [timer.id])
        seedPausedHAGroup(in: store, defaults: defaults, memberID: light.id)
        await store.providerShutdownTask?.value

        #expect(store.updateConnection(serverURL: otherURL, token: Self.haToken))
        #expect(!store.isHAConnectionEnabled)
        clock.advance(by: 120)
        #expect(store.setHAConnectionEnabled(true).disposition == .allowed)
        store.handleProviderEvent(.statusChanged(.connected))
        store.handleProviderEvent(.snapshotUpdated(otherSnapshot))
        #expect(AutomationMatcher.rules(for: .away, in: rules.load()).isEmpty)
        #expect(!store.pausedQuickActionIDs.contains(QuickAction.lightsOff.rawValue))
        #expect(store.pausedQuickActionIDs.contains("group:hall"))
        #expect(store.foreignScheduledCommands.map(\.id) == [timer.id])
        #expect(store.missedScheduledCommands.isEmpty && store.scheduledCommands.isEmpty)
        #expect(store.scheduledTasks[timer.id] == nil)

        // Disabling HA again while pointed at another server must keep the original HA scope intact.
        disableHAAndPauseReferences(in: store)
        #expect(rules.load().allSatisfy { !$0.isEnabled && $0.pausedScopes == [Self.haScope] })
        #expect(store.pausedQuickActionScopes["group:hall"] == [Self.haScope])
        #expect(store.setHAConnectionEnabled(true).disposition == .allowed)
        store.handleProviderEvent(.statusChanged(.connected))
        store.handleProviderEvent(.snapshotUpdated(otherSnapshot))
        #expect(rules.load().allSatisfy { !$0.isEnabled && $0.pausedScopes == [Self.haScope] })
        #expect(store.pausedQuickActionIDs.contains("group:hall"))

        store.eventTask?.cancel()
        store = HomeStore(provider: nil, credentialVault: vault, haProviderFactory: { _, _ in stub }, defaults: defaults)
        store.assistantNow = { clock.now }
        store.assistantSleep = { _ in await timerGate.sleep() }
        store.handleProviderEvent(.statusChanged(.connected))
        store.handleProviderEvent(.snapshotUpdated(Self.makeLoadedSnapshot()))
        #expect(rules.load().allSatisfy { !$0.isEnabled && $0.pausedScopes == [Self.haScope] })
        #expect(store.pausedQuickActionIDs.contains("group:hall"))

        #expect(store.updateConnection(serverURL: Self.haURL, token: Self.haToken))
        store.handleProviderEvent(.statusChanged(.connected))
        var partial = Self.makeLoadedSnapshot()
        partial.sourceStatuses = [.homeAssistant: .connected]
        partial.activeBackends = [.xiaomiCloud]
        store.handleProviderEvent(.snapshotUpdated(partial))
        #expect(rules.load().allSatisfy { !$0.isEnabled && $0.pausedScopes == [Self.haScope] })
        #expect(store.pausedQuickActionIDs.contains("group:hall"))

        // A stale dual-source snapshot from the prior HA address must not unlock references for the new URL.
        var staleDual = otherSnapshot
        staleDual.sourceStatuses = [.homeAssistant: .connected, .xiaomiCloud: .connected]
        staleDual.activeBackends = [.homeAssistant, .xiaomiCloud]
        store.handleProviderEvent(.snapshotUpdated(staleDual))
        #expect(rules.load().allSatisfy { !$0.isEnabled && $0.pausedScopes == [Self.haScope] })
        #expect(store.pausedQuickActionIDs.contains("group:hall"))

        store.handleProviderEvent(.snapshotUpdated(snapshot))
        #expect(rules.load().allSatisfy { $0.isEnabled && $0.pausedScopes.isEmpty })
        #expect(!store.pausedQuickActionIDs.contains("group:hall"))
        #expect(store.missedScheduledCommands.map(\.id) == [timer.id])
        #expect(store.scheduledTasks[timer.id] == nil)
        #expect(await stub.executedCommands.isEmpty)
    }

    enum CredentialRemoval: CaseIterable { case delete, disconnect, clearToken }

    @Test("Removing HA credentials makes previously paused HA rules manual across subsequent connections", arguments: CredentialRemoval.allCases)
    func removingHAWhileAtAnotherAddressRequiresManualResume(_ removal: CredentialRemoval) async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        let otherURL = "http://192.168.1.51:8123"
        let thirdURL = "http://192.168.1.52:8123"
        let light = Self.makeLight(id: "ha-light", name: "Hall", entityId: "light.hall")
        let snapshot = Self.makeLoadedSnapshot(devices: [light])
        let stub = StubHARuntimeProvider()
        var store = HomeStore(provider: nil, credentialVault: vault, haProviderFactory: { _, _ in stub }, defaults: defaults)
        store.handleProviderEvent(.statusChanged(.connected))
        store.handleProviderEvent(.snapshotUpdated(snapshot))
        let rule = AutomationRule(trigger: .away, action: .devices(ids: [light.id], isOn: false), isEnabled: true)
        let rules = store.automationRuleStore
        rules.save([rule])
        disableHAAndPauseReferences(in: store)
        seedPausedHAGroup(in: store, defaults: defaults, memberID: light.id)
        await store.providerShutdownTask?.value
        #expect(store.updateConnection(serverURL: otherURL, token: Self.haToken))
        #expect(rules.load().first?.pausedScopes == [Self.haScope])

        switch removal {
        case .delete:
            #expect(await store.removeHomeAssistantConnection() == .completed)
        case .disconnect:
            #expect(store.disconnectHomeAssistant())
        case .clearToken:
            #expect(store.updateConnection(serverURL: thirdURL, token: ""))
        }
        #expect(store.loadHAToken().isEmpty)
        let disabled = try #require(rules.load().first)
        #expect(disabled.id == rule.id && disabled.action == rule.action && !disabled.isEnabled)
        #expect(disabled.pausedScopes.isEmpty && disabled.pausedCapabilities.isEmpty)
        store.eventTask?.cancel()
        store = HomeStore(provider: nil, credentialVault: vault, haProviderFactory: { _, _ in stub }, defaults: defaults)

        // Both a different server and a later use of the old URL require manual enablement.
        for url in [thirdURL, Self.haURL] {
            #expect(store.updateConnection(serverURL: url, token: Self.haToken))
            store.handleProviderEvent(.statusChanged(.connected))
            store.handleProviderEvent(.snapshotUpdated(snapshot))
            #expect(rules.load() == [disabled])
            #expect(store.pausedQuickActionIDs.contains("group:hall"))
        }
        #expect(await stub.executedCommands.isEmpty)
    }

    private func disableHAAndPauseReferences(in store: HomeStore) {
        let preview = store.previewSetHAConnectionEnabled(false)
        #expect(preview.disposition == .requiresPauseConfirmation)
        _ = store.setHAConnectionEnabled(
            false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration,
            expectedPauseItemKeys: Set(preview.itemsToPause.map(\.pauseKey))
        )
        #expect(!store.isHAConnectionEnabled)
    }

    private func seedPausedHAGroup(in store: HomeStore, defaults: UserDefaults, memberID: String) {
        defaults.set(#"[{"id":"hall","name":"Hall"}]"#, forKey: "device_groups")
        defaults.set("{\"\(memberID)\":\"hall\"}", forKey: ViewPreferenceKeys.groupMap)
        store.pauseAffectedReferences([AffectedReferenceItem(
            kind: .quickAction, id: "group:hall", name: "Hall", connectionScopes: [Self.haScope],
            affectedTargetIds: [memberID], affectedCapabilities: [.connection(.homeAssistant)]
        )])
    }

    @Test("Dual-source unpinned paired card fails over to Xiaomi Cloud without pausing references and strips HA facets, while HA-pinned card blocks writes")
    func dualSourceFailoverAndPinnedSourceSemantics() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let unpinnedDid = "10001"
        let pinnedDid = "10002"
        let haUnpinnedID = "ha-unpinned-light"
        let haPinnedID = "ha-pinned-light"

        let haUnpinned = Self.makeLight(id: haUnpinnedID, name: "客厅吸顶灯", model: "yeelink.light.ceiling22", entityId: "light.living_ceiling", brightness: 80)
        let haPinned = Self.makeLight(id: haPinnedID, name: "主卧吊灯", roomId: "ha-bed", roomName: "主卧", model: "yeelink.light.ceiling22", entityId: "light.master_chandelier", brightness: 60)
        let miUnpinned = Self.makeLight(id: unpinnedDid, name: "客厅吸顶灯", roomId: "\(Self.miAccount.id)/living", model: "yeelink.light.ceiling22", entityId: "miot:\(unpinnedDid):2", brightness: 80, accountId: Self.miAccount.id)
        let miPinned = Self.makeLight(id: pinnedDid, name: "主卧吊灯", roomId: "\(Self.miAccount.id)/bed", roomName: "主卧", model: "yeelink.light.ceiling22", entityId: "miot:\(pinnedDid):2", brightness: 60, accountId: Self.miAccount.id)

        let haFacet = FacetControl(id: "ha.night_mode", kind: .toggle, name: "night_mode", title: "HA 夜灯开关", serviceName: "light", value: .bool(false), isWritable: true, writesByDefault: true, isHighValue: false, target: .haProperty(entityId: "switch.living_night_mode"))
        let miFacet = FacetControl(id: "2.7", kind: .toggle, name: "flex-switch", title: "凌动开关", serviceName: "light", value: .bool(true), isWritable: true, writesByDefault: true, isHighValue: false, target: .property(entityId: "miot:\(unpinnedDid):2", piid: 7))

        var haHome = Self.makeLoadedSnapshot(devices: [haUnpinned, haPinned])
        haHome.deviceIdentities = [
            haUnpinnedID: DeviceSourceIdentity(dids: [unpinnedDid], model: "yeelink.light.ceiling22", name: "客厅吸顶灯", roomName: "客厅", kindTag: .light),
            haPinnedID: DeviceSourceIdentity(dids: [pinnedDid], model: "yeelink.light.ceiling22", name: "主卧吊灯", roomName: "主卧", kindTag: .light),
        ]
        haHome.deviceFacets = [haUnpinnedID: [haFacet]]

        var miHome = Self.makeLoadedSnapshot(devices: [miUnpinned, miPinned])
        miHome.deviceIdentities = [
            unpinnedDid: DeviceSourceIdentity(dids: [unpinnedDid], model: "yeelink.light.ceiling22", name: "客厅吸顶灯", roomName: "客厅", kindTag: .light),
            pinnedDid: DeviceSourceIdentity(dids: [pinnedDid], model: "yeelink.light.ceiling22", name: "主卧吊灯", roomName: "主卧", kindTag: .light),
        ]
        miHome.deviceFacets = [unpinnedDid: [miFacet]]
        miHome.freshAccountIds = [Self.miAccount.id]
        miHome.accountStatuses = [Self.miAccount.id: .connected]

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(dualSource: (homeAssistant: haMock, xiaomiCloud: miMock), credentialVault: vault, defaults: defaults)
        store.hasHASource = true
        store.serverURLString = Self.haURL
        store.miAccounts = [Self.miAccount]
        store.syncInMemoryConfiguredCapabilities()

        try await awaitState {
            Set(store.devices.map(\.id)) == [haUnpinnedID, haPinnedID]
                && store.pairedDeviceIDs == [haUnpinnedID, haPinnedID]
                && store.deviceBackend(for: haUnpinnedID) == .homeAssistant
                && store.deviceBackend(for: haPinnedID) == .homeAssistant
        }

        store.pinDeviceSource(haPinnedID, to: .homeAssistant)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let timerGate = ScheduledCommandTestSupport.SleepGate()
        store.assistantNow = { now }
        store.assistantSleep = { _ in await timerGate.sleep() }
        defer { store.scheduledTasks.values.forEach { $0.cancel() } }

        let unpinnedTimer = Self.makeTimer(reply: "关闭客厅吸顶灯", fireDate: now.addingTimeInterval(600), targetId: haUnpinnedID, scopes: [Self.haScope, Self.miAccount.id])
        let pinnedTimer = Self.makeTimer(reply: "关闭主卧吊灯", fireDate: now.addingTimeInterval(600), targetId: haPinnedID, scopes: [Self.haScope, Self.miAccount.id])
        ScheduledCommand.save([unpinnedTimer, pinnedTimer], to: defaults)
        store.restoreScheduledCommands()
        let ruleStore = AutomationRuleStore(defaults: defaults)
        let unpinnedRule = AutomationRule(trigger: .away, action: .devices(ids: [haUnpinnedID], isOn: false), isEnabled: true)
        let pinnedRule = AutomationRule(trigger: .back, action: .devices(ids: [haPinnedID], isOn: false), isEnabled: true)
        ruleStore.save([unpinnedRule, pinnedRule])

        let preview = store.previewSetHAConnectionEnabled(false)
        let pausedIDs = Set(preview.itemsToPause.map(\.id))
        #expect(pausedIDs.contains(pinnedTimer.id.uuidString) && pausedIDs.contains(pinnedRule.id.uuidString))
        #expect(!pausedIDs.contains(unpinnedTimer.id.uuidString) && !pausedIDs.contains(unpinnedRule.id.uuidString))
        #expect(!preview.itemsToPause.contains { $0.kind == .quickAction })

        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(store.scheduledCommands.map(\.id) == [unpinnedTimer.id])
        #expect(store.pausedScheduledCommands.map(\.command.id) == [pinnedTimer.id])
        #expect(store.deviceFacets[haUnpinnedID] == nil)

        await store.providerShutdownTask?.value
        try await awaitState {
            store.deviceBackend(for: haUnpinnedID) == .xiaomiCloud
                && store.deviceFacets[haUnpinnedID]?.map(\.id) == ["2.7"]
        }

        let haCommandsBefore = await haMock.executedCommands.count
        let miCommandsBefore = await miMock.executedCommands.count
        let pinnedRaycast = await store.executeRaycastPower(deviceId: haPinnedID, isOn: false)
        #expect(pinnedRaycast.isError && pinnedRaycast.message == "Home Assistant 已停用")
        #expect(await haMock.executedCommands.count == haCommandsBefore)
        #expect(await miMock.executedCommands.count == miCommandsBefore)

        let liveUnpinned = try #require(store.devices.first { $0.id == haUnpinnedID })
        _ = await store.togglePrimary(liveUnpinned)?.value
        #expect(await haMock.executedCommands.count == haCommandsBefore)
        #expect((await miMock.executedCommands).contains { $0.targetEntityId == "miot:\(unpinnedDid):2" })
    }

    @Test("Host write gate blocks all HA control entry points, mixed plans, partial undo, mid-modal races, and 200-device allOffTargets")
    func comprehensiveHostWriteGateAndAtomicPlanRejection() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let haLock = SmartDevice(
            id: "ha-lock",
            name: "庭院门锁",
            roomId: "ha-yard",
            roomName: "庭院",
            model: "ha.lock",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.yard_lock", isOn: true))
        )
        let haPinnedLight = Self.makeLight(id: "ha-pinned-lamp", name: "落地灯", entityId: "light.floor_lamp", brightness: 75)
        let miLight = Self.makeLight(id: "mi-desk-lamp", name: "书桌台灯", roomId: "\(Self.miAccount.id)/study", roomName: "书房", model: "yeelink.light.lamp4", entityId: "miot:mi-desk-lamp:2", brightness: 90, accountId: Self.miAccount.id)
        let haFacet = FacetControl(id: "ha.child_lock", kind: .toggle, name: "child_lock", title: "童锁", serviceName: "lock", value: .bool(true), isWritable: true, writesByDefault: true, isHighValue: false, target: .haProperty(entityId: "switch.yard_child_lock"))
        let haActionFacet = FacetControl(id: "ha.calibrate", kind: .button, name: "calibrate", title: "校准", serviceName: "lock", isWritable: true, writesByDefault: true, isHighValue: false, target: .haAction(entityId: "button.yard_calibrate"))
        let haScene = HomeScene(id: "scene.sleep", name: "睡眠模式", entityId: "scene.sleep")

        var snapshot = Self.makeLoadedSnapshot(devices: [haLock, haPinnedLight, miLight], scenes: [haScene])
        snapshot.deviceBackends = ["ha-lock": .homeAssistant, "ha-pinned-lamp": .homeAssistant, "mi-desk-lamp": .xiaomiCloud]
        snapshot.pairedDeviceIDs = ["ha-pinned-lamp"]
        snapshot.deviceFacets = ["ha-lock": [haFacet, haActionFacet]]

        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        store.hasHASource = true
        store.serverURLString = Self.haURL
        store.syncInMemoryConfiguredCapabilities()
        try await awaitState { store.hasReceivedInitialSnapshot }
        store.pinDeviceSource("ha-pinned-lamp", to: .homeAssistant)

        var confirmationPrompts = 0
        store.manualControlConfirmationHandler = { _ in
            confirmationPrompts += 1
            return true
        }

        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        var pausedPinnedLamp = haPinnedLight
        pausedPinnedLamp.isOnline = false
        store.devices = [pausedPinnedLamp, miLight]
        store.deviceFacets["ha-lock"] = [haFacet, haActionFacet]

        let commandsBefore = await mock.executedCommands.count

        #expect(store.evaluateDeviceControlGate(deviceId: "ha-lock").rejectionReason?.userMessage == "Home Assistant 已停用")
        #expect(store.evaluateDeviceControlGate(deviceId: "non-existent-id").rejectionReason?.userMessage == "设备不存在")
        #expect(store.evaluateSceneControlGate(sceneId: "scene.sleep").rejectionReason?.userMessage == "Home Assistant 已停用")
        #expect(store.evaluateSceneControlGate(sceneId: "scene.never_existed").rejectionReason?.userMessage == "场景不存在")

        _ = store.togglePrimary(haLock)
        #expect(confirmationPrompts == 0 && store.toastNotice?.message == "Home Assistant 已停用")
        store.setLightBrightness("ha-pinned-lamp", percent: 50)
        store.setFacetValue("ha-lock", controlId: "ha.child_lock", value: .bool(false))
        store.runFacetAction("ha-lock", controlId: "ha.calibrate")
        store.pressDeviceButton("button.yard_calibrate", label: "校准")
        await #expect(throws: CapabilityControlBlockedError(reason: .connectionDisabled(.homeAssistant, scope: Self.haScope))) {
            try await store.executeDeviceCommand(.setSwitch(entityId: "switch.unindexed_entity", isOn: true))
        }
        #expect(!(await store.triggerScene(haScene).value))

        let mixedDevicePlan = IntentPlan(
            intents: [DeviceIntent(targetId: "mi-desk-lamp", operation: .power(false)), DeviceIntent(targetId: "ha-lock", operation: .power(false))],
            reply: "关闭台灯和门锁",
            source: .model
        )
        let mixedResult = await store.executeIntentPlan(mixedDevicePlan, recordedUtterance: "关闭台灯和门锁", origin: .userInitiated)
        #expect(mixedResult.intents.isEmpty && mixedResult.reply == "Home Assistant 已停用")
        #expect(await mock.executedCommands.count == commandsBefore)

        let mixedRestoreMi = DeviceCommand.setLightPower(entityId: "miot:mi-desk-lamp:2", isOn: true)
        let mixedRestoreHA = DeviceCommand.setSwitch(entityId: "switch.yard_lock", isOn: true)
        store.undoBanner = UndoBanner(
            title: "已关闭 2 个设备",
            restoreCommands: [mixedRestoreMi, mixedRestoreHA],
            previousDevices: [miLight, haLock],
            deviceCount: 2,
            habitReceipt: nil,
            isAllOff: true
        )
        if let undoTask = store.undoTurnAllOff() { await undoTask.value }
        #expect(await mock.executedCommands.count == commandsBefore + 1)
        #expect(store.undoBanner?.restoreCommands == [mixedRestoreHA])
        #expect(store.toastNotice?.message.contains("部分设备未撤销") == true)

        let autoOutcome = await store.runAutomation(intents: [DeviceIntent(targetId: "scene.sleep", operation: .activateScene)], title: "睡眠自动化")
        #expect(autoOutcome.succeededCount == 0 && autoOutcome.errorMessage == "Home Assistant 已停用")

        var bulkDevices: [SmartDevice] = []
        for idx in 0..<100 {
            bulkDevices.append(Self.makeLight(id: "ha-light-\(idx)", name: "HA 灯 \(idx)", entityId: "light.ha_\(idx)"))
            bulkDevices.append(Self.makeLight(id: "mi-light-\(idx)", name: "米家灯 \(idx)", roomId: "\(Self.miAccount.id)/r", entityId: "miot:mi-light-\(idx):2", accountId: Self.miAccount.id))
        }
        store.devices = bulkDevices
        store.pinDeviceSource("mi-light-0", to: .homeAssistant)
        store.pinDeviceSource("mi-light-1", to: .xiaomiCloud)
        for device in bulkDevices {
            #expect(store.capabilityWriteRejection(for: device) == store.capabilityWriteRejection(forDeviceId: device.id))
        }
        let targets = Set(store.allOffTargets.map(\.id))
        #expect(!targets.contains("ha-light-0") && !targets.contains("mi-light-0") && targets.contains("mi-light-1") && targets.count == 99)

        _ = store.setHAConnectionEnabled(true)
        var offLock = haLock
        offLock.kind = .plug(PlugSpec(switchEntityId: "switch.yard_lock", isOn: false))
        store.devices = [offLock, miLight]
        let commandsBeforeModalRace = await mock.executedCommands.count
        var modalEntered = false
        store.manualControlConfirmationHandler = { _ in
            modalEntered = true
            _ = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
            return true
        }
        #expect(store.togglePrimary(offLock) == nil && modalEntered)
        #expect(await mock.executedCommands.count == commandsBeforeModalRace)
    }

    @Test("Disabling HA retains credentials, consent, preferences, and history, while Disconnect wipes token and tears down active HA cameras")
    func disableRetainsCredentialsAndHistoryWhileDisconnectWipesToken() throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let publicHTTPURL = "http://203.0.113.42:8123"
        let publicScope = "ha:http://203.0.113.42:8123"
        Self.seedHAConfig(defaults, vault, url: publicHTTPURL)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)
        HAPlaintextConsent.approve(publicHTTPURL, defaults: defaults)

        var createdURLs: [String] = []
        let store = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        store.haProviderFactory = { url, _ in
            createdURLs.append(url)
            return MockHomeProvider()
        }
        let haSensor = SmartDevice(id: "ha-sensor-1", name: "书房温湿度计", roomId: "ha-study", roomName: "书房", model: "ha.sensor", isOnline: true, kind: .sensor(SensorSpec(temperature: 23.4, humidity: 48)))
        let haPlug = SmartDevice(id: "ha-plug-1", name: "桌面排插", roomId: "ha-study", roomName: "书房", model: "ha.plug", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.desk_strip", isOn: true, powerWatts: 45, energyKwh: 12.5)))
        let haCam = SmartDevice(id: "ha-cam-1", name: "HA 摄像头", roomId: "porch", roomName: "玄关", model: "ha.camera", isOnline: true, kind: .camera(CameraSpec(entityId: "camera.porch", isOn: true)))
        let miCam = SmartDevice(id: "mi-cam-1", name: "米家摄像头", roomId: "\(Self.miAccount.id)/living", roomName: "客厅", model: "chuangmi.camera.055a02", isOnline: true, kind: .camera(CameraSpec(entityId: "miot:mi-cam-1:2", isOn: true)), accountId: Self.miAccount.id)

        store.devices = [haSensor, haPlug, haCam, miCam]
        store.toggleFavorite("ha-plug-1")
        store.applyDeviceAliases(["ha-plug-1": "主显示器排插"])
        store.pinDeviceSource("ha-plug-1", to: .homeAssistant)

        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        SensorHistory(defaults: defaults, connectionScope: publicScope).record(devices: [haSensor], now: t0)
        EnergyHistory(defaults: defaults, connectionScope: publicScope).record(devices: [haPlug], now: t0)

        let plugTimer = Self.makeTimer(reply: "关闭桌面排插", fireDate: Date().addingTimeInterval(600), targetId: "ha-plug-1", scope: publicScope)
        ScheduledCommand.save([plugTimer], to: defaults)
        store.restoreScheduledCommands()

        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(!store.isHAConnectionEnabled && store.loadHAToken() == Self.haToken && store.serverURLString == publicHTTPURL)
        #expect(HAPlaintextConsent.allowsToken(to: publicHTTPURL, defaults: defaults))
        #expect(store.favoriteDeviceIds.contains("ha-plug-1") && store.devicesWithAliases([haPlug]).first?.name == "主显示器排插")
        #expect(store.pinnedSource(for: "ha-plug-1") == .homeAssistant)
        #expect(defaults.data(forKey: SensorHistory.storageKey) != nil)
        #expect(EnergyHistory(defaults: defaults, connectionScope: publicScope).recordingStartedAt != nil)
        #expect(store.pausedScheduledCommands.count == 1)

        store.updateConnection(serverURL: publicHTTPURL, token: Self.haToken)
        #expect(!store.isHAConnectionEnabled && createdURLs.isEmpty)

        #expect(store.setHAConnectionEnabled(true).disposition == .allowed)
        #expect(store.isHAConnectionEnabled && store.pendingRevalidationScopes.contains(publicScope))

        store.devices = [haPlug]
        store.pendingRevalidationScopes.removeAll()
        store.revalidatePausedItems()
        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(store.disconnectHomeAssistant())
        #expect(!store.hasHASource && store.loadHAToken().isEmpty && store.pausedScheduledCommands.isEmpty)

        Self.seedHAConfig(defaults, vault)
        let camStore = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        camStore.devices = [haCam, miCam]
        camStore.activeLiveCameraDeviceId = haCam.id
        var tornDownSets: [Set<String>] = []
        camStore.onHAConnectionDisabled = { tornDownSets.append($0) }
        #expect(camStore.disconnectHomeAssistant())
        #expect(tornDownSets == [Set([haCam.id])] && camStore.activeLiveCameraDeviceId == nil)
    }
}
