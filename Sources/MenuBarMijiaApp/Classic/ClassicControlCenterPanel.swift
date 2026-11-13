import SwiftUI
import AppKit
import Carbon
import MijiaCore

public struct ClassicControlCenterPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelFoldRecord) private var panelFoldRecord
    @AppStorage(PanelPrefs.climatePanelKey) var climatePanelModule: Bool = true
    @State var draggingId: String?
    @State var activeResize: ActiveTileResize?
    @State var tileFrames: [String: CGRect] = [:]
    @State var dragLocation: CGPoint?
    @State var grabOffset: CGSize = .zero
    @State var lastSwapTarget: String?
    @State var lastSwapAt: Date = .distantPast
    @State var pressTask: Task<Void, Never>?
    @State var pressCancelled = false
    @State var pendingScrollToDeviceId: String?
    @AppStorage(GroupPrefs.groupsKey) var groupsRaw: String = "[]"
    @AppStorage(GroupPrefs.collapsedKey) var collapsedRaw: String = "[]"
    @State var hoveredHeader: String?
    @AppStorage(GroupPrefs.aliasesKey) var aliasesRaw: String = "{}"
    // #146: room aliases and order, separate from device prefs so a room rename never touches devices.
    @AppStorage(RoomPrefs.aliasesKey) var roomAliasesRaw: String = "{}"
    @AppStorage(RoomPrefs.orderKey) var roomOrderRaw: String = "[]"
    @State var layoutUI = LayoutUIState.shared
    /// In-memory mirror of a just-committed room order: `@AppStorage` publishes a moment later, so
    /// reading only it would show the pre-session order for one frame (§6.3).
    @State var liveRoomOrder: [String]?
    /// Device-kind chip order (插座、扫地机…), edited in the same order session as rooms.
    @AppStorage(KindOrderPrefs.orderKey) var kindOrderRaw: String = "[]"
    @State var liveKindOrder: [String]?
    /// #60: type-to-search. The query lives outside `@State` because the app-wide key monitor
    /// (`PanelSearchKeyboard`) has to read and write it before AppKit dispatches the event.
    @State var search = PanelSearchState.shared
    @FocusState private var isSearchFieldFocused: Bool
    /// The assistant requests already acted on, so a panel built after one still replays it once.
    @State private var lastHandledVoiceRequest = 0
    /// The pointer is over the scene/suggestion drawer; the drawer stays open so a click can land.
    @State private var isDrawerHovered = false
    @Bindable private var speech = SpeechInputController.shared
    @Environment(\.effectiveReduceMotion) var reduceMotion
    @Environment(\.effectiveReduceTransparency) var reduceTransparency
    /// Opens the ⌘, Settings window; the popover no longer hosts the long form (#42).
    @Environment(\.openSettings) var openSettings
    /// Flips with the menu-bar window so the room strip re-centers on every open.
    @State var isPresented = false
    /// Re-centers the active room pill when the user taps an already-selected pill after scrolling.
    @State var roomScrollTrigger = 0
    @State var kindScrollTrigger = 0
    /// The kind-chip row stays hidden until the user taps the active 全部 pill again.
    @State var kindChipsRevealed = false
    /// Expansion ends on panel close, backend change, or an empty activity feed.
    @State var activitiesExpanded = false
    /// Measured by the transient surface; reset when that surface disappears.
    @State var transientStackHeight: CGFloat = 0
    let initialTransientExpanded: Bool

    /// Card sizes are remembered per page: a room id, or "all" for the overview.
    var layoutScope: String { store.selectedRoomId ?? "all" }
    /// #146: the panel's edit state lives in one shared mode, so the key monitor and every view read
    /// the same value. `isEditingLayout` stays the name the card/panel modifiers already use.
    var isEditingLayout: Bool { layoutUI.editMode == .deviceLayout }
    var isRoomOrdering: Bool { layoutUI.editMode == .roomOrder }
    /// Either edit mode: cards and room pills stop hit-testing while one is active.
    var isEditing: Bool { layoutUI.editMode != .none }
    @AppStorage(PanelHeight.storageKey) private var panelHeightRaw: String = PanelHeight.standard.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    public let store: HomeStore

    private static let panelWidth: CGFloat = 376
    private var panelHeight: CGFloat { (PanelHeight(rawValue: panelHeightRaw) ?? .standard).points }
    var activityViewportHeight: CGFloat { panelHeight / 2 }
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }
    /// The panel sets `panelRoot` on its own body, so it cannot read that environment back;
    /// resolve the effective scheme locally (#51).
    var effectiveScheme: ColorScheme { appearance.colorScheme ?? colorScheme }

    public init(store: HomeStore, initialActivitiesExpanded: Bool = false, initialTransientExpanded: Bool = false) {
        self.store = store
        _activitiesExpanded = State(initialValue: initialActivitiesExpanded)
        self.initialTransientExpanded = initialTransientExpanded
    }
    public var body: some View {
        let _ = (store.effectiveLanguage, store.selectedRoomId, store.rooms.count)
        return dashboardRoot
            .frame(width: Self.panelWidth, height: panelHeight)
            .onChange(of: panelHeightRaw) { _, _ in syncMenuBarWindowSize() }
            .onChange(of: store.lastAssistantActionAt) { _, date in
                UndoAvailabilityTracker.shared.syncAction(at: date)
            }
            .onChange(of: store.assistantState) { _, state in handleAssistantState(state) }
            // #45: the only place that sees every error toast is the panel root.
            .onChange(of: store.toastNotice?.id) { _, _ in handleToastNotice() }
            // Frequently opened utility: show immediately, including keyboard invocation.
            .onReceive(NotificationCenter.default.publisher(for: MenuBarPanelController.didShowNotification)) { _ in
                UndoAvailabilityTracker.shared.syncAction(at: store.lastAssistantActionAt)
                LaunchAtLoginCoordinator.live(store: store).refresh()
                isPresented = true
            }
            .onAppear { handlePanelAppear() }
            // The panel tree survives a close, so a half-typed query would come back on the next open.
            .onReceive(NotificationCenter.default.publisher(for: MenuBarPanelController.didHideNotification)) { _ in
                handlePanelDidHide()
                activitiesExpanded = false
            }
            // Leaving search puts the caret back on the panel, so Esc closes it instead of resigning the field.
            .onChange(of: search.isSearching) { _, searching in handleSearching(searching) }
            .onChange(of: store.homeBackend) { _, _ in activitiesExpanded = false }
            .onChange(of: store.panelActivities.isEmpty) { _, empty in
                if empty { activitiesExpanded = false }
            }
            // #180: typing a query — through the key monitor or the field — ticks the guide's search step.
            .onChange(of: search.query) { _, query in handleSearchQuery(query) }
            // Scenes and suggestions open with the field; make sure the suggestions are fresh by then.
            .onChange(of: isSearchFieldFocused) { _, focused in handleSearchFocus(focused) }
            .transaction { if reduceMotion { $0.disablesAnimations = true } }
            .environment(\.isEditingLayout, isEditingLayout)
            .classicPanelRoot()
            .task {
                await store.checkForUpdatesIfNeeded()
            }
    }

    /// The dashboard plus the hooks that only react to state the panel itself owns. Kept out of
    /// `body` on purpose: one 30-modifier chain made CI's compiler give up with "unable to
    /// type-check this expression in reasonable time", so the chain is split in two.
    private var dashboardRoot: some View {
        let _ = (store.effectiveLanguage, store.selectedRoomId, store.rooms.count)
        return ZStack(alignment: .bottom) {
            if store.showsFullOnboardingGuide {
                OnboardingGuideView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                mainDashboard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            overlayNotifications

            groupPromptOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: store.devices.map(\.id)) { _, _ in pruneStalePrompts() }
                .onChange(of: groupsRaw) { _, _ in pruneStalePrompts() }

            if store.isShowingMiReauth {
                miReauthOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .onChange(of: store.favoriteOrder) { _, favOrder in
            guard !favOrder.isEmpty else { return }
            var order = currentOrder
            guard !order.isEmpty else { return }
            // Permute only the favorites the saved order already holds. A favorite that is not in
            // it yet (a card that appeared after the last drag) would otherwise take another
            // favorite's slot and push that card out of the saved order.
            let known = Set(order)
            let favorites = favOrder.filter(known.contains)
            let favSet = Set(favorites)
            var favIdx = 0
            for i in order.indices where favSet.contains(order[i]) {
                if favIdx < favorites.count {
                    order[i] = favorites[favIdx]
                    favIdx += 1
                }
            }
            if order != currentOrder {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { panelLayout.setOrder(order) }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.newGroupForDevice)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.renamingGroupId)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.renamingDeviceId)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: layoutUI.renamingRoomId)
        // #41: the context menu's "Edit Layout" replaces the 0.6 s long-press for keyboard/VoiceOver users.
        .onChange(of: layoutUI.isEditingLayoutRequested) { _, requested in
            guard requested else { return }
            layoutUI.isEditingLayoutRequested = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.expandedDeviceId = nil
                layoutUI.beginDeviceLayoutEditing()
            }
        }
        // Room preferences survive a room disappearing; only the open prompt cannot.
        .onChange(of: store.rooms.map(\.id)) { _, ids in handleRoomIds(ids) }
        // Another home or account brings another room set: a draft or open prompt must never cross that boundary.
        .onChange(of: store.selectedMiHomeId) { _, _ in handleHomeContextChange() }
        .onChange(of: store.homeBackend) { _, _ in handleHomeContextChange() }
        // The saved key caught up with the commit (or something else rewrote it): drop the mirror.
        .onChange(of: roomOrderRaw) { _, _ in liveRoomOrder = nil }
        .onChange(of: kindOrderRaw) { _, _ in liveKindOrder = nil }
        .onChange(of: store.kindChips) { _, _ in
            if isRoomOrdering { layoutUI.updateKindOrderDraft(kinds: kindItems) { _ in } }
        }
    }

    // MARK: - Body hooks
    //
    // The handlers live here rather than inline: closures with control flow inside the panel's long
    // modifier chain are what pushed CI's type checker over its limit.

    private func handleAssistantState(_ state: AssistantState) {
        switch state {
        case .done:
            SoundFeedback.playSuccess()
        case .failed:
            SoundFeedback.playFailure()
        default:
            break
        }
    }

    private func handleToastNotice() {
        AppDiagnosticsLog.shared.record(store.toastNotice)
        // #54: failures get an audible cue when the user opted into feedback sounds.
        if store.toastNotice?.isError == true {
            SoundFeedback.playFailure()
        }
    }

    private func handlePanelAppear() {
        UndoAvailabilityTracker.shared.syncAction(at: store.lastAssistantActionAt)
        SettingsWindowOpener.shared.open = { openSettings() }
        syncMenuBarWindowSize()
        isPresented = true
    }

    private func handlePanelDidHide() {
        isPresented = false
        pressTask?.cancel()
        pressTask = nil
        pressCancelled = false
        draggingId = nil
        dragLocation = nil
        activeResize = nil
        lastSwapTarget = nil
        layoutUI.dismissActivePrompt()
        search.end()
        isSearchFieldFocused = false
        isDrawerHovered = false
    }

    private func handleHomeContextChange() {
        layoutUI.commitRoomOrderIfNeeded()
        layoutUI.dismissActivePrompt()
    }

    private func pruneStalePrompts() {
        layoutUI.pruneStalePrompts(
            deviceIds: Set(store.devices.map(\.id)),
            groupIds: Set(groups.map(\.id)),
            roomIds: Set(store.rooms.map(\.id))
        )
    }

    private func handleSearching(_ searching: Bool) {
        if searching {
            // Results replace the room strip; reordering underneath them would be invisible.
            layoutUI.commitRoomOrderIfNeeded()
        }
    }

    private func handleSearchFocus(_ focused: Bool) {
        if focused { store.refreshProactiveSuggestionCacheIfStale() }
    }

    private func handleSearchQuery(_ query: String) {
        if !query.isEmpty { store.recordOnboardingMilestone(.searchedDevice) }
    }

    private func handleRoomIds(_ ids: [String]) {
        if let rid = layoutUI.renamingRoomId, !ids.contains(rid) {
            layoutUI.renamingRoomId = nil
        }
        // A room arriving or leaving mid-session joins the list at the end / keeps its slot.
        if isRoomOrdering { layoutUI.updateRoomOrderDraft(rooms: store.rooms) { _ in } }
    }

    private func syncMenuBarWindowSize() {
        MenuBarPanelController.shared.updatePanelSize(width: Self.panelWidth, height: panelHeight)
    }

    // MARK: - Main Dashboard

    private var mainDashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            topHeroHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if !store.panelActivities.isEmpty {
                activityStack
                    .layoutPriority(activitiesExpanded ? 1 : 0)
                    .foldOrigin { $0.systemNoticeMinY = $1 }
                    .accessibilityIdentifier("panel-system-notice")
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            // One input for search and assistant commands, always on screen (#60). Reordering wants
            // the height for the list instead.
            if !isRoomOrdering {
                omnibar
                    .foldOrigin { $0.omnibarMinY = $1 }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                if showsInputDrawer {
                    inputDrawer
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .transition(AppleMotion.drawerTransition)
                }

                if store.isShowingAssistantBar || speech.errorMessage != nil {
                    AssistantResponseArea(store: store)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .transition(AppleMotion.drawerTransition)
                }
            }

            // While a search is open the results replace the room strip, so the empty-query layout
            // is untouched and results are not silently narrowed by the selected room.
            // #146: sorting keeps the room strip as a live preview, but drops the kind-filter row.
            if !search.isSearching {
                if isRoomOrdering {
                    if showsRoomStripPreview {
                        VStack(alignment: .leading, spacing: 6) {
                            roomFilterBar
                            // Ordering kinds previews the chip row under the strip instead.
                            if layoutUI.orderTarget == .kinds { kindFilterBar }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                } else {
                    browsingFilters
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }
            }

            Divider()
                .overlay(Color.primary.opacity(0.07))

            if isRoomOrdering {
                // The order list replaces the whole scrolling dashboard: one vertical scroll only,
                // and no tile frames or tile drag gesture mounted underneath (§5.1).
                ClassicRoomOrderEditor(store: store)
                    .frame(maxHeight: .infinity)
            } else {
                deviceGrid
                    .frame(maxHeight: .infinity)
            }

            Divider()
                .overlay(Color.primary.opacity(0.07))

            footerBar
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .foldOrigin { $0.panelMinY = $1 }
        .animation(AppleMotion.snappySpring, value: store.isShowingAssistantBar)
        .animation(AppleMotion.snappySpring, value: layoutUI.editMode)
        .animation(AppleMotion.snappySpring, value: kindChipsRevealed)
        .onChange(of: roomScrollTrigger) { _, value in handleAllPillReselect(value) }
    }

    /// Re-tapping the already-selected 全部 pill increments `roomScrollTrigger`. That second tap
    /// is the gesture that shows or hides the kind chips.
    private func handleAllPillReselect(_ value: Int) {
        guard value > 0, store.listCut == .all else { return }
        kindChipsRevealed.toggle()
    }

    private var showsLessonRow: Bool {
        store.showsOnboardingChecklistCard && !store.panelActivities.contains { activity in
            if case .notice(let kind) = activity.kind { return kind.hidesChecklist }
            return false
        }
    }

    private var showsScrollPreface: Bool { showsLessonRow }

    /// The toast the panel actually draws. A pinned blocked notice already carries the same
    /// message and Scan action, so #47's persistent expiry toast must not repeat it.
    var visibleToast: ToastNotice? {
        guard let toast = store.toastNotice else { return nil }
        guard !store.panelNoticeKinds.contains(where: { $0.repeats(toast) }) else { return nil }
        return toast
    }

    private var showsKindChips: Bool {
        ClassicKindChipRowPolicy.isShown(listCut: store.listCut, revealed: kindChipsRevealed)
    }

    private var browsingFilters: some View {
        VStack(alignment: .leading, spacing: 6) {
            roomFilterBar
            if showsKindChips {
                kindFilterBar
                    .foldOrigin { $0.kindRowMinY = $1 }
            }
        }
    }

    @ViewBuilder
    private var scrollPreface: some View {
        if showsLessonRow {
            ClassicOnboardingChecklistCard(store: store, onBeginSearch: { search.focus() })
                .foldOrigin { $0.lessonRowMinY = $1 }
        }
    }


    /// The 460 pt panel gives the height to the list instead of a strip that duplicates it (§5.1).
    var showsRoomStripPreview: Bool { panelHeight > PanelHeight.compact.points }

    private var deviceGrid: some View {
        Group {
            ScrollViewReader { scrollProxy in
                let sections = pageSections
                let quickIndex = classicQuickIndexOrder(sections)
                let quickIndexMap = quickIndex.badges
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if showsScrollPreface {
                            scrollPreface
                        }
                        VStack(alignment: .leading, spacing: 11) {
                            if search.isSearching {
                                searchResultsList(results: searchResults)
                            } else if store.visibleDevices.isEmpty {
                                emptyStateView
                            } else {
                                ForEach(sections) { section in
                                    if section.title != nil {
                                        groupHeader(section)
                                    }
                                    if !collapsedGroups.contains(collapseKey(section)) {
                                        deviceCollectionView(
                                            devices: section.devices,
                                            showRoomBadge: store.selectedRoomId == nil,
                                            quickIndexMap: quickIndexMap
                                        )
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .offset(y: -8)),
                                            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                                        ))
                                    }
                                }
                            }
                        }
                        .coordinateSpace(name: TileSpace.name)
                        // Cards stop hit-testing in edit mode; the container must still catch the press.
                        .contentShape(Rectangle())
                        .simultaneousGesture(tileDragGesture)
                        .onPreferenceChange(TileFramesKey.self) { frames in
                            if frames != tileFrames { tileFrames = frames }
                        }
                        .onPreferenceChange(CardGlobalTopKey.self) { tops in
                            panelFoldRecord?.cardTops = tops
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.top, showsScrollPreface ? 0 : 10)
                    .padding(.bottom, max(12, transientStackHeight + 8))
                }
                .onChange(of: pendingScrollToDeviceId) { _, targetId in
                    guard let targetId else { return }
                    pendingScrollToDeviceId = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(AppleMotion.snappySpring) {
                            scrollProxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
                .onAppear { PanelQuickIndexState.shared.register(quickIndex, theme: .classic) }
                .onChange(of: quickIndex) { _, next in PanelQuickIndexState.shared.register(next, theme: .classic) }
                .onDisappear { PanelQuickIndexState.shared.clear(theme: .classic) }
            }
        }
    }

    private func classicQuickIndexOrder(_ sections: [PageSection]) -> PanelQuickIndexOrder {
        if search.isSearching {
            return PanelQuickIndexOrder(deviceIds: searchResults.map(\.id))
        }
        let ids = sections
            .filter { !collapsedGroups.contains(collapseKey($0)) }
            .flatMap { DeviceLayoutPrefs.apply(order: currentOrder, to: $0.devices) }
            .map(\.id)
        return PanelQuickIndexOrder(deviceIds: ids)
    }

    // MARK: - Search (#60)

    /// Ranked results for the current query. While the bar is open but still empty, every searchable
    /// device is listed in the panel's own order, so opening search never reshuffles the page.
    private var searchResults: [SmartDevice] {
        search.results(store: store)
    }

    /// Scenes and suggestions appear while the input is focused and empty, then fold away.
    private var showsInputDrawer: Bool {
        (isSearchFieldFocused || isDrawerHovered) && !search.isSearching && !speech.isListening
    }

    private var inputDrawer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if store.showQuickActionsBar {
                quickActionsAndScenesBar
            }
            AssistantSuggestionsRow(store: store)
        }
        .onHover { isDrawerHovered = $0 }
        .onDisappear { isDrawerHovered = false }
    }

    /// The single input: typing filters devices, a sentence plus Return runs as an instruction, the
    /// mic dictates into the same field.
    private var omnibar: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        let listening = speech.isListening
        return HStack(spacing: 7) {
            Image(systemName: listening ? "waveform" : "magnifyingglass")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(listening ? Color.red : Color.secondary)
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .symbolEffect(.pulse, isActive: store.assistantState == .thinking)

            TextField(
                omnibarPlaceholder,
                text: Binding(
                    get: { search.query },
                    set: { search.query = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
            .focused($isSearchFieldFocused)
            .onSubmit { submitSearch() }
            .onChange(of: isSearchFieldFocused) { _, focused in search.isFieldFocused = focused }

            if !search.query.isEmpty {
                Text(searchCountLabel)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    withAnimation(AppleMotion.snappySpring) { search.query = "" }
                    focusInput()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("清空输入", "Clear input")))
            }

            if store.assistantState == .thinking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 18)
            } else {
                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        store.presentAssistantBar(startVoice: true)
                    }
                } label: {
                    Image(systemName: listening ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(listening ? Color.red : Color.accentColor)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(listening
                    ? L10n.tr("停止聆听", "Stop listening")
                    : L10n.tr("语音输入", "Voice input")))
                .help(listening
                    ? L10n.tr("停止聆听并执行", "Stop listening and run")
                    : L10n.tr("语音输入（快捷键 V，或长按 ⌥M / 菜单栏图标）", "Voice input (Shortcut V, or hold ⌥M / menu bar icon)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .classicAdaptiveGlass(in: shape, interactive: true)
        .overlay(
            shape.strokeBorder(
                listening ? Color.red.opacity(0.65) : Color.accentColor.opacity(isSearchFieldFocused ? 0.55 : 0.16),
                lineWidth: DesignTokens.hairline
            )
        )
        .onChange(of: search.focusRequest) { _, _ in focusInput() }
        .onChange(of: store.assistantFocusRequest) { _, _ in focusInput() }
        .onChange(of: store.assistantVoiceRequest) { _, newValue in
            lastHandledVoiceRequest = newValue
            speech.toggle(store: store)
        }
        // Dictation lands in the same field; once the instruction ran the draft empties and so does it.
        .onChange(of: speech.draft) { _, draft in
            if speech.isListening {
                search.query = draft
                search.focus()
            } else if draft.isEmpty {
                search.end()
            }
        }
        .onAppear {
            if store.assistantVoiceRequest != lastHandledVoiceRequest {
                lastHandledVoiceRequest = store.assistantVoiceRequest
                Task { await speech.start(holdMode: false, store: store) }
            } else if search.focusRequest > 0 {
                focusInput()
            }
        }
        .accessibilityElement(children: .contain)
        .panelHelp(L10n.tr(
            "打字过滤设备，回车开关；整句话（如「书房灯月光模式」）回车交给助手。⌘F 聚焦，↑↓ 选择，→ 展开，Esc 清空，再按 Esc 关闭面板",
            "Type to filter devices, Return toggles; a whole sentence runs as a command. ⌘F focuses, ↑↓ selects, → expands, Esc clears, then closes"
        ))
    }

    private func focusInput() {
        guard !speech.isListening, !speech.isHoldToTalk else { return }
        Task { @MainActor in isSearchFieldFocused = true }
    }

    private var omnibarPlaceholder: String {
        if speech.isHoldToTalk {
            return L10n.tr("按住说话，松开立即执行", "Hold to speak, release to run")
        }
        if speech.isListening {
            return L10n.tr("正在聆听…说完自动执行", "Listening… runs when you stop")
        }
        return L10n.tr("搜索设备，或直接说一句话", "Search devices, or say a command")
    }

    private var searchCountLabel: String {
        let count = searchResults.count
        return count == 1 ? L10n.tr("1 台", "1 device") : L10n.tr("\(count) 台", "\(count) devices")
    }

    /// Return inside the field: same rules as the global key monitor (toggle, or run an instruction).
    private func submitSearch() {
        let results = searchResults
        if search.isExplicitSelection, let device = search.selected(in: results) {
            toggleSearchResult(device)
            return
        }
        if PanelSearch.kind(of: search.query, devices: store.devices, scenes: store.scenes) == .command {
            PanelSearchKeyboard.runCommand(search.query, store: store, state: search)
            return
        }
        guard let device = search.selected(in: results) else { return }
        toggleSearchResult(device)
    }

    private func toggleSearchResult(_ device: SmartDevice) {
        withAnimation(AppleMotion.snappySpring) { _ = store.togglePrimary(device) }
        if device.isOnline { SoundFeedback.playSuccess() }
    }

    @ViewBuilder
    private func searchResultsList(results: [SmartDevice]) -> some View {
        if results.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DesignTokens.TypeSize.reading))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("没有匹配的设备", "No matching devices"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                if PanelSearch.kind(of: search.query, devices: store.devices, scenes: store.scenes) == .command {
                    Text(L10n.tr("回车把这句交给助手执行", "Press Return to run this as a command"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                } else {
                    Text(search.query.isEmpty
                        ? L10n.tr("输入设备名、房间或拼音首字母", "Type a device, room or pinyin initials")
                        : L10n.tr("试试房间名「书房」或首字母「sfd」", "Try a room (书房) or initials (sfd)"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            let quickIndexMap = Dictionary(
                uniqueKeysWithValues: results.prefix(9).enumerated().map { ($1.id, $0 + 1) }
            )
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("搜索结果", "Results"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)

                // The highlight is the keyboard selection, drawn as the card's own focus ring would be.
                deviceCollectionView(
                    devices: results,
                    showRoomBadge: true,
                    quickIndexMap: quickIndexMap,
                    highlightId: search.selected(in: results)?.id,
                    sortByUserOrder: false
                )
            }
        }
    }

}

// MARK: - Fold Test Hooks

/// Writes one element's global top edge into the test-injected `PanelFoldRecord`. The record is the
/// shared one, so the fold layout tests read the classic panel with the same hook as the glass one.
private struct ClassicFoldOriginWriter: View {
    @Environment(\.panelFoldRecord) private var record
    var assign: (PanelFoldRecord, CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let y = geo.frame(in: .global).minY
            Color.clear
                .onAppear {
                    if let record { assign(record, y) }
                }
                .onChange(of: y) { _, newY in
                    if let record { assign(record, newY) }
                }
        }
    }
}

private extension View {
    func foldOrigin(_ assign: @escaping (PanelFoldRecord, CGFloat) -> Void) -> some View {
        background { ClassicFoldOriginWriter(assign: assign) }
    }
}

