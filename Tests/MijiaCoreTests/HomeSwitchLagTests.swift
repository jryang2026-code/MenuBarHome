import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

private actor HomeSwitchGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var enterCount = 0
    private var released = false

    func enter() async {
        enterCount += 1
        let pending = entryWaiters
        entryWaiters.removeAll()
        for waiter in pending { waiter.resume() }
        if released { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if released {
                    cont.resume()
                } else {
                    waiters.append(cont)
                }
            }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func waitUntilEntered(count: Int = 1) async {
        while enterCount < count {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                entryWaiters.append(cont)
            }
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    var entries: Int { enterCount }
}

private actor GatedMiCloudAPI: MiCloudAPI {
    let devices: [MiDeviceRecord]
    let rooms: [MiRoom]
    var values: [MiotPropKey: JSONValue]
    private var propGatesByDid: [String: HomeSwitchGate] = [:]
    private(set) var deviceListCalls = 0
    private(set) var getPropsDids: [[String]] = []

    init(devices: [MiDeviceRecord], rooms: [MiRoom], values: [MiotPropKey: JSONValue]) {
        self.devices = devices
        self.rooms = rooms
        self.values = values
    }

    func setPropGate(_ gate: HomeSwitchGate?, forDid did: String) {
        propGatesByDid[did] = gate
    }

    func setValue(_ key: MiotPropKey, _ value: JSONValue) {
        values[key] = value
    }

    func deviceList() async throws -> [MiDeviceRecord] {
        deviceListCalls += 1
        return devices
    }

    func homeRooms() async throws -> [MiRoom] { rooms }

    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        let dids = Array(Set(keys.map(\.did))).sorted()
        getPropsDids.append(dids)
        for did in dids {
            if let gate = propGatesByDid[did] {
                await gate.enter()
            }
        }
        return values.filter { keys.contains($0.key) }
    }

    func setProps(_ writes: [MiotPropWrite]) async throws {}
    func action(_ call: MiotActionCall) async throws {}
}

private actor ControlledHomeSwitchProvider: HomeProvider {
    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var attachWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var switchedGenerations: [UInt64] = []

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { cont in
            Task { await self.setContinuation(cont) }
        }
    }

    private func setContinuation(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        continuation = cont
        let waiters = attachWaiters
        attachWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilAttached() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if continuation != nil {
                cont.resume()
            } else {
                attachWaiters.append(cont)
            }
        }
    }

    func emit(_ event: HomeProviderEvent) {
        continuation?.yield(event)
    }

    func switchMiHome(generation: UInt64) async {
        switchedGenerations.append(generation)
    }

    func refreshNow() async {}
    func execute(_ command: DeviceCommand) async throws {}
    func shutdown() async { continuation?.finish() }
}

