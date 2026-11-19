import Foundation
import Testing
@testable import MijiaCore

/// P3a-M on the host side: a closed type answers 「该设备类型已关闭」 with zero writes on every entry,
/// keeps evaluating the alerts the user left on, and is dropped per account, never in one sweep.
struct MiotTypePruneStoreTests {
    static let scope = "mi:region:acct"

    static let hiddenCover = SmartDevice(
        id: "curtain-hidden", name: "客厅窗帘", roomId: "living", roomName: "客厅",
        model: "090615.curtain.1mcu01", isOnline: true,
        kind: .cover(CoverSpec(
            entityId: "miot:curtain-hidden:2", subtype: .curtain, positionPercent: 40, positionWritable: true
        ))
    )

    static let leakSensor = SmartDevice(
        id: "leak-hidden", name: "厨房水浸", roomId: "kitchen", roomName: "厨房",
        model: "bkxh.flood.yf02", isOnline: true,
        kind: .sensor(SensorSpec(
            battery: 90,
            observations: [SensorObservation(sourceId: "leak-hidden#miot:2", kind: .leak, alarming: true)]
        ))
    )

    static let visibleLight = SmartDevice(
        id: "light-visible", name: "书房吸顶灯", roomId: "study", roomName: "书房",
        model: "090615.light.ailig1", isOnline: true,
        kind: .light(LightSpec(entityId: "miot:light-visible:2", isOn: true))
    )

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.visibleLight]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.miotprune.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.toastAutoDismissInterval = nil
        return (store, mock)
    }

    /// The provider only reports for an enabled account, and the gate reads the same scope. `closed`
    /// removes the types the user turned off.
    @MainActor
    private func enableMiScope(_ closed: Set<DeviceCategoryID> = [], in store: HomeStore) {
        var selection = store.capabilitySelection
        selection.enabledConnections.insert(.xiaomiCloud)
        selection.enabledConnectionScopes.insert(Self.scope)
        selection.enabledCategories.subtract(closed)
        store.capabilitySelection = selection
    }

    private func report(_ devices: [SmartDevice], scope: String = scope, safety: [SmartDevice] = []) -> MiotTypePruneReport {
        MiotTypePruneReport(
            scope: scope,
            hiddenIndexedDevices: devices.map { device in
                CapabilityIndexedDevice(
                    id: device.id, name: device.name, category: device.capabilityCategoryID,
                    connection: .xiaomiCloud, sourceScope: scope,
                    isSourceAvailable: true, upstreamHiddenOrDisabled: false, participatesInAllOff: false,
                    safetySignals: [], readKeys: [device.id], safetyReadKeys: [device.id]
                )
            },
            hiddenDeviceIds: Set(devices.map(\.id)),
            safetyDevices: safety
        )
    }

    @Test("A closed type answers 「该设备类型已关闭」 and writes nothing, not 「设备不存在」")
    @MainActor
    func closedTypeRejectsWritesWithoutTouchingTheDevice() async throws {
        let (store, mock) = try await makeStore()
        enableMiScope([.cover], in: store)
        store.applyMiotTypePruneReport(report([Self.hiddenCover]))

        let gate = store.evaluateDeviceControlGate(deviceId: Self.hiddenCover.id)
        #expect(!gate.allowed)
        #expect(gate.rejectionReason == .categoryDisabled(.cover))
        #expect(gate.writeCount == 0)
        let expected = ControlTargetRejectionReason.categoryDisabled(.cover).userMessage
        #expect(store.capabilityControlRejectionMessage(forDeviceId: Self.hiddenCover.id) == expected)

        do {
            try await store.executeDeviceCommand(
                .setMiotProperty(entityId: "miot:curtain-hidden:2", piid: 2, value: .number(100))
            )
            Issue.record("a closed type must refuse the write")
        } catch let error as CapabilityControlBlockedError {
            #expect(error.reason == .categoryDisabled(.cover))
        }
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A closed sensor type keeps its enabled leak alert without showing the card")
    @MainActor
    func closedSensorStillRaisesItsEnabledAlert() async throws {
        let (store, _) = try await makeStore()
        enableMiScope([.sensor], in: store)
        store.applyMiotTypePruneReport(report([Self.leakSensor], safety: [Self.leakSensor]))

        #expect(!store.devices.contains { $0.id == Self.leakSensor.id }, "the card stays hidden")
        #expect(store.typeHiddenSafetyDevices.map(\.id) == [Self.leakSensor.id])
        #expect(store.menuBarShowsHazard, "a retained hazard still colours the menu bar")
        #expect(store.evaluateSafetyAlerts(now: Date()).contains { $0.deviceId == Self.leakSensor.id })
    }

    @Test("The doorbell is its own switch: a closed camera keeps ringing with safety alerts off")
    @MainActor
    func doorbellRetentionIgnoresTheSafetyMasterSwitch() async throws {
        let (store, _) = try await makeStore()
        enableMiScope([.camera], in: store)
        store.enableSafetyAlerts = false
        store.doorbellChime = true
        store.syncMiotTypePrunePolicy()
        #expect(store.miotTypePruneBox.get().safetyPolicy.enabledSignals == [.doorbell])

        store.doorbellChime = false
        #expect(store.miotTypePruneBox.get().safetyPolicy.enabledSignals.isEmpty)
    }

    @Test("A retained sensor's alert still reaches the activity feed")
    @MainActor
    func retainedAlertAppearsInTheActivityFeed() async throws {
        let (store, _) = try await makeStore()
        enableMiScope([.sensor], in: store)
        store.applyMiotTypePruneReport(report([Self.leakSensor], safety: [Self.leakSensor]))
        #expect(store.evaluateSafetyAlerts(now: Date()).contains { $0.deviceId == Self.leakSensor.id })
        #expect(store.panelActivities.contains { activity in
            if case .safety(let recorded) = activity.kind { recorded.alert.deviceId == Self.leakSensor.id }
            else { false }
        })
    }

    @Test("A shared hidden device is evaluated from its freshest account, not the first one")
    @MainActor
    func sharedHiddenDeviceUsesTheFreshestReading() async throws {
        let (store, _) = try await makeStore()
        var stale = Self.leakSensor
        stale.telemetryStale = true
        var offline = Self.leakSensor
        offline.isOnline = false
        store.applyMiotTypePruneReport(report([], scope: "mi:a", safety: [stale]))
        store.applyMiotTypePruneReport(report([], scope: "mi:b", safety: [offline]))
        #expect(store.typeHiddenSafetyDevices.first?.isOnline == false, "the offline copy is fresher than stale telemetry")
        store.applyMiotTypePruneReport(report([], scope: "mi:c", safety: [Self.leakSensor]))
        #expect(store.typeHiddenSafetyDevices.map(\.id) == [Self.leakSensor.id])
        #expect(store.typeHiddenSafetyDevices.first?.isOnline == true)
        #expect(store.typeHiddenSafetyDevices.first?.telemetryStale == false)
    }

    @Test("Contact and motion ship off, so the published policy keeps neither")
    @MainActor
    func publishedPolicyFollowsAlertDefaults() async throws {
        let (store, _) = try await makeStore()
        store.syncMiotTypePrunePolicy()
        let signals = store.miotTypePruneBox.get().safetyPolicy.enabledSignals
        #expect(signals.isSuperset(of: [.leak, .smoke, .gas]))
        #expect(!signals.contains(.contact))
        #expect(!signals.contains(.motion))

        store.setSensorAlertEnabled(.motion, true)
        #expect(store.miotTypePruneBox.get().safetyPolicy.enabledSignals.contains(.motion))
    }

    @Test("Retention is per account, and a provider swap or a sign-out clears every account")
    @MainActor
    func retentionIsPerAccountAndClearedOnSwap() async throws {
        let (store, _) = try await makeStore()
        let other = "mi:region:other"
        store.applyMiotTypePruneReport(report([], safety: [Self.leakSensor]))
        store.applyMiotTypePruneReport(report([], scope: other, safety: [Self.leakSensor]))
        #expect(store.typeHiddenSafetyDevices.count == 1, "one device shared by two reports counts once")

        store.applyMiotTypePruneReport(report([], scope: other))
        #expect(store.typeHiddenSafetyDevices.map(\.id) == [Self.leakSensor.id], "the other account keeps its set")
        store.dropMiotTypePruneReport(scope: Self.scope)
        #expect(store.typeHiddenSafetyDevices.isEmpty)

        // A provider swap owns a fresh read plan; the previous connection's safety set must not survive it.
        store.applyMiotTypePruneReport(report([], safety: [Self.leakSensor]))
        store.startListening()
        #expect(store.typeHiddenSafetyDevices.isEmpty)
        store.applyMiotTypePruneReport(report([], safety: [Self.leakSensor]))
        store.clearMiotTypePruneReports()
        #expect(store.typeHiddenSafetyDevices.isEmpty)
    }
}
