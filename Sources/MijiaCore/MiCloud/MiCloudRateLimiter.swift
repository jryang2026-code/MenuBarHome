import Foundation
import os

final class MiCloudRateLimiter: Sendable {
    static let shared = MiCloudRateLimiter()

    // A full 6-second visible poll interval refills 12 read requests (1,200 properties)
    // and 8 reserved writes. Discovery and bursts can spend a full interval's tokens at once.
    private static let readCapacity = 12.0
    private static let writeCapacity = 8.0
    private static let refillInterval: TimeInterval = 6

    enum Admission: Equatable {
        case admitted(generation: UInt64)
        case waitForReadToken(TimeInterval)
        case limited
    }

    private struct AccountState: Sendable {
        var reads = MiCloudRateLimiter.readCapacity
        var writes = MiCloudRateLimiter.writeCapacity
        var lastRefill: TimeInterval
        var readNotBefore: TimeInterval = 0
        var generation: UInt64 = 0
        var consecutiveLimits = 0
    }

    private let accounts = OSAllocatedUnfairLock(initialState: [String: AccountState]())
    private let uptime: @Sendable () -> TimeInterval
    private let wallClock: @Sendable () -> Date
    private let jitter: @Sendable () -> Double

    init(
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.uptime = uptime
        self.wallClock = wallClock
        self.jitter = jitter
    }

    func admit(account: String, write: Bool) -> Admission {
        accounts.withLock { accounts in
            let now = uptime()
            var state = accounts[account] ?? AccountState(lastRefill: now)
            defer { accounts[account] = state }
            let elapsed = max(0, now - state.lastRefill)
            state.lastRefill = now
            state.reads = min(Self.readCapacity, state.reads + elapsed * Self.readCapacity / Self.refillInterval)
            state.writes = min(Self.writeCapacity, state.writes + elapsed * Self.writeCapacity / Self.refillInterval)

            if write && state.writes >= 1 {
                state.writes -= 1
            } else if now < state.readNotBefore {
                return .limited
            } else if state.reads >= 1 {
                state.reads -= 1
            } else if write {
                return .limited
            } else {
                return .waitForReadToken((1 - state.reads) * Self.refillInterval / Self.readCapacity)
            }
            return .admitted(generation: state.generation)
        }
    }

    func recordLimit(account: String, retryAfter: String?) {
        let minimumDelay = Self.retryAfterDelay(retryAfter, now: wallClock()) ?? 0
        let sample = jitter()
        accounts.withLock { accounts in
            let now = uptime()
            var state = accounts[account] ?? AccountState(lastRefill: now)
            state.generation &+= 1
            state.consecutiveLimits = min(state.consecutiveLimits + 1, 5)
            let ceiling = min(60 * pow(2, Double(state.consecutiveLimits - 1)), 900)
            state.readNotBefore = max(state.readNotBefore, now + minimumDelay + ceiling * sample)
            accounts[account] = state
        }
    }

    func recordReadSuccess(account: String, generation: UInt64) {
        accounts.withLock { accounts in
            guard var state = accounts[account], state.generation == generation else { return }
            state.consecutiveLimits = 0
            accounts[account] = state
        }
    }

    func readCooldown(account: String) -> TimeInterval {
        accounts.withLock { accounts in
            max(0, (accounts[account]?.readNotBefore ?? 0) - uptime())
        }
    }

    private static func retryAfterDelay(_ raw: String?, now: Date) -> TimeInterval? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = TimeInterval(value), seconds.isFinite else { return nil }
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }
}
