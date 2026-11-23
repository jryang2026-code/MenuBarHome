import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

/// P3a-M: a closed Mi device type stops contributing read keys and cards, while every alert the user
/// still has switched on keeps its own signals (`architecture.md` §D, rulings 2–4).
struct MiotTypePruningTests {
    private static let scope = "mi:acct"
    /// The host's default switch set: smoke / gas / leak, the long-run, power and battery reminders,
    /// and favourited devices going offline. Contact and motion are off by default.
    private static let defaultSignals: Set<SafetySignalKind> = [
        .leak, .smoke, .gas, .lock, .lowBattery, .longRunningPlug, .longRunningClimate, .highPower, .starredOffline,
    ]

    private static func policy(
        _ categories: Set<DeviceCategoryID>,
        signals: Set<SafetySignalKind> = defaultSignals,
        enabledScopes: Set<String> = [scope]
    ) -> MiotTypePrunePolicy {
        MiotTypePrunePolicy(
            selection: CapabilitySelection(
                enabledConnections: [.xiaomiCloud], enabledConnectionScopes: enabledScopes,
                enabledFeatures: [], enabledCategories: categories
            ),
            safetyPolicy: SafetyRetentionPolicy(enabledSignals: signals),
            sourceScope: scope
        )
    }

    private static func spec(_ model: String) throws -> MiotDeviceSpec {
        try MiotCoverageBaselineTests.coverageSpec(model)
    }

    private static func specs(_ models: String...) throws -> [String: MiotDeviceSpec] {
        var specs = MiotFixtures.specs
        for model in models { specs[model] = try spec(model) }
        return specs
    }

    private static func plan(
        _ records: [MiDeviceRecord], _ specs: [String: MiotDeviceSpec], _ policy: MiotTypePrunePolicy
    ) -> MiotTypePrunePlan {
        MiotSynthesizer.typePrunePlan(devices: records, rooms: [], specs: specs, policy: policy)
    }

    private static let curtain = MiDeviceRecord(did: "curtain-1", name: "窗帘", model: "090615.curtain.1mcu01", isOnline: true)
    private static let light = MiDeviceRecord(did: "light-1", name: "吸顶灯", model: "090615.light.ailig1", isOnline: true)
    private static let plug = MiDeviceRecord(did: "plug-1", name: "插座", model: "090615.plug.cmp86", isOnline: true)
    private static let three = [curtain, light, plug]

    @Test("A closed cover type contributes neither cards nor read keys, while lights and plugs keep their plan")
    func curtainIsPrunedWhileLightAndPlugStay() throws {
        let specs = try Self.specs("090615.curtain.1mcu01", "090615.light.ailig1", "090615.plug.cmp86")
        let plan = Self.plan(Self.three, specs, Self.policy([.light, .plug]))

        #expect(plan.isPruned)
        #expect(plan.visibleRecords.map(\.did) == ["light-1", "plug-1"])
        #expect(plan.hiddenDeviceIds == ["curtain-1"])
        #expect(plan.safetyRecords.isEmpty)
        #expect(!plan.readKeys.contains { $0.did == "curtain-1" }, "a pruned cover must not be polled")
        #expect(plan.hiddenIndexedDevices.map(\.id) == ["curtain-1"])
        #expect(plan.hiddenIndexedDevices.first?.category == .cover)
        #expect(plan.hiddenIndexedDevices.first?.sourceScope == Self.scope)
        #expect(Set(plan.readKeys) == Set(MiotSynthesizer.legacyPropKeys(devices: [Self.light, Self.plug], specs: specs)))
    }

    @Test("Every type on keeps the historical read plan key for key")
    func everyCategoryOnKeepsTheHistoricalReadPlan() throws {
        let specs = try MiotCoverageBaselineTests.coverageSpecs()
        let records = specs.keys.sorted().enumerated().map {
            MiDeviceRecord(did: "did-\($0.offset)", name: $0.element, model: $0.element, isOnline: true)
        }
        let plan = Self.plan(records, specs, Self.policy(Set(DeviceCategoryID.allCases)))
        #expect(!plan.isPruned)
        #expect(plan.visibleRecords.count == records.count)
        #expect(plan.hiddenDeviceIds.isEmpty)
        #expect(plan.readKeys == MiotSynthesizer.legacyPropKeys(devices: records, specs: specs))
    }

