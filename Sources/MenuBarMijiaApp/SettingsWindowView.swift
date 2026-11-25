import SwiftUI
import AppKit
import MijiaCore

// MARK: - Settings Window (#42)

/// The ⌘, window, laid out like System Settings: a vibrancy sidebar of categories on the left, one
/// pane of cards on the right, and a search field that reaches individual rows.
///
/// Everything that used to live in the menu-bar popover's long form is here so it survives switching
/// to the browser to copy a token (audit #42). The sidebar replaced the old capsule rail: six
/// categories no longer fit comfortably across the top of a 740 pt window once each carries a
/// coloured tile, and a vertical rail also leaves room for search results to appear in place.
@MainActor
private enum SettingsSearchMemoCache {
    struct Key: Equatable {
        let query: String
        let availability: SettingsSearchAvailability
        let language: AppLanguage
    }

    private static var lastKey: Key?
    private static var lastOutcome = SettingsSearchOutcome()

    static func search(
        query: String,
        availability: SettingsSearchAvailability,
        language: AppLanguage
    ) -> SettingsSearchOutcome {
        let key = Key(query: query, availability: availability, language: language)
        if lastKey == key {
            return lastOutcome
        }
        let outcome = SettingsSearch.search(query, availability: availability)
        lastKey = key
        lastOutcome = outcome
        return outcome
    }
}

enum SettingsTopUpdateBanner {
    enum Prompt: Equatable {
        case release(AppRelease, readyToRelaunch: Bool)
        case failure(AppUpdateFailure)
    }

    static func showsSidebarBadge(for updateState: AppUpdateState) -> Bool {
        updateState.badgeRelease != nil || updateState.isFailure
    }

    static func prompt(for updateState: AppUpdateState, activeTab: SettingsTab) -> Prompt? {
        guard activeTab.canonicalTab != .about else { return nil }
        if let release = updateState.badgeRelease {
            return .release(release, readyToRelaunch: updateState.isReadyToRelaunch)
        }
        if case .failed(let failure) = updateState {
            return .failure(failure)
        }
        return nil
    }

    static func releaseToShow(updateState: AppUpdateState, activeTab: SettingsTab) -> AppRelease? {
        guard activeTab.canonicalTab != .about else { return nil }
        return updateState.badgeRelease
    }

    static var actionTitle: String {
        L10n.tr("前往查看", "View Update")
    }

    static func actionTitle(for _: AppRelease, updateState _: AppUpdateState) -> String {
        actionTitle
    }

    static func failureHeadline(for failure: AppUpdateFailure) -> String {
        failure.release == nil
            ? L10n.tr("更新检查失败", "Update Check Failed")
            : L10n.tr("软件更新失败", "Software Update Failed")
    }
}

public struct SettingsWindowView: View {
    public let store: HomeStore
    @State private var tab: SettingsTab = .general
    @State private var advancedDisplay = GeneralSettingsDisclosure.State()
    @State private var connectionAdvancedDisclosure = ConnectionSettingsDisclosure.State()
    @State private var lgWakeDisclosure = LGWebOSSettingsSaveGuard.WakeDisclosureState()
    @State private var safetyDisclosure = SafetySettingsDisclosure.State()
    @State private var aboutDisclosure = AboutSettingsDisclosure.State()
    @State private var focus = SettingsSearchFocus()
    @State private var unsaved = SettingsUnsavedChanges()
    @State private var highlightedResult: Int?
    /// The ⌘, window is a separate scene, so it must apply the app's appearance itself.
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    /// The height control lives behind the resolved theme, so the window reads the same stored value
    /// the general pane does and resolves it identically.
    @AppStorage(PanelTheme.storageKey) private var panelThemeRaw: String = PanelTheme.defaultValue.rawValue
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    public init(store: HomeStore) {
        self.store = store
    }

    init(
        store: HomeStore,
        selectedTab: SettingsTab,
        safetyDisclosure: SafetySettingsDisclosure.State = .init(),
        aboutDisclosure: AboutSettingsDisclosure.State = .init()
    ) {
        self.store = store
        _tab = State(initialValue: selectedTab.canonicalTab)
        var initialDisclosure = GeneralSettingsDisclosure.State()
        initialDisclosure.expandIfNeeded(forRequestedTab: selectedTab)
        _advancedDisplay = State(initialValue: initialDisclosure)
        _safetyDisclosure = State(initialValue: safetyDisclosure)
        _aboutDisclosure = State(initialValue: aboutDisclosure)
    }

    /// Which rows this window is actually drawing, so search never offers a row that is not there.
    private var searchAvailability: SettingsSearchAvailability {
        SettingsSearchAvailability(
            backend: store.homeBackend,
            hiddenDeviceCount: store.hiddenDevices.count,
            storedPanelTheme: panelThemeRaw,
            liquidGlassAvailable: PanelTheme.isLiquidGlassAvailable,
            hasLocalNetworkBlock: !store.effectiveLocalNetworkBlocks.isEmpty
        )
    }

    private var outcome: SettingsSearchOutcome {
        focus.isSearching
            ? SettingsSearchMemoCache.search(
                query: focus.query,
                availability: searchAvailability,
                language: store.effectiveLanguage
            )
            : SettingsSearchOutcome()
    }

    private var hits: [SettingsSearchHit] { outcome.hits }

    public var body: some View {
        let _ = store.effectiveLanguage
        let opener = SettingsWindowOpener.shared
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                SettingsSidebar(
                    selection: guardedTab,
                    isSearching: focus.isSearching,
                    searchField: AnyView(searchField),
                    hasUpdateBadge: SettingsTopUpdateBanner.showsSidebarBadge(for: store.updateState),
                    onSelectCategory: selectCategory
                )
                Divider()
                detailPane
            }

            // Toasts are rendered by the panel; surface them here too while the panel is closed.
            if let toast = store.toastNotice {
                NoticeToastBanner(
                    notice: toast,
                    onAction: {
                        guard let action = toast.action else { return }
                        ToastNoticeActions.perform(action, store: store)
                    },
                    onDismiss: { store.dismissToast() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .adaptiveGlass(in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        .frame(minWidth: 740, idealWidth: 820, minHeight: 560, idealHeight: 660)
        .font(.system(size: DesignTokens.TypeSize.body))
        .controlSize(.regular)
        .environment(\.settingsSearchFocus, focus)
        .environment(\.settingsUnsavedChanges, unsaved)
        .background(WindowCloseGuard {
            // Save, Discard or Cancel; a save that fails keeps the window open (#148).
            unsaved.resolveBeforeLeaving(allowCancel: true)
        })
        .animation(AppleMotion.resolve(.pressFeedback, reduceMotion: reduceMotion), value: store.toastNotice)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        // Errors shown while the window is open still reach the diagnostics ring buffer (#45).
        .onChange(of: store.toastNotice?.id) { _, _ in
            AppDiagnosticsLog.shared.record(store.toastNotice)
        }
        .onChange(of: focus.query) { _, _ in
            // Start on the best match, which is exactly what Return commits. Leaving it nil would
            // draw no highlighted row while Return still acted on the first one.
            highlightedResult = SettingsSearchSelection.clamped(0, count: hits.count)
        }
        .onChange(of: tab) { _, newTab in
            // A jump changes the tab too; it only abandons its highlight by leaving the pane that
            // holds the row. Leaving search itself is `selectCategory`'s job: `onChange` does not
            // fire when the clicked category is already selected, which is how a query used to
            // survive a click on the category already on screen.
            if let highlight = focus.highlight, destinationTab(for: highlight) != newTab {
                focus.endHighlight()
            }
        }
        .onAppear {
            consumeOpenerRequestIfNeeded(opener)
        }
        .onChange(of: opener.requestedTab) { _, _ in
            consumeOpenerRequestIfNeeded(opener)
        }
        .onChange(of: opener.requestedAnchor) { _, _ in
            consumeOpenerRequestIfNeeded(opener)
        }
        .task {
            await store.checkForUpdatesIfNeeded()
        }
    }

    // MARK: Search

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSearchField(
                text: Binding(get: { focus.query }, set: { focus.query = $0 }),
                onSubmit: commitSearch,
                onMove: moveSearch,
                onCancel: clearSearch
            )
            if focus.isSearching {
                SettingsSearchResults(
                    hits: hits,
                    selection: highlightedResult,
                    blocked: outcome.blocked
                ) { hit in
                    jump(to: hit)
                }
                .padding(.top, 6)
            }
        }
    }

    private func moveSearch(_ delta: Int) {
        highlightedResult = SettingsSearchSelection.clamped(
            SettingsSearchSelection.moved(highlightedResult, by: delta, count: hits.count),
            count: hits.count
        )
    }

    private func commitSearch() {
        let index = SettingsSearchSelection.commitIndex(highlightedResult, count: hits.count)
        guard let index else { return }
        jump(to: hits[index])
    }

    private func clearSearch() {
        focus.clearQuery()
        highlightedResult = nil
    }

    private func consumeOpenerRequestIfNeeded(_ opener: SettingsWindowOpener) {
        if let requestedAnchor = opener.requestedAnchor {
            opener.requestedTab = nil
            opener.requestedAnchor = nil
            jump(toAnchor: requestedAnchor)
            return
        }
        if let requested = opener.requestedTab {
            opener.requestedTab = nil
            // A panel button asking for a pane is a category choice like a sidebar click, so it
            // leaves search too; otherwise the result list keeps covering the rail.
            selectCategory(requested)
        }
    }

    /// A click on a category in the rail. It leaves search *here*, not through `onChange(of: tab)`:
    /// clicking the category already on screen does not change `selection`, so the callback was never
    /// reached and a live query kept covering the rail with no selected row in sight.
    private func selectCategory(_ category: SettingsTab) {
        focus.clearQuery()
        highlightedResult = nil
        let destination = category.canonicalTab
        guard leavesTabSafely(for: destination) else { return }
        advancedDisplay.expandIfNeeded(forRequestedTab: category)
        tab = destination
    }

    /// Switching pages drops the page's drafts, so unsaved edits are resolved first (#148).
    private func leavesTabSafely(for destination: SettingsTab) -> Bool {
        guard destination != tab else { return true }
        return unsaved.resolveBeforeLeaving(allowCancel: true)
    }

    /// The rail writes its selection into this binding and then calls `onSelectCategory` for the same
    /// click. Only the second path resolves unsaved edits and changes `tab`, so one click asks once and
    /// a Cancel or a failed save leaves the page as it was (#148).
    private var guardedTab: Binding<SettingsTab> {
        Binding(get: { tab.canonicalTab }, set: { _ in })
    }

    private func destinationTab(for anchor: SettingsAnchor) -> SettingsTab {
        if anchor == .setupGuide && !store.hasCompletedOnboarding {
            return .general
        }
        return anchor.tab.canonicalTab
    }

    private func expandDisclosures(for anchor: SettingsAnchor) {
        advancedDisplay.expandIfNeeded(forHighlight: anchor)
        connectionAdvancedDisclosure.expandForHighlightIfNeeded(anchor)
        lgWakeDisclosure.expandForHighlightIfNeeded(anchor)
        safetyDisclosure.expandForHighlightIfNeeded(anchor)
        aboutDisclosure.expandForHighlightIfNeeded(anchor)
    }

    private func jump(toAnchor anchor: SettingsAnchor) {
        // Order matters. `clearQuery()` hides the result list and ends any previous highlight, so
        // the landing highlight has to be requested *after* it; setting it first would be wiped by
        // the query change and the jump would arrive with nothing to scroll to or point at.
        focus.clearQuery()
        highlightedResult = nil
        let destination = destinationTab(for: anchor)
        guard leavesTabSafely(for: destination) else { return }
        expandDisclosures(for: anchor)
        tab = destination
        focus.jump(to: anchor)
    }

    private func jump(to hit: SettingsSearchHit) {
        jump(toAnchor: hit.anchor)
    }

    private func jumpToSoftwareUpdate() {
        jump(toAnchor: .softwareUpdate)
    }

    // MARK: Detail

    private func scrollToAnchor(_ anchor: SettingsAnchor, using proxy: ScrollViewProxy) {
        // No animation under Reduce Motion, and none at all would make a long page jump
        // feel like the window lost its place.
        if reduceMotion {
            proxy.scrollTo(anchor, anchor: .center)
        } else {
            withAnimation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
    }

    private var detailPane: some View {
        ScrollViewReader { proxy in
            // The pane has to scroll: it holds six cards plus their explanatory lines, and
            // `proxy.scrollTo` below is what a search hit lands on. Without this `ScrollView` a
            // jump would silently do nothing and the lower cards would be unreachable.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DesignTokens.Settings.cardSpacing) {
                    if let prompt = SettingsTopUpdateBanner.prompt(
                        for: store.updateState,
                        activeTab: tab
                    ) {
                        topUpdatePromptBanner(prompt)
                    }
                    SettingsPaneHeader(tab: tab.canonicalTab, subtitle: tab.canonicalTab.paneSubtitle)
                    settingsPage
                }
                .padding(.horizontal, DesignTokens.Settings.contentInset)
                .padding(.vertical, 16)
                .frame(maxWidth: DesignTokens.Settings.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .coordinateSpace(name: SettingsScrollSpace.name)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
            .onChange(of: focus.generation) { _, targetGeneration in
                guard let anchor = focus.highlight else { return }
                let destination = destinationTab(for: anchor)
                if tab.canonicalTab != destination {
                    guard leavesTabSafely(for: destination) else {
                        focus.endHighlight()
                        return
                    }
                    tab = destination
                }
                expandDisclosures(for: anchor)
                scrollToAnchor(anchor, using: proxy)
                // Cross-tab jumps and newly expanded disclosures mount their `.id(anchor)` row
                // asynchronously after state changes, so re-scroll once the layout settles.
                Task { @MainActor in
                    await Task.yield()
                    guard focus.generation == targetGeneration, focus.highlight == anchor else { return }
                    scrollToAnchor(anchor, using: proxy)
                    try? await Task.sleep(for: .milliseconds(40))
                    guard focus.generation == targetGeneration, focus.highlight == anchor else { return }
                    scrollToAnchor(anchor, using: proxy)
                }
            }
        }
    }

    private func topUpdatePromptBanner(_ prompt: SettingsTopUpdateBanner.Prompt) -> some View {
        let isFailure: Bool = {
            if case .failure = prompt { return true }
            return false
        }()
        return HStack(spacing: 10) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                .foregroundStyle(isFailure ? Color.orange : Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                switch prompt {
                case .release(let release, let readyToRelaunch):
                    Text(L10n.tr("发现新版本 v\(release.version)", "New version v\(release.version) available"))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    if readyToRelaunch {
                        Text(L10n.tr("更新已就绪，重启后生效。", "Ready to install — relaunch to finish updating."))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                case .failure(let failure):
                    Text(SettingsTopUpdateBanner.failureHeadline(for: failure))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    Text(failure.message)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(SettingsTopUpdateBanner.actionTitle) {
                jumpToSoftwareUpdate()
            }
            .buttonStyle(PillActionButtonStyle(isSelected: !isFailure, tintColor: .accentColor))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(SettingsCardBackground())
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch tab.canonicalTab {
        case .general, .appearance:
            GeneralSettingsTab(store: store, advancedDisplay: $advancedDisplay)
        case .connection:
            ConnectionSettingsTab(
                store: store,
                advancedConnections: $connectionAdvancedDisclosure,
                lgWakeDisclosure: $lgWakeDisclosure
            )
        case .assistant:
            AssistantSettingsTab(store: store)
        case .privacy:
            PrivacySettingsTab(store: store, disclosure: $safetyDisclosure)
        case .about:
            AboutSettingsTab(store: store, disclosure: $aboutDisclosure)
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case connection
    case assistant
    case appearance
    case privacy
    case about

    static var allCases: [SettingsTab] {
        [.general, .connection, .assistant, .privacy, .about]
    }

    var canonicalTab: SettingsTab {
        self == .appearance ? .general : self
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tr("常规", "General")
        case .connection: return L10n.tr("家居连接", "Connections")
        case .assistant: return L10n.tr("AI 助手", "AI Assistant")
        case .appearance: return L10n.tr("外观", "Appearance")
        case .privacy: return L10n.tr("安全与提醒", "Safety & Alerts")
        case .about: return L10n.tr("关于与诊断", "About & Diagnostics")
        }
    }
}

// MARK: - Shared Building Blocks

/// One grouped card: a secondary-coloured caption above an opaque rounded surface, which is how
/// System Settings separates a pane into readable groups.
///
/// The group's caption sits *outside* the card, so the card itself holds only rows. That keeps a
/// section's title from competing with the pane title at the top of the window, and it means the
/// hairline dividers between rows line up with nothing but rows.
struct SettingsSection<Content: View>: View {
    let title: String
    /// Set when the whole card is one search destination (a group whose individual rows are
    /// generated, such as the sensor-alert switches). Rows that are anchored one by one leave it nil.
    let anchor: SettingsAnchor?
    private let content: Content

    init(title: String, anchor: SettingsAnchor? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.anchor = anchor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(DesignTokens.secondaryText)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DesignTokens.Settings.rowSpacing) {
                content
            }
            .font(.system(size: DesignTokens.TypeSize.body))
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsCardBackground())
        }
        .modifier(OptionalSettingsAnchor(anchor: anchor))
    }
}

/// Applies `settingsRow(anchor:)` only when the card is itself a destination.
private struct OptionalSettingsAnchor: ViewModifier {
    let anchor: SettingsAnchor?

    func body(content: Content) -> some View {
        if let anchor {
            content.settingsRow(anchor: anchor)
        } else {
            content
        }
    }
}

/// The card surface. Opaque in both schemes so a stacked slider or text field never shows the page
/// gradient through it, with a hairline that follows the appearance.
private struct SettingsCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Settings.cardRadius, style: .continuous)
        shape
            .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.white)
            .overlay {
                shape.strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.07),
                    lineWidth: DesignTokens.hairline
                )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.045), radius: 1.5, y: 0.5)
    }
}

