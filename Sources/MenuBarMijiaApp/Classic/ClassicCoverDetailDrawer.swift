import MijiaCore
import SwiftUI

struct ClassicCoverDetailDrawer: View {
    let device: SmartDevice
    let spec: CoverSpec
    let store: HomeStore
    let accent: Color
    let statusColor: Color

    var body: some View {
        CoverDetailDrawer(
            device: device,
            spec: spec,
            store: store,
            accent: accent,
            statusColor: statusColor,
            theme: .classic
        )
    }
}
