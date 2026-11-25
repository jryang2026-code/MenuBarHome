import Foundation
import Testing
@testable import MijiaCore

struct HASubscribeEntitiesTests {
    static func frames() throws -> [[String: JSONValue]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/ha_subscribe_entities.json")
        return try JSONDecoder().decode([[String: JSONValue]].self, from: Data(contentsOf: url))
    }

    @Test("Compressed snapshots and diffs preserve state, attribute removal, context, and timestamps")
    func appliesEntityDiffs() throws {
        let frames = try Self.frames()
        var snapshot = HAHomeSnapshot()
        #expect(try !snapshot.ingestCompressedStates(frames[0]["event"], typePrunePolicy: .unpruned))
        let initial = try #require(snapshot.states["light.desk"])
        #expect(initial.context == ["id": .string("01J00000000000000000000001"), "parent_id": .null, "user_id": .null])
        #expect(initial.lastChanged == Date(timeIntervalSince1970: 1730000000.125))
        #expect(initial.lastUpdated == initial.lastChanged)
        #expect(snapshot.synthesizeCurrent() == nil)

        for id in 1...3 {
            _ = try snapshot.receive(["id": .number(Double(id)), "type": .string("result"),
                                      "success": .bool(true), "result": .array([])])
        }
        #expect(snapshot.synthesizeCurrent()?.devices.map(\.id) == ["light.desk"])
        #expect(try snapshot.ingestCompressedStates(frames[1]["event"], typePrunePolicy: .unpruned))
        let changed = try #require(snapshot.states["light.desk"])
        #expect(changed.state == "on")
        #expect(changed.attributes == ["friendly_name": .string("Desk"), "brightness": .number(128)])
        #expect(changed.lastChanged == Date(timeIntervalSince1970: 1730000001.25))
        #expect(changed.lastUpdated == changed.lastChanged)
        #expect(changed.context == [
            "id": .string("01J00000000000000000000002"), "parent_id": .string("parent"), "user_id": .string("user")
        ])

        #expect(try snapshot.ingestCompressedStates(frames[2]["event"], typePrunePolicy: .unpruned))
        let updated = try #require(snapshot.states["light.desk"])
        #expect(updated.attributes["brightness"] == .number(192))
        #expect(updated.lastChanged == changed.lastChanged)
        #expect(updated.lastUpdated == Date(timeIntervalSince1970: 1730000002.5))
        #expect(updated.context == [
            "id": .string("01J00000000000000000000003"), "parent_id": .string("parent"), "user_id": .string("user")
        ])

        #expect(try snapshot.ingestCompressedStates(frames[3]["event"], typePrunePolicy: .unpruned))
        #expect(snapshot.states.isEmpty)
        #expect(snapshot.synthesizeCurrent()?.devices.isEmpty == true)
        #expect(try snapshot.ingestCompressedStates(frames[4]["event"], typePrunePolicy: .unpruned))
        let added = try #require(snapshot.states["light.hall"])
        #expect(added.lastChanged == Date(timeIntervalSince1970: 1730000003.125))
        #expect(added.lastUpdated == Date(timeIntervalSince1970: 1730000004.125))
        #expect(added.context["user_id"] == .string("user"))
    }

    @Test("An unknown subscribe_entities command falls back to the legacy snapshot and live events", .timeLimit(.minutes(1)))
    func fallsBackToStateChanged() async throws {
        let socket = FixtureSocket(root: ["states": .array([
            .object(["entity_id": .string("light.desk"), "state": .string("off")])
        ])])
        let provider = Self.makeProvider()
        await provider.setTestSeams(connectOverride: nil, webSocketFactory: { _ in socket })
        var events = provider.events().makeAsyncIterator()

        let initial = try await Self.nextSnapshot(&events)
        #expect(initial.devices.map(\.id) == ["light.desk"])
        #expect(initial.devices.first?.isActiveOn == false)
        await socket.push(#"{"type":"event","event":{"event_type":"state_changed","data":{"new_state":{"entity_id":"light.desk","state":"on"}}}}"#)
        let updated = try await Self.nextSnapshot(&events)
        #expect(updated.devices.first?.isActiveOn == true)

        await provider.refreshNow()
        let refreshed = try await Self.nextSnapshot(&events)
        #expect(refreshed.devices.first?.isActiveOn == false)
        let commands = await socket.commands
        #expect(commands.suffix(4).compactMap { $0["type"]?.stringValue } == [
            "subscribe_entities", "get_states", "subscribe_events", "get_states"
        ])
        #expect(commands.first { $0["type"]?.stringValue == "subscribe_events" }?["event_type"] == .string("state_changed"))
        await provider.shutdown()
    }

    @Test("Reconnect re-subscribes and replaces the previous connection's entity baseline", .timeLimit(.minutes(1)))
    func resubscribesAfterDisconnect() async throws {
        let frames = try Self.frames()
        let first = FixtureSocket(compressedSnapshot: frames[0])
        let second = FixtureSocket(compressedSnapshot: frames[4])
        let attempts = ProviderTestCounter()
        let provider = Self.makeProvider()
        await provider.setTestSeams(
            connectOverride: nil, reconnectSleep: { _ in },
            webSocketFactory: { _ in attempts.increment() == 1 ? first : second }
        )
        var events = provider.events().makeAsyncIterator()

        let initial = try await Self.nextSnapshot(&events)
        #expect(initial.devices.map(\.id) == ["light.desk"])
        try await first.push(frames[1])
        let updated = try await Self.nextSnapshot(&events)
        #expect(updated.devices.first?.isActiveOn == true)
        await first.disconnect()

        let reconnected = try await Self.nextSnapshot(&events)
        #expect(reconnected.devices.map(\.id) == ["light.hall"])
        #expect(attempts.value == 2)
        for socket in [first, second] {
            let commands = await socket.commands.compactMap { $0["type"]?.stringValue }
            #expect(commands == [
                "config/area_registry/list", "config/device_registry/list", "config/entity_registry/list", "subscribe_entities"
            ])
        }
        await provider.shutdown()
    }

    @Test("Compressed updates with capturedEpoch prevent stale get_states refreshes from rolling back state")
    func compressedUpdatesPreventStaleGetStatesRollback() throws {
        let frames = try Self.frames()
        var snapshot = HAHomeSnapshot()
        let t0 = ContinuousClock.now, tPoll = t0.advanced(by: .seconds(1)), tEvent = t0.advanced(by: .seconds(2))
        for id in 1...3 {
            _ = try snapshot.receive(["id": .number(Double(id)), "type": .string("result"), "success": .bool(true), "result": .array([])])
        }
        #expect(try snapshot.ingestCompressedStates(frames[0]["event"], typePrunePolicy: .unpruned, capturedEpoch: t0))
        #expect(try snapshot.ingestCompressedStates(frames[1]["event"], typePrunePolicy: .unpruned, capturedEpoch: tEvent))
        #expect(snapshot.states["light.desk"]?.state == "on")

        let staleRefresh: [String: JSONValue] = [
            "id": .number(99), "type": .string("result"), "success": .bool(true),
            "result": .array([.object(["entity_id": .string("light.desk"), "state": .string("off"), "attributes": .object(["friendly_name": .string("Desk")])])]),
        ]
        let refreshedHome = try #require(try snapshot.receive(staleRefresh, isRefreshStatesResult: true, pollCapturedEpoch: tPoll))
        #expect(snapshot.states["light.desk"]?.state == "on" && refreshedHome.devices.first?.isActiveOn == true)

        #expect(try snapshot.ingestCompressedStates(frames[3]["event"], typePrunePolicy: .unpruned, capturedEpoch: t0.advanced(by: .seconds(3))))
        let afterRemove = try #require(try snapshot.receive(staleRefresh, isRefreshStatesResult: true, pollCapturedEpoch: tPoll))
        #expect(snapshot.states["light.desk"] == nil && afterRemove.devices.isEmpty)
    }

    @Test("Empty initial subscribe_entities {} frame completes initialization without error", .timeLimit(.minutes(1)))
    func acceptsEmptyInitialCompressedFrame() async throws {
        var snapshot = HAHomeSnapshot()
        for id in 1...3 {
            _ = try snapshot.receive(["id": .number(Double(id)), "type": .string("result"), "success": .bool(true), "result": .array([])])
        }
        #expect(try snapshot.ingestCompressedStates(.object([:]), typePrunePolicy: .unpruned, capturedEpoch: .now))
        #expect(snapshot.states.isEmpty && snapshot.synthesizeCurrent()?.devices.isEmpty == true)

        var malformed = HAHomeSnapshot()
        #expect(throws: HAHomeSnapshot.ReadError.invalidResponse) {
            _ = try malformed.ingestCompressedStates(.object(["a": .string("bad")]), typePrunePolicy: .unpruned)
        }

        let socket = FixtureSocket(compressedSnapshot: ["id": .number(4), "type": .string("event"), "event": .object([:])])
        let attempts = ProviderTestCounter()
        let provider = Self.makeProvider()
        await provider.setTestSeams(connectOverride: nil, reconnectSleep: { _ in }, webSocketFactory: { _ in _ = attempts.increment(); return socket })
        var events = provider.events().makeAsyncIterator()
        #expect(try await Self.nextSnapshot(&events).devices.isEmpty && attempts.value == 1)
        await provider.shutdown()
    }

    @Test("removeLiveState ignores unknown entities and full get_states prunes expired deletion tombstones")
    func boundsStateCaptureEpochsAndPrunesExpiredTombstones() throws {
        let frames = try Self.frames()
        var snapshot = HAHomeSnapshot()
        let t0 = ContinuousClock.now
        let tStalePoll = t0.advanced(by: .seconds(1))
        let tRemove = t0.advanced(by: .seconds(2))
        let tFreshPoll = t0.advanced(by: .seconds(3))

        for id in 1...3 {
            _ = try snapshot.receive([
                "id": .number(Double(id)), "type": .string("result"),
                "success": .bool(true), "result": .array([]),
            ])
        }
        #expect(try snapshot.ingestCompressedStates(frames[0]["event"], typePrunePolicy: .unpruned, capturedEpoch: t0))
        #expect(snapshot.stateCaptureEpochs.keys.sorted() == ["light.desk"])

        // Removing non-existent entity IDs must not grow stateCaptureEpochs.
        _ = try snapshot.ingestCompressedStates(
            .object(["r": .array([.string("light.nonexistent_1"), .string("switch.nonexistent_2")])]),
            typePrunePolicy: .unpruned,
            capturedEpoch: tRemove
        )
        _ = snapshot.ingestStateChangedEvent(
            [
                "type": .string("event"),
                "event": .object([
                    "event_type": .string("state_changed"),
                    "data": .object([
                        "entity_id": .string("light.nonexistent_3"),
                        "new_state": .null,
                    ]),
                ]),
            ],
            typePrunePolicy: .unpruned,
            capturedEpoch: tRemove
        )
        #expect(snapshot.stateCaptureEpochs.keys.sorted() == ["light.desk"])

        // Removing an existing entity records a tombstone that blocks stale get_states resurrection.
        #expect(try snapshot.ingestCompressedStates(frames[3]["event"], typePrunePolicy: .unpruned, capturedEpoch: tRemove))
        #expect(snapshot.states["light.desk"] == nil)
        #expect(snapshot.stateCaptureEpochs["light.desk"] == tRemove)

        let staleRefresh: [String: JSONValue] = [
            "id": .number(99), "type": .string("result"), "success": .bool(true),
            "result": .array([
                .object(["entity_id": .string("light.desk"), "state": .string("on"), "attributes": .object([:])]),
            ]),
        ]
        _ = try snapshot.receive(staleRefresh, isRefreshStatesResult: true, pollCapturedEpoch: tStalePoll)
        #expect(snapshot.states["light.desk"] == nil)
        #expect(snapshot.stateCaptureEpochs["light.desk"] == tRemove)

        // A newer full get_states omitting light.desk prunes the expired tombstone.
        let newerRefresh: [String: JSONValue] = [
            "id": .number(100), "type": .string("result"), "success": .bool(true),
            "result": .array([
                .object(["entity_id": .string("light.hall"), "state": .string("off"), "attributes": .object([:])]),
            ]),
        ]
        _ = try snapshot.receive(newerRefresh, isRefreshStatesResult: true, pollCapturedEpoch: tFreshPoll)
        #expect(snapshot.states["light.desk"] == nil)
        #expect(snapshot.stateCaptureEpochs["light.desk"] == nil)
        #expect(snapshot.stateCaptureEpochs == ["light.hall": tFreshPoll])
    }

    private static func makeProvider() -> HAWebSocketProvider {
        HAWebSocketProvider(
            baseURLString: "http://192.0.2.10:8123", token: "test-token",
            rediscover: { _ in [] }, allowsToken: { _ in true }
        )
    }

    private static func nextSnapshot(_ events: inout AsyncStream<HomeProviderEvent>.Iterator) async throws -> SynthesizedHome {
        while let event = await events.next() {
            if case .snapshotUpdated(let home) = event { return home }
        }
        throw CancellationError()
    }
}
