import AppKit
import Carbon
import PreferencesTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@MainActor
@Suite(.serialized)
struct MacOSPrivacyAndHUDTests {
    @MainActor
    private final class HUDClock {
        private let registrations = AsyncStream<Duration>.makeStream()
        private var now: Duration = .zero
        private var sleepers: [(deadline: Duration, continuation: CheckedContinuation<Void, Never>)] = []

        var scheduledDurations: AsyncStream<Duration> { registrations.stream }

        func sleep(for duration: Duration) async {
            await withCheckedContinuation { continuation in
                sleepers.append((now + duration, continuation))
                registrations.continuation.yield(duration)
            }
        }

        func advance(by duration: Duration) {
            now += duration
            let ready = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            for sleeper in ready {
                sleeper.continuation.resume()
            }
        }
    }

    @Test
    func hudSelectsScreenContainingMouse() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        ]
        #expect(hotkeyHUDScreenIndex(mouseLocation: CGPoint(x: 100, y: 100), screenFrames: screens) == 0)
        #expect(hotkeyHUDScreenIndex(mouseLocation: CGPoint(x: 1500, y: 100), screenFrames: screens) == 1)
        #expect(hotkeyHUDScreenIndex(mouseLocation: CGPoint(x: -10, y: 100), screenFrames: screens) == nil)
    }

    @Test("The latest hotkey action replaces the HUD and gets its own 1.2 second timeout without taking focus")
    func hudReplacesActionAndHidesWithoutTakingFocus() async throws {
        _ = NSApplication.shared
        let clock = HUDClock()
        var durations = clock.scheduledDurations.makeAsyncIterator()
        let hud = HotkeyHUDController(
            sharingPrivacy: ScreenSharingPrivacy(defaults: InMemoryUserDefaults()),
            sleep: clock.sleep(for:)
        )

        hud.show(title: "First", result: .on)
        let firstDismissal = try #require(hud.dismissTask)
        let panel = try #require(hud.window)
        defer { panel.orderOut(nil) }
        #expect(await durations.next() == .milliseconds(1_200))
        #expect(hud.state?.title == "First")
        #expect(panel.isVisible)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        panel.makeKey()
        #expect(!panel.isKeyWindow)

        clock.advance(by: .milliseconds(200))
        hud.show(title: "Second", result: .off)
        let secondDismissal = try #require(hud.dismissTask)
        #expect(await durations.next() == .milliseconds(1_200))
        #expect(hud.window === panel)
        #expect(hud.state?.title == "Second")
        #expect(hud.state?.result == .off)
        #expect(!panel.isKeyWindow)

        clock.advance(by: .milliseconds(1_000))
        await firstDismissal.value
        #expect(hud.state?.title == "Second")
        #expect(panel.isVisible)

        clock.advance(by: .milliseconds(200))
        await secondDismissal.value
        #expect(hud.state == nil)
        #expect(!panel.isVisible)
    }

    @Test("Sharing preference updates each registered window and is applied before new windows open")
    func sharingAppliesToExistingAndNewWindows() {
        _ = NSApplication.shared
        let defaults = InMemoryUserDefaults()
        let privacy = ScreenSharingPrivacy(defaults: defaults)
        let camera = CameraLivePanelController()
        let hud = HotkeyHUDController(sharingPrivacy: privacy)

        func makeWindows() -> [NSWindow] {
            [
                MenuBarPanelController.makePanel(theme: .classic, sharingPrivacy: privacy),
                MenuBarPanelController.makePanel(theme: .liquidGlass, sharingPrivacy: privacy),
                MenuBarPanelController.makeBackdropWindow(frame: .zero, sharingPrivacy: privacy),
                camera.makePanel(sharingPrivacy: privacy),
                hud.makeWindow(),
            ]
        }

        let existing = makeWindows()
        #expect(existing.allSatisfy { $0.sharingType == .readOnly })
        privacy.setHidden(true)
        #expect(defaults.bool(forKey: ScreenSharingPrivacy.storageKey))
        #expect(existing.allSatisfy { $0.sharingType == .none })

        let createdWhileHidden = makeWindows()
        #expect(createdWhileHidden.allSatisfy { $0.sharingType == .none })
        privacy.setHidden(false)
        #expect(!defaults.bool(forKey: ScreenSharingPrivacy.storageKey))
        #expect((existing + createdWhileHidden).allSatisfy { $0.sharingType == .readOnly })
    }

    @Test("The Emoji shortcut passes through before device and search shortcuts")
    func emojiShortcutPassesThrough() {
        let emoji = PanelKeyRouter.Key(code: kVK_Space, command: true, control: true)
        #expect(PanelKeyRouter.beforeSearch(emoji, .init(hasFocusedDevice: true)) == .passThrough)
        #expect(PanelKeyRouter.beforeSearch(emoji, .init(isTextFieldFocused: true)) == .passThrough)
    }

    @Test("Panel hover yields to keyboard navigation until the panel receives mouse movement")
    func panelInputSwitchesBetweenKeyboardAndMouse() async throws {
        _ = NSApplication.shared
        let defaults = InMemoryUserDefaults()
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaults: defaults)
        try await store.waitForTestSnapshot()
        let devices = store.devices
        try #require(devices.count >= 2)
        let first = devices[0].id
        let second = devices[1].id
        let panel = MenuBarPanelController.makePanel(
            theme: .classic, sharingPrivacy: ScreenSharingPrivacy(defaults: defaults)
        )
        let moveFocus = PanelKeyRouter.afterSearch(.init(code: kVK_DownArrow), .init())
        #expect(moveFocus == .moveFocus(1))
        let moved = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))

        store.focusedDeviceId = first
        panel.input.record(moveFocus)
        #expect(panel.input.mode == .keyboard)
        panel.input.selectHoveredCard(second, store: store, search: nil)
        #expect(store.focusedDeviceId == first)

        panel.sendEvent(moved)
        #expect(panel.input.mode == .mouse)
        panel.input.selectHoveredCard(second, store: store, search: nil)
        #expect(store.focusedDeviceId == second)

        panel.input.record(moveFocus)
        #expect(panel.input.mode == .keyboard)
        panel.input.selectHoveredCard(first, store: store, search: nil)
        #expect(store.focusedDeviceId == second)
    }
}
