import SwiftUI
import MijiaCore

struct TieredPanelActivities: Equatable {
    var pinned: [PanelActivity]
    var ordinary: [PanelActivity]
}

enum ActivityStackPolicy {
    static func rendersExpanded(isExpanded: Bool, count: Int) -> Bool { isExpanded && count > 1 }
    static func sanitizedExpansion(isExpanded: Bool, count: Int) -> Bool { count > 1 ? isExpanded : false }

    static func collapsedAccessibilitySummary(count: Int, firstLabel: String) -> String? {
        guard count > 1 else { return nil }
        return L10n.tr("\(count) 条提醒，第 1 条：\(firstLabel)", "\(count) notifications. First: \(firstLabel)")
    }

    @MainActor
    static func partition(activities: [PanelActivity], store: HomeStore?) -> TieredPanelActivities {
        var pinned: [PanelActivity] = []
        var ordinary: [PanelActivity] = []
        for activity in activities {
            isPinned(activity, store: store) ? pinned.append(activity) : ordinary.append(activity)
        }
        return TieredPanelActivities(pinned: pinned, ordinary: ordinary)
    }

    @MainActor
    static func isPinned(_ activity: PanelActivity, store: HomeStore?) -> Bool {
        switch activity.kind {
        case .notice, .doorbell:
            return true
        case .safety(let recorded):
            let id = recorded.alert.id
            if id.hasPrefix("sensor:smoke:") || id.hasPrefix("sensor:gas:") || id.hasPrefix("sensor:leak:")
                || id.hasPrefix("longrun:") || recorded.alert.turnOffCommand != nil {
                return true
            }
            if id.hasPrefix("sensor:contact:") {
                return allowsPinningSensor(.contact, store: store)
            }
            if id.hasPrefix("sensor:motion:") {
                return allowsPinningSensor(.motion, store: store)
            }
            if id.hasPrefix("sensor:lock:") || id.hasPrefix("sensor:vibration:") {
                return allowsPinningAwayCondition(store: store)
            }
            return false
        }
    }

    @MainActor
    private static func allowsPinningSensor(_ kind: SensorAlertKind, store: HomeStore?) -> Bool {
        guard let store else { return true }
        return store.isSensorAlertEnabled(kind) && allowsPinningAwayCondition(store: store)
    }

    @MainActor
    private static func allowsPinningAwayCondition(store: HomeStore?) -> Bool {
        guard let store else { return true }
        return !(store.sensorAlertsOnlyWhenAway && !store.awayGapIncludesAway)
    }

    static func ordinaryCapsuleSummary(labels: [String]) -> String {
        guard let first = labels.first else { return "" }
        guard labels.count > 1 else { return first }
        return L10n.tr("\(first) 等 \(labels.count) 条提醒", "\(first) and \(labels.count - 1) more")
    }
}

