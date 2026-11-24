import Foundation
import Testing
@testable import MijiaCore

struct AutomationContextStackTests {
    private func snapshot(_ id: String, baseline: Bool, applied: Bool) -> AutomationContextSnapshot {
        AutomationContextSnapshot(
            deviceID: id,
            baseline: AutomationContextValue(field: .power, boolValue: baseline),
            applied: AutomationContextValue(field: .power, boolValue: applied)
        )
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
}
