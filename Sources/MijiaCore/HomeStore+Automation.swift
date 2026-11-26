import Foundation

public struct AutomationExecutionOutcome: Equatable, Sendable {
    public let plan: IntentPlan
    public let attemptedCount: Int
    public let succeededCount: Int
    public let failedCount: Int
    public let errorMessage: String?
    public let skipReason: AutomationSkipReason?

    public var reply: String { plan.reply }
    public var intents: [DeviceIntent] { plan.intents }

    public init(plan: IntentPlan, attemptedCount: Int, succeededCount: Int, failedCount: Int, errorMessage: String? = nil, skipReason: AutomationSkipReason? = nil) {
        self.plan = plan
        self.attemptedCount = attemptedCount
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.errorMessage = errorMessage
        self.skipReason = skipReason
    }
}

extension HomeStore {
    public var automationRuleStore: AutomationRuleStore {
        AutomationRuleStore(defaults: userDefaults)
    }

    public var eventAutomationEnabled: Bool {
        capabilitySelection.enabledFeatures.contains(.eventAutomation)
    }

    @discardableResult
    public func setEventAutomationEnabled(_ enabled: Bool) -> Bool {
        guard enabled != eventAutomationEnabled else { return true }
        guard !isIdentityUncertain else {
            showToast(
                L10n.tr(
                    "仍无法读取历史配置或凭据，请检查钥匙串授权后重试",
                    "Still unable to read settings or credentials; check Keychain access and try again"
                ),
                isError: true
            )
            return false
        }
        let previous = capabilitySelection
        if enabled {
            capabilitySelection.enabledFeatures.insert(.eventAutomation)
        } else {
            capabilitySelection.enabledFeatures.remove(.eventAutomation)
        }
        guard persistCapabilitySelection() else {
            capabilitySelection = previous
            showToast(L10n.tr("无法保存自动化开关状态，请重试", "Could not save the automation switch; try again"), isError: true)
            return false
        }
        automationAvailabilityDidChange()
        return true
    }

    func automationAvailabilityDidChange() {
        guard reconciledAutomationGeneration != automationGeneration else { return }
        reconciledAutomationGeneration = automationGeneration
        if eventAutomationEnabled, !isIdentityUncertain {
            let ruleStore = automationRuleStore
            var rules = ruleStore.load()
            var changed = false
            for index in rules.indices where rules[index].isEnabled {
                let rule = rules[index]
                if !automationTargetsAreAvailable(rule.action)
                    || (!rule.highRiskApproved && rule.highRiskConfirmation(devices: devices) != nil) {
                    rules[index].isEnabled = false
                    changed = true
                }
            }
            if changed { ruleStore.save(rules) }
        }
        onAutomationRulesChanged?()
    }

    private func automationTargetsAreAvailable(_ action: AutomationAction) -> Bool {
        switch action {
        case .scene(let id):
            return visibleScenes.contains { $0.id == id } && evaluateSceneControlGate(sceneId: id).allowed
        case .devices(let ids, let turnOn):
            return !deviceValuesAreStale && !ids.isEmpty && ids.allSatisfy { id in
                devices.contains {
                    $0.id == id && $0.isOnline && capabilityWriteRejection(for: $0) == nil
                        && IntentDeviceCategory($0).isAssistantControllable
                        && Self.assistantEffect(of: .power(turnOn), on: $0) != nil
                }
            }
        case .quickAction(let action):
            let categories = QuickActionReferenceKind(rawValue: action.rawValue)?.targetCategories ?? []
            return !deviceValuesAreStale && !pausedQuickActionIDs.contains(action.rawValue)
                && categories.allSatisfy(capabilitySelection.enabledCategories.contains)
                && devices.contains { $0.isOnline && isAutomationQuickActionTarget($0, action: action) }
        }
    }

    private func isAutomationQuickActionTarget(_ device: SmartDevice, action: QuickAction) -> Bool {
        guard capabilityWriteRejection(for: device) == nil else { return false }
        switch (action, device.kind) {
        case (.lightsOff, .light(let spec)): return spec.powerWritable
        case (.softNightLight, .light(let spec)): return spec.brightnessWritable && spec.colorWritable
        case (.climateSleepOff, .climate(let spec)): return spec.powerWritable
        case (.climateSleepOff, .fan(let spec)): return spec.powerWritable
        default: return false
        }
    }

