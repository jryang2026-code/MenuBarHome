import AppKit
import Testing
@testable import MenuBarMijiaApp

/// Pure placement table for `MenuBarPanelController`: a visible menu bar must keep the exact legacy
/// geometry, while a retracted bar and a notch must move the panel off the broken anchor.
@MainActor
struct MenuBarPanelPlacementTests {
    private enum Fixture {
        static let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        static let visible = NSRect(x: 0, y: 0, width: 1512, height: 957)
        static let classicSize = NSSize(width: 376, height: 520)
        static let liquidSize = NSSize(width: 380, height: 560)
        /// The strips beside a 192 pt notch, as `NSScreen` reports them in the menu-bar band.
        static let notchLeft = NSRect(x: 0, y: 957, width: 660, height: 25)
        static let notchRight = NSRect(x: 852, y: 957, width: 660, height: 25)
    }

    private func input(
        visible: NSRect = Fixture.visible,
        left: NSRect = .zero,
        right: NSRect = .zero,
        anchor: NSRect?,
        size: NSSize,
        menuBarHidden: Bool = false
    ) -> MenuBarPanelController.PanelPlacementInput {
        MenuBarPanelController.PanelPlacementInput(
            screenFrame: Fixture.screen,
            visibleFrame: visible,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right,
            anchor: anchor,
            size: size,
            menuBarHidden: menuBarHidden
        )
    }

    // MARK: - The visible menu bar keeps today's geometry

