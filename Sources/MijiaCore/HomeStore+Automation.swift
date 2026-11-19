import Foundation

public struct AutomationExecutionOutcome: Equatable, Sendable {
    public let plan: IntentPlan
    public let attemptedCount: Int
    public let succeededCount: Int
    public let failedCount: Int
    public let errorMessage: String?

    public var reply: String { plan.reply }
    public var intents: [DeviceIntent] { plan.intents }

    public init(plan: IntentPlan, attemptedCount: Int, succeededCount: Int, failedCount: Int, errorMessage: String? = nil) {
        self.plan = plan
        self.attemptedCount = attemptedCount
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.errorMessage = errorMessage
    }
}

extension HomeStore {
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
        (homeBackend == .demo || isHAConnectionEnabled) ? scenes : []
    }

    /// Runs one automation rule through the same optimistic-update, dispatch, rollback, and undo
    /// path as the panel and the assistant.
    ///
    /// `origin: .automation` deliberately records no habit-memory entry (#34) and keeps the undo
    /// banner up for `AutomationPolicy.undoWindow`, because a lock/sleep rule usually fires while
    /// the panel is closed. Demo mode uses `DemoHomeProvider`, which applies commands to an
    /// in-memory home only — nothing is sent over the network (#47).
    @discardableResult
    public func runAutomation(intents: [DeviceIntent], title: String) async -> AutomationExecutionOutcome {
        let plan = IntentPlan(intents: intents, reply: title, source: .local)
        guard !intents.isEmpty else {
            return AutomationExecutionOutcome(
                plan: plan, attemptedCount: 0, succeededCount: 0, failedCount: 0,
                errorMessage: L10n.tr("没有可执行的设备操作", "No matching device actions")
            )
        }
        let offlineTargetNames = intents.compactMap { intent -> String? in
            guard intent.operation != .activateScene,
                  let dev = devices.first(where: { $0.id == intent.targetId }),
                  !dev.isOnline else { return nil }
            return dev.name
        }
        let previousBannerId = undoBanner?.id
        setAssistantState(.idle)
        let resultPlan = await executeIntentPlan(plan, recordedUtterance: nil, origin: .automation)
        let newBanner = (undoBanner?.id != previousBannerId) ? undoBanner : nil

        switch assistantState {
        case .failed(let message):
            if let newBanner, newBanner.deviceCount > 0 {
                let succeeded = newBanner.deviceCount
                let failed = max(1, intents.count - succeeded)
                return AutomationExecutionOutcome(
                    plan: resultPlan, attemptedCount: succeeded + failed,
                    succeededCount: succeeded, failedCount: failed, errorMessage: message
                )
            }
            return AutomationExecutionOutcome(
                plan: resultPlan, attemptedCount: intents.count,
                succeededCount: 0, failedCount: intents.count, errorMessage: message
            )
        case .done:
            if !offlineTargetNames.isEmpty {
                let failed = offlineTargetNames.count
                let succeeded = newBanner?.deviceCount ?? max(0, intents.count - failed)
                let sep = L10n.isEnglish ? ", " : "、"
                let reason = L10n.tr("\(offlineTargetNames.joined(separator: sep)) 当前离线", "\(offlineTargetNames.joined(separator: sep)) offline")
                return AutomationExecutionOutcome(
                    plan: resultPlan, attemptedCount: succeeded + failed,
                    succeededCount: succeeded, failedCount: failed, errorMessage: reason
                )
            }
            let succeeded = newBanner?.deviceCount ?? intents.count
            return AutomationExecutionOutcome(
                plan: resultPlan, attemptedCount: intents.count, succeededCount: succeeded, failedCount: 0
            )
        case .idle, .thinking, .awaitingChoice:
            let succeeded = newBanner?.deviceCount ?? 0
            return AutomationExecutionOutcome(
                plan: resultPlan, attemptedCount: intents.count,
                succeededCount: succeeded, failedCount: max(0, intents.count - succeeded)
            )
        }
    }
}
