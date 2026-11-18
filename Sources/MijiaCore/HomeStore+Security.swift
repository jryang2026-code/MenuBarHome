import Foundation

// Manual-control safety: the screen-lock guard and the high-risk confirmation gate (#143).
extension HomeStore {
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
    /// installed presenter once and runs only when approved. The wall-switch light marks (#104)
    /// ride the store's own defaults suite so a suite-scoped test sees the same behaviour the
    /// production store (`.standard`) gives every other caller of the policy.
    func allowManualControl(
        _ operation: IntentOperation,
        for device: SmartDevice,
        offersMarkAsLight: Bool = false,
        ignoresSwitchLightMark: Bool = false
    ) -> Bool {
        let marks: Set<String> = ignoresSwitchLightMark ? [] : SwitchLightMarks.load(defaults: userDefaults)
        guard let prompt = ManualControlPolicy.confirmation(
            DeviceIntent(targetId: device.id, operation: operation),
            devices: devices,
            markedLightIds: marks,
            offersMarkAsLight: offersMarkAsLight && !ignoresSwitchLightMark
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
