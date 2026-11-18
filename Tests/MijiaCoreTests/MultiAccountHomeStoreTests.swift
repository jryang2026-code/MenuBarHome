import Foundation
import Testing
@testable import MijiaCore

/// One install, several Xiaomi accounts: a sign-in adds to the list instead of replacing it, a
/// removal keeps the others, and a home id saved before multi-account lands on the only account.
///
/// `completeMiLogin` starts a real Mi Cloud provider, so every test asserts store state only and
/// signs out at the end to cancel the provider's event task. No test awaits the network.
@MainActor
struct MultiAccountHomeStoreTests {
    private static let cnSession = MiSession(
        userId: "10010001",
        cUserId: "c-cn",
        ssecurity: "ssec-cn",
        serviceToken: "tok-cn",
        region: "cn"
    )
    private static let deSession = MiSession(
        userId: "20020002",
        cUserId: "c-de",
        ssecurity: "ssec-de",
        serviceToken: "tok-de",
        region: "de"
    )
    private static let cn = MiAccount(session: cnSession)
    private static let de = MiAccount(session: deSession)

    private static func makeSuite() -> String {
        "com.jryang1997.MenuBarMijia.multi-account.\(UUID().uuidString)"
    }

    @Test("Signing in a second account keeps the first")
    func secondSignInKeepsTheFirst() {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        defer { store.logoutMiAccount() }
        store.homeBackend = .xiaomiCloud

        store.completeMiLogin(Self.cnSession)
        store.completeMiLogin(Self.deSession)

        #expect(store.miAccounts.count == 2)
        #expect(store.miAccounts.map(\.region) == [MiCloudRegion.cn, .de])
        // The first account stays primary: adding one never relabels the panel with the newcomer.
        #expect(store.miSessionMaskedUserId == Self.cnSession.maskedUserId)
        #expect(store.serverHostSummary == "米家云端 (2 个账号)")

        let reopened = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        defer { reopened.logoutMiAccount() }
        #expect(reopened.miAccounts == store.miAccounts)
        #expect(reopened.miSessionMaskedUserId == Self.cnSession.maskedUserId)
    }

