import SwiftUI
import MijiaCore

struct ClassicOnboardingChecklistCard: View {
    let store: HomeStore
    var onBeginSearch: () -> Void

    var body: some View {
        OnboardingChecklistCard(store: store, onBeginSearch: onBeginSearch, theme: .classic)
    }
}