/// A label on the left, a control of fixed width on the right — System Settings' picker row.
struct SettingsValueRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.body))
            Spacer(minLength: 12)
            content()
                .font(.system(size: DesignTokens.TypeSize.body))
                .controlSize(.regular)
                .frame(width: DesignTokens.Settings.fieldWidth, alignment: .trailing)
        }
        .frame(minHeight: DesignTokens.Settings.rowHeight)
    }
}

/// A label on the left, a switch pinned right — System Settings' switch row.
///
/// Only the switch itself is the control. A row-wide tap gesture would fire alongside the
/// `Toggle`'s own and flip the value twice, ending where it started.
struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.body))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .glassLabelHidden()
                .toggleStyle(.glass)
                .controlSize(.regular)
        }
        .frame(minHeight: DesignTokens.Settings.rowHeight)
    }
}

// MARK: - General

enum GeneralSettingsDisclosure {
    static let advancedDisplayAnchors: Set<SettingsAnchor> = [
        .panelTheme, .panelHeight, .compactGrid, .climatePanelModule, .hideGroupedLights, .menuBarPinnedReadouts
    ]

    struct State: Equatable, Sendable {
        var isExpanded: Bool = false
        private(set) var hasAppliedInitialDefaults = false

        init(isExpanded: Bool = false) {
            self.isExpanded = isExpanded
        }

        mutating func applyInitialNonDefaultIfNeeded(
            panelTheme: PanelTheme,
            panelHeight: PanelHeight,
            isCompactGridMode: Bool,
            climatePanelModule: Bool,
            hideGroupedLights: Bool,
            hasPinnedMenuBarReadouts: Bool = false
        ) {
            guard !hasAppliedInitialDefaults else { return }
            hasAppliedInitialDefaults = true
            if GeneralSettingsDisclosure.hasNonDefaultDisplaySettings(
                panelTheme: panelTheme,
                panelHeight: panelHeight,
                isCompactGridMode: isCompactGridMode,
                climatePanelModule: climatePanelModule,
                hideGroupedLights: hideGroupedLights,
                hasPinnedMenuBarReadouts: hasPinnedMenuBarReadouts
            ) {
                isExpanded = true
            }
        }

        mutating func expandIfNeeded(forRequestedTab tab: SettingsTab?) {
            if GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forRequestedTab: tab) {
                isExpanded = true
            }
        }

        mutating func expandIfNeeded(forHighlight anchor: SettingsAnchor?) {
            if GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forHighlight: anchor) {
                isExpanded = true
            }
        }
    }

    static func shouldExpandAdvancedDisplay(forHighlight anchor: SettingsAnchor?) -> Bool {
        anchor.map(advancedDisplayAnchors.contains) ?? false
    }

    static func shouldExpandAdvancedDisplay(forRequestedTab tab: SettingsTab?) -> Bool {
        tab == .appearance
    }

    static func hasNonDefaultDisplaySettings(
        panelTheme: PanelTheme,
        panelHeight: PanelHeight,
        isCompactGridMode: Bool,
        climatePanelModule: Bool,
        hideGroupedLights: Bool,
        hasPinnedMenuBarReadouts: Bool = false
    ) -> Bool {
        if panelTheme != .classic { return true }
        if panelHeight != .standard { return true }
        if !isCompactGridMode { return true }
        if !climatePanelModule { return true }
        if !hideGroupedLights { return true }
        if hasPinnedMenuBarReadouts { return true }
        return false
    }
}

struct ContinueOnboardingSection: View {
    let store: HomeStore
    var anchor: SettingsAnchor? = nil
    @Environment(\.settingsUnsavedChanges) private var unsaved

    @MainActor
    @discardableResult
    static func reopenIfUnsavedResolved(
        store: HomeStore,
        unsaved: SettingsUnsavedChanges?,
        ask: ((_ titles: [String], _ allowCancel: Bool) -> SettingsUnsavedChanges.Choice)? = nil
    ) -> Bool {
        if let unsaved {
            let resolved = if let ask {
                unsaved.resolveBeforeLeaving(allowCancel: true, ask: ask)
            } else {
                unsaved.resolveBeforeLeaving(allowCancel: true)
            }
            if !resolved {
                return false
            }
        }
        store.reopenOnboarding()
        return true
    }

