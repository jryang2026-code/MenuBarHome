import Foundation
import Testing
@testable import MijiaCore

struct HomeSummaryAndSlotBudgetTests {
    // MARK: - Golden Fixture Helpers

    private static func fixtureURL(_ filename: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Tests/Fixtures/\(filename)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    // MARK: - HomeSummary Golden Fixture

    private struct HomeSummaryGolden: Decodable {
        let schemaVersion: Int
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let devices: [DeviceFixture]
            let alerts: [AlertFixture]
            let lightMarkedSwitchIds: [String]
            let expected: [ExpectedCapsule]
        }

        struct DeviceFixture: Decodable {
            let id: String
            let kind: String
            let isOnline: Bool
            let isOn: Bool?
            let positionPercent: Int?
            let contactAlarming: Bool?
            let temperature: Double?
            let currentTemperature: Double?
        }

        struct AlertFixture: Decodable {
            let id: String
            let deviceId: String
        }

        struct ExpectedCapsule: Decodable {
            let kind: String
            let count: Int
            let temperatureCelsius: Double?
            let alertSeverity: String?
            let targetDeviceIds: [String]
            let filterTag: String?
        }
    }

    private static func makeDevice(_ fixture: HomeSummaryGolden.DeviceFixture) -> SmartDevice {
        let kind: DeviceKind = switch fixture.kind {
        case "light":
            .light(LightSpec(entityId: "light.\(fixture.id)", isOn: fixture.isOn ?? false))
        case "plug":
            .plug(PlugSpec(switchEntityId: "switch.\(fixture.id)", isOn: fixture.isOn ?? false))
        case "cover":
            .cover(CoverSpec(entityId: "cover.\(fixture.id)", subtype: .curtain, positionPercent: fixture.positionPercent))
        case "climate":
            .climate(ClimateSpec(
                entityId: "climate.\(fixture.id)",
                isOn: fixture.isOn ?? false,
                hvacMode: (fixture.isOn ?? false) ? "cool" : "off",
                availableModes: ["off", "cool"],
                targetTemperature: 24,
                currentTemperature: fixture.currentTemperature
            ))
        default:
            .sensor(SensorSpec(
                temperature: fixture.temperature,
                observations: fixture.contactAlarming == true
                    ? [SensorObservation(sourceId: "contact.\(fixture.id)", kind: .contact, alarming: true)]
                    : []
            ))
        }
        return SmartDevice(
            id: fixture.id,
            name: fixture.id,
            roomId: "living",
            roomName: "客厅",
            model: "",
            isOnline: fixture.isOnline,
            kind: kind
        )
    }

    @Test("HomeSummary matches shared home_summary_golden.json fixture")
    func homeSummaryMatchesGolden() throws {
        let data = try Data(contentsOf: Self.fixtureURL("home_summary_golden.json"))
        let golden = try JSONDecoder().decode(HomeSummaryGolden.self, from: data)
        #expect(golden.schemaVersion == 1)
        #expect(!golden.cases.isEmpty)

        for testCase in golden.cases {
            let devices = testCase.devices.map(Self.makeDevice)
            let alerts = testCase.alerts.map {
                SafetyAlert(id: $0.id, deviceId: $0.deviceId, title: "", body: "")
            }
            let summary = HomeSummary.compute(
                devices: devices,
                alerts: alerts,
                lightMarkedSwitchIds: Set(testCase.lightMarkedSwitchIds)
            )
            #expect(summary.isEmpty == testCase.expected.isEmpty, "\(testCase.name)")
            #expect(summary.capsules.count == testCase.expected.count, "\(testCase.name)")
            for (actual, expected) in zip(summary.capsules, testCase.expected) {
                #expect(actual.kind.rawValue == expected.kind, "\(testCase.name)")
                #expect(actual.count == expected.count, "\(testCase.name)")
                #expect(actual.alertSeverity?.rawValue == expected.alertSeverity, "\(testCase.name)")
                #expect(actual.targetDeviceIds == expected.targetDeviceIds, "\(testCase.name)")
                #expect(actual.filterTag?.rawValue == expected.filterTag, "\(testCase.name)")
                if let expectedTemp = expected.temperatureCelsius {
                    let actualTemp = try #require(actual.temperatureCelsius)
                    #expect(abs(actualTemp - expectedTemp) < 0.001, "\(testCase.name)")
                } else {
                    #expect(actual.temperatureCelsius == nil, "\(testCase.name)")
                }
            }
        }
    }

