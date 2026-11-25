import Foundation
import Testing
@testable import MijiaCore

struct MiCloudRateLimiterTests {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0

        var uptime: Double { lock.withLock { value } }

        func setUptime(_ uptime: Double) {
            lock.withLock { value = uptime }
        }
    }

    @Test func pollsCanOnlySpendTheReadBucket() {
        let clock = TestClock()
        let limiter = MiCloudRateLimiter(uptime: { clock.uptime })
        for _ in 0..<12 {
            #expect(limiter.admit(account: "a", write: false) == .admitted(generation: 0))
        }
        #expect(limiter.admit(account: "a", write: false) == .waitForReadToken(0.5))
        for _ in 0..<8 {
            #expect(limiter.admit(account: "a", write: true) == .admitted(generation: 0))
        }
        #expect(limiter.admit(account: "a", write: true) == .limited)
        clock.setUptime(0.5)
        #expect(limiter.admit(account: "a", write: true) == .admitted(generation: 0))
        #expect(limiter.admit(account: "a", write: false) == .waitForReadToken(0.5))
    }

    @Test(arguments: ["30", "Thu, 01 Jan 1970 00:00:30 GMT"])
    func retryAfterSetsMinimumReadPause(_ header: String) {
        let clock = TestClock()
        let limiter = MiCloudRateLimiter(
            uptime: { clock.uptime },
            wallClock: { Date(timeIntervalSince1970: 0) },
            jitter: { 0.5 }
        )
        limiter.recordLimit(account: "a", retryAfter: header)
        #expect(limiter.readCooldown(account: "a") == 60)
        #expect(limiter.admit(account: "b", write: false) == .admitted(generation: 0))
        for _ in 0..<8 {
            #expect(limiter.admit(account: "a", write: true) == .admitted(generation: 1))
        }
        #expect(limiter.admit(account: "a", write: true) == .limited)
        clock.setUptime(59.99)
        #expect(limiter.admit(account: "a", write: false) == .limited)
        clock.setUptime(60)
        #expect(limiter.admit(account: "a", write: false) == .admitted(generation: 1))
    }

    @Test(arguments: [0.0, 0.25, 1.0])
    func fullJitterUsesTheEntireExponentialWindow(_ sample: Double) {
        let limiter = MiCloudRateLimiter(uptime: { 0 }, jitter: { sample })
        limiter.recordLimit(account: "a", retryAfter: "invalid")
        #expect(limiter.readCooldown(account: "a") == 60 * sample)
        limiter.recordReadSuccess(account: "a", generation: 0)
        limiter.recordLimit(account: "a", retryAfter: nil)
        #expect(limiter.readCooldown(account: "a") == 120 * sample)
        for _ in 0..<5 { limiter.recordLimit(account: "a", retryAfter: nil) }
        #expect(limiter.readCooldown(account: "a") == 900 * sample)
    }
}
