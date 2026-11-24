import Carbon
import Foundation
import MijiaCore

/// Tracks transient panel interactions that live outside `HomeStore` — an active 0.6 s All-Off hold
/// and expanded ordinary-reminder / offline drawers — without `@Observable` invalidations on hidden
/// `ViewGraph` trees.
@MainActor
final class PanelTransientUIState {
    static let shared = PanelTransientUIState()

    private(set) var isAllOffHoldActive = false
    private var nextHoldSessionId: UInt64 = 0
    private var activeHoldSessionId: UInt64?
    private var cancelActiveHoldHandler: (() -> Void)?
    private var suppressTapUntilUptime: TimeInterval = 0

    private var deviceControlGesture: (id: UUID, cancel: () -> Void)?
    var isConfirmationGestureActive: Bool { isAllOffHoldActive || deviceControlGesture != nil }

    func beginDeviceControlGesture(onCancel: @escaping () -> Void) -> UUID {
        cancelDeviceControlGesture()
        let id = UUID()
        deviceControlGesture = (id, onCancel)
        return id
    }

    func endDeviceControlGesture(_ id: UUID?) {
        if deviceControlGesture?.id == id { deviceControlGesture = nil }
    }

    func cancelDeviceControlGesture() {
        let gesture = deviceControlGesture
        deviceControlGesture = nil
        gesture?.cancel()
    }

    var hasExpandedReminders = false
    var hasExpandedOfflineDrawer = false
    var collapseRemindersHandler: (() -> Void)?
    var collapseOfflineDrawerHandler: (() -> Void)?

    func beginAllOffHold(onCancel: @escaping () -> Void) -> UInt64 {
        nextHoldSessionId &+= 1
        let session = nextHoldSessionId
        activeHoldSessionId = session
        isAllOffHoldActive = true
        suppressTapUntilUptime = 0
        cancelActiveHoldHandler = onCancel
        return session
    }

    /// The pointer lifted. `onPressingChanged(false)` runs *before* a completed 0.6 s long press's
    /// `perform` closure, so a release only stops the key/tap semantics: it keeps the session
    /// consumable. Otherwise SwiftUI's own callback order would reject every successful hold.
    /// Only an explicit cancel (Esc, focus loss, panel hide) invalidates the session.
    func releaseAllOffHold(session: UInt64?) {
        guard let session, activeHoldSessionId == session else { return }
        isAllOffHoldActive = false
        cancelActiveHoldHandler = nil
    }

    /// Esc, key-focus loss, or the panel hiding: the hold is over, and a late `perform` must not fire.
    func cancelAllOffHold(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let handler = cancelActiveHoldHandler
        let wasActive = activeHoldSessionId != nil
        activeHoldSessionId = nil
        isAllOffHoldActive = false
        cancelActiveHoldHandler = nil
        if wasActive {
            // The cancelled press must not turn into the button's tap on mouse-up.
            suppressTapUntilUptime = now + 0.8
            handler?()
        }
    }

    func consumeConfirmedHold(session: UInt64?) -> Bool {
        guard let session, activeHoldSessionId == session else { return false }
        activeHoldSessionId = nil
        isAllOffHoldActive = false
        cancelActiveHoldHandler = nil
        return true
    }

    func shouldSuppressTap(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now < suppressTapUntilUptime else {
            suppressTapUntilUptime = 0
            return false
        }
        suppressTapUntilUptime = 0
        return true
    }

    func collapseReminders() {
        hasExpandedReminders = false
        collapseRemindersHandler?()
    }

    func collapseOfflineDrawer() {
        hasExpandedOfflineDrawer = false
        collapseOfflineDrawerHandler?()
    }

    /// Cleans up pending confirmations, in-flight All-Off holds, and temporary drawers/popovers when
    /// the panel hides or loses focus (`ui.md` §4 `全关` & `键盘`).
    func resetOnPanelHide(store: HomeStore?) {
        cancelAllOffHold()
        cancelDeviceControlGesture()
        if store?.pendingCloudConsent != nil {
            store?.declinePendingCloudRequest()
        }
        LayoutUIState.shared.dismissActivePrompt()
        PanelConnectionDetailState.shared.dismiss(restoreFocus: false)
        store?.expandedDeviceId = nil
        collapseReminders()
        collapseOfflineDrawer()
        hasExpandedReminders = false
        hasExpandedOfflineDrawer = false
        collapseRemindersHandler = nil
        collapseOfflineDrawerHandler = nil
    }

    func resetForTesting() {
        cancelDeviceControlGesture()
        activeHoldSessionId = nil
        isAllOffHoldActive = false
        cancelActiveHoldHandler = nil
        suppressTapUntilUptime = 0
        hasExpandedReminders = false
        hasExpandedOfflineDrawer = false
        collapseRemindersHandler = nil
        collapseOfflineDrawerHandler = nil
    }
}

