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
    /// `snapshotGeneration` is the counter. The wait does not guess with `Task.yield`.
    func waitForCoverSnapshot(after generation: UInt64) async {
        await waitUntil(timeout: .seconds(30)) { snapshotGeneration > generation }
    }

    /// Extends the lock a cover command armed and waits for the provider echo it produces, so the
    /// next assertion or command runs against the settled row instead of racing the echo.
    func settleCoverCommand(_ deviceId: String, after generation: UInt64) async throws {
        try extendCoverLock(deviceId)
        await waitForCoverSnapshot(after: generation)
    }
}