    @Test("Removing one account keeps the other")
    func removingOneAccountKeepsTheOther() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults)
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        defer { store.logoutMiAccount() }
        store.miAccounts = [Self.cn, Self.de]
        store.miSessionMaskedUserId = Self.cn.maskedUserId
        store.homeBackend = .xiaomiCloud

        store.devices = [
            SmartDevice(
                id: "cn-light",
                name: "客厅灯",
                roomId: Self.cn.id + "/r-cn",
                roomName: "客厅",
                model: "yeelink.light.ceiling22",
                isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.cn-light", isOn: true)),
                accountId: Self.cn.id,
                accountLabel: Self.cn.maskedUserId
            ),
            SmartDevice(
                id: "de-plug",
                name: "卧室插座",
                roomId: Self.de.id + "/r-de",
                roomName: "卧室",
                model: "cuco.plug.v3",
                isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.de-plug", isOn: false)),
                accountId: Self.de.id,
                accountLabel: Self.de.maskedUserId
            ),
        ]
        store.rooms = [
            RoomArea(id: Self.cn.id + "/r-cn", name: "客厅"),
            RoomArea(id: Self.de.id + "/r-de", name: "卧室"),
        ]
        store.homes = [
            HomeOption(id: Self.cn.id + "/home-cn", name: "国内家", deviceCount: 1, accountId: Self.cn.id),
            HomeOption(id: Self.de.id + "/home-de", name: "海外家", deviceCount: 1, accountId: Self.de.id),
        ]
        store.environmentReadings = [
            EnvironmentReading(id: "cn-light", label: "客厅灯", roomName: "客厅", temperature: 25.4, humidity: 55),
        ]
        store.selectedMiHomeId = Self.cn.id + "/home-cn"
        defaults.set(Self.cn.id + "/home-cn", forKey: MiCloudProvider.selectedHomeKey)

        store.logoutMiAccount(id: Self.cn.id)

        #expect(store.miAccounts == [Self.de])
        // The remaining account becomes primary.
        #expect(store.miSessionMaskedUserId == Self.deSession.maskedUserId)
        #expect(store.devices.map(\.id) == ["de-plug"])
        #expect(store.rooms.map(\.id) == [Self.de.id + "/r-de"])
        #expect(store.homes.map(\.id) == [Self.de.id + "/home-de"])
        #expect(store.environmentReadings.isEmpty)
        // The selected home belonged to the removed account.
        #expect(store.selectedMiHomeId == nil)
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == nil)
        #expect(store.toastNotice?.message == "已移除米家账号")
    }

    @Test("Logging out removes all accounts")
    func loggingOutRemovesAllAccounts() {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        store.homeBackend = .xiaomiCloud

        store.completeMiLogin(Self.cnSession)
        store.completeMiLogin(Self.deSession)
        store.logoutMiAccount()

        #expect(store.miAccounts.isEmpty)
        #expect(store.miSessionMaskedUserId == nil)
        #expect(store.serverHostSummary == "米家云端 (未登录)")
        #expect(store.toastNotice?.message == "已退出米家账号")
    }

    @Test("Leaving Xiaomi closes reauthentication and a late login preserves the selected backend")
    func lateReauthDoesNotReplaceBackend() {
        let suite = Self.makeSuite()
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        defer {
            store.logoutMiAccount()
            store.userDefaults.removePersistentDomain(forName: suite)
        }
        store.homeBackend = .xiaomiCloud
        store.isShowingMiReauth = true
        store.beginMiLogin()
        store.switchBackend(.homeAssistant)
        #expect(!store.isShowingMiReauth)
        let toast = store.toastNotice?.message
        let context = store.controlContextID
        store.completeMiLogin(Self.cnSession)
        #expect(store.homeBackend == .homeAssistant)
        #expect(store.miAccounts.map(\.id).contains(Self.cn.id))
        #expect(store.toastNotice?.message == toast)
        #expect(store.controlContextID == context)
        store.switchBackend(.demo)
        store.beginMiLogin()
        store.completeMiLogin(Self.deSession)
        #expect(store.homeBackend == .xiaomiCloud)
        #expect(store.miAccounts.count == 2)

        store.beginMiLogin()
        store.switchBackend(.demo)
        store.completeMiLogin(Self.cnSession)
        #expect(store.homeBackend == .demo)
    }

    @Test("A legacy bare selected home migrates to the only account on launch")
    func legacySelectedHomeMigrates() throws {
        let suite = Self.makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        // Exactly what a single-account build left behind: one bare session and a bare home id.
        defaults.set(try JSONEncoder().encode(Self.cnSession), forKey: MiSessionStore.fallbackDefaultsKey)
        defaults.set("home-1", forKey: MiCloudProvider.selectedHomeKey)

        let single = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(single.miAccounts.count == 1)
        #expect(single.selectedMiHomeId == Self.cn.id + "/home-1")
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == Self.cn.id + "/home-1")

        // Two accounts make a bare id ambiguous, so it is dropped instead of guessed.
        MiSessionStore.saveAccounts([Self.cn, Self.de], defaults: defaults)
        defaults.set("home-1", forKey: MiCloudProvider.selectedHomeKey)

        let several = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(several.miAccounts.count == 2)
        #expect(several.selectedMiHomeId == nil)
        #expect(defaults.string(forKey: MiCloudProvider.selectedHomeKey) == nil)
    }

    @Test("Shared did fails over to healthy secondary account on primary disconnect or HTTP 429, without retrying deviceError")
    func sharedDidFailsOverToSecondaryAccountOnDisconnectAndHTTP429() async throws {
        let sharedRecord = MiDeviceRecord(
            did: "shared-plug",
            name: "共享插座",
            model: "cuco.plug.v3",
            isOnline: true
        )
        let cnApi = FailoverStubMiCloudAPI(
            devices: [sharedRecord],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["shared-plug"], homeId: "h-cn", homeName: "家A")],
            values: [MiotFixtures.key("shared-plug", 2, 1): .bool(true)]
        )
        let deApi = FailoverStubMiCloudAPI(
            devices: [sharedRecord],
            rooms: [MiRoom(id: "r-de", name: "客厅", dids: ["shared-plug"], homeId: "h-de", homeName: "家B")],
            values: [MiotFixtures.key("shared-plug", 2, 1): .bool(true)]
        )
        let provider = MiAccountsProvider(
            accounts: [Self.cn, Self.de],
            apiFactory: { $0.region == "de" ? deApi : cnApi },
            specSource: StubSpecSource(),
            localClientFactory: { nil },
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil },
            clearSelectedHome: {}
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { events in
            await events.snapshots.contains { $0.homes.count == 2 && $0.devices.count == 1 }
        })
        #expect(await log.snapshots.last?.devices.first?.accountId == Self.cn.id)

        await cnApi.setSetPropsFailure(.http(429))
        try await provider.execute(.setSwitch(entityId: "miot:shared-plug:2", isOn: false))
        #expect(await cnApi.setPropsCalls.count == 1)
        #expect(await deApi.setPropsCalls.count == 1)

        await cnApi.setSetPropsFailure(.deviceError(code: -4004, message: "hardware fault"))
        await #expect(throws: MiCloudError.deviceError(code: -4004, message: "hardware fault")) {
            try await provider.execute(.setSwitch(entityId: "miot:shared-plug:2", isOn: true))
        }
        #expect(await deApi.setPropsCalls.count == 1)

        let cnId = Self.cn.id
        let deId = Self.de.id
        await cnApi.setGetPropsFailure(.http(503))
        await provider.refreshNow()
        #expect(await log.wait { events in
            guard let snap = await events.snapshots.last,
                  let dev = snap.devices.first(where: { $0.id == "shared-plug" }) else { return false }
            return dev.accountId == deId && dev.isOnline && !dev.telemetryStale
        })
        if case .disconnected? = await log.snapshots.last?.accountStatuses[cnId] {
        } else {
            Issue.record("Expected cn account status to remain disconnected")
        }

        let (cnRetryGate, cnRetryCont) = AsyncStream<Void>.makeStream()
        await cnApi.setGetPropsHook {
            var iter = cnRetryGate.makeAsyncIterator()
            _ = await iter.next()
        }
        let refreshTask = Task { await provider.refreshNow() }
        #expect(await log.wait { _ in await cnApi.getPropsCalls >= 3 })
        let snapDuringRetry = try #require(await log.snapshots.last)
        let devDuringRetry = try #require(snapDuringRetry.devices.first { $0.id == "shared-plug" })
        #expect(devDuringRetry.accountId == deId)
        #expect(devDuringRetry.isOnline == true)
        #expect(devDuringRetry.telemetryStale == false)
        if case .disconnected? = snapDuringRetry.accountStatuses[cnId] {
        } else {
            Issue.record("Expected cn account status to stay disconnected during retry")
        }

        await cnApi.setGetPropsHook(nil)
        await cnApi.setGetPropsFailure(nil)
        cnRetryCont.yield(())
        cnRetryCont.finish()
        await refreshTask.value

        #expect(await log.wait { events in
            guard let snap = await events.snapshots.last,
                  let dev = snap.devices.first(where: { $0.id == "shared-plug" }) else { return false }
            return dev.accountId == cnId && snap.accountStatuses[cnId] == .connected
        })

        await provider.shutdown()
    }
}

