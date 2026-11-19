import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
@Suite("WP2c macOS Panel Split Tiles, Priority, Long-Tail & Offline Drawer", .serialized)
struct PanelSplitTilesTests {
    private func makeIsolatedStore(
        devices: [SmartDevice],
        rooms: [RoomArea] = [
            RoomArea(id: "living", name: "客厅", sortOrder: 0),
            RoomArea(id: "bedroom", name: "卧室", sortOrder: 1),
            RoomArea(id: "study", name: "书房", sortOrder: 2),
        ],
        configureDefaults: (UserDefaults) -> Void = { _ in }
    ) async throws -> (HomeStore, MockHomeProvider, String) {
        let suiteName = "com.menubarmijia.tests.splittiles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        configureDefaults(defaults)
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: rooms,
            devices: devices,
            scenes: []
        ))
        let store = HomeStore(provider: provider, defaultsSuiteName: suiteName)
        try await store.waitForTestSnapshot()
        return (store, provider, suiteName)
    }

    @Test("Typography and hit-target tokens satisfy §4.2 and compact split tiles are the default")
    func tokensAndCompactDefaultPreserveSavedPreferences() throws {
        #expect(DesignTokens.TypeSize.body == 13)
        #expect(DesignTokens.TypeSize.footnote >= 11)
        #expect(DesignTokens.minHitTarget >= 28)

        let freshSuite = "com.menubarmijia.tests.splittiles.prefs.\(UUID().uuidString)"
        let freshDefaults = try #require(UserDefaults(suiteName: freshSuite))
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }

        let freshStore = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: freshSuite)
        #expect(freshStore.isCompactGridMode == true)

        let light = SmartDevice(
            id: "l1", name: "客厅主灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.l1", isOn: true, brightnessPercent: 80))
        )
        #expect(DeviceLayoutPrefs.resolved(.auto, device: light, compactGrid: freshStore.isCompactGridMode, climatePanel: true) == .half)

        // Existing users who turned off compact grid or saved per-device full/panel sizes keep them.
        freshStore.isCompactGridMode = false
        let reloadedStore = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: freshSuite)
        #expect(reloadedStore.isCompactGridMode == false)
        #expect(DeviceLayoutPrefs.resolved(.auto, device: light, compactGrid: reloadedStore.isCompactGridMode, climatePanel: true) == .full)
        #expect(DeviceLayoutPrefs.resolved(.full, device: light, compactGrid: true, climatePanel: true) == .full)
        #expect(DeviceLayoutPrefs.resolved(.panel, device: light, compactGrid: true, climatePanel: true) == .panel)
    }

    @Test("Split-tile action layout separates left toggle and right adjustment, and retains single-action entries")
    func splitAndSingleActionRouting() async throws {
        let dimmableLight = SmartDevice(
            id: "light_dim", name: "吸顶灯", roomId: "living", roomName: "客厅",
            model: "yeelink.light.ceiling", isOnline: true,
            kind: .light(LightSpec(entityId: "light.dim", isOn: false, brightnessPercent: 75, colorTempKelvin: 4000))
        )
        let plainPlug = SmartDevice(
            id: "plug_plain", name: "普通插座", roomId: "living", roomName: "客厅",
            model: "chuangmi.plug.v1", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.plain", isOn: false))
        )
        let speaker = SmartDevice(
            id: "speaker_1", name: "小爱音箱", roomId: "living", roomName: "客厅",
            model: "xiaomi.wifispeaker.l05c", isOnline: true,
            kind: .speaker(SpeakerSpec(mediaEntityId: "media_player.speaker", state: "idle", volumePercent: 40))
        )
        let readOnlyGeneric = SmartDevice(
            id: "ro_generic", name: "只读通用设备", roomId: "living", roomName: "客厅",
            model: "xiaomi.router.ax3000", isOnline: true,
            kind: .generic(GenericSpec(deviceType: "router", typeTitle: "路由器", isOn: false, isReadOnly: true))
        )
        let readOnlyValve = SmartDevice(
            id: "ro_valve", name: "只读水阀", roomId: "living", roomName: "客厅",
            model: "xiaomi.valve.v1", isOnline: true,
            kind: .valve(ValveSpec(entityId: "valve.ro", isOpen: false, openWritable: false, closeWritable: false))
        )
        let cameraWithDrawer = SmartDevice(
            id: "cam_1", name: "客厅摄像机", roomId: "living", roomName: "客厅",
            model: "chuangmi.camera.ipc019", isOnline: true,
            kind: .camera(CameraSpec(
                entityId: "camera.living",
                isOn: true,
                nightShot: "Auto",
                availableNightShots: ["Off", "On", "Auto"],
                streamEntityId: "camera.living"
            ))
        )

        let (store, provider, suiteName) = try await makeIsolatedStore(
            devices: [dimmableLight, plainPlug, speaker, readOnlyGeneric, readOnlyValve, cameraWithDrawer]
        )
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        #expect(DeviceTileActionLayout.resolve(for: dimmableLight, store: store) == .split(primary: .togglePower))
        #expect(DeviceTileActionLayout.resolve(for: cameraWithDrawer, store: store) == .split(primary: .cameraLive))
        #expect(DeviceTileActionLayout.resolve(for: plainPlug, store: store) == .primaryOnly(.togglePower))
        #expect(DeviceTileActionLayout.resolve(for: speaker, store: store) == .adjustOnly)
        // Read-only generic cards retain their explanation drawer (.adjustOnly), while non-writable
        // drawerless devices resolve to .readOnly.
        #expect(DeviceTileActionLayout.resolve(for: readOnlyGeneric, store: store) == .adjustOnly)
        #expect(DeviceTileActionLayout.resolve(for: readOnlyValve, store: store) == .readOnly)

        // Left side of split tile toggles power without opening the adjustment drawer.
        let toggleTask = try #require(DeviceTileActionLayout.performPrimary(for: dimmableLight, store: store))
        #expect(store.expandedDeviceId == nil)
        _ = await toggleTask.value
        let executed: [DeviceCommand] = await provider.executedCommands
        #expect(executed == [.setLightPower(entityId: "light.dim", isOn: true)])

        // Right side of split tile toggles the adjustment drawer without sending a power command.
        DeviceTileActionLayout.performAdjust(for: dimmableLight, store: store)
        #expect(store.expandedDeviceId == "light_dim")
        #expect(await provider.executedCommands.count == 1)

        // Single-action adjust-only tile opens its drawer.
        DeviceTileActionLayout.performAdjust(for: speaker, store: store)
        #expect(store.expandedDeviceId == "speaker_1")
    }

    @Test("Split-tile primary toggle never bypasses high-risk confirmation, wall-switch 'this is a light' entry, or lock-screen gate")
    func splitTileRespectsConfirmationAndLockScreenGate() async throws {
        let heater = SmartDevice(
            id: "heater_1", name: "踢脚线取暖器", roomId: "bedroom", roomName: "卧室",
            model: "zhimi.heater.za2", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.heater",
                isOn: false,
                hvacMode: "off",
                availableModes: ["off", "heat"],
                targetTemperature: 24
            ))
        )
        let wallSwitch = SmartDevice(
            id: "wall_sw", name: "左键", roomId: "living", roomName: "客厅",
            model: "lumi.switch.b1nacn02", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.wall", isOn: false, powerWatts: 12, powerWritable: true))
        )
        let light = SmartDevice(
            id: "l_locked", name: "台灯", roomId: "study", roomName: "书房",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.locked", isOn: false, brightnessPercent: 50))
        )

        let (store, provider, suiteName) = try await makeIsolatedStore(devices: [heater, wallSwitch, light])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        #expect(DeviceTileActionLayout.resolve(for: heater, store: store) == .split(primary: .togglePower))
        #expect(DeviceTileActionLayout.resolve(for: wallSwitch, store: store) == .split(primary: .togglePower))

        var capturedPrompts: [ManualControlConfirmation] = []
        store.manualControlConfirmationHandler = { prompt in
            capturedPrompts.append(prompt)
            return false
        }

        // High-risk heater requires confirmation on left-zone tap; canceling sends zero commands.
        let heaterTask = DeviceTileActionLayout.performPrimary(for: heater, store: store)
        #expect(heaterTask == nil)
        #expect(capturedPrompts.count == 1)
        #expect(capturedPrompts.first?.markAsLight == nil)
        #expect(await provider.executedCommands.isEmpty)

        // Wall switch preserves the "这其实是灯" (markAsLight) confirmation entry.
        let switchTask = DeviceTileActionLayout.performPrimary(for: wallSwitch, store: store)
        #expect(switchTask == nil)
        #expect(capturedPrompts.count == 2)
        #expect(capturedPrompts.last?.markAsLight?.deviceId == "wall_sw")
        #expect(await provider.executedCommands.isEmpty)

        // Lock-screen gate blocks split-tile primary toggle when screen is locked.
        store.setScreenLocked(true)
        store.blockControlWhileLocked = true
        let lockedTask = DeviceTileActionLayout.performPrimary(for: light, store: store)
        #expect(lockedTask == nil)
        #expect(await provider.executedCommands.isEmpty)
    }

    @Test("Offline or unpowered devices collapse open drawers and sink into a collapsed bottom drawer")
    func offlineDevicesCollapseDrawerAndSinkToBottom() async throws {
        let onlineLight = SmartDevice(
            id: "on_light", name: "书房吸顶灯", roomId: "study", roomName: "书房",
            model: "yeelink.light.ceiling", isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true, brightnessPercent: 80))
        )
        let offlineLamp = SmartDevice(
            id: "off_lamp", name: "断电台灯", roomId: "study", roomName: "书房",
            model: "yeelink.light.lamp", isOnline: false,
            kind: .light(LightSpec(entityId: "light.off_lamp", isOn: false, brightnessPercent: 50))
        )

        let (store, provider, suiteName) = try await makeIsolatedStore(devices: [offlineLamp, onlineLight])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        store.favoriteDeviceIds = ["off_lamp", "on_light"]
        store.favoriteOrder = ["off_lamp", "on_light"]

        // Offline device suppresses adjustment drawer and cannot be expanded.
        #expect(DeviceTileActionLayout.resolve(for: offlineLamp, store: store) == .primaryOnly(.togglePower))
        store.toggleExpanded("off_lamp")
        #expect(store.expandedDeviceId == nil)

        // An open online device drawer automatically collapses as soon as a snapshot marks it offline.
        store.toggleExpanded("on_light")
        #expect(store.expandedDeviceId == "on_light")
        var wentOffline = onlineLight
        wentOffline.isOnline = false
        await provider.updateSnapshot(SynthesizedHome(
            rooms: store.rooms,
            devices: [offlineLamp, wentOffline],
            scenes: []
        ))
        await waitUntil { store.expandedDeviceId == nil }
        #expect(store.expandedDeviceId == nil)

        // Partition sinks offline devices out of top sections into the collapsed bottom drawer,
        // even when only 1 offline device exists.
        await provider.updateSnapshot(SynthesizedHome(
            rooms: store.rooms,
            devices: [offlineLamp, onlineLight],
            scenes: []
        ))
        await waitUntil { store.devices.first(where: { $0.id == "on_light" })?.isOnline == true }

        let partition = PanelDeviceOrganizer.partition(store.visibleDevices, customOrder: [])
        #expect(partition.online.map(\.id) == ["on_light"])
        #expect(partition.offline.map(\.id) == ["off_lamp"])

        let offlineStack = DeviceStack(
            id: PanelDeviceOrganizer.offlineSectionId,
            source: .offline,
            title: "离线或未通电",
            devices: [offlineLamp]
        )
        #expect(!offlineStack.isOpen(expandedStacks: []))
        #expect(offlineStack.isOpen(expandedStacks: [PanelDeviceOrganizer.offlineSectionId]))
        #expect(offlineStack.canCollapse())

        // Respects existing hideOfflineDevices preference.
        store.hideOfflineDevices = true
        let hiddenPartition = PanelDeviceOrganizer.partition(store.visibleDevices, customOrder: [])
        #expect(hiddenPartition.offline.isEmpty)
    }

    @Test("Online ordering prioritizes favorites, frequent habits, and active devices; >8 devices in All view offer long-tail expand and room browse")
    func priorityOrderingAndOverEightLongTail() async throws {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        var devices: [SmartDevice] = []
        let roomIds = [("living", "客厅"), ("bedroom", "卧室"), ("study", "书房")]
        for idx in 1...10 {
            let room = roomIds[(idx - 1) % roomIds.count]
            let isOn = (idx == 4 || idx == 9)
            devices.append(SmartDevice(
                id: "dev_\(idx)",
                name: "设备 \(idx)",
                roomId: room.0,
                roomName: room.1,
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.dev_\(idx)", isOn: isOn, brightnessPercent: 60))
            ))
        }
        devices.append(SmartDevice(
            id: "dev_offline",
            name: "离线插座",
            roomId: "study",
            roomName: "书房",
            model: "chuangmi.plug.v1",
            isOnline: false,
            kind: .plug(PlugSpec(switchEntityId: "switch.offline", isOn: false))
        ))

        let (store, _, suiteName) = try await makeIsolatedStore(devices: devices)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        store.favoriteDeviceIds = ["dev_2"]
        store.favoriteOrder = ["dev_2"]
        // Record dev_7 as frequently used in this time bucket.
        var memory = store.userHabitMemory
        for _ in 0..<3 {
            _ = memory.record(
                utterance: nil,
                intents: [DeviceIntent(targetId: "dev_7", operation: .power(true))],
                devices: devices,
                scenes: [],
                now: now
            )
        }
        store.userHabitMemory = memory

        let orderedOnline = PanelDeviceOrganizer.prioritizeOnline(
            devices.filter(\.isOnline),
            favoriteIds: store.favoriteDeviceIds,
            favoriteOrder: store.favoriteOrder,
            habitOrder: store.userHabitMemory.usageOrder(for: now),
            customOrder: [],
            isActive: { store.presentsAsActive($0) }
        )
        // Favorite (dev_2) -> Habit-frequent (dev_7) -> Active on (dev_4, dev_9) -> Remaining idle in snapshot order.
        #expect(Array(orderedOnline.prefix(4).map(\.id)) == ["dev_2", "dev_7", "dev_4", "dev_9"])

        // Saved customOrder overrides automatic ranking for existing users.
        let customRanked = PanelDeviceOrganizer.prioritizeOnline(
            devices.filter(\.isOnline),
            favoriteIds: store.favoriteDeviceIds,
            favoriteOrder: store.favoriteOrder,
            habitOrder: store.userHabitMemory.usageOrder(for: now),
            customOrder: ["dev_10", "dev_1"],
            isActive: { store.presentsAsActive($0) }
        )
        #expect(Array(customRanked.prefix(2).map(\.id)) == ["dev_10", "dev_1"])

        // Over-8 long-tail slicing in All view (`listCut == .all`): caps initial overview at 8 and reports 2 hidden.
        let collapsedOverview = PanelDeviceOrganizer.overviewSlice(
            orderedOnline: orderedOnline,
            listCut: .all,
            isExpanded: false,
            keepingVisibleIds: []
        )
        #expect(collapsedOverview.visible.count == 8)
        #expect(collapsedOverview.hiddenCount == 2)
        #expect(collapsedOverview.showsLongTailControl == true)

        // Expanding reveals all 10 online devices and keeps the "Show Less" toggle visible.
        let expandedOverview = PanelDeviceOrganizer.overviewSlice(
            orderedOnline: orderedOnline,
            listCut: .all,
            isExpanded: true,
            keepingVisibleIds: []
        )
        #expect(expandedOverview.visible.count == 10)
        #expect(expandedOverview.hiddenCount == 0)
        #expect(expandedOverview.showsLongTailControl == true)

        // Room cut (`listCut == .room(...)`) never truncates devices into a long tail.
        let roomCutOverview = PanelDeviceOrganizer.overviewSlice(
            orderedOnline: orderedOnline,
            listCut: .room("living"),
            isExpanded: false,
            keepingVisibleIds: []
        )
        #expect(roomCutOverview.visible.count == 10)
        #expect(roomCutOverview.showsLongTailControl == false)
    }

    @Test("Split-tile, long-tail, and offline-drawer copy is localized in Simplified Chinese, Traditional Chinese, and English")
    func localizationCompleteness() {
        let zhHans = L10n.$overrideLanguage.withValue(.zhHans) {
            [
                PanelDeviceOrganizer.offlineDrawerTitle(),
                PanelDeviceOrganizer.longTailExpandTitle(count: 4),
                PanelDeviceOrganizer.longTailCollapseTitle(),
                PanelDeviceOrganizer.browseByRoomTitle(),
                DeviceTileActionLayout.adjustTooltip(isExpanded: false),
            ]
        }
        let zhHant = L10n.$overrideLanguage.withValue(.zhHant) {
            [
                PanelDeviceOrganizer.offlineDrawerTitle(),
                PanelDeviceOrganizer.longTailExpandTitle(count: 4),
                PanelDeviceOrganizer.longTailCollapseTitle(),
                PanelDeviceOrganizer.browseByRoomTitle(),
                DeviceTileActionLayout.adjustTooltip(isExpanded: false),
            ]
        }
        let en = L10n.$overrideLanguage.withValue(.en) {
            [
                PanelDeviceOrganizer.offlineDrawerTitle(),
                PanelDeviceOrganizer.longTailExpandTitle(count: 4),
                PanelDeviceOrganizer.longTailCollapseTitle(),
                PanelDeviceOrganizer.browseByRoomTitle(),
                DeviceTileActionLayout.adjustTooltip(isExpanded: false),
            ]
        }

        #expect(zhHans == ["离线或未通电", "展开其余 4 台设备", "收起其余设备", "按房间找", "展开调节"])
        #expect(zhHant == ["離線或未通電", "展開其餘 4 臺裝置", "收起其餘裝置", "按房間找", "展開調節"])
        #expect(en == ["Offline or Unpowered", "Show 4 More Devices", "Show Less", "By Room", "Adjust controls"])
    }
}
