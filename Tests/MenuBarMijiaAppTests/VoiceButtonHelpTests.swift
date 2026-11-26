import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

@Suite(.serialized)
struct VoiceButtonHelpTests {
    @Test("Listening state shows stop-and-run prompt regardless of hotkey state")
    func listeningPrompt() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: true,
                globalHotkeyEnabled: false,
                isGlobalHotkeyRegistered: false,
                shortcutDisplay: "⌥M"
            )
            #expect(text == "停止聆听并执行")
        }
        L10n.$overrideLanguage.withValue(.en) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: true,
                globalHotkeyEnabled: true,
                isGlobalHotkeyRegistered: true,
                shortcutDisplay: "⌥M"
            )
            #expect(text == "Stop listening and run")
        }
    }

    @Test("Registered global hotkey includes hold-shortcut hint")
    func registeredHotkeyIncluded() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: true,
                isGlobalHotkeyRegistered: true,
                shortcutDisplay: "⌃⇧V"
            )
            #expect(text == "语音输入（快捷键 V，或长按 ⌃⇧V / 菜单栏图标）")
        }
        L10n.$overrideLanguage.withValue(.en) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: true,
                isGlobalHotkeyRegistered: true,
                shortcutDisplay: "⌃⇧V"
            )
            #expect(text == "Voice input (Shortcut V, or hold ⌃⇧V / menu bar icon)")
        }
    }

    @Test("Disabled global hotkey omits shortcut hint across zh-Hans, zh-Hant, and en")
    func disabledHotkeyOmitted() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: false,
                isGlobalHotkeyRegistered: true,
                shortcutDisplay: "⌥M"
            )
            #expect(text == "语音输入（快捷键 V，或长按菜单栏图标）")
            #expect(!text.contains("⌥M"))
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: false,
                isGlobalHotkeyRegistered: false,
                shortcutDisplay: "⌥M"
            )
            #expect(text == "語音輸入（快捷鍵 V，或長按選單欄圖示）")
            #expect(!text.contains("⌥M"))
        }
        L10n.$overrideLanguage.withValue(.en) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: false,
                isGlobalHotkeyRegistered: false,
                shortcutDisplay: "⌥M"
            )
            #expect(text == "Voice input (Shortcut V, or hold menu bar icon)")
            #expect(!text.contains("⌥M"))
        }
    }

    @Test("Failed global hotkey registration omits shortcut hint even when enabled")
    func failedRegistrationOmitted() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: true,
                isGlobalHotkeyRegistered: false,
                shortcutDisplay: "⌥M"
            )
            #expect(text == "语音输入（快捷键 V，或长按菜单栏图标）")
            #expect(!text.contains("⌥M"))
        }
        L10n.$overrideLanguage.withValue(.en) {
            let text = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: true,
                isGlobalHotkeyRegistered: false,
                shortcutDisplay: "⌥M"
            )
            #expect(text == "Voice input (Shortcut V, or hold menu bar icon)")
            #expect(!text.contains("⌥M"))
        }
    }

    @Test("HotkeySettingsState registration transitions drive the voice button hint")
    @MainActor
    func hotkeySettingsStateTransitions() {
        let state = HotkeySettingsState.shared
        let originalShortcut = state.shortcut
        let originalRegistered = state.isRegistered
        let originalError = state.registrationError
        defer {
            if originalRegistered {
                state.markRegistered(originalShortcut)
            } else if originalError != nil {
                state.markFailed(originalShortcut, status: -9878)
            } else {
                state.markDisabled()
            }
        }

        let custom = HotkeyShortcut(keyCode: 9, keyLabel: "V", modifiers: [.control, .shift])

        L10n.$overrideLanguage.withValue(.zhHans) {
            state.markRegistered(custom)
            let registeredHint = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: true,
                isGlobalHotkeyRegistered: state.isRegistered,
                shortcutDisplay: state.shortcut.displayString
            )
            #expect(registeredHint.contains(custom.displayString))

            state.markFailed(custom, status: -9878)
            let failedHint = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: true,
                isGlobalHotkeyRegistered: state.isRegistered,
                shortcutDisplay: state.shortcut.displayString
            )
            #expect(!failedHint.contains(custom.displayString))
            #expect(failedHint == "语音输入（快捷键 V，或长按菜单栏图标）")

            state.markDisabled()
            let disabledHint = ControlCenterPanel.voiceButtonHelp(
                listening: false,
                globalHotkeyEnabled: false,
                isGlobalHotkeyRegistered: state.isRegistered,
                shortcutDisplay: state.shortcut.displayString
            )
            #expect(!disabledHint.contains(custom.displayString))
            #expect(disabledHint == "语音输入（快捷键 V，或长按菜单栏图标）")
        }
    }
}
