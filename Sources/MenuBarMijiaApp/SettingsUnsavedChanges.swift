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

/// Asks `shouldClose` before the window hosting this view closes, so a failed Save keeps the window
/// (and its drafts) open and the prompt can offer Cancel. The window's own delegate keeps receiving
/// everything else.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.shouldClose = shouldClose
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.shouldClose = shouldClose
    }

    @MainActor
    final class Probe: NSView {
        var shouldClose: () -> Bool = { true }
        private var guardDelegate: Delegate?
        private weak var guardedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, guardedWindow !== window else { return }
            restore()
            let delegate = Delegate(original: window.delegate) { [weak self] in self?.shouldClose() ?? true }
            guardDelegate = delegate
            guardedWindow = window
            window.delegate = delegate
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { restore() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func restore() {
            if let window = guardedWindow, window.delegate === guardDelegate {
                window.delegate = guardDelegate?.original
            }
            guardDelegate = nil
            guardedWindow = nil
        }
    }

    @MainActor
    final class Delegate: NSObject, NSWindowDelegate {
        /// `responds(to:)` and `forwardingTarget(for:)` are declared nonisolated by NSObject, so they cannot
        /// read a main-actor property. AppKit sends them from the main thread, and the reference is weak,
        /// so a stale read cannot dangle; `nonisolated(unsafe)` says exactly that.
        nonisolated(unsafe) weak var original: NSWindowDelegate?
        private let shouldClose: () -> Bool

        init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
            self.original = original
            self.shouldClose = shouldClose
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard original?.windowShouldClose?(sender) ?? true else { return false }
            return shouldClose()
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
