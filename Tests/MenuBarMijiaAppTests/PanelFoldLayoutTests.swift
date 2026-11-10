import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

extension PanelPresentationTests {
/// Layout checks for the 560 pt panel in both panel themes. This suite is separate from
/// `SnapshotTests` so the macOS CI job, which skips snapshot image comparison, still measures the
/// fold.
///
/// Both themes render in a 376 × 560 hosting view. Classic keeps the 321c067 geometry: the search
/// field stays on screen above the checklist, and the first device card stays above 200 pt. The
/// liquid-glass theme folds the search field behind the header's magnifier.
@MainActor
@Suite(.serialized)
struct PanelFoldLayoutTests {
    @Test("The first device card sits right under the header and grouping capsule", arguments: [
        (PanelTheme.classic, AppLanguage.zhHans, false),
        (PanelTheme.classic, AppLanguage.en, false),
        (PanelTheme.classic, AppLanguage.zhHans, true),
        (PanelTheme.classic, AppLanguage.en, true),
        (PanelTheme.liquidGlass, AppLanguage.zhHans, false),
        (PanelTheme.liquidGlass, AppLanguage.en, false),
        (PanelTheme.liquidGlass, AppLanguage.zhHans, true),
        (PanelTheme.liquidGlass, AppLanguage.en, true),
    ])
    func firstDeviceCardIsAboveTheFold(theme: PanelTheme, language: AppLanguage, compact: Bool) async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        fixture.store.isCompactGridMode = compact
        let reading = try PanelFoldMeasure.reading(theme: theme, store: fixture.store, language: language)
        let cardTop = reading.cardTop
        #expect(
            cardTop <= 200,
            "\(theme.rawValue) \(language.rawValue) compact=\(compact): first device card top is \(cardTop)"
        )
        #expect(reading.lessonMinY != nil, "the getting-started row is in the list")
        let lesson = try #require(reading.lessonTop)
        #expect(lesson < cardTop, "the lesson row leads the device list")
        switch theme {
        case .classic:
            #expect(reading.kindMinY == nil, "kind chips stay hidden until 全部 is tapped again")
            // 321c067 keeps the search field on screen; the lesson row scrolls under it.
            let omnibar = try #require(reading.omnibarTop, "the classic panel keeps the search field on screen")
            #expect(lesson > omnibar, "the lesson row scrolls under the search field")
        case .liquidGlass:
            #expect(reading.omnibarMinY == nil, "search stays folded behind the header's magnifier")
        }
    }

    @Test("A blocked or plaintext warning leads the panel and hides the checklist", arguments: [
        (PanelTheme.classic, "expired"),
        (PanelTheme.classic, "plaintext"),
        (PanelTheme.liquidGlass, "expired"),
        (PanelTheme.liquidGlass, "plaintext"),
    ])
    func warningLeadsThePanel(theme: PanelTheme, kind: String) async throws {
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

        let reading = try PanelFoldMeasure.reading(theme: theme, store: fixture.store)
        let notice = try #require(reading.noticeTop, "the warning is on screen")
        let cardTop = reading.cardTop
        #expect(reading.lessonMinY == nil, "the checklist hides behind a blocked or security notice")
        #expect(notice < cardTop)
        switch theme {
        case .classic:
            let omnibar = try #require(reading.omnibarTop, "the classic search field is on screen")
            #expect(notice < omnibar, "the warning sits above the search field")
            #expect(notice < 120, "the warning is the first block under the header, at \(notice)")
        case .liquidGlass:
            #expect(notice < 140, "the warning is the first block under the header, at \(notice)")
        }
    }
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
    /// Measurements stay on a record this test owns. Other suites do not see it.
    ///
    /// The language override is task-local and this function does not await, so the hosting
    /// view is measured on the same task that pinned the language.
    static func reading(theme: PanelTheme, store: HomeStore, language: AppLanguage = .zhHans) throws -> Reading {
        try L10n.$overrideLanguage.withValue(language) {
        let speech = SpeechInputController.shared
        let savedSpeech = (speech.isListening, speech.isHoldToTalk, speech.draft, speech.errorMessage)
        speech.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
        defer {
            speech.setPreviewState(
                isListening: savedSpeech.0,
                isHoldToTalk: savedSpeech.1,
                draft: savedSpeech.2,
                errorMessage: savedSpeech.3
            )
        }
        let record = PanelFoldRecord()
        _ = NSApplication.shared
        let root: AnyView
        switch theme {
        case .classic:
            root = AnyView(ClassicControlCenterPanel(store: store))
        case .liquidGlass:
            root = AnyView(ControlCenterPanel(store: store))
        }
        let hosting = NSHostingView(
            rootView: root
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
            lessonMinY: record.lessonRowMinY,
            kindMinY: record.kindRowMinY
        )
        }
    }
}

/// `CFRunLoopRunInMode` is unavailable directly inside an async test.
private func pumpMainRunLoop() {
    CFRunLoopRunInMode(.defaultMode, 0.05, false)
}
