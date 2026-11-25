import Observation
import SwiftUI
import MijiaCore

/// Pure persistence helper for the unified Quick Actions + "For You" suggestions fold state.
/// Defaults to folded (`false`) so the first screen stays within ≤3 stacked layers.
enum PanelQuickDrawerPrefs {
    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: PanelPrefs.quickDrawerExpandedKey)
    }

    static func save(_ expanded: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(expanded, forKey: PanelPrefs.quickDrawerExpandedKey)
    }

    @discardableResult
    static func toggle(in defaults: UserDefaults = .standard) -> Bool {
        let next = !load(from: defaults)
        save(next, to: defaults)
        return next
    }
}

/// Pure visibility rules for the folded Quick Actions + "For You" suggestions drawer.
enum PanelQuickDrawerPolicy {
    static func hasContent(
        showQuickActionsBar: Bool,
        hasScenes: Bool,
        proactiveEnabled: Bool,
        suggestionCount: Int
    ) -> Bool {
        showQuickActionsBar || hasScenes || proactiveEnabled || suggestionCount > 0
    }

    static func shouldShowDrawer(
        isExpanded: Bool,
        hasContent: Bool,
        isSearching: Bool,
        isEditing: Bool,
        isListening: Bool
    ) -> Bool {
        isExpanded && hasContent && !isSearching && !isEditing && !isListening
    }
}

/// Shared observable fold state for Quick Actions & "For You" suggestions across both themes and
/// the global keyboard router (`⌘K`).
@MainActor
@Observable
final class PanelQuickDrawerState {
    static let shared = PanelQuickDrawerState()

    private let defaults: UserDefaults
    private(set) var isExpanded: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isExpanded = PanelQuickDrawerPrefs.load(from: defaults)
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        PanelQuickDrawerPrefs.save(expanded, to: defaults)
    }

    @discardableResult
    func toggle() -> Bool {
        let next = !isExpanded
        isExpanded = next
        PanelQuickDrawerPrefs.save(next, to: defaults)
        return next
    }

    func reloadFromDefaults() {
        isExpanded = PanelQuickDrawerPrefs.load(from: defaults)
    }
}

/// Single compact, discoverable affordance that folds/expands both Quick Actions/Scenes and
/// "For You" suggestions without adding an extra vertical layer to the first screen.
struct PanelQuickDrawerToggleButton: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let isExpanded: Bool
    let theme: PanelTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                    .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
                Text(L10n.tr("快捷", "Shortcuts"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: isExpanded ? .semibold : .medium))
                    .foregroundStyle(isExpanded ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: DesignTokens.TypeSize.footnote - 1, weight: .bold))
                    .animation(AppleMotion.resolve(.control, reduceMotion: reduceMotion)) {
                        $0.rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: theme == .liquidGlass ? 30 : 32)
            .contentShape(Capsule(style: .continuous))
            .modifier(QuickDrawerToggleSurface(theme: theme, isExpanded: isExpanded))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("panel-quick-drawer-toggle")
        .accessibilityLabel(Text(L10n.tr("快捷操作与为你推荐", "Shortcuts & For You")))
        .accessibilityValue(Text(isExpanded ? L10n.tr("已展开", "Expanded") : L10n.tr("已折叠", "Collapsed")))
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .panelHelp(isExpanded
            ? L10n.tr("收起快捷场景与推荐（⌘K）", "Collapse shortcuts and suggestions (⌘K)")
            : L10n.tr("展开快捷场景与推荐（⌘K）", "Expand shortcuts and suggestions (⌘K)"))
    }
}

private struct QuickDrawerToggleSurface: ViewModifier {
    let theme: PanelTheme
    let isExpanded: Bool

    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        switch theme {
        case .liquidGlass:
            content
                .adaptiveGlass(in: shape, tint: isExpanded ? .accentColor : nil, interactive: true)
        case .classic:
            content
                .classicAdaptiveGlass(in: shape, tint: isExpanded ? .accentColor : nil, interactive: true)
                .overlay(
                    shape.strokeBorder(
                        isExpanded ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                        lineWidth: DesignTokens.hairline
                    )
                )
        }
    }
}
