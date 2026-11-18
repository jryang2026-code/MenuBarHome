import SwiftUI
import MijiaCore

struct ClassicActivityStackView<Content: View>: View {
    let activities: [PanelActivity]
    var missedTimers: [ScheduledCommand] = []
    let store: HomeStore
    @Binding var isExpanded: Bool
    let expandedViewportHeight: CGFloat
    let dismiss: (PanelActivity) -> Void
    let clear: () -> Void
    var runMissedTimer: ((UUID) -> Void)? = nil
    var dismissMissedTimer: ((UUID) -> Void)? = nil
    let label: (PanelActivity) -> String
    @ViewBuilder let content: (PanelActivity) -> Content

    var body: some View {
        ActivityStackView(
            activities: activities,
            missedTimers: missedTimers,
            store: store,
            isExpanded: $isExpanded,
            expandedViewportHeight: expandedViewportHeight,
            theme: .classic,
            dismiss: dismiss,
            clear: clear,
            runMissedTimer: runMissedTimer,
            dismissMissedTimer: dismissMissedTimer,
            label: label,
            content: content
        )
    }
}