    var body: some View {
        SettingsSection(title: L10n.tr("初始设置", "Initial Setup"), anchor: anchor) {
            HStack(spacing: 12) {
                Text(L10n.tr(
                    "完成设备连接与基础引导",
                    "Finish connecting devices and the basic guide"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button {
                    guard Self.reopenIfUnsavedResolved(store: store, unsaved: unsaved) else { return }
                    NSApp.keyWindow?.orderOut(nil)
                    HotkeyAndNotificationManager.shared.ensureMenuBarExtraWindowVisible()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text(L10n.tr("继续初始设置", "Continue Setup"))
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
        }
    }
}

private struct GeneralSettingsTab: View {
    let store: HomeStore
    @Binding var advancedDisplay: GeneralSettingsDisclosure.State
    @Environment(\.settingsSearchFocus) private var searchFocus
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var showNotificationRationale = false
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PanelTheme.storageKey) private var panelThemeRaw: String = PanelTheme.defaultValue.rawValue
    @AppStorage(PanelHeight.storageKey) private var panelHeightRaw: String = PanelHeight.standard.rawValue
    @AppStorage(PanelPrefs.climatePanelKey) private var climatePanelModule: Bool = true
    @AppStorage(SoundFeedback.storageKey) private var soundFeedbackEnabled = false
    @AppStorage(TemperatureUnitPreference.storageKey) private var temperatureUnitRaw = TemperatureUnitPreference.system.rawValue

    private var notifications: NotificationPermissionState { .shared }
    private var hotkey: HotkeySettingsState { .shared }
    @MainActor private var launchAtLogin: LaunchAtLoginCoordinator { .live(store: store) }

    /// The theme the app actually renders, so a stored Liquid Glass choice on an older system still
    /// shows the classic controls.
    private var panelTheme: PanelTheme {
        PanelTheme.resolved(from: panelThemeRaw)
    }

    var body: some View {
        let _ = store.effectiveLanguage
        VStack(alignment: .leading, spacing: 16) {
            if !store.hasCompletedOnboarding {
                ContinueOnboardingSection(store: store, anchor: .setupGuide)
            }

            SettingsSection(title: L10n.tr("基础显示", "Basic Display")) {
                HStack {
                    Text(L10n.tr("外观模式", "Appearance"))
                        .font(.system(size: DesignTokens.TypeSize.body))
                    Spacer(minLength: 12)
                    GlassSegmentedControl(
                        selection: $appearanceRaw,
                        segments: AppAppearance.allCases.map {
                            GlassSegment(value: $0.rawValue, title: $0.title)
                        }
                    )
                    .frame(width: DesignTokens.Settings.fieldWidth)
                }
                .frame(minHeight: DesignTokens.Settings.rowHeight)
                .settingsRow(anchor: .appearanceMode)

                Divider().overlay(Color.primary.opacity(0.06))

                SettingsValueRow(title: L10n.tr("界面语言", "Language")) {
                    Picker(L10n.tr("界面语言", "Language"), selection: Binding(
                        get: { store.appLanguagePreference },
                        set: { store.appLanguagePreference = $0 }
                    )) {
                        ForEach(AppLanguagePreference.allCases) { pref in
                            Text(pref.label).tag(pref)
                        }
                    }
                    .labelsHidden()
                }
                .settingsRow(anchor: .language)

                SettingsValueRow(title: L10n.tr("温度单位", "Temperature Unit")) {
                    Picker(L10n.tr("温度单位", "Temperature Unit"), selection: $temperatureUnitRaw) {
                        ForEach(TemperatureUnitPreference.allCases) { unit in
                            Text(unit.title).tag(unit.rawValue)
                        }
                    }
                    .labelsHidden()
                }
                .settingsRow(anchor: .temperatureUnit)

                SettingsValueRow(title: L10n.tr("面板标题", "Dashboard Title")) {
                    TextField(KeychainHelper.localizedDefaultHomeName, text: Binding(
                        get: { store.homeName },
                        set: { store.homeName = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.tr("面板标题", "Dashboard Title"))
                }
                .settingsRow(anchor: .dashboardTitle)

                SettingsValueRow(title: L10n.tr("菜单栏旁显示", "Menu Bar Readout")) {
                    Picker(L10n.tr("菜单栏旁显示", "Menu Bar Readout"), selection: Binding(
                        get: { store.menuBarTargetId },
                        set: { store.menuBarTargetId = $0 }
                    )) {
                        ForEach(store.availableMenuBarOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                }
                .settingsRow(anchor: .menuBarReadout)
            }

            SettingsSection(title: L10n.tr("交互", "Interaction")) {
                SettingsToggleRow(
                    title: L10n.tr("输入框里显示快捷场景", "Show Scenes Under the Input"),
                    isOn: Binding(
                        get: { store.showQuickActionsBar },
                        set: { store.showQuickActionsBar = $0 }
                    )
                )
                .settingsRow(anchor: .quickScenesBar)

                SettingsToggleRow(
                    title: L10n.tr("面板顶部显示「我家现在」摘要行", "Show Home Summary Row"),
                    isOn: Binding(
                        get: { store.showHomeSummaryRow },
                        set: { store.showHomeSummaryRow = $0 }
                    )
                )
                .settingsRow(anchor: .homeSummaryRow)

                SettingsToggleRow(
                    title: L10n.tr("操作声音反馈", "Play Feedback Sounds"),
                    isOn: $soundFeedbackEnabled
                )
                .settingsRow(anchor: .soundFeedback)

                SettingsToggleRow(
                    title: L10n.tr("语音输入", "Voice Input"),
                    isOn: Binding(
                        get: { store.enableVoiceInput },
                        set: { store.enableVoiceInput = $0 }
                    )
                )
                .settingsRow(anchor: .voiceInput)

                Text(L10n.tr(
                    "按 V，或长按菜单栏图标、快捷键说话",
                    "Press V, or hold the menu bar icon or shortcut, to speak"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: L10n.tr("启动与快捷键", "Startup & Shortcuts")) {
                HStack {
                    Text(L10n.tr("登录 Mac 时自动启动", "Launch at Login"))
                        .font(.system(size: DesignTokens.TypeSize.body))
                    Spacer()
                    Toggle(L10n.tr("登录 Mac 时自动启动", "Launch at Login"), isOn: Binding(
                        get: { store.launchAtLoginPolicy.settingsToggleIsOn },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .glassLabelHidden()
                    .toggleStyle(.glass)
                    .controlSize(.regular)
                }
                .frame(minHeight: DesignTokens.Settings.rowHeight)
                .settingsRow(anchor: .launchAtLogin)

                if store.launchAtLoginPolicy.needsManualApproval {
                    HStack(alignment: .top, spacing: 8) {
                        Label(
                            L10n.tr(
                                "系统没有自动设置成功，请到系统设置里手动开启。",
                                "macOS could not enable it automatically. Turn it on in System Settings."
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Button(L10n.tr("去系统设置开启", "Open System Settings")) {
                            launchAtLogin.openSystemSettings()
                        }
                        .buttonStyle(PillActionButtonStyle())
                    }
                }

                Divider().overlay(Color.primary.opacity(0.06))

                VStack(alignment: .leading, spacing: DesignTokens.Settings.rowSpacing) {
                    SettingsToggleRow(
                        title: L10n.tr(
                            "启用全局快捷键 \(hotkey.shortcut.displayString)",
                            "Global shortcut \(hotkey.shortcut.displayString)"
                        ),
                        isOn: Binding(
                            get: { store.enableGlobalHotkey },
                            set: { store.enableGlobalHotkey = $0 }
                        )
                    )

                    if store.enableGlobalHotkey {
                        HotkeyRecorderRow()
                    }

                    Divider().overlay(Color.primary.opacity(0.06))

                    CustomHotkeyBindingsSection(store: store)
                }
                .settingsRow(anchor: .globalHotkey)
            }

            SettingsSection(title: L10n.tr("设备可见性", "Device Visibility")) {
                SettingsToggleRow(
                    title: L10n.tr("隐藏离线/未通电的设备", "Hide Offline / Unpowered Devices"),
                    isOn: Binding(
                        get: { store.hideOfflineDevices },
                        set: { store.hideOfflineDevices = $0 }
                    )
                )
                .settingsRow(anchor: .hideOfflineDevices)

                if !store.hiddenDevices.isEmpty {
                    Divider().overlay(Color.primary.opacity(0.06))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.tr(
                                "已手动隐藏 \(store.hiddenDevices.count) 台设备",
                                "\(store.hiddenDevices.count) manually hidden device(s)"
                            ))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(DesignTokens.secondaryText)

                            Spacer()

                            if store.hiddenDevices.count > 1 {
                                Button(L10n.tr("全部恢复显示", "Unhide All")) {
                                    let ids = store.hiddenDevices.map(\.id)
                                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                                        for id in ids {
                                            store.unhideDevice(id)
                                        }
                                    }
                                }
                                .buttonStyle(PillActionButtonStyle())
                            }
                        }

                        ForEach(store.hiddenDevices) { dev in
                            HStack(spacing: 8) {
                                Image(systemName: dev.sfSymbolName)
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                    .foregroundStyle(DesignTokens.secondaryText)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dev.name)
                                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                    Text(L10n.displayRoomName(dev.roomName))
                                        .font(.system(size: DesignTokens.TypeSize.caption))
                                        .foregroundStyle(DesignTokens.secondaryText)
                                }

                                Spacer()

                                Button(L10n.tr("恢复显示", "Unhide")) {
                                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                                        store.unhideDevice(dev.id)
                                    }
                                }
                                .buttonStyle(PillActionButtonStyle())
                            }
                        }
                    }
                    .settingsRow(anchor: .hiddenDevices)
                }
            }

            if store.homeBackend != .demo {
                SettingsSection(title: L10n.tr("设备类型", "Device Types")) {
                    DeviceTypeSelectionView(store: store)
                }
            }

            SettingsSection(title: L10n.tr("高级显示", "Advanced Display")) {
                DisclosureGroup(isExpanded: $advancedDisplay.isExpanded) {
                    VStack(alignment: .leading, spacing: DesignTokens.Settings.rowSpacing) {
                        if #available(macOS 26.0, *) {
                            HStack {
                                Text(L10n.tr("面板主题", "Panel Theme"))
                                    .font(.system(size: DesignTokens.TypeSize.body))
                                Spacer()
                                GlassSegmentedControl(
                                    selection: $panelThemeRaw,
                                    segments: PanelTheme.allCases.map { GlassSegment(value: $0.rawValue, title: $0.title) }
                                )
                                .frame(width: 210)
                            }
                            .frame(minHeight: DesignTokens.Settings.rowHeight)
                            .settingsRow(anchor: .panelTheme)

                            Divider().overlay(Color.primary.opacity(0.06))
                        }

                        if panelTheme == .classic {
                            HStack {
                                Text(L10n.tr("面板高度", "Panel Height"))
                                    .font(.system(size: DesignTokens.TypeSize.body))
                                Spacer()
                                GlassSegmentedControl(
                                    selection: $panelHeightRaw,
                                    segments: PanelHeight.allCases.map { GlassSegment(value: $0.rawValue, title: $0.title) }
                                )
                                .frame(width: 210)
                            }
                            .frame(minHeight: DesignTokens.Settings.rowHeight)
                            .settingsRow(anchor: .panelHeight)

                            Divider().overlay(Color.primary.opacity(0.06))
                        }

                        SettingsToggleRow(
                            title: L10n.tr("双列紧凑磁贴视图", "2-Column Compact Grid"),
                            isOn: Binding(get: { store.isCompactGridMode }, set: { store.isCompactGridMode = $0 })
                        )
                        .settingsRow(anchor: .compactGrid)

                        SettingsToggleRow(
                            title: L10n.tr("空调使用整行面板模块", "Full-Width Climate Panel"),
                            isOn: $climatePanelModule
                        )
                        .settingsRow(anchor: .climatePanelModule)

                        SettingsToggleRow(
                            title: L10n.tr("灯组内的单灯不重复显示", "Hide individual lights inside groups"),
                            isOn: Binding(get: { store.hideGroupedLights }, set: { store.hideGroupedLights = $0 })
                        )
                        .settingsRow(anchor: .hideGroupedLights)

                        Divider().overlay(Color.primary.opacity(0.06))

                        VStack(alignment: .leading, spacing: DesignTokens.Settings.rowSpacing) {
                            SettingsValueRow(title: L10n.tr("菜单栏钉选读数 1", "Pinned Readout 1")) {
                                Picker(L10n.tr("菜单栏钉选读数 1", "Pinned Readout 1"), selection: Binding(
                                    get: { store.menuBarPinnedReadouts.first ?? "" },
                                    set: { store.setMenuBarPinnedReadout($0, at: 0) }
                                )) {
                                    Text(L10n.tr("不钉选", "None")).tag("")
                                    ForEach(store.availablePinnedMenuBarOptions) { option in
                                        Text(option.title).tag(option.id)
                                    }
                                }
                                .labelsHidden()
                            }

                            if !store.menuBarPinnedReadouts.isEmpty {
                                SettingsValueRow(title: L10n.tr("菜单栏钉选读数 2", "Pinned Readout 2")) {
                                    let first = store.menuBarPinnedReadouts.first ?? ""
                                    let second = store.menuBarPinnedReadouts.count > 1 ? store.menuBarPinnedReadouts[1] : ""
                                    Picker(L10n.tr("菜单栏钉选读数 2", "Pinned Readout 2"), selection: Binding(
                                        get: { second },
                                        set: { store.setMenuBarPinnedReadout($0, at: 1) }
                                    )) {
                                        Text(L10n.tr("不钉选", "None")).tag("")
                                        ForEach(store.availablePinnedMenuBarOptions.filter { $0.id != first }) { option in
                                            Text(option.title).tag(option.id)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                        }
                        .settingsRow(anchor: .menuBarPinnedReadouts)
                    }
                    .padding(.top, 6)
                } label: {
                    Text(L10n.tr("高级显示", "Advanced Display"))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
            }

            SettingsSection(title: L10n.tr("家庭健康周报", "Weekly Health Report")) {
                SettingsToggleRow(
                    title: L10n.tr("每周日晚发送家庭健康周报", "Send a weekly home health report on Sunday evening"),
                    isOn: Binding(
                        get: { store.enableWeeklyHealthReport },
                        set: { enabled in
                            store.enableWeeklyHealthReport = enabled
                            if enabled { askForNotificationsIfNeeded() }
                        }
                    )
                )
                .settingsRow(anchor: .weeklyReport)

                HStack {
                    Spacer()
                    Button(L10n.tr("导出本周周报…", "Export This Week's Report…")) {
                        WeeklyHealthReportExport.save(store.weeklyHealthReport())
                    }
                    .buttonStyle(PillActionButtonStyle())
                }

                if showNotificationRationale {
                    NotificationRationaleCard(
                        onDismiss: { showNotificationRationale = false },
                        onAllow: {
                            showNotificationRationale = false
                            Task {
                                _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization()
                            }
                        }
                    )
                }
            }

            AutomationSettingsSection(store: store)
            EnergySettingsSection(store: store)
        }
        .task { await HotkeyAndNotificationManager.shared.refreshNotificationPermission() }
        .onAppear {
            advancedDisplay.applyInitialNonDefaultIfNeeded(
                panelTheme: panelTheme,
                panelHeight: PanelHeight(rawValue: panelHeightRaw) ?? .standard,
                isCompactGridMode: store.isCompactGridMode,
                climatePanelModule: climatePanelModule,
                hideGroupedLights: store.hideGroupedLights,
                hasPinnedMenuBarReadouts: !store.menuBarPinnedReadouts.isEmpty
            )
            advancedDisplay.expandIfNeeded(forHighlight: searchFocus?.highlight)
            launchAtLogin.refresh()
        }
        .onChange(of: searchFocus?.highlight) { _, highlight in
            advancedDisplay.expandIfNeeded(forHighlight: highlight)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    /// In-app explanation first, system prompt second (#55).
    private func askForNotificationsIfNeeded() {
        if HotkeyAndNotificationManager.hasRequestedNotificationAuthorization {
            // Asked before: only show the system prompt when macOS can still present it.
            if notifications.canRequest {
                Task { _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization() }
            }
            return
        }
        // A denial made in System Settings has nothing left to ask; the permission row offers the repair link.
        if notifications.isDenied { return }
        showNotificationRationale = true
    }
}

/// Saves the weekly report as Markdown wherever the user picks (#182).
@MainActor
enum WeeklyHealthReportExport {
    static func save(_ report: WeeklyHealthReport, now: Date = Date()) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        let stamp = now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = L10n.tr("家庭健康周报-\(stamp).md", "home-health-\(stamp).md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.markdown().write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Connections

enum HAConnectionSaveGuard {
    static let haTokenAccount = "ha_access_token"

    /// #143: a fresh install shows an empty field (the placeholder names the address) instead of a
    /// pre-filled `http://homeassistant.local:8123` that raises a plaintext warning before anyone typed.
    /// Whoever already connected Home Assistant, or saved a custom address, keeps what they have.
    static func initialURLDraft(storedURL: String, hasHASource: Bool) -> String {
        if hasHASource { return storedURL }
        return HAWebSocketProvider.normalizeBaseURL(storedURL) == KeychainHelper.defaultNASURL ? "" : storedURL
    }

    /// An empty field still means the default address, exactly as the pre-filled one did.
    static func effectiveURL(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? KeychainHelper.defaultNASURL : draft
    }

    /// The plaintext-token warning is about something the user typed, never about the default.
    static func showsPlaintextWarning(forDraft draft: String) -> Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let address = URL(string: HAWebSocketProvider.normalizeBaseURL(draft)),
              address.scheme == "http",
              let host = address.host else { return false }
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    /// Search anchors that live inside the collapsed Home Assistant card.
    static let collapsedAnchors: Set<SettingsAnchor> = [.haServerAddress, .haToken, .haDiscovery]

    /// A search hit inside the folded card opens it for good: the highlight itself fades after about
    /// 1.6 s, and the form must not vanish while the user is typing or scanning.
    static func shouldLatchExpansion(forHighlight anchor: SettingsAnchor?) -> Bool {
        anchor.map(collapsedAnchors.contains) ?? false
    }

    static func showsConnectionStatusHeader(hasHASource: Bool) -> Bool {
        hasHASource
    }

    static func saveButtonTitle(hasHASource: Bool, isHAConnectionEnabled: Bool) -> String {
        if hasHASource && !isHAConnectionEnabled {
            return L10n.tr("保存配置（保持停用）", "Save Settings (Keep Turned Off)")
        }
        return L10n.tr("保存并重新连接", "Save & Reconnect")
    }

    enum Decision: Equatable {
        case proceed(token: String, clearUnavailableFlag: Bool)
        case blockedKeychainUnavailable
    }

    @MainActor
    static func vault(for store: HomeStore) -> CredentialVault? {
        store.credentialVault ?? (store.userDefaults === UserDefaults.standard ? .shared : nil)
    }

    @MainActor
    static func isInitialLookupUnavailable(loadedToken: String, vault: CredentialVault?) -> Bool {
        loadedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && vault?.lookup(haTokenAccount) == .unavailable
    }

    @MainActor
    static func loadInitialToken(from store: HomeStore) -> (token: String, lookupWasUnavailable: Bool) {
        let loaded = store.loadHAToken()
        let unavailable = isInitialLookupUnavailable(loadedToken: loaded, vault: vault(for: store))
        return (loaded, unavailable)
    }

    /// Protects a stored Home Assistant token when the user opened Settings while the Keychain was
    /// temporarily unreadable (`loadHAToken()` returned `""`) and then saved an edited URL without
    /// typing a replacement token.
    static func resolve(
        draftToken: String,
        initialLookupWasUnavailable: Bool,
        retryLookup: () -> CredentialVault.Lookup
    ) -> Decision {
        let trimmed = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty, initialLookupWasUnavailable else {
            return .proceed(token: draftToken, clearUnavailableFlag: !trimmed.isEmpty)
        }
        switch retryLookup() {
        case .value(let data):
            let recovered = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .proceed(token: recovered, clearUnavailableFlag: true)
        case .missing:
            return .proceed(token: "", clearUnavailableFlag: true)
        case .unavailable:
            return .blockedKeychainUnavailable
        }
    }

    @MainActor
    @discardableResult
    static func save(
        serverURL: String,
        tokenDraft: inout String,
        initialLookupWasUnavailable: inout Bool,
        in store: HomeStore
    ) -> Bool {
        if store.identityMigrationDiagnostic != nil, !store.retryIdentityMigration() {
            return false
        }
        let activeVault = vault(for: store)
        let decision = resolve(
            draftToken: tokenDraft,
            initialLookupWasUnavailable: initialLookupWasUnavailable,
            retryLookup: { activeVault?.lookup(haTokenAccount, retryingUnavailable: true) ?? .missing }
        )
        switch decision {
        case .proceed(let resolvedToken, let clearFlag):
            if clearFlag {
                initialLookupWasUnavailable = false
            }
            if tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !resolvedToken.isEmpty {
                tokenDraft = resolvedToken
            }
            return store.updateConnection(serverURL: serverURL, token: resolvedToken)
        case .blockedKeychainUnavailable:
            store.showToast(
                L10n.tr(
                    "无法访问钥匙串，已保留原有 Home Assistant 令牌",
                    "Keychain access was denied; kept existing Home Assistant token"
                ),
                isError: true
            )
            return false
        }
    }
}

enum CorruptRemovalRecoveryGuidance {
    struct ActionSet: Equatable, Sendable {
        let primaryRetryTitle: String
        let showsChooseAlternateFolderButton: Bool
        let chooseAlternateFolderTitle: String
    }

    struct Copy: Equatable, Sendable {
        let title: String
        let detail: String
        let steps: [String]
        let actions: ActionSet
    }

    static func resolve(failure: ConnectionRemovalQuarantineFailure) -> Copy {
        let locationSuffix = failure.directoryPath.map { "（\($0)）" } ?? ""
        let locationSuffixEn = failure.directoryPath.map { " (\($0))" } ?? ""
        switch failure.kind {
        case .fullFsyncUnsupported:
            let title = failure.usedAlternateDirectory
                ? L10n.tr("所选文件夹无法安全保存数据", "The selected folder cannot save data safely")
                : L10n.tr("当前位置无法安全保存数据", "This location cannot save data safely")
            let detail = L10n.tr(
                "清理损坏记录前，要先在一个私有文件夹里留一份确认写入成功的备份。目标位置\(locationSuffix)做不到这一点（常见于网络主目录、NAS 挂载或部分外置磁盘）。原记录已原样保留，换到 Mac 内置磁盘上的文件夹再试即可。",
                "Before clearing a damaged record, a verified backup must be written to a private folder. The target location\(locationSuffixEn) cannot guarantee that (common on network home folders, NAS mounts or some external drives). The original record was kept untouched; try again with a folder on your Mac's internal disk."
            )
            let steps = [
                L10n.tr(
                    "1. 点击下方「选择本地文件夹并重试…」，选一个 Mac 内置磁盘上的个人文件夹。",
                    "1. Click \"Choose Local Folder & Retry…\" below and pick a folder on your Mac's internal disk."
                ),
            ]
            return Copy(
                title: title,
                detail: detail,
                steps: steps,
                actions: ActionSet(
                    primaryRetryTitle: L10n.tr("重试原位置", "Retry Default Location"),
                    showsChooseAlternateFolderButton: true,
                    chooseAlternateFolderTitle: L10n.tr("选择本地文件夹并重试…", "Choose Local Folder & Retry…")
                )
            )
        case .transientOrVerificationFailed:
            let title = failure.usedAlternateDirectory
                ? L10n.tr("所选备用位置写入或校验未通过", "Selected alternate location failed write or verification")
                : L10n.tr("隔离备份写入或校验未通过", "Could not write or verify quarantine backup")
            let detail = L10n.tr(
                "备份写入或校验失败，原记录已保留。可能是磁盘空间不足、文件夹权限不对或临时读写错误。",
                "Writing or verifying the backup failed; the original record was kept. Low disk space, wrong folder permissions or a temporary disk error can cause this."
            )
            let steps = [
                L10n.tr(
                    "1. 检查目标目录磁盘空间与权限\(locationSuffix)后，点击「重试放弃记录」。",
                    "1. Check disk space and permissions\(locationSuffixEn), then click \"Retry Discard\"."
                ),
                L10n.tr(
                    "2. 若原目录持续无法写入，可点击「选择本地文件夹并重试…」改存到本机其他私有文件夹。",
                    "2. If the default location keeps failing, click \"Choose Local Folder & Retry…\" to use another local folder."
                ),
            ]
            return Copy(
                title: title,
                detail: detail,
                steps: steps,
                actions: ActionSet(
                    primaryRetryTitle: L10n.tr("重试放弃记录", "Retry Discard"),
                    showsChooseAlternateFolderButton: true,
                    chooseAlternateFolderTitle: L10n.tr("选择本地文件夹并重试…", "Choose Local Folder & Retry…")
                )
            )
        }
    }
}

enum ConnectionSettingsDisclosure {
    static let advancedConnectionAnchors: Set<SettingsAnchor> = [.miMultiAccounts]

    struct State: Equatable, Sendable {
        var isExpanded: Bool = false
        private(set) var hasAppliedInitialDefaults = false

        init(isExpanded: Bool = false, hasAppliedInitialDefaults: Bool = false) {
            self.isExpanded = isExpanded
            self.hasAppliedInitialDefaults = hasAppliedInitialDefaults
        }

        mutating func applyInitialDefaultsIfNeeded(accountCount: Int, isDualSourceActive: Bool) {
            guard !hasAppliedInitialDefaults else { return }
            hasAppliedInitialDefaults = true
            if accountCount > 1 || isDualSourceActive {
                isExpanded = true
            }
        }

        mutating func expandForHighlightIfNeeded(_ highlight: SettingsAnchor?) {
            guard let highlight, ConnectionSettingsDisclosure.advancedConnectionAnchors.contains(highlight) else {
                return
            }
            isExpanded = true
        }
    }

    @MainActor
    static func requestAddMiAccount(trigger: inout Int, focus: SettingsSearchFocus?) {
        trigger &+= 1
        focus?.jump(to: .miAccount)
    }
}

struct HADisableConnectionConfirmation: Equatable {
    let itemsToPause: [AffectedReferenceItem]
    let generation: Int

    /// Exact list shown in the confirmation sheet; M3 re-previews if the live set changes before submit.
    var pauseItemKeys: Set<String> { Set(itemsToPause.map(\.pauseKey)) }

    var title: String { L10n.tr("停用 Home Assistant 连接？", "Turn off Home Assistant connection?") }
    var confirmButtonTitle: String { L10n.tr("暂停这些项并关闭", "Pause These & Turn Off") }
    var messageText: String {
        let sep = L10n.isEnglish ? ", " : "、"
        let names = itemsToPause.prefix(6).map(\.name).joined(separator: sep)
        let suffix = itemsToPause.count > 6 ? "…" : ""
        return L10n.format(
            "停用 Home Assistant 连接后，以下受影响的定时、自动化或快捷动作将暂停保留，重新启用连接后自动复验恢复：%@%@",
            "Turning off the Home Assistant connection will pause and keep the following affected timers, automations, or quick actions until you turn it back on: %@%@",
            names, suffix
        )
    }
}

private struct ConnectionSettingsTab: View {
    let store: HomeStore
    @Binding var advancedConnections: ConnectionSettingsDisclosure.State
    @Binding var lgWakeDisclosure: LGWebOSSettingsSaveGuard.WakeDisclosureState
    @State private var urlDraft: String = ""
    @State private var tokenDraft: String = ""
    @State private var tokenLookupWasUnavailable = false
    /// #143: Home Assistant is the second path, so its form stays folded until it is needed.
    @State private var haExpanded = false
    @State private var addMiAccountTrigger = 0
    @State private var pendingHADisableConfirmation: HADisableConnectionConfirmation?
    @State private var haRemovalPreview: ConnectionRemovalPreview?
    @State private var showHARemovalDetails = false
    @State private var confirmsDiscardCorruptRemoval = false
    @State private var pendingHARemovalPauseConfirmation: HADisableConnectionConfirmation?
    @Environment(\.settingsSearchFocus) private var searchFocus
    @Environment(\.settingsUnsavedChanges) private var unsaved
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    /// The address and token as loaded or last saved; edits that differ are unsaved (#148).
    @State private var haBaselineURL = ""
    @State private var haBaselineToken = ""

    private var haIsDirty: Bool { urlDraft != haBaselineURL || tokenDraft != haBaselineToken }

    private func registerUnsavedForm() {
        unsaved?.register("home-assistant", .init(
            title: "Home Assistant",
            isDirty: haIsDirty,
            save: { saveHomeAssistant() },
            discard: {
                urlDraft = haBaselineURL
                tokenDraft = haBaselineToken
            }
        ))
    }

    /// Saves through the usual guard, then reports whether the store really holds the draft now. A
    /// refused Keychain write leaves the edits flagged as unsaved.
    @discardableResult
    private func saveHomeAssistant() -> Bool {
        guard HAConnectionSaveGuard.save(
            serverURL: HAConnectionSaveGuard.effectiveURL(urlDraft),
            tokenDraft: &tokenDraft,
            initialLookupWasUnavailable: &tokenLookupWasUnavailable,
            in: store
        ) else {
            return false
        }
        let urlSaved = HAWebSocketProvider.normalizeBaseURL(store.serverURLString)
            == HAWebSocketProvider.normalizeBaseURL(HAConnectionSaveGuard.effectiveURL(urlDraft))
        let tokenSaved = store.loadHAToken().trimmingCharacters(in: .whitespacesAndNewlines)
            == tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlSaved, tokenSaved else { return false }
        haBaselineURL = urlDraft
        haBaselineToken = tokenDraft
        return true
    }

    private func requestDisableHAConnection() {
        let generation = store.capabilityGeneration
        let verdict = store.previewSetHAConnectionEnabled(false)
        switch verdict.disposition {
        case .allowed:
            let applied = store.setHAConnectionEnabled(false, expectedGeneration: generation)
            if applied.disposition == .blocked {
                reportBlockedHADisable(applied)
            } else {
                presentHADisableConfirmationIfStillNeeded(applied)
            }
        case .requiresPauseConfirmation:
            pendingHADisableConfirmation = HADisableConnectionConfirmation(
                itemsToPause: verdict.itemsToPause,
                generation: generation
            )
        case .blocked:
            reportBlockedHADisable(verdict)
        }
    }

    private func presentHADisableConfirmationIfStillNeeded(_ verdict: CapabilityDeactivationVerdict) {
        guard verdict.disposition == .requiresPauseConfirmation,
              store.isHAConnectionEnabled else { return }
        let fresh = HADisableConnectionConfirmation(
            itemsToPause: verdict.itemsToPause,
            generation: store.capabilityGeneration
        )
        Task { @MainActor in pendingHADisableConfirmation = fresh }
    }

    private func reportBlockedHADisable(_ verdict: CapabilityDeactivationVerdict) {
        let kinds = Set(verdict.blockingReasons.map(\.kind))
        let message: String
        if kinds.contains(.corruptedReferenceStore) {
            message = L10n.tr(
                "无法停用该连接：本地保存的定时、自动化或布局数据已损坏。请先在对应页面修复或删除这些数据后重试",
                "Could not turn off this connection: saved timers, automations or layout data are damaged. Fix or delete them in their pages and try again"
            )
        } else if kinds.contains(.unresolvedReferenceOwnership) {
            message = L10n.tr(
                "无法停用该连接：有定时或自动化无法确认目标属于哪个连接。请先在这些项目里重新选择目标",
                "Could not turn off this connection: a timer or automation has targets that cannot be attributed to a connection. Reselect their targets first"
            )
        } else if kinds.contains(.stalePreviewGeneration) {
            message = L10n.tr(
                "连接状态刚刚发生变化，请再试一次",
                "The connection state just changed; try again"
            )
        } else {
            message = L10n.tr("无法停用该连接", "Could not turn off this connection")
        }
        store.showToast(message, isError: true)
    }

    private var showsHomeAssistantForm: Bool {
        if haExpanded || store.hasHASource { return true }
        return HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: searchFocus?.highlight)
    }

    var body: some View {
        let _ = store.effectiveLanguage
        let _ = store.capabilityGeneration
        VStack(alignment: .leading, spacing: 16) {
            if !store.hasCompletedOnboarding {
                ContinueOnboardingSection(store: store)
            }

            SettingsSection(title: L10n.tr("连接状态与示例家庭", "Connection Status & Demo Home")) {
                HStack {
                    Text(store.connectionSourceSummary)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                    Spacer()
                    Text(connectionBadgeText)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(connectionBadgeColor)
                        .help(connectionBadgeHelp)
                }

                Toggle(isOn: Binding(
                    get: { store.homeBackend == .demo },
                    set: { isDemo in
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                            store.switchBackend(isDemo ? .demo : store.preferredLiveBackend)
                        }
                    }
                )) {
                    Text(L10n.tr("先逛逛示例家庭", "Explore Demo Home"))
                }
                .toggleStyle(.switch)
                .settingsRow(anchor: .demoMode)

                if store.homeBackend == .demo {
                    Text(L10n.tr("示例家庭，不会控制真实设备", "Demo home; won't control real devices"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
            }

            if store.homeBackend != .demo {
                if !store.pendingConnectionRemovals.isEmpty || store.hasCorruptConnectionRemovalState {
                    pendingConnectionRemovalsSection
                }

                if !store.effectiveLocalNetworkBlocks.isEmpty {
                    SettingsSection(title: L10n.tr("本地网络权限", "Local Network Permission")) {
                        LocalNetworkPermissionBannerView(
                            blockedFeatures: store.effectiveLocalNetworkBlocks,
                            store: store,
                            theme: .liquidGlass,
                            inSettings: true
                        )
                        .settingsRow(anchor: .localNetwork)
                    }
                }

                SettingsSection(title: L10n.tr("米家", "Xiaomi Home"), anchor: .miAccount) {
                    MiAccountSection(store: store, showsInlineAddAccountButton: false, addAccountTrigger: addMiAccountTrigger)
                    if !store.deviceTransportDiagnostics.isEmpty {
                        Divider().overlay(Color.primary.opacity(0.06))
                        XiaomiLANTransportSummaryRow(store: store)
                    }
                }

                if showsHomeAssistantForm {
                    homeAssistantConfiguredSection
                } else {
                    SettingsSection(title: "Home Assistant") {
                        Button {
                            withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { haExpanded = true }
                        } label: {
                            HStack {
                                Text(L10n.tr("连接 Home Assistant", "Connect Home Assistant"))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(DesignTokens.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                LGWebOSSettingsSection(store: store, wakeDisclosure: $lgWakeDisclosure)

                SettingsSection(title: L10n.tr("高级连接选项", "Advanced Connection Options")) {
                    DisclosureGroup(isExpanded: $advancedConnections.isExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.tr("添加更多米家账号", "Add Another Xiaomi Home Account"))
                                        .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
                                }
                                Spacer(minLength: 8)
                                Button {
                                    ConnectionSettingsDisclosure.requestAddMiAccount(
                                        trigger: &addMiAccountTrigger,
                                        focus: searchFocus
                                    )
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.circle")
                                        Text(L10n.tr("继续扫码添加", "Scan Another Account"))
                                    }
                                }
                                .buttonStyle(PillActionButtonStyle())
                            }
                            .settingsRow(anchor: .miMultiAccounts)

                            Divider().overlay(Color.primary.opacity(0.06))

                            GenericCameraSettings(store: store)
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(L10n.tr("多账号、多平台与通用摄像机", "Multiple Accounts, Platforms & Generic Cameras"))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                }
            }
        }
        .onChange(of: haIsDirty) { _, _ in registerUnsavedForm() }
        .onDisappear {
            pendingHADisableConfirmation = nil
            pendingHARemovalPauseConfirmation = nil
            haRemovalPreview = nil
            showHARemovalDetails = false
            unsaved?.unregister("home-assistant")
        }
        .onChange(of: searchFocus?.highlight) { _, highlight in
            if HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: highlight) { haExpanded = true }
            advancedConnections.expandForHighlightIfNeeded(highlight)
        }
        .onAppear {
            if HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: searchFocus?.highlight) {
                haExpanded = true
            }
            advancedConnections.applyInitialDefaultsIfNeeded(
                accountCount: store.miAccounts.count,
                isDualSourceActive: store.hasMiSource && store.hasHASource
            )
            advancedConnections.expandForHighlightIfNeeded(searchFocus?.highlight)
            urlDraft = HAConnectionSaveGuard.initialURLDraft(storedURL: store.serverURLString, hasHASource: store.hasHASource)
            let initialHAToken = HAConnectionSaveGuard.loadInitialToken(from: store)
            tokenDraft = initialHAToken.token
            tokenLookupWasUnavailable = initialHAToken.lookupWasUnavailable
            haBaselineURL = urlDraft
            haBaselineToken = tokenDraft
            registerUnsavedForm()
        }
        .alert(
            pendingHADisableConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingHADisableConfirmation != nil },
                set: { if !$0 { pendingHADisableConfirmation = nil } }
            ),
            presenting: pendingHADisableConfirmation
        ) { confirmation in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {
                pendingHADisableConfirmation = nil
            }
            Button(confirmation.confirmButtonTitle) {
                pendingHADisableConfirmation = nil
                let verdict = store.setHAConnectionEnabled(
                    false,
                    pauseConfirmed: true,
                    expectedGeneration: confirmation.generation,
                    expectedPauseItemKeys: confirmation.pauseItemKeys
                )
                if verdict.disposition == .blocked {
                    reportBlockedHADisable(verdict)
                } else {
                    presentHADisableConfirmationIfStillNeeded(verdict)
                }
            }
        } message: { confirmation in
            Text(confirmation.messageText)
        }
        .alert(
            pendingHARemovalPauseConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingHARemovalPauseConfirmation != nil },
                set: { if !$0 { pendingHARemovalPauseConfirmation = nil } }
            ),
            presenting: pendingHARemovalPauseConfirmation
        ) { confirmation in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {
                pendingHARemovalPauseConfirmation = nil
            }
            Button(L10n.tr("暂停这些项并移除", "Pause These & Remove"), role: .destructive) {
                pendingHARemovalPauseConfirmation = nil
                Task {
                    await executeHARemoval(
                        pauseConfirmed: true,
                        expectedGeneration: confirmation.generation,
                        expectedPauseItemKeys: confirmation.pauseItemKeys
                    )
                }
            }
        } message: { confirmation in
            Text(confirmation.messageText)
        }
    }

    @ViewBuilder
    private var homeAssistantConfiguredSection: some View {
        SettingsSection(title: "Home Assistant", anchor: .haServerAddress) {
            if HAConnectionSaveGuard.showsConnectionStatusHeader(hasHASource: store.hasHASource) {
                haConnectionStatusHeader
            }

            homeAssistantForm

            HStack {
                Button(store.isDiscoveringHA ? L10n.tr("查找中…", "Finding…") : L10n.tr("查找家中的 Home Assistant", "Find Home Assistant on LAN")) {
                    Task {
                        let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
                        if let first = found.first {
                            urlDraft = first.baseURL
                            store.showToast(L10n.tr("已发现：\(first.displaySummary)", "Found: \(first.displaySummary)"))
                        } else {
                            store.showToast(L10n.tr("未在局域网扫描到 Home Assistant", "No Home Assistant found on LAN"), isError: true)
                        }
                    }
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(store.isDiscoveringHA || !store.isHAConnectionEnabled)
                .settingsRow(anchor: .haDiscovery)

                Button(L10n.tr("填入默认地址", "Use Default URL")) {
                    urlDraft = KeychainHelper.defaultNASURL
                }
                .buttonStyle(PillActionButtonStyle())

                Spacer()

                UnsavedChangesBadge(isVisible: haIsDirty)

                if store.hasHASource {
                    Button(L10n.tr("断开连接", "Disconnect")) {
                        showHARemovalDetails = false
                        haRemovalPreview = store.previewHomeAssistantRemoval()
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .disabled(store.isRemovingConnectionScopes.contains(ConnectionRemovalStore.haScope(serverURL: store.serverURLString)))
                }

                Button(
                    HAConnectionSaveGuard.saveButtonTitle(
                        hasHASource: store.hasHASource,
                        isHAConnectionEnabled: store.isHAConnectionEnabled
                    )
                ) {
                    saveHomeAssistant()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
            .padding(.top, 2)

            if let preview = haRemovalPreview {
                haRemovalConfirmationCard(preview)
            }
        }
    }

    private func reloadHATokenDraftIfCleanAfterDiscard(_ succeeded: Bool) {
        guard succeeded, tokenDraft == haBaselineToken else { return }
        let initialHAToken = HAConnectionSaveGuard.loadInitialToken(from: store)
        tokenDraft = initialHAToken.token
        tokenLookupWasUnavailable = initialHAToken.lookupWasUnavailable
        haBaselineToken = tokenDraft
    }

    @MainActor
    private func pickAlternateQuarantineFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("选择此位置", "Use This Folder")
        panel.message = L10n.tr(
            "请改选 Mac 内置磁盘上的文件夹",
            "Choose a folder on your Mac's internal disk"
        )
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func corruptRemovalRecoveryCard(_ failure: ConnectionRemovalQuarantineFailure) -> some View {
        let guidance = CorruptRemovalRecoveryGuidance.resolve(failure: failure)
        return VStack(alignment: .leading, spacing: 6) {
            Text(guidance.title)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.orange)
            Text(guidance.detail)
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(guidance.steps, id: \.self) { step in
                Text(step)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(guidance.actions.primaryRetryTitle) {
                    reloadHATokenDraftIfCleanAfterDiscard(store.discardCorruptConnectionRemovalRecord())
                }
                .buttonStyle(PillActionButtonStyle())
                if guidance.actions.showsChooseAlternateFolderButton {
                    Button(guidance.actions.chooseAlternateFolderTitle) {
                        guard let picked = pickAlternateQuarantineFolder() else { return }
                        reloadHATokenDraftIfCleanAfterDiscard(
                            store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: picked)
                        )
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var corruptRemovalDiscardRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(L10n.tr(
                "放弃后已保存的凭据保持不变，原先想移除的连接需要重新发起移除。",
                "Saved credentials stay as they are. Any connection you meant to remove must be removed again."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.primary.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L10n.tr("放弃损坏记录", "Discard Damaged Record")) {
                confirmsDiscardCorruptRemoval = true
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
        }
        .alert(L10n.tr("放弃损坏的移除记录？", "Discard the damaged removal record?"), isPresented: $confirmsDiscardCorruptRemoval) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("放弃记录", "Discard Record"), role: .destructive) {
                reloadHATokenDraftIfCleanAfterDiscard(store.discardCorruptConnectionRemovalRecord())
            }
        } message: {
            Text(L10n.tr(
                "只删除这条无法读取的记录（原始数据已另存备份），不会删除任何米家会话、Home Assistant 钥匙或 AI 密钥。之后账号会恢复显示；如仍想移除某个连接，请重新发起移除。",
                "Only this unreadable record is deleted (a backup of the raw data is kept). No Xiaomi session, Home Assistant token, or AI key is deleted. Accounts reappear afterwards; to remove a connection, start the removal again."
            ))
        }
    }

    @ViewBuilder
    private var pendingConnectionRemovalsSection: some View {
        SettingsSection(title: L10n.tr("未完成移除", "Unfinished Removals")) {
            if store.hasCorruptConnectionRemovalState {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr(
                            "连接移除记录已损坏，已隔离原始数据并暂停相关凭据写入与重连，避免误删或误恢复。",
                            "The connection removal record is unreadable. Raw data was quarantined and credential saves/reconnects stay blocked fail-closed."
                        ))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        if store.canDiscardCorruptConnectionRemovalRecord {
                            if let failure = store.corruptRemovalDiscardFailure {
                                corruptRemovalRecoveryCard(failure)
                            } else {
                                corruptRemovalDiscardRow
                            }
                        }
                    }
                }
            }
            ForEach(store.pendingConnectionRemovals) { record in
                let busy = store.isRemovingConnectionScopes.contains(record.scope)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName ?? record.scope)
                                .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
                            Text(L10n.tr("未完成移除 · 重试", "Removal not finished · Retry"))
                                .font(.system(size: DesignTokens.TypeSize.caption))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button(busy ? L10n.tr("清理中…", "Cleaning…") : L10n.tr("重试清理", "Retry Cleanup")) {
                            Task {
                                let outcome = await store.retryConnectionRemoval(scope: record.scope)
                                if case .completed = outcome, record.kind == .ha {
                                    tokenDraft = ""
                                    haBaselineToken = ""
                                    tokenLookupWasUnavailable = false
                                }
                            }
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                        .disabled(busy)
                    }
                    Text(L10n.tr(
                        "在清理完成前，该连接保持停用且不会被重新启用或覆盖凭据。",
                        "Until cleanup completes, this connection stays blocked and will not reconnect or overwrite credentials."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func haRemovalConfirmationCard(_ preview: ConnectionRemovalPreview) -> some View {
        ConnectionRemovalConfirmationCard(
            title: nil,
            preview: preview,
            isBusy: store.isRemovingConnectionScopes.contains(preview.scope),
            showDetails: $showHARemovalDetails,
            onCancel: {
                haRemovalPreview = nil
                showHARemovalDetails = false
            },
            onConfirm: {
                let generation = store.capabilityGeneration
                Task { await executeHARemoval(pauseConfirmed: false, expectedGeneration: generation, expectedPauseItemKeys: nil) }
            }
        )
    }

    private func executeHARemoval(
        pauseConfirmed: Bool,
        expectedGeneration: Int?,
        expectedPauseItemKeys: Set<String>?
    ) async {
        let outcome = await store.removeHomeAssistantConnection(
            pauseConfirmed: pauseConfirmed,
            expectedGeneration: expectedGeneration,
            expectedPauseItemKeys: expectedPauseItemKeys
        )
        switch outcome {
        case .completed:
            haRemovalPreview = nil
            showHARemovalDetails = false
            tokenDraft = ""
            haBaselineToken = ""
            tokenLookupWasUnavailable = false
        case .requiresPauseConfirmation(let verdict):
            pendingHARemovalPauseConfirmation = HADisableConnectionConfirmation(
                itemsToPause: verdict.itemsToPause,
                generation: store.capabilityGeneration
            )
        case .blockedByDeactivation(let verdict):
            reportBlockedHADisable(verdict)
        case .blockedByUncertainIdentity:
            store.showToast(
                L10n.tr(
                    "无法确认现有配置或凭据，未执行移除，请检查钥匙串授权后重试",
                    "Could not verify existing settings or credentials; removal was not performed. Check Keychain access and try again"
                ),
                isError: true
            )
        case .incomplete:
            haRemovalPreview = nil
            showHARemovalDetails = false
            tokenDraft = ""
            haBaselineToken = ""
            tokenLookupWasUnavailable = false
        }
    }

    @ViewBuilder
    private var haConnectionStatusHeader: some View {
        let isDisabling = store.isDisablingHAConnection
        let isEnabled = store.isHAConnectionEnabled
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isDisabling
                      ? "ellipsis.circle.fill"
                      : (!isEnabled ? "pause.circle.fill" : (disconnectReason != nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(isDisabling || !isEnabled ? DesignTokens.secondaryText : (disconnectReason != nil ? .orange : .green))
                Text(isDisabling
                     ? L10n.tr("Home Assistant 连接停止中…", "Turning off Home Assistant connection…")
                     : (!isEnabled
                        ? L10n.tr("Home Assistant 连接已停用", "Home Assistant connection turned off")
                        : L10n.tr("已配置 Home Assistant 连接", "Home Assistant connection configured")))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Spacer()
                Button(isDisabling
                       ? L10n.tr("停止中…", "Turning Off…")
                       : (isEnabled ? L10n.tr("停用连接", "Turn Off Connection") : L10n.tr("启用连接", "Turn On Connection"))) {
                    if isEnabled {
                        requestDisableHAConnection()
                    } else {
                        _ = store.setHAConnectionEnabled(true)
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: !isEnabled && !isDisabling, tintColor: .accentColor))
                .disabled(isDisabling)
            }
            if isDisabling {
                Text(L10n.tr(
                    "正在停用…",
                    "Turning off…"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            } else if !isEnabled {
                Text(L10n.tr(
                    "已停用，配置与历史已保留",
                    "Turned off; settings and history are kept"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var homeAssistantForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr("Home Assistant 地址 (URL)", "Home Assistant Address (URL)"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                    Spacer()
                    if let firstHA = store.discoveredHAInstances.first {
                        if HAWebSocketProvider.normalizeBaseURL(urlDraft) == firstHA.baseURL {
                            Label(
                                L10n.tr("局域网已识别 · \(firstHA.locationName)", "LAN Detected · \(firstHA.locationName)"),
                                systemImage: "checkmark.seal.fill"
                            )
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(.green)
                        } else {
                            Button(L10n.tr("填入已发现：\(firstHA.hostAndPort)", "Use Found: \(firstHA.hostAndPort)")) {
                                urlDraft = firstHA.baseURL
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                TextField("http://homeassistant.local:8123", text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                if HAConnectionSaveGuard.showsPlaintextWarning(forDraft: urlDraft) {
                    Label(L10n.tr("当前为明文 HTTP，建议改用 HTTPS", "This is plain HTTP; use HTTPS instead"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr("访问密钥 (Access Token)", "Access Token"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                    Spacer()
                    if let secURL = URL(string: "\(HAWebSocketProvider.normalizeBaseURL(HAConnectionSaveGuard.effectiveURL(urlDraft)))/profile/security") {
                        Button(L10n.tr("打开网页取钥匙", "Open Security Page")) {
                            NSWorkspace.shared.open(secURL)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }
                SecureField(L10n.tr("粘贴 Home Assistant 专属连接钥匙", "Paste Home Assistant Access Token"), text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                Text(L10n.tr(
                    "在 HA「个人资料 → 安全」底部创建",
                    "Create one at the bottom of Profile → Security in HA"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                if let reason = disconnectReason {
                    Label(reason, systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The card is anchored as a whole for the server address; the token field earns its own
            // anchor because "令牌" is what people search for and it sits below the fold of that card.
            .settingsRow(anchor: .haToken)
        }
    }

    private var connectionBadgeText: String {
        switch store.panelHealth {
        case .ok where store.homeBackend == .demo:
            return L10n.tr("● 示例家庭", "● Demo Home")
        case .ok:
            return L10n.tr("● 已连接", "● Connected")
        case .connecting:
            return L10n.tr("● 连接中…", "● Connecting…")
        case .degraded:
            return L10n.tr("● 部分可用", "● Partially available")
        case .blocked:
            return L10n.tr("● 未连接", "● Disconnected")
        case .notConfigured:
            return L10n.tr("未配置数据源", "No data source configured")
        }
    }

    private var connectionBadgeColor: Color {
        switch store.panelHealth {
        case .ok where store.homeBackend == .demo:
            return .secondary
        case .ok:
            return .green
        case .connecting, .degraded:
            return .orange
        case .blocked, .notConfigured:
            return .red
        }
    }

    private var connectionBadgeHelp: String {
        switch store.panelHealth {
        case .degraded(let reason), .blocked(let reason, _):
            return reason
        case .notConfigured:
            return L10n.tr("未配置数据源", "No data source configured")
        case .ok, .connecting:
            return disconnectReason ?? ""
        }
    }

    private var disconnectReason: String? {
        guard store.homeBackend != .demo, store.isHAConnectionEnabled else {
            return nil
        }
        let haStatus = store.sourceStatuses[.homeAssistant]
            ?? (store.hasEnabledMiSource ? nil : store.connectionStatus)
        guard case .disconnected(let reason) = haStatus else {
            return nil
        }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - AI Assistant

private struct AssistantSettingsTab: View {
    let store: HomeStore

    var body: some View {
        let _ = store.effectiveLanguage
        VStack(alignment: .leading, spacing: 16) {
            AssistantSettingsSection(store: store)
        }
    }
}

// MARK: - Shared Notification Rationale (#55)

struct NotificationRationaleCard: View {
    let onDismiss: () -> Void
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                L10n.tr("为什么需要通知权限？", "Why do notifications need permission?"),
                systemImage: "bell.badge"
            )
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))

            Text(L10n.tr(
                "用于推送安全提醒与定时通知",
                "Used for safety alerts and timer notices"
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.tr("暂不", "Not Now"), action: onDismiss)
                    .buttonStyle(PillActionButtonStyle())

                Button(L10n.tr("允许通知", "Allow Notifications"), action: onAllow)
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
        }
        .padding(9)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
        )
    }
}

// MARK: - Safety & Alerts (WP3c)

enum SafetySettingsDisclosure {
    struct State: Equatable, Sendable {
        var isDoorbellAdvancedExpanded: Bool = false
        var isAllOffScopeExpanded: Bool = false
        private(set) var hasAppliedInitialDefaults = false

        init(
            isDoorbellAdvancedExpanded: Bool = false,
            isAllOffScopeExpanded: Bool = false
        ) {
            self.isDoorbellAdvancedExpanded = isDoorbellAdvancedExpanded
            self.isAllOffScopeExpanded = isAllOffScopeExpanded
        }

        mutating func applyInitialDefaultsIfNeeded(doorbellPopupSeconds: Int) {
            guard !hasAppliedInitialDefaults else { return }
            hasAppliedInitialDefaults = true
            if SafetySettingsDisclosure.hasNonDefaultDoorbellPopupSeconds(doorbellPopupSeconds) {
                isDoorbellAdvancedExpanded = true
            }
        }

        mutating func expandForHighlightIfNeeded(_ anchor: SettingsAnchor?) {
            if SafetySettingsDisclosure.shouldExpandDoorbellAdvanced(forHighlight: anchor) {
                isDoorbellAdvancedExpanded = true
            }
            if SafetySettingsDisclosure.shouldExpandAllOffScope(forHighlight: anchor) {
                isAllOffScopeExpanded = true
            }
        }
    }

    static func hasNonDefaultDoorbellPopupSeconds(_ seconds: Int) -> Bool {
        seconds != HomeStore.defaultDoorbellPopupSeconds
    }

    static func shouldExpandDoorbellAdvanced(forHighlight anchor: SettingsAnchor?) -> Bool {
        anchor == .doorbellAutoCloseSeconds
    }

    static func shouldExpandAllOffScope(forHighlight anchor: SettingsAnchor?) -> Bool {
        anchor == .allOffScope
    }
}

private struct PrivacySettingsTab: View {
    let store: HomeStore
    @Binding var disclosure: SafetySettingsDisclosure.State
    @Environment(\.settingsSearchFocus) private var searchFocus
    @State private var showNotificationRationale = false
    @State private var confirmsAdvancedFacetWrites = false
    @State private var confirmsDirectControl = false
    @AppStorage(URLDirectControl.allowDirectControlKey) private var allowDirectControl = false
    @AppStorage(ScreenSharingPrivacy.storageKey) private var hideFromScreenSharing = false

    private var notifications: NotificationPermissionState { .shared }

    var body: some View {
        let _ = store.effectiveLanguage
        let configurableDevices = store.allOffConfigurableDevices
        let includedCount = store.allOffIncludedDevices.count

        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: L10n.tr("投屏隐私", "Screen Sharing Privacy"), anchor: .hideFromScreenSharing) {
                SettingsToggleRow(
                    title: L10n.tr("共享屏幕时隐藏面板与摄像机窗口", "Hide from screen sharing"),
                    isOn: Binding(
                        get: { hideFromScreenSharing },
                        set: { ScreenSharingPrivacy.shared.setHidden($0) }
                    )
                )
                Text(L10n.tr(
                    "仅对兼容的共享工具生效",
                    "Works only with compatible sharing tools"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: L10n.tr("锁屏控制", "Lock-Screen Protection"), anchor: .blockControlWhileLocked) {
                SettingsToggleRow(
                    title: L10n.tr("锁屏时禁止控制设备", "Block device control while locked"),
                    isOn: Binding(
                        get: { store.blockControlWhileLocked },
                        set: { store.blockControlWhileLocked = $0 }
                    )
                )
                Text(L10n.tr(
                    "不影响定时任务与自动化规则",
                    "Timers and automation rules still run"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: L10n.tr("守护提醒与通知", "Safety Alerts & Notifications")) {
                SettingsToggleRow(
                    title: L10n.tr("主动安全与低电量提醒", "Safety & Low Battery Alerts"),
                    isOn: Binding(
                        get: { store.enableSafetyAlerts },
                        set: { enabled in
                            store.enableSafetyAlerts = enabled
                            if enabled { askForNotificationsIfNeeded() }
                        }
                    )
                )
                .settingsRow(anchor: .safetyAlerts)

                ForEach(SensorAlertKind.allCases) { kind in
                    SettingsToggleRow(
                        title: kind.settingsTitle,
                        isOn: Binding(
                            get: { store.isSensorAlertEnabled(kind) },
                            set: { enabled in
                                store.setSensorAlertEnabled(kind, enabled)
                                if enabled { askForNotificationsIfNeeded() }
                            }
                        )
                    )
                }
                .settingsRow(anchor: .sensorAlerts)

                SettingsToggleRow(
                    title: L10n.tr(
                        "门窗与移动仅在离开或锁屏时提醒",
                        "Door and motion only when away or locked"
                    ),
                    isOn: Binding(
                        get: { store.sensorAlertsOnlyWhenAway },
                        set: { store.sensorAlertsOnlyWhenAway = $0 }
                    )
                )
                .settingsRow(anchor: .alertsOnlyWhenAway)

                Divider().overlay(Color.primary.opacity(0.06))

                SettingsToggleRow(
                    title: L10n.tr("门铃响时自动弹出摄像头画面", "Show the doorbell camera when it rings"),
                    isOn: Binding(
                        get: { store.doorbellAutoPopup },
                        set: { enabled in
                            store.doorbellAutoPopup = enabled
                            if enabled { askForNotificationsIfNeeded() }
                        }
                    )
                )
                .settingsRow(anchor: .doorbellAutoView)

                SettingsToggleRow(
                    title: L10n.tr("门铃响时播放提示音", "Play a chime when the doorbell rings"),
                    isOn: Binding(
                        get: { store.doorbellChime },
                        set: { enabled in
                            store.doorbellChime = enabled
                            if enabled { askForNotificationsIfNeeded() }
                        }
                    )
                )
                .settingsRow(anchor: .doorbellChime)

                if !store.hasMiSource && !store.hasHASource && store.homeBackend != .demo {
                }

                DisclosureGroup(isExpanded: $disclosure.isDoorbellAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(L10n.tr("门铃画面自动收起", "Close the doorbell view after"))
                                .font(.system(size: DesignTokens.TypeSize.caption))
                                .foregroundStyle(DesignTokens.secondaryText)
                            Spacer()
                            Stepper(
                                value: Binding(get: { store.doorbellPopupSeconds }, set: { store.doorbellPopupSeconds = $0 }),
                                in: HomeStore.doorbellPopupSecondsRange,
                                step: 15
                            ) {
                                Text(L10n.tr("\(store.doorbellPopupSeconds) 秒", "\(store.doorbellPopupSeconds) s"))
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                                    .monospacedDigit()
                            }
                            .fixedSize()
                        }
                        .disabled(!store.doorbellAutoPopup)

                        if !store.doorbellAutoPopup {
                            Text(L10n.tr(
                                "请先开启「门铃响时自动弹出摄像头画面」。",
                                "Turn on “Show the doorbell camera when it rings” first."
                            ))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(DesignTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                    .settingsRow(anchor: .doorbellAutoCloseSeconds)
                } label: {
                    Text(L10n.tr("高级门铃选项", "Advanced Doorbell Options"))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(DesignTokens.secondaryText)
                }

                Divider().overlay(Color.primary.opacity(0.06))

                NotificationPermissionRow()
                    .settingsRow(anchor: .notificationPermission)

                if showNotificationRationale {
                    NotificationRationaleCard(
                        onDismiss: { showNotificationRationale = false },
                        onAllow: {
                            showNotificationRationale = false
                            Task {
                                _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization()
                            }
                        }
                    )
                }
            }

            SettingsSection(title: L10n.tr("全关范围", "All Off Scope"), anchor: .allOffScope) {
                HStack(spacing: 12) {
                    Text(L10n.tr("已包含 \(includedCount) 台设备", "\(includedCount) device(s) included"))
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
                        .monospacedDigit()

                    Spacer(minLength: 8)

                    Button(disclosure.isAllOffScopeExpanded
                           ? L10n.tr("收起", "Done")
                           : L10n.tr("修改", "Edit")) {
                        disclosure.isAllOffScopeExpanded.toggle()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .frame(minHeight: DesignTokens.Settings.rowHeight)

                Text(L10n.tr(
                    "插座、扫地机等默认不参与",
                    "Plugs, vacuums and similar are left out by default"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                if disclosure.isAllOffScopeExpanded {
                    Divider().overlay(Color.primary.opacity(0.06))

                    if configurableDevices.isEmpty {
                        Text(L10n.tr(
                            "当前没有可配置全关范围的设备。连接家庭并同步设备后，可在此单独调整每台设备是否参与全关。",
                            "No configurable devices right now. Once your home is connected and synced, you can choose which devices join All Off here."
                        ))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(configurableDevices) { dev in
                            let defaultIncluded = HomeStore.joinsAllOffByDefault(dev)
                            HStack(spacing: 8) {
                                Image(systemName: dev.sfSymbolName)
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                    .foregroundStyle(DesignTokens.secondaryText)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dev.name)
                                        .font(.system(size: DesignTokens.TypeSize.body))
                                    Text(
                                        "\(L10n.displayRoomName(dev.roomName)) · " +
                                        (defaultIncluded
                                            ? L10n.tr("默认包含", "Included by default")
                                            : L10n.tr("默认排除", "Excluded by default"))
                                    )
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                                    .foregroundStyle(DesignTokens.secondaryText)
                                }

                                Spacer(minLength: 12)

                                Toggle(
                                    dev.name,
                                    isOn: Binding(
                                        get: { store.joinsAllOff(dev) },
                                        set: { store.setJoinsAllOff($0, deviceId: dev.id) }
                                    )
                                )
                                .labelsHidden()
                                .glassLabelHidden()
                                .toggleStyle(.glass)
                                .controlSize(.regular)
                            }
                            .frame(minHeight: DesignTokens.Settings.rowHeight)
                        }
                    }
                }
            }

            SettingsSection(title: L10n.tr("高级控制权限", "High-Risk Control Permissions")) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggleRow(
                        title: L10n.tr(
                            "允许「更多设置」写入次要控件",
                            "Allow secondary controls under More Settings"
                        ),
                        isOn: Binding(
                            get: { store.allowAdvancedFacetWrites },
                            set: { newValue in
                                if newValue && !store.allowAdvancedFacetWrites {
                                    confirmsAdvancedFacetWrites = true
                                } else {
                                    store.allowAdvancedFacetWrites = newValue
                                }
                            }
                        )
                    )
                    .confirmationDialog(
                        L10n.tr("允许写入次要控件？", "Allow secondary writes?"),
                        isPresented: $confirmsAdvancedFacetWrites,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.tr("允许写入", "Allow writes"), role: .destructive) {
                            store.allowAdvancedFacetWrites = true
                        }
                        Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
                    } message: {
                        Text(L10n.tr(
                            "开启后，加热、门锁、阀门、路由器配置等高风险操作在执行前仍会再次确认。只修改你确认设备支持的项目。",
                            "High-risk operations such as heating, locks, valves, and router configuration still ask for confirmation before they run. Only change settings you know the device supports."
                        ))
                    }

                    Label(
                        L10n.tr(
                            "允许写入次要控件，高风险仍需确认",
                            "Enables secondary writes; high-risk actions still ask first"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow(anchor: .advancedDeviceWrites)

                Divider().overlay(Color.primary.opacity(0.06))

                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggleRow(
                        title: L10n.tr("允许外部链接直控（跳过确认）", "Allow external URL control without confirmation"),
                        isOn: Binding(
                            get: { allowDirectControl },
                            set: { newValue in
                                if newValue && !allowDirectControl {
                                    confirmsDirectControl = true
                                } else {
                                    allowDirectControl = newValue
                                }
                            }
                        )
                    )
                    .confirmationDialog(
                        L10n.tr("允许外部链接直接控制设备？", "Let external links control devices directly?"),
                        isPresented: $confirmsDirectControl,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.tr("允许直控", "Allow"), role: .destructive) {
                            allowDirectControl = true
                        }
                        Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
                    } message: {
                        Text(L10n.tr(
                            "任何能打开链接的网页或 App 都可以直接执行：单个设备的开关里，门锁、阀门、加热等高风险设备仍会单独确认；场景和 Home Assistant 脚本会直接运行，不再逐次确认。开启「锁屏时禁止控制设备」时，锁屏期间的链接会被拦截。",
                            "Any web page or app that can open a link will run it directly. Switching a single high-risk device (locks, valves, heaters) still asks; scenes and Home Assistant scripts run without asking. With “Block device control while locked” on, links are blocked while the screen is locked."
                        ))
                    }

                    Label(
                        L10n.tr(
                            "场景与脚本直接运行，高风险操作仍需确认",
                            "Scenes and scripts run directly; high-risk actions still ask first"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow(anchor: .allowURLControl)

                Divider().overlay(Color.primary.opacity(0.06))

                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggleRow(
                        title: L10n.tr(
                            "在系统搜索（Spotlight）里找到设备、房间与场景",
                            "Show devices, rooms and scenes in Spotlight search"
                        ),
                        isOn: Binding(
                            get: { store.spotlightIndexEnabled },
                            set: { store.spotlightIndexEnabled = $0 }
                        )
                    )

                    Text(L10n.tr(
                        "仅索引名称，不含账号与密钥",
                        "Names only; no accounts or keys"
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .settingsRow(anchor: .spotlightIndex)
            }
        }
        .task { await HotkeyAndNotificationManager.shared.refreshNotificationPermission() }
        .onAppear {
            disclosure.applyInitialDefaultsIfNeeded(doorbellPopupSeconds: store.doorbellPopupSeconds)
            disclosure.expandForHighlightIfNeeded(searchFocus?.highlight)
        }
        .onChange(of: searchFocus?.highlight) { _, highlight in
            disclosure.expandForHighlightIfNeeded(highlight)
        }
    }

    /// In-app explanation first, system prompt second (#55).
    private func askForNotificationsIfNeeded() {
        if HotkeyAndNotificationManager.hasRequestedNotificationAuthorization {
            if notifications.canRequest {
                Task { _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization() }
            }
            return
        }
        if notifications.isDenied { return }
        showNotificationRationale = true
    }
}

// MARK: - About & Diagnostics (WP3c)

enum AboutSettingsDisclosure {
    struct State: Equatable, Sendable {
        var isResetExpanded: Bool = false

        init(isResetExpanded: Bool = false) {
            self.isResetExpanded = isResetExpanded
        }

        mutating func expandForHighlightIfNeeded(_ anchor: SettingsAnchor?) {
            if AboutSettingsDisclosure.shouldExpandReset(forHighlight: anchor) {
                isResetExpanded = true
            }
        }
    }

    static func shouldExpandReset(forHighlight anchor: SettingsAnchor?) -> Bool {
        anchor == .signOut
    }
}

enum UnsupportedDeviceGrouping {
    struct Group: Identifiable, Equatable, Sendable {
        let reason: UnsupportedDevice.Reason
        let title: String
        let devices: [UnsupportedDevice]

        var id: String { reason.rawValue }
        var count: Int { devices.count }
    }

    static func group(_ devices: [UnsupportedDevice]) -> [Group] {
        guard !devices.isEmpty else { return [] }
        let bucketed = Dictionary(grouping: devices, by: \.reason)
        return UnsupportedDevice.Reason.allCases.compactMap { reason in
            guard let items = bucketed[reason], let first = items.first else { return nil }
            return Group(reason: reason, title: first.reasonText, devices: items)
        }
    }
}

private struct ScannerResetKey: Equatable {
    let homeBackend: HomeBackend
    let accountIDs: [String]
    let hasEnabledHASource: Bool
    let serverURL: String
}

private struct DiagnosticsRefreshKey: Equatable {
    let hasHASource: Bool
    let unsupportedDevices: [UnsupportedDevice]
    let errorTimestamps: [Date]
    let deviceCount: Int
    let onlineCount: Int
    let hiddenCount: Int
    let language: AppLanguage
}

private struct AboutSettingsTab: View {
    let store: HomeStore
    @Binding var disclosure: AboutSettingsDisclosure.State
    @Environment(\.settingsSearchFocus) private var searchFocus
    @Environment(\.settingsUnsavedChanges) private var unsaved
    @State private var didCopy = false
    @State private var showsDiagnosticsPreview = false
    @State private var diagnosticsPreviewMarkdown = ""
    @State private var confirmsRevoke = false

    private var scanner: UnsupportedDeviceScanner { .shared }
    private var errorLog: AppDiagnosticsLog { .shared }

    private var scannerResetKey: ScannerResetKey {
        ScannerResetKey(
            homeBackend: store.homeBackend,
            accountIDs: store.enabledMiAccounts.map(\.id),
            hasEnabledHASource: store.hasEnabledHASource,
            serverURL: store.serverURLString
        )
    }

    private var diagnosticsRefreshKey: DiagnosticsRefreshKey {
        DiagnosticsRefreshKey(
            hasHASource: store.hasHASource,
            unsupportedDevices: scanner.devices,
            errorTimestamps: errorLog.errorTimestamps,
            deviceCount: store.devices.count,
            onlineCount: store.onlineDeviceCount,
            hiddenCount: store.hiddenDevices.count,
            language: store.effectiveLanguage
        )
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        let _ = store.effectiveLanguage

        aboutContent
            .onAppear {
                scanner.invalidateIfContextChanged(for: store)
                refreshDiagnosticsPreviewIfNeeded()
                disclosure.expandForHighlightIfNeeded(searchFocus?.highlight)
            }
            .onChange(of: searchFocus?.highlight) { _, highlight in
                disclosure.expandForHighlightIfNeeded(highlight)
            }
            .onChange(of: showsDiagnosticsPreview) { _, isExpanded in
                guard isExpanded else { return }
                scanner.invalidateIfContextChanged(for: store)
                diagnosticsPreviewMarkdown = buildDiagnosticsMarkdown()
            }
            .onChange(of: scannerResetKey) { _, _ in
                scanner.reset()
                refreshDiagnosticsPreviewIfNeeded()
            }
            .onChange(of: diagnosticsRefreshKey) { oldKey, newKey in
                if oldKey.hasHASource != newKey.hasHASource {
                    scanner.invalidateIfContextChanged(for: store)
                }
                refreshDiagnosticsPreviewIfNeeded()
            }
            .alert(L10n.tr("退出米家并清除 HA 与 AI 密钥？", "Sign out of Xiaomi Home and clear HA and AI keys?"), isPresented: $confirmsRevoke) {
                Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
                Button(L10n.tr("退出并清除", "Sign Out & Clear"), role: .destructive) {
                    scanner.reset()
                    store.signOutAndRevokeAll()
                    refreshDiagnosticsPreviewIfNeeded()
                }
            } message: {
                Text(L10n.tr(
                    "米家会话、HA 访问密钥、AI 密钥与云端授权将从本机删除；摄像机与电视凭据、历史和偏好保留。",
                    "Xiaomi Home sessions, the HA access token, AI keys and cloud consent are removed from this Mac; camera and TV credentials, history and preferences stay."
                ))
            }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            aboutHeader

            UpdateSection(store: store)

            if store.hasCompletedOnboarding {
                aboutSetupGuide
            }

            aboutPrivacy

            aboutDiagnostics

            aboutUnsupportedDevices

            aboutAdvancedReset

            aboutQuit
        }
    }

    private var aboutHeader: some View {
        SettingsSection(title: L10n.tr("关于 MenuBarHome", "About MenuBarHome"), anchor: .aboutVersion) {
            HStack(spacing: 10) {
                Image(systemName: "house.fill")
                    .font(.system(size: DesignTokens.TypeSize.title, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(
                            colors: [Color.orange, DesignTokens.active],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("MenuBarHome")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .bold))
                    Text(L10n.tr("版本 \(appVersion) (\(buildNumber))", "Version \(appVersion) (\(buildNumber))"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .monospacedDigit()
                }

                Spacer()

                if store.homeBackend == .demo {
                    Text(L10n.tr("演示模式", "Demo Mode"))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                Link(L10n.tr("项目主页", "Repository"), destination: URL(string: "https://github.com/jryang2026-code/MenuBarHome")!)
                Link(L10n.tr("问题反馈", "Issues"), destination: URL(string: "https://github.com/jryang2026-code/MenuBarHome/issues")!)
                Link(L10n.tr("更新日志", "Releases"), destination: URL(string: "https://github.com/jryang2026-code/MenuBarHome/releases")!)
                Spacer()
            }
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
        }
    }

    private var aboutSetupGuide: some View {
        SettingsSection(title: L10n.tr("初始设置引导", "Setup Guide"), anchor: .setupGuide) {
            HStack(spacing: 12) {

                Spacer(minLength: 8)

                Button {
                    guard ContinueOnboardingSection.reopenIfUnsavedResolved(store: store, unsaved: unsaved) else {
                        return
                    }
                    NSApp.keyWindow?.orderOut(nil)
                    HotkeyAndNotificationManager.shared.ensureMenuBarExtraWindowVisible()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text(L10n.tr("重新查看初始设置引导", "Reopen Setup Guide"))
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
    }

    private var aboutPrivacy: some View {
        SettingsSection(title: L10n.tr("隐私", "Privacy"), anchor: .privacyNotes) {
            privacyBullet(L10n.tr("语音只在本机识别时可完全离线；不支持的语种会提示改用苹果服务器。", "On-device speech stays on this Mac; unsupported languages say they fall back to Apple's servers."))
            privacyBullet(L10n.tr("诊断报告不含设备 ID、令牌、服务器地址或账号信息。", "Diagnostics never include device IDs, tokens, server addresses or account info."))
            privacyBullet(L10n.tr("演示模式完全离线，不发起任何网络请求。", "Demo mode is fully offline and sends no requests."))
            privacyBullet(L10n.tr("最近错误只记录次数与时间，不保存错误原文。", "Recent errors are counted by time only; the raw text is not stored."))
        }
    }

    @ViewBuilder
    private var aboutDiagnostics: some View {
        let errorTimestamps = errorLog.errorTimestamps

        SettingsSection(title: L10n.tr("诊断与排障工具", "Diagnostics & Troubleshooting"), anchor: .copyDiagnostics) {
            Text(L10n.tr(
                "不含账号、密钥与设备 ID",
                "No accounts, keys or device IDs"
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if let lastErrorAt = errorTimestamps.last {
                Text(L10n.tr(
                    "近期错误：\(errorTimestamps.count) 次（最近一次 \(lastErrorAt.formatted(date: .abbreviated, time: .shortened))）",
                    "Recent errors: \(errorTimestamps.count), latest \(lastErrorAt.formatted(date: .abbreviated, time: .shortened))"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button {
                    copyDiagnostics()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text(L10n.tr(
                            "复制脱敏诊断报告",
                            "Copy Diagnostics Report"
                        ))
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                if didCopy {
                    Label(L10n.tr("已复制", "Copied"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(.green)
                }

                Spacer()

                Button(L10n.tr("打开 GitHub Issues", "Open GitHub Issues")) {
                    if let url = URL(string: "https://github.com/jryang2026-code/MenuBarHome/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PillActionButtonStyle())
            }

            HStack(alignment: .top, spacing: 8) {
                Button {
                    openFeedbackIssue()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.bubble")
                        Text(L10n.tr("反馈问题", "Report a Problem"))
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                Text(L10n.tr("打开 GitHub 并复制脱敏诊断", "Opens GitHub and copies redacted diagnostics"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $showsDiagnosticsPreview) {
                Text(diagnosticsPreviewMarkdown)
                    .font(.system(size: DesignTokens.TypeSize.control, design: .monospaced))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
                    )
                    .padding(.top, 4)
            } label: {
                Text(L10n.tr("预览排障报告内容", "Preview Diagnostics Report"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(DesignTokens.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var aboutUnsupportedDevices: some View {
        let unsupportedGroups = UnsupportedDeviceGrouping.group(scanner.devices)

        SettingsSection(title: L10n.tr("未能显示在面板的设备", "Devices Not Shown in the Panel"), anchor: .scanUnsupportedDevices) {
            Text(L10n.tr(
                "查找未在面板显示的设备",
                "Find devices the panel doesn't show"
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let scannedAt = scanner.lastScannedAt, !scanner.isScanning {
                    Text(L10n.tr("上次扫描：\(scannedAt.formatted(date: .abbreviated, time: .shortened))", "Last scan: \(scannedAt.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
                Spacer()
                Button(scanner.isScanning
                       ? L10n.tr("扫描中…", "Scanning…")
                       : L10n.tr("扫描未能显示的设备", "Scan Hidden Devices")) {
                    Task { await scanner.scan(store: store) }
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(scanner.isScanning)
            }

            if let error = scanner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !scanner.isScanning && scanner.lastScannedAt != nil && unsupportedGroups.isEmpty && scanner.errorMessage == nil {
                Label(L10n.tr("没有发现被跳过的设备", "No skipped devices found"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.green)
            }

            ForEach(unsupportedGroups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Divider().overlay(Color.primary.opacity(0.06))

                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        Spacer()
                        Text(L10n.tr("\(group.count) 台", "\(group.count) device(s)"))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(DesignTokens.secondaryText)
                            .monospacedDigit()
                    }

                    ForEach(group.devices) { device in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "questionmark.square.dashed")
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                .foregroundStyle(DesignTokens.secondaryText)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                Text(device.model.isEmpty ? L10n.tr("未知型号", "Unknown model") : device.model)
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                                    .foregroundStyle(DesignTokens.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            if let url = UnsupportedDeviceFeedbackURL.make(for: device) {
                                Link(destination: url) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.up.right.square")
                                        Text(L10n.tr("去 GitHub 反馈", "Report on GitHub"))
                                    }
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var aboutAdvancedReset: some View {
        SettingsSection(title: L10n.tr("高级排障与重置", "Advanced Troubleshooting & Reset")) {
            DisclosureGroup(isExpanded: $disclosure.isResetExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.tr("退出米家并清除 HA 与 AI 密钥", "Sign Out of Xiaomi Home & Clear HA and AI Keys"))
                                .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))

                            Text(L10n.tr(
                                "摄像机与电视凭据、本地偏好保留",
                                "Camera and TV credentials and local preferences stay"
                            ))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(DesignTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Button(L10n.tr("退出并清除…", "Sign Out & Clear…")) {
                            confirmsRevoke = true
                        }
                        .buttonStyle(PillActionButtonStyle())
                    }
                    .padding(.top, 6)
                    .settingsRow(anchor: .signOut)
                }
            } label: {
                Text(L10n.tr("清除米家、HA 与 AI 凭据", "Clear Xiaomi Home, HA and AI credentials"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(DesignTokens.secondaryText)
            }
        }
    }

    private var aboutQuit: some View {
        SettingsSection(title: L10n.tr("退出", "Quit"), anchor: .quitApp) {
            HStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text(L10n.tr("退出 MenuBarHome", "Quit MenuBarHome"))
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func privacyBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.green)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshDiagnosticsPreviewIfNeeded() {
        guard showsDiagnosticsPreview else { return }
        diagnosticsPreviewMarkdown = buildDiagnosticsMarkdown()
    }

    private func buildDiagnosticsMarkdown() -> String {
        let info = Bundle.main.infoDictionary
        let models = Dictionary(grouping: store.devices, by: { $0.model })
            .map { DiagnosticsReportBuilder.ModelCount(model: $0.key, count: $0.value.count) }
        let crashTimestamps = DiagnosticsReportBuilder.crashTimestamps(
            from: AppDiagnosticsLog.crashReportStamps()
        )
        let input = DiagnosticsReportBuilder.Input(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            buildNumber: info?["CFBundleVersion"] as? String ?? "-",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            backendTitle: store.connectionSourceSummary,
            miCloudRegion: store.hasMiSource ? store.miCloudRegion.title : "-",
            deviceCount: store.devices.count,
            onlineDeviceCount: store.onlineDeviceCount,
            hiddenDeviceCount: store.hiddenDevices.count,
            models: models,
            unsupported: scanner.devices,
            recentErrorCount: errorLog.errorTimestamps.count,
            lastErrorAt: errorLog.errorTimestamps.last,
            recentCrashTimestamps: crashTimestamps,
            extraSettings: [
                L10n.tr("快捷键", "Shortcut") + ": " + HotkeyPreferences.load().displayString,
                L10n.tr("本机语音", "On-device speech") + ": " + (store.prefersOnDeviceSpeech ? "on" : "off"),
            ],
            miHomeCount: store.hasMiSource ? store.homes.count : nil,
            miSharedHomeCount: store.hasMiSource ? store.homes.filter(\.isSharedHome).count : nil,
            isMiHomeFiltered: store.hasMiSource && store.selectedMiHomeId != nil,
            transportSummary: DeviceTransportSummary.summarize(
                store.deviceTransportDiagnostics,
                localNetworkBlocks: store.effectiveLocalNetworkBlocks
            )
        )
        return DiagnosticsReportBuilder.markdown(input)
    }

    private func copyDiagnostics() {
        scanner.invalidateIfContextChanged(for: store)
        let markdown = buildDiagnosticsMarkdown()
        if showsDiagnosticsPreview {
            diagnosticsPreviewMarkdown = markdown
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    /// What the one-click feedback link carries into a GitHub issue (#29).
    ///
    /// Only counts and closed-set labels: the block cannot name a device, a home, a host or an
    /// account, so there is nothing here to redact (the builder still runs its scrubber as a backstop).
    private func buildFeedbackDiagnostics() -> FeedbackDiagnostics {
        FeedbackDiagnosticsComposer.make(
            store: store,
            appVersion: appVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            errorTimestamps: errorLog.errorTimestamps,
            crashCount: DiagnosticsReportBuilder.crashSummary(
                DiagnosticsReportBuilder.crashTimestamps(from: AppDiagnosticsLog.crashReportStamps())
            ).count,
            transport: DeviceTransportSummary.summarize(
                store.deviceTransportDiagnostics,
                localNetworkBlocks: store.effectiveLocalNetworkBlocks
            )
        )
    }

    /// Opens the prefilled issue in the browser and puts the same block on the pasteboard.
    ///
    /// Nothing is filed here: the person reads the form and presses Submit, which is also why the
    /// clipboard copy matters — a form that ignores the prefill would otherwise lose the block.
    private func openFeedbackIssue() {
        let diagnostics = buildFeedbackDiagnostics()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnostics.text, forType: .string)
        guard let url = diagnostics.issueURL() else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - LG webOS

enum LGWebOSSettingsSaveGuard {
    struct WakeDisclosureState: Equatable, Sendable {
        var isExpanded: Bool = false
        private(set) var hasAppliedInitialDefaults = false

        init(isExpanded: Bool = false, hasAppliedInitialDefaults: Bool = false) {
            self.isExpanded = isExpanded
            self.hasAppliedInitialDefaults = hasAppliedInitialDefaults
        }

        mutating func applyInitialDefaultsIfNeeded(macAddress: String) {
            guard !hasAppliedInitialDefaults else { return }
            hasAppliedInitialDefaults = true
            if !macAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isExpanded = true
            }
        }

        mutating func expandForHighlightIfNeeded(_ highlight: SettingsAnchor?) {
            if highlight == .lgTV {
                isExpanded = true
            }
        }
    }

    @MainActor
    @discardableResult
    static func toggleEnabled(
        _ newValue: Bool,
        isEnabled: inout Bool,
        hostDraft: String,
        macDraft: String,
        in store: HomeStore
    ) -> Bool {
        guard newValue != store.lgConfig.isEnabled else { return true }
        var next = store.lgConfig
        next.isEnabled = newValue
        next.host = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        next.macAddress = macDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = store.updateLGWebOSConfig(next)
        isEnabled = store.lgConfig.isEnabled
        return saved
    }

    @MainActor
    @discardableResult
    static func saveDrafts(
        isEnabled: inout Bool,
        hostDraft: inout String,
        macDraft: inout String,
        in store: HomeStore
    ) -> Bool {
        var next = store.lgConfig
        next.isEnabled = isEnabled
        next.host = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        next.macAddress = macDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = store.updateLGWebOSConfig(next)
        isEnabled = store.lgConfig.isEnabled
        if saved {
            hostDraft = store.lgConfig.host
            macDraft = store.lgConfig.macAddress
        }
        return saved
    }

    @MainActor
    @discardableResult
    static func pairTV(
        isEnabled: inout Bool,
        hostDraft: inout String,
        macDraft: inout String,
        in store: HomeStore
    ) -> Bool {
        guard saveDrafts(isEnabled: &isEnabled, hostDraft: &hostDraft, macDraft: &macDraft, in: store) else {
            return false
        }
        store.triggerLGWebOSPairing()
        return true
    }

    @MainActor
    @discardableResult
    static func resetTrustAndPair(
        isEnabled: inout Bool,
        hostDraft: inout String,
        macDraft: inout String,
        in store: HomeStore
    ) -> Task<Bool, Never>? {
        guard saveDrafts(isEnabled: &isEnabled, hostDraft: &hostDraft, macDraft: &macDraft, in: store) else {
            return nil
        }
        return store.resetLGWebOSTrustAndPair()
    }
}

struct LGWebOSSettingsSection: View {
    let store: HomeStore
    @Binding var wakeDisclosure: LGWebOSSettingsSaveGuard.WakeDisclosureState
    @State private var isEnabled: Bool = false
    @State private var hostDraft: String = ""
    @State private var macDraft: String = ""
    @State private var isScanning: Bool = false
    @State private var confirmsTrustReset = false
    @Environment(\.settingsSearchFocus) private var searchFocus

    var body: some View {
        let _ = store.effectiveLanguage
        let isPaired = !store.lgConfig.clientKey.isEmpty
        let hasHost = !hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        SettingsSection(title: L10n.tr("LG 电视", "LG TV"), anchor: .lgTV) {
            HStack {
                Spacer()
                Text(isPaired
                     ? L10n.tr("● 已配对密钥", "● Paired")
                     : (isEnabled
                        ? (hasHost ? L10n.tr("● 待电视确认", "● Awaiting TV Prompt") : L10n.tr("● 待填电视 IP", "● Enter TV IP"))
                        : L10n.tr("● 已停用", "● Disabled")))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(isPaired ? .green : (isEnabled ? .orange : .secondary))
            }

            HStack {
                Text(L10n.tr("启用 LG 电视局域网控制", "Enable LG TV LAN Control"))
                    .font(.system(size: DesignTokens.TypeSize.body))
                Spacer()
                Toggle(L10n.tr("启用 LG 电视局域网控制", "Enable LG TV LAN Control"), isOn: $isEnabled)
                    .labelsHidden()
                    .glassLabelHidden()
                    .toggleStyle(.glass)
                    .controlSize(.regular)
                    .onChange(of: isEnabled) { _, newValue in
                        LGWebOSSettingsSaveGuard.toggleEnabled(
                            newValue,
                            isEnabled: &isEnabled,
                            hostDraft: hostDraft,
                            macDraft: macDraft,
                            in: store
                        )
                    }
            }

            if isEnabled {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("电视局域网 IP", "TV LAN IP"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                    TextField(L10n.tr("如 192.168.1.50", "e.g. 192.168.1.50"), text: $hostDraft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                }

                DisclosureGroup(isExpanded: $wakeDisclosure.isExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("电视的网络硬件地址 (MAC)", "TV Network Hardware Address (MAC)"))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(DesignTokens.secondaryText)
                        TextField(L10n.tr("如 AA:BB:CC:DD:EE:FF", "e.g. AA:BB:CC:DD:EE:FF"), text: $macDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                        Text(L10n.tr(
                            "在电视「设置 → 网络」查看",
                            "Find it in TV Settings → Network"
                        ))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                } label: {
                    Text(L10n.tr(
                        "高级：远程开机",
                        "Advanced: Remote Power On"
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(DesignTokens.secondaryText)
                }

                HStack {
                    Button(isScanning ? L10n.tr("查找中…", "Finding…") : L10n.tr("查找局域网电视", "Find TV on LAN")) {
                        isScanning = true
                        Task {
                            let found = await store.discoverLGWebOSTVs(hostHint: hostDraft)
                            isScanning = false
                            Self.handleDiscoveryResult(found, hostHint: hostDraft, store: store) {
                                hostDraft = $0
                            }
                        }
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .disabled(isScanning)

                    Button(L10n.tr("发起电视配对", "Pair TV")) {
                        LGWebOSSettingsSaveGuard.pairTV(
                            isEnabled: &isEnabled,
                            hostDraft: &hostDraft,
                            macDraft: &macDraft,
                            in: store
                        )
                    }
                    .buttonStyle(PillActionButtonStyle())

                    Button(L10n.tr("重新信任电视", "Trust TV Again")) {
                        confirmsTrustReset = true
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .alert(L10n.tr("清除已保存的电视身份？", "Clear the saved TV identity?"), isPresented: $confirmsTrustReset) {
                        Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
                        Button(L10n.tr("重新配对", "Pair Again"), role: .destructive) {
                            LGWebOSSettingsSaveGuard.resetTrustAndPair(
                                isEnabled: &isEnabled,
                                hostDraft: &hostDraft,
                                macDraft: &macDraft,
                                in: store
                            )
                        }
                    } message: {
                        Text(L10n.tr("请先核对电视 IP。确认后将清除旧证书和配对密钥，下次连接会信任新的证书，并要求在电视上重新确认。", "Verify the TV IP first. This clears the saved certificate and pairing key, trusts the certificate on the next connection, and requires confirmation on the TV."))
                    }

                    Spacer()

                    Button(L10n.tr("保存配置", "Save")) {
                        saveDrafts()
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                }
            }
        }
        .onAppear {
            isEnabled = store.lgConfig.isEnabled
            hostDraft = store.lgConfig.host
            macDraft = store.lgConfig.macAddress
            wakeDisclosure.applyInitialDefaultsIfNeeded(macAddress: macDraft)
            wakeDisclosure.expandForHighlightIfNeeded(searchFocus?.highlight)
        }
        .onChange(of: store.lgConfig.isEnabled) { _, newValue in
            isEnabled = newValue
            if newValue {
                wakeDisclosure.applyInitialDefaultsIfNeeded(macAddress: macDraft)
            }
        }
        .onChange(of: searchFocus?.highlight) { _, highlight in
            wakeDisclosure.expandForHighlightIfNeeded(highlight)
        }
    }

    static func handleDiscoveryResult(
        _ found: [LGWebOSDiscoveredTV],
        hostHint: String,
        store: HomeStore,
        applyHost: (String) -> Void
    ) {
        if let first = found.first {
            applyHost(first.host)
            store.showToast(L10n.tr(
                "已发现：\(first.friendlyName) (\(first.host))",
                "Found: \(first.friendlyName) (\(first.host))"
            ))
        } else {
            store.showToast(
                store.lgWebOSDiscoveryFailureMessage(hostHint: hostHint),
                isError: true
            )
        }
    }

    @discardableResult
    private func saveDrafts() -> Bool {
        LGWebOSSettingsSaveGuard.saveDrafts(
            isEnabled: &isEnabled,
            hostDraft: &hostDraft,
            macDraft: &macDraft,
            in: store
        )
    }
}
