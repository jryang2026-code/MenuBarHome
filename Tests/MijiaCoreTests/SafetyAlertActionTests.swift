import Foundation
import Testing
@testable import MijiaCore

/// 守护提醒的通知按钮等同于一次手动操作：锁屏拦截、跨家居保护、失败要说明 (#143)。
struct SafetyAlertActionTests {
    static let light = SmartDevice(
        id: "dev_study_ceiling", name: "书房吸顶灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study_ceiling", isOn: true))
    )

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.light], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.safetyalert.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    private func alert(deviceId: String = "dev_study_ceiling") -> SafetyAlert {
        SafetyAlert(
            id: "longrun:\(deviceId)",
            deviceId: deviceId,
            title: "书房吸顶灯 已开启超过 45 分钟",
            body: "当前功率 120W，如需关闭可直接点击通知按钮。",
            turnOffCommand: .setLightPower(entityId: "light.study_ceiling", isOn: false)
        )
    }

    @Test("A locked Mac refuses the notification's turn-off action")
    @MainActor
    func lockedScreenRefusesAlertAction() async throws {
        let (store, mock) = try await makeStore()
        store.setScreenLocked(true)

        #expect(store.executeSafetyAlertAction(alert()) == nil)
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("An alert for a device that is no longer in the current home sends nothing")
    @MainActor
    func staleAlertSendsNothing() async throws {
        let (store, mock) = try await makeStore()

        // The notification was delivered from another home, account or source; that device is gone.
        #expect(store.executeSafetyAlertAction(alert(deviceId: "dev_other_home")) == nil)
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message == "该提醒已不适用于当前家居，未关闭设备")
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A failed turn-off names the device and reports the failure")
    @MainActor
    func failedSendShowsErrorToast() async throws {
        let (store, mock) = try await makeStore()
        await mock.setShouldFail(true)

        let task = try #require(store.executeSafetyAlertAction(alert()))
        await task.value

        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message == "「书房吸顶灯」关闭失败")
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A successful turn-off sends the command through the shared write path")
    @MainActor
    func successfulSendExecutesCommand() async throws {
        let (store, mock) = try await makeStore()

        let task = try #require(store.executeSafetyAlertAction(alert()))
        await task.value

        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
    }

    @Test("An alert without a turn-off command does nothing")
    @MainActor
    func readOnlyAlertDoesNothing() async throws {
        let (store, mock) = try await makeStore()
        let offline = SafetyAlert(id: "offline:dev", deviceId: "dev_study_ceiling", title: "已离线", body: "")

        #expect(store.executeSafetyAlertAction(offline) == nil)
        #expect(await mock.executedCommands.isEmpty)
    }
}
