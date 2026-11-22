import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct DeviceTypeMappingTests {
    private struct RootCorpus: Decodable { let deviceTypeMapping: DeviceTypeMappingCorpus }
    private struct DeviceTypeMappingCorpus: Decodable {
        let presets: [PresetEntry]
        let cardCases: [CardCase]
        let mixedTypeCases: [MixedTypeCase]
        let splitCardCases: [SplitCardCase]
        let typeIndexHome: TypeIndexHome
        let leakCases: [LeakCase]
        let zeroWriteCases: [ZeroWriteCase]
    }
    private struct PresetEntry: Decodable { let id: DeviceCategoryPreset; let categories: [DeviceCategoryID] }
    private struct HADeviceSpec: Decodable { let name: String; let model: String }
    private struct HAStateRow: Decodable { let entity_id: String; let state: String; let attributes: [String: JSONValue] }
    private struct CardInput: Decodable {
        let source: String; let model: String?; let service: String?; let name: String?
        let device: HADeviceSpec?; let states: [HAStateRow]?
    }
    private struct CardCase: Decodable { let id: String; let input: CardInput; let expectedCategory: DeviceCategoryID }
    private struct ExpectedCard: Decodable {
        let id: String?; let category: DeviceCategoryID; let controlDid: String?; let controlSiid: Int?; let controlEntityId: String?
    }
    private struct MergedServiceRef: Decodable { let model: String; let service: String; let iid: Int }
    private struct MixedTypeCase: Decodable {
        let id: String; let source: String; let did: String?; let name: String?; let model: String?
        let services: [MergedServiceRef]?; let device: HADeviceSpec?; let states: [HAStateRow]?
        let expectedCards: [ExpectedCard]; let expectedFacetSiids: [Int]?; let expectedFacetEntityIds: [String]?
    }
    private struct SplitKeyRef: Decodable { let did: String; let siid: Int }
    private struct SplitCardCase: Decodable {
        let id: String; let source: String; let model: String?; let service: String?; let serviceIids: [Int]?
        let name: String?; let did: String?; let parentDid: String?; let keys: [SplitKeyRef]?
        let device: HADeviceSpec?; let states: [HAStateRow]?; let expectedCards: [ExpectedCard]
    }
    private struct TypeIndexHome: Decodable {
        struct MiHome: Decodable {
            struct Record: Decodable { let did: String; let name: String; let model: String }
            let connectionScope: String; let records: [Record]
        }
        struct HAHome: Decodable { let connectionScope: String; let device: HADeviceSpec; let states: [HAStateRow] }
        let xiaomiCloud: MiHome; let homeAssistant: HAHome
    }
    private struct FixtureSelection: Decodable {
        let enabledConnections: [ConnectionCapabilityID]; let enabledConnectionScopes: [String]
        let enabledFeatures: [FeatureID]; let preset: DeviceCategoryPreset
    }
    private struct PropRef: Decodable, Hashable { let siid: Int; let piid: Int }
    private struct LeakCase: Decodable {
        let id: String; let selection: FixtureSelection; let safetySignals: [SafetySignalKind]
        let leakDid: String; let alertKey: PropRef; let alertValue: JSONValue
        let expectedAvailableDids: [String]; let expectedRetainedDids: [String]
        let expectedLeakReadKeys: [PropRef]; let expectLeakAlert: Bool
    }
    private struct ZeroWriteTarget: Decodable { let source: String; let did: String?; let entityId: String? }
    private struct ZeroWriteCase: Decodable {
        let id: String; let target: ZeroWriteTarget; let selection: FixtureSelection
        let safetySignals: [SafetySignalKind]; let expectedMappedCategory: DeviceCategoryID?
        let expectedAllowed: Bool; let expectedWriteCount: Int; let expectedRejectionCode: String?
    }

    private static func loadMapping() throws -> DeviceTypeMappingCorpus {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/capability_selection_golden.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(RootCorpus.self, from: Data(contentsOf: candidate)).deviceTypeMapping
            }
            dir.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func selection(from f: FixtureSelection) -> CapabilitySelection {
        CapabilitySelection(
            enabledConnections: Set(f.enabledConnections),
            enabledConnectionScopes: Set(f.enabledConnectionScopes),
            enabledFeatures: Set(f.enabledFeatures),
            enabledCategories: f.preset.categorySet
        )
    }

    private static func spec(_ model: String) throws -> MiotDeviceSpec {
        try MiotCoverageBaselineTests.coverageSpec(model)
    }

    private static func service(from model: String, named shortName: String, iid: Int? = nil) throws -> MiotService {
        let base = try spec(model)
        var found = try #require(base.services.first { $0.shortName == shortName })
        if let iid { found.iid = iid }
        return found
    }

    private static func mergedSpec(typeModel: String, services: [MiotService]) throws -> MiotDeviceSpec {
        MiotDeviceSpec(type: try spec(typeModel).type, description: "merged", services: services)
    }

    private static func synthesizeHA(
        deviceId: String,
        device: HADeviceSpec,
        states: [HAStateRow]
    ) -> (home: SynthesizedHome, entities: [HAEntityEntry], stateMap: [String: HAEntityState]) {
        let areas = [HAAreaEntry(area_id: "home", name: "家")]
        let devices = [HADeviceEntry(id: deviceId, area_id: "home", name: device.name, model: device.model)]
        let entities = states.map { HAEntityEntry(entity_id: $0.entity_id, device_id: deviceId) }
        let stateMap = Dictionary(uniqueKeysWithValues: states.map {
            ($0.entity_id, HAEntityState(entityId: $0.entity_id, state: $0.state, attributes: $0.attributes))
        })
        return (DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: stateMap), entities, stateMap)
    }

    private static func haPolicy(categories: Set<DeviceCategoryID>, scope: String = "ha:test") -> HATypePrunePolicy {
        HATypePrunePolicy(
            selection: CapabilitySelection(enabledConnections: [.homeAssistant], enabledConnectionScopes: [scope], enabledFeatures: [], enabledCategories: categories),
            safetyPolicy: SafetyRetentionPolicy(),
            sourceScope: scope
        )
    }

    private static func miPolicy(categories: Set<DeviceCategoryID>, scope: String = "mi:acc1") -> MiotTypePrunePolicy {
        MiotTypePrunePolicy(
            selection: CapabilitySelection(enabledConnections: [.xiaomiCloud], enabledConnectionScopes: [scope], enabledFeatures: [], enabledCategories: categories),
            safetyPolicy: SafetyRetentionPolicy(),
            sourceScope: scope
        )
    }

    private static func assertCards(_ home: SynthesizedHome, expected: [ExpectedCard], label: String) throws {
        #expect(home.devices.count == expected.count, "\(label): card count")
        let entityIds = home.devices.compactMap(\.referencedEntityIds.first)
        #expect(Set(entityIds).count == entityIds.count, "\(label): unique entities")
        for (index, want) in expected.enumerated() {
            let card = home.devices[index]
            if let expectedId = want.id { #expect(card.id == expectedId) }
            #expect(card.capabilityCategoryID == want.category)
            let primaryEntity = card.referencedEntityIds.first
            if let expectedEntity = want.controlEntityId { #expect(primaryEntity == expectedEntity) }
            if let expectedSiid = want.controlSiid {
                let rawEntity = try #require(primaryEntity)
                let address = try #require(MiotAddress.parse(rawEntity))
                #expect(address.siid == expectedSiid)
                if let expectedDid = want.controlDid { #expect(address.did == expectedDid) }
            }
        }
    }

    @Test("Shared device category presets and 20 cardCases map through synthesizers and prune plans")
    func presetsAndCardCasesMatchSharedCorpus() throws {
        let mapping = try Self.loadMapping()
        #expect(mapping.presets.map(\.id.rawValue).sorted() == DeviceCategoryPreset.allCases.map(\.rawValue).sorted())
        for preset in mapping.presets {
            #expect(preset.categories.map(\.rawValue).sorted() == preset.id.categories.map(\.rawValue).sorted())
            #expect(Set(preset.categories) == preset.id.categorySet)
        }
        #expect(DeviceCategoryPreset.lightAndSwitch.categories == [.light, .plug])
        #expect(DeviceCategoryPreset.allSupportedTypes.categories == DeviceCategoryID.allCases)
        #expect(Set(mapping.cardCases.map(\.expectedCategory)) == Set(DeviceCategoryID.allCases))
        #expect(mapping.cardCases.count == 20)

        for c in mapping.cardCases {
            let allExcept = Set(DeviceCategoryID.allCases).subtracting([c.expectedCategory])
            if c.input.source == "home-assistant" {
                let synthesized = Self.synthesizeHA(
                    deviceId: "d-\(c.id)",
                    device: try #require(c.input.device),
                    states: try #require(c.input.states)
                )
                let card = try #require(synthesized.home.devices.first)
                #expect(synthesized.home.devices.count == 1 && card.capabilityCategoryID == c.expectedCategory)
                let cardEntities = DeviceSynthesizer.haCardEntities(cardIds: [card.id], entities: synthesized.entities)
                let closedPlan = try #require(DeviceSynthesizer.haTypePrunePlan(home: synthesized.home, cardEntities: cardEntities, states: synthesized.stateMap, policy: Self.haPolicy(categories: allExcept)))
                #expect(closedPlan.visibleDeviceIds.isEmpty)
                #expect(closedPlan.hiddenIndexedDevices.first { $0.id == card.id }?.category == c.expectedCategory)
                let keptPlan = try #require(DeviceSynthesizer.haTypePrunePlan(home: synthesized.home, cardEntities: cardEntities, states: synthesized.stateMap, policy: Self.haPolicy(categories: [c.expectedCategory])))
                #expect(keptPlan.visibleDeviceIds == [card.id] && keptPlan.hiddenIndexedDevices.isEmpty)
            } else {
                let model = try #require(c.input.model)
                let deviceSpec = try Self.spec(model)
                if let expectedService = c.input.service {
                    #expect(deviceSpec.services.contains { $0.shortName == expectedService })
                }
                let raw = MiDeviceRecord(did: "did-\(c.id)", name: try #require(c.input.name), model: model, isOnline: true)
                let home = MiotSynthesizer.synthesize(devices: [raw], rooms: [], specs: [model: deviceSpec], values: [:])
                let card = try #require(home.devices.first)
                #expect(home.devices.count == 1 && card.capabilityCategoryID == c.expectedCategory)
                #expect(MiotSynthesizer.cardShapes(record: raw, spec: deviceSpec, room: nil).map(\.category) == [c.expectedCategory])
                let closedPlan = MiotSynthesizer.typePrunePlan(devices: [raw], rooms: [], specs: [model: deviceSpec], policy: Self.miPolicy(categories: allExcept))
                #expect(closedPlan.visibleRecords.isEmpty)
                #expect(closedPlan.hiddenIndexedDevices.first { $0.id == card.id }?.category == c.expectedCategory)
                let keptPlan = MiotSynthesizer.typePrunePlan(devices: [raw], rooms: [], specs: [model: deviceSpec], policy: Self.miPolicy(categories: [c.expectedCategory]))
                #expect(keptPlan.visibleDeviceIds == [card.id] && keptPlan.hiddenIndexedDevices.isEmpty)
            }
        }
    }

    @Test("Mixed-type devices, split-key switches, and multi-track covers produce expected cards and prune plans")
    func mixedTypeAndSplitCardCases() throws {
        let mapping = try Self.loadMapping()
        for c in mapping.mixedTypeCases {
            if c.source == "home-assistant" {
                let synthesized = Self.synthesizeHA(deviceId: "d-\(c.id)", device: try #require(c.device), states: try #require(c.states))
                try Self.assertCards(synthesized.home, expected: c.expectedCards, label: c.id)
                let facetIds = Set(synthesized.home.deviceFacets.values.flatMap { $0.map(\.id) })
                for entityId in c.expectedFacetEntityIds ?? [] {
                    #expect(facetIds.contains(entityId), "\(c.id): \(entityId) stays on the card")
                }
                continue
            }
            let did = try #require(c.did)
            let name = try #require(c.name)
            let (model, deviceSpec): (String, MiotDeviceSpec) = if let services = c.services {
                (c.model ?? services[0].model, try Self.mergedSpec(typeModel: c.model ?? services[0].model, services: services.map { try Self.service(from: $0.model, named: $0.service, iid: $0.iid) }))
            } else {
                (try #require(c.model), try Self.spec(try #require(c.model)))
            }
            let home = MiotSynthesizer.synthesize(devices: [MiDeviceRecord(did: did, name: name, model: model, isOnline: true)], rooms: [], specs: [model: deviceSpec], values: [:])
            try Self.assertCards(home, expected: c.expectedCards, label: c.id)
            let facetSiids = Set((home.deviceFacets[did] ?? []).compactMap { $0.target?.referencedEntityId }.compactMap { MiotAddress.parse($0)?.siid })
            for siid in c.expectedFacetSiids ?? [] { #expect(facetSiids.contains(siid)) }
        }

        for c in mapping.splitCardCases {
            if c.source == "home-assistant" {
                let synthesized = Self.synthesizeHA(deviceId: "d-\(c.id)", device: try #require(c.device), states: try #require(c.states))
                try Self.assertCards(synthesized.home, expected: c.expectedCards, label: c.id)
                let cardEntities = DeviceSynthesizer.haCardEntities(cardIds: Set(synthesized.home.devices.map(\.id)), entities: synthesized.entities)
                let plan = try #require(DeviceSynthesizer.haTypePrunePlan(home: synthesized.home, cardEntities: cardEntities, states: synthesized.stateMap, policy: Self.haPolicy(categories: DeviceCategoryPreset.lightAndSwitch.categorySet)))
                #expect(plan.visibleDeviceIds.isEmpty && Set(plan.hiddenIndexedDevices.map(\.id)) == Set(synthesized.home.devices.map(\.id)))
                #expect(plan.hiddenIndexedDevices.allSatisfy { $0.category == .cover })
                continue
            }
            let model = try #require(c.model)
            let serviceName = try #require(c.service)
            let name = try #require(c.name)
            let services = try #require(c.serviceIids).map { try Self.service(from: model, named: serviceName, iid: $0) }
            let deviceSpec = try Self.mergedSpec(typeModel: model, services: services)
            let records: [MiDeviceRecord] = if let keys = c.keys, let parentDid = c.parentDid {
                [MiDeviceRecord(did: parentDid, name: name, model: model, isOnline: true)]
                    + keys.map { MiDeviceRecord(did: $0.did, name: "\(name) \($0.did)", model: model, isOnline: true, splitParentDid: parentDid, splitSiid: $0.siid) }
            } else {
                [MiDeviceRecord(did: try #require(c.did), name: name, model: model, isOnline: true)]
            }
            let home = MiotSynthesizer.synthesize(devices: records, rooms: [], specs: [model: deviceSpec], values: [:])
            try Self.assertCards(home, expected: c.expectedCards, label: c.id)
            let cardCategory = try #require(c.expectedCards.first?.category)
            let keptPlan = MiotSynthesizer.typePrunePlan(devices: records, rooms: [], specs: [model: deviceSpec], policy: Self.miPolicy(categories: [cardCategory]))
            #expect(keptPlan.visibleDeviceIds == Set(home.devices.map(\.id)))
            if let parentDid = c.parentDid {
                #expect(!keptPlan.visibleDeviceIds.contains(parentDid) && !keptPlan.hiddenDeviceIds.contains(parentDid))
            }
            let closedPlan = MiotSynthesizer.typePrunePlan(devices: records, rooms: [], specs: [model: deviceSpec], policy: Self.miPolicy(categories: Set(DeviceCategoryID.allCases).subtracting([cardCategory])))
            #expect(Set(closedPlan.hiddenIndexedDevices.map(\.id)) == Set(home.devices.map(\.id)))
            #expect(closedPlan.hiddenIndexedDevices.allSatisfy { $0.category == cardCategory })
        }
    }

    @Test("Enabling allSupportedTypes leaves MIoT and HA read plans and cards identical to unpruned")
    func allSupportedTypesPresetLeavesReadPlansAndCardsUnchanged() throws {
        let sampleModels = [("curtain", "090615.curtain.1mcu01"), ("light", "miot.light.hyz05"), ("plug", "090615.plug.cmp86"), ("fan", "123888.fan.1121"), ("leak", "bkxh.flood.yf02")]
        var specs: [String: MiotDeviceSpec] = [:]
        for entry in sampleModels { specs[entry.1] = try Self.spec(entry.1) }
        let records = sampleModels.map { MiDeviceRecord(did: $0.0, name: $0.0, model: $0.1, isOnline: true) }
        let allTypesSelection = CapabilitySelection(
            enabledConnections: [.xiaomiCloud, .homeAssistant],
            enabledConnectionScopes: ["mi:acc1", HATypePruningTests.scope],
            enabledFeatures: [],
            enabledCategories: DeviceCategoryPreset.allSupportedTypes.categorySet
        )
        let miPlan = MiotSynthesizer.typePrunePlan(devices: records, rooms: [], specs: specs, policy: MiotTypePrunePolicy(selection: allTypesSelection, safetyPolicy: SafetyRetentionPolicy(enabledSignals: [.leak]), sourceScope: "mi:acc1"))
        #expect(!miPlan.isPruned && miPlan.readKeys == MiotSynthesizer.legacyPropKeys(devices: records, specs: specs))
        #expect(miPlan.hiddenDeviceIds.isEmpty && miPlan.hiddenIndexedDevices.isEmpty && miPlan.visibleRecords == records)

        let haPolicy = HATypePrunePolicy(selection: allTypesSelection, safetyPolicy: SafetyRetentionPolicy(enabledSignals: [.leak]), sourceScope: HATypePruningTests.scope)
        #expect(haPolicy.prunesNothing)
        for name in HATypePruningTests.fixtureNames {
            let root = try HATypePruningTests.fixture(name)
            let (_, baseline, _) = try HATypePruningTests.load(root, policy: .unpruned)
            let (_, actual, report) = try HATypePruningTests.load(root, policy: haPolicy)
            #expect(actual == baseline && (report?.isEmpty ?? true))
        }
    }

    private static func buildTypeIndexPlans(
        home: TypeIndexHome,
        selection: CapabilitySelection,
        safetySignals: [SafetySignalKind]
    ) throws -> (miPlan: MiotTypePrunePlan, miSpecs: [String: MiotDeviceSpec], haPlan: HATypePrunePlan?, haHome: SynthesizedHome) {
        let miRecords = home.xiaomiCloud.records.map { MiDeviceRecord(did: $0.did, name: $0.name, model: $0.model, isOnline: true) }
        var miSpecs: [String: MiotDeviceSpec] = [:]
        for r in miRecords { miSpecs[r.model] = try Self.spec(r.model) }
        let safetyPolicy = SafetyRetentionPolicy(enabledSignals: Set(safetySignals))
        let miPlan = MiotSynthesizer.typePrunePlan(devices: miRecords, rooms: [], specs: miSpecs, policy: MiotTypePrunePolicy(selection: selection, safetyPolicy: safetyPolicy, sourceScope: home.xiaomiCloud.connectionScope))
        let haSynth = Self.synthesizeHA(deviceId: "d-type-index", device: home.homeAssistant.device, states: home.homeAssistant.states)
        let cardEntities = DeviceSynthesizer.haCardEntities(cardIds: Set(haSynth.home.devices.map(\.id)), entities: haSynth.entities)
        let haPlan = DeviceSynthesizer.haTypePrunePlan(home: haSynth.home, cardEntities: cardEntities, states: haSynth.stateMap, policy: HATypePrunePolicy(selection: selection, safetyPolicy: safetyPolicy, sourceScope: home.homeAssistant.connectionScope))
        return (miPlan, miSpecs, haPlan, haSynth.home)
    }

    @Test("Closed sensor type retains leak reads/alerts and host write gate blocks hidden Mi and HA targets end-to-end")
    @MainActor
    func leakRetentionAndZeroWriteGateEndToEnd() async throws {
        let mapping = try Self.loadMapping()
        for c in mapping.leakCases {
            let sel = Self.selection(from: c.selection)
            let built = try Self.buildTypeIndexPlans(home: mapping.typeIndexHome, selection: sel, safetySignals: c.safetySignals)
            let mi = built.miPlan
            #expect(mi.hiddenIndexedDevices.first { $0.id == c.leakDid }?.category == .sensor)
            #expect(mi.visibleDeviceIds == Set(c.expectedAvailableDids) && mi.safetyRetainedDeviceIds == Set(c.expectedRetainedDids))
            #expect(Set(mi.readKeys.filter { $0.did == c.leakDid }.map { PropRef(siid: $0.siid, piid: $0.piid) }) == Set(c.expectedLeakReadKeys))

            var values: [MiotPropKey: JSONValue] = [:]
            let alertKey = MiotPropKey(did: c.leakDid, siid: c.alertKey.siid, piid: c.alertKey.piid)
            if mi.readKeys.contains(alertKey) { values[alertKey] = c.alertValue }
            let evaluated = MiotSynthesizer.synthesize(devices: mi.safetyRecords, rooms: [], specs: built.miSpecs, values: values)
            let result = SensorAlerts.evaluate(
                devices: evaluated.devices, ledger: [:], now: Date(timeIntervalSince1970: 1_700_000_000),
                calendar: Calendar(identifier: .gregorian),
                policy: SensorAlertPolicy(enabled: [.leak: c.safetySignals.contains(.leak)], onlyWhenAway: false, includesAway: true)
            )
            #expect((!result.alerts.isEmpty) == c.expectLeakAlert)
        }

        for c in mapping.zeroWriteCases {
            let sel = Self.selection(from: c.selection)
            let built = try Self.buildTypeIndexPlans(home: mapping.typeIndexHome, selection: sel, safetySignals: c.safetySignals)
            let index = built.miPlan.hiddenIndexedDevices + (built.haPlan?.hiddenIndexedDevices ?? [])
            let targetId: String = if c.target.source == "xiaomi-cloud" {
                try #require(c.target.did)
            } else {
                built.haHome.devices.first { $0.referencedEntityIds.contains(c.target.entityId ?? "") }?.id ?? (c.target.entityId ?? "")
            }
            let mapped = index.first { $0.id == targetId }?.category
            #expect(mapped == c.expectedMappedCategory)
            let verdict = CapabilityReferenceEngine.evaluateControlTargetGate(targetKind: .device, targetId: targetId, candidateIds: [], selection: sel, devices: index)
            #expect(verdict.allowed == c.expectedAllowed && verdict.writeCount == c.expectedWriteCount && verdict.rejectionReason?.code == c.expectedRejectionCode)
        }

        let leakCase = try #require(mapping.leakCases.first { $0.expectLeakAlert })
        let built = try Self.buildTypeIndexPlans(home: mapping.typeIndexHome, selection: Self.selection(from: leakCase.selection), safetySignals: leakCase.safetySignals)
        let visibleMiHome = MiotSynthesizer.synthesize(devices: built.miPlan.visibleRecords, rooms: [], specs: built.miSpecs, values: [:])
        let alertKey = MiotPropKey(did: leakCase.leakDid, siid: leakCase.alertKey.siid, piid: leakCase.alertKey.piid)
        let safetyMiHome = MiotSynthesizer.synthesize(devices: built.miPlan.safetyRecords, rooms: [], specs: built.miSpecs, values: [alertKey: leakCase.alertValue])

        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        defaults.set("http://home.local:8123", forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken("ha-token", defaults: defaults, vault: vault)

        var snapshot = visibleMiHome
        snapshot.isInitialLoadComplete = true
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()

        store.capabilitySelection = CapabilitySelection(
            enabledConnections: [.xiaomiCloud, .homeAssistant],
            enabledConnectionScopes: [mapping.typeIndexHome.xiaomiCloud.connectionScope, store.homeAssistantScopeIdentifier],
            enabledFeatures: [],
            enabledCategories: DeviceCategoryPreset.lightAndSwitch.categorySet
        )
        let haPlan = try #require(built.haPlan)
        store.applyMiotTypePruneReport(MiotTypePruneReport(
            scope: mapping.typeIndexHome.xiaomiCloud.connectionScope,
            hiddenIndexedDevices: built.miPlan.hiddenIndexedDevices,
            hiddenDeviceIds: built.miPlan.hiddenDeviceIds,
            safetyDevices: safetyMiHome.devices
        ))
        store.handleProviderEvent(.haTypePruneChanged(MiotTypePruneReport(
            scope: store.homeAssistantScopeIdentifier,
            hiddenIndexedDevices: haPlan.hiddenIndexedDevices,
            hiddenDeviceIds: Set(haPlan.hiddenIndexedDevices.map(\.id)),
            safetyDevices: []
        )))

        #expect(store.devices.map(\.id) == ["101"])
        #expect(store.typeHiddenSafetyDevices.map(\.id) == ["105"])
        #expect(store.menuBarShowsHazard)
        #expect(store.recentSafetyAlerts.contains { $0.alert.deviceId == "105" })
        await #expect(throws: CapabilityControlBlockedError(reason: .categoryDisabled(.sensor))) {
            try await store.executeDeviceCommand(.setMiotProperty(entityId: "miot:105:2", piid: 1006, value: .bool(false)))
        }
        await #expect(throws: CapabilityControlBlockedError(reason: .categoryDisabled(.valve))) {
            try await store.executeDeviceCommand(.setSwitch(entityId: "valve.gas_main", isOn: true))
        }
        #expect(store.evaluateDeviceControlGate(deviceId: "sensor.gone").rejectionReason == .deviceNotFound)
        #expect(await mock.executedCommands.isEmpty)
    }
}
