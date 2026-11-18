import Foundation
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FacetDragConfirmationTests {
    private typealias SleepGate = ScheduledCommandTestSupport.SleepGate

    private static func waterHeater(id: String = "wh", cardTarget: Double = 40) -> SmartDevice {
        SmartDevice(
            id: id,
            name: "热水器",
            roomId: "bath",
            roomName: "卫生间",
            model: "viomi.waterheater.e1",
            isOnline: true,
            kind: .appliance(ApplianceSpec(
                entityId: "miot:\(id):2",
                isOn: true,
                powerPresent: true,
                powerWritable: true,
                targetTemperature: cardTarget,
                minTemp: 30,
                maxTemp: 75,
                temperatureWritable: true,
                heats: true
            ))
        )
    }

    private static func targetTemperatureSlider(
        deviceId: String = "wh",
        service: String = "water-heater",
        value: JSONValue? = .number(40)
    ) -> FacetControl {
        FacetControl(
            id: "2.5",
            kind: .slider,
            name: "target-temperature",
            title: "目标温度",
            serviceName: service,
            value: value,
            range: MiotFacetRange(min: 30, max: 75, step: 1),
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:\(deviceId):2", piid: 5)
        )
    }

    private func makeStore(
        device: SmartDevice = Self.waterHeater(),
        facets: [FacetControl] = [Self.targetTemperatureSlider()]
    ) async throws -> (HomeStore, MockHomeProvider, SleepGate) {
        let gate = SleepGate()
        var home = SynthesizedHome(devices: [device])
        home.deviceFacets = [device.id: facets]
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.facet.drag.confirm.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        store.controlDebounceInterval = .milliseconds(150)
        store.controlDebounceSleep = { _ in await gate.sleep() }
        try await store.waitForTestSnapshot()
        return (store, mock, gate)
    }

    @Test("Cooling down first then dragging hotter in the same gesture must ask for confirmation")
    func coolDownThenWarmUpRequiresConfirmation() async throws {
        let (store, mock, gate) = try await makeStore()
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        // 40 -> 39 cools down, so it needs no confirmation.
        store.setFacetValue("wh", controlId: "2.5", value: .number(39))
        #expect(prompts == 0)
        #expect(store.deviceFacets["wh"]?.first?.value == .number(39))

        // Reversing to 75 in the same drag warms above the 40°C origin and must ask.
        store.setFacetValue("wh", controlId: "2.5", value: .number(75))
        #expect(prompts == 1, "cooling first must not bypass confirmation for a subsequent warm-up")
        #expect(
            store.deviceFacets["wh"]?.first?.value == .number(39),
            "refusing 75 leaves the UI on the last allowed value"
        )

        await waitUntil { gate.waiting == 1 }
        gate.release()
        let pending = store.debounceTasks["wh.facet.2.5"]
        await pending?.value
        let sent = await mock.executedCommands
        #expect(!sent.contains(.setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(75))))
        #expect(sent == [.setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(39))])
    }

    @Test("Once warming is confirmed, further hotter ticks in the same drag do not re-prompt")
    func confirmedWarmUpContinuesWithoutRepeatingPrompt() async throws {
        let (store, mock, gate) = try await makeStore()
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        store.setFacetValue("wh", controlId: "2.5", value: .number(39))
        #expect(prompts == 0)

        store.setFacetValue("wh", controlId: "2.5", value: .number(60))
        #expect(prompts == 1)

        store.setFacetValue("wh", controlId: "2.5", value: .number(68))
        store.setFacetValue("wh", controlId: "2.5", value: .number(40))
        store.setFacetValue("wh", controlId: "2.5", value: .number(75))
        #expect(prompts == 1, "continuing the confirmed drag does not repeat the modal")
        #expect(store.deviceFacets["wh"]?.first?.value == .number(75))

        await waitUntil { gate.waiting == 1 }
        gate.release()
        let pending = store.debounceTasks["wh.facet.2.5"]
        await pending?.value
        #expect(await mock.executedCommands == [
            .setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(75))
        ])

        // A separate drag after the first write went out must ask on its own.
        var snapshot = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 75)])
        snapshot.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(60))]]
        let before = store.snapshotGeneration
        await mock.updateSnapshot(snapshot)
        await waitUntil { store.snapshotGeneration > before }

        store.setFacetValue("wh", controlId: "2.5", value: .number(70))
        #expect(prompts == 2, "a new drag after the command went out asks again")
        store.cancelFacetWrites(for: nil)
    }

    @Test("Refusing a warm-up drag sends zero commands and keeps the starting value")
    func refusedWarmUpSendsZeroCommands() async throws {
        let (store, mock, _) = try await makeStore()
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        store.setFacetValue("wh", controlId: "2.5", value: .number(65))
        #expect(prompts == 1)
        #expect(store.deviceFacets["wh"]?.first?.value == .number(40))
        #expect(store.facetWrites.isEmpty)
        #expect(store.optimisticLockUntil["wh"] == nil)
        #expect(store.undoBanner == nil)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Pure cool-down drags and ordinary sliders never prompt, even when wiggling below the start")
    func pureCoolDownAndOrdinarySliderNeverPrompt() async throws {
        let light = SmartDevice(
            id: "lamp",
            name: "台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:lamp:2", isOn: true))
        )
        let lampSlider = FacetControl(
            id: "3.1",
            kind: .slider,
            name: "brightness",
            title: "辅灯亮度",
            serviceName: "light",
            value: .number(20),
            range: MiotFacetRange(min: 1, max: 100, step: 1),
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:lamp:3", piid: 1)
        )
        let gate = SleepGate()
        var home = SynthesizedHome(devices: [Self.waterHeater(), light])
        home.deviceFacets = [
            "wh": [Self.targetTemperatureSlider(value: .number(40))],
            "lamp": [lampSlider],
        ]
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.facet.drag.cool.\(UUID().uuidString)"
        )
        store.controlDebounceSleep = { _ in await gate.sleep() }
        try await store.waitForTestSnapshot()

        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        // 40 -> 34 -> 38 stays below the 40°C drag origin on every tick.
        store.setFacetValue("wh", controlId: "2.5", value: .number(34))
        store.setFacetValue("wh", controlId: "2.5", value: .number(38))
        #expect(prompts == 0, "38°C is still cooler than the 40°C origin")

        // Ordinary slider moves in both directions stay direct.
        store.setFacetValue("lamp", controlId: "3.1", value: .number(10))
        store.setFacetValue("lamp", controlId: "3.1", value: .number(80))
        #expect(prompts == 0)

        await waitUntil { gate.waiting == 2 }
        gate.release()
        gate.release()
        let whTask = store.debounceTasks["wh.facet.2.5"]
        let lampTask = store.debounceTasks["lamp.facet.3.1"]
        await whTask?.value
        await lampTask?.value

        let sent = await mock.executedCommands
        #expect(sent.contains(.setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(38))))
        #expect(sent.contains(.setMiotProperty(entityId: "miot:lamp:3", piid: 1, value: .number(80))))
    }

    @Test("Pre-send recheck fails closed when a device report lowers the start below an unconfirmed drag")
    func preSendRecheckFailsClosedWhenDeviceReportFlipsDirection() async throws {
        let (store, mock, gate) = try await makeStore()
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        // 40 -> 39 needs no confirmation when the drag begins.
        store.setFacetValue("wh", controlId: "2.5", value: .number(39))
        #expect(prompts == 0)
        store.pauseUndoBannerCountdown()
        #expect(store.undoBanner != nil)

        // While the debounce waits, the device reports 35°C, making 39°C an unapproved warm-up.
        var updated = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 35)])
        updated.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(35))]]
        let before = store.snapshotGeneration
        await mock.updateSnapshot(updated)
        await waitUntil { store.snapshotGeneration > before }

        await waitUntil { gate.waiting == 1 }
        gate.release()
        let pending = store.debounceTasks["wh.facet.2.5"]
        await pending?.value

        #expect(await mock.executedCommands.isEmpty, "the unconfirmed 35 -> 39 warm-up must not send")
        #expect(store.deviceFacets["wh"]?.first?.value == .number(35), "the facet rolls back to the latest report")
        #expect(store.optimisticLockUntil["wh"] == nil)
        #expect(store.undoBanner == nil)
        let toastMessage = try #require(store.toastNotice?.message)
        #expect(store.toastNotice?.isError == true)
        #expect(toastMessage.contains("重新确认"))
    }

    @Test("Pre-send recheck fails closed when a confirmed known warm-up loses its reported start")
    func preSendRecheckFailsClosedWhenStartBecomesUnknown() async throws {
        let ac = SmartDevice(
            id: "ac",
            name: "客厅空调",
            roomId: "living",
            roomName: "客厅",
            model: "xiaomi.aircondition.v1",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "miot:ac:2",
                isOn: true,
                hvacMode: "heat",
                availableModes: ["off", "heat"],
                targetTemperature: 26
            ))
        )
        let ptcSlider = Self.targetTemperatureSlider(deviceId: "ac", service: "ptc", value: .number(40))
        let (store, mock, gate) = try await makeStore(device: ac, facets: [ptcSlider])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        store.setFacetValue("ac", controlId: "2.5", value: .number(50))
        #expect(prompts == 1)

        var missingStart = SynthesizedHome(devices: [ac])
        missingStart.deviceFacets = ["ac": [Self.targetTemperatureSlider(deviceId: "ac", service: "ptc", value: nil)]]
        let before = store.snapshotGeneration
        await mock.updateSnapshot(missingStart)
        await waitUntil { store.snapshotGeneration > before }

        await waitUntil { gate.waiting == 1 }
        gate.release()
        let pending = store.debounceTasks["ac.facet.2.5"]
        await pending?.value

        #expect(await mock.executedCommands.isEmpty)
        #expect(store.deviceFacets["ac"]?.first?.value == nil)
    }

    @Test("Pre-send recheck allows a confirmed warm-up that remains a known warm-up after a report")
    func preSendRecheckAllowsConfirmedWarmUpWhenDirectionHolds() async throws {
        let (store, mock, gate) = try await makeStore()
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }

        store.setFacetValue("wh", controlId: "2.5", value: .number(60))
        #expect(prompts == 1)

        var updated = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 45)])
        updated.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(45))]]
        let before = store.snapshotGeneration
        await mock.updateSnapshot(updated)
        await waitUntil { store.snapshotGeneration > before }

        await waitUntil { gate.waiting == 1 }
        gate.release()
        let pending = store.debounceTasks["wh.facet.2.5"]
        await pending?.value

        #expect(await mock.executedCommands == [
            .setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(60))
        ])
    }

    @Test("Toggle and Select facets keep their per-tap confirmation rules")
    func toggleAndSelectKeepExistingBehavior() async throws {
        let modeFacet = FacetControl(
            id: "2.2",
            kind: .select,
            name: "mode",
            title: "工作模式",
            serviceName: "water-heater",
            value: .number(1),
            options: [
                MiotFacetOption(value: 0, label: "Off"),
                MiotFacetOption(value: 1, label: "Standard"),
                MiotFacetOption(value: 2, label: "Boost"),
            ],
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:wh:2", piid: 2)
        )
        let powerFacet = FacetControl(
            id: "2.1",
            kind: .toggle,
            name: "on",
            title: "电源",
            serviceName: "water-heater",
            value: .bool(true),
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:wh:2", piid: 1)
        )
        let (store, mock, _) = try await makeStore(facets: [powerFacet, modeFacet])
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }

        // Turning off and selecting Off stay direct.
        store.setFacetValue("wh", controlId: "2.1", value: .bool(false))
        store.setFacetValue("wh", controlId: "2.2", value: .number(0))
        #expect(prompts == 0)
        let offTask = store.debounceTasks["wh.facet.2.1"]
        let modeOffTask = store.debounceTasks["wh.facet.2.2"]
        await offTask?.value
        await modeOffTask?.value

        // Turning back on or picking a heating mode asks and sends nothing on refusal.
        store.setFacetValue("wh", controlId: "2.1", value: .bool(true))
        store.setFacetValue("wh", controlId: "2.2", value: .number(2))
        #expect(prompts == 2)
        #expect(store.deviceFacets["wh"]?[0].value == .bool(false))
        #expect(store.deviceFacets["wh"]?[1].value == .number(0))
        #expect(await mock.executedCommands.count == 2)
    }

    @Test("An in-flight command from an earlier drag never lends its confirmation to a new drag")
    func inFlightWriteDoesNotLendApprovalToSecondDrag() async throws {
        let (store, mock, gate) = try await makeStore()
        await mock.holdNextExecute()
        var allowNext = true
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return allowNext
        }

        store.setFacetValue("wh", controlId: "2.5", value: .number(60))
        #expect(prompts == 1)
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await waitUntil { await mock.executeStarted == 1 }

        // 60°C has left the debounce and is now in flight; dragging further to 70°C is a new gesture.
        allowNext = false
        store.setFacetValue("wh", controlId: "2.5", value: .number(70))
        #expect(prompts == 2)
        #expect(store.deviceFacets["wh"]?.first?.value == .number(60))

        let inFlight = store.debounceTasks["wh.facet.2.5"]
        await mock.releaseExecute()
        await inFlight?.value
        #expect(await mock.executedCommands == [
            .setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(60))
        ])
    }
}
