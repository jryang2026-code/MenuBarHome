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
