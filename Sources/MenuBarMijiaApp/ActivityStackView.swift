import SwiftUI
import MijiaCore

struct TieredPanelActivities: Equatable {
    var pinned: [PanelActivity]
    var ordinary: [PanelActivity]
}

enum ActivityStackPolicy {
    @MainActor
    static func partition(activities: [PanelActivity], store: HomeStore) -> TieredPanelActivities {
        var urgentPinned: [PanelActivity] = []
        var standardPinned: [PanelActivity] = []
        var ordinary: [PanelActivity] = []
        for activity in activities {
            if isPinned(activity, store: store) {
                if isUrgentLifeSafetyHazard(activity) {
                    urgentPinned.append(activity)
                } else {
                    standardPinned.append(activity)
                }
            } else {
                ordinary.append(activity)
            }
        }
        return TieredPanelActivities(pinned: urgentPinned + standardPinned, ordinary: ordinary)
    }

    static func isUrgentLifeSafetyHazard(_ activity: PanelActivity) -> Bool {
        guard case .safety(let recorded) = activity.kind,
              let kind = SensorAlertKind.parse(fromAlertId: recorded.alert.id) else {
            return false
        }
        return !kind.honorsAwayLimit
    }

    @MainActor
    static func isPinned(_ activity: PanelActivity, store: HomeStore) -> Bool {
        switch activity.kind {
        case .notice, .doorbell:
            return true
        case .safety(let recorded):
            let id = recorded.alert.id
            if let kind = SensorAlertKind.parse(fromAlertId: id) {
                switch kind {
                case .leak, .smoke, .gas:
                    return true
                case .contact, .motion:
                    return store.isSensorAlertEnabled(kind) && allowsPinningAwayCondition(store: store)
                }
            }
            if id.hasPrefix("longrun:") || recorded.alert.turnOffCommand != nil {
                return true
            }
            return false
        }
    }

    @MainActor
    private static func allowsPinningAwayCondition(store: HomeStore) -> Bool {
        !(store.sensorAlertsOnlyWhenAway && !store.awayGapIncludesAway)
    }

    /// VoiceOver label for the capsule's xmark. It clears every dismissible ordinary reminder, so it must
    /// not read as the neighbouring 收起/Collapse control.
    static func ordinaryClearAccessibilityLabel() -> String {
        L10n.tr("清除全部普通提醒", "Dismiss all reminders")
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
    let store: HomeStore
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

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.2) : AppleMotion.stack }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous) }
    private var capsuleShape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        let tiered = ActivityStackPolicy.partition(activities: activities, store: store)
        if !tiered.pinned.isEmpty || !missedTimers.isEmpty || !tiered.ordinary.isEmpty {
            let stack = stackContent(tiered: tiered)
            if theme == .classic, let maxHeight = expandedViewportHeight {
                BoundedActivityStackLayout(maxHeight: maxHeight) {
                    ViewThatFits(in: .vertical) {
                        stack
                        ScrollView(.vertical, showsIndicators: false) {
                            stack
                        }
                    }
                }
            } else {
                stack
            }
        }
    }

    private func stackContent(tiered: TieredPanelActivities) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tiered.pinned) { pinnedCard($0) }
            ForEach(missedTimers) { missedTimerCard($0) }
            if !tiered.ordinary.isEmpty { ordinaryReminderSection(tiered.ordinary) }
        }
        .animation(animation, value: activities.map(\.id))
        .animation(animation, value: missedTimers.map(\.id))
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
                    .accessibilityLabel(Text(ActivityStackPolicy.ordinaryClearAccessibilityLabel()))
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
}

/// Proposes a fixed vertical ceiling (`maxHeight`) to its child (`ViewThatFits(in: .vertical)`),
/// so intrinsic content height is preserved when `<= maxHeight` and a vertical `ScrollView`
/// bounded to `maxHeight` takes over when content exceeds `maxHeight`.
private struct BoundedActivityStackLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let boundedProposal = ProposedViewSize(width: proposal.width, height: maxHeight)
        let size = subview.sizeThatFits(boundedProposal)
        return CGSize(width: size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let boundedProposal = ProposedViewSize(width: bounds.width, height: bounds.height)
        subview.place(at: bounds.origin, anchor: .topLeading, proposal: boundedProposal)
    }
}

