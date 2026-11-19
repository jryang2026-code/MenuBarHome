import Foundation

extension CapabilityID: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = CapabilityID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown CapabilityID \(raw)"))
        }
        self = id
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public enum SafetySignalKind: String, CaseIterable, Codable, Hashable, Sendable {
    case leak, smoke, gas, contact, motion, vibration, lock, doorbell
    case lowBattery, longRunningPlug, longRunningClimate, highPower, starredOffline
    public init(sensorAlertKind: SensorAlertKind) {
        switch sensorAlertKind {
        case .leak: self = .leak; case .smoke: self = .smoke; case .gas: self = .gas
        case .contact: self = .contact; case .motion: self = .motion
        }
    }
}

public enum CapabilityInstallResolutionMode: String, CaseIterable, Codable, Hashable, Sendable {
    case explicit, legacyPreserved, freshInstall, uncertainFallback
}

public struct CapabilitySelection: Codable, Equatable, Sendable {
    public var enabledConnections: Set<ConnectionCapabilityID>, enabledConnectionScopes: Set<String>
    public var enabledFeatures: Set<FeatureID>, enabledCategories: Set<DeviceCategoryID>
    public init(
        enabledConnections: Set<ConnectionCapabilityID>, enabledConnectionScopes: Set<String>,
        enabledFeatures: Set<FeatureID>, enabledCategories: Set<DeviceCategoryID>
    ) {
        self.enabledConnections = enabledConnections; self.enabledConnectionScopes = enabledConnectionScopes
        self.enabledFeatures = enabledFeatures; self.enabledCategories = enabledCategories
    }
    public var hasDisabledDeviceCategories: Bool { enabledCategories.count < DeviceCategoryID.allCases.count }
    public func contains(_ id: CapabilityID) -> Bool {
        switch id { case .connection(let c): enabledConnections.contains(c); case .feature(let f): enabledFeatures.contains(f); case .deviceCategory(let d): enabledCategories.contains(d) }
    }
    public mutating func remove(_ id: CapabilityID) {
        switch id { case .connection(let c): enabledConnections.remove(c); case .feature(let f): enabledFeatures.remove(f); case .deviceCategory(let d): enabledCategories.remove(d) }
    }
    public func normalized(with manifest: CapabilityManifest) -> CapabilitySelection {
        var res = self, changed = true
        while changed {
            changed = false
            for e in manifest.entries where res.contains(e.id) && e.dependsOn.contains(where: { !res.contains($0) }) { res.remove(e.id); changed = true }
        }
        return res
    }
    public func isSourceEnabled(connection: ConnectionCapabilityID?, scope: String) -> Bool {
        guard let resolved = connection ?? CapabilityReferenceEngine.connectionCapability(forScope: scope) else { return true }
        return enabledConnections.contains(resolved) && enabledConnectionScopes.contains(scope)
    }
}

public struct CapabilityInstallEvidence: Decodable, Equatable, Sendable {
    public var explicitSelection: CapabilitySelection?, hasLegacySettingsOrOnboarding: Bool
    public var configuredConnectionScopes: [String], hasPersistedLocalData: Bool
    public var legacyFeatureFlags: [FeatureID: Bool], identityReadFailure: String?
    private enum CodingKeys: String, CodingKey {
        case explicitSelection, hasLegacySettingsOrOnboarding, configuredConnectionScopes, hasPersistedLocalData, legacyFeatureFlags, identityReadFailure
    }
    public init(
        explicitSelection: CapabilitySelection? = nil, hasLegacySettingsOrOnboarding: Bool = false,
        configuredConnectionScopes: [String] = [], hasPersistedLocalData: Bool = false,
        legacyFeatureFlags: [FeatureID: Bool] = [:], identityReadFailure: String? = nil
    ) {
        self.explicitSelection = explicitSelection; self.hasLegacySettingsOrOnboarding = hasLegacySettingsOrOnboarding
        self.configuredConnectionScopes = configuredConnectionScopes; self.hasPersistedLocalData = hasPersistedLocalData
        self.legacyFeatureFlags = legacyFeatureFlags; self.identityReadFailure = identityReadFailure
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        explicitSelection = try c.decodeIfPresent(CapabilitySelection.self, forKey: .explicitSelection)
        hasLegacySettingsOrOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasLegacySettingsOrOnboarding) ?? false
        configuredConnectionScopes = try c.decodeIfPresent([String].self, forKey: .configuredConnectionScopes) ?? []
        hasPersistedLocalData = try c.decodeIfPresent(Bool.self, forKey: .hasPersistedLocalData) ?? false
        let raw = try c.decodeIfPresent([String: Bool].self, forKey: .legacyFeatureFlags) ?? [:]
        legacyFeatureFlags = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in FeatureID(rawValue: k).map { ($0, v) } })
        identityReadFailure = try c.decodeIfPresent(String.self, forKey: .identityReadFailure)
    }
}

public struct CapabilityInstallResolution: Equatable, Sendable {
    public let mode: CapabilityInstallResolutionMode, selection: CapabilitySelection, persistMigrationComplete: Bool, retryDiagnostic: String?
}

