import Foundation

/// Snapshot of a device's control identity before presenting a confirmation modal.
///
/// `NSAlert.runModal()` spins the main run loop synchronously, so provider snapshots, dual-source
/// failovers, account changes, session expiry or screen lock can run before confirmation returns.
struct ModalDeviceContext: Sendable {
    let controlContextID: UUID
    let deviceId: String
    let backend: HomeBackend
    let accountId: String?
    let lgServed: Bool
}

// Manual-control safety: the screen-lock guard and the high-risk confirmation gate (#143).
extension HomeStore {
    func captureModalDeviceContext(for device: SmartDevice) -> ModalDeviceContext {
        ModalDeviceContext(
            controlContextID: controlContextID,
            deviceId: device.id,
            backend: deviceBackend(for: device.id),
            accountId: device.accountId,
            lgServed: lgClientServes(device)
        )
    }

    /// Re-reads the live device after a confirmation gate and verifies that its home context and
    /// backing source are unchanged, session/lock gates still allow control, and online state holds.
    func resolvePostModalDevice(
        _ captured: ModalDeviceContext,
        requireOnline: Bool = false,
        showOfflineToast: Bool = false
    ) -> SmartDevice? {
        guard controlContextID == captured.controlContextID,
              let current = devices.first(where: { $0.id == captured.deviceId }),
              deviceBackend(for: captured.deviceId) == captured.backend,
              current.accountId == captured.accountId,
              lgClientServes(current) == captured.lgServed else {
            return nil
        }
        guard !rejectWritesBlockedByMiSession(needsMi: !lgClientServes(current)) else { return nil }
        guard !rejectControlWhileLocked() else { return nil }
        if requireOnline, !current.isOnline {
            if showOfflineToast {
                showToast(
                    L10n.tr("\(current.name) 当前离线（可能断电）", "\(current.name) is offline (unplugged)"),
                    isError: true
                )
            }
            return nil
        }
        return current
    }

    /// True while `deviceId` still exists on the exact control context and source captured in `captured`.
    func matchesModalDeviceContext(_ captured: ModalDeviceContext) -> Bool {
        guard controlContextID == captured.controlContextID,
              let current = devices.first(where: { $0.id == captured.deviceId }) else {
            return false
        }
        return deviceBackend(for: captured.deviceId) == captured.backend
            && current.accountId == captured.accountId
            && lgClientServes(current) == captured.lgServed
    }

    /// Shown wherever a user-initiated control is refused because the Mac is locked.
    public var screenLockBlockedMessage: String {
        L10n.tr(
            "Mac 已锁定，已阻止设备控制。可在设置 → 隐私中关闭此限制。",
            "Mac is locked, so device control is blocked. Turn this off in Settings → Privacy."
        )
    }

    public var isControlBlockedByScreenLock: Bool {
        ManualControlPolicy.isScreenLockBlocked(
            isLocked: isScreenLocked,
            blockWhileLocked: blockControlWhileLocked
        )
    }

    /// Returns true when a user control must stop now, after telling the user why.
    func rejectControlWhileLocked() -> Bool {
        guard isControlBlockedByScreenLock else { return false }
        showToast(screenLockBlockedMessage, isError: true)
        return true
    }

    /// Gate for a manual intent, used when a tapped suggestion must keep the same hazard rule as a card.
    func allowManualControl(_ intent: DeviceIntent) -> Bool {
        guard let device = devices.first(where: { $0.id == intent.targetId }) else { return false }
        return allowManualControl(intent.operation, for: device)
    }

    /// Gate for a manual operation on a device. Low-risk actions pass; a hazardous action asks the
    /// installed presenter once and runs only when approved.
    func allowManualControl(_ operation: IntentOperation, for device: SmartDevice) -> Bool {
        guard let prompt = ManualControlPolicy.confirmation(
            DeviceIntent(targetId: device.id, operation: operation),
            devices: devices
        ) else { return true }
        return presentManualControlConfirmation(prompt, for: device)
    }

    func allowManualControl(facet: FacetControl, value: JSONValue?, portion: Int? = nil, for device: SmartDevice) -> Bool {
        guard let prompt = ManualControlPolicy.confirmation(
            facet: facet,
            value: value,
            portion: portion,
            for: device
        ) else { return true }
        return presentManualControlConfirmation(prompt, for: device)
    }

    /// Gate for a cover position move whose start the device never reported. The direction is
    /// unknown, so the opening/closing copy would be wrong; the write still needs a second answer
    /// on the subtypes whose hazard table guards movement.
    func allowUnknownStartCoverControl(for device: SmartDevice) -> Bool {
        let prompt = ManualControlConfirmation(
            title: L10n.tr("确认操作高风险设备？", "Control a high-risk device?"),
            message: L10n.format(
                "「%@」的位置回报缺失，任何位置调整都需要再次确认。",
                "\"%@\" reported no position, so any position change needs confirmation.",
                device.name
            ),
            confirmTitle: L10n.tr("确认执行", "Confirm"),
            cancelTitle: L10n.tr("取消", "Cancel")
        )
        return presentManualControlConfirmation(prompt, for: device)
    }

    private func presentManualControlConfirmation(_ prompt: ManualControlConfirmation, for device: SmartDevice) -> Bool {
        guard let handler = manualControlConfirmationHandler, handler(prompt) else {
            showToast(
                L10n.format("已取消「%@」的操作", "Cancelled the action for %@", device.name),
                isError: true
            )
            return false
        }
        return true
    }

    /// Called by `SystemActivityMonitor` on the screen-lock/unlock distributed notifications.
    public func setScreenLocked(_ locked: Bool) {
        guard isScreenLocked != locked else { return }
        isScreenLocked = locked
    }
}
