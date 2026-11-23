import AppKit
import Foundation
import PreferencesTestSupport
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

private actor LANRetrySpyProvider: HomeProvider {
    private let snapshot: SynthesizedHome
    private(set) var retriedDeviceIds: [String?] = []
    init(snapshot: SynthesizedHome) { self.snapshot = snapshot }
    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        let initial = snapshot
        return AsyncStream { continuation in
            continuation.yield(.statusChanged(.connected))
            continuation.yield(.snapshotUpdated(initial))
        }
    }
    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}
    func retryLAN(deviceId: String?) async { retriedDeviceIds.append(deviceId) }
}

extension PanelPresentationTests {
@MainActor
@Suite("Pre-release macOS UI & integration fixes", .serialized)
struct PreReleaseMacOSUIFixesTests {

    @Test("Quick-index keyboard navigation, SliderStepSnap bounds, URL toggle state check, UnsupportedDeviceScanner invalidation, favorite reorder, and AutomationEngine polling check")
    func quickIndexSliderStepUrlToggleScannerFavoritesAndPolling() async throws {
        // One instance for the seed, the store and the assertions: a second
        // `UserDefaults(suiteName:)` reads through cfprefsd and can serve a stale cache (#309).
        let defaults = InMemoryUserDefaults()
        defer { PanelQuickIndexState.shared.clear() }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")

        let room = RoomArea(id: "r1", name: "客厅", sortOrder: 0)
        let devices = (1...11).map { idx in
            SmartDevice(id: "d\(idx)", name: "灯 \(idx)", roomId: room.id, roomName: room.name, model: "test.light", isOnline: true, kind: .light(LightSpec(entityId: "light.d\(idx)", isOn: true)))
        }
        let mock = MockHomeProvider(snapshot: SynthesizedHome(rooms: [room], devices: devices))
        let store = HomeStore(provider: mock, defaults: defaults)
        try await store.waitForTestSnapshot()

        let drawnOrder = PanelQuickIndexOrder(deviceIds: devices.map(\.id).reversed())
        #expect(drawnOrder.deviceIds.count == 9 && drawnOrder.navigableIds.count == 11)
        PanelQuickIndexState.shared.register(drawnOrder, theme: .classic)
        PanelQuickIndexState.shared.clear(theme: .liquidGlass)
        #expect(PanelQuickIndexState.shared.registeredTheme == .classic)
        PanelQuickIndexState.shared.moveFocus(delta: 1, store: store, theme: .classic)
        #expect(store.focusedDeviceId == "d11")
        PanelQuickIndexState.shared.moveFocus(delta: -1, store: store, theme: .classic)
        #expect(store.focusedDeviceId == "d1")
        store.focusedDeviceId = nil
        let before = await mock.executedCommands.count
        PanelQuickIndexState.shared.toggleFocusedDevice(store: store, theme: .classic)
        await waitUntil { await mock.executedCommands.count > before }
        #expect(await mock.executedCommands.last == .setLightPower(entityId: "light.d11", isOn: false))

        #expect(SliderStepSnap.snap(1.0, in: 1...99, step: 2) == 1)
        #expect(SliderStepSnap.snap(2.1, in: 1...99, step: 2) == 3)
        #expect(SliderStepSnap.snap(98.4, in: 1...99, step: 2) == 99)
        #expect(SliderStepSnap.snap(6520, in: 2000...6535, step: 100) == 6535)
        #expect(SliderStepSnap.step(from: 6535, by: -100, in: 2000...6535, step: 100) == 6500)
        #expect(SliderStepSnap.step(from: 10, by: -8, in: 0...10, step: 8) == 8)
        let extreme: ClosedRange<Double> = -1e308...1e308
        #expect(SliderStepSnap.snap(0, in: extreme, step: 1) == -1e308)
        #expect(SliderStepSnap.step(from: 0, by: 1, in: extreme, step: 1) == -1e308)

        let handler = URLCommandHandler()
        handler.windowVisibilityHandler = {}
        handler.confirmationHandler = { _ in
            store.devices[0] = SmartDevice(id: "d1", name: "灯 1", roomId: room.id, roomName: room.name, model: "test.light", isOnline: true, kind: .light(LightSpec(entityId: "light.d1", isOn: false)))
            return true
        }
        let cmdsBeforeLink = await mock.executedCommands.count
        await handler.handle(try #require(URL(string: "menumijia://toggle?device=d1&id=ext-1")), in: store)
        #expect(await mock.executedCommands.count == cmdsBeforeLink)
        #expect(store.lastRaycastCommandFeedback?.isError == false)

        let scanner = UnsupportedDeviceScanner.shared
        defer { scanner.reset() }
        store.homeBackend = .demo
        await scanner.scan(store: store)
        #expect(scanner.lastScannedAt != nil)
        store.serverURLString = "https://other-ha.example:8123"
        scanner.invalidateIfContextChanged(for: store)
        #expect(scanner.lastScannedAt == nil && !scanner.isScanning)

        let rooms = [RoomArea(id: "living", name: "客厅", sortOrder: 0), RoomArea(id: "bedroom", name: "卧室", sortOrder: 1), RoomArea(id: "study", name: "书房", sortOrder: 2)]
        let favDevices = [
            SmartDevice(id: "l1", name: "客厅灯", roomId: "living", roomName: "客厅", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.l1", isOn: true))),
            SmartDevice(id: "b1", name: "主灯", roomId: "bedroom", roomName: "卧室", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.b1", isOn: true))),
            SmartDevice(id: "s1", name: "台灯", roomId: "study", roomName: "书房", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.s1", isOn: true))),
            SmartDevice(id: "b2", name: "床头灯", roomId: "bedroom", roomName: "卧室", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.b2", isOn: true)))
        ]
        let favStore = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(rooms: rooms, devices: favDevices)),
            defaults: InMemoryUserDefaults()
        )
        try await favStore.waitForTestSnapshot()
        favStore.favoriteDeviceIds = ["l1", "b1", "s1", "b2"]
        favStore.favoriteOrder = ["l1", "b1", "s1", "b2"]
        #expect(favStore.selectRoom("bedroom"))
        favStore.moveFavorite(deviceId: "b2", direction: -1)
        #expect(favStore.favoriteOrder == ["l1", "b2", "b1", "s1"])

        #expect(!AutomationEngine.needsContextPolling([]))
        #expect(!AutomationEngine.needsContextPolling([AutomationRule(trigger: .cameraInUse, action: .devices(ids: ["d1"], isOn: true), isEnabled: false)]))
        #expect(!AutomationEngine.needsContextPolling([AutomationRule(trigger: .away, action: .devices(ids: ["d1"], isOn: false), isEnabled: true)]))
        #expect(AutomationEngine.needsContextPolling([AutomationRule(trigger: .away, action: .devices(ids: ["d1"], isOn: false), isEnabled: true, conditions: AutomationConditions(wifi: .inAny(["HomeWiFi"])))]))
        #expect(AutomationEngine.needsContextPolling([AutomationRule(trigger: .cameraInUse, action: .devices(ids: ["d1"], isOn: true), isEnabled: true)]))
    }

    @Test("HAConnectionSaveGuard, LGWebOSSettingsSaveGuard, SettingsUnsavedChanges, and settings disclosures preserve credentials and user collapse")
    func saveGuardsUnsavedChangesAndSettingsDisclosures() async throws {
        #expect(HAConnectionSaveGuard.resolve(draftToken: "  ", initialLookupWasUnavailable: true, retryLookup: { .unavailable }) == .blockedKeychainUnavailable)
        #expect(HAConnectionSaveGuard.resolve(draftToken: "", initialLookupWasUnavailable: true, retryLookup: { .value(Data("secret-ha-token".utf8)) }) == .proceed(token: "secret-ha-token", clearUnavailableFlag: true))
        #expect(HAConnectionSaveGuard.resolve(draftToken: "new-token", initialLookupWasUnavailable: true, retryLookup: { .unavailable }) == .proceed(token: "new-token", clearUnavailableFlag: true))
        #expect(HAConnectionSaveGuard.resolve(draftToken: "", initialLookupWasUnavailable: false, retryLookup: { .unavailable }) == .proceed(token: "", clearUnavailableFlag: false))

        let fallback = KeychainHelper.defaultNASURL
        #expect(HAConnectionSaveGuard.initialURLDraft(storedURL: fallback, hasHASource: false).isEmpty)
        #expect(HAConnectionSaveGuard.initialURLDraft(storedURL: fallback, hasHASource: true) == fallback)
        #expect(HAConnectionSaveGuard.effectiveURL("  ") == fallback)
        #expect(!HAConnectionSaveGuard.showsPlaintextWarning(forDraft: "") && !HAConnectionSaveGuard.showsPlaintextWarning(forDraft: "http://localhost:8123"))
        #expect(HAConnectionSaveGuard.showsPlaintextWarning(forDraft: "http://ha.ddns.example:8123"))
        #expect(HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: .haToken) && !HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: .miAccount))

        final class ToggleableVaultBox: @unchecked Sendable {
            private let lock = NSLock()
            var blob: Data?
            var readable: Bool
            var writable: Bool
            init(blob: Data?, readable: Bool, writable: Bool = true) {
                self.blob = blob
                self.readable = readable
                self.writable = writable
            }
            var storage: CredentialVault.Storage {
                CredentialVault.Storage(
                    read: { [self] in lock.withLock { readable ? (blob.map(CredentialVault.Storage.ReadResult.found) ?? .notFound) : .unavailable } },
                    write: { [self] data in lock.withLock { guard readable && writable else { return false }; blob = data; return true } }
                )
            }
        }

        let defaults = InMemoryUserDefaults()
        let seeded = try #require(CredentialVault.encode([HAConnectionSaveGuard.haTokenAccount: Data("secret-ha-token".utf8)]))
        let box = ToggleableVaultBox(blob: seeded, readable: false, writable: false)
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            credentialVault: CredentialVault(storage: box.storage),
            defaults: defaults
        )
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        let initial = HAConnectionSaveGuard.loadInitialToken(from: store)
        #expect(initial.token.isEmpty && initial.lookupWasUnavailable)
        var draft = initial.token
        var wasUnavailable = initial.lookupWasUnavailable
        HAConnectionSaveGuard.save(serverURL: "https://new-ha.example:8123", tokenDraft: &draft, initialLookupWasUnavailable: &wasUnavailable, in: store)
        #expect(wasUnavailable && store.toastNotice?.isError == true && box.blob == seeded)

        var lgEnabled = false
        var lgHost = "192.0.2.50"
        var lgMac = "AA:BB:CC:DD:EE:FF"
        #expect(!LGWebOSSettingsSaveGuard.toggleEnabled(true, isEnabled: &lgEnabled, hostDraft: lgHost, macDraft: lgMac, in: store))
        #expect(!lgEnabled && !store.lgConfig.isEnabled)

        box.readable = true
        box.writable = true
        HAConnectionSaveGuard.save(serverURL: "https://new-ha.example:8123", tokenDraft: &draft, initialLookupWasUnavailable: &wasUnavailable, in: store)
        #expect(!wasUnavailable && draft == "secret-ha-token" && store.loadHAToken() == "secret-ha-token")

        lgEnabled = true
        #expect(LGWebOSSettingsSaveGuard.saveDrafts(isEnabled: &lgEnabled, hostDraft: &lgHost, macDraft: &lgMac, in: store))
        #expect(store.applyLGClientKey("saved-key"))
        box.writable = false
        let resetTask = try #require(LGWebOSSettingsSaveGuard.resetTrustAndPair(isEnabled: &lgEnabled, hostDraft: &lgHost, macDraft: &lgMac, in: store))
        #expect(await resetTask.value == false && store.lgConfig.clientKey == "saved-key")
        await store.lgWebOSClient?.shutdown()

        var genState = GeneralSettingsDisclosure.State()
        genState.expandIfNeeded(forRequestedTab: .appearance)
        #expect(genState.isExpanded)
        genState.isExpanded = false
        genState.applyInitialNonDefaultIfNeeded(panelTheme: .classic, panelHeight: .standard, isCompactGridMode: true, climatePanelModule: true, hideGroupedLights: true)
        #expect(!genState.isExpanded)
        genState.expandIfNeeded(forHighlight: .panelHeight)
        genState.expandIfNeeded(forHighlight: nil)
        #expect(genState.isExpanded)

        var connState = ConnectionSettingsDisclosure.State()
        connState.applyInitialDefaultsIfNeeded(accountCount: 1, isDualSourceActive: true)
        #expect(connState.isExpanded)
        connState.isExpanded = false
        connState.applyInitialDefaultsIfNeeded(accountCount: 1, isDualSourceActive: true)
        #expect(!connState.isExpanded)
        connState.expandForHighlightIfNeeded(.dualSourceFusion)
        #expect(connState.isExpanded)

        var regionState = MiAccountSection.RegionDisclosureState()
        regionState.applyInitialNonDefaultIfNeeded(region: .sg)
        #expect(regionState.isExpanded)
        regionState.isExpanded = false
        regionState.applyInitialNonDefaultIfNeeded(region: .sg)
        #expect(!regionState.isExpanded)

        let unsaved = SettingsUnsavedChanges()
        var saved: [String] = []
        var discarded = 0
        unsaved.register("ha", .init(title: "Home Assistant", isDirty: true, save: { saved.append("ha"); return true }, discard: { discarded += 1 }))
        #expect(!unsaved.resolveBeforeLeaving(allowCancel: true) { _, _ in .cancel })
        #expect(unsaved.resolveBeforeLeaving(allowCancel: true) { _, _ in .save } && saved == ["ha"])
        #expect(unsaved.resolveBeforeLeaving(allowCancel: false) { _, _ in .discard } && discarded == 1)
    }

    @Test("ActivityStackView collapse, DeviceFacetSection nil select binding, MenuBarPanelController idle timer, card context menus, LG discovery, stale sensor/climate a11y, and AllOffHoldLatch rehearsal lock")
    func activityStackFacetsMenuBarTimerCardsStaleA11yAndAllOffLatch() async throws {
        let defaults = InMemoryUserDefaults()
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()),
            defaults: defaults
        )
        try await store.waitForTestSnapshot()
        _ = NSApplication.shared

        L10n.$overrideLanguage.withValue(.en) {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let a1 = RecordedSafetyAlert(alert: SafetyAlert(id: "offline:d1", deviceId: "d1", title: "Kettle Offline", body: "Check outlet.", turnOffCommand: nil), scope: "demo", date: t0)
            let a2 = RecordedSafetyAlert(alert: SafetyAlert(id: "battery:d2", deviceId: "d2", title: "Low Battery", body: "9%.", turnOffCommand: nil), scope: "demo", date: t0)
            let items = PanelActivityFeed.items(notices: [], safety: [a1, a2], doorbells: [], dismissedIds: [])
            #expect(ActivityStackPolicy.ordinaryCapsuleSummary(labels: ["Kettle Offline", "Low Battery"]) == "Kettle Offline and 1 more")
            for theme in PanelTheme.allCases {
                let collapsed = NSHostingView(rootView: ActivityStackView(activities: items, store: store, isExpanded: .constant(false), expandedViewportHeight: 220, theme: theme, dismiss: { _ in }, clear: {}, label: { _ in "Kettle" }, content: { _ in Text("Card").padding(12) }).frame(width: 340))
                let expanded = NSHostingView(rootView: ActivityStackView(activities: items, store: store, isExpanded: .constant(true), expandedViewportHeight: 220, theme: theme, dismiss: { _ in }, clear: {}, label: { _ in "Kettle" }, content: { _ in Text("Card").padding(12) }).frame(width: 340))
                collapsed.layoutSubtreeIfNeeded()
                expanded.layoutSubtreeIfNeeded()
                #expect(expanded.fittingSize.height > collapsed.fittingSize.height)
            }
        }

        let options = [MiotFacetOption(value: 1, label: "Silent"), MiotFacetOption(value: 2, label: "Turbo")]
        var control = FacetControl(id: "2.1", kind: .select, name: "mode", title: "Mode", serviceName: "fan", value: nil, options: options, isWritable: true, writesByDefault: true, isHighValue: true)
        var picked: [Int] = []
        let binding = DeviceFacetSection.selectBinding(for: control) { picked.append($0) }
        #expect(binding.wrappedValue == nil)
        binding.wrappedValue = 1
        #expect(picked == [1])
        control.value = .number(99)
        #expect(DeviceFacetSection.selectedOptionValue(for: control) == nil)

        let controller = MenuBarPanelController(userDefaults: defaults)
        controller.presentsActively = false
        controller.install(with: store)
        defer { controller.uninstall() }
        #expect(!controller.isLabelTimerRunning)
        let now = Date()
        store.scheduledCommands = [ScheduledCommand(reply: "Lamp off", fireDate: now.addingTimeInterval(30), plan: IntentPlan(intents: [], reply: "Lamp off", source: .local))]
        controller.updateLabelTimer(now: now)
        #expect(controller.isLabelTimerRunning)
        store.scheduledCommands = []
        controller.updateLabelTimer(now: now)
        #expect(!controller.isLabelTimerRunning)

        let light = SmartDevice(id: "l1", name: "客厅灯", roomId: "r1", roomName: "客厅", model: "yeelink.light.lamp4", isOnline: true, kind: .light(LightSpec(entityId: "light.1", isOn: true)))
        let curtain = SmartDevice(id: "c1", name: "客厅窗帘", roomId: "r1", roomName: "客厅", model: "fixture.curtain", isOnline: true, kind: .cover(CoverSpec(entityId: "cover.curtain", subtype: .curtain, positionPercent: 50, positionWritable: true)))
        let generic = SmartDevice(id: "gen1", name: "未知设备", roomId: "r1", roomName: "客厅", model: "fixture.generic", isOnline: true, kind: .generic(GenericSpec(deviceType: "switch", typeTitle: "开关", isOn: true, isReadOnly: false)))
        #expect(DeviceCardView.showsAllOffMenuOption(for: light) && !DeviceCardView.showsAllOffMenuOption(for: curtain) && !DeviceCardView.showsAllOffMenuOption(for: generic))
        #expect(ClassicDeviceCardView.showsAllOffMenuOption(for: light) && !ClassicDeviceCardView.showsAllOffMenuOption(for: curtain) && !ClassicDeviceCardView.showsAllOffMenuOption(for: generic))

        var hostDraft = "8.8.8.8"
        LGWebOSSettingsSection.handleDiscoveryResult([], hostHint: hostDraft, store: store) { hostDraft = $0 }
        #expect(store.toastNotice?.isError == true && store.toastNotice?.message.contains("8.8.8.8") == true)
        LGWebOSSettingsSection.handleDiscoveryResult([LGWebOSDiscoveredTV(host: "192.168.1.55", friendlyName: "LG C2")], hostHint: "8.8.8.8", store: store) { hostDraft = $0 }
        #expect(hostDraft == "192.168.1.55" && store.toastNotice?.isError == false)

        let sSpec = SensorSpec(temperature: 26.4, humidity: 58, battery: 87)
        let staleSensor = SmartDevice(id: "sensor-1", name: "书房温湿度计", roomId: "r1", roomName: "书房", model: "miaomiaoce.sensor_ht.t2", isOnline: true, kind: .sensor(sSpec), telemetryStale: true)
        #expect(SensorCardView.collapsesAccessibilityChildren(isExpanded: false, isStale: false))
        #expect(!SensorCardView.collapsesAccessibilityChildren(isExpanded: false, isStale: true))
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(!SensorCardView.accessibilitySummary(device: staleSensor, spec: sSpec, isStale: true).contains("26.4"))
        }

