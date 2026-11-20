import Foundation
import Testing
@testable import MijiaCore

/// P3b-M: Home Assistant device-type pruning happens after synthesis. The link is unchanged (a
/// `get_states` round has no per-domain form), a closed type's cards leave the round, their own state
/// changes stop re-synthesizing, and enabled alerts keep the cards they read.
struct HATypePruningTests {
    static let scope = "ha:http://192.168.1.60:8123"

    private static func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
        ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
    }

    private static func stateChanged(_ entityId: String, _ state: String, _ attributes: [String: JSONValue] = [:]) -> [String: JSONValue] {
        [
            "type": .string("event"),
            "event": .object([
                "event_type": .string("state_changed"),
                "data": .object([
                    "entity_id": .string(entityId),
                    "new_state": .object([
                        "entity_id": .string(entityId), "state": .string(state), "attributes": .object(attributes),
                    ]),
                ]),
            ]),
        ]
    }

    private static func object(_ pairs: [String: String?]) -> JSONValue {
        .object(pairs.compactMapValues { $0 }.mapValues(JSONValue.string))
    }

    private static func state(_ id: String, _ state: String, _ attributes: [String: JSONValue] = [:]) -> JSONValue {
        .object(["entity_id": .string(id), "state": .string(state), "attributes": .object(attributes)])
    }

    /// A light, a curtain, a leak sensor with a battery, a gas valve whose alarm is a `binary_sensor`
    /// row on the valve, a disabled device, an upstream-hidden blind, a scene and a script.
    static let home: [String: JSONValue] = [
        "areas": .array([
            object(["area_id": "living", "name": "客厅"]),
            object(["area_id": "kitchen", "name": "厨房"]),
            object(["area_id": "balcony", "name": "阳台"]),
        ]),
        "devices": .array([
            object(["id": "dev_light", "area_id": "living", "name": "吸顶灯"]),
            object(["id": "dev_cover", "area_id": "balcony", "name": "阳台窗帘"]),
            object(["id": "dev_leak", "area_id": "kitchen", "name": "水浸传感器"]),
            object(["id": "dev_valve", "area_id": "kitchen", "name": "燃气阀"]),
            object(["id": "dev_disabled", "area_id": "living", "name": "停用窗帘", "disabled_by": "user"]),
        ]),
        "entities": .array([
            object(["entity_id": "light.ceiling", "device_id": "dev_light"]),
            object(["entity_id": "cover.balcony", "device_id": "dev_cover"]),
            object(["entity_id": "binary_sensor.kitchen_leak", "device_id": "dev_leak"]),
            object(["entity_id": "sensor.kitchen_leak_battery", "device_id": "dev_leak"]),
            object(["entity_id": "valve.gas_main", "device_id": "dev_valve"]),
            object(["entity_id": "binary_sensor.gas_alarm", "device_id": "dev_valve"]),
            object(["entity_id": "cover.disabled_curtain", "device_id": "dev_disabled"]),
            object(["entity_id": "cover.hidden_blind", "hidden_by": "user"]),
            object(["entity_id": "scene.movie"]),
            object(["entity_id": "script.goodnight"]),
        ]),
        "states": .array([
            state("light.ceiling", "on", ["friendly_name": .string("吸顶灯")]),
            state("cover.balcony", "open", ["current_position": .number(80), "supported_features": .number(15)]),
            state("binary_sensor.kitchen_leak", "off", ["device_class": .string("moisture")]),
            state("sensor.kitchen_leak_battery", "90", ["device_class": .string("battery"), "unit_of_measurement": .string("%")]),
            state("valve.gas_main", "open", ["supported_features": .number(3)]),
            state("binary_sensor.gas_alarm", "off", ["device_class": .string("gas")]),
            state("cover.disabled_curtain", "open"),
            state("cover.hidden_blind", "open"),
            state("scene.movie", "scening", ["friendly_name": .string("观影")]),
            state("script.goodnight", "off", ["friendly_name": .string("晚安")]),
        ]),
    ]

    static func policy(
        closed: Set<DeviceCategoryID>,
        signals: Set<SafetySignalKind> = [],
        starred: Set<String> = [],
        enabledScopes: Set<String> = [scope]
    ) -> HATypePrunePolicy {
        HATypePrunePolicy(
            selection: CapabilitySelection(
                enabledConnections: [.homeAssistant], enabledConnectionScopes: enabledScopes, enabledFeatures: [],
                enabledCategories: Set(DeviceCategoryID.allCases).subtracting(closed)
            ),
            safetyPolicy: SafetyRetentionPolicy(enabledSignals: signals, starredDeviceIds: starred),
            sourceScope: Self.scope
        )
    }

    /// Loads one fixture under `policy`, returning the first complete round and its report.
    static func load(
        _ root: [String: JSONValue],
        policy: HATypePrunePolicy
    ) throws -> (HAHomeSnapshot, SynthesizedHome, MiotTypePruneReport?) {
        var snapshot = HAHomeSnapshot()
        _ = try snapshot.receive(reply(1, root["areas"] ?? .array([])), typePrunePolicy: policy)
        _ = try snapshot.receive(reply(2, root["devices"] ?? .array([])), typePrunePolicy: policy)
        _ = try snapshot.receive(reply(3, root["entities"] ?? .array([])), typePrunePolicy: policy)
        let home = try #require(try snapshot.receive(reply(4, root["states"] ?? .array([])), typePrunePolicy: policy))
        let report = snapshot.takeTypePruneReport()
        return (snapshot, home, report)
    }

    static func fixture(_ name: String) throws -> [String: JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Fixtures/\(name)")
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    static let fixtureNames = ["ha_snapshot.json", "ha_domain_cards.json", "ha_cover_snapshot.json", "ha_regressions.json"]

    @Test("Every type on, or the connection or its address off, keeps each fixture's round equal to the unpruned one", arguments: fixtureNames)
    func fullSelectionIsUnchanged(_ name: String) throws {
        let root = try Self.fixture(name)
        let (_, baseline, _) = try Self.load(root, policy: .unpruned)
        let noOps: [HATypePrunePolicy] = [
            Self.policy(closed: []),
            // The connection is off: the host suppresses it, the provider prunes nothing.
            HATypePrunePolicy(
                selection: CapabilitySelection(
                    enabledConnections: [], enabledConnectionScopes: [Self.scope], enabledFeatures: [],
                    enabledCategories: [.light]
                ),
                safetyPolicy: SafetyRetentionPolicy(), sourceScope: Self.scope
            ),
            // A new address is not an enabled scope yet.
            Self.policy(closed: [.cover, .sensor, .light], enabledScopes: ["ha:http://old.local:8123"]),
        ]
        for policy in noOps {
            var (snapshot, home, report) = try Self.load(root, policy: policy)
            #expect(home == baseline)
            #expect(report?.isEmpty ?? true)
            // Every later frame still matches the unpruned projection.
            var reference = HAHomeSnapshot()
            for id in 1...4 {
                let key = ["areas", "devices", "entities", "states"][id - 1]
                _ = try reference.receive(Self.reply(id, root[key] ?? .array([])))
            }
            for case .object(let entry) in root["states"]?.arrayValue ?? [] {
                guard let id = entry["entity_id"]?.stringValue else { continue }
                let frame = Self.stateChanged(id, "unavailable")
                #expect(try snapshot.receive(frame, typePrunePolicy: policy) == reference.receive(frame))
            }
        }
    }

    @Test("A closed cover leaves the round with its room, keeps its identity, and its events stop re-synthesizing")
    func closedCoverIsDroppedAndItsEventsAreSkipped() throws {
        let policy = Self.policy(closed: [.cover])
        var (snapshot, home, report) = try Self.load(Self.home, policy: policy)
        #expect(!home.devices.contains { $0.id == "dev_cover" })
        #expect(home.devices.contains { $0.id == "dev_light" })
        #expect(!home.rooms.contains { $0.name == "阳台" }, "a room with only hidden cards goes too")
        #expect(home.scenes.map(\.entityId).sorted() == ["scene.movie", "script.goodnight"], "scenes and scripts are never pruned")

        let pruned = try #require(report)
        #expect(pruned.scope == Self.scope)
        #expect(pruned.hiddenDeviceIds == ["dev_cover"])
        #expect(pruned.safetyDevices.isEmpty)
        let entry = try #require(pruned.hiddenIndexedDevices.first { $0.id == "dev_cover" })
        #expect(entry.category == .cover && entry.connection == .homeAssistant && entry.sourceScope == Self.scope)
        #expect(entry.readKeys.contains("cover.balcony"), "a stored entity command finds its hidden owner")
        // Upstream hidden or disabled entities never become cards, so they never enter the index.
        #expect(!pruned.hiddenIndexedDevices.contains { $0.id == "dev_disabled" || $0.id == "cover.hidden_blind" })

        #expect(try snapshot.receive(Self.stateChanged("cover.balcony", "closed"), typePrunePolicy: policy) == nil)
        #expect(snapshot.takeTypePruneReport() == nil)
        let next = try #require(try snapshot.receive(Self.stateChanged("light.ceiling", "off"), typePrunePolicy: policy))
        #expect(next.devices.first { $0.id == "dev_light" }?.isActiveOn == false)
        #expect(snapshot.takeTypePruneReport() == nil, "an unchanged report is not sent again")
    }

    @Test("Reopening the type re-synthesizes on the next frame, even one for a skipped entity")
    func policyChangeForcesTheNextRound() throws {
        let closed = Self.policy(closed: [.cover])
        var (snapshot, _, _) = try Self.load(Self.home, policy: closed)
        let reopened = Self.policy(closed: [])
        let home = try #require(try snapshot.receive(Self.stateChanged("cover.balcony", "closed"), typePrunePolicy: reopened))
        #expect(home.devices.contains { $0.id == "dev_cover" })
        #expect(snapshot.takeTypePruneReport()?.isEmpty == true, "an empty report clears the host's set")
    }

    @Test("A closed sensor type keeps the leak sensor while its alert is on and drops it once off")
    func leakSensorFollowsItsAlert() throws {
        let kept = Self.policy(closed: [.sensor], signals: [.leak])
        var (snapshot, home, report) = try Self.load(Self.home, policy: kept)
        #expect(!home.devices.contains { $0.id == "dev_leak" })
        #expect(report?.safetyDevices.map(\.id) == ["dev_leak"])
        #expect(report?.hiddenDeviceIds.isEmpty == true)
        // A retained sensor's change is consumed: it still re-synthesizes for alert evaluation.
        _ = try #require(try snapshot.receive(Self.stateChanged("binary_sensor.kitchen_leak", "on", ["device_class": .string("moisture")]), typePrunePolicy: kept))
        let alarming = try #require(snapshot.takeTypePruneReport()?.safetyDevices.first)
        guard case .sensor(let spec) = alarming.kind else { Issue.record("expected a sensor"); return }
        #expect(spec.observations.contains { $0.kind == .leak && $0.alarming })

        let (_, _, dropped) = try Self.load(Self.home, policy: Self.policy(closed: [.sensor]))
        #expect(dropped?.safetyDevices.isEmpty == true)
        #expect(dropped?.hiddenDeviceIds == ["dev_leak"])
    }

    @Test("A gas alarm row on a valve card keeps the valve while the gas alert is on")
    func auxiliaryAlarmRowKeepsTheCard() throws {
        let (_, home, report) = try Self.load(Self.home, policy: Self.policy(closed: [.valve], signals: [.gas]))
        #expect(!home.devices.contains { $0.id == "dev_valve" })
        #expect(report?.safetyDevices.map(\.id) == ["dev_valve"])
        let (_, _, dropped) = try Self.load(Self.home, policy: Self.policy(closed: [.valve], signals: [.leak]))
        #expect(dropped?.hiddenDeviceIds == ["dev_valve"])
    }

    @Test("A starred card of a closed type is kept only while the offline alert is on")
    func starredOfflineKeepsTheCard() throws {
        let kept = Self.policy(closed: [.cover], signals: [.starredOffline], starred: ["dev_cover"])
        #expect(try Self.load(Self.home, policy: kept).2?.safetyDevices.map(\.id) == ["dev_cover"])
        let notStarred = Self.policy(closed: [.cover], signals: [.starredOffline])
        #expect(try Self.load(Self.home, policy: notStarred).2?.hiddenDeviceIds == ["dev_cover"])
    }
}