public struct CapabilityIndexedDevice: Codable, Equatable, Sendable {
    public let id: String, name: String, category: DeviceCategoryID, connection: ConnectionCapabilityID?, sourceScope: String
    public let isSourceAvailable: Bool, upstreamHiddenOrDisabled: Bool, participatesInAllOff: Bool
    public let safetySignals: Set<SafetySignalKind>, readKeys: [String], safetyReadKeys: [String]
    private enum CodingKeys: String, CodingKey {
        case id, name, category, connection, sourceScope
        case isSourceAvailable, upstreamHiddenOrDisabled, participatesInAllOff
        case safetySignals, readKeys, safetyReadKeys
    }
    public init(
        id: String, name: String, category: DeviceCategoryID, connection: ConnectionCapabilityID?, sourceScope: String,
        isSourceAvailable: Bool, upstreamHiddenOrDisabled: Bool, participatesInAllOff: Bool,
        safetySignals: Set<SafetySignalKind>, readKeys: [String], safetyReadKeys: [String]
    ) {
        self.id = id; self.name = name; self.category = category; self.connection = connection; self.sourceScope = sourceScope
        self.isSourceAvailable = isSourceAvailable; self.upstreamHiddenOrDisabled = upstreamHiddenOrDisabled
        self.participatesInAllOff = participatesInAllOff; self.safetySignals = safetySignals
        self.readKeys = readKeys; self.safetyReadKeys = safetyReadKeys
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.connection) else {
            throw DecodingError.keyNotFound(CodingKeys.connection, .init(codingPath: c.codingPath, debugDescription: "Missing required key connection"))
        }
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(DeviceCategoryID.self, forKey: .category)
        connection = try c.decodeIfPresent(ConnectionCapabilityID.self, forKey: .connection)
        sourceScope = try c.decode(String.self, forKey: .sourceScope)
        isSourceAvailable = try c.decode(Bool.self, forKey: .isSourceAvailable)
        upstreamHiddenOrDisabled = try c.decode(Bool.self, forKey: .upstreamHiddenOrDisabled)
        participatesInAllOff = try c.decode(Bool.self, forKey: .participatesInAllOff)
        safetySignals = try c.decode(Set<SafetySignalKind>.self, forKey: .safetySignals)
        readKeys = try c.decode([String].self, forKey: .readKeys)
        safetyReadKeys = try c.decode([String].self, forKey: .safetyReadKeys)
        if id.isEmpty || name.isEmpty || sourceScope.isEmpty {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Empty required string in CapabilityIndexedDevice"))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(category, forKey: .category)
        if let connection { try c.encode(connection, forKey: .connection) } else { try c.encodeNil(forKey: .connection) }
        try c.encode(sourceScope, forKey: .sourceScope); try c.encode(isSourceAvailable, forKey: .isSourceAvailable)
        try c.encode(upstreamHiddenOrDisabled, forKey: .upstreamHiddenOrDisabled); try c.encode(participatesInAllOff, forKey: .participatesInAllOff)
        try c.encode(safetySignals, forKey: .safetySignals); try c.encode(readKeys, forKey: .readKeys); try c.encode(safetyReadKeys, forKey: .safetyReadKeys)
    }
}

public struct SafetyRetentionPolicy: Codable, Equatable, Sendable {
    public var enabledSignals: Set<SafetySignalKind>, starredDeviceIds: Set<String>
    public init(enabledSignals: Set<SafetySignalKind> = [], starredDeviceIds: Set<String> = []) {
        self.enabledSignals = enabledSignals; self.starredDeviceIds = starredDeviceIds
    }
}

public struct DeviceSetPartition: Codable, Equatable, Sendable {
    public let availableDeviceIds: [String], hiddenSafetyRetainedDeviceIds: [String]
    public let safetyEvaluationDeviceIds: [String], readPlanKeys: [String], showsHiddenSafetyNotice: Bool
}

public enum TimerPartition: String, CaseIterable, Codable, Hashable, Sendable { case waiting, missed, foreign }
public enum QuickActionReferenceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case lightsOff, softNightLight, climateSleepOff, deviceGroup
    public var targetCategories: Set<DeviceCategoryID> {
        switch self { case .lightsOff, .softNightLight: [.light]; case .climateSleepOff: [.climate, .fan]; case .deviceGroup: [] }
    }
}

public struct TimerReference: Codable, Equatable, Sendable {
    public let id: String, name: String, partition: TimerPartition, targetIds: [String], sourceScopes: [String]
    public let allTargetsLGLan: Bool, pausedCapabilities: [CapabilityID]
    private enum CodingKeys: String, CodingKey { case id, name, partition, targetIds, sourceScopes, allTargetsLGLan, pausedCapabilities }
    public init(
        id: String, name: String, partition: TimerPartition, targetIds: [String],
        sourceScopes: [String], allTargetsLGLan: Bool = false, pausedCapabilities: [CapabilityID] = []
    ) {
        self.id = id; self.name = name; self.partition = partition; self.targetIds = targetIds
        self.sourceScopes = sourceScopes; self.allTargetsLGLan = allTargetsLGLan; self.pausedCapabilities = pausedCapabilities
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        partition = try c.decode(TimerPartition.self, forKey: .partition)
        targetIds = try c.decode([String].self, forKey: .targetIds); sourceScopes = try c.decode([String].self, forKey: .sourceScopes)
        allTargetsLGLan = try c.decodeIfPresent(Bool.self, forKey: .allTargetsLGLan) ?? false
        pausedCapabilities = try c.decodeIfPresent([CapabilityID].self, forKey: .pausedCapabilities) ?? []
    }
}

