import AppKit
import Foundation
import MijiaCore
import SwiftUI

@MainActor
enum LocalNetworkSystemSettings {
    static let privacyLocalNetworkURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    )!

    static func open() {
        if NSWorkspace.shared.open(privacyLocalNetworkURL) { return }
        SettingsWindowOpener.shared.show(tab: .connection)
    }

    static func blockedSubsystemSummary(_ blocked: Set<LocalNetworkBlockedFeature>) -> String {
        let ordered: [LocalNetworkBlockedFeature] = [.xiaomiLAN, .homeAssistant, .lgWebOS]
        let names = ordered.filter { blocked.contains($0) }.map { feature in
            switch feature {
            case .xiaomiLAN: return L10n.tr("小米局域网控制", "Xiaomi LAN control")
            case .homeAssistant: return "Home Assistant"
            case .lgWebOS: return L10n.tr("LG 电视", "LG TV")
            }
        }
        return names.isEmpty ? L10n.tr("局域网设备", "local network devices") : names.joined(separator: L10n.tr("、", ", "))
    }
}

struct DeviceTransportReadoutRow: View {
    let deviceId: String
    let store: HomeStore
    var theme: PanelTheme = .liquidGlass

    var body: some View {
        if let diagnostics = store.deviceTransportDiagnostics[deviceId] {
            HStack(spacing: 6) {
                Image(systemName: symbolName(for: diagnostics.route))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(iconColor(for: diagnostics.route))
                Text(statusTitle(for: diagnostics))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(textColor(for: diagnostics.route))
                    .lineLimit(1)
                if diagnostics.usedBroadcastRecovery {
                    Text(L10n.tr("自动重连", "Auto-healed"))
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                        .foregroundStyle(DesignTokens.Orb.plug)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule(style: .continuous).fill(DesignTokens.Orb.plug.opacity(0.14)))
                }
                Spacer(minLength: 6)
                trailingContent(for: diagnostics)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func trailingContent(for diagnostics: DeviceTransportDiagnostics) -> some View {
        switch diagnostics.route {
        case .lan:
            if let rtt = diagnostics.rttMs {
                DetailValueText(text: "\(rtt) ms", color: .secondary)
            }
        case .cloud:
            DetailValueText(text: L10n.tr("云端转发", "Cloud Relay"), color: .secondary)
        case .cooldown:
            Button(L10n.tr("重试", "Retry")) { store.retryDeviceLAN(deviceId) }
                .themedPillButtonStyle(theme)
        case .localNetworkBlocked:
            Button(L10n.tr("打开系统设置", "Open System Settings")) { LocalNetworkSystemSettings.open() }
                .themedPillButtonStyle(theme, isSelected: true, tintColor: .orange)
        }
    }

    private func symbolName(for route: DeviceTransportRoute) -> String {
        switch route {
        case .lan: return "wifi"
        case .cloud: return "icloud"
        case .cooldown: return "exclamationmark.arrow.triangle.2.circlepath"
        case .localNetworkBlocked: return "network.slash"
        }
    }

    private func iconColor(for route: DeviceTransportRoute) -> Color {
        switch route {
        case .lan: return DesignTokens.Orb.plug
        case .cloud: return .secondary
        case .cooldown, .localNetworkBlocked: return .orange
        }
    }

    private func textColor(for route: DeviceTransportRoute) -> Color {
        switch route {
        case .lan, .cloud: return .secondary
        case .cooldown, .localNetworkBlocked: return .primary
        }
    }

    private func statusTitle(for diagnostics: DeviceTransportDiagnostics) -> String {
        switch diagnostics.route {
        case .lan: return L10n.tr("局域网直连", "LAN Direct")
        case .cloud: return L10n.tr("米家云端", "Xiaomi Cloud")
        case .cooldown: return L10n.tr("局域网暂不可达，已回退云端", "LAN unreachable, using Cloud")
        case .localNetworkBlocked: return L10n.tr("本地网络权限已关闭", "Local network access is off")
        }
    }
}

struct DeviceCardContextMenuItems: View {
    @Environment(\.headerlessStackMenu) private var headerlessStackMenu
    @AppStorage(GroupPrefs.groupsKey) private var groupsRaw: String = "[]"

    let device: SmartDevice
    let store: HomeStore
    var theme: PanelTheme = .liquidGlass
    let isExpanded: Bool

    private var layoutScope: String { store.selectedRoomId ?? "all" }
    private var panelLayout: PanelLayoutStore { PanelLayoutStore.shared(for: store.userDefaults) }
    private var chosenSize: TileSize {
        let raw = panelLayout.size(of: device.id, scope: layoutScope)
        return theme == .classic ? classicTileSize(raw) : raw
    }
    private var isFavorite: Bool { store.favoriteDeviceIds.contains(device.id) }
    private var availableSizes: [TileSize] {
        theme == .classic ? classicTileSizes : TileSize.allCases
    }

    private func setSize(_ size: TileSize) {
        withAnimation(AppleMotion.snappySpring) {
            panelLayout.setSize(size, of: device.id, scope: layoutScope)
        }
    }

    private func assignGroup(_ groupId: String?) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            panelLayout.assign(device.id, toGroup: groupId)
        }
    }