    @Test("A visible menu bar keeps the classic card exactly where the legacy formula put it")
    func classicMatchesLegacyWithVisibleMenuBar() {
        let anchors: [NSRect?] = [
            nil,
            NSRect(x: 1_400, y: 957, width: 24, height: 24),
            NSRect(x: 744, y: 957, width: 24, height: 24),
            NSRect(x: 2, y: 957, width: 24, height: 24),
            NSRect(x: 300, y: 700, width: 24, height: 24),
        ]
        for anchor in anchors {
            let placed = MenuBarPanelController.placement(
                theme: .classic,
                input: input(anchor: anchor, size: Fixture.classicSize)
            )
            #expect(
                placed.frame == legacyClassicFrame(size: Fixture.classicSize, visible: Fixture.visible, anchor: anchor),
                "anchor \(String(describing: anchor))"
            )
        }
    }

    @Test("A visible menu bar keeps the pilot column exactly where the legacy formula put it")
    func liquidMatchesLegacyWithVisibleMenuBar() {
        let anchors: [NSRect?] = [
            nil,
            NSRect(x: 1_400, y: 957, width: 24, height: 24),
            NSRect(x: 744, y: 957, width: 24, height: 24),
            NSRect(x: 300, y: 700, width: 24, height: 24),
        ]
        for anchor in anchors {
            let placed = MenuBarPanelController.placement(
                theme: .liquidGlass,
                input: input(anchor: anchor, size: Fixture.liquidSize)
            )
            #expect(
                placed.frame == legacyLiquidFrame(size: Fixture.liquidSize, visible: Fixture.visible, anchor: anchor),
                "anchor \(String(describing: anchor))"
            )
        }
    }

    // MARK: - Retracted menu bar

    @Test("A retracted menu bar pins the classic card to the usable top instead of the off-screen item")
    func classicHiddenMenuBarPinsToVisibleTop() {
        // Auto-hide leaves no reserved band, and AppKit parks the item window above the display.
        let staleAnchor = NSRect(x: 700, y: 990, width: 24, height: 24)
        let placed = MenuBarPanelController.placement(
            theme: .classic,
            input: input(visible: Fixture.screen, anchor: staleAnchor, size: Fixture.classicSize, menuBarHidden: true)
        )
        #expect(placed.frame.maxY == Fixture.screen.maxY - 6)
        #expect(placed.frame.maxY <= Fixture.screen.maxY)
        #expect(placed.frame.minY >= Fixture.screen.minY + 8)
        #expect(placed.frame.minX == 524, "the hidden bar keeps the item's horizontal anchor: 712 - 188")
    }

    @Test("A retracted menu bar pins the pilot column to the usable top as well")
    func liquidHiddenMenuBarPinsToVisibleTop() {
        let staleAnchor = NSRect(x: 700, y: 990, width: 24, height: 24)
        let placed = MenuBarPanelController.placement(
            theme: .liquidGlass,
            input: input(visible: Fixture.screen, anchor: staleAnchor, size: Fixture.liquidSize, menuBarHidden: true)
        )
        #expect(placed.frame.maxY == Fixture.screen.maxY - 6)
        #expect(placed.frame.maxY <= Fixture.screen.maxY)
        #expect(placed.frame.maxX == Fixture.screen.maxX - 16)
    }

    @Test("Menu-bar retraction covers hide, auto-hide, and a visible frame that reaches the display top")
    func menuBarRetractionDetection() {
        let hidden = MenuBarPanelController.menuBarIsHidden(
            systemOptions: [.hideMenuBar],
            menuBarVisible: true,
            screenFrame: Fixture.screen,
            visibleFrame: Fixture.visible
        )
        #expect(hidden, "a hidden bar counts even if the menu bar reports itself visible")

        let visibleBar = MenuBarPanelController.menuBarIsHidden(
            systemOptions: [],
            menuBarVisible: true,
            screenFrame: Fixture.screen,
            visibleFrame: Fixture.visible
        )
        #expect(!visibleBar)

        let autoHidden = MenuBarPanelController.menuBarIsHidden(
            systemOptions: [.autoHideMenuBar],
            menuBarVisible: false,
            screenFrame: Fixture.screen,
            visibleFrame: Fixture.screen
        )
        #expect(autoHidden)

        let autoHideRevealed = MenuBarPanelController.menuBarIsHidden(
            systemOptions: [.autoHideMenuBar],
            menuBarVisible: true,
            screenFrame: Fixture.screen,
            visibleFrame: Fixture.screen
        )
        #expect(!autoHideRevealed, "a temporarily revealed bar still anchors the panel")

        let fullHeightVisibleFrame = MenuBarPanelController.menuBarIsHidden(
            systemOptions: [],
            menuBarVisible: false,
            screenFrame: Fixture.screen,
            visibleFrame: Fixture.screen
        )
        #expect(fullHeightVisibleFrame)

        let reservedBand = MenuBarPanelController.menuBarIsHidden(
            systemOptions: [],
            menuBarVisible: false,
            screenFrame: Fixture.screen,
            visibleFrame: Fixture.visible
        )
        #expect(!reservedBand, "a reserved menu-bar band means the item has a real on-screen anchor")
    }

    // MARK: - Notch

    @Test("An item hidden by the notch opens the card at the trailing edge")
    func classicClearsNotchForHiddenItem() {
        let anchor = NSRect(x: 744, y: 957, width: 24, height: 24)
        let placed = MenuBarPanelController.placement(
            theme: .classic,
            input: input(left: Fixture.notchLeft, right: Fixture.notchRight, anchor: anchor, size: Fixture.classicSize)
        )
        #expect(placed.frame.minX >= Fixture.notchRight.minX, "the card starts right of the notch")
        #expect(placed.frame.maxX == Fixture.visible.maxX - 8)
    }

    @Test("A missing item still clears the notch instead of centring under it")
    func classicClearsNotchWithoutAnchor() {
        let placed = MenuBarPanelController.placement(
            theme: .classic,
            input: input(left: Fixture.notchLeft, right: Fixture.notchRight, anchor: nil, size: Fixture.classicSize)
        )
        #expect(placed.frame.minX >= Fixture.notchRight.minX)
    }

    @Test("A visible item beside the notch keeps its centred card, even when the card reaches the notch column")
    func classicKeepsCentredCardBesideNotch() {
        // The item is visible left of the housing; the 376 pt card spans 424...800 and crosses the
        // notch column, but it hangs below the menu-bar band, so it must not jump to the trailing edge.
        let anchor = NSRect(x: 600, y: 957, width: 24, height: 24)
        let placed = MenuBarPanelController.placement(
            theme: .classic,
            input: input(left: Fixture.notchLeft, right: Fixture.notchRight, anchor: anchor, size: Fixture.classicSize)
        )
        #expect(placed.frame.minX == 424, "612 - 188")
        #expect(placed.frame.maxX > Fixture.notchLeft.maxX, "the card spans into the notch column")
        #expect(placed.frame.minX < Fixture.notchRight.minX)
    }

    @Test("A card already clear of the notch keeps its centred position")
    func classicKeepsClearOfNotch() {
        let anchor = NSRect(x: 1_200, y: 957, width: 24, height: 24)
        let placed = MenuBarPanelController.placement(
            theme: .classic,
            input: input(left: Fixture.notchLeft, right: Fixture.notchRight, anchor: anchor, size: Fixture.classicSize)
        )
        #expect(placed.frame.minX == 1_024, "1 212 - 188")
        #expect(placed.frame.minX > Fixture.notchRight.minX)
    }

    @Test("The right-aligned pilot column is unchanged by the notch rule")
    func liquidKeepsTrailingEdgeBesideNotch() {
        let anchor = NSRect(x: 744, y: 957, width: 24, height: 24)
        let placed = MenuBarPanelController.placement(
            theme: .liquidGlass,
            input: input(left: Fixture.notchLeft, right: Fixture.notchRight, anchor: anchor, size: Fixture.liquidSize)
        )
        #expect(placed.frame.maxX == Fixture.visible.maxX - 16)
        #expect(placed.frame.minX > Fixture.notchRight.minX)
    }

    @Test("Displays without auxiliary areas never apply the notch rule")
    func flatDisplayIgnoresNotchRule() {
        let anchor = NSRect(x: 744, y: 957, width: 24, height: 24)
        let placed = MenuBarPanelController.placement(
            theme: .classic,
            input: input(anchor: anchor, size: Fixture.classicSize)
        )
        #expect(placed.frame.minX == 568, "756 - 188")
    }

    // MARK: - Screen resolution

    @Test("The status screen follows the pointer, then the first screen, never the keyboard-focus screen")
    func statusScreenFallbackOrder() throws {
        let screens = NSScreen.screens
        try #require(!screens.isEmpty)
        let pointed = try #require(screens.last)
        let point = NSPoint(x: pointed.frame.midX, y: pointed.frame.midY)
        #expect(MenuBarPanelController.screen(hosting: nil, mouseLocation: point, screens: screens) === pointed)

        let offScreen = NSPoint(x: -50_000, y: -50_000)
        #expect(MenuBarPanelController.screen(hosting: nil, mouseLocation: offScreen, screens: screens) === screens.first)
        #expect(MenuBarPanelController.screen(hosting: nil, mouseLocation: point, screens: []) == nil)
    }

    // MARK: - Legacy reference implementations

    private func legacyClassicFrame(size: NSSize, visible: NSRect, anchor: NSRect?) -> NSRect {
        let width = min(size.width, visible.width - 16)
        let height = min(size.height, visible.height - 16)
        var x = (anchor?.midX ?? visible.midX) - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let top = anchor?.minY ?? visible.maxY
        let y = max(top - height - 6, visible.minY + 8)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    private func legacyLiquidFrame(size: NSSize, visible: NSRect, anchor: NSRect?) -> NSRect {
        let maxUsableWidth = max(1, visible.width - 8 - 16)
        let width = min(size.width, maxUsableWidth)
        let x = max(visible.minX + 8, visible.maxX - width - 16)
        let bottom = visible.minY + 8
        let anchorTop = anchor?.minY ?? visible.maxY
        let minTopClearance = min(MenuBarPanelController.pilotMinHeight, max(0, visible.height - 6 - 8))
        let top = (anchorTop >= bottom + minTopClearance && anchorTop <= visible.maxY + 1 ? anchorTop : visible.maxY) - 6
        let height = MenuBarPanelController.clampAdaptiveHeight(size.height, availableHeight: max(0, top - bottom))
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width.rounded(), height: height.rounded())
    }
}