/// The provider reads the host's box for every frame, sends the report before the snapshot it
/// belongs to, and publishes nothing for a frame that only a closed type would have consumed.
struct HATypePruneProviderTests {
    @Test("The report precedes its snapshot, and a closed cover's frame publishes nothing", .timeLimit(.minutes(1)))
    func providerSkipsUnconsumedFrames() async throws {
        let socket = FixtureSocket(root: HATypePruningTests.home)
        let box = HATypePrunePolicyBox(policy: HATypePruningTests.policy(closed: [.cover]))
        let provider = HAWebSocketProvider(
            baseURLString: "http://192.0.2.10:8123", token: "t",
            rediscover: { _ in [] }, allowsToken: { _ in true },
            typePrunePolicyLoader: { box.get() }
        )
        await provider.setTestSeams(connectOverride: nil, reconnectSleep: { _ in await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }, webSocketFactory: { _ in socket })
        let log = PruneEventLog()
        let collecting = Task { for await event in provider.events() { await log.append(event) } }

        await log.waitForSnapshots(1)
        await socket.push(#"{"type":"event","event":{"event_type":"state_changed","data":{"new_state":{"entity_id":"cover.balcony","state":"closed","attributes":{}}}}}"#)
        await socket.push(#"{"type":"event","event":{"event_type":"state_changed","data":{"new_state":{"entity_id":"light.ceiling","state":"off","attributes":{}}}}}"#)
        await log.waitForSnapshots(2)

        let kinds = await log.kinds
        #expect(kinds == ["report", "snapshot", "snapshot"], "the cover frame neither synthesized nor published")
        #expect(await log.reports.first?.hiddenDeviceIds == ["dev_cover"])
        #expect(await log.lastSnapshot?.devices.contains { $0.id == "dev_cover" } == false)

        await provider.shutdown()
        await collecting.value
    }
}

private actor PruneEventLog {
    private(set) var kinds: [String] = []
    private(set) var reports: [MiotTypePruneReport] = []
    private(set) var lastSnapshot: SynthesizedHome?
    private var snapshotCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ event: HomeProviderEvent) {
        switch event {
        case .haTypePruneChanged(let report): kinds.append("report"); reports.append(report)
        case .snapshotUpdated(let home): kinds.append("snapshot"); lastSnapshot = home; snapshotCount += 1
        default: return
        }
        let ready = waiters.filter { $0.0 <= snapshotCount }
        waiters.removeAll { $0.0 <= snapshotCount }
        for waiter in ready { waiter.1.resume() }
    }

    func waitForSnapshots(_ count: Int) async {
        guard snapshotCount < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// Answers the four startup requests from a fixture and then delivers pushed frames in order.
private actor FixtureSocket: HAWebSocketConnection {
    private let results: [Int: String]
    private var phase = 0
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var isCancelled = false

    init(root: [String: JSONValue]) {
        let encode = { (value: JSONValue?) in String(decoding: (try? JSONEncoder().encode(value ?? .array([]))) ?? Data("[]".utf8), as: UTF8.self) }
        results = [1: encode(root["areas"]), 2: encode(root["devices"]), 3: encode(root["entities"]), 4: encode(root["states"]), 5: "null"]
    }

    nonisolated func resume() {}

    func send(_ text: String) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let result = results[id] else { return }
        push(#"{"id":\#(id),"type":"result","success":true,"result":\#(result)}"#)
    }

    func push(_ text: String) {
        let data = Data(text.utf8)
        if let waiter { self.waiter = nil; waiter.resume(returning: data) } else { pending.append(data) }
    }

    func receive() async throws -> Data {
        guard !isCancelled else { throw CancellationError() }
        phase += 1
        if phase == 1 { return Data(#"{"type":"auth_required"}"#.utf8) }
        if phase == 2 { return Data(#"{"type":"auth_ok"}"#.utf8) }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    nonisolated func cancel() { Task { await self.close() } }

    private func close() {
        isCancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
