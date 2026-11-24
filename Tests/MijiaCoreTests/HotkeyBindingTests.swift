import Foundation
import Testing
@testable import MijiaCore

@Suite("Per-Device / Per-Scene Global Hotkey Bindings (P1-6)")
struct HotkeyBindingTests {
    private static let light = SmartDevice(
        id: "light.study",
        name: "书房台灯",
        roomId: "room.study",
        roomName: "书房",
        model: "yeelink.light.lamp4",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: false))
    )

    private static let wallSwitchPlug = SmartDevice(
        id: "switch.desk_plug",
        name: "书房插座",
        roomId: "room.study",
        roomName: "书房",
        model: "lumi.switch.b2nacn02",
        isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.desk_plug", isOn: false))
    )

    private static let movieScene = HomeScene(
        id: "scene.movie",
        name: "观影模式",
        entityId: "scene.movie"
    )

    @MainActor
    private func makeStore(
        devices: [SmartDevice] = [Self.light, Self.wallSwitchPlug],
        scenes: [HomeScene] = [Self.movieScene]
    ) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices, scenes: scenes))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.hotkeybindings.\(UUID().uuidString)")
        store.assistantAutoResetTiming = .never
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    @Test("Bindings persist round-trip and enforce the 8-binding cap")
    func persistenceAndCap() throws {
        let suite = "test.hotkey.persist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let shortcuts: [HotkeyShortcut] = (0..<10).map { i in
            HotkeyShortcut(keyCode: UInt16(18 + i), keyLabel: "\(i)", modifiers: [.control, .option])
        }
        let bindings = shortcuts.enumerated().map { idx, shortcut in
            HotkeyBinding(
                id: "b-\(idx)",
                target: idx % 2 == 0 ? .devicePower(deviceId: "dev-\(idx)") : .scene(sceneId: "scene-\(idx)"),
                targetLabel: "Target \(idx)",
                shortcut: shortcut
            )
        }

        HotkeyBindingsPreferences.save(bindings, to: defaults)
        let loaded = HotkeyBindingsPreferences.load(from: defaults)
        #expect(loaded.count == HotkeyBindingsPreferences.maxBindings)
        #expect(loaded.first?.id == "b-0")
        #expect(loaded.first?.target == .devicePower(deviceId: "dev-0"))
        #expect(loaded[1].target == .scene(sceneId: "scene-1"))
    }

    @Test("Conflict detection catches panel hotkey, duplicate bindings, and system shortcuts")
    func conflictDetection() {
        let panelShortcut = HotkeyShortcut.defaultShortcut // ⌥M
        let existingShortcut = HotkeyShortcut(keyCode: 18, keyLabel: "1", modifiers: [.option, .shift])
        let existing = [
            HotkeyBinding(
                id: "b-1",
                target: .devicePower(deviceId: "light.study"),
                targetLabel: "书房台灯",
                shortcut: existingShortcut
            )
        ]

        #expect(
            HotkeyBindingsPreferences.validate(
                shortcut: panelShortcut,
                panelShortcut: panelShortcut,
                existingBindings: existing
            ) == .panelHotkey
        )

        #expect(
            HotkeyBindingsPreferences.validate(
                shortcut: existingShortcut,
                excludingBindingId: nil,
                panelShortcut: panelShortcut,
                existingBindings: existing
            ) == .existingBinding(targetLabel: "书房台灯")
        )

        // Editing the same binding excludes itself from duplicate conflict.
        #expect(
            HotkeyBindingsPreferences.validate(
                shortcut: existingShortcut,
                excludingBindingId: "b-1",
                panelShortcut: panelShortcut,
                existingBindings: existing
            ) == nil
        )

        // Known macOS system shortcuts are rejected.
        let spotlight = HotkeyShortcut(keyCode: 49, keyLabel: "Space", modifiers: .command)
        if case .systemShortcut = HotkeyBindingsPreferences.validate(
            shortcut: spotlight,
            panelShortcut: panelShortcut,
            existingBindings: existing
        ) {
            // expected
        } else {
            Issue.record("Expected ⌘Space to be flagged as a system shortcut conflict")
        }

        // Bare letter is invalid.
        let bareLetter = HotkeyShortcut(keyCode: 0, keyLabel: "A", modifiers: [])
        #expect(
            HotkeyBindingsPreferences.validate(
                shortcut: bareLetter,
                panelShortcut: panelShortcut,
                existingBindings: existing
            ) == .invalidShortcut
        )

        // Distinct valid shortcut passes.
        let ok = HotkeyShortcut(keyCode: 19, keyLabel: "2", modifiers: [.option, .shift])
        #expect(
            HotkeyBindingsPreferences.validate(
                shortcut: ok,
                panelShortcut: panelShortcut,
                existingBindings: existing
            ) == nil
        )
    }

    @Test("Executing a bound low-risk device hotkey toggles primary power through togglePrimary")
    @MainActor
    func executeLowRiskDevice() async throws {
        let (store, mock) = try await makeStore()
        let binding = HotkeyBinding(
            target: .devicePower(deviceId: Self.light.id),
            targetLabel: Self.light.name,
            shortcut: HotkeyShortcut(keyCode: 18, keyLabel: "1", modifiers: [.option, .shift])
        )
        let outcome = await store.executeHotkeyBinding(binding)
        if case .executed = outcome {
            // expected
        } else {
            Issue.record("Expected .executed, got \(outcome)")
        }
        let commands = await mock.executedCommands
        #expect(commands.contains(.setLightPower(entityId: "light.study", isOn: true)))
    }

    @Test("Screen lock blocks device, scene, and quick action hotkeys")
    @MainActor
    func screenLockBlocksAllTargets() async throws {
        let (store, mock) = try await makeStore()
        store.blockControlWhileLocked = true
        store.isScreenLocked = true

        let shortcut = HotkeyShortcut(keyCode: 18, keyLabel: "1", modifiers: [.option, .shift])
        let deviceOutcome = await store.executeHotkeyBinding(
            HotkeyBinding(target: .devicePower(deviceId: Self.light.id), targetLabel: Self.light.name, shortcut: shortcut)
        )
        let sceneOutcome = await store.executeHotkeyBinding(
            HotkeyBinding(target: .scene(sceneId: Self.movieScene.id), targetLabel: Self.movieScene.name, shortcut: shortcut)
        )
        let quickOutcome = await store.executeHotkeyBinding(
            HotkeyBinding(target: .quickAction(.lightsOff), targetLabel: QuickAction.lightsOff.title, shortcut: shortcut)
        )

        #expect(deviceOutcome == .blocked(message: store.screenLockBlockedMessage))
        #expect(sceneOutcome == .blocked(message: store.screenLockBlockedMessage))
        #expect(quickOutcome == .blocked(message: store.screenLockBlockedMessage))
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("High-risk device hotkey still asks for confirmation and never offers don't-ask-again")
    @MainActor
    func highRiskDeviceAsksWithoutDontAskAgain() async throws {
        let (store, mock) = try await makeStore()
        var receivedPrompts: [ManualControlConfirmation] = []
        store.manualControlConfirmationHandler = { prompt in
            receivedPrompts.append(prompt)
            return false
        }

        let binding = HotkeyBinding(
            target: .devicePower(deviceId: Self.wallSwitchPlug.id),
            targetLabel: Self.wallSwitchPlug.name,
            shortcut: HotkeyShortcut(keyCode: 19, keyLabel: "2", modifiers: [.option, .shift])
        )

        let cancelledOutcome = await store.executeHotkeyBinding(binding)
        #expect(receivedPrompts.count == 1)
        #expect(receivedPrompts.first?.markAsLight == nil, "Hotkey confirmation must never offer 'don't ask again'")
        #expect(await mock.executedCommands.isEmpty)
        if case .executed = cancelledOutcome {
            Issue.record("Declined high-risk hotkey must not execute")
        }

        // Approving runs the command.
        store.manualControlConfirmationHandler = { prompt in
            receivedPrompts.append(prompt)
            return true
        }
        let approvedOutcome = await store.executeHotkeyBinding(binding)
        #expect(receivedPrompts.count == 2)
        #expect(receivedPrompts.last?.markAsLight == nil)
        if case .executed = approvedOutcome {
            // expected
        } else {
            Issue.record("Expected approved high-risk hotkey to execute, got \(approvedOutcome)")
        }
        #expect(await mock.executedCommands.contains(.setSwitch(entityId: "switch.desk_plug", isOn: true)))
    }

    @Test("Missing device or scene target is reported unavailable and executes nothing")
    @MainActor
    func missingTargetIsNoOp() async throws {
        let (store, mock) = try await makeStore()
        let shortcut = HotkeyShortcut(keyCode: 20, keyLabel: "3", modifiers: [.option, .shift])

        let missingDevice = HotkeyBinding(
            target: .devicePower(deviceId: "light.deleted"),
            targetLabel: "已删除台灯",
            shortcut: shortcut
        )
        #expect(missingDevice.isTargetAvailable(devices: store.devices, scenes: store.scenes) == false)
        let devOutcome = await store.executeHotkeyBinding(missingDevice)
        #expect(devOutcome == .unavailable(label: "已删除台灯"))

        let missingScene = HotkeyBinding(
            target: .scene(sceneId: "scene.deleted"),
            targetLabel: "已删除场景",
            shortcut: shortcut
        )
        #expect(missingScene.isTargetAvailable(devices: store.devices, scenes: store.scenes) == false)
        let sceneOutcome = await store.executeHotkeyBinding(missingScene)
        #expect(sceneOutcome == .unavailable(label: "已删除场景"))

        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Scene hotkey executes through triggerScene")
    @MainActor
    func executeSceneHotkey() async throws {
        let (store, mock) = try await makeStore()
        let binding = HotkeyBinding(
            target: .scene(sceneId: Self.movieScene.id),
            targetLabel: Self.movieScene.name,
            shortcut: HotkeyShortcut(keyCode: 21, keyLabel: "4", modifiers: [.option, .shift])
        )
        let outcome = await store.executeHotkeyBinding(binding)
        if case .executed = outcome {
            // expected
        } else {
            Issue.record("Expected .executed, got \(outcome)")
        }
        let commands = await mock.executedCommands
        #expect(commands.contains(.activateScene(entityId: "scene.movie")))
    }

    @Test("Quick-action hotkey ignores unrelated pre-existing toast when building notification text")
    @MainActor
    func quickActionDoesNotReuseStaleToast() async throws {
        let onLight = SmartDevice(
            id: "light.living",
            name: "客厅主灯",
            roomId: "room.living",
            roomName: "客厅",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        let (store, _) = try await makeStore(devices: [onLight], scenes: [])
        store.showToast("之前的无关提示")

        let binding = HotkeyBinding(
            target: .quickAction(.lightsOff),
            targetLabel: QuickAction.lightsOff.title,
            shortcut: HotkeyShortcut(keyCode: 22, keyLabel: "6", modifiers: [.option, .shift])
        )
        let outcome = await store.executeHotkeyBinding(binding)
        #expect(outcome.notificationBody != "之前的无关提示")
    }
}
