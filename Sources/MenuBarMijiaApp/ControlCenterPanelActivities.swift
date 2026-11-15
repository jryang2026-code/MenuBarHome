import SwiftUI
import MijiaCore

enum PanelActivityCard {
    @MainActor
    @ViewBuilder
    static func content<NoticeView: View>(
        _ activity: PanelActivity,
        store: HomeStore,
        theme: PanelTheme,
        @ViewBuilder notice: (PanelNoticeSlot.Kind) -> NoticeView
    ) -> some View {
        switch activity.kind {
        case .notice(let kind):
            notice(kind)
        case .safety(let recorded):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label(recorded.alert.title, systemImage: "exclamationmark.shield.fill")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    Spacer(minLength: 4)
                    timeView(recorded.date)
                }
                Text(recorded.alert.body)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if recorded.alert.turnOffCommand != nil {
                    Button(L10n.tr("立即关闭", "Turn Off Now")) {
                        _ = store.executeSafetyAlertAction(recorded.alert, deliveredInScope: recorded.scope)
                    }
                    .themedPillButtonStyle(theme, isSelected: true, tintColor: .orange)
                }
            }
            .padding(10)
        case .doorbell(let ring):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label(label(activity, devices: store.devices), systemImage: "video.doorbell.fill")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    Spacer(minLength: 4)
                    if let date = activity.date { timeView(date) }
                }
                Button(L10n.tr("查看画面", "View Camera")) { store.openCameraLiveView(ring.deviceId) }
                    .themedPillButtonStyle(theme, isSelected: true, tintColor: .accentColor)
            }
            .padding(10)
        }
    }

    private static func timeView(_ date: Date) -> some View {
        Text(date, style: .relative)
            .font(.system(size: DesignTokens.TypeSize.micro))
            .foregroundStyle(.secondary)
    }

    static func label(_ activity: PanelActivity, devices: [SmartDevice]) -> String {
        switch activity.kind {
        case .notice(let kind):
            switch kind {
            case .miBlocked: L10n.tr("米家登录已过期", "Xiaomi Home session expired")
            case .miExpiringSoon: L10n.tr("米家登录即将过期", "Xiaomi Home session expires soon")
            case .haPlaintext: L10n.tr("Home Assistant 明文连接", "Home Assistant plaintext connection")
            case .haAddress: L10n.tr("发现 Home Assistant 地址", "Home Assistant address found")
            }
        case .safety(let recorded): recorded.alert.title
        case .doorbell(let ring):
            devices.first(where: { $0.id == ring.deviceId })?.name ?? L10n.tr("门铃", "Doorbell")
        }
    }
}

extension ControlCenterPanel {
    var activityStack: some View {
        ActivityStackView(
            activities: store.panelActivities,
            isExpanded: $activitiesExpanded,
            dismiss: store.dismissActivity,
            clear: store.clearDismissibleActivities,
            label: { PanelActivityCard.label($0, devices: store.devices) }
        ) { activity in
            PanelActivityCard.content(activity, store: store, theme: .liquidGlass) { kind in
                switch kind {
                case .miBlocked, .miExpiringSoon: miSessionExpiryBanner
                case .haPlaintext(let prompt): haPlaintextConsentBanner(prompt)
                case .haAddress(let instance): haAddressSuggestionBanner(instance)
                }
            }
        }
    }
}
