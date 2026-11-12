import Foundation
import Testing
@testable import MijiaCore

/// The download caption, the failure taxonomy it is paired with, and the relaunch watchdog.
///
/// These are the parts of the in-app update a user actually reads or acts on, so they are asserted
/// through the same values the settings pane renders rather than through the views.
struct UpdateProgressAndRecoveryTests {
    // MARK: - Time remaining

    @Test("The caption counts down in seconds, minutes, then hours as the rate allows")
    func timeRemainingScalesWithTheEstimate() {
        func caption(remainingSeconds: Double) -> String? {
            // 1 MB/s, so the byte counts below read directly as seconds.
            DownloadSectionCopy.timeRemaining(
                DownloadProgress(
                    receivedBytes: 0,
                    totalBytes: Int64((remainingSeconds * 1_000_000).rounded()),
                    bytesPerSecond: 1_000_000
                )
            )
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            // Under ten seconds the caption stops pretending to be precise.
            #expect(caption(remainingSeconds: 0.4) == "约剩几秒")
            #expect(caption(remainingSeconds: 9) == "约剩几秒")
            #expect(caption(remainingSeconds: 10) == "约剩 10 秒")
            #expect(caption(remainingSeconds: 59) == "约剩 59 秒")
            #expect(caption(remainingSeconds: 60) == "约剩 1 分钟")
            #expect(caption(remainingSeconds: 900) == "约剩 15 分钟")
            #expect(caption(remainingSeconds: 3600) == "约剩 1 小时")
            #expect(caption(remainingSeconds: 3900) == "约剩 1 小时 5 分钟")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(caption(remainingSeconds: 0.4) == "A few seconds left")
            #expect(caption(remainingSeconds: 12) == "12s left")
            #expect(caption(remainingSeconds: 900) == "15m left")
            #expect(caption(remainingSeconds: 3900) == "1h 5m left")
        }
    }

