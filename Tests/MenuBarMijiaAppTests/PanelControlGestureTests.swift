import PreferencesTestSupport
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
struct PanelControlGestureTests {
    @Test("Only existing hazardous operations receive a panel gesture")
    func confirmationLevels() {
        let valve = Self.device(.valve(ValveSpec(entityId: "valve.water", isOpen: false)))
        let garage = Self.device(.cover(CoverSpec(
            entityId: "cover.garage", subtype: .garageDoor, positionPercent: 0, positionWritable: true
        )))
        let window = Self.device(.cover(CoverSpec(
            entityId: "cover.window", subtype: .windowOpener, positionPercent: 0, positionWritable: true
        )))
        let heater = Self.device(.climate(ClimateSpec(
            entityId: "climate.heater", isOn: false, hvacMode: "off", availableModes: ["off", "heat"],
            targetTemperature: 22, minTemp: 16, maxTemp: 30
        )), name: "电暖器")
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(true), for: valve) == .slide)
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(false), for: valve) == nil)
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(true), for: garage) == .slide)
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(false), for: garage) == .slide)
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(true), for: window) == .hold)
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(false), for: window) == nil)
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(true), for: heater) == .hold)
        #expect(ManualControlPolicy.panelConfirmationLevel(.power(false), for: heater) == nil)
    }

    @Test("Releasing at 500 ms writes nothing and a completed 650 ms hold sends once")
    func holdCancelAndComplete() async throws {
        let (store, provider, device) = try await makeStore()
        store.manualControlConfirmationHandler = { _ in
            Issue.record("A completed pointer hold should answer the confirmation")
            return false
        }
        let started = ContinuousClock.now
        let aborted = try #require(store.beginPanelConfirmation(for: device, action: .primary, level: .hold))
        var hold = PanelControlGestureAttempt(startedAt: started)
        if hold.completeHold(at: started + .milliseconds(500)) {
            _ = await store.performPanelConfirmation(aborted)?.value
        }
        hold.cancel()
        let cancelled = hold.completeHold(at: started + .milliseconds(650))
        #expect(!cancelled)
        #expect(await provider.executedCommands.isEmpty)

        let approved = try #require(store.beginPanelConfirmation(for: device, action: .primary, level: .hold))
        hold = PanelControlGestureAttempt(startedAt: started)
        let completed = hold.completeHold(at: started + .milliseconds(650))
        #expect(completed)
        let task = try #require(store.performPanelConfirmation(approved))
        #expect(await task.value)
        let repeated = hold.completeHold(at: started + .milliseconds(900))
        #expect(!repeated)
        #expect(store.performPanelConfirmation(approved) == nil)
        #expect(await provider.executedCommands == [.setSwitch(entityId: "switch.socket", isOn: true)])
    }

    @Test("Keyboard activation asks before dispatching a write")
    func keyboardKeepsConfirmation() async throws {
        let (store, provider, device) = try await makeStore()
        var promptCount = 0
        var approved = false
        store.manualControlConfirmationHandler = { _ in
            promptCount += 1
            return approved
        }
        let quickIndex = PanelQuickIndexState()
        quickIndex.register(.init(deviceIds: [device.id]))
        quickIndex.select(1, store: store, theme: .liquidGlass)
        #expect(promptCount == 1)
        #expect(await provider.executedCommands.isEmpty)
        approved = true
        let task = try #require(DeviceTileActionLayout.performPrimary(for: device, store: store))
        #expect(await task.value)
        #expect(promptCount == 2)
        #expect(await provider.executedCommands == [.setSwitch(entityId: "switch.socket", isOn: true)])
    }

    @Test("A panel gesture cannot commit after screen lock")
    func screenLockInvalidatesApproval() async throws {
        let (store, provider, device) = try await makeStore()
        let approval = try #require(store.beginPanelConfirmation(for: device, action: .primary, level: .hold))
        store.setScreenLocked(true)
        #expect(store.performPanelConfirmation(approval) == nil)
        #expect(await provider.executedCommands.isEmpty)
    }

    @Test("The slide requires 92 percent travel and can complete once")
    func slideThreshold() {
        var slide = PanelControlGestureAttempt(startedAt: .now)
        let short = slide.completeSlide(progress: 0.91)
        let completed = slide.completeSlide(progress: 0.92)
        let repeated = slide.completeSlide(progress: 1)
        #expect(!short)
        #expect(completed)
        #expect(!repeated)
    }

    private func makeStore() async throws -> (HomeStore, MockHomeProvider, SmartDevice) {
        let socket = Self.device(.plug(PlugSpec(switchEntityId: "switch.socket", isOn: false, powerWritable: true)))
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [socket], scenes: []))
        let store = HomeStore(provider: provider, defaults: InMemoryUserDefaults())
        try await store.waitForTestSnapshot()
        return (store, provider, try #require(store.devices.first))
    }

    private static func device(_ kind: DeviceKind, name: String = "Device") -> SmartDevice {
        SmartDevice(
            id: "device", name: name, roomId: "room", roomName: "Room", model: "", isOnline: true, kind: kind
        )
    }
}
