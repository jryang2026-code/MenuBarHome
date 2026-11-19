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

// MARK: - 6. Review follow-ups: scope migration, revalidation durability, authority & UI contracts

@MainActor
struct MiAccountDisableTestsReview {
    private static let cn = MiAccountDisableFixture.cn
    private static let de = MiAccountDisableFixture.de

    private static func makeSuite() -> String {
        "com.jryang1997.MenuBarMijia.mi-disable-review.\(UUID().uuidString)"
    }

    private static func makeStore(
        suite: String, vault: CredentialVault, provider: (any HomeProvider)? = nil
    ) -> HomeStore {
        HomeStore(provider: provider ?? MockHomeProvider(), defaultsSuiteName: suite, credentialVault: vault)
    }

    private static func seedAccounts(_ defaults: UserDefaults, _ vault: CredentialVault) {
        MiSessionStore.saveAccounts([cn, de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
    }

    private static func selectionJSON(_ defaults: UserDefaults) throws -> [String: Any] {
        let data = try #require(defaults.data(forKey: CapabilitySelectionStore.storageKey))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func indexedLight(id: String, name: String, accountId: String?) -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: "\(Self.cn.id)/r",
            roomName: "客厅",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:\(id):2", isOn: true)),
            accountId: accountId,
            accountLabel: accountId == nil ? nil : "米家账号"
        )
    }

    // MARK: H1 – Home Assistant address migration

    @Test("Accepting a new Home Assistant address keeps Home Assistant enabled")
    func haAddressChangeKeepsConnectionEnabled() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let store = Self.makeStore(suite: suite, vault: vault)

        store.hasHASource = true
        store.serverURLString = "http://192.168.1.10:8123"
        #expect(store.isHAConnectionEnabled)

        store.serverURLString = "http://192.168.1.20:8123"
        #expect(store.isHAConnectionEnabled)
        #expect(store.activeConnectionScopes.contains("ha:http://192.168.1.20:8123"))
        #expect(!store.activeConnectionScopes.contains("ha:http://192.168.1.10:8123"))

        let json = try Self.selectionJSON(defaults)
        let disabledScopes = Set(json["disabledConnectionScopes"] as? [String] ?? [])
        #expect(!disabledScopes.contains("ha:http://192.168.1.20:8123"))
        #expect(!disabledScopes.contains("ha:http://192.168.1.10:8123"))
    }

    @Test("A disabled Home Assistant connection never records its new address as an explicitly disabled scope")
    func haAddressChangeDoesNotRecordDisabledScope() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedAccounts(defaults, vault)
        CapabilitySelectionStore.save(
            selection: CapabilitySelection(
                enabledConnections: [.xiaomiCloud],
                enabledConnectionScopes: [Self.cn.id, Self.de.id],
                enabledFeatures: Set(FeatureID.allCases),
                enabledCategories: Set(DeviceCategoryID.allCases)
            ),
            configuredScopes: [Self.cn.id, Self.de.id],
            explicitlyDisabledConnections: [.homeAssistant],
            defaults: defaults
        )

        let store = Self.makeStore(suite: suite, vault: vault)
        store.hasHASource = true
        store.serverURLString = "http://192.168.1.10:8123"
        store.serverURLString = "http://192.168.1.20:8123"
        // Any unrelated write (a newly configured account) must not turn the new address into a
        // disabled-scope marker: the connection-level decision already covers it.
        store.registerNewlyConfiguredScope(Self.de.id, connection: .xiaomiCloud)

