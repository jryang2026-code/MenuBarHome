import SwiftUI
import MijiaCore

/// Persistent activity surface; transient undo and toast state belongs to TransientStackView.
struct ActivityStackView<Content: View>: View {
    let activities: [PanelActivity]
    @Binding var isExpanded: Bool
    let dismiss: (PanelActivity) -> Void
    let clear: () -> Void
    let label: (PanelActivity) -> String
    @ViewBuilder let content: (PanelActivity) -> Content
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    // Gesture state resets on release/cancellation; outgoing state ends when the head changes.
    @GestureState(resetTransaction: Transaction(animation: AppleMotion.stack)) private var translation: CGFloat = 0
    @State private var outgoing: CGFloat = 0

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.2) : AppleMotion.stack }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous)
    }

    var body: some View {
        if let first = activities.first {
            VStack(alignment: .leading, spacing: 8) {
                if activities.count > 1 { header }
                if isExpanded {
                    // The column is the one scroll view; an expanded stack simply grows inside it.
                    VStack(spacing: 8) {
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
                    .accessibilityElement(children: .contain)
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
                        .adaptiveGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("清除可清除提醒", "Clear dismissible notifications")))
            }
        }
    }

    private func card(_ activity: PanelActivity) -> some View {
        content(activity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(in: shape)
            .clipShape(shape)
    }

    private func collapsed(_ first: PanelActivity) -> some View {
            card(first)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                .offset(x: reduceMotion ? 0 : outgoing + dragOffset(first))
                .opacity(reduceMotion && outgoing != 0 ? 0 : 1)
                .background {
                    GeometryReader { proxy in
                        if !reduceMotion, activities.count > 1 {
                            ForEach((1..<min(activities.count, StackedCardGeometry.maxVisible)).reversed(), id: \.self) { depth in
                                StackedCardBackplate(depth: depth, size: proxy.size)
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
        .padding(.bottom, activities.count > 1 && !reduceMotion
            ? StackedCardGeometry.offsetY(depth: activities.count - 1) : 0)
        .onPreferenceChange(ActivityHeadSizeKey.self) { size in
            if size.width > 0 { cardWidth = size.width }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.tr("\(activities.count) 条提醒，第 1 条：\(label(first))", "\(activities.count) notifications. First: \(label(first))")))
        .accessibilityActions {
            if activities.count > 1 {
                Button(L10n.tr("展开", "Expand")) { isExpanded = true }
            }
            if first.isDismissible {
                Button(L10n.tr("清除", "Dismiss")) { dismiss(first) }
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
