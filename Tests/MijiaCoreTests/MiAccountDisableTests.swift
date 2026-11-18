import Foundation
import KeychainTestSupport
import Testing
@testable import MijiaCore

/// P2a-M: Xiaomi account connection disablement on macOS.
///
/// Covers persisted selection & migration safety, effective backend derivation, multi-account
/// teardown (zero post-disable cloud/LAN/camera/timer/write activity including in-flight and late
/// results), P1b reference verdicts (preview, pause confirmation, re-enable revalidation), and
/// host control write gating with distinct rejection copy.
@MainActor
struct MiAccountDisableTests {
    private static let cnSession = MiSession(
        userId: "10010001",
        cUserId: "c-cn",
        ssecurity: "ssec-cn",
        serviceToken: "tok-cn",
        region: "cn"
    )
    private static let deSession = MiSession(
        userId: "20020002",
        cUserId: "c-de",
        ssecurity: "ssec-de",
        serviceToken: "tok-de",
        region: "de"
    )
    private static let cn = MiAccount(session: cnSession)
    private static let de = MiAccount(session: deSession)

    private static func makeSuite() -> String {
        "com.jryang1997.MenuBarMijia.mi-disable.\(UUID().uuidString)"
    }

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

    // MARK: - 1. Persistence, Legacy Migration, Idempotency & Read-Failure Fallback

    @Test("Bundled capability manifest matches Shared/capability-manifest.json byte for byte")
    func bundledManifestMatchesSharedManifest() throws {
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
        #expect(sharedData == bundledData)
        #expect(CapabilityManifest.shared.schemaVersion == 1)
    }

