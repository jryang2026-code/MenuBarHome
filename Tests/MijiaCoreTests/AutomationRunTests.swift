import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct AutomationRunTests {
    private struct Fixture: Decodable {
        struct Start: Decodable {
            let time: Int
            let mode: AutomationExecutionMode
            let accepted: Bool
        }
        let reasons: [String]
        let starts: [Start]
    }

    @Test func runStateMatchesGoldenFixture() throws {
        let url = try GoldenCorpusTests.locateGoldenFixture("Tests/Fixtures/automation_run_golden.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(AutomationSkipReason.allCases.map(\.rawValue) == fixture.reasons)
        var state = AutomationRunState()
        var tokens: [Int: UUID] = [:]
        for start in fixture.starts {
            let token = UUID()
            tokens[start.time] = token
            #expect(state.start(token, mode: start.mode) == start.accepted)
        }
        for time in [1000, 1002] {
            let old = try #require(tokens[time])
            #expect(!state.owns(old))
            state.finish(old)
        }
        let newest = try #require(tokens[1003])
        #expect(state.owns(newest))
        state.finish(newest)
        #expect(!state.isRunning)
    }

    @MainActor @Test func historyPersistsBoundedEntries() {
        let defaults = InMemoryUserDefaults()
        let store = HomeStore(defaults: defaults)
        let rule = AutomationRule(trigger: .back, action: .quickAction(.lightsOff))
        for time in 0...200 {
            store.recordAutomationRun(rule, at: Date(timeIntervalSince1970: Double(time)), reason: .conditionFalse)
        }
        let restored = HomeStore(defaults: defaults).automationRunHistory
        #expect(restored.count == 200)
        #expect(restored.first?.time == Date(timeIntervalSince1970: 200))
        #expect(restored.last?.time == Date(timeIntervalSince1970: 1))
    }
}
