import AppKit
import SwiftUI
import MijiaCore

/// Shared presentation & action dispatch for the "signed in to Xiaomi Cloud, 0 devices" empty panel
/// across both Liquid Glass and Classic themes (#67, #76).
@MainActor
enum EmptyPanelDiagnosisPresenter {
    struct Copy: Equatable {
        let iconName: String
        let isWarning: Bool
        let title: String
        let detail: String
        let actionTitle: String
        let showsResyncButton: Bool
        let action: EmptyPanelSuggestedAction
    }

    static func copy(for reason: EmptyPanelReason, region: MiCloudRegion) -> Copy {
        switch reason {
        case .sessionReauthRequired:
            return Copy(
                iconName: "qrcode",
                isWarning: true,
                title: L10n.tr("米家登录状态已失效", "Xiaomi Home sign-in expired"),
                detail: L10n.tr(
                    "升级或改名迁移后旧会话可能已失效，重新扫码登录即可恢复设备列表。",
                    "Your session may have expired after an upgrade or migration. Scan to sign in again and restore your devices."
                ),
                actionTitle: L10n.tr("重新扫码登录", "Sign In Again"),
                showsResyncButton: false,
                action: reason.suggestedAction
            )
        case .syncFailed:
            return Copy(
                iconName: "exclamationmark.triangle",
                isWarning: true,
                title: L10n.tr("同步米家设备失败", "Failed to sync Xiaomi Home devices"),
                detail: L10n.tr(
                    "最近一次云端同步未能拉取设备，可复制脱敏诊断信息排查或重试同步。",
                    "The latest cloud sync could not load devices. Copy desensitized diagnostics to troubleshoot, or try syncing again."
                ),
                actionTitle: L10n.tr("复制诊断", "Copy Diagnostics"),
                showsResyncButton: true,
                action: reason.suggestedAction
            )
        case .possibleWrongRegion:
            return Copy(
                iconName: "globe",
                isWarning: false,
                title: L10n.tr("当前服务器区域未找到家庭", "No homes found in this server region"),
                detail: L10n.tr(
                    "当前地区（\(region.rawValue)）没有返回任何家庭，可能选错了米家服务器区域。",
                    "No homes were returned for region (\(region.rawValue)). You may have selected the wrong Xiaomi Cloud server region."
                ),
                actionTitle: L10n.tr("切换区域", "Switch Region"),
                showsResyncButton: true,
                action: reason.suggestedAction
            )
        case .noHomes:
            return Copy(
                iconName: "house",
                isWarning: false,
                title: L10n.tr("当前米家账号下没有家庭", "No homes in this Xiaomi account"),
                detail: L10n.tr(
                    "请先在手机「米家」App 中确认已创建或接受共享家庭，再回来重新同步。",
                    "Check the Mi Home app on your phone to confirm a home or shared home exists for this account, then sync again."
                ),
                actionTitle: L10n.tr("打开米家确认家庭", "Check Homes in Mi Home"),
                showsResyncButton: true,
                action: reason.suggestedAction
            )
        case .homesWithoutDevices:
            return Copy(
                iconName: "sparkles",
                isWarning: false,
                title: L10n.tr("已找到家庭，但没有可显示的设备", "Homes found, but no displayable devices"),
                detail: L10n.tr(
                    "请确认手机米家 App 里这些家庭下有设备（含被共享家庭）。若设备仍不显示，请复制诊断信息反馈。",
                    "Check that these homes have devices in the Mi Home app (shared homes included). If devices are still missing, copy diagnostics to report it."
                ),
                actionTitle: L10n.tr("复制诊断", "Copy Diagnostics"),
                showsResyncButton: true,
                action: reason.suggestedAction
            )
        }
    }

    static func perform(_ action: EmptyPanelSuggestedAction, store: HomeStore) {
        switch action {
        case .reauth:
            if store.miSessionMaskedUserId != nil || !store.enabledMiAccounts.isEmpty {
                withAnimation(AppleMotion.resolve(.snappy)) {
                    store.presentMiReauth()
                }
            } else {
                SettingsWindowOpener.shared.show(tab: .connection, anchor: .miAccount)
            }
        case .switchRegion:
            SettingsWindowOpener.shared.show(tab: .connection, anchor: .miCloudRegion)
        case .confirmMiHome:
            SettingsWindowOpener.shared.show(tab: .connection, anchor: .miAccount)
        case .copyDiagnostics:
            copyDiagnosticsToClipboard(store: store)
        }
    }

    @discardableResult
    static func copyDiagnosticsToClipboard(store: HomeStore) -> String {
        let info = Bundle.main.infoDictionary
        let models = Dictionary(grouping: store.devices, by: { $0.model })
            .map { DiagnosticsReportBuilder.ModelCount(model: $0.key, count: $0.value.count) }
        let crashTimestamps = DiagnosticsReportBuilder.crashTimestamps(
            from: AppDiagnosticsLog.crashReportStamps()
        )
        let input = DiagnosticsReportBuilder.Input(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            buildNumber: info?["CFBundleVersion"] as? String ?? "-",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            backendTitle: store.connectionSourceSummary,
            miCloudRegion: store.hasMiSource ? store.miCloudRegion.title : "-",
            deviceCount: store.devices.count,
            onlineDeviceCount: store.onlineDeviceCount,
            hiddenDeviceCount: store.hiddenDevices.count,
            models: models,
            unsupported: [],
            recentErrorCount: AppDiagnosticsLog.shared.errorTimestamps.count,
            lastErrorAt: AppDiagnosticsLog.shared.errorTimestamps.last,
            recentCrashTimestamps: crashTimestamps,
            extraSettings: [
                L10n.tr("快捷键", "Shortcut") + ": " + HotkeyPreferences.load().displayString,
                L10n.tr("本机语音", "On-device speech") + ": " + (store.prefersOnDeviceSpeech ? "on" : "off"),
            ],
            miHomeCount: store.hasMiSource ? store.homes.count : nil,
            miSharedHomeCount: store.hasMiSource ? store.homes.filter(\.isSharedHome).count : nil,
            isMiHomeFiltered: store.hasMiSource && store.selectedMiHomeId != nil,
            transportSummary: DeviceTransportSummary.summarize(
                store.deviceTransportDiagnostics,
                localNetworkBlocks: store.effectiveLocalNetworkBlocks
            )
        )
        let markdown = DiagnosticsReportBuilder.markdown(input)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        store.showToast(L10n.tr("已复制脱敏诊断报告到剪贴板", "Copied desensitized diagnostics report to clipboard"))
        return markdown
    }
}
