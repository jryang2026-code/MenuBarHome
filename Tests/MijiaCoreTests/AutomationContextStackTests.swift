import Foundation
import Testing
@testable import MijiaCore

struct AutomationContextStackTests {
    private struct ContextStackGolden: Decodable {
        let version: Int
        let maxAgeHours: TimeInterval
        let cases: [GoldenCase]

        struct GoldenCase: Decodable {
            let name: String
            let enter: [GoldenEntry]
            let exit: GoldenExit

            private enum CodingKeys: String, CodingKey { case name, enter, exit }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                if let single = try? container.decode(GoldenEntry.self, forKey: .enter) {
                    enter = [single]
                } else {
                    enter = try container.decode([GoldenEntry].self, forKey: .enter)
                }
                exit = try container.decode(GoldenExit.self, forKey: .exit)
            }
        }

        struct GoldenEntry: Decodable {
            let device: String
            let before: Bool
            let applied: Bool
        }

        struct GoldenExit: Decodable {
            let live: Bool
            let restored: Bool?
        }
    }

    private func snapshot(_ id: String, baseline: Bool, applied: Bool) -> AutomationContextSnapshot {
        AutomationContextSnapshot(
            deviceID: id,
            baseline: AutomationContextValue(field: .power, boolValue: baseline),
            applied: AutomationContextValue(field: .power, boolValue: applied)
        )
    }

    @Test("Cross-platform context stack golden JSON corpus matches Swift AutomationContextStack")
    func contextStackGoldenCorpusParity() throws {
        let fixtureURL = try GoldenCorpusTests.locateGoldenFixture("Tests/Fixtures/context_stack_golden.json")
        let golden = try JSONDecoder().decode(ContextStackGolden.self, from: Data(contentsOf: fixtureURL))
        #expect(golden.version == 1)
        #expect(AutomationContextStack.maximumAge == golden.maxAgeHours * 60 * 60)

        let start = Date(timeIntervalSince1970: 100_000)
        for testCase in golden.cases {
            let stack = AutomationContextStack()
            var ruleIDs: [UUID] = []
            for (index, entry) in testCase.enter.enumerated() {
                let ruleID = UUID()
                ruleIDs.append(ruleID)
                stack.push(
                    ruleID: ruleID,
                    snapshots: [snapshot(entry.device, baseline: entry.before, applied: entry.applied)],
                    at: start.addingTimeInterval(TimeInterval(index))
                )
            }
            guard let last = testCase.enter.last, let ruleID = ruleIDs.last else { continue }
            let expected: [DeviceIntent] = testCase.exit.restored.map {
                [DeviceIntent(targetId: last.device, operation: .power($0))]
            } ?? []
            let intents = stack.pop(
                ruleID: ruleID,
                liveValues: [last.device: AutomationContextValue(field: .power, boolValue: testCase.exit.live)],
                at: start.addingTimeInterval(TimeInterval(testCase.enter.count))
            )
            #expect(intents == expected, "\(testCase.name)")
        }
    }

    @Test("Context restore is LIFO and respects manual takeover")
    func nestingAndTakeover() {
        let stack = AutomationContextStack()
        let outer = UUID()
        let inner = UUID()
        let start = Date(timeIntervalSince1970: 100)
        stack.push(ruleID: outer, snapshots: [snapshot("lamp", baseline: true, applied: false)], at: start)
        stack.push(ruleID: inner, snapshots: [snapshot("lamp", baseline: false, applied: true)], at: start.addingTimeInterval(1))

        let innerRestore = stack.pop(
            ruleID: inner,
            liveValues: ["lamp": AutomationContextValue(field: .power, boolValue: true)],
            at: start.addingTimeInterval(2)
        )
        #expect(innerRestore == [DeviceIntent(targetId: "lamp", operation: .power(false))])

        let manual = stack.pop(
            ruleID: outer,
            liveValues: ["lamp": AutomationContextValue(field: .power, boolValue: true)],
            at: start.addingTimeInterval(3)
        )
        #expect(manual.isEmpty)
    }

    @Test("Expired frames are discarded without producing writes")
    func expiry() {
        let stack = AutomationContextStack()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 100)
        stack.push(ruleID: id, snapshots: [snapshot("lamp", baseline: true, applied: false)], at: start)
        #expect(stack.pop(ruleID: id, liveValues: ["lamp": AutomationContextValue(field: .power, boolValue: false)], at: start.addingTimeInterval(AutomationContextStack.maximumAge + 1)).isEmpty)
        #expect(stack.isEmpty)
    }

    @Test("A restore plan keeps its frame until the provider confirms the write")
    func failedRestoreCanRetry() throws {
        let stack = AutomationContextStack()
        let rule = UUID()
        let start = Date(timeIntervalSince1970: 100)
        stack.push(ruleID: rule, snapshots: [snapshot("lamp", baseline: true, applied: false)], at: start)

        let frame = try #require(stack.allFrames.first)
        let plan = try #require(stack.prepareRestore(
            frame: frame,
            liveValues: ["lamp": AutomationContextValue(field: .power, boolValue: false)],
            at: start.addingTimeInterval(1)
        ))
        #expect(plan.intents == [DeviceIntent(targetId: "lamp", operation: .power(true))])
        stack.commitRestore(plan, restoredDeviceIDs: [])
        #expect(stack.count == 1)
        stack.commitRestore(plan, restoredDeviceIDs: ["lamp"])
        #expect(stack.isEmpty)
    }

    @Test("Partial confirmation removes only the snapshots that were restored")
    func partialRestoreRetainsUnrestoredSnapshots() throws {
        let stack = AutomationContextStack()
        let rule = UUID()
        let start = Date(timeIntervalSince1970: 100)
        stack.push(ruleID: rule, snapshots: [
            snapshot("lamp", baseline: true, applied: false),
            snapshot("fan", baseline: false, applied: true)
        ], at: start)
        let plan = try #require(stack.prepareRestore(frame: stack.allFrames[0], liveValues: [
            "lamp": AutomationContextValue(field: .power, boolValue: false),
            "fan": AutomationContextValue(field: .power, boolValue: true)
        ], at: start.addingTimeInterval(1)))
        stack.commitRestore(plan, restoredDeviceIDs: ["lamp"])
        #expect(stack.allFrames.first?.snapshots.map(\.deviceID) == ["fan"])
    }

    @Test("Frames sharing an exit trigger can restore newest-first to the original baseline")
    func sharedExitRestoresNewestFirst() {
        let stack = AutomationContextStack()
        let older = UUID()
        let newer = UUID()
        let start = Date(timeIntervalSince1970: 100)
        stack.push(ruleID: older, snapshots: [snapshot("lamp", baseline: true, applied: false)], at: start)
        stack.push(ruleID: newer, snapshots: [snapshot("lamp", baseline: false, applied: true)], at: start.addingTimeInterval(1))

        let inner = stack.pop(
            ruleID: newer,
            liveValues: ["lamp": AutomationContextValue(field: .power, boolValue: true)],
            at: start.addingTimeInterval(2)
        )
        #expect(inner == [DeviceIntent(targetId: "lamp", operation: .power(false))])
        let outer = stack.pop(
            ruleID: older,
            liveValues: ["lamp": AutomationContextValue(field: .power, boolValue: false)],
            at: start.addingTimeInterval(3)
        )
        #expect(outer == [DeviceIntent(targetId: "lamp", operation: .power(true))])
        #expect(stack.isEmpty)
    }

    @Test("The frame cap keeps the newest 32 entries")
    func frameCap() {
        let stack = AutomationContextStack()
        for index in 0...AutomationContextStack.maximumFrames {
            _ = stack.push(
                ruleID: UUID(),
                snapshots: [snapshot("lamp-\(index)", baseline: false, applied: true)],
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        #expect(stack.count == AutomationContextStack.maximumFrames)
        #expect(stack.allFrames.first?.snapshots.first?.deviceID == "lamp-1")
    }
}
