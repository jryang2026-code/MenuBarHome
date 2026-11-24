import Foundation

public enum HotkeyExecutionOutcome: Equatable, Sendable {
    case executed(message: String)
    case blocked(message: String)
    case cancelled
    case unavailable(label: String)
    case failed(message: String)

    public var notificationBody: String? {
        switch self {
        case .executed(let message), .blocked(let message), .failed(let message):
            return message
        case .unavailable, .cancelled:
            return nil
        }
    }
}

extension HomeStore {
    /// Executes a bound global hotkey through the exact same control path as a panel tap:
    /// capability gate, lock-screen block, Mi session check, and high-risk confirmation (without
    /// offering "don't ask again"). Missing targets are a silent no-op.
    @discardableResult
    public func executeHotkeyBinding(_ binding: HotkeyBinding) async -> HotkeyExecutionOutcome {
        switch binding.target {
        case .devicePower(let deviceId):
            guard let device = devices.first(where: { $0.id == deviceId }) else {
                return .unavailable(label: binding.targetLabel)
            }
            guard device.isPrimaryToggleable else {
                return .unavailable(label: device.name)
            }
            if isControlBlockedByScreenLock {
                _ = rejectControlWhileLocked()
                return .blocked(message: screenLockBlockedMessage)
            }
            let wasOn = device.isActiveOn
            let priorToast = toastNotice?.message
            guard let task = togglePrimary(device, offersSwitchLightMark: false) else {
                if let currentToast = toastNotice?.message, currentToast != priorToast {
                    return .blocked(message: currentToast)
                }
                return .cancelled
            }
            let succeeded = await task.value
            if succeeded {
                let message = wasOn
                    ? L10n.tr("已关闭 \(device.name)", "Turned off \(device.name)")
                    : L10n.tr("已打开 \(device.name)", "Turned on \(device.name)")
                showToast(message)
                return .executed(message: message)
            }
            let failure = toastNotice?.message ?? L10n.tr("\(device.name) 操作失败", "\(device.name) failed")
            return .failed(message: failure)

        case .scene(let sceneId):
            guard let scene = scenes.first(where: { $0.id == sceneId }) else {
                return .unavailable(label: binding.targetLabel)
            }
            if isControlBlockedByScreenLock {
                _ = rejectControlWhileLocked()
                return .blocked(message: screenLockBlockedMessage)
            }
            let priorToast = toastNotice?.message
            let succeeded = await triggerScene(scene).value
            if succeeded {
                let message = L10n.tr("已触发场景：\(scene.name)", "Activated scene: \(scene.name)")
                return .executed(message: message)
            }
            if let currentToast = toastNotice?.message, currentToast != priorToast, !currentToast.isEmpty {
                return .blocked(message: currentToast)
            }
            return .cancelled

        case .quickAction(let action):
            guard !devices.isEmpty else {
                return .unavailable(label: action.title)
            }
            if isControlBlockedByScreenLock {
                _ = rejectControlWhileLocked()
                return .blocked(message: screenLockBlockedMessage)
            }
            let priorToast = toastNotice?.message
            guard let task = executeQuickAction(action, respectScreenLock: true) else {
                if let currentToast = toastNotice?.message, currentToast != priorToast, !currentToast.isEmpty {
                    return .blocked(message: currentToast)
                }
                return .cancelled
            }
            let outcome = await task.value
            let freshToast = toastNotice?.message != priorToast ? toastNotice?.message : nil
            let message = freshToast ?? L10n.tr("已执行：\(action.title)", "Ran: \(action.title)")
            switch outcome {
            case .completed:
                return .executed(message: message)
            case .partial:
                return .failed(message: message)
            case .refusedByMiSession:
                return .blocked(message: HomeStore.miSessionBlockedMessage)
            }
        }
    }
}
