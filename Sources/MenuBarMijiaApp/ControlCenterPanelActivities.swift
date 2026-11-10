import SwiftUI
import MijiaCore

extension ControlCenterPanel {
    var activityStack: some View {
        ActivityStackView(
            activities: store.panelActivities,
            isExpanded: $activitiesExpanded,
            dismiss: store.dismissActivity,
            clear: store.clearDismissibleActivities,
            label: activityLabel
        ) { activity in
            activityContent(activity)
        }
    }

    @ViewBuilder
    private func activityContent(_ activity: PanelActivity) -> some View {
        switch activity.kind {
        case .notice(let kind):
            switch kind {
            case .miBlocked, .miExpiringSoon: miSessionExpiryBanner
            case .haPlaintext(let prompt): haPlaintextConsentBanner(prompt)
            case .haAddress(let instance): haAddressSuggestionBanner(instance)
            }
        case .safety(let recorded):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label(recorded.alert.title, systemImage: "exclamationmark.shield.fill")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    Spacer(minLength: 4)
                    activityTime(recorded.date)
                }
                Text(recorded.alert.body)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if recorded.alert.turnOffCommand != nil {
                    Button(L10n.tr("立即关闭", "Turn Off Now")) {
                        _ = store.executeSafetyAlertAction(recorded.alert, deliveredInScope: recorded.scope)
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                }
            }
            .padding(10)
        case .doorbell(let ring):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label(activityLabel(activity), systemImage: "video.doorbell.fill")
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    Spacer(minLength: 4)
                    if let date = activity.date { activityTime(date) }
                }
                Button(L10n.tr("查看画面", "View Camera")) { store.openCameraLiveView(ring.deviceId) }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
            .padding(10)
        }
    }

    private func activityTime(_ date: Date) -> some View {
        Text(date, style: .relative)
            .font(.system(size: DesignTokens.TypeSize.micro))
            .foregroundStyle(.secondary)
    }

    private func activityLabel(_ activity: PanelActivity) -> String {
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
            store.devices.first(where: { $0.id == ring.deviceId })?.name ?? L10n.tr("门铃", "Doorbell")
        }
    }
}
