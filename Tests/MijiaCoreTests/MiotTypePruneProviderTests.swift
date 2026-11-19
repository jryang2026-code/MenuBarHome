import Foundation
import Testing
@testable import MijiaCore

extension EventLog {
    /// Every device-type pruning report the provider delivered, in order (P3a-M).
    var typePruneReports: [MiotTypePruneReport] {
        events.compactMap { if case .miotTypePruneChanged(let report) = $0 { return report } else { return nil } }
    }
}

/// P3a-M at the two seams the plan touches: the Mi provider's poll and snapshot, and the host's
/// write gate and alert engine.
struct MiotTypePruneProviderTests {
    static let session = MiSession(userId: "42", cUserId: "c", ssecurity: "c2VjcmV0", serviceToken: "tok")
    static let scope = "mi:acct"

    struct PruneSpecSource: MiotSpecSource {
        let specs: [String: MiotDeviceSpec]
        func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? { specs[model] }
    }

    static func specs() throws -> [String: MiotDeviceSpec] {
        var specs = MiotFixtures.specs
        for model in ["090615.curtain.1mcu01", "bkxh.flood.yf02"] {
            specs[model] = try MiotCoverageBaselineTests.coverageSpec(model)
        }
        return specs
    }

    static func policy(_ categories: Set<DeviceCategoryID>, signals: Set<SafetySignalKind>) -> MiotTypePrunePolicy {
        MiotTypePrunePolicy(
            selection: CapabilitySelection(
                enabledConnections: [.xiaomiCloud], enabledConnectionScopes: [scope],
                enabledFeatures: [], enabledCategories: categories
            ),
            safetyPolicy: SafetyRetentionPolicy(enabledSignals: signals),
            sourceScope: scope
        )
    }

    static let curtain = MiDeviceRecord(did: "curtain-1", name: "客厅窗帘", model: "090615.curtain.1mcu01", isOnline: true)
    static let leak = MiDeviceRecord(did: "leak-1", name: "厨房水浸", model: "bkxh.flood.yf02", isOnline: true)