@MainActor
private func waitForMainActor(
    _ label: String,
    condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite(.timeLimit(.minutes(1)))
struct HomeSwitchLagTests {
    private static let sessionA = MiSession(
        userId: "1001",
        cUserId: "c1001",
        ssecurity: "c2VjcmV0",
        serviceToken: "tokA",
        region: "cn"
    )
    private static let sessionB = MiSession(
        userId: "2002",
        cUserId: "c2002",
        ssecurity: "c2VjcmV0",
        serviceToken: "tokB",
        region: "de"
    )
    private static let devA = MiDeviceRecord(did: "dev-a", name: "A 灯", model: "yeelink.light.ceiling22", isOnline: true)
    private static let devB = MiDeviceRecord(did: "dev-b", name: "B 灯", model: "yeelink.light.ceiling22", isOnline: true)
    private static let twoHomeRooms = [
        MiRoom(id: "room-a", name: "客厅", dids: ["dev-a"], homeId: "home-a", homeName: "A 家"),
        MiRoom(id: "room-b", name: "卧室", dids: ["dev-b"], homeId: "home-b", homeName: "B 家"),
    ]
    private static let twoHomeValues: [MiotPropKey: JSONValue] = [
        MiotPropKey(did: "dev-a", siid: 2, piid: 1): .bool(true),
        MiotPropKey(did: "dev-a", siid: 2, piid: 2): .number(60),
        MiotPropKey(did: "dev-b", siid: 2, piid: 1): .bool(true),
        MiotPropKey(did: "dev-b", siid: 2, piid: 2): .number(88),
    ]

    @MainActor
    private func makeSingleAccountStore(
        api: GatedMiCloudAPI,
        initialHomeId: String = "home-a"
    ) -> (HomeStore, MiCloudProvider, InMemoryUserDefaults) {
        let defaults = InMemoryUserDefaults()
        let provider = MiCloudProvider(
            sessionLoader: { Self.sessionA },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            localClient: nil,
            pollInterval: .seconds(300),
            closedPollInterval: .seconds(300),
            selectedHomeLoader: { defaults.string(forKey: MiCloudProvider.selectedHomeKey) }
        )
        let store = HomeStore(provider: provider, defaults: defaults)
        store.homeBackend = .xiaomiCloud
        defaults.set(initialHomeId, forKey: MiCloudProvider.selectedHomeKey)
        store.selectedMiHomeId = initialHomeId
        store.startListening()
        return (store, provider, defaults)
    }

    @Test("Switching home cancels in-flight old-home poll, clears old devices immediately, starts new fetch at once, and drops stale old-home results")
    @MainActor
    func switchCancelsInFlightOldPollAndDropsStaleResults() async {
        let api = GatedMiCloudAPI(devices: [Self.devA, Self.devB], rooms: Self.twoHomeRooms, values: Self.twoHomeValues)
        let (store, provider, _) = makeSingleAccountStore(api: api)
        defer { Task { await provider.shutdown() } }

        #expect(await waitForMainActor("initial home-a") { store.devices.map(\.id) == ["dev-a"] })
        let listCallsBeforeSwitch = await api.deviceListCalls

        // Park an in-flight refresh for home-a inside getProps.
        let homeAGate = HomeSwitchGate()
        await api.setPropGate(homeAGate, forDid: "dev-a")
        let inFlightOldPoll = Task { await provider.refreshNow() }
        await homeAGate.waitUntilEntered()

        // Switch to home-b while home-a's poll is blocked.
        store.selectMiHome("home-b")

        // Synchronously: old devices are gone, loading flag is on, empty-home warning is suppressed.
        #expect(store.devices.isEmpty)
        #expect(store.isSwitchingMiHome)
        #expect(store.otherMiHomesDeviceCountWhenSelectedEmpty == nil)

        // Without releasing homeAGate, home-b fetches immediately and appears.
        #expect(await waitForMainActor("home-b loaded while home-a still parked") {
            store.devices.map(\.id) == ["dev-b"] && !store.isSwitchingMiHome
        })
        #expect(await api.deviceListCalls > listCallsBeforeSwitch)

        // Now let the old home-a getProps finish late — it must be discarded.
        await api.setPropGate(nil, forDid: "dev-a")
        await homeAGate.release()
        await inFlightOldPoll.value
        try? await Task.sleep(for: .milliseconds(30))

        #expect(store.devices.map(\.id) == ["dev-b"])
        #expect(store.selectedMiHomeId == "home-b")
        await provider.shutdown()
    }

    @Test("New home device list is published before slower property fetches complete")
    @MainActor
    func publishesNewHomeListBeforePropertiesFinish() async {
        let api = GatedMiCloudAPI(devices: [Self.devA, Self.devB], rooms: Self.twoHomeRooms, values: Self.twoHomeValues)
        let (store, provider, _) = makeSingleAccountStore(api: api)
        defer { Task { await provider.shutdown() } }

        #expect(await waitForMainActor("initial home-a") { store.devices.map(\.id) == ["dev-a"] })

        // Park home-b's property fetch so we can inspect the panel mid-switch.
        let homeBPropsGate = HomeSwitchGate()
        await api.setPropGate(homeBPropsGate, forDid: "dev-b")

        store.selectMiHome("home-b")
        #expect(store.devices.isEmpty)
        #expect(store.isSwitchingMiHome)

        await homeBPropsGate.waitUntilEntered()

        // Stage-1 device list must already be visible while getProps for dev-b is still parked.
        #expect(await waitForMainActor("stage-1 home-b list") {
            store.devices.map(\.id) == ["dev-b"] && !store.isSwitchingMiHome
        })
        if case .light(let state)? = store.devices.first?.kind {
            #expect(state.isOn == false, "stage-1 device list arrives before live prop values")
        } else {
            Issue.record("expected dev-b light card in stage-1 snapshot")
        }

        // Release getProps and verify live values arrive seamlessly.
        await api.setPropGate(nil, forDid: "dev-b")
        await homeBPropsGate.release()
        #expect(await waitForMainActor("stage-2 home-b live props") {
            if case .light(let state)? = store.devices.first?.kind {
                return state.isOn && state.brightnessPercent == 88
            }
            return false
        })
        await provider.shutdown()
    }

    @Test("Switching back to a previously visited home restores cached snapshot immediately while refreshing")
    @MainActor
    func cachedHomeRestoresSynchronouslyThenRefreshes() async {
        let api = GatedMiCloudAPI(devices: [Self.devA, Self.devB], rooms: Self.twoHomeRooms, values: Self.twoHomeValues)
        let (store, provider, _) = makeSingleAccountStore(api: api)
        defer { Task { await provider.shutdown() } }

        #expect(await waitForMainActor("initial home-a") { store.devices.map(\.id) == ["dev-a"] })

        store.selectMiHome("home-b")
        #expect(await waitForMainActor("home-b full load") {
            if case .light(let state)? = store.devices.first?.kind {
                return store.devices.map(\.id) == ["dev-b"] && state.isOn && state.brightnessPercent == 88
            }
            return false
        })

        // Update dev-a's brightness in the cloud and park its getProps before switching back.
        await api.setValue(MiotPropKey(did: "dev-a", siid: 2, piid: 2), .number(95))
        let homeAPropsGate = HomeSwitchGate()
        await api.setPropGate(homeAPropsGate, forDid: "dev-a")

        store.selectMiHome("home-a")

        // Synchronously restored from cache without flashing empty or loading.
        #expect(store.devices.map(\.id) == ["dev-a"])
        #expect(!store.isSwitchingMiHome)
        if case .light(let state)? = store.devices.first?.kind {
            #expect(state.brightnessPercent == 60)
        }

        // Background refresh still runs immediately and updates brightness to 95.
        await homeAPropsGate.waitUntilEntered()
        await api.setPropGate(nil, forDid: "dev-a")
        await homeAPropsGate.release()
        #expect(await waitForMainActor("home-a refreshed brightness") {
            if case .light(let state)? = store.devices.first?.kind {
                return state.brightnessPercent == 95
            }
            return false
        })
        await provider.shutdown()
    }

    @Test("HomeStore discards buffered old-generation snapshots after a home switch")
    @MainActor
    func homeStoreDropsStaleGenerationSnapshot() async {
        let defaults = InMemoryUserDefaults()
        defaults.set("home-a", forKey: MiCloudProvider.selectedHomeKey)
        let provider = ControlledHomeSwitchProvider()
        let store = HomeStore(provider: provider, defaults: defaults)
        store.homeBackend = .xiaomiCloud
        defaults.set("home-a", forKey: MiCloudProvider.selectedHomeKey)
        store.selectedMiHomeId = "home-a"
        store.startListening()
        defer { Task { await provider.shutdown() } }
        await provider.waitUntilAttached()

        let homes = [
            HomeOption(id: "home-a", name: "A 家", deviceCount: 1),
            HomeOption(id: "home-b", name: "B 家", deviceCount: 1),
        ]
        var homeASnap = SynthesizedHome(
            rooms: [RoomArea(id: "room-a", name: "客厅")],
            devices: [SmartDevice(id: "dev-a", name: "A 灯", roomId: "room-a", roomName: "客厅", model: "m", isOnline: true, kind: .light(.init(entityId: "miot:dev-a:2", isOn: true)))]
        )
        homeASnap.homes = homes
        homeASnap.miHomeGeneration = 0
        await provider.emit(.snapshotUpdated(homeASnap))
        #expect(await waitForMainActor("initial gen 0") { store.devices.map(\.id) == ["dev-a"] })

        store.selectMiHome("home-b")
        #expect(store.devices.isEmpty)
        #expect(store.isSwitchingMiHome)

        // Emit a late gen-0 snapshot from home-a — must be discarded.
        await provider.emit(.snapshotUpdated(homeASnap))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.devices.isEmpty)
        #expect(store.isSwitchingMiHome)

        // Emit gen-1 snapshot for home-b — must be accepted.
        var homeBSnap = SynthesizedHome(
            rooms: [RoomArea(id: "room-b", name: "卧室")],
            devices: [SmartDevice(id: "dev-b", name: "B 灯", roomId: "room-b", roomName: "卧室", model: "m", isOnline: true, kind: .light(.init(entityId: "miot:dev-b:2", isOn: false)))]
        )
        homeBSnap.homes = homes
        homeBSnap.miHomeGeneration = 1
        await provider.emit(.snapshotUpdated(homeBSnap))
        #expect(await waitForMainActor("gen 1 accepted") {
            store.devices.map(\.id) == ["dev-b"] && !store.isSwitchingMiHome
        })
        #expect(await provider.switchedGenerations == [1])
        await provider.shutdown()
    }

    @Test("Multi-account cross-account home switch clears old devices immediately and publishes new list before properties finish")
    @MainActor
    func multiAccountCrossAccountSwitchFastPath() async {
        let accA = MiAccount(session: Self.sessionA)
        let accB = MiAccount(session: Self.sessionB)
        let apiA = GatedMiCloudAPI(
            devices: [Self.devA],
            rooms: [MiRoom(id: "room-a", name: "客厅", dids: ["dev-a"], homeId: "home-a", homeName: "A 家")],
            values: [
                MiotPropKey(did: "dev-a", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "dev-a", siid: 2, piid: 2): .number(50),
            ]
        )
        let apiB = GatedMiCloudAPI(
            devices: [Self.devB],
            rooms: [MiRoom(id: "room-b", name: "卧室", dids: ["dev-b"], homeId: "home-b", homeName: "B 家")],
            values: [
                MiotPropKey(did: "dev-b", siid: 2, piid: 1): .bool(true),
                MiotPropKey(did: "dev-b", siid: 2, piid: 2): .number(77),
            ]
        )
        let defaults = InMemoryUserDefaults()
        defaults.set(MiAccountScope.id("home-a", account: accA.id), forKey: MiCloudProvider.selectedHomeKey)

        let provider = MiAccountsProvider(
            accounts: [accA, accB],
            apiFactory: { $0.region == "de" ? apiB : apiA },
            specSource: StubSpecSource(),
            localClientFactory: { nil },
            pollInterval: .seconds(300),
            closedPollInterval: .seconds(300),
            selectedHomeLoader: { defaults.string(forKey: MiCloudProvider.selectedHomeKey) },
            clearSelectedHome: { defaults.removeObject(forKey: MiCloudProvider.selectedHomeKey) }
        )
        let store = HomeStore(provider: provider, defaults: defaults)
        store.homeBackend = .xiaomiCloud
        defaults.set(MiAccountScope.id("home-a", account: accA.id), forKey: MiCloudProvider.selectedHomeKey)
        store.selectedMiHomeId = MiAccountScope.id("home-a", account: accA.id)
        store.startListening()
        defer { Task { await provider.shutdown() } }

        #expect(await waitForMainActor("initial accA home-a") { store.devices.map(\.id) == ["dev-a"] })

        let accBPropsGate = HomeSwitchGate()
        await apiB.setPropGate(accBPropsGate, forDid: "dev-b")

        store.selectMiHome(MiAccountScope.id("home-b", account: accB.id))
        #expect(store.devices.isEmpty)
        #expect(store.isSwitchingMiHome)

        await accBPropsGate.waitUntilEntered()
        // New account's device list appears before its property batch completes, and accA's device never leaks.
        #expect(await waitForMainActor("stage-1 accB dev-b") {
            store.devices.map(\.id) == ["dev-b"] && !store.isSwitchingMiHome
        })

        await apiB.setPropGate(nil, forDid: "dev-b")
        await accBPropsGate.release()
        #expect(await waitForMainActor("stage-2 accB live props") {
            if case .light(let state)? = store.devices.first?.kind {
                return state.isOn && state.brightnessPercent == 77
            }
            return false
        })
        await provider.shutdown()
    }
}
