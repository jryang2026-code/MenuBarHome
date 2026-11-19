import Foundation
import KeychainTestSupport
import Observation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

/// P2b-M: Home Assistant connection disablement and host write gate on macOS.
///
/// Covers persisted selection & migration safety, effective backend/scope/panelHealth derivation,
/// HA runtime teardown & generation isolation (zero post-disable WS/LAN/camera/doorbell/write
/// activity including in-flight and late events), P1b reference verdicts (preview, pause
/// confirmation, atomic commit, M3 re-preview, fresh-snapshot revalidation), dual-source failover
/// & pinned-source semantics, host write gate across every entry point (including multi-target
/// atomic assistant rejection & post-modal generation races), and disable vs disconnect retention.
///
/// Each test owns one `InMemoryUserDefaults` and hands the same instance to the store, the rule
/// store, `ScheduledCommand` and the history stores. A second `UserDefaults(suiteName:)` instance
/// for the same suite reads through `cfprefsd` and can answer an emptied cache under CI load, which
/// is how these assertions once read rules back as `[]` on an otherwise green run.
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

    // MARK: - 1. Persistence, Legacy Migration, Unknown JSON Preservation & Uncertain Fallback

    @Test("Legacy upgrade keeps configured Home Assistant enabled, preserves unknown JSON fields, and survives relaunch")
    func legacyUpgradeKeepsHAEnabledAndPreservesUnknownFields() throws {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedHAConfig(defaults, vault)

        let first = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        #expect(first.hasHASource)
        #expect(first.isHAConnectionEnabled)
        #expect(first.hasEnabledHASource)
        #expect(first.activeBackends == [.homeAssistant])
        #expect(first.activeConnectionScopes == [Self.haScope])
        #expect(CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))

        // Inject unknown future keys & features to prove read-merge-write preserves them.
        let rawData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        var json = try #require(try JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        json["futureTopLevelFlag"] = "keep-ha-future"
        var enabledFeatures = (json["enabledFeatures"] as? [String]) ?? []
        enabledFeatures.append("future.ha.feature")
        json["enabledFeatures"] = enabledFeatures
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: CapabilitySelectionStore.storageKey)

        let verdict = first.setHAConnectionEnabled(false)
        #expect(verdict.disposition == .allowed)
        #expect(!first.isHAConnectionEnabled)
        #expect(!first.hasEnabledHASource)
        #expect(first.hasHASource)
        #expect(first.activeBackends.isEmpty)
        #expect(first.activeConnectionScopes.isEmpty)

        let updatedData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let updatedJSON = try #require(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        #expect(updatedJSON["futureTopLevelFlag"] as? String == "keep-ha-future")
        #expect((updatedJSON["enabledFeatures"] as? [String])?.contains("future.ha.feature") == true)
        #expect((updatedJSON["disabledConnections"] as? [String])?.contains("home-assistant") == true)

        // Relaunch preserves explicit HA disablement idempotently.
        let second = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        #expect(second.hasHASource)
        #expect(!second.isHAConnectionEnabled)
        #expect(second.activeBackends.isEmpty)
        #expect(second.activeConnectionScopes.isEmpty)
    }

    @Test("Vault or selection read failure falls back safely while keeping explicit HA disablement once readable")
    func vaultAndSelectionFallbackBehavior() throws {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedHAConfig(defaults, vault)

        // 1. Keychain temporarily unavailable before migration ever ran -> uncertainFallback, no migration sealed.
        mem.readResult = .unavailable
        let fallbackBeforeMigration = HomeStore(
            provider: MockHomeProvider(),
            credentialVault: CredentialVault(storage: mem.storage),
            defaults: defaults
        )
        #expect(!CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))
        #expect(fallbackBeforeMigration.capabilityResolutionMode == .uncertainFallback)

        // 2. Recover Keychain, migrate, and explicitly disable HA.
        mem.readResult = nil
        let recovered = HomeStore(
            provider: MockHomeProvider(),
            credentialVault: CredentialVault(storage: mem.storage),
            defaults: defaults
        )
        #expect(CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))
        #expect(recovered.isHAConnectionEnabled)
        #expect(recovered.setHAConnectionEnabled(false).disposition == .allowed)
        #expect(!recovered.isHAConnectionEnabled)

        // 3. Keychain temporarily unavailable AFTER explicit HA disable -> still honors explicit HA disable!
        mem.readResult = .unavailable
        let fallbackAfterDisable = HomeStore(
            provider: MockHomeProvider(),
            credentialVault: CredentialVault(storage: mem.storage),
            defaults: defaults
        )
        #expect(fallbackAfterDisable.capabilityResolutionMode == .uncertainFallback)
        fallbackAfterDisable.hasHASource = true
        #expect(!fallbackAfterDisable.isHAConnectionEnabled)
    }

    // MARK: - 2. Effective Backends, Panel Health & Connection Summaries

    @Test("Panel health and connection summaries distinguish disabled HA from unconfigured and keep dual-source Mi healthy")
    func panelHealthAndSummariesReflectHADisabledState() throws {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedHAConfig(defaults, vault)

        // Single-HA: turning off HA reports turned-off connection (blocked), NOT unconfigured, and suppresses plaintext-declined warning.
        let singleHA = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        singleHA.haPlaintextPrompt = .declined("http://203.0.113.9:8123")
        #expect(singleHA.setHAConnectionEnabled(false).disposition == .allowed)
        #expect(singleHA.allConfiguredSourcesTurnedOff)
        #expect(singleHA.haPlaintextPrompt == nil)

        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(singleHA.panelHealth == .blocked(
                reason: "连接已停用 · 点此重新启用",
                action: .openConnectionSettings
            ))
            #expect(singleHA.serverHostSummary.contains("已停用"))
        }

        // Dual-source: turning off HA while Xiaomi Cloud is connected keeps panelHealth == .ok!
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
        #expect(dualStore.activeBackends == [.xiaomiCloud])
        #expect(dualStore.activeConnectionScopes == [Self.miAccount.id])
        #expect(!dualStore.allConfiguredSourcesTurnedOff)
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(dualStore.panelHealth == .ok)
            #expect(dualStore.dualSourceStatusSummary == "米家云已连接（HA 已停用）")
        }
    }

    // MARK: - 3. Runtime Teardown, Generation Isolation & Zero Post-Disable Activity

    @Test("Disabling Home Assistant awaits shutdown, clears HA runtime state, and drops late WS, LAN, doorbell, plaintext, and camera activity")
    func disablingHAProducesZeroPostDisableActivityAndDropsLateEvents() async throws {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let haLight = SmartDevice(
            id: "ha-light",
            name: "客厅射灯",
            roomId: "ha-living",
            roomName: "客厅",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living_spot", isOn: true))
        )
        let haCam = SmartDevice(
            id: "ha-cam",
            name: "门廊摄像头",
            roomId: "ha-porch",
            roomName: "玄关",
            model: "ha.camera",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.porch", isOn: true))
        )
        let haScene = HomeScene(id: "scene.movie", name: "观影模式", entityId: "scene.movie")
        var initialHAHome = SynthesizedHome(
            rooms: [RoomArea(id: "ha-living", name: "客厅")],
            devices: [haLight, haCam],
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
        let shutdownGate = AsyncGate()
        await haStub.setShutdownHook {
            await shutdownGate.enterAndWait()
        }

        let discoveryGate = AsyncGate()
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
            haProviderFactory: { _, _ in haStub },
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
        store.onHAConnectionDisabled = { ids in
            disabledCameraCallbacks.append(ids)
        }
        var doorbellResponses: [DoorbellResponse] = []
        store.onDoorbellRing = { response in
            doorbellResponses.append(response)
        }

        try await awaitSnapshotState {
            Set(store.devices.map(\.id)) == ["ha-light", "ha-cam", "mi-plug"]
                && store.scenes.map(\.id) == ["scene.movie"]
        }

        // Open HA camera before disable, seed HA transient prompts/blocks/suggestions, and start an in-flight LAN discovery.
        _ = try await store.resolveCameraStream(for: "ha-cam")
        #expect(await haStub.cameraResolveCalls.count == 1)

        store.pendingHAAddressSuggestion = HADiscoveredInstance(
            baseURL: "http://192.168.1.88:8123",
            locationName: "Other HA",
            version: "2026.4",
            uuid: "u-88"
        )
        store.haPlaintextPrompt = .asking("http://203.0.113.5:8123")
        store.localNetworkBlocks.insert(.homeAssistant)
        store.assistantSuggestions = [
            AssistantSuggestion(
                id: "sug-ha",
                title: "开启观影模式",
                intents: [DeviceIntent(targetId: "scene.movie", operation: .activateScene)]
            )
        ]

        let inFlightDiscovery = Task {
            await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
        }
        await discoveryGate.waitUntilEntered()
        #expect(await discoveryGate.callCount == 1)

        // Disable HA (ha-light is the only light in the home so confirm quickAction pause).
        let disableVerdict = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(disableVerdict.disposition == .requiresPauseConfirmation)
        #expect(!store.isHAConnectionEnabled)
        #expect(disabledCameraCallbacks == [["ha-light", "ha-cam"]])
        #expect(store.scenes.isEmpty)
        #expect(store.visibleScenes.isEmpty)
        #expect(store.pendingHAAddressSuggestion == nil)
        #expect(store.haPlaintextPrompt == nil)
        #expect(!store.localNetworkBlocks.contains(.homeAssistant))
        #expect(store.assistantSuggestions.isEmpty)
        #expect(!store.shouldAutoDiscoverHomeAssistantOnLAN)

        // While old HA provider is still shutting down, emit late events and finish in-flight LAN discovery: ALL must be dropped!
        await shutdownGate.waitUntilEntered()
        await haStub.emit(.snapshotUpdated(initialHAHome))
        await haStub.emit(.localNetworkPermissionChanged([.homeAssistant]))
        await haStub.emit(.doorbellRang(DoorbellRing(deviceId: "ha-cam", entityId: "event.porch_bell", firedAt: "2026-04-20T12:00:00Z")))
        store.handleProviderEvent(.doorbellRang(DoorbellRing(deviceId: "ha-cam", entityId: "event.porch_bell_2", firedAt: "2026-04-20T12:00:01Z")))
        store.handleProviderEvent(.localNetworkPermissionChanged([.homeAssistant]))
        store.askHAPlaintext(Self.haURL)
        store.offerHAAddress(HADiscoveredInstance(baseURL: "http://192.168.1.77:8123", locationName: "Late HA", version: "2026.4", uuid: "u-77"))

        await discoveryGate.release()
        let lateDiscoveryResult = await inFlightDiscovery.value
        #expect(lateDiscoveryResult.isEmpty)
        #expect(store.discoveredHAInstances.isEmpty)

        await shutdownGate.release()
        await store.providerShutdownTask?.value
        #expect(await haStub.shutdownCalls == 1)

        let postDisableRefreshes = await haStub.refreshCalls
        let postDisableCommands = await haStub.executedCommands.count
        let postDisableCameraCalls = await haStub.cameraResolveCalls.count
        let postDisableHistoryCalls = await haStub.sensorHistoryCalls.count

        // Verify post-disable state & directional zero counts.
        #expect(store.devices.map(\.id) == ["mi-plug"])
        #expect(store.scenes.isEmpty)
        #expect(doorbellResponses.isEmpty)
        #expect(store.haPlaintextPrompt == nil)
        #expect(store.pendingHAAddressSuggestion == nil)
        #expect(!store.localNetworkBlocks.contains(.homeAssistant))

        let secondDiscovery = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
        #expect(secondDiscovery.isEmpty)
        #expect(await discoveryGate.callCount == 1)

        await #expect(throws: CapabilityControlBlockedError.self) {
            _ = try await store.resolveCameraStream(for: "ha-cam")
        }
        store.refreshNow()
        await waitUntil { await miApi.deviceListCalls >= 2 }

        #expect(await haStub.refreshCalls == postDisableRefreshes)
        #expect(await haStub.executedCommands.count == postDisableCommands)
        #expect(await haStub.cameraResolveCalls.count == postDisableCameraCalls)
        #expect(await haStub.sensorHistoryCalls.count == postDisableHistoryCalls)

        // Meanwhile Xiaomi Cloud plug remains online and controllable!
        store.manualControlConfirmationHandler = { _ in true }
        let liveMiPlug = try #require(store.devices.first { $0.id == "mi-plug" })
        _ = await store.togglePrimary(liveMiPlug)?.value
        await waitUntil { await miApi.setPropsCalls.count == 1 }
    }

    // A snapshot can arrive after a polling deadline on a loaded runner. Wait for the
    // observed state itself and let the test time limit cancel a missing transition.
    private func awaitSnapshotState(_ matches: () -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            let (changes, change) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let ready = withObservationTracking {
                matches()
            } onChange: {
                change.yield(())
                change.finish()
            }
            if ready {
                change.finish()
                return
            }
            var iterator = changes.makeAsyncIterator()
            _ = await iterator.next()
            change.finish()
        }
    }

    // MARK: - 4. Reference Verdict Preview, Pause Confirmation, Atomic Commit & Revalidation

    @Test("HA disable previews device and scene timers, automations, and quick actions, enforces M2/M3, and revalidates on fresh snapshot without silent overdue execution")
    func referencePreviewPauseAtomicCommitAndFreshSnapshotRevalidation() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)

        let haLight = SmartDevice(
            id: "ha-light",
            name: "客厅主灯",
            roomId: "ha-living",
            roomName: "客厅",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living_main", isOn: true))
        )
        let haVanished = SmartDevice(
            id: "ha-vanished",
            name: "走廊夜灯",
            roomId: "ha-hall",
            roomName: "走廊",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.hall_night", isOn: true))
        )
        let movieScene = HomeScene(id: "scene.movie", name: "观影模式", entityId: "scene.movie")
        var initialHome = SynthesizedHome(devices: [haLight, haVanished], scenes: [movieScene])
        initialHome.isInitialLoadComplete = true

        final class ClockBox: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_760_000_000)
        }
        let clock = ClockBox()
        let haStub = StubHARuntimeProvider(initialSnapshot: initialHome)
        let store = HomeStore(
            provider: nil,
            credentialVault: vault,
            haProviderFactory: { _, _ in haStub },
            defaults: defaults
        )
        defer { _ = store.disconnectHomeAssistant() }
        store.assistantNow = { clock.now }
        let timerGate = ScheduledCommandTestSupport.SleepGate()
        store.assistantSleep = { _ in await timerGate.sleep() }
        defer { store.scheduledTasks.values.forEach { $0.cancel() } }

        try await awaitSnapshotState {
            Set(store.devices.map(\.id)) == ["ha-light", "ha-vanished"]
                && store.scenes.map(\.id) == ["scene.movie"]
        }

        // Seed waiting device timer (+600s), expiring scene timer (+60s), missed HA timer (-30s), and foreign HA timer.
        let futureDeviceTimer = ScheduledCommand(
            reply: "10 分钟后关闭客厅主灯",
            fireDate: clock.now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "ha-light", operation: .power(false))], reply: "关闭客厅主灯", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope]
        )
        let expiringSceneTimer = ScheduledCommand(
            reply: "1 分钟后开启观影模式",
            fireDate: clock.now.addingTimeInterval(60),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "scene.movie", operation: .activateScene)], reply: "开启观影模式", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope]
        )
        let alreadyMissedTimer = ScheduledCommand(
            reply: "刚才关闭客厅主灯",
            fireDate: clock.now.addingTimeInterval(-30),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "ha-light", operation: .power(false))], reply: "关闭客厅主灯", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope]
        )
        let foreignHATimer = ScheduledCommand(
            reply: "双源家庭关闭走廊夜灯",
            fireDate: clock.now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "ha-vanished", operation: .power(false))], reply: "关闭走廊夜灯", source: .local),
            sourceScope: "mi:other-account",
            sourceScopes: ["mi:other-account"]
        )
        ScheduledCommand.save([futureDeviceTimer, expiringSceneTimer, alreadyMissedTimer, foreignHATimer], to: defaults)
        store.restoreScheduledCommands(now: clock.now)
        #expect(store.scheduledCommands.count == 2)
        #expect(store.missedScheduledCommands.count == 1)
        #expect(store.foreignScheduledCommands.count == 1)

        // Seed enabled automation rules: one device rule on ha-light, one scene rule on scene.movie, one on ha-vanished.
        let deviceRule = AutomationRule(trigger: .away, action: .devices(ids: ["ha-light"], isOn: false), isEnabled: true)
        let sceneRule = AutomationRule(trigger: .back, action: .scene(sceneId: "scene.movie"), isEnabled: true)
        let vanishedRule = AutomationRule(trigger: .systemSleep, action: .devices(ids: ["ha-vanished"], isOn: false), isEnabled: true)
        let ruleStore = AutomationRuleStore(defaults: defaults)
        ruleStore.save([deviceRule, sceneRule, vanishedRule])

        let previewGen = store.capabilityGeneration
        let preview = store.previewSetHAConnectionEnabled(false)
        #expect(preview.disposition == .requiresPauseConfirmation)
        let kinds = Set(preview.itemsToPause.map(\.kind))
        #expect(kinds.contains(.waitingTimer))
        #expect(kinds.contains(.missedTimer))
        #expect(kinds.contains(.foreignTimer))
        #expect(kinds.contains(.automationRule))
        #expect(kinds.contains(.quickAction))
        let initialKeys = Set(preview.itemsToPause.map(\.pauseKey))

        // 1. Unconfirmed disable does nothing.
        let unconfirmed = store.setHAConnectionEnabled(false, pauseConfirmed: false)
        #expect(unconfirmed.disposition == .requiresPauseConfirmation)
        #expect(store.isHAConnectionEnabled)
        #expect(store.scheduledTasks.count == 2)

        // 2. Stale generation is blocked.
        let stale = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: previewGen - 1
        )
        #expect(stale.disposition == .blocked)
        #expect(store.isHAConnectionEnabled)

        // 3. M2 atomic commit: corrupting selection envelope blocks before pausing anything.
        let validSelectionBytes = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        defaults.set(Data("{corrupt".utf8), forKey: CapabilitySelectionStore.storageKey)
        let blockedWrite = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(blockedWrite.disposition == .blocked)
        #expect(store.isHAConnectionEnabled)
        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(store.scheduledTasks.count == 2)
        defaults.set(validSelectionBytes, forKey: CapabilitySelectionStore.storageKey)

        // 4. M3 changed pause list re-previews instead of pausing a different set.
        let extraTimer = ScheduledCommand(
            reply: "5 分钟后打开客厅主灯",
            fireDate: clock.now.addingTimeInterval(300),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "ha-light", operation: .power(true))], reply: "打开客厅主灯", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope]
        )
        store.scheduledCommands.append(extraTimer)
        ScheduledCommand.save(
            store.scheduledCommands + store.missedScheduledCommands + store.foreignScheduledCommands,
            to: defaults
        )
        let m3Verdict = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration,
            expectedPauseItemKeys: initialKeys
        )
        #expect(m3Verdict.disposition == .requiresPauseConfirmation)
        #expect(store.isHAConnectionEnabled)
        _ = store.cancelScheduledCommands(id: extraTimer.id)

        // 5. Confirmed disable with matching pause keys commits atomically.
        let freshPreview = store.previewSetHAConnectionEnabled(false)
        let confirmed = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration,
            expectedPauseItemKeys: Set(freshPreview.itemsToPause.map(\.pauseKey))
        )
        #expect(confirmed.disposition == .requiresPauseConfirmation)
        #expect(!store.isHAConnectionEnabled)
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(store.foreignScheduledCommands.isEmpty)
        #expect(store.scheduledTasks.isEmpty)
        #expect(store.pausedScheduledCommands.count == 4)
        #expect(ruleStore.load().allSatisfy { !$0.isEnabled })
        await store.providerShutdownTask?.value

        // Advance clock by +120s so expiringSceneTimer is overdue, and remove ha-vanished upstream.
        clock.now = clock.now.addingTimeInterval(120)
        var reconnectedHome = SynthesizedHome(devices: [haLight], scenes: [movieScene])
        reconnectedHome.isInitialLoadComplete = true
        await haStub.setInitialSnapshot(nil)

        let reenabled = store.setHAConnectionEnabled(true)
        #expect(reenabled.disposition == .allowed)
        #expect(store.isHAConnectionEnabled)
        #expect(store.pendingRevalidationScopes.contains(Self.haScope))

        // While HA is still disconnected, a non-authoritative snapshot must NOT resolve paused items!
        store.handleProviderEvent(.statusChanged(.disconnected("Reconnecting")))
        var disconnectedSnap = SynthesizedHome(devices: [], scenes: [])
        disconnectedSnap.isInitialLoadComplete = true
        store.reconcileReenabledScopesAfterSnapshot(disconnectedSnap)
        #expect(store.pendingRevalidationScopes.contains(Self.haScope))
        #expect(store.pausedScheduledCommands.count == 4)

        // Now deliver the authoritative connected HA snapshot:
        store.handleProviderEvent(.statusChanged(.connected))
        store.handleProviderEvent(.snapshotUpdated(reconnectedHome))

        #expect(store.pendingRevalidationScopes.isEmpty)
        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(store.scheduledCommands.map(\.id) == [futureDeviceTimer.id])
        #expect(store.scheduledTasks[futureDeviceTimer.id] != nil)
        // Expired timer moves to missed (0 silent commands sent!).
        #expect(Set(store.missedScheduledCommands.map(\.id)) == Set([expiringSceneTimer.id, alreadyMissedTimer.id]))
        #expect(await haStub.executedCommands.isEmpty)

        let rulesAfter = Dictionary(uniqueKeysWithValues: ruleStore.load().map { ($0.id, $0) })
        #expect(rulesAfter[deviceRule.id]?.isEnabled == true)
        #expect(rulesAfter[sceneRule.id]?.isEnabled == true)
        #expect(rulesAfter[vanishedRule.id]?.isEnabled == false)
        #expect(rulesAfter[vanishedRule.id]?.pausedCapabilities.isEmpty == true)
    }

    // MARK: - 5. Dual-Source Failover & Pinned-Source Semantics

    @Test("Dual-source unpinned paired card fails over to Xiaomi Cloud without pausing references and strips HA facets, while HA-pinned card stays pinned and blocks writes")
    func dualSourceFailoverAndPinnedSourceSemantics() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let unpinnedDid = "10001"
        let pinnedDid = "10002"
        let haUnpinnedID = "ha-unpinned-light"
        let haPinnedID = "ha-pinned-light"

        let haUnpinned = SmartDevice(
            id: haUnpinnedID,
            name: "客厅吸顶灯",
            roomId: "ha-living",
            roomName: "客厅",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living_ceiling", isOn: true, brightnessPercent: 80))
        )
        let haPinned = SmartDevice(
            id: haPinnedID,
            name: "主卧吊灯",
            roomId: "ha-bed",
            roomName: "主卧",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.master_chandelier", isOn: true, brightnessPercent: 60))
        )
        let miUnpinned = SmartDevice(
            id: unpinnedDid,
            name: "客厅吸顶灯",
            roomId: "\(Self.miAccount.id)/living",
            roomName: "客厅",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:\(unpinnedDid):2", isOn: true, brightnessPercent: 80)),
            accountId: Self.miAccount.id
        )
        let miPinned = SmartDevice(
            id: pinnedDid,
            name: "主卧吊灯",
            roomId: "\(Self.miAccount.id)/bed",
            roomName: "主卧",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:\(pinnedDid):2", isOn: true, brightnessPercent: 60)),
            accountId: Self.miAccount.id
        )

        let haFacet = FacetControl(
            id: "ha.night_mode",
            kind: .toggle,
            name: "night_mode",
            title: "HA 夜灯开关",
            serviceName: "light",
            value: .bool(false),
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: .haProperty(entityId: "switch.living_night_mode")
        )
        let miFacet = FacetControl(
            id: "2.7",
            kind: .toggle,
            name: "flex-switch",
            title: "凌动开关",
            serviceName: "light",
            value: .bool(true),
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: .property(entityId: "miot:\(unpinnedDid):2", piid: 7)
        )

        var haHome = SynthesizedHome(devices: [haUnpinned, haPinned])
        haHome.isInitialLoadComplete = true
        haHome.deviceIdentities = [
            haUnpinnedID: DeviceSourceIdentity(dids: [unpinnedDid], model: "yeelink.light.ceiling22", name: "客厅吸顶灯", roomName: "客厅", kindTag: .light),
            haPinnedID: DeviceSourceIdentity(dids: [pinnedDid], model: "yeelink.light.ceiling22", name: "主卧吊灯", roomName: "主卧", kindTag: .light),
        ]
        haHome.deviceFacets = [haUnpinnedID: [haFacet]]

        var miHome = SynthesizedHome(devices: [miUnpinned, miPinned])
        miHome.isInitialLoadComplete = true
        miHome.deviceIdentities = [
            unpinnedDid: DeviceSourceIdentity(dids: [unpinnedDid], model: "yeelink.light.ceiling22", name: "客厅吸顶灯", roomName: "客厅", kindTag: .light),
            pinnedDid: DeviceSourceIdentity(dids: [pinnedDid], model: "yeelink.light.ceiling22", name: "主卧吊灯", roomName: "主卧", kindTag: .light),
        ]
        miHome.deviceFacets = [unpinnedDid: [miFacet]]
        miHome.freshAccountIds = [Self.miAccount.id]
        miHome.accountStatuses = [Self.miAccount.id: .connected]

        let haMock = MockHomeProvider(snapshot: haHome)
        let miMock = MockHomeProvider(snapshot: miHome)
        let store = HomeStore(
            dualSource: (homeAssistant: haMock, xiaomiCloud: miMock),
            credentialVault: vault,
            defaults: defaults
        )
        store.hasHASource = true
        store.serverURLString = Self.haURL
        store.miAccounts = [Self.miAccount]
        store.syncInMemoryConfiguredCapabilities()

        try await awaitSnapshotState {
            Set(store.devices.map(\.id)) == [haUnpinnedID, haPinnedID]
                && store.pairedDeviceIDs == [haUnpinnedID, haPinnedID]
                && store.deviceBackend(for: haUnpinnedID) == .homeAssistant
                && store.deviceBackend(for: haPinnedID) == .homeAssistant
        }

        // Pin `haPinnedID` explicitly to `.homeAssistant`; keep `haUnpinnedID` automatic.
        store.pinDeviceSource(haPinnedID, to: .homeAssistant)
        #expect(store.pinnedSource(for: haPinnedID) == .homeAssistant)
        #expect(store.pinnedSource(for: haUnpinnedID) == nil)

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let timerGate = ScheduledCommandTestSupport.SleepGate()
        store.assistantNow = { now }
        store.assistantSleep = { _ in await timerGate.sleep() }
        defer { store.scheduledTasks.values.forEach { $0.cancel() } }

        // Seed one timer on unpinned card and one timer on HA-pinned card.
        let unpinnedTimer = ScheduledCommand(
            reply: "10 分钟后关闭客厅吸顶灯",
            fireDate: now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: haUnpinnedID, operation: .power(false))], reply: "关闭客厅吸顶灯", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope, Self.miAccount.id]
        )
        let pinnedTimer = ScheduledCommand(
            reply: "10 分钟后关闭主卧吊灯",
            fireDate: now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: haPinnedID, operation: .power(false))], reply: "关闭主卧吊灯", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope, Self.miAccount.id]
        )
        ScheduledCommand.save([unpinnedTimer, pinnedTimer], to: defaults)
        store.restoreScheduledCommands()
        let ruleStore = AutomationRuleStore(defaults: defaults)
        let unpinnedRule = AutomationRule(trigger: .away, action: .devices(ids: [haUnpinnedID], isOn: false), isEnabled: true)
        let pinnedRule = AutomationRule(trigger: .back, action: .devices(ids: [haPinnedID], isOn: false), isEnabled: true)
        ruleStore.save([unpinnedRule, pinnedRule])

        // Preview: ONLY `pinnedTimer` and `pinnedRule` require pause; `unpinnedTimer`, `unpinnedRule`, and `lightsOff` quick action survive on Xiaomi Cloud!
        let preview = store.previewSetHAConnectionEnabled(false)
        #expect(preview.disposition == .requiresPauseConfirmation)
        let pausedIDs = Set(preview.itemsToPause.map(\.id))
        #expect(pausedIDs.contains(pinnedTimer.id.uuidString))
        #expect(pausedIDs.contains(pinnedRule.id.uuidString))
        #expect(!pausedIDs.contains(unpinnedTimer.id.uuidString))
        #expect(!pausedIDs.contains(unpinnedRule.id.uuidString))
        #expect(!preview.itemsToPause.contains { $0.kind == .quickAction })

        // Confirm HA disable.
        let verdict = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(verdict.disposition == .requiresPauseConfirmation)
        #expect(store.pinnedSource(for: haPinnedID) == .homeAssistant)
        #expect(store.scheduledCommands.map(\.id) == [unpinnedTimer.id])
        #expect(store.pausedScheduledCommands.map(\.command.id) == [pinnedTimer.id])

        // Merged HA facet on `haUnpinnedID` is stripped immediately on disable, then MIoT facet takes over once HA child tears down!
        #expect(store.deviceFacets[haUnpinnedID] == nil)

        await store.providerShutdownTask?.value
        try await awaitSnapshotState {
            store.deviceBackend(for: haUnpinnedID) == .xiaomiCloud
                && store.deviceFacets[haUnpinnedID]?.map(\.id) == ["2.7"]
        }

        let haCommandsBefore = await haMock.executedCommands.count
        let miCommandsBefore = await miMock.executedCommands.count

        // Controlling HA-pinned card is rejected with "Home Assistant 已停用" and ZERO writes to Xiaomi or HA!
        if let pinnedCard = store.devices.first(where: { $0.id == haPinnedID }) {
            _ = store.togglePrimary(pinnedCard)
        } else {
            let gate = store.evaluateDeviceControlGate(deviceId: haPinnedID)
            #expect(!gate.allowed)
        }
        let pinnedRaycast = await store.executeRaycastPower(deviceId: haPinnedID, isOn: false)
        #expect(pinnedRaycast.isError)
        #expect(pinnedRaycast.message == "Home Assistant 已停用")
        #expect(await haMock.executedCommands.count == haCommandsBefore)
        #expect(await miMock.executedCommands.count == miCommandsBefore)

        // Meanwhile controlling unpinned card succeeds through Xiaomi Cloud with ZERO HA writes!
        let liveUnpinned = try #require(store.devices.first { $0.id == haUnpinnedID })
        _ = await store.togglePrimary(liveUnpinned)?.value
        #expect(await haMock.executedCommands.count == haCommandsBefore)
        #expect((await miMock.executedCommands).contains { $0.targetEntityId == "miot:\(unpinnedDid):2" })
    }

    // MARK: - 6. Comprehensive Host Write Gate & Post-Modal Generation Race

    @Test("Host write gate blocks all HA control entry points, atomically rejects mixed multi-target assistant plans, and catches mid-modal disable races")
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
        let haPinnedLight = SmartDevice(
            id: "ha-pinned-lamp",
            name: "落地灯",
            roomId: "ha-living",
            roomName: "客厅",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.floor_lamp", isOn: true, brightnessPercent: 75))
        )
        let miLight = SmartDevice(
            id: "mi-desk-lamp",
            name: "书桌台灯",
            roomId: "\(Self.miAccount.id)/study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:mi-desk-lamp:2", isOn: true, brightnessPercent: 90)),
            accountId: Self.miAccount.id
        )
        let haFacet = FacetControl(
            id: "ha.child_lock",
            kind: .toggle,
            name: "child_lock",
            title: "童锁",
            serviceName: "lock",
            value: .bool(true),
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: .haProperty(entityId: "switch.yard_child_lock")
        )
        let haActionFacet = FacetControl(
            id: "ha.calibrate",
            kind: .button,
            name: "calibrate",
            title: "校准",
            serviceName: "lock",
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: .haAction(entityId: "button.yard_calibrate")
        )
        let haScene = HomeScene(id: "scene.sleep", name: "睡眠模式", entityId: "scene.sleep")

        var snapshot = SynthesizedHome(devices: [haLock, haPinnedLight, miLight], scenes: [haScene])
        snapshot.isInitialLoadComplete = true
        snapshot.deviceBackends = [
            "ha-lock": .homeAssistant,
            "ha-pinned-lamp": .homeAssistant,
            "mi-desk-lamp": .xiaomiCloud,
        ]
        snapshot.pairedDeviceIDs = ["ha-pinned-lamp"]
        snapshot.deviceFacets = ["ha-lock": [haFacet, haActionFacet]]

        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        store.hasHASource = true
        store.serverURLString = Self.haURL
        store.syncInMemoryConfiguredCapabilities()
        try await awaitSnapshotState { store.hasReceivedInitialSnapshot }
        store.pinDeviceSource("ha-pinned-lamp", to: .homeAssistant)

        var confirmationPrompts = 0
        store.manualControlConfirmationHandler = { _ in
            confirmationPrompts += 1
            return true
        }

        // Disable HA.
        _ = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        // Keep stale pinned row on screen (as DualSourceHomeProvider paused pinned card does) to test card/quickAction/allOff/Raycast gates!
        var pausedPinnedLamp = haPinnedLight
        pausedPinnedLamp.isOnline = false
        store.devices = [pausedPinnedLamp, miLight]
        store.deviceFacets["ha-lock"] = [haFacet, haActionFacet]

        let commandsBefore = await mock.executedCommands.count

        // 1. Direct device & scene gate verdicts: disabled HA vs unknown!
        let disabledDevGate = store.evaluateDeviceControlGate(deviceId: "ha-lock")
        #expect(!disabledDevGate.allowed)
        #expect(disabledDevGate.writeCount == 0)
        #expect(disabledDevGate.rejectionReason?.userMessage == "Home Assistant 已停用")

        let unknownDevGate = store.evaluateDeviceControlGate(deviceId: "non-existent-id")
        #expect(!unknownDevGate.allowed)
        #expect(unknownDevGate.rejectionReason?.userMessage == "设备不存在")

        let disabledSceneGate = store.evaluateSceneControlGate(sceneId: "scene.sleep")
        #expect(!disabledSceneGate.allowed)
        #expect(disabledSceneGate.writeCount == 0)
        #expect(disabledSceneGate.rejectionReason?.userMessage == "Home Assistant 已停用")

        let unknownSceneGate = store.evaluateSceneControlGate(sceneId: "scene.never_existed")
        #expect(!unknownSceneGate.allowed)
        #expect(unknownSceneGate.rejectionReason?.userMessage == "场景不存在")

        // 2. Card, slider, drawer facets, button press, and unindexed HA entity commands -> 0 writes, 0 modals!
        store.dismissToast()
        _ = store.togglePrimary(haLock)
        #expect(confirmationPrompts == 0)
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        store.dismissToast()
        store.setLightBrightness("ha-pinned-lamp", percent: 50)
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        store.dismissToast()
        store.setFacetValue("ha-lock", controlId: "ha.child_lock", value: .bool(false))
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        store.dismissToast()
        store.runFacetAction("ha-lock", controlId: "ha.calibrate")
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        store.dismissToast()
        store.pressDeviceButton("button.yard_calibrate", label: "校准")
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        await #expect(throws: CapabilityControlBlockedError(reason: .connectionDisabled(.homeAssistant, scope: Self.haScope))) {
            try await store.executeDeviceCommand(.setSwitch(entityId: "switch.unindexed_entity", isOn: true))
        }

        // 3. Scene trigger: known disabled HA scene vs unknown scene.
        store.dismissToast()
        let disabledSceneOk = await store.triggerScene(haScene).value
        #expect(!disabledSceneOk)
        #expect(store.toastNotice?.message == "Home Assistant 已停用")

        store.dismissToast()
        let unknownSceneOk = await store.triggerScene(HomeScene(id: "scene.ghost", name: "幽灵场景", entityId: "scene.ghost")).value
        #expect(!unknownSceneOk)
        #expect(store.toastNotice?.message == "场景不存在")

        // 4. Assistant multi-target ATOMIC whole-plan rejection (1 enabled Xiaomi target + 1 disabled HA target -> 0 writes to BOTH!).
        let mixedDevicePlan = IntentPlan(
            intents: [
                DeviceIntent(targetId: "mi-desk-lamp", operation: .power(false)),
                DeviceIntent(targetId: "ha-lock", operation: .power(false)),
            ],
            reply: "关闭台灯和门锁",
            source: .model
        )
        let mixedResult = await store.executeIntentPlan(mixedDevicePlan, recordedUtterance: "关闭台灯和门锁", origin: .userInitiated)
        #expect(mixedResult.intents.isEmpty)
        #expect(mixedResult.reply == "Home Assistant 已停用")
        #expect(store.assistantState == .failed("Home Assistant 已停用"))
        #expect(await mock.executedCommands.count == commandsBefore)

        // Mixed scene + Xiaomi device plan also rejects atomically with 0 writes!
        let mixedScenePlan = IntentPlan(
            intents: [
                DeviceIntent(targetId: "mi-desk-lamp", operation: .brightness(30)),
                DeviceIntent(targetId: "scene.sleep", operation: .activateScene),
            ],
            reply: "开启睡眠模式",
            source: .model
        )
        let mixedSceneResult = await store.executeIntentPlan(mixedScenePlan, recordedUtterance: nil, origin: .aiAutomatic)
        #expect(mixedSceneResult.intents.isEmpty)
        #expect(mixedSceneResult.reply == "Home Assistant 已停用")
        #expect(await mock.executedCommands.count == commandsBefore)

        // Tapping a stale suggestion containing any HA target also rejects atomically with 0 writes!
        let mixedSuggestion = AssistantSuggestion(
            id: "sug-mixed",
            title: "全屋睡眠",
            intents: [
                DeviceIntent(targetId: "mi-desk-lamp", operation: .power(false)),
                DeviceIntent(targetId: "ha-pinned-lamp", operation: .power(false)),
            ]
        )
        await store.applyAssistantSuggestion(mixedSuggestion)
        #expect(store.assistantState == .failed("Home Assistant 已停用"))
        #expect(await mock.executedCommands.count == commandsBefore)

        // 5. Voice Undo & Automation with disabled HA targets -> 0 writes!
        store.lastAssistantUndo = AssistantUndoEntry(
            actionId: UUID(),
            reply: "已关闭门锁",
            restore: [.setSwitch(entityId: "switch.yard_lock", isOn: true)],
            previous: [haLock],
            at: Date(),
            habitReceipt: nil
        )
        _ = await store.runAssistantCommand("撤销")
        #expect(store.assistantState == .failed("Home Assistant 已停用"))
        #expect(await mock.executedCommands.count == commandsBefore)

        let autoOutcome = await store.runAutomation(
            intents: [DeviceIntent(targetId: "scene.sleep", operation: .activateScene)],
            title: "睡眠自动化"
        )
        #expect(autoOutcome.succeededCount == 0)
        #expect(autoOutcome.errorMessage == "Home Assistant 已停用")
        #expect(await mock.executedCommands.count == commandsBefore)

        // 6. Raycast snapshot & Raycast commands.
        let raycastSnap = store.buildRaycastSnapshot()
        #expect(raycastSnap.scenes.isEmpty)
        let raycastPinnedRow = try #require(raycastSnap.devices.first { $0.id == "ha-pinned-lamp" })
        #expect(!raycastPinnedRow.isPrimaryToggleable)

        let raycastBright = await store.executeRaycastBrightness(deviceId: "ha-pinned-lamp", percent: 40)
        #expect(raycastBright.isError)
        #expect(raycastBright.message == "Home Assistant 已停用")
        #expect(await mock.executedCommands.count == commandsBefore)

        // 7. Quick action & turnAllOff in mixed home skip disabled HA rows and only control enabled Xiaomi row!
        _ = await store.turnAllOff()?.value
        let afterAllOff = await mock.executedCommands
        #expect(afterAllOff.count == commandsBefore + 1)
        #expect(afterAllOff.last == .setLightPower(entityId: "miot:mi-desk-lamp:2", isOn: false))

        // 8. Post-modal capabilityGeneration race: re-enable HA, open high-risk power-ON confirmation on haLock, and disable HA mid-modal!
        _ = store.setHAConnectionEnabled(true)
        var offLock = haLock
        offLock.kind = .plug(PlugSpec(switchEntityId: "switch.yard_lock", isOn: false))
        store.devices = [offLock, miLight]
        let commandsBeforeModalRace = await mock.executedCommands.count
        var modalEntered = false
        store.manualControlConfirmationHandler = { _ in
            modalEntered = true
            _ = store.setHAConnectionEnabled(
                false,
                pauseConfirmed: true,
                expectedGeneration: store.capabilityGeneration
            )
            return true
        }
        let raceTask = store.togglePrimary(offLock)
        #expect(modalEntered)
        #expect(raceTask == nil)
        #expect(await mock.executedCommands.count == commandsBeforeModalRace)
    }

    // MARK: - 7. Disable vs Disconnect (Retained Credentials, Consent, Preferences & History)

    @Test("Disabling Home Assistant retains token, URL, plaintext consent, favorites, aliases, pins, and history, while Disconnect wipes token and releases paused timers")
    func disableRetainsCredentialsAndHistoryWhileDisconnectWipesToken() throws {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)

        let publicHTTPURL = "http://203.0.113.42:8123"
        let publicScope = "ha:http://203.0.113.42:8123"
        Self.seedHAConfig(defaults, vault, url: publicHTTPURL)
        HAPlaintextConsent.approve(publicHTTPURL, defaults: defaults)
        #expect(HAPlaintextConsent.allowsToken(to: publicHTTPURL, defaults: defaults))

        let store = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        store.haProviderFactory = { _, _ in MockHomeProvider() }
        let haSensor = SmartDevice(
            id: "ha-sensor-1",
            name: "书房温湿度计",
            roomId: "ha-study",
            roomName: "书房",
            model: "ha.sensor",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 23.4, humidity: 48))
        )
        let haPlug = SmartDevice(
            id: "ha-plug-1",
            name: "桌面排插",
            roomId: "ha-study",
            roomName: "书房",
            model: "ha.plug",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.desk_strip", isOn: true, powerWatts: 45, energyKwh: 12.5))
        )
        store.devices = [haSensor, haPlug]
        store.toggleFavorite("ha-plug-1")
        store.applyDeviceAliases(["ha-plug-1": "主显示器排插"])
        store.pinDeviceSource("ha-plug-1", to: .homeAssistant)

        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let sensorHistory = SensorHistory(defaults: defaults, connectionScope: publicScope)
        sensorHistory.record(devices: [haSensor], now: t0)
        let energyHistory = EnergyHistory(defaults: defaults, connectionScope: publicScope)
        energyHistory.record(devices: [haPlug], now: t0)
        #expect(defaults.data(forKey: SensorHistory.storageKey) != nil)
        #expect(energyHistory.recordingStartedAt != nil)

        // Seed a future timer on `ha-plug-1` so disabling pauses it.
        let plugTimer = ScheduledCommand(
            reply: "10 分钟后关闭桌面排插",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "ha-plug-1", operation: .power(false))], reply: "关闭桌面排插", source: .local),
            sourceScope: publicScope,
            sourceScopes: [publicScope]
        )
        ScheduledCommand.save([plugTimer], to: defaults)
        store.restoreScheduledCommands()

        // 1. Disable HA: ALL credentials, URL, plaintext consent, favorites, aliases, pins, and history stay intact!
        let disabled = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(disabled.disposition == .requiresPauseConfirmation)
        #expect(!store.isHAConnectionEnabled)
        #expect(store.loadHAToken() == Self.haToken)
        #expect(store.serverURLString == publicHTTPURL)
        #expect(HAPlaintextConsent.allowsToken(to: publicHTTPURL, defaults: defaults))
        #expect(store.favoriteDeviceIds.contains("ha-plug-1"))
        #expect(store.favoriteOrder.contains("ha-plug-1"))
        #expect(store.devicesWithAliases([haPlug]).first?.name == "主显示器排插")
        #expect(store.pinnedSource(for: "ha-plug-1") == .homeAssistant)
        #expect(defaults.data(forKey: SensorHistory.storageKey) != nil)
        #expect(EnergyHistory(defaults: defaults, connectionScope: publicScope).recordingStartedAt != nil)
        #expect(store.pausedScheduledCommands.count == 1)

        // 2. Saving via `updateConnection` while disabled retains disabled state without connecting;
        // explicit `setHAConnectionEnabled(true)` re-enables HA and queues fresh-snapshot revalidation.
        store.updateConnection(serverURL: publicHTTPURL, token: Self.haToken)
        #expect(!store.isHAConnectionEnabled)
        #expect(!store.pendingRevalidationScopes.contains(publicScope))

        let reenabled = store.setHAConnectionEnabled(true)
        #expect(reenabled.disposition == .allowed)
        #expect(store.isHAConnectionEnabled)
        #expect(store.pendingRevalidationScopes.contains(publicScope))

        // Pause again, then call `disconnectHomeAssistant()`: token is wiped, explicit-disable flag is cleared, and paused HA timer is released!
        store.devices = [haPlug]
        store.pendingRevalidationScopes.removeAll()
        store.revalidatePausedItems()
        #expect(store.scheduledCommands.count == 1)
        _ = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(store.pausedScheduledCommands.count == 1)

        #expect(store.disconnectHomeAssistant())
        #expect(!store.hasHASource)
        #expect(store.loadHAToken().isEmpty)
        #expect(store.serverURLString == publicHTTPURL)
        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(store.indexedDevicesById["ha-plug-1"] == nil)
    }

    // MARK: - 7. PR #285 Cross-Model Review Regression & Concurrency Tests

    private static func makeLoadedSnapshot(
        devices: [SmartDevice] = [],
        scenes: [HomeScene] = []
    ) -> SynthesizedHome {
        var snapshot = SynthesizedHome(devices: devices, scenes: scenes)
        snapshot.isInitialLoadComplete = true
        return snapshot
    }

    @Test("Disabling HA then switching to demo preserves all demo scenes and connected status")
    func disablingHAThenSwitchingToDemoPreservesDemoScenesAndStatus() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)

        let haProvider = StubHARuntimeProvider(
            initialSnapshot: Self.makeLoadedSnapshot(
                devices: [
                    SmartDevice(
                        id: "ha-lamp-demo-switch",
                        name: "书房灯",
                        roomId: "ha-study",
                        roomName: "书房",
                        model: "ha.light",
                        isOnline: true,
                        kind: .light(LightSpec(entityId: "light.study_demo_switch", isOn: true))
                    )
                ],
                scenes: [HomeScene(id: "scene.ha_only", name: "HA 观影", entityId: "scene.ha_only")]
            )
        )
        let store = HomeStore(provider: haProvider, credentialVault: vault, defaults: defaults)
        try await awaitSnapshotState { store.hasReceivedInitialSnapshot }

        let disabled = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(disabled.disposition == .allowed || disabled.disposition == .requiresPauseConfirmation)
        #expect(!store.isHAConnectionEnabled)
        #expect(store.allConfiguredSourcesTurnedOff)
        #expect(store.connectionStatus == .disconnected("连接已停用"))

        store.switchBackend(.demo)
        try await awaitSnapshotState { store.hasReceivedInitialSnapshot }

        #expect(store.homeBackend == .demo)
        #expect(!store.allConfiguredSourcesTurnedOff)
        #expect(store.connectionStatus == .connected)
        #expect(store.scenes.count == 2)
        #expect(store.visibleScenes.count == 2)
        #expect(!store.devices.isEmpty)
    }

    @Test("Saving HA settings while disabled preserves disabled state and emits zero HA provider creations until explicitly re-enabled")
    func updateConnectionWhileHADisabledKeepsDisabledState() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)

        var createdURLs: [String] = []
        var createdTokens: [String] = []
        let store = HomeStore(
            provider: StubHARuntimeProvider(initialSnapshot: Self.makeLoadedSnapshot()),
            credentialVault: vault,
            defaults: defaults
        )
        store.haProviderFactory = { url, token in
            createdURLs.append(url)
            createdTokens.append(token)
            return StubHARuntimeProvider(initialSnapshot: Self.makeLoadedSnapshot())
        }

        _ = store.setHAConnectionEnabled(false)
        if let teardownTask = store.capabilityTeardownTask {
            await teardownTask.value
        }
        #expect(!store.isHAConnectionEnabled)
        #expect(createdURLs.isEmpty)

        // A banner captured against the old instance must not survive an address change.
        store.lastAssistantUndo = AssistantUndoEntry(
            reply: "已关闭客厅灯",
            restore: [.setLightPower(entityId: "light.old_instance", isOn: true)],
            previous: [],
            at: Date(timeIntervalSince1970: 1_760_000_000)
        )

        let updatedURL = "http://192.168.1.99:8123"
        let updatedScope = "ha:\(updatedURL)"
        let updatedToken = "ha-updated-secret-token"
        store.updateConnection(serverURL: updatedURL, token: updatedToken)

        #expect(store.lastAssistantUndo == nil)
        #expect(!store.isHAConnectionEnabled)
        #expect(store.hasHASource)
        #expect(store.serverURLString == updatedURL)
        #expect(store.loadHAToken() == updatedToken)
        #expect(store.explicitlyDisabledConnections.contains(.homeAssistant))
        #expect(!store.capabilitySelection.enabledConnections.contains(.homeAssistant))
        #expect(!store.capabilitySelection.enabledConnectionScopes.contains(updatedScope))
        #expect(!store.capabilitySelection.enabledConnectionScopes.contains(Self.haScope))
        #expect(createdURLs.isEmpty)
        #expect(store.toastNotice?.message.contains("连接仍处于停用状态") == true)

        let reenabled = store.setHAConnectionEnabled(true)
        #expect(reenabled.disposition == .allowed)
        #expect(store.isHAConnectionEnabled)
        #expect(createdURLs == [updatedURL])
        #expect(createdTokens == [updatedToken])
        #expect(store.pendingRevalidationScopes.contains(updatedScope))
    }

    @Test("Saving a new HA address over a stale scope-level turn-off reconnects instead of leaving an enabled connection without a provider")
    func updateConnectionRecoversScopeLevelDisableWithoutLosingProvider() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        // Residue from an earlier address: the connection itself is on, only its `ha:` scope is off.
        // `migrateHomeAssistantScope` carries the connection's enablement to the freshly saved
        // address, so a save must not be mistaken for a save while disabled.
        let residue = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": CapabilitySelectionStore.schemaVersion,
            "migrationComplete": true,
            "enabledConnections": [ConnectionCapabilityID.homeAssistant.rawValue],
            "disabledConnections": [String](),
            "disabledConnectionScopes": [Self.haScope],
        ] as [String: Any], options: [.sortedKeys])
        defaults.set(residue, forKey: CapabilitySelectionStore.storageKey)

        var createdURLs: [String] = []
        let store = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        store.haProviderFactory = { url, _ in
            createdURLs.append(url)
            return MockHomeProvider()
        }
        #expect(store.hasHASource)
        #expect(!store.explicitlyDisabledConnections.contains(.homeAssistant))
        #expect(store.explicitlyDisabledScopes.contains(Self.haScope))
        #expect(!store.isHAConnectionEnabled)

        let updatedURL = "http://192.168.1.99:8123"
        store.updateConnection(serverURL: updatedURL, token: Self.haToken)

        // Either it stays turned off consistently, or it connects. Never「已启用但没有 provider」:
        // that state cannot be recovered from「启用连接」because the selection already reads enabled.
        if store.isHAConnectionEnabled {
            #expect(createdURLs == [updatedURL])
            #expect(store.activeBackends == [.homeAssistant])
            #expect(!store.explicitlyDisabledConnections.contains(.homeAssistant))
        } else {
            #expect(store.explicitlyDisabledConnections.contains(.homeAssistant)
                || store.explicitlyDisabledScopes.contains("ha:\(updatedURL)"))
            #expect(createdURLs.isEmpty)
            #expect(store.activeBackends.isEmpty)
        }
    }

    @Test("Dual-source undo with HA disabled restores Mi items, retains blocked HA restore items and receipts, and reports partial undo")
    func dualSourceUndoPreservesBlockedHAItemsAndHabitReceipts() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let miLamp = SmartDevice(
            id: "mi-lamp-undo",
            name: "客厅米家灯",
            roomId: "\(Self.miAccount.id)/living",
            roomName: "客厅",
            model: "yeelink.light.lamp1",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:mi-lamp-undo:2", isOn: false)),
            accountId: Self.miAccount.id
        )
        let miLampPrev = SmartDevice(
            id: "mi-lamp-undo",
            name: "客厅米家灯",
            roomId: "\(Self.miAccount.id)/living",
            roomName: "客厅",
            model: "yeelink.light.lamp1",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:mi-lamp-undo:2", isOn: true)),
            accountId: Self.miAccount.id
        )
        let haLamp = SmartDevice(
            id: "ha-lamp-undo",
            name: "书房 HA 灯",
            roomId: "study",
            roomName: "书房",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study_undo", isOn: false))
        )
        let haLampPrev = SmartDevice(
            id: "ha-lamp-undo",
            name: "书房 HA 灯",
            roomId: "study",
            roomName: "书房",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study_undo", isOn: true))
        )

        var miSnapshot = Self.makeLoadedSnapshot(devices: [miLamp])
        miSnapshot.freshAccountIds = [Self.miAccount.id]
        miSnapshot.accountStatuses = [Self.miAccount.id: .connected]
        let haSnapshot = Self.makeLoadedSnapshot(devices: [haLamp])

        let miProvider = StubHARuntimeProvider(initialSnapshot: miSnapshot)
        let haProvider = StubHARuntimeProvider(initialSnapshot: haSnapshot)
        let dual = DualSourceHomeProvider(homeAssistant: haProvider, xiaomiCloud: miProvider)
        let store = HomeStore(provider: dual, credentialVault: vault, defaults: defaults)
        try await awaitSnapshotState { store.hasReceivedInitialSnapshot }
        store.devices = [miLamp, haLamp]

        let miRestore = DeviceCommand.setLightPower(entityId: "miot:mi-lamp-undo:2", isOn: true)
        let haRestore = DeviceCommand.setLightPower(entityId: "light.study_undo", isOn: true)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var memory = store.userHabitMemory
        let habitReceipt = memory.record(
            utterance: nil,
            intents: [
                DeviceIntent(targetId: miLamp.id, operation: .power(false)),
                DeviceIntent(targetId: haLamp.id, operation: .power(false)),
            ],
            devices: [miLampPrev, haLampPrev],
            scenes: [],
            now: now
        )
        store.userHabitMemory = memory

        store.undoBanner = UndoBanner(
            title: "已关闭 2 个设备",
            restoreCommands: [miRestore, haRestore],
            previousDevices: [miLampPrev, haLampPrev],
            deviceCount: 2,
            habitReceipt: habitReceipt,
            isAllOff: true
        )

        // Disable HA after the dual-source all-off action.
        _ = store.setHAConnectionEnabled(false)
        if let teardownTask = store.capabilityTeardownTask {
            await teardownTask.value
        }
        #expect(!store.isHAConnectionEnabled)

        let haCommandsBefore = await haProvider.executedCommands.count
        let miCommandsBefore = await miProvider.executedCommands.count

        if let undoTask = store.undoTurnAllOff() {
            await undoTask.value
        }

        #expect(await miProvider.executedCommands.count == miCommandsBefore + 1)
        #expect(await miProvider.executedCommands.last?.targetEntityId == "miot:mi-lamp-undo:2")
        #expect(await haProvider.executedCommands.count == haCommandsBefore)
        #expect(store.undoBanner != nil)
        #expect(store.undoBanner?.restoreCommands == [haRestore])
        #expect(store.undoBanner?.habitReceipt?.entries.map(\.targetId) == [haLamp.id])
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message.contains("部分设备未撤销") == true)
        #expect(store.toastNotice?.message.contains("Home Assistant 已停用") == true)

        // Assistant undo path follows the exact same partial-retention contract.
        store.devices = [miLamp, haLamp]
        store.lastAssistantUndo = AssistantUndoEntry(
            reply: "已关闭全部灯光",
            restore: [miRestore, haRestore],
            previous: [miLampPrev, haLampPrev],
            at: Date()
        )
        let miCommandsBeforeAssistant = await miProvider.executedCommands.count
        _ = await store.runAssistantCommand("撤销")

        #expect(await miProvider.executedCommands.count == miCommandsBeforeAssistant + 1)
        #expect(await haProvider.executedCommands.count == haCommandsBefore)
        #expect(store.lastAssistantUndo != nil)
        #expect(store.lastAssistantUndo?.restore == [haRestore])
        if case .failed(let message) = store.assistantState {
            #expect(message.contains("部分设备未撤销"))
            #expect(message.contains("Home Assistant 已停用"))
        } else {
            Issue.record("Expected assistantState .failed with partial undo message, got \(store.assistantState)")
        }
    }

    @Test("Disabling HA short-circuits DualSourceHomeProvider reads during slow shutdown and exposes teardown state")
    func dualSourceDisableShortCircuitsReadsDuringSlowShutdown() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let haSensor = SmartDevice(
            id: "ha-sensor-race",
            name: "卧室传感器",
            roomId: "bedroom",
            roomName: "卧室",
            model: "ha.sensor",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 23.5, humidity: 48))
        )
        let haCam = SmartDevice(
            id: "ha-cam-race",
            name: "走廊摄像头",
            roomId: "hall",
            roomName: "走廊",
            model: "ha.camera",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.hall", isOn: true))
        )
        let miLamp = SmartDevice(
            id: "mi-lamp-race",
            name: "玄关灯",
            roomId: "\(Self.miAccount.id)/entry",
            roomName: "玄关",
            model: "yeelink.light.lamp1",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:mi-lamp-race:2", isOn: true)),
            accountId: Self.miAccount.id
        )

        let shutdownGate = AsyncGate()
        var miSnapshot = Self.makeLoadedSnapshot(devices: [miLamp])
        miSnapshot.freshAccountIds = [Self.miAccount.id]
        miSnapshot.accountStatuses = [Self.miAccount.id: .connected]
        let miProvider = StubHARuntimeProvider(initialSnapshot: miSnapshot)
        let haProvider = StubHARuntimeProvider(initialSnapshot: Self.makeLoadedSnapshot(devices: [haSensor, haCam]))
        await haProvider.setShutdownHook {
            await shutdownGate.enterAndWait()
        }

        let dual = DualSourceHomeProvider(homeAssistant: haProvider, xiaomiCloud: miProvider)
        let store = HomeStore(provider: dual, credentialVault: vault, defaults: defaults)
        try await awaitSnapshotState { store.hasReceivedInitialSnapshot }

        let haRefreshBefore = await haProvider.refreshCalls
        let miRefreshBefore = await miProvider.refreshCalls

        let result = store.setHAConnectionEnabled(false)
        #expect(result.disposition == .allowed)
        #expect(store.isDisablingHAConnection)
        #expect(store.capabilityTeardownTask != nil)

        // Wait deterministically until old HA child is blocked inside `shutdown()`.
        await shutdownGate.waitUntilEntered()

        // Concurrent reads during the teardown window must short-circuit HA while keeping Mi working.
        async let r1: Void = store.refreshNow()
        async let r2: Void = dual.refreshNow()
        async let r3: [SensorHistorySample] = dual.fetchSensorHistory(
            deviceId: haSensor.id,
            window: .last24Hours,
            now: Date(timeIntervalSince1970: 1_760_000_000)
        )
        async let r4: CameraStreamSource? = try? await dual.resolveCameraStream(
            for: haCam,
            quality: .sd,
            channel: 0
        )
        store.requestSensorHistory(for: haSensor.id, window: .last24Hours)
        let (_, _, historySamples, cameraStream) = await (r1, r2, r3, r4)

        #expect(historySamples.isEmpty)
        #expect(cameraStream == nil)
        #expect(await haProvider.refreshCalls == haRefreshBefore)
        #expect(await haProvider.sensorHistoryCalls.isEmpty)
        #expect(await haProvider.cameraResolveCalls.isEmpty)
        #expect(await miProvider.refreshCalls > miRefreshBefore)

        // Stale generation re-attach must be rejected while a newer disable generation exists.
        let staleGen = dual.disableGeneration(for: .homeAssistant)
        _ = dual.markBackendDisabled(.homeAssistant)
        let staleReplacement = StubHARuntimeProvider()
        await dual.setSourceProvider(staleReplacement, for: .homeAssistant, expectedDisableGeneration: staleGen)
        #expect(await staleReplacement.shutdownCalls == 1)

        await shutdownGate.release()
        if let teardownTask = store.capabilityTeardownTask {
            await teardownTask.value
        }

        #expect(!store.isDisablingHAConnection)
        #expect(store.capabilityTeardownTask == nil)
        #expect(await haProvider.shutdownCalls == 1)
    }

    @Test("Re-enabling HA after a completed teardown reopens the dual-source gate for commands, refresh and history")
    func reenableAfterTeardownReopensDualSourceGate() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)

        let haLamp = SmartDevice(
            id: "ha-lamp-reenable",
            name: "书房台灯",
            roomId: "ha-study",
            roomName: "书房",
            model: "ha.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study_reenable", isOn: true))
        )
        let haSensor = SmartDevice(
            id: "ha-sensor-reenable",
            name: "书房传感器",
            roomId: "ha-study",
            roomName: "书房",
            model: "ha.sensor",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 22.5, humidity: 45))
        )
        let haSnapshot = Self.makeLoadedSnapshot(devices: [haLamp, haSensor])
        let firstHA = StubHARuntimeProvider(initialSnapshot: haSnapshot)
        let newHA = StubHARuntimeProvider(initialSnapshot: haSnapshot)
        var createdProviders = 0
        let store = HomeStore(
            credentialVault: vault,
            haProviderFactory: { _, _ in
                createdProviders += 1
                return createdProviders == 1 ? firstHA : newHA
            },
            defaults: defaults
        )
        try await awaitSnapshotState { store.hasReceivedInitialSnapshot }
        let dual = try #require(store.activeDualProvider)
        #expect(createdProviders == 1)
        #expect(store.devices.map(\.id).sorted() == [haLamp.id, haSensor.id])
        let firstRefreshBefore = await firstHA.refreshCalls

        // The HA lamp owns a couple of quick-action references, so the disable is confirmed up front.
        _ = store.setHAConnectionEnabled(false, pauseConfirmed: true)
        #expect(store.explicitlyDisabledConnections.contains(.homeAssistant))
        #expect(!store.isHAConnectionEnabled)
        if let teardownTask = store.capabilityTeardownTask {
            await teardownTask.value
        }
        #expect(!store.isDisablingHAConnection)
        #expect(await firstHA.shutdownCalls == 1)
        #expect(!store.devices.contains { $0.id == haSensor.id })

        // The closed gate refuses the write before the async teardown even reaches the actor.
        var closedGateRefusedExecute = false
        do {
            try await dual.execute(.setLightPower(entityId: "light.study_reenable", isOn: false))
        } catch {
            closedGateRefusedExecute = true
        }
        #expect(closedGateRefusedExecute)

        let reenabled = store.setHAConnectionEnabled(true)
        #expect(reenabled.disposition == .allowed)
        #expect(store.isHAConnectionEnabled)
        await store.providerShutdownTask?.value
        // The gate only reopens once the replacement provider owns the backend again.
        try await awaitSnapshotState { store.devices.contains { $0.id == haSensor.id } }
        #expect(createdProviders == 2)
        #expect(store.isDisablingHAConnection == false)
        #expect(store.capabilityTeardownTask == nil)

        try await dual.execute(.setLightPower(entityId: "light.study_reenable", isOn: false))
        #expect(await newHA.executedCommands == [.setLightPower(entityId: "light.study_reenable", isOn: false)])
        #expect(await firstHA.executedCommands.isEmpty)

        await dual.refreshNow()
        #expect(await newHA.refreshCalls == 1)
        #expect(await firstHA.refreshCalls == firstRefreshBefore)

        let samples = await dual.fetchSensorHistory(
            deviceId: haSensor.id,
            window: .last24Hours,
            now: Date(timeIntervalSince1970: 1_760_000_000)
        )
        #expect(samples.isEmpty)
        #expect(await newHA.sensorHistoryCalls == [haSensor.id])
    }

    @Test("Single-device capabilityWriteRejection matches ID lookup across 200 mixed devices and preserves allOffTargets and RaycastSnapshot semantics")
    func singleDeviceCapabilityWriteRejectionMatchesIdLookup() throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let store = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)

        var devices: [SmartDevice] = []
        for index in 0..<100 {
            devices.append(SmartDevice(
                id: "ha-light-\(index)",
                name: "HA 灯 \(index)",
                roomId: "ha-room",
                roomName: "书房",
                model: "ha.light",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.ha_\(index)", isOn: true))
            ))
            devices.append(SmartDevice(
                id: "mi-light-\(index)",
                name: "米家灯 \(index)",
                roomId: "\(Self.miAccount.id)/mi-room",
                roomName: "客厅",
                model: "yeelink.light.lamp1",
                isOnline: true,
                kind: .light(LightSpec(entityId: "miot:mi-light-\(index):2", isOn: true)),
                accountId: Self.miAccount.id
            ))
        }
        store.devices = devices
        store.pinDeviceSource("mi-light-0", to: .homeAssistant)
        store.pinDeviceSource("mi-light-1", to: .xiaomiCloud)

        _ = store.setHAConnectionEnabled(false)

        for device in devices {
            let byDevice = store.capabilityWriteRejection(for: device)
            let byId = store.capabilityWriteRejection(forDeviceId: device.id)
            #expect(byDevice == byId)
        }

        // All HA-only lights and the HA-pinned Mi light are excluded from allOffTargets.
        let targets = Set(store.allOffTargets.map(\.id))
        #expect(!targets.contains("ha-light-0"))
        #expect(!targets.contains("mi-light-0"))
        #expect(targets.contains("mi-light-1"))
        #expect(targets.count == 99)

        let snapshot = store.buildRaycastSnapshot()
        #expect(snapshot.devices.first(where: { $0.id == "ha-light-0" }) == nil)
        let pinnedHAItem = try #require(snapshot.devices.first(where: { $0.id == "mi-light-0" }))
        let miItem = try #require(snapshot.devices.first(where: { $0.id == "mi-light-1" }))
        #expect(!pinnedHAItem.capabilities.canTogglePower)
        #expect(!pinnedHAItem.isPrimaryToggleable)
        #expect(miItem.capabilities.canTogglePower)
        #expect(miItem.isPrimaryToggleable)
    }

    @Test("disconnectHomeAssistant tears down active HA cameras while leaving Mi cameras untouched")
    func disconnectHomeAssistantTearsDownActiveHACameras() throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let haCam = SmartDevice(
            id: "ha-cam-disconnect",
            name: "HA 门廊摄像头",
            roomId: "porch",
            roomName: "玄关",
            model: "ha.camera",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.porch_disconnect", isOn: true))
        )
        let miCam = SmartDevice(
            id: "mi-cam-disconnect",
            name: "米家客厅摄像头",
            roomId: "\(Self.miAccount.id)/living",
            roomName: "客厅",
            model: "chuangmi.camera.055a02",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "miot:mi-cam-disconnect:2", isOn: true)),
            accountId: Self.miAccount.id
        )

        let store = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        store.devices = [haCam, miCam]
        store.activeLiveCameraDeviceId = haCam.id

        var tornDownSets: [Set<String>] = []
        store.onHAConnectionDisabled = { ids in
            tornDownSets.append(ids)
        }

        #expect(store.disconnectHomeAssistant())
        #expect(tornDownSets == [Set([haCam.id])])
        #expect(store.activeLiveCameraDeviceId == nil)

        // Re-seed HA and verify an active Mi camera stays open when disconnecting HA.
        Self.seedHAConfig(defaults, vault)
        store.devices = [haCam, miCam]
        store.activeLiveCameraDeviceId = miCam.id
        tornDownSets.removeAll()

        #expect(store.disconnectHomeAssistant())
        #expect(tornDownSets == [Set([haCam.id])])
        #expect(store.activeLiveCameraDeviceId == miCam.id)
    }

    @Test("Re-enabling HA on an injected DualSourceHomeProvider queues pendingRevalidationScopes symmetrically")
    func injectedDualSourceReenableQueuesPendingRevalidationScope() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedHAConfig(defaults, vault)
        MiSessionStore.saveAccounts([Self.miAccount], defaults: defaults, vault: vault)

        let haPlug = SmartDevice(
            id: "ha-plug-injected",
            name: "书房插座",
            roomId: "study",
            roomName: "书房",
            model: "ha.plug",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.study_injected", isOn: true))
        )
        var miSnapshot = Self.makeLoadedSnapshot()
        miSnapshot.freshAccountIds = [Self.miAccount.id]
        miSnapshot.accountStatuses = [Self.miAccount.id: .connected]
        let miProvider = StubHARuntimeProvider(initialSnapshot: miSnapshot)
        let haProvider = StubHARuntimeProvider(initialSnapshot: Self.makeLoadedSnapshot(devices: [haPlug]))
        let dual = DualSourceHomeProvider(homeAssistant: haProvider, xiaomiCloud: miProvider)

        let store = HomeStore(provider: dual, credentialVault: vault, defaults: defaults)
        try await awaitSnapshotState { store.hasReceivedInitialSnapshot }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        store.assistantNow = { now }
        let plugTimer = ScheduledCommand(
            reply: "10 分钟后关闭书房插座",
            fireDate: now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: haPlug.id, operation: .power(false))], reply: "关闭书房插座", source: .local),
            sourceScope: Self.haScope,
            sourceScopes: [Self.haScope]
        )
        ScheduledCommand.save([plugTimer], to: defaults)
        store.restoreScheduledCommands(now: now)

        _ = store.setHAConnectionEnabled(
            false,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        if let teardownTask = store.capabilityTeardownTask {
            await teardownTask.value
        }
        #expect(store.pausedScheduledCommands.count == 1)

        // No `haProviderFactory` is installed, yet `hasManagedHAProvider` recognizes the injected DualSourceHomeProvider.
        let reenabled = store.setHAConnectionEnabled(true)
        #expect(reenabled.disposition == .allowed)
        #expect(store.pendingRevalidationScopes.contains(Self.haScope))
        #expect(store.pausedScheduledCommands.count == 1)
    }
}


