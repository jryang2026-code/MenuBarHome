import MijiaCore
import SwiftUI

typealias ClassicDetailValueText = DetailValueText
typealias ClassicGenericDetailDrawer = GenericDetailDrawer

struct ClassicDetailPillButton: View {
    let title: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        DetailPillButton(title: title, tint: tint, theme: .classic, action: action)
    }
}

struct ClassicDetailSliderControl: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let iconName: String
    var iconColor: Color = .secondary
    var trackColors: [Color]
    let formattedValue: String
    let onChange: (Double) -> Void

    var body: some View {
        DetailSliderControl(
            value: value,
            range: range,
            step: step,
            iconName: iconName,
            iconColor: iconColor,
            trackColors: trackColors,
            formattedValue: formattedValue,
            theme: .classic,
            onChange: onChange
        )
    }
}

struct ClassicDeviceFacetSection: View {
    let device: SmartDevice
    let store: HomeStore
    let accent: Color
    let statusColor: Color
    var initiallyExpanded: Bool = false
    var initiallyShowsRest: Bool = false

    var body: some View {
        DeviceFacetSection(
            device: device,
            store: store,
            accent: accent,
            statusColor: statusColor,
            initiallyExpanded: initiallyExpanded,
            initiallyShowsRest: initiallyShowsRest,
            theme: .classic
        )
    }
}