    private func makeProvider(_ api: StubMiCloudAPI, _ box: MiotTypePrunePolicyBox) throws -> MiCloudProvider {
        MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: PruneSpecSource(specs: try Self.specs()),
            pollInterval: .seconds(60),
            selectedHomeLoader: { nil },
            typePrunePolicyLoader: { box.get() }
        )
    }

    private func start(_ provider: MiCloudProvider) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let stream = provider.events()
        return (log, Task { for await event in stream { await log.append(event) } })
    }

    @Test("A closed cover type is not polled and leaves the snapshot, but keeps its identity for the write gate")
    func closedCoverStopsBeingPolledAndDrawn() async throws {
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord, Self.curtain], rooms: [], values: MiotFixtures.lightValues)
        let provider = try makeProvider(api, MiotTypePrunePolicyBox(policy: Self.policy([.light], signals: [])))
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })

        let polled = await api.getPropsCalls.first ?? []
        #expect(!polled.isEmpty)
        #expect(!polled.contains { $0.did == "curtain-1" }, "a closed cover type must not be polled")
        #expect(await log.snapshots.first?.devices.map(\.id) == ["123"])
        #expect(await log.wait { await $0.typePruneReports.last?.hiddenDeviceIds.isEmpty == false })
        let report = try #require(await log.typePruneReports.last)
        #expect(report.scope == Self.scope)
        #expect(report.hiddenDeviceIds == ["curtain-1"])
        #expect(report.hiddenIndexedDevices.map(\.id) == ["curtain-1"])
        #expect(report.hiddenIndexedDevices.first?.category == .cover)
        #expect(report.safetyDevices.isEmpty)
        await provider.shutdown()
    }

    @Test("The report reaches the host before the snapshot that triggers safety evaluation")
    func reportArrivesBeforeTheSnapshot() async throws {
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord, Self.leak], rooms: [],
            values: MiotFixtures.lightValues.merging([MiotFixtures.key("leak-1", 2, 1006): .bool(true)]) { $1 }
        )
        let provider = try makeProvider(api, MiotTypePrunePolicyBox(policy: Self.policy([.light], signals: [.leak])))
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await $0.typePruneReports.contains { !$0.safetyDevices.isEmpty } })
        let order = await log.events.map { event -> String in
            switch event {
            case .miotTypePruneChanged: "report"
            case .snapshotUpdated: "snapshot"
            default: "other"
            }
        }
        #expect(order.firstIndex(of: "report")! < order.firstIndex(of: "snapshot")!)
        await provider.shutdown()
    }

    @Test("With every type on the poll is byte for byte the historical key list")
    func everyTypeOnKeepsThePolledKeys() async throws {
        let specs = try Self.specs()
        let records = [MiotFixtures.lightRecord, Self.curtain]
        let api = StubMiCloudAPI(devices: records, rooms: [], values: MiotFixtures.lightValues)
        let box = MiotTypePrunePolicyBox(policy: Self.policy(Set(DeviceCategoryID.allCases), signals: []))
        let provider = try makeProvider(api, box)
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })

        #expect(await api.getPropsCalls.first == MiotSynthesizer.legacyPropKeys(devices: records, specs: specs))
        #expect(Set(await log.snapshots.first?.devices.map(\.id) ?? []) == ["123", "curtain-1"])
        #expect(await log.typePruneReports.contains { !$0.isEmpty } == false)
        await provider.shutdown()
    }

    @Test("A closed sensor type still reads its leak signal and hands the hidden device to the alert engine")
    func closedSensorKeepsItsEnabledAlert() async throws {
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord, Self.leak], rooms: [],
            values: MiotFixtures.lightValues.merging([
                MiotFixtures.key("leak-1", 2, 1006): .bool(true),
                MiotFixtures.key("leak-1", 3, 1003): .number(90),
            ]) { $1 }
        )
        let provider = try makeProvider(api, MiotTypePrunePolicyBox(policy: Self.policy([.light], signals: [.leak])))
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })

        let polled = await api.getPropsCalls.first ?? []
        #expect(Set(polled.map(\.did)) == ["123", "leak-1"], "only the enabled light and the retained leak stay")
        #expect(await log.snapshots.first?.devices.map(\.id) == ["123"], "the retained sensor is not drawn")
        #expect(await log.wait { await $0.typePruneReports.last?.safetyDevices.isEmpty == false })
        let report = try #require(await log.typePruneReports.last)
        #expect(report.safetyDevices.map(\.id) == ["leak-1"])
        let hidden = try #require(report.safetyDevices.first)
        guard case .sensor(let sensorSpec) = hidden.kind else {
            Issue.record("expected a sensor card for the retained leak device")
            return
        }
        #expect(try #require(sensorSpec.observations.first { $0.kind == .leak }).alarming)
        await provider.shutdown()
    }

    @Test("Turning the last leak alert off ends the retained read on the next poll")
    func disablingTheAlertEndsTheRead() async throws {
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord, Self.leak], rooms: [],
            values: MiotFixtures.lightValues.merging([MiotFixtures.key("leak-1", 2, 1006): .bool(true)]) { $1 }
        )
        let box = MiotTypePrunePolicyBox(policy: Self.policy([.light], signals: [.leak]))
        let provider = try makeProvider(api, box)
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })
        #expect(await api.getPropsCalls.first?.contains { $0.did == "leak-1" } == true)

        box.update(Self.policy([.light], signals: []))
        await provider.refreshNow()
        #expect(await log.wait { _ in await api.getPropsCalls.count >= 2 })
        #expect(await api.getPropsCalls.last?.contains { $0.did == "leak-1" } == false)
        #expect(await log.wait { await $0.typePruneReports.last?.safetyDevices.isEmpty == true })
        await provider.shutdown()
    }
}
