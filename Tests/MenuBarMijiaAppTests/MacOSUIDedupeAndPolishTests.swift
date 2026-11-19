import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
@Suite("macOS UI dedupe & polish regressions", .serialized)
struct MacOSUIDedupeAndPolishTests {
    private func stackHeight(_ list: [PanelActivity], store: HomeStore, expanded: Bool, theme: PanelTheme) -> CGFloat {
        _ = NSApplication.shared
        let root = ActivityStackView(
            activities: list, store: store, isExpanded: .constant(expanded), expandedViewportHeight: 220, theme: theme,
            dismiss: { _ in }, clear: {}, label: { _ in "Kettle Running" }, content: { _ in Text("Card").padding(12) }
        ).frame(width: 340)
        let view = NSHostingView(rootView: root)
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }

    @Test("ActivityStackView collapses ordinary reminders into a 32pt capsule and expands them on demand")
    func activityStackSingleCardCollapseAndAccessibility() {
        let suiteName = "com.menubarmijia.tests.dedupe.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = HomeStore(provider: DemoHomeProvider(), defaultsSuiteName: suiteName)

        L10n.$overrideLanguage.withValue(.en) {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let a1 = RecordedSafetyAlert(alert: SafetyAlert(id: "offline:d1", deviceId: "d1", title: "Kettle Offline", body: "Check kitchen outlet now.", turnOffCommand: nil), scope: "demo", date: t0)
            let a2 = RecordedSafetyAlert(alert: SafetyAlert(id: "battery:d2", deviceId: "d2", title: "Sensor Low Battery", body: "Battery at 9%.", turnOffCommand: nil), scope: "demo", date: t0)
            let items = PanelActivityFeed.items(notices: [], safety: [a1, a2], doorbells: [], dismissedIds: [])
            let first = items[0]

            #expect(ActivityStackPolicy.ordinaryCapsuleSummary(labels: ["Kettle Offline"]) == "Kettle Offline")
            #expect(ActivityStackPolicy.ordinaryCapsuleSummary(labels: ["Kettle Offline", "Sensor Low Battery"]) == "Kettle Offline and 1 more")

            for theme in PanelTheme.allCases {
                #expect(stackHeight(items, store: store, expanded: true, theme: theme) > stackHeight(items, store: store, expanded: false, theme: theme))
                let collapsedOne = stackHeight([first], store: store, expanded: false, theme: theme)
                #expect(collapsedOne < 60)
            }
        }
    }

    @Test("DeviceFacetSection select binding keeps nil/unlisted unselected so picking option 1 fires")
    func facetSelectBindingDispatchesFirstOptionFromNilOrUnlisted() {
        let options = [MiotFacetOption(value: 1, label: "Silent"), MiotFacetOption(value: 2, label: "Turbo")]
        var control = FacetControl(
            id: "2.1", kind: .select, name: "mode", title: "Mode", serviceName: "fan",
            value: nil, options: options, isWritable: true, writesByDefault: true, isHighValue: true
        )
        #expect(DeviceFacetSection.selectedOptionValue(for: control) == nil)
        var picked: [Int] = []
        let binding = DeviceFacetSection.selectBinding(for: control) { picked.append($0) }
        #expect(binding.wrappedValue == nil)
        binding.wrappedValue = nil
        #expect(picked.isEmpty)
        binding.wrappedValue = 1
        #expect(picked == [1])
        control.value = .number(99)
        #expect(DeviceFacetSection.selectedOptionValue(for: control) == nil)
        control.value = .number(2)
        #expect(DeviceFacetSection.selectedOptionValue(for: control) == 2)
    }

