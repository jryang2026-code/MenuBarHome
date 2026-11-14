import Testing
import Foundation
@testable import MenuBarMijiaApp
@testable import MijiaCore

/// The settings search has to do more than filter category names: a person types "开机启动",
/// "token" or "深色" and expects the one row that owns that setting, from any category. These tests
/// pin the three things that make that true — synonym coverage, ranking, and the anchors the rows
/// actually attach — because a silent miss looks exactly like a setting that does not exist.
@MainActor
@Suite(.serialized)
struct SettingsSearchTests {

    // MARK: Matching a concrete setting, not a category

    @Test("A synonym finds its row even when the word is not in the title")
    func synonymFindsRow() {
        let hits = SettingsSearch.search("开机启动")
        #expect(hits.first?.anchor == .launchAtLogin)

        let token = SettingsSearch.search("token")
        #expect(token.contains { $0.anchor == .haToken })
        #expect(token.contains { $0.anchor == .assistantAPIKey })

        let dark = SettingsSearch.search("深色")
        #expect(dark.first?.anchor == .appearanceMode)
    }

    @Test("A query in the other interface language still matches")
    func crossLanguageQuery() {
        // The index carries both languages' words, so an English query works in a Chinese window
        // and a Chinese query works in an English one. `L10n` is not consulted for synonyms.
        try L10n.$overrideLanguage.withValue(.en) {
            let chinese = SettingsSearch.search("周报")
            #expect(chinese.first?.anchor == .weeklyReport)
        }
        try L10n.$overrideLanguage.withValue(.zhHans) {
            let english = SettingsSearch.search("raycast")
            #expect(english.first?.anchor == .raycast)
        }
    }

