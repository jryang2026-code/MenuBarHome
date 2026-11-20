import Foundation

struct HAHomeSnapshot {
    enum ReadError: LocalizedError {
        case rejected
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .rejected: L10n.tr(
                "HA 未允许读取设备或注册表，请检查访问令牌的账号权限",
                "Home Assistant refused to read devices or registries; check the access token's user permissions"
            )
            case .invalidResponse: L10n.tr(
                "HA 返回的设备或注册表数据格式无效，请检查 HA 版本和连接地址",
                "Home Assistant returned invalid device or registry data; check its version and address"
            )
            }
        }
    }

    private var areas: [HAAreaEntry] = []
    private var devices: [HADeviceEntry] = []
    private var entities: [HAEntityEntry] = []
    private var states: [String: HAEntityState] = [:]
    private var pendingInitialResults: Set<Int> = [1, 2, 3, 4]
    private var rings: [DoorbellRing] = []
    /// Last valid press timestamp per doorbell entity. It survives `unavailable`, so a doorbell
    /// coming back with a press already seen is not a new press.
    private var doorbellTimestamps: [String: String] = [:]
    /// The type-pruning policy the last published round was built under (P3b-M).
    private var appliedPrunePolicy: HATypePrunePolicy?
    /// Entities whose every card a closed type dropped with no enabled alert left to feed: a state
    /// change on one of them has no consumer, so it neither re-synthesizes nor publishes.
    private var unconsumedEntityIds: Set<String> = []
    private var lastPruneReport: MiotTypePruneReport?
    private var pendingPruneReport: MiotTypePruneReport?

    /// Doorbell presses seen since the last call. Initial loads and `get_states` refreshes never ring.
    mutating func takeDoorbellRings() -> [DoorbellRing] {
        defer { rings = [] }
        return rings
    }

    /// The pruning result of the round just returned, when it differs from the one reported last.
    /// The first round of a connection always reports, so a fresh connection replaces whatever the
    /// host kept from the previous one.
    mutating func takeTypePruneReport() -> MiotTypePruneReport? {
        defer { pendingPruneReport = nil }
        return pendingPruneReport
    }

    /// The last report with its retained devices marked stale, once the connection is lost: they no
    /// longer receive state, so `SafetyMonitor` must skip them as it skips the visible cards after the
    /// fallback grace. The next connection's first round reports fresh values again.
    mutating func staleTypePruneReport() -> MiotTypePruneReport? {
        guard let last = lastPruneReport, last.safetyDevices.contains(where: { !$0.telemetryStale }) else { return nil }
        let stale = MiotTypePruneReport(
            scope: last.scope,
            hiddenIndexedDevices: last.hiddenIndexedDevices,
            hiddenDeviceIds: last.hiddenDeviceIds,
            safetyDevices: last.safetyDevices.map { var device = $0; device.telemetryStale = true; return device }
        )
        lastPruneReport = stale
        return stale
    }

    mutating func receive(
        _ message: [String: JSONValue],
        isRefreshStatesResult: Bool = false,
        typePrunePolicy: HATypePrunePolicy = .unpruned
    ) throws -> SynthesizedHome? {
        if message["type"]?.stringValue == "result", let id = message["id"]?.intValue {
            guard (1...4).contains(id) || isRefreshStatesResult else { return nil }
            guard message["success"]?.boolValue == true else { throw ReadError.rejected }
            guard let result = message["result"] else { throw ReadError.invalidResponse }
            switch id {
            case 1:
                areas = try decode([HAAreaEntry].self, from: result)
            case 2:
                devices = try decode([HADeviceEntry].self, from: result)
            case 3:
                entities = try decode([HAEntityEntry].self, from: result)
            case let stateResultID where stateResultID == 4 || isRefreshStatesResult:
                guard case .array(let entries) = result else { throw ReadError.invalidResponse }
                var nextStates: [String: HAEntityState] = [:]
                for value in entries {
                    guard let state = Self.parseState(value) else { throw ReadError.invalidResponse }
                    nextStates[state.entityId] = state
                    if let timestamp = DoorbellRing.timestamp(state) { doorbellTimestamps[state.entityId] = timestamp }
                }
                states = nextStates
            default:
                return nil
            }
            pendingInitialResults.remove(id)
        } else if message["type"]?.stringValue == "event",
                  case .object(let event) = message["event"],
                  event["event_type"]?.stringValue == "state_changed",
                  case .object(let data) = event["data"] {
            if let newState = data["new_state"], let state = Self.parseState(newState) {
                if let timestamp = DoorbellRing.timestamp(state), timestamp != doorbellTimestamps[state.entityId] {
                    doorbellTimestamps[state.entityId] = timestamp
                    if pendingInitialResults.isEmpty, isActiveEntity(state.entityId) {
                        let deviceId = entities.first { $0.entity_id == state.entityId }?.device_id ?? state.entityId
                        rings.append(DoorbellRing(deviceId: deviceId, entityId: state.entityId, firedAt: timestamp))
                    }
                }
                states[state.entityId] = state
                if pendingInitialResults.isEmpty,
                   appliedPrunePolicy == typePrunePolicy,
                   unconsumedEntityIds.contains(state.entityId) {
                    return nil
                }
            } else if data["new_state"] == .null {
                let entityId = data["entity_id"]?.stringValue ?? data["old_state"]?["entity_id"]?.stringValue
                guard let entityId, states.removeValue(forKey: entityId) != nil else {
                    return nil
                }
                doorbellTimestamps.removeValue(forKey: entityId)
            } else {
                return nil
            }
        } else {
            return nil
        }
        guard pendingInitialResults.isEmpty else { return nil }
        let home = DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: states)
        return applyTypePruning(to: home, policy: typePrunePolicy)
    }

    /// Home Assistant has no per-domain `get_states`, so the link is unchanged and the saving is here:
    /// a closed type's cards leave the round, and their own state changes stop re-synthesizing
    /// (architecture.md §D, network saving counted as 0).
    private mutating func applyTypePruning(to home: SynthesizedHome, policy: HATypePrunePolicy) -> SynthesizedHome {
        appliedPrunePolicy = policy
        let cardEntities = policy.prunesNothing
            ? [:]
            : DeviceSynthesizer.haCardEntities(cardIds: Set(home.devices.map(\.id)), entities: entities)
        guard let plan = DeviceSynthesizer.haTypePrunePlan(
            home: home, cardEntities: cardEntities, states: states, policy: policy
        ) else {
            unconsumedEntityIds = []
            // An empty report clears what the host kept; a provider that never ran under a host
            // scope has nothing to clear.
            if let scope = policy.sourceScope.isEmpty ? lastPruneReport?.scope : policy.sourceScope {
                stagePruneReport(MiotTypePruneReport(scope: scope, hiddenIndexedDevices: [], hiddenDeviceIds: [], safetyDevices: []))
            }
            return home
        }
        let dropped = Set(plan.hiddenIndexedDevices.map(\.id)).subtracting(plan.safetyRetainedDeviceIds)
        // An entity whose device drew no card stays consumed: its next state may create one.
        var owners: [String: [String]] = [:]
        for (card, rows) in cardEntities {
            for row in rows { owners[row.entity_id, default: []].append(card) }
        }
        unconsumedEntityIds = Set(owners.filter { $0.value.allSatisfy(dropped.contains) }.keys)
        stagePruneReport(MiotTypePruneReport(
            scope: policy.sourceScope,
            hiddenIndexedDevices: plan.hiddenIndexedDevices,
            hiddenDeviceIds: dropped,
            safetyDevices: home.devices.filter { plan.safetyRetainedDeviceIds.contains($0.id) }
        ))
        return DeviceSynthesizer.applying(plan, to: home)
    }

    private mutating func stagePruneReport(_ report: MiotTypePruneReport) {
        guard report != lastPruneReport else { return }
        lastPruneReport = report
        pendingPruneReport = report
    }

    private func isActiveEntity(_ entityId: String) -> Bool {
        guard let entry = entities.first(where: { $0.entity_id == entityId }) else { return true }
        guard entry.disabled_by == nil, entry.hidden_by == nil else { return false }
        if let deviceId = entry.device_id,
           let device = devices.first(where: { $0.id == deviceId }),
           device.disabled_by != nil {
            return false
        }
        return true
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ReadError.invalidResponse
        }
    }

    private static func parseState(_ value: JSONValue) -> HAEntityState? {
        guard case .object(let object) = value,
              let entityId = object["entity_id"]?.stringValue,
              let state = object["state"]?.stringValue else { return nil }
        let attributes: [String: JSONValue]
        if case .object(let values) = object["attributes"] {
            attributes = values
        } else {
            attributes = [:]
        }
        return HAEntityState(
            entityId: entityId,
            state: state,
            attributes: attributes,
            lastChanged: parseLastChanged(object["last_changed"])
        )
    }

    private static let dateFormatterLock = NSLock()
    nonisolated(unsafe) private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeSecondISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseLastChanged(_ value: JSONValue?) -> Date? {
        guard let raw = value?.stringValue else { return nil }
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        if let date = fractionalISO8601Formatter.date(from: raw) { return date }
        return wholeSecondISO8601Formatter.date(from: raw)
    }
}
