import Foundation
import PreferencesTestSupport
import Testing
import UserNotifications
@testable import MenuBarMijiaApp
@testable import MijiaCore

@Suite("Interactive notifications", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct InteractiveNotificationTests {
    private actor MockProvider: HomeProvider {
        nonisolated let stream: AsyncStream<HomeProviderEvent>
        private let continuation: AsyncStream<HomeProviderEvent>.Continuation
        var executedCommands: [DeviceCommand] = []
        private var commandWaiter: CheckedContinuation<Void, Never>?

        init(devices: [SmartDevice]) {
            (stream, continuation) = AsyncStream.makeStream()
            let rooms = Array(Set(devices.map(\.roomId))).map { id in
                let name = devices.first(where: { $0.roomId == id })?.roomName ?? id
                return RoomArea(id: id, name: name)
            }
            continuation.yield(.statusChanged(.connected))
            continuation.yield(.snapshotUpdated(SynthesizedHome(rooms: rooms, devices: devices, scenes: [])))
        }

        nonisolated func events() -> AsyncStream<HomeProviderEvent> { stream }

        func execute(_ command: DeviceCommand) async throws {
            executedCommands.append(command)
            commandWaiter?.resume()
            commandWaiter = nil
        }

        func refreshNow() async {}

        func waitForFirstCommand() async {
            if !executedCommands.isEmpty { return }
            await withCheckedContinuation { commandWaiter = $0 }
        }
    }

    private static func makeStore(
        devices: [SmartDevice],
        provider: MockProvider
    ) async throws -> HomeStore {
        let ud = InMemoryUserDefaults()
        ud.set(true, forKey: "onboarding_completed_v1")
        ud.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        let store = HomeStore(provider: provider, defaults: ud)
        try await store.waitForTestSnapshot()
        store.blockControlWhileLocked = true
        store.setScreenLocked(false)
        return store
    }

    @Test("notification categories carry 1-2 safe actions, require auth, and never unlock/open high-risk devices")
    func categoryDefinitionsAndActionBounds() {
        let categories = HotkeyAndNotificationManager.makeNotificationCategories()
        #expect(categories.count == 4)
        for category in categories {
            #expect(category.actions.count >= 1 && category.actions.count <= 2)
            for action in category.actions {
                #expect(action.options.contains(.authenticationRequired))
                #expect(!action.identifier.lowercased().contains("unlock"))
                #expect(!action.identifier.lowercased().contains("open_lock"))
            }
        }
        let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.identifier, $0) })
        #expect(byId[HotkeyAndNotificationManager.safetyCategoryId]?.actions.map(\.identifier) == [
            HotkeyAndNotificationManager.turnOffActionId,
            HotkeyAndNotificationManager.viewActionId,
        ])
        #expect(byId[HotkeyAndNotificationManager.alertViewCategoryId]?.actions.map(\.identifier) == [
            HotkeyAndNotificationManager.viewActionId,
        ])
        #expect(byId[HotkeyAndNotificationManager.doorbellCategoryId]?.actions.map(\.identifier) == [
            HotkeyAndNotificationManager.viewCameraActionId,
        ])
    }

    @Test("safety notification content assigns safetyCategoryId when turnOffCommand exists and alertViewCategoryId otherwise")
    func contentCategoriesForAlerts() throws {
        let manager = HotkeyAndNotificationManager.shared
        let actionable = SafetyAlert(
            id: "longrun:plug.heater",
            deviceId: "plug.heater",
            title: "取暖器已开启超过 45 分钟",
            body: "点击关闭",
            turnOffCommand: .setSwitch(entityId: "switch.heater", isOn: false)
        )
        let actionableContent = try #require(manager.configuredSafetyNotificationContent(for: actionable))
        #expect(actionableContent.categoryIdentifier == HotkeyAndNotificationManager.safetyCategoryId)
        #expect(actionableContent.userInfo[HotkeyAndNotificationManager.alertDeviceIdKey] as? String == "plug.heater")

        let leakAlert = SafetyAlert(
            id: "sensor:leak:kitchen",
            deviceId: "sensor.leak",
            title: "厨房浸水告警",
            body: "请检查"
        )
        let leakContent = try #require(manager.configuredSafetyNotificationContent(for: leakAlert))
        #expect(leakContent.categoryIdentifier == HotkeyAndNotificationManager.alertViewCategoryId)
        #expect(leakContent.userInfo[HotkeyAndNotificationManager.alertDeviceIdKey] as? String == "sensor.leak")
    }

    @Test("turn-off action goes through normal control path, blocks when locked (keeping pending alert retryable), and rejects stale scope")
    func turnOffActionLockAndScopePolicy() async throws {
        let plug = SmartDevice(
            id: "plug.coffee",
            name: "咖啡机插座",
            roomId: "kitchen",
            roomName: "厨房",
            model: "cuco.plug.cp1",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.coffee", isOn: true, powerWatts: 1200, powerWritable: true))
        )
        let provider = MockProvider(devices: [plug])
        let store = try await Self.makeStore(devices: [plug], provider: provider)
        defer { HotkeyAndNotificationManager.shared.attachStoreForTesting(nil) }

        let manager = HotkeyAndNotificationManager.shared
        manager.attachStoreForTesting(store)

        let alert = SafetyAlert(
            id: "longrun:plug.coffee",
            deviceId: plug.id,
            title: "咖啡机插座 已开启超过 45 分钟",
            body: "点击关闭",
            turnOffCommand: .setSwitch(entityId: "switch.coffee", isOn: false)
        )
        manager.rememberPendingAlert(alert, scope: store.connectionScopeIdentifier)

        // 1. Blocked while Mac is locked, and preserves pending alert for retry after unlock.
        store.setScreenLocked(true)
        let blockedOutcome = manager.handleNotificationResponse(
            identifier: alert.id,
            actionIdentifier: HotkeyAndNotificationManager.turnOffActionId,
            userInfo: [HotkeyAndNotificationManager.alertDeviceIdKey: plug.id],
            refreshScreenLock: false
        )
        #expect(blockedOutcome == .blockedByScreenLock)
        #expect(manager.hasPendingAlert(id: alert.id))
        #expect(await provider.executedCommands.isEmpty)

        // 2. Stale home scope rejects safely without sending command.
        store.setScreenLocked(false)
        manager.rememberPendingAlert(alert, scope: "other-home-scope")
        let staleOutcome = manager.handleNotificationResponse(
            identifier: alert.id,
            actionIdentifier: HotkeyAndNotificationManager.turnOffActionId,
            userInfo: [HotkeyAndNotificationManager.alertDeviceIdKey: plug.id],
            refreshScreenLock: false
        )
        #expect(staleOutcome == .staleHome)
        #expect(await provider.executedCommands.isEmpty)

        // 3. Matching scope while unlocked executes command via normal control path.
        manager.rememberPendingAlert(alert, scope: store.connectionScopeIdentifier)
        let okOutcome = manager.handleNotificationResponse(
            identifier: alert.id,
            actionIdentifier: HotkeyAndNotificationManager.turnOffActionId,
            userInfo: [HotkeyAndNotificationManager.alertDeviceIdKey: plug.id],
            refreshScreenLock: false
        )
        #expect(okOutcome == .executedTurnOff)
        #expect(!manager.hasPendingAlert(id: alert.id))
        await provider.waitForFirstCommand()
        #expect(await provider.executedCommands == [.setSwitch(entityId: "switch.coffee", isOn: false)])
    }

    @Test("view action focuses device card when unlocked and is blocked when locked; doorbell action opens live camera")
    func viewAndDoorbellActionsRespectLockPolicy() async throws {
        let leakSensor = SmartDevice(
            id: "sensor.kitchen_leak",
            name: "厨房水浸",
            roomId: "kitchen",
            roomName: "厨房",
            model: "lumi.sensor_wleak.aq1",
            isOnline: true,
            kind: .sensor(SensorSpec(statusText: "发现漏水"))
        )
        let camera = SmartDevice(
            id: "camera.doorbell",
            name: "门口门铃",
            roomId: "entry",
            roomName: "玄关",
            model: "isa.camera.hlc7",
            isOnline: true,
            kind: .camera(CameraSpec(entityId: "camera.doorbell", isOn: true))
        )
        let provider = MockProvider(devices: [leakSensor, camera])
        let store = try await Self.makeStore(devices: [leakSensor, camera], provider: provider)
        defer { HotkeyAndNotificationManager.shared.attachStoreForTesting(nil) }

        var openedCameraId: String?
        store.onOpenCameraLiveView = { (cam: SmartDevice) in openedCameraId = cam.id }
        let manager = HotkeyAndNotificationManager.shared
        manager.attachStoreForTesting(store)

        let leakAlert = SafetyAlert(
            id: "sensor:leak:kitchen",
            deviceId: leakSensor.id,
            title: "厨房水浸告警",
            body: "发现漏水"
        )
        manager.rememberPendingAlert(leakAlert, scope: store.connectionScopeIdentifier)

        // Locked: view action is blocked and preserves pending alert.
        store.setScreenLocked(true)
        let lockedView = manager.handleNotificationResponse(
            identifier: leakAlert.id,
            actionIdentifier: HotkeyAndNotificationManager.viewActionId,
            userInfo: [HotkeyAndNotificationManager.alertDeviceIdKey: leakSensor.id],
            refreshScreenLock: false
        )
        #expect(lockedView == .blockedByScreenLock)
        #expect(store.focusedDeviceId == nil)
        #expect(manager.hasPendingAlert(id: leakAlert.id))

        let lockedDoorbell = manager.handleNotificationResponse(
            identifier: "doorbell:1",
            actionIdentifier: HotkeyAndNotificationManager.viewCameraActionId,
            userInfo: [HotkeyAndNotificationManager.doorbellDeviceIdKey: camera.id],
            refreshScreenLock: false
        )
        #expect(lockedDoorbell == .blockedByScreenLock)
        #expect(openedCameraId == nil)

        // Unlocked: view focuses sensor card; doorbell view-live opens camera live view.
        store.setScreenLocked(false)
        let okView = manager.handleNotificationResponse(
            identifier: leakAlert.id,
            actionIdentifier: HotkeyAndNotificationManager.viewActionId,
            userInfo: [HotkeyAndNotificationManager.alertDeviceIdKey: leakSensor.id],
            refreshScreenLock: false
        )
        #expect(okView == .focusedDevice(leakSensor.id))
        #expect(store.focusedDeviceId == leakSensor.id)
        #expect(!manager.hasPendingAlert(id: leakAlert.id))

        let okDoorbell = manager.handleNotificationResponse(
            identifier: "doorbell:1",
            actionIdentifier: HotkeyAndNotificationManager.viewCameraActionId,
            userInfo: [HotkeyAndNotificationManager.doorbellDeviceIdKey: camera.id],
            refreshScreenLock: false
        )
        #expect(okDoorbell == .openedDoorbellCamera(camera.id))
        #expect(openedCameraId == camera.id)
    }
}
