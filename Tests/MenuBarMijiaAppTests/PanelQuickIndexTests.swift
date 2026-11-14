import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

extension PanelPresentationTests {
    /// Digit shortcuts must control the card wearing the badge, never a device hidden inside a
    /// folded stack. The real glass column is rendered so the published order is the one the view
    /// draws, and each press goes through `PanelKeyRouter` into the same seam the app-wide key
    /// monitor calls. The window and standard `UserDefaults` are process-wide, so the suite is
    /// serialized.
    @MainActor
    @Suite(.serialized)
    struct PanelQuickIndexTests {
        init() {
            SnapshotWindow.pinOverlayScrollers()
        }

        @Test("A folded stack takes no badge: key 1 controls the card wearing badge 1")
        func foldedStackDigitControlsBadgeOne() async throws {
            let harness = try await QuickIndexHarness(home: QuickIndexHarness.twoRoomHome)
            defer { harness.tearDown() }

            try await harness.waitForOrder(["b1"])
            #expect(PanelQuickIndexState.shared.order?.badges == ["b1": 1])

            let before = await harness.commandCount()
            harness.press(1)
            let command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.b1", isOn: false))
        }

        @Test("Expanding and folding a stack renumbers the card under key 1")
        func expandedStackRenumbersDigitOne() async throws {
            let harness = try await QuickIndexHarness(home: QuickIndexHarness.twoRoomHome)
            defer { harness.tearDown() }

            try await harness.waitForOrder(["b1"])

            // A keyboard focus change opens the two-device room, as it does in the panel.
            harness.store.focusedDeviceId = "a1"
            try await harness.waitForOrder(["a1", "a2", "b1"])

            var before = await harness.commandCount()
            harness.press(1)
            var command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.a1", isOn: false))

            // Closing the panel folds every stack again; badge 1 returns to the single-device room.
            NotificationCenter.default.post(name: MenuBarPanelController.didHideNotification, object: nil)
            try await harness.waitForOrder(["b1"])

            before = await harness.commandCount()
            harness.press(1)
            command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.b1", isOn: false))
        }

        @Test("Removing a favorite renumbers the badges the digits follow")
        func favoriteRemovalRenumbersDigits() async throws {
            let harness = try await QuickIndexHarness(
                home: QuickIndexHarness.twoRoomHome,
                favorites: ["a1"]
            )
            defer { harness.tearDown() }

            try await harness.waitForOrder(["a1", "a2", "b1"])

            // The favorite leaves the pinned stack: its room folds again, and the single-device
            // room's card becomes badge 1.
            harness.store.toggleFavorite("a1")
            try await harness.waitForOrder(["b1"])

            let before = await harness.commandCount()
            harness.press(1)
            let command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.b1", isOn: false))
        }

        @Test("A saved card order renumbers the digits")
        func savedCardOrderRenumbersDigits() async throws {
            let harness = try await QuickIndexHarness(home: QuickIndexHarness.twoRoomHome)
            defer { harness.tearDown() }

            try await harness.waitForOrder(["b1"])
            harness.store.focusedDeviceId = "a1"
            try await harness.waitForOrder(["a1", "a2", "b1"])

            PanelLayoutStore.shared(for: harness.store.userDefaults)
                .setOrder(["b1", "a2", "a1"])
            try await harness.waitForOrder(["a2", "a1", "b1"])

            let before = await harness.commandCount()
            harness.press(1)
            let command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.a2", isOn: false))
        }

        @Test("Default packing puts full-row modules after the capsules, and key 1 follows")
        func defaultPackingRenumbersDigits() async throws {
            let harness = try await QuickIndexHarness(home: QuickIndexHarness.climateAndLightHome)
            defer { harness.tearDown() }

            // One two-device room starts folded, so it contributes no badge.
            try await harness.waitForOrder([])

            harness.store.focusedDeviceId = "c1"
            // Without a saved order the light capsule is packed before the full-row climate module,
            // even though the snapshot lists the climate first.
            try await harness.waitForOrder(["l1", "c1"])

            let before = await harness.commandCount()
            harness.press(1)
            let command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.l1", isOn: false))
        }

