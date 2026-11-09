import Foundation
import Testing
@testable import MijiaCore

extension HomeStore {
    /// Extends the optimistic lock a cover command armed. It never creates one, so a test that
    /// asserts the card kept its commanded position cannot pass on a lock the test itself added.
    /// The lock runs on real time: a loaded runner can let its eight seconds expire mid-test, and
    /// the next provider snapshot then replaces the commanded row with the device's parked one.
    func extendCoverLock(_ deviceId: String) throws {
        let existing = try #require(
            optimisticLockUntil[deviceId],
            "the command must have armed the optimistic lock before the test extends it"
        )
        optimisticLockUntil[deviceId] = max(existing, ContinuousClock.now.advanced(by: .seconds(600)))
    }

    /// Waits for the provider snapshot a cover command produces. `MockHomeProvider` echoes a
    /// snapshot while the send is in flight, and it is applied after the command is recorded, so
    /// waiting for it keeps a later write from being judged against the older report.
    func waitForCoverSnapshot(after generation: UInt64) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while snapshotGeneration <= generation, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for the provider snapshot a cover command produces, keeps its lock from expiring, and
    /// puts back the travel origin the command wrote when a merge cleared it.
    ///
    /// A merge that runs while the command's read-back ticket is in flight replaces the row with
    /// the parked report and drops the origin; without the origin, the echo that is still pending
    /// would then take the row over. Restoring the origin before the wait makes that merge hold,
    /// and waiting for the echo before the next command keeps the takeover rule, not echo timing,
    /// in charge. `origin` is the position the row held before the command.
    func settleCoverCommand(_ deviceId: String, origin: Int?, after generation: UInt64) async throws {
        try extendCoverLock(deviceId)
        if coverCommandOrigins[deviceId] == nil, let origin {
            coverCommandOrigins[deviceId] = origin
        }
        await waitForCoverSnapshot(after: generation)
    }
}
