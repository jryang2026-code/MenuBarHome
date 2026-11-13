import Foundation

// Debounced wake/unlock/network-restore resume coordination and lifecycle teardown.
extension HomeStore {
    /// Schedules a debounced background refresh after wake, unlock, session activation, or
    /// network restoration. Passive catch-up only: foreground user actions never wait on this.
    public func scheduleDebouncedResume(reason: ResumeReason) {
        guard !isResumeShutdown else { return }
        guard let coordinator = ensureResumeCoordinator() else { return }
        enqueueResumeSync {
            await coordinator.notify(reason)
        }
    }

    /// Updates network reachability for debounced resume gating.
    public func setNetworkSatisfiedForResume(_ satisfied: Bool) {
        guard isNetworkSatisfiedForResume != satisfied else { return }
        isNetworkSatisfiedForResume = satisfied
        guard let coordinator = debouncedResumeCoordinator else { return }
        enqueueResumeSync {
            await coordinator.setNetworkSatisfied(satisfied)
        }
    }

    func syncResumeScreenLocked(_ locked: Bool) {
        guard let coordinator = debouncedResumeCoordinator else { return }
        enqueueResumeSync {
            await coordinator.setScreenLocked(locked)
        }
    }

    func syncResumeSystemActive(_ active: Bool) {
        guard let coordinator = debouncedResumeCoordinator else { return }
        enqueueResumeSync {
            await coordinator.setSystemActive(active)
        }
    }

    /// Stops active tasks, tears down the debounced resume coordinator, and shuts down the
    /// active provider and LG webOS client synchronously from `@MainActor`.
    public func stop() {
        let state = cancelResumeAndStoreTasks()
        Task {
            await state.coordinator?.shutdown()
            await state.provider.shutdown()
            await state.lgClient?.shutdown()
        }
    }

    /// Async counterpart to `stop()`, awaiting coordinator, provider, and LG client teardown.
    public func shutdown() async {
        let state = cancelResumeAndStoreTasks()
        await state.coordinator?.shutdown()
        await state.provider.shutdown()
        await state.lgClient?.shutdown()
    }

    /// Waits for any queued resume-state updates to reach the coordinator (deterministic test seam).
    func flushResumeSync() async {
        await resumeSyncTask?.value
    }

    private func ensureResumeCoordinator() -> DebouncedResumeCoordinator? {
        guard !isResumeShutdown else { return nil }
        if let existing = debouncedResumeCoordinator {
            return existing
        }
        let coordinator = DebouncedResumeCoordinator(
            debounceInterval: resumeDebounceInterval,
            maxDelay: resumeMaxDelay,
            scheduler: resumeScheduler,
            initiallyActive: pollingContext.systemActive,
            initiallyLocked: isScreenLocked,
            initiallyNetworkSatisfied: isNetworkSatisfiedForResume,
            onResume: { [weak self] reasons in
                await self?.performDebouncedResumeRefresh(reasons: reasons)
            }
        )
        debouncedResumeCoordinator = coordinator
        return coordinator
    }

    private func enqueueResumeSync(_ work: @escaping @Sendable () async -> Void) {
        let previous = resumeSyncTask
        resumeSyncTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    private func performDebouncedResumeRefresh(reasons: Set<ResumeReason>) async {
        guard !isResumeShutdown,
              homeBackend != .demo,
              !isScreenLocked,
              pollingContext.systemActive,
              isNetworkSatisfiedForResume else {
            return
        }
        if let hook = onDebouncedResumeHook {
            await hook(reasons)
        }
        await provider.refreshNow()
        if homeBackend != .demo,
           lgConfig.isEnabled,
           lgConfig.hasConfiguredHost,
           let lgClient = lgWebOSClient {
            await lgClient.start()
        }
    }

    private func cancelResumeAndStoreTasks() -> (
        coordinator: DebouncedResumeCoordinator?,
        provider: any HomeProvider,
        lgClient: LGWebOSClient?
    ) {
        isResumeShutdown = true
        let coordinator = debouncedResumeCoordinator
        debouncedResumeCoordinator = nil
        resumeSyncTask?.cancel()
        resumeSyncTask = nil

        eventTask?.cancel()
        eventTask = nil
        pollingContextSync?.cancel()
        pollingContextSync = nil
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        undoTimerTask?.cancel()
        undoTimerTask = nil
        miSessionExpiryTimerTask?.cancel()
        miSessionExpiryTimerTask = nil
        raycastExportTask?.cancel()
        raycastExportTask = nil
        proactiveRefreshTask?.cancel()
        proactiveRefreshTask = nil
        grokBallCelebrationTask?.cancel()
        grokBallCelebrationTask = nil
        assistantResetTask?.cancel()
        assistantResetTask = nil
        for task in scheduledTasks.values {
            task.cancel()
        }
        scheduledTasks.removeAll()
        scheduledTaskTokens.removeAll()

        clearOptimisticLocks()

        let currentProvider = provider
        let currentLG = lgWebOSClient
        lgWebOSClient = nil
        return (coordinator, currentProvider, currentLG)
    }
}
