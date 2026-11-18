import Foundation

extension HomeStore {
    private static let lastUpdateCheckTimestampKey = "last_update_check_timestamp"

    private var lastUpdateCheckDate: Date? {
        get {
            guard userDefaults.object(forKey: Self.lastUpdateCheckTimestampKey) != nil else { return nil }
            let interval = userDefaults.double(forKey: Self.lastUpdateCheckTimestampKey)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            if let newValue {
                userDefaults.set(newValue.timeIntervalSince1970, forKey: Self.lastUpdateCheckTimestampKey)
            } else {
                userDefaults.removeObject(forKey: Self.lastUpdateCheckTimestampKey)
            }
        }
    }

    public func checkForUpdatesIfNeeded(now: Date = Date()) async {
        guard automaticallyChecksForUpdates else { return }
        switch updateState {
        case .idle, .upToDate:
            break
        default:
            return
        }
        if let lastCheck = lastUpdateCheckDate,
           now.timeIntervalSince(lastCheck) < Self.automaticUpdateCheckInterval {
            return
        }
        await performUpdateCheck(userInitiated: false, now: now)
    }

    public func checkForUpdates(now: Date = Date()) async {
        await performUpdateCheck(userInitiated: true, now: now)
    }

    private func performUpdateCheck(userInitiated: Bool, now: Date) async {
        guard homeBackend != .demo else {
            if userInitiated {
                showToast(L10n.tr("演示模式不联网，请切换数据源后检查更新", "Demo mode is offline; switch the data source to check for updates"))
            }
            return
        }
        var previousStaged: VerifiedStagedApp?
        switch updateState {
        case .checking, .downloading, .verifying, .installing:
            return
        case .readyToRelaunch(let staged):
            if !userInitiated { return }
            previousStaged = staged
        case .idle, .upToDate, .available, .failed:
            break
        }

        updateState = .checking
        do {
            let release = try await updater.checkLatestRelease()
            guard case .checking = updateState else { return }
            lastUpdateCheckDate = now
            if let release {
                if let previousStaged,
                   Self.matchesStagedRelease(release, staged: previousStaged),
                   FileManager.default.fileExists(atPath: previousStaged.stagingRootURL.path) {
                    updateState = .readyToRelaunch(previousStaged)
                } else {
                    if let previousStaged {
                        updater.cleanupStagedApp(previousStaged)
                    }
                    updateState = .available(release)
                }
            } else {
                if let previousStaged {
                    updater.cleanupStagedApp(previousStaged)
                }
                updateState = .upToDate(checkedAt: now)
            }
        } catch is CancellationError {
            if case .checking = updateState {
                if let previousStaged,
                   FileManager.default.fileExists(atPath: previousStaged.stagingRootURL.path) {
                    updateState = .readyToRelaunch(previousStaged)
                } else {
                    updateState = .idle
                }
            }
        } catch {
            guard case .checking = updateState else { return }
            if let previousStaged,
               FileManager.default.fileExists(atPath: previousStaged.stagingRootURL.path) {
                updateState = .readyToRelaunch(previousStaged)
                if userInitiated {
                    showToast(error.localizedDescription)
                }
            } else if userInitiated {
                // The check itself failed; checking again is the only useful next step.
                updateState = .failed(
                    AppUpdateFailure(
                        release: nil,
                        message: error.localizedDescription,
                        recovery: .recheck
                    )
                )
            } else {
                updateState = .idle
            }
        }
    }

    private static func matchesStagedRelease(_ release: AppRelease, staged: VerifiedStagedApp) -> Bool {
        if let latest = AppVersion(release.version), let stagedVersion = AppVersion(staged.release.version) {
            return latest == stagedVersion
        }
        return release.version == staged.release.version
    }

