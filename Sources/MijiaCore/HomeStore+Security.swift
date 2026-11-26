import Foundation

/// Hazard-classification dimensions of a device that govern manual confirmation policy.
///
/// Benign telemetry updates or non-reclassifying renames preserve the profile, whereas turning a
/// light-eligible wall switch into a non-light load, changing `IntentDeviceCategory`, or escalating
/// a cover/appliance hazard changes the profile and invalidates an in-flight modal approval.
struct ManualControlHazardProfile: Equatable, Sendable {
    let category: IntentDeviceCategory
    let wallSwitchLightCandidate: Bool
    let isMomentaryPlugButton: Bool
    let coverSubtype: CoverSubtype?
    let isClimateWaterHeater: Bool
    let applianceHeats: Bool
    let applianceHasStartAction: Bool
    let genericDeviceType: String?

    init(_ device: SmartDevice) {
        self.category = IntentDeviceCategory(device)
        self.wallSwitchLightCandidate = ManualControlPolicy.wallSwitchMayControlLight(device)
        if case .plug(let spec) = device.kind {
            self.isMomentaryPlugButton = spec.switchEntityId.hasPrefix("button.")
        } else {
            self.isMomentaryPlugButton = false
        }
        if case .cover(let spec) = device.kind {
            self.coverSubtype = spec.subtype
        } else {
            self.coverSubtype = nil
        }
        if case .climate = device.kind {
            self.isClimateWaterHeater = device.name.contains("热水器")
        } else {
            self.isClimateWaterHeater = false
        }
        if case .appliance(let spec) = device.kind {
            self.applianceHeats = spec.heats
            self.applianceHasStartAction = spec.startAction != nil
        } else {
            self.applianceHeats = false
            self.applianceHasStartAction = false
        }
        if case .generic(let spec) = device.kind {
            self.genericDeviceType = spec.deviceType
        } else {
            self.genericDeviceType = nil
        }
    }
}

/// Snapshot of a device's control identity and hazard profile before presenting a confirmation modal.
///
/// `NSAlert.runModal()` spins the main run loop synchronously, so provider snapshots, dual-source
/// failovers, account changes, session expiry or screen lock can run before confirmation returns.
struct ModalDeviceContext: Sendable {
    let controlContextID: UUID
    let capabilityGeneration: Int
    let deviceId: String
    let backend: HomeBackend
    let accountId: String?
    let lgServed: Bool
    let hazardProfile: ManualControlHazardProfile
}

// Manual-control safety: the screen-lock guard and the high-risk confirmation gate (#143).
extension HomeStore {
    func captureModalDeviceContext(for device: SmartDevice) -> ModalDeviceContext {
        ModalDeviceContext(
            controlContextID: controlContextID,
            capabilityGeneration: capabilityGeneration,
            deviceId: device.id,
            backend: deviceBackend(for: device.id),
            accountId: device.accountId,
            lgServed: lgClientServes(device),
            hazardProfile: ManualControlHazardProfile(device)
        )
    }

    /// Re-reads the live device after a confirmation gate and verifies that its home context and
    /// backing source are unchanged, session/lock gates still allow control, and online state holds.
    func resolvePostModalDevice(
        _ captured: ModalDeviceContext,
        requireOnline: Bool = false,
        showOfflineToast: Bool = false
    ) -> SmartDevice? {
        if rejectDeviceWriteIfCapabilityDisabled(deviceId: captured.deviceId) != nil {
            return nil
        }
        guard controlContextID == captured.controlContextID,
              capabilityGeneration == captured.capabilityGeneration,
              let current = devices.first(where: { $0.id == captured.deviceId }),
              deviceBackend(for: captured.deviceId) == captured.backend,
              current.accountId == captured.accountId,
              lgClientServes(current) == captured.lgServed else {
            return nil
        }
        guard !rejectWritesBlockedByMiSession(needsMi: !servedWithoutMiSession(current)) else { return nil }
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
              capabilityGeneration == captured.capabilityGeneration,
              capabilityWriteRejection(forDeviceId: captured.deviceId) == nil,
              let current = devices.first(where: { $0.id == captured.deviceId }) else {
            return false
        }
        return deviceBackend(for: captured.deviceId) == captured.backend
            && current.accountId == captured.accountId
            && lgClientServes(current) == captured.lgServed
    }

