import Carbon
import Foundation
import Testing
@testable import MenuBarMijiaApp

/// The panel's key priority, asserted as a table without AppKit events or singletons.
struct PanelKeyRouterTests {
    typealias Key = PanelKeyRouter.Key
    typealias Context = PanelKeyRouter.Context

    private func route(_ key: Key, _ context: Context = Context()) -> PanelKeyRouter.Action {
        PanelKeyRouter.beforeSearch(key, context) ?? PanelKeyRouter.afterSearch(key, context)
    }

    @Test("⌘, opens Settings from anywhere")
    func commandComma() {
        #expect(route(Key(code: kVK_ANSI_Comma, command: true), Context(isTextFieldFocused: true)) == .openSettings)
    }

    @Test("The re-auth modal owns the keyboard: Esc dismisses, everything else passes through")
    func reauthModal() {
        let modal = Context(isShowingMiReauth: true, isShowingConnectionDetail: true)
        #expect(route(Key(code: kVK_Escape), modal) == .dismissMiReauth)
        #expect(route(Key(code: kVK_Space), modal) == .passThrough)
    }

    @Test("An open prompt takes Esc and lets Return and arrows reach its field")
    func prompt() {
        let prompt = Context(hasActivePrompt: true, isTextFieldFocused: true)
        #expect(route(Key(code: kVK_Escape), prompt) == .dismissPrompt)
        #expect(route(Key(code: kVK_Return), prompt) == .passThrough)
        #expect(route(Key(code: kVK_DownArrow), Context(hasActivePrompt: true)) == .passThrough)
    }

    @Test("A global-shortcut echo is swallowed and hides the panel only on a fresh, unregistered press")
    func globalHotkeyEcho() {
        let enabled = Context(globalHotkeyEnabled: true)
        #expect(route(Key(code: kVK_ANSI_M, option: true, matchesGlobalHotkey: true), enabled) == .globalHotkeyEcho(hidePanel: true))
        #expect(route(Key(code: kVK_ANSI_M, option: true, isRepeat: true, matchesGlobalHotkey: true), enabled) == .globalHotkeyEcho(hidePanel: false))
        var registered = enabled
        registered.isGlobalHotkeyRegistered = true
        #expect(route(Key(code: kVK_ANSI_M, option: true, matchesGlobalHotkey: true), registered) == .globalHotkeyEcho(hidePanel: false))
        var recording = enabled
        recording.isRecordingHotkey = true
        #expect(route(Key(code: kVK_ANSI_M, option: true, characters: "m", matchesGlobalHotkey: true), recording) == .passThrough)
    }

    @Test("A focused text field keeps typing; Esc leaves it and closes the assistant bar")
    func textField() {
        #expect(route(Key(code: kVK_Space, characters: " "), Context(isTextFieldFocused: true)) == .passThrough)
        #expect(route(Key(code: kVK_Escape), Context(isTextFieldFocused: true, isShowingAssistantBar: true)) == .leaveTextField(dismissAssistant: true))
    }

    @Test("Outside the panel window device shortcuts never fire")
    func otherWindow() {
        #expect(route(Key(code: kVK_Space), Context(isPanelWindow: false)) == .passThrough)
    }

    @Test("Room order swallows Return, Space and digits but lets / open the assistant")
    func roomOrder() {
        let ordering = Context(editMode: .roomOrder)
        #expect(route(Key(code: kVK_Return), ordering) == .roomOrder(.commit))
        #expect(route(Key(code: kVK_Space, characters: " "), ordering) == .roomOrder(.consume))
        #expect(route(Key(code: kVK_ANSI_3, characters: "3"), ordering) == .roomOrder(.consume))
        #expect(route(Key(code: kVK_ANSI_Slash, characters: "/"), ordering) == .presentAssistant(voice: false))
    }

    @Test("Device-layout mode leaves Return to the Done button, Esc exits editing, and device shortcuts are swallowed")
    func deviceLayoutReturn() {
        let layout = Context(editMode: .deviceLayout, hasFocusedDevice: true)
        #expect(route(Key(code: kVK_Return), layout) == .passThrough)
        #expect(route(Key(code: kVK_ANSI_KeypadEnter), layout) == .passThrough)
        #expect(route(Key(code: kVK_Escape), layout) == .endDeviceLayoutEditing)
        #expect(route(Key(code: kVK_Space, characters: " "), layout) == .consume)
        #expect(route(Key(code: kVK_UpArrow), layout) == .consume)
        #expect(route(Key(code: kVK_DownArrow), layout) == .consume)
        #expect(route(Key(code: kVK_LeftArrow), layout) == .consume)
        #expect(route(Key(code: kVK_RightArrow), layout) == .consume)
        #expect(route(Key(code: kVK_Tab), layout) == .consume)
        #expect(route(Key(code: kVK_ANSI_1, characters: "1"), layout) == .consume)
        #expect(route(Key(code: kVK_ANSI_9, characters: "9"), layout) == .consume)
        #expect(route(Key(code: kVK_ANSI_Slash, characters: "/"), layout) == .presentAssistant(voice: false))
    }

