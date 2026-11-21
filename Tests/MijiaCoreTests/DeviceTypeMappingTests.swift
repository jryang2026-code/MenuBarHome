import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MijiaCore

/// P3c-M: macOS device-type mapping against the shared `deviceTypeMapping` section of
/// `Tests/Fixtures/capability_selection_golden.json`. Every case feeds real production synthesis
/// (`MiotSynthesizer` / `DeviceSynthesizer`), pruning (`typePrunePlan` / `haTypePrunePlan`),
/// safety evaluation (`SensorAlerts`), and the host write gate (`CapabilityReferenceEngine` / `HomeStore`).
struct DeviceTypeMappingTests {
    // MARK: - Shared Fixture Schema

    private struct RootCorpus: Decodable {
        let deviceTypeMapping: DeviceTypeMappingCorpus
    }

    private struct DeviceTypeMappingCorpus: Decodable {
        let presets: [PresetEntry]
        let cardCases: [CardCase]
        let mixedTypeCases: [MixedTypeCase]
        let splitCardCases: [SplitCardCase]
        let typeIndexHome: TypeIndexHome
        let leakCases: [LeakCase]
        let zeroWriteCases: [ZeroWriteCase]
    }

    private struct PresetEntry: Decodable {
        let id: DeviceCategoryPreset
        let categories: [DeviceCategoryID]
    }

    private struct HADeviceSpec: Decodable {
        let name: String
        let model: String
    }

    private struct HAStateRow: Decodable {
        let entity_id: String
        let state: String
        let attributes: [String: JSONValue]
    }

    private struct CardInput: Decodable {
        let source: String
        let model: String?
        let service: String?
        let name: String?
        let device: HADeviceSpec?
        let states: [HAStateRow]?
    }

    private struct CardCase: Decodable {
        let id: String
        let input: CardInput
        let expectedCategory: DeviceCategoryID
    }

    private struct ExpectedCard: Decodable {
        let id: String?
        let category: DeviceCategoryID
        let controlDid: String?
        let controlSiid: Int?
        let controlEntityId: String?
    }

    private struct MergedServiceRef: Decodable {
        let model: String
        let service: String
        let iid: Int
    }

    private struct MixedTypeCase: Decodable {
        let id: String
        let source: String
        let did: String?
        let name: String?
        let model: String?
        let services: [MergedServiceRef]?
        let device: HADeviceSpec?
        let states: [HAStateRow]?
        let expectedCards: [ExpectedCard]
        let expectedFacetSiids: [Int]?
    }

    private struct SplitKeyRef: Decodable {
        let did: String
        let siid: Int
    }

    private struct SplitCardCase: Decodable {
        let id: String
        let source: String
        let model: String?
        let service: String?
        let serviceIids: [Int]?
        let name: String?
        let did: String?
        let parentDid: String?
        let keys: [SplitKeyRef]?
        let device: HADeviceSpec?
        let states: [HAStateRow]?
        let expectedCards: [ExpectedCard]
    }

    private struct TypeIndexHome: Decodable {
        struct MiHome: Decodable {
            struct Record: Decodable {
                let did: String
                let name: String
                let model: String
            }
            let connectionScope: String
            let records: [Record]
        }

        struct HAHome: Decodable {
            let connectionScope: String
            let device: HADeviceSpec
            let states: [HAStateRow]
        }

        let xiaomiCloud: MiHome
        let homeAssistant: HAHome
    }

    private struct FixtureSelection: Decodable {
        let enabledConnections: [ConnectionCapabilityID]
        let enabledConnectionScopes: [String]
        let enabledFeatures: [FeatureID]
        let preset: DeviceCategoryPreset
    }

    private struct PropRef: Decodable, Hashable {
        let siid: Int
        let piid: Int
    }

    private struct LeakCase: Decodable {
        let id: String
        let selection: FixtureSelection
        let safetySignals: [SafetySignalKind]
        let leakDid: String
        let alertKey: PropRef
        let alertValue: JSONValue
        let expectedAvailableDids: [String]
        let expectedRetainedDids: [String]
        let expectedLeakReadKeys: [PropRef]
        let expectLeakAlert: Bool
    }

    private struct ZeroWriteTarget: Decodable {
        let source: String
        let did: String?
        let entityId: String?
    }

    private struct ZeroWriteCase: Decodable {
        let id: String
        let target: ZeroWriteTarget
        let selection: FixtureSelection
        let safetySignals: [SafetySignalKind]
        let expectedMappedCategory: DeviceCategoryID?
        let expectedAllowed: Bool
        let expectedWriteCount: Int
        let expectedRejectionCode: String?
    }