    @Test("HomeSummary capsule titles localize in zh-Hans, zh-Hant, en and convert °F")
    func capsuleTitlesLocalizationAndTemperatureUnit() {
        let capsules = [
            HomeSummaryCapsule(kind: .alerts, count: 1, alertSeverity: .alert),
            HomeSummaryCapsule(kind: .lightsOn, count: 3),
            HomeSummaryCapsule(kind: .doorsOpen, count: 2),
            HomeSummaryCapsule(kind: .indoorTemp, count: 1, temperatureCelsius: 24.0),
        ]

        let zhHans = L10n.$overrideLanguage.withValue(.zhHans) {
            capsules.map { $0.title(temperatureUnit: .celsius) }
        }
        #expect(zhHans == ["1 条告警", "3 盏灯开着", "2 处门窗开着", "室内 24°"])

        let zhHant = L10n.$overrideLanguage.withValue(.zhHant) {
            capsules.map { $0.title(temperatureUnit: .celsius) }
        }
        #expect(zhHant == ["1 條告警", "3 盞燈開著", "2 處門窗開著", "室內 24°"])

        let enFahrenheit = L10n.$overrideLanguage.withValue(.en) {
            capsules.map { $0.title(temperatureUnit: .fahrenheit) }
        }
        #expect(enFahrenheit == ["1 alert", "3 lights on", "2 doors/windows open", "Indoor 75°"])

        let average = HomeSummaryCapsule(kind: .indoorTemp, count: 3, temperatureCelsius: 25.8)
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(average.title(temperatureUnit: .celsius) == "室内均温 25.8°")
            #expect(average.title(temperatureUnit: .fahrenheit) == "室内均温 78°")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(average.title(temperatureUnit: .celsius) == "Indoor avg 25.8°")
        }
    }

    @Test("showHomeSummaryRow defaults to true and persists across HomeStore instances")
    @MainActor
    func showHomeSummaryRowSettingPersists() {
        let suite = "HomeSummarySettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: DemoHomeProvider(), defaults: defaults)
        #expect(store.showHomeSummaryRow == true)
        store.showHomeSummaryRow = false

        let reloaded = HomeStore(provider: DemoHomeProvider(), defaults: defaults)
        #expect(reloaded.showHomeSummaryRow == false)
    }

    // MARK: - SlotBudget Golden Fixture

    private struct SlotBudgetGolden: Decodable {
        let schemaVersion: Int
        let defaultBudget: Int
        let slotCosts: [String: Int]
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let budget: Int
            let items: [ItemFixture]
            let keepingVisibleIds: [String]
            let expectedVisibleIds: [String]
            let expectedHiddenIds: [String]
            let expectedUsedSlots: Int
            let expectedEffectiveBudget: Int
        }

        struct ItemFixture: Decodable {
            let id: String
            let size: String
            let isPinned: Bool
        }
    }

    @Test("OverviewSlotBudget matches shared slot_budget_golden.json fixture")
    func slotBudgetMatchesGolden() throws {
        let data = try Data(contentsOf: Self.fixtureURL("slot_budget_golden.json"))
        let golden = try JSONDecoder().decode(SlotBudgetGolden.self, from: data)
        #expect(golden.schemaVersion == 1)
        #expect(OverviewSlotBudget.defaultBudget == golden.defaultBudget)

        for size in OverviewSlotSize.allCases {
            #expect(golden.slotCosts[size.rawValue] == size.slotCost, "\(size.rawValue)")
        }

        for testCase in golden.cases {
            let items = try testCase.items.map { item in
                let size = try #require(OverviewSlotSize(rawValue: item.size))
                return OverviewSlotItem(id: item.id, size: size, isPinned: item.isPinned)
            }
            let result = OverviewSlotBudget.select(
                items: items,
                budget: testCase.budget,
                keepingVisibleIds: Set(testCase.keepingVisibleIds)
            )
            #expect(result.visibleIds == testCase.expectedVisibleIds, "\(testCase.name)")
            #expect(result.hiddenIds == testCase.expectedHiddenIds, "\(testCase.name)")
            #expect(result.usedSlots == testCase.expectedUsedSlots, "\(testCase.name)")
            #expect(result.effectiveBudget == testCase.expectedEffectiveBudget, "\(testCase.name)")
            #expect(result.hiddenCount == testCase.expectedHiddenIds.count, "\(testCase.name)")
            #expect(result.hasOverflow == !testCase.expectedHiddenIds.isEmpty, "\(testCase.name)")
        }
    }
}