    @Test("Plain / and v open the assistant; with ⌘ they do not; disabling voice input gates v while keeping / and device shortcuts")
    func assistantKeys() {
        #expect(route(Key(code: kVK_ANSI_V, characters: "v")) == .presentAssistant(voice: true))
        #expect(route(Key(code: kVK_ANSI_V, command: true, characters: "v")) == .passThrough)

        let voiceDisabled = Context(voiceInputEnabled: false)
        #expect(route(Key(code: kVK_ANSI_V, characters: "v"), voiceDisabled) == .passThrough)
        #expect(route(Key(code: kVK_ANSI_V, characters: "V"), voiceDisabled) == .passThrough)
        #expect(route(Key(code: kVK_ANSI_Slash, characters: "/"), voiceDisabled) == .presentAssistant(voice: false))
        #expect(route(Key(code: kVK_Space, characters: " "), voiceDisabled) == .toggleFocusedDevice)
        #expect(route(Key(code: kVK_DownArrow), voiceDisabled) == .moveFocus(1))
    }

    @Test("Device shortcuts: arrows, Space, Tab and digits")
    func deviceShortcuts() {
        #expect(route(Key(code: kVK_UpArrow)) == .moveFocus(-1))
        #expect(route(Key(code: kVK_RightArrow)) == .adjustFocusedDevice(1))
        #expect(route(Key(code: kVK_Space, characters: " ")) == .toggleFocusedDevice)
        #expect(route(Key(code: kVK_Tab, shift: true)) == .cycleRoom(-1))
        #expect(route(Key(code: kVK_ANSI_4, characters: "4")) == .selectQuickIndex(4))
        #expect(route(Key(code: kVK_ANSI_0, characters: "0")) == .passThrough)
    }

    @Test("Esc walks the ladder: assistant bar, drawer, focus, then hide")
    func escapeLadder() {
        #expect(route(Key(code: kVK_Escape), Context(isShowingAssistantBar: true, hasExpandedDevice: true)) == .dismissAssistantBar)
        #expect(route(Key(code: kVK_Escape), Context(hasExpandedDevice: true, hasFocusedDevice: true)) == .collapseExpandedDevice)
        #expect(route(Key(code: kVK_Escape), Context(hasFocusedDevice: true)) == .clearFocus)
        #expect(route(Key(code: kVK_Escape)) == .hidePanel)
    }

    @Test("Connection status and detail popover: Tab reaches status from device focus, Return/Space pass through, Esc dismisses detail")
    func connectionStatusAndDetailPopover() {
        #expect(route(Key(code: kVK_Tab), Context(hasFocusedDevice: true)) == .focusConnectionStatus)

        let statusFocused = Context(isConnectionStatusFocused: true)
        #expect(route(Key(code: kVK_Return), statusFocused) == .passThrough)
        #expect(route(Key(code: kVK_Space, characters: " "), statusFocused) == .passThrough)
        #expect(route(Key(code: kVK_Escape), statusFocused) == .clearConnectionStatusFocus)
        #expect(route(Key(code: kVK_Tab), statusFocused) == .cycleRoom(1))

        let detailOpen = Context(isShowingConnectionDetail: true, hasExpandedDevice: true, hasFocusedDevice: true)
        #expect(route(Key(code: kVK_Escape), detailOpen) == .dismissConnectionDetail)
        #expect(route(Key(code: kVK_Return), detailOpen) == .passThrough)
        #expect(route(Key(code: kVK_Space, characters: " "), detailOpen) == .passThrough)
        #expect(route(Key(code: kVK_Tab), detailOpen) == .passThrough)
    }

