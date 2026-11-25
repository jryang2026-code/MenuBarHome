import SwiftUI
import AppKit
import MijiaCore

extension ControlCenterPanel {
    // MARK: - Mi Session Expiry (#181)

    var miSessionExpiryBanner: some View {
        let expired = store.miSessionShowsExpired
        let dateText = store.miSessionExpiringSoonDate?
            .formatted(date: .abbreviated, time: .omitted) ?? ""
        return HStack(spacing: 8) {
            Image(systemName: expired ? "exclamationmark.triangle.fill" : "clock")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(expired ? Color.orange : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(expired
                    ? L10n.tr("米家登录已过期", "Xiaomi Home session expired")
                    : L10n.tr("米家登录将在 \(dateText) 到期", "Xiaomi Home sign-in expires \(dateText)"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                Text(expired
                    ? L10n.tr("设备控制已暂停，扫码后恢复", "Device controls are paused; scan to restore them")
                    : L10n.tr("提前扫码可以避免控制中断", "Scan now to avoid an interruption"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button(expired
                ? L10n.tr("扫码重新登录", "Scan to sign in")
                : L10n.tr("现在重新扫码", "Re-scan now")) {
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.presentMiReauth() }
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var miReauthOverlay: some View {
        promptBackdrop(onDismiss: {
            withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.dismissMiReauth() }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(store.miSessionShowsExpired
                        ? L10n.tr("米家登录已过期", "Xiaomi Home session expired")
                        : L10n.tr("扫码登录米家账号", "Sign in to Xiaomi Home"))
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    Spacer()
                    Button {
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.dismissMiReauth() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("关闭", "Close")))
                    .panelHelp(L10n.tr("关闭", "Close"))
                }

                MiAccountSection(store: store, autoStartsQRLogin: true, showsRegionPicker: false)
            }
            .padding(14)
            .frame(maxWidth: 332)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.20), radius: 14, y: 5)
            .padding(16)
        }
    }

    // MARK: - 1. Notification Center–style text header

    /// A large text title like Notification Center's, the live climate as plain text under it, and
    /// round glass buttons on the right. No capsule around the words: type carries the hierarchy.
    var panelHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    homeTitle
                        .lineLimit(1)
                    if store.homeBackend == .demo {
                        Text(L10n.tr("演示", "Demo"))
                            .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    BreathingDot(color: statusDotColor)
                        .id(statusDotColor)
                    statusSubtitle
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            AdaptiveGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if isRoomOrdering {
                        cancelRoomOrderButton
                        doneEditingButton
                    } else if !isEditingLayout {
                        if let release = store.updateState.badgeRelease {
                            updateCapsule(for: release)
                        }
                        if !store.allOffTargets.isEmpty {
                            let copy = store.allOffHeaderCopy(scopeName: allOffScopeDisplayName)
                            HoldToConfirmButton(
                                title: copy.title,
                                count: store.allOffTargets.count,
                                helpText: [copy.tooltip, copy.helper].compactMap { $0 }.joined(separator: "\n"),
                                onBeginHold: { store.beginAllOffHold() },
                                onConfirm: { mode in
                                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { _ = store.confirmAllOffHold(mode: mode) }
                                    SoundFeedback.playSuccess()
                                },
                                onTap: {
                                    store.showToast(L10n.tr("按住 0.6 秒确认全关", "Hold for 0.6s to confirm All Off"))
                                }
                            )
                        }
                        searchButton
                        panelMoreMenu
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 44)
    }

    private var searchButton: some View {
        let open = showsOmnibar
        return Button {
            toggleSearch()
        } label: {
            Image(systemName: open ? "xmark" : "magnifyingglass")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveGlass(in: Circle(), interactive: true)
        .accessibilityLabel(Text(open ? L10n.tr("关闭搜索", "Close search") : L10n.tr("搜索设备", "Search devices")))
        .panelHelp(L10n.tr("搜索设备或说一句话（⌘F，或直接打字）", "Search devices or give a command (⌘F, or just type)"))
    }

    private var panelMoreMenu: some View {
        let connectionStatus = PanelConnectionStatusPresentation.resolve(store: store)
        return Menu {
            Button {
                PanelConnectionDetailState.shared.toggle()
            } label: {
                Label(connectionStatus.text, systemImage: connectionStatus.iconName)
            }
            if let actionTitle = connectionStatus.inlineActionTitle,
               let inlineAction = connectionStatus.inlineAction,
               inlineAction != .openDetail {
                Button(actionTitle) {
                    PanelConnectionStatusPresentation.performInline(inlineAction, store: store)
                }
            }
            Divider()
            Toggle(L10n.tr("双列分体磁贴", "Two-column split tiles"), isOn: Binding(
                get: { store.isCompactGridMode },
                set: { value in withAnimation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion)) { store.isCompactGridMode = value } }
            ))
            Toggle(L10n.tr("只显示在线设备", "Online devices only"), isOn: Binding(
                get: { store.hideOfflineDevices },
                set: { value in withAnimation(AppleMotion.resolve(.reveal, reduceMotion: reduceMotion)) { store.hideOfflineDevices = value } }
            ))
            Divider()
            if UndoAvailabilityTracker.shared.isAvailable {
                Button(L10n.tr("撤销上一步", "Undo last action")) {
                    store.presentAssistantBar()
                    Task { await UndoAvailabilityTracker.shared.performUndo(store: store) }
                }
            }
            Button(L10n.tr("立即同步", "Refresh now")) { store.refreshNow() }
            Button(L10n.tr("编辑卡片布局…", "Edit card layout…")) {
                LayoutUIState.shared.isEditingLayoutRequested = true
            }
            if canReorderRooms || canReorderKinds {
                let reorderTitle: String = switch (canReorderRooms, canReorderKinds) {
                case (true, true): L10n.tr("排序房间与类型…", "Reorder rooms and kinds…")
                case (true, false): L10n.tr("排序房间…", "Reorder rooms…")
                case (false, true): L10n.tr("排序类型…", "Reorder kinds…")
                case (false, false): ""
                }
                Button(reorderTitle) {
                    beginRoomOrder(target: grouping == .kind ? .kinds : .rooms)
                }
            }
            Button(L10n.tr("设置…", "Settings…")) { presentSettingsWindow() }
            Divider()
            Button(L10n.tr("退出 MenuBarHome", "Quit MenuBarHome")) { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .adaptiveGlass(in: Circle(), interactive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(L10n.tr("更多操作", "More actions")))
        .panelHelp(L10n.tr("更多操作", "More actions"))
    }

    private func updateCapsule(for release: AppRelease) -> some View {
        Button {
            if store.updateState.isReadyToRelaunch {
                withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.confirmRelaunchForUpdate() }
            } else {
                SettingsWindowOpener.shared.show(tab: .about)
            }
        } label: {
            Image(systemName: store.updateState.isReadyToRelaunch ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .adaptiveGlass(in: Circle(), tint: .accentColor, interactive: true)
        .accessibilityLabel(Text(updateBadgeTitle(for: release)))
        .panelHelp(updateBadgeTitle(for: release))
    }

    /// Dashboard title; with several Mi Homes it becomes a menu that switches between them. Several
    /// signed-in accounts list their homes under the account that owns them.
    @ViewBuilder
    var homeTitle: some View {
        if store.homes.count > 1 {
            Menu {
                Button {
                    store.selectMiHome(nil)
                } label: {
                    Label(L10n.tr("全部家庭", "All Homes"), systemImage: store.selectedMiHomeId == nil ? "checkmark" : "")
                }
                Divider()
                if store.miAccounts.count > 1 {
                    ForEach(store.miAccounts) { account in
                        let accountHomes = store.homes.filter { $0.accountId == account.id }
                        if !accountHomes.isEmpty {
                            Section {
                                ForEach(accountHomes) { home in
                                    homeMenuButton(home)
                                }
                            } header: {
                                Text(account.displayName)
                            }
                        }
                    }
                } else {
                    ForEach(store.homes) { home in
                        homeMenuButton(home)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(selectedHomeTitle)
                        .font(.system(size: DesignTokens.TypeSize.headline, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .panelHelp(L10n.tr("切换家庭", "Switch home"))
        } else {
            Text(store.homeName)
                .font(.system(size: DesignTokens.TypeSize.headline, weight: .bold))
        }
    }

    func homeMenuButton(_ home: HomeOption) -> some View {
        Button {
            store.selectMiHome(home.id)
        } label: {
            Label(
                "\(home.name)  \(home.deviceCount)",
                systemImage: store.selectedMiHomeId == home.id ? "checkmark" : ""
            )
        }
    }

    var selectedHomeTitle: String {
        if let id = store.selectedMiHomeId, let home = store.homes.first(where: { $0.id == id }) {
            return home.name
        }
        return store.homeName
    }

    func handleEnvironmentChipTap(_ env: EnvironmentReading) {
        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
            if search.isSearching {
                search.clear()
            }
            if store.hiddenDeviceIds.contains(env.id) {
                store.unhideDevice(env.id)
            }
            if !store.filteredDevices.contains(where: { $0.id == env.id }) {
                store.selectRoom(nil)
            }
            openStack(containing: env.id)
            store.toggleExpanded(env.id)
            if store.expandedDeviceId == env.id {
                pendingScrollToDeviceId = env.id
            }
        }
    }

    /// Edit hints replace the live status while room ordering is open; card layout editing shows its
    /// own glass toolbar capsule below the header instead.
    private var editingHint: String? {
        if isRoomOrdering {
            // Short on purpose: the long explanation lives under the list title, and a sentence
            // this wide used to be clipped inside the 166 pt status column (§5.9).
            return layoutUI.orderTarget == .kinds
                ? L10n.tr("调整类型顺序", "Reorder kinds")
                : L10n.tr("调整房间顺序", "Reorder rooms")
        }
        return nil
    }

    /// Compact live status; tapping the reading locates and expands its sensor card.
    var statusSubtitle: some View {
        Group {
            if let hint = editingHint {
                Text(hint)
            } else {
                let line = PanelStatusLine.make(
                    activeDeviceCount: store.activeDeviceCount,
                    reading: store.preferredEnvironmentReading,
                    valuesAreStale: store.deviceValuesAreStale
                )
                ViewThatFits(in: .horizontal) {
                    ForEach(0..<line.candidateCount, id: \.self) { index in
                        statusLineContent(line, candidate: index)
                    }
                    Text(line.summary)
                }
            }
        }
        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    @ViewBuilder
    private func statusLineContent(_ line: PanelStatusLine, candidate: Int) -> some View {
        HStack(spacing: 0) {
            Text(line.summary)
            switch line.trailing {
            case .stale:
                Text(" · " + L10n.tr("可能过期", "Possibly stale"))
            case .sensor(let candidates):
                Text(" · ")
                Button {
                    if let reading = store.preferredEnvironmentReading {
                        handleEnvironmentChipTap(reading)
                    }
                } label: {
                    Text(candidates[candidate]).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .panelHelp(L10n.tr("点击定位并展开温湿度折线", "Click to locate and expand sensor chart"))
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: - 1B. Quick Actions & HA Scenes Strip

    /// Scene strip: equal-width glass pills, four across when there are four or fewer.
    var quickActionsAndScenesBar: some View {
        let itemCount = QuickAction.allCases.count + store.scenes.count
        return Group {
            if itemCount <= 4 {
                scenePillRow(expand: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    scenePillRow(expand: false)
                        .horizontalWheelScroll()
                }
            }
        }
    }

    func scenePillRow(expand: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(QuickAction.allCases) { action in
                Button {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                        _ = store.executeQuickAction(action)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: action.sfSymbolName)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(ScenePalette.tint(for: action.visualCategory))
                        Text(action.title)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillActionButtonStyle())
                .frame(maxWidth: expand ? .infinity : nil)
            }

            ForEach(store.scenes) { scene in
                Button {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                        _ = store.triggerScene(scene)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: scene.iconName)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(ScenePalette.tint(for: scene.visualCategory))
                        Text(scene.name)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillActionButtonStyle())
                .frame(maxWidth: expand ? .infinity : nil)
            }
        }
    }


    var disconnectedEmptyBackend: HomeBackend {
        if store.hasMiSource && !store.hasHASource { return .xiaomiCloud }
        if store.hasHASource && !store.hasMiSource { return .homeAssistant }
        return store.homeBackend
    }

    var emptyStateView: some View {
        let diagnosisCopy = store.emptyPanelDiagnosis.map {
            EmptyPanelDiagnosisPresenter.copy(for: $0, region: store.miCloudRegion)
        }
        return VStack(spacing: 8) {
            Image(systemName: store.identityMigrationDiagnostic != nil
                ? "exclamationmark.triangle"
                : (store.allConfiguredSourcesTurnedOff
                    ? "pause.circle"
                    : (diagnosisCopy?.iconName ?? "sparkles")))
                .font(.system(size: DesignTokens.TypeSize.reading))
                .foregroundStyle((store.identityMigrationDiagnostic != nil || diagnosisCopy?.isWarning == true) ? .orange : .secondary)
            if store.identityMigrationDiagnostic != nil {
                Text(L10n.tr("配置或凭据读取受阻", "Could not read settings or credentials"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr(
                    "暂时无法确认历史连接与凭据，已保持现有配置不变，不会清空或覆盖原设置。",
                    "Existing connections or credentials could not be read. Your settings were left untouched."
                ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.primary.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button(L10n.tr("重试读取", "Retry Reading")) {
                    _ = store.retryIdentityMigration()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                .padding(.top, 2)
            } else if store.allConfiguredSourcesTurnedOff {
                Text(L10n.tr("已停用当前连接", "Connections turned off"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr(
                    "需要时可在连接设置中重新启用，收藏、别名与历史数据均已保留",
                    "Turn a connection back on anytime in Settings. Favorites, aliases, and history are kept."
                ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(L10n.tr("连接设置", "Connection Settings")) {
                        SettingsWindowOpener.shared.show(tab: .connection)
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                }
                .padding(.top, 2)
            } else if let diagnosisCopy {
                Text(diagnosisCopy.title)
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(diagnosisCopy.detail)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(diagnosisCopy.actionTitle) {
                        EmptyPanelDiagnosisPresenter.perform(diagnosisCopy.action, store: store)
                    }
                    .buttonStyle(PillActionButtonStyle(
                        isSelected: true,
                        tintColor: diagnosisCopy.isWarning ? .orange : .accentColor
                    ))

                    if diagnosisCopy.showsResyncButton {
                        Button(L10n.tr("重新同步", "Sync Again")) {
                            store.refreshNow()
                        }
                        .buttonStyle(PillActionButtonStyle())
                    }
                }
                .padding(.top, 2)
            } else if case .disconnected = store.connectionStatus {
                Text(
                    store.isDualSourceActive
                        ? L10n.tr("尚未连接到 Home Assistant 或米家云端", "Not connected to Home Assistant or Xiaomi Cloud")
                        : (disconnectedEmptyBackend == .xiaomiCloud
                            ? L10n.tr("尚未登录米家云端账号", "Not signed in to Xiaomi Cloud")
                            : L10n.tr("尚未连接到 Home Assistant", "Not connected to Home Assistant"))
                )
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(
                    store.isDualSourceActive
                        ? L10n.tr("请检查两端配置，或在设置中查看连接状态", "Check both configurations, or review connection status in Settings")
                        : (disconnectedEmptyBackend == .xiaomiCloud
                            ? L10n.tr("无需额外部署服务器，使用手机「米家」App 扫码即可同步设备", "Scan with the Mi Home app on your phone to sync devices without a server")
                            : L10n.tr("点击下方按钮配置服务器地址与令牌，或切换为手机米家扫码直连", "Configure your server URL and token below, or switch to Xiaomi Cloud QR login"))
                )
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(L10n.tr("打开新手引导", "Setup Guide")) {
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                            store.reopenOnboarding()
                        }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                    Button {
                        presentSettingsWindow()
                    } label: {
                        Text(L10n.tr("设置", "Settings"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.top, 2)
            } else if store.hasReceivedInitialSnapshot && store.devices.isEmpty,
                      let otherCount = store.otherMiHomesDeviceCountWhenSelectedEmpty {
                // The chosen home is empty but the account has devices elsewhere: offer the switch
                // instead of the "synced, nothing came back" report (#76, #67).
                Text(L10n.tr("当前所选家庭暂无可显示的设备", "No devices to show in the selected home"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr(
                    "其他家庭共有 \(otherCount) 台设备，切换为「全部家庭」即可查看。",
                    "There are \(otherCount) devices in other homes. Switch to All Homes to view them."
                ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(L10n.tr("显示全部家庭", "Show All Homes")) {
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.selectMiHome(nil) }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                    Button {
                        presentSettingsWindow()
                    } label: {
                        Text(L10n.tr("设置", "Settings"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.top, 2)
            } else if store.hasReceivedInitialSnapshot && store.devices.isEmpty {
                // Synced but nothing came back: say so instead of spinning on "syncing" forever (#134).
                Text(L10n.tr("同步完成，但没有拉取到可显示的设备", "Synced, but no devices to show"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(EmptyPanelDiagnosisPresenter.syncedButEmptyDetail(store: store))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(L10n.tr("重新同步", "Sync Again")) {
                        store.refreshNow()
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                    Button {
                        presentSettingsWindow()
                    } label: {
                        Text(L10n.tr("设置", "Settings"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.top, 2)
            } else {
                Group {
                    if case .kind = store.listCut {
                        Text(store.hideOfflineDevices
                            ? L10n.tr("这一类暂无通电在线的设备", "Nothing of this type is online")
                            : L10n.tr("这一类暂无设备", "Nothing of this type"))
                    } else {
                        Text(
                            store.hideOfflineDevices
                                ? L10n.tr("该房间暂无通电在线的设备", "No online devices in this room")
                                : store.hasReceivedInitialSnapshot
                                    ? L10n.tr("这个房间暂无设备", "No devices in this room")
                                    : L10n.tr("正在同步设备列表…", "Syncing devices…")
                        )
                    }
                }
                .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))
                .foregroundStyle(.secondary)
                if store.hideOfflineDevices {
                    Button(L10n.tr("显示离线设备", "Show Offline Devices")) {
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                            store.hideOfflineDevices = false
                        }
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.module)
    }

    // MARK: - Home Assistant Address Question (#18)

    /// The app never moves the token to a new address by itself; it asks here first.
    func haAddressSuggestionBanner(_ instance: HADiscoveredInstance) -> some View {
        let place = instance.locationName.isEmpty || instance.locationName == "Home Assistant"
            ? instance.hostAndPort
            : "\(instance.locationName)（\(instance.hostAndPort)）"
        return VStack(alignment: .leading, spacing: 6) {
            Label(
                L10n.tr("连不上 Home Assistant。发现了 \(place)，要切换过去吗？", "Can't reach Home Assistant. Found \(place). Switch to it?"),
                systemImage: "questionmark.circle.fill"
            )
            .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
            Text(L10n.tr(
                "切换后会把访问令牌发给这个地址。不认识这个地址就点「不切换」。",
                "Switching sends your access token to this address. If you don't recognize it, choose Don't Switch."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(L10n.tr("切换", "Switch")) {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.acceptHAAddressSuggestion() }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                Button(L10n.tr("不切换", "Don't Switch")) {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.dismissHAAddressSuggestion() }
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A public plain-http Home Assistant address: nothing carrying the token is sent until the user agrees (#276).
    func haPlaintextConsentBanner(_ prompt: HAPlaintextPrompt) -> some View {
        let host = HAPlaintextConsent.host(prompt.address)
        let isDeclined = prompt == .declined(prompt.address)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isDeclined
                        ? HAPlaintextConsent.declinedMessage(prompt.address)
                        : L10n.tr("令牌会以明文发送", "Your token would be sent in plaintext"))
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !isDeclined {
                        Text(L10n.tr(
                            "\(host) 是公网上的 http 地址，路上任何人都能看到 Home Assistant 令牌。能改用 https 就别连接。",
                            "\(host) is a public http address, so anyone on the path can read your Home Assistant token. Use https if you can."
                        ))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if isDeclined {
                Button(L10n.tr("改用 https…", "Use https…")) {
                    SettingsWindowOpener.shared.show(tab: .connection)
                }
                .buttonStyle(.plain)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 8) {
                if !isDeclined {
                    Button(L10n.tr("不连接", "Don't Connect")) {
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.declineHAPlaintext() }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                }
                Spacer(minLength: 8)
                Button(L10n.tr("仍然连接", "Connect Anyway")) {
                    withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.allowHAPlaintext() }
                }
                .buttonStyle(.plain)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 3. Floating Undo & Toast Stack

    /// Undo and toast share one floating surface instead of taking turns (spec §2.2). The stack
    /// measures itself, so the device list reserves the real height rather than a guess.
    var overlayNotifications: some View {
        TransientStackView(
            store: store,
            toast: visibleToast,
            initialExpanded: initialTransientExpanded,
            onHeightChange: { transientStackHeight = $0 }
        )
    }

    // MARK: - Header Status and Actions

    /// `openSettings` is the supported way to reveal the Settings scene from a MenuBarExtra.
    func presentSettingsWindow() {
        SettingsWindowOpener.shared.show()
    }

    func updateBadgeTitle(for release: AppRelease) -> String {
        switch store.updateState {
        case .readyToRelaunch:
            return L10n.tr("重启更新 v\(release.version)", "Relaunch v\(release.version)")
        case .downloading(_, let progress):
            if let fraction = progress.fractionCompleted {
                return L10n.tr("下载 \(Int(fraction * 100))%", "DL \(Int(fraction * 100))%")
            }
            return L10n.tr("下载中…", "Downloading…")
        case .verifying:
            return L10n.tr("校验中…", "Verifying…")
        default:
            return L10n.tr("更新 v\(release.version)", "Update v\(release.version)")
        }
    }

    var statusDotColor: Color {
        PanelConnectionStatusPresentation.resolve(store: store).color
    }

    @ViewBuilder
    var statusFooterControl: some View {
        PanelConnectionStatusControl(store: store, theme: .liquidGlass)
    }

    var footerBar: some View {
        PanelConnectionFooterBar(
            store: store,
            theme: .liquidGlass,
            updateBadgeTitle: updateBadgeTitle,
            presentSettingsWindow: presentSettingsWindow
        )
    }

    func performPanelHealthAction(_ action: PanelHealthAction) {
        PanelConnectionStatusPresentation.perform(action, store: store)
    }

    var statusFooterLabel: String {
        PanelConnectionStatusPresentation.resolve(store: store).text
    }
}

// MARK: - Shared Footer Connection Status & Detail Popover (WP2a, §4.1 & §4.2)

@MainActor
@Observable
final class PanelConnectionDetailState {
    static let shared = PanelConnectionDetailState()
    var isPresented = false
    var isStatusControlFocused = false
    var restoreFocusTrigger = 0
    var clearFocusTrigger = 0

    func toggle() {
        isPresented.toggle()
        if !isPresented {
            isStatusControlFocused = true
            restoreFocusTrigger &+= 1
        }
    }

    func dismiss(restoreFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        if restoreFocus {
            isStatusControlFocused = true
            restoreFocusTrigger &+= 1
        }
    }

    func focusStatusControl() {
        isStatusControlFocused = true
        restoreFocusTrigger &+= 1
    }

    func clearStatusControlFocus() {
        guard isStatusControlFocused else { return }
        isStatusControlFocused = false
        clearFocusTrigger &+= 1
    }
}

struct PanelConnectionSourceItem: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var statusText: String
    var isOnline: Bool
    var badge: PanelConnectionBadgeKind
}

enum PanelConnectionBadgeKind: Equatable, Sendable {
    case online, connecting, degraded, reauthRequired, disconnected, notConfigured, turnedOff, demo

    var iconName: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .degraded: "exclamationmark.triangle.fill"
        case .reauthRequired: "qrcode"
        case .disconnected: "wifi.slash"
        case .notConfigured: "link.badge.plus"
        case .turnedOff: "pause.circle.fill"
        case .demo: "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .connecting, .degraded, .reauthRequired: .orange
        case .disconnected, .notConfigured: .red
        case .turnedOff, .demo: .secondary
        }
    }
}

enum PanelConnectionInlineAction: Equatable, Sendable {
    case leaveDemo, openConnectionSettings, presentMiReauth, openDetail, openLocalNetworkSettings, retryIdentityMigration
}

struct PanelConnectionStatusPresentation: Equatable, Sendable {
    var badge: PanelConnectionBadgeKind
    var text: String
    var inlineActionTitle: String? = nil
    var inlineAction: PanelConnectionInlineAction? = nil
    var sources: [PanelConnectionSourceItem] = []

    var iconName: String { badge.iconName }
    var color: Color { badge.color }

    @MainActor
    static func perform(_ action: PanelHealthAction, store: HomeStore) {
        switch action {
        case .presentMiReauth: withAnimation(AppleMotion.resolve(.snappy)) { store.presentMiReauth() }
        case .openConnectionSettings: SettingsWindowOpener.shared.show(tab: .connection)
        case .openLocalNetworkSettings: LocalNetworkSystemSettings.open()
        case .retryIdentityMigration: _ = store.retryIdentityMigration()
        }
    }

    @MainActor
    static func performInline(_ action: PanelConnectionInlineAction, store: HomeStore) {
        switch action {
        case .leaveDemo: withAnimation(AppleMotion.resolve(.snappy)) { _ = store.leaveDemo() }
        case .openConnectionSettings: SettingsWindowOpener.shared.show(tab: .connection)
        case .presentMiReauth: withAnimation(AppleMotion.resolve(.snappy)) { store.presentMiReauth() }
        case .openDetail: PanelConnectionDetailState.shared.toggle()
        case .openLocalNetworkSettings: LocalNetworkSystemSettings.open()
        case .retryIdentityMigration: _ = store.retryIdentityMigration()
        }
    }

    @MainActor
    static func resolve(store: HomeStore) -> PanelConnectionStatusPresentation {
        if store.identityMigrationDiagnostic != nil {
            return PanelConnectionStatusPresentation(
                badge: .degraded,
                text: L10n.tr("配置或凭据读取受阻", "Could not read settings or credentials"),
                inlineActionTitle: L10n.tr("重试读取", "Retry Reading"),
                inlineAction: .retryIdentityMigration
            )
        }
        if store.homeBackend == .demo {
            return PanelConnectionStatusPresentation(
                badge: .demo,
                text: L10n.tr("示例家庭，不会控制真实设备", "Demo home; won't control real devices"),
                inlineActionTitle: L10n.tr("连接真实家庭", "Connect a Real Home"),
                inlineAction: .leaveDemo,
                sources: [PanelConnectionSourceItem(
                    id: "demo",
                    name: L10n.tr("示例家庭", "Demo Home"),
                    statusText: L10n.tr("本地演示数据", "Local demo data"),
                    isOnline: true,
                    badge: .demo
                )]
            )
        }

        let hasMi = store.hasMiSource || !store.miAccounts.isEmpty
        let hasHA = store.hasHASource
        let hasLGTV = store.hasConfiguredLGTVSource
        let lgOnline = hasLGTV && !store.effectiveLocalNetworkBlocks.contains(.lgWebOS) && store.devices.contains { device in
            guard device.isOnline, case .tv(let spec) = device.kind else { return false }
            return LGWebOSProtocol.isLGEntity(spec.mediaEntityId)
        }

        if !hasMi && !hasHA && !hasLGTV {
            return PanelConnectionStatusPresentation(
                badge: .notConfigured,
                text: L10n.tr("还没连接家居平台", "No smart home platform connected"),
                inlineActionTitle: L10n.tr("去连接", "Connect"),
                inlineAction: .openConnectionSettings
            )
        }

        let miItem = hasMi ? resolveMiSource(store: store) : nil
        let haItem = hasHA ? resolveHASource(store: store) : nil
        let lgItem = hasLGTV ? resolveLGSource(store: store, isOnline: lgOnline) : nil
        let sources = [miItem, haItem, lgItem].compactMap { $0 }

        if store.allConfiguredSourcesTurnedOff {
            return PanelConnectionStatusPresentation(
                badge: .turnedOff,
                text: L10n.tr("连接已停用 · 点此重新启用", "Connections turned off · Turn one back on"),
                inlineActionTitle: L10n.tr("去启用", "Turn On"),
                inlineAction: .openConnectionSettings,
                sources: sources
            )
        }

        if store.miSessionBlocksControl {
            if lgOnline {
                return PanelConnectionStatusPresentation(
                    badge: .degraded,
                    text: L10n.tr("米家暂不可用，LG 电视仍可控制", "Xiaomi Home unavailable; LG TV still controllable"),
                    inlineActionTitle: L10n.tr("重新扫码", "Re-scan"),
                    inlineAction: .presentMiReauth,
                    sources: sources
                )
            }
            return PanelConnectionStatusPresentation(
                badge: .reauthRequired,
                text: L10n.tr("米家登录已过期", "Xiaomi Home session expired"),
                inlineActionTitle: L10n.tr("重新扫码", "Re-scan"),
                inlineAction: .presentMiReauth,
                sources: sources
            )
        }

        // #268: a blocked Local Network permission owns the footer, so the recovery action is the
        // one the user actually needs instead of a source-level retry.
        if case .blocked(_, .openLocalNetworkSettings) = store.panelHealth {
            return PanelConnectionStatusPresentation(
                badge: .disconnected,
                text: L10n.tr("本地网络权限受阻", "Local network access blocked"),
                inlineActionTitle: L10n.tr("打开系统设置", "Open System Settings"),
                inlineAction: .openLocalNetworkSettings,
                sources: sources
            )
        }

        let activeMiItem = store.hasEnabledMiSource ? miItem : nil
        let activeHAItem = store.hasEnabledHASource ? haItem : nil

        if let miItem = activeMiItem, let haItem = activeHAItem {
            if !miItem.isOnline && haItem.isOnline {
                if miItem.badge == .connecting {
                    return PanelConnectionStatusPresentation(
                        badge: .connecting,
                        text: L10n.tr("正在连接米家…", "Connecting to Xiaomi Home…"),
                        sources: sources
                    )
                }
                return PanelConnectionStatusPresentation(
                    badge: .degraded,
                    text: L10n.tr("米家暂不可用，部分设备暂无数据", "Xiaomi Home unavailable; some devices have no data"),
                    inlineActionTitle: store.miSessionShowsExpired ? L10n.tr("重新扫码", "Re-scan") : nil,
                    inlineAction: store.miSessionShowsExpired ? .presentMiReauth : nil,
                    sources: sources
                )
            }
            if miItem.isOnline && !haItem.isOnline {
                if haItem.badge == .connecting {
                    return PanelConnectionStatusPresentation(
                        badge: .connecting,
                        text: L10n.tr("正在连接 Home Assistant…", "Connecting to Home Assistant…"),
                        sources: sources
                    )
                }
                if case .declined = store.haPlaintextPrompt {
                    return PanelConnectionStatusPresentation(
                        badge: .reauthRequired,
                        text: L10n.tr("未连接 Home Assistant（已拒绝明文 http）", "Home Assistant not connected (plaintext http declined)"),
                        inlineActionTitle: L10n.tr("改用 https…", "Use https…"),
                        inlineAction: .openConnectionSettings,
                        sources: sources
                    )
                }
                if haItem.badge == .reauthRequired {
                    return PanelConnectionStatusPresentation(
                        badge: .reauthRequired,
                        text: L10n.tr("Home Assistant 凭据或地址需更新", "Home Assistant credentials or address need attention"),
                        inlineActionTitle: L10n.tr("查看连接", "Check Connection"),
                        inlineAction: .openDetail,
                        sources: sources
                    )
                }
                return PanelConnectionStatusPresentation(
                    badge: .degraded,
                    text: L10n.tr("Home Assistant 暂不可用，部分设备暂无数据", "Home Assistant unavailable; some devices have no data"),
                    sources: sources
                )
            }
            if !miItem.isOnline && !haItem.isOnline {
                if lgOnline {
                    return PanelConnectionStatusPresentation(
                        badge: .degraded,
                        text: L10n.tr("米家与 Home Assistant 暂不可用，LG 电视仍可控制", "Xiaomi Home and Home Assistant unavailable; LG TV still controllable"),
                        sources: sources
                    )
                }
                if miItem.badge == .connecting || haItem.badge == .connecting {
                    return PanelConnectionStatusPresentation(
                        badge: .connecting,
                        text: L10n.tr("正在连接家居平台…", "Connecting to smart home platforms…"),
                        sources: sources
                    )
                }
                return PanelConnectionStatusPresentation(
                    badge: .disconnected,
                    text: L10n.tr("米家与 Home Assistant 均不可用", "Xiaomi Home and Home Assistant are both unavailable"),
                    inlineActionTitle: L10n.tr("查看连接", "Check Connection"),
                    inlineAction: .openDetail,
                    sources: sources
                )
            }
        }

        if let miItem = activeMiItem, activeHAItem == nil, !miItem.isOnline {
            if lgOnline {
                return PanelConnectionStatusPresentation(
                    badge: .degraded,
                    text: L10n.tr("米家暂不可用，LG 电视仍可控制", "Xiaomi Home unavailable; LG TV still controllable"),
                    sources: sources
                )
            }
            if miItem.badge == .connecting {
                return PanelConnectionStatusPresentation(
                    badge: .connecting,
                    text: L10n.tr("正在连接米家…", "Connecting to Xiaomi Home…"),
                    sources: sources
                )
            }
            return PanelConnectionStatusPresentation(
                badge: .disconnected,
                text: L10n.tr("米家暂不可用，部分设备暂无数据", "Xiaomi Home unavailable; some devices have no data"),
                inlineActionTitle: L10n.tr("查看连接", "Check Connection"),
                inlineAction: .openDetail,
                sources: sources
            )
        }

        if let haItem = activeHAItem, activeMiItem == nil, !haItem.isOnline {
            if lgOnline {
                return PanelConnectionStatusPresentation(
                    badge: .degraded,
                    text: L10n.tr("Home Assistant 暂不可用，LG 电视仍可控制", "Home Assistant unavailable; LG TV still controllable"),
                    sources: sources
                )
            }
            if haItem.badge == .connecting {
                return PanelConnectionStatusPresentation(
                    badge: .connecting,
                    text: L10n.tr("正在连接 Home Assistant…", "Connecting to Home Assistant…"),
                    sources: sources
                )
            }
            if case .declined = store.haPlaintextPrompt {
                return PanelConnectionStatusPresentation(
                    badge: .reauthRequired,
                    text: L10n.tr("未连接 Home Assistant（已拒绝明文 http）", "Home Assistant not connected (plaintext http declined)"),
                    inlineActionTitle: L10n.tr("改用 https…", "Use https…"),
                    inlineAction: .openConnectionSettings,
                    sources: sources
                )
            }
            let text = haItem.badge == .reauthRequired
                ? L10n.tr("Home Assistant 凭据或地址需更新", "Home Assistant credentials or address need attention")
                : L10n.tr("Home Assistant 暂不可用，部分设备暂无数据", "Home Assistant unavailable; some devices have no data")
            return PanelConnectionStatusPresentation(
                badge: haItem.badge == .reauthRequired ? .reauthRequired : .disconnected,
                text: text,
                inlineActionTitle: L10n.tr("查看连接", "Check Connection"),
                inlineAction: .openDetail,
                sources: sources
            )
        }

        if case .degraded(let reason) = store.panelHealth {
            return PanelConnectionStatusPresentation(badge: .degraded, text: reason, sources: sources)
        }

        return PanelConnectionStatusPresentation(
            badge: .online,
            text: L10n.tr("设备同步正常", "Devices synced"),
            sources: sources
        )
    }

    @MainActor
    private static func resolveMiSource(store: HomeStore) -> PanelConnectionSourceItem {
        let name = L10n.tr("米家", "Xiaomi Home")
        if !store.hasEnabledMiSource {
            return PanelConnectionSourceItem(
                id: "mi", name: name,
                statusText: L10n.tr("连接已停用", "Connection turned off"),
                isOnline: false, badge: .turnedOff
            )
        }
        if store.miSessionBlocksControl || (store.miSessionShowsExpired && !store.enabledMiAccounts.contains { $0.session.expiryState(at: Date()) != .expired }) {
            return PanelConnectionSourceItem(
                id: "mi", name: name,
                statusText: L10n.tr("登录已过期 · 需要重新扫码", "Session expired · Re-scan required"),
                isOnline: false, badge: .reauthRequired
            )
        }
        let status = store.sourceStatuses[.xiaomiCloud]
            ?? (store.connectedBackends.contains(.xiaomiCloud) || !store.hasEnabledHASource ? store.connectionStatus : .connecting)
        switch status {
        case .connected:
            if store.effectiveLocalNetworkBlocks.contains(.xiaomiLAN) {
                return PanelConnectionSourceItem(
                    id: "mi", name: name,
                    statusText: L10n.tr("云端在线（局域网权限受阻）", "Cloud online (LAN blocked)"),
                    isOnline: true, badge: .degraded
                )
            }
            return PanelConnectionSourceItem(id: "mi", name: name, statusText: L10n.tr("在线", "Online"), isOnline: true, badge: .online)
        case .connecting:
            return PanelConnectionSourceItem(id: "mi", name: name, statusText: L10n.tr("正在连接…", "Connecting…"), isOnline: false, badge: .connecting)
        case .disconnected(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? L10n.tr("暂不可用", "Unavailable") : trimmed
            return PanelConnectionSourceItem(id: "mi", name: name, statusText: detail, isOnline: false, badge: .disconnected)
        }
    }

    @MainActor
    private static func resolveHASource(store: HomeStore) -> PanelConnectionSourceItem {
        let name = "Home Assistant"
        if !store.isHAConnectionEnabled {
            return PanelConnectionSourceItem(
                id: "ha", name: name,
                statusText: L10n.tr("连接已停用", "Connection turned off"),
                isOnline: false, badge: .turnedOff
            )
        }
        if case .declined = store.haPlaintextPrompt {
            return PanelConnectionSourceItem(
                id: "ha", name: name,
                statusText: L10n.tr("未连接（已拒绝明文 http）", "Not connected (plaintext http declined)"),
                isOnline: false, badge: .reauthRequired
            )
        }
        if store.effectiveLocalNetworkBlocks.contains(.homeAssistant) {
            return PanelConnectionSourceItem(
                id: "ha", name: name,
                statusText: L10n.tr("本地网络权限受阻", "Local network access blocked"),
                isOnline: false, badge: .disconnected
            )
        }
        let status = store.sourceStatuses[.homeAssistant]
            ?? (store.connectedBackends.contains(.homeAssistant) || !store.hasEnabledMiSource ? store.connectionStatus : .connecting)
        switch status {
        case .connected:
            return PanelConnectionSourceItem(id: "ha", name: name, statusText: L10n.tr("在线", "Online"), isOnline: true, badge: .online)
        case .connecting:
            return PanelConnectionSourceItem(id: "ha", name: name, statusText: L10n.tr("正在连接…", "Connecting…"), isOnline: false, badge: .connecting)
        case .disconnected(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAuth = trimmed.contains("401") || trimmed.contains("403") || trimmed.localizedCaseInsensitiveContains("token") || trimmed.contains("令牌")
            let detail = trimmed.isEmpty ? L10n.tr("暂不可用", "Unavailable") : trimmed
            return PanelConnectionSourceItem(
                id: "ha", name: name, statusText: detail, isOnline: false,
                badge: isAuth ? .reauthRequired : .disconnected
            )
        }
    }

    @MainActor
    private static func resolveLGSource(store: HomeStore, isOnline: Bool) -> PanelConnectionSourceItem {
        let name = L10n.tr("LG 电视", "LG TV")
        if store.effectiveLocalNetworkBlocks.contains(.lgWebOS) {
            return PanelConnectionSourceItem(
                id: "lg", name: name,
                statusText: L10n.tr("本地网络权限受阻", "Local network access blocked"),
                isOnline: false, badge: .degraded
            )
        }
        return PanelConnectionSourceItem(
            id: "lg", name: name,
            statusText: isOnline ? L10n.tr("在线", "Online") : L10n.tr("待机或离线", "Standby or offline"),
            isOnline: isOnline, badge: isOnline ? .online : .degraded
        )
    }
}

struct PanelConnectionStatusControl: View {
    let store: HomeStore
    let theme: PanelTheme
    @Bindable private var detailState = PanelConnectionDetailState.shared
    @FocusState private var isStatusButtonFocused: Bool

    var body: some View {
        let status = PanelConnectionStatusPresentation.resolve(store: store)
        let isMuted = status.badge == .online || status.badge == .demo || status.badge == .turnedOff
        HStack(spacing: 6) {
            Button {
                detailState.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: status.iconName)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(status.color)
                    Text(status.text)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: isMuted ? .medium : .semibold))
                        .foregroundStyle(isMuted ? Color.secondary : status.color)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($isStatusButtonFocused)
            .onKeyPress(.return) { detailState.toggle(); return .handled }
            .onKeyPress(.space) { detailState.toggle(); return .handled }
            .accessibilityIdentifier("panel-connection-status-button")
            .accessibilityLabel(Text(status.text))
            .accessibilityHint(Text(L10n.tr("点击或按回车查看各平台连接状态", "Click or press Return to view platform connection details")))
            .popover(
                isPresented: Binding(
                    get: { detailState.isPresented },
                    set: { newValue in newValue ? (detailState.isPresented = true) : detailState.dismiss(restoreFocus: true) }
                ),
                arrowEdge: .top
            ) {
                PanelConnectionDetailPopover(store: store, theme: theme, status: status) {
                    detailState.dismiss(restoreFocus: true)
                }
            }
            .onChange(of: isStatusButtonFocused) { _, focused in
                detailState.isStatusControlFocused = focused
            }
            .onChange(of: detailState.restoreFocusTrigger) { _, _ in isStatusButtonFocused = true }
            .onChange(of: detailState.clearFocusTrigger) { _, _ in isStatusButtonFocused = false }

            if let actionTitle = status.inlineActionTitle, let inlineAction = status.inlineAction {
                Button(actionTitle) {
                    PanelConnectionStatusPresentation.performInline(inlineAction, store: store)
                }
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .lineLimit(1)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

struct PanelConnectionDetailPopover: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let store: HomeStore
    let theme: PanelTheme
    let status: PanelConnectionStatusPresentation
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: status.iconName)
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(status.color)
                Text(status.text)
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.body))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("关闭连接详情", "Close connection details")))
            }

            if !status.sources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(status.sources) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.badge.iconName)
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                .foregroundStyle(item.badge.color)
                            Text(item.name)
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            Spacer(minLength: 8)
                            Text(item.statusText)
                                .font(.system(size: DesignTokens.TypeSize.caption))
                                .foregroundStyle((item.isOnline || item.badge == .turnedOff) ? Color.secondary : item.badge.color)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                if store.identityMigrationDiagnostic != nil {
                    Button(L10n.tr("重试读取", "Retry Reading")) {
                        if store.retryIdentityMigration() { onClose() }
                    }
                    .themedPillButtonStyle(theme, isSelected: true, tintColor: .orange)
                } else if store.homeBackend != .demo, (store.hasEnabledMiSource || store.hasEnabledHASource) {
                    Button(L10n.tr("重试连接", "Retry Connection")) { store.refreshNow() }
                        .themedPillButtonStyle(theme)
                }
                if store.miSessionShowsExpired {
                    Button(L10n.tr("重新扫码", "Re-scan")) {
                        onClose()
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.presentMiReauth() }
                    }
                    .themedPillButtonStyle(theme, isSelected: true, tintColor: .orange)
                }
                Spacer(minLength: 4)
                Button(L10n.tr("连接设置…", "Connection Settings…")) {
                    onClose()
                    SettingsWindowOpener.shared.show(tab: .connection)
                }
                .themedPillButtonStyle(theme, isSelected: true, tintColor: .accentColor)
            }
        }
        .padding(12)
        .frame(width: 288)
        .onExitCommand(perform: onClose)
    }
}

struct PanelConnectionFooterBar: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let store: HomeStore
    let theme: PanelTheme
    let updateBadgeTitle: (AppRelease) -> String
    let presentSettingsWindow: () -> Void

    private var status: PanelConnectionStatusPresentation { PanelConnectionStatusPresentation.resolve(store: store) }

    var body: some View {
        HStack(spacing: 8) {
            BreathingDot(color: status.color)
                .id(status.color)
            PanelConnectionStatusControl(store: store, theme: theme)
            Spacer(minLength: 4)

            if let release = store.updateState.badgeRelease {
                Button {
                    if store.updateState.isReadyToRelaunch {
                        withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) { store.confirmRelaunchForUpdate() }
                    } else {
                        SettingsWindowOpener.shared.show(tab: .about)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.updateState.isReadyToRelaunch ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        Text(updateBadgeTitle(release))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .themedPillButtonStyle(theme, isSelected: true, tintColor: store.updateState.isReadyToRelaunch ? .green : .accentColor)
                .panelHelp(store.updateState.isReadyToRelaunch
                    ? L10n.tr("点击立即重启并完成 v\(release.version) 更新", "Click to relaunch and finish updating to v\(release.version)")
                    : L10n.tr("发现新版本 v\(release.version)，点击直接打开更新", "New version v\(release.version) available"))
            }

            HStack(spacing: 2) {
                if store.undoBanner == nil, !store.isShowingAssistantBar, UndoAvailabilityTracker.shared.isAvailable {
                    footerIconButton("arrow.uturn.backward", label: L10n.tr("撤销上一步", "Undo last action"), help: L10n.tr("撤销上一步（10 分钟内有效）", "Undo the last assistant action (valid for 10 minutes)")) {
                        store.presentAssistantBar()
                        Task { await UndoAvailabilityTracker.shared.performUndo(store: store) }
                    }
                }

                footerIconButton("arrow.clockwise", label: L10n.tr("立即同步", "Refresh now"), help: L10n.tr("立即同步最新状态", "Refresh device states now")) {
                    store.refreshNow()
                }
                footerIconButton("slider.horizontal.3", size: DesignTokens.TypeSize.body, label: L10n.tr("打开设置", "Open Settings"), help: L10n.tr("设置与连接配置（⌘,）", "Settings & connections (⌘,)") ) {
                    presentSettingsWindow()
                }
                // Quit lives in the ⋯ menu and ⌘Q: a one-click quit beside Settings stopped timers and alerts by accident.
            }
        }
    }

    private func footerIconButton(_ symbol: String, size: CGFloat = DesignTokens.TypeSize.caption, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.72))
                .frame(minWidth: DesignTokens.minHitTarget, minHeight: DesignTokens.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .panelHelp(help)
    }
}

