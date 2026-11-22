import Foundation
import PreferencesTestSupport
import Testing
import KeychainTestSupport
@testable import MijiaCore

/// #143: high-risk manual actions ask again, the screen-lock guard blocks only user paths, and the
/// single revoke action removes every saved credential.
@Suite("Manual control safety (#143)")
struct ManualControlSafetyTests {
    static let light = SmartDevice(
        id: "dev_light", name: "书房灯", roomId: "study", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: false))
    )

    static let plug = SmartDevice(
        id: "dev_plug", name: "书房插座", roomId: "study", roomName: "书房",
        model: "cuco.plug.v3", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.study_plug", isOn: false))
    )

    /// `.climate` whose model marks it as a heater, so `IntentDeviceCategory` reports `.heater`.
    static let heater = SmartDevice(
        id: "dev_heater", name: "电暖器", roomId: "study", roomName: "书房",
        model: "xiaomi.heater.v1", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.heater",
            isOn: false,
            hvacMode: "off",
            availableModes: ["off", "heat"],
            targetTemperature: 22,
            minTemp: 16,
            maxTemp: 30
        ))
    )

    static let waterHeater = SmartDevice(
        id: "dev_water", name: "热水器", roomId: "bath", roomName: "浴室",
        model: "xiaomi.climate.v1", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.water",
            isOn: true,
            hvacMode: "heat",
            availableModes: ["off", "heat"],
            targetTemperature: 50,
            minTemp: 30,
            maxTemp: 75
        ))
    )

    static func cover(_ subtype: CoverSubtype, position: Int = 0) -> SmartDevice {
        SmartDevice(
            id: "cover-\(subtype.rawValue)", name: "测试开合设备", roomId: "bed", roomName: "卧室",
            model: "linp.wopener.wd1lb", isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "miot:wd1:2",
                subtype: subtype,
                positionPercent: position,
                positionWritable: true,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Pause"
            ))
        )
    }

    // MARK: - Pure policy

    @Test("Cover confirmation follows the subtype; an unknown subtype is a window opener")
    func coverConfirmationTable() {
        let rules: [(subtype: CoverSubtype, openConfirms: Bool, closeConfirms: Bool)] = [
            (.curtain, false, false),
            (.windowOpener, true, false),
            (.garageDoor, true, true),
            (.clothesAirer, true, false),
        ]
        for rule in rules {
            let cover = Self.cover(rule.subtype)
            let open = DeviceIntent(targetId: cover.id, operation: .power(true))
            let close = DeviceIntent(targetId: cover.id, operation: .power(false))
            #expect(
                ManualControlPolicy.requiresConfirmation(.power(true), for: cover) == rule.openConfirms,
                "\(rule.subtype) open"
            )
            #expect(
                ManualControlPolicy.requiresConfirmation(.power(false), for: cover) == rule.closeConfirms,
                "\(rule.subtype) close"
            )
            #expect(
                ModelActionPolicy.needsConfirmation(open, devices: [cover]) == rule.openConfirms,
                "\(rule.subtype) model open"
            )
            #expect(
                ModelActionPolicy.needsConfirmation(close, devices: [cover]) == rule.closeConfirms,
                "\(rule.subtype) model close"
            )
        }
        #expect(CoverSubtype(miotServiceShortName: "window-opener") == .windowOpener)
        #expect(CoverSubtype(miotServiceShortName: "unknown-service") == .windowOpener)
        #expect(CoverSubtype(miotServiceShortName: nil) == .windowOpener)
    }

    @Test("A launch-time session fails closed and recognizes locked or unlocked logins")
    func initialSessionLockState() {
        #expect(ScreenLockPolicy.isLocked(session: nil), "No session information must block control")
        #expect(ScreenLockPolicy.isLocked(session: [
            "CGSSessionScreenIsLocked": 1,
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": 1
        ]))
        #expect(!ScreenLockPolicy.isLocked(session: [
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": 1
        ]))
        #expect(ScreenLockPolicy.isLocked(session: [
            "kCGSSessionOnConsoleKey": 0,
            "kCGSessionLoginDoneKey": 1
        ]), "Another user's off-console session must not pass the guard")
        #expect(!ScreenLockPolicy.isLocked(session: [
            "CGSSessionScreenIsLocked": 0,
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": 1
        ]))
    }

    // MARK: - Store behavior

    @MainActor
    private func makeStore(_ devices: [SmartDevice]) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.manualcontrol.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        #expect(store.devices.count == devices.count)
        return (store, mock)
    }

    @Test("A manual plug action asks once, then runs when approved")
    @MainActor
    func manualHazardConfirmationApproved() async throws {
        let (store, mock) = try await makeStore([Self.plug])
        var prompts: [ManualControlConfirmation] = []
        store.manualControlConfirmationHandler = { prompt in
            prompts.append(prompt)
            return true
        }
        let plug = try #require(store.devices.first)
        let task = store.togglePrimary(plug)
        #expect(prompts.count == 1)
        #expect(await task?.value == true)
        let commands = await mock.executedCommands
        #expect(commands.contains(.setSwitch(entityId: "switch.study_plug", isOn: true)))
    }

    @Test("A cancelled hazard confirmation sends no command")
    @MainActor
    func manualHazardConfirmationCancelled() async throws {
        let (store, mock) = try await makeStore([Self.plug])
        store.manualControlConfirmationHandler = { _ in false }
        let plug = try #require(store.devices.first)
        #expect(store.togglePrimary(plug) == nil)
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.toastNotice?.isError == true)
        #expect(store.devices.first?.isActiveOn == false)
    }

    @Test("Low-risk manual actions never ask")
    @MainActor
    func lowRiskIsDirect() async throws {
        let (store, _) = try await makeStore([Self.light])
        var promptCount = 0
        store.manualControlConfirmationHandler = { _ in
            promptCount += 1
            return true
        }
        let light = try #require(store.devices.first)
        #expect(await store.togglePrimary(light)?.value == true)
        #expect(promptCount == 0)
    }

    @Test("A hot-water temperature step asks before changing the setpoint")
    @MainActor
    func detailHazardConfirmation() async throws {
        let (store, _) = try await makeStore([Self.waterHeater])
        store.manualControlConfirmationHandler = { _ in false }
        let before = try #require(store.devices.first)
        store.stepClimateTemperature(before.id, delta: 10)
        #expect(store.devices.first?.kind == before.kind, "A cancelled confirmation must not move the slider")
    }

    @Test("The lock guard blocks user control and clears when the preference is off")
    @MainActor
    func screenLockBlocksUserControl() async throws {
        let (store, _) = try await makeStore([Self.light])
        #expect(store.blockControlWhileLocked, "Safe default: on")
        store.setScreenLocked(true)
        #expect(store.isControlBlockedByScreenLock)

        let light = try #require(store.devices.first)
        #expect(store.togglePrimary(light) == nil)
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)

        store.blockControlWhileLocked = false
        #expect(!store.isControlBlockedByScreenLock)
        #expect(await store.togglePrimary(light)?.value == true)
    }

    @Test("Automation still runs while locked; a direct assistant plan does not")
    @MainActor
    func lockExemptsAutomationOnly() async throws {
        let (store, mock) = try await makeStore([Self.light])
        store.setScreenLocked(true)

        _ = await store.runAutomation(
            intents: [DeviceIntent(targetId: Self.light.id, operation: .power(true))],
            title: "锁屏自动化"
        )
        let commands = await mock.executedCommands
        #expect(commands.contains(.setLightPower(entityId: "light.study", isOn: true)))
        #expect(store.devices.first?.isActiveOn == true)

        _ = await store.executeIntentPlan(
            IntentPlan(
                intents: [DeviceIntent(targetId: Self.light.id, operation: .power(false))],
                reply: "关灯",
                source: .local
            ),
            recordedUtterance: "关灯",
            origin: .userInitiated
        )
        #expect(await mock.executedCommands.count == commands.count, "The locked direct command must send nothing")
        if case .failed(let message) = store.assistantState {
            #expect(message == store.screenLockBlockedMessage)
        } else {
            Issue.record("A blocked assistant command should report the lock message")
        }
    }

    @Test("Sign out and revoke clears Mi sessions, the HA token, AI keys and cloud consent")
    @MainActor
    func revokeAllClearsCredentials() async throws {
        let defaults = InMemoryUserDefaults()
        let session = MiSession(
            userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "token",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        #expect(MiSessionStore.save(session, defaults: defaults))
        KeychainHelper.saveToken("ha-token", defaults: defaults)
        AssistantConfig(
            baseURL: AssistantConfig.defaultBaseURL,
            model: AssistantConfig.defaultModel,
            apiKey: "sk-secret"
        ).save(to: defaults)
        #expect(!KeychainHelper.loadToken(defaults: defaults).isEmpty)
        #expect(!AssistantConfig.load(from: defaults).apiKey.isEmpty)

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.light]))
        let store = HomeStore(provider: mock, defaults: defaults)
        #expect(store.miAccounts.count == 1)

        #expect(store.signOutAndRevokeAll())

        #expect(store.miAccounts.isEmpty)
        #expect(KeychainHelper.loadToken(defaults: defaults).isEmpty)
        #expect(AssistantConfig.load(from: defaults).apiKey.isEmpty)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: AssistantConfig.defaultBaseURL, defaults: defaults).isEmpty)
        #expect(store.toastNotice != nil)
    }

    @Test("A refused keychain delete reports an incomplete revocation")
    @MainActor
    func revokeAllReportsFailure() async throws {
        let seededAccounts = [MiSessionStore.keychainAccount, "ha_access_token"]
            + KeychainHelper.assistantSecretAccounts
        let seeded = try #require(CredentialVault.encode(Dictionary(
            uniqueKeysWithValues: seededAccounts.map { ($0, Data("stored".utf8)) }
        )))
        let storage = MemoryVaultStorage(blob: seeded)
        storage.writeSucceeds = false
        let vault = CredentialVault(storage: storage.storage)
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.light]))
        let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
        store.credentialVault = vault

        #expect(!store.signOutAndRevokeAll(), "A refused delete must not report success")
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message == L10n.tr(
            "部分凭据未能删除，请在钥匙串授权后重试",
            "Some credentials could not be removed. Allow Keychain access and try again."
        ))
    }

    @Test("Undo requires confirmation before restoring high-risk devices and preserves banner when declined")
    @MainActor
    func undoHighRiskRequiresConfirmation() async throws {
        let onLight = SmartDevice(
            id: "dev_light_on",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let plug = SmartDevice(
            id: "plug_heater",
            name: "取暖器插座",
            roomId: "living",
            roomName: "客厅",
            model: "chuangmi.plug.212a01",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: true))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [onLight, plug]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.undo.highrisk.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.setJoinsAllOff(true, deviceId: plug.id)

        _ = await store.turnAllOff()?.value
        #expect(store.devices.first(where: { $0.id == onLight.id })?.isActiveOn == false)
        #expect(store.devices.first(where: { $0.id == plug.id })?.isActiveOn == false)

        store.manualControlConfirmationHandler = { _ in false }
        let mixedUndo = store.undoTurnAllOff()
        await mixedUndo?.value
        #expect(store.devices.first(where: { $0.id == onLight.id })?.isActiveOn == true)
        #expect(store.devices.first(where: { $0.id == plug.id })?.isActiveOn == false)

        _ = await store.runAutomation(
            intents: [DeviceIntent(targetId: plug.id, operation: .power(true))],
            title: "开启插座"
        )
        _ = await store.runAutomation(
            intents: [DeviceIntent(targetId: onLight.id, operation: .power(false))],
            title: "关闭书房灯"
        )
        _ = await store.turnAllOff()?.value
        store.manualControlConfirmationHandler = { _ in false }
        let aborted = store.undoTurnAllOff()
        #expect(aborted == nil)
        #expect(store.undoBanner != nil)
        #expect(store.devices.first(where: { $0.id == plug.id })?.isActiveOn == false)

        store.manualControlConfirmationHandler = { _ in true }
        let approved = store.undoTurnAllOff()
        await approved?.value
        #expect(store.devices.first(where: { $0.id == plug.id })?.isActiveOn == true)
    }

    @Test("The 全关 undo banner is refused while the Mac is locked and stays retryable")
    @MainActor
    func screenLockBlocksUndoBanner() async throws {
        let onLight = SmartDevice(
            id: "dev_light_lock",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let (store, mock) = try await makeStore([onLight])
        _ = await store.turnAllOff()?.value
        #expect(store.undoBanner != nil)
        let commandsAfterAllOff = await mock.executedCommands

        store.setScreenLocked(true)
        // Even a handler that approves every hazard cannot unblock the lock gate: the undo of a
        // control write is itself a user control (#143).
        store.manualControlConfirmationHandler = { _ in true }
        #expect(store.undoTurnAllOff() == nil)
        #expect(store.undoBanner != nil, "A refused undo keeps the banner retryable after unlocking")
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)
        #expect(await mock.executedCommands.count == commandsAfterAllOff.count, "No restore command while locked")

        store.setScreenLocked(false)
        let undo = try #require(store.undoTurnAllOff())
        await undo.value
        #expect(await mock.executedCommands.count == commandsAfterAllOff.count + 1)
        #expect(store.devices.first?.isActiveOn == true)
    }

    @Test("Voice undo is refused while the Mac is locked and stays retryable")
    @MainActor
    func screenLockBlocksVoiceUndo() async throws {
        let onLight = SmartDevice(
            id: "dev_light_lock",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let (store, mock) = try await makeStore([onLight])
        _ = await store.executeIntentPlan(
            IntentPlan(
                intents: [DeviceIntent(targetId: onLight.id, operation: .power(false))],
                reply: "关灯",
                source: .local
            ),
            recordedUtterance: "关灯",
            origin: .userInitiated
        )
        let commandsAfterOff = await mock.executedCommands
        #expect(store.devices.first?.isActiveOn == false)

        store.setScreenLocked(true)
        _ = await store.runAssistantCommand("撤销")
        if case .failed(let message) = store.assistantState {
            #expect(message == store.screenLockBlockedMessage)
        } else {
            Issue.record("A locked voice undo must report the lock message")
        }
        #expect(await mock.executedCommands.count == commandsAfterOff.count, "No restore command while locked")

        store.setScreenLocked(false)
        _ = await store.runAssistantCommand("撤销")
        #expect(store.devices.first?.isActiveOn == true)
        #expect(await mock.executedCommands.count == commandsAfterOff.count + 1)
    }

    @Test("Locking the Mac while undoTurnAllOff waits on an in-flight batch rolls back optimistic restore and keeps undo retryable")
    @MainActor
    func screenLockDuringInFlightUndoBatchRollsBackAndKeepsUndoRetryable() async throws {
        let onLight = SmartDevice(
            id: "dev_light_lock",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let (store, mock) = try await makeStore([onLight])
        store.toastAutoDismissInterval = nil
        await mock.holdNextExecute()

        let batch = store.turnAllOff()
        store.pauseUndoBannerCountdown()
        await waitUntil { await mock.executeStarted == 1 }

        let undo = try #require(store.undoTurnAllOff())
        #expect(store.devices.first?.isActiveOn == true, "Optimistically restored while waiting on the in-flight batch")

        store.setScreenLocked(true)
        await mock.releaseExecute()
        _ = await batch?.value
        await undo.value

        #expect(
            await mock.executedCommands == [.setLightPower(entityId: "light.study", isOn: false)],
            "No restore command may be sent after the Mac locks"
        )
        #expect(store.devices.first?.isActiveOn == false, "Optimistic restore must roll back when send is refused by screen lock")
        #expect(store.optimisticLockUntil.isEmpty, "Failed undo must release its optimistic lock")
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)
        let rearmedBanner = try #require(store.undoBanner, "Refused undo must re-arm the banner for retry after unlock")
        #expect(rearmedBanner.restoreCommands == [.setLightPower(entityId: "light.study", isOn: true)])

        store.setScreenLocked(false)
        let retry = try #require(store.undoTurnAllOff())
        await retry.value
        #expect(store.devices.first?.isActiveOn == true)
        #expect(store.undoBanner == nil)
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.study", isOn: false),
            .setLightPower(entityId: "light.study", isOn: true),
        ])
    }

    @Test("Locking the Mac mid-voice-undo rolls back remaining devices, preserves undo entries, and retries after unlock")
    @MainActor
    func screenLockDuringVoiceUndoRollsBackAndKeepsVoiceUndoRetryable() async throws {
        let studyLight = SmartDevice(
            id: "dev_light_study",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let livingLight = SmartDevice(
            id: "dev_light_living",
            name: "客厅灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let (store, mock) = try await makeStore([studyLight, livingLight])
        store.toastAutoDismissInterval = nil
        _ = await store.executeIntentPlan(
            IntentPlan(
                intents: [
                    DeviceIntent(targetId: studyLight.id, operation: .power(false)),
                    DeviceIntent(targetId: livingLight.id, operation: .power(false)),
                ],
                reply: "已关闭 2 盏灯",
                source: .local
            ),
            recordedUtterance: "关灯",
            origin: .userInitiated
        )
        store.pauseUndoBannerCountdown()
        let startedBeforeUndo = await mock.executeStarted
        await mock.holdNextExecute()

        let voiceUndoTask = Task { @MainActor in
            await store.runAssistantCommand("撤销")
        }
        await waitUntil { await mock.executeStarted > startedBeforeUndo }

        store.setScreenLocked(true)
        await mock.releaseExecute()
        _ = await voiceUndoTask.value

        // The first restore command was already in flight before lock; the second must be refused,
        // rolled back, and kept in lastAssistantUndo (and undoBanner) for retry after unlocking.
        let executedAfterLockedUndo = await mock.executedCommands
        #expect(executedAfterLockedUndo.count == 3)
        let firstRestoredDeviceId = executedAfterLockedUndo.last == .setLightPower(entityId: "light.living", isOn: true)
            ? livingLight.id
            : studyLight.id
        let refusedDeviceId = firstRestoredDeviceId == livingLight.id ? studyLight.id : livingLight.id
        let refusedEntityId = refusedDeviceId == livingLight.id ? "light.living" : "light.study"

        #expect(store.devices.first(where: { $0.id == firstRestoredDeviceId })?.isActiveOn == true)
        #expect(store.devices.first(where: { $0.id == refusedDeviceId })?.isActiveOn == false)
        #expect(store.optimisticLockUntil[refusedDeviceId] == nil)
        #expect(store.assistantState == .failed(store.screenLockBlockedMessage))
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)
        #expect(store.lastAssistantUndo?.restore == [.setLightPower(entityId: refusedEntityId, isOn: true)])
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: refusedEntityId, isOn: true)])

        store.setScreenLocked(false)
        _ = await store.runAssistantCommand("撤销")
        #expect(store.devices.allSatisfy { $0.isActiveOn })
        #expect(store.lastAssistantUndo == nil)
        #expect(await mock.executedCommands.count == 4)
    }

    @Test("When banner and voice undo belong to different actions, a failed voice undo leaves the banner untouched")
    @MainActor
    func failedVoiceUndoDoesNotOverwriteIndependentBannerUndo() async throws {
        let studyLight = SmartDevice(
            id: "dev_light_study",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let livingLight = SmartDevice(
            id: "dev_light_living",
            name: "客厅灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let (store, mock) = try await makeStore([studyLight, livingLight])
        store.toastAutoDismissInterval = nil

        _ = await store.executeIntentPlan(
            IntentPlan(
                intents: [DeviceIntent(targetId: studyLight.id, operation: .power(false))],
                reply: "已关闭书房灯",
                source: .local
            ),
            recordedUtterance: "关闭书房灯",
            origin: .userInitiated
        )
        #expect(store.undoBanner == nil)

        _ = await store.turnAllOff()?.value
        store.pauseUndoBannerCountdown()
        let bannerBefore = try #require(store.undoBanner)
        #expect(bannerBefore.isAllOff)
        #expect(bannerBefore.restoreCommands == [.setLightPower(entityId: "light.living", isOn: true)])

        await mock.setFailingTargets(["light.study"])
        _ = await store.runAssistantCommand("撤销")

        #expect(store.lastAssistantUndo?.reply == "已关闭书房灯")
        #expect(store.lastAssistantUndo?.restore == [.setLightPower(entityId: "light.study", isOn: true)])
        #expect(store.undoBanner == bannerBefore)

        await mock.setFailingTargets([])
        let bannerUndo = try #require(store.undoTurnAllOff())
        await bannerUndo.value
        #expect(store.devices.first(where: { $0.id == livingLight.id })?.isActiveOn == true)
        #expect(store.devices.first(where: { $0.id == studyLight.id })?.isActiveOn == false)
        #expect(store.lastAssistantUndo?.restore == [.setLightPower(entityId: "light.study", isOn: true)])

        _ = await store.runAssistantCommand("撤销")
        #expect(store.devices.allSatisfy { $0.isActiveOn })
        #expect(store.lastAssistantUndo == nil)
    }

    @Test("When banner and voice undo belong to different actions, a failed banner undo leaves the voice undo untouched")
    @MainActor
    func failedBannerUndoDoesNotOverwriteIndependentVoiceUndo() async throws {
        let studyLight = SmartDevice(
            id: "dev_light_study",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let livingLight = SmartDevice(
            id: "dev_light_living",
            name: "客厅灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let (store, mock) = try await makeStore([studyLight, livingLight])
        store.toastAutoDismissInterval = nil

        _ = await store.executeIntentPlan(
            IntentPlan(
                intents: [DeviceIntent(targetId: studyLight.id, operation: .power(false))],
                reply: "已关闭书房灯",
                source: .local
            ),
            recordedUtterance: "关闭书房灯",
            origin: .userInitiated
        )
        let voiceAtBefore = try #require(store.lastAssistantUndo?.at)

        _ = await store.turnAllOff()?.value
        store.pauseUndoBannerCountdown()

        await mock.setFailingTargets(["light.living"])
        let failedBannerUndo = try #require(store.undoTurnAllOff())
        await failedBannerUndo.value
        store.pauseUndoBannerCountdown()

        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.living", isOn: true)])
        #expect(store.undoBanner?.isAllOff == true)
        #expect(store.lastAssistantUndo?.reply == "已关闭书房灯")
        #expect(store.lastAssistantUndo?.restore == [.setLightPower(entityId: "light.study", isOn: true)])
        #expect(store.lastAssistantUndo?.at == voiceAtBefore)

        await mock.setFailingTargets([])
        _ = await store.runAssistantCommand("撤销")
        #expect(store.devices.first(where: { $0.id == studyLight.id })?.isActiveOn == true)
        #expect(store.devices.first(where: { $0.id == livingLight.id })?.isActiveOn == false)
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.living", isOn: true)])

        let retryBanner = try #require(store.undoTurnAllOff())
        await retryBanner.value
        #expect(store.devices.allSatisfy { $0.isActiveOn })
        #expect(store.undoBanner == nil)
    }

    @Test("Partial failure on a shared action keeps only failed commands on both entry points and never resends succeeded ones")
    @MainActor
    func partialUndoOfSharedActionKeepsOnlyFailedCommandsOnBothEntries() async throws {
        let studyLight = SmartDevice(
            id: "dev_light_study",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let livingLight = SmartDevice(
            id: "dev_light_living",
            name: "客厅灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let (store, mock) = try await makeStore([studyLight, livingLight])
        store.toastAutoDismissInterval = nil

        let turnBothOffPlan = IntentPlan(
            intents: [
                DeviceIntent(targetId: studyLight.id, operation: .power(false)),
                DeviceIntent(targetId: livingLight.id, operation: .power(false)),
            ],
            reply: "已关闭 2 盏灯",
            source: .local
        )

        // Direction 1: Banner undo partially fails -> both entry points hold only the failed command -> voice retry finishes without resending.
        _ = await store.executeIntentPlan(turnBothOffPlan, recordedUtterance: "关灯", origin: .userInitiated)
        store.pauseUndoBannerCountdown()
        #expect(store.undoBanner?.actionId == store.lastAssistantUndo?.actionId)

        await mock.setFailingTargets(["light.study"])
        let partialBannerUndo = try #require(store.undoTurnAllOff())
        await partialBannerUndo.value
        store.pauseUndoBannerCountdown()

        #expect(store.devices.first(where: { $0.id == livingLight.id })?.isActiveOn == true)
        #expect(store.devices.first(where: { $0.id == studyLight.id })?.isActiveOn == false)
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.study", isOn: true)])
        #expect(store.lastAssistantUndo?.restore == [.setLightPower(entityId: "light.study", isOn: true)])
        #expect(store.undoBanner?.actionId == store.lastAssistantUndo?.actionId)
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.study", isOn: false),
            .setLightPower(entityId: "light.living", isOn: false),
            .setLightPower(entityId: "light.living", isOn: true),
        ])

        await mock.setFailingTargets([])
        _ = await store.runAssistantCommand("撤销")
        #expect(store.devices.allSatisfy { $0.isActiveOn })
        #expect(store.lastAssistantUndo == nil)
        #expect(store.undoBanner == nil)
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.study", isOn: false),
            .setLightPower(entityId: "light.living", isOn: false),
            .setLightPower(entityId: "light.living", isOn: true),
            .setLightPower(entityId: "light.study", isOn: true),
        ])

        // Direction 2: Voice undo partially fails -> both entry points hold only the failed command -> banner retry finishes without resending.
        _ = await store.executeIntentPlan(turnBothOffPlan, recordedUtterance: "关灯", origin: .userInitiated)
        store.pauseUndoBannerCountdown()

        await mock.setFailingTargets(["light.living"])
        _ = await store.runAssistantCommand("撤销")
        store.pauseUndoBannerCountdown()

        #expect(store.devices.first(where: { $0.id == studyLight.id })?.isActiveOn == true)
        #expect(store.devices.first(where: { $0.id == livingLight.id })?.isActiveOn == false)
        #expect(store.lastAssistantUndo?.restore == [.setLightPower(entityId: "light.living", isOn: true)])
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.living", isOn: true)])
        #expect(store.undoBanner?.actionId == store.lastAssistantUndo?.actionId)

        await mock.setFailingTargets([])
        let retryBanner = try #require(store.undoTurnAllOff())
        await retryBanner.value
        #expect(store.devices.allSatisfy { $0.isActiveOn })
        #expect(store.undoBanner == nil)
        #expect(store.lastAssistantUndo == nil)
        #expect(await mock.executedCommands == [
            .setLightPower(entityId: "light.study", isOn: false),
            .setLightPower(entityId: "light.living", isOn: false),
            .setLightPower(entityId: "light.living", isOn: true),
            .setLightPower(entityId: "light.study", isOn: true),
            .setLightPower(entityId: "light.study", isOn: false),
            .setLightPower(entityId: "light.living", isOn: false),
            .setLightPower(entityId: "light.study", isOn: true),
            .setLightPower(entityId: "light.living", isOn: true),
        ])
    }

    @Test("Screen lock with zero commands sent restores pre-undo state and keeps both entry points retryable")
    @MainActor
    func screenLockBeforeAnySendPreservesBothUndoEntryPointsForRetry() async throws {
        let studyLight = SmartDevice(
            id: "dev_light_study",
            name: "书房灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let livingLight = SmartDevice(
            id: "dev_light_living",
            name: "客厅灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let heaterPlug = SmartDevice(
            id: "dev_plug_heater",
            name: "取暖插座",
            roomId: "living",
            roomName: "客厅",
            model: "chuangmi.plug.212a01",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: true))
        )

        // Case 1: Independent actions — mid-wait lock before any restore command is sent keeps both independent entries retryable.
        do {
            let (store, mock) = try await makeStore([studyLight, livingLight])
            store.toastAutoDismissInterval = nil

            _ = await store.executeIntentPlan(
                IntentPlan(
                    intents: [DeviceIntent(targetId: studyLight.id, operation: .power(false))],
                    reply: "已关闭书房灯",
                    source: .local
                ),
                recordedUtterance: "关闭书房灯",
                origin: .userInitiated
            )
            let voiceBefore = try #require(store.lastAssistantUndo)

            let startedBeforeAllOff = await mock.executeStarted
            await mock.holdNextExecute()
            let batch = store.turnAllOff()
            store.pauseUndoBannerCountdown()
            await waitUntil { await mock.executeStarted > startedBeforeAllOff }

            let undo = try #require(store.undoTurnAllOff())
            store.setScreenLocked(true)
            await mock.releaseExecute()
            _ = await batch?.value
            await undo.value
            store.pauseUndoBannerCountdown()

            #expect(await mock.executedCommands == [
                .setLightPower(entityId: "light.study", isOn: false),
                .setLightPower(entityId: "light.living", isOn: false),
            ])
            #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.living", isOn: true)])
            #expect(store.lastAssistantUndo == voiceBefore)

            store.setScreenLocked(false)
            let retryBanner = try #require(store.undoTurnAllOff())
            await retryBanner.value
            #expect(store.devices.first(where: { $0.id == livingLight.id })?.isActiveOn == true)
            #expect(store.devices.first(where: { $0.id == studyLight.id })?.isActiveOn == false)

            _ = await store.runAssistantCommand("撤销")
            #expect(store.devices.allSatisfy { $0.isActiveOn })
            #expect(store.lastAssistantUndo == nil)
        }

        // Case 2: Shared action — lock arriving after confirmation but before the first restore command restores both entries verbatim.
        do {
            let (store, mock) = try await makeStore([studyLight, heaterPlug])
            store.toastAutoDismissInterval = nil

            _ = await store.executeIntentPlan(
                IntentPlan(
                    intents: [
                        DeviceIntent(targetId: studyLight.id, operation: .power(false)),
                        DeviceIntent(targetId: heaterPlug.id, operation: .power(false)),
                    ],
                    reply: "已关闭 2 台设备",
                    source: .local
                ),
                recordedUtterance: "全关",
                origin: .userInitiated
            )
            store.pauseUndoBannerCountdown()
            let voiceBefore = try #require(store.lastAssistantUndo)
            let bannerBefore = try #require(store.undoBanner)

            store.manualControlConfirmationHandler = { _ in
                store.setScreenLocked(true)
                return true
            }
            _ = await store.runAssistantCommand("撤销")
            store.pauseUndoBannerCountdown()

            #expect(await mock.executedCommands.count == 2, "Zero restore commands may be sent once the Mac locks")
            #expect(store.devices.allSatisfy { !$0.isActiveOn })
            #expect(store.lastAssistantUndo == voiceBefore)
            #expect(store.undoBanner?.actionId == bannerBefore.actionId)
            #expect(store.undoBanner?.restoreCommands == bannerBefore.restoreCommands)
            #expect(store.undoBanner?.previousDevices == bannerBefore.previousDevices)
            #expect(store.undoBanner?.deviceCount == bannerBefore.deviceCount)

            store.setScreenLocked(false)
            store.manualControlConfirmationHandler = { _ in true }
            let retryBanner = try #require(store.undoTurnAllOff())
            await retryBanner.value
            #expect(store.devices.allSatisfy { $0.isActiveOn })
            #expect(store.undoBanner == nil)
            #expect(store.lastAssistantUndo == nil)
            #expect(await mock.executedCommands.count == 4)
        }
    }

    @Test("Speaker directive commands require confirmation and return false when cancelled while TTS succeeds directly")
    @MainActor
    func speakerDirectiveConfirmation() async throws {
        let speaker = SmartDevice(
            id: "sp_pro",
            name: "客厅小爱",
            roomId: "living",
            roomName: "客厅",
            model: "xiaomi.wifispeaker.l17a",
            isOnline: true,
            kind: .speaker(SpeakerSpec(
                mediaEntityId: "miot:sp_pro:2",
                state: "idle",
                volumePercent: 35,
                isMuted: false,
                muteSwitchEntityId: "miot:sp_pro:2",
                sleepModeEntityId: nil,
                isSleepMode: false,
                ttsNotifyEntityId: "miot-action:sp_pro:7:3",
                directiveNotifyEntityId: "miot-action:sp_pro:7:4",
                volumeWritable: true
            ))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [speaker]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.speaker.directive.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()

        store.manualControlConfirmationHandler = { _ in false }
        #expect(!store.sendSpeakerText(speaker.id, text: "打开所有设备", asDirective: true))
        #expect(await mock.executedCommands.isEmpty)

        #expect(store.sendSpeakerText(speaker.id, text: "开饭了", asDirective: false))
        let deadline1 = ContinuousClock.now + .seconds(2)
        while await mock.executedCommands.count < 1, ContinuousClock.now < deadline1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await mock.executedCommands.count == 1)

        store.manualControlConfirmationHandler = { _ in true }
        #expect(store.sendSpeakerText(speaker.id, text: "关闭书房灯", asDirective: true))
        let deadline2 = ContinuousClock.now + .seconds(2)
        while await mock.executedCommands.count < 2, ContinuousClock.now < deadline2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await mock.executedCommands.count == 2)
    }
}