    @Test("A record whose spec has not arrived stays visible and invents no keys")
    func missingSpecStaysUnpruned() throws {
        let unknown = MiDeviceRecord(did: "unknown-1", name: "未知", model: "unknown.model", isOnline: true)
        let plan = Self.plan([unknown, Self.light], try Self.specs("090615.light.ailig1"), Self.policy([.plug]))
        #expect(plan.visibleRecords.map(\.did).contains("unknown-1"))
        #expect(plan.hiddenDeviceIds == ["light-1"])
        #expect(!plan.readKeys.contains { $0.did == "unknown-1" || $0.did == "light-1" })
    }

    @Test("A split parent is drawn through its keys only: no visible record, no read key")
    func splitParentStaysOutOfThePlan() throws {
        let specs = ["lemesh.switch.sw2f12": try #require(MiotFixtures.specs["lemesh.switch.sw2f12"])]
        let parent = MiDeviceRecord(did: "panel", name: "双开面板", model: "lemesh.switch.sw2f12", isOnline: true)
        let left = MiDeviceRecord(
            did: "panel.s2", name: "双开面板 左键", model: "lemesh.switch.sw2f12",
            isOnline: true, splitParentDid: "panel", splitSiid: 2
        )
        let right = MiDeviceRecord(
            did: "panel.s3", name: "双开面板 右键", model: "lemesh.switch.sw2f12",
            isOnline: true, splitParentDid: "panel", splitSiid: 3
        )
        let plan = Self.plan([parent, left, right], specs, Self.policy([.plug]))

        #expect(plan.visibleRecords.map(\.did) == ["panel.s2", "panel.s3"])
        #expect(!plan.visibleDeviceIds.contains("panel"))
        #expect(!plan.hiddenDeviceIds.contains("panel"))
        #expect(!plan.hiddenIndexedDevices.contains { $0.id == "panel" })
        #expect(plan.readKeys.count == 2)
        #expect(Set(plan.readKeys.map(\.siid)) == [2, 3])
    }

    @Test("A smart door drawn as a camera keeps motion and lock, so closing cameras keeps its safety reads")
    func smartDoorKeepsSafetySignals() throws {
        let door = MiDeviceRecord(did: "door-1", name: "智能门", model: "chuangmi.door.515a01", isOnline: true)
        let plan = Self.plan([door], try Self.specs("chuangmi.door.515a01"), Self.policy([.light], signals: [.motion, .lock]))
        #expect(plan.visibleRecords.isEmpty)
        #expect(plan.safetyRecords.map(\.did) == ["door-1"])
        #expect(plan.safetyRetainedDeviceIds == ["door-1"])
        #expect(!plan.readKeys.isEmpty, "its motion and lock reads stay in the plan")
        let signals = try #require(plan.hiddenIndexedDevices.first?.safetySignals)
        #expect(signals.isSuperset(of: [.motion, .lock]))
    }

    @Test("Only a Mi camera with a real ring event is retained for doorbell reads")
    func onlyActualMiDoorbellIsRetained() throws {
        let camera = MiDeviceRecord(did: "camera-1", name: "Camera", model: "careco.camera.650", isOnline: true)
        let doorbell = MiDeviceRecord(did: "doorbell-1", name: "Doorbell", model: "test.doorbell", isOnline: true)
        var specs = try Self.specs(camera.model)
        specs[doorbell.model] = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:video-doorbell:0000A03A:test:1",
            services: [MiotService(
                iid: 2,
                type: "urn:miot-spec-v2:service:video-doorbell:00007867:test:1",
                events: [MiotEvent(iid: 1, type: "urn:miot-spec-v2:event:doorbell-ring:00005013:test:1")]
            )]
        )
        let plan = Self.plan([camera, doorbell], specs, Self.policy([.light], signals: [.doorbell]))
        #expect(plan.safetyRecords.map(\.did) == [doorbell.did])
    }

