import SwiftUI
import AppKit
import MijiaCore

// MARK: - Landing Highlight

/// Marks a settings row as a search destination.
///
/// A jump from search would otherwise leave the user on a page with no sign of which of forty rows
/// answered the query. The row that owns the anchor draws a short accent wash, then fades. The pulse
/// is skipped entirely under Reduce Motion, and it never loops: `SettingsSearchFocus` is the single
/// owner of when it starts and ends (§13).
private struct SettingsAnchorHighlight: ViewModifier {
    @Environment(\.settingsSearchFocus) private var focus
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let anchor: SettingsAnchor

    private var isHighlighted: Bool { focus?.highlight == anchor }

    private var wash: Color {
        colorScheme == .dark
            ? Color.accentColor.opacity(0.26)
            : Color.accentColor.opacity(0.15)
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
                    .fill(isHighlighted ? wash : Color.clear)
            }
            // A ring as well as the wash: on a busy card the fill alone is easy to miss.
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.55 : 0), lineWidth: 1)
            }
            .padding(.horizontal, -6)
            .padding(.vertical, -3)
            .animation(reduceMotion ? nil : AppleMotion.control, value: isHighlighted)
            .id(anchor)
            .background {
                // Report the row's frame so a jump can scroll to it. A `GeometryReader` in the
                // background keeps the row's own layout untouched.
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsRowAnchorKey.self,
                        value: [anchor: proxy.frame(in: .named(SettingsScrollSpace.name))]
                    )
                }
            }
    }
}

/// The scroll coordinate space every settings page and the anchor reporter share.
enum SettingsScrollSpace {
    static let name = "settings-scroll"
}

struct SettingsRowAnchorKey: PreferenceKey {
    static var defaultValue: [SettingsAnchor: CGRect] { [:] }

    static func reduce(value: inout [SettingsAnchor: CGRect], nextValue: () -> [SettingsAnchor: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Registers this row as the target of a search hit and draws its landing highlight.
    func settingsRow(anchor: SettingsAnchor) -> some View {
        modifier(SettingsAnchorHighlight(anchor: anchor))
    }
}

// MARK: - Sidebar

/// The vibrancy-backed category rail, System Settings' left column.
///
/// Uses a real `NSVisualEffectView` rather than a material fill: the blur has to sample the window's
/// desktop through the titlebar, and only the AppKit view does that on macOS 14 as well as 26.
struct SettingsSidebar: View {
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Binding var selection: SettingsTab
    /// Drives the accent row while the search field is showing results.
    var isSearching: Bool
    var searchField: AnyView
    var hasUpdateBadge: Bool
    /// A click on a row. It carries the click itself rather than leaving the window to notice a
    /// changed `selection`, because clicking the category already selected changes nothing.
    var onSelectCategory: (SettingsTab) -> Void

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, DesignTokens.Settings.sidebarInset)
                .padding(.top, 10)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(SettingsTab.allCases) { tab in
                        row(tab)
                    }
                }
                .padding(.horizontal, DesignTokens.Settings.sidebarInset - 4)
                .padding(.vertical, 4)
            }
        }
        .frame(width: DesignTokens.Settings.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                SidebarVibrancy()
            }
        }
    }

    private func row(_ tab: SettingsTab) -> some View {
        let selected = tab == selection && !isSearching
        return Button {
            selection = tab
            onSelectCategory(tab)
        } label: {
            HStack(spacing: 7) {
                SettingsCategoryTile(tab: tab)
                Text(tab.title)
                    .font(.system(size: DesignTokens.TypeSize.body, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if tab == .about && hasUpdateBadge {
                    Circle()
                        .fill(selected ? Color.white : Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: DesignTokens.Settings.sidebarRowHeight)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: DesignTokens.Settings.sidebarRowRadius,
                                     style: .continuous)
                        .fill(Color.accentColor)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Settings.sidebarRowRadius,
                                           style: .continuous))
        }
        .buttonStyle(SidebarRowButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(tab.title)
    }
}

/// Rows highlight before the click lands, so the rail answers the pointer the way an `NSTableView`
/// sidebar does.
private struct SidebarRowButtonStyle: ButtonStyle {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Settings.sidebarRowRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// The sidebar's translucent backdrop. Blends behind the window, so the rail keeps a hint of the
/// desktop while the detail pane stays an opaque content surface, exactly as System Settings does.
private struct SidebarVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
    }
}

// MARK: - Search Field