enum PanelKeyRouter {
    struct Key: Equatable {
        var code: Int
        var command = false
        var shift = false
        var option = false
        var control = false
        var characters: String?
        var isRepeat = false
        /// The press matches the user's global shortcut chord.
        var matchesGlobalHotkey = false
    }

    struct Context: Equatable {
        var isPanelWindow = true
        var isShowingMiReauth = false
        var isAllOffHoldActive = false
        var hasPendingConfirmation = false
        var isShowingConnectionDetail = false
        var isConnectionStatusFocused = false
        var hasActivePrompt = false
        var globalHotkeyEnabled = false
        var isRecordingHotkey = false
        var isGlobalHotkeyRegistered = false
        var isHotkeyPhysicallyDown = false
        var isTextFieldFocused = false
        var isFormFieldFocused = false
        /// An IME has uncommitted marked text in the focused field: Esc cancels the composition, not the panel.
        var isComposingText = false
        var isShowingOnboarding = false
        var isShowingAssistantBar = false
        var editMode: PanelEditMode = .none
        var hasExpandedDevice = false
        var hasExpandedReminders = false
        var hasExpandedOfflineDrawer = false
        var hasFocusedDevice = false
        var voiceInputEnabled = true
    }

    enum Action: Equatable {
        /// Not the panel's key: let AppKit deliver it.
        case passThrough
        /// The panel swallows the key and does nothing.
        case consume
        case openSettings
        case dismissMiReauth
        case cancelAllOffHold
        case cancelPendingConfirmation
        case dismissConnectionDetail
        case focusConnectionStatus
        case clearConnectionStatusFocus
        case dismissPrompt
        /// A repeat of the global shortcut leaked into the panel; hide it only on a fresh press
        /// when the shortcut is not registered system-wide.
        case globalHotkeyEcho(hidePanel: Bool)
        /// Esc in a text field: leave the field, and close the assistant bar when it is open.
        case leaveTextField(dismissAssistant: Bool)
        case roomOrder(HotkeyAndNotificationManager.RoomOrderKeyAction)
        case endDeviceLayoutEditing
        case presentAssistant(voice: Bool)
        case toggleQuickDrawer
        case moveFocus(Int)
        case adjustFocusedDevice(Int)
        case toggleFocusedDevice
        case cycleRoom(Int)
        case dismissAssistantBar
        case collapseExpandedDevice
        case collapseExpandedReminders
        case collapseOfflineDrawer
        case clearFocus
        case hidePanel
        case selectQuickIndex(Int)
        /// A digit pressed while the footer status control holds focus: select the device and release the
        /// status control, otherwise the Return/Space that follows would still land on the status button.
        case selectQuickIndexClearingStatusFocus(Int)
    }

    /// Keys decided before search sees them. nil means search goes next.
    static func beforeSearch(_ key: Key, _ context: Context) -> Action? {
        if key.code == kVK_ANSI_Comma, key.command { return .openSettings }
        if key.code == kVK_ANSI_K,
           key.command, !key.shift, !key.option, !key.control,
           context.isPanelWindow,
           !context.isShowingOnboarding,
           !context.isShowingMiReauth,
           !context.hasActivePrompt,
           !context.isShowingConnectionDetail,
           !context.isFormFieldFocused,
           context.editMode == .none {
            return .toggleQuickDrawer
        }
        if let consumes = HotkeyAndNotificationManager.miReauthKeyDownResult(
            keyCode: key.code,
            isShowingMiReauth: context.isShowingMiReauth,
            isPanelWindow: context.isPanelWindow
        ) {
            return consumes ? .dismissMiReauth : .passThrough
        }
        if key.code == kVK_Escape, context.isPanelWindow {
            if context.isAllOffHoldActive { return .cancelAllOffHold }
            if context.hasPendingConfirmation { return .cancelPendingConfirmation }
        }
        if context.isPanelWindow, context.hasActivePrompt {
            // Esc belongs to the prompt; Return and ↑↓ go to the prompt's field, never to search or cards.
            if key.code == kVK_Escape { return .dismissPrompt }
            if key.code == kVK_Return || key.code == kVK_UpArrow || key.code == kVK_DownArrow { return .passThrough }
        }
        // The IME owns Esc while it has marked text, so a Chinese/Japanese composition can be abandoned
        // without a panel-level surface collapsing behind it.
        if key.code == kVK_Escape, context.isPanelWindow, !context.isFormFieldFocused, !context.isComposingText {
            if context.isShowingConnectionDetail { return .dismissConnectionDetail }
            if !context.isTextFieldFocused, context.isShowingAssistantBar { return .dismissAssistantBar }
            if context.editMode == .none, !context.isShowingAssistantBar {
                if context.hasExpandedDevice { return .collapseExpandedDevice }
                if context.hasExpandedReminders { return .collapseExpandedReminders }
                if context.hasExpandedOfflineDrawer { return .collapseOfflineDrawer }
            }
            if context.isConnectionStatusFocused { return .clearConnectionStatusFocus }
        }
        if context.isShowingConnectionDetail, context.isPanelWindow {
            // The detail keeps its own form keys (the reader is a text field, not the panel's search), but
            // Esc still leaves the field first instead of also tearing down the assistant bar behind it.
            // A live IME composition keeps its own Esc, as in tier 2 above.
            if key.code == kVK_Escape, context.isFormFieldFocused, !context.isComposingText {
                return .leaveTextField(dismissAssistant: false)
            }
            return .passThrough
        }
        if context.isConnectionStatusFocused, context.isPanelWindow {
            switch key.code {
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
                return .passThrough
            default:
                break
            }
        }
        return nil
    }

