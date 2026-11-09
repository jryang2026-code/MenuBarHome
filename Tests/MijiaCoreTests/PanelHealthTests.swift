import Foundation
import Testing
@testable import MijiaCore

/// Connection health, error-toast lifetime, and the expired-session write refusal (UX-01, UX-09, UX-22).
@MainActor
struct PanelHealthTests {
    private let expiredAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let farEnd = Date(timeIntervalSince1970: 4_000_000_000)

    @Test("panelHealth tells expired-only Mi, expired-with-HA, declined plaintext, demo and no source apart")
    func truthTable() async throws {
        let expiredOnly = try await makeStore(backend: .xiaomiCloud, session: expiredSession())
        let expiredWithHA = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), haSource: true)
        let declined = try await makeStore()
        declined.haPlaintextPrompt = .declined("http://203.0.113.5:8123")
        let demo = try await makeStore(backend: .demo)
        let noSource = try await makeStore()
        let stale = try await makeStore(haSource: true)
        stale.deviceValuesAreStale = true
        let miAndDeclined = try await makeStore(backend: .xiaomiCloud, session: validSession())
        miAndDeclined.haPlaintextPrompt = .declined("http://203.0.113.5:8123")

        try await L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(expiredOnly.miSessionBlocksControl)
            #expect(health(expiredOnly) == .blocked(
                reason: "米家登录已过期 · 点此扫码",
                action: .presentMiReauth
            ))

            #expect(expiredWithHA.miSessionShowsExpired)
            #expect(!expiredWithHA.miSessionBlocksControl)
            #expect(health(expiredWithHA) == .degraded(reason: "米家登录已过期，Home Assistant 仍可用"))

            #expect(health(declined) == .blocked(
                reason: "Home Assistant 未连接（已拒绝明文）",
                action: .openConnectionSettings
            ))
            #expect(health(miAndDeclined) == .degraded(reason: "Home Assistant 未连接（已拒绝明文）"))

            #expect(health(demo) == .ok)
            #expect(noSource.hasHASource == false)
            #expect(noSource.hasMiSource == false)
            #expect(noSource.connectionStatus == .connected)
            #expect(health(noSource) == .notConfigured)
            #expect(health(stale) == .degraded(reason: "设备状态可能过期"))
        }

        try await L10n.$overrideLanguage.withValue(.en) {
            #expect(health(declined) == .blocked(
                reason: "Home Assistant is not connected (plaintext declined)",
                action: .openConnectionSettings
            ))
        }
    }

    @Test("An error toast waits 8 seconds, a success toast 2.8, and a persistent toast does not auto-dismiss")
    func toastLifetimes() async throws {
        let store = try await makeStore()
        let success = ToastNotice(message: "saved")
        let failure = ToastNotice(message: "failed", isError: true)
        let pinned = ToastNotice(message: "stay", isError: true, persistent: true)

        #expect(store.toastDismissInterval(for: success) == .seconds(2.8))
        #expect(store.toastDismissInterval(for: success) == HomeStore.successToastDismissInterval)
        #expect(store.toastDismissInterval(for: failure) == HomeStore.errorToastDismissInterval)
        #expect(HomeStore.errorToastDismissInterval == .seconds(8))
        #expect(store.toastDismissInterval(for: pinned) == nil)

        store.showToast("saved")
        #expect(store.toastNotice?.message == "saved")
        #expect(store.toastNotice?.isError == false)
        #expect(store.activeToastDismissInterval == .seconds(2.8))

        store.showToast("failed", isError: true)
        #expect(store.toastNotice?.isError == true)
        #expect(store.activeToastDismissInterval == .seconds(8))

        store.showToast("stay", isError: true, action: ToastAction(title: "扫码", kind: .presentMiReauth), persistent: true)
        #expect(store.toastNotice?.persistent == true)
        #expect(store.toastNotice?.action?.title == "扫码")
        #expect(store.activeToastDismissInterval == nil)

        store.toastAutoDismissInterval = nil
        store.showToast("frozen", isError: true)
        #expect(store.toastNotice?.message == "frozen")
        #expect(store.activeToastDismissInterval == nil)
    }

    @Test("Tapping a card while the Mi session blocks control sends no provider command")
    func blockedSessionSendsNoCommand() async throws {
        let provider = MockHomeProvider(snapshot: Self.lampHome)
        let blocked = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), provider: provider)
        let allowedProvider = MockHomeProvider(snapshot: Self.lampHome)
        let allowed = try await makeStore(provider: allowedProvider)

        let device = try #require(blocked.devices.first { $0.id == "lamp" })
        #expect(blocked.miSessionBlocksControl)
        let refused = blocked.togglePrimary(device)
        #expect(refused == nil)
        await Task.yield()
        let blockedCommands = await provider.executedCommands
        #expect(blockedCommands.isEmpty)
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            blocked.togglePrimary(device)
            #expect(blocked.toastNotice?.message == "米家登录已过期")
            #expect(blocked.toastNotice?.persistent == true)
            #expect(blocked.toastNotice?.action == ToastAction(title: "扫码", kind: .presentMiReauth))
            let shown = blocked.toastNotice?.id
            blocked.togglePrimary(device)
            #expect(blocked.toastNotice?.id == shown)
        }

        let openDevice = try #require(allowed.devices.first { $0.id == "lamp" })
        #expect(!allowed.miSessionBlocksControl)
        allowed.readBackEchoDelay = .milliseconds(1)
        let sent = allowed.togglePrimary(openDevice)
        let task = try #require(sent)
        _ = await task.value
        let allowedCommands = await allowedProvider.executedCommands
        #expect(!allowedCommands.isEmpty)
    }

    @Test("All Off names the devices it will turn off and the ones it leaves out")
    func allOffCopy() async throws {
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let narrow = AllOffHeaderCopy.make(
                activeDeviceCount: 4, targetNames: ["台灯"], scopeName: nil, excludedIncludesPlug: true
            )
            #expect(narrow.title == "全关 1 台")
            #expect(narrow.helper == "全关不含插座等 3 台")
            #expect(narrow.tooltip == "按住 0.6 秒关闭：台灯")

            let matched = AllOffHeaderCopy.make(
                activeDeviceCount: 1, targetNames: ["台灯"], scopeName: nil, excludedIncludesPlug: false
            )
            #expect(matched.helper == nil)

            let room = AllOffHeaderCopy.make(
                activeDeviceCount: 2, targetNames: ["台灯"], scopeName: "书房", excludedIncludesPlug: false
            )
            #expect(room.title == "全关 书房 1 台")
            #expect(room.helper == "全关不含这 1 台")

            let names = ["一", "二", "三", "四", "五", "六"]
            let listed = AllOffHeaderCopy.make(
                activeDeviceCount: 6, targetNames: names, scopeName: nil, excludedIncludesPlug: true
            )
            #expect(listed.tooltip == "按住 0.6 秒关闭：一、二、三、四、五 等")
            #expect(!listed.tooltip.contains("六"))
        }
        try await L10n.$overrideLanguage.withValue(.en) {
            let room = AllOffHeaderCopy.make(
                activeDeviceCount: 2, targetNames: ["Desk"], scopeName: "Study", excludedIncludesPlug: false
            )
            #expect(room.title == "All Off 1 in Study")
        }
    }

    @Test("A blocked Mi session sends no quick action, undo, assistant, safety, or URL command")
    func blockedSessionStopsEveryWriteEntry() async throws {
        let provider = MockHomeProvider(snapshot: Self.lampHome)
        let store = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), provider: provider)
        #expect(store.miSessionBlocksControl)
        let lampOn = store.devices.first { $0.id == "lamp" }?.isActiveOn

        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let quick = try #require(store.executeQuickAction(.lightsOff))
            await quick.value
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.toastNotice?.message == "米家登录已过期")
            #expect(store.toastNotice?.persistent == true)
            #expect(store.toastNotice?.action == ToastAction(title: "扫码", kind: .presentMiReauth))
            #expect(store.devices.first { $0.id == "lamp" }?.isActiveOn == lampOn)

            store.undoBanner = UndoBanner(
                title: "已关闭 1 台",
                restoreCommands: [.setLightPower(entityId: "light.lamp", isOn: false)],
                previousDevices: store.devices,
                deviceCount: 1,
                isAllOff: true
            )
            #expect(store.undoTurnAllOff() == nil)
            #expect(store.undoBanner != nil)
            #expect(store.devices.first { $0.id == "lamp" }?.isActiveOn == lampOn)
            #expect(await provider.executedCommands.isEmpty)

            _ = await store.runAssistantCommand("关灯")
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.toastNotice?.message == "米家登录已过期")

            let scope = try #require(store.connectionScopeIdentifier)
            let alert = SafetyAlert(
                id: "longrun:lamp",
                deviceId: "lamp",
                title: "台灯开着",
                body: "关闭",
                turnOffCommand: .setLightPower(entityId: "light.lamp", isOn: false)
            )
            if let safety = store.executeSafetyAlertAction(alert, deliveredInScope: scope) {
                await safety.value
            }
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.toastNotice?.message == "米家登录已过期")
            #expect(store.toastNotice?.isError == true)

            let url = await store.executeBuiltInURLScene(.allOff)
            #expect(url.isError)
            #expect(url.message == "米家登录已过期")
            let quickURL = await store.executeBuiltInURLScene(.lightsOff)
            #expect(quickURL.isError, "a refused quick action is not the success title it captured")
            #expect(quickURL.message == "米家登录已过期")
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("One expired Mi account beside a live one does not claim Home Assistant still works")
    func partialMiExpiryNamesTheOtherAccount() async throws {
        let suite = "com.jryang1997.MenuBarMijia.panel-health.partial.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let saved = MiSessionStore.saveAccounts([
            MiAccount(session: MiSession(
                userId: "1111111111", cUserId: "c1", ssecurity: "s", serviceToken: "t1", expiresAt: expiredAt
            )),
            MiAccount(session: MiSession(
                userId: "2222222222", cUserId: "c2", ssecurity: "s", serviceToken: "t2", expiresAt: farEnd
            ))
        ], defaults: defaults)
        #expect(saved)
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        #expect(store.miSessionShowsExpired)
        #expect(!store.miSessionBlocksControl)
        #expect(!store.hasHASource)

        try await L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "有米家账号已过期，其他账号仍保持登录"))
            store.connectionStatus = .connecting
            #expect(store.panelHealth == .degraded(reason: "有米家账号已过期，其他账号仍保持登录"))
        }

        let ha = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), haSource: true)
        ha.connectionStatus = .connecting
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(ha.panelHealth == .connecting)
        }
        ha.connectionStatus = .connected
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(ha.panelHealth == .degraded(reason: "米家登录已过期，Home Assistant 仍可用"))
        }
    }

    @Test("All Off exclusion follows the visible room and mentions plugs only when a plug is left out")
    func allOffExclusionFollowsTheFilter() async throws {
        let studyLight = SmartDevice(
            id: "study-light", name: "书房灯", roomId: "study", roomName: "书房",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let studyPlug = SmartDevice(
            id: "study-plug", name: "插座", roomId: "study", roomName: "书房",
            model: "chuangmi.plug.v3", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.study", isOn: true))
        )
        let studyCamera = SmartDevice(
            id: "study-cam", name: "摄像机", roomId: "study", roomName: "书房",
            model: "chuangmi.camera", isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.study", isOn: true))
        )
        let otherLight = SmartDevice(
            id: "bed-light", name: "床头灯", roomId: "bed", roomName: "主卧",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.bed", isOn: true))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "study", name: "书房", sortOrder: 0), RoomArea(id: "bed", name: "主卧", sortOrder: 1)],
            devices: [studyLight, studyPlug, otherLight]
        ))
        let store = try await makeStore(provider: provider)
        store.listCut = .room("study")
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let copy = store.allOffHeaderCopy(scopeName: "书房")
            #expect(copy.title == "全关 书房 1 台")
            #expect(copy.helper == "全关不含插座等 1 台")
        }

        let cameraProvider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "study", name: "书房", sortOrder: 0)],
            devices: [studyLight, studyCamera]
        ))
        let cameraStore = try await makeStore(provider: cameraProvider)
        try await L10n.$overrideLanguage.withValue(.zhHans) {
            let copy = cameraStore.allOffHeaderCopy(scopeName: nil)
            #expect(copy.helper == "全关不含这 1 台")
            #expect(copy.helper?.contains("插座") == false)
        }
    }

    @Test("An expired Mi session still controls a LAN LG TV; the Mi light stays refused")
    func blockedSessionDoesNotBlockLGViaLAN() async throws {
        let lgTV = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: "LG C2 电视",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "lg.webos.oled42c2pca",
            isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: LGWebOSProtocol.mediaEntityId,
                state: "standby",
                volumePercent: 18,
                currentSource: "HDMI 1",
                availableSources: ["HDMI 1", "HDMI 2"]
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [
            lgTV,
            try #require(Self.lampHome.devices.first),
        ]))
        let store = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), provider: provider)
        store.lgWebOSClient = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: false),
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )
        #expect(store.miSessionBlocksControl)

        try await L10n.$overrideLanguage.withValue(.zhHans) {
            // The card tap is answered over the LAN: no expiry toast, nothing sent to the provider.
            let tv = try #require(store.devices.first { $0.id == LGWebOSProtocol.deviceId })
            let task = try #require(store.togglePrimary(tv))
            #expect(await task.value)
            #expect(store.toastNotice == nil)
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.devices.first { $0.id == LGWebOSProtocol.deviceId }?.isActiveOn == true)

            // The drawer's own LAN controls pass the same gate (`controllableDevice`).
            store.grokBallCelebrationUntil = nil
            store.toggleTVMute(LGWebOSProtocol.deviceId)
            for _ in 0..<500 {
                if store.grokBallCelebrationUntil != nil { break }
                await Task.yield()
            }
            #expect(store.grokBallCelebrationUntil != nil)
            #expect(store.toastNotice == nil)
            if case .tv(let spec)? = store.devices.first(where: { $0.id == LGWebOSProtocol.deviceId })?.kind {
                #expect(spec.isMuted)
            } else {
                Issue.record("the LG TV row is missing")
            }

            // A Mi light still sends nothing and explains the expired session.
            let lamp = try #require(store.devices.first { $0.id == "lamp" })
            #expect(store.togglePrimary(lamp) == nil)
            #expect(store.toastNotice?.message == "米家登录已过期")
            #expect(store.toastNotice?.persistent == true)
            #expect(store.toastNotice?.action == ToastAction(title: "扫码", kind: .presentMiReauth))
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("A blocked toggle leaves no optimistic lock or fake row on a cover")
    func blockedCoverToggleLeavesNoLock() async throws {
        let cover = SmartDevice(
            id: "curtain",
            name: "窗帘",
            roomId: "room",
            roomName: "书房",
            model: "lumi.curtain",
            isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.curtain",
                subtype: .curtain,
                positionPercent: 0,
                positionWritable: true,
                openDescription: "open",
                closeDescription: "close"
            ))
        )
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [cover]))
        )
        #expect(store.miSessionBlocksControl)
        let row = try #require(store.devices.first)
        #expect(store.togglePrimary(row) == nil)
        #expect(store.optimisticLockUntil[cover.id] == nil, "a refused tap takes no row lock")
        #expect(store.devices.first == cover, "a refused tap shows no fake row")
        #expect(store.toastNotice?.message == "米家登录已过期")
    }

    @Test("All Off of only LAN TVs runs while every Mi session is expired")
    func blockedSessionAllowsLGOnlyAllOff() async throws {
        let lgTV = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: "LG C2 电视",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "lg.webos.oled42c2pca",
            isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: LGWebOSProtocol.mediaEntityId,
                state: "on",
                volumePercent: 18
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lgTV]))
        let store = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), provider: provider)
        store.lgWebOSClient = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: false),
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )
        #expect(store.miSessionBlocksControl)

        let task = try #require(store.turnAllOff(), "an all-LAN 全关 does not need the Mi session")
        await task.value
        #expect(store.toastNotice == nil)
        #expect(await provider.executedCommands.isEmpty)
        #expect(store.devices.first { $0.id == LGWebOSProtocol.deviceId }?.isActiveOn == false)
        #expect(store.undoBanner != nil)
    }

    @Test("All Off with no device on is a result, not an error")
    func allOffWithNothingOnIsNotAnError() async throws {
        let store = try await makeStore()
        await L10n.$overrideLanguage.withValue(.zhHans) {
            let result = await store.executeBuiltInURLScene(.allOff)
            #expect(result.message == "当前没有开启的设备")
            #expect(!result.isError)
        }
    }

    @Test("An All Off link reports the expiry that stops its batch midway")
    func allOffURLReportsMidBatchExpiry() async throws {
        let provider = MockHomeProvider(snapshot: Self.twoLampHome)
        let store = try await makeStore(backend: .xiaomiCloud, session: validSession(), provider: provider)
        #expect(!store.miSessionBlocksControl)

        await provider.holdNextExecute(forTarget: "light.a")
        let link = Task { await store.executeBuiltInURLScene(.allOff) }
        for _ in 0..<1_000 {
            if await provider.executeStarted >= 1 { break }
            await Task.yield()
        }
        #expect(await provider.executeStarted == 1)

        // The session expires while the first command is in flight.
        store.miSessionExpiresAt = expiredAt
        store.miAccounts = [MiAccount(session: expiredSession())]
        #expect(store.miSessionBlocksControl)
        await provider.releaseExecute()

        await L10n.$overrideLanguage.withValue(.zhHans) {
            let result = await link.value
            #expect(result.isError)
            #expect(result.message == "米家登录已过期", "the link must not report the success banner it captured first")
        }
        // The accepted device did switch off, so its row and its undo entry stay. The refused one
        // goes back and leaves the banner.
        #expect(store.devices.first { $0.id == "lamp-a" }?.isActiveOn == false)
        #expect(store.devices.first { $0.id == "lamp-b" }?.isActiveOn == true)
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.a", isOn: true)])
        #expect(store.undoBanner?.deviceCount == 1)
        #expect(store.toastNotice?.message == "米家登录已过期")
        #expect(store.toastNotice?.persistent == true)
    }

    @Test("A mixed LG and Mi 全关 sends the LAN TV and refuses only the Mi row")
    func mixedLGAAndMiAllOffSendsLG() async throws {
        let lgTV = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: "LG C2 电视",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "lg.webos.oled42c2pca",
            isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: LGWebOSProtocol.mediaEntityId,
                state: "on",
                volumePercent: 18
            ))
        )
        let lamp = try #require(Self.lampHome.devices.first)
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lgTV, lamp]))
        let store = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), provider: provider)
        store.lgWebOSClient = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: false),
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )
        #expect(store.miSessionBlocksControl)

        let task = try #require(store.turnAllOff(), "a mixed batch sends its LAN targets")
        let outcome = await task.value
        #expect(outcome == .refusedByMiSession)
        #expect(await provider.executedCommands.isEmpty, "the Mi light is refused, not sent")
        #expect(store.devices.first { $0.id == LGWebOSProtocol.deviceId }?.isActiveOn == false)
        #expect(store.devices.first { $0.id == "lamp" }?.isActiveOn == true)
        #expect(store.undoBanner?.restoreCommands == [
            .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true),
        ])
        #expect(store.toastNotice?.message == "米家登录已过期")
        #expect(store.toastNotice?.persistent == true)
    }

    @Test("A batch with a refusal and a real failure shows the failure, then restores the scan toast")
    func batchRefusalAndFailureRestoresScanToast() async throws {
        let provider = MockHomeProvider(snapshot: Self.twoLampHome)
        let store = try await makeStore(backend: .xiaomiCloud, session: validSession(), provider: provider)
        #expect(!store.miSessionBlocksControl)

        await provider.holdNextExecute(forTarget: "light.a")
        await provider.setFailingTargets(["light.a"])
        let allOff = try #require(store.turnAllOff())
        for _ in 0..<1_000 {
            if await provider.executeStarted >= 1 { break }
            await Task.yield()
        }
        #expect(await provider.executeStarted == 1)
        store.miSessionExpiresAt = expiredAt
        store.miAccounts = [MiAccount(session: expiredSession())]
        await provider.releaseExecute()

        let outcome = await allOff.value
        #expect(outcome == .refusedByMiSession)
        #expect(store.undoBanner == nil, "neither device accepted a command")
        // The real failure is shown, the expiry prompt waits behind it, then comes back.
        #expect(store.toastNotice?.message.contains("未完成") == true)
        #expect(store.toastNotice?.persistent == false)
        store.dismissToast()
        #expect(store.toastNotice?.message == "米家登录已过期")
        #expect(store.toastNotice?.persistent == true)
        #expect(store.toastNotice?.action == ToastAction(title: "扫码", kind: .presentMiReauth))
    }

    @Test("An ordinary toast shows normally again once the session is valid")
    func ordinaryToastReturnsAfterSessionRecovers() async throws {
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: Self.lampHome)
        )
        #expect(store.rejectWritesBlockedByMiSession())
        #expect(store.toastNotice?.persistent == true)

        // The user signed in again.
        store.miSessionExpiresAt = farEnd
        store.miAccounts = [MiAccount(session: validSession())]
        #expect(!store.miSessionBlocksControl)

        store.showToast("已保存")
        #expect(store.toastNotice?.message == "已保存")
        #expect(store.toastNotice?.persistent == false)
    }

    @Test("A batch whose row a newer write took reports partial")
    func takenOverBatchReportsPartial() async throws {
        let provider = MockHomeProvider(snapshot: Self.twoLampHome)
        let store = try await makeStore(backend: .xiaomiCloud, session: validSession(), provider: provider)

        await provider.holdNextExecute(forTarget: "light.a")
        let allOff = try #require(store.turnAllOff())
        for _ in 0..<1_000 {
            if await provider.executeStarted >= 1 { break }
            await Task.yield()
        }
        #expect(await provider.executeStarted == 1)

        // The user moves the second lamp while the batch is still on the first one: this takes the
        // row at a newer revision, so the queued off command must not overwrite it.
        store.controlDebounceInterval = .milliseconds(1)
        store.setLightBrightness("lamp-b", percent: 30)
        await provider.releaseExecute()

        #expect(await allOff.value == .partial, "a taken-over row means the action was not fully applied")
        #expect(store.devices.first { $0.id == "lamp-a" }?.isActiveOn == false)
        #expect(store.devices.first { $0.id == "lamp-b" }?.isActiveOn == true)
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.a", isOn: true)])
    }

    @Test("Two Mi accounts, one expired, keep a declined HA prompt degraded")
    func declinedPlaintextWithAnotherMiAccountStaysDegraded() async throws {
        let suite = "com.jryang1997.MenuBarMijia.panel-health.declined-partial.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let saved = MiSessionStore.saveAccounts([
            MiAccount(session: MiSession(
                userId: "1111111111", cUserId: "c1", ssecurity: "s", serviceToken: "t1", expiresAt: expiredAt
            )),
            MiAccount(session: MiSession(
                userId: "2222222222", cUserId: "c2", ssecurity: "s", serviceToken: "t2", expiresAt: farEnd
            )),
        ], defaults: defaults)
        #expect(saved)
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.hasHASource = true
        store.haPlaintextPrompt = .declined("http://203.0.113.5:8123")
        #expect(store.miSessionShowsExpired)
        #expect(!store.miSessionBlocksControl)

        try await L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "Home Assistant 未连接（已拒绝明文）"))
        }
    }

    @Test("A mixed undo sends the LAN restore and keeps the refused Mi restore in the banner")
    func mixedUndoSendsLGAndKeepsMi() async throws {
        let lgTV = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: "LG C2 电视",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "lg.webos.oled42c2pca",
            isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: LGWebOSProtocol.mediaEntityId,
                state: "on",
                volumePercent: 18
            ))
        )
        let lamp = try #require(Self.lampHome.devices.first)
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lgTV, lamp]))
        let store = try await makeStore(backend: .xiaomiCloud, session: validSession(), provider: provider)
        store.lgWebOSClient = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: false),
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )

        let allOff = try #require(store.turnAllOff())
        #expect(await allOff.value == .completed)
        #expect(store.undoBanner != nil)

        // The undo starts after the session expired, but its LAN restore still runs.
        store.miSessionExpiresAt = expiredAt
        store.miAccounts = [MiAccount(session: expiredSession())]
        #expect(store.miSessionBlocksControl)

        let undo = try #require(store.undoTurnAllOff(), "a mixed undo is not refused outright")
        await undo.value

        #expect(store.devices.first { $0.id == LGWebOSProtocol.deviceId }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "lamp" }?.isActiveOn == false)
        #expect(store.undoBanner?.restoreCommands == [.setLightPower(entityId: "light.lamp", isOn: true)])
        #expect(store.toastNotice?.message == "米家登录已过期", "the generic undo failure must not replace the scan toast")
        #expect(store.toastNotice?.persistent == true)
    }

    @Test("A stale expiry toast does not turn a completed LAN-only 全关 into an error")
    func staleExpiryToastDoesNotFailLGOnlyAllOff() async throws {
        let lgTV = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: "LG C2 电视",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "lg.webos.oled42c2pca",
            isOnline: true,
            kind: .tv(TVSpec(
                mediaEntityId: LGWebOSProtocol.mediaEntityId,
                state: "on",
                volumePercent: 18
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lgTV]))
        let store = try await makeStore(backend: .xiaomiCloud, session: expiredSession(), provider: provider)
        store.lgWebOSClient = LGWebOSClient(
            config: LGWebOSConfig(isEnabled: false),
            onDeviceUpdated: { _ in },
            onClientKeyRegistered: { _ in },
            onSecurityFailure: { _ in }
        )
        #expect(store.miSessionBlocksControl)

        // An earlier Mi tap left the persistent toast up.
        #expect(store.rejectWritesBlockedByMiSession())

        await L10n.$overrideLanguage.withValue(.zhHans) {
            let result = await store.executeBuiltInURLScene(.allOff)
            #expect(!result.isError, "the LAN batch completed, so the link must not report the stale toast")
            #expect(result.message == "已关闭 1 台设备")
        }
        #expect(store.toastNotice?.message == "米家登录已过期", "the Mi session is still expired")
    }

    @Test("A slider write refused mid-debounce keeps the scan toast")
    func blockedSliderWriteKeepsScanToast() async throws {
        let provider = MockHomeProvider(snapshot: Self.lampHome)
        let store = try await makeStore(backend: .xiaomiCloud, session: validSession(), provider: provider)
        #expect(!store.miSessionBlocksControl)
        store.controlDebounceInterval = .milliseconds(1)

        store.setLightBrightness("lamp", percent: 40)
        // Nothing may run between the tap and this line: the debounce task cannot start until the
        // main actor yields, so the session is expired before the send.
        store.miSessionExpiresAt = expiredAt
        store.miAccounts = [MiAccount(session: expiredSession())]
        #expect(store.miSessionBlocksControl)

        for _ in 0..<1_000 {
            if case .light(let spec)? = store.devices.first(where: { $0.id == "lamp" })?.kind,
               spec.brightnessPercent == 80 {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if case .light(let spec)? = store.devices.first(where: { $0.id == "lamp" })?.kind {
            #expect(spec.brightnessPercent == 80, "the refused write puts the row back")
        } else {
            Issue.record("the lamp row is missing")
        }
        #expect(store.toastNotice?.message == "台灯 调节未生效")
        #expect(store.toastNotice?.persistent == false)
        store.dismissToast()
        #expect(store.toastNotice?.message == "米家登录已过期")
        #expect(store.toastNotice?.persistent == true)
        #expect(await provider.executedCommands.isEmpty)
    }

    @Test("An ordinary error during the block is shown, and the scan toast returns when it ends")
    func ordinaryErrorSuspendsSessionToast() async throws {
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: Self.lampHome)
        )
        #expect(store.rejectWritesBlockedByMiSession())
        #expect(store.toastNotice?.persistent == true)

        store.showToast("无法写入钥匙串", isError: true)
        #expect(store.toastNotice?.message == "无法写入钥匙串", "the keychain error must not be swallowed")
        #expect(store.toastNotice?.persistent == false)
        #expect(store.isSessionToastSuspended)
        let keychainToastID = store.toastNotice?.id

        store.dismissToast()
        #expect(store.toastNotice?.message == "米家登录已过期")
        #expect(store.toastNotice?.persistent == true)
        #expect(store.toastNotice?.id != keychainToastID)
        #expect(!store.isSessionToastSuspended)
    }

    @Test("The scan toast returns after an ordinary toast auto-dismisses")
    func autoDismissRestoresSessionToast() async throws {
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: Self.lampHome)
        )
        #expect(store.rejectWritesBlockedByMiSession())
        store.toastAutoDismissInterval = .milliseconds(1)

        store.showToast("已同步")
        #expect(store.toastNotice?.message == "已同步")
        #expect(store.isSessionToastSuspended)

        for _ in 0..<1_000 {
            if store.toastNotice?.persistent == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(store.toastNotice?.message == "米家登录已过期")
        #expect(store.toastNotice?.persistent == true)
        #expect(!store.isSessionToastSuspended)
    }

    @Test("Recovery while the scan toast is suspended restores nothing")
    func recoveryWhileSuspendedRestoresNothing() async throws {
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: Self.lampHome)
        )
        #expect(store.rejectWritesBlockedByMiSession())
        store.showToast("无法写入钥匙串", isError: true)
        #expect(store.isSessionToastSuspended)

        store.miSessionExpiresAt = farEnd
        store.miAccounts = [MiAccount(session: validSession())]
        #expect(!store.miSessionBlocksControl)

        store.dismissToast()
        #expect(store.toastNotice == nil, "a recovered session must not bring the prompt back")
        #expect(!store.isSessionToastSuspended)
    }

    @Test("A context change while the scan toast is suspended restores nothing")
    func contextChangeWhileSuspendedRestoresNothing() async throws {
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: Self.lampHome)
        )
        #expect(store.rejectWritesBlockedByMiSession())
        store.showToast("无法写入钥匙串", isError: true)
        #expect(store.isSessionToastSuspended)

        store.switchBackend(.demo)
        #expect(!store.isSessionToastSuspended)
        store.dismissToast()
        #expect(store.toastNotice == nil, "demo mode must not restore the old prompt")
    }

    @Test("A second blocked write does not stack a toast behind the ordinary one")
    func secondBlockedWriteDoesNotStack() async throws {
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: Self.lampHome)
        )
        #expect(store.rejectWritesBlockedByMiSession())
        store.showToast("无法写入钥匙串", isError: true)
        let ordinaryID = store.toastNotice?.id

        #expect(store.rejectWritesBlockedByMiSession())
        #expect(store.toastNotice?.id == ordinaryID, "the ordinary message stays on screen")
        #expect(store.isSessionToastSuspended)

        store.dismissToast()
        #expect(store.toastNotice?.message == "米家登录已过期")
        #expect(store.toastNotice?.persistent == true)
    }

    @Test("Switching to demo clears the expired-session toast")
    func switchingBackendClearsExpiredToast() async throws {
        let store = try await makeStore(
            backend: .xiaomiCloud,
            session: expiredSession(),
            provider: MockHomeProvider(snapshot: Self.lampHome)
        )
        #expect(store.miSessionBlocksControl)
        #expect(store.rejectWritesBlockedByMiSession())
        #expect(store.toastNotice?.persistent == true)

        store.switchBackend(.demo)
        #expect(store.toastNotice == nil, "the toast belongs to the old connection")
    }

    @Test("One expired Mi account beside an online one and an offline HA names the other account")
    func offlineHAWithAnotherMiAccountNamesTheOtherAccount() async throws {
        let suite = "com.jryang1997.MenuBarMijia.panel-health.offline-ha.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let saved = MiSessionStore.saveAccounts([
            MiAccount(session: MiSession(
                userId: "1111111111", cUserId: "c1", ssecurity: "s", serviceToken: "t1", expiresAt: expiredAt
            )),
            MiAccount(session: MiSession(
                userId: "2222222222", cUserId: "c2", ssecurity: "s", serviceToken: "t2", expiresAt: farEnd
            )),
        ], defaults: defaults)
        #expect(saved)
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        #expect(store.miSessionShowsExpired)
        #expect(!store.miSessionBlocksControl)
        store.hasHASource = true
        store.sourceStatuses = [.homeAssistant: .disconnected("")]
        store.connectionStatus = .connected

        try await L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(store.panelHealth == .degraded(reason: "有米家账号已过期，其他账号仍保持登录"))
        }
    }

    private func health(_ store: HomeStore) -> PanelHealth {
        store.panelHealth
    }

    private func expiredSession() -> MiSession {
        MiSession(userId: "1234567890", cUserId: "cu", ssecurity: "s", serviceToken: "tok", expiresAt: expiredAt)
    }

    private func validSession() -> MiSession {
        MiSession(userId: "1234567890", cUserId: "cu", ssecurity: "s", serviceToken: "tok", expiresAt: farEnd)
    }

    private static let lampHome = SynthesizedHome(devices: [
        SmartDevice(
            id: "lamp",
            name: "台灯",
            roomId: "room",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 80))
        )
    ])

    private static let twoLampHome = SynthesizedHome(devices: [
        SmartDevice(
            id: "lamp-a",
            name: "台灯 A",
            roomId: "room",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.a", isOn: true))
        ),
        SmartDevice(
            id: "lamp-b",
            name: "台灯 B",
            roomId: "room",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.b", isOn: true))
        ),
    ])

    @discardableResult
    private func makeStore(
        backend: HomeBackend = .homeAssistant,
        session: MiSession? = nil,
        haSource: Bool = false,
        provider: MockHomeProvider? = nil
    ) async throws -> HomeStore {
        let suite = "com.jryang1997.MenuBarMijia.panel-health.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(backend.rawValue, forKey: "home_backend")
        if let session {
            let saved = MiSessionStore.save(session, defaults: defaults)
            #expect(saved)
        }
        let store = HomeStore(provider: provider ?? MockHomeProvider(), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        if haSource {
            store.hasHASource = true
            store.sourceStatuses[.homeAssistant] = .connected
        }
        return store
    }
}
