import AppKit
import Carbon
import CoreGraphics
import Foundation
import Observation
import Security
import UserNotifications
import MijiaCore

@MainActor
public final class HotkeyAndNotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    public static let shared = HotkeyAndNotificationManager()

    /// Holding the global shortcut (`⌥M` by default) for 0.5 s starts hold-to-talk voice input,
    /// matching the menu-bar icon long-press threshold (`MenuBarPanelController.holdThreshold`).
    public static let hotkeyHoldThreshold: TimeInterval = 0.5

    private weak var store: HomeStore?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyHoldTask: Task<Void, Never>?
    private var hotkeyPressedAt: Date?
    public private(set) var isHotkeyPhysicallyDown = false
    public private(set) var isHotkeyHoldTriggered = false
    private var localKeyMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var localFlagsMonitor: Any?
    private var windowBecomeKeyObserver: NSObjectProtocol?
    private var applicationBecomeActiveObserver: NSObjectProtocol?
    private var safetyWakeObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var safetyWakeTask: Task<Void, Never>?
    private var automaticUpdateTask: Task<Void, Never>?
    private var automaticUpdateRetryAt: Date?
    /// The alert and the connection scope it was delivered in. Home Assistant entity ids repeat across
    /// servers (`light.heater`), so the device id alone does not identify the home the alert was about.
    private struct PendingAlert {
        let alert: SafetyAlert
        let scope: String?
    }
    private var pendingAlertsById: [String: PendingAlert] = [:]
    /// Insertion order of `pendingAlertsById`, so the oldest alert can be dropped at the cap.
    private var pendingAlertOrder: [String] = []
    /// Alerts whose notification the system never reports back (permission removed, banners off) would
    /// otherwise accumulate for the whole run; only the recent ones can still be acted on.
    private static let pendingAlertLimit = 32

    private static let turnOffActionId = "TURN_OFF_ACTION"
    private static let safetyCategoryId = "MIJIA_SAFETY_ALERT"
    private static let runMissedTimerActionId = "RUN_MISSED_TIMER_ACTION"
    private static let missedTimerCategoryId = "MIJIA_MISSED_TIMER"
    /// Ties a banner back to the camera card it was about, so a tap can open that camera (#10).
    static let doorbellDeviceIdKey = "doorbell_device_id"

    private override init() {
        super.init()
        applicationBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshNotificationPermission()
            }
        }
    }

    func attachStoreForTesting(_ store: HomeStore?) {
        cancelHotkeyHold()
        self.store = store
        store?.onVoiceInputPreferenceChanged = { [weak self] enabled in
            self?.handleVoiceInputPreferenceChanged(enabled: enabled)
        }
    }

    public func start(with store: HomeStore) {
        self.store = store
        store.onTerminateForUpdate = {
            NSApplication.shared.terminate(nil)
        }
        store.onGlobalHotkeyPreferenceChanged = { [weak self] enabled in
            self?.syncGlobalHotKeyRegistration(enabled: enabled)
        }
        store.onVoiceInputPreferenceChanged = { [weak self] enabled in
            self?.handleVoiceInputPreferenceChanged(enabled: enabled)
        }
        syncGlobalHotKeyRegistration(enabled: store.enableGlobalHotkey)
        MenuBarPanelController.shared.install(with: store)
        setupLocalKeyboardMonitors()
        setupNotificationsIfBundled()
        observeSafetyWakeEvents()
        observeSafetyWakeInputs(store)
        // The status item exists as soon as `install` returns, but the first launch has no window to
        // host yet; give SwiftUI one run-loop turn before an onboarding panel is requested.
        Task { @MainActor [weak self] in
            self?.runSafetyWake()
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, let store = self.store, store.shouldShowOnboarding else { return }
            self.ensureMenuBarExtraWindowVisible()
        }
    }

    private func handleVoiceInputPreferenceChanged(enabled: Bool) {
        guard !enabled else { return }
        cancelHotkeyHoldOnVoiceDisable()
        MenuBarPanelController.shared.cancelHoldToTalkOnDisable()
        SpeechInputController.shared.handleVoiceInputPreferenceChanged(enabled: false, store: store)
    }

    // MARK: - 1. Global Hotkey (user-recorded, ⌥M by default) via Carbon RegisterEventHotKey

    private func syncGlobalHotKeyRegistration(enabled: Bool) {
        if enabled {
            applyHotkeyPreference()
        } else {
            unregisterGlobalHotKey()
            HotkeySettingsState.shared.markDisabled()
        }
    }

    /// Re-registers with the stored shortcut. Called when the toggle flips (#43 rule 3) and after
    /// the recorder saves a new combination.
    public func applyHotkeyPreference() {
        guard let store, store.enableGlobalHotkey else {
            unregisterGlobalHotKey()
            HotkeySettingsState.shared.markDisabled()
            return
        }
        let shortcut = HotkeyPreferences.load()
        HotkeySettingsState.shared.reload()
        registerGlobalHotKey(shortcut)
    }

    /// Retry button next to the registration error.
    public func retryHotkeyRegistration() {
        applyHotkeyPreference()
    }

    private func unregisterGlobalHotKey() {
        cancelHotkeyHold()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func registerGlobalHotKey(_ shortcut: HotkeyShortcut) {
        unregisterGlobalHotKey()
        guard installHotKeyHandler() else {
            reportHotkeyFailure(shortcut, status: OSStatus(-1))
            return
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D49_4A41), id: 1) // 'MIJA'
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRef = ref
            HotkeySettingsState.shared.markRegistered(shortcut)
        } else {
            reportHotkeyFailure(shortcut, status: status)
        }
    }

    /// Never let a shortcut fail silently (#43): Settings shows the error and, when the panel is
    /// visible, a toast says why the hotkey does nothing.
    private func reportHotkeyFailure(_ shortcut: HotkeyShortcut, status: OSStatus) {
        HotkeySettingsState.shared.markFailed(shortcut, status: status)
        if let message = HotkeySettingsState.shared.registrationError {
            store?.showToast(message, isError: true)
        }
    }

    private func installHotKeyHandler() -> Bool {
        if eventHandlerRef != nil { return true }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                let kind = GetEventKind(event)
                if kind == UInt32(kEventHotKeyPressed) {
                    Task { @MainActor in
                        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed()
                    }
                } else if kind == UInt32(kEventHotKeyReleased) {
                    Task { @MainActor in
                        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandlerRef
        )
        return status == noErr
    }

    private static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Short press (< `hotkeyHoldThreshold`) toggles the panel on release; holding for at least
    /// `hotkeyHoldThreshold` opens the panel and starts Push-to-Talk voice recognition, matching
    /// the menu-bar icon press/hold gesture.
    func handleGlobalHotKeyPressed(holdThreshold: TimeInterval = HotkeyAndNotificationManager.hotkeyHoldThreshold) {
        guard let store, store.enableGlobalHotkey else { return }
        if isHotkeyPhysicallyDown {
            // Carbon can miss `kEventHotKeyReleased` across sleep, secure-input transitions, or
            // screen lock; recover if a prior press was left latched without active hold-to-talk.
            let elapsed = hotkeyPressedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            guard elapsed > 2.0, !SpeechInputController.shared.isHoldToTalk else { return }
            cancelHotkeyHold()
        }
        isHotkeyPhysicallyDown = true
        hotkeyPressedAt = Date()
        isHotkeyHoldTriggered = false
        hotkeyHoldTask?.cancel()
        if store.enableVoiceInput {
            hotkeyHoldTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(holdThreshold))
                guard !Task.isCancelled,
                      let self,
                      let store = self.store,
                      store.enableVoiceInput,
                      self.isHotkeyPhysicallyDown,
                      !self.isHotkeyHoldTriggered else { return }
                self.isHotkeyHoldTriggered = true
                MenuBarPanelController.shared.beginHoldToTalk()
            }
        } else {
            hotkeyHoldTask = nil
        }
    }

    func handleGlobalHotKeyReleased() {
        guard isHotkeyPhysicallyDown else { return }
        isHotkeyPhysicallyDown = false
        hotkeyPressedAt = nil
        hotkeyHoldTask?.cancel()
        hotkeyHoldTask = nil

        if isHotkeyHoldTriggered {
            isHotkeyHoldTriggered = false
            MenuBarPanelController.shared.endHoldToTalk()
        } else {
            guard let store, store.enableGlobalHotkey else { return }
            toggleMenuBarExtraWindow()
        }
    }

    private func cancelHotkeyHold() {
        hotkeyHoldTask?.cancel()
        hotkeyHoldTask = nil
        hotkeyPressedAt = nil
        let wasHoldTriggered = isHotkeyHoldTriggered
        isHotkeyPhysicallyDown = false
        isHotkeyHoldTriggered = false
        if wasHoldTriggered {
            MenuBarPanelController.shared.endHoldToTalk()
        }
    }

    private func cancelHotkeyHoldOnVoiceDisable() {
        hotkeyHoldTask?.cancel()
        hotkeyHoldTask = nil
        hotkeyPressedAt = nil
        isHotkeyPhysicallyDown = false
        isHotkeyHoldTriggered = false
    }

    /// Opens the control center, or closes it when it is already on screen.
    ///
    /// The name predates #56: the panel is an app-owned `NSPanel` now, not a `MenuBarExtra` window.
    /// Other app files (Settings, URL scheme, App Intents) call it, so the seam is kept.
    public func toggleMenuBarExtraWindow() {
        MenuBarPanelController.shared.togglePanel()
    }

    /// Brings the control center on screen without toggling, e.g. to show an onboarding guide or an
    /// undo banner. Same legacy name as `toggleMenuBarExtraWindow()`.
    public func ensureMenuBarExtraWindowVisible() {
        MenuBarPanelController.shared.showPanel()
    }

    // MARK: - 2. Local Keyboard Monitors

    /// ⌥-state tracking and panel shortcuts. Mouse handling for the status item lives in
    /// `MenuBarPanelController`, which owns the item (#56).
    private func setupLocalKeyboardMonitors() {
        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                self.store?.isOptionKeyPressed = event.modifierFlags.contains(.option)
                // Releasing the modifier key (e.g. ⌥) before the main key (M) while the panel is
                // active ends a hotkey hold just like releasing the main key does.
                if self.isHotkeyPhysicallyDown {
                    let shortcut = HotkeyPreferences.load()
                    let currentMods = HotkeyRecorderController.modifiers(from: event.modifierFlags)
                    if !currentMods.isSuperset(of: shortcut.modifiers) {
                        self.handleGlobalHotKeyReleased()
                    }
                }
                return event
            }
        }

        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let store = self.store else { return event }
                if self.handleKeyDown(event, store: store) {
                    return nil
                }
                return event
            }
        }

        if localKeyUpMonitor == nil {
            localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard let self, self.isHotkeyPhysicallyDown else { return event }
                let shortcut = HotkeyPreferences.load()
                if Int(event.keyCode) == Int(shortcut.keyCode) {
                    self.handleGlobalHotKeyReleased()
                }
                return event
            }
        }

        // Opening any window of our own (Settings, the panel) is a chance to run the daily update
        // check. Menu-bar gestures are handled by the status item controller.
        if windowBecomeKeyObserver == nil {
            windowBecomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        await self?.store?.checkForUpdatesIfNeeded()
                    }
                }
            }
        }
    }

    // MARK: - 3. Local Keyboard Shortcuts

    nonisolated static func miReauthKeyDownResult(
        keyCode: Int, isShowingMiReauth: Bool, isPanelWindow: Bool
    ) -> Bool? {
        guard isShowingMiReauth, isPanelWindow else { return nil }
        return keyCode == kVK_Escape
    }

    /// #146 §5.5：排序模式下每个按键的归属。判定与执行分开，`handleKeyDown` 只把结果映射到
    /// `RoomOrderKeyboard` / `LayoutUIState`，这张表本身可以逐键断言，不依赖真实事件。
    enum RoomOrderKeyAction: Equatable {
        /// ↑ ↓ / Tab ⇧Tab：只移动列表焦点，不碰设备。
        case moveFocus(Int)
        /// ⌘↑ ⌘↓：焦点行上下移动一位。
        case moveRow(Int)
        /// ⌘Home ⌘End：移到最前 / 最后（`true` = 最前）。
        case moveRowToEdge(Bool)
        /// Return / 小键盘 Enter：提交并退出。
        case commit
        /// Esc：回滚并退出。
        case cancel
        /// Space / ← → / 1…9：只吞掉，绝不落到设备操作。
        case consume
    }

    /// 返回 `nil` 表示这个键不归排序会话，调用方继续走面板旧逻辑。`/` 与 `v` 故意不在这里：
    /// 助手栏是叠在列表上的输入条，不会改动房间顺序，所以保持原来的打开行为。
    nonisolated static func roomOrderKeyAction(
        keyCode: UInt16,
        hasCommand: Bool,
        hasShift: Bool,
        charactersIgnoringModifiers: String?
    ) -> RoomOrderKeyAction? {
        switch Int(keyCode) {
        case kVK_UpArrow:
            return hasCommand ? .moveRow(-1) : .moveFocus(-1)
        case kVK_DownArrow:
            return hasCommand ? .moveRow(1) : .moveFocus(1)
        case kVK_Home, kVK_End:
            // 未按 ⌘ 的 Home/End 不是这个会话的键，维持原来的落空行为。
            guard hasCommand else { return nil }
            return .moveRowToEdge(Int(keyCode) == kVK_Home)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .commit
        case kVK_Escape:
            return .cancel
        case kVK_Tab:
            return .moveFocus(hasShift ? -1 : 1)
        case kVK_Space:
            // 空格原来会落到 `toggleFocusedDevice()`；排序列表下它必须什么都不做。
            return .consume
        case kVK_LeftArrow, kVK_RightArrow:
            // 左右键一律吞掉：主 switch 的 `adjustFocusedDevice` 不检查修饰键，⌘← 同样会改到残留的
            // `focusedDeviceId` 上（那是改设备属性/亮度的路径，不只是移动焦点）；排序列表里没有
            // 「选中设备」的视觉表达，左右键在这个模式下没有合理语义。
            return .consume
        default:
            // 1…9 原来会 `selectQuickIndex()` 直接开关设备。⌘ 也吞：与 `adjustFocusedDevice` 同类问题，
            // 主 switch 的数字段不检查修饰键；排序列表里 1…9 没有合法语义。
            guard let chars = charactersIgnoringModifiers, chars.count == 1,
                  let digit = Int(chars), (1...9).contains(digit)
            else { return nil }
            return .consume
        }
    }

    /// Snapshots the panel state, asks `PanelKeyRouter` who owns the key, and performs it.
    private func handleKeyDown(_ event: NSEvent, store: HomeStore) -> Bool {
        let flags = event.modifierFlags
        let key = PanelKeyRouter.Key(
            code: Int(event.keyCode),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            characters: event.charactersIgnoringModifiers,
            isRepeat: event.isARepeat,
            matchesGlobalHotkey: HotkeyRecorderController.matches(event)
        )
        let context = keyContext(store: store)
        if let action = PanelKeyRouter.beforeSearch(key, context) {
            return perform(action, store: store)
        }
        // #60: an open search owns ↑↓ / Return / → / Esc / typing; with no search it returns false.
        if PanelSearchKeyboard.handle(event, store: store) {
            return true
        }
        // Search may have changed the state (closing itself, moving focus).
        return perform(PanelKeyRouter.afterSearch(key, keyContext(store: store)), store: store)
    }

    private func keyContext(store: HomeStore) -> PanelKeyRouter.Context {
        let responder = NSApp.keyWindow?.firstResponder
        let isFieldResponder = responder is NSTextView || responder is NSTextField
        let transient = PanelTransientUIState.shared
        return PanelKeyRouter.Context(
            isPanelWindow: MenuBarPanelController.shared.isPanelWindow(NSApp.keyWindow),
            isShowingMiReauth: store.isShowingMiReauth,
            isAllOffHoldActive: transient.isAllOffHoldActive,
            hasPendingConfirmation: store.pendingCloudConsent != nil,
            isShowingConnectionDetail: PanelConnectionDetailState.shared.isPresented,
            isConnectionStatusFocused: PanelConnectionDetailState.shared.isStatusControlFocused,
            hasActivePrompt: LayoutUIState.shared.hasActivePrompt,
            globalHotkeyEnabled: store.enableGlobalHotkey,
            isRecordingHotkey: HotkeyRecorderController.shared.isRecording,
            isGlobalHotkeyRegistered: HotkeySettingsState.shared.isRegistered,
            isHotkeyPhysicallyDown: isHotkeyPhysicallyDown,
            isTextFieldFocused: isFieldResponder,
            isFormFieldFocused: isFieldResponder && !PanelSearchState.shared.isFieldFocused,
            // A field that is mid-composition (Pinyin, Kana, Hangul) owns Esc to cancel the marked text.
            isComposingText: (responder as? NSTextView)?.hasMarkedText() == true,
            isShowingOnboarding: store.showsFullOnboardingGuide,
            isShowingAssistantBar: store.isShowingAssistantBar,
            editMode: LayoutUIState.shared.editMode,
            hasExpandedDevice: store.expandedDeviceId != nil,
            hasExpandedReminders: transient.hasExpandedReminders,
            hasExpandedOfflineDrawer: transient.hasExpandedOfflineDrawer,
            hasFocusedDevice: store.focusedDeviceId != nil,
            voiceInputEnabled: store.enableVoiceInput
        )
    }

    /// Performs a routed key; returns whether the panel consumed the event.
    private func perform(_ action: PanelKeyRouter.Action, store: HomeStore) -> Bool {
        switch action {
        case .passThrough:
            return false
        case .consume:
            return true
        case .openSettings:
            // Settings is a separate scene; the panel has no app menu of its own (agent app).
            SettingsWindowOpener.shared.show()
        case .dismissMiReauth:
            store.dismissMiReauth()
        case .cancelAllOffHold:
            PanelTransientUIState.shared.cancelAllOffHold()
        case .cancelPendingConfirmation:
            store.declinePendingCloudRequest()
        case .dismissConnectionDetail:
            PanelConnectionDetailState.shared.dismiss(restoreFocus: true)
        case .focusConnectionStatus:
            store.focusedDeviceId = nil
            PanelConnectionDetailState.shared.focusStatusControl()
        case .clearConnectionStatusFocus:
            PanelConnectionDetailState.shared.clearStatusControlFocus()
        case .dismissPrompt:
            LayoutUIState.shared.dismissActivePrompt()
        case .globalHotkeyEcho(let hidePanel):
            if hidePanel { MenuBarPanelController.shared.hidePanel() }
        case .leaveTextField(let dismissAssistant):
            if dismissAssistant {
                SpeechInputController.shared.stop(andSubmit: false, store: store)
                store.dismissAssistantBar()
            }
            NSApp.keyWindow?.makeFirstResponder(nil)
        case .roomOrder(let action):
            performRoomOrder(action, store: store)
        case .endDeviceLayoutEditing:
            LayoutUIState.shared.endDeviceLayoutEditing()
        case .presentAssistant(let voice):
            store.presentAssistantBar(startVoice: voice)
        case .moveFocus(let delta):
            PanelConnectionDetailState.shared.clearStatusControlFocus()
            PanelQuickIndexState.shared.moveFocus(delta: delta, store: store)
        case .adjustFocusedDevice(let delta):
            store.adjustFocusedDevice(delta: delta)
        case .toggleFocusedDevice:
            PanelQuickIndexState.shared.toggleFocusedDevice(store: store)
        case .cycleRoom(let delta):
            cycleRoomOrConnectionStatus(delta: delta, store: store)
        case .dismissAssistantBar:
            SpeechInputController.shared.stop(andSubmit: false, store: store)
            store.dismissAssistantBar()
        case .collapseExpandedDevice:
            store.expandedDeviceId = nil
        case .collapseExpandedReminders:
            PanelTransientUIState.shared.collapseReminders()
        case .collapseOfflineDrawer:
            PanelTransientUIState.shared.collapseOfflineDrawer()
        case .clearFocus:
            store.focusedDeviceId = nil
        case .hidePanel:
            MenuBarPanelController.shared.hidePanel()
        case .selectQuickIndex(let digit):
            // Both themes publish the order of the cards they actually draw; when no panel is
            // mounted, `PanelQuickIndexState` falls back to the store's own list.
            PanelQuickIndexState.shared.select(digit, store: store)
        case .selectQuickIndexClearingStatusFocus(let digit):
            PanelConnectionDetailState.shared.clearStatusControlFocus()
            PanelQuickIndexState.shared.select(digit, store: store)
        }
        return true
    }

    /// Cycles room pills in display order (#146) and includes the footer connection status control
    /// as a Tab stop at the wrap boundary so keyboard users can reach connection status even without
    /// focusing a device card first.
    func cycleRoomOrConnectionStatus(delta: Int, store: HomeStore) {
        let order = RoomPrefs.displayIds(order: RoomPrefs.storedOrder(), rooms: store.rooms)
        let known = Set(store.rooms.map(\.id))
        var seen = Set<String>()
        let ids = order.filter { known.contains($0) && seen.insert($0).inserted }
        let options: [String?] = [nil] + ids

        if PanelConnectionDetailState.shared.isStatusControlFocused {
            PanelConnectionDetailState.shared.clearStatusControlFocus()
            if delta >= 0 {
                store.selectRoom(options.first ?? nil)
            } else {
                store.selectRoom(options.last ?? nil)
            }
            return
        }

        guard options.count > 1 else {
            PanelConnectionDetailState.shared.focusStatusControl()
            return
        }
        let curIdx = options.firstIndex(where: { $0 == store.selectedRoomId }) ?? 0
        if delta > 0, curIdx == options.count - 1 {
            PanelConnectionDetailState.shared.focusStatusControl()
            return
        }
        if delta < 0, curIdx == 0 {
            PanelConnectionDetailState.shared.focusStatusControl()
            return
        }
        store.cycleRoom(delta: delta, order: order)
    }

    private func performRoomOrder(_ action: RoomOrderKeyAction, store: HomeStore) {
        switch action {
        case .moveFocus(let delta):
            RoomOrderKeyboard.moveFocus(delta, rooms: RoomOrderKeyboard.items(store: store))
        case .moveRow(let slots):
            RoomOrderKeyboard.moveFocused(bySlots: slots, rooms: RoomOrderKeyboard.items(store: store))
        case .moveRowToEdge(let toFront):
            RoomOrderKeyboard.moveFocusedToEdge(toFront: toFront, rooms: RoomOrderKeyboard.items(store: store))
        case .commit:
            // Return in the room order only commits and exits, never `toggleFocusedDevice()`.
            LayoutUIState.shared.exitRoomOrder(.commit)
        case .cancel:
            // Esc only rolls the order back; it does not walk the close-panel ladder.
            LayoutUIState.shared.cancelRoomOrder()
        case .consume:
            break
        }
    }

    // MARK: - 4. Native macOS Safety Alerts (UNUserNotificationCenter)

    private func setupNotificationsIfBundled() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let turnOffAction = UNNotificationAction(
            identifier: Self.turnOffActionId,
            title: L10n.tr("立即关闭", "Turn Off Now"),
            // A device control from the lock screen still needs the Mac unlocked.
            options: [.destructive, .authenticationRequired]
        )
        let category = UNNotificationCategory(
            identifier: Self.safetyCategoryId,
            actions: [turnOffAction],
            intentIdentifiers: [],
            // Report a dismissal too, so the alert can be forgotten instead of kept for the whole run.
            options: [.customDismissAction]
        )
        let runMissedAction = UNNotificationAction(
            identifier: Self.runMissedTimerActionId,
            title: L10n.tr("立即补执行", "Run Now"),
            options: [.authenticationRequired]
        )
        let missedCategory = UNNotificationCategory(
            identifier: Self.missedTimerCategoryId,
            actions: [runMissedAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category, missedCategory])

        // Permission is requested on demand (#55): first time 守护提醒 is enabled or a timer is set,
        // after an in-app explanation. Nothing is asked at launch.
        store?.onSafetyAlert = { [weak self] alert in
            self?.deliverNotification(for: alert)
        }
        store?.onMissedScheduledCommand = { [weak self] entry in
            self?.deliverMissedTimerNotification(for: entry)
        }
        store?.onDoorbellSnapshot = { [weak self] deviceId in
            guard let store = self?.store, let device = store.devices.first(where: { $0.id == deviceId }) else { return nil }
            return await DoorbellNotificationThumbnail.snapshotData(for: device, store: store)
        }
        store?.onDoorbellNotification = { [weak self] event in
            self?.deliverDoorbellNotification(event)
        }
        store?.notifyMissedScheduledCommandsIfNeeded()
        Task { [weak self] in
            await self?.refreshNotificationPermission()
        }
    }

    // MARK: - Notification Permission on Demand (#55)

    /// Set the first time the user is asked, so a denial is not re-prompted in-app forever.
    public static let notificationPromptedKey = "notification_permission_prompted"

    public static var hasRequestedNotificationAuthorization: Bool {
        UserDefaults.standard.bool(forKey: notificationPromptedKey)
    }

    /// Shows the macOS prompt only when it can still be shown. Returns whether banners are allowed.
    public func requestNotificationAuthorization() async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            UserDefaults.standard.set(true, forKey: Self.notificationPromptedKey)
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshNotificationPermission()
            return granted
        }
        await refreshNotificationPermission()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Mirrors the system state into the settings UI (authorized / denied / not asked yet).
    public func refreshNotificationPermission() async {
        let state = NotificationPermissionState.shared
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state.update(.notDetermined, canRequest: false)
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        state.update(settings.authorizationStatus, canRequest: settings.authorizationStatus == .notDetermined)
    }

    /// "打开系统设置" next to a denied state.
    public func openNotificationSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private struct MissedTimerNotificationIdentifier {
        private static let prefix = "missed-timer:"
        let commandId: UUID

        var rawValue: String { "\(Self.prefix)\(commandId.uuidString)" }

        init(commandId: UUID) {
            self.commandId = commandId
        }

        init?(rawValue: String) {
            guard rawValue.hasPrefix(Self.prefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.prefix.count))) else {
                return nil
            }
            self.commandId = id
        }
    }

    private func observeSafetyWakeEvents() {
        guard safetyWakeObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let sources: [(NotificationCenter, Notification.Name, SafetyWakeEvent)] = [
            (workspace, NSWorkspace.didWakeNotification, .systemWake),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked),
            (.default, .NSSystemClockDidChange, .clockChanged),
            (.default, .NSSystemTimeZoneDidChange, .timeZoneChanged),
        ]
        for (center, name, event) in sources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleSafetyWake(after: event)
                }
            }
            safetyWakeObservers.append((center, token))
        }
    }

    private func observeSafetyWakeInputs(_ store: HomeStore) {
        withObservationTracking {
            _ = store.nextSafetyAlertCheck(now: Date())
            if store.enableSafetyAlerts {
                _ = store.favoriteDeviceIds
                _ = store.sensorAlertPreferences
                _ = store.sensorAlertsOnlyWhenAway
            }
            _ = store.enableWeeklyHealthReport
            _ = store.nextAutomaticUpdateCheck(now: Date())
            _ = store.scheduledCommands
            _ = store.pollingContext.panelVisible
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store, self.store === store else { return }
                self.runSafetyWake()
                self.observeSafetyWakeInputs(store)
            }
        }
    }

    private func runSafetyWake(after event: SafetyWakeEvent? = nil) {
        guard let store else { return }
        let now = Date()
        if let event {
            if event == .clockChanged { automaticUpdateRetryAt = nil }
            store.reevaluateScheduledCommands(after: event)
        }
        for alert in store.evaluateSafetyAlerts(now: now) {
            deliverNotification(for: alert)
        }
        if let report = store.takeDueWeeklyHealthReport(now: now) {
            deliverWeeklyHealthReport(report)
        }
        if nextUpdateWake(store: store, now: now) == now {
            automaticUpdateTask = Task { [weak self, weak store] in
                await store?.checkForUpdatesIfNeeded()
                guard let self else { return }
                self.automaticUpdateTask = nil
                // A failed automatic check leaves the last successful date unchanged.
                self.automaticUpdateRetryAt = Date().addingTimeInterval(60)
                self.scheduleSafetyWake()
            }
        }
        scheduleSafetyWake()
    }

    private func nextUpdateWake(store: HomeStore, now: Date) -> Date? {
        guard automaticUpdateTask == nil, let due = store.nextAutomaticUpdateCheck(now: now) else { return nil }
        return max(due, automaticUpdateRetryAt ?? now)
    }

    private func scheduleSafetyWake(after event: SafetyWakeEvent? = nil) {
        safetyWakeTask?.cancel()
        safetyWakeTask = nil
        guard let store else { return }
        let now = Date()
        let alertCheck = store.nextSafetyAlertCheck(now: now)
        guard let wake = nextSafetyWake(
            now: now, alertCheck: alertCheck,
            weeklyReport: store.nextWeeklyHealthReportCheck(now: now),
            updateCheck: nextUpdateWake(store: store, now: now), event: event
        ) else { return }
        if wake == now, let event {
            runSafetyWake(after: event)
            return
        }
        // Coalesce housekeeping without moving a safety deadline past its threshold.
        let tolerance = min(1, max(0, alertCheck?.timeIntervalSince(wake) ?? 1))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(wake.timeIntervalSince(now)))
        safetyWakeTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline, tolerance: .seconds(tolerance)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.runSafetyWake()
        }
    }

    private func deliverNotification(for alert: SafetyAlert) {
        // Remember which home this alert belongs to at delivery time; the tap may come much later.
        rememberPendingAlert(alert, scope: store?.connectionScopeIdentifier)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        guard let content = notificationContent(for: .safetyAlert(alert)) else { return }
        content.title = alert.title
        content.body = alert.body
        if content.interruptionLevel != .passive {
            content.sound = .default
        }
        if alert.turnOffCommand != nil {
            content.categoryIdentifier = Self.safetyCategoryId
        }

        let request = UNNotificationRequest(
            identifier: alert.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Weekly home health report summary (#182); the full report is exported from Settings.
    private func deliverWeeklyHealthReport(_ report: WeeklyHealthReport) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard let content = notificationContent(for: .weeklyHealthReport) else { return }
        content.title = L10n.tr("家庭健康周报", "Weekly Home Health Report")
        content.body = report.notificationSummary()
        let request = UNNotificationRequest(
            identifier: "weekly-health-report-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Banner for actions invoked from outside the panel (URL Scheme / App Intents, #57).
    ///
    /// This never asks for permission: if the user has not allowed notifications, it silently does
    /// nothing and the in-panel toast / intent dialog remains the feedback. The bundle check keeps
    /// `swift test` from touching `UNUserNotificationCenter` (#55).
    public func deliverExternalActionNotification(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        guard let content = notificationContent(for: .externalAction) else { return }
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "external-action-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// A doorbell press as a banner with the camera's snapshot (#10).
    ///
    /// One request id per press comes from `DoorbellNotification`, the same dedupe key the
    /// activity feed uses, so a duplicated report replaces the banner instead of stacking a second
    /// one. The picture is fetched first, bounded to 2.5 s; a missing snapshot still posts the
    /// notification without one.
    private func deliverDoorbellNotification(_ event: DoorbellNotification) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var picture: DoorbellNotificationThumbnail.Picture?
            if let store = self.store,
               let device = store.devices.first(where: { $0.id == event.deviceId }) {
                picture = await DoorbellNotificationThumbnail.picture(for: device, store: store)
            }

            guard let content = self.notificationContent(for: .doorbell) else { return }
            content.title = event.title
            content.body = event.body
            content.threadIdentifier = "doorbell"
            content.userInfo = [Self.doorbellDeviceIdKey: event.deviceId]
            // The chime switch already plays its own sound for this press; the banner does not
            // need to double it. Every other ring gets the system sound.
            if content.interruptionLevel != .passive, self.store?.doorbellChime != true {
                content.sound = .default
            }
            if let picture {
                content.attachments = [picture.attachment]
            }
            let request = UNNotificationRequest(
                identifier: event.identifier,
                content: content,
                trigger: nil
            )
            // The system copies the attachment file when the request is added; the temp file is
            // ours to clean up either way.
            let pictureFile = picture?.fileURL
            UNUserNotificationCenter.current().add(request) { _ in
                if let pictureFile {
                    try? FileManager.default.removeItem(at: pictureFile)
                }
            }
        }
    }

    /// Then the tap opens the card and its live camera through the same entry points as
    /// `menumijia://focus` (#10).
    private func openDoorbellCamera(deviceId: String) {
        guard let store else { return }
        // Same order as `menumijia://focus`: move the panel to the card, then show it.
        _ = store.focusRaycastDevice(deviceId: deviceId)
        ensureMenuBarExtraWindowVisible()
        guard let device = store.devices.first(where: { $0.id == deviceId }),
              device.isOnline,
              case .camera = device.kind else { return }
        store.openCameraLiveView(device.id)
    }

    private func deliverMissedTimerNotification(for entry: ScheduledCommand) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        guard let content = notificationContent(for: .missedTimer) else { return }
        content.title = L10n.tr("已错过定时任务", "Missed Scheduled Command")
        content.body = L10n.tr(
            "应用关闭或电脑睡眠时错过的定时：「\(entry.reply)」。没有自动执行，可点通知按钮立即补执行。",
            "Missed while the app was closed or the Mac was asleep: \"\(entry.reply)\". It did not run. Click Run Now to run it."
        )
        if content.interruptionLevel != .passive {
            content.sound = .default
        }
        content.categoryIdentifier = Self.missedTimerCategoryId

        let request = UNNotificationRequest(
            identifier: MissedTimerNotificationIdentifier(commandId: entry.id).rawValue,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static let hasTimeSensitiveEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.usernotifications.time-sensitive" as CFString
        return SecTaskCopyValueForEntitlement(task, key, nil) as? Bool == true
    }()

    /// `nil` means the user's Focus filter asked for silence for this category (#575). Safety alerts
    /// and the doorbell never reach that branch: `NotificationDeliveryPolicy` refuses to suppress them.
    private func notificationContent(for category: NotificationCategory) -> UNMutableNotificationContent? {
        let policy = NotificationDeliveryPolicy.resolve(
            for: category,
            isFocusActive: MacContextObserver.focusActive() == true,
            focusFilter: FocusFilterStorage.load()
        )
        guard !policy.isSuppressed else { return nil }
        let content = UNMutableNotificationContent()
        content.interruptionLevel = switch policy.interruptionLevel {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: Self.hasTimeSensitiveEntitlement ? .timeSensitive : .active
        }
        content.relevanceScore = policy.relevanceScore
        return content
    }

    private func rememberPendingAlert(_ alert: SafetyAlert, scope: String?) {
        let record = PendingAlert(alert: alert, scope: scope)
        if pendingAlertsById.updateValue(record, forKey: alert.id) == nil {
            pendingAlertOrder.append(alert.id)
        }
        while pendingAlertOrder.count > Self.pendingAlertLimit {
            let evicted = pendingAlertOrder.removeFirst()
            pendingAlertsById.removeValue(forKey: evicted)
            // The banner for an alert we can no longer act on would only fail when tapped.
            if Bundle.main.bundleURL.pathExtension == "app" {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [evicted])
            }
        }
    }

    private func forgetPendingAlert(_ id: String) {
        pendingAlertsById.removeValue(forKey: id)
        pendingAlertOrder.removeAll { $0 == id }
    }

    /// The distributed lock notification can arrive after the authenticated action callback, so a
    /// legitimate tap would be refused with the stale flag still set. Read the session itself (#143).
    private func refreshScreenLockState() {
        guard let store else { return }
        store.setScreenLocked(ScreenLockPolicy.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any]))
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let alertId = response.notification.request.identifier
        // A doorbell banner is not a pending alert: its tap opens the camera card (#10).
        if let deviceId = response.notification.request.content.userInfo[Self.doorbellDeviceIdKey] as? String {
            completionHandler()
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                openDoorbellCamera(deviceId: deviceId)
            }
            return
        }
        if response.actionIdentifier == Self.turnOffActionId {
            defer { completionHandler() }
            guard let pending = pendingAlertsById[alertId] else {
                if let store {
                    store.showToast(store.staleSafetyAlertMessage, isError: true)
                }
                return
            }
            refreshScreenLockState()
            let task = store?.executeSafetyAlertAction(pending.alert, deliveredInScope: pending.scope)
            // A refusal (locked, or another home now) has not consumed the notification: keep the
            // record so a later tap after unlocking still works.
            if task != nil {
                forgetPendingAlert(alertId)
            }
            return
        }
        // The default tap, a dismissal and the missed-timer action all consume the notification.
        defer {
            forgetPendingAlert(alertId)
            completionHandler()
        }
        if response.actionIdentifier == Self.runMissedTimerActionId,
           let missedId = MissedTimerNotificationIdentifier(rawValue: alertId) {
            refreshScreenLockState()
            Task { @MainActor [weak self] in
                _ = await self?.store?.runMissedScheduledCommand(id: missedId.commandId)
            }
        }
        // The default tap only opens the app; nothing else to do here.
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .sound])
    }
}
