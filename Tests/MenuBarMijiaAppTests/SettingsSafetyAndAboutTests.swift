import Foundation
import PreferencesTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@MainActor
@Suite("WP3c Settings: Safety & Alerts and About & Diagnostics", .serialized)
struct SettingsSafetyAndAboutTests {

    @Test("Tabs 4 and 5 use Safety & Alerts and About & Diagnostics titles while preserving rawValues")
    func tabRenamingAndRawValueCompatibility() {
        #expect(SettingsTab.allCases == [.general, .connection, .assistant, .privacy, .about])
        #expect(SettingsTab.privacy.rawValue == "privacy")
        #expect(SettingsTab.about.rawValue == "about")
        #expect(SettingsTab(rawValue: "privacy") == .privacy)
        #expect(SettingsTab(rawValue: "about") == .about)

        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(SettingsTab.privacy.title == "安全与提醒")
            #expect(SettingsTab.about.title == "关于与诊断")
            #expect(SettingsTab.privacy.paneSubtitle == "锁屏保护、安全提醒与全关范围")
            #expect(SettingsTab.about.paneSubtitle?.contains("版本更新、隐私说明、排障信息、重置与退出") == true)
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(SettingsTab.privacy.title == "安全與提醒")
            #expect(SettingsTab.about.title == "關於與診斷")
            #expect(SettingsTab.privacy.paneSubtitle == "鎖定畫面保護、安全提醒與全關範圍")
            #expect(SettingsTab.about.paneSubtitle?.contains("版本更新、隱私說明、排障資訊、重置與退出") == true)
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(SettingsTab.privacy.title == "Safety & Alerts")
            #expect(SettingsTab.about.title == "About & Diagnostics")
            #expect(SettingsTab.privacy.paneSubtitle?.contains("Lock-screen protection") == true)
            #expect(SettingsTab.about.paneSubtitle?.contains("Software updates, privacy notes, diagnostics") == true)
        }
    }

    @Test("Migrated anchors and All Off Scope route to Safety & Alerts or About & Diagnostics and remain searchable")
    func anchorRoutingAndSearchReachability() {
        let safetyAnchors: [SettingsAnchor] = [
            .blockControlWhileLocked,
            .safetyAlerts,
            .sensorAlerts,
            .alertsOnlyWhenAway,
            .doorbellAutoView,
            .doorbellChime,
            .doorbellAutoCloseSeconds,
            .notificationPermission,
            .allOffScope,
            .advancedDeviceWrites,
            .allowURLControl,
        ]
        for anchor in safetyAnchors {
            #expect(anchor.tab == .privacy, "\(anchor.rawValue) should route to .privacy")
        }

        let aboutAnchors: [SettingsAnchor] = [
            .aboutVersion,
            .softwareUpdate,
            .setupGuide,
            .privacyNotes,
            .copyDiagnostics,
            .scanUnsupportedDevices,
            .signOut,
            .quitApp,
        ]
        for anchor in aboutAnchors {
            #expect(anchor.tab == .about, "\(anchor.rawValue) should route to .about")
        }

        let queries: [(String, SettingsAnchor)] = [
            ("全关范围", .allOffScope),
            ("all off scope", .allOffScope),
            ("打开高风险设备的额外控制", .advancedDeviceWrites),
            ("允许外部链接直接控制设备", .allowURLControl),
            ("menumijia", .allowURLControl),
            ("高级门铃选项", .doorbellAutoCloseSeconds),
            ("守护提醒", .safetyAlerts),
            ("重新查看初始设置引导", .setupGuide),
            ("复制排障信息", .copyDiagnostics),
            ("隐去账号", .copyDiagnostics),
            ("退出并清除所有账号与密钥", .signOut),
            ("高级排障", .signOut),
        ]
        let demoAvailability = SettingsSearchAvailability(
            backend: .demo,
            hiddenDeviceCount: 0,
            storedPanelTheme: PanelTheme.classic.rawValue,
            liquidGlassAvailable: true
        )
        for (query, expectedAnchor) in queries {
            let outcome = SettingsSearch.search(query, availability: demoAvailability)
            #expect(
                outcome.hits.contains { $0.anchor == expectedAnchor },
                "「\(query)」should reach \(expectedAnchor.rawValue), got \(outcome.hits.map(\.anchor.rawValue))"
            )
            #expect(demoAvailability.isReachable(expectedAnchor))
        }
    }

    @Test("Safety and About disclosures auto-expand for non-default values and search highlights")
    func disclosuresAutoExpand() {
        var defaultSafety = SafetySettingsDisclosure.State()
        defaultSafety.applyInitialDefaultsIfNeeded(doorbellPopupSeconds: HomeStore.defaultDoorbellPopupSeconds)
        #expect(!defaultSafety.isDoorbellAdvancedExpanded)
        #expect(!defaultSafety.isAllOffScopeExpanded)

        var customDoorbellSafety = SafetySettingsDisclosure.State()
        customDoorbellSafety.applyInitialDefaultsIfNeeded(doorbellPopupSeconds: 30)
        #expect(customDoorbellSafety.isDoorbellAdvancedExpanded)
        #expect(!customDoorbellSafety.isAllOffScopeExpanded)

        // Manual collapse after initial load is not overwritten on subsequent onAppear passes.
        customDoorbellSafety.isDoorbellAdvancedExpanded = false
        customDoorbellSafety.applyInitialDefaultsIfNeeded(doorbellPopupSeconds: 30)
        #expect(!customDoorbellSafety.isDoorbellAdvancedExpanded)

        defaultSafety.expandForHighlightIfNeeded(.safetyAlerts)
        #expect(!defaultSafety.isDoorbellAdvancedExpanded)
        #expect(!defaultSafety.isAllOffScopeExpanded)

        defaultSafety.expandForHighlightIfNeeded(.doorbellAutoCloseSeconds)
        #expect(defaultSafety.isDoorbellAdvancedExpanded)
        #expect(!defaultSafety.isAllOffScopeExpanded)

        defaultSafety.expandForHighlightIfNeeded(.allOffScope)
        #expect(defaultSafety.isAllOffScopeExpanded)

        var aboutState = AboutSettingsDisclosure.State()
        #expect(!aboutState.isResetExpanded)
        aboutState.expandForHighlightIfNeeded(.copyDiagnostics)
        #expect(!aboutState.isResetExpanded)
        aboutState.expandForHighlightIfNeeded(.signOut)
        #expect(aboutState.isResetExpanded)
    }

    @Test("All Off Scope lists configurable devices, keeps closed writable valves configurable, and updates included count")
    func allOffScopeInclusionAndOverrides() async throws {
        let defaults = InMemoryUserDefaults()

        let room = RoomArea(id: "living", name: "客厅", sortOrder: 0)
        let light = SmartDevice(
            id: "light_1", name: "客厅主灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.ceiling13", isOnline: true,
            kind: .light(LightSpec(entityId: "light.1", isOn: false))
        )
        let hiddenLight = SmartDevice(
            id: "light_hidden", name: "玄关夜灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.hidden", isOn: true))
        )
        let plug = SmartDevice(
            id: "plug_1", name: "路由器插座", roomId: "living", roomName: "客厅",
            model: "cuco.plug.v3", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.router", isOn: true))
        )
        let vacuum = SmartDevice(
            id: "vac_1", name: "扫地机器人", roomId: "living", roomName: "客厅",
            model: "roborock.vacuum.a15", isOnline: true,
            kind: .vacuum(VacuumSpec(entityId: "vacuum.1", status: "docked"))
        )
        let closedWritableValve = SmartDevice(
            id: "valve_closed", name: "厨房总水阀", roomId: "living", roomName: "客厅",
            model: "aqara.valve.v1", isOnline: true,
            kind: .valve(ValveSpec(entityId: "valve.water", isOpen: false, openWritable: true, closeWritable: true))
        )
        let readOnlyValve = SmartDevice(
            id: "valve_ro", name: "只读水阀", roomId: "living", roomName: "客厅",
            model: "aqara.valve.ro", isOnline: true,
            kind: .valve(ValveSpec(entityId: "valve.ro", isOpen: true, openWritable: false, closeWritable: false))
        )
        let curtain = SmartDevice(
            id: "cover_1", name: "客厅窗帘", roomId: "living", roomName: "客厅",
            model: "lumi.curtain.v1", isOnline: true,
            kind: .cover(CoverSpec(entityId: "cover.1", subtype: .curtain, positionPercent: 80, positionWritable: true))
        )

        #expect(HomeStore.canConfigureAllOff(light))
        #expect(HomeStore.canConfigureAllOff(plug))
        #expect(HomeStore.canConfigureAllOff(vacuum))
        #expect(HomeStore.canConfigureAllOff(closedWritableValve))
        #expect(!HomeStore.canConfigureAllOff(readOnlyValve))
        #expect(!HomeStore.canConfigureAllOff(curtain))

        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [room],
            devices: [light, hiddenLight, plug, vacuum, closedWritableValve, readOnlyValve, curtain]
        ))
        let store = HomeStore(provider: mock, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.hideDevice(hiddenLight.id)

        #expect(store.allOffConfigurableDevices.map(\.id) == ["light_1", "plug_1", "vac_1", "valve_closed"])
        #expect(store.allOffIncludedDevices.map(\.id) == ["light_1"])

        store.setJoinsAllOff(true, deviceId: plug.id)
        store.setJoinsAllOff(true, deviceId: closedWritableValve.id)
        #expect(store.allOffIncludedDevices.map(\.id) == ["light_1", "plug_1", "valve_closed"])

        store.setJoinsAllOff(false, deviceId: light.id)
        #expect(store.allOffIncludedDevices.map(\.id) == ["plug_1", "valve_closed"])
    }

    @Test("All Off Scope shows global included devices while panel All Off only targets active online included devices in the selected room slice")
    func allOffIncludedDevicesVersusRoomSliceTargets() async throws {
        let defaults = InMemoryUserDefaults()

        let rooms = [
            RoomArea(id: "living", name: "客厅", sortOrder: 0),
            RoomArea(id: "bedroom", name: "卧室", sortOrder: 1),
        ]
        let livingOnLight = SmartDevice(
            id: "living_on", name: "客厅吸顶灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.ceiling13", isOnline: true,
            kind: .light(LightSpec(entityId: "light.living_on", isOn: true))
        )
        let livingOffLight = SmartDevice(
            id: "living_off", name: "客厅氛围灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.strip1", isOnline: true,
            kind: .light(LightSpec(entityId: "light.living_off", isOn: false))
        )
        let livingOfflineLight = SmartDevice(
            id: "living_offline", name: "客厅落地灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.lamp4", isOnline: false,
            kind: .light(LightSpec(entityId: "light.living_offline", isOn: true))
        )
        let livingHiddenLight = SmartDevice(
            id: "living_hidden", name: "客厅隐藏夜灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.lamp2", isOnline: true,
            kind: .light(LightSpec(entityId: "light.living_hidden", isOn: true))
        )
        let bedroomOnLight = SmartDevice(
            id: "bedroom_on", name: "卧室主灯", roomId: "bedroom", roomName: "卧室",
            model: "yeelink.light.ceiling13", isOnline: true,
            kind: .light(LightSpec(entityId: "light.bedroom_on", isOn: true))
        )

        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: rooms,
            devices: [livingOnLight, livingOffLight, livingOfflineLight, livingHiddenLight, bedroomOnLight]
        ))
        let store = HomeStore(provider: mock, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.hideDevice(livingHiddenLight.id)

        // Settings summary counts all non-hidden participating devices across rooms regardless of power/online state.
        #expect(store.allOffIncludedDevices.map(\.id) == [
            "living_on",
            "living_off",
            "living_offline",
            "bedroom_on",
        ])

        // Under "All" rooms, only online & currently-on participating non-hidden devices are targeted.
        #expect(store.allOffTargets.map(\.id) == ["living_on", "bedroom_on"])

        // Selecting a local room slice narrows All Off execution to that room's online & currently-on participating devices.
        store.selectRoom("living")
        #expect(store.allOffIncludedDevices.count == 4)
        #expect(store.allOffTargets.map(\.id) == ["living_on"])
    }

    @Test("Unsupported device scan results group deterministically by reason with localized titles and counts")
    func unsupportedDeviceGroupingByReason() {
        let items: [UnsupportedDevice] = [
            UnsupportedDevice(id: "d1", name: "客厅蓝牙网关", model: "xiaomi.gateway.v1", reason: .filteredDuplicate),
            UnsupportedDevice(id: "d2", name: "智能香薰机", model: "hl.aromatherapy.v2", reason: .unknownModel),
            UnsupportedDevice(id: "d3", name: "厨房燃气表", model: "miot.meter.v1", reason: .noControllableItems),
            UnsupportedDevice(id: "d4", name: "卧室蓝牙音箱", model: "xiaomi.speaker.v3", reason: .unknownModel),
        ]

        #expect(UnsupportedDeviceGrouping.group([]).isEmpty)

        L10n.$overrideLanguage.withValue(.zhHans) {
            let groups = UnsupportedDeviceGrouping.group(items)
            #expect(groups.map(\.reason) == [.unknownModel, .noControllableItems, .filteredDuplicate])
            #expect(groups.map(\.count) == [2, 1, 1])
            #expect(groups[0].title == "没有取到米家设备规格")
            #expect(groups[0].devices.map(\.id) == ["d2", "d4"])
            #expect(groups[1].title == "该设备没有向云端开放可控项")
            #expect(groups[2].devices.map(\.id) == ["d1"])
        }
    }

    @Test("Top update prompt banner covers release badges and update failures on non-About tabs with unified View Update action")
    func topUpdateBannerVisibilityAndActionTitle() throws {
        let pageURL = try #require(URL(string: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v2.1.0"))
        let downloadURL = try #require(URL(string: "https://github.com/jryang2026-code/MenuBarHome/releases/download/v2.1.0/MenuBarHome.dmg"))

        let notesOnlyRelease = AppRelease(version: "2.1.0", pageURL: pageURL, notes: "Fixes")
        let dmgRelease = AppRelease(
            version: "2.1.0",
            pageURL: pageURL,
            notes: "Fixes",
            packageAsset: AppRelease.PackageAsset(
                name: "MenuBarHome.dmg",
                downloadURL: downloadURL,
                sizeBytes: 12_345_678,
                kind: .dmg
            )
        )
        let stagedApp = VerifiedStagedApp(
            release: dmgRelease,
            stagedBundleURL: URL(fileURLWithPath: "/tmp/MenuBarHome.app"),
            stagingRootURL: URL(fileURLWithPath: "/tmp")
        )
        let checkFailure = AppUpdateFailure(release: nil, message: "Network offline", recovery: .recheck)
        let installFailure = AppUpdateFailure(release: dmgRelease, message: "Disk full", recovery: .retryInstall)

        #expect(!SettingsTopUpdateBanner.showsSidebarBadge(for: .idle))
        #expect(!SettingsTopUpdateBanner.showsSidebarBadge(for: .checking))
        #expect(!SettingsTopUpdateBanner.showsSidebarBadge(for: .upToDate(checkedAt: Date())))
        #expect(SettingsTopUpdateBanner.showsSidebarBadge(for: .available(notesOnlyRelease)))
        #expect(SettingsTopUpdateBanner.showsSidebarBadge(for: .readyToRelaunch(stagedApp)))
        #expect(SettingsTopUpdateBanner.showsSidebarBadge(for: .failed(checkFailure)))
        #expect(SettingsTopUpdateBanner.showsSidebarBadge(for: .failed(installFailure)))

        #expect(SettingsTopUpdateBanner.prompt(for: .idle, activeTab: .general) == nil)
        #expect(SettingsTopUpdateBanner.prompt(for: .checking, activeTab: .privacy) == nil)
        #expect(SettingsTopUpdateBanner.prompt(for: .upToDate(checkedAt: Date()), activeTab: .general) == nil)

        for tab in [SettingsTab.general, .connection, .assistant, .privacy, .appearance] {
            #expect(
                SettingsTopUpdateBanner.releaseToShow(updateState: .available(notesOnlyRelease), activeTab: tab) == notesOnlyRelease,
                "Banner should appear on \(tab.rawValue)"
            )
            #expect(
                SettingsTopUpdateBanner.prompt(for: .failed(checkFailure), activeTab: tab) == .failure(checkFailure),
                "Failure banner should appear on \(tab.rawValue)"
            )
        }
        #expect(SettingsTopUpdateBanner.releaseToShow(updateState: .available(notesOnlyRelease), activeTab: .about) == nil)
        #expect(SettingsTopUpdateBanner.prompt(for: .failed(checkFailure), activeTab: .about) == nil)
        #expect(
            SettingsTopUpdateBanner.prompt(for: .readyToRelaunch(stagedApp), activeTab: .general)
                == .release(dmgRelease, readyToRelaunch: true)
        )

        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(SettingsTopUpdateBanner.actionTitle == "前往查看")
            #expect(
                SettingsTopUpdateBanner.actionTitle(for: notesOnlyRelease, updateState: .available(notesOnlyRelease)) == "前往查看"
            )
            #expect(
                SettingsTopUpdateBanner.actionTitle(for: dmgRelease, updateState: .available(dmgRelease)) == "前往查看"
            )
            #expect(
                SettingsTopUpdateBanner.actionTitle(for: dmgRelease, updateState: .readyToRelaunch(stagedApp)) == "前往查看"
            )
            #expect(SettingsTopUpdateBanner.failureHeadline(for: checkFailure) == "更新检查失败")
            #expect(SettingsTopUpdateBanner.failureHeadline(for: installFailure) == "软件更新失败")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(SettingsTopUpdateBanner.actionTitle == "View Update")
            #expect(SettingsTopUpdateBanner.failureHeadline(for: checkFailure) == "Update Check Failed")
            #expect(SettingsTopUpdateBanner.failureHeadline(for: installFailure) == "Software Update Failed")
        }
    }

    @Test("SettingsWindowOpener records target anchor and ContinueOnboardingSection respects unsaved draft cancellation")
    func openerAnchorRoutingAndUnsavedOnboardingGuard() throws {
        let opener = SettingsWindowOpener.shared
        let previousOpen = opener.open
        let previousTab = opener.requestedTab
        let previousAnchor = opener.requestedAnchor
        defer {
            opener.open = previousOpen
            opener.requestedTab = previousTab
            opener.requestedAnchor = previousAnchor
        }

        var didCallOpen = false
        opener.open = { didCallOpen = true }
        opener.show(tab: .privacy, anchor: .advancedDeviceWrites)
        #expect(didCallOpen)
        #expect(opener.requestedTab == .privacy)
        #expect(opener.requestedAnchor == .advancedDeviceWrites)

        opener.show(tab: .general)
        #expect(opener.requestedTab == .general)
        #expect(opener.requestedAnchor == nil)

        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")

        let store = HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome(rooms: [], devices: [])), defaults: defaults)
        #expect(!store.isShowingOnboarding)

        let unsaved = SettingsUnsavedChanges()
        var discarded = false
        unsaved.register(
            "ha",
            .init(
                title: "Home Assistant",
                isDirty: true,
                save: { false },
                discard: { discarded = true }
            )
        )

        // User cancels the unsaved prompt: onboarding does not reopen and window stays open.
        let cancelled = ContinueOnboardingSection.reopenIfUnsavedResolved(
            store: store,
            unsaved: unsaved,
            ask: { _, _ in .cancel }
        )
        #expect(!cancelled)
        #expect(!store.isShowingOnboarding)
        #expect(!discarded)

        // User discards draft: onboarding reopens cleanly.
        let proceeded = ContinueOnboardingSection.reopenIfUnsavedResolved(
            store: store,
            unsaved: unsaved,
            ask: { _, _ in .discard }
        )
        #expect(proceeded)
        #expect(discarded)
        #expect(store.isShowingOnboarding)
    }

    @Test("Traditional Chinese translations cover WP3c risk warnings, diagnostics redaction, reset copy, and review additions")
    func traditionalChineseWP3cTranslations() {
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(L10n.tr(
                "打开高风险设备的额外控制（门锁、阀门、加热等），每次操作前仍会单独确认",
                "Enable extra controls for high-risk devices (locks, valves, heating, etc.); each action still asks for confirmation"
            ) == "打開高風險裝置的額外控制（門鎖、閥門、加熱等），每次操作前仍會單獨確認")

            #expect(L10n.tr(
                "允许外部链接直接控制设备（跳过所有二次确认，含门锁、阀门）",
                "Allow external links to control devices directly (skips all secondary confirmations, including locks and valves)"
            ) == "允許外部連結直接控制裝置（跳過所有二次確認，含門鎖、閥門）")

            #expect(L10n.tr(
                "复制排障信息（已自动隐去账号与密钥）",
                "Copy Diagnostics (Accounts & Keys Redacted)"
            ) == "複製排障資訊（已自動隱去帳號與金鑰）")

            #expect(L10n.tr(
                "退出并清除所有账号与密钥",
                "Sign Out & Clear All Accounts and Keys"
            ) == "登出並清除所有帳號與金鑰")

            #expect(L10n.tr("前往查看", "View Update") == "前往查看")
            #expect(L10n.tr("更新检查失败", "Update Check Failed") == "更新檢查失敗")
            #expect(L10n.tr("软件更新失败", "Software Update Failed") == "軟體更新失敗")
            #expect(L10n.tr(
                "面板执行「全关」时，仅关闭当前房间或筛选范围内已开启的参与设备。",
                "Running All Off in the panel only turns off participating devices that are currently on in the active room or filter."
            ) == "面板執行「全關」時，僅關閉目前房間或篩選範圍內已開啟的參與裝置。")
            #expect(L10n.tr(
                "请先开启「门铃响时自动弹出摄像头画面」。",
                "Turn on “Show the doorbell camera when it rings” first."
            ) == "請先開啟「門鈴響時自動彈出攝影機畫面」。")
        }
    }
}