        let onClimateSpec = ClimateSpec(entityId: "climate.living_ac", isOn: true, hvacMode: "cool", availableModes: ["off", "cool", "heat"], targetTemperature: 24, currentTemperature: 27, minTemp: 16, maxTemp: 30, step: 1)
        let offClimateSpec = ClimateSpec(entityId: "climate.living_ac", isOn: false, hvacMode: "off", availableModes: ["off", "cool", "heat"], targetTemperature: 24, currentTemperature: 27, minTemp: 16, maxTemp: 30, step: 1)
        #expect(ClimatePanelModule.powerToggleTurnsOff(onClimateSpec) && !ClimatePanelModule.powerToggleTurnsOff(offClimateSpec))

        let plainSwitch = SmartDevice(id: "switch-plain", name: "走廊墙壁开关", roomId: "r1", roomName: "走廊", model: "lumi.switch.b1lacn02", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "miot:switch-plain:2", isOn: true)))
        let spy = LANRetrySpyProvider(snapshot: SynthesizedHome(devices: [plainSwitch, staleSensor, light], scenes: []))
        let spyStore = HomeStore(provider: spy, defaults: InMemoryUserDefaults())
        try await spyStore.waitForTestSnapshot()
        #expect(!spyStore.hasDetailDrawer(for: plainSwitch))
        spyStore.deviceTransportDiagnostics = [plainSwitch.id: DeviceTransportDiagnostics(route: .cooldown, consecutiveFailures: 3)]
        #expect(spyStore.hasDetailDrawer(for: plainSwitch) && !spyStore.hasDetailDrawer(for: staleSensor))
        await spyStore.retryDeviceLAN(plainSwitch.id).value
        #expect(await spy.retriedDeviceIds == [plainSwitch.id])

        spyStore.recordOnboardingMilestone(.searchedDevice)
        #expect(spyStore.allOffLessonIsActive)
        var latch = AllOffHoldLatch()
        latch.pressingChanged(true) { spyStore.beginAllOffHold() }
        #expect(latch.latchedMode == .rehearsal)
        spyStore.localNetworkBlocks = [.xiaomiLAN]
        spyStore.haPlaintextPrompt = .asking("http://203.0.113.5:8123")
        latch.pressingChanged(false) { spyStore.beginAllOffHold() }
        let confirmedMode = latch.consumeOnConfirm { spyStore.beginAllOffHold() }
        #expect(confirmedMode == .rehearsal && spyStore.confirmAllOffHold(mode: confirmedMode) == nil)
        await spyStore.shutdown()
    }
}
}