        @Test("A device hidden after the order was published is never controlled")
        func hiddenDeviceIsNeverControlled() async throws {
            let harness = try await QuickIndexHarness(home: QuickIndexHarness.twoRoomHome)
            defer { harness.tearDown() }

            try await harness.waitForOrder(["b1"])
            harness.store.hideDevice("b1")
            // The panel has not redrawn yet: the registration still lists the hidden device.
            let before = await harness.commandCount()
            harness.press(1)
            try await Task.sleep(for: .milliseconds(200))
            let after = await harness.commandCount()
            #expect(after == before, "a hidden device must not be toggled by a stale badge")

            try await harness.waitForOrder([])
        }

        @Test("Classic keeps the store's own number order; a missing glass order falls back to it")
        func classicKeepsStoreOrder() async throws {
            let harness = try await QuickIndexHarness(home: QuickIndexHarness.twoRoomHome)
            defer { harness.tearDown() }

            try await harness.waitForOrder(["b1"])

            // The stored theme is Classic: the glass registration must not leak into it.
            var before = await harness.commandCount()
            harness.press(1, theme: .classic)
            var command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.a1", isOn: false))

            // No glass column owns the digits: `HomeStore.selectQuickIndex` runs, as before.
            PanelQuickIndexState.shared.clear()
            #expect(PanelQuickIndexState.shared.order == nil)
            before = await harness.commandCount()
            harness.press(2)
            command = try await harness.nextCommand(after: before)
            #expect(command == .setLightPower(entityId: "light.a2", isOn: false))
        }

        @Test("Leaving the glass column withdraws its number order")
        func leavingGlassColumnClearsOrder() async throws {
            let harness = try await QuickIndexHarness(home: QuickIndexHarness.twoRoomHome)
            defer { harness.tearDown() }

            try await harness.waitForOrder(["b1"])
            harness.detachPanel()

            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, PanelQuickIndexState.shared.order != nil {
                QuickIndexHarness.pump()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(PanelQuickIndexState.shared.order == nil)
        }
    }
}

// MARK: - Fixture

@MainActor
private final class QuickIndexHarness {
    enum FixtureError: Error {
        case missingDefaults
        case missingCommand
    }

    static let roomA = RoomArea(id: "room_a", name: "Room A", sortOrder: 0)
    static let roomB = RoomArea(id: "room_b", name: "Room B", sortOrder: 1)

    /// Two lights in the first room (a folded stack by default) and one in the second.
    static var twoRoomHome: SynthesizedHome {
        SynthesizedHome(
            rooms: [roomA, roomB],
            devices: [
                light("a1", room: roomA),
                light("a2", room: roomA),
                light("b1", room: roomB)
            ]
        )
    }

    /// One climate module (a full-row tile) listed before a light capsule: default packing draws
    /// the capsule first.
    static var climateAndLightHome: SynthesizedHome {
        SynthesizedHome(
            rooms: [roomA],
            devices: [
                SmartDevice(
                    id: "c1",
                    name: "Climate",
                    roomId: roomA.id,
                    roomName: roomA.name,
                    model: "test.climate",
                    isOnline: true,
                    kind: .climate(ClimateSpec(
                        entityId: "climate.c1",
                        isOn: false,
                        hvacMode: "off",
                        availableModes: ["off", "cool"],
                        targetTemperature: 25
                    ))
                ),
                light("l1", room: roomA)
            ]
        )
    }

    static func light(_ id: String, room: RoomArea) -> SmartDevice {
        SmartDevice(
            id: id,
            name: id,
            roomId: room.id,
            roomName: room.name,
            model: "test.light",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.\(id)", isOn: true))
        )
    }

    /// Values the panel reads through `@AppStorage` on `.standard`.
    static let isolatedStandardKeys = [
        PanelGrouping.storageKey,
        GroupPrefs.groupsKey,
        GroupPrefs.mapKey,
        GroupPrefs.aliasesKey,
        RoomPrefs.aliasesKey,
        RoomPrefs.orderKey,
        KindOrderPrefs.orderKey,
        PanelPrefs.climatePanelKey,
        DeviceLayoutPrefs.orderKey,
        DeviceLayoutPrefs.storageKey
    ]

    let store: HomeStore
    let mock: MockHomeProvider
    private let suite: String
    private let savedStandard: [(String, Any?)]
    private let window: NSWindow
    private var hosting: NSHostingView<AnyView>?

