import Foundation

// Debounced wake/unlock/network-restore resume coordination and lifecycle teardown.
extension HomeStore {
    /// Schedules a debounced background refresh after wake, unlock, session activation, or
    /// network restoration. Passive catch-up only: foreground user actions never wait on this.
    public func scheduleDebouncedResume(reason: ResumeReason) {
        guard !isResumeShutdown else { return }
        if reason == .systemWake, homeBackend != .demo, isIdentityUncertain,
           pollingContext.systemActive, !isScreenLocked {
            let now = resumeScheduler.now()
            if lastWakeIdentityReadAt.map({ $0.duration(to: now) >= .seconds(60) }) ?? true {
                lastWakeIdentityReadAt = now
                rereadIdentityOnWake()
            }
        }
        guard let coordinator = ensureResumeCoordinator() else { return }
        enqueueResumeSync {
            await coordinator.notify(reason)
        }
    }

    /// Updates network reachability for debounced resume gating and Local Network classification.
    public func setNetworkSatisfiedForResume(_ satisfied: Bool) {
        knownNetworkSatisfied = satisfied
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
            await state.pendingProviderShutdown?.value
            await state.provider.shutdown()
            await state.lgClient?.shutdown()
        }
    }

    /// Async counterpart to `stop()`, awaiting coordinator, provider, and LG client teardown.
    public func shutdown() async {
        let state = cancelResumeAndStoreTasks()
        await state.coordinator?.shutdown()
        await state.pendingProviderShutdown?.value
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

    private func canContinueDebouncedResumeRefresh(
        expectedProviderGeneration: UInt64,
        expectedProvider: any HomeProvider
    ) -> Bool {
        guard !isResumeShutdown,
              homeBackend != .demo,
              !shouldSuppressBackgroundNetworkWork,
              !isScreenLocked,
              pollingContext.systemActive,
              isNetworkSatisfiedForResume,
              providerGeneration == expectedProviderGeneration else {
            return false
        }
        if type(of: provider) is AnyObject.Type || type(of: expectedProvider) is AnyObject.Type {
            return (provider as AnyObject) === (expectedProvider as AnyObject)
        }
        return true
    }

    private func performDebouncedResumeRefresh(reasons: Set<ResumeReason>) async {
        guard !isResumeShutdown,
              !isPerformingResumeRefresh,
              homeBackend != .demo,
              !isScreenLocked,
              pollingContext.systemActive,
              isNetworkSatisfiedForResume else {
            return
        }
        if let wakeIdentityProviderGeneration {
            self.wakeIdentityProviderGeneration = nil
            if !usesInjectedProvider, !shouldSuppressBackgroundNetworkWork {
                if wakeIdentityProviderGeneration == providerGeneration {
                    rebuildLiveProvider(migrateLegacyMiEnvelope: false)
                }
                if lgWebOSClient == nil {
                    startLGWebOSIfNeeded(startImmediately: false)
                }
            }
        }
        guard !shouldSuppressBackgroundNetworkWork else { return }
        isPerformingResumeRefresh = true
        defer { isPerformingResumeRefresh = false }
        let expectedProviderGeneration = providerGeneration
        let targetProvider = provider
        if let hook = onDebouncedResumeHook {
            await hook(reasons)
            guard canContinueDebouncedResumeRefresh(
                expectedProviderGeneration: expectedProviderGeneration,
                expectedProvider: targetProvider
            ) else {
                return
            }
        }
        await targetProvider.refreshNow()
        guard canContinueDebouncedResumeRefresh(
            expectedProviderGeneration: expectedProviderGeneration,
            expectedProvider: targetProvider
        ),
        lgConfig.isEnabled,
        lgConfig.hasConfiguredHost,
        let lgClient = lgWebOSClient else {
            return
        }
        await lgClient.start()
    }

    private func cancelResumeAndStoreTasks() -> (
        coordinator: DebouncedResumeCoordinator?,
        pendingProviderShutdown: Task<Void, Never>?,
        provider: any HomeProvider,
        lgClient: LGWebOSClient?
    ) {
        isResumeShutdown = true
        wakeIdentityProviderGeneration = nil
        let coordinator = debouncedResumeCoordinator
        debouncedResumeCoordinator = nil
        resumeSyncTask?.cancel()
        resumeSyncTask = nil

        eventTask?.cancel()
        eventTask = nil
        pollingContextSync?.cancel()
        pollingContextSync = nil
        activeDualProvider = nil
        activeHAProvider = nil
        activeHAConfig = nil
        activeMiAccountsProvider = nil
        let pendingProviderShutdown = providerShutdownTask
        providerShutdownTask = nil
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        for flight in activeSliderWrites.values { flight.task.cancel() }
        activeSliderWrites.removeAll()
        debouncedWrites.removeAll()
        undoTimerTask?.cancel()
        undoTimerTask = nil
        miSessionExpiryTimerTask?.cancel()
        miSessionExpiryTimerTask = nil
        raycastExportTask?.cancel()
        raycastExportTask = nil
        proactiveRefreshTask?.cancel()
        proactiveRefreshTask = nil
        assistantResetTask?.cancel()
        assistantResetTask = nil
        for task in scheduledTasks.values {
            task.cancel()
        }
        scheduledTasks.removeAll()
        scheduledTaskTokens.removeAll()

        readBackTickets.reset()
        releaseReadBackEcho()
        clearOptimisticLocks()

        let currentProvider = provider
        let currentLG = lgWebOSClient
        lgWebOSClient = nil
        return (coordinator, pendingProviderShutdown, currentProvider, currentLG)
    }
}
