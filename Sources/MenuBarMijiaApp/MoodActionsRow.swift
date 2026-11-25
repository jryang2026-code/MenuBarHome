import MijiaCore
import SwiftUI

struct MoodActionsRow: View {
    let store: HomeStore
    @State private var isCapturing = false
    @State private var roomId = ""
    @State private var name = ""

    private var rooms: [RoomArea] {
        var seen: Set<String> = []
        return store.devices.compactMap { device in
            guard seen.insert(device.roomId).inserted else { return nil }
            return RoomArea(id: device.roomId, name: device.roomName.isEmpty
                ? L10n.tr("未分配房间", "Unassigned") : device.roomName)
        }
    }

    var body: some View {
        HStack {
            Button {
                roomId = rooms.first?.id ?? ""
                name = ""
                isCapturing = true
            } label: {
                Label(L10n.tr("保存当前为氛围", "Capture Current as a Mood"), systemImage: "plus")
            }
            .disabled(rooms.isEmpty)
            .popover(isPresented: $isCapturing) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.tr("房间", "Room"), selection: $roomId) {
                        ForEach(rooms) { room in Text(room.name).tag(room.id) }
                    }
                    TextField(L10n.tr("氛围名称", "Mood Name"), text: $name)
                    Button(L10n.tr("保存", "Save")) {
                        if store.captureMood(name: name, roomId: roomId) {
                            isCapturing = false
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(14)
                .frame(width: 250)
            }
            if !store.moods.isEmpty {
                Menu {
                    ForEach(store.moods) { mood in
                        Button(mood.name) { Task { await store.applyMood(id: mood.id) } }
                    }
                    Menu(L10n.tr("删除氛围", "Delete Mood")) {
                        ForEach(store.moods) { mood in
                            Button(mood.name, role: .destructive) { store.deleteMood(id: mood.id) }
                        }
                    }
                } label: {
                    Label(L10n.tr("应用氛围", "Apply Mood"), systemImage: "sparkles")
                }
                .fixedSize()
            }
        }
        .font(.system(size: DesignTokens.TypeSize.caption))
    }
}
