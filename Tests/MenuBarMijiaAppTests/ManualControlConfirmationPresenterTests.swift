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
                devices: [wall],
                markedLightIds: [],
                offersMarkAsLight: true
            )
        })
        let hint = try #require(prompt.hint)
        #expect(hint.contains("这是灯，以后不再询问"))

        let alert = ManualControlConfirmationPresenter.makeAlert(prompt)
        #expect(alert.informativeText == prompt.message)
        #expect((alert.accessoryView as? NSTextField)?.stringValue == hint)
        // #104: the primary-power wall-switch prompt carries the «this is a light» mark entry as a third button.
        let mark = try #require(prompt.markAsLight)
        #expect(mark.deviceId == wall.id)
        #expect(alert.buttons.map(\.title) == [prompt.cancelTitle, prompt.confirmTitle, mark.title])

        // Non-card confirmations omit the third button and show the rename hint instead.
        let nonCardPrompt = try #require(L10n.$overrideLanguage.withValue(.zhHans) {
            ManualControlPolicy.confirmation(
                DeviceIntent(targetId: wall.id, operation: .power(true)),
                devices: [wall],
                markedLightIds: [],
                offersMarkAsLight: false
            )
        })
        #expect(nonCardPrompt.markAsLight == nil)
        #expect(nonCardPrompt.hint?.contains("加上「灯」") == true)
        #expect(nonCardPrompt.hint?.contains("这是灯，以后不再询问") == false)
        let nonCardAlert = ManualControlConfirmationPresenter.makeAlert(nonCardPrompt)
        #expect(nonCardAlert.buttons.map(\.title) == [nonCardPrompt.cancelTitle, nonCardPrompt.confirmTitle])
    }

    @Test("A marked wall switch never offers the mark entry, other prompts keep two buttons (#104)")
    func markedSwitchPromptKeepsTwoButtons() throws {
        let wall = SmartDevice(
            id: "wall-marked", name: "左键", roomId: "hall", roomName: "玄关",
            model: "lumi.switch.b1nacn02", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.wall", isOn: false, powerWritable: true))
        )
        let marked = ManualControlPolicy.confirmation(
            DeviceIntent(targetId: wall.id, operation: .power(true)),
            devices: [wall],
            markedLightIds: [wall.id],
            offersMarkAsLight: true
        )
        #expect(marked == nil, "the marked wall switch asks nothing at all")

        let plug = SmartDevice(
            id: "plug", name: "书房插座", roomId: "study", roomName: "书房",
            model: "cuco.plug.v3", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.plug", isOn: false, powerWritable: true))
        )
        let plugPrompt = try #require(ManualControlPolicy.confirmation(
            DeviceIntent(targetId: plug.id, operation: .power(true)),
            devices: [plug],
            markedLightIds: [],
            offersMarkAsLight: true
        ))
        #expect(plugPrompt.markAsLight == nil, "a real plug never offers the mark entry")
    }

    @Test("Choosing «这是灯，以后不再询问» marks and executes primary power once; cancelling writes no mark (#104)")
    func modalResponseMarksAndExecutesOnceWhileCancelWritesNothing() async throws {
        let wall = SmartDevice(
            id: "wall-modal", name: "左键", roomId: "hall", roomName: "玄关",
            model: "lumi.switch.b1nacn02", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.wall_modal", isOn: false, powerWritable: true))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [wall], scenes: []))
        let suiteName = "test.presenter.modal.\(UUID().uuidString)"
        let store = HomeStore(provider: provider, defaultsSuiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        store.controlDebounceInterval = .milliseconds(10)
        try await store.waitForTestSnapshot()
        let device = try #require(store.devices.first { $0.id == wall.id })

        // 1. Cancel neither marks nor executes.
        var nextModalResponse: NSApplication.ModalResponse = .alertFirstButtonReturn
        store.manualControlConfirmationHandler = { prompt in
            ManualControlConfirmationPresenter.applyModalResponse(nextModalResponse, for: prompt, in: store)
        }
        #expect(store.togglePrimary(device) == nil)
        #expect(!store.isSwitchMarkedAsLight(wall.id))
        #expect(await provider.executedCommands.isEmpty)

        // 2. Third button persists the mark and runs the current primary power action once.
        nextModalResponse = .alertThirdButtonReturn
        let task = try #require(store.togglePrimary(device))
        #expect(await task.value == true)
        #expect(store.isSwitchMarkedAsLight(wall.id))
        let commands = await provider.executedCommands
        #expect(commands == [.setSwitch(entityId: "switch.wall_modal", isOn: true)])
    }
}
