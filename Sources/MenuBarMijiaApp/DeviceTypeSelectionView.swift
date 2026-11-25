import SwiftUI
import AppKit
import MijiaCore

/// 设备类型选择 (P4b-M), shared by the first-run guide and 常规 › 设备类型. A choice is only a draft
/// until the user applies it after reading the impact; a refused save keeps the stored types.
struct DeviceTypeSelectionView: View {
    let store: HomeStore

    @State private var draft: Set<DeviceCategoryID>
    @State private var isChoosingCustom: Bool
    @State private var review: DeviceTypeSelectionReview
    @State private var errorMessage: String?

    init(store: HomeStore, initialDraft: Set<DeviceCategoryID>? = nil) {
        self.store = store
        let stored = store.capabilitySelection.enabledCategories
        let start = initialDraft ?? stored
        _draft = State(initialValue: start)
        _isChoosingCustom = State(initialValue: DeviceTypeSelectionMode.mode(for: start) == .custom)
        _review = State(initialValue: .init(start == stored ? nil : store.previewDeviceCategorySelection(start)))
    }

    private var stored: Set<DeviceCategoryID> { store.capabilitySelection.enabledCategories }
    private var draftMode: DeviceTypeSelectionMode {
        isChoosingCustom ? .custom : DeviceTypeSelectionMode.mode(for: draft)
    }
    private var hasPendingChange: Bool { draft != stored }

    var body: some View {
        let _ = store.effectiveLanguage
        let liveImpact = hasPendingChange ? store.previewDeviceCategorySelection(draft) : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(DeviceTypeSelectionMode.allCases, id: \.self) { mode in
                    Button(mode.title) { select(mode) }
                        .buttonStyle(PillActionButtonStyle(isSelected: draftMode == mode))
                        .accessibilityAddTraits(draftMode == mode ? [.isSelected] : [])
                        .accessibilityHint(Text(hint(for: mode)))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(L10n.tr("设备类型", "Device Types")))

            if draftMode == .custom {
                customList
            }

            // Only a selection that hides types has hidden devices to explain.
            if draftMode != .allSupportedTypes {
                Label(
                    L10n.tr(
                        "为了继续提供你已开启的安全提醒，仍会读取部分传感器、门锁、阀门、插座和空调的数据。可在「安全与提醒」单独关闭提醒。",
                        "To keep the safety alerts you turned on, some sensors, locks, valves, plugs and air conditioners are still read. Turn alerts off separately in Safety & Alerts."
                    ),
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if hasPendingChange, let impact = review.shown {
                impactSummary(impact)
                actionRow(impact)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: liveImpact) { _, latest in review.shown = latest }
    }

    private func hint(for mode: DeviceTypeSelectionMode) -> String {
        switch mode {
        case .allSupportedTypes: L10n.tr("显示所有已支持的设备类型", "Shows every supported device type")
        case .lightAndSwitch: L10n.tr("只显示灯和插座开关，应用前先预览影响", "Shows only lights and plug switches; previews the impact first")
        case .custom: L10n.tr("逐类勾选要显示的设备类型", "Pick each device type to show")
        }
    }

    private var customList: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
            ForEach(HomeStore.deliveredDeviceCategories, id: \.self) { category in
                let count = store.devices.filter { $0.capabilityCategoryID == category }.count
                Toggle(isOn: Binding(
                    get: { draft.contains(category) },
                    set: { isOn in
                        var next = draft
                        if isOn { next.insert(category) } else { next.remove(category) }
                        updateDraft(next)
                    }
                )) {
                    Text(count > 0 ? "\(category.selectionTitle) (\(count))" : category.selectionTitle)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text(category.selectionTitle))
                .accessibilityValue(Text(L10n.format("当前 %@ 台", "%@ now", String(count))))
            }
        }
    }

