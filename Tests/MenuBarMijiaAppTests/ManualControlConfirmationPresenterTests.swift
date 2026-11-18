import AppKit
import ObjectiveC
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

extension NSWorkspace {
    /// Stand-in for `icon(forFile:)`. `NSAlert`'s nib calls that method, and on the
    /// hosted runner the IconServices reply never arrives.
    @objc func snapshotTest_iconForFile(_ path: String) -> NSImage {
        NSImage(size: NSSize(width: 1, height: 1))
    }
}

/// Swap `icon(forFile:)` with the stub. Call again to put the original back.
private func exchangeFileIconMethod() -> Bool {
    let workspace: AnyClass = NSWorkspace.self
    guard
        let original = class_getInstanceMethod(workspace, #selector(NSWorkspace.icon(forFile:))),
        let stubbed = class_getInstanceMethod(workspace, #selector(NSWorkspace.snapshotTest_iconForFile(_:)))
    else {
        return false
    }
    method_exchangeImplementations(original, stubbed)
    return true
}

@MainActor
@Suite
struct ManualControlConfirmationPresenterTests {
    @Test("makeAlert keeps the message, the hint, and cancel-then-confirm buttons")
    func makeAlertCopiesPromptWithoutDrawing() throws {
        guard exchangeFileIconMethod() else {
            Issue.record(Comment(rawValue: "NSWorkspace.icon(forFile:) could not be stubbed."))
            return
        }
        defer { _ = exchangeFileIconMethod() }

        let wall = SmartDevice(
            id: "wall", name: "左键", roomId: "hall", roomName: "玄关",
            model: "lumi.switch.b1nacn02", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.wall", isOn: false, powerWritable: true))
        )
        let prompt = try #require(L10n.$overrideLanguage.withValue(.zhHans) {
            ManualControlPolicy.confirmation(
                DeviceIntent(targetId: wall.id, operation: .power(true)),
                devices: [wall]
            )
        })
        let hint = try #require(prompt.hint)

        let alert = ManualControlConfirmationPresenter.makeAlert(prompt)
        #expect(alert.informativeText == prompt.message)
        #expect((alert.accessoryView as? NSTextField)?.stringValue == hint)
        #expect(alert.buttons.map(\.title) == [prompt.cancelTitle, prompt.confirmTitle])
    }
}
