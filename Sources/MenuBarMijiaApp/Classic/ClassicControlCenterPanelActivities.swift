import SwiftUI
import MijiaCore

extension ClassicControlCenterPanel {
    var activityStack: some View {
        ClassicActivityStackView(
            activities: store.panelActivities,
            isExpanded: $activitiesExpanded,
            expandedViewportHeight: activityViewportHeight,
            dismiss: store.dismissActivity,
            clear: store.clearDismissibleActivities,
            label: { PanelActivityCard.label($0, devices: store.devices) }
        ) { activity in
            PanelActivityCard.content(activity, store: store, theme: .classic) { kind in
                switch kind {
                case .miBlocked, .miExpiringSoon: miSessionExpiryBanner
                case .haPlaintext(let prompt): haPlaintextConsentBanner(prompt)
                case .haAddress(let instance): haAddressSuggestionBanner(instance)
                }
            }
        }
    }
}