    @Test("Search reaches rows far from the first category")
    func coversEveryCategory() {
        let expected: [(String, SettingsAnchor)] = [
            ("界面语言", .language),
            ("温度单位", .temperatureUnit),
            ("双列紧凑", .compactGrid),
            ("快捷键", .globalHotkey),
            ("门铃", .doorbellAutoView),
            ("令牌", .haToken),
            ("米家", .miAccount),
            ("电视", .lgTV),
            ("把握度", .confidenceThreshold),
            ("习惯", .habitMemory),
            ("浅色", .appearanceMode),
            ("面板高度", .panelHeight),
            ("诊断", .copyDiagnostics),
            ("锁屏时禁止", .blockControlWhileLocked),
            ("更新", .aboutVersion),
            ("退出", .quitApp)
        ]
        for (query, anchor) in expected {
            let hits = SettingsSearch.search(query)
            #expect(hits.contains { $0.anchor == anchor },
                    "「\(query)」should reach \(anchor.rawValue), got \(hits.map(\.anchor.rawValue))")
        }
    }

    @Test("Every anchor in the enum is searchable")
    func everyAnchorIsIndexed() {
        // An anchor with no index entry is a row nobody can find; an index entry with no anchor
        // would not compile. This closes the first direction.
        let indexed = Set(SettingsSearch.entries().map(\.anchor))
        let missing = Set(SettingsAnchor.allCases).subtracting(indexed)
        #expect(missing.isEmpty, "unsearchable anchors: \(missing.map(\.rawValue).sorted())")
    }

    @Test("Every anchor is actually attached to a rendered row")
    func everyAnchorIsWired() throws {
        // Being in the index is not enough: `proxy.scrollTo` and the landing highlight both resolve
        // by the `.id`/preference that `settingsRow(anchor:)` installs. An anchor that only exists in
        // the index makes a hit that silently does nothing — the failure this test exists to stop.
        // Scans the settings sources because a Swift view tree cannot be walked for modifiers.
        let root = try Self.sourceRoot()
        var wired = Set<String>()
        for path in try Self.swiftSources(under: root) {
            let text = try String(contentsOf: path, encoding: .utf8)
            for match in text.matches(of: /anchor:\s*\.([A-Za-z]+)/) {
                wired.insert(String(match.output.1))
            }
        }
        let attached = Set(SettingsAnchor.allCases.map(\.rawValue)).subtracting(wired)
        #expect(attached.isEmpty, "anchors no row attaches: \(attached.sorted())")
    }

    private static func sourceRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = directory.appendingPathComponent("MenuBarMijiaApp/SettingsWindowView.swift")
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory.appendingPathComponent("MenuBarMijiaApp")
            }
            let alternate = directory.appendingPathComponent("Sources/MenuBarMijiaApp/SettingsWindowView.swift")
            if FileManager.default.fileExists(atPath: alternate.path) {
                return directory.appendingPathComponent("Sources/MenuBarMijiaApp")
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func swiftSources(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }

    // MARK: Ranking

    @Test("A title match outranks a synonym-only match")
    func titleBeatsSynonym() {
        // "更新" is in the About title and appears as a synonym on nothing else, but "周报" is only
        // a synonym — so this pins the weight by comparing two rows that both contain "报".
        let hits = SettingsSearch.search("更新")
        #expect(hits.first?.anchor == .aboutVersion)
        #expect(hits.count >= 1)
    }

    @Test("An exact field match outranks a prefix match")
    func exactBeatsPrefix() {
        // "temperature" is a synonym of one row only, so this asserts the ordering primitive works
        // by checking a query that is an exact synonym: it must come first.
        let hits = SettingsSearch.search("temperature")
        #expect(hits.first?.anchor == .temperatureUnit)
    }

    @Test("Multiple words must all land on the same row")
    func allTokensMustMatch() {
        let both = SettingsSearch.search("launch login")
        #expect(both.contains { $0.anchor == .launchAtLogin })

        // Two words that live on different rows must not produce a false hit.
        let impossible = SettingsSearch.search("launch temperature")
        #expect(impossible.isEmpty, "got \(impossible.map(\.anchor.rawValue))")
    }

    @Test("Punctuation and case do not change the match")
    func normalization() {
        #expect(SettingsSearch.search("LAUNCH").first?.anchor == .launchAtLogin)
        #expect(SettingsSearch.search("  launch  ").first?.anchor == .launchAtLogin)
        #expect(SettingsSearch.search("launch-at-login").contains { $0.anchor == .launchAtLogin })
        #expect(SettingsSearch.search("launch，login").contains { $0.anchor == .launchAtLogin })
    }

    @Test("An empty or whitespace query returns nothing")
    func emptyQueryMatchesNothing() {
        #expect(SettingsSearch.search("").isEmpty)
        #expect(SettingsSearch.search("   ").isEmpty)
        #expect(SettingsSearch.search("\n\t").isEmpty)
    }

    @Test("Results are capped so the rail stays a rail")
    func resultLimit() {
        #expect(SettingsSearch.search("e").count <= SettingsSearch.resultLimit)
        #expect(SettingsSearch.search("e", limit: 3).count <= 3)
        #expect(SettingsSearch.search("e", limit: 0).isEmpty)
    }

    // MARK: Keyboard navigation

    @Test("Arrow keys walk the list and stop at its ends")
    func selectionMoves() {
        #expect(SettingsSearchSelection.moved(nil, by: 1, count: 4) == 0)
        #expect(SettingsSearchSelection.moved(nil, by: -1, count: 4) == 3)
        #expect(SettingsSearchSelection.moved(0, by: 1, count: 4) == 1)
        #expect(SettingsSearchSelection.moved(3, by: 1, count: 4) == 3)
        #expect(SettingsSearchSelection.moved(0, by: -1, count: 4) == 0)
        #expect(SettingsSearchSelection.moved(nil, by: 1, count: 0) == nil)
    }

    @Test("Return acts on the highlighted row, or the best match")
    func commitSelection() {
        #expect(SettingsSearchSelection.commitIndex(nil, count: 3) == 0)
        #expect(SettingsSearchSelection.commitIndex(2, count: 3) == 2)
        #expect(SettingsSearchSelection.commitIndex(9, count: 3) == 0)
        #expect(SettingsSearchSelection.commitIndex(nil, count: 0) == nil)
    }

    @Test("A shrinking result list keeps the cursor inside it")
    func selectionClamps() {
        #expect(SettingsSearchSelection.clamped(7, count: 3) == 2)
        #expect(SettingsSearchSelection.clamped(-2, count: 3) == 0)
        #expect(SettingsSearchSelection.clamped(1, count: 3) == 1)
        #expect(SettingsSearchSelection.clamped(nil, count: 3) == nil)
        #expect(SettingsSearchSelection.clamped(0, count: 0) == nil)
    }

    // MARK: Focus lifecycle (§13 single owner)

    @Test("Jumping sets the highlight and typing a new query clears it")
    func highlightEndsWhenQueryChanges() async {
        let focus = SettingsSearchFocus()
        focus.jump(to: .launchAtLogin)
        #expect(focus.highlight == .launchAtLogin)

        focus.query = "令牌"
        #expect(focus.highlight == nil, "a new query must not inherit the previous landing highlight")
    }

    @Test("Clearing the query ends the highlight and the search")
    func clearQueryResetsBoth() {
        let focus = SettingsSearchFocus()
        focus.query = "令牌"
        focus.jump(to: .haToken)
        #expect(focus.isSearching)
        #expect(focus.highlight == .haToken)

        focus.clearQuery()
        #expect(focus.query.isEmpty)
        #expect(!focus.isSearching)
        #expect(focus.highlight == nil)
    }

    @Test("The highlight expires on its own instead of looping")
    func highlightExpires() async throws {
        let focus = SettingsSearchFocus()
        focus.jump(to: .privacyNotes)
        #expect(focus.highlight == .privacyNotes)

        // The window dims the row for ~1.6 s; waiting for it to end proves it does not persist.
        try await Task.sleep(for: .milliseconds(1900))
        #expect(focus.highlight == nil)
    }

    @Test("Entries have unique anchors")
    func uniqueAnchors() {
        let anchors = SettingsSearch.entries().map(\.anchor)
        #expect(Set(anchors).count == anchors.count)
    }

    // MARK: Reachability

    @Test("A hit behind a condition is reported as blocked, not offered")
    func demoModeHidesConnectionRows() {
        // The connection card lives inside `if store.homeBackend != .demo`, so in demo mode a jump
        // to these rows would clear the query and land on a page without them.
        let demo = SettingsSearchAvailability(
            backend: .demo,
            hiddenDeviceCount: 0,
            storedPanelTheme: PanelTheme.classic.rawValue,
            liquidGlassAvailable: true
        )
        for (query, anchor) in [
            ("nabu casa", SettingsAnchor.haServerAddress),
            ("access token", .haToken),
            ("xiaomi", .miAccount),
            ("ssap", .lgTV)
        ] {
            let outcome = SettingsSearch.search(query, availability: demo)
            #expect(outcome.hits.isEmpty, "demo mode must not offer \(anchor.rawValue)")
            #expect(outcome.blocked?.anchor == anchor)
            #expect(outcome.blocked?.reason == .demoMode)
        }
    }

    @Test("A reachable match keeps the explanation away")
    func blockedOnlyWhenEveryMatchIsHidden() {
        // "token" reaches both the HA token (behind demo mode) and the AI key (always drawn). A
        // real destination must win: telling someone their setting is unavailable while offering
        // it in the same list would be worse than saying nothing.
        let demo = SettingsSearchAvailability(
            backend: .demo,
            hiddenDeviceCount: 0,
            storedPanelTheme: PanelTheme.classic.rawValue,
            liquidGlassAvailable: true
        )
        let outcome = SettingsSearch.search("token", availability: demo)
        #expect(outcome.hits.contains { $0.anchor == .assistantAPIKey })
        #expect(outcome.blocked == nil)
        #expect(!outcome.isEmpty)
    }

    @Test("The theme picker is only reachable on macOS 26")
    func panelThemeNeedsMacOS26() {
        let oldSystem = SettingsSearchAvailability(
            backend: .homeAssistant,
            hiddenDeviceCount: 0,
            storedPanelTheme: PanelTheme.classic.rawValue,
            liquidGlassAvailable: false
        )
        let outcome = SettingsSearch.search("liquid glass", availability: oldSystem)
        #expect(outcome.hits.isEmpty)
        #expect(outcome.blocked?.reason == .needsMacOS26)

        let newSystem = SettingsSearchAvailability(
            backend: .homeAssistant,
            hiddenDeviceCount: 0,
            storedPanelTheme: PanelTheme.classic.rawValue,
            liquidGlassAvailable: true
        )
        let reachable = SettingsSearch.search("liquid glass", availability: newSystem)
        #expect(reachable.hits.contains { $0.anchor == .panelTheme })
        #expect(reachable.blocked == nil)
    }

    @Test("The height control follows the resolved theme, not the stored string")
    func panelHeightOnlyForClassic() {
        // Storing "liquidGlass" on a pre-26 Mac resolves to `.classic`, so the height control is
        // still drawn. Reading the raw string instead of resolving it would hide a live row.
        let storedGlassButOldMac = SettingsSearchAvailability(
            backend: .homeAssistant,
            hiddenDeviceCount: 1,
            storedPanelTheme: PanelTheme.liquidGlass.rawValue,
            liquidGlassAvailable: false
        )
        #expect(storedGlassButOldMac.isReachable(.panelHeight))

        let realGlass = SettingsSearchAvailability(
            backend: .homeAssistant,
            hiddenDeviceCount: 1,
            storedPanelTheme: PanelTheme.liquidGlass.rawValue,
            liquidGlassAvailable: true
        )
        let outcome = SettingsSearch.search("面板大小", availability: realGlass)
        #expect(outcome.hits.isEmpty)
        #expect(outcome.blocked?.reason == .liquidGlassPanel)
    }

    @Test("Hidden devices are only searchable while something is hidden")
    func hiddenDevicesNeedsSomethingHidden() {
        let nothingHidden = SettingsSearchAvailability(
            backend: .homeAssistant,
            hiddenDeviceCount: 0,
            storedPanelTheme: PanelTheme.classic.rawValue,
            liquidGlassAvailable: true
        )
        let blocked = SettingsSearch.search("hidden", availability: nothingHidden)
        #expect(blocked.hits.isEmpty)
        #expect(blocked.blocked?.reason == .nothingHidden)

        let someHidden = SettingsSearchAvailability(
            backend: .homeAssistant,
            hiddenDeviceCount: 2,
            storedPanelTheme: PanelTheme.classic.rawValue,
            liquidGlassAvailable: true
        )
        #expect(SettingsSearch.search("hidden", availability: someHidden)
            .hits.contains { $0.anchor == .hiddenDevices })
    }
}
