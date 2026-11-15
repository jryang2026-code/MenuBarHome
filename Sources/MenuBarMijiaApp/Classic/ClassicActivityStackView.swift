import SwiftUI
import MijiaCore

struct ClassicActivityStackView<Content: View>: View {
    let activities: [PanelActivity]
    @Binding var isExpanded: Bool
    let expandedViewportHeight: CGFloat
    let dismiss: (PanelActivity) -> Void
    let clear: () -> Void
    let label: (PanelActivity) -> String
    @ViewBuilder let content: (PanelActivity) -> Content

    var body: some View {
        ActivityStackView(
            activities: activities,
            isExpanded: $isExpanded,
            expandedViewportHeight: expandedViewportHeight,
            theme: .classic,
            dismiss: dismiss,
            clear: clear,
            label: label,
            content: content
        )
    }
}
