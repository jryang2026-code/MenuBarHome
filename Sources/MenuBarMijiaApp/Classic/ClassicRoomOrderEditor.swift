import SwiftUI
import MijiaCore

@MainActor
struct ClassicRoomOrderEditor: View {
    let store: HomeStore

    var body: some View {
        RoomOrderEditor(store: store, theme: .classic)
    }
}
