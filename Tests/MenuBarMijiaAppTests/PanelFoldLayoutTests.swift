import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

/// Layout checks for the 560 pt panel. This suite is separate from `SnapshotTests` so the macOS
/// CI job, which skips snapshot image comparison, still measures the fold.
@MainActor
@Suite(.serialized)
struct PanelFoldLayoutTests {
    @Test("The default 560 pt panel keeps the first device card at or above 200 pt")
    func firstDeviceCardIsAboveTheFold() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        let reading = try await PanelFoldMeasure.reading(store: fixture.store)
        let cardTop = reading.cardTop
        #expect(cardTop <= 200, "first device card top is \(cardTop)")
        #expect(reading.kindMinY == nil, "kind chips stay hidden until 全部 is tapped again")
        #expect(reading.lessonMinY != nil, "the getting-started row is in the list")
        let lesson = try #require(reading.lessonTop)
        let omnibar = try #require(reading.omnibarTop)
        #expect(lesson > omnibar, "the lesson row scrolls under the search field")
    }

    @Test("A blocked or plaintext warning leads the panel and hides the checklist", arguments: [
        "expired", "plaintext"
    ])
    func warningLeadsThePanel(kind: String) async throws {
        let fixture: SnapshotFixture
        if kind == "expired" {
            fixture = try await SnapshotFixture(
                miSession: MiSession(
                    userId: "42",
                    cUserId: "c",
                    ssecurity: "c2VjcmV0",
                    serviceToken: "tok",
                    expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        } else {
            fixture = try await SnapshotFixture()
            fixture.store.haPlaintextPrompt = .asking("http://203.0.113.5:8123")
        }
        defer { fixture.restore() }

        let reading = try await PanelFoldMeasure.reading(store: fixture.store)
        let notice = try #require(reading.noticeTop, "the warning is on screen")
        let omnibar = try #require(reading.omnibarTop)
        let cardTop = reading.cardTop
        #expect(reading.lessonMinY == nil, "the checklist hides behind a blocked or security notice")
        #expect(notice < omnibar, "the warning sits above the search field")
        #expect(notice < cardTop)
        #expect(notice < 120, "the warning is the first block under the header, at \(notice)")
    }
}

@MainActor
enum PanelFoldMeasure {
    struct Reading {
        var panelMinY: CGFloat
        var cardMinY: CGFloat
        var noticeMinY: CGFloat?
        var omnibarMinY: CGFloat?
        var lessonMinY: CGFloat?
        var kindMinY: CGFloat?

        /// Distance from the top of the panel. Both edges share one global origin.
        var cardTop: CGFloat { cardMinY - panelMinY }
        var noticeTop: CGFloat? { noticeMinY.map { $0 - panelMinY } }
        var omnibarTop: CGFloat? { omnibarMinY.map { $0 - panelMinY } }
        var lessonTop: CGFloat? { lessonMinY.map { $0 - panelMinY } }
    }

    /// Card frames are published from `onAppear`, the same wait the resize test already uses.
    static func reading(store: HomeStore) async throws -> Reading {
        PanelFoldProbe.reset()
        LayoutUIState.shared.cardGlobalFrames.removeAll()
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: ControlCenterPanel(store: store)
                .environment(\.colorScheme, .light)
                .environment(\.reduceMotionOverride, true)
                .environment(\.reduceTransparencyOverride, true)
                .transaction { $0.disablesAnimations = true }
                .focusEffectDisabled()
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 560)
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
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        CFRunLoopRunInMode(.defaultMode, 0.05, false)

        let light = try #require(store.devices.first { device in
            if case .light = device.kind { return true }
            return false
        })
        let card = try #require(
            LayoutUIState.shared.cardGlobalFrames[light.id],
            "the first light card publishes its frame"
        )
        let panelMinY = try #require(PanelFoldProbe.panelMinY, "the panel publishes its top edge")
        return Reading(
            panelMinY: panelMinY,
            cardMinY: card.minY,
            noticeMinY: PanelFoldProbe.systemNoticeMinY,
            omnibarMinY: PanelFoldProbe.omnibarMinY,
            lessonMinY: PanelFoldProbe.lessonRowMinY,
            kindMinY: PanelFoldProbe.kindRowMinY
        )
    }
}