/// Persistent activity surface; transient undo and toast state belongs to TransientStackView.
struct ActivityStackView<Content: View>: View {
    let activities: [PanelActivity]
    var missedTimers: [ScheduledCommand] = []
    var store: HomeStore? = nil
    @Binding var isExpanded: Bool
    var expandedViewportHeight: CGFloat? = nil
    var theme: PanelTheme = .liquidGlass
    let dismiss: (PanelActivity) -> Void
    let clear: () -> Void
    var runMissedTimer: ((UUID) -> Void)? = nil
    var dismissMissedTimer: ((UUID) -> Void)? = nil
    let label: (PanelActivity) -> String
    @ViewBuilder let content: (PanelActivity) -> Content
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    // Gesture state resets on release/cancellation; outgoing state ends when the head changes.
    @GestureState(resetTransaction: Transaction(animation: AppleMotion.stack)) private var translation: CGFloat = 0
    @State private var outgoing: CGFloat = 0

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.2) : AppleMotion.stack }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous) }
    private var capsuleShape: Capsule { Capsule(style: .continuous) }
    private var usesTieredLayout: Bool { store != nil || !missedTimers.isEmpty }

    var body: some View {
        if usesTieredLayout { tieredBody } else { legacyStackBody }
    }

    // MARK: - Tiered WP2a Layout (Pinned Independent Cards + 32pt Ordinary Capsule)

    @ViewBuilder
    private var tieredBody: some View {
        let tiered = ActivityStackPolicy.partition(activities: activities, store: store)
        if !tiered.pinned.isEmpty || !missedTimers.isEmpty || !tiered.ordinary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tiered.pinned) { pinnedCard($0) }
                ForEach(missedTimers) { missedTimerCard($0) }
                if !tiered.ordinary.isEmpty { ordinaryReminderSection(tiered.ordinary) }
            }
            .animation(animation, value: activities.map(\.id))
            .animation(animation, value: missedTimers.map(\.id))
            .transaction { if reduceMotion { $0.disablesAnimations = false } }
        }
    }

    private func pinnedCard(_ activity: PanelActivity) -> some View {
        HStack(alignment: .top, spacing: 6) {
            content(activity)
                .frame(maxWidth: .infinity, alignment: .leading)
            if activity.isDismissible {
                Button {
                    withAnimation(animation) { dismiss(activity) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .padding(.trailing, 6)
                .accessibilityLabel(Text(L10n.tr("清除", "Dismiss")))
            }
        }
        .themedAdaptiveGlass(theme, in: shape)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if activity.isDismissible {
                Button(L10n.tr("清除", "Dismiss")) { dismiss(activity) }
            }
        }
    }

    private func missedTimerCard(_ entry: ScheduledCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(
                    L10n.tr("已错过的定时：\(entry.reply)", "Missed timer: \(entry.reply)"),
                    systemImage: "exclamationmark.clock.fill"
                )
                .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                .foregroundStyle(.primary)
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                Button(L10n.tr("立即执行", "Run Now")) { runMissedTimer?(entry.id) }
                    .themedPillButtonStyle(theme, isSelected: true, tintColor: .orange)
                Button(L10n.tr("忽略", "Dismiss")) {
                    withAnimation(animation) { dismissMissedTimer?(entry.id) }
                }
                .themedPillButtonStyle(theme)
                .accessibilityLabel(Text(L10n.tr("忽略已错过的定时", "Dismiss missed timer")))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedAdaptiveGlass(theme, in: shape)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func ordinaryReminderSection(_ ordinary: [PanelActivity]) -> some View {
        let summaryText = ActivityStackPolicy.ordinaryCapsuleSummary(labels: ordinary.map(label))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(animation) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(summaryText)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.88))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(isExpanded ? L10n.tr("收起", "Collapse") : L10n.tr("查看", "View"))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if ordinary.contains(where: \.isDismissible) {
                    Button {
                        withAnimation(animation) {
                            for item in ordinary where item.isDismissible { dismiss(item) }
                            isExpanded = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("收起普通提醒", "Dismiss notifications")))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .themedAdaptiveGlass(theme, in: capsuleShape)
            .clipShape(capsuleShape)
            .accessibilityElement(children: .contain)

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(ordinary) { pinnedCard($0) }
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Legacy Generic Stack Fallback (Preserves Direct Unit Tests)

    @ViewBuilder
    private var legacyStackBody: some View {
        if let first = activities.first {
            VStack(alignment: .leading, spacing: 8) {
                if activities.count > 1 { header }
                if ActivityStackPolicy.rendersExpanded(isExpanded: isExpanded, count: activities.count) {
                    expandedList(first: first)
                } else {
                    collapsed(first)
                }
            }
            .animation(animation, value: activities.map(\.id))
            .onChange(of: first.id) { _, _ in outgoing = 0 }
            .onDisappear { outgoing = 0; cardWidth = 1 }
            .transaction { transaction in
                // The panel suppresses legacy springs globally; this surface supplies a fade instead.
                if reduceMotion { transaction.disablesAnimations = false }
            }
        }
    }

    @ViewBuilder
    private func expandedList(first: PanelActivity) -> some View {
        switch theme {
        case .liquidGlass:
            // The column is the one scroll view; an expanded stack simply grows inside it.
            VStack(spacing: 8) {
                expandedCards(first: first)
            }
            .accessibilityElement(children: .contain)
        case .classic:
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    expandedCards(first: first)
                    Button(L10n.tr("收起", "Collapse")) {
                        withAnimation(animation) { isExpanded = false }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .padding(.vertical, 4)
                }
            }
            .frame(height: expandedViewportHeight)
            .accessibilityElement(children: .contain)
        }
    }

    private func expandedCards(first: PanelActivity) -> some View {
        ForEach(activities) { activity in
            card(activity)
                .shadow(color: .black.opacity(activity.id == first.id ? 0.18 : 0), radius: 10, x: 0, y: 4)
                .accessibilityActions {
                    if activity.isDismissible {
                        Button(L10n.tr("清除", "Dismiss")) { dismiss(activity) }
                    }
                }
        }
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(animation) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.tr("通知中心", "Notifications"))
                        .font(.system(size: DesignTokens.TypeSize.title, weight: .bold))
                    Text("\(activities.count)")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if activities.contains(where: \.isDismissible) {
                Button {
                    withAnimation(animation) { clear() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
                        .frame(width: 28, height: 28)
                        .themedAdaptiveGlass(theme, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("清除可清除提醒", "Clear dismissible notifications")))
            }
        }
    }

    private func card(_ activity: PanelActivity) -> some View {
        content(activity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedAdaptiveGlass(theme, in: shape)
            .clipShape(shape)
    }

    private var collapsedBottomPadding: CGFloat {
        guard activities.count > 1, !reduceMotion else { return 0 }
        switch theme {
        case .liquidGlass:
            return StackedCardGeometry.offsetY(depth: activities.count - 1)
        case .classic:
            return ClassicStackedCardGeometry.peekReserve
        }
    }

    @ViewBuilder
    private func collapsed(_ first: PanelActivity) -> some View {
        let base = card(first)
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .offset(x: reduceMotion ? 0 : outgoing + dragOffset(first))
            .opacity(reduceMotion && outgoing != 0 ? 0 : 1)
            .background {
                GeometryReader { proxy in
                    if !reduceMotion, activities.count > 1 {
                        switch theme {
                        case .liquidGlass:
                            ForEach((1..<min(activities.count, StackedCardGeometry.maxVisible)).reversed(), id: \.self) { depth in
                                StackedCardBackplate(depth: depth, size: proxy.size)
                            }
                        case .classic:
                            ForEach((1..<min(activities.count, ClassicStackedCardGeometry.maxVisible)).reversed(), id: \.self) { depth in
                                ClassicStackedCardBackplate(depth: depth, size: proxy.size)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ActivityHeadSizeKey.self, value: proxy.size)
                }
            }
            .contentShape(shape)
            .onTapGesture {
                if activities.count > 1 { withAnimation(animation) { isExpanded = true } }
            }
            .simultaneousGesture(swipe(first))
            .padding(.bottom, collapsedBottomPadding)
            .onPreferenceChange(ActivityHeadSizeKey.self) { size in
                if size.width > 0 { cardWidth = size.width }
            }

        if let summary = ActivityStackPolicy.collapsedAccessibilitySummary(
            count: activities.count,
            firstLabel: label(first)
        ) {
            base
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(summary))
                .accessibilityActions {
                    Button(L10n.tr("展开", "Expand")) { isExpanded = true }
                    if first.isDismissible {
                        Button(L10n.tr("清除", "Dismiss")) { dismiss(first) }
                    }
                }
        } else {
            base
                .accessibilityElement(children: .contain)
                .accessibilityActions {
                    if first.isDismissible {
                        Button(L10n.tr("清除", "Dismiss")) { dismiss(first) }
                    }
                }
        }
    }

    // Set by the head's bounds; discarded when the stack leaves the tree.
    @State private var cardWidth: CGFloat = 1

    private func dragOffset(_ activity: PanelActivity) -> CGFloat {
        activity.isDismissible ? translation : StackedCardGeometry.rubberBand(translation, width: cardWidth)
    }

    private func swipe(_ activity: PanelActivity) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($translation) { value, state, transaction in
                transaction.animation = nil
                if abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
            }
            .onChanged { _ in
                // Retarget an in-progress exit immediately when the card is grabbed again.
                if outgoing != 0 { outgoing = 0 }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height), activity.isDismissible,
                      StackedCardGeometry.shouldDismiss(translation: value.translation.width,
                          predictedTranslation: value.predictedEndTranslation.width,
                          velocity: value.velocity.width, width: cardWidth) else {
                    withAnimation(animation) { outgoing = 0 }
                    return
                }
                let direction: CGFloat = value.predictedEndTranslation.width < 0 ? -1 : 1
                outgoing = value.translation.width
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : AppleMotion.dismiss, completionCriteria: .logicallyComplete) {
                    outgoing = direction * cardWidth * 1.2
                } completion: {
                    guard outgoing != 0, activities.first?.id == activity.id else { return }
                    withAnimation(animation) { dismiss(activity); outgoing = 0 }
                }
            }
    }
}

private struct ActivityHeadSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}
