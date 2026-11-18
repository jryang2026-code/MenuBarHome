import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #174 review: exercise the real IOKit power description path (owned vs borrowed CFDictionary)
/// and keep the battery reading range valid.
@MainActor
struct MacContextObserverTests {
    @Test("Power source read owns/releases IOKit values correctly and clamps the battery")
    func powerSourceRead() {
        let (source, percent) = MacContextObserver.readPowerState()
        #expect([MacPowerSource.ac, .battery, .unknown].contains(source))
        if let percent {
            #expect((0...100).contains(percent))
        }
    }

    @Test("Snapshot presence requires both an awake display and an unlocked on-console session")
    func snapshotPresenceRequiresUnlockedSession() {
        let unlockedSession: [String: Any] = [
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": 1
        ]
        let lockedSession: [String: Any] = [
            "CGSSessionScreenIsLocked": 1,
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": 1
        ]
        let offConsoleSession: [String: Any] = [
            "kCGSSessionOnConsoleKey": 0,
            "kCGSessionLoginDoneKey": 1
        ]

        #expect(MacContextObserver.isUserPresent(displayIsAsleep: false, session: unlockedSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: true, session: unlockedSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: false, session: lockedSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: false, session: offConsoleSession))
        #expect(!MacContextObserver.isUserPresent(displayIsAsleep: false, session: nil))
    }
}
