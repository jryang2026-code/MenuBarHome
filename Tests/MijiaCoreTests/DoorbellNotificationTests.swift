import Foundation
import Testing
@testable import MijiaCore

/// #10: a doorbell press posts one banner, named after the card, timed by the press itself.
struct DoorbellNotificationTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let chinese = Locale(identifier: "zh_Hans_CN")
    private static let ring = DoorbellRing(
        deviceId: "door-device",
        entityId: "event.door_ring",
        firedAt: "2026-11-05T01:05:00.000+00:00"
    )

    private static func notification(
        _ ring: DoorbellRing = ring,
        name: String? = "门口"
    ) -> DoorbellNotification {
        DoorbellNotification(
            ring: ring,
            deviceName: name,
            locale: chinese,
            timeZone: utc,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("The banner is titled with the card and bodies the press time")
    func contentUsesNameAndPressTime() {
        let note = Self.notification()
        #expect(note.title == "门铃：门口")
        #expect(note.body.contains("01:05"), "the HA press timestamp, not delivery time")
        #expect(note.deviceId == "door-device")
    }

    @Test("A card without a name still reads as a doorbell, and blank names count as missing")
    func unnamedCardFallsBack() {
        #expect(Self.notification(name: nil).title == "门铃响了")
        #expect(Self.notification(name: "  ").title == "门铃响了")
    }

    @Test("An unparsable source timestamp falls back to the delivery time")
    func unreadableTimestampUsesNow() {
        let ring = DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: "unknown")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = DoorbellNotification.timeText(now, locale: Self.chinese, timeZone: Self.utc)
        let note = DoorbellNotification(ring: ring, deviceName: "门口", locale: Self.chinese, timeZone: Self.utc, now: now)
        #expect(note.body.contains(expected))
    }

    @Test("One press is one identifier, so a repeat report replaces the banner")
    func identifierIsPerPress() {
        let first = Self.notification()
        #expect(first.identifier == DoorbellNotification.identifierPrefix + Self.ring.key)
        #expect(first.identifier == Self.notification().identifier, "same press, same request id")

        let later = Self.ring
        var secondRing = later
        secondRing.firedAt = "2026-11-05T01:06:00.000+00:00"
        #expect(Self.notification(secondRing).identifier != first.identifier)

        var otherDoor = later
        otherDoor.entityId = "event.side_ring"
        #expect(Self.notification(otherDoor).identifier != first.identifier)
    }

    @MainActor
    private static func store() -> HomeStore {
        HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome()), defaultsSuiteName: "test.doorbell-notification.\(UUID().uuidString)")
    }

    @Test("Off by default: the same switches that make the app notice rings gate the banner")
    @MainActor
    func notificationFollowsDoorbellSwitches() {
        let store = Self.store()
        let delivered = Delivered()
        store.onDoorbellNotification = { delivered.items.append($0) }
        #expect(!store.wantsDoorbellNotification)

        store.handleDoorbellRing(Self.ring)
        #expect(delivered.items.isEmpty)
        #expect(store.recentDoorbellRings == [Self.ring])

        store.doorbellChime = true
        let chimePress = DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: "2026-11-05T01:06:00.000+00:00")
        store.handleDoorbellRing(chimePress)
        #expect(delivered.items.map(\.identifier) == [DoorbellNotification.identifierPrefix + chimePress.key])

        store.handleDoorbellRing(chimePress)
        #expect(delivered.items.count == 1, "the same press never posts twice")

        store.doorbellChime = false
        store.doorbellAutoPopup = true
        #expect(store.wantsDoorbellNotification)
        let popupPress = DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: "2026-11-05T01:07:00.000+00:00")
        store.handleDoorbellRing(popupPress)
        #expect(delivered.items.count == 2)

        store.doorbellAutoPopup = false
        #expect(!store.wantsDoorbellNotification)
        store.handleDoorbellRing(DoorbellRing(deviceId: "door-device", entityId: "event.door_ring", firedAt: "2026-11-05T01:08:00.000+00:00"))
        #expect(delivered.items.count == 2)
    }

    @Test("A ring for a card that is not loaded still posts, named generically")
    @MainActor
    func unknownCardStillPosts() {
        let store = Self.store()
        store.doorbellChime = true
        let delivered = Delivered()
        store.onDoorbellNotification = { delivered.items.append($0) }
        store.handleDoorbellRing(DoorbellRing(deviceId: "missing", entityId: "event.unknown_ring", firedAt: "2026-11-05T01:09:00.000+00:00"))
        #expect(delivered.items.count == 1)
        #expect(delivered.items.first?.title == L10n.tr("门铃响了", "Doorbell rang"))
    }

    @MainActor
    private final class Delivered {
        var items: [DoorbellNotification] = []
    }
}
