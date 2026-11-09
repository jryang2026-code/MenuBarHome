import Foundation
import Testing
@testable import MijiaCore

/// A cover tap records where the motor started before the command is sent, so a stale poll at that
/// position cannot pull the card back. A tap that never reaches the device must not leave that
/// origin behind, or the next genuine report at the same position is rejected (#298 follow-up).
struct CoverCommandOriginTests {
    private static let curtain = SmartDevice(
        id: "curtain", name: "客厅窗帘", roomId: "ke_ting", roomName: "客厅",
        model: "lumi.curtain.hagl04", isOnline: true,
        kind: .cover(CoverSpec(
            entityId: "cover.curtain",
            subtype: .curtain,
            positionPercent: 0,
            positionWritable: true,
            openDescription: "Open",
            closeDescription: "Close",
            pauseDescription: "Pause"
        ))
    )

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.curtain]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.coverorigin.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was never satisfied")
    }

    @Test("A failed cover send leaves no travel origin behind")
    @MainActor
    func failedSendDropsOrigin() async throws {
        let (store, mock) = try await makeStore()
        await mock.setFailingTargets(["cover.curtain"])

        let device = try #require(store.devices.first)
        let succeeded = await store.togglePrimary(device)?.value
        #expect(succeeded == false)
        #expect(store.coverCommandOrigins["curtain"] == nil)
        #expect(store.optimisticLockUntil["curtain"] == nil, "a failed send releases its early lock")
        let row = try #require(store.devices.first)
        if case .cover(let spec) = row.kind {
            #expect(spec.positionPercent == 0, "the row keeps the closed position")
        } else {
            Issue.record("expected the curtain row, got \(row.kind)")
        }
    }

    @Test("A snapshot while the command is in flight cannot pull the card back")
    @MainActor
    func inFlightSnapshotCannotDropCommandedTravel() async throws {
        let (store, mock) = try await makeStore()
        await mock.holdNextExecute()

        let card = try #require(store.devices.first)
        let beforeCommand = store.snapshotGeneration
        let command = try #require(store.togglePrimary(card))
        try await waitUntil { await mock.executeStarted > 0 }

        // The provider still reports the parked position while the write is in flight.
        await mock.updateSnapshot(SynthesizedHome(devices: [Self.curtain]))
        try await waitUntil { store.snapshotGeneration > beforeCommand }

        let during = try #require(store.devices.first)
        guard case .cover(let optimistic) = during.kind else {
            Issue.record("expected the curtain row, got \(during.kind)")
            return
        }
        #expect(optimistic.positionPercent == 100, "the card shows the commanded travel before the send returns")
        #expect(optimistic.motion == .opening, "the in-flight snapshot does not stop the commanded travel")

        let beforeRelease = store.snapshotGeneration
        await mock.releaseExecute()
        #expect(await command.value == true)
        await store.waitForCoverSnapshot(after: beforeRelease)

        // A late poll still reports the pre-command position. The tap's origin must keep the
        // commanded travel on the card instead of reading the stale stop as a takeover.
        let beforeStale = store.snapshotGeneration
        await mock.updateSnapshot(SynthesizedHome(devices: [Self.curtain]))
        try await waitUntil { store.snapshotGeneration > beforeStale }

        let row = try #require(store.devices.first)
        guard case .cover(let shown) = row.kind else {
            Issue.record("expected the curtain row, got \(row.kind)")
            return
        }
        #expect(shown.positionPercent == 100, "the card keeps the commanded open position")
        #expect(shown.motion == .opening, "the card keeps showing the commanded travel")
    }

    @Test("A tap that cannot claim leaves the in-flight tap's origin alone")
    @MainActor
    func claimFailureKeepsTheInFlightOrigin() async throws {
        let (store, mock) = try await makeStore()
        await mock.holdNextExecute()

        let device = try #require(store.devices.first)
        let first = try #require(store.togglePrimary(device))
        try await waitUntil { await mock.executeStarted > 0 }
        #expect(store.coverCommandOrigins["curtain"] == 0)

        let second = store.togglePrimary(device)
        #expect(second == nil, "the first tap still owns the read-back")
        #expect(store.coverCommandOrigins["curtain"] == 0, "the refused tap must not drop the origin")

        await mock.releaseExecute()
        _ = await first.value
    }
}
