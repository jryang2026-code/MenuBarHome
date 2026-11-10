import Foundation
@testable import MijiaCore

/// Fixtures and the sleep gate shared by scheduled-command tests.
enum ScheduledCommandTestSupport {
    static let ceiling = SmartDevice(
        id: "dev_study_ceiling", name: "书房吸顶灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study_ceiling", isOn: true))
    )

    /// A device from another Mi Home. It keeps a timer from being confused with an empty store.
    static let kitchen = SmartDevice(
        id: "dev_kitchen", name: "厨房灯", roomId: "chu_fang", roomName: "厨房",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.kitchen", isOn: true))
    )

    static let plan = IntentPlan(
        intents: [DeviceIntent(targetId: "dev_study_ceiling", operation: .power(false))],
        reply: "已关闭书房吸顶灯",
        source: .local
    )

    /// A second Home Assistant that is not the one this test store starts on.
    static let otherHomeURL = "http://192.0.2.20:8123"

    static let cnAccount = MiAccount(session: MiSession(
        userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn"
    ))
    static let deAccount = MiAccount(session: MiSession(
        userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de"
    ))
    static let miLamp = SmartDevice(
        id: "1234567890", name: "米家台灯", roomId: "wo_shi", roomName: "卧室",
        model: "yeelink.light.lamp1", isOnline: true,
        kind: .light(LightSpec(entityId: "miot:1234567890:2", isOn: true)),
        accountId: cnAccount.id
    )
    static let deLamp = SmartDevice(
        id: "{{DEVICE_ab12cd34}}", name: "德国台灯", roomId: "de_wo_shi", roomName: "卧室",
        model: "yeelink.light.lamp1", isOnline: true,
        kind: .light(LightSpec(entityId: "miot:{{DEVICE_ab12cd34}}:2", isOn: true)),
        accountId: deAccount.id
    )
    static let lgTV = SmartDevice(
        id: LGWebOSProtocol.deviceId, name: "LG电视", roomId: "ke_ting", roomName: "客厅",
        model: "lg.webos.oled42c2pca", isOnline: true,
        kind: .tv(TVSpec(mediaEntityId: LGWebOSProtocol.mediaEntityId, state: "on", volumePercent: 12))
    )

    /// Home Assistant plus one Xiaomi account, both configured.
    @MainActor
    static func makeDualSourceStore(
        devices: [SmartDevice]? = nil
    ) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: devices ?? [ceiling, miLamp],
            scenes: []
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedulescope.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.hasHASource = true
        store.miAccounts = [cnAccount]
        store.miSessionMaskedUserId = cnAccount.maskedUserId
        store.miSessionScopeIdentifier = cnAccount.id
        store.homeBackend = .homeAssistant
        return (store, mock)
    }

    @MainActor
    static func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedulescope.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    /// Parks a timer inside `assistantSleep` until the test releases it. Cancellation still wakes it,
    /// so a source switch never depends on a wall-clock countdown. `waiting` is the counter a test
    /// waits on.
    @MainActor
    final class SleepGate {
        private var continuation: AsyncStream<Void>.Continuation
        private var stream: AsyncStream<Void>
        private(set) var waiting = 0

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        }

        func sleep() async {
            waiting += 1
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            waiting -= 1
        }

        func release() {
            continuation.yield(())
        }
    }
}