    @Test("Legacy upgrade keeps all configured Xiaomi accounts enabled and migrates idempotently")
    func legacyUpgradeKeepsAllAccountsEnabledAndPreservesUnknownFields() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let first = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, credentialVault: vault)
        #expect(first.isMiAccountEnabled(Self.cn.id))
        #expect(first.isMiAccountEnabled(Self.de.id))
        #expect(first.enabledMiAccounts.map(\.id) == [Self.cn.id, Self.de.id])
        #expect(CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))

        // Inject unknown future JSON keys and unknown capability strings to prove read-merge-write preserves them.
        let rawData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        var json = try #require(try JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        json["futureTopLevelFlag"] = "keep-me"
        var enabledFeatures = (json["enabledFeatures"] as? [String]) ?? []
        enabledFeatures.append("future.feature.alpha")
        json["enabledFeatures"] = enabledFeatures
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: CapabilitySelectionStore.storageKey)

        let verdict = first.setMiAccountEnabled(false, id: Self.cn.id)
        #expect(verdict.disposition == .allowed)
        #expect(!first.isMiAccountEnabled(Self.cn.id))
        #expect(first.isMiAccountEnabled(Self.de.id))

        let updatedData = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        let updatedJSON = try #require(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        #expect(updatedJSON["futureTopLevelFlag"] as? String == "keep-me")
        #expect((updatedJSON["enabledFeatures"] as? [String])?.contains("future.feature.alpha") == true)

        // Reopening is idempotent and preserves explicit account disablement.
        let second = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, credentialVault: vault)
        #expect(!second.isMiAccountEnabled(Self.cn.id))
        #expect(second.isMiAccountEnabled(Self.de.id))
        #expect(second.enabledMiAccounts.map(\.id) == [Self.de.id])
    }

    @Test("Vault or selection read failure falls back to legacy behavior without writing migration-complete")
    func readFailureFallsBackWithoutSealingMigration() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        // Simulate temporarily unavailable Keychain during launch before migration has ever succeeded.
        mem.readResult = .unavailable
        let unavailableVault = CredentialVault(storage: mem.storage)
        let fallbackStore = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, credentialVault: unavailableVault)
        #expect(!CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))
        #expect(defaults.data(forKey: CapabilitySelectionStore.storageKey) == nil)
        #expect(fallbackStore.capabilityResolutionMode == .uncertainFallback)

        // Once Keychain recovers, next launch completes migration cleanly with Self.cn enabled.
        mem.readResult = nil
        let recoveredVault = CredentialVault(storage: mem.storage)
        let recoveredStore = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, credentialVault: recoveredVault)
        #expect(CapabilitySelectionStore.hasCompletedMigration(defaults: defaults))
        #expect(recoveredStore.isMiAccountEnabled(Self.cn.id))

        // Corrupting the selection envelope also triggers uncertainFallback and does not overwrite the blob.
        let corruptBytes = Data("{not-valid-json".utf8)
        defaults.set(corruptBytes, forKey: CapabilitySelectionStore.storageKey)
        let corruptStore = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, credentialVault: CredentialVault(storage: mem.storage))
        #expect(corruptStore.capabilityResolutionMode == .uncertainFallback)
        #expect(corruptStore.isMiAccountEnabled(Self.cn.id))
        #expect(defaults.data(forKey: CapabilitySelectionStore.storageKey) == corruptBytes)
    }

    // MARK: - 2. Effective Backends & Multi-Account Scope Aggregation

    @Test("Active backends reflect per-account Xiaomi enablement without disturbing Home Assistant or other accounts")
    func activeBackendsReflectAccountEnablement() throws {
        #expect(
            HomeBackendDescriptor.activeBackends(
                homeBackend: .xiaomiCloud,
                hasHASource: false,
                hasMiSource: true,
                isHAEnabled: true,
                isMiEnabled: false
            ).isEmpty
        )
        #expect(
            HomeBackendDescriptor.activeBackends(
                homeBackend: .xiaomiCloud,
                hasHASource: true,
                hasMiSource: true,
                isHAEnabled: true,
                isMiEnabled: false
            ) == [.homeAssistant]
        )

        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, credentialVault: vault)
        #expect(store.activeBackends == [.xiaomiCloud])
        #expect(store.activeConnectionScopes == [Self.cn.id, Self.de.id])

        store.setMiAccountEnabled(false, id: Self.cn.id)
        #expect(store.hasMiSource)
        #expect(store.hasEnabledMiSource)
        #expect(store.activeBackends == [.xiaomiCloud])
        #expect(store.activeConnectionScopes == [Self.de.id])

        store.setMiAccountEnabled(false, id: Self.de.id)
        #expect(store.hasMiSource)
        #expect(!store.hasEnabledMiSource)
        #expect(store.activeBackends.isEmpty)
        #expect(store.activeConnectionScopes.isEmpty)
        #expect(!store.isShowingMiReauth)
    }

    // MARK: - 3. Runtime Teardown, Zero Post-Disable Activity, In-Flight & Late Results

    @Test("Disabling one Xiaomi account stops its cloud, camera, follow-up, and write activity while keeping the other online")
    func disablingOneAccountProducesZeroPostDisableActivityAndHandlesInFlightRequests() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let cnLight = MiDeviceRecord(did: "cn-light", name: "客厅吸顶灯", model: "yeelink.light.ceiling22", isOnline: true)
        let cnCam = MiDeviceRecord(did: "cn-cam", name: "玄关摄像机", model: "isa.camera.hlc7", isOnline: true)
        let dePlug = MiDeviceRecord(did: "de-plug", name: "书房插座", model: "cuco.plug.v3", isOnline: true)

        let cnApi = StubMiCloudAPI(
            devices: [cnLight, cnCam],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light", "cn-cam"], homeId: "home-cn", homeName: "国内家")],
            values: [
                MiotFixtures.key("cn-light", 2, 1): .bool(true),
                MiotFixtures.key("cn-light", 2, 2): .number(80),
            ]
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
            defaultsSuiteName: suite,
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
            }
        )
        defer { store.logoutMiAccount() }

        var disabledCallbacks: [(String, Set<String>)] = []
        store.onMiAccountDisabled = { accountId, deviceIds in
            disabledCallbacks.append((accountId, deviceIds))
        }

        await waitUntil {
            let ids = Set(store.devices.map(\.id))
            return ids == ["cn-light", "cn-cam", "de-plug"]
        }

        // Open a camera stream on cn-cam before disable, then hold an in-flight getProps poll on cnApi.
        _ = try await store.resolveCameraStream(for: "cn-cam")
        #expect(await cnBridge.startCalls.count == 1)

        let inFlightGate = AsyncGate()
        await cnApi.setGetPropsHook {
            await inFlightGate.enterAndWait()
        }

        // Trigger a manual refresh so cnApi enters an in-flight getProps call.
        store.refreshNow()
        await inFlightGate.waitUntilEntered()

        let cnLightSnapshot = try #require(store.devices.first { $0.id == "cn-light" })

        // Disable cn while cnApi.getProps is in flight! Since cn-light is the only light in the home,
        // built-in light quick actions require pause confirmation before teardown proceeds.
        let unconfirmedDisable = store.setMiAccountEnabled(false, id: Self.cn.id)
        #expect(unconfirmedDisable.disposition == .requiresPauseConfirmation)
        #expect(disabledCallbacks.isEmpty)

        let disableVerdict = store.setMiAccountEnabled(
            false,
            id: Self.cn.id,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(disableVerdict.disposition == .requiresPauseConfirmation)
        #expect(disabledCallbacks.count == 1)
        #expect(disabledCallbacks.first?.0 == Self.cn.id)
        #expect(disabledCallbacks.first?.1 == ["cn-light", "cn-cam"])

        // Release the single already-entered getProps call and wait for provider shutdown task to finish.
        await cnApi.setGetPropsHook(nil)
        await inFlightGate.release()
        await store.providerShutdownTask?.value

        let postDisableDeviceListCalls = await cnApi.deviceListCalls
        let postDisableGetPropsCalls = await cnApi.getPropsCalls.count
        let postDisableSetPropsCalls = await cnApi.setPropsCalls.count
        let postDisableCameraStarts = await cnBridge.startCalls.count

        // Late results must not re-add cn's devices, rooms, homes, or statuses.
        #expect(store.devices.map(\.id) == ["de-plug"])
        #expect(store.rooms.map(\.id) == [Self.de.id + "/shu_fang"])
        #expect(store.homes.map(\.id) == [Self.de.id + "/home-de"])
        #expect(store.miAccountStatuses[Self.cn.id] == nil)

        store.manualControlConfirmationHandler = { _ in true }

        // Attempting control, camera start, or refresh after disable produces 0 new cn requests/tasks/timers/writes.
        _ = store.togglePrimary(cnLightSnapshot)
        await #expect(throws: Error.self) {
            _ = try await store.resolveCameraStream(for: "cn-cam")
        }
        store.refreshNow()
        await waitUntil { await deApi.deviceListCalls >= 2 }

        #expect(await cnApi.deviceListCalls == postDisableDeviceListCalls)
        #expect(await cnApi.getPropsCalls.count == postDisableGetPropsCalls)
        #expect(await cnApi.setPropsCalls.count == postDisableSetPropsCalls)
        #expect(await cnBridge.startCalls.count == postDisableCameraStarts)
        #expect(store.scheduledTasks.isEmpty)

        // Meanwhile Account B (de) remains online and controllable.
        let dePlugDevice = try #require(store.devices.first { $0.id == "de-plug" })
        _ = await store.togglePrimary(dePlugDevice)?.value
        await waitUntil { await deApi.setPropsCalls.count == 1 }
        #expect(await cnApi.setPropsCalls.count == postDisableSetPropsCalls)
    }

    // MARK: - 4. Reference Verdict Preview, Pause Confirmation & Re-Enable Revalidation

    @Test("Disabling an account previews affected timers, automations, and quick actions, pauses on confirm, and revalidates on re-enable")
    func referencePreviewPauseAndReenableRevalidation() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let cnLight = MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)
        let cnVanished = MiDeviceRecord(did: "cn-vanished", name: "阳台灯", model: "yeelink.light.ceiling22", isOnline: true)
        let dePlug = MiDeviceRecord(did: "de-plug", name: "书房插座", model: "cuco.plug.v3", isOnline: true)

        let cnApi = StubMiCloudAPI(
            devices: [cnLight, cnVanished],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light", "cn-vanished"], homeId: "home-cn", homeName: "国内家")],
            values: [
                MiotFixtures.key("cn-light", 2, 1): .bool(true),
                MiotFixtures.key("cn-vanished", 2, 1): .bool(true),
            ]
        )
        let deApi = StubMiCloudAPI(
            devices: [dePlug],
            rooms: [MiRoom(id: "r-de", name: "书房", dids: ["de-plug"], homeId: "home-de", homeName: "海外家")],
            values: [MiotFixtures.key("de-plug", 2, 1): .bool(false)]
        )

        final class ClockBox: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_760_000_000)
        }
        let clock = ClockBox()
        let store = HomeStore(
            provider: nil,
            defaultsSuiteName: suite,
            credentialVault: vault,
            miAccountsProviderFactory: { accounts in
                MiAccountsProvider(
                    accounts: accounts,
                    apiFactory: { session in session.region == "de" ? deApi : cnApi },
                    specSource: StubSpecSource(),
                    pollInterval: .seconds(60),
                    followUpDelay: .seconds(30)
                )
            }
        )
        defer { store.logoutMiAccount() }
        store.assistantNow = { clock.now }

        await waitUntil {
            Set(store.devices.map(\.id)) == ["cn-light", "cn-vanished", "de-plug"]
        }

        // Seed 3 waiting timers on cn: future (+600s), expiring (+60s), and deleted-target (+600s).
        let futureTimer = ScheduledCommand(
            reply: "10 分钟后关闭客厅灯",
            fireDate: clock.now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))], reply: "关闭客厅灯", source: .local),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id, Self.de.id]
        )
        let expiringTimer = ScheduledCommand(
            reply: "1 分钟后关闭客厅灯",
            fireDate: clock.now.addingTimeInterval(60),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))], reply: "关闭客厅灯", source: .local),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id, Self.de.id]
        )
        let deletedTargetTimer = ScheduledCommand(
            reply: "10 分钟后关闭阳台灯",
            fireDate: clock.now.addingTimeInterval(600),
            plan: IntentPlan(intents: [DeviceIntent(targetId: "cn-vanished", operation: .power(false))], reply: "关闭阳台灯", source: .local),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id, Self.de.id]
        )
        ScheduledCommand.save([futureTimer, expiringTimer, deletedTargetTimer], to: defaults)
        store.restoreScheduledCommands()
        #expect(store.scheduledCommands.count == 3)
        #expect(store.scheduledTasks.count == 3)

        // Seed enabled automation rules (one valid on cn-light, one on cn-vanished) and a custom device group.
        let validRule = AutomationRule(trigger: .away, action: .devices(ids: ["cn-light"], isOn: false), isEnabled: true)
        let deletedRule = AutomationRule(trigger: .back, action: .devices(ids: ["cn-vanished"], isOn: true), isEnabled: true)
        let ruleStore = AutomationRuleStore(defaults: defaults)
        ruleStore.save([validRule, deletedRule])

        defaults.set("[{\"id\":\"grp-living\",\"name\":\"客厅灯组\"}]", forKey: "device_groups")
        defaults.set("{\"cn-light\":\"grp-living\"}", forKey: ViewPreferenceKeys.groupMap)

        let previewGen = store.capabilityGeneration
        let preview = store.previewSetMiAccountEnabled(false, id: Self.cn.id)
        #expect(preview.disposition == .requiresPauseConfirmation)
        let kinds = Set(preview.itemsToPause.map(\.kind))
        #expect(kinds.contains(.waitingTimer))
        #expect(kinds.contains(.automationRule))
        #expect(kinds.contains(.quickAction))

        // Without confirmation, disabling is refused and nothing is paused or torn down.
        let unconfirmed = store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: false)
        #expect(unconfirmed.disposition == .requiresPauseConfirmation)
        #expect(store.isMiAccountEnabled(Self.cn.id))
        #expect(store.scheduledTasks.count == 3)

        // Stale generation is blocked.
        let stale = store.setMiAccountEnabled(
            false,
            id: Self.cn.id,
            pauseConfirmed: true,
            expectedGeneration: previewGen - 1
        )
        #expect(stale.disposition == .blocked)
        #expect(store.isMiAccountEnabled(Self.cn.id))

        // Confirmed deactivation pauses timers (canceling Tasks, storing outside active key), rules, and quick actions.
        let confirmed = store.setMiAccountEnabled(
            false,
            id: Self.cn.id,
            pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration
        )
        #expect(confirmed.disposition == .requiresPauseConfirmation)
        #expect(!store.isMiAccountEnabled(Self.cn.id))
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.scheduledTasks.isEmpty)
        #expect(ScheduledCommand.load(from: defaults).isEmpty)

        let pausedRules = ruleStore.load()
        #expect(pausedRules.allSatisfy { !$0.isEnabled })

        // Before re-enabling: advance clock by +120s (so expiringTimer is past due) and remove cn-vanished upstream.
        clock.now = clock.now.addingTimeInterval(120)
        await cnApi.replaceDevices([cnLight])

        let reenabled = store.setMiAccountEnabled(true, id: Self.cn.id)
        #expect(reenabled.disposition == .allowed)

        await waitUntil {
            Set(store.devices.map(\.id)) == ["cn-light", "de-plug"]
                && store.scheduledCommands.map(\.id) == [futureTimer.id]
        }

        #expect(store.scheduledTasks[futureTimer.id] != nil)
        #expect(Set(store.missedScheduledCommands.map(\.id)) == Set([expiringTimer.id, deletedTargetTimer.id]))

        let resumedRules = Dictionary(uniqueKeysWithValues: ruleStore.load().map { ($0.id, $0) })
        #expect(resumedRules[validRule.id]?.isEnabled == true)
        #expect(resumedRules[deletedRule.id]?.isEnabled == false)
    }

    // MARK: - 5. Control Write Gate & Distinct Rejection Copy

    @Test("Control write gate rejects disabled account targets before confirmation with zero writes and distinct copy")
    func controlWriteGateDistinguishesDisabledAccountFromMissingDevice() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let mock = MockHomeProvider()
        let store = HomeStore(provider: mock, defaultsSuiteName: suite, credentialVault: vault)
        var confirmationCalls = 0
        store.manualControlConfirmationHandler = { _ in
            confirmationCalls += 1
            return true
        }

        let cnLock = SmartDevice(
            id: "cn-lock",
            name: "入户门锁",
            roomId: Self.cn.id + "/r-cn",
            roomName: "玄关",
            model: "xiaomi.lock.pro",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:cn-lock:2", isOn: true)),
            accountId: Self.cn.id,
            accountLabel: Self.cn.maskedUserId
        )
        let dePlug = SmartDevice(
            id: "de-plug",
            name: "书房插座",
            roomId: Self.de.id + "/r-de",
            roomName: "书房",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:de-plug:2", isOn: false)),
            accountId: Self.de.id,
            accountLabel: Self.de.maskedUserId
        )
        let cnSplitSwitch = SmartDevice(
            id: "\(Self.cn.id)/wall-panel.s2",
            name: "走廊二键开关",
            roomId: Self.cn.id + "/r-cn",
            roomName: "玄关",
            model: "lumi.switch.b2lacn02",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:\(Self.cn.id)/wall-panel:2", isOn: true)),
            accountId: Self.cn.id,
            accountLabel: Self.cn.maskedUserId
        )
        store.devices = [cnLock, cnSplitSwitch, dePlug]

        store.setMiAccountEnabled(false, id: Self.cn.id)
        let commandsBefore = await mock.executedCommands.count

        // Direct gate verdicts distinguish disabled account vs unknown device.
        let disabledGate = store.evaluateDeviceControlGate(deviceId: "cn-lock")
        #expect(!disabledGate.allowed)
        #expect(disabledGate.writeCount == 0)
        #expect(disabledGate.rejectionReason?.userMessage == "该米家账号已停用")

        let missingGate = store.evaluateDeviceControlGate(deviceId: "never-existed")
        #expect(!missingGate.allowed)
        #expect(missingGate.writeCount == 0)
        #expect(missingGate.rejectionReason?.userMessage == "设备不存在")

        // Stale device handle, direct command, split-key command, miot-action, and Raycast entry all reject before confirmation with 0 writes.
        _ = store.togglePrimary(cnLock)
        #expect(confirmationCalls == 0)
        #expect(store.toastNotice?.message == "该米家账号已停用")

        await #expect(throws: CapabilityControlBlockedError(reason: .connectionScopeDisabled(.xiaomiCloud, scope: Self.cn.id))) {
            try await store.executeDeviceCommand(.setSwitch(entityId: "miot:cn-lock:2", isOn: false))
        }
        await #expect(throws: CapabilityControlBlockedError(reason: .connectionScopeDisabled(.xiaomiCloud, scope: Self.cn.id))) {
            try await store.executeDeviceCommand(.setSwitch(entityId: "miot:\(Self.cn.id)/wall-panel:2", isOn: false))
        }
        await #expect(throws: CapabilityControlBlockedError(reason: .connectionScopeDisabled(.xiaomiCloud, scope: Self.cn.id))) {
            try await store.executeDeviceCommand(.pressButton(entityId: "miot-action:cn-lock:2:1"))
        }

        let raycastDisabled = await store.executeRaycastPower(deviceId: "cn-lock", isOn: false)
        #expect(raycastDisabled.isError)
        #expect(raycastDisabled.message == "该米家账号已停用")

        let raycastMissing = await store.executeRaycastPower(deviceId: "never-existed", isOn: false)
        #expect(raycastMissing.isError)
        #expect(raycastMissing.message == "设备不存在")

        #expect(confirmationCalls == 0)
        #expect(await mock.executedCommands.count == commandsBefore)
    }
}