    init(home: SynthesizedHome, favorites: [String] = []) async throws {
        _ = NSApplication.shared
        let suite = "PanelQuickIndexTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw FixtureError.missingDefaults
        }
        self.suite = suite
        self.savedStandard = Self.isolatedStandardKeys.map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        for key in Self.isolatedStandardKeys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(PanelGrouping.room.rawValue, forKey: PanelGrouping.storageKey)
        UserDefaults.standard.set(true, forKey: PanelPrefs.climatePanelKey)
        UserDefaults.standard.set("[]", forKey: GroupPrefs.groupsKey)
        UserDefaults.standard.set("{}", forKey: GroupPrefs.mapKey)
        UserDefaults.standard.set("{}", forKey: GroupPrefs.aliasesKey)
        UserDefaults.standard.set("{}", forKey: RoomPrefs.aliasesKey)
        UserDefaults.standard.set("[]", forKey: RoomPrefs.orderKey)
        UserDefaults.standard.set("[]", forKey: KindOrderPrefs.orderKey)
        UserDefaults.standard.set("[]", forKey: DeviceLayoutPrefs.orderKey)
        UserDefaults.standard.set("{}", forKey: DeviceLayoutPrefs.storageKey)

        // The store's own suite: onboarding off, no update check, and an explicit empty favorites
        // key so the first snapshot does not seed favorites behind the test.
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")
        defaults.set([String](), forKey: HomePreferences.favoriteDeviceIds.key)
        defaults.set([String](), forKey: HomePreferences.favoriteOrder.key)

        let mock = MockHomeProvider(snapshot: home)
        self.mock = mock
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        self.store = store
        try await store.waitForTestSnapshot()
        if !favorites.isEmpty {
            store.favoriteDeviceIds = Set(favorites)
            store.favoriteOrder = favorites
        }

        #if DEBUG
        LayoutUIState.shared.resetForTesting()
        #endif
        PanelSearchState.shared.end()
        PanelQuickIndexState.shared.clear()
        SpeechInputController.shared.setPreviewState(
            isListening: false, isHoldToTalk: false, draft: ""
        )

        let root = AnyView(
            ControlCenterPanel(store: store)
                .environment(\.colorScheme, .light)
                .environment(\.reduceMotionOverride, true)
                .environment(\.reduceTransparencyOverride, true)
                .transaction { $0.disablesAnimations = true }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 560)
        self.hosting = hosting

        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 120, width: 376, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.hasShadow = false
        window.contentView = hosting
        self.window = window
        window.orderFront(nil)
        for _ in 0..<4 { Self.pump() }
    }

    /// Renders and runs the main run loop briefly, like a display pass.
    static func pump(_ seconds: TimeInterval = 0.02) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }

    /// Waits for the mounted column to publish `expected` as the order its badges draw.
    func waitForOrder(_ expected: [String]) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if PanelQuickIndexState.shared.order?.deviceIds == expected { return }
            Self.pump(0.02)
            try await Task.sleep(for: .milliseconds(20))
        }
        let actual = PanelQuickIndexState.shared.order?.deviceIds
        try #require(
            actual == expected,
            "the glass column drew \(actual.map { $0.joined(separator: ", ") } ?? "no order"), expected \(expected.joined(separator: ", "))"
        )
    }

    /// Sends a digit through the real router, then performs it exactly as the key monitor does.
    func press(_ digit: Int, theme: PanelTheme = .liquidGlass) {
        let key = PanelKeyRouter.Key(
            code: Int(kVK_ANSI_1) + (digit - 1),
            characters: "\(digit)"
        )
        let action = PanelKeyRouter.afterSearch(key, PanelKeyRouter.Context(isPanelWindow: true))
        guard case .selectQuickIndex(let routed) = action else {
            Issue.record("digit \(digit) routed to \(action) instead of the quick index")
            return
        }
        #expect(routed == digit)
        PanelQuickIndexState.shared.select(routed, store: store, theme: theme)
    }

    func commandCount() async -> Int {
        await mock.executedCommands.count
    }

    /// The command a press of the digit produced, once the store's async toggle reaches the mock.
    func nextCommand(after count: Int) async throws -> DeviceCommand {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let commands = await mock.executedCommands
            if commands.count > count, let last = commands.last { return last }
            Self.pump(0.02)
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.missingCommand
    }

    /// Removes the hosted panel, which is the theme switch's teardown.
    func detachPanel() {
        hosting = nil
        window.contentView = nil
        for _ in 0..<4 { Self.pump() }
    }

    func tearDown() {
        detachPanel()
        window.orderOut(nil)
        PanelQuickIndexState.shared.clear()
        PanelSearchState.shared.end()
        for (key, value) in savedStandard {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
