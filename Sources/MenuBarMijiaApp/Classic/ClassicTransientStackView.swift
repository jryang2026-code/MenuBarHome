import Foundation
import SwiftUI
import MijiaCore

/// The bottom floating surface: the undo banner and the panel's toast share one stack instead of
/// taking turns (spec §2.2). The newest card sits in front and the other keeps only its glass bottom
/// edge; resting the pointer on the stack spreads both into a readable list.
///
/// The panel owns the height: `onHeightChange` reports the whole surface, its 42 pt bottom inset
/// included, so the device list can stay clear of it. Nothing else measures the transient surface,
/// which keeps one source of truth for this geometry.
struct ClassicTransientStackView: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    let store: HomeStore
    /// Already filtered by the panel: a toast the pinned notice repeats never reaches this surface.
    let toast: ToastNotice?
    let onHeightChange: (CGFloat) -> Void

    @State private var isExpanded: Bool
    /// Cleared on leave, an empty feed, panel hide and view disappearance.
    @State private var isHovered = false
    /// Keyboard / VoiceOver / tap expansion for multi-card stacks; cleared on single-card collapse,
    /// hover leave, panel hide and disappearance.
    @State private var isManuallyExpanded: Bool
    @FocusState private var isExpandButtonFocused: Bool
    /// Newest first. A card that arrives later takes the front, so a fresh toast never hides behind
    /// a banner that is about to expire.
    @State private var newestCardID: String?

    init(
        store: HomeStore,
        toast: ToastNotice?,
        initialExpanded: Bool = false,
        onHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.store = store
        self.toast = toast
        self.onHeightChange = onHeightChange
        _isExpanded = State(initialValue: initialExpanded)
        _isManuallyExpanded = State(initialValue: initialExpanded)
    }

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.2) : AppleMotion.stack }

    /// Stacked cards share the notification centre's corner, so the peeking edge lines up with the
    /// card in front of it.
    private var stackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous)
    }

    private var cardTransition: AnyTransition { reduceMotion ? .opacity : AppleMotion.drawerTransition }

    /// Reduced motion never offsets or scales; only the opacity changes.
    private var peekOffset: CGFloat { reduceMotion ? 0 : ClassicStackedCardGeometry.transform(depth: 1).offsetY }

    var body: some View {
        content
            // Attached even when the surface draws nothing, so emptying it reports 0 instead of
            // leaving the panel reserving the last card's height.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ClassicTransientStackHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(ClassicTransientStackHeightKey.self) { height in onHeightChange(height) }
            .animation(animation, value: orderedCards.map(\.id))
            .animation(animation, value: isExpanded)
            .onChange(of: cards.map(\.id)) { oldIDs, newIDs in
                if let added = newIDs.first(where: { !oldIDs.contains($0) }) {
                    newestCardID = added
                } else if let newestCardID, !newIDs.contains(newestCardID) {
                    self.newestCardID = newIDs.first
                }
                if newIDs.count <= 1 {
                    isExpandButtonFocused = false
                }
                if newIDs.isEmpty {
                    isHovered = false
                    isManuallyExpanded = false
                    newestCardID = nil
                }
                syncExpansionAndCountdown(cardCount: newIDs.count, animated: false)
            }
            .onChange(of: store.undoBanner?.id) { _, _ in
                if TransientStackExpansion.pausesUndoCountdown(
                    isHovered: isHovered,
                    isManuallyExpanded: isManuallyExpanded,
                    cardCount: cards.count
                ) {
                    store.pauseUndoBannerCountdown()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MenuBarPanelController.didHideNotification)) { _ in
                // The window closing mid-hover or mid-expansion never sends a leave event.
                resetInteractionState()
            }
            .onDisappear {
                // A panel that goes away mid-hover or mid-expansion must not leave the undo window paused.
                resetInteractionState()
                newestCardID = nil
                onHeightChange(0)
            }
            .transaction { transaction in
                if reduceMotion { transaction.disablesAnimations = false }
            }
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        if orderedCards.isEmpty {
            EmptyView()
        } else {
            Group {
                if orderedCards.count == 1, let card = orderedCards.first {
                    single(card)
                } else {
                    Group {
                        if isExpanded { list(orderedCards) } else { collapsed(orderedCards) }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in handleHover(hovering) }
            .padding(.bottom, 42)
        }
    }

    /// One card keeps the surface exactly as it always looked: same paddings, same position, no
    /// stacking and no hover expansion. Reading it still holds the undo countdown open (#53).
    @ViewBuilder
    private func single(_ card: Card) -> some View {
        switch card {
        case .undo:
            cardView(card, stacked: false)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                .padding(.horizontal, 14)
                .transition(cardTransition)
        case .toast:
            cardView(card, stacked: false)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
                .transition(cardTransition)
        }
    }

    @ViewBuilder
    private func collapsed(_ cards: [Card]) -> some View {
        if let first = cards.first {
            cardView(first, stacked: true)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                .background { expandStackButton(cardCount: cards.count) }
                .overlay {
                    if isExpandButtonFocused {
                        stackShape.strokeBorder(Color.accentColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .background {
                    GeometryReader { proxy in
                        if !reduceMotion { ClassicStackedCardBackplate(depth: 1, size: proxy.size) }
                    }
                    .allowsHitTesting(false)
                }
                .background { hiddenUndoShortcut(for: cards) }
                .padding(.bottom, peekOffset)
                .transition(cardTransition)
                .accessibilityActions {
                    Button(L10n.tr("展开", "Expand")) { setManuallyExpanded(true) }
                    if cards.dropFirst().contains(where: { if case .undo = $0 { return true }; return false }) {
                        Button(L10n.tr("撤销", "Undo")) {
                            withAnimation(AppleMotion.snappySpring) { _ = store.undoTurnAllOff() }
                        }
                    }
                }
        }
    }

    private func expandStackButton(cardCount: Int) -> some View {
        Button {
            setManuallyExpanded(true)
        } label: {
            Color.clear.contentShape(stackShape)
        }
        .buttonStyle(.plain)
        .focused($isExpandButtonFocused)
        .focusEffectDisabled()
        .accessibilityLabel(Text(L10n.tr(
            "展开全部 \(cardCount) 条提示",
            "Expand all \(cardCount) notifications"
        )))
    }

    @ViewBuilder
    private func hiddenUndoShortcut(for cards: [Card]) -> some View {
        if cards.dropFirst().contains(where: { if case .undo = $0 { return true }; return false }) {
            Button("") {
                withAnimation(AppleMotion.snappySpring) { _ = store.undoTurnAllOff() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func list(_ cards: [Card]) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { depth, card in
                cardView(card, stacked: true)
                    .shadow(color: .black.opacity(depth == 0 ? 0.18 : 0), radius: 10, x: 0, y: 4)
                    .transition(cardTransition)
            }
        }
        .accessibilityActions {
            if isManuallyExpanded && !isHovered {
                Button(L10n.tr("收起", "Collapse")) { setManuallyExpanded(false) }
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func cardView(_ card: Card, stacked: Bool) -> some View {
        switch card {
        case .undo(let banner):
            undoCard(banner, radius: stacked ? DesignTokens.Radius.module : DesignTokens.Radius.card)
        case .toast(let toast):
            toastCard(toast, stacked: stacked)
        }
    }

    private func undoCard(_ banner: UndoBanner, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return HStack(spacing: 10) {
            // `isAllOff` is the store's own answer, not a guess from the title or the command list.
            Image(systemName: banner.isAllOff ? "power" : "arrow.uturn.backward")
                .foregroundStyle(.orange)
                .font(.system(size: DesignTokens.TypeSize.body))

            Text(banner.title)
                .font(.system(size: DesignTokens.TypeSize.body, weight: .medium))

            Spacer()

            Button(L10n.tr("撤销", "Undo")) {
                withAnimation(AppleMotion.snappySpring) {
                    _ = store.undoTurnAllOff()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .buttonStyle(ClassicPillActionButtonStyle(isSelected: true, tintColor: DesignTokens.active))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .classicAdaptiveGlass(in: shape)
        .clipShape(shape)
    }

    @ViewBuilder
    private func toastCard(_ toast: ToastNotice, stacked: Bool) -> some View {
        let banner = NoticeToastBanner(
            notice: toast,
            onAction: {
                guard let action = toast.action else { return }
                withAnimation(AppleMotion.snappySpring) {
                    ToastNoticeActions.perform(action, store: store)
                }
            },
            onDismiss: { store.dismissToast() }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        if stacked {
            // Inside the stack every card fills the row, so the two edges line up.
            banner
                .frame(maxWidth: .infinity, alignment: .leading)
                .classicAdaptiveGlass(in: stackShape)
                .clipShape(stackShape)
        } else {
            banner
                .classicAdaptiveGlass(in: Capsule(style: .continuous))
        }
    }

    // MARK: - Order

    /// Both surfaces can be on screen at once; the base order puts the time-limited undo first when
    /// they arrive together, which is also the priority the panel used before the stack existed.
    private var cards: [Card] {
        var cards: [Card] = []
        if let banner = store.undoBanner { cards.append(.undo(banner)) }
        if let toast { cards.append(.toast(toast)) }
        return cards
    }

    private var orderedCards: [Card] {
        let base = cards
        guard base.count > 1,
              let newestCardID,
              let index = base.firstIndex(where: { $0.id == newestCardID }) else { return base }
        var ordered = base
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    // MARK: - Expansion

    private func handleHover(_ hovering: Bool) {
        isHovered = hovering
        if !hovering {
            isManuallyExpanded = false
        }
        syncExpansionAndCountdown(cardCount: cards.count, animated: true)
    }

    private func setManuallyExpanded(_ expanded: Bool) {
        guard cards.count > 1 || !expanded else { return }
        isManuallyExpanded = expanded
        if expanded { isExpandButtonFocused = false }
        syncExpansionAndCountdown(cardCount: cards.count, animated: true)
    }

    private func resetInteractionState() {
        store.resumeUndoBannerCountdown()
        isHovered = false
        isManuallyExpanded = false
        isExpandButtonFocused = false
        isExpanded = false
    }

    private func syncExpansionAndCountdown(cardCount: Int, animated: Bool) {
        isManuallyExpanded = TransientStackExpansion.sanitizedManualExpansion(
            isManuallyExpanded: isManuallyExpanded,
            cardCount: cardCount
        )
        let nextExpanded = TransientStackExpansion.isExpanded(
            isHovered: isHovered,
            isManuallyExpanded: isManuallyExpanded,
            cardCount: cardCount
        )
        if TransientStackExpansion.pausesUndoCountdown(
            isHovered: isHovered,
            isManuallyExpanded: isManuallyExpanded,
            cardCount: cardCount
        ) {
            store.pauseUndoBannerCountdown()
        } else {
            store.resumeUndoBannerCountdown()
        }
        if animated {
            withAnimation(animation) { isExpanded = nextExpanded }
        } else {
            isExpanded = nextExpanded
        }
    }

    // MARK: - Model

    private enum Card: Identifiable {
        case undo(UndoBanner)
        case toast(ToastNotice)

        var id: String {
            switch self {
            case .undo(let banner): "undo-\(banner.id.uuidString)"
            case .toast(let toast): "toast-\(toast.id.uuidString)"
            }
        }
    }
}

private struct ClassicTransientStackHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
