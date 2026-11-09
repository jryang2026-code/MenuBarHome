import Foundation
import Testing
@testable import MijiaCore

/// The provider seam: the store stops whatever provider it replaces through `HomeProvider`
/// itself, and multi-account ids are read through `MiAccountScope`.
struct ProviderSeamTests {
    @Test("Account scope names, splits and owns ids")
    func accountScope() {
        let scoped = MiAccountScope.id("home-1", account: "cn:42")
        #expect(scoped == "cn:42/home-1")
        #expect(MiAccountScope.owner(of: scoped) == "cn:42")
        #expect(MiAccountScope.localId(of: scoped) == "home-1")
        #expect(MiAccountScope.isOwned(scoped, by: "cn:42"))
        #expect(!MiAccountScope.isOwned(scoped, by: "cn:4"))
        #expect(MiAccountScope.owner(of: "home-1") == nil)
        #expect(MiAccountScope.localId(of: "home-1") == "home-1")
    }

    @Test("The composite stops both sources through the protocol")
    @MainActor
    func compositeShutsDownChildren() async throws {
        let ha = StoppableProvider()
        let mi = StoppableProvider()
        let composite = HomeStore.makeComposite(
            homeAssistant: ha,
            xiaomiCloud: mi,
            defaults: UserDefaults(suiteName: "test.seam.\(UUID().uuidString)")!
        )
        let provider: any HomeProvider = composite
        await provider.shutdown()
        // The composite shuts each source down from a detached task. Wait on each source's own
        // signal instead of yielding a fixed number of times, which a loaded runner can outrun.
        await ha.waitUntilStopped()
        await mi.waitUntilStopped()
        #expect(await ha.stopped)
        #expect(await mi.stopped)
    }
}

private actor StoppableProvider: HomeProvider {
    private(set) var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { _ in }
    }

    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}
    func shutdown() async {
        stopped = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until `shutdown` ran; returns at once when it already did.
    func waitUntilStopped() async {
        guard !stopped else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
}
