import Foundation
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
            #expect(SettingsTab.privacy.paneSubtitle?.contains("设备类型关闭后仍可管理对应提醒") == true)
            #expect(SettingsTab.about.paneSubtitle?.contains("版本更新、隐私说明、排障信息、重置与退出") == true)
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(SettingsTab.privacy.title == "安全與提醒")
            #expect(SettingsTab.about.title == "關於與診斷")
            #expect(SettingsTab.privacy.paneSubtitle?.contains("裝置類型關閉後仍可管理對應提醒") == true)
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
        let suite = "test.wp3c.alloff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

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
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
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

    @Test("Top update prompt banner shows on non-About tabs when a release badge is active and hides on About")
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

        #expect(SettingsTopUpdateBanner.releaseToShow(updateState: .idle, activeTab: .general) == nil)
        #expect(SettingsTopUpdateBanner.releaseToShow(updateState: .checking, activeTab: .privacy) == nil)
        #expect(SettingsTopUpdateBanner.releaseToShow(updateState: .upToDate(checkedAt: Date()), activeTab: .general) == nil)

        for tab in [SettingsTab.general, .connection, .assistant, .privacy, .appearance] {
            #expect(
                SettingsTopUpdateBanner.releaseToShow(updateState: .available(notesOnlyRelease), activeTab: tab) == notesOnlyRelease,
                "Banner should appear on \(tab.rawValue)"
            )
        }
        #expect(SettingsTopUpdateBanner.releaseToShow(updateState: .available(notesOnlyRelease), activeTab: .about) == nil)

        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(
                SettingsTopUpdateBanner.actionTitle(for: notesOnlyRelease, updateState: .available(notesOnlyRelease)) == "前往查看"
            )
            #expect(
                SettingsTopUpdateBanner.actionTitle(for: dmgRelease, updateState: .available(dmgRelease)) == "立即更新"
            )
        }
    }

    @Test("Traditional Chinese translations cover WP3c risk warnings, diagnostics redaction, and reset copy")
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
        }
    }
}