        let disabledScopes = Set(try Self.selectionJSON(defaults)["disabledConnectionScopes"] as? [String] ?? [])
        #expect(!disabledScopes.contains("ha:http://192.168.1.20:8123"))
    }

    // MARK: H2 – Revalidation survives re-login, removal and relaunch

    @Test("A QR login that re-enables a disabled account queues the paused references for revalidation")
    func reloginQueuesRevalidation() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)
        defer { store.logoutMiAccount() }

        #expect(store.setMiAccountEnabled(false, id: Self.cn.id).disposition == .allowed)
        #expect(!store.isMiAccountEnabled(Self.cn.id))

        store.completeMiLogin(MiAccountDisableFixture.cnSession)

        #expect(store.isMiAccountEnabled(Self.cn.id))
        #expect(store.pendingRevalidationScopes.contains(Self.cn.id))
    }

    @Test("Removing an account releases the timers it paused instead of leaving them paused forever")
    func removingAccountReleasesPausedTimers() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)

        let deLight = Self.indexedLight(id: "de-light", name: "书房灯", accountId: Self.de.id)
        store.devices = [deLight]
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭书房灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "de-light", operation: .power(false))],
                reply: "关闭书房灯", source: .local
            ),
            sourceScope: Self.de.id,
            sourceScopes: [Self.de.id]
        )
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands()
        #expect(store.scheduledCommands.count == 1)

        let disabled = store.setMiAccountEnabled(
            false, id: Self.de.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration
        )
        #expect(disabled.disposition == .requiresPauseConfirmation)
        #expect(store.pausedScheduledCommands.count == 1)

        store.logoutMiAccount(id: Self.de.id)
        #expect(store.pausedScheduledCommands.isEmpty)
    }

    @Test("A relaunch rebuilds pending revalidation from the persisted pause markers and resumes after a fresh snapshot")
    func relaunchRevalidatesPausedItems() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let light = Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [light]
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭客厅灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))],
                reply: "关闭客厅灯", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id]
        )
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands()
        store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(store.pausedScheduledCommands.count == 1)

        // The account was re-enabled but the app quit before the fresh snapshot arrived.
        var selection = store.capabilitySelection
        selection.enabledConnections.insert(.xiaomiCloud)
        selection.enabledConnectionScopes.insert(Self.cn.id)
        CapabilitySelectionStore.save(
            selection: selection, configuredScopes: [Self.cn.id],
            explicitlyDisabledConnections: [], removingScopes: [], defaults: defaults
        )

        let relaunched = Self.makeStore(suite: suite, vault: vault)
        #expect(relaunched.isMiAccountEnabled(Self.cn.id))
        #expect(relaunched.pausedScheduledCommands.count == 1)
        #expect(relaunched.pendingRevalidationScopes.contains(Self.cn.id))

        var snapshot = SynthesizedHome(rooms: [], devices: [light], environmentReadings: [], scenes: [])
        snapshot.isInitialLoadComplete = true
        snapshot.freshAccountIds = [Self.cn.id]
        snapshot.miAccountsEpoch = relaunched.miAccountsConfigEpoch
        snapshot.accountStatuses = [Self.cn.id: .connected]
        relaunched.reconcileReenabledScopesAfterSnapshot(snapshot)

        #expect(relaunched.pendingRevalidationScopes.isEmpty)
        #expect(relaunched.pausedScheduledCommands.isEmpty)
        #expect(relaunched.scheduledCommands.map(\.id) == [timer.id])
    }

    @Test("A queued Home Assistant scope completes on its first complete snapshot")
    func haScopeRevalidationCompletes() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.hasHASource = true
        store.serverURLString = "http://192.168.1.10:8123"
        store.pendingRevalidationScopes = [store.homeAssistantScopeIdentifier]

        var snapshot = SynthesizedHome(rooms: [], devices: [], environmentReadings: [], scenes: [])
        snapshot.isInitialLoadComplete = true
        // A Mi provider is present, so Mi freshness stamps exist; the HA scope must not wait on them.
        snapshot.miAccountsEpoch = store.miAccountsConfigEpoch
        store.reconcileReenabledScopesAfterSnapshot(snapshot)

        #expect(store.pendingRevalidationScopes.isEmpty)
    }

    // MARK: H3 – Only a connected, authoritative snapshot may resolve a pause

    @Test("Reconciliation ignores a scope whose account is still disconnected")
    func reconciliationRequiresConnectedScope() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let light = Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [light]
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭客厅灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))],
                reply: "关闭客厅灯", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id]
        )
        store.pausedScheduledCommands = [PausedScheduledCommand(
            command: timer, originalPartition: .waiting, pausedCapabilities: [.connection(.xiaomiCloud)]
        )]
        store.pendingRevalidationScopes = [Self.cn.id]

        var snapshot = SynthesizedHome(rooms: [], devices: [], environmentReadings: [], scenes: [])
        snapshot.isInitialLoadComplete = true
        snapshot.freshAccountIds = [Self.cn.id]
        snapshot.miAccountsEpoch = store.miAccountsConfigEpoch
        snapshot.accountStatuses = [Self.cn.id: .disconnected("登录已过期")]
        store.reconcileReenabledScopesAfterSnapshot(snapshot)

        #expect(store.pendingRevalidationScopes.contains(Self.cn.id))
        #expect(store.pausedScheduledCommands.count == 1)
        #expect(store.scheduledCommands.isEmpty)
    }

    @Test("A paused timer waits for its own account to be fresh again")
    func pausedTimerWaitsForItsOwnAccount() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)
        let deLight = Self.indexedLight(id: "de-light", name: "书房灯", accountId: Self.de.id)
        store.devices = [deLight]
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭书房灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "de-light", operation: .power(false))],
                reply: "关闭书房灯", source: .local
            ),
            sourceScope: Self.de.id,
            sourceScopes: [Self.de.id]
        )
        store.pausedScheduledCommands = [PausedScheduledCommand(
            command: timer, originalPartition: .waiting, pausedCapabilities: [.connection(.xiaomiCloud)]
        )]

        // A still-disabled account keeps its timer paused instead of partitioning it away as foreign.
        store.setMiAccountEnabled(
            false, id: Self.de.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration
        )
        #expect(!store.isMiAccountEnabled(Self.de.id))
        store.pendingRevalidationScopes = []
        store.revalidatePausedItems()
        #expect(store.pausedScheduledCommands.count == 1)
        #expect(store.foreignScheduledCommands.isEmpty)

        // Re-enabled but not fresh yet: a fresh snapshot from the other account must not move it.
        var selection = store.capabilitySelection
        selection.enabledConnectionScopes.insert(Self.de.id)
        store.capabilitySelection = selection
        store.pendingRevalidationScopes = [Self.cn.id, Self.de.id]

        var snapshot = SynthesizedHome(rooms: [], devices: [], environmentReadings: [], scenes: [])
        snapshot.isInitialLoadComplete = true
        snapshot.miAccountsEpoch = store.miAccountsConfigEpoch
        snapshot.freshAccountIds = [Self.cn.id]
        snapshot.accountStatuses = [Self.cn.id: .connected, Self.de.id: .disconnected("登录已过期")]
        store.reconcileReenabledScopesAfterSnapshot(snapshot)

        #expect(store.pendingRevalidationScopes == [Self.de.id])
        #expect(store.pausedScheduledCommands.count == 1)
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.foreignScheduledCommands.isEmpty)
    }

    @Test("A timer paused for a visible account resumes while another account is only hidden by the selected home")
    func hiddenAccountDoesNotFreezeVisibleTimers() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)]

        // Timers stamp every source connected at creation; only the scope that was actually lost
        // belongs in the pause marker.
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭客厅灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))],
                reply: "关闭客厅灯", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id, Self.de.id]
        )
        store.pausedScheduledCommands = [PausedScheduledCommand(
            command: timer, originalPartition: .waiting,
            pausedCapabilities: [.connection(.xiaomiCloud)], pausedScopes: [Self.cn.id]
        )]
        store.selectedMiHomeId = Self.cn.id + "/home-cn"
        store.pendingRevalidationScopes = [Self.de.id]

        store.revalidatePausedItems()

        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(store.scheduledCommands.map(\.id) == [timer.id])
        // The hidden account keeps its own pending work for when its devices are visible again.
        #expect(store.pendingRevalidationScopes == [Self.de.id])
    }

    @Test("A paused quick action waits only for the scopes it lost")
    func pausedQuickActionWaitsForItsOwnScopes() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)]
        store.selectedMiHomeId = Self.de.id + "/home-de"

        // Paused for the visible account while the other account is only hidden and pending: resume.
        store.pausedQuickActionIDs = ["lightsOff"]
        store.pausedQuickActionScopes = ["lightsOff": [Self.cn.id]]
        store.pendingRevalidationScopes = [Self.de.id]
        store.revalidatePausedItems()
        #expect(!store.pausedQuickActionIDs.contains("lightsOff"))
        #expect(!store.pausedQuickActionScopes.keys.contains("lightsOff"))

        // Paused for the hidden account: no fresh, visible snapshot can prove its lights are back.
        store.pausedQuickActionIDs = ["lightsOff"]
        store.pausedQuickActionScopes = ["lightsOff": [Self.de.id]]
        store.revalidatePausedItems()
        #expect(store.pausedQuickActionIDs.contains("lightsOff"))
        #expect(store.pausedQuickActionScopes["lightsOff"] == [Self.de.id])
    }

    @Test("Another account's selected home delays revalidation instead of pruning the hidden account")
    func selectedHomeDelaysRevalidation() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)]
        store.selectedMiHomeId = Self.de.id + "/home-de"
        store.pendingRevalidationScopes = [Self.cn.id]

        var snapshot = SynthesizedHome(rooms: [], devices: [], environmentReadings: [], scenes: [])
        snapshot.isInitialLoadComplete = true
        snapshot.miAccountsEpoch = store.miAccountsConfigEpoch
        snapshot.freshAccountIds = [Self.cn.id]
        snapshot.accountStatuses = [Self.cn.id: .connected]
        store.reconcileReenabledScopesAfterSnapshot(snapshot)

        #expect(store.pendingRevalidationScopes.contains(Self.cn.id))
        #expect(store.indexedDevicesById["cn-light"] != nil)

        // The account's own selected home filters out its other homes too: still not an inventory.
        store.selectedMiHomeId = Self.cn.id + "/home-cn"
        store.reconcileReenabledScopesAfterSnapshot(snapshot)
        #expect(store.pendingRevalidationScopes.contains(Self.cn.id))
        #expect(store.indexedDevicesById["cn-light"] != nil)
    }

    @Test("A non-authoritative snapshot never clears a paused rule's markers")
    func nonAuthoritativeSnapshotKeepsPausedRuleMarkers() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let ruleStore = AutomationRuleStore(defaults: defaults)
        let rule = AutomationRule(trigger: .away, action: .devices(ids: ["cn-light"], isOn: false), isEnabled: false)
        ruleStore.save([rule])
        var paused = try #require(ruleStore.load().first)
        paused.pausedCapabilities = [.connection(.xiaomiCloud)]
        paused.pausedScopes = [Self.cn.id]
        ruleStore.save([paused])

        let store = Self.makeStore(suite: suite, vault: vault)
        store.hasReceivedInitialSnapshot = true
        store.miAccountStatuses = [Self.cn.id: .disconnected("登录已过期")]

        store.revalidatePausedItems()
        let stillPaused = try #require(ruleStore.load().first)
        #expect(!stillPaused.pausedCapabilities.isEmpty)
        #expect(stillPaused.pausedScopes == [Self.cn.id])

        // The same state with a connected account is authoritative: the target really is gone. A
        // launch-rebuilt pending scope is cleared by the snapshot reconciliation itself.
        store.miAccountStatuses = [Self.cn.id: .connected]
        store.pendingRevalidationScopes = []
        store.revalidatePausedItems()
        let resolved = try #require(ruleStore.load().first)
        #expect(!resolved.isEnabled)
        #expect(resolved.pausedCapabilities.isEmpty)
    }

    // MARK: H4 – Credential fallback keeps the explicit disables

    @Test("An unreadable credential slot in fallback mode still keeps a disabled account off")
    func fallbackKeepsExplicitAccountDisable() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        CapabilitySelectionStore.save(
            selection: CapabilitySelection(
                enabledConnections: [.xiaomiCloud],
                enabledConnectionScopes: [Self.de.id],
                enabledFeatures: Set(FeatureID.allCases),
                enabledCategories: Set(DeviceCategoryID.allCases)
            ),
            configuredScopes: [Self.cn.id, Self.de.id],
            explicitlyDisabledConnections: [],
            defaults: defaults
        )

        mem.readResult = .unavailable
        let unavailableVault = CredentialVault(storage: mem.storage)
        let store = HomeStore(
            provider: nil, defaultsSuiteName: suite, credentialVault: unavailableVault,
            miAccountsProviderFactory: { accounts in
                MiAccountsProvider(accounts: accounts, specSource: StubSpecSource(), pollInterval: .seconds(60))
            }
        )
        defer { store.logoutMiAccount() }

        #expect(store.capabilityResolutionMode == .uncertainFallback)
        // The vault becomes readable later in the same session; loading the accounts must honour the
        // disable the user stored, not re-enable A because the resolver fell back.
        store.miAccounts = [Self.cn, Self.de]
        #expect(!store.isMiAccountEnabled(Self.cn.id))
        #expect(store.isMiAccountEnabled(Self.de.id))
    }

    // MARK: M1 – Paused timers are visible and cancellable

    @Test("Cancelling every timer includes the paused ones")
    func cancelAllIncludesPausedTimers() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)]
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭客厅灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))],
                reply: "关闭客厅灯", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id]
        )
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands()
        store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(store.pausedScheduledCommands.count == 1)

        #expect(store.cancelScheduledCommands() == 1)
        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(PausedScheduledCommand.load(from: defaults).isEmpty)
    }

    // MARK: M2 – Atomic commit

    @Test("A refused selection write leaves nothing paused")
    func refusedSelectionWriteLeavesNothingPaused() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)]
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭客厅灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))],
                reply: "关闭客厅灯", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id]
        )
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands()
        #expect(store.scheduledTasks.count == 1)

        defaults.set(Data("{not-valid-json".utf8), forKey: CapabilitySelectionStore.storageKey)
        let verdict = store.setMiAccountEnabled(
            false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration
        )

        #expect(verdict.disposition == .blocked)
        #expect(store.isMiAccountEnabled(Self.cn.id))
        #expect(store.pausedScheduledCommands.isEmpty)
        #expect(store.scheduledCommands.count == 1)
        #expect(store.scheduledTasks.count == 1)
    }

    // MARK: M3 – Confirmation must match the previewed list

    @Test("A confirmation whose pause list changed re-previews instead of pausing a different set")
    func changedPauseListRepreviews() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)]
        let preview = store.previewSetMiAccountEnabled(false, id: Self.cn.id)
        #expect(preview.disposition == .requiresPauseConfirmation)
        let confirmedKeys = Set(preview.itemsToPause.map(\.pauseKey))
        #expect(!confirmedKeys.isEmpty)

        // A new timer appears after the preview was shown, without changing the capability generation.
        let late = ScheduledCommand(
            reply: "5 分钟后关闭客厅灯",
            fireDate: Date().addingTimeInterval(300),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: "cn-light", operation: .power(false))],
                reply: "关闭客厅灯", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id]
        )
        ScheduledCommand.save([late], to: defaults)
        store.scheduledCommands = [late]

        let verdict = store.setMiAccountEnabled(
            false, id: Self.cn.id, pauseConfirmed: true,
            expectedGeneration: store.capabilityGeneration, expectedPauseItemKeys: confirmedKeys
        )
        #expect(verdict.disposition == .requiresPauseConfirmation)
        #expect(store.isMiAccountEnabled(Self.cn.id))
        #expect(store.pausedScheduledCommands.isEmpty)
    }

    // MARK: M4 – Custom groups are not quick actions

    @Test("Custom layout groups are not quick actions and damaged group data never blocks a disable")
    func customGroupsAreNotQuickActions() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [
            Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id),
            Self.indexedLight(id: "cn-light-2", name: "阳台灯", accountId: Self.cn.id),
        ]
        defaults.set("[{\"id\":\"grp-living\",\"name\":\"客厅灯组\"}]", forKey: "device_groups")
        defaults.set("{\"cn-light\":\"grp-living\",\"cn-light-2\":\"grp-living\"}", forKey: ViewPreferenceKeys.groupMap)

        let preview = store.previewSetMiAccountEnabled(false, id: Self.cn.id)
        #expect(!preview.itemsToPause.contains { $0.id.hasPrefix("group:") })

        defaults.set("{broken", forKey: "device_groups")
        defaults.set("not-json", forKey: ViewPreferenceKeys.groupMap)
        let withBrokenGroups = store.previewSetMiAccountEnabled(false, id: Self.cn.id)
        #expect(withBrokenGroups.disposition != .blocked)
    }

    // MARK: M5 – A paused rule waits for its own scope

    @Test("A rule paused for one account is not resumed by re-enabling a different account")
    func pausedRuleWaitsForItsOwnScope() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)

        let store = Self.makeStore(suite: suite, vault: vault)
        let cnLight = Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)
        let dePlug = SmartDevice(
            id: "de-plug", name: "书房插座", roomId: "\(Self.de.id)/r", roomName: "书房",
            model: "cuco.plug.v3", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:de-plug:2", isOn: false)),
            accountId: Self.de.id, accountLabel: "米家账号"
        )
        store.devices = [cnLight, dePlug]

        let ruleStore = AutomationRuleStore(defaults: defaults)
        ruleStore.save([AutomationRule(trigger: .away, action: .devices(ids: ["cn-light"], isOn: false))])

        let paused = store.setMiAccountEnabled(
            false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration
        )
        #expect(paused.disposition == .requiresPauseConfirmation)
        let afterPause = try #require(ruleStore.load().first)
        #expect(!afterPause.isEnabled)
        #expect(afterPause.pausedScopes == [Self.cn.id])

        // B is disabled and re-enabled while the rule's own account stays off.
        store.setMiAccountEnabled(false, id: Self.de.id)
        store.setMiAccountEnabled(true, id: Self.de.id)
        #expect(try #require(ruleStore.load().first).isEnabled == false)
        #expect(try #require(ruleStore.load().first).pausedScopes == [Self.cn.id])

        store.setMiAccountEnabled(true, id: Self.cn.id)
        #expect(try #require(ruleStore.load().first).isEnabled == true)
    }

    @Test("Pausing a valid rule keeps an automation entry that no longer decodes")
    func pausingRulesPreservesUndecodableEntries() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)]

        let valid = AutomationRule(trigger: .away, action: .devices(ids: ["cn-light"], isOn: false))
        let validJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        let unreadable: [String: Any] = ["id": UUID().uuidString, "trigger": "renamed-trigger", "action": [:]]
        defaults.set(
            try JSONSerialization.data(withJSONObject: [validJSON, unreadable]),
            forKey: AutomationRuleStore.storageKey
        )
        #expect(AutomationRuleStore(defaults: defaults).load().count == 1)

        let verdict = store.setMiAccountEnabled(
            false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration
        )
        #expect(verdict.disposition == .requiresPauseConfirmation)

        let storedData = try #require(defaults.data(forKey: AutomationRuleStore.storageKey))
        let raw = try #require(try JSONSerialization.jsonObject(with: storedData) as? [Any])
        #expect(raw.count == 2)
        #expect(raw.contains { ($0 as? [String: Any])?["trigger"] as? String == "renamed-trigger" })
    }

    // MARK: M6 – Pure LG timers are exempt

    @Test("A timer whose targets are all LG LAN cards survives disabling the last Xiaomi account")
    func pureLGTimerSurvivesLastAccountDisable() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭电视",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: LGWebOSProtocol.deviceId, operation: .power(false))],
                reply: "关闭电视", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id]
        )
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands()
        #expect(store.scheduledCommands.count == 1)

        store.setMiAccountEnabled(false, id: Self.cn.id)

        #expect(store.scheduledCommands.map(\.id) == [timer.id])
        #expect(store.foreignScheduledCommands.isEmpty)
    }

    @Test("A missed LG-only timer still runs after the last Xiaomi account is turned off")
    func missedLGTimerRunsAfterDisable() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let mock = MockHomeProvider()
        let store = HomeStore(provider: mock, defaultsSuiteName: suite, credentialVault: vault)
        let tv = SmartDevice(
            id: LGWebOSProtocol.deviceId, name: "LG 电视", roomId: "ke_ting", roomName: "客厅",
            model: "lg.webos", isOnline: true,
            kind: .tv(TVSpec(mediaEntityId: LGWebOSProtocol.mediaEntityId, state: "on", volumePercent: 12))
        )
        store.devices = [tv]
        let missed = ScheduledCommand(
            reply: "关闭电视",
            fireDate: Date().addingTimeInterval(-60),
            plan: IntentPlan(
                intents: [DeviceIntent(targetId: LGWebOSProtocol.deviceId, operation: .power(false))],
                reply: "关闭电视", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id]
        )
        ScheduledCommand.save([missed], to: defaults)
        store.restoreScheduledCommands()
        #expect(store.missedScheduledCommands.map(\.id) == [missed.id])

        store.setMiAccountEnabled(false, id: Self.cn.id)
        #expect(store.missedScheduledCommands.map(\.id) == [missed.id])

        let ran = await store.runMissedScheduledCommand(id: missed.id)
        #expect(ran != nil)
        #expect(store.missedScheduledCommands.isEmpty)
        #expect(!(await mock.executedCommands.isEmpty))
    }

    @Test("Disabling a Xiaomi account keeps the cards Home Assistant drives")
    func disableKeepsHAPairedCards() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)

        let paired = Self.indexedLight(id: "paired-light", name: "走廊灯", accountId: Self.cn.id)
        var home = SynthesizedHome(rooms: [], devices: [paired], environmentReadings: [], scenes: [])
        home.deviceBackends = ["paired-light": .homeAssistant]
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: suite, credentialVault: vault)
        // A Home Assistant-winning card only exists while Home Assistant is configured.
        store.hasHASource = true
        store.serverURLString = "http://192.168.1.10:8123"
        try await store.waitForTestSnapshot()
        #expect(store.deviceBackends["paired-light"] == .homeAssistant)

        store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(store.devices.map(\.id) == ["paired-light"])

        // Later snapshots keep the Home Assistant row even though its copied account id is off.
        await mock.updateSnapshot(home)
        await waitUntil { store.devices.map(\.id) == ["paired-light"] }
        #expect(store.devices.map(\.id) == ["paired-light"])
    }

    @Test("Disabling a second account extends the pause markers of an already paused rule")
    func secondDisableExtendsPausedScopes() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [
            Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id),
            Self.indexedLight(id: "de-light", name: "书房灯", accountId: Self.de.id),
        ]
        let ruleStore = AutomationRuleStore(defaults: defaults)
        ruleStore.save([AutomationRule(trigger: .away, action: .devices(ids: ["cn-light", "de-light"], isOn: false))])

        store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(try #require(ruleStore.load().first).pausedScopes == [Self.cn.id])

        // The second account takes away the rule's remaining targets; its pause markers must grow.
        let preview = store.previewSetMiAccountEnabled(false, id: Self.de.id)
        #expect(preview.disposition == .requiresPauseConfirmation)
        #expect(preview.itemsToPause.contains { $0.kind == .automationRule })
        store.setMiAccountEnabled(false, id: Self.de.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(try #require(ruleStore.load().first).pausedScopes == [Self.cn.id, Self.de.id].sorted())

        store.setMiAccountEnabled(true, id: Self.cn.id)
        #expect(try #require(ruleStore.load().first).isEnabled == false)

        store.setMiAccountEnabled(true, id: Self.de.id)
        #expect(try #require(ruleStore.load().first).isEnabled == true)
    }

    @Test("Disabling a second account extends the pause markers of an already paused timer")
    func secondDisableExtendsPausedTimers() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)
        store.devices = [
            Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id),
            Self.indexedLight(id: "de-light", name: "书房灯", accountId: Self.de.id),
        ]
        let timer = ScheduledCommand(
            reply: "10 分钟后关闭两盏灯",
            fireDate: Date().addingTimeInterval(600),
            plan: IntentPlan(
                intents: [
                    DeviceIntent(targetId: "cn-light", operation: .power(false)),
                    DeviceIntent(targetId: "de-light", operation: .power(false)),
                ],
                reply: "关闭两盏灯", source: .local
            ),
            sourceScope: Self.cn.id,
            sourceScopes: [Self.cn.id, Self.de.id]
        )
        ScheduledCommand.save([timer], to: defaults)
        store.restoreScheduledCommands()

        store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        let afterFirst = try #require(store.pausedScheduledCommands.first)
        #expect(afterFirst.pausedScopes == [Self.cn.id])

        // The second disable must grow the marker instead of leaving it pinned to the first account.
        store.setMiAccountEnabled(false, id: Self.de.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        let afterSecond = try #require(store.pausedScheduledCommands.first)
        #expect(afterSecond.pausedScopes == [Self.cn.id, Self.de.id].sorted())

        store.setMiAccountEnabled(true, id: Self.cn.id)
        #expect(store.pausedScheduledCommands.count == 1)
        #expect(store.scheduledCommands.isEmpty)

        store.setMiAccountEnabled(true, id: Self.de.id)
        #expect(store.pausedScheduledCommands.isEmpty)
    }

    @Test("Re-adding an account revalidates the paused quick actions it left behind")
    func readdedAccountRevalidatesQuickActions() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let store = Self.makeStore(suite: suite, vault: vault)
        let light = Self.indexedLight(id: "cn-light", name: "客厅灯", accountId: Self.cn.id)
        store.devices = [light]

        store.setMiAccountEnabled(false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration)
        #expect(store.pausedQuickActionIDs.contains("lightsOff"))
        store.logoutMiAccount(id: Self.cn.id)
        #expect(store.pausedQuickActionIDs.contains("lightsOff"))

        _ = MiSessionStore.upsert(MiAccountDisableFixture.cnSession, defaults: defaults, vault: vault)
        store.miAccounts = MiSessionStore.loadAccounts(defaults: defaults, vault: vault)
        store.registerNewlyConfiguredScope(Self.cn.id, connection: .xiaomiCloud)
        #expect(store.pendingRevalidationScopes.contains(Self.cn.id))

        store.devices = [light]
        var snapshot = SynthesizedHome(rooms: [], devices: [light], environmentReadings: [], scenes: [])
        snapshot.isInitialLoadComplete = true
        snapshot.freshAccountIds = [Self.cn.id]
        snapshot.miAccountsEpoch = store.miAccountsConfigEpoch
        snapshot.accountStatuses = [Self.cn.id: .connected]
        store.reconcileReenabledScopesAfterSnapshot(snapshot)

        #expect(!store.pausedQuickActionIDs.contains("lightsOff"))
    }

    @Test("A row naming an account this Mac does not have is not blocked by the capability gate")
    func unknownAccountRowStaysControllable() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        #expect(MiSessionStore.loadAccounts(defaults: defaults, vault: vault).isEmpty)

        let mock = MockHomeProvider()
        let store = HomeStore(provider: mock, defaultsSuiteName: suite, credentialVault: vault)
        let stale = SmartDevice(
            id: "stale-light", name: "旧账号灯", roomId: "r", roomName: "客厅",
            model: "yeelink.light.ceiling22", isOnline: true,
            kind: .light(LightSpec(entityId: "miot:stale-light:2", isOn: true)),
            accountId: "acc-not-on-this-mac"
        )
        store.devices = [stale]

        let task = try #require(store.togglePrimary(stale), "an unconfigured account is not a capability the host turned off")
        _ = await task.value
        #expect(await mock.executedCommands.count == 1)
    }

    // MARK: L1 – All accounts turned off is not "not configured"

    @Test("Turning off the only Xiaomi account reports a turned-off connection, not an unconfigured home")
    func allAccountsOffIsNotUnconfigured() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        store.setMiAccountEnabled(false, id: Self.cn.id)

        #expect(store.panelHealth != .notConfigured)
        if case .blocked = store.panelHealth {} else {
            Issue.record("expected a blocked health verdict, got \(store.panelHealth)")
        }
    }

    // MARK: Review comments – backend, suppression and write gate

    @Test("A paired device resolves through the backend that actually drives it")
    func pairedDeviceUsesWinningBackend() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let store = Self.makeStore(suite: suite, vault: vault)

        store.hasHASource = true
        let paired = Self.indexedLight(id: "paired-light", name: "走廊灯", accountId: Self.cn.id)
        store.devices = [paired]
        store.deviceBackends = ["paired-light": .homeAssistant]

        let (connection, scope) = store.inferSource(for: paired)
        #expect(connection == .homeAssistant)
        #expect(scope == store.homeAssistantScopeIdentifier)
    }

    @Test("Disabling an account drops its rows even when they carry no account id")
    func disableDropsRowsWithoutAccountId() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults, vault: vault)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")

        let store = Self.makeStore(suite: suite, vault: vault)
        // Its owner is only known through the index (the first enabled account).
        let anonymous = Self.indexedLight(id: "cn-anon", name: "玄关门厅灯", accountId: nil)
        store.deviceBackends = ["cn-anon": .xiaomiCloud]
        store.devices = [anonymous]
        #expect(store.indexedDevicesById["cn-anon"]?.sourceScope == Self.cn.id)

        store.setMiAccountEnabled(
            false, id: Self.cn.id, pauseConfirmed: true, expectedGeneration: store.capabilityGeneration
        )

        #expect(!store.devices.contains { $0.id == "cn-anon" })
    }

    @Test("The write gate blocks a live row whose persisted index entry is missing")
    func writeGateCoversLiveRowWithoutIndexEntry() async throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        Self.seedAccounts(defaults, vault)
        let mock = MockHomeProvider()
        let store = HomeStore(provider: mock, defaultsSuiteName: suite, credentialVault: vault)

        let lock = SmartDevice(
            id: "cn-lock", name: "入户门锁", roomId: "\(Self.cn.id)/r", roomName: "玄关",
            model: "xiaomi.lock.pro", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:cn-lock:2", isOn: true)),
            accountId: Self.cn.id, accountLabel: "米家账号"
        )
        store.devices = [lock]
        store.indexedDevicesById.removeValue(forKey: "cn-lock")
        var selection = store.capabilitySelection
        selection.enabledConnectionScopes.remove(Self.cn.id)
        store.capabilitySelection = selection

        await #expect(throws: CapabilityControlBlockedError.self) {
            try await store.executeDeviceCommand(.setSwitch(entityId: "miot:cn-lock:2", isOn: false))
        }
        #expect(await mock.executedCommands.isEmpty)
    }
}

/// Shared fixture values so the review tests can reuse the primary test suite's sessions.
@MainActor
enum MiAccountDisableFixture {
    static let cnSession = MiSession(
        userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn"
    )
    static let deSession = MiSession(
        userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de"
    )
    static let cn = MiAccount(session: cnSession)
    static let de = MiAccount(session: deSession)
}
