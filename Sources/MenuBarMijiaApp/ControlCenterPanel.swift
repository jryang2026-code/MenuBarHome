import SwiftUI
import AppKit
import Carbon
import MijiaCore

public struct ControlCenterPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelAdaptiveHeightProbe) private var panelAdaptiveHeightProbe
    @AppStorage(PanelPrefs.climatePanelKey) var climatePanelModule: Bool = true
    @State var draggingId: String?
    @State var activeResize: ActiveTileResize?
    @State var tileFrames: [String: CGRect] = [:]
    @State var dragLocation: CGPoint?
    @State var grabOffset: CGSize = .zero
    @State var lastSwapTarget: String?
    @State var lastSwapAt: Date = .distantPast
    @State var pendingScrollToDeviceId: String?
    @AppStorage(GroupPrefs.groupsKey) var groupsRaw: String = "[]"
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
    /// Persisted fold state for the unified Quick Actions & "For You" suggestions drawer.
    @State var quickDrawerState = PanelQuickDrawerState.shared
    @Bindable private var speech = SpeechInputController.shared
    /// Optional DDC/CI monitor card; off by default, so the panel is unchanged unless enabled.
    @State var externalDisplays = ExternalDisplayStore.shared
    @Environment(\.effectiveReduceMotion) var reduceMotion
    @Environment(\.effectiveReduceTransparency) var reduceTransparency
    /// Opens the ⌘, Settings window; the popover no longer hosts the long form (#42).
    @Environment(\.openSettings) var openSettings
    /// Room stacks or kind stacks — the capsule under the title (Notification Center's grouping).
    @AppStorage(PanelGrouping.storageKey) var groupingRaw: String = PanelGrouping.room.rawValue
    /// Stacks opened this session; Notification Center also forgets an opened group on close.
    @State var expandedStacks: Set<String> = []
    /// Frozen habit/active priority snapshot for the current open session; cleared on panel close.
    @State var prioritySnapshot: PanelPrioritySnapshot?
    /// The search field is folded behind the header's magnifier until asked for.
    @State private var isSearchRevealed = false
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
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    public let store: HomeStore

    private static let panelWidth: CGFloat = MenuBarPanelController.pilotPanelWidth
    /// One inset for the header, the grouping capsule and every card, so their edges line up.
    static let columnInset: CGFloat = 12
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }
    /// The panel sets `panelRoot` on its own body, so it cannot read that environment back;
    /// resolve the effective scheme locally (#51).
    var effectiveScheme: ColorScheme { appearance.colorScheme ?? colorScheme }

    public init(
        store: HomeStore,
        initialActivitiesExpanded: Bool = false,
        initialTransientExpanded: Bool = false,
        initialOfflineExpanded: Bool = false
    ) {
        self.store = store
        _activitiesExpanded = State(initialValue: initialActivitiesExpanded)
        _expandedStacks = State(initialValue: initialOfflineExpanded ? [PanelDeviceOrganizer.offlineSectionId] : [])
        self.initialTransientExpanded = initialTransientExpanded
    }
    public var body: some View {
        let _ = (store.effectiveLanguage, store.selectedRoomId, store.rooms.count)
        return dashboardRoot
            .frame(minWidth: MenuBarPanelController.panelWidth, idealWidth: Self.panelWidth, maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: store.lastAssistantActionAt) { _, date in
                UndoAvailabilityTracker.shared.syncAction(at: date)
            }
            .onChange(of: store.assistantState) { _, state in handleAssistantState(state) }
            // #45: the only place that sees every error toast is the panel root.
            .onChange(of: store.toastNotice?.id) { _, _ in handleToastNotice() }
            // The window fades in like Control Center; nothing inside the panel moves on open.
            .onReceive(NotificationCenter.default.publisher(for: MenuBarPanelController.didShowNotification)) { _ in
                UndoAvailabilityTracker.shared.syncAction(at: store.lastAssistantActionAt)
                LaunchAtLoginCoordinator.live(store: store).refresh()
                prioritySnapshot = .capture(from: store)
                registerTransientUIHandlers()
                syncAdaptiveMaximumHeight(notify: true)
                ExternalDisplayStore.shared.panelDidOpen()
            }
            .onAppear { handlePanelAppear() }
            .onDisappear { handlePanelDidHide() }
            .onReceive(NotificationCenter.default.publisher(for: MenuBarPanelController.didHideNotification)) { _ in
                handlePanelDidHide()
                activitiesExpanded = false
                expandedStacks = []
                PanelConnectionDetailState.shared.dismiss(restoreFocus: false)
            }
            // Leaving search puts the caret back on the panel, so Esc closes it instead of resigning the field.
            .onChange(of: search.isSearching) { _, searching in handleSearching(searching) }
            .onChange(of: store.homeBackend) { _, _ in
                activitiesExpanded = false
                expandedStacks = []
                prioritySnapshot = .capture(from: store)
                PanelConnectionDetailState.shared.dismiss(restoreFocus: false)
            }
            .onChange(of: store.panelActivities.count) { _, _ in
                let ordinaryCount = ActivityStackPolicy.partition(activities: store.panelActivities, store: store).ordinary.count
                activitiesExpanded = ordinaryCount > 0 ? activitiesExpanded : false
            }
            // #180: typing a query — through the key monitor or the field — ticks the guide's search step.
            .onChange(of: search.query) { _, query in handleSearchQuery(query) }
            // Scenes and suggestions open with the field; make sure the suggestions are fresh by then.
            .onChange(of: isSearchFieldFocused) { _, focused in handleSearchFocus(focused) }
            .transaction { if reduceMotion { $0.disablesAnimations = true } }
            .environment(\.isEditingLayout, isEditingLayout)
            .panelRoot()
            .task {
                await store.checkForUpdatesIfNeeded()
            }
    }

    /// The dashboard plus the hooks that only react to state the panel itself owns. Kept out of
    /// `body` on purpose: one 30-modifier chain made CI's compiler give up with "unable to
    /// type-check this expression in reasonable time", so the chain is split in two.
    ///
    /// `body` stays free of side effects: the probe's height cap is written only from `onAppear`,
    /// `onChange` and the panel's `didShow` notification, so those notifications are never swallowed
    /// by a flag a previous body pass already applied.
    private var dashboardRoot: some View {
        let _ = (store.effectiveLanguage, store.selectedRoomId, store.rooms.count)
        return ZStack(alignment: .bottom) {
            if store.showsFullOnboardingGuide {
                OnboardingGuideView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: 640, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
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
        .onChange(of: usesMaximumAdaptiveHeight) { _, _ in
            syncAdaptiveMaximumHeight(notify: true)
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
                withAnimation(AppleMotion.resolve(.reorder, reduceMotion: reduceMotion)) { panelLayout.setOrder(order) }
            }
        }
        .animation(AppleMotion.resolve(.surface, reduceMotion: reduceMotion), value: layoutUI.newGroupForDevice)
        .animation(AppleMotion.resolve(.surface, reduceMotion: reduceMotion), value: layoutUI.renamingGroupId)
        .animation(AppleMotion.resolve(.surface, reduceMotion: reduceMotion), value: layoutUI.renamingDeviceId)
        .animation(AppleMotion.resolve(.surface, reduceMotion: reduceMotion), value: layoutUI.renamingRoomId)
        // #41: the context menu's "Edit Layout" replaces the 0.6 s long-press for keyboard/VoiceOver users.
        .onChange(of: layoutUI.isEditingLayoutRequested) { _, requested in
            guard requested else { return }
            layoutUI.isEditingLayoutRequested = false
            withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                store.expandedDeviceId = nil
                layoutUI.beginDeviceLayoutEditing()
            }
        }
        // Room preferences survive a room disappearing; only the open prompt cannot.
        .onChange(of: store.rooms.map(\.id)) { _, ids in handleRoomIds(ids) }
        // Another home, account, or server brings another room set: a draft or open prompt must never cross that boundary.
        .onChange(of: homeContextSignature) { _, _ in handleHomeContextChange() }
        .onChange(of: hasVisibleOfflineDevices) { _, hasOffline in if !hasOffline { resetOfflineExpansion() } }
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

    private var hasVisibleOfflineDevices: Bool {
        store.visibleDevices.contains { !$0.isOnline }
    }

    private var isOfflineDrawerExpanded: Bool {
        expandedStacks.contains(PanelDeviceOrganizer.offlineSectionId) && hasVisibleOfflineDevices
    }

    private var usesMaximumAdaptiveHeight: Bool {
        store.showsFullOnboardingGuide || isRoomOrdering
    }

    private func syncAdaptiveMaximumHeight(notify: Bool) {
        panelAdaptiveHeightProbe?.setUsesMaximumHeight(usesMaximumAdaptiveHeight, notify: notify)
    }

    private func registerTransientUIHandlers() {
        PanelTransientUIState.shared.hasExpandedReminders = activitiesExpanded
        PanelTransientUIState.shared.hasExpandedOfflineDrawer = isOfflineDrawerExpanded
        PanelTransientUIState.shared.collapseRemindersHandler = {
            withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                activitiesExpanded = false
            }
        }
        PanelTransientUIState.shared.collapseOfflineDrawerHandler = {
            withAnimation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion)) {
                _ = expandedStacks.remove(PanelDeviceOrganizer.offlineSectionId)
            }
        }
    }

    private func resetOfflineExpansion() {
        expandedStacks.remove(PanelDeviceOrganizer.offlineSectionId)
    }

    private func handlePanelAppear() {
        UndoAvailabilityTracker.shared.syncAction(at: store.lastAssistantActionAt)
        SettingsWindowOpener.shared.open = { openSettings() }
        prioritySnapshot = .capture(from: store)
        registerTransientUIHandlers()
        if quickDrawerState.isExpanded {
            store.refreshProactiveSuggestionCacheIfStale()
        }
        syncAdaptiveMaximumHeight(notify: false)
    }

    private func handlePanelDidHide() {
        layoutUI.dismissActivePrompt()
        draggingId = nil
        dragLocation = nil
        activeResize = nil
        lastSwapTarget = nil
        prioritySnapshot = nil
        search.end()
        isSearchFieldFocused = false
        isSearchRevealed = false
    }

    private struct HomeContextSignature: Equatable {
        let selectedMiHomeId: String?
        let homeBackend: HomeBackend
        let miAccountIds: [String]
        let serverURLString: String
    }

    private var homeContextSignature: HomeContextSignature {
        HomeContextSignature(
            selectedMiHomeId: store.selectedMiHomeId,
            homeBackend: store.homeBackend,
            miAccountIds: store.miAccounts.map(\.id),
            serverURLString: store.serverURLString
        )
    }

    private func handleHomeContextChange() {
        layoutUI.commitRoomOrderIfNeeded()
        layoutUI.dismissActivePrompt()
        expandedStacks = []
        prioritySnapshot = .capture(from: store)
    }

    private func pruneStalePrompts() {
        if let snapshot = prioritySnapshot {
            prioritySnapshot = snapshot.freezingNewDevices(from: store)
        }
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

    // MARK: - Main Dashboard

    /// Notification Center's column: a text title, the grouping capsule, then one scroll of
    /// notices, the pinned favorites and the room or kind stacks.
    private var mainDashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                panelHeader
                    .padding(.horizontal, Self.columnInset + 2)
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                if showsOmnibar, !isRoomOrdering {
                    omnibar
                        .padding(.horizontal, Self.columnInset)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }

                if store.isShowingAssistantBar || speech.errorMessage != nil {
                    AssistantResponseArea(store: store)
                        .padding(.horizontal, Self.columnInset)
                        .padding(.bottom, 10)
                        .transition(AppleMotion.drawerTransition(reduceMotion: reduceMotion))
                }

                if !isRoomOrdering, !search.isSearching {
                    if isEditingLayout {
                        layoutEditToolbar
                            .padding(.horizontal, Self.columnInset)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    } else if showsGroupingBar {
                        groupingBar
                            .padding(.horizontal, Self.columnInset)
                            .padding(.bottom, showsQuickDrawer ? 8 : 12)
                            .transition(.opacity)
                    }
                }

                if showsQuickDrawer {
                    quickDrawer
                        .padding(.horizontal, Self.columnInset)
                        .padding(.bottom, 10)
                        .transition(AppleMotion.drawerTransition(reduceMotion: reduceMotion))
                }
            }
            .adaptiveHeightSlice(.topChrome)

            if isRoomOrdering {
                // The order list replaces the whole scrolling column: one vertical scroll only,
                // and no tile frames or tile drag gesture mounted underneath (§5.1).
                RoomOrderEditor(store: store)
                    .frame(maxHeight: .infinity)
            } else {
                deviceColumn
                    .frame(maxHeight: .infinity)
            }

            if !isEditing {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .overlay(Color.primary.opacity(0.07))

                    footerBar
                        .padding(.horizontal, Self.columnInset + 2)
                        .padding(.vertical, 6)
                }
                .adaptiveHeightSlice(.bottomChrome, clearOnDisappear: true)
            }
        }
        .animation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion), value: store.expandedDeviceId)
        .animation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion), value: store.listCut)
        .animation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion), value: store.isCompactGridMode)
        .animation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion), value: groupingRaw)
        .animation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion), value: store.isShowingAssistantBar)
        .animation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion), value: layoutUI.editMode)
        .animation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion), value: showsOmnibar)
        .animation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion), value: quickDrawerState.isExpanded)
        // Typing, ⌘F, "/" and dictation all ask for the field; it unfolds before it takes focus.
        .onChange(of: search.focusRequest) { _, _ in revealSearch() }
        .onChange(of: store.assistantFocusRequest) { _, _ in revealSearch() }
        .onChange(of: store.assistantVoiceRequest) { _, _ in if store.enableVoiceInput { revealSearch() } }
        .onChange(of: isSearchFieldFocused) { _, focused in if !focused { foldSearchIfIdle() } }
        // A device reached by keyboard, the status line or the assistant opens its stack first.
        .onChange(of: store.focusedDeviceId) { _, id in openStack(containing: id) }
        .onChange(of: store.expandedDeviceId) { _, id in openStack(containing: id) }
        .onChange(of: activitiesExpanded) { _, expanded in
            PanelTransientUIState.shared.hasExpandedReminders = expanded
        }
        .onChange(of: isOfflineDrawerExpanded) { _, expanded in
            PanelTransientUIState.shared.hasExpandedOfflineDrawer = expanded
        }
    }

    /// The field shows while asked for, while something is typed, and while voice or the assistant
    /// is working through it.
    var showsOmnibar: Bool {
        isSearchRevealed || search.isSearching || speech.isListening || speech.isHoldToTalk
            || store.isShowingAssistantBar
    }

    private func revealSearch() {
        guard !isSearchRevealed else { return }
        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { isSearchRevealed = true }
    }

    /// Leaving an empty field folds it back.
    private func foldSearchIfIdle() {
        guard search.query.isEmpty, !speech.isListening, !speech.isHoldToTalk,
              !store.isShowingAssistantBar else { return }
        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { isSearchRevealed = false }
    }

    /// The header's magnifier: opens and focuses the field, or closes an open one.
    func toggleSearch() {
        if showsOmnibar {
            search.end()
            isSearchFieldFocused = false
            withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { isSearchRevealed = false }
        } else {
            search.focus()
        }
    }

    private var showsLessonRow: Bool { store.showsLessonRow }

    /// The toast the panel actually draws. A pinned blocked notice already carries the same
    /// message and Scan action, so #47's persistent expiry toast must not repeat it.
    var visibleToast: ToastNotice? {
        guard let toast = store.toastNotice else { return nil }
        guard !store.panelNoticeKinds.contains(where: { $0.repeats(toast) }) else { return nil }
        return toast
    }

    private var deviceColumn: some View {
        ScrollViewReader { scrollProxy in
            let stacks = deviceStacks
            let onlineStacks = stacks.filter { $0.source != .offline }
            let offlineStacks = stacks.filter { $0.source == .offline }
            let overviewFolded = overviewFoldedStackIds(in: stacks)
            let longTailState = longTailBarState(for: stacks)
            // The one order both the card badges and the digit/navigation shortcuts read: only cards
            // that are actually drawn take a number, in the order they are drawn.
            let quickIndex = search.isSearching
                ? PanelQuickIndexOrder(deviceIds: searchResults.map(\.id))
                : quickIndexOrder(stacks)
            let quickIndexBadges = quickIndex.badges
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if !store.panelActivities.isEmpty || !store.missedScheduledCommands.isEmpty {
                        activityStack
                            .accessibilityIdentifier("panel-system-notice")
                    }
                    if showsLessonRow {
                        OnboardingChecklistCard(store: store, onBeginSearch: { search.focus() })
                    }
                    if store.showHomeSummaryRow, !search.isSearching, !isEditingLayout {
                        let summary = store.homeSummary
                        if !summary.isEmpty {
                            HomeSummaryRowView(
                                summary: summary,
                                activeListCut: store.listCut,
                                theme: .liquidGlass
                            ) { capsule in
                                HomeSummaryCapsuleRouter.handleTap(
                                    capsule,
                                    store: store,
                                    expandActivities: { activitiesExpanded = true },
                                    scrollToDevice: { pendingScrollToDeviceId = $0 }
                                )
                            }
                            .transition(.opacity)
                        }
                    }
                    if search.isSearching {
                        searchResultsList(results: searchResults)
                    } else if store.visibleDevices.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(onlineStacks) { stack in
                            stackView(
                                stack,
                                totalStacks: stacks.count,
                                overviewFolded: overviewFolded,
                                quickIndexMap: quickIndexBadges
                            )
                            .transition(.opacity)
                        }

                        if longTailState.shows {
                            PanelLongTailBar(
                                hiddenCount: longTailState.hiddenCount,
                                isExpanded: longTailState.isExpanded,
                                rooms: roomBrowseOptions,
                                theme: .liquidGlass,
                                onToggleExpand: { toggleLongTail(in: stacks) },
                                onSelectRoom: { roomId in
                                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                                        _ = store.selectRoom(roomId)
                                    }
                                }
                            )
                            .transition(.opacity)
                        }

                        ForEach(offlineStacks) { stack in
                            stackView(
                                stack,
                                totalStacks: stacks.count,
                                overviewFolded: overviewFolded,
                                quickIndexMap: quickIndexBadges
                            )
                            .transition(.opacity)
                        }
                    }

                    if !search.isSearching, !isEditingLayout, externalDisplays.showsPanelCard {
                        ExternalDisplaySectionView(store: externalDisplays, theme: .liquidGlass)
                            .transition(.opacity)
                    }

                    if !search.isSearching, !isEditingLayout {
                        let unsupportedCount = UnsupportedDeviceScanner.shared.cachedUnsupportedCount(for: store)
                        if unsupportedCount > 0 {
                            UnsupportedDevicesQuietRow(count: unsupportedCount) {
                                SettingsWindowOpener.shared.show(tab: .about, anchor: .scanUnsupportedDevices)
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
                .padding(.horizontal, Self.columnInset)
                .padding(.top, 2)
                .padding(.bottom, max(16, transientStackHeight + 8))
                .adaptiveHeightSlice(.scrollContent)
            }
            .scrollDisabled(draggingId != nil || activeResize != nil)
            .softTopScrollEdge()
            .onChange(of: pendingScrollToDeviceId) { _, targetId in
                guard let targetId else { return }
                pendingScrollToDeviceId = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                        scrollProxy.scrollTo(targetId, anchor: .center)
                    }
                }
            }
            // The digit shortcuts run in the app-wide key monitor, which cannot read this view's
            // state: publish the drawn order it must follow, and withdraw it with the column.
            .onAppear { PanelQuickIndexState.shared.register(quickIndex, theme: .liquidGlass) }
            .onChange(of: quickIndex) { _, next in PanelQuickIndexState.shared.register(next, theme: .liquidGlass) }
            .onDisappear { PanelQuickIndexState.shared.clear(theme: .liquidGlass) }
        }
    }

    // MARK: - Search (#60)

    /// Ranked results for the current query. While the bar is open but still empty, every searchable
    /// device is listed in the panel's own order, so opening search never reshuffles the page.
    private var searchResults: [SmartDevice] {
        search.results(store: store)
    }

    var hasQuickDrawerContent: Bool {
        PanelQuickDrawerPolicy.hasContent(
            showQuickActionsBar: store.showQuickActionsBar,
            hasScenes: !store.scenes.isEmpty,
            proactiveEnabled: store.proactiveSuggestionsEnabled,
            suggestionCount: store.assistantSuggestions.count
        )
    }

    /// Unified Quick Actions / Scenes and "For You" suggestions drawer; folded by default and
    /// remembered per user so the first screen stays at ≤3 stacked layers.
    private var showsQuickDrawer: Bool {
        PanelQuickDrawerPolicy.shouldShowDrawer(
            isExpanded: quickDrawerState.isExpanded,
            hasContent: hasQuickDrawerContent,
            isSearching: search.isSearching,
            isEditing: isEditing,
            isListening: speech.isListening
        )
    }

    func toggleQuickDrawer() {
        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
            let expanded = quickDrawerState.toggle()
            if expanded {
                store.refreshProactiveSuggestionCacheIfStale()
            }
        }
    }

    private var quickDrawer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if store.showQuickActionsBar {
                quickActionsAndScenesBar
                MoodActionsRow(store: store)
            }
            if store.proactiveSuggestionsEnabled || !store.assistantSuggestions.isEmpty {
                AssistantSuggestionsRow(store: store)
            }
        }
        .tahoeHoverHitTarget()
        .accessibilityIdentifier("panel-quick-drawer")
    }

    /// The single input: typing filters devices, a sentence plus Return runs as an instruction, the
    /// mic dictates into the same field.
    private var omnibar: some View {
        let shape = Capsule(style: .continuous)
        let listening = speech.isListening
        return HStack(spacing: 4) {
            Image(systemName: listening ? "waveform" : "magnifyingglass")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(listening ? Color.red : Color.secondary)
                .symbolEffect(.variableColor.iterative, isActive: listening && !reduceMotion)
                .symbolEffect(.pulse, isActive: store.assistantState == .thinking && !reduceMotion)
                .padding(.trailing, 3)

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
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { search.query = "" }
                    focusInput()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("清空输入", "Clear input")))
                .panelHelp(L10n.tr("清空输入", "Clear input"))
            }

            if store.assistantState == .thinking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
            } else if store.enableVoiceInput {
                Button {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                        store.presentAssistantBar(startVoice: true)
                    }
                } label: {
                    Image(systemName: listening ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(listening ? Color.red : Color.accentColor)
                        .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(listening
                    ? L10n.tr("停止聆听", "Stop listening")
                    : L10n.tr("语音输入", "Voice input")))
                .panelHelp(ControlCenterPanel.voiceButtonHelp(
                    listening: listening,
                    globalHotkeyEnabled: store.enableGlobalHotkey,
                    isGlobalHotkeyRegistered: HotkeySettingsState.shared.isRegistered,
                    shortcutDisplay: HotkeySettingsState.shared.shortcut.displayString
                ))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 32)
        .adaptiveGlass(in: shape)
        .overlay(
            shape.strokeBorder(
                listening ? Color.red.opacity(0.65) : (isSearchFieldFocused ? Color.accentColor.opacity(0.65) : Color.clear),
                lineWidth: 1.5
            )
        )
        .onChange(of: search.focusRequest) { _, _ in focusInput() }
        .onChange(of: store.assistantFocusRequest) { _, _ in focusInput() }
        .onChange(of: store.assistantVoiceRequest) { _, newValue in
            lastHandledVoiceRequest = newValue
            guard store.enableVoiceInput else { return }
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
                if store.enableVoiceInput {
                    Task { await speech.start(holdMode: false, store: store) }
                } else {
                    focusInput()
                }
            } else {
                // The field only mounts when someone asked for it, so it takes the caret at once.
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
        MenuBarPanelController.shared.activateForTextInputIfNeeded()
        Task { @MainActor in isSearchFieldFocused = true }
    }

    private var omnibarPlaceholder: String {
        if speech.isHoldToTalk {
            return L10n.tr("按住说话，松开立即执行", "Hold to speak, release to run")
        }
        if speech.isListening {
            return L10n.tr("正在聆听…说完自动执行", "Listening… runs when you stop")
        }
        if !store.enableVoiceInput {
            return L10n.tr("搜索设备，或输入一句话", "Search devices, or type a command")
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
        if PanelSearch.kind(of: search.query, devices: store.categoryVisibleDevices, scenes: store.scenes) == .command {
            PanelSearchKeyboard.runCommand(search.query, store: store, state: search)
            return
        }
        guard let device = search.selected(in: results) else { return }
        toggleSearchResult(device)
    }

    private func toggleSearchResult(_ device: SmartDevice) {
        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { _ = store.togglePrimary(device) }
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
                if PanelSearch.kind(of: search.query, devices: store.categoryVisibleDevices, scenes: store.scenes) == .command {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
            .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.module)
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

// MARK: - Search State (#60)

/// The panel's search, shared between the SwiftUI tree and the app-wide key monitor.
///
/// The panel keeps arrow keys, Return, Esc, Space and the 1–9 shortcuts in
/// `HotkeyAndNotificationManager`'s local key monitor, which runs before any SwiftUI view can see
/// the event. So the query cannot live in `@State` alone: it has to be readable (and writable) from
/// that monitor, while the field itself stays a normal `TextField` so IME, paste and selection work.
@MainActor
@Observable
final class PanelSearchState {
    static let shared = PanelSearchState()

    /// What the user typed. Empty means "no query" but says nothing about whether the bar is open.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            // A new query restarts the highlight at the best match.
            selectionId = nil
            isExplicitSelection = false
        }
    }
    /// Bumped to move the caret into the field; the panel focuses on every change.
    var focusRequest = 0
    /// The search field itself is first responder, so AppKit inserts text instead of the monitor.
    var isFieldFocused = false
    /// Highlighted result, or `nil` for "the best match".
    private(set) var selectionId: String?
    /// The user moved the highlight, so Return acts on it even when the text reads like a command.
    private(set) var isExplicitSelection = false

    /// Results replace the grid only while something is typed; a focused empty field changes nothing.
    var isSearching: Bool { !query.isEmpty }

    /// Puts the caret in the field. The page stays as is until something is typed.
    func focus() {
        focusRequest &+= 1
    }

    /// Esc step one: drop the query and leave search mode. The next Esc closes the panel.
    func clear() {
        end()
    }

    func end() {
        query = ""
        selectionId = nil
        isExplicitSelection = false
        isFieldFocused = false
    }

    /// Devices in the order the panel draws them, so ties keep the on-screen order.
    func devices(store: HomeStore) -> [SmartDevice] {
        let order = DeviceLayoutPrefs.decodeOrder(
            store.userDefaults.string(forKey: DeviceLayoutPrefs.orderKey) ?? "[]"
        )
        return DeviceLayoutPrefs.apply(order: order, to: store.categoryVisibleDevices)
    }

    /// Search results for the current query: hidden and (optionally) offline devices are excluded,
    /// the room filter is not applied, and ranked matches come first.
    func results(store: HomeStore) -> [SmartDevice] {
        let aliases = GroupPrefs.map(store.userDefaults.string(forKey: GroupPrefs.aliasesKey) ?? "{}")
        return PanelSearch.results(
            query,
            devices: devices(store: store),
            hiddenIds: store.hiddenDeviceIds,
            hideOffline: store.hideOfflineDevices,
            aliases: aliases
        )
    }

    /// The highlighted device: the user's pick while it is still visible, else the best match.
    func selected(in results: [SmartDevice]) -> SmartDevice? {
        if let selectionId, let picked = results.first(where: { $0.id == selectionId }) { return picked }
        return results.first
    }

    func selectHoveredResult(_ id: String) {
        if isExplicitSelection, selectionId != id {
            selectionId = id
        }
    }

    /// ↑/↓ through the results, wrapping at both ends.
    func moveSelection(_ delta: Int, in results: [SmartDevice]) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectionId } ?? (delta > 0 ? -1 : 0)
        var next = current + delta
        if next < 0 { next = results.count - 1 }
        if next >= results.count { next = 0 }
        selectionId = results[next].id
        isExplicitSelection = true
    }
}