    public func startUpdateInstallation() async {
        guard homeBackend != .demo else {
            showToast(L10n.tr("演示模式不联网，请切换数据源后下载更新", "Demo mode is offline; switch the data source to download updates"))
            return
        }
        let release: AppRelease
        switch updateState {
        case .available(let availableRelease):
            release = availableRelease
        case .failed(let failure):
            // A non-retryable failure would fail identically a second time; only re-checking or the
            // release page can change the outcome, so refuse to start instead of looping.
            guard let failedRelease = failure.release, failure.canRetryInstall else { return }
            release = failedRelease
        default:
            return
        }

        updateTask?.cancel()
        let attemptID = UUID()
        activeUpdateAttemptID = attemptID
        let initialTotal = release.packageAsset.flatMap { $0.sizeBytes > 0 ? $0.sizeBytes : nil }
        updateState = .downloading(release, progress: DownloadProgress(receivedBytes: 0, totalBytes: initialTotal))

        let currentUpdater = updater
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let staged = try await currentUpdater.stageUpdate(for: release) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeUpdateAttemptID == attemptID else { return }
                        if case .verifying = self.updateState, case .downloading = phase {
                            return
                        }
                        self.updateState = phase
                    }
                }
                guard self.activeUpdateAttemptID == attemptID else {
                    currentUpdater.cleanupStagedApp(staged)
                    return
                }
                self.activeUpdateAttemptID = nil
                if Task.isCancelled {
                    currentUpdater.cleanupStagedApp(staged)
                    self.updateState = .available(release)
                } else {
                    self.updateState = .readyToRelaunch(staged)
                }
            } catch is CancellationError {
                guard self.activeUpdateAttemptID == attemptID else { return }
                self.activeUpdateAttemptID = nil
                self.updateState = .available(release)
            } catch {
                guard self.activeUpdateAttemptID == attemptID else { return }
                self.activeUpdateAttemptID = nil
                if Task.isCancelled {
                    self.updateState = .available(release)
                } else {
                    self.updateState = .failed(
                        AppUpdateFailure(
                            release: release,
                            message: error.localizedDescription,
                            recovery: UpdateFailureClassifier.recovery(for: error)
                        )
                    )
                }
            }
        }
        updateTask = task
        await task.value
    }

    public func cancelUpdateInstallation() {
        // `.installing` has already handed the staging root to the detached swap script. Reporting
        // "cancelled" there would be false, and deleting the root would break the running swap.
        guard !isInstallingUpdate else { return }
        activeUpdateAttemptID = nil
        updateTask?.cancel()
        updateTask = nil
        if case .readyToRelaunch(let staged) = updateState {
            updater.cleanupStagedApp(staged)
        }
        if let release = updateState.associatedRelease {
            updateState = .available(release)
        }
    }

    public func confirmRelaunchForUpdate() {
        guard case .readyToRelaunch(let staged) = updateState else { return }
        updateState = .installing(staged.release)
        // Nothing is mirrored into `UserDefaults` any more, so there is no snapshot to take before the binary is
        // replaced; the plaintext migration is idempotent and gets one last chance to run (#16).
        KeychainHelper.migratePlaintextCredentialsToKeychain(defaults: userDefaults, vault: credentialVault ?? .shared)
        do {
            try updater.installStagedUpdateAndRelaunch(staged)
        } catch {
            updater.cleanupStagedApp(staged)
            updateState = .failed(
                AppUpdateFailure(
                    release: staged.release,
                    message: error.localizedDescription,
                    recovery: .retryInstall
                )
            )
            return
        }
        scheduleRelaunchWatchdog(for: staged)
        onTerminateForUpdate?()
    }

    /// Covers the case where the swap never terminates this process.
    ///
    /// The detached script waits at most 15 s for the app to exit, but on a busy system 150 polls
    /// or the bundle move can run past the nominal window. The watchdog therefore waits while the
    /// swap process is still alive before cleaning up staging and reporting that this process did
    /// not exit in time. `nil` freezes the watchdog for tests.
    private func scheduleRelaunchWatchdog(for staged: VerifiedStagedApp) {
        updateRelaunchWatchdogTask?.cancel()
        guard let interval = updateRelaunchWatchdogInterval else { return }
        updateRelaunchWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            while let self, !Task.isCancelled, self.isInstallingUpdate,
                  self.updater.isSwapProcessRunning(for: staged) {
                try? await Task.sleep(for: interval)
            }
            guard let self, !Task.isCancelled,
                  case .installing(let installingRelease) = self.updateState,
                  installingRelease == staged.release else {
                return
            }
            self.updater.cleanupStagedApp(staged)
            self.updateState = .failed(
                AppUpdateFailure(
                    release: staged.release,
                    message: L10n.tr(
                        "应用未能及时退出以完成替换，请重试或手动下载安装",
                        "The app did not exit in time to complete the update; retry or install manually"
                    ),
                    recovery: .retryInstall
                )
            )
        }
    }
}
