import Foundation

public struct AssistantDiffPreviewItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let deviceName: String
    public let fromState: String
    public let toState: String
    public let isHighRisk: Bool
}

public struct AssistantDiffPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let plan: IntentPlan
    public let items: [AssistantDiffPreviewItem]
    public let utterance: String
    public let delaySeconds: TimeInterval?
    public let startedAt: Date
    public let habitSummary: String?
    public let controlContextID: UUID
    public let capabilityGeneration: Int
    public let hasHighRiskDevice: Bool
    let hazardProfiles: [String: ManualControlHazardProfile]

    public var title: String {
        hasHighRiskDevice
            ? L10n.tr("确认执行 \(items.count) 项变更（含高风险设备）", "Confirm \(items.count) change(s) (includes high-risk)")
            : L10n.tr("确认执行 \(items.count) 项设备变更", "Confirm \(items.count) device changes")
    }

    /// True when the command touches `>= 2` distinct targets or any high-risk device.
    public static func requiresPreview(
        intents: [DeviceIntent], devices: [SmartDevice], scenes: [HomeScene], markedLightIds: Set<String>
    ) -> Bool {
        guard !intents.isEmpty else { return false }
        if Set(intents.map(\.targetId)).count >= 2 { return true }
        let byId = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return intents.contains { intent in
            guard intent.operation != .activateScene, let device = byId[intent.targetId] else { return false }
            return ManualControlPolicy.requiresConfirmation(intent.operation, for: device, markedLightIds: markedLightIds)
        }
    }

    static func build(
        plan: IntentPlan, devices: [SmartDevice], scenes: [HomeScene], markedLightIds: Set<String>,
        utterance: String, delaySeconds: TimeInterval?, startedAt: Date, habitSummary: String?,
        controlContextID: UUID, capabilityGeneration: Int
    ) -> AssistantDiffPreview {
        let byId = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scenesById = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var targetOrder: [String] = [], byTarget: [String: [DeviceIntent]] = [:]
        for intent in plan.intents {
            if byTarget[intent.targetId] == nil { targetOrder.append(intent.targetId) }
            byTarget[intent.targetId, default: []].append(intent)
        }
        var items: [AssistantDiffPreviewItem] = []
        var hazardProfiles: [String: ManualControlHazardProfile] = [:]
        for targetId in targetOrder {
            let group = byTarget[targetId] ?? []
            if group.contains(where: { $0.operation == .activateScene }) {
                items.append(AssistantDiffPreviewItem(
                    id: targetId, deviceName: scenesById[targetId]?.name ?? targetId,
                    fromState: L10n.tr("场景", "Scene"), toState: L10n.tr("执行", "Run"), isHighRisk: false
                ))
                continue
            }
            guard let original = byId[targetId] else { continue }
            var projected = original, isHighRisk = false
            for intent in group {
                if ManualControlPolicy.requiresConfirmation(intent.operation, for: original, markedLightIds: markedLightIds) {
                    isHighRisk = true
                    hazardProfiles[original.id] = ManualControlHazardProfile(original)
                }
                if let effect = HomeStore.assistantEffect(of: intent.operation, on: projected) {
                    projected = effect.updated
                }
            }
            items.append(AssistantDiffPreviewItem(
                id: targetId, deviceName: original.name,
                fromState: IntentCatalog.stateSummary(original),
                toState: IntentCatalog.stateSummary(projected),
                isHighRisk: isHighRisk
            ))
        }
        return AssistantDiffPreview(
            id: UUID(), plan: plan, items: items, utterance: utterance, delaySeconds: delaySeconds,
            startedAt: startedAt, habitSummary: habitSummary, controlContextID: controlContextID,
            capabilityGeneration: capabilityGeneration, hasHighRiskDevice: items.contains(where: \.isHighRisk),
            hazardProfiles: hazardProfiles
        )
    }
}