public enum AutomationReferenceAction: Decodable, Equatable, Sendable {
    case devices([String]), quickAction(QuickActionReferenceKind), dynamicAllOff, scene(String)
    private enum CodingKeys: String, CodingKey { case kind, targetIds, quickAction, sceneId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "devices": self = .devices(try c.decode([String].self, forKey: .targetIds))
        case "quickAction": self = .quickAction(try c.decode(QuickActionReferenceKind.self, forKey: .quickAction))
        case "dynamicAllOff": self = .dynamicAllOff
        case "scene": self = .scene(try c.decode(String.self, forKey: .sceneId))
        case let other: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown action \(other)"))
        }
    }
}

public struct AutomationReference: Decodable, Equatable, Sendable {
    public let id: String, name: String, isEnabled: Bool, action: AutomationReferenceAction, sourceScopes: [String]
    public init(id: String, name: String, isEnabled: Bool, action: AutomationReferenceAction, sourceScopes: [String] = []) {
        self.id = id; self.name = name; self.isEnabled = isEnabled; self.action = action; self.sourceScopes = sourceScopes
    }
}

public struct QuickActionReference: Codable, Equatable, Sendable {
    public let id: String, name: String, kind: QuickActionReferenceKind, targetIds: [String], isEnabled: Bool
    public init(id: String, name: String, kind: QuickActionReferenceKind, targetIds: [String] = [], isEnabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.targetIds = targetIds; self.isEnabled = isEnabled
    }
}

public struct SceneReference: Codable, Equatable, Sendable {
    public let id: String, name: String, connection: ConnectionCapabilityID?, sourceScope: String, isSourceAvailable: Bool
    public init(id: String, name: String, connection: ConnectionCapabilityID?, sourceScope: String, isSourceAvailable: Bool) {
        self.id = id; self.name = name; self.connection = connection; self.sourceScope = sourceScope; self.isSourceAvailable = isSourceAvailable
    }
}

public struct DeviceGroupReference: Codable, Equatable, Sendable {
    public let id: String, name: String, memberDeviceIds: [String]
    public init(id: String, name: String, memberDeviceIds: [String]) { self.id = id; self.name = name; self.memberDeviceIds = memberDeviceIds }
}

public struct PreferenceReferenceSet: Codable, Equatable, Sendable {
    public var favoriteDeviceIds: [String], aliasDeviceIds: [String], customOrderDeviceIds: [String]
    public var menuBarTargetDeviceIds: [String], pinnedSourceDeviceIds: [String], cameraPreferenceDeviceIds: [String]
    public init(
        favoriteDeviceIds: [String] = [], aliasDeviceIds: [String] = [], customOrderDeviceIds: [String] = [],
        menuBarTargetDeviceIds: [String] = [], pinnedSourceDeviceIds: [String] = [], cameraPreferenceDeviceIds: [String] = []
    ) {
        self.favoriteDeviceIds = favoriteDeviceIds; self.aliasDeviceIds = aliasDeviceIds; self.customOrderDeviceIds = customOrderDeviceIds
        self.menuBarTargetDeviceIds = menuBarTargetDeviceIds; self.pinnedSourceDeviceIds = pinnedSourceDeviceIds; self.cameraPreferenceDeviceIds = cameraPreferenceDeviceIds
    }
    public static func fromUserDefaults(_ defaults: UserDefaults) -> PreferenceReferenceSet {
        PreferenceReferenceSet(favoriteDeviceIds: DevicePreferenceIndex.referencedIDs(defaults: defaults).sorted())
    }
    public var allDeviceIds: Set<String> {
        Set(favoriteDeviceIds + aliasDeviceIds + customOrderDeviceIds + menuBarTargetDeviceIds + pinnedSourceDeviceIds + cameraPreferenceDeviceIds)
    }
}

public struct CapabilityReferenceGraph: Decodable, Equatable, Sendable {
    public var timers: [TimerReference], automations: [AutomationReference], quickActions: [QuickActionReference]
    public var scenes: [SceneReference], deviceGroups: [DeviceGroupReference], preferences: PreferenceReferenceSet
    public var corruptedStoreReasons: [String], expectedGeneration: Int?, currentGeneration: Int?
    public init(
        timers: [TimerReference] = [], automations: [AutomationReference] = [], quickActions: [QuickActionReference] = [],
        scenes: [SceneReference] = [], deviceGroups: [DeviceGroupReference] = [], preferences: PreferenceReferenceSet = .init(),
        corruptedStoreReasons: [String] = [], expectedGeneration: Int? = nil, currentGeneration: Int? = nil
    ) {
        self.timers = timers; self.automations = automations; self.quickActions = quickActions
        self.scenes = scenes; self.deviceGroups = deviceGroups; self.preferences = preferences
        self.corruptedStoreReasons = corruptedStoreReasons; self.expectedGeneration = expectedGeneration; self.currentGeneration = currentGeneration
    }
}

public enum DeactivationDisposition: String, CaseIterable, Codable, Hashable, Sendable { case allowed, requiresPauseConfirmation, blocked }
public enum AffectedReferenceKind: String, CaseIterable, Codable, Hashable, Sendable { case waitingTimer, missedTimer, foreignTimer, automationRule, quickAction }
public struct AffectedReferenceItem: Codable, Equatable, Sendable {
    public let kind: AffectedReferenceKind, id: String, name: String, connectionScopes: [String], affectedTargetIds: [String], affectedCapabilities: [CapabilityID]
    /// Stable identity of one previewed item, so a confirmation can name exactly the list it showed.
    public var pauseKey: String { "\(kind.rawValue):\(id)" }
}

