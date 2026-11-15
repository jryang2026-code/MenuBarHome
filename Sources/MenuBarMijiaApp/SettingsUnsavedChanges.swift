import AppKit
import Observation
import MijiaCore
import SwiftUI

/// #148: forms that need an explicit Save (Home Assistant address and token, the AI service) report
/// here whether they hold edits that were never saved. Leaving the page or closing the window with
/// such edits asks first instead of silently dropping them.
///
/// Switches and pickers apply at once and never register. The rule is written down in
/// `CODING_STANDARDS.md` §17.
@MainActor
@Observable
final class SettingsUnsavedChanges {
    struct Form {
        let title: String
        let isDirty: Bool
        /// Saves the form. `false` means it could not (a missing address, a refused Keychain write).
        let save: @MainActor () -> Bool
        let discard: @MainActor () -> Void
    }

    enum Choice: Equatable {
        case save
        case discard
        case cancel
    }

    private(set) var forms: [String: Form] = [:]

    func register(_ id: String, _ form: Form) {
        forms[id] = form
    }

    func unregister(_ id: String) {
        forms[id] = nil
    }

    var dirtyForms: [Form] {
        forms.values.filter(\.isDirty).sorted { $0.title < $1.title }
    }

    var isDirty: Bool { forms.values.contains(where: \.isDirty) }

    /// Whether the caller may go on leaving. Nothing is asked when no form is dirty. `Save` that fails
    /// keeps the user where the problem is; `Discard` resets the drafts; `Cancel` stays.
    func resolveBeforeLeaving(
        allowCancel: Bool,
        ask: (_ titles: [String], _ allowCancel: Bool) -> Choice
    ) -> Bool {
        let dirty = dirtyForms
        guard !dirty.isEmpty else { return true }
        switch ask(dirty.map(\.title), allowCancel) {
        case .save:
            return dirty.allSatisfy { $0.save() }
        case .discard:
            dirty.forEach { $0.discard() }
            return true
        case .cancel:
            return false
        }
    }

    /// The real prompt: Save is the default button.
    func resolveBeforeLeaving(allowCancel: Bool) -> Bool {
        resolveBeforeLeaving(allowCancel: allowCancel, ask: Self.presentAlert)
    }

    private static func presentAlert(titles: [String], allowCancel: Bool) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("有更改还没保存", "You have unsaved changes")
        alert.informativeText = L10n.tr(
            "「\(titles.joined(separator: "」「"))」里的改动还没有保存。",
            "Changes in \(titles.joined(separator: ", ")) have not been saved."
        )
        alert.addButton(withTitle: L10n.tr("保存", "Save"))
        alert.addButton(withTitle: L10n.tr("放弃更改", "Discard Changes"))
        if allowCancel {
            alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}

private struct SettingsUnsavedChangesKey: EnvironmentKey {
    static let defaultValue: SettingsUnsavedChanges? = nil
}

extension EnvironmentValues {
    var settingsUnsavedChanges: SettingsUnsavedChanges? {
        get { self[SettingsUnsavedChangesKey.self] }
        set { self[SettingsUnsavedChangesKey.self] = newValue }
    }
}

/// "有未保存的更改" beside a form's Save button.
struct UnsavedChangesBadge: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Label(L10n.tr("有未保存的更改", "Unsaved changes"), systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .foregroundStyle(.orange)
                .imageScale(.small)
        }
    }
}

/// Runs `onClose` when the window hosting this view is about to close. The window closes either way,
/// so the handler can offer Save or Discard but not Cancel.
struct WindowWillCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onClose = onClose
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onClose = onClose
    }

    final class Probe: NSView {
        var onClose: (() -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let token {
                NotificationCenter.default.removeObserver(token)
                self.token = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
