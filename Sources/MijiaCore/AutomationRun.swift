import Foundation

public enum AutomationExecutionMode: String, Codable, CaseIterable, Sendable {
    case single, restart

    public var title: String {
        switch self {
        case .single: L10n.tr("单次运行", "Single")
        case .restart: L10n.tr("重新开始", "Restart")
        }
    }
}

public enum AutomationSkipReason: String, Codable, CaseIterable, Sendable {
    case conditionFalse, singleAlreadyRunning, screenLocked, writeGateDenied, deviceOffline, error
    case cooldown, superseded, noActionNeeded

    public var title: String {
        switch self {
        case .conditionFalse: L10n.tr("条件未满足", "Conditions not met")
        case .singleAlreadyRunning: L10n.tr("规则正在运行", "Already running")
        case .screenLocked: L10n.tr("屏幕已锁定", "Screen locked")
        case .writeGateDenied: L10n.tr("设备控制被拒绝", "Device control denied")
        case .deviceOffline: L10n.tr("设备离线", "Device offline")
        case .error: L10n.tr("执行失败", "Execution failed")
        case .cooldown: L10n.tr("触发间隔过短", "Trigger cooldown")
        case .superseded: L10n.tr("被新运行替代", "Replaced by a newer run")
        case .noActionNeeded: L10n.tr("无需变更设备", "No device change needed")
        }
    }
}

public struct AutomationRunEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let ruleId: UUID
    public let trigger: AutomationTrigger
    public let time: Date
    public let result: Result
    public let reason: AutomationSkipReason?

    public enum Result: String, Codable, Sendable {
        case executed, skipped
    }

    init(rule: AutomationRule, at time: Date, reason: AutomationSkipReason?) {
        self.id = UUID()
        self.ruleId = rule.id
        self.trigger = rule.trigger
        self.time = time
        self.result = reason == nil ? .executed : .skipped
        self.reason = reason
    }
}

public struct AutomationRunState {
    private var current: UUID?

    public init() {}
    public var isRunning: Bool { current != nil }

    public mutating func start(_ id: UUID, mode: AutomationExecutionMode) -> Bool {
        guard !isRunning || mode == .restart else { return false }
        current = id
        return true
    }

    public func owns(_ id: UUID) -> Bool { current == id }

    public mutating func finish(_ id: UUID) {
        if owns(id) { current = nil }
    }
}

extension HomeStore {
    static let automationRunHistoryKey = "automation_run_history_v1"
    static let automationRunHistoryLimit = 200

    public func recordAutomationRun(_ rule: AutomationRule, at time: Date, reason: AutomationSkipReason?) {
        automationRunHistory.insert(AutomationRunEntry(rule: rule, at: time, reason: reason), at: 0)
        if automationRunHistory.count > Self.automationRunHistoryLimit {
            automationRunHistory.removeLast()
        }
        if let data = try? JSONEncoder().encode(automationRunHistory) {
            userDefaults.set(data, forKey: Self.automationRunHistoryKey)
        }
        scheduleRaycastSnapshotExport()
    }
}
