import Observation

/// Waits for changes to the observable properties read by `matches`.
/// Set a test time limit to cancel a transition that never arrives.
@MainActor
public func awaitState(_ matches: () -> Bool) async throws {
    while true {
        try Task.checkCancellation()
        let (changes, change) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let ready = withObservationTracking {
            matches()
        } onChange: {
            change.yield(())
            change.finish()
        }
        if ready {
            change.finish()
            return
        }
        var iterator = changes.makeAsyncIterator()
        _ = await iterator.next()
        change.finish()
    }
}
