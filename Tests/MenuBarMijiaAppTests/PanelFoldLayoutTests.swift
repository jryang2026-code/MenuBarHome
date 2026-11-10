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
    @Test("The first device card sits right under the header and grouping capsule", arguments: [
        (AppLanguage.zhHans, false),
        (AppLanguage.en, false),
        (AppLanguage.zhHans, true),
        (AppLanguage.en, true),
    ])
    func firstDeviceCardIsAboveTheFold(language: AppLanguage, compact: Bool) async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        fixture.store.isCompactGridMode = compact
        let reading = try PanelFoldMeasure.reading(store: fixture.store, language: language)
        let cardTop = reading.cardTop
        #expect(cardTop <= 200, "\(language.rawValue) compact=\(compact): first device card top is \(cardTop)")
        #expect(reading.omnibarMinY == nil, "search stays folded behind the header's magnifier")
        let lesson = try #require(reading.lessonTop, "the getting-started row is in the list")
        #expect(lesson < cardTop, "the lesson row leads the device list")
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

        let reading = try PanelFoldMeasure.reading(store: fixture.store)
        let notice = try #require(reading.noticeTop, "the warning is on screen")
        let cardTop = reading.cardTop
        #expect(reading.lessonMinY == nil, "the checklist hides behind a blocked or security notice")
        #expect(notice < cardTop)
        #expect(notice < 140, "the warning is the first block under the header, at \(notice)")
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

        /// Distance from the top of the panel. Both edges share one global origin.
        var cardTop: CGFloat { cardMinY - panelMinY }
        var noticeTop: CGFloat? { noticeMinY.map { $0 - panelMinY } }
        var omnibarTop: CGFloat? { omnibarMinY.map { $0 - panelMinY } }
        var lessonTop: CGFloat? { lessonMinY.map { $0 - panelMinY } }
    }

    /// Card frames are published from `onAppear`, the same wait the resize test already uses.
    /// Measurements stay on a record this test owns. Other suites do not see it.
    ///
    /// Synchronous on purpose: `L10n.currentLanguage` is process-wide, so the switch and its
    /// restore must not span an await where another suite could render a snapshot in the other
    /// language.
    static func reading(store: HomeStore, language: AppLanguage = .zhHans) throws -> Reading {
        let previousLanguage = L10n.currentLanguage
        L10n.currentLanguage = language
        defer { L10n.currentLanguage = previousLanguage }

        let record = PanelFoldRecord()
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: ControlCenterPanel(store: store)
                .environment(\.panelFoldRecord, record)
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
        for _ in 0..<6 {
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            pumpMainRunLoop()
        }

        let light = try #require(store.devices.first { device in
            if case .light = device.kind { return true }
            return false
        })
        let cardMinY = try #require(record.cardTops[light.id], "the first light card publishes its frame")
        let panelMinY = try #require(record.panelMinY, "the panel publishes its top edge")
        return Reading(
            panelMinY: panelMinY,
            cardMinY: cardMinY,
            noticeMinY: record.systemNoticeMinY,
            omnibarMinY: record.omnibarMinY,
            lessonMinY: record.lessonRowMinY
        )
    }
}

/// `CFRunLoopRunInMode` is unavailable directly inside an async test.
private func pumpMainRunLoop() {
    CFRunLoopRunInMode(.defaultMode, 0.05, false)
}
