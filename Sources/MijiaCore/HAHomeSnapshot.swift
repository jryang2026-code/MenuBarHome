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
    private(set) var states: [String: HAEntityState] = [:]
    private(set) var stateCaptureEpochs: [String: ContinuousClock.Instant] = [:]
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
        "remote", "scene", "script", "button", "sensor", "binary_sensor", "select",
        "number", "notify", "event",
    ]

    func remoteProfile(for entityId: String) -> HARemoteProfile {
        let entity = entities.first(where: { $0.entity_id == entityId })
        let device = entity?.device_id.flatMap { devId in devices.first(where: { $0.id == devId }) }
        let friendly = states[entityId]?.attributes["friendly_name"]?.stringValue ?? entity?.name ?? device?.name_by_user ?? device?.name
        return HARemoteProfile.infer(platform: entity?.platform, manufacturer: device?.manufacturer, model: device?.model, identifiers: device?.identifiers, entityId: entityId, friendlyName: friendly)
    }

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

    mutating func receive(
        _ message: [String: JSONValue],
        isInitialStatesResult: Bool = false,
        isRefreshStatesResult: Bool = false,
        typePrunePolicy: HATypePrunePolicy = .unpruned,
        pollCapturedEpoch: ContinuousClock.Instant? = nil
    ) throws -> SynthesizedHome? {
        if message["type"]?.stringValue == "result", let id = message["id"]?.intValue {
            guard (1...4).contains(id) || isInitialStatesResult || isRefreshStatesResult else { return nil }
            guard message["success"]?.boolValue == true else { throw ReadError.rejected }
            guard let result = message["result"] else { throw ReadError.invalidResponse }
            switch id {
            case 1:
                areas = try decode([HAAreaEntry].self, from: result)
            case 2:
                devices = try decode([HADeviceEntry].self, from: result)
            case 3:
                entities = try decode([HAEntityEntry].self, from: result)
            case _ where id == 4 || isInitialStatesResult || isRefreshStatesResult:
                guard case .array(let entries) = result else { throw ReadError.invalidResponse }
                var nextStates: [String: HAEntityState] = [:]
                for value in entries {
                    guard let state = Self.parseState(value) else { throw ReadError.invalidResponse }
                    if let pollCapturedEpoch, let previousEpoch = stateCaptureEpochs[state.entityId], previousEpoch > pollCapturedEpoch {
                        nextStates[state.entityId] = states[state.entityId]
                        continue
                    }
                    nextStates[state.entityId] = state
                    if let pollCapturedEpoch { stateCaptureEpochs[state.entityId] = pollCapturedEpoch }
                    if let timestamp = DoorbellRing.timestamp(state) { doorbellTimestamps[state.entityId] = timestamp }
                }
                if let pollCapturedEpoch {
                    for (entityId, epoch) in stateCaptureEpochs where epoch > pollCapturedEpoch {
                        nextStates[entityId] = states[entityId]
                    }
                    stateCaptureEpochs = stateCaptureEpochs.filter { entityId, recordedEpoch in
                        nextStates[entityId] != nil || !(pollCapturedEpoch > recordedEpoch)
                    }
                }
                states = nextStates
                if isInitialStatesResult { pendingInitialResults.remove(4) }
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
            return ingestLiveState(state, typePrunePolicy: typePrunePolicy, capturedEpoch: capturedEpoch)
        } else if data["new_state"] == .null {
            let entityId = data["entity_id"]?.stringValue ?? data["old_state"]?["entity_id"]?.stringValue
            guard let entityId, Self.isSupportedSmartHomeDomain(entityId) else { return false }
            return removeLiveState(entityId, typePrunePolicy: typePrunePolicy, capturedEpoch: capturedEpoch)
        }
        return false
    }

    mutating func ingestCompressedStates(
        _ event: JSONValue?,
        typePrunePolicy: HATypePrunePolicy,
        capturedEpoch: ContinuousClock.Instant? = nil
    ) throws -> Bool {
        guard case .object(let updates) = event else { throw ReadError.invalidResponse }
        let isInitial = pendingInitialResults.contains(4)
        var needsSynthesis = false
        if isInitial {
            let additions: [String: JSONValue]
            if let rawAdditions = updates["a"] {
                guard case .object(let object) = rawAdditions else { throw ReadError.invalidResponse }
                additions = object
            } else {
                additions = [:]
            }
            var initialStates: [String: HAEntityState] = [:]
            for (entityId, value) in additions {
                initialStates[entityId] = try Self.parseCompressedState(entityId, value)
                if let capturedEpoch { stateCaptureEpochs[entityId] = capturedEpoch }
            }
            states = initialStates
            doorbellTimestamps = initialStates.compactMapValues(DoorbellRing.timestamp)
            pendingInitialResults.remove(4)
            needsSynthesis = pendingInitialResults.isEmpty
        } else if case .object(let additions) = updates["a"] {
            for (entityId, value) in additions {
                let state = try Self.parseCompressedState(entityId, value)
                if ingestLiveState(state, typePrunePolicy: typePrunePolicy, capturedEpoch: capturedEpoch) { needsSynthesis = true }
            }
        }
        for entityId in updates["r"]?.stringArrayValue ?? [] {
            if removeLiveState(entityId, typePrunePolicy: typePrunePolicy, capturedEpoch: capturedEpoch) { needsSynthesis = true }
        }
        if case .object(let changes) = updates["c"] {
            for (entityId, diff) in changes {
                guard var state = states[entityId] else { continue }
                let additions = diff["+"]
                if let value = additions?["s"]?.stringValue { state.state = value }
                state.attributes.merge(Self.fields(additions?["a"])) { _, new in new }
                for key in diff["-"]?["a"]?.stringArrayValue ?? [] {
                    state.attributes.removeValue(forKey: key)
                }
                if let context = additions?["c"] {
                    if let id = context.stringValue {
                        state.context["id"] = .string(id)
                    } else {
                        state.context.merge(Self.fields(context)) { _, new in new }
                    }
                }
                if let lastChanged = Self.parseCompressedTimestamp(additions?["lc"]) {
                    state.lastChanged = lastChanged
                    state.lastUpdated = lastChanged
                } else if let lastUpdated = Self.parseCompressedTimestamp(additions?["lu"]) {
                    state.lastUpdated = lastUpdated
                }
                if ingestLiveState(state, typePrunePolicy: typePrunePolicy, capturedEpoch: capturedEpoch) { needsSynthesis = true }
            }
        }
        return needsSynthesis
    }

    private mutating func ingestLiveState(
        _ state: HAEntityState,
        typePrunePolicy: HATypePrunePolicy,
        capturedEpoch: ContinuousClock.Instant? = nil
    ) -> Bool {
        let entityId = state.entityId
        if let capturedEpoch { stateCaptureEpochs[entityId] = capturedEpoch }
        let previous = states.updateValue(state, forKey: entityId)
        guard Self.isSupportedSmartHomeDomain(entityId) else { return false }
        if let timestamp = DoorbellRing.timestamp(state), timestamp != doorbellTimestamps[entityId] {
            doorbellTimestamps[entityId] = timestamp
            if pendingInitialResults.isEmpty, isActiveEntity(entityId) {
                let deviceId = entities.first { $0.entity_id == entityId }?.device_id ?? entityId
                rings.append(DoorbellRing(deviceId: deviceId, entityId: entityId, firedAt: timestamp))
            }
        }
        guard pendingInitialResults.isEmpty else { return false }
        if entityId.hasPrefix("event.") {
            let wasDoorbell = previous.map(DoorbellRing.isDoorbellEvent) ?? false
            return wasDoorbell != DoorbellRing.isDoorbellEvent(state)
        }
        if appliedPrunePolicy == typePrunePolicy, let previous {
            if previous.state == state.state && previous.attributes == state.attributes {
                return false
            }
            if !consumedEntityIds.contains(entityId),
               previous.isAvailable == state.isAvailable,
               previous.attributes["device_class"] == state.attributes["device_class"],
               previous.attributes["unit_of_measurement"] == state.attributes["unit_of_measurement"] {
                return false
            }
        }
        return true
    }

    private mutating func removeLiveState(
        _ entityId: String,
        typePrunePolicy: HATypePrunePolicy,
        capturedEpoch: ContinuousClock.Instant? = nil
    ) -> Bool {
        let removed = states.removeValue(forKey: entityId)
        if let capturedEpoch, removed != nil {
            stateCaptureEpochs[entityId] = capturedEpoch
        }
        guard removed != nil, Self.isSupportedSmartHomeDomain(entityId) else {
            return false
        }
        doorbellTimestamps.removeValue(forKey: entityId)
        guard pendingInitialResults.isEmpty else { return false }
        return appliedPrunePolicy != typePrunePolicy || consumedEntityIds.contains(entityId)
    }

    mutating func synthesizeCurrent(
        typePrunePolicy: HATypePrunePolicy = .unpruned
    ) -> SynthesizedHome? {
        guard pendingInitialResults.isEmpty else { return nil }
        var home = DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: states)
        home = applyTypePruning(to: home, policy: typePrunePolicy)
        for device in home.devices {
            let keys = DeviceSynthesizer.haCardReadKeys(
                for: device,
                entities: DeviceSynthesizer.haCardEntities(cardIds: [device.id], entities: entities)[device.id] ?? [],
                facets: home.deviceFacets[device.id] ?? []
            )
            home.devicePollCapturedEpochs[device.id] = keys.compactMap { stateCaptureEpochs[$0] }.max()
        }
        return home
    }

    /// Closed types leave synthesis while the subscription still tracks entities for policy changes.
    private mutating func applyTypePruning(to home: SynthesizedHome, policy: HATypePrunePolicy) -> SynthesizedHome {
        appliedPrunePolicy = policy
        var home = home
        let cardEntities = DeviceSynthesizer.haCardEntities(cardIds: Set(home.devices.map(\.id)), entities: entities)
        cardCategoriesByEntityId.removeAll(keepingCapacity: true)
        for index in home.devices.indices {
            let device = home.devices[index]
            let rows = cardEntities[device.id] ?? []
            for entityId in DeviceSynthesizer.haCardReadKeys(
                for: device, entities: rows, facets: home.deviceFacets[device.id] ?? []
            ) {
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
        var entity = HAEntityState(
            entityId: entityId,
            state: state,
            attributes: fields(object["attributes"]),
            lastChanged: parseLastChanged(object["last_changed"])
        )
        entity.lastUpdated = parseLastChanged(object["last_updated"])
        entity.context = fields(object["context"])
        return entity
    }

    private static func parseCompressedState(_ entityId: String, _ value: JSONValue) throws -> HAEntityState {
        guard let state = value["s"]?.stringValue,
              let lastChanged = parseCompressedTimestamp(value["lc"]) else { throw ReadError.invalidResponse }
        var entity = HAEntityState(
            entityId: entityId, state: state, attributes: fields(value["a"]), lastChanged: lastChanged
        )
        entity.lastUpdated = parseCompressedTimestamp(value["lu"]) ?? lastChanged
        if let contextId = value["c"]?.stringValue {
            entity.context = ["id": .string(contextId), "parent_id": .null, "user_id": .null]
        } else {
            entity.context = fields(value["c"])
        }
        return entity
    }

    private static func fields(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields) = value { return fields }
        return [:]
    }

    private static func parseCompressedTimestamp(_ value: JSONValue?) -> Date? {
        guard case .number(let seconds) = value, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