    static func transportRouteTitle(_ diagnostics: DeviceTransportDiagnostics) -> String {
        switch diagnostics.route {
        case .lan:
            if let rtt = diagnostics.rttMs {
                return L10n.tr("通信通道：局域网直连（\(rtt) ms）", "Transport: LAN Direct (\(rtt) ms)")
            }
            return L10n.tr("通信通道：局域网直连", "Transport: LAN Direct")
        case .cloud:
            return L10n.tr("通信通道：米家云端", "Transport: Xiaomi Cloud")
        case .cooldown:
            return L10n.tr("通信通道：云端回退（局域网重连中）", "Transport: Cloud Fallback (reconnecting LAN)")
        case .localNetworkBlocked:
            return L10n.tr("通信通道：本地网络权限受阻", "Transport: Local network blocked")
        }
    }

    var body: some View {
        let diagnostics = store.deviceTransportDiagnostics[device.id]
        let isPaired = store.isPairedDualSourceDevice(device.id)

        if let diagnostics {
            Text(Self.transportRouteTitle(diagnostics))
        }

        if isPaired {
            Text(store.currentSourceMenuTitle(for: device.id))
            Menu {
                Button {
                    store.pinDeviceSource(device.id, to: nil)
                } label: {
                    if store.pinnedSource(for: device.id) == nil {
                        Label(L10n.tr("自动择优（默认）", "Automatic (Default)"), systemImage: "checkmark")
                    } else {
                        Text(L10n.tr("自动择优（默认）", "Automatic (Default)"))
                    }
                }
                Button {
                    store.pinDeviceSource(device.id, to: .homeAssistant)
                } label: {
                    if store.pinnedSource(for: device.id) == .homeAssistant {
                        Label("Home Assistant", systemImage: "checkmark")
                    } else {
                        Text("Home Assistant")
                    }
                }
                Button {
                    store.pinDeviceSource(device.id, to: .xiaomiCloud)
                } label: {
                    if store.pinnedSource(for: device.id) == .xiaomiCloud {
                        Label(L10n.tr("米家云端", "Xiaomi Cloud"), systemImage: "checkmark")
                    } else {
                        Text(L10n.tr("米家云端", "Xiaomi Cloud"))
                    }
                }
            } label: {
                Label(L10n.tr("数据来源", "Data Source"), systemImage: "arrow.triangle.branch")
            }
        }

        if diagnostics != nil || isPaired {
            Divider()
        }

        Menu {
            ForEach(availableSizes) { size in
                Button {
                    setSize(size)
                } label: {
                    Label(size.title, systemImage: chosenSize == size ? "checkmark" : size.symbol)
                }
            }
        } label: {
            Label(L10n.tr("卡片大小（本页）", "Card Size (this page)"), systemImage: "square.resize")
        }

        Button {
            LayoutUIState.shared.renamingDeviceId = device.id
        } label: {
            Label(L10n.tr("重命名…", "Rename…"), systemImage: "pencil")
        }

        // #104: marking lives exclusively in the primary-power confirmation dialog; the context
        // menu keeps the undo entry so the user can restore the confirmation later.
        if ManualControlPolicy.wallSwitchMayControlLight(device),
           store.isSwitchMarkedAsLight(device.id) {
            Button {
                store.unmarkSwitchAsLight(device.id)
            } label: {
                Label(
                    L10n.tr("撤销『这是灯』标记", "Undo “this is a light”"),
                    systemImage: "lightbulb.slash"
                )
            }
        }

        Button {
            LayoutUIState.shared.isEditingLayoutRequested = true
        } label: {
            Label(L10n.tr("编辑布局…", "Edit Layout…"), systemImage: "rectangle.3.group")
        }

        Menu {
            let groups = GroupPrefs.groups(groupsRaw)
            let current = panelLayout.groupMap[device.id]
            ForEach(groups) { group in
                Button {
                    assignGroup(group.id)
                } label: {
                    Label(group.name, systemImage: current == group.id ? "checkmark" : "folder")
                }
            }
            if current != nil {
                Button {
                    assignGroup(nil)
                } label: {
                    Label(L10n.tr("不分组", "No Group"), systemImage: "tray")
                }
            }
            if !groups.isEmpty { Divider() }
            Button {
                LayoutUIState.shared.newGroupForDevice = device.id
            } label: {
                Label(L10n.tr("新建分组…", "New Group…"), systemImage: "folder.badge.plus")
            }
        } label: {
            Label(L10n.tr("移到分组", "Move to Group"), systemImage: "folder")
        }

        if theme == .liquidGlass, let parentMenu = headerlessStackMenu {
            Menu {
                parentMenu.makeContent()
            } label: {
                Label(parentMenu.title, systemImage: parentMenu.symbol)
            }
        }

        Divider()

        Button {
            store.toggleFavorite(device.id)
        } label: {
            Label(
                isFavorite ? L10n.tr("取消常用星标", "Remove from Favorites") : L10n.tr("设为常用星标", "Add to Favorites"),
                systemImage: isFavorite ? "star.slash" : "star.fill"
            )
        }

        if isFavorite {
            Button {
                store.moveFavorite(deviceId: device.id, direction: -1)
            } label: {
                Label(L10n.tr("常用排序上移", "Move Up in Favorites"), systemImage: "arrow.up")
            }

            Button {
                store.moveFavorite(deviceId: device.id, direction: 1)
            } label: {
                Label(L10n.tr("常用排序下移", "Move Down in Favorites"), systemImage: "arrow.down")
            }
        }

        if case .camera = device.kind {
            Button {
                store.openCameraLiveView(device.id)
            } label: {
                Label(L10n.tr("打开实时画面小窗", "Open Floating Live View"), systemImage: "pip.enter")
            }
        }

        if store.hasDetailDrawer(for: device) {
            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.toggleExpanded(device.id)
                }
            } label: {
                Label(
                    isExpanded ? L10n.tr("收起详细控制", "Collapse Controls") : L10n.tr("展开详细控制", "Expand Controls"),
                    systemImage: "slider.horizontal.3"
                )
            }
        } else if case .sensor(let spec) = device.kind, spec.temperature != nil || spec.humidity != nil {
            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.toggleExpanded(device.id)
                }
            } label: {
                Label(
                    isExpanded ? L10n.tr("收起温湿度折线", "Collapse Chart") : L10n.tr("展开温湿度折线", "Expand Chart"),
                    systemImage: "chart.xyaxis.line"
                )
            }
        }

        if DeviceCardView.showsAllOffMenuOption(for: device) {
            Button {
                store.setJoinsAllOff(!store.joinsAllOff(device), deviceId: device.id)
            } label: {
                if store.joinsAllOff(device) {
                    Label(L10n.tr("不参与「全关」", "Leave Out of All Off"), systemImage: "power.circle")
                } else {
                    Label(L10n.tr("参与「全关」", "Include in All Off"), systemImage: "power.circle.fill")
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            withAnimation(AppleMotion.snappySpring) {
                store.hideDevice(device.id)
            }
        } label: {
            Label(L10n.tr("隐藏此设备", "Hide Device"), systemImage: "eye.slash")
        }
    }
}

