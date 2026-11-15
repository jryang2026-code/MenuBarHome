import SwiftUI
import MijiaCore

struct ClassicTransientStackView: View {
    let store: HomeStore
    let toast: ToastNotice?
    let initialExpanded: Bool
    let onHeightChange: (CGFloat) -> Void

    init(
        store: HomeStore,
        toast: ToastNotice?,
        initialExpanded: Bool = false,
        onHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.store = store
        self.toast = toast
        self.initialExpanded = initialExpanded
        self.onHeightChange = onHeightChange
    }

    var body: some View {
        TransientStackView(
            store: store,
            toast: toast,
            initialExpanded: initialExpanded,
            theme: .classic,
            onHeightChange: onHeightChange
        )
    }
}
