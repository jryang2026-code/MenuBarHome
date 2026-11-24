import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

@MainActor
struct MiAccountDisableTests {
    private static let cnSession = MiSession(
        userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn"
    )
    private static let deSession = MiSession(
        userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de"
    )
    private static let cn = MiAccount(session: cnSession)
    private static let de = MiAccount(session: deSession)

    private actor AsyncGate {
        private var entered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            if !entered {
                entered = true
                let waiters = enteredWaiters
                enteredWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            if released { return }
            await withCheckedContinuation { cont in
                if released { cont.resume() } else { releaseWaiters.append(cont) }
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { cont in
                if entered { cont.resume() } else { enteredWaiters.append(cont) }
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

    private static func makeSeededStore(
        accounts: [MiAccount] = [cn, de],
        provider: (any HomeProvider)? = nil
    ) -> (HomeStore, InMemoryUserDefaults, CredentialVault, MemoryVaultStorage) {
        let defaults = InMemoryUserDefaults()
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        if !accounts.isEmpty {
            MiSessionStore.saveAccounts(accounts, defaults: defaults, vault: vault)
            defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        }
        let store = HomeStore(provider: provider ?? MockHomeProvider(), credentialVault: vault, defaults: defaults)
        return (store, defaults, vault, mem)
    }

    private static func indexedLight(id: String, name: String, accountId: String?) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: "\(Self.cn.id)/r", roomName: "客厅",
            model: "yeelink.light.ceiling22", isOnline: true,
            kind: .light(LightSpec(entityId: "miot:\(id):2", isOn: true)),
            accountId: accountId, accountLabel: accountId == nil ? nil : "米家账号"
        )
    }

    private static func timer(id: String, scope: String, scopes: [String]? = nil, offset: TimeInterval = 600, now: Date = Date()) -> ScheduledCommand {
        ScheduledCommand(
            reply: "关闭 \(id)",
            fireDate: now.addingTimeInterval(offset),
            plan: IntentPlan(intents: [DeviceIntent(targetId: id, operation: .power(false))], reply: "关闭 \(id)", source: .local),
            sourceScope: scope,
            sourceScopes: scopes ?? [scope]
        )
    }

    @Test("Bundled capability manifest matches Shared/capability-manifest.json and legacy migration preserves unknown fields and fallback disables")
    func manifestParityLegacyMigrationAndFallback() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var foundRoot: URL?
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Shared/capability-manifest.json").path) {
                foundRoot = dir
                break
            }
            dir.deleteLastPathComponent()
        }
        let repoRoot = try #require(foundRoot)
        let sharedData = try Data(contentsOf: repoRoot.appendingPathComponent("Shared/capability-manifest.json"))
        let bundledData = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/MijiaCore/Resources/capability-manifest.json"))
        #expect(sharedData == bundledData && CapabilityManifest.shared.schemaVersion == 1)

        let (first, defaults, vault, mem) = Self.makeSeededStore()
        #expect(first.isMiAccountEnabled(Self.cn.id) && first.isMiAccountEnabled(Self.de.id))
        #expect(first.enabledMiAccounts.map(\.id) == [Self.cn.id, Self.de.id])
        #expect(CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))