struct LocalNetworkPermissionBannerView: View {
    let blockedFeatures: Set<LocalNetworkBlockedFeature>
    let store: HomeStore
    var theme: PanelTheme = .liquidGlass
    var inSettings: Bool = false

    private var subsystemNames: String {
        LocalNetworkSystemSettings.blockedSubsystemSummary(blockedFeatures)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "network.slash")
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("本地网络权限已关闭", "Local network access is turned off"))
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr(
                        "系统「隐私与安全性 > 本地网络」未授权 MenuBarHome，\(subsystemNames)无法直连局域网设备。",
                        "macOS Privacy & Security > Local Network has blocked MenuBarHome, so \(subsystemNames) cannot reach devices on your LAN."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(inSettings ? DesignTokens.secondaryText : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(L10n.tr("打开系统设置", "Open System Settings")) {
                    LocalNetworkSystemSettings.open()
                }
                .themedPillButtonStyle(theme, isSelected: true, tintColor: .orange)

                Button(L10n.tr("重试连接", "Retry")) {
                    store.refreshNow()
                }
                .themedPillButtonStyle(theme)
            }
        }
        .padding(inSettings ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct XiaomiLANTransportSummaryRow: View {
    let store: HomeStore

    var body: some View {
        if let summary = DeviceTransportSummary.summarize(
            store.deviceTransportDiagnostics,
            localNetworkBlocks: store.effectiveLocalNetworkBlocks
        ), !store.deviceTransportDiagnostics.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "wifi.router")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(summary.lanDeviceCount > 0 ? DesignTokens.Orb.plug : DesignTokens.secondaryText)
                Text(L10n.tr("米家局域网通道", "Xiaomi LAN Transport"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Spacer(minLength: 8)
                Text(Self.summaryLine(summary))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    static func summaryLine(_ summary: DiagnosticsReportBuilder.TransportSummary) -> String {
        var parts: [String] = [
            L10n.tr("直连 \(summary.lanDeviceCount) 台", "LAN \(summary.lanDeviceCount)"),
            L10n.tr("云端 \(summary.cloudDeviceCount) 台", "Cloud \(summary.cloudDeviceCount)")
        ]
        if summary.cooldownDeviceCount > 0 {
            parts.append(L10n.tr("重连中 \(summary.cooldownDeviceCount) 台", "Cooldown \(summary.cooldownDeviceCount)"))
        }
        if summary.blockedDeviceCount > 0 {
            parts.append(L10n.tr("权限受阻 \(summary.blockedDeviceCount) 台", "Blocked \(summary.blockedDeviceCount)"))
        }
        if summary.broadcastRecoveredCount > 0 {
            parts.append(L10n.tr("自动重连 \(summary.broadcastRecoveredCount) 台", "Auto-healed \(summary.broadcastRecoveredCount)"))
        }
        if let rtt = summary.medianLANRTTMs {
            parts.append("\(rtt) ms")
        }
        return parts.joined(separator: " · ")
    }
}
