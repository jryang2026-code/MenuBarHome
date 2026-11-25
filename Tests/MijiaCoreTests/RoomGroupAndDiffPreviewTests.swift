import Foundation
import StateTestSupport
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RoomGroupAndDiffPreviewTests {
    private func dev(
        _ id: String, name: String? = nil, _ kind: DeviceKind,
        roomId: String = "living", roomName: String = "客厅", online: Bool = true
    ) -> SmartDevice {
        SmartDevice(id: id, name: name ?? id, roomId: roomId, roomName: roomName, model: "", isOnline: online, kind: kind)
    }

    private func makeStore(_ snapshot: SynthesizedHome) async throws -> (HomeStore, MockHomeProvider) {
        let provider = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.roomgroup.\(UUID())")
        store.assistantAutoResetTiming = .never
        try await store.waitForTestSnapshot()
        return (store, provider)
    }

    @Test func circularHueMeanWrapsAcrossZeroAndAggregatesRoomLights() throws {
        let wrapped = try #require(HueMath.circularMean([350, 10]))
        #expect(wrapped < 0.001 || abs(wrapped - 360) < 0.001)
        #expect(abs(try #require(HueMath.circularMean([60, 120])) - 90) < 0.001)
        #expect(HueMath.circularMean([]) == nil)
        #expect(HueMath.circularMean([0, 180]) == nil)

        let lights = [
            dev("l1", .light(.init(entityId: "light.1", isOn: true, brightnessPercent: 80, hueDegrees: 350))),
            dev("l2", .light(.init(entityId: "light.2", isOn: true, brightnessPercent: 40, hueDegrees: 10))),
            dev("l3", .light(.init(entityId: "light.3", isOn: false, brightnessPercent: 10, hueDegrees: 180))),
            dev("p1", .plug(.init(switchEntityId: "switch.1", isOn: false))),
        ]
        let groups = RoomAutoGroup.build(roomId: "living", roomName: "客厅", devices: lights)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.kind == .light && group.count == 3 && group.isAnyOn && group.activeCount == 2)
        #expect(group.averageBrightness == 60)
        #expect(try #require(group.averageHueDegrees) < 0.001)
        L10n.$overrideLanguage.withValue(.zhHans) { #expect(group.label == "客厅 3 盏灯") }
        L10n.$overrideLanguage.withValue(.en) { #expect(group.label == "客厅 3 lights") }
    }

    @Test func coverGroupCommandIgnoresIntermediateUpdatesFor60Seconds() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        func curtain(_ id: String, _ pos: Int, _ motion: CoverMotion = .stopped) -> SmartDevice {
            dev(id, .cover(.init(entityId: "cover.\(id)", subtype: .curtain, positionPercent: pos,
                                 reportedPositionPercent: pos, positionWritable: true, motion: motion)))
        }
        let (store, provider) = try await makeStore(SynthesizedHome(devices: [curtain("c1", 0), curtain("c2", 0)]))
        store.optimisticNow = { start }

        let group = try #require(store.roomAutoGroups(for: "living", roomName: "客厅").first)
        guard case .executed = await store.toggleRoomGroup(group) else { Issue.record("Expected executed"); return }
        #expect(await provider.executedCommands == [
            .setNumberValue(entityId: "cover.c1", value: 100), .setNumberValue(entityId: "cover.c2", value: 100),
        ])

        let at30s = start.addingTimeInterval(30)
        store.optimisticNow = { at30s }
        let gen1 = store.snapshotGeneration
        await provider.updateSnapshot(SynthesizedHome(devices: [curtain("c1", 45, .opening), curtain("c2", 50, .opening)]))
        await waitUntil { store.snapshotGeneration > gen1 }
        if case .cover(let s) = store.devices.first(where: { $0.id == "c1" })?.kind { #expect(s.positionPercent == 100) }
        else { Issue.record("Missing c1") }

        let at61s = start.addingTimeInterval(61)
        store.optimisticNow = { at61s }
        let gen2 = store.snapshotGeneration
        await provider.updateSnapshot(SynthesizedHome(devices: [curtain("c1", 90), curtain("c2", 90)]))
        await waitUntil { store.snapshotGeneration > gen2 }
        if case .cover(let s) = store.devices.first(where: { $0.id == "c1" })?.kind { #expect(s.positionPercent == 90) }
        else { Issue.record("Missing c1") }
    }

    @Test func groupWriteEnforcesLockScreenCapabilitySingleConfirmationAndUndo() async throws {
        let p1 = dev("p1", name: "客厅插座A", .plug(.init(switchEntityId: "switch.p1", isOn: false)))
        let p2 = dev("p2", name: "客厅插座B", .plug(.init(switchEntityId: "switch.p2", isOn: false)))
        let (store, provider) = try await makeStore(SynthesizedHome(devices: [p1, p2]))
        let group = try #require(store.roomAutoGroups(for: "living", roomName: "客厅").first)

        var prompts = 0
        store.manualControlConfirmationHandler = { _ in prompts += 1; return true }
        store.blockControlWhileLocked = true
        store.setScreenLocked(true)
        #expect(await store.toggleRoomGroup(group) == .blocked(message: store.screenLockBlockedMessage))
        #expect(prompts == 0)
        #expect(await provider.executedCommands.isEmpty)
        store.setScreenLocked(false)

        store.capabilitySelection.enabledCategories.remove(.plug)
        #expect(store.roomAutoGroups(for: "living", roomName: "客厅").isEmpty)
        #expect(await store.toggleRoomGroup(group) == .unavailable(label: group.label))
        store.capabilitySelection.enabledCategories.insert(.plug)

        store.manualControlConfirmationHandler = { _ in prompts += 1; return false }
        #expect(await store.toggleRoomGroup(group) == .cancelled)
        #expect(prompts == 1)
        #expect(await provider.executedCommands.isEmpty)

        store.manualControlConfirmationHandler = { _ in prompts += 1; return true }
        guard case .executed = await store.toggleRoomGroup(group) else { Issue.record("Expected executed"); return }
        #expect(prompts == 2)
        let expected: [DeviceCommand] = [.setSwitch(entityId: "switch.p1", isOn: true), .setSwitch(entityId: "switch.p2", isOn: true)]
        #expect(await provider.executedCommands == expected)
        let undo = try #require(store.undoTurnAllOff())
        await undo.value
        #expect(await provider.executedCommands == expected + [
            .setSwitch(entityId: "switch.p1", isOn: false), .setSwitch(entityId: "switch.p2", isOn: false),
        ])
    }

    @Test func diffPreviewGatesMultiDeviceAndHighRiskWhileSingleLowRiskRunsDirectly() async throws {
        let l1 = dev("l1", name: "客厅主灯", .light(.init(entityId: "light.1", isOn: true, brightnessPercent: 80)))
        let l2 = dev("l2", name: "客厅射灯", .light(.init(entityId: "light.2", isOn: true, brightnessPercent: 60)))
        let p1 = dev("p1", name: "书房插座", .plug(.init(switchEntityId: "switch.p1", isOn: false)), roomId: "study", roomName: "书房")
        let rooms = [RoomArea(id: "living", name: "客厅", sortOrder: 0), RoomArea(id: "study", name: "书房", sortOrder: 1)]
        let (store, provider) = try await makeStore(SynthesizedHome(rooms: rooms, devices: [l1, l2, p1]))

        _ = await store.runAssistantCommand("关闭客厅主灯", preferDiffPreview: true)
        #expect(store.pendingDiffPreview == nil)
        #expect(await provider.executedCommands == [.setLightPower(entityId: "light.1", isOn: false)])

        _ = await store.runAssistantCommand("打开客厅灯", preferDiffPreview: true)
        let multi = try #require(store.pendingDiffPreview)
        #expect(multi.items.count == 2 && !multi.hasHighRiskDevice)
        #expect(await provider.executedCommands.count == 1)

        store.cancelPendingDiffPreview()
        #expect(store.pendingDiffPreview == nil)
        #expect(await provider.executedCommands.count == 1)

        _ = await store.runAssistantCommand("打开书房插座", preferDiffPreview: true)
        let risky = try #require(store.pendingDiffPreview)
        #expect(risky.items.count == 1 && risky.hasHighRiskDevice && risky.items.first?.deviceName == "书房插座")
        #expect(await provider.executedCommands.count == 1)

        _ = await store.confirmPendingDiffPreview()
        #expect(store.pendingDiffPreview == nil)
        #expect(await provider.executedCommands == [
            .setLightPower(entityId: "light.1", isOn: false), .setSwitch(entityId: "switch.p1", isOn: true),
        ])
    }
}