/// Routes key presses into the panel's search before the panel's own shortcuts run (#60).
///
/// Returns `true` when the key belonged to the search and must not reach the existing keyboard
/// ladder (device focus, quick-index digits, "/" for the assistant, "v" for dictation). With no
/// search open and nothing typed, every key returns `false`, so the panel behaves exactly as before.
@MainActor
enum PanelSearchKeyboard {
    /// Narrows an `NSEvent` down to the keys the search cares about.
    static func key(for event: NSEvent) -> PanelSearchKey? {
        let flags = event.modifierFlags
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)

        let kind: PanelSearchKey.Kind
        switch Int(event.keyCode) {
        case kVK_UpArrow: kind = .up
        case kVK_DownArrow: kind = .down
        case kVK_LeftArrow: kind = .left
        case kVK_RightArrow: kind = .right
        case kVK_Return, kVK_ANSI_KeypadEnter: kind = .return
        case kVK_Escape: kind = .escape
        case kVK_Tab: kind = .tab
        case kVK_Delete: kind = .delete
        default:
            // Only unmodified (or shift-modified) printing keys count as typing.
            guard !control, !option else { return nil }
            guard let characters = event.characters, !characters.isEmpty else { return nil }
            guard characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            kind = .character(characters)
        }
        return PanelSearchKey(kind: kind, hasCommand: command, hasControl: control, hasOption: option)
    }

    /// A text field other than the search field (assistant bar, layout rename) owns the keyboard.
    private static var isOtherFieldFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    /// Handles the event and reports whether it was consumed.
    @discardableResult
    static func handle(_ event: NSEvent, store: HomeStore, state: PanelSearchState = .shared) -> Bool {
        // The Settings window and every other window keep their own typing.
        guard MenuBarPanelController.shared.isPanelWindow(NSApp.keyWindow) else { return false }
        guard !store.showsFullOnboardingGuide else { return false }
        guard let key = key(for: event) else { return false }

        // A text field that is not the search field (assistant bar, layout rename) owns the keyboard.
        if isOtherFieldFocused, !state.isFieldFocused { return false }

        let results = state.isSearching ? state.results(store: store) : []
        let context = PanelSearchContext(
            query: state.query,
            isSearching: state.isSearching,
            isFieldFocused: state.isFieldFocused,
            hasSelection: state.selected(in: results) != nil,
            hasExplicitSelection: state.isExplicitSelection,
            queryKind: state.isSearching
                ? PanelSearch.kind(of: state.query, devices: store.categoryVisibleDevices, scenes: store.scenes)
                : .filter
        )

        switch PanelSearch.action(for: key, context: context) {
        case .ignore:
            return false

        case .appendQuery(let text):
            state.query += text
            state.focus()
            return true

        case .deleteBackward:
            if !state.query.isEmpty { state.query.removeLast() }
            state.focus()
            return true

        case .clearQuery:
            state.clear()
            // Hand the keyboard back so the next Esc reaches the panel's own ladder (which closes it)
            // instead of the text-field guard that only resigns first responder.
            if isOtherFieldFocused { NSApp.keyWindow?.makeFirstResponder(nil) }
            return true

        case .focusField:
            state.focus()
            return true

        case .moveSelection(let delta):
            (NSApp.keyWindow as? MenuBarPanel)?.input.keyboardNavigated()
            state.moveSelection(delta, in: results)
            return true

        case .toggleSelection:
            guard let device = state.selected(in: results) else { return false }
            withAnimation(AppleMotion.resolve(.snappy)) { _ = store.togglePrimary(device) }
            if device.isOnline { SoundFeedback.playSuccess() }
            return true

        case .expandSelection:
            guard let device = state.selected(in: results) else { return false }
            withAnimation(AppleMotion.resolve(.snappy)) { store.toggleExpanded(device.id) }
            return true

        case .runCommand:
            runCommand(state.query, store: store, state: state)
            return true
        }
    }

    /// Return on an instruction: the pre-typed query goes through the same path as the assistant bar,
    /// so local parsing, demo mode, API keys and cloud consent all behave as before.
    static func runCommand(_ text: String, store: HomeStore, state: PanelSearchState = .shared) {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        state.end()
        store.presentAssistantBar()
        Task { @MainActor in
            await store.runAssistantCommand(utterance, preferDiffPreview: true)
        }
    }
}

extension ControlCenterPanel {
    /// Hover help for the omnibar voice button (shared with `ClassicControlCenterPanel`).
    /// Mentions holding the global hotkey only when it is enabled and registered with Carbon.
    static func voiceButtonHelp(
        listening: Bool,
        globalHotkeyEnabled: Bool,
        isGlobalHotkeyRegistered: Bool,
        shortcutDisplay: String
    ) -> String {
        if listening {
            return L10n.tr("停止聆听并执行", "Stop listening and run")
        }
        if globalHotkeyEnabled && isGlobalHotkeyRegistered {
            return L10n.tr(
                "语音输入（快捷键 V，或长按 \(shortcutDisplay) / 菜单栏图标）",
                "Voice input (Shortcut V, or hold \(shortcutDisplay) / menu bar icon)"
            )
        }
        return L10n.tr(
            "语音输入（快捷键 V，或长按菜单栏图标）",
            "Voice input (Shortcut V, or hold menu bar icon)"
        )
    }
}
