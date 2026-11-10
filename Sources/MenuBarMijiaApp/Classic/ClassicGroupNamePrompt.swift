import SwiftUI
import MijiaCore

/// The classic panel's name prompt: a 16 pt material card with a hairline outline, floating over
/// the dimmed panel while a group, device or room is renamed. The liquid-glass panel uses the
/// system glass module instead, so the classic overlay keeps this shape and its own radius.
struct ClassicGroupNamePrompt: View {
    /// The classic overlay radius. `DesignTokens.Radius.module` grew to 18 with the glass panel;
    /// the classic prompt keeps the 16 pt card the classic snapshots recorded.
    static let overlayRadius: CGFloat = 16

    let title: String
    @State var name: String
    var placeholder: String = L10n.tr("例如：灯光、电器、环境", "e.g. Lights, Appliances")
    var onReset: (() -> Void)? = nil
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: DesignTokens.TypeSize.body))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .classicAdaptiveGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous))
                .focused($focused)
                .onSubmit(save)
            HStack {
                if let onReset {
                    Button(L10n.tr("恢复原名", "Reset"), action: onReset)
                        .buttonStyle(ClassicPillActionButtonStyle())
                }
                Spacer()
                Button(L10n.tr("取消", "Cancel"), action: onCancel)
                    .buttonStyle(ClassicPillActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存", "Save"), action: save)
                    .buttonStyle(ClassicPillActionButtonStyle(isSelected: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background {
            RoundedRectangle(cornerRadius: Self.overlayRadius, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.overlayRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
