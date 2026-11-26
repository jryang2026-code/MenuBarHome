import SwiftUI
import MijiaCore

/// Settings → 常规 → 外接显示器控制（DDC/CI）. Off by default; turning it off clears every
/// detected display and stops all DDC/CI traffic.
struct ExternalDisplaySettingsSection: View {
    @Bindable var displays: ExternalDisplayStore

    var body: some View {
        SettingsSection(title: L10n.tr("外接显示器控制（DDC/CI）", "External Display Control (DDC/CI)")) {
            SettingsToggleRow(
                title: L10n.tr("在面板中控制外接显示器", "Control external displays from the panel"),
                isOn: Binding(get: { displays.isEnabled }, set: { displays.setEnabled($0) })
            )
            .accessibilityIdentifier("settings-external-display-ddc")

            Text(L10n.tr(
                "支持 Redmi G27U 等外接显示器的亮度、音量与 DP/HDMI/USB-C 输入源切换。未开启时零后台开销；为保护显示器固件、避免假死，刻意不提供电源关屏（0xD6）。M1/M2 基础款 Mac 的内置 HDMI 口若无法控制，请改用 USB-C/DP 线缆连接。",
                "Adjust brightness, volume and DP/HDMI/USB-C input on monitors such as the Redmi G27U. Nothing runs in the background while this is off. Power-off (0xD6) is deliberately not offered to protect monitor firmware from hanging. On base M1/M2 Macs the built-in HDMI port may not pass DDC/CI — use a USB-C/DP cable instead."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if displays.isEnabled {
                Divider().overlay(Color.primary.opacity(0.06))
                scanSummary
                HStack {
                    Spacer()
                    Button(displays.isRefreshing
                           ? L10n.tr("正在扫描…", "Scanning…")
                           : L10n.tr("扫描外接显示器", "Scan External Displays")) {
                        displays.refresh()
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .disabled(displays.isRefreshing)
                }
            }
        }
    }

    @ViewBuilder
    private var scanSummary: some View {
        if let message = displays.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if displays.displays.isEmpty {
            Text(displays.hasScanned
                 ? L10n.tr("未检测到支持 DDC/CI 的外接显示器", "No DDC/CI external display detected")
                 : L10n.tr("点击扫描以检测外接显示器", "Scan to detect external displays"))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
        } else {
            ForEach(displays.displays) { display in
                HStack(spacing: 6) {
                    Image(systemName: "display")
                        .foregroundStyle(.secondary)
                    Text(display.descriptor.name)
                        .lineLimit(1)
                    if display.isRedmiOrXiaomi { ExternalDisplayBadge() }
                    Spacer(minLength: 8)
                    Text(summary(for: display))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private func summary(for display: ExternalDisplayEntry) -> String {
        var parts: [String] = []
        if let brightness = display.brightnessPercent {
            parts.append(L10n.format("亮度 %@%", "Brightness %@%", "\(brightness)"))
        }
        if let source = display.inputSource { parts.append(source.displayTitle) }
        return parts.isEmpty ? L10n.tr("已连接", "Connected") : parts.joined(separator: " · ")
    }
}
