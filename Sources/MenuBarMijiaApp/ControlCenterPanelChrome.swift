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
                withAnimation(AppleMotion.snappySpring) { store.presentMiReauth() }
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var miReauthOverlay: some View {
        promptBackdrop(onDismiss: {
            withAnimation(AppleMotion.snappySpring) { store.dismissMiReauth() }
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
                        withAnimation(AppleMotion.snappySpring) { store.dismissMiReauth() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("关闭", "Close")))
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
                            .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    BreathingDot(color: statusDotColor, animate: statusDotAnimates)
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
                                onConfirm: {
                                    withAnimation(AppleMotion.snappySpring) { _ = store.rehearseAllOff() }
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
        Menu {
            statusFooterControl
            Divider()
            Toggle(L10n.tr("常用设备用双列胶囊", "Two-column favorites"), isOn: Binding(
                get: { store.isCompactGridMode },
                set: { value in withAnimation(AppleMotion.reveal) { store.isCompactGridMode = value } }
            ))
            Toggle(L10n.tr("只显示在线设备", "Online devices only"), isOn: Binding(
                get: { store.hideOfflineDevices },
                set: { value in withAnimation(AppleMotion.reveal) { store.hideOfflineDevices = value } }
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
            Button(L10n.tr("偏好设置…", "Preferences…")) { presentSettingsWindow() }
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
    }

    private func updateCapsule(for release: AppRelease) -> some View {
        Button {
            if store.updateState.isReadyToRelaunch {
                withAnimation(AppleMotion.snappySpring) { store.confirmRelaunchForUpdate() }
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
        withAnimation(AppleMotion.snappySpring) {
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
                    withAnimation(AppleMotion.snappySpring) {
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
                    withAnimation(AppleMotion.snappySpring) {
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
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: DesignTokens.TypeSize.reading))
                .foregroundStyle(.secondary)
            if case .disconnected = store.connectionStatus {
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
                        ? L10n.tr("请检查两端配置，或在偏好设置中查看连接状态", "Check both configurations, or review connection status in Preferences")
                        : (disconnectedEmptyBackend == .xiaomiCloud
                            ? L10n.tr("无需额外部署服务器，使用手机「米家」App 扫码即可同步设备", "Scan with the Mi Home app on your phone to sync devices without a server")
                            : L10n.tr("点击下方按钮配置服务器地址与令牌，或切换为手机米家扫码直连", "Configure your server URL and token below, or switch to Xiaomi Cloud QR login"))
                )
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button(L10n.tr("打开新手引导", "Setup Guide")) {
                        withAnimation(AppleMotion.snappySpring) {
                            store.reopenOnboarding()
                        }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                    Button {
                        presentSettingsWindow()
                    } label: {
                        Text(L10n.tr("偏好设置", "Preferences"))
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
                        withAnimation(AppleMotion.snappySpring) { store.selectMiHome(nil) }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                    Button {
                        presentSettingsWindow()
                    } label: {
                        Text(L10n.tr("偏好设置", "Preferences"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.top, 2)
            } else if store.hasReceivedInitialSnapshot && store.devices.isEmpty {
                // Synced but nothing came back: say so instead of spinning on "syncing" forever (#134).
                Text(L10n.tr("同步完成，但没有拉取到可显示的设备", "Synced, but no devices to show"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr(
                    "请确认手机米家 App 里这个账号能看到设备（被共享的家庭也算）。仍然为空，请在偏好设置里「复制诊断信息」反馈。",
                    "Check that this account can see devices in the Mi Home app (shared homes included). If it is still empty, use Copy Diagnostics in Preferences and report it."
                ))
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
                        Text(L10n.tr("偏好设置", "Preferences"))
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
                        withAnimation(AppleMotion.snappySpring) {
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
                    withAnimation(AppleMotion.snappySpring) { store.acceptHAAddressSuggestion() }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                Button(L10n.tr("不切换", "Don't Switch")) {
                    withAnimation(AppleMotion.snappySpring) { store.dismissHAAddressSuggestion() }
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
                        withAnimation(AppleMotion.snappySpring) { store.declineHAPlaintext() }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                }
                Spacer(minLength: 8)
                Button(L10n.tr("仍然连接", "Connect Anyway")) {
                    withAnimation(AppleMotion.snappySpring) { store.allowHAPlaintext() }
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

    var statusDotAnimates: Bool {
        if case .ok = store.panelHealth { return true }
        return false
    }

    var statusDotColor: Color {
        switch store.panelHealth {
        case .ok:
            return .green
        case .connecting, .degraded:
            return .orange
        case .blocked, .notConfigured:
            return .red
        }
    }

    @ViewBuilder
    var statusFooterControl: some View {
        if case .blocked(_, let action) = store.panelHealth {
            Button {
                performPanelHealthAction(action)
            } label: {
                Text(statusFooterLabel)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(statusDotColor)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(statusFooterLabel)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    func performPanelHealthAction(_ action: PanelHealthAction) {
        switch action {
        case .presentMiReauth:
            withAnimation(AppleMotion.snappySpring) { store.presentMiReauth() }
        case .openConnectionSettings:
            SettingsWindowOpener.shared.show(tab: .connection)
        }
    }

    var statusFooterLabel: String {
        switch store.panelHealth {
        case .ok:
            if let dual = store.dualSourceStatusSummary { return dual }
            if store.homeBackend == .demo {
                return L10n.tr("虚拟设备，离线运行", "Virtual devices, offline")
            }
            if store.connectedBackends.contains(.homeAssistant) && store.connectedBackends.contains(.xiaomiCloud) {
                return L10n.tr("HA + 米家云 (\(store.serverHostSummary))", "HA + Xiaomi Cloud (\(store.serverHostSummary))")
            }
            if store.connectedBackends.contains(.xiaomiCloud) {
                return L10n.tr("\(store.serverHostSummary)，Miot 直连", "\(store.serverHostSummary), MIoT Direct")
            }
            return L10n.tr("HA 实时连接 (\(store.serverHostSummary))", "HA Live (\(store.serverHostSummary))")
        case .connecting:
            return L10n.tr("正在连接 (\(store.serverHostSummary))…", "Connecting (\(store.serverHostSummary))…")
        case .degraded(let reason), .blocked(let reason, _):
            return reason
        case .notConfigured:
            return L10n.tr("未配置数据源", "No data source configured")
        }
    }
}