    /// Keys search did not take.
    static func afterSearch(_ key: Key, _ context: Context) -> Action {
        if context.isPanelWindow, context.hasActivePrompt {
            if key.code == kVK_Escape { return .dismissPrompt }
            if key.code == kVK_Return || key.code == kVK_UpArrow || key.code == kVK_DownArrow { return .passThrough }
        }

        if context.globalHotkeyEnabled, !context.isRecordingHotkey, key.matchesGlobalHotkey {
            let hide = !context.isGlobalHotkeyRegistered && !key.isRepeat && !context.isHotkeyPhysicallyDown
            return .globalHotkeyEcho(hidePanel: hide)
        }

        if context.isTextFieldFocused || context.isFormFieldFocused {
            return key.code == kVK_Escape ? .leaveTextField(dismissAssistant: context.isShowingAssistantBar) : .passThrough
        }

        // Device shortcuts belong to the menu-bar panel; Settings keeps normal AppKit behaviour (#42).
        guard context.isPanelWindow else { return .passThrough }

        if context.isShowingOnboarding {
            return key.code == kVK_Escape ? .hidePanel : .passThrough
        }

        if context.editMode == .roomOrder,
           let action = HotkeyAndNotificationManager.roomOrderKeyAction(
               keyCode: UInt16(key.code),
               hasCommand: key.command,
               hasShift: key.shift,
               charactersIgnoringModifiers: key.characters
           ) {
            return .roomOrder(action)
        }

        if context.editMode == .deviceLayout {
            switch key.code {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                // Return triggers the Done button's default action in device-layout mode.
                return .passThrough
            case kVK_Escape:
                return .endDeviceLayoutEditing
            case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Space, kVK_Tab:
                return .consume
            default:
                if let chars = key.characters, chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
                    return .consume
                }
            }
        }

        if context.isConnectionStatusFocused {
            switch key.code {
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
                return .passThrough
            case kVK_Escape:
                return .clearConnectionStatusFocus
            case kVK_Tab:
                return .cycleRoom(key.shift ? -1 : 1)
            default:
                break
            }
        }

        let plain = !key.command && !key.option && !key.control
        if plain, key.characters == "/" { return .presentAssistant(voice: false) }
        if plain, context.voiceInputEnabled, key.characters?.lowercased() == "v" { return .presentAssistant(voice: true) }

        switch key.code {
        case kVK_UpArrow: return .moveFocus(-1)
        case kVK_DownArrow: return .moveFocus(1)
        case kVK_LeftArrow: return .adjustFocusedDevice(-1)
        case kVK_RightArrow: return .adjustFocusedDevice(1)
        case kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter: return .toggleFocusedDevice
        case kVK_Tab:
            if context.hasFocusedDevice { return .focusConnectionStatus }
            return .cycleRoom(key.shift ? -1 : 1)
        case kVK_Escape:
            if context.isAllOffHoldActive { return .cancelAllOffHold }
            if context.hasPendingConfirmation { return .cancelPendingConfirmation }
            if context.isShowingConnectionDetail { return .dismissConnectionDetail }
            if context.isShowingAssistantBar { return .dismissAssistantBar }
            if context.hasExpandedDevice { return .collapseExpandedDevice }
            if context.hasExpandedReminders { return .collapseExpandedReminders }
            if context.hasExpandedOfflineDrawer { return .collapseOfflineDrawer }
            if context.hasFocusedDevice { return .clearFocus }
            return .hidePanel
        default:
            break
        }

        if let chars = key.characters, chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
            return context.isConnectionStatusFocused ? .selectQuickIndexClearingStatusFocus(digit) : .selectQuickIndex(digit)
        }
        return .passThrough
    }
}
