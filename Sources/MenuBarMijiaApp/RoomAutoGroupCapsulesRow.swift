import MijiaCore
import SwiftUI

struct RoomAutoGroupCapsulesRow: View {
    let groups: [RoomAutoGroup]
    let store: HomeStore
    let theme: PanelTheme

    var body: some View {
        if !groups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(groups) { RoomAutoGroupCapsuleView(group: $0, store: store, theme: theme) }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

private struct RoomAutoGroupCapsuleView: View {
    let group: RoomAutoGroup
    let store: HomeStore
    let theme: PanelTheme

    @State private var isShowingBrightness = false
    @State private var draftBrightness: Double = 80

    private var accentColor: Color {
        switch group.kind {
        case .light: return .orange
        case .cover: return .teal
        case .plug: return .green
        case .fan: return .cyan
        case .climate: return .blue
        }
    }

    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: 4) {
            Button {
                Task { await store.toggleRoomGroup(group) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: group.kind.sfSymbolName)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(group.isAnyOn ? accentColor : DesignTokens.secondaryText)
                    Text(group.label)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let summary = group.statusSummary {
                        Text(summary)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(group.isAnyOn ? accentColor : DesignTokens.secondaryText)
                    }
                }
                .padding(.horizontal, 9)
                .frame(minHeight: DesignTokens.minHitTarget)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(group.isAnyOn
                ? L10n.format("关闭 %@", "Turn off %@", group.label)
                : L10n.format("打开 %@", "Turn on %@", group.label)))
            .panelHelp(group.isAnyOn
                ? L10n.format("一键关闭 %@", "Turn off all in %@", group.label)
                : L10n.format("一键打开 %@", "Turn on all in %@", group.label))

            if group.kind == .light && group.supportsBrightnessControl {
                Button {
                    draftBrightness = Double(group.averageBrightness ?? 80)
                    isShowingBrightness = true
                } label: {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(group.isAnyOn ? accentColor : DesignTokens.secondaryText)
                        .frame(width: DesignTokens.minHitTarget, height: DesignTokens.minHitTarget)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.format("调节 %@ 亮度", "Adjust brightness for %@", group.label)))
                .panelHelp(L10n.format("统一调节 %@ 亮度", "Adjust group brightness for %@", group.label))
                .popover(isPresented: $isShowingBrightness) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(group.label).font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            Spacer(minLength: 8)
                            Text("\(Int(draftBrightness.rounded()))%")
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                .monospacedDigit().foregroundStyle(accentColor)
                        }
                        Slider(value: $draftBrightness, in: 1...100, step: 1) { editing in
                            if !editing {
                                let percent = Int(draftBrightness.rounded())
                                Task { await store.setRoomGroupLightBrightness(group, percent: percent) }
                            }
                        }
                        .frame(width: 190)
                    }
                    .padding(12)
                }
            }
        }
        .background {
            if theme == .liquidGlass {
                Color.clear.adaptiveGlass(in: shape, interactive: true)
            } else {
                shape.fill(group.isAnyOn ? accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            }
        }
        .overlay(shape.strokeBorder(group.isAnyOn ? accentColor.opacity(0.42) : Color.primary.opacity(0.10), lineWidth: DesignTokens.hairline))
    }
}
