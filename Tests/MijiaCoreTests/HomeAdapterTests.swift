import Testing
@testable import MijiaCore

struct HomeAdapterTests {
    private struct FakeAdapter: HomeAdapter {
        let id = HomeAdapterID(backend: .demo, scope: "demo")
        let capabilities: Set<HomeProviderCapability> = [.readSnapshot, .control]
        let home = SynthesizedHome(rooms: [], devices: [], environmentReadings: [], scenes: [])

        func snapshot() async -> SynthesizedHome? { home }

        func events() -> AsyncStream<HomeAdapterEvent> {
            AsyncStream { continuation in
                continuation.yield(.snapshotUpdated(home))
                continuation.finish()
            }
        }

        func execute(command: DeviceCommand) async -> AdapterWriteResult { .acknowledged }
    }

    @Test func fakeAdapterCanBeUsedThroughSPI() async {
        let adapter: any HomeAdapter = FakeAdapter()
        #expect(await adapter.id == HomeAdapterID(backend: .demo, scope: "demo"))
        #expect(adapter.capabilities.contains(.readSnapshot))
        let snapshot = await adapter.snapshot()
        var events = adapter.events().makeAsyncIterator()
        guard case .snapshotUpdated(let home) = await events.next() else {
            Issue.record("Expected a snapshot event")
            return
        }
        #expect(home == snapshot)
        #expect(await events.next() == nil)
        #expect(await adapter.execute(command: .setSwitch(entityId: "switch.test", isOn: true)) == .acknowledged)
    }

    @Test func haAdapterClassifiesFailureAndLegacyExecutionPreservesTheError() async {
        let adapter = HAHomeAdapter(provider: HAWebSocketProvider(
            baseURLString: "http://192.0.2.10:8123", token: "test-token",
            allowsToken: { _ in false }
        ))
        let command = DeviceCommand.setSwitch(entityId: "switch.test", isOn: true)
        #expect(await adapter.execute(command: command) == .failed(.unreachable))
        #expect(await adapter.execute(command: .setMiotProperty(entityId: "miot:test:2", piid: 1, value: .bool(true))) == .failed(.unsupported))
        await #expect(throws: HomeProviderError.self) {
            try await (adapter as any HomeProvider).execute(command)
        }
        await adapter.shutdown()
    }
}