    public func automationQuickActionSkipReason(_ action: QuickAction) -> AutomationSkipReason {
        if automationTargetsAreAvailable(.quickAction(action)) { return .noActionNeeded }
        if devices.contains(where: { !$0.isOnline && isAutomationQuickActionTarget($0, action: action) }) {
            return .deviceOffline
        }
        return .writeGateDenied
    }

    func automationCanWrite(generation: UInt64) -> Bool {
        eventAutomationEnabled && automationGeneration == generation
    }

    @discardableResult
    public func runAutomationQuickAction(
        _ action: QuickAction,
        canContinue: (() -> Bool)? = nil,
        onWrite: ((Bool) -> Void)? = nil
    ) -> Task<BulkWriteOutcome, Never>? {
        guard eventAutomationEnabled else { return nil }
        return executeQuickAction(
            action, undoBannerDuration: AutomationPolicy.undoWindow, recordsHabits: false,
            respectScreenLock: false, automationGeneration: automationGeneration,
            automationCanContinue: canContinue, onAutomationWrite: onWrite
        )
    }

    /// Devices an external entry point may toggle: visible, online, and able to react to a single
    /// primary click. Used by App Intents (#57) so Shortcuts/Siri only offer actions that work.
    public var controllableDevices: [SmartDevice] {
        devices.filter {
            $0.isPrimaryToggleable
                && $0.isOnline
                && !hiddenDeviceIds.contains($0.id)
                && capabilityWriteRejection(for: $0) == nil
        }
    }

    /// Scenes an external entry point may list and trigger: empty when Home Assistant is turned off
    /// outside demo mode.
    public var visibleScenes: [HomeScene] {
        scenes.filter { homeBackend == .demo || evaluateSceneControlGate(sceneId: $0.id).allowed }
    }

    /// Runs one automation rule through the same optimistic-update, dispatch, rollback, and undo
    /// path as the panel and the assistant.
    ///
    /// `origin: .automation` deliberately records no habit-memory entry (#34) and keeps the undo
    /// banner up for `AutomationPolicy.undoWindow`, because a lock/sleep rule usually fires while
    /// the panel is closed. Demo mode uses `DemoHomeProvider`, which applies commands to an
    /// in-memory home only — nothing is sent over the network (#47).
    @discardableResult
    public func runAutomation(
        intents: [DeviceIntent],
        title: String,
        shouldSkipIntent: ((DeviceIntent) -> Bool)? = nil,
        canContinue: (() -> Bool)? = nil
    ) async -> AutomationExecutionOutcome {
        let plan = IntentPlan(intents: intents, reply: title, source: .local)
        let generation = automationGeneration
        guard !intents.isEmpty else {
            return AutomationExecutionOutcome(
                plan: plan, attemptedCount: 0, succeededCount: 0, failedCount: 0,
                errorMessage: L10n.tr("没有可执行的设备操作", "No matching device actions"),
                skipReason: .noActionNeeded
            )
        }
        guard automationCanWrite(generation: generation) else {
            return AutomationExecutionOutcome(
                plan: plan, attemptedCount: 0, succeededCount: 0, failedCount: 0, skipReason: .writeGateDenied
            )
        }
        if let message = firstPlanCapabilityRejectionMessage(for: intents) {
            showToast(message, isError: true)
            setAssistantState(.failed(message))
            return AutomationExecutionOutcome(
                plan: plan, attemptedCount: 0, succeededCount: 0, failedCount: 0,
                errorMessage: message, skipReason: .writeGateDenied
            )
        }
        var executed = (attempted: 0, succeeded: 0, failed: 0, offline: false)
        setAssistantState(.idle)
        let resultPlan = await MiCloudClient.$isBackgroundWrite.withValue(true) {
            await executeIntentPlan(
                plan, recordedUtterance: nil, origin: .automation, automationGeneration: generation,
                automationCanContinue: canContinue, automationShouldSkipIntent: shouldSkipIntent
            ) { attempted, succeeded, failed, offline in
                executed = (attempted, succeeded, failed, offline)
            }
        }
        let errorMessage = if case .failed(let message) = assistantState { message } else { nil as String? }
        let skipReason: AutomationSkipReason?
        if executed.succeeded > 0 {
            skipReason = nil
        } else if executed.offline {
            skipReason = .deviceOffline
        } else if !automationCanWrite(generation: generation) {
            skipReason = .writeGateDenied
        } else {
            skipReason = .error
        }
        return AutomationExecutionOutcome(
            plan: resultPlan, attemptedCount: executed.attempted,
            succeededCount: executed.succeeded, failedCount: executed.failed,
            errorMessage: errorMessage, skipReason: skipReason
        )
    }
}
