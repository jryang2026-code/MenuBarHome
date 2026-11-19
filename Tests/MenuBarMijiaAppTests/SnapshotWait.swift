import Testing
@testable import MijiaCore

extension HomeStore {
    /// Waits for the first mock snapshot. Returns as soon as it lands; the deadline only matters on a
    /// loaded machine, where the 4 s production default and fixed poll counts flaked (#349).
    func waitForTestSnapshot() async throws {
        try await waitForInitialSnapshot(timeout: .seconds(30))
    }
}

/// Polls `condition` until it is true or `timeout` passes. The deadline is the only bound.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(15),
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column,
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if await condition() { return }
    Issue.record(
        "condition was not met before \(timeout)",
        sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
}