    // MARK: - Helpers

    private static func loadMapping() throws -> DeviceTypeMappingCorpus {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/capability_selection_golden.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try JSONDecoder().decode(RootCorpus.self, from: data).deviceTypeMapping
            }
            dir.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func selection(from fixture: FixtureSelection) -> CapabilitySelection {
        CapabilitySelection(
            enabledConnections: Set(fixture.enabledConnections),
            enabledConnectionScopes: Set(fixture.enabledConnectionScopes),
            enabledFeatures: Set(fixture.enabledFeatures),
            enabledCategories: fixture.preset.categorySet
        )
    }

    private static func spec(_ model: String) throws -> MiotDeviceSpec {
        try MiotCoverageBaselineTests.coverageSpec(model)
    }

    private static func service(from model: String, named shortName: String, iid: Int? = nil) throws -> MiotService {
        let base = try spec(model)
        var found = try #require(
            base.services.first(where: { $0.shortName == shortName }),
            "\(model) publishes a \(shortName) service"
        )
        if let iid { found.iid = iid }
        return found
    }

    private static func mergedSpec(typeModel: String, services: [MiotService]) throws -> MiotDeviceSpec {
        let base = try spec(typeModel)
        return MiotDeviceSpec(type: base.type, description: "merged", services: services)
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
        let home = DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: stateMap)
        return (home, entities, stateMap)
    }

    private static func assertCards(_ home: SynthesizedHome, expected: [ExpectedCard], label: String) throws {
        #expect(home.devices.count == expected.count, "\(label): card count")
        let entityIds = home.devices.compactMap(\.referencedEntityIds.first)
        #expect(Set(entityIds).count == entityIds.count, "\(label): every card addresses its own entity")
        for (index, want) in expected.enumerated() {
            let card = home.devices[index]
            if let expectedId = want.id {
                #expect(card.id == expectedId, "\(label)[\(index)] id")
            }
            #expect(card.capabilityCategoryID == want.category, "\(label)[\(index)] category")
            let primaryEntity = card.referencedEntityIds.first
            if let expectedEntity = want.controlEntityId {
                #expect(primaryEntity == expectedEntity, "\(label)[\(index)] entity")
            }
            if let expectedSiid = want.controlSiid {
                let entity = try #require(primaryEntity, "\(label)[\(index)] missing control entity")
                let address = try #require(MiotAddress.parse(entity), "\(label)[\(index)] expected MIoT address, got \(entity)")
                #expect(address.siid == expectedSiid, "\(label)[\(index)] siid")
                if let expectedDid = want.controlDid {
                    #expect(address.did == expectedDid, "\(label)[\(index)] did")
                }
            }
        }
    }

    // MARK: - Presets & Coverage

    @Test("Shared device category presets match corpus and cover every approved type")
    func presetsAndCoverageMatchSharedCorpus() throws {
        let mapping = try Self.loadMapping()

        #expect(
            mapping.presets.map(\.id.rawValue).sorted()
                == DeviceCategoryPreset.allCases.map(\.rawValue).sorted()
        )
        for preset in mapping.presets {
            #expect(
                preset.categories.map(\.rawValue).sorted()
                    == preset.id.categories.map(\.rawValue).sorted(),
                "\(preset.id.rawValue)"
            )
            #expect(Set(preset.categories) == preset.id.categorySet, "\(preset.id.rawValue)")
        }

        // 「只用灯和开关」 covers both `.light` and `.plug` because a wall switch driving a lamp draws as `.plug`.
        #expect(DeviceCategoryPreset.lightAndSwitch.categories == [.light, .plug])
        #expect(DeviceCategoryPreset.allSupportedTypes.categories == DeviceCategoryID.allCases)

        let covered = Set(mapping.cardCases.map(\.expectedCategory))
        #expect(covered == Set(DeviceCategoryID.allCases))
    }

    // MARK: - 20 Shared Card Cases

    @Test("Every shared cardCase synthesizes and prunes to its expected manifest category")
    func cardCasesMapThroughSynthesizersAndPrunePlans() throws {
        let mapping = try Self.loadMapping()
        #expect(mapping.cardCases.count == 20)

        for c in mapping.cardCases {
            if c.input.source == "home-assistant" {
                let haDevice = try #require(c.input.device, "\(c.id): missing HA device")
                let haStates = try #require(c.input.states, "\(c.id): missing HA states")
                let synthesized = Self.synthesizeHA(deviceId: "d-\(c.id)", device: haDevice, states: haStates)
                #expect(synthesized.home.devices.count == 1, "\(c.id): one card")
                let card = try #require(synthesized.home.devices.first, "\(c.id): missing card")
                #expect(card.capabilityCategoryID == c.expectedCategory, "\(c.id): card category")

                let cardEntities = DeviceSynthesizer.haCardEntities(
                    cardIds: Set(synthesized.home.devices.map(\.id)),
                    entities: synthesized.entities
                )
                // Closing only this category must hide the card and record its mapped category in the index.
                let closedPolicy = HATypePrunePolicy(
                    selection: CapabilitySelection(
                        enabledConnections: [.homeAssistant],
                        enabledConnectionScopes: ["ha:test"],
                        enabledFeatures: [],
                        enabledCategories: Set(DeviceCategoryID.allCases).subtracting([c.expectedCategory])
                    ),
                    safetyPolicy: SafetyRetentionPolicy(),
                    sourceScope: "ha:test"
                )
                let closedPlan = try #require(
                    DeviceSynthesizer.haTypePrunePlan(
                        home: synthesized.home, cardEntities: cardEntities, states: synthesized.stateMap, policy: closedPolicy
                    ),
                    "\(c.id): expected non-nil closed plan"
                )
                #expect(closedPlan.visibleDeviceIds.isEmpty, "\(c.id): closed category hides card")
                let indexed = try #require(
                    closedPlan.hiddenIndexedDevices.first(where: { $0.id == card.id }),
                    "\(c.id): closed card must enter hidden index"
                )
                #expect(indexed.category == c.expectedCategory, "\(c.id): prune plan category")

                // Enabling only this category must keep the card visible.
                let onlyThisPolicy = HATypePrunePolicy(
                    selection: CapabilitySelection(
                        enabledConnections: [.homeAssistant],
                        enabledConnectionScopes: ["ha:test"],
                        enabledFeatures: [],
                        enabledCategories: [c.expectedCategory]
                    ),
                    safetyPolicy: SafetyRetentionPolicy(),
                    sourceScope: "ha:test"
                )
                let keptPlan = try #require(
                    DeviceSynthesizer.haTypePrunePlan(
                        home: synthesized.home, cardEntities: cardEntities, states: synthesized.stateMap, policy: onlyThisPolicy
                    ),
                    "\(c.id): expected non-nil single-category plan"
                )
                #expect(keptPlan.visibleDeviceIds == [card.id], "\(c.id): enabled category keeps card")
                #expect(keptPlan.hiddenIndexedDevices.isEmpty, "\(c.id): enabled category hides nothing")
            } else {
                let model = try #require(c.input.model, "\(c.id): missing MIoT model")
                let name = try #require(c.input.name, "\(c.id): missing MIoT name")
                let deviceSpec = try Self.spec(model)
                if let expectedService = c.input.service {
                    #expect(
                        deviceSpec.services.contains(where: { $0.shortName == expectedService }),
                        "\(c.id): spec has \(expectedService)"
                    )
                }
                let raw = MiDeviceRecord(did: "did-\(c.id)", name: name, model: model, isOnline: true)
                let home = MiotSynthesizer.synthesize(devices: [raw], rooms: [], specs: [model: deviceSpec], values: [:])
                #expect(home.devices.count == 1, "\(c.id): one card")
                let card = try #require(home.devices.first, "\(c.id): missing card")
                #expect(card.capabilityCategoryID == c.expectedCategory, "\(c.id): card category")

                let shapes = MiotSynthesizer.cardShapes(record: raw, spec: deviceSpec, room: nil)
                #expect(shapes.count == 1, "\(c.id): one shape")
                #expect(shapes.first?.category == c.expectedCategory, "\(c.id): shape category")

                // Closing only this category hides the record and indexes it under the expected category.
                let closedPolicy = MiotTypePrunePolicy(
                    selection: CapabilitySelection(
                        enabledConnections: [.xiaomiCloud],
                        enabledConnectionScopes: ["mi:acc1"],
                        enabledFeatures: [],
                        enabledCategories: Set(DeviceCategoryID.allCases).subtracting([c.expectedCategory])
                    ),
                    safetyPolicy: SafetyRetentionPolicy(),
                    sourceScope: "mi:acc1"
                )
                let closedPlan = MiotSynthesizer.typePrunePlan(
                    devices: [raw], rooms: [], specs: [model: deviceSpec], policy: closedPolicy
                )
                #expect(closedPlan.visibleRecords.isEmpty, "\(c.id): closed category hides record")
                let indexed = try #require(
                    closedPlan.hiddenIndexedDevices.first(where: { $0.id == card.id }),
                    "\(c.id): closed record enters hidden index"
                )
                #expect(indexed.category == c.expectedCategory, "\(c.id): prune plan category")

                // Enabling only this category keeps the record visible.
                let onlyThisPolicy = MiotTypePrunePolicy(
                    selection: CapabilitySelection(
                        enabledConnections: [.xiaomiCloud],
                        enabledConnectionScopes: ["mi:acc1"],
                        enabledFeatures: [],
                        enabledCategories: [c.expectedCategory]
                    ),
                    safetyPolicy: SafetyRetentionPolicy(),
                    sourceScope: "mi:acc1"
                )
                let keptPlan = MiotSynthesizer.typePrunePlan(
                    devices: [raw], rooms: [], specs: [model: deviceSpec], policy: onlyThisPolicy
                )
                #expect(keptPlan.visibleDeviceIds == [card.id], "\(c.id): enabled category keeps record")
                #expect(keptPlan.hiddenIndexedDevices.isEmpty, "\(c.id): enabled category hides nothing")
            }
        }
    }

    @Test("A water heater named after a gas valve stays appliance whether online or offline")
    func waterHeaterNamedAfterGasValveNeverFlipsToValve() throws {
        let mapping = try Self.loadMapping()
        let online = try #require(mapping.cardCases.first { $0.id == "ha_water_heater_named_after_a_gas_valve_online" })
        let offline = try #require(mapping.cardCases.first { $0.id == "ha_water_heater_named_after_a_gas_valve_offline" })

        let onlineDev = try #require(online.input.device)
        let onlineStates = try #require(online.input.states)
        let offlineDev = try #require(offline.input.device)
        let offlineStates = try #require(offline.input.states)

        let onlineCard = try #require(Self.synthesizeHA(deviceId: "d-water-heater", device: onlineDev, states: onlineStates).home.devices.first)
        let offlineCard = try #require(Self.synthesizeHA(deviceId: "d-water-heater", device: offlineDev, states: offlineStates).home.devices.first)

        #expect(onlineCard.isOnline == true)
        #expect(offlineCard.isOnline == false)
        for card in [onlineCard, offlineCard] {
            guard case .appliance = card.kind else {
                Issue.record("expected .appliance card for online=\(card.isOnline)")
                return
            }
            #expect(card.capabilityCategoryID == .appliance, "online=\(card.isOnline)")
        }
    }

    // MARK: - Mixed-Type & Split-Card Cases

    @Test("Mixed-type devices stay one card with secondary services kept in facets")
    func mixedTypeCasesKeepOneCardAndSecondaryFacets() throws {
        let mapping = try Self.loadMapping()
        #expect(mapping.mixedTypeCases.count == 3)

        for c in mapping.mixedTypeCases {
            if c.source == "home-assistant" {
                let device = try #require(c.device, "\(c.id): missing HA device")
                let states = try #require(c.states, "\(c.id): missing HA states")
                let synthesized = Self.synthesizeHA(deviceId: "d-\(c.id)", device: device, states: states)
                try Self.assertCards(synthesized.home, expected: c.expectedCards, label: c.id)
                continue
            }

            let did = try #require(c.did, "\(c.id): missing did")
            let name = try #require(c.name, "\(c.id): missing name")
            let model: String
            let deviceSpec: MiotDeviceSpec
            if let services = c.services {
                let first = try #require(services.first, "\(c.id): empty services")
                model = c.model ?? first.model
                let builtServices = try services.map { try Self.service(from: $0.model, named: $0.service, iid: $0.iid) }
                deviceSpec = try Self.mergedSpec(typeModel: model, services: builtServices)
            } else {
                model = try #require(c.model, "\(c.id): missing model")
                deviceSpec = try Self.spec(model)
            }
            let record = MiDeviceRecord(did: did, name: name, model: model, isOnline: true)
            let home = MiotSynthesizer.synthesize(devices: [record], rooms: [], specs: [model: deviceSpec], values: [:])
            try Self.assertCards(home, expected: c.expectedCards, label: c.id)

            let facetSiids = Set(
                (home.deviceFacets[did] ?? [])
                    .compactMap { $0.target?.referencedEntityId }
                    .compactMap { MiotAddress.parse($0)?.siid }
            )
            for siid in c.expectedFacetSiids ?? [] {
                #expect(facetSiids.contains(siid), "\(c.id): siid \(siid) stays on the card, got \(facetSiids.sorted())")
            }
        }
    }

    @Test("Split-key switches and multi-track covers produce independent cards and prune plans")
    func splitCardCasesProduceIndependentCardsAndPrunePlans() throws {
        let mapping = try Self.loadMapping()
        #expect(mapping.splitCardCases.count == 3)

        for c in mapping.splitCardCases {
            if c.source == "home-assistant" {
                let device = try #require(c.device, "\(c.id): missing HA device")
                let states = try #require(c.states, "\(c.id): missing HA states")
                let synthesized = Self.synthesizeHA(deviceId: "d-\(c.id)", device: device, states: states)
                try Self.assertCards(synthesized.home, expected: c.expectedCards, label: c.id)

                let cardEntities = DeviceSynthesizer.haCardEntities(
                    cardIds: Set(synthesized.home.devices.map(\.id)),
                    entities: synthesized.entities
                )
                let closedCover = HATypePrunePolicy(
                    selection: CapabilitySelection(
                        enabledConnections: [.homeAssistant],
                        enabledConnectionScopes: ["ha:test"],
                        enabledFeatures: [],
                        enabledCategories: DeviceCategoryPreset.lightAndSwitch.categorySet
                    ),
                    safetyPolicy: SafetyRetentionPolicy(),
                    sourceScope: "ha:test"
                )
                let plan = try #require(
                    DeviceSynthesizer.haTypePrunePlan(
                        home: synthesized.home, cardEntities: cardEntities, states: synthesized.stateMap, policy: closedCover
                    )
                )
                #expect(plan.visibleDeviceIds.isEmpty, "\(c.id): closing cover hides both tracks")
                #expect(
                    Set(plan.hiddenIndexedDevices.map(\.id)) == Set(synthesized.home.devices.map(\.id)),
                    "\(c.id): prune plan indexes both tracks"
                )
                for entry in plan.hiddenIndexedDevices {
                    #expect(entry.category == .cover, "\(c.id): \(entry.id) indexed as cover")
                }
                continue
            }

            let model = try #require(c.model, "\(c.id): missing model")
            let serviceName = try #require(c.service, "\(c.id): missing service")
            let serviceIids = try #require(c.serviceIids, "\(c.id): missing serviceIids")
            let name = try #require(c.name, "\(c.id): missing name")
            let services = try serviceIids.map { try Self.service(from: model, named: serviceName, iid: $0) }
            let deviceSpec = try Self.mergedSpec(typeModel: model, services: services)

            let records: [MiDeviceRecord]
            if let keys = c.keys {
                let parentDid = try #require(c.parentDid, "\(c.id): missing parentDid")
                records = [MiDeviceRecord(did: parentDid, name: name, model: model, isOnline: true)]
                    + keys.map { key in
                        MiDeviceRecord(
                            did: key.did, name: "\(name) \(key.did)", model: model,
                            isOnline: true, splitParentDid: parentDid, splitSiid: key.siid
                        )
                    }
            } else {
                let did = try #require(c.did, "\(c.id): missing did")
                records = [MiDeviceRecord(did: did, name: name, model: model, isOnline: true)]
            }

            let home = MiotSynthesizer.synthesize(devices: records, rooms: [], specs: [model: deviceSpec], values: [:])
            try Self.assertCards(home, expected: c.expectedCards, label: c.id)

            // Verify prune plan sees the exact same split cards (and never draws or indexes a split parent).
            let cardCategory = try #require(c.expectedCards.first?.category)
            let keepCategoryPolicy = MiotTypePrunePolicy(
                selection: CapabilitySelection(
                    enabledConnections: [.xiaomiCloud],
                    enabledConnectionScopes: ["mi:acc1"],
                    enabledFeatures: [],
                    enabledCategories: [cardCategory]
                ),
                safetyPolicy: SafetyRetentionPolicy(),
                sourceScope: "mi:acc1"
            )
            let keptPlan = MiotSynthesizer.typePrunePlan(
                devices: records, rooms: [], specs: [model: deviceSpec], policy: keepCategoryPolicy
            )
            #expect(keptPlan.visibleDeviceIds == Set(home.devices.map(\.id)), "\(c.id): visible ids match cards")
            if let parentDid = c.parentDid {
                #expect(!keptPlan.visibleDeviceIds.contains(parentDid), "\(c.id): split parent is not visible")
                #expect(!keptPlan.hiddenDeviceIds.contains(parentDid), "\(c.id): split parent is not hidden")
            }

            let closeCategoryPolicy = MiotTypePrunePolicy(
                selection: CapabilitySelection(
                    enabledConnections: [.xiaomiCloud],
                    enabledConnectionScopes: ["mi:acc1"],
                    enabledFeatures: [],
                    enabledCategories: Set(DeviceCategoryID.allCases).subtracting([cardCategory])
                ),
                safetyPolicy: SafetyRetentionPolicy(),
                sourceScope: "mi:acc1"
            )
            let closedPlan = MiotSynthesizer.typePrunePlan(
                devices: records, rooms: [], specs: [model: deviceSpec], policy: closeCategoryPolicy
            )
            #expect(
                Set(closedPlan.hiddenIndexedDevices.map(\.id)) == Set(home.devices.map(\.id)),
                "\(c.id): closed plan indexes every split card and no parent"
            )
            for entry in closedPlan.hiddenIndexedDevices {
                #expect(entry.category == cardCategory, "\(c.id): \(entry.id) category")
            }
        }
    }

    // MARK: - All Types Enabled Invariant

    @Test("Enabling allSupportedTypes keeps MIoT read plans and HA/MIoT synthesized cards identical to unpruned")
    func allSupportedTypesPresetLeavesReadPlansAndCardsUnchanged() throws {
        let sampleModels: [(did: String, model: String)] = [
            ("curtain", "090615.curtain.1mcu01"),
            ("light", "miot.light.hyz05"),
            ("plug", "090615.plug.cmp86"),
            ("fan", "123888.fan.1121"),
            ("leak", "bkxh.flood.yf02"),
        ]
        var specs: [String: MiotDeviceSpec] = [:]
        for entry in sampleModels { specs[entry.model] = try Self.spec(entry.model) }
        let records = sampleModels.map { MiDeviceRecord(did: $0.did, name: $0.did, model: $0.model, isOnline: true) }

        let allTypesSelection = CapabilitySelection(
            enabledConnections: [.xiaomiCloud, .homeAssistant],
            enabledConnectionScopes: ["mi:acc1", HATypePruningTests.scope],
            enabledFeatures: [],
            enabledCategories: DeviceCategoryPreset.allSupportedTypes.categorySet
        )
        let miPlan = MiotSynthesizer.typePrunePlan(
            devices: records,
            rooms: [],
            specs: specs,
            policy: MiotTypePrunePolicy(
                selection: allTypesSelection,
                safetyPolicy: SafetyRetentionPolicy(enabledSignals: [.leak]),
                sourceScope: "mi:acc1"
            )
        )
        let legacyKeys = MiotSynthesizer.legacyPropKeys(devices: records, specs: specs)
        #expect(!miPlan.isPruned)
        #expect(miPlan.readKeys == legacyKeys)
        #expect(miPlan.hiddenDeviceIds.isEmpty)
        #expect(miPlan.hiddenIndexedDevices.isEmpty)
        #expect(miPlan.visibleRecords == records)
        #expect(
            MiotSynthesizer.synthesize(devices: miPlan.visibleRecords, rooms: [], specs: specs, values: [:])
                == MiotSynthesizer.synthesize(devices: records, rooms: [], specs: specs, values: [:])
        )

        // Home Assistant: every fixture round under `allSupportedTypes` equals `.unpruned`.
        let haPolicy = HATypePrunePolicy(
            selection: allTypesSelection,
            safetyPolicy: SafetyRetentionPolicy(enabledSignals: [.leak]),
            sourceScope: HATypePruningTests.scope
        )
        #expect(haPolicy.prunesNothing)
        for name in HATypePruningTests.fixtureNames {
            let root = try HATypePruningTests.fixture(name)
            let (_, baseline, _) = try HATypePruningTests.load(root, policy: .unpruned)
            let (_, actual, report) = try HATypePruningTests.load(root, policy: haPolicy)
            #expect(actual == baseline, "\(name): card output unchanged")
            #expect(report?.isEmpty ?? true, "\(name): no pruned entries")
        }
    }

    // MARK: - Fixed Assertions: Leak Retention & Zero-Write Gate

    private static func buildTypeIndexPlans(
        home: TypeIndexHome,
        selection: CapabilitySelection,
        safetySignals: [SafetySignalKind]
    ) throws -> (
        miPlan: MiotTypePrunePlan,
        miSpecs: [String: MiotDeviceSpec],
        haPlan: HATypePrunePlan?,
        haHome: SynthesizedHome,
        haEntities: [HAEntityEntry],
        haStateMap: [String: HAEntityState]
    ) {
        let miRecords = home.xiaomiCloud.records.map {
            MiDeviceRecord(did: $0.did, name: $0.name, model: $0.model, isOnline: true)
        }
        var miSpecs: [String: MiotDeviceSpec] = [:]
        for r in miRecords { miSpecs[r.model] = try Self.spec(r.model) }
        let safetyPolicy = SafetyRetentionPolicy(enabledSignals: Set(safetySignals))
        let miPlan = MiotSynthesizer.typePrunePlan(
            devices: miRecords,
            rooms: [],
            specs: miSpecs,
            policy: MiotTypePrunePolicy(
                selection: selection,
                safetyPolicy: safetyPolicy,
                sourceScope: home.xiaomiCloud.connectionScope
            )
        )

        let haSynth = Self.synthesizeHA(
            deviceId: "d-type-index",
            device: home.homeAssistant.device,
            states: home.homeAssistant.states
        )
        let cardEntities = DeviceSynthesizer.haCardEntities(
            cardIds: Set(haSynth.home.devices.map(\.id)),
            entities: haSynth.entities
        )
        let haPlan = DeviceSynthesizer.haTypePrunePlan(
            home: haSynth.home,
            cardEntities: cardEntities,
            states: haSynth.stateMap,
            policy: HATypePrunePolicy(
                selection: selection,
                safetyPolicy: safetyPolicy,
                sourceScope: home.homeAssistant.connectionScope
            )
        )
        return (miPlan, miSpecs, haPlan, haSynth.home, haSynth.entities, haSynth.stateMap)
    }

    @Test("Fixed assertion 1: closed sensor type keeps leak reads and alerts until leak alert is turned off")
    func leakCasesRetainSensorReadAndAlertUntilAlertIsDisabled() throws {
        let mapping = try Self.loadMapping()
        #expect(mapping.leakCases.count == 2)

        for c in mapping.leakCases {
            let sel = Self.selection(from: c.selection)
            #expect(!sel.enabledCategories.contains(.sensor), "\(c.id)")

            let built = try Self.buildTypeIndexPlans(
                home: mapping.typeIndexHome,
                selection: sel,
                safetySignals: c.safetySignals
            )
            let mi = built.miPlan
            let leakIndexEntry = try #require(
                mi.hiddenIndexedDevices.first(where: { $0.id == c.leakDid }),
                "\(c.id): leak sensor must be in hidden index"
            )
            #expect(leakIndexEntry.category == .sensor, "\(c.id)")
            #expect(mi.visibleDeviceIds == Set(c.expectedAvailableDids), "\(c.id)")
            #expect(mi.safetyRetainedDeviceIds == Set(c.expectedRetainedDids), "\(c.id)")
            #expect(!mi.visibleRecords.contains(where: { $0.did == c.leakDid }), "\(c.id): never on panel")

            let actualLeakReads = Set(
                mi.readKeys
                    .filter { $0.did == c.leakDid }
                    .map { PropRef(siid: $0.siid, piid: $0.piid) }
            )
            #expect(actualLeakReads == Set(c.expectedLeakReadKeys), "\(c.id)")

            var values: [MiotPropKey: JSONValue] = [:]
            let alertKey = MiotPropKey(did: c.leakDid, siid: c.alertKey.siid, piid: c.alertKey.piid)
            if mi.readKeys.contains(alertKey) {
                values[alertKey] = c.alertValue
            }
            let evaluated = MiotSynthesizer.synthesize(
                devices: mi.safetyRecords, rooms: [], specs: built.miSpecs, values: values
            )
            let alertPolicy = SensorAlertPolicy(
                enabled: [.leak: c.safetySignals.contains(.leak)],
                onlyWhenAway: false,
                includesAway: true
            )
            let result = SensorAlerts.evaluate(
                devices: evaluated.devices,
                ledger: [:],
                now: Date(timeIntervalSince1970: 1_700_000_000),
                calendar: Calendar(identifier: .gregorian),
                policy: alertPolicy
            )
            #expect((!result.alerts.isEmpty) == c.expectLeakAlert, "\(c.id)")
        }
    }

    @Test("Fixed assertion 2: closed-type hidden targets and unknown IDs are rejected with zero writes")
    func zeroWriteCasesRejectHiddenTargetsFromRealPrunePlanIndex() throws {
        let mapping = try Self.loadMapping()
        #expect(mapping.zeroWriteCases.count == 3)

        for c in mapping.zeroWriteCases {
            let sel = Self.selection(from: c.selection)
            let built = try Self.buildTypeIndexPlans(
                home: mapping.typeIndexHome,
                selection: sel,
                safetySignals: c.safetySignals
            )
            let index = built.miPlan.hiddenIndexedDevices + (built.haPlan?.hiddenIndexedDevices ?? [])

            let targetId: String
            if c.target.source == "xiaomi-cloud" {
                targetId = try #require(c.target.did, "\(c.id): missing target did")
            } else {
                let entityId = try #require(c.target.entityId, "\(c.id): missing target entityId")
                targetId = built.haHome.devices.first(where: { $0.referencedEntityIds.contains(entityId) })?.id ?? entityId
            }

            let mapped = index.first(where: { $0.id == targetId })?.category
            #expect(mapped == c.expectedMappedCategory, "\(c.id)")

            let verdict = CapabilityReferenceEngine.evaluateControlTargetGate(
                targetKind: .device,
                targetId: targetId,
                candidateIds: [],
                selection: sel,
                devices: index
            )
            #expect(verdict.allowed == c.expectedAllowed, "\(c.id)")
            #expect(verdict.writeCount == c.expectedWriteCount, "\(c.id)")
            #expect(verdict.rejectionReason?.code == c.expectedRejectionCode, "\(c.id)")
            if let mapped {
                #expect(verdict.rejectionReason == .categoryDisabled(mapped), "\(c.id)")
            }
        }
    }

    @Test("HomeStore with lightAndSwitch preset retains leak alerts and blocks writes to hidden Mi and HA targets")
    @MainActor
    func homeStoreEndToEndLightAndSwitchPresetRetainsLeakAlertAndBlocksHiddenWrites() async throws {
        let mapping = try Self.loadMapping()
        let leakCase = try #require(mapping.leakCases.first { $0.expectLeakAlert })
        let sel = Self.selection(from: leakCase.selection)
        let built = try Self.buildTypeIndexPlans(
            home: mapping.typeIndexHome,
            selection: sel,
            safetySignals: leakCase.safetySignals
        )

        let visibleMiHome = MiotSynthesizer.synthesize(
            devices: built.miPlan.visibleRecords, rooms: [], specs: built.miSpecs, values: [:]
        )
        let alertKey = MiotPropKey(did: leakCase.leakDid, siid: leakCase.alertKey.siid, piid: leakCase.alertKey.piid)
        let safetyMiHome = MiotSynthesizer.synthesize(
            devices: built.miPlan.safetyRecords,
            rooms: [],
            specs: built.miSpecs,
            values: [alertKey: leakCase.alertValue]
        )

        let defaults = InMemoryUserDefaults()
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let haURL = "http://home.local:8123"
        defaults.set(haURL, forKey: "ha_server_url")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        _ = KeychainHelper.saveToken("ha-token", defaults: defaults, vault: vault)

        var snapshot = visibleMiHome
        snapshot.isInitialLoadComplete = true
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, credentialVault: vault, defaults: defaults)
        try await store.waitForTestSnapshot()
        store.toastAutoDismissInterval = nil

        // Apply the lightAndSwitch preset and enable both scopes from the shared corpus.
        store.capabilitySelection = CapabilitySelection(
            enabledConnections: [.xiaomiCloud, .homeAssistant],
            enabledConnectionScopes: [mapping.typeIndexHome.xiaomiCloud.connectionScope, store.homeAssistantScopeIdentifier],
            enabledFeatures: [],
            enabledCategories: DeviceCategoryPreset.lightAndSwitch.categorySet
        )
        let miReport = MiotTypePruneReport(
            scope: mapping.typeIndexHome.xiaomiCloud.connectionScope,
            hiddenIndexedDevices: built.miPlan.hiddenIndexedDevices,
            hiddenDeviceIds: built.miPlan.hiddenDeviceIds,
            safetyDevices: safetyMiHome.devices
        )
        let haPlan = try #require(built.haPlan)
        let haReport = MiotTypePruneReport(
            scope: store.homeAssistantScopeIdentifier,
            hiddenIndexedDevices: haPlan.hiddenIndexedDevices.map { entry in
                CapabilityIndexedDevice(
                    id: entry.id, name: entry.name, category: entry.category,
                    connection: entry.connection, sourceScope: store.homeAssistantScopeIdentifier,
                    isSourceAvailable: entry.isSourceAvailable,
                    upstreamHiddenOrDisabled: entry.upstreamHiddenOrDisabled,
                    participatesInAllOff: entry.participatesInAllOff,
                    safetySignals: entry.safetySignals,
                    readKeys: entry.readKeys, safetyReadKeys: entry.safetyReadKeys
                )
            },
            hiddenDeviceIds: Set(haPlan.hiddenIndexedDevices.map(\.id)),
            safetyDevices: []
        )
        store.applyMiotTypePruneReport(miReport)
        store.handleProviderEvent(.haTypePruneChanged(haReport))

        // Panel shows only the light; hidden leak sensor still raises alert and lights hazard indicator.
        #expect(store.devices.map(\.id) == ["101"])
        #expect(store.typeHiddenSafetyDevices.map(\.id) == ["105"])
        #expect(store.menuBarShowsHazard)
        #expect(store.recentSafetyAlerts.contains { $0.alert.deviceId == "105" })

        // Host write gate blocks hidden sensor and hidden gas valve with zero writes.
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