    @Test("GrokBallAnimator starts in target emotion pose on first mount instead of blending from 02")
    func grokBallStartsDirectlyInInitialEmotion() throws {
        let defaultBase = try #require(GrokBallData.emotions["02"]).base
        let distinct = try #require(GrokBallData.emotions.first { key, emo in
            let start = emo.frames.first?.pose ?? emo.base
            return key != "02" && emo.transition > 0 && start.body.color.r != defaultBase.body.color.r
        })
        let expectedR = (distinct.value.frames.first?.pose ?? distinct.value.base).body.color.r
        let t0 = Date(timeIntervalSinceReferenceDate: 10)
        let fresh = GrokBallAnimator()
        fresh.sample(at: t0, emotionId: distinct.key, pointer: .zero, reduceMotion: false)
        #expect(fresh.pose.body.color.r == expectedR)

        let switched = GrokBallAnimator()
        switched.sample(at: t0, emotionId: "02", pointer: .zero, reduceMotion: false)
        switched.sample(at: t0, emotionId: distinct.key, pointer: .zero, reduceMotion: false)
        #expect(switched.pose.body.color.r == defaultBase.body.color.r)
    }

    @Test("MenuBarPanelController idles label timer when closed and ignores unrelated UserDefaults")
    func menuBarControllerTimerIdlesAndFiltersUserDefaults() async throws {
        let suite = "test.menubar.idle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let otherDefaults = try #require(UserDefaults(suiteName: "\(suite).other"))
        defer { defaults.removePersistentDomain(forName: suite); otherDefaults.removePersistentDomain(forName: "\(suite).other") }
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        _ = NSApplication.shared
        let controller = MenuBarPanelController(userDefaults: defaults)
        controller.presentsActively = false
        controller.install(with: store)
        defer { controller.uninstall() }

        #expect(!controller.isLabelTimerRunning)
        controller.showPanel()
        #expect(controller.isLabelTimerRunning)
        controller.hidePanel(animated: false)
        #expect(!controller.isLabelTimerRunning)

        let now = Date()
        store.scheduledCommands = [ScheduledCommand(reply: "Lamp off", fireDate: now.addingTimeInterval(30), plan: IntentPlan(intents: [], reply: "Lamp off", source: .local))]
        controller.updateLabelTimer(now: now)
        #expect(controller.isLabelTimerRunning)
        store.scheduledCommands = []
        controller.updateLabelTimer(now: now)
        #expect(!controller.isLabelTimerRunning)

        defaults.set("value", forKey: "unrelated_setting")
        otherDefaults.set(PanelHeight.tall.rawValue, forKey: PanelHeight.storageKey)
        controller.handleUserDefaultsDidChange()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: otherDefaults)
        await Task.yield()
        #expect(controller.preferencesReloadCount == 0)
        defaults.set(PanelHeight.tall.rawValue, forKey: PanelHeight.storageKey)
        controller.handleUserDefaultsDidChange()
        #expect(controller.preferencesReloadCount == 1)
    }

    @Test("Liquid Glass and Classic device card context menus hide All Off option for cover and generic devices")
    func contextMenuHidesAllOffOptionForCoverAndGenericDevices() {
        let light = SmartDevice(
            id: "l1", name: "客厅灯", roomId: "r1", roomName: "客厅",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.1", isOn: true))
        )
        let garage = SmartDevice(
            id: "g1", name: "车库门", roomId: "r1", roomName: "车库",
            model: "fixture.garage", isOnline: true,
            kind: .cover(CoverSpec(entityId: "cover.garage", subtype: .garageDoor, positionPercent: 100, positionWritable: true))
        )
        let curtain = SmartDevice(
            id: "c1", name: "客厅窗帘", roomId: "r1", roomName: "客厅",
            model: "fixture.curtain", isOnline: true,
            kind: .cover(CoverSpec(entityId: "cover.curtain", subtype: .curtain, positionPercent: 50, positionWritable: true))
        )
        let generic = SmartDevice(
            id: "gen1", name: "未知设备", roomId: "r1", roomName: "客厅",
            model: "fixture.generic", isOnline: true,
            kind: .generic(GenericSpec(deviceType: "switch", typeTitle: "开关", isOn: true, isReadOnly: false))
        )

        #expect(DeviceCardView.showsAllOffMenuOption(for: light) == true)
        #expect(DeviceCardView.showsAllOffMenuOption(for: garage) == false)
        #expect(DeviceCardView.showsAllOffMenuOption(for: curtain) == false)
        #expect(DeviceCardView.showsAllOffMenuOption(for: generic) == false)

        #expect(ClassicDeviceCardView.showsAllOffMenuOption(for: light) == true)
        #expect(ClassicDeviceCardView.showsAllOffMenuOption(for: garage) == false)
        #expect(ClassicDeviceCardView.showsAllOffMenuOption(for: curtain) == false)
        #expect(ClassicDeviceCardView.showsAllOffMenuOption(for: generic) == false)
    }

    @Test("LGWebOSSettingsSection scan caller preserves rejected-host explanation toast when no TV is found")
    func lgScanCallerPreservesRejectedHostExplanation() async throws {
        let suite = "test.lg.settings.scan.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        var hostDraft = "8.8.8.8"
        LGWebOSSettingsSection.handleDiscoveryResult([], hostHint: hostDraft, store: store) {
            hostDraft = $0
        }
        #expect(hostDraft == "8.8.8.8")
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message == LGWebOSClient.discoveryFailureMessage(hostHint: "8.8.8.8"))
        #expect(store.toastNotice?.message.contains("8.8.8.8") == true)

        LGWebOSSettingsSection.handleDiscoveryResult([], hostHint: "192.168.1.50", store: store) {
            hostDraft = $0
        }
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message == LGWebOSClient.discoveryFailureMessage(hostHint: "192.168.1.50"))
        #expect(store.toastNotice?.message.contains("192.168.1.50") == false)

        let tv = LGWebOSDiscoveredTV(host: "192.168.1.55", friendlyName: "LG C2 电视")
        LGWebOSSettingsSection.handleDiscoveryResult([tv], hostHint: "8.8.8.8", store: store) {
            hostDraft = $0
        }
        #expect(hostDraft == "192.168.1.55")
        #expect(store.toastNotice?.isError == false)
        #expect(store.toastNotice?.message.contains("192.168.1.55") == true)
    }

    @Test("Stale sensor cards keep child actions accessible when collapsed and never announce stale readings")
    func staleSensorCardAccessibilityExposesActionsAndSuppressesStaleReadings() async throws {
        #expect(SensorCardView.collapsesAccessibilityChildren(isExpanded: false, isStale: false) == true)
        #expect(SensorCardView.collapsesAccessibilityChildren(isExpanded: true, isStale: false) == false)
        #expect(SensorCardView.collapsesAccessibilityChildren(isExpanded: false, isStale: true) == false)
        #expect(SensorCardView.collapsesAccessibilityChildren(isExpanded: true, isStale: true) == false)

        let spec = SensorSpec(
            temperature: 26.4,
            humidity: 58,
            battery: 87
        )
        let staleSensor = SmartDevice(
            id: "sensor-1",
            name: "书房温湿度计",
            roomId: "r1",
            roomName: "书房",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: true,
            kind: .sensor(spec),
            telemetryStale: true
        )

        L10n.$overrideLanguage.withValue(.zhHans) {
            let freshSummary = SensorCardView.accessibilitySummary(device: staleSensor, spec: spec, isStale: false)
            #expect(freshSummary.contains("26.4"))
            #expect(freshSummary.contains("58%"))
            #expect(freshSummary.contains("87%"))

            let staleSummary = SensorCardView.accessibilitySummary(device: staleSensor, spec: spec, isStale: true)
            #expect(staleSummary == "书房温湿度计，可能过期")
            #expect(!staleSummary.contains("26.4"))
            #expect(!staleSummary.contains("58%"))
            #expect(!staleSummary.contains("87%"))
        }

        L10n.$overrideLanguage.withValue(.en) {
            let enDevice = SmartDevice(
                id: "sensor-en",
                name: "Study Sensor",
                roomId: "r1",
                roomName: "Study",
                model: "miaomiaoce.sensor_ht.t2",
                isOnline: true,
                kind: .sensor(spec),
                telemetryStale: true
            )
            let staleSummary = SensorCardView.accessibilitySummary(device: enDevice, spec: spec, isStale: true)
            #expect(staleSummary == "Study Sensor, possibly stale")
            #expect(!staleSummary.contains("26.4"))
        }

        let suite = "test.sensor.stale.a11y.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var snapshot = SynthesizedHome(devices: [staleSensor], scenes: [])
        snapshot.deviceTransportDiagnostics = [
            "sensor-1": DeviceTransportDiagnostics(route: .cooldown, consecutiveFailures: 2),
        ]
        let store = HomeStore(provider: MockHomeProvider(snapshot: snapshot), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        #expect(SensorCardView.showsStaleTransportReadout(device: staleSensor, store: store) == true)

        L10n.$overrideLanguage.withValue(.zhHans) {
            _ = NSApplication.shared
            let liquid = NSHostingView(
                rootView: SensorCardView(device: staleSensor, spec: spec, store: store, isCompact: false, showRoomBadge: false)
                    .frame(width: 340)
            )
            liquid.layoutSubtreeIfNeeded()
            #expect(liquid.fittingSize.height >= 120)

            let classic = NSHostingView(
                rootView: ClassicSensorCardView(device: staleSensor, spec: spec, store: store, isCompact: false, showRoomBadge: false)
                    .frame(width: 340)
            )
            classic.layoutSubtreeIfNeeded()
            #expect(classic.fittingSize.height >= 120)
        }
        await store.shutdown()
    }

    @Test("Climate power button accessibility label and help match HomeStore.togglePrimary when telemetry is stale")
    func climatePowerButtonAccessibilityMatchesTogglePrimaryWhenStale() async throws {
        let onSpec = ClimateSpec(
            entityId: "climate.living_ac",
            isOn: true,
            hvacMode: "cool",
            availableModes: ["off", "cool", "heat"],
            targetTemperature: 24,
            currentTemperature: 27,
            minTemp: 16,
            maxTemp: 30,
            step: 1
        )
        let offSpec = ClimateSpec(
            entityId: "climate.living_ac",
            isOn: false,
            hvacMode: "off",
            availableModes: ["off", "cool", "heat"],
            targetTemperature: 24,
            currentTemperature: 27,
            minTemp: 16,
            maxTemp: 30,
            step: 1
        )

        #expect(ClimatePanelModule.powerToggleTurnsOff(onSpec) == true)
        #expect(ClimatePanelModule.powerToggleTurnsOff(offSpec) == false)

        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(ClimatePanelModule.powerAccessibilityLabel(deviceName: "客厅空调", spec: onSpec) == "关闭 客厅空调")
            #expect(ClimatePanelModule.powerHelpText(onSpec) == "关闭空调")
            #expect(ClimatePanelModule.powerAccessibilityLabel(deviceName: "客厅空调", spec: offSpec) == "打开 客厅空调")
            #expect(ClimatePanelModule.powerHelpText(offSpec) == "打开空调")
        }

        L10n.$overrideLanguage.withValue(.en) {
            #expect(ClimatePanelModule.powerAccessibilityLabel(deviceName: "Living Room AC", spec: onSpec) == "Turn off Living Room AC")
            #expect(ClimatePanelModule.powerHelpText(onSpec) == "Turn off")
            #expect(ClimatePanelModule.powerAccessibilityLabel(deviceName: "Living Room AC", spec: offSpec) == "Turn on Living Room AC")
            #expect(ClimatePanelModule.powerHelpText(offSpec) == "Turn on")
        }

        let staleOnClimate = SmartDevice(
            id: "ac-1",
            name: "客厅空调",
            roomId: "r1",
            roomName: "客厅",
            model: "xiaomi.aircondition.mc5",
            isOnline: true,
            kind: .climate(onSpec),
            telemetryStale: true
        )
        let staleOffClimate = SmartDevice(
            id: "ac-2",
            name: "卧室空调",
            roomId: "r2",
            roomName: "卧室",
            model: "xiaomi.aircondition.mc5",
            isOnline: true,
            kind: .climate(offSpec),
            telemetryStale: true
        )
        let suite = "test.climate.stale.a11y.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [staleOnClimate, staleOffClimate], scenes: []))
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        L10n.$overrideLanguage.withValue(.zhHans) {
            _ = NSApplication.shared
            let liquid = NSHostingView(
                rootView: ClimatePanelModule(device: staleOnClimate, spec: onSpec, store: store, showRoomBadge: false)
                    .frame(width: 340)
            )
            liquid.layoutSubtreeIfNeeded()
            #expect(liquid.fittingSize.height > 0)

            let classic = NSHostingView(
                rootView: ClassicClimatePanelModule(device: staleOnClimate, spec: onSpec, store: store, showRoomBadge: false)
                    .frame(width: 340)
            )
            classic.layoutSubtreeIfNeeded()
            #expect(classic.fittingSize.height > 0)
        }

        if let turnOffTask = store.togglePrimary(staleOnClimate) {
            _ = await turnOffTask.result
        }
        if let turnOnTask = store.togglePrimary(staleOffClimate) {
            _ = await turnOnTask.result
        }
        let executed = await provider.executedCommands
        #expect(executed == [
            .setClimatePower(entityId: "climate.living_ac", isOn: false, fallbackMode: "off"),
            .setClimatePower(entityId: "climate.living_ac", isOn: true, fallbackMode: "cool"),
        ])
        await store.shutdown()
    }

    @Test("Plain switch and light without native drawer or facets expand transport drawer and expose context-menu recovery")
    func plainSwitchWithoutFacetsOpensTransportDrawerAndOffersContextMenuRecovery() async throws {
        let plainSwitch = SmartDevice(
            id: "switch-plain",
            name: "走廊墙壁开关",
            roomId: "r1",
            roomName: "走廊",
            model: "lumi.switch.b1lacn02",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:switch-plain:2", isOn: true))
        )
        let plainLight = SmartDevice(
            id: "light-plain",
            name: "玄关吸顶灯",
            roomId: "r1",
            roomName: "玄关",
            model: "yeelink.light.mono1",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "miot:light-plain:2",
                isOn: true,
                brightnessWritable: false,
                colorWritable: false
            ))
        )
        let sensor = SmartDevice(
            id: "sensor-chart",
            name: "客厅温湿度计",
            roomId: "r1",
            roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 24.2, humidity: 52))
        )
        #expect(!plainSwitch.hasDetailDrawer)
        #expect(!plainLight.hasDetailDrawer)

        let suite = "test.transport.only.drawer.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let spy = LANRetrySpyProvider(snapshot: SynthesizedHome(devices: [plainSwitch, plainLight, sensor], scenes: []))
        let store = HomeStore(provider: spy, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        #expect(store.deviceFacets[plainSwitch.id] == nil)
        #expect(store.hasDetailDrawer(for: plainSwitch) == false)
        #expect(store.hasDetailDrawer(for: plainLight) == false)

        store.deviceTransportDiagnostics = [
            plainSwitch.id: DeviceTransportDiagnostics(route: .cooldown, consecutiveFailures: 3),
            plainLight.id: DeviceTransportDiagnostics(route: .localNetworkBlocked),
            sensor.id: DeviceTransportDiagnostics(route: .cooldown, consecutiveFailures: 2),
        ]

        #expect(store.hasDetailDrawer(for: plainSwitch) == true)
        #expect(store.hasDetailDrawer(for: plainLight) == true)
        #expect(store.hasDetailDrawer(for: sensor) == false)

        L10n.$overrideLanguage.withValue(.zhHans) {
            _ = NSApplication.shared
            let collapsedLiquid = NSHostingView(
                rootView: DeviceCardView(device: plainSwitch, store: store)
                    .frame(width: 340)
            )
            collapsedLiquid.layoutSubtreeIfNeeded()
            let collapsedLiquidHeight = collapsedLiquid.fittingSize.height

            let collapsedClassic = NSHostingView(
                rootView: ClassicDeviceCardView(device: plainSwitch, store: store)
                    .frame(width: 340)
            )
            collapsedClassic.layoutSubtreeIfNeeded()
            let collapsedClassicHeight = collapsedClassic.fittingSize.height

            store.toggleExpanded(plainSwitch.id)
            #expect(store.expandedDeviceId == plainSwitch.id)

            let expandedLiquid = NSHostingView(
                rootView: DeviceCardView(device: plainSwitch, store: store)
                    .frame(width: 340)
            )
            expandedLiquid.layoutSubtreeIfNeeded()
            let expandedLiquidHeight = expandedLiquid.fittingSize.height

            let expandedClassic = NSHostingView(
                rootView: ClassicDeviceCardView(device: plainSwitch, store: store)
                    .frame(width: 340)
            )
            expandedClassic.layoutSubtreeIfNeeded()
            let expandedClassicHeight = expandedClassic.fittingSize.height

            #expect(expandedLiquidHeight > collapsedLiquidHeight)
            #expect(expandedClassicHeight > collapsedClassicHeight)
            // Transport-only drawer for a plain switch must not synthesize a fake 0 W power meter row.
            #expect(expandedLiquidHeight - collapsedLiquidHeight < 75)
            #expect(expandedClassicHeight - collapsedClassicHeight < 75)

            if #available(macOS 14.4, *) {
                let cooldownMenu = NSHostingMenu(
                    rootView: DeviceCardContextMenuItems(
                        device: plainSwitch,
                        store: store,
                        theme: .liquidGlass,
                        isExpanded: true
                    )
                )
                cooldownMenu.update()
                let cooldownTitles = cooldownMenu.items.map(\.title)
                #expect(cooldownTitles.contains("重试局域网连接"))
                #expect(!cooldownTitles.contains("打开本地网络设置…"))

                let blockedMenu = NSHostingMenu(
                    rootView: DeviceCardContextMenuItems(
                        device: plainLight,
                        store: store,
                        theme: .liquidGlass,
                        isExpanded: false
                    )
                )
                blockedMenu.update()
                let blockedTitles = blockedMenu.items.map(\.title)
                #expect(blockedTitles.contains("打开本地网络设置…"))
                #expect(!blockedTitles.contains("重试局域网连接"))

                store.deviceTransportDiagnostics[plainSwitch.id] = DeviceTransportDiagnostics(route: .lan, rttMs: 9)
                let lanMenu = NSHostingMenu(
                    rootView: DeviceCardContextMenuItems(
                        device: plainSwitch,
                        store: store,
                        theme: .liquidGlass,
                        isExpanded: true
                    )
                )
                lanMenu.update()
                let lanTitles = lanMenu.items.map(\.title)
                #expect(!lanTitles.contains("重试局域网连接"))
                #expect(!lanTitles.contains("打开本地网络设置…"))
            }
        }

        await store.retryDeviceLAN(plainSwitch.id).value
        let retried = await spy.retriedDeviceIds
        #expect(retried == [plainSwitch.id])
        await store.shutdown()
    }

    @Test("Stale sensor expands history chart instead of staying locked behind stale overlay and keeps transport readout reachable")
    func staleSensorExpandsHistoryChartAndKeepsTransportDiagnosticsReachable() async throws {
        let spec = SensorSpec(temperature: 25.8, humidity: 56, battery: 91)
        let staleSensor = SmartDevice(
            id: "sensor-stale-expand",
            name: "主卧温湿度计",
            roomId: "r1",
            roomName: "主卧",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: true,
            kind: .sensor(spec),
            telemetryStale: true
        )
        let suite = "test.sensor.stale.expand.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        var snapshot = SynthesizedHome(devices: [staleSensor], scenes: [])
        snapshot.deviceTransportDiagnostics = [
            staleSensor.id: DeviceTransportDiagnostics(route: .cooldown, consecutiveFailures: 2),
        ]
        let spy = LANRetrySpyProvider(snapshot: snapshot)
        let store = HomeStore(provider: spy, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        let now = Date()
        store.sensorHistory.mergeCloudSamples(
            deviceId: staleSensor.id,
            window: .last24Hours,
            samples: [
                SensorHistorySample(timestamp: now.addingTimeInterval(-3600), temperature: 24.1, humidity: 50),
                SensorHistorySample(timestamp: now, temperature: 24.8, humidity: 53),
            ],
            now: now
        )
        let observedPoints = store.sensorHistory
            .points(forDevice: staleSensor.id, window: .last24Hours)
            .filter(\.isObserved)
        #expect(observedPoints.count >= 2)
        #expect(store.sensorHistory.summary(forDevice: staleSensor.id, window: .last24Hours, metric: .temperature) != nil)

        L10n.$overrideLanguage.withValue(.zhHans) {
            _ = NSApplication.shared
            let collapsedLiquid = NSHostingView(
                rootView: SensorCardView(device: staleSensor, spec: spec, store: store, isCompact: false, showRoomBadge: false)
                    .frame(width: 340)
            )
            collapsedLiquid.layoutSubtreeIfNeeded()
            let collapsedLiquidHeight = collapsedLiquid.fittingSize.height

            let collapsedClassic = NSHostingView(
                rootView: ClassicSensorCardView(device: staleSensor, spec: spec, store: store, isCompact: false, showRoomBadge: false)
                    .frame(width: 340)
            )
            collapsedClassic.layoutSubtreeIfNeeded()
            let collapsedClassicHeight = collapsedClassic.fittingSize.height

            store.toggleExpanded(staleSensor.id)
            #expect(store.expandedDeviceId == staleSensor.id)
            #expect(SensorCardView.collapsesAccessibilityChildren(isExpanded: true, isStale: true) == false)

            let expandedLiquid = NSHostingView(
                rootView: SensorCardView(device: staleSensor, spec: spec, store: store, isCompact: false, showRoomBadge: false)
                    .frame(width: 340)
            )
            expandedLiquid.layoutSubtreeIfNeeded()

            let expandedClassic = NSHostingView(
                rootView: ClassicSensorCardView(device: staleSensor, spec: spec, store: store, isCompact: false, showRoomBadge: false)
                    .frame(width: 340)
            )
            expandedClassic.layoutSubtreeIfNeeded()

            #expect(expandedLiquid.fittingSize.height > collapsedLiquidHeight + 60)
            #expect(expandedClassic.fittingSize.height > collapsedClassicHeight + 60)
        }

        await store.retryDeviceLAN(staleSensor.id).value
        let retried = await spy.retriedDeviceIds
        #expect(retried == [staleSensor.id])
        await store.shutdown()
    }

    @Test("AllOffHoldLatch locks press-down rehearsal mode even if notices arrive before confirm and resets cleanly for subsequent live holds")
    func allOffHoldLatchLocksRehearsalModeAcrossMidHoldNotice() async throws {
        let suite = "test.alloff.latch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let light = SmartDevice(
            id: "l1", name: "客厅吸顶灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.ceiling20", isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 1)],
            devices: [light],
            scenes: []
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.recordOnboardingMilestone(.searchedDevice)
        #expect(store.allOffLessonIsActive)

        var latch = AllOffHoldLatch()
        latch.pressingChanged(true) { store.beginAllOffHold() }
        #expect(latch.latchedMode == .rehearsal)

        // Inject both a LAN blocked event and a checklist-hiding notice during the 0.6s hold.
        store.localNetworkBlocks = [.xiaomiLAN]
        store.haPlaintextPrompt = .asking("http://203.0.113.5:8123")
        #expect(!store.allOffLessonIsActive)

        // SwiftUI's onLongPressGesture may fire onPressingChanged(false) just before perform.
        latch.pressingChanged(false) { store.beginAllOffHold() }
        #expect(latch.latchedMode == .rehearsal)

        let confirmedMode = latch.consumeOnConfirm { store.beginAllOffHold() }
        #expect(confirmedMode == .rehearsal)
        #expect(latch.latchedMode == nil)

        let rehearsalTask = store.confirmAllOffHold(mode: confirmedMode)
        #expect(rehearsalTask == nil)
        await Task.yield()
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.devices.allSatisfy { $0.isActiveOn })

        // After rehearsal completes, a new hold latches `.live` and executes real writes.
        store.haPlaintextPrompt = nil
        latch.pressingChanged(true) { store.beginAllOffHold() }
        #expect(latch.latchedMode == .live)
        latch.reset()
        #expect(latch.latchedMode == nil)

        latch.pressingChanged(true) { store.beginAllOffHold() }
        let liveMode = latch.consumeOnConfirm { store.beginAllOffHold() }
        #expect(liveMode == .live)
        let liveTask = try #require(store.confirmAllOffHold(mode: liveMode))
        _ = await liveTask.value
        #expect(!(await mock.executedCommands).isEmpty)
        await store.shutdown()
    }
}

private actor LANRetrySpyProvider: HomeProvider {
    private let snapshot: SynthesizedHome
    private(set) var retriedDeviceIds: [String?] = []

    init(snapshot: SynthesizedHome) {
        self.snapshot = snapshot
    }

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        let initial = snapshot
        return AsyncStream { continuation in
            continuation.yield(.statusChanged(.connected))
            continuation.yield(.snapshotUpdated(initial))
        }
    }

    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}

    func retryLAN(deviceId: String?) async {
        retriedDeviceIds.append(deviceId)
    }
}