public enum CapabilitySoftNoticeKind: String, CaseIterable, Codable, Hashable, Sendable {
    case manualScenesMayControlHiddenDevices, preferencesPreserved, safetyReadsRetained, dependentCapabilitiesCascaded
    public var userMessage: String {
        switch self {
        case .manualScenesMayControlHiddenDevices: L10n.tr("平台场景和脚本仍可手动启动，可能控制已隐藏的设备", "Platform scenes and scripts remain manually available and may control hidden devices")
        case .preferencesPreserved: L10n.tr("收藏、别名、排序与固定来源已保留，重新开启后按原 ID 恢复", "Favorites, aliases, sort order, and pinned sources are preserved and will restore by ID")
        case .safetyReadsRetained: L10n.tr("为了继续提供已开启的安全提醒，仍会读取部分隐藏设备", "Some hidden devices are still read to keep enabled safety alerts active")
        case .dependentCapabilitiesCascaded: L10n.tr("关联子功能将一并关闭", "Dependent capabilities will also be turned off")
        }
    }
}
public struct CapabilitySoftNotice: Codable, Equatable, Sendable {
    public let kind: CapabilitySoftNoticeKind, affectedIds: [String]
    public var userMessage: String { kind.userMessage }
}

public enum CapabilityBlockingReasonKind: String, CaseIterable, Codable, Hashable, Sendable {
    case unresolvedReferenceOwnership, corruptedReferenceStore, stalePreviewGeneration
}
public struct CapabilityBlockingReason: Codable, Equatable, Sendable {
    public let kind: CapabilityBlockingReasonKind, referenceId: String, detail: String
}

public struct CapabilityDeactivationVerdict: Equatable, Sendable {
    public let disposition: DeactivationDisposition, cascadedCapabilities: [CapabilityID], itemsToPause: [AffectedReferenceItem]
    public let softNotices: [CapabilitySoftNotice], blockingReasons: [CapabilityBlockingReason]
    public let preservedPreferenceDeviceIds: [String], partition: DeviceSetPartition
    public var canDeactivate: Bool { disposition != .blocked }
    public var requiresPauseConfirmation: Bool { disposition == .requiresPauseConfirmation }
}

public enum ControlTargetKind: String, CaseIterable, Codable, Hashable, Sendable { case device, scene }
public enum ControlTargetRejectionReason: Equatable, Sendable {
    case categoryDisabled(DeviceCategoryID), deviceNotFound, sceneNotFound
    case connectionDisabled(ConnectionCapabilityID?, scope: String)
    case connectionScopeDisabled(ConnectionCapabilityID?, scope: String)
    case connectionUnavailable(ConnectionCapabilityID?, scope: String)
    case ambiguousTarget, staleGeneration
    public var code: String {
        switch self {
        case .categoryDisabled: "categoryDisabled"; case .deviceNotFound: "deviceNotFound"; case .sceneNotFound: "sceneNotFound"
        case .connectionDisabled: "connectionDisabled"; case .connectionScopeDisabled: "connectionScopeDisabled"
        case .connectionUnavailable: "connectionUnavailable"; case .ambiguousTarget: "ambiguousTarget"; case .staleGeneration: "staleGeneration"
        }
    }
    public var userMessage: String {
        switch self {
        case .categoryDisabled: L10n.tr("该设备类型已关闭", "This device category is turned off")
        case .deviceNotFound: L10n.tr("设备不存在", "Device not found")
        case .sceneNotFound: L10n.tr("场景不存在", "Scene not found")
        case .connectionDisabled(.xiaomiCloud, _): L10n.tr("米家已停用", "Xiaomi Home is turned off")
        case .connectionDisabled(.homeAssistant, _): L10n.tr("Home Assistant 已停用", "Home Assistant is turned off")
        case .connectionDisabled(nil, _): L10n.tr("该连接已停用", "This connection is turned off")
        case .connectionScopeDisabled(.xiaomiCloud, _): L10n.tr("该米家账号已停用", "This Xiaomi account is turned off")
        case .connectionScopeDisabled(.homeAssistant, _): L10n.tr("该 Home Assistant 连接已停用", "This Home Assistant connection is turned off")
        case .connectionScopeDisabled(nil, _): L10n.tr("该连接来源已停用", "This connection source is turned off")
        case .connectionUnavailable(.xiaomiCloud, _): L10n.tr("米家暂不可用，部分设备暂无数据", "Xiaomi Home is temporarily unavailable")
        case .connectionUnavailable(.homeAssistant, _): L10n.tr("Home Assistant 暂不可用，部分设备暂无数据", "Home Assistant is temporarily unavailable")
        case .connectionUnavailable(nil, _): L10n.tr("该连接暂不可用", "This connection is temporarily unavailable")
        case .ambiguousTarget: L10n.tr("目标存在重名或跨源冲突，请明确指定设备", "Target is ambiguous across devices or sources")
        case .staleGeneration: L10n.tr("状态已变化，请刷新后重试", "State changed; refresh and try again")
        }
    }
}

public struct ControlTargetGateVerdict: Equatable, Sendable {
    public let allowed: Bool, writeCount: Int, rejectionReason: ControlTargetRejectionReason?, mayControlHiddenDevices: Bool
    public var manualSceneNotice: String? { mayControlHiddenDevices ? CapabilitySoftNoticeKind.manualScenesMayControlHiddenDevices.userMessage : nil }
}
public struct PlanTargetGateVerdict: Equatable, Sendable {
    public let allowed: Bool, writeCount: Int, rejectedTargetId: String?, rejectionReason: ControlTargetRejectionReason?
}
public enum PausedTimerResumeDisposition: String, CaseIterable, Codable, Hashable, Sendable {
    case armWaiting, moveToMissed, keepPaused, partitionForeign
}

