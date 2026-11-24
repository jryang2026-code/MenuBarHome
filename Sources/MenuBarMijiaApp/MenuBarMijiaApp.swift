import SwiftUI
import AppKit
import CoreSpotlight
import MijiaCore

@main
@MainActor
struct MenuBarMijiaApp: App {
    /// Receives `menumijia://` links while the app is running and on cold launch (#57).
    @NSApplicationDelegateAdaptor(MenuBarMijiaAppDelegate.self) private var appDelegate

    init() {
        // Creating the store reads the Keychain; explain the post-upgrade prompt before macOS shows it (#16).
        KeychainUpgradeNotice.presentIfNeeded()
        let sharedStore = HomeStore.shared
        sharedStore.manualControlConfirmationHandler = ManualControlConfirmationPresenter.present
        sharedStore.onCompanionIntegrationChanged = { enabled in
            if !enabled {
                URLCommandHandler.shared.invalidatePendingCommands()
            }
        }
        sharedStore.launchAtLoginSystem = SystemLaunchAtLogin()
        LaunchAtLoginCoordinator.live(store: sharedStore).refresh()
        KeychainUpgradeNotice.recordIfLoaded()
        // The menu-bar item, its label, tooltip, long press and panel all live in the AppKit
        // controller now (#56), so there is no `MenuBarExtra` scene left to host.
        HotkeyAndNotificationManager.shared.start(with: sharedStore)
        SystemActivityMonitor.shared.start(with: sharedStore)
        AutomationEngine.shared.start(with: sharedStore)
        XiaomiCameraBridge.scrubStaleConfigOnLaunch()
        Task { await XiaomiCameraBridge.shared.scrubStaleConfigOnStartup() }
        CameraLivePanelController.shared.install(with: sharedStore)
        SpotlightIndexer.shared.start(with: sharedStore)
    }

    var body: some Scene {
        // ⌘, and the app menu's Settings… item still come from the SwiftUI `Settings` scene; the
        // window survives switching to the browser to copy a token (#42).
        Settings {
            SettingsWindowView(store: HomeStore.shared)
        }
    }
}

// MARK: - Manual High-Risk Confirmation (#143)

/// App-modal second confirmation for manual controls on high-risk devices. Cancel is the default
/// button, so a stray Return cannot approve a heater or plug action.
@MainActor
enum ManualControlConfirmationPresenter {
    /// True while a high-risk confirmation alert is running its modal loop so the non-activating
    /// panel does not dismiss itself behind the alert.
    static private(set) var isPresenting = false

    static func present(_ prompt: ManualControlConfirmation) -> Bool {
        isPresenting = true
        defer { isPresenting = false }
        NSApp.activate(ignoringOtherApps: true)
        let answer = makeAlert(prompt).runModal()
        return applyModalResponse(answer, for: prompt, in: HomeStore.shared)
    }

    static func applyModalResponse(
        _ answer: NSApplication.ModalResponse,
        for prompt: ManualControlConfirmation,
        in store: HomeStore
    ) -> Bool {
        // #104: the third button both marks the wall switch as an ordinary light (persisted) and
        // executes the action in the same tap, provided the live post-modal device still matches
        // its modal context and remains an eligible wall switch.
        if answer == .alertThirdButtonReturn, let mark = prompt.markAsLight {
            return store.confirmSwitchAsLightFromModal(mark.deviceId)
        }
        return answer == .alertSecondButtonReturn
    }

    /// The alert `present` runs, built separately so a snapshot can render it without a modal loop.
    static func makeAlert(_ prompt: ManualControlConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        if let hint = prompt.hint {
            alert.accessoryView = hintAccessory(hint)
        }
        alert.addButton(withTitle: prompt.cancelTitle)
        alert.addButton(withTitle: prompt.confirmTitle)
        if let mark = prompt.markAsLight {
            alert.addButton(withTitle: mark.title)
        }
        return alert
    }

    /// 12 pt primary text: the sentence says how to stop this dialog, so it is not secondary grey (§18).
    private static func hintAccessory(_ hint: String) -> NSTextField {
        let width: CGFloat = 280
        let field = NSTextField(wrappingLabelWithString: hint)
        field.font = .systemFont(ofSize: DesignTokens.TypeSize.caption)
        field.textColor = .labelColor
        field.preferredMaxLayoutWidth = width
        let fitted = field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        field.frame = NSRect(origin: .zero, size: NSSize(width: width, height: ceil(fitted.height)))
        return field
    }
}

