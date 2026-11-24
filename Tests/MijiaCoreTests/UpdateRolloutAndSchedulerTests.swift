import Foundation
import Testing
@testable import MijiaCore

@Suite("Update rollout and background scheduler", .timeLimit(.minutes(1)))
struct UpdateRolloutAndSchedulerTests {
    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test("Rollout bucketing, eligibility, and metadata parsing match the cross-platform golden corpus")
    func rolloutMatchesGoldenCorpus() throws {
        let data = try Data(contentsOf: Self.fixtureURL("update_rollout_golden.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        for item in try #require(root["bucketCases"] as? [[String: Any]]) {
            #expect(
                UpdateRollout.bucket(
                    installID: try #require(item["installId"] as? String),
                    version: try #require(item["version"] as? String)
                ) == (try #require(item["expectedBucket"] as? Int))
            )
        }
        for item in try #require(root["eligibilityCases"] as? [[String: Any]]) {
            #expect(
                UpdateRollout.isEligible(
                    installID: try #require(item["installId"] as? String),
                    version: try #require(item["version"] as? String),
                    rolloutPercentage: item["rolloutPercentage"] as? Int,
                    manual: try #require(item["manual"] as? Bool)
                ) == (try #require(item["expectedEligible"] as? Bool))
            )
        }
        for item in try #require(root["metadataCases"] as? [[String: Any]]) {
            let label = try #require(item["label"] as? String)
            let json = try #require(item["json"] as? [String: Any])
            let expected = item["expectedRolloutPercentage"] as? Int
            #expect(UpdateRollout.parseRolloutPercentage(fromReleaseObject: json) == expected, "Case: \(label)")
        }
    }

    @Test("Install ID is generated once, persisted locally, and reused across calls")
    func installIDPersistsLocally() throws {
        let suite = "UpdateRolloutInstallIDTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var generatedCount = 0
        let first = UpdateRollout.installID(in: defaults) {
            generatedCount += 1
            return "550e8400-e29b-41d4-a716-446655440000"
        }
        let second = UpdateRollout.installID(in: defaults) {
            generatedCount += 1
            return "ffffffff-ffff-4fff-bfff-ffffffffffff"
        }
        #expect(first == "550e8400-e29b-41d4-a716-446655440000")
        #expect(second == first)
        #expect(generatedCount == 1)
    }

    @Test("Automatic update check respects rollout percentage while manual check always offers the release")
    @MainActor
    func homeStoreAutomaticRolloutGatingAndManualBypass() async throws {
        let suite = "UpdateRolloutStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("550e8400-e29b-41d4-a716-446655440000", forKey: UpdateRollout.installIDKey) // bucket 18 for 1.5.0

        final class RolloutBox: @unchecked Sendable { var percentage = 10 }
        let rolloutBox = RolloutBox()
        let updater = AppUpdater(
            currentVersion: "1.4.0",
            driver: UpdateSystemDriver(
                downloadFile: { _, _, _ in },
                fetchData: { req in
                    let body = """
                    {"tag_name":"v1.5.0","html_url":"https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.5.0","rollout_percentage":\(rolloutBox.percentage),"body":"Staged release"}
                    """
                    let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(body.utf8), resp)
                },
                unpackArchive: { _, _, dir in dir },
                verifyCodeSignature: { _, _ in },
                launchDetachedSwapAndRelaunch: { _, _, _ in }
            )
        )

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, updater: updater)
        store.automaticallyChecksForUpdates = true
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)

        await store.checkForUpdatesIfNeeded(now: t0)
        #expect(store.updateState == .upToDate(checkedAt: t0))

        rolloutBox.percentage = 0
        await store.checkForUpdates(now: t0.addingTimeInterval(60))
        #expect(store.updateState.badgeRelease?.version == "1.5.0")

        rolloutBox.percentage = 25
        store.updateState = .idle
        await store.checkForUpdatesIfNeeded(now: t0.addingTimeInterval(HomeStore.automaticUpdateCheckInterval + 120))
        #expect(store.updateState.badgeRelease?.version == "1.5.0")
    }

    private final class FakeActivity: BackgroundActivityScheduling, @unchecked Sendable {
        let identifier: String
        var repeats = false
        var interval: TimeInterval = 0
        var tolerance: TimeInterval = 0
        var qualityOfService: QualityOfService = .default
        var shouldDefer = false
        var invalidateCount = 0
        var scheduledBlock: (@Sendable (@escaping @Sendable (BackgroundActivityResult) -> Void) -> Void)?

        init(identifier: String) { self.identifier = identifier }
        func schedule(_ block: @escaping @Sendable (@escaping @Sendable (BackgroundActivityResult) -> Void) -> Void) {
            scheduledBlock = block
        }
        func invalidate() { invalidateCount += 1 }
        func fire() async -> BackgroundActivityResult {
            await withCheckedContinuation { cont in
                guard let block = scheduledBlock else { cont.resume(returning: .finished); return }
                block { cont.resume(returning: $0) }
            }
        }
    }

    @Test("BackgroundUpdateScheduler configures repeats, interval, tolerance, QoS, honors shouldDefer, and applies deterministic jitter")
    @MainActor
    func schedulerConfigurationDeferralAndJitter() async {
        final class Box: @unchecked Sendable {
            var activities: [FakeActivity] = []
            var recordedDelays: [TimeInterval] = []
            var delayEnteredContinuation: CheckedContinuation<Void, Never>?
            var delayReleaseContinuation: CheckedContinuation<Void, Error>?
            var checkCount = 0
            var checkContinuation: CheckedContinuation<Void, Never>?
        }

        let box = Box()
        let scheduler = BackgroundUpdateScheduler(
            identifier: "com.test.updateCheck",
            interval: 6 * 3600,
            tolerance: 3600,
            maxInitialJitter: 1800,
            makeActivity: { id in
                let activity = FakeActivity(identifier: id)
                box.activities.append(activity)
                return activity
            },
            randomUnit: { 0.25 },
            delay: { seconds in
                box.recordedDelays.append(seconds)
                box.delayEnteredContinuation?.resume()
                box.delayEnteredContinuation = nil
                try await withCheckedThrowingContinuation { box.delayReleaseContinuation = $0 }
            },
            performCheck: {
                box.checkCount += 1
                box.checkContinuation?.resume()
                box.checkContinuation = nil
                return nil
            }
        )

        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            box.delayEnteredContinuation = entered
            scheduler.start()
        }
        #expect(scheduler.isRunning)
        #expect(scheduler.lastScheduledJitterDelay == 450)
        #expect(box.recordedDelays == [450])
        #expect(box.checkCount == 0)

        let activity = box.activities[0]
        #expect(activity.identifier == "com.test.updateCheck")
        #expect(activity.repeats)
        #expect(activity.interval == 6 * 3600)
        #expect(activity.tolerance == 3600)
        #expect(activity.qualityOfService == .utility)

        activity.shouldDefer = true
        #expect(await activity.fire() == .deferred)
        #expect(box.checkCount == 0)

        activity.shouldDefer = false
        #expect(await activity.fire() == .finished)
        #expect(box.checkCount == 1)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            box.checkContinuation = done
            box.delayReleaseContinuation?.resume()
            box.delayReleaseContinuation = nil
        }
        #expect(box.checkCount == 2)

        scheduler.stop()
        #expect(!scheduler.isRunning)
        #expect(activity.invalidateCount == 1)
    }

    @Test("An early background wake retries at the six-hour deadline without an extra request", arguments: [false, true])
    @MainActor
    func backgroundWakeAfterJitterOrManualCheck(manual: Bool) async throws {
        final class Probe: @unchecked Sendable {
            var activity: FakeActivity?
            var requestCount = 0
        }

        let suite = "UpdateCadenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        let updater = AppUpdater(
            currentVersion: "1.5.0",
            driver: UpdateSystemDriver(
                downloadFile: { _, _, _ in },
                fetchData: { req in
                    probe.requestCount += 1
                    let body = #"{"tag_name":"v1.5.0","html_url":"https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.5.0"}"#
                    let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(body.utf8), response)
                },
                unpackArchive: { _, _, dir in dir },
                verifyCodeSignature: { _, _ in },
                launchDetachedSwapAndRelaunch: { _, _, _ in }
            )
        )
        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite, updater: updater)
        store.automaticallyChecksForUpdates = true
        let launched = Date(timeIntervalSince1970: 1_750_000_000)
        let interval = HomeStore.automaticUpdateCheckInterval
        var now = launched
        let jitterGate = AsyncStream<Void>.makeStream()
        let jitterFinished = AsyncStream<Void>.makeStream()
        let scheduler = BackgroundUpdateScheduler(
            makeActivity: { id in
                let activity = FakeActivity(identifier: id)
                probe.activity = activity
                return activity
            },
            randomUnit: { 0.5 },
            delay: { _ in
                for await _ in jitterGate.stream { return }
                throw CancellationError()
            },
            now: { now },
            performCheck: {
                let retryAt = await store.checkForUpdatesIfNeeded(now: now)
                jitterFinished.continuation.yield()
                return retryAt
            }
        )
        defer {
            scheduler.stop()
            jitterGate.continuation.finish()
            jitterFinished.continuation.finish()
        }
        scheduler.start()
        let activity = try #require(probe.activity)

        now = launched.addingTimeInterval(15 * 60)
        jitterGate.continuation.yield()
        var checks = jitterFinished.stream.makeAsyncIterator()
        _ = await checks.next()
        #expect(probe.requestCount == 1)

        if manual {
            now = launched.addingTimeInterval(3 * 3600)
            await store.checkForUpdates(now: now)
        }
        let lastSuccessfulCheck = now
        let requestCount = manual ? 2 : 1

        now = launched.addingTimeInterval(interval)
        let remaining = lastSuccessfulCheck.addingTimeInterval(interval).timeIntervalSince(now)
        #expect(await activity.fire() == .finished)
        let retry = try #require(probe.activity)
        #expect(activity.invalidateCount == 1)
        #expect(!retry.repeats)
        #expect(retry.interval == remaining)
        #expect(retry.tolerance == 0)
        #expect(probe.requestCount == requestCount)

        now = now.addingTimeInterval(retry.interval)
        #expect(await activity.fire() == .finished)
        #expect(probe.requestCount == requestCount)
        #expect(await retry.fire() == .finished)
        #expect(now == lastSuccessfulCheck.addingTimeInterval(interval))
        #expect(probe.requestCount == requestCount + 1)
        #expect(store.updateState == .upToDate(checkedAt: now))
        let repeating = try #require(probe.activity)
        #expect(repeating.repeats)
        #expect(repeating.interval == interval)
        #expect(repeating.tolerance == BackgroundUpdateScheduler.defaultTolerance)

        // macOS can also invoke the next repeat before the six-hour deadline.
        now = now.addingTimeInterval(repeating.interval - repeating.tolerance)
        #expect(await repeating.fire() == .finished)
        #expect(probe.requestCount == requestCount + 1)
        let nextRetry = try #require(probe.activity)
        #expect(nextRetry.interval == repeating.tolerance)
        now = now.addingTimeInterval(nextRetry.interval)
        #expect(await nextRetry.fire() == .finished)
        #expect(probe.requestCount == requestCount + 2)
    }

    @Test("Jitter computation clamps out-of-range and non-finite RNG values")
    func jitterClamping() {
        #expect(BackgroundUpdateScheduler.computeInitialJitter(randomUnit: 0.0, maxJitter: 1800) == 0)
        #expect(BackgroundUpdateScheduler.computeInitialJitter(randomUnit: 0.5, maxJitter: 1800) == 900)
        #expect(BackgroundUpdateScheduler.computeInitialJitter(randomUnit: 1.5, maxJitter: 1800) == 1800)
        #expect(BackgroundUpdateScheduler.computeInitialJitter(randomUnit: -0.2, maxJitter: 1800) == 0)
        #expect(BackgroundUpdateScheduler.computeInitialJitter(randomUnit: .nan, maxJitter: 1800) == 0)
    }
}