    /// Verifies that after a confirmation gate on `captured`, `operation` on `current` neither
    /// newly requires an unasked confirmation nor changed its hazard classification while still
    /// requiring confirmation.
    func postModalAllowsOperation(
        _ operation: IntentOperation,
        on current: SmartDevice,
        captured: ModalDeviceContext,
        didPresentModal: Bool,
        ignoresSwitchLightMark: Bool = false
    ) -> Bool {
        let marks: Set<String> = ignoresSwitchLightMark ? [] : SwitchLightMarks.load(defaults: userDefaults)
        let stillNeedsConfirmation = ManualControlPolicy.requiresConfirmation(
            operation,
            for: current,
            markedLightIds: marks
        )
        guard stillNeedsConfirmation else { return true }
        guard didPresentModal else { return false }
        return ManualControlHazardProfile(current) == captured.hazardProfile
    }

    /// Fails closed with a cancellation toast when post-modal state or mark changes invalidate the
    /// confirmation decision for `operation`.
    func rejectChangedPostModalHazard(
        _ operation: IntentOperation,
        on current: SmartDevice,
        captured: ModalDeviceContext,
        didPresentModal: Bool,
        ignoresSwitchLightMark: Bool = false
    ) -> Bool {
        guard !postModalAllowsOperation(
            operation,
            on: current,
            captured: captured,
            didPresentModal: didPresentModal,
            ignoresSwitchLightMark: ignoresSwitchLightMark
        ) else {
            return false
        }
        showPostModalDeviceChangedToast()
        return true
    }

    func showPostModalDeviceChangedToast() {
        showToast(L10n.tr("设备已变化，操作已取消", "The device changed. The action was cancelled."), isError: true)
    }

    /// Runs the manual confirmation gate for `operation` on `initial` and resolves the verified
    /// post-modal device, failing closed if context, source, online/lock/session state, or hazard
    /// classification changed incompatibly while the modal was open.
    func confirmAndResolveManualControl(
        _ operation: IntentOperation,
        for initial: SmartDevice,
        offersMarkAsLight: Bool = false,
        ignoresSwitchLightMark: Bool = false,
        requireOnline: Bool = false,
        showOfflineToast: Bool = false,
        panelConfirmed: Bool = false
    ) -> (device: SmartDevice, didPresentModal: Bool, context: ModalDeviceContext)? {
        if rejectDeviceWriteIfCapabilityDisabled(deviceId: initial.id) != nil {
            return nil
        }
        let modalContext = captureModalDeviceContext(for: initial)
        let marks: Set<String> = ignoresSwitchLightMark ? [] : SwitchLightMarks.load(defaults: userDefaults)
        let didPresentModal = ManualControlPolicy.requiresConfirmation(
            operation,
            for: initial,
            markedLightIds: marks
        )
        guard panelConfirmed || allowManualControl(
            operation,
            for: initial,
            offersMarkAsLight: offersMarkAsLight,
            ignoresSwitchLightMark: ignoresSwitchLightMark
        ) else {
            return nil
        }
        guard let current = resolvePostModalDevice(
            modalContext,
            requireOnline: requireOnline,
            showOfflineToast: showOfflineToast
        ) else {
            return nil
        }
        guard !rejectChangedPostModalHazard(
            operation,
            on: current,
            captured: modalContext,
            didPresentModal: didPresentModal,
            ignoresSwitchLightMark: ignoresSwitchLightMark
        ) else {
            return nil
        }
        return (current, didPresentModal, modalContext)
    }

    /// Validates and persists «这是灯，以后不再询问» from an active primary-power modal (#104).
    ///
    /// If the wall switch vanished, went offline, switched source/account, hit screen lock or Mi
    /// session expiry, or changed into a non-light high-risk device while the modal was open,
    /// neither persists the mark nor approves the write.
    public func confirmSwitchAsLightFromModal(_ deviceId: String) -> Bool {
        if let captured = activeModalContexts.last(where: { $0.deviceId == deviceId }) {
            guard matchesModalDeviceContext(captured) else { return false }
        }
        guard capabilityWriteRejection(forDeviceId: deviceId) == nil,
              let current = devices.first(where: { $0.id == deviceId }),
              current.isOnline,
              current.isPrimaryToggleable,
              !isControlBlockedByScreenLock,
              !(miSessionBlocksControl && !lgClientServes(current)),
              ManualControlPolicy.wallSwitchMayControlLight(current) else {
            return false
        }
        markSwitchAsLight(deviceId)
        return isSwitchMarkedAsLight(deviceId)
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
        if rejectDeviceWriteIfCapabilityDisabled(deviceId: intent.targetId) != nil { return false }
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
        let context = captureModalDeviceContext(for: device)
        activeModalContexts.append(context)
        defer { _ = activeModalContexts.popLast() }
        guard let handler = manualControlConfirmationHandler, handler(prompt) else {
            let currentName = devices.first(where: { $0.id == device.id })?.name ?? device.name
            showToast(
                L10n.format("已取消「%@」的操作", "Cancelled the action for %@", currentName),
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