// MARK: - External URL Scheme (#57)

/// `application(_:open:)` is the reliable entry point for custom schemes on a menu-bar app: no panel
/// exists when a link launches the app, so `.onOpenURL` alone would miss cold-start links.
/// `ObservableObject` is required by `NSApplicationDelegateAdaptor`; the type publishes nothing.
@MainActor
final class MenuBarMijiaAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    func application(_ application: NSApplication, open urls: [URL]) {
        URLCommandHandler.shared.enqueue(urls)
    }

    /// A Spotlight result carries our item identifier; the deeplink it maps to goes through the
    /// same `menumijia://` entry point as an external link, so no new control path exists (#575).
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let url = SpotlightIndexPlan.route(forItemIdentifier: identifier) else {
            return false
        }
        URLCommandHandler.shared.enqueue([url])
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LayoutUIState.shared.commitRoomOrderIfNeeded()
        return CameraLivePanelController.shared.prepareForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
    }

    /// #146 §5.2：应用退出时也要把排序草稿提交回 `UserDefaults`，否则拖到一半的会话会静默丢失。
    func applicationWillTerminate(_ notification: Notification) {
        LayoutUIState.shared.commitRoomOrderIfNeeded()
        XiaomiCameraBridge.scrubStaleConfigOnLaunch()
    }
}

// MARK: - Menu Bar Tooltip (#54)

/// One-line status shown when hovering the menu-bar icon: "MenuBarHome · 3 on · Study 26.5° ·
/// Xiaomi Cloud connected". Disconnected shows the reason instead of the backend name.
@MainActor
enum MenuBarStatusSummary {
    static func text(for store: HomeStore) -> String {
        let _ = store.effectiveLanguage
        var parts: [String] = ["MenuBarHome"]
        if store.deviceValuesAreStale {
            parts.append(L10n.tr("可能过期", "Possibly stale"))
        } else {
            parts.append(L10n.tr("\(store.activeDeviceCount) 台开启", "\(store.activeDeviceCount) on"))
            if let reading = store.preferredEnvironmentReading,
               let temperature = reading.temperature {
                parts.append("\(L10n.displayRoomName(reading.label)) \(L10n.temperature(temperature, fractionDigits: 1))")
            }
        }

        switch store.panelHealth {
        case .ok:
            if let expiresAt = store.miSessionExpiringSoonDate {
                let dateText = expiresAt.formatted(date: .abbreviated, time: .omitted)
                parts.append(L10n.tr("米家登录将在 \(dateText) 到期", "Xiaomi Home sign-in expires \(dateText)"))
            } else {
                switch store.connectionStatus {
                case .connected:
                    if store.connectedBackends.contains(.homeAssistant) && store.connectedBackends.contains(.xiaomiCloud) {
                        parts.append(L10n.tr("Home Assistant + 米家云已连接", "Home Assistant + Xiaomi Cloud connected"))
                    } else if store.connectedBackends.contains(.xiaomiCloud) {
                        parts.append(L10n.tr("已连接米家云", "Xiaomi Cloud connected"))
                    } else if store.connectedBackends.contains(.homeAssistant) {
                        parts.append(L10n.tr("已连接 Home Assistant", "Home Assistant connected"))
                    } else {
                        switch store.homeBackend {
                        case .xiaomiCloud:
                            parts.append(L10n.tr("已连接米家云", "Xiaomi Cloud connected"))
                        case .homeAssistant:
                            parts.append(L10n.tr("已连接 Home Assistant", "Home Assistant connected"))
                        case .demo:
                            parts.append(L10n.tr("演示模式", "Demo mode"))
                        }
                    }
                case .connecting:
                    parts.append(L10n.tr("正在连接…", "Connecting…"))
                case .disconnected(let reason):
                    parts.append(L10n.tr("未连接：\(reason)", "Disconnected: \(reason)"))
                }
            }
        case .connecting:
            parts.append(L10n.tr("正在连接…", "Connecting…"))
        case .degraded(let reason), .blocked(let reason, _):
            parts.append(reason)
        case .notConfigured:
            parts.append(L10n.tr("未配置数据源", "No data source configured"))
        }

        return parts.joined(separator: " · ")
    }
}
