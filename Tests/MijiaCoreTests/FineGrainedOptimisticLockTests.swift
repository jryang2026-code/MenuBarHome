import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct FineGrainedOptimisticLockTests {
    private final class ManualClock: @unchecked Sendable {
        var now: Date

        init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.now = start
        }

        func advance(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    private actor ScriptedProvider: HomeProvider {
        private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
        private var initialSnapshot: SynthesizedHome
        private(set) var executedCommands: [DeviceCommand] = []
        private var commandWaiters: [CheckedContinuation<Void, Never>] = []
        var readBackResult: ControlReadBack = .unavailable

        init(snapshot: SynthesizedHome) {
            self.initialSnapshot = snapshot
        }

        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            AsyncStream { continuation in
                Task { await self.attach(continuation) }
            }
        }

        private func attach(_ continuation: AsyncStream<HomeProviderEvent>.Continuation) {
            self.continuation = continuation
            continuation.yield(.statusChanged(.connected))
            continuation.yield(.snapshotUpdated(initialSnapshot))
        }

        func emit(_ snapshot: SynthesizedHome) {
            continuation?.yield(.snapshotUpdated(snapshot))
        }

        func execute(_ command: DeviceCommand) async throws {
            executedCommands.append(command)
            let waiters = commandWaiters
            commandWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func readBack(deviceId: String) async -> ControlReadBack {
            readBackResult
        }

        func refreshNow() async {}

        func waitForCommandCount(_ count: Int) async {
            while executedCommands.count < count {
                await withCheckedContinuation { continuation in
                    commandWaiters.append(continuation)
                }
            }
        }
    }

    private static let lightDevice = SmartDevice(
        id: "light-1",
        name: "吸顶灯",
        roomId: "room-1",
        roomName: "客厅",
        model: "yeelink.light.ceiling1",
        isOnline: true,
        kind: .light(LightSpec(
            entityId: "light.living_ceiling",
            isOn: false,
            brightnessPercent: 40,
            colorTempKelvin: 3000
        ))
    )

    private static let climateDevice = SmartDevice(
        id: "ac-1",
        name: "空调",
        roomId: "room-1",
        roomName: "客厅",
        model: "lumi.acpartner.mcn02",
        isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.living_ac",
            isOn: true,
            hvacMode: "cool",
            availableModes: ["cool", "heat", "off"],
            targetTemperature: 24,
            currentTemperature: 26.0,
            fanMode: "low",
            availableFanModes: ["low", "medium", "high"]
        ))
    )

    private static let sensorDevice = SmartDevice(
        id: "sensor-1",
        name: "温湿度计",
        roomId: "room-1",
        roomName: "客厅",
        model: "miaomiaoce.sensor_ht.t2",
        isOnline: true,
        kind: .sensor(SensorSpec(temperature: 21.0, humidity: 45.0))
    )

    private func makeSnapshot(
        devices: [SmartDevice],
        facets: [String: [FacetControl]] = [:]
    ) -> SynthesizedHome {
        var home = SynthesizedHome(devices: devices)
        home.deviceFacets = facets
        return home
    }

    private func makeStore(
        devices: [SmartDevice],
        facets: [String: [FacetControl]] = [:],
        clock: ManualClock
    ) async throws -> (HomeStore, ScriptedProvider) {
        let provider = ScriptedProvider(snapshot: makeSnapshot(devices: devices, facets: facets))
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.fine.lock.\(UUID().uuidString)")
        store.optimisticNow = { clock.now }
        store.controlDebounceInterval = Duration.zero
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()
        return (store, provider)
    }

    private func emitAndWait(
        _ provider: ScriptedProvider,
        store: HomeStore,
        snapshot: SynthesizedHome
    ) async {
        let gen = store.snapshotGeneration
        await provider.emit(snapshot)
        await waitUntil { store.snapshotGeneration > gen }
    }

    @Test("Power lock protects isOn while brightness, colorTemp, and sensor fields still update")
    func powerLockLeavesUnrelatedFieldsUnlocked() async throws {
        let clock = ManualClock()
        let (store, provider) = try await makeStore(
            devices: [Self.lightDevice, Self.sensorDevice],
            clock: clock
        )

        let light = try #require(store.devices.first(where: { $0.id == "light-1" }))
        let toggled = await store.togglePrimary(light)?.value ?? false
        #expect(toggled)
        #expect(store.optimisticFieldLocks[.field("light-1", .power)] != nil)
        #expect(store.optimisticFieldLocks[.field("light-1", .brightness)] == nil)

        clock.advance(by: 0.5)
        let staleLight = SmartDevice(
            id: "light-1", name: "吸顶灯", roomId: "room-1", roomName: "客厅",
            model: "yeelink.light.ceiling1", isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.living_ceiling",
                isOn: false,
                brightnessPercent: 85,
                colorTempKelvin: 4800
            ))
        )
        let updatedSensor = SmartDevice(
            id: "sensor-1", name: "温湿度计", roomId: "room-1", roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t2", isOnline: true,
            kind: .sensor(SensorSpec(temperature: 24.5, humidity: 52.0))
        )
        await emitAndWait(provider, store: store, snapshot: makeSnapshot(devices: [staleLight, updatedSensor]))

        guard case .light(let lightSpec) = store.devices.first(where: { $0.id == "light-1" })?.kind else {
            Issue.record("light-1 missing")
            return
        }
        #expect(lightSpec.isOn == true)
        #expect(lightSpec.brightnessPercent == 85)
        #expect(lightSpec.colorTempKelvin == 4800)

        guard case .sensor(let sensorSpec) = store.devices.first(where: { $0.id == "sensor-1" })?.kind else {
            Issue.record("sensor-1 missing")
            return
        }
        #expect(sensorSpec.temperature == 24.5)
        #expect(sensorSpec.humidity == 52.0)
    }

    @Test("Brightness lock protects brightnessPercent while power and colorTemp update from snapshot")
    func brightnessLockLeavesPowerAndColorTempUnlocked() async throws {
        let clock = ManualClock()
        let initialLight = SmartDevice(
            id: "light-1", name: "吸顶灯", roomId: "room-1", roomName: "客厅",
            model: "yeelink.light.ceiling1", isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.living_ceiling",
                isOn: true,
                brightnessPercent: 40,
                colorTempKelvin: 3000
            ))
        )
        let (store, provider) = try await makeStore(devices: [initialLight], clock: clock)

        store.setLightBrightness("light-1", percent: 75)
        await provider.waitForCommandCount(1)
        #expect(store.optimisticFieldLocks[.field("light-1", .brightness)] != nil)
        #expect(store.optimisticFieldLocks[.field("light-1", .power)] == nil)

        clock.advance(by: 0.5)
        let incomingLight = SmartDevice(
            id: "light-1", name: "吸顶灯", roomId: "room-1", roomName: "客厅",
            model: "yeelink.light.ceiling1", isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.living_ceiling",
                isOn: false,
                brightnessPercent: 20,
                colorTempKelvin: 5200
            ))
        )
        await emitAndWait(provider, store: store, snapshot: makeSnapshot(devices: [incomingLight]))

        guard case .light(let spec) = store.devices.first(where: { $0.id == "light-1" })?.kind else {
            Issue.record("light-1 missing")
            return
        }
        #expect(spec.brightnessPercent == 75)
        #expect(spec.isOn == false)
        #expect(spec.colorTempKelvin == 5200)
    }

    @Test("Target temperature lock preserves targetTemperature while currentTemperature and fanMode update")
    func climateTargetTemperatureLockIsIndependent() async throws {
        let clock = ManualClock()
        let (store, provider) = try await makeStore(devices: [Self.climateDevice], clock: clock)

        store.stepClimateTemperature("ac-1", delta: 2.5)
        await provider.waitForCommandCount(1)
        #expect(store.optimisticFieldLocks[.field("ac-1", .targetTemperature)] != nil)

        clock.advance(by: 0.5)
        let incoming = SmartDevice(
            id: "ac-1", name: "空调", roomId: "room-1", roomName: "客厅",
            model: "lumi.acpartner.mcn02", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.living_ac",
                isOn: true,
                hvacMode: "cool",
                availableModes: ["cool", "heat", "off"],
                targetTemperature: 21.0,
                currentTemperature: 28.0,
                fanMode: "high",
                availableFanModes: ["low", "medium", "high"]
            ))
        )
        await emitAndWait(provider, store: store, snapshot: makeSnapshot(devices: [incoming]))

        guard case .climate(let spec) = store.devices.first(where: { $0.id == "ac-1" })?.kind else {
            Issue.record("ac-1 missing")
            return
        }
        #expect(spec.targetTemperature == 26.5)
        #expect(spec.currentTemperature == 28.0)
        #expect(spec.fanMode == "high")
    }

    @Test("Facet lock protects only the targeted controlId, leaving sibling facets and card fields free to update")
    func facetLockIsScopedPerControlId() async throws {
        let clock = ManualClock()
        let modeFacet = FacetControl(
            id: "mode",
            kind: .slider,
            name: "mode",
            title: "亮度",
            serviceName: "light",
            value: .number(10),
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:light-1:2", piid: 1)
        )
        let nightFacet = FacetControl(
            id: "night-light",
            kind: .toggle,
            name: "night-light",
            title: "夜灯",
            serviceName: "light",
            value: .bool(false),
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:light-1:2", piid: 2)
        )
        let (store, provider) = try await makeStore(
            devices: [Self.lightDevice],
            facets: ["light-1": [modeFacet, nightFacet]],
            clock: clock
        )

        store.setFacetValue("light-1", controlId: "mode", value: .number(42))
        await provider.waitForCommandCount(1)
        #expect(store.optimisticFacetLocks[HomeStore.facetLockKey("light-1", "mode")] != nil)
        #expect(store.optimisticFacetLocks[HomeStore.facetLockKey("light-1", "night-light")] == nil)

        clock.advance(by: 0.5)
        let incomingLight = SmartDevice(
            id: "light-1", name: "吸顶灯", roomId: "room-1", roomName: "客厅",
            model: "yeelink.light.ceiling1", isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.living_ceiling",
                isOn: true,
                brightnessPercent: 90,
                colorTempKelvin: 4000
            ))
        )
        var incomingMode = modeFacet
        incomingMode.value = .number(99)
        var incomingNight = nightFacet
        incomingNight.value = .bool(true)

        await emitAndWait(
            provider,
            store: store,
            snapshot: makeSnapshot(
                devices: [incomingLight],
                facets: ["light-1": [incomingMode, incomingNight]]
            )
        )

        let facets = store.deviceFacets["light-1"] ?? []
        #expect(facets.first(where: { $0.id == "mode" })?.value == .number(42))
        #expect(facets.first(where: { $0.id == "night-light" })?.value == .bool(true))
        guard case .light(let spec) = store.devices.first(where: { $0.id == "light-1" })?.kind else {
            Issue.record("light-1 missing")
            return
        }
        #expect(spec.isOn == true)
        #expect(spec.brightnessPercent == 90)
    }

    @Test("Expired field and facet locks are pruned cleanly on snapshot merge")
    func lockExpiryPrunesCleanly() async throws {
        let clock = ManualClock()
        let modeFacet = FacetControl(
            id: "mode",
            kind: .slider,
            name: "mode",
            title: "模式",
            serviceName: "light",
            value: .number(10),
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:light-1:2", piid: 1)
        )
        let (store, provider) = try await makeStore(
            devices: [Self.lightDevice],
            facets: ["light-1": [modeFacet]],
            clock: clock
        )

        let light = try #require(store.devices.first(where: { $0.id == "light-1" }))
        _ = await store.togglePrimary(light)?.value
        store.extendFacetLock("light-1", controlId: "mode", duration: .seconds(2.2))

        // Before 2.0s: power and facet locks still hold.
        clock.advance(by: 1.9)
        await emitAndWait(
            provider,
            store: store,
            snapshot: makeSnapshot(devices: [Self.lightDevice], facets: ["light-1": [modeFacet]])
        )
        if case .light(let spec) = store.devices.first(where: { $0.id == "light-1" })?.kind {
            #expect(spec.isOn == true)
        } else {
            Issue.record("light-1 missing")
        }
        #expect(store.optimisticFieldLocks[.field("light-1", .power)] != nil)
        #expect(store.optimisticFacetLocks[HomeStore.facetLockKey("light-1", "mode")] != nil)

        // Past 2.2s: both locks expire and incoming snapshot takes over.
        clock.advance(by: 0.4)
        var updatedFacet = modeFacet
        updatedFacet.value = .number(77)
        await emitAndWait(
            provider,
            store: store,
            snapshot: makeSnapshot(devices: [Self.lightDevice], facets: ["light-1": [updatedFacet]])
        )

        if case .light(let spec) = store.devices.first(where: { $0.id == "light-1" })?.kind {
            #expect(spec.isOn == false)
        } else {
            Issue.record("light-1 missing")
        }
        #expect(store.deviceFacets["light-1"]?.first?.value == .number(77))
        #expect(store.optimisticFieldLocks.isEmpty)
        #expect(store.optimisticFacetLocks.isEmpty)
    }

    @Test("Backend switch and clearOptimisticLocks wipe all field locks, facet locks, revisions, and cover origins")
    func backendSwitchAndClearWipeAllLockState() async throws {
        let clock = ManualClock()
        let (store, _) = try await makeStore(devices: [Self.lightDevice], clock: clock)

        _ = store.lockOptimistic("light-1", fields: [.power, .brightness], duration: .seconds(5))
        _ = store.lockOptimisticFacet("light-1", controlId: "mode", duration: .seconds(5))
        store.coverCommandOrigins["curtain-1"] = 40

        #expect(!store.optimisticFieldLocks.isEmpty)
        #expect(!store.optimisticFacetLocks.isEmpty)
        #expect(!store.optimisticLockRevision.isEmpty)
        #expect(!store.coverCommandOrigins.isEmpty)

        store.switchBackend(.demo)

        #expect(store.optimisticFieldLocks.isEmpty)
        #expect(store.optimisticFacetLocks.isEmpty)
        #expect(store.optimisticLockRevision.isEmpty)
        #expect(store.coverCommandOrigins.isEmpty)
        #expect(store.optimisticLockUntil.isEmpty)

        _ = store.lockOptimistic("light-1", fields: [.power], duration: .seconds(5))
        _ = store.lockOptimisticFacet("light-1", controlId: "mode", duration: .seconds(5))
        store.clearOptimisticLocks()

        #expect(store.optimisticFieldLocks.isEmpty)
        #expect(store.optimisticFacetLocks.isEmpty)
        #expect(store.optimisticLockRevision.isEmpty)
        #expect(store.coverCommandOrigins.isEmpty)
    }

    @Test("undoTurnAllOff keeps bidirectional power lock while letting unrelated brightness update")
    func undoTurnAllOffHoldsFineGrainedBidirectionalLock() async throws {
        let clock = ManualClock()
        let onLight = SmartDevice(
            id: "light-1", name: "吸顶灯", roomId: "room-1", roomName: "客厅",
            model: "yeelink.light.ceiling1", isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.living_ceiling",
                isOn: true,
                brightnessPercent: 40,
                colorTempKelvin: 3000
            ))
        )
        let (store, provider) = try await makeStore(devices: [onLight], clock: clock)

        store.turnAllOff()
        await provider.waitForCommandCount(1)
        if case .light(let offSpec) = store.devices.first?.kind {
            #expect(offSpec.isOn == false)
        } else {
            Issue.record("light-1 missing")
        }

        // Undo restores light-1 back to ON and acquires a 3s lock on `.power`.
        await store.undoTurnAllOff()?.value
        if case .light(let restoredSpec) = store.devices.first?.kind {
            #expect(restoredSpec.isOn == true)
        } else {
            Issue.record("light-1 missing")
        }
        #expect(store.optimisticFieldLocks[.field("light-1", .power)] != nil)
        #expect(store.optimisticFieldLocks[.field("light-1", .brightness)] == nil)

        // Stale OFF snapshot arrives before the 3s lock expires: isOn stays true, brightness updates.
        clock.advance(by: 1.0)
        let staleSnapshotLight = SmartDevice(
            id: "light-1", name: "吸顶灯", roomId: "room-1", roomName: "客厅",
            model: "yeelink.light.ceiling1", isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.living_ceiling",
                isOn: false,
                brightnessPercent: 88,
                colorTempKelvin: 4500
            ))
        )
        await emitAndWait(provider, store: store, snapshot: makeSnapshot(devices: [staleSnapshotLight]))

        guard case .light(let mergedSpec) = store.devices.first?.kind else {
            Issue.record("light-1 missing")
            return
        }
        #expect(mergedSpec.isOn == true)
        #expect(mergedSpec.brightnessPercent == 88)
        #expect(mergedSpec.colorTempKelvin == 4500)
    }
}