public enum CapabilityReferenceEngine {
    public static func connectionCapability(forScope scope: String) -> ConnectionCapabilityID? {
        scope.hasPrefix("mi:") ? .xiaomiCloud : (scope.hasPrefix("ha:") ? .homeAssistant : nil)
    }

    public static func timerScopesMatch(stampedScopes: [String], activeConnectionScopes: Set<String>) -> Bool {
        guard stampedScopes.contains(where: activeConnectionScopes.contains) else { return false }
        return activeConnectionScopes.filter { $0.hasPrefix("ha:") }.allSatisfy(stampedScopes.contains)
    }

    public static func resolveInstallSelection(evidence: CapabilityInstallEvidence, manifest: CapabilityManifest) -> CapabilityInstallResolution {
        let failure = evidence.identityReadFailure?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = CapabilitySelection(
            enabledConnections: Set(evidence.configuredConnectionScopes.compactMap(connectionCapability(forScope:))),
            enabledConnectionScopes: Set(evidence.configuredConnectionScopes),
            enabledFeatures: Set(FeatureID.allCases.filter { evidence.legacyFeatureFlags[$0] ?? true }),
            enabledCategories: Set(DeviceCategoryID.allCases)
        ).normalized(with: manifest)
        if let failure, !failure.isEmpty {
            return .init(mode: .uncertainFallback, selection: evidence.explicitSelection?.normalized(with: manifest) ?? legacy, persistMigrationComplete: false, retryDiagnostic: failure)
        }
        if let explicit = evidence.explicitSelection {
            return .init(mode: .explicit, selection: explicit.normalized(with: manifest), persistMigrationComplete: true, retryDiagnostic: nil)
        }
        if evidence.hasLegacySettingsOrOnboarding || !evidence.configuredConnectionScopes.isEmpty || evidence.hasPersistedLocalData {
            return .init(mode: .legacyPreserved, selection: legacy, persistMigrationComplete: true, retryDiagnostic: nil)
        }
        var conns: Set<ConnectionCapabilityID> = [], feats: Set<FeatureID> = [], cats: Set<DeviceCategoryID> = []
        for e in manifest.entries where e.defaultOnFreshInstall {
            switch e.id { case .connection(let c): conns.insert(c); case .feature(let f): feats.insert(f); case .deviceCategory(let d): cats.insert(d) }
        }
        return .init(mode: .freshInstall, selection: CapabilitySelection(enabledConnections: conns, enabledConnectionScopes: [], enabledFeatures: feats, enabledCategories: cats).normalized(with: manifest), persistMigrationComplete: true, retryDiagnostic: nil)
    }

    public static func partitionDevices(devices: [CapabilityIndexedDevice], selection: CapabilitySelection, safetyPolicy: SafetyRetentionPolicy) -> DeviceSetPartition {
        var available: [String] = [], hiddenSafety: [String] = [], safetyEval: [String] = [], seen: Set<String> = [], keys: Set<String> = []
        for dev in devices where !dev.upstreamHiddenOrDisabled && selection.isSourceEnabled(connection: dev.connection, scope: dev.sourceScope) && seen.insert(dev.id).inserted {
            if selection.enabledCategories.contains(dev.category) {
                available.append(dev.id); safetyEval.append(dev.id); keys.formUnion(dev.readKeys)
            } else if dev.safetySignals.contains(where: { $0 == .starredOffline ? safetyPolicy.enabledSignals.contains(.starredOffline) && safetyPolicy.starredDeviceIds.contains(dev.id) : safetyPolicy.enabledSignals.contains($0) }) {
                hiddenSafety.append(dev.id); safetyEval.append(dev.id); keys.formUnion(dev.safetyReadKeys.isEmpty ? dev.readKeys : dev.safetyReadKeys)
            }
        }
        return .init(availableDeviceIds: available, hiddenSafetyRetainedDeviceIds: hiddenSafety, safetyEvaluationDeviceIds: safetyEval, readPlanKeys: keys.sorted(), showsHiddenSafetyNotice: !hiddenSafety.isEmpty)
    }