    @Test("An offline Mi camera carries its spec-level alarm into the type-selection preview")
    @MainActor
    func offlineMiServiceAlarmAppearsInPreview() throws {
        let door = MiDeviceRecord(did: "door-1", name: "门铃", model: "chuangmi.door.515a01", isOnline: false)
        let specs = try Self.specs(door.model)
        let actual = Self.plan([door], specs, Self.policy([.light], signals: [.motion]))
        let home = MiotSynthesizer.synthesize(devices: [door], rooms: [], specs: specs, values: [:])
        let device = try #require(home.devices.first)
        let store = HomeStore(provider: MockHomeProvider(snapshot: home), defaults: InMemoryUserDefaults())
        store.enableSafetyAlerts = true
        store.doorbellAutoPopup = false
        store.doorbellChime = false
        store.setSensorAlertEnabled(.motion, true)
        store.devices = home.devices

        let impact = store.previewDeviceCategorySelection([.light])
        #expect(!device.isOnline)
        #expect(device.safetyObservations.isEmpty)
        #expect(actual.safetyRetainedDeviceIds.contains(device.id))
        #expect(impact.retainedSafetyDevices.first { $0.id == device.id }?.signals == [.motion])
    }

    @Test("A real lock keeps its identity signals; child-lock appliances are not locks")
    func lockIdentityBeatsChildLockTokens() throws {
        let lock = MiDeviceRecord(did: "lock-1", name: "门锁", model: "miot.lock.ble22", isOnline: true)
        let fishTank = MiDeviceRecord(did: "tank-1", name: "鱼缸", model: "xiaomi.fishbowl.m200", isOnline: true)
        let plan = Self.plan(
            [lock, fishTank], try Self.specs("miot.lock.ble22", "xiaomi.fishbowl.m200"),
            Self.policy([.light], signals: [.lock, .lowBattery])
        )
        let byId = Dictionary(uniqueKeysWithValues: plan.hiddenIndexedDevices.map { ($0.id, $0) })
        let lockSignals = try #require(byId["lock-1"]?.safetySignals)
        #expect(lockSignals.isSuperset(of: [.lock, .lowBattery]))
        #expect(plan.safetyRetainedDeviceIds.contains("lock-1"))
        let tankSignals = try #require(byId["tank-1"]?.safetySignals)
        #expect(!tankSignals.contains(.lock), "physical-controls-locked is a lockout, not a lock")
    }

    @Test("The safety master switch off retains nothing; each alert keeps only its own signal")
    func retentionFollowsTheEnabledSwitches() throws {
        let specs = try Self.specs("090615.curtain.1mcu01", "bkxh.flood.yf02", "090615.plug.cmp86")
        let leak = MiDeviceRecord(did: "leak-1", name: "水浸", model: "bkxh.flood.yf02", isOnline: true)
        let records = [Self.curtain, leak, Self.plug]

        let off = Self.plan(records, specs, Self.policy([.light], signals: []))
        #expect(off.safetyRecords.isEmpty)
        #expect(off.readKeys.isEmpty)
        #expect(Set(off.hiddenDeviceIds) == ["curtain-1", "leak-1", "plug-1"])

        let leakOnly = Self.plan(records, specs, Self.policy([.light], signals: [.leak]))
        #expect(leakOnly.safetyRecords.map(\.did) == ["leak-1"])
        #expect(leakOnly.readKeys.allSatisfy { $0.did == "leak-1" })

        let plugOnly = Self.plan(records, specs, Self.policy([.light], signals: [.longRunningPlug, .highPower]))
        #expect(plugOnly.safetyRecords.map(\.did) == ["plug-1"])
        #expect(plugOnly.readKeys.allSatisfy { $0.did == "plug-1" })
    }

    @Test("A disabled account scope prunes nothing: a login in flight must not look like a closed type")
    func disabledScopeKeepsTheLegacyPlan() throws {
        let specs = try Self.specs("090615.curtain.1mcu01")
        let plan = Self.plan([Self.curtain], specs, Self.policy([.light], enabledScopes: ["mi:other"]))
        #expect(!plan.isPruned)
        #expect(plan.visibleRecords.map(\.did) == ["curtain-1"])
        #expect(plan.readKeys == MiotSynthesizer.legacyPropKeys(devices: [Self.curtain], specs: specs))
    }
}