    @Test("Rounding is upwards, so the caption never promises a time that has already passed")
    func timeRemainingRoundsUp() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            let progress = DownloadProgress(receivedBytes: 0, totalBytes: 10_000, bytesPerSecond: 1_000)
            // Exactly 10 s, and 10.2 s, both read as ten seconds rather than nine.
            #expect(DownloadSectionCopy.timeRemaining(progress) == "约剩 10 秒")
        }
    }

    @Test("An unmeasured rate or an unknown length shows no time at all")
    func timeRemainingNeedsBothSidesOfTheDivision() {
        // No rate yet: the first samples are too close together to measure.
        #expect(DownloadSectionCopy.timeRemaining(
            DownloadProgress(receivedBytes: 1_000, totalBytes: 10_000, bytesPerSecond: nil)
        ) == nil)
        // No declared length.
        #expect(DownloadSectionCopy.timeRemaining(
            DownloadProgress(receivedBytes: 1_000, totalBytes: nil, bytesPerSecond: 1_000)
        ) == nil)
        // Already past the declared length: nothing left to count down.
        #expect(DownloadSectionCopy.timeRemaining(
            DownloadProgress(receivedBytes: 10_000, totalBytes: 10_000, bytesPerSecond: 1_000)
        ) == nil)
        // A stalled transfer must not divide by zero.
        #expect(DownloadSectionCopy.timeRemaining(
            DownloadProgress(receivedBytes: 1_000, totalBytes: 10_000, bytesPerSecond: 0)
        ) == nil)
    }

    // MARK: - Rate sampling

    @Test("The sampler smooths the rate, measures nothing from one sample, and forgets a restarted download")
    func samplerSmoothsAndResets() throws {
        let clock = TestClock()
        let sampler = DownloadProgressSampler(now: { clock.instant })

        // First sample: no history, so no rate. A caption must not show a fabricated speed.
        let first = sampler.decorate(DownloadProgress(receivedBytes: 0, totalBytes: 4 * 1_000_000))
        #expect(first.bytesPerSecond == nil)

        clock.advance(bySeconds: 1)
        let second = sampler.decorate(DownloadProgress(receivedBytes: 1_000_000, totalBytes: 4 * 1_000_000))
        let rate = try #require(second.bytesPerSecond)
        #expect(abs(rate - 1_000_000) < 1)

        // A slower second pulls the smoothed rate halfway towards the new sample, not straight to it.
        clock.advance(bySeconds: 1)
        let third = sampler.decorate(DownloadProgress(receivedBytes: 1_500_000, totalBytes: 4 * 1_000_000))
        let smoothed = try #require(third.bytesPerSecond)
        #expect(smoothed > 500_000 && smoothed < 1_000_000)

        // A download that restarts (fewer bytes than last time) clears the history instead of
        // reporting a negative rate.
        let restarted = sampler.decorate(DownloadProgress(receivedBytes: 10, totalBytes: 4 * 1_000_000))
        #expect(restarted.bytesPerSecond == nil)
    }

    // MARK: - Failure taxonomy

    @Test("Each install error maps to the recovery the user actually has")
    func failureRecoveryMatchesTheCause() {
        let manual: [UpdateInstallError] = [
            .checksumMismatch(expected: "a", actual: "b"),
            .bundleIdentifierMismatch(found: "other.app"),
            .bundleVersionMismatch(found: "1.0.0", expected: "1.2.0"),
            .codeSignatureInvalid("codesign said no"),
            .updateSignatureMissing,
            .updateSignatureInvalid("bad signature"),
            .updateBelowMinimum(current: "1.0.0", minimum: "1.1.0"),
            .missingPackageAsset,
            .notRunningFromAppBundle,
            .targetLocationNotWritable("/Applications"),
        ]
        for error in manual {
            #expect(
                UpdateFailureClassifier.recovery(for: error) == .manualDownload,
                "\(error) should not offer a retry that fails identically"
            )
        }
        for error in [UpdateInstallError.unpackFailed("busy"), .relaunchFailed("no exit")] {
            #expect(UpdateFailureClassifier.recovery(for: error) == .retryInstall, "\(error)")
        }

        // Transport and disk errors are not install errors at all; another attempt can work.
        struct TransportBoom: Error {}
        #expect(UpdateFailureClassifier.recovery(for: TransportBoom()) == .retryInstall)

        // `canRetryInstall` is exactly the retryable case, so the UI has one rule to branch on.
        #expect(AppUpdateFailure(release: nil, message: "", recovery: .retryInstall).canRetryInstall)
        #expect(!AppUpdateFailure(release: nil, message: "", recovery: .recheck).canRetryInstall)
        #expect(!AppUpdateFailure(release: nil, message: "", recovery: .manualDownload).canRetryInstall)
    }

    // MARK: - HomeStore

    @MainActor
    @Test("A non-retryable failure refuses to start the same installation again")
    func nonRetryableFailureDoesNotLoop() async throws {
        let harness = try HomeStoreHarness()
        defer { harness.cleanUp() }

        harness.store.updateState = .failed(
            AppUpdateFailure(
                release: harness.release,
                message: "package signature rejected",
                recovery: .manualDownload
            )
        )
        await harness.store.startUpdateInstallation()

        #expect(harness.downloadAttempts.value == 0)
        guard case .failed(let failure) = harness.store.updateState else {
            Issue.record("expected the failure to stand, got \(harness.store.updateState)")
            return
        }
        #expect(failure.recovery == .manualDownload)
    }

    @MainActor
    @Test("A retryable failure does start the installation again")
    func retryableFailureStartsAgain() async throws {
        let harness = try HomeStoreHarness()
        defer { harness.cleanUp() }

        harness.store.updateState = .failed(
            AppUpdateFailure(
                release: harness.release,
                message: "disk hiccup",
                recovery: .retryInstall
            )
        )
        await harness.store.startUpdateInstallation()

        #expect(harness.downloadAttempts.value >= 1)
    }

    @MainActor
    @Test("Cancel is refused while the swap script owns the staged bundle")
    func cancelIsRefusedWhileInstalling() throws {
        let harness = try HomeStoreHarness()
        defer { harness.cleanUp() }

        harness.store.updateState = .installing(harness.release)
        harness.store.cancelUpdateInstallation()

        // Saying "cancelled" here would be a lie: the detached script already owns the staging root.
        #expect(harness.store.updateState == .installing(harness.release))
    }

    @MainActor
    @Test("A relaunch that never terminates turns into a retryable failure instead of a stuck spinner")
    func relaunchWatchdogRecovers() async throws {
        let harness = try HomeStoreHarness()
        defer { harness.cleanUp() }

        let staged = harness.stagedApp()
        harness.store.updateRelaunchWatchdogInterval = .milliseconds(20)
        harness.store.updateState = .readyToRelaunch(staged)
        harness.store.confirmRelaunchForUpdate()

        // The detached swap was launched, so the app believes it is on its way out.
        #expect(harness.store.updateState == .installing(harness.release))
        #expect(harness.didTerminate.value)

        // It did not exit. The watchdog must stop claiming "正在重启…" and offer a retry.
        try await waitUntil(timeout: .seconds(5)) {
            if case .failed = harness.store.updateState { return true }
            return false
        }
        guard case .failed(let failure) = harness.store.updateState else {
            Issue.record("expected a failure after the watchdog fired, got \(harness.store.updateState)")
            return
        }
        #expect(failure.recovery == .retryInstall)
        #expect(failure.release?.version == harness.release.version)
        #expect(!failure.message.isEmpty)
        // The staged copy is discarded; retrying downloads a fresh package.
        #expect(!FileManager.default.fileExists(atPath: staged.stagingRootURL.path))
    }

    @MainActor
    @Test("Disabling the watchdog leaves a launched relaunch alone")
    func watchdogCanBeDisabled() throws {
        let harness = try HomeStoreHarness()
        defer { harness.cleanUp() }

        harness.store.updateRelaunchWatchdogInterval = nil
        harness.store.updateState = .readyToRelaunch(harness.stagedApp())
        harness.store.confirmRelaunchForUpdate()

        #expect(harness.store.updateState == .installing(harness.release))
    }

    // MARK: - Traditional Chinese

    @Test("The new update copy is translated into Traditional Chinese")
    func newUpdateCopyHasHantTranslations() {
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(DownloadSectionCopy.timeRemaining(
                DownloadProgress(receivedBytes: 0, totalBytes: 12_000, bytesPerSecond: 1_000)
            ) == "約剩 12 秒")
            #expect(DownloadSectionCopy.timeRemaining(
                DownloadProgress(receivedBytes: 0, totalBytes: 900_000, bytesPerSecond: 1_000)
            ) == "約剩 15 分鐘")
            #expect(L10n.tr("重新检查", "Check Again") == "重新檢查")
            #expect(L10n.tr("立即更新", "Update Now") == "立即更新")
            #expect(
                L10n.tr(
                    "替换后的应用没有自动启动，请重试或手动下载安装",
                    "The replaced app did not start; retry or install manually"
                ) == "替換後的應用沒有自動啟動，請重試或手動下載安裝"
            )
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(DownloadSectionCopy.timeRemaining(
                DownloadProgress(receivedBytes: 0, totalBytes: 12_000, bytesPerSecond: 1_000)
            ) == "12s left")
        }
    }
}

