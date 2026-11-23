import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MijiaCore

/// Dual-source device-type pruning canonical ID normalization and cross-source safety deduplication
/// (#303, #325).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DualSourceTypePruneTests {
    private static let haURL = "http://192.168.1.60:8123"
    private static let haScope = "ha:http://192.168.1.60:8123"
    private static let miScope = "mi:cn:acct1"

    private static let fanDID = "1105610999"
    private static let fanHAID = "ha-living-fan"
    private static let leakDID = "1105610777"
    private static let leakHAID = "ha-kitchen-leak"

    private static let visibleLight = SmartDevice(
        id: "dev_light", name: "吸顶灯", roomId: "living", roomName: "客厅",
        model: "ha.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true))
    )

    private static func fanDevice(id: String, entity: String, isOnline: Bool = true) -> SmartDevice {
        SmartDevice(
            id: id,
            name: "客厅风扇",
            roomId: "living",
            roomName: "客厅",
            model: "dmaker.fan.p18",
            isOnline: isOnline,
            kind: .fan(FanSpec(entityId: entity, isOn: true, percentage: 50))
        )
    }

    private static func leakDevice(
        id: String,
        observationSourceId: String,
        alarming: Bool,
        isOnline: Bool = true,
        telemetryStale: Bool = false
    ) -> SmartDevice {
        SmartDevice(
            id: id,
            name: "厨房水浸",
            roomId: "kitchen",
            roomName: "厨房",
            model: "lumi.sensor_wleak.aq1",
            isOnline: isOnline,
            kind: .sensor(SensorSpec(
                battery: 90,
                observations: [SensorObservation(sourceId: observationSourceId, kind: .leak, alarming: alarming)]
            )),
            telemetryStale: telemetryStale
        )
    }

    private static func pairedHome(
        devices: [SmartDevice],
        identities: [String: DeviceSourceIdentity]
    ) -> SynthesizedHome {
        var home = SynthesizedHome(devices: devices)
        home.deviceIdentities = identities
        home.isInitialLoadComplete = true
        return home
    }

    private static func fanIdentity() -> DeviceSourceIdentity {
        DeviceSourceIdentity(
            dids: [fanDID],
            model: "dmaker.fan.p18",
            name: "客厅风扇",
            roomName: "客厅",
            kindTag: .fan
        )
    }

    private static func leakIdentity() -> DeviceSourceIdentity {
        DeviceSourceIdentity(
            dids: [leakDID],
            model: "lumi.sensor_wleak.aq1",
            name: "厨房水浸",
            roomName: "厨房",
            kindTag: .sensor
        )
    }

    private static func makePruneReport(
        scope: String,
        connection: ConnectionCapabilityID,
        hidden: [SmartDevice],
        safety: [SmartDevice]
    ) -> MiotTypePruneReport {
        MiotTypePruneReport(
            scope: scope,
            hiddenIndexedDevices: hidden.map { device in
                let keys = device.referencedEntityIds.isEmpty ? [device.id] : device.referencedEntityIds
                return CapabilityIndexedDevice(
                    id: device.id,
                    name: device.name,
                    category: device.capabilityCategoryID,
                    connection: connection,
                    sourceScope: scope,
                    isSourceAvailable: true,
                    upstreamHiddenOrDisabled: false,
                    participatesInAllOff: false,
                    safetySignals: [.starredOffline],
                    readKeys: keys,
                    safetyReadKeys: keys
                )
            },
            hiddenDeviceIds: Set(hidden.map(\.id)).subtracting(safety.map(\.id)),
            safetyDevices: safety
        )
    }

    @MainActor
    private static func configureDualStore(
        haMock: MockHomeProvider?,
        miMock: MockHomeProvider?,
        initialCanonicalIDs: [String: String] = [:],
        knownPreferenceIDs: Set<String> = []
    ) -> (HomeStore, DualSourceHomeProvider) {
        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set(haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken("ha-token", defaults: defaults, vault: vault)

        let dual = DualSourceHomeProvider(
            homeAssistant: haMock,
            xiaomiCloud: miMock,
            initialCanonicalIDs: initialCanonicalIDs,
            knownPreferenceIDs: { knownPreferenceIDs }
        )
        let store = HomeStore(provider: dual, credentialVault: vault, defaults: defaults)
        store.toastAutoDismissInterval = nil
        store.enableSafetyAlerts = true
        var selection = store.capabilitySelection
        selection.enabledConnections.formUnion([.homeAssistant, .xiaomiCloud])
        selection.enabledConnectionScopes.formUnion([haScope, miScope])
        store.capabilitySelection = selection
        return (store, dual)
    }

    @Test("Mi pruning expands starred canonical ID to Mi source did and translates retained offline alerts back (#303)")
    @MainActor
    func miPruningCanonicalizesStarredOfflineAlert() async throws {
        let haFan = Self.fanDevice(id: Self.fanHAID, entity: "fan.living_fan")
        let miFan = Self.fanDevice(id: Self.fanDID, entity: "miot:\(Self.fanDID):2")
        let haMock = MockHomeProvider(snapshot: Self.pairedHome(
            devices: [Self.visibleLight, haFan],
            identities: [Self.fanHAID: Self.fanIdentity()]
        ))
        let miMock = MockHomeProvider(snapshot: Self.pairedHome(
            devices: [miFan],
            identities: [Self.fanDID: Self.fanIdentity()]
        ))
        let (store, dual) = Self.configureDualStore(haMock: haMock, miMock: miMock)
        defer { Task { await dual.shutdown() } }

        try await store.waitForTestSnapshot()
        try await awaitState {
            store.devices.contains { $0.id == Self.fanHAID }
                && store.pairedDeviceIDs.contains(Self.fanHAID)
        }
        #expect(dual.canonicalToMiSourceIDs[Self.fanHAID] == [Self.fanDID])

        // Star the paired card by its canonical ID (HA ID != Mi did), then close `.fan`.
        store.favoriteDeviceIds = [Self.fanHAID]
        var selection = store.capabilitySelection
        selection.enabledCategories.remove(.fan)
        store.capabilitySelection = selection
        store.syncMiotTypePrunePolicy()

        let miPolicy = store.miotTypePruneBox.get()
        #expect(miPolicy.safetyPolicy.starredDeviceIds.contains(Self.fanHAID))
        #expect(miPolicy.safetyPolicy.starredDeviceIds.contains(Self.fanDID))

        // Verify partitionDevices keeps the Mi record when evaluated with the published policy.
        let miIndexed = CapabilityIndexedDevice(
            id: Self.fanDID, name: miFan.name, category: .fan,
            connection: .xiaomiCloud, sourceScope: Self.miScope,
            isSourceAvailable: true, upstreamHiddenOrDisabled: false, participatesInAllOff: false,
            safetySignals: [.starredOffline], readKeys: [Self.fanDID], safetyReadKeys: [Self.fanDID]
        )
        let partition = CapabilityReferenceEngine.partitionDevices(
            devices: [miIndexed], selection: miPolicy.selection, safetyPolicy: miPolicy.safetyPolicy
        )
        #expect(partition.hiddenSafetyRetainedDeviceIds == [Self.fanDID])

        // Prune `.fan` out of live snapshots (simulating closed type on both sides).
        await haMock.updateSnapshot(SynthesizedHome(devices: [Self.visibleLight]))
        await miMock.updateSnapshot(SynthesizedHome(devices: []))
        try await awaitState {
            !store.devices.contains { $0.id == Self.fanHAID }
        }
        // Monotonic mapping survives pruning.
        #expect(dual.miSourceIDs(forCanonicalIDs: [Self.fanHAID]) == [Self.fanDID])

        // Mi emits prune report with native did while online, then transitions to offline.
        let onlineMiReport = Self.makePruneReport(
            scope: Self.miScope, connection: .xiaomiCloud, hidden: [miFan], safety: [miFan]
        )
        await miMock.sendMiotTypePrune(onlineMiReport)
        try await awaitState {
            store.typeHiddenSafetyDevices.map(\.id) == [Self.fanHAID]
        }
        #expect(store.evaluateDeviceControlGate(deviceId: Self.fanHAID).rejectionReason == .categoryDisabled(.fan))
        await #expect(throws: CapabilityControlBlockedError(reason: .categoryDisabled(.fan))) {
            try await store.executeDeviceCommand(.setMiotProperty(entityId: "miot:\(Self.fanDID):2", piid: 1, value: .bool(false)))
        }
        #expect(await miMock.executedCommands.isEmpty)

        var offlineMiFan = miFan
        offlineMiFan.isOnline = false
        let offlineMiReport = Self.makePruneReport(
            scope: Self.miScope, connection: .xiaomiCloud, hidden: [offlineMiFan], safety: [offlineMiFan]
        )
        await miMock.sendMiotTypePrune(offlineMiReport)
        try await awaitState {
            store.recentSafetyAlerts.contains { $0.alert.deviceId == Self.fanHAID && $0.alert.id.hasPrefix("offline:\(Self.fanHAID):") }
        }
        #expect(store.panelActivities.contains { activity in
            if case .safety(let recorded) = activity.kind {
                return recorded.alert.deviceId == Self.fanHAID
            }
            return false
        })
    }

    @Test("HA pruning expands starred canonical ID to HA native ID and translates reports after Mi is disabled (#325)")
    @MainActor
    func haPruningCanonicalizesStarredOfflineAlert() async throws {
        let haFan = Self.fanDevice(id: Self.fanHAID, entity: "fan.living_fan")
        let miFan = Self.fanDevice(id: Self.fanDID, entity: "miot:\(Self.fanDID):2")
        let haMock = MockHomeProvider(snapshot: Self.pairedHome(
            devices: [Self.visibleLight, haFan],
            identities: [Self.fanHAID: Self.fanIdentity()]
        ))
        let miMock = MockHomeProvider(snapshot: Self.pairedHome(
            devices: [miFan],
            identities: [Self.fanDID: Self.fanIdentity()]
        ))
        // Pre-existing preference on Mi did makes Mi did the canonical ID (canonical ID != HA native ID).
        let (store, dual) = Self.configureDualStore(
            haMock: haMock,
            miMock: miMock,
            knownPreferenceIDs: [Self.fanDID]
        )
        defer { Task { await dual.shutdown() } }

        try await store.waitForTestSnapshot()
        try await awaitState {
            store.devices.contains { $0.id == Self.fanDID }
                && store.pairedDeviceIDs.contains(Self.fanDID)
        }
        #expect(dual.canonicalToHASourceIDs[Self.fanDID] == [Self.fanHAID])

        store.favoriteDeviceIds = [Self.fanDID]
        // Disable Xiaomi Cloud; the card keeps its canonical ID (fanDID).
        await dual.setSourceProvider(nil, for: .xiaomiCloud)

        var selection = store.capabilitySelection
        selection.enabledCategories.remove(.fan)
        store.capabilitySelection = selection
        store.syncMiotTypePrunePolicy()

        let haPolicy = store.haTypePruneBox.get()
        #expect(haPolicy.safetyPolicy.starredDeviceIds.contains(Self.fanDID))
        #expect(haPolicy.safetyPolicy.starredDeviceIds.contains(Self.fanHAID))

        // Verify partitionDevices keeps the HA card under its native ID.
        let haIndexed = CapabilityIndexedDevice(
            id: Self.fanHAID, name: haFan.name, category: .fan,
            connection: .homeAssistant, sourceScope: Self.haScope,
            isSourceAvailable: true, upstreamHiddenOrDisabled: false, participatesInAllOff: false,
            safetySignals: [.starredOffline], readKeys: ["fan.living_fan"], safetyReadKeys: ["fan.living_fan"]
        )
        let partition = CapabilityReferenceEngine.partitionDevices(
            devices: [haIndexed], selection: haPolicy.selection, safetyPolicy: haPolicy.safetyPolicy
        )
        #expect(partition.hiddenSafetyRetainedDeviceIds == [Self.fanHAID])

        // HA prunes the fan from visible devices and sends `.haTypePruneChanged` with HA native ID.
        await haMock.updateSnapshot(SynthesizedHome(devices: [Self.visibleLight]))
        try await awaitState {
            !store.devices.contains { $0.id == Self.fanDID }
        }

        let onlineHAReport = Self.makePruneReport(
            scope: Self.haScope, connection: .homeAssistant, hidden: [haFan], safety: [haFan]
        )
        await haMock.sendHATypePrune(onlineHAReport)
        try await awaitState {
            store.typeHiddenSafetyDevices.map(\.id) == [Self.fanDID]
        }
        #expect(store.evaluateDeviceControlGate(deviceId: Self.fanDID).rejectionReason == .categoryDisabled(.fan))

        var offlineHAFan = haFan
        offlineHAFan.isOnline = false
        let offlineHAReport = Self.makePruneReport(
            scope: Self.haScope, connection: .homeAssistant, hidden: [offlineHAFan], safety: [offlineHAFan]
        )
        await haMock.sendHATypePrune(offlineHAReport)
        try await awaitState {
            store.recentSafetyAlerts.contains { $0.alert.deviceId == Self.fanDID && $0.alert.id.hasPrefix("offline:\(Self.fanDID):") }
        }
    }

    @Test("Persisted initialCanonicalIDs restore bidirectional translation even when the type is already closed at launch")
    @MainActor
    func persistedCanonicalIDsWorkBeforeAnyVisiblePair() async throws {
        let haMock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.visibleLight]))
        let miMock = MockHomeProvider(snapshot: SynthesizedHome(devices: []))
        let persisted: [String: String] = [
            "pair:\(Self.fanHAID)|\(Self.fanDID)": Self.fanDID,
            "ha:\(Self.fanHAID)": Self.fanDID,
            "mi:\(Self.fanDID)": Self.fanDID,
        ]
        let (store, dual) = Self.configureDualStore(
            haMock: haMock,
            miMock: miMock,
            initialCanonicalIDs: persisted
        )
        defer { Task { await dual.shutdown() } }

        try await store.waitForTestSnapshot()
        store.favoriteDeviceIds = [Self.fanDID]
        var selection = store.capabilitySelection
        selection.enabledCategories.remove(.fan)
        store.capabilitySelection = selection
        store.syncMiotTypePrunePolicy()

        #expect(store.haTypePruneBox.get().safetyPolicy.starredDeviceIds.contains(Self.fanHAID))
        #expect(store.miotTypePruneBox.get().safetyPolicy.starredDeviceIds.contains(Self.fanDID))

        let haFan = Self.fanDevice(id: Self.fanHAID, entity: "fan.living_fan")
        await haMock.sendHATypePrune(Self.makePruneReport(
            scope: Self.haScope, connection: .homeAssistant, hidden: [haFan], safety: [haFan]
        ))
        try await awaitState {
            store.typeHiddenSafetyDevices.map(\.id) == [Self.fanDID]
        }
    }

    @Test("Same physical device retained by both HA and Mi deduplicates by canonical ID and alerts only once (#325)")
    @MainActor
    func dualRetainedDeviceDoesNotDuplicateOfflineOrSensorAlerts() async throws {
        let haFan = Self.fanDevice(id: Self.fanHAID, entity: "fan.living_fan")
        let miFan = Self.fanDevice(id: Self.fanDID, entity: "miot:\(Self.fanDID):2")
        let haLeak = Self.leakDevice(id: Self.leakHAID, observationSourceId: "\(Self.leakHAID)#binary_sensor.kitchen_leak", alarming: false)
        let miLeak = Self.leakDevice(id: Self.leakDID, observationSourceId: "\(Self.leakDID)#miot:2", alarming: false)

        let haMock = MockHomeProvider(snapshot: Self.pairedHome(
            devices: [Self.visibleLight, haFan, haLeak],
            identities: [
                Self.fanHAID: Self.fanIdentity(),
                Self.leakHAID: Self.leakIdentity(),
            ]
        ))
        let miMock = MockHomeProvider(snapshot: Self.pairedHome(
            devices: [miFan, miLeak],
            identities: [
                Self.fanDID: Self.fanIdentity(),
                Self.leakDID: Self.leakIdentity(),
            ]
        ))
        let (store, dual) = Self.configureDualStore(haMock: haMock, miMock: miMock)
        defer { Task { await dual.shutdown() } }

        try await store.waitForTestSnapshot()
        try await awaitState {
            store.pairedDeviceIDs.contains(Self.fanHAID)
                && store.pairedDeviceIDs.contains(Self.leakHAID)
        }
        #expect(dual.canonicalToMiSourceIDs[Self.fanHAID] == [Self.fanDID])
        #expect(dual.canonicalToMiSourceIDs[Self.leakHAID] == [Self.leakDID])

        store.favoriteDeviceIds = [Self.fanHAID]
        var selection = store.capabilitySelection
        selection.enabledCategories.subtract([.fan, .sensor])
        store.capabilitySelection = selection
        store.syncMiotTypePrunePolicy()

        await haMock.updateSnapshot(SynthesizedHome(devices: [Self.visibleLight]))
        await miMock.updateSnapshot(SynthesizedHome(devices: []))
        try await awaitState {
            !store.devices.contains { $0.id == Self.fanHAID || $0.id == Self.leakHAID }
        }

        // 1. Both sources retain the same starred fan online -> single retained entry.
        await haMock.sendHATypePrune(Self.makePruneReport(
            scope: Self.haScope, connection: .homeAssistant, hidden: [haFan], safety: [haFan]
        ))
        await miMock.sendMiotTypePrune(Self.makePruneReport(
            scope: Self.miScope, connection: .xiaomiCloud, hidden: [miFan], safety: [miFan]
        ))
        try await awaitState {
            store.miotTypePruneReports[Self.haScope] != nil && store.miotTypePruneReports[Self.miScope] != nil
        }
        #expect(store.typeHiddenSafetyDevices.map(\.id) == [Self.fanHAID])

        // One side goes offline while the other is still online -> no premature alert;
        // once both sides report offline -> exactly one offline alert.
        var offlineHAFan = haFan
        offlineHAFan.isOnline = false
        var offlineMiFan = miFan
        offlineMiFan.isOnline = false

        var emittedAlerts: [SafetyAlert] = []
        store.onSafetyAlert = { emittedAlerts.append($0) }

        await haMock.sendHATypePrune(Self.makePruneReport(
            scope: Self.haScope, connection: .homeAssistant, hidden: [offlineHAFan], safety: [offlineHAFan]
        ))
        try await awaitState {
            store.miotTypePruneReports[Self.haScope]?.safetyDevices.first?.isOnline == false
        }
        #expect(emittedAlerts.filter { $0.deviceId == Self.fanHAID }.isEmpty)

        await miMock.sendMiotTypePrune(Self.makePruneReport(
            scope: Self.miScope, connection: .xiaomiCloud, hidden: [offlineMiFan], safety: [offlineMiFan]
        ))
        try await awaitState {
            store.recentSafetyAlerts.contains { $0.alert.deviceId == Self.fanHAID && $0.alert.id.hasPrefix("offline:\(Self.fanHAID):") }
        }
        #expect(emittedAlerts.filter { $0.deviceId == Self.fanHAID && $0.id.hasPrefix("offline:") }.count == 1)

        // 2. Same physical leak sensor retained by both Mi and HA: Mi reports alarming first,
        // then HA reports alarming (switching the winning copy in typeHiddenSafetyDevices) ->
        // must fire only ONE leak alert, not two.
        let alarmingMiLeak = Self.leakDevice(
            id: Self.leakDID, observationSourceId: "\(Self.leakDID)#miot:2", alarming: true
        )
        let alarmingHALeak = Self.leakDevice(
            id: Self.leakHAID, observationSourceId: "\(Self.leakHAID)#binary_sensor.kitchen_leak", alarming: true
        )
        await miMock.sendMiotTypePrune(Self.makePruneReport(
            scope: Self.miScope, connection: .xiaomiCloud,
            hidden: [offlineMiFan, alarmingMiLeak], safety: [offlineMiFan, alarmingMiLeak]
        ))
        try await awaitState {
            store.recentSafetyAlerts.contains { $0.alert.deviceId == Self.leakHAID && $0.alert.id.hasPrefix("sensor:leak:") }
        }
        await haMock.sendHATypePrune(Self.makePruneReport(
            scope: Self.haScope, connection: .homeAssistant,
            hidden: [offlineHAFan, alarmingHALeak], safety: [offlineHAFan, alarmingHALeak]
        ))
        try await awaitState {
            store.miotTypePruneReports[Self.haScope]?.safetyDevices.contains { $0.id == Self.leakHAID } == true
        }
        #expect(
            emittedAlerts.filter { $0.deviceId == Self.leakHAID && $0.id.hasPrefix("sensor:leak:") }.count == 1,
            "switching from Mi to HA on the same canonical leak sensor must not duplicate the alarm"
        )
    }
}