        let rawData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        var json = try #require(try JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        json["futureTopLevelFlag"] = "keep-me"
        var enabledFeatures = (json["enabledFeatures"] as? [String]) ?? []
        enabledFeatures.append("future.feature.alpha")
        json["enabledFeatures"] = enabledFeatures
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: CapabilitySelectionStore.storageKey)

        #expect(first.setMiAccountEnabled(false, id: Self.cn.id).disposition == .allowed)
        #expect(!first.isMiAccountEnabled(Self.cn.id) && first.isMiAccountEnabled(Self.de.id))

        let rawUpdated = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let updatedJSON = try #require(try JSONSerialization.jsonObject(with: rawUpdated) as? [String: Any])
        #expect(updatedJSON["futureTopLevelFlag"] as? String == "keep-me")
        #expect((updatedJSON["enabledFeatures"] as? [String])?.contains("future.feature.alpha") == true)

        let second = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        #expect(!second.isMiAccountEnabled(Self.cn.id) && second.isMiAccountEnabled(Self.de.id))

        mem.readResult = .unavailable
        let fallbackAfterDisable = HomeStore(
            provider: nil, credentialVault: CredentialVault(storage: mem.storage),
            miAccountsProviderFactory: { MiAccountsProvider(accounts: $0, specSource: StubSpecSource(), pollInterval: .seconds(60)) },
            defaults: defaults
        )
        defer { fallbackAfterDisable.logoutMiAccount() }
        #expect(fallbackAfterDisable.capabilityResolutionMode == .uncertainFallback)
        fallbackAfterDisable.miAccounts = [Self.cn, Self.de]
        #expect(!fallbackAfterDisable.isMiAccountEnabled(Self.cn.id) && fallbackAfterDisable.isMiAccountEnabled(Self.de.id))

        let freshDefaults = InMemoryUserDefaults()
        let freshMem = MemoryVaultStorage()
        MiSessionStore.saveAccounts([Self.cn], defaults: freshDefaults, vault: CredentialVault(storage: freshMem.storage))
        freshDefaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        freshMem.readResult = .unavailable
        let fallbackBeforeMigration = HomeStore(provider: MockHomeProvider(), credentialVault: CredentialVault(storage: freshMem.storage), defaults: freshDefaults)
        #expect(!CapabilitySelectionStore.hasCompletedMigration(defaults: freshDefaults) && fallbackBeforeMigration.capabilityResolutionMode == .uncertainFallback)

        freshMem.readResult = nil
        let recoveredStore = HomeStore(provider: MockHomeProvider(), credentialVault: CredentialVault(storage: freshMem.storage), defaults: freshDefaults)
        #expect(CapabilitySelectionStore.hasCompletedMigration(defaults: freshDefaults) && recoveredStore.isMiAccountEnabled(Self.cn.id))

        let corruptBytes = Data("{not-valid-json".utf8)
        freshDefaults.set(corruptBytes, forKey: CapabilitySelectionStore.storageKey)
        let corruptStore = HomeStore(provider: MockHomeProvider(), credentialVault: CredentialVault(storage: freshMem.storage), defaults: freshDefaults)
        #expect(corruptStore.capabilityResolutionMode == .uncertainFallback && freshDefaults.data(forKey: CapabilitySelectionStore.storageKey) == corruptBytes)
    }

    @Test("Active backends, panel health, HA address changes, and per-account session expiry reflect account enablement")
    func activeBackendsPanelHealthHAAddressAndSessionExpiry() throws {
        #expect(HomeBackendDescriptor.activeBackends(
            homeBackend: .xiaomiCloud, configuredSources: [.xiaomiCloud], disabledSources: [.xiaomiCloud]
        ).isEmpty)
        #expect(HomeBackendDescriptor.activeBackends(
            homeBackend: .xiaomiCloud, configuredSources: [.homeAssistant, .xiaomiCloud], disabledSources: [.xiaomiCloud]
        ) == [.homeAssistant])

        let (store, defaults, _, _) = Self.makeSeededStore()
        #expect(store.activeBackends == [.xiaomiCloud] && store.activeConnectionScopes == [Self.cn.id, Self.de.id])
        store.setMiAccountEnabled(false, id: Self.cn.id)
        #expect(store.hasMiSource && store.hasEnabledMiSource && store.activeConnectionScopes == [Self.de.id])
        store.setMiAccountEnabled(false, id: Self.de.id)
        #expect(store.hasMiSource && !store.hasEnabledMiSource && store.activeBackends.isEmpty && !store.isShowingMiReauth)
        #expect(store.panelHealth != .notConfigured)
        if case .blocked = store.panelHealth {} else { Issue.record("expected .blocked") }

        store.hasHASource = true
        store.serverURLString = "http://192.168.1.10:8123"
        #expect(store.isHAConnectionEnabled)
        store.serverURLString = "http://192.168.1.20:8123"
        #expect(store.isHAConnectionEnabled && store.activeConnectionScopes.contains("ha:http://192.168.1.20:8123"))
        _ = store.setHAConnectionEnabled(false)
        store.serverURLString = "http://192.168.1.30:8123"
        store.registerNewlyConfiguredScope(Self.de.id, connection: .xiaomiCloud)
        let rawScopeData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let json = try #require(try JSONSerialization.jsonObject(with: rawScopeData) as? [String: Any])
        #expect(!(Set(json["disabledConnectionScopes"] as? [String] ?? [])).contains("ha:http://192.168.1.30:8123"))

        let now = Date()
        let expiredCN = MiAccount(session: MiSession(userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn", expiresAt: now.addingTimeInterval(-3600)))
        let validDE = MiAccount(session: MiSession(userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de", expiresAt: now.addingTimeInterval(86_400 * 10)))
        let (expStore, _, _, _) = Self.makeSeededStore(accounts: [expiredCN, validDE])
        expStore.miAccountStatuses = [expiredCN.id: .disconnected("401 expired"), validDE.id: .connected]
        #expect(expStore.miSessionShowsExpired && !expStore.miSessionBlocksControl)
        #expect(expStore.setMiAccountEnabled(false, id: expiredCN.id).disposition == .allowed)
        #expect(expStore.miAccountStatuses[expiredCN.id] == nil && !expStore.miSessionShowsExpired && !expStore.miSessionBlocksControl)
        #expect(expStore.setMiAccountEnabled(true, id: expiredCN.id).disposition == .allowed)
        #expect(expStore.setMiAccountEnabled(false, id: validDE.id).disposition == .allowed)
        #expect(expStore.miSessionShowsExpired && expStore.miSessionBlocksControl)
    }

    @Test("Disabling one Xiaomi account stops its cloud, camera, follow-up, and write activity while keeping the other online", .timeLimit(.minutes(1)))
    func disablingOneAccountProducesZeroPostDisableActivityAndHandlesInFlightRequests() async throws {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let cnLight = MiDeviceRecord(did: "cn-light", name: "客厅吸顶灯", model: "yeelink.light.ceiling22", isOnline: true)
        let cnCam = MiDeviceRecord(did: "cn-cam", name: "玄关摄像机", model: "isa.camera.hlc7", isOnline: true)
        let dePlug = MiDeviceRecord(did: "de-plug", name: "书房插座", model: "cuco.plug.v3", isOnline: true)

        let cnApi = StubMiCloudAPI(
            devices: [cnLight, cnCam],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light", "cn-cam"], homeId: "home-cn", homeName: "国内家")],
            values: [MiotFixtures.key("cn-light", 2, 1): .bool(true), MiotFixtures.key("cn-light", 2, 2): .number(80)]
        )
        let deApi = StubMiCloudAPI(
            devices: [dePlug],
            rooms: [MiRoom(id: "r-de", name: "书房", dids: ["de-plug"], homeId: "home-de", homeName: "海外家")],
            values: [MiotFixtures.key("de-plug", 2, 1): .bool(false)]
        )
        let cnBridge = StubXiaomiCameraBridge()
        let deBridge = StubXiaomiCameraBridge()

        let store = HomeStore(
            provider: nil,
            credentialVault: vault,
            miAccountsProviderFactory: { accounts in
                MiAccountsProvider(
                    accounts: accounts,
                    apiFactory: { session in session.region == "de" ? deApi : cnApi },
                    specSource: StubSpecSource(),
                    cameraBridgeFactory: { session in session.region == "de" ? deBridge : cnBridge },
                    pollInterval: .seconds(60),
                    followUpDelay: .seconds(30)
                )
            },
            defaults: defaults
        )
        defer { store.logoutMiAccount() }

        var disabledCallbacks: [(String, Set<String>)] = []
        store.onMiAccountDisabled = { disabledCallbacks.append(($0, $1)) }
        try await awaitState { store.hasReceivedInitialSnapshot }
        try #require(Set(store.devices.map(\.id)) == ["cn-light", "cn-cam", "de-plug"])

        _ = try await store.resolveCameraStream(for: "cn-cam")
        #expect(await cnBridge.startCalls.count == 1)

        let inFlightGate = AsyncGate()
        await cnApi.setGetPropsHook { await inFlightGate.enterAndWait() }
        store.refreshNow()
        await inFlightGate.waitUntilEntered()

        let cnLightSnapshot = try #require(store.devices.first { $0.id == "cn-light" })
        #expect(store.setMiAccountEnabled(false, id: Self.cn.id).disposition == .requiresPauseConfirmation)
        #expect(disabledCallbacks.isEmpty)

        let disableVerdict = store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(disableVerdict.disposition == .requiresPauseConfirmation && disabledCallbacks.count == 1)
        #expect(disabledCallbacks.first?.0 == Self.cn.id && disabledCallbacks.first?.1 == ["cn-light", "cn-cam"])

        await cnApi.setGetPropsHook(nil)
        await inFlightGate.release()
        await store.providerShutdownTask?.value

        let postDisableDeviceListCalls = await cnApi.deviceListCalls
        let postDisableGetPropsCalls = await cnApi.getPropsCalls.count
        let postDisableSetPropsCalls = await cnApi.setPropsCalls.count
        let postDisableCameraStarts = await cnBridge.startCalls.count

        #expect(store.devices.map(\.id) == ["de-plug"] && store.miAccountStatuses[Self.cn.id] == nil)
        store.manualControlConfirmationHandler = { _ in true }
        _ = store.togglePrimary(cnLightSnapshot)
        await #expect(throws: Error.self) { _ = try await store.resolveCameraStream(for: "cn-cam") }
        await deApi.setValue(MiotFixtures.key("de-plug", 2, 1), .bool(true))
        store.refreshNow()
        try await awaitState { store.devices.first { $0.id == "de-plug" }?.isActiveOn == true }
        #expect(await deApi.deviceListCalls >= 2)

        #expect(await cnApi.deviceListCalls == postDisableDeviceListCalls)
        #expect(await cnApi.getPropsCalls.count == postDisableGetPropsCalls)
        #expect(await cnApi.setPropsCalls.count == postDisableSetPropsCalls)
        #expect(await cnBridge.startCalls.count == postDisableCameraStarts)

        let dePlugDevice = try #require(store.devices.first { $0.id == "de-plug" })
        let write = try #require(store.togglePrimary(dePlugDevice))
        #expect(await write.value)
        #expect(await deApi.setPropsCalls.count == 1)
        #expect(await cnApi.setPropsCalls.count == postDisableSetPropsCalls)
    }

    @Test("Reference verdict previews affected items, pauses/extends on confirm, guards M2/M3/M4/M6, and revalidates only on connected authoritative snapshots")
    func referenceVerdictPauseAndAuthoritativeRevalidation() async throws {
        let (store, defaults, vault, _) = Self.makeSeededStore()
        let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
        store.assistantNow = { fixedNow }

        let cnLight = Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)
        let deLight = Self.indexedLight(id: "de-light", name: "书房灯", accountId: Self.de.id)
        store.devices = [cnLight, deLight]
        defaults.set("[{\"id\":\"grp-living\",\"name\":\"客厅灯组\"}]", forKey: "device_groups")
        defaults.set("{\"cn-light\":\"grp-living\"}", forKey: ViewPreferenceKeys.groupMap)

        let futureTimer = Self.timer(id: "cn-light", scope: Self.cn.id, scopes: [Self.cn.id, Self.de.id], offset: 600, now: fixedNow)
        let multiTimer = ScheduledCommand(
            reply: "关闭两盏灯", fireDate: fixedNow.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "cn-light", operation: .power(false)), DeviceIntent(targetId: "de-light", operation: .power(false))], reply: "关闭两盏灯", source: .local),
            sourceScope: Self.cn.id, sourceScopes: [Self.cn.id, Self.de.id]
        )
        let lgTimer = Self.timer(id: LGWebOSProtocol.deviceId, scope: Self.cn.id, offset: 600, now: fixedNow)
        ScheduledCommand.save([futureTimer, multiTimer, lgTimer], to: defaults)
        store.restoreScheduledCommands()

        let ruleStore = AutomationRuleStore(defaults: defaults)
        let validRule = AutomationRule(trigger: .away, action: .devices(ids: ["cn-light"], isOn: false), isEnabled: true)
        let multiRule = AutomationRule(trigger: .back, action: .devices(ids: ["cn-light", "de-light"], isOn: false), isEnabled: true)
        let validJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(validRule)) as? [String: Any])
        let multiJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(multiRule)) as? [String: Any])
        let unreadable: [String: Any] = ["id": UUID().uuidString, "trigger": "renamed-trigger", "action": [:]]
        defaults.set(try JSONSerialization.data(withJSONObject: [validJSON, multiJSON, unreadable]), forKey: AutomationRuleStore.storageKey)

        let preview = store.previewSetMiAccountEnabled(false, id: Self.cn.id)
        #expect(preview.disposition == .requiresPauseConfirmation)
        #expect(!preview.itemsToPause.contains { $0.id.hasPrefix("group:") })
        let confirmedKeys = Set(preview.itemsToPause.map(\.pauseKey))

        #expect(store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration, expectedPauseItemKeys: ["stale-key"]).disposition == .requiresPauseConfirmation)
        #expect(store.isMiAccountEnabled(Self.cn.id))

        let savedBlob = defaults.data(forKey: CapabilitySelectionStore.storageKey)
        defaults.set(Data("{not-valid-json".utf8), forKey: CapabilitySelectionStore.storageKey)
        #expect(store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration).disposition == .blocked)
        #expect(store.pausedScheduledCommands.isEmpty)
        defaults.set(savedBlob, forKey: CapabilitySelectionStore.storageKey)

        let confirmed = store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration, expectedPauseItemKeys: confirmedKeys)
        #expect(confirmed.disposition == .requiresPauseConfirmation && !store.isMiAccountEnabled(Self.cn.id))
        #expect(store.scheduledCommands.map(\.id) == [lgTimer.id])
        #expect(store.pausedScheduledCommands.count == 2)
        let rawRulesData = try #require(defaults.data(forKey: AutomationRuleStore.storageKey))
        let rawRules = try #require(try JSONSerialization.jsonObject(with: rawRulesData) as? [Any])
        #expect(rawRules.count == 3)

        store.setMiAccountEnabled(false, id: Self.de.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        let multiPaused = try #require(store.pausedScheduledCommands.first { $0.command.id == multiTimer.id })
        #expect(multiPaused.pausedScopes == [Self.cn.id, Self.de.id].sorted())
        #expect(ruleStore.load().first { $0.id == multiRule.id }?.pausedScopes == [Self.cn.id, Self.de.id].sorted())

        store.completeMiLogin(Self.cnSession)
        #expect(store.isMiAccountEnabled(Self.cn.id) && store.pendingRevalidationScopes.contains(Self.cn.id))
        var disconnectedSnap = SynthesizedHome(devices: [cnLight])
        disconnectedSnap.isInitialLoadComplete = true
        disconnectedSnap.freshAccountIds = [Self.cn.id]
        disconnectedSnap.miAccountsEpoch = store.miAccountsConfigEpoch
        disconnectedSnap.accountStatuses = [Self.cn.id: .disconnected("401")]
        store.reconcileReenabledScopesAfterSnapshot(disconnectedSnap)
        #expect(store.pendingRevalidationScopes.contains(Self.cn.id) && store.pausedScheduledCommands.count == 2)

        store.selectedMiHomeId = Self.cn.id + "/home-cn"
        var connectedSnap = disconnectedSnap
        connectedSnap.accountStatuses = [Self.cn.id: .connected]
        store.reconcileReenabledScopesAfterSnapshot(connectedSnap)
        #expect(store.pendingRevalidationScopes.contains(Self.cn.id))

        store.selectedMiHomeId = nil
        store.devices = [cnLight]
        store.reconcileReenabledScopesAfterSnapshot(connectedSnap)
        #expect(!store.pendingRevalidationScopes.contains(Self.cn.id))
        #expect(store.scheduledCommands.map(\.id).contains(futureTimer.id))
        #expect(store.pausedScheduledCommands.map(\.command.id) == [multiTimer.id])
        #expect(ruleStore.load().first { $0.id == validRule.id }?.isEnabled == true)
        #expect(ruleStore.load().first { $0.id == multiRule.id }?.isEnabled == false)

        let relaunched = HomeStore(provider: MockHomeProvider(), credentialVault: vault, defaults: defaults)
        #expect(relaunched.pausedScheduledCommands.count == 1)
        relaunched.logoutMiAccount()
        #expect(relaunched.pausedScheduledCommands.isEmpty)
        #expect(store.cancelScheduledCommands() >= 1 && store.pausedScheduledCommands.isEmpty)
    }

    @Test("Control write gate blocks disabled account targets, split/merged facets, and unknown MIoT dids while keeping HA-paired and unknown-account rows controllable")
    func controlWriteGateAndDualSourcePairingInvariants() async throws {
        let cnLock = SmartDevice(
            id: "cn-lock", name: "入户门锁", roomId: Self.cn.id + "/r-cn", roomName: "玄关",
            model: "xiaomi.lock.pro", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:cn-lock:2", isOn: true)),
            accountId: Self.cn.id, accountLabel: Self.cn.maskedUserId
        )
        let splitSwitch = SmartDevice(
            id: "wall-hub.s2", name: "玄关二键开关", roomId: "\(Self.cn.id)/hall", roomName: "玄关",
            model: "lumi.switch.b2lacn02", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:wall-hub:2:1", isOn: true)),
            accountId: Self.cn.id, accountLabel: Self.cn.maskedUserId
        )
        let haPairedAC = SmartDevice(
            id: "climate.bedroom", name: "主卧空调", roomId: "ha-bed", roomName: "主卧",
            model: "xiaomi.aircondition.mc5", isOnline: true,
            kind: .climate(ClimateSpec(entityId: "climate.bedroom", isOn: true, hvacMode: "cool", availableModes: ["cool", "heat"], targetTemperature: 25)),
            accountId: Self.cn.id
        )
        let splitFacet = FacetControl(
            id: "5.1", kind: .toggle, name: "indicator-light", title: "背光指示灯",
            serviceName: "indicator-light", value: .bool(true), isWritable: true, writesByDefault: true, isHighValue: false,
            target: .property(entityId: "miot:wall-hub:5", piid: 1)
        )
        let mergedMiFacet = FacetControl(
            id: "7.1", kind: .toggle, name: "alarm", title: "提示音",
            serviceName: "alarm", value: .bool(true), isWritable: true, writesByDefault: true, isHighValue: false,
            target: .property(entityId: "miot:mi-ac-did:7", piid: 1)
        )
        let mergedMiActionFacet = FacetControl(
            id: "7.a2", kind: .button, name: "self-clean", title: "自清洁",
            serviceName: "maintenance", isWritable: true, writesByDefault: true, isHighValue: false,
            target: .action(entityId: "miot-action:mi-ac-did:7:2")
        )
        let haNativeFacet = FacetControl(
            id: "ha.eco", kind: .toggle, name: "eco", title: "节能模式",
            serviceName: "climate", value: .bool(false), isWritable: true, writesByDefault: true, isHighValue: false,
            target: .haProperty(entityId: "switch.bedroom_ac_eco")
        )

        var snapshot = SynthesizedHome(devices: [cnLock, splitSwitch, haPairedAC])
        snapshot.isInitialLoadComplete = true
        snapshot.deviceBackends = ["cn-lock": .xiaomiCloud, "wall-hub.s2": .xiaomiCloud, "climate.bedroom": .homeAssistant]
        snapshot.pairedDeviceIDs = ["climate.bedroom"]
        snapshot.deviceFacets = [
            "wall-hub.s2": [splitFacet],
            "climate.bedroom": [mergedMiFacet, mergedMiActionFacet, haNativeFacet],
        ]
        let mock = MockHomeProvider(snapshot: snapshot)
        let (store, defaults, vault, _) = Self.makeSeededStore(provider: mock)
        var confirmationCalls = 0
        store.manualControlConfirmationHandler = { _ in confirmationCalls += 1; return true }
        store.hasHASource = true
        store.serverURLString = "http://192.168.1.10:8123"
        try await store.waitForTestSnapshot()
        #expect(store.inferSource(for: haPairedAC) == (.homeAssistant, store.homeAssistantScopeIdentifier))

        let pairedTimer = Self.timer(id: "climate.bedroom", scope: Self.cn.id, scopes: [Self.cn.id, store.homeAssistantScopeIdentifier])
        ScheduledCommand.save([pairedTimer], to: defaults)
        store.restoreScheduledCommands()
        #expect(store.previewSetMiAccountEnabled(false, id: Self.cn.id).disposition == .allowed)
        #expect(store.setMiAccountEnabled(false, id: Self.cn.id).disposition == .allowed)
        #expect(store.scheduledCommands.count == 1 && store.pausedScheduledCommands.isEmpty)

        #expect(store.devices.map(\.id) == ["climate.bedroom"])
        #expect(store.deviceFacets["climate.bedroom"]?.map(\.id) == ["ha.eco"])

        let disabledGate = store.evaluateDeviceControlGate(deviceId: "cn-lock")
        #expect(!disabledGate.allowed && disabledGate.rejectionReason?.userMessage == "该米家账号已停用")
        let missingGate = store.evaluateDeviceControlGate(deviceId: "never-existed")
        #expect(!missingGate.allowed && missingGate.rejectionReason?.userMessage == "设备不存在")

        _ = store.togglePrimary(cnLock)
        #expect(confirmationCalls == 0 && store.toastNotice?.message == "该米家账号已停用")

        for blockedCmd in [
            DeviceCommand.setSwitch(entityId: "miot:cn-lock:2", isOn: false),
            .setMiotProperty(entityId: "miot:wall-hub:5", piid: 1, value: .bool(false)),
            .setMiotProperty(entityId: "miot:mi-ac-did:7", piid: 1, value: .bool(false)),
            .setSwitch(entityId: "miot:unindexed-did:9:1", isOn: false),
            .pressButton(entityId: "miot-action:cn-lock:2:1"),
        ] {
            await #expect(throws: CapabilityControlBlockedError(reason: .connectionScopeDisabled(.xiaomiCloud, scope: Self.cn.id))) {
                try await store.executeDeviceCommand(blockedCmd)
            }
        }

        let raycastDisabled = await store.executeRaycastPower(deviceId: "cn-lock", isOn: false)
        #expect(raycastDisabled.isError && raycastDisabled.message == "该米家账号已停用")
        let raycastMissing = await store.executeRaycastPower(deviceId: "never-existed", isOn: false)
        #expect(raycastMissing.isError && raycastMissing.message == "设备不存在")

        store.deviceFacets["climate.bedroom"] = [mergedMiFacet, mergedMiActionFacet, haNativeFacet]
        store.dismissToast()
        store.pressDeviceButton("miot-action:mi-ac-did:7:2", label: "自清洁")
        #expect(store.toastNotice?.message == "该米家账号已停用")
        store.dismissToast()
        store.setFacetValue("climate.bedroom", controlId: "7.1", value: .bool(false))
        #expect(store.toastNotice?.message == "该米家账号已停用")
        store.dismissToast()
        store.runFacetAction("climate.bedroom", controlId: "7.a2")
        #expect(store.toastNotice?.message == "该米家账号已停用")
        #expect(await mock.executedCommands.isEmpty)

        try await store.executeDeviceCommand(.setSwitch(entityId: "switch.bedroom_ac_eco", isOn: true))
        #expect(await mock.executedCommands.count == 1)

        let (unconfiguredStore, _, _, _) = Self.makeSeededStore(accounts: [], provider: mock)
        let foreignRow = Self.indexedLight(id: "stale-light", name: "旧账号灯", accountId: "acc-not-on-this-mac")
        unconfiguredStore.devices = [foreignRow]
        _ = try await #require(unconfiguredStore.togglePrimary(foreignRow)).value
        #expect(await mock.executedCommands.count == 2)
        _ = vault
    }
}
