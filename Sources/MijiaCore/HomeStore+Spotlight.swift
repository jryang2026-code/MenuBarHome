import Foundation

// MARK: - Spotlight Refresh (#575)

/// What the store tells the app's indexer to do (#575).
///
/// A plan replaces the index after a debounce; `clearNow` empties it immediately, because a sign-out
/// must not wait two seconds before the credentials behind those names are gone.
public enum SpotlightIndexUpdate: Equatable, Sendable {
    case plan([SpotlightIndexEntry])
    case clearNow
}

extension HomeStore {
    /// The entries the system Spotlight index should hold right now.
    ///
    /// Empty means "the index must be empty", and every reason for it is deliberate: the setting is
    /// off (privacy default), the home is the built-in demo one (fake devices must not sit in a
    /// system index), credentials could not be verified, or no snapshot has loaded yet. Returning an
    /// empty plan instead of `nil` keeps the app-side indexer on one code path.
    public func spotlightIndexEntries() -> [SpotlightIndexEntry] {
        guard spotlightIndexEnabled,
              !isIdentityUncertain,
              homeBackend != .demo,
              hasReceivedInitialSnapshot else {
            return []
        }
        return SpotlightIndexPlan.entries(
            devices: devices,
            rooms: rooms,
            scenes: visibleScenes,
            hiddenIds: hiddenDeviceIds,
            homeDomain: SpotlightIndexPlan.domain(for: homeBackend),
            backend: { [self] deviceId in deviceBackend(for: deviceId) }
        )
    }

    /// Hands the current plan to the app's indexer. The store owns the privacy gate, so a disabled
    /// setting sends an empty list and the indexer clears the system index instead of reading state.
    func scheduleSpotlightIndexUpdate() {
        guard let onSpotlightIndexUpdate else { return }
        // Before the first snapshot there is nothing to mirror yet; keeping the previous index
        // avoids wiping and rebuilding it on every launch.
        guard hasReceivedInitialSnapshot || !spotlightIndexEnabled else { return }
        onSpotlightIndexUpdate(.plan(spotlightIndexEntries()))
    }

    /// Empties the system index even though `devices` may still hold a snapshot for another
    /// run-loop turn after sign-out (#575).
    public func clearSpotlightIndex() {
        if let onSpotlightIndexUpdate { onSpotlightIndexUpdate(.clearNow) }
    }
}
