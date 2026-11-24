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
    private var consumedEntityIds: Set<String> = []
    private var cardCategoriesByEntityId: [String: Set<DeviceCategoryID>] = [:]
    private var lastPruneReport: MiotTypePruneReport?
    private var pendingPruneReport: MiotTypePruneReport?

    static let supportedSmartHomeDomains: Set<String> = [
        "light", "switch", "climate", "cover", "fan", "humidifier",
        "vacuum", "valve", "water_heater", "lock", "camera", "media_player",
        "scene", "script", "button", "sensor", "binary_sensor", "select",
        "number", "notify", "event",
    ]

    static func isSupportedSmartHomeDomain(_ entityId: String) -> Bool {
        guard let dotIndex = entityId.firstIndex(of: ".") else { return false }
        return supportedSmartHomeDomains.contains(String(entityId[..<dotIndex]))
    }

    mutating func resetForReconnect() {
        let knownCategories = cardCategoriesByEntityId
        self = HAHomeSnapshot()
        cardCategoriesByEntityId = knownCategories
    }

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

    private var stateCaptureEpochs: [String: ContinuousClock.Instant] = [:]

    mutating func receive(
        _ message: [String: JSONValue],
        isRefreshStatesResult: Bool = false,
        typePrunePolicy: HATypePrunePolicy = .unpruned,
        pollCapturedEpoch: ContinuousClock.Instant? = nil
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
                    if let pollCapturedEpoch, let previousEpoch = stateCaptureEpochs[state.entityId], previousEpoch > pollCapturedEpoch {
                        nextStates[state.entityId] = states[state.entityId]
                        continue
                    }
                    nextStates[state.entityId] = state
                    stateCaptureEpochs[state.entityId] = pollCapturedEpoch
                    if let timestamp = DoorbellRing.timestamp(state) { doorbellTimestamps[state.entityId] = timestamp }
                }
                if let pollCapturedEpoch {
                    for (entityId, epoch) in stateCaptureEpochs where epoch > pollCapturedEpoch {
                        nextStates[entityId] = states[entityId]
                    }
                }
                states = nextStates
            default:
                return nil
            }
            pendingInitialResults.remove(id)
        } else if message["type"]?.stringValue == "event" {
            guard ingestStateChangedEvent(message, typePrunePolicy: typePrunePolicy) else {
                return nil
            }
        } else {
            return nil
        }
        guard var home = synthesizeCurrent(typePrunePolicy: typePrunePolicy) else { return nil }
        if let pollCapturedEpoch {
            home.devicePollCapturedEpochs = home.devicePollCapturedEpochs.mapValues { min($0, pollCapturedEpoch) }
        }
        return home
    }

    mutating func ingestStateChangedEvent(
        _ message: [String: JSONValue],
        typePrunePolicy: HATypePrunePolicy = .unpruned,
        capturedEpoch: ContinuousClock.Instant? = nil
    ) -> Bool {
        guard message["type"]?.stringValue == "event",
              case .object(let event) = message["event"],
              event["event_type"]?.stringValue == "state_changed",
              case .object(let data) = event["data"] else {
            return false
        }
        if let newState = data["new_state"], let state = Self.parseState(newState) {
            guard Self.isSupportedSmartHomeDomain(state.entityId) else { return false }
            if let timestamp = DoorbellRing.timestamp(state), timestamp != doorbellTimestamps[state.entityId] {
                doorbellTimestamps[state.entityId] = timestamp
                if pendingInitialResults.isEmpty, isActiveEntity(state.entityId) {
                    let deviceId = entities.first { $0.entity_id == state.entityId }?.device_id ?? state.entityId
                    rings.append(DoorbellRing(deviceId: deviceId, entityId: state.entityId, firedAt: timestamp))
                }
            }
            stateCaptureEpochs[state.entityId] = capturedEpoch
            let previous = states.updateValue(state, forKey: state.entityId)
            guard pendingInitialResults.isEmpty else { return false }
            if state.entityId.hasPrefix("event.") {
                let wasDoorbell = previous.map(DoorbellRing.isDoorbellEvent) ?? false
                return wasDoorbell != DoorbellRing.isDoorbellEvent(state)
            }
            if appliedPrunePolicy == typePrunePolicy, let previous {
                if previous.state == state.state && previous.attributes == state.attributes {
                    return false
                }
                if !consumedEntityIds.contains(state.entityId),
                   previous.isAvailable == state.isAvailable,
                   previous.attributes["device_class"] == state.attributes["device_class"],
                   previous.attributes["unit_of_measurement"] == state.attributes["unit_of_measurement"] {
                    return false
                }
            }
            return true
        } else if data["new_state"] == .null {
            let entityId = data["entity_id"]?.stringValue ?? data["old_state"]?["entity_id"]?.stringValue
            guard let entityId,
                  Self.isSupportedSmartHomeDomain(entityId),
                  states.removeValue(forKey: entityId) != nil else {
                return false
            }
            stateCaptureEpochs[entityId] = capturedEpoch
            doorbellTimestamps.removeValue(forKey: entityId)
            guard pendingInitialResults.isEmpty else { return false }
            if appliedPrunePolicy == typePrunePolicy, !consumedEntityIds.contains(entityId) {
                return false
            }
            return true
        }
        return false
    }

    mutating func synthesizeCurrent(
        typePrunePolicy: HATypePrunePolicy = .unpruned
    ) -> SynthesizedHome? {
        guard pendingInitialResults.isEmpty else { return nil }
        let home = DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: states)
        return applyTypePruning(to: home, policy: typePrunePolicy)
    }

    /// Home Assistant has no per-domain `get_states`, so the link is unchanged and the saving is here:
    /// a closed type's cards leave the round, and their own state changes stop re-synthesizing
    /// (architecture.md §D, network saving counted as 0).
    private mutating func applyTypePruning(to home: SynthesizedHome, policy: HATypePrunePolicy) -> SynthesizedHome {
        appliedPrunePolicy = policy
        var home = home
        let cardEntities = DeviceSynthesizer.haCardEntities(cardIds: Set(home.devices.map(\.id)), entities: entities)
        cardCategoriesByEntityId.removeAll(keepingCapacity: true)
        for index in home.devices.indices {
            let device = home.devices[index]
            let rows = cardEntities[device.id] ?? []
            let readKeys = DeviceSynthesizer.haCardReadKeys(
                for: device, entities: rows, facets: home.deviceFacets[device.id] ?? []
            )
            home.devicePollCapturedEpochs[device.id] = readKeys.compactMap { stateCaptureEpochs[$0] }.max()
            for entityId in readKeys {
                cardCategoriesByEntityId[entityId, default: []].insert(device.capabilityCategoryID)
            }
            home.devices[index].providerSafetySignals = DeviceSynthesizer.haSafetySignals(
                for: device, entities: rows, states: states
            )
        }
        guard let plan = DeviceSynthesizer.haTypePrunePlan(
            home: home, cardEntities: cardEntities, states: states, policy: policy
        ) else {
            consumedEntityIds = Self.collectConsumedEntityIds(
                home: home,
                cardEntities: cardEntities,
                entities: entities,
                states: states,
                droppedCardIds: []
            )
            if let scope = policy.sourceScope.isEmpty ? lastPruneReport?.scope : policy.sourceScope {
                stagePruneReport(MiotTypePruneReport(scope: scope, hiddenIndexedDevices: [], hiddenDeviceIds: [], safetyDevices: []))
            }
            return home
        }
        let dropped = Set(plan.hiddenIndexedDevices.map(\.id)).subtracting(plan.safetyRetainedDeviceIds)
        consumedEntityIds = Self.collectConsumedEntityIds(
            home: home,
            cardEntities: cardEntities,
            entities: entities,
            states: states,
            droppedCardIds: dropped
        )
        stagePruneReport(MiotTypePruneReport(
            scope: policy.sourceScope,
            hiddenIndexedDevices: plan.hiddenIndexedDevices,
            hiddenDeviceIds: dropped,
            safetyDevices: home.devices.filter { plan.safetyRetainedDeviceIds.contains($0.id) }
        ))
        return DeviceSynthesizer.applying(plan, to: home)
    }

    func closedCategory(for entityId: String, policy: HATypePrunePolicy) -> DeviceCategoryID? {
        guard !policy.prunesNothing,
              let categories = cardCategoriesByEntityId[entityId],
              categories.isDisjoint(with: policy.selection.enabledCategories) else { return nil }
        return DeviceCategoryID.allCases.first(where: categories.contains)
    }

    private static func collectConsumedEntityIds(
        home: SynthesizedHome,
        cardEntities: [String: [HAEntityEntry]],
        entities: [HAEntityEntry],
        states: [String: HAEntityState],
        droppedCardIds: Set<String>
    ) -> Set<String> {
        var consumed: Set<String> = []
        for device in home.devices where !droppedCardIds.contains(device.id) {
            consumed.formUnion(device.referencedEntityIds)
            if let rows = cardEntities[device.id] {
                for row in rows {
                    consumed.insert(row.entity_id)
                }
            }
            if let facets = home.deviceFacets[device.id] {
                for facet in facets {
                    consumed.formUnion(facet.referencedEntityIds)
                }
            }
        }
        for scene in home.scenes {
            consumed.insert(scene.entityId)
        }
        for entity in entities where entity.entity_id.hasPrefix("scene.") || entity.entity_id.hasPrefix("script.") {
            consumed.insert(entity.entity_id)
        }
        for entityId in states.keys where entityId.hasPrefix("scene.") || entityId.hasPrefix("script.") {
            consumed.insert(entityId)
        }
        return consumed
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
