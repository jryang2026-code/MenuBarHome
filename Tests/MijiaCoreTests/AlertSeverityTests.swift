import Foundation
import Testing
@testable import MijiaCore

/// R16 §1.5: the two-level alert severity table is one shared contract. Windows reads the same
/// fixture in `windows/tests/alertSeverity.test.ts`.
struct AlertSeverityTests {
    private struct Golden: Decodable {
        let schemaVersion: Int
        let severities: [String: String]
    }

    private func golden() throws -> Golden {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Tests/Fixtures/alert_severity_golden.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: candidate))
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("Every macOS sensor kind matches the shared severity fixture")
    func kindTableMatchesGolden() throws {
        let golden = try golden()
        #expect(golden.schemaVersion == 1)
        #expect(Set(SensorAlertKind.allCases.map(\.rawValue)).isSubset(of: Set(golden.severities.keys)))
        for kind in SensorAlertKind.allCases {
            #expect(golden.severities[kind.rawValue] == kind.severity.rawValue, "\(kind.rawValue)")
        }
    }

    @Test("Every kind delivers through Focus according to the fixture", arguments: SensorAlertKind.allCases)
    func deliveryFollowsGolden(kind: SensorAlertKind) throws {
        let golden = try golden()
        let fixtureSeverity = try #require(golden.severities[kind.rawValue])
        let severity = try #require(AlertSeverity(rawValue: fixtureSeverity))
        #expect(severity == kind.severity)

        let alert = SafetyAlert(
            id: "sensor:\(kind.rawValue):device:123",
            deviceId: "device",
            title: "",
            body: ""
        )
        #expect(alert.severity == severity)

        let ordinary = NotificationDeliveryPolicy.resolve(for: .safetyAlert(alert), isFocusActive: false)
        let focused = NotificationDeliveryPolicy.resolve(for: .safetyAlert(alert), isFocusActive: true)
        #expect(ordinary.interruptionLevel == (severity == .alert ? .timeSensitive : .active))
        #expect(focused.interruptionLevel == (severity == .alert ? .timeSensitive : .passive))
        #expect(ordinary.relevanceScore == 1)
        #expect(focused.relevanceScore == 1)
    }

    @Test("Non-sensor safety alerts stay out of the sensor severity table")
    func nonSensorAlertsHaveNoSeverity() {
        let battery = SafetyAlert(id: "battery:device", deviceId: "device", title: "", body: "")
        #expect(battery.severity == nil)
        #expect(NotificationDeliveryPolicy.resolve(for: .safetyAlert(battery), isFocusActive: false).interruptionLevel == .active)
        #expect(NotificationDeliveryPolicy.resolve(for: .safetyAlert(battery), isFocusActive: true).interruptionLevel == .passive)
    }

    @Test("Downstream flags agree with severity")
    func downstreamFlagsAgree() {
        for kind in SensorAlertKind.allCases {
            #expect(kind.enabledByDefault == (kind.severity == .alert))
            #expect(kind.colorsMenuBar == (kind.severity == .alert))
            #expect(kind.notifiesOnFirstSample == (kind.severity == .alert))
            #expect(kind.honorsAwayLimit == (kind.severity == .warning))
        }
    }

    @Test("Alert ranks before warning")
    func ranksOrderAlertsFirst() {
        #expect(AlertSeverity.allCases.sorted { $0.sortRank < $1.sortRank } == [.alert, .warning])
    }
}