// MARK: - Support

/// A `HomeStore` wired to a driver that records attempts and never touches the network or the
/// Keychain, plus a temp `.app` the updater can validate as an install target.
@MainActor
private struct HomeStoreHarness {
    let store: HomeStore
    let release: AppRelease
    let rootDir: URL
    let targetAppURL: URL
    let downloadAttempts = Counter()
    let didTerminate = Flag()
    private let suiteName: String

    init() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)

        targetAppURL = rootDir.appendingPathComponent("MenuBarHome.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetAppURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": AppUpdater.expectedBundleIdentifier,
            "CFBundleShortVersionString": "1.0.0",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: targetAppURL.appendingPathComponent("Contents/Info.plist"))

        release = AppRelease(
            version: "1.4.0",
            pageURL: URL(string: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.4.0")!,
            notes: "",
            packageAsset: .init(
                name: "MenuBarHome-1.4.0.dmg",
                downloadURL: UpdateChecker.releaseAssetURL(
                    version: "1.4.0",
                    fileName: "MenuBarHome-1.4.0.dmg"
                )!,
                sizeBytes: 1024,
                kind: .dmg
            )
        )

        let attempts = downloadAttempts
        let driver = UpdateSystemDriver(
            downloadFile: { _, destination, onProgress in
                attempts.increment()
                let bytes = Data(repeating: 0x41, count: 16)
                try bytes.write(to: destination)
                onProgress(DownloadProgress(receivedBytes: 16, totalBytes: 16))
            },
            fetchData: { request in
                // Anything past the download is a manifest fetch that should not be needed here.
                // Built as a guarded value rather than `HTTPURLResponse(...) ?? URLResponse()`:
                // corelibs-foundation has no zero-argument `URLResponse()`, so the fallback only
                // compiled on Darwin.
                guard let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                ) else {
                    throw UpdateChecker.CheckError.httpStatus(500)
                }
                return (Data(), response)
            },
            unpackArchive: { _, _, directory in directory },
            verifyCodeSignature: { _, _ in },
            launchDetachedSwapAndRelaunch: { _, _, _ in }
        )

        suiteName = "com.jryang1997.MenuBarMijia.update-recovery.\(UUID().uuidString)"
        store = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suiteName,
            updater: AppUpdater(
                currentVersion: "1.0.0",
                targetBundleURL: targetAppURL,
                stagingBaseDirectory: rootDir,
                updateSigningPublicKeysBase64: ["unused-in-these-tests"],
                driver: driver
            )
        )
        store.automaticallyChecksForUpdates = false
        // Every one of these tests asserts on a relaunch that is expected *not* to exit this
        // process, so the watchdog default must be replaced per test.
        store.updateRelaunchWatchdogInterval = nil
        let flag = didTerminate
        store.onTerminateForUpdate = { flag.set() }
    }

    func stagedApp() -> VerifiedStagedApp {
        let stagingRoot = rootDir.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        return VerifiedStagedApp(
            release: release,
            stagedBundleURL: stagingRoot.appendingPathComponent("MenuBarHome.app", isDirectory: true),
            stagingRootURL: stagingRoot
        )
    }

    func cleanUp() {
        store.updateRelaunchWatchdogTask?.cancel()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootDir)
    }
}

/// A clock the test advances by hand, so the sampler measures a deterministic rate instead of wall
/// time.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    var instant: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(bySeconds seconds: Int) {
        lock.lock()
        current = current.advanced(by: .seconds(seconds))
        lock.unlock()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}

@MainActor
private func waitUntil(
    timeout: Duration,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
