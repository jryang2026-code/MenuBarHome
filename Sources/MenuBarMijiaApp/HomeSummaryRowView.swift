import SwiftUI
import MijiaCore

/// First-screen "我家现在" horizontal capsule row summarizing active alerts, lights on,
/// open doors/windows, and indoor temperature (R16 §1.3).
struct HomeSummaryRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    let summary: HomeSummary
    let activeListCut: DeviceListCut
    let theme: PanelTheme
    let onTapCapsule: (HomeSummaryCapsule) -> Void

    var body: some View {
        if !summary.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme == .classic ? ClassicDesign.Space.s : 6) {
                    ForEach(summary.capsules) { capsule in
                        capsuleButton(capsule)
                    }
                }
                .padding(.vertical, 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(L10n.tr("我家现在摘要", "Home Summary")))
            .accessibilityIdentifier("home-summary-row")
        }
    }

    private func isCapsuleSelected(_ capsule: HomeSummaryCapsule) -> Bool {
        guard let tag = capsule.filterTag, case .kind(let activeTag) = activeListCut else {
            return false
        }
        return tag == activeTag
    }

    private func tintColor(for capsule: HomeSummaryCapsule) -> Color {
        switch capsule.kind {
        case .alerts:
            return capsule.alertSeverity == .alert ? Color.red : Color.orange
        case .lightsOn:
            return Color.orange
        case .doorsOpen:
            return Color.indigo
        case .indoorTemp:
            return Color.teal
        }
    }

    private func capsuleButton(_ capsule: HomeSummaryCapsule) -> some View {
        let selected = isCapsuleSelected(capsule)
        let tint = tintColor(for: capsule)
        let title = capsule.title(temperatureUnit: L10n.temperatureUnit)
        let isCriticalAlert = capsule.kind == .alerts && capsule.alertSeverity == .alert

        return Button {
            _ = withAnimation(AppleMotion.resolve(.snappy, reduceMotion: reduceMotion)) {
                onTapCapsule(capsule)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: capsule.sfSymbolName)
                    .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold))
                    .foregroundStyle(selected || isCriticalAlert ? tint : tint.opacity(0.92))
                Text(title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: selected || isCriticalAlert ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(selected ? .primary : (isCriticalAlert ? tint : .primary.opacity(0.88)))
                    .lineLimit(1)
            }
            .padding(.horizontal, theme == .classic ? ClassicDesign.Space.m : 9)
            .padding(.vertical, 4)
            .frame(minHeight: theme == .classic ? ClassicDesign.iconButton : 26)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(
                        selected
                            ? (colorScheme == .dark ? 0.24 : 0.16)
                            : (isCriticalAlert ? (colorScheme == .dark ? 0.18 : 0.12) : 0)
                    ))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        tint.opacity(selected ? 0.55 : (isCriticalAlert ? 0.42 : 0)),
                        lineWidth: selected || isCriticalAlert ? 1 : 0
                    )
            )
            .modifier(HomeSummaryCapsuleSurface(theme: theme))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(Text(
            selected
                ? L10n.tr("再次点击恢复显示全部设备", "Click again to show all devices")
                : L10n.tr("点击筛选或定位相关设备", "Click to filter or jump to matching devices")
        ))
        .accessibilityIdentifier("home-summary-capsule-\(capsule.kind.rawValue)")
    }
}

private struct HomeSummaryCapsuleSurface: ViewModifier {
    let theme: PanelTheme

    func body(content: Content) -> some View {
        switch theme {
        case .classic:
            content.classicAdaptiveGlass(in: Capsule(style: .continuous), interactive: true)
        case .liquidGlass:
            content.adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
        }
    }
}

@MainActor
enum HomeSummaryCapsuleRouter {
    /// Applies a capsule tap: filters by `DeviceKindTag` (toggling back to `.all` if already active),
    /// or focuses the first target device / expands alerts.
    static func handleTap(
        _ capsule: HomeSummaryCapsule,
        store: HomeStore,
        expandActivities: () -> Void,
        scrollToDevice: (String) -> Void
    ) {
        if capsule.kind == .alerts {
            expandActivities()
            if let deviceId = capsule.targetDeviceIds.first {
                if store.listCut != .all {
                    _ = store.selectRoom(nil)
                }
                store.focusedDeviceId = deviceId
                scrollToDevice(deviceId)
            }
            return
        }
        if let tag = capsule.filterTag {
            if case .kind(let current) = store.listCut, current == tag {
                _ = store.selectRoom(nil)
            } else {
                store.selectKind(tag)
            }
            return
        }
        if let deviceId = capsule.targetDeviceIds.first {
            store.focusedDeviceId = deviceId
            scrollToDevice(deviceId)
        }
    }
}