/// The sidebar's search box.
///
/// A plain `TextField` with `.textFieldStyle(.plain)` inside a shaped background, rather than
/// `.searchable`: the latter installs its own toolbar field, which would fight the reference layout
/// that keeps search inside the rail.
struct SettingsSearchField: View {
    @Binding var text: String
    /// Return commits the highlighted suggestion.
    var onSubmit: () -> Void
    var onMove: (Int) -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L10n.tr("搜索设置", "Search"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: DesignTokens.TypeSize.body))
                .focused($isFocused)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onCancel)
                .accessibilityLabel(L10n.tr("搜索设置", "Search settings"))

            if !text.isEmpty {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("清除搜索", "Clear search"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: DesignTokens.Settings.searchFieldHeight)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Settings.searchFieldHeight / 2, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Settings.searchFieldHeight / 2, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                              lineWidth: isFocused ? 1 : DesignTokens.hairline)
        }
        // The arrow keys belong to the suggestion list while the field has text.
        .onKeyPress(.downArrow) { onMove(1); return .handled }
        .onKeyPress(.upArrow) { onMove(-1); return .handled }
    }
}

// MARK: - Search Results

/// The list of hits that replaces the categories while a query is typed.
struct SettingsSearchResults: View {
    let hits: [SettingsSearchHit]
    let selection: Int?
    /// The row the query asked for that this window is not drawing, with the condition that hides it.
    var blocked: SettingsSearchBlocked?
    var onPick: (SettingsSearchHit) -> Void

    @Environment(\.effectiveReduceMotion) private var reduceMotion

    init(
        hits: [SettingsSearchHit],
        selection: Int?,
        blocked: SettingsSearchBlocked? = nil,
        onPick: @escaping (SettingsSearchHit) -> Void
    ) {
        self.hits = hits
        self.selection = selection
        self.blocked = blocked
        self.onPick = onPick
    }

    var body: some View {
        if hits.isEmpty {
            VStack(spacing: 4) {
                Text(blocked == nil
                     ? L10n.tr("没有匹配的设置", "No matching settings")
                     : L10n.tr("这一项现在不在窗口里", "That setting is not on screen now"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                // Naming the condition is the difference between "this app has no such setting" and
                // "turn Demo Mode off and it will be here".
                Text(blocked?.reason.explanation
                     ?? L10n.tr("试试「开机」「令牌」「深色」", "Try “login”, “token”, “dark”"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 18)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        Button { onPick(hit) } label: {
                            hitRow(hit, highlighted: selection == index)
                        }
                        .buttonStyle(SidebarRowButtonStyle())
                    }
                }
                .padding(.horizontal, DesignTokens.Settings.sidebarInset - 4)
                .padding(.vertical, 4)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("搜索结果", "Search results"))
        }
    }

    private func hitRow(_ hit: SettingsSearchHit, highlighted: Bool) -> some View {
        HStack(alignment: .center, spacing: 7) {
            SettingsCategoryTile(tab: hit.anchor.tab,
                                 size: DesignTokens.Settings.searchResultIconSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(hit.title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(hit.section)
                    .font(.system(size: DesignTokens.TypeSize.micro))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: DesignTokens.Settings.sidebarRowRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hit.title), \(hit.section)")
        .accessibilityAddTraits(highlighted ? [.isSelected] : [])
    }
}

// MARK: - Pane Header

/// The large tile and title at the top of the detail pane, System Settings' pane heading.
struct SettingsPaneHeader: View {
    let tab: SettingsTab
    let subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            SettingsCategoryTile(tab: tab, size: DesignTokens.Settings.headerIconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: DesignTokens.TypeSize.headline, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }
}

extension SettingsTab {
    /// One line under the pane title, the way System Settings explains what a pane governs.
    var paneSubtitle: String? {
        switch self {
        case .general:
            return L10n.tr("菜单栏外观、设备卡片、快捷键与提醒。",
                           "Menu bar readout, device cards, shortcuts and alerts.")
        case .connection:
            return L10n.tr("连接 Home Assistant、米家云端与局域网电视。",
                           "Connect Home Assistant, Xiaomi Cloud and LAN TVs.")
        case .assistant:
            return L10n.tr("AI 的密钥、模型，以及它有多主动。",
                           "The AI's key, model and how boldly it acts.")
        case .appearance:
            return L10n.tr("面板的明暗、主题与布局。",
                           "The panel's light or dark look, theme and layout.")
        case .privacy:
            return L10n.tr("诊断、安全与退出登录。",
                           "Diagnostics, security and signing out.")
        case .about:
            return L10n.tr("版本、更新与退出。",
                           "Version, updates and quitting.")
        }
    }
}