    public static func evaluateDeactivation(
        current: CapabilitySelection, proposed: CapabilitySelection, manifest: CapabilityManifest,
        devices: [CapabilityIndexedDevice], safetyPolicy: SafetyRetentionPolicy, references: CapabilityReferenceGraph
    ) -> CapabilityDeactivationVerdict {
        let before = current.normalized(with: manifest), after = proposed.normalized(with: manifest)
        let beforePart = partitionDevices(devices: devices, selection: before, safetyPolicy: safetyPolicy)
        let afterPart = partitionDevices(devices: devices, selection: after, safetyPolicy: safetyPolicy)
        let beforeAvail = Set(beforePart.availableDeviceIds), afterAvail = Set(afterPart.availableDeviceIds)
        let disabledCats = before.enabledCategories.subtracting(after.enabledCategories)
        let disabledFeats = before.enabledFeatures.subtracting(after.enabledFeatures)
        let cascaded = reverseDependencyOrder(manifest: manifest).filter { before.contains($0) && !after.contains($0) }
        let autoChildren = cascaded.filter { proposed.contains($0) && !after.contains($0) }

        let devById = Dictionary(devices.filter { !$0.upstreamHiddenOrDisabled }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sceneById = Dictionary(references.scenes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groupById = Dictionary(references.deviceGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let expand = { (ids: [String]) in ids.flatMap { groupById[$0]?.memberDeviceIds ?? [$0] } }

        var blocking: [CapabilityBlockingReason] = []
        if let exp = references.expectedGeneration, let cur = references.currentGeneration, exp != cur {
            blocking.append(.init(kind: .stalePreviewGeneration, referenceId: "generation", detail: "\(exp)!=\(cur)"))
        }
        for store in references.corruptedStoreReasons { blocking.append(.init(kind: .corruptedReferenceStore, referenceId: store, detail: store)) }

        var items: [AffectedReferenceItem] = [], seenItems: Set<String> = []
        func addItem(_ kind: AffectedReferenceKind, id: String, name: String, scopes: [String], targets: [String], caps: [CapabilityID]) {
            guard seenItems.insert("\(kind.rawValue):\(id)").inserted else { return }
            items.append(.init(kind: kind, id: id, name: name, connectionScopes: Array(Set(scopes)).sorted(), affectedTargetIds: Array(Set(targets)).sorted(), affectedCapabilities: Array(Set(caps)).sorted { $0.rawValue < $1.rawValue }))
        }
        func inspect(refId: String, rawIds: [String], scopes: [String]) -> (scopes: [String], targets: [String], caps: [CapabilityID], blocked: Bool) {
            var hs: [String] = [], ht: [String] = [], hc: [CapabilityID] = []
            for tid in expand(rawIds) {
                if let d = devById[tid] {
                    let sLost = before.isSourceEnabled(connection: d.connection, scope: d.sourceScope) && !after.isSourceEnabled(connection: d.connection, scope: d.sourceScope)
                    let cLost = before.enabledCategories.contains(d.category) && !after.enabledCategories.contains(d.category)
                    if sLost || cLost {
                        hs.append(d.sourceScope); ht.append(tid)
                        if sLost, let c = d.connection ?? connectionCapability(forScope: d.sourceScope) { hc.append(.connection(c)) }
                        if cLost { hc.append(.deviceCategory(d.category)) }
                    }
                } else if let sc = sceneById[tid] {
                    if before.isSourceEnabled(connection: sc.connection, scope: sc.sourceScope) && !after.isSourceEnabled(connection: sc.connection, scope: sc.sourceScope) {
                        hs.append(sc.sourceScope); ht.append(tid)
                        if let c = sc.connection ?? connectionCapability(forScope: sc.sourceScope) { hc.append(.connection(c)) }
                    }
                } else {
                    let lostScopes = scopes.filter { before.isSourceEnabled(connection: nil, scope: $0) && !after.isSourceEnabled(connection: nil, scope: $0) }
                    if !lostScopes.isEmpty {
                        if scopes.filter({ after.isSourceEnabled(connection: nil, scope: $0) }).isEmpty {
                            hs.append(contentsOf: lostScopes); ht.append(tid)
                            hc.append(contentsOf: lostScopes.compactMap(connectionCapability(forScope:)).map(CapabilityID.connection))
                        } else {
                            blocking.append(.init(kind: .unresolvedReferenceOwnership, referenceId: refId, detail: tid))
                            return ([], [], [], true)
                        }
                    }
                }
            }
            return (hs, ht, hc, false)
        }
        func lostCaps(for ids: [String]) -> [CapabilityID] {
            ids.compactMap { devById[$0] }.flatMap { d -> [CapabilityID] in
                var c: [CapabilityID] = []
                if !after.isSourceEnabled(connection: d.connection, scope: d.sourceScope), let conn = d.connection ?? connectionCapability(forScope: d.sourceScope) { c.append(.connection(conn)) }
                if disabledCats.contains(d.category) { c.append(.deviceCategory(d.category)) }
                return c
            }
        }

        for t in references.timers {
            let kind: AffectedReferenceKind = switch t.partition { case .waiting: .waitingTimer; case .missed: .missedTimer; case .foreign: .foreignTimer }
            if t.allTargetsLGLan {
                let lostLG = expand(t.targetIds).filter { (beforeAvail.contains($0) && !afterAvail.contains($0)) || (disabledCats.contains(.tv) && devById[$0] == nil) }
                if !lostLG.isEmpty {
                    addItem(kind, id: t.id, name: t.name, scopes: t.sourceScopes, targets: lostLG, caps: lostCaps(for: lostLG) + (disabledCats.contains(.tv) ? [.deviceCategory(.tv)] : []))
                }
                continue
            }
            let r = inspect(refId: t.id, rawIds: t.targetIds, scopes: t.sourceScopes)
            if !r.blocked && !r.targets.isEmpty { addItem(kind, id: t.id, name: t.name, scopes: r.scopes.isEmpty ? t.sourceScopes : r.scopes, targets: r.targets, caps: r.caps) }
        }
        for r in references.automations where r.isEnabled {
            if disabledFeats.contains(.eventAutomation) { addItem(.automationRule, id: r.id, name: r.name, scopes: r.sourceScopes, targets: [], caps: [.feature(.eventAutomation)]); continue }
            switch r.action {
            case .devices(let ids):
                let res = inspect(refId: r.id, rawIds: ids, scopes: r.sourceScopes)
                if !res.blocked && !res.targets.isEmpty { addItem(.automationRule, id: r.id, name: r.name, scopes: res.scopes, targets: res.targets, caps: res.caps) }
            case .scene(let sid):
                let res = inspect(refId: r.id, rawIds: [sid], scopes: r.sourceScopes)
                if !res.blocked && !res.targets.isEmpty { addItem(.automationRule, id: r.id, name: r.name, scopes: res.scopes, targets: res.targets, caps: res.caps) }
            case .quickAction(let qk):
                let cats = qk.targetCategories
                let lost = Array(beforeAvail.subtracting(afterAvail)).filter { devById[$0].map { cats.contains($0.category) } ?? false }
                let catOff = cats.intersection(disabledCats).map(CapabilityID.deviceCategory)
                if !lost.isEmpty || !catOff.isEmpty { addItem(.automationRule, id: r.id, name: r.name, scopes: lost.compactMap { devById[$0]?.sourceScope }, targets: lost, caps: lostCaps(for: lost) + catOff) }
            case .dynamicAllOff:
                let lost = Array(beforeAvail.subtracting(afterAvail)).filter { devById[$0]?.participatesInAllOff == true }
                if !lost.isEmpty { addItem(.automationRule, id: r.id, name: r.name, scopes: lost.compactMap { devById[$0]?.sourceScope }, targets: lost, caps: lostCaps(for: lost)) }
            }
        }
        for qa in references.quickActions where qa.isEnabled {
            if !qa.targetIds.isEmpty {
                let res = inspect(refId: qa.id, rawIds: qa.targetIds, scopes: [])
                if !res.blocked && !res.targets.isEmpty { addItem(.quickAction, id: qa.id, name: qa.name, scopes: res.scopes, targets: res.targets, caps: res.caps) }
            } else {
                let cats = qa.kind.targetCategories
                let prev = beforePart.availableDeviceIds.filter { devById[$0].map { cats.contains($0.category) } ?? false }
                let rem = afterPart.availableDeviceIds.filter { devById[$0].map { cats.contains($0.category) } ?? false }
                let catOff = cats.intersection(disabledCats)
                if (!prev.isEmpty && rem.isEmpty) || (!cats.isEmpty && catOff == cats) {
                    addItem(.quickAction, id: qa.id, name: qa.name, scopes: prev.compactMap { devById[$0]?.sourceScope }, targets: prev, caps: lostCaps(for: prev) + catOff.map(CapabilityID.deviceCategory))
                }
            }
        }

        let preserved = references.preferences.allDeviceIds.filter { devById[$0] != nil && !afterAvail.contains($0) }.sorted()
        var notices: [CapabilitySoftNotice] = []
        let activeScenes = references.scenes.filter { after.isSourceEnabled(connection: $0.connection, scope: $0.sourceScope) }.map(\.id)
        if !activeScenes.isEmpty && after.hasDisabledDeviceCategories { notices.append(.init(kind: .manualScenesMayControlHiddenDevices, affectedIds: activeScenes)) }
        if !preserved.isEmpty { notices.append(.init(kind: .preferencesPreserved, affectedIds: preserved)) }
        if !afterPart.hiddenSafetyRetainedDeviceIds.isEmpty { notices.append(.init(kind: .safetyReadsRetained, affectedIds: afterPart.hiddenSafetyRetainedDeviceIds)) }
        if !autoChildren.isEmpty { notices.append(.init(kind: .dependentCapabilitiesCascaded, affectedIds: autoChildren.map(\.rawValue))) }

        let disposition: DeactivationDisposition = !blocking.isEmpty ? .blocked : (!items.isEmpty ? .requiresPauseConfirmation : .allowed)
        return .init(disposition: disposition, cascadedCapabilities: cascaded, itemsToPause: items, softNotices: notices, blockingReasons: blocking, preservedPreferenceDeviceIds: preserved, partition: afterPart)
    }

    public static func evaluateControlTargetGate(
        targetKind: ControlTargetKind, targetId: String, candidateIds: [String] = [],
        expectedGeneration: Int? = nil, currentGeneration: Int? = nil,
        selection: CapabilitySelection, devices: [CapabilityIndexedDevice], scenes: [SceneReference] = []
    ) -> ControlTargetGateVerdict {
        if let exp = expectedGeneration, let cur = currentGeneration, exp != cur { return .init(allowed: false, writeCount: 0, rejectionReason: .staleGeneration, mayControlHiddenDevices: false) }
        if Set(candidateIds).count > 1 { return .init(allowed: false, writeCount: 0, rejectionReason: .ambiguousTarget, mayControlHiddenDevices: false) }
        func sourceRejection(connection: ConnectionCapabilityID?, scope: String, isAvailable: Bool) -> ControlTargetRejectionReason? {
            let conn = connection ?? connectionCapability(forScope: scope)
            if let conn, !selection.enabledConnections.contains(conn) { return .connectionDisabled(conn, scope: scope) }
            if !selection.isSourceEnabled(connection: conn, scope: scope) { return .connectionScopeDisabled(conn, scope: scope) }
            return isAvailable ? nil : .connectionUnavailable(conn, scope: scope)
        }
        switch targetKind {
        case .device:
            guard let dev = devices.first(where: { $0.id == targetId && !$0.upstreamHiddenOrDisabled }) else {
                return .init(allowed: false, writeCount: 0, rejectionReason: .deviceNotFound, mayControlHiddenDevices: false)
            }
            let conn = dev.connection ?? connectionCapability(forScope: dev.sourceScope)
            if let conn, !selection.enabledConnections.contains(conn) {
                return .init(allowed: false, writeCount: 0, rejectionReason: .connectionDisabled(conn, scope: dev.sourceScope), mayControlHiddenDevices: false)
            }
            if !selection.isSourceEnabled(connection: conn, scope: dev.sourceScope) {
                return .init(allowed: false, writeCount: 0, rejectionReason: .connectionScopeDisabled(conn, scope: dev.sourceScope), mayControlHiddenDevices: false)
            }
            if !selection.enabledCategories.contains(dev.category) {
                return .init(allowed: false, writeCount: 0, rejectionReason: .categoryDisabled(dev.category), mayControlHiddenDevices: false)
            }
            if !dev.isSourceAvailable {
                return .init(allowed: false, writeCount: 0, rejectionReason: .connectionUnavailable(conn, scope: dev.sourceScope), mayControlHiddenDevices: false)
            }
            return .init(allowed: true, writeCount: 1, rejectionReason: nil, mayControlHiddenDevices: false)
        case .scene:
            guard let sc = scenes.first(where: { $0.id == targetId }) else {
                return .init(allowed: false, writeCount: 0, rejectionReason: .sceneNotFound, mayControlHiddenDevices: false)
            }
            if let reason = sourceRejection(connection: sc.connection, scope: sc.sourceScope, isAvailable: sc.isSourceAvailable) {
                return .init(allowed: false, writeCount: 0, rejectionReason: reason, mayControlHiddenDevices: false)
            }
            return .init(allowed: true, writeCount: 1, rejectionReason: nil, mayControlHiddenDevices: selection.hasDisabledDeviceCategories)
        }
    }

    public static func evaluatePlanTargetsGate(
        targets: [(kind: ControlTargetKind, id: String)], expectedGeneration: Int? = nil, currentGeneration: Int? = nil,
        selection: CapabilitySelection, devices: [CapabilityIndexedDevice], scenes: [SceneReference] = []
    ) -> PlanTargetGateVerdict {
        for t in targets {
            let v = evaluateControlTargetGate(targetKind: t.kind, targetId: t.id, expectedGeneration: expectedGeneration, currentGeneration: currentGeneration, selection: selection, devices: devices, scenes: scenes)
            if !v.allowed { return .init(allowed: false, writeCount: 0, rejectedTargetId: t.id, rejectionReason: v.rejectionReason) }
        }
        return .init(allowed: true, writeCount: targets.count, rejectedTargetId: nil, rejectionReason: nil)
    }

    public static func revalidatePausedTimer(
        timer: TimerReference, fireAtEpochSeconds: Int, nowEpochSeconds: Int,
        activeConnectionScopes: Set<String>, selection: CapabilitySelection,
        devices: [CapabilityIndexedDevice], scenes: [SceneReference] = [], deviceGroups: [DeviceGroupReference] = []
    ) -> PausedTimerResumeDisposition {
        if !timer.allTargetsLGLan && !timerScopesMatch(stampedScopes: timer.sourceScopes, activeConnectionScopes: activeConnectionScopes) {
            return .partitionForeign
        }
        if timer.allTargetsLGLan && !selection.enabledCategories.contains(.tv) { return .keepPaused }
        let activeStamped = timer.sourceScopes.filter { activeConnectionScopes.contains($0) }
        if !timer.allTargetsLGLan && !activeStamped.contains(where: { selection.isSourceEnabled(connection: nil, scope: $0) }) {
            return .keepPaused
        }
        for cap in timer.pausedCapabilities {
            switch cap {
            case .deviceCategory, .feature:
                if !selection.contains(cap) { return .keepPaused }
            case .connection(let conn):
                if !selection.enabledConnections.contains(conn) && activeStamped.contains(where: { connectionCapability(forScope: $0) == conn }) {
                    return .keepPaused
                }
            }
        }
        let groupById = Dictionary(deviceGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sceneIds = Set(scenes.map(\.id))
        var expandedIds: [String] = [], hasMissingTarget = false
        for rawId in timer.targetIds {
            if let group = groupById[rawId] {
                if group.memberDeviceIds.isEmpty { hasMissingTarget = true } else { expandedIds.append(contentsOf: group.memberDeviceIds) }
            } else {
                expandedIds.append(rawId)
            }
        }
        for tid in expandedIds {
            let kind: ControlTargetKind = sceneIds.contains(tid) ? .scene : .device
            let verdict = evaluateControlTargetGate(targetKind: kind, targetId: tid, selection: selection, devices: devices, scenes: scenes)
            if !verdict.allowed {
                if verdict.rejectionReason == .deviceNotFound || verdict.rejectionReason == .sceneNotFound {
                    hasMissingTarget = true
                } else {
                    return .keepPaused
                }
            }
        }
        if hasMissingTarget {
            if !timer.allTargetsLGLan && activeStamped.contains(where: { !selection.isSourceEnabled(connection: nil, scope: $0) }) {
                return .keepPaused
            }
            return .moveToMissed
        }
        return fireAtEpochSeconds <= nowEpochSeconds ? .moveToMissed : .armWaiting
    }

    private static func reverseDependencyOrder(manifest: CapabilityManifest) -> [CapabilityID] {
        var visited: Set<CapabilityID> = [], topo: [CapabilityID] = []
        let byId = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) })
        func visit(_ id: CapabilityID) {
            guard visited.insert(id).inserted, let entry = byId[id] else { return }
            for dep in entry.dependsOn { visit(dep) }
            topo.append(id)
        }
        for entry in manifest.entries { visit(entry.id) }
        return topo.reversed()
    }
}