    private func impactSummary(_ impact: DeviceTypeSelectionImpact) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if impact.hiddenCardNames.isEmpty {
                impactLine("eye", L10n.tr("面板上没有会被隐藏的卡片", "No panel cards will be hidden"))
            } else {
                impactLine("eye.slash", L10n.format(
                    "将从面板、搜索与 AI 目录隐藏 %@ 张卡片：%@",
                    "Hides %@ cards from the panel, search and AI catalog: %@",
                    String(impact.hiddenCardNames.count), Self.list(impact.hiddenCardNames)
                ))
            }
            if !impact.retainedSafetyDevices.isEmpty {
                impactLine("shield.checkered", L10n.format(
                    "继续读取安全信号：%@",
                    "Continues reading safety signals: %@",
                    Self.list(impact.retainedSafetyDevices.map { device in
                        L10n.format("%@（%@）", "%@ (%@)", device.name, device.signals.map(\.selectionTitle).joined(separator: L10n.tr("、", ", ")))
                    })
                ))
            }
            ForEach(impact.itemsToPause, id: \.pauseKey) { item in
                impactLine("pause.circle", L10n.format("将暂停%@：%@", "Pauses %@: %@", Self.kindTitle(item.kind), item.name))
            }
            if impact.showsManualSceneNotice {
                impactLine("play.circle", CapabilitySoftNoticeKind.manualScenesMayControlHiddenDevices.userMessage)
            }
            ForEach(impact.verdict.blockingReasons, id: \.referenceId) { reason in
                impactLine("xmark.octagon", L10n.format("无法应用：%@", "Cannot apply: %@", reason.detail))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.tr("应用前的影响", "Impact before applying")))
    }

    private func impactLine(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: DesignTokens.TypeSize.caption))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionRow(_ impact: DeviceTypeSelectionImpact) -> some View {
        let reviewOnly = review.needsReview
        return HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(L10n.tr("取消", "Cancel")) { updateDraft(stored, custom: false) }
                .buttonStyle(PillActionButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle(impact, reviewOnly: reviewOnly)) { confirm(impact, reviewOnly: reviewOnly) }
                .buttonStyle(PillActionButtonStyle(isSelected: true))
                .disabled(!impact.verdict.canDeactivate || draft.isEmpty)
        }
    }

    private func confirmTitle(_ impact: DeviceTypeSelectionImpact, reviewOnly: Bool) -> String {
        if reviewOnly {
            return L10n.tr("确认更新后的影响", "Confirm Updated Impact")
        }
        return impact.itemsToPause.isEmpty
            ? L10n.tr("应用", "Apply")
            : L10n.tr("暂停这些项并应用", "Pause These and Apply")
    }

    private func select(_ mode: DeviceTypeSelectionMode) {
        switch mode {
        case .allSupportedTypes: updateDraft(DeviceCategoryPreset.allSupportedTypes.categorySet, custom: false)
        case .lightAndSwitch: updateDraft(DeviceCategoryPreset.lightAndSwitch.categorySet, custom: false)
        case .custom: isChoosingCustom = true
        }
    }

    private func updateDraft(_ next: Set<DeviceCategoryID>, custom: Bool? = nil) {
        if let custom { isChoosingCustom = custom }
        draft = next
        review = .init(next == stored ? nil : store.previewDeviceCategorySelection(next))
        errorMessage = nil
    }

    private func confirm(_ previewed: DeviceTypeSelectionImpact, reviewOnly: Bool) {
        let latest = store.previewDeviceCategorySelection(draft)
        switch review.confirm(shown: previewed, latest: latest, reviewOnly: reviewOnly) {
        case .refresh:
            showChangedImpact()
            return
        case .reviewed:
            errorMessage = nil
            return
        case .apply:
            break
        }

        let outcome = store.applyDeviceCategorySelection(
            draft,
            pauseConfirmed: !previewed.itemsToPause.isEmpty,
            expectedPauseItemKeys: previewed.pauseItemKeys,
            expectedGeneration: previewed.generation
        )
        switch outcome {
        case .applied, .unchanged:
            updateDraft(stored, custom: DeviceTypeSelectionMode.mode(for: stored) == .custom)
            announce(L10n.tr("设备类型已更新", "Device types updated"))
        case .needsConfirmation(let fresh), .blocked(let fresh):
            review.shown = fresh
            showChangedImpact()
        case .refused(let reason):
            updateDraft(stored, custom: DeviceTypeSelectionMode.mode(for: stored) == .custom)
            errorMessage = reason
            announce(reason)
        }
    }

    private func showChangedImpact() {
        let message = L10n.tr("影响范围有变化，请确认后再应用", "The impact changed; review it before applying")
        errorMessage = message
        announce(message)
    }

    private func announce(_ message: String) {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    static func list(_ names: [String], limit: Int = 4) -> String {
        let shown = names.prefix(limit).joined(separator: "、")
        return names.count > limit ? shown + L10n.format(" 等 %@ 台", " and %@ more", String(names.count - limit)) : shown
    }

    static func kindTitle(_ kind: AffectedReferenceKind) -> String {
        switch kind {
        case .waitingTimer: L10n.tr("等待中的定时", "waiting timer")
        case .missedTimer: L10n.tr("错过的定时", "missed timer")
        case .foreignTimer: L10n.tr("其他来源的定时", "timer from another source")
        case .automationRule: L10n.tr("自动化规则", "automation rule")
        case .quickAction: L10n.tr("快捷动作", "quick action")
        }
    }
}

struct DeviceTypeSelectionReview {
    enum Decision: Equatable { case refresh, reviewed, apply }

    var shown: DeviceTypeSelectionImpact?
    private var reviewed: DeviceTypeSelectionImpact?
    var needsReview: Bool {
        guard let shown else { return false }
        return !shown.matchesReview(reviewed)
    }

    init(_ impact: DeviceTypeSelectionImpact?) {
        shown = impact
        reviewed = impact
    }

    mutating func confirm(
        shown preview: DeviceTypeSelectionImpact, latest: DeviceTypeSelectionImpact, reviewOnly: Bool
    ) -> Decision {
        shown = latest
        guard latest.matchesReview(preview) else { return .refresh }
        if reviewOnly {
            reviewed = latest
            return .reviewed
        }
        return needsReview ? .refresh : .apply
    }
}

private extension DeviceTypeSelectionImpact {
    func matchesReview(_ other: Self?) -> Bool {
        guard let other else { return false }
        return target == other.target
            && generation == other.generation
            && removedCategories == other.removedCategories
            && hiddenCardNames == other.hiddenCardNames
            && retainedSafetyDevices == other.retainedSafetyDevices
            && itemsToPause == other.itemsToPause
            && showsManualSceneNotice == other.showsManualSceneNotice
            && verdict.disposition == other.verdict.disposition
            && verdict.cascadedCapabilities == other.verdict.cascadedCapabilities
            && verdict.blockingReasons == other.verdict.blockingReasons
    }
}