private actor FailoverStubMiCloudAPI: MiCloudAPI {
    var devices: [MiDeviceRecord]
    var rooms: [MiRoom]
    var values: [MiotPropKey: JSONValue]
    private var getPropsFailure: MiCloudError?
    private var setPropsFailure: MiCloudError?
    private var getPropsHook: (@Sendable () async -> Void)?
    private(set) var getPropsCalls = 0
    private(set) var setPropsCalls: [[MiotPropWrite]] = []

    init(devices: [MiDeviceRecord], rooms: [MiRoom], values: [MiotPropKey: JSONValue]) {
        self.devices = devices
        self.rooms = rooms
        self.values = values
    }

    func setGetPropsFailure(_ failure: MiCloudError?) { getPropsFailure = failure }
    func setSetPropsFailure(_ failure: MiCloudError?) { setPropsFailure = failure }
    func setGetPropsHook(_ hook: (@Sendable () async -> Void)?) { getPropsHook = hook }

    func deviceList() async throws -> [MiDeviceRecord] { devices }
    func homeRooms() async throws -> [MiRoom] { rooms }
    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        getPropsCalls += 1
        if let getPropsHook { await getPropsHook() }
        if let getPropsFailure { throw getPropsFailure }
        return values.filter { keys.contains($0.key) }
    }
    func setProps(_ writes: [MiotPropWrite]) async throws {
        setPropsCalls.append(writes)
        if let setPropsFailure { throw setPropsFailure }
        for w in writes { values[MiotPropKey(did: w.did, siid: w.siid, piid: w.piid)] = w.value }
    }
    func action(_ call: MiotActionCall) async throws {}
}
