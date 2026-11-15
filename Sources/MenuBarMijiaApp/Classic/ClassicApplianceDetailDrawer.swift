import MijiaCore
import SwiftUI

struct ClassicApplianceDetailDrawer: View {
    let device: SmartDevice
    let spec: ApplianceSpec
    let store: HomeStore
    let accent: Color
    let statusColor: Color

    var body: some View {
        ApplianceDetailDrawer(
            device: device,
            spec: spec,
            store: store,
            accent: accent,
            statusColor: statusColor,
            theme: .classic
        )
    }
}
