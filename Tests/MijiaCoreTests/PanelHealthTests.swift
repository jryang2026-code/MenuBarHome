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
            let narrow = AllOffHeaderCopy.make(activeDeviceCount: 4, targetNames: ["台灯"], scopeName: nil)
            #expect(narrow.title == "全关 1 台")
            #expect(narrow.helper == "全关不含插座等 3 台")
            #expect(narrow.tooltip == "按住 0.6 秒关闭：台灯")

            let matched = AllOffHeaderCopy.make(activeDeviceCount: 1, targetNames: ["台灯"], scopeName: nil)
            #expect(matched.helper == nil)

            let room = AllOffHeaderCopy.make(activeDeviceCount: 2, targetNames: ["台灯"], scopeName: "书房")
            #expect(room.title == "全关 书房 1 台")

            let names = ["一", "二", "三", "四", "五", "六"]
            let listed = AllOffHeaderCopy.make(activeDeviceCount: 6, targetNames: names, scopeName: nil)
            #expect(listed.tooltip == "按住 0.6 秒关闭：一、二、三、四、五 等")
            #expect(!listed.tooltip.contains("六"))
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
        if haSource { store.hasHASource = true }
        try await store.waitForTestSnapshot()
        return store
    }
}