    @Test("WP2d Escape priority: confirmation/hold -> expanded surfaces -> search/focus/hide, without hijacking form fields")
    func escapePriorityTiersAndFormGuards() {
        let esc = Key(code: kVK_Escape)

        // Tier 1: active confirmation or 0.6s All-Off hold beats expanded drawers and search.
        let holdAndDrawer = Context(
            isAllOffHoldActive: true,
            hasPendingConfirmation: true,
            hasExpandedDevice: true,
            hasExpandedReminders: true,
            hasExpandedOfflineDrawer: true,
            hasFocusedDevice: true
        )
        #expect(route(esc, holdAndDrawer) == .cancelAllOffHold)

        var confirmAndDrawer = holdAndDrawer
        confirmAndDrawer.isAllOffHoldActive = false
        #expect(route(esc, confirmAndDrawer) == .cancelPendingConfirmation)

        // Tier 2: expanded device drawer -> expanded reminders -> expanded offline drawer -> focus/hide.
        var expandedSurfaces = confirmAndDrawer
        expandedSurfaces.hasPendingConfirmation = false
        #expect(route(esc, expandedSurfaces) == .collapseExpandedDevice)

        expandedSurfaces.hasExpandedDevice = false
        #expect(route(esc, expandedSurfaces) == .collapseExpandedReminders)

        expandedSurfaces.hasExpandedReminders = false
        #expect(route(esc, expandedSurfaces) == .collapseOfflineDrawer)

        expandedSurfaces.hasExpandedOfflineDrawer = false
        #expect(route(esc, expandedSurfaces) == .clearFocus)

        // Form fields and onboarding keep typing/digits/arrows instead of being hijacked by panel shortcuts.
        let formFocused = Context(isFormFieldFocused: true, hasFocusedDevice: true)
        #expect(route(Key(code: kVK_ANSI_2, characters: "2"), formFocused) == .passThrough)
        #expect(route(Key(code: kVK_DownArrow), formFocused) == .passThrough)
        #expect(route(Key(code: kVK_ANSI_Slash, characters: "/"), formFocused) == .passThrough)
        #expect(route(esc, formFocused) == .leaveTextField(dismissAssistant: false))

        let onboarding = Context(isShowingOnboarding: true, hasFocusedDevice: true)
        #expect(route(Key(code: kVK_ANSI_1, characters: "1"), onboarding) == .passThrough)
        #expect(route(Key(code: kVK_Space, characters: " "), onboarding) == .passThrough)
        #expect(route(esc, onboarding) == .hidePanel)
    }

    @Test("An IME composition keeps Esc: tier-2 surfaces wait for the marked text to commit")
    func imeCompositionKeepsEscape() {
        let esc = Key(code: kVK_Escape)
        let composing = Context(
            isTextFieldFocused: true,
            isComposingText: true,
            hasExpandedDevice: true
        )
        #expect(PanelKeyRouter.beforeSearch(esc, composing) == nil)
        #expect(route(esc, composing) == .leaveTextField(dismissAssistant: false))

        var committed = composing
        committed.isComposingText = false
        #expect(route(esc, committed) == .collapseExpandedDevice)
    }

    @Test("An active prompt only owns keys inside the panel window")
    func promptScopeIsThePanelWindow() {
        let esc = Key(code: kVK_Escape)
        #expect(route(esc, Context(isPanelWindow: false, hasActivePrompt: true)) == .passThrough)
        #expect(route(Key(code: kVK_Return), Context(isPanelWindow: false, hasActivePrompt: true)) == .passThrough)
        #expect(route(esc, Context(isPanelWindow: true, hasActivePrompt: true)) == .dismissPrompt)
    }

    @Test("Esc in a connection-detail form leaves the field without closing the assistant bar behind it")
    func connectionDetailFormEscape() {
        let detailForm = Context(isShowingConnectionDetail: true, isTextFieldFocused: true, isFormFieldFocused: true, isShowingAssistantBar: true)
        #expect(route(Key(code: kVK_Escape), detailForm) == .leaveTextField(dismissAssistant: false))
        // Other keys still belong to the detail's own form controls.
        #expect(route(Key(code: kVK_Tab), detailForm) == .passThrough)
        // A connection-detail field that is mid-composition keeps Esc for the IME.
        var composingDetail = detailForm
        composingDetail.isComposingText = true
        #expect(route(Key(code: kVK_Escape), composingDetail) == .passThrough)
        // With no field focused, Esc closes the detail itself.
        var unfocused = detailForm
        unfocused.isTextFieldFocused = false
        unfocused.isFormFieldFocused = false
        #expect(route(Key(code: kVK_Escape), unfocused) == .dismissConnectionDetail)
    }
}

