import Foundation
import os
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ModalConfirmationStateTests {
    private typealias SleepGate = ScheduledCommandTestSupport.SleepGate

    private actor ScriptedProvider: HomeProvider {
        private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
        private let initialSnapshot: SynthesizedHome
        private(set) var executedCommands: [DeviceCommand] = []
        var readBackResult: ControlReadBack = .unavailable

        init(snapshot: SynthesizedHome) {
            self.initialSnapshot = snapshot
        }

        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            AsyncStream { continuation in
                Task { await self.attach(continuation) }
            }
        }

        private func attach(_ continuation: AsyncStream<HomeProviderEvent>.Continuation) {
            self.continuation = continuation
            continuation.yield(.statusChanged(.connected))
            continuation.yield(.snapshotUpdated(initialSnapshot))
        }

        func execute(_ command: DeviceCommand) async throws {
            executedCommands.append(command)
        }

        func readBack(deviceId: String) async -> ControlReadBack {
            readBackResult
        }

        func refreshNow() async {}
    }

    private static func heaterClimate(
        id: String = "heater",
        name: String = "卧室取暖器",
        isOn: Bool = false,
        hvacMode: String = "off",
        currentTemp: Double = 18,
        targetTemp: Double = 20,
        fanMode: String = "low",
        entityId: String = "climate.heater",
        accountId: String? = "acc-1"
    ) -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: "bedroom",
            roomName: "卧室",
            model: "zhimi.heater.ma2",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: entityId,
                isOn: isOn,
                hvacMode: hvacMode,
                availableModes: ["off", "heat", "auto"],
                targetTemperature: targetTemp,
                currentTemperature: currentTemp,
                minTemp: 16,
                maxTemp: 30,
                step: 1,
                fanMode: fanMode,
                availableFanModes: ["low", "high"],
                temperatureWritable: true
            )),
            accountId: accountId
        )
    }

    private static func garageDoor(
        id: String = "garage",
        name: String = "车库门",
        position: Int? = 0,
        motion: CoverMotion = .stopped,
        entityId: String = "cover.garage"
    ) -> SmartDevice {
        SmartDevice(
            id: id,
            name: name,
            roomId: "yard",
            roomName: "车库",
            model: "dooya.curtain.garage",
            isOnline: true,
            kind: .cover(CoverSpec(
                entityId: entityId,
                subtype: .garageDoor,
                positionPercent: position,
                reportedPositionPercent: position,
                positionWritable: true,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Pause",
                motion: motion
            )),
            accountId: "acc-1"
        )
    }

    private static func waterHeater(
        id: String = "wh",
        cardTarget: Double = 40,
        accountId: String? = "acc-1"
    ) -> SmartDevice {
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
            )),
            accountId: accountId
        )
    }

    private static func targetTemperatureSlider(
        deviceId: String = "wh",
        value: JSONValue = .number(40)
    ) -> FacetControl {
        FacetControl(
            id: "2.5",
            kind: .slider,
            name: "target-temperature",
            title: "目标温度",
            serviceName: "water-heater",
            value: value,
            range: MiotFacetRange(min: 30, max: 75, step: 1),
            isWritable: true,
            writesByDefault: true,
            isHighValue: true,
            target: .property(entityId: "miot:\(deviceId):2", piid: 5)
        )
    }

    private static func childLockToggle(
        deviceId: String = "wh",
        value: JSONValue = .bool(false)
    ) -> FacetControl {
        FacetControl(
            id: "2.6",
            kind: .toggle,
            name: "physical-controls-locked",
            title: "童锁",
            serviceName: "physical-controls-locked",
            value: value,
            isWritable: true,
            writesByDefault: true,
            isHighValue: false,
            target: .property(entityId: "miot:\(deviceId):3", piid: 1)
        )
    }

    @Test("togglePrimary re-reads post-modal cloud fields while keeping the confirmed power action")
    func togglePrimaryPreservesCloudFieldsUpdatedDuringModal() async throws {
        let initial = Self.heaterClimate(
            isOn: false,
            hvacMode: "off",
            currentTemp: 18,
            targetTemp: 20,
            fanMode: "low"
        )
        let mock = ScriptedProvider(snapshot: SynthesizedHome(devices: [initial]))
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.toggle.climate.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        store.manualControlConfirmationHandler = { _ in
            // Cloud reports new temperature, fan speed, and active mode while the modal is open.
            let cloudUpdated = Self.heaterClimate(
                isOn: true,
                hvacMode: "auto",
                currentTemp: 23,
                targetTemp: 26,
                fanMode: "high"
            )
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [cloudUpdated])))
            return true
        }

        let card = try #require(store.devices.first)
        let task = try #require(store.togglePrimary(card))
        #expect(await task.value == true)

        let commands = await mock.executedCommands
        #expect(
            commands == [.setClimatePower(entityId: "climate.heater", isOn: true, fallbackMode: "auto")],
            "must still send the confirmed power-on command using the latest post-modal hvacMode"
        )

        let finalDevice = try #require(store.devices.first)
        guard case .climate(let spec) = finalDevice.kind else {
            Issue.record("expected climate spec, got \(finalDevice.kind)")
            return
        }
        #expect(spec.isOn == true)
        #expect(spec.hvacMode == "auto")
        #expect(spec.currentTemperature == 23)
        #expect(spec.targetTemperature == 26)
        #expect(spec.fanMode == "high")
    }

    @Test("togglePrimary on a cover uses post-modal position for travel origin and rollback")
    func togglePrimaryCoverUsesPostModalOriginAndRollbackState() async throws {
        actor Recorder {
            var attempted: [DeviceCommand] = []
            func record(_ cmd: DeviceCommand) { attempted.append(cmd) }
        }
        let recorder = Recorder()
        let door = Self.garageDoor(position: 0)
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [door]))
        await mock.holdNextExecute()
        await mock.setFailingCommands { cmd in
            Task { await recorder.record(cmd) }
            return cmd == .setSelectOption(entityId: "cover.garage", option: "Open")
        }
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.toggle.cover.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        store.manualControlConfirmationHandler = { _ in
            // Garage door moved to 30% in the cloud while the confirmation modal was open.
            let moved = Self.garageDoor(position: 30, motion: .stopped)
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [moved])))
            return true
        }

        let initialCard = try #require(store.devices.first)
        let task = try #require(store.togglePrimary(initialCard))
        await waitUntil { await mock.executeStarted > 0 }

        #expect(
            store.coverCommandOrigins["garage"] == 30,
            "travel origin must reflect the 30% post-modal position, not the pre-modal 0%"
        )
        let optimisticRow = try #require(store.devices.first)
        guard case .cover(let optSpec) = optimisticRow.kind else {
            Issue.record("expected cover spec")
            return
        }
        #expect(optSpec.positionPercent == 100)
        #expect(optSpec.motion == .opening)

        await mock.releaseExecute()
        #expect(await task.value == false)
        await waitUntil { await recorder.attempted.count == 1 }
        #expect(await recorder.attempted == [.setSelectOption(entityId: "cover.garage", option: "Open")])
        let rolledBack = try #require(store.devices.first)
        guard case .cover(let rolledSpec) = rolledBack.kind else {
            Issue.record("expected cover spec")
            return
        }
        #expect(
            rolledSpec.positionPercent == 30,
            "failed send must roll back to the post-modal 30% state, not overwrite it with 0%"
        )
        #expect(store.coverCommandOrigins["garage"] == nil)
    }

    @Test("togglePrimary aborts when device vanishes or switches source during modal")
    func togglePrimaryAbortsWhenDeviceVanishesOrSwitchesSourceDuringModal() async throws {
        var initialHome = SynthesizedHome(devices: [Self.heaterClimate()])
        initialHome.deviceBackends = ["heater": .xiaomiCloud]
        let mock = MockHomeProvider(snapshot: initialHome)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.toggle.source.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        // 1. Source switches from Xiaomi Cloud to Home Assistant while modal is open.
        store.manualControlConfirmationHandler = { _ in
            var switched = SynthesizedHome(devices: [Self.heaterClimate(currentTemp: 24)])
            switched.deviceBackends = ["heater": .homeAssistant]
            store.handleProviderEvent(.snapshotUpdated(switched))
            return true
        }

        let card = try #require(store.devices.first)
        #expect(store.togglePrimary(card) == nil)
        #expect(await mock.executedCommands.isEmpty)

        // 2. Device disappears completely while modal is open.
        store.manualControlConfirmationHandler = { _ in
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [])))
            return true
        }
        let switchedCard = try #require(store.devices.first)
        #expect(store.togglePrimary(switchedCard) == nil)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Card controls preserve post-modal cloud state, roll back to post-modal state, and abort on source switch")
    func cardControlsPreservePostModalStateAndRollback() async throws {
        let attempted = OSAllocatedUnfairLock(initialState: [DeviceCommand]())
        let gate = SleepGate()
        var initialHome = SynthesizedHome(devices: [
            Self.heaterClimate(isOn: true, hvacMode: "heat", currentTemp: 19, targetTemp: 22, fanMode: "low")
        ])
        initialHome.deviceBackends = ["heater": .xiaomiCloud]
        let mock = MockHomeProvider(snapshot: initialHome)
        await mock.setFailingCommands { cmd in
            attempted.withLock { $0.append(cmd) }
            return cmd.targetEntityId == "climate.heater"
        }
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.card.controls.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        store.controlDebounceSleep = { _ in await gate.sleep() }
        try await store.waitForTestSnapshot()

        store.manualControlConfirmationHandler = { _ in
            var updatedHome = SynthesizedHome(devices: [
                Self.heaterClimate(isOn: true, hvacMode: "heat", currentTemp: 21, targetTemp: 26, fanMode: "high")
            ])
            updatedHome.deviceBackends = ["heater": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(updatedHome))
            return true
        }

        // User steps +2 from 22 -> confirms 24°C.
        store.stepClimateTemperature("heater", delta: 2)

        let optimistic = try #require(store.devices.first)
        guard case .climate(let optSpec) = optimistic.kind else {
            Issue.record("expected climate spec")
            return
        }
        #expect(optSpec.targetTemperature == 24, "confirmed target 24°C must be shown")
        #expect(optSpec.currentTemperature == 21, "post-modal currentTemperature must not be overwritten by 19°C")
        #expect(optSpec.fanMode == "high", "post-modal fanMode must not be overwritten by low")

        await waitUntil { gate.waiting == 1 }
        gate.release()
        let task = store.debounceTasks["heater.temp"]
        await task?.value

        #expect(attempted.withLock { $0 } == [
            .setClimateTemperature(entityId: "climate.heater", temperature: 24)
        ])

        let rolledBack = try #require(store.devices.first)
        guard case .climate(let rbSpec) = rolledBack.kind else {
            Issue.record("expected climate spec")
            return
        }
        #expect(rbSpec.targetTemperature == 26, "rollback must restore post-modal 26°C, not pre-modal 22°C")
        #expect(rbSpec.currentTemperature == 21)
        #expect(rbSpec.fanMode == "high")

        // Source switch during setClimateMode modal must abort without sending.
        await mock.setFailingCommands { _ in false }
        store.manualControlConfirmationHandler = { _ in
            var switchedHome = SynthesizedHome(devices: [
                Self.heaterClimate(isOn: false, hvacMode: "off", currentTemp: 21, targetTemp: 26, fanMode: "high")
            ])
            switchedHome.deviceBackends = ["heater": .homeAssistant]
            store.handleProviderEvent(.snapshotUpdated(switchedHome))
            return true
        }

        let countBefore = await mock.executedCommands.count
        store.setClimateMode("heater", mode: "heat")
        #expect(store.manualWriteSessions["heater"] == nil)
        #expect(await mock.executedCommands.count == countBefore)
    }

    @Test("Cover motor and position controls re-read post-modal position and fail closed on direction flip")
    func coverControlsUsePostModalPositionAndAbortOnDirectionFlip() async throws {
        let gate = SleepGate()
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.garageDoor(position: 0)]))
        await mock.holdNextExecute()
        await mock.setFailingTargets(["cover.garage"])
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.cover.controls.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        store.controlDebounceSleep = { _ in await gate.sleep() }
        try await store.waitForTestSnapshot()

        // 1. setCoverMotor("Open") while garage door moves 0% -> 25% during modal.
        store.manualControlConfirmationHandler = { _ in
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [
                Self.garageDoor(position: 25, motion: .stopped)
            ])))
            return true
        }

        let exitsBefore = store.manualWriteExits
        store.setCoverMotor("garage", description: "Open")
        await waitUntil { await mock.executeStarted > 0 }
        #expect(store.coverCommandOrigins["garage"] == 25)

        await mock.releaseExecute()
        await waitUntil { store.manualWriteExits > exitsBefore }

        let afterMotorFail = try #require(store.devices.first)
        if case .cover(let spec) = afterMotorFail.kind {
            #expect(spec.positionPercent == 25, "failed motor command must restore post-modal 25%")
        } else {
            Issue.record("expected cover spec")
        }

        // 2. setCoverPosition(60) from 25%, while garage door updates to 35% during modal.
        await mock.setFailingTargets([])
        store.manualControlConfirmationHandler = { _ in
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [
                Self.garageDoor(name: "主车库门", position: 35, motion: .stopped)
            ])))
            return true
        }

        store.setCoverPosition("garage", percent: 60)
        #expect(store.coverCommandOrigins["garage"] == 35)
        #expect(store.devices.first?.name == "主车库门")

        await waitUntil { gate.waiting == 1 }
        gate.release()
        await store.debounceTasks["garage.cover"]?.value
        #expect(await mock.executedCommands.last == .setNumberValue(entityId: "cover.garage", value: 60))

        // 3. Reset to 10%, drag to 50% (opening approved), but cloud reports 80% during modal (making 50% a close).
        store.clearManualWriteSession(for: "garage", bumpRevision: true)
        store.clearOptimisticLockEntries(for: "garage")
        store.coverCommandOrigins.removeValue(forKey: "garage")
        store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [
            Self.garageDoor(position: 10, motion: .stopped)
        ])))

        let sentBeforeFlip = await mock.executedCommands.count
        store.manualControlConfirmationHandler = { _ in
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [
                Self.garageDoor(position: 80, motion: .stopped)
            ])))
            return true
        }

        store.setCoverPosition("garage", percent: 50)
        if gate.waiting > 0 {
            gate.release()
            await store.debounceTasks["garage.cover"]?.value
        }
        #expect(
            await mock.executedCommands.count == sentBeforeFlip,
            "an opening approval must not send a closing command when cloud moved to 80% during modal"
        )
        if case .cover(let finalSpec) = store.devices.first?.kind {
            #expect(finalSpec.positionPercent == 80)
        } else {
            Issue.record("expected cover spec")
        }
    }

    @Test("setFacetValue updates undo baseline to post-modal cloud value and aborts on source switch")
    func setFacetValueUsesPostModalUndoOriginAndAbortsOnSourceSwitch() async throws {
        let gate = SleepGate()
        var home = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 40)])
        home.deviceFacets = [
            "wh": [
                Self.targetTemperatureSlider(value: .number(40)),
                Self.childLockToggle(value: .bool(false)),
            ]
        ]
        home.deviceBackends = ["wh": .xiaomiCloud]
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.facet.value.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        store.controlDebounceSleep = { _ in await gate.sleep() }
        try await store.waitForTestSnapshot()

        // First tick cools 40 -> 39 without prompting, creating an unsent debounce + undo for 40°C.
        store.setFacetValue("wh", controlId: "2.5", value: .number(39))
        store.pauseUndoBannerCountdown()
        #expect(store.undoBanner?.restoreCommands == [
            .setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(40))
        ])

        // Reversing to 75°C opens the confirmation modal; during the modal, cloud updates to 52°C and childLock=true.
        store.manualControlConfirmationHandler = { _ in
            var cloudHome = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 52)])
            cloudHome.deviceFacets = [
                "wh": [
                    Self.targetTemperatureSlider(value: .number(52)),
                    Self.childLockToggle(value: .bool(true)),
                ]
            ]
            cloudHome.deviceBackends = ["wh": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(cloudHome))
            return true
        }

        store.setFacetValue("wh", controlId: "2.5", value: .number(75))
        store.pauseUndoBannerCountdown()

        #expect(store.deviceFacets["wh"]?.first(where: { $0.id == "2.5" })?.value == .number(75))
        #expect(store.deviceFacets["wh"]?.first(where: { $0.id == "2.6" })?.value == .bool(true))
        #expect(
            store.undoBanner?.restoreCommands == [
                .setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(52))
            ],
            "undo must restore the 52°C cloud state received during the modal, not the stale 40°C origin"
        )
        if case .appliance(let prevSpec) = store.undoBanner?.previousDevices.first?.kind {
            #expect(prevSpec.targetTemperature == 52)
        } else {
            Issue.record("expected previousDevices to hold post-modal water heater")
        }

        await waitUntil { gate.waiting == 1 }
        gate.release()
        await store.debounceTasks["wh.facet.2.5"]?.value

        #expect(await mock.executedCommands == [
            .setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(75))
        ])

        // Clicking Undo sends 52°C.
        let undoTask = try #require(store.undoTurnAllOff())
        await undoTask.value
        #expect(await mock.executedCommands.last == .setMiotProperty(
            entityId: "miot:wh:2",
            piid: 5,
            value: .number(52)
        ))

        // Source switch during modal on setFacetValue must abort without sending or scheduling undo.
        store.optimisticFacetLocks.removeAll()
        var resetHome = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 50)])
        resetHome.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(50))]]
        resetHome.deviceBackends = ["wh": .xiaomiCloud]
        store.handleProviderEvent(.snapshotUpdated(resetHome))

        let sentCount = await mock.executedCommands.count
        store.manualControlConfirmationHandler = { _ in
            var switchedHome = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 50)])
            switchedHome.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(50))]]
            switchedHome.deviceBackends = ["wh": .homeAssistant]
            store.handleProviderEvent(.snapshotUpdated(switchedHome))
            return true
        }

        store.setFacetValue("wh", controlId: "2.5", value: .number(68))
        #expect(store.facetWrites.isEmpty)
        #expect(store.undoBanner == nil)
        #expect(await mock.executedCommands.count == sentCount)
    }

    @Test("runFacetAction aborts on source switch and uses fresh post-modal action spec when valid")
    func runFacetActionRevalidatesSourceAndUsesFreshSpecAfterModal() async throws {
        let feeder = SmartDevice(
            id: "feeder",
            name: "宠物喂食器",
            roomId: "living",
            roomName: "客厅",
            model: "mmgg.feeder.inland",
            isOnline: true,
            kind: .generic(GenericSpec(deviceType: "pet-feeder", typeTitle: "宠物喂食器", isReadOnly: false)),
            accountId: "acc-1"
        )
        func feedAction(maxPortion: Double) -> FacetControl {
            FacetControl(
                id: "2.1",
                kind: .button,
                name: "out-food",
                title: "出粮",
                serviceName: "pet-feeder",
                isWritable: true,
                writesByDefault: true,
                isHighValue: true,
                target: .action(entityId: "miot:feeder:2:1"),
                arguments: [
                    MiotFacetArgument(
                        propertyId: 1,
                        name: "feeding-measure",
                        format: "uint8",
                        range: MiotFacetRange(min: 1, max: maxPortion, step: 1)
                    )
                ],
                portionArgumentIndex: 0
            )
        }

        var home = SynthesizedHome(devices: [feeder])
        home.deviceFacets = ["feeder": [feedAction(maxPortion: 10)]]
        home.deviceBackends = ["feeder": .xiaomiCloud]
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.facet.action.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        // 1. Source switches during modal -> must not execute.
        store.manualControlConfirmationHandler = { _ in
            var switched = SynthesizedHome(devices: [feeder])
            switched.deviceFacets = ["feeder": [feedAction(maxPortion: 10)]]
            switched.deviceBackends = ["feeder": .homeAssistant]
            store.handleProviderEvent(.snapshotUpdated(switched))
            return true
        }

        store.runFacetAction("feeder", controlId: "2.1", portion: 5)
        await store.debounceTasks["feeder.facet.2.1"]?.value
        #expect(await mock.executedCommands.isEmpty)

        // 2. Same source, cloud updates argument range max from 10 -> 3 during modal -> clamps using fresh control.
        var sameSourceHome = SynthesizedHome(devices: [feeder])
        sameSourceHome.deviceFacets = ["feeder": [feedAction(maxPortion: 10)]]
        sameSourceHome.deviceBackends = ["feeder": .xiaomiCloud]
        store.handleProviderEvent(.snapshotUpdated(sameSourceHome))

        store.manualControlConfirmationHandler = { _ in
            var updatedSpecHome = SynthesizedHome(devices: [feeder])
            updatedSpecHome.deviceFacets = ["feeder": [feedAction(maxPortion: 3)]]
            updatedSpecHome.deviceBackends = ["feeder": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(updatedSpecHome))
            return true
        }

        store.runFacetAction("feeder", controlId: "2.1", portion: 5)
        await store.debounceTasks["feeder.facet.2.1"]?.value
        #expect(await mock.executedCommands == [
            .callMiotAction(entityId: "miot:feeder:2:1", arguments: [.number(3)])
        ])
    }

    @Test("togglePrimary fails closed when a wall switch changes into a non-light high-risk device during modal")
    func togglePrimaryFailsClosedWhenWallSwitchCategoryChangesDuringModal() async throws {
        func wallSwitch(
            name: String = "左键",
            model: String = "lumi.switch.b1nacn02",
            roomName: String = "玄关"
        ) -> SmartDevice {
            SmartDevice(
                id: "wall-1",
                name: name,
                roomId: "hall",
                roomName: roomName,
                model: model,
                isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.wall_1", isOn: false, powerWritable: true)),
                accountId: "acc-1"
            )
        }

        let mock = ScriptedProvider(snapshot: SynthesizedHome(devices: [wallSwitch()]))
        let suiteName = "test.modal.wall.category.\(UUID().uuidString)"
        let store = HomeStore(provider: mock, defaultsSuiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        // 1. Wall switch becomes a UV lamp ("杀菌灯", no longer light-eligible) while modal is open.
        store.manualControlConfirmationHandler = { _ in
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [
                wallSwitch(name: "杀菌灯")
            ])))
            return true
        }
        let initial = try #require(store.devices.first)
        #expect(store.togglePrimary(initial) == nil)
        #expect(await mock.executedCommands.isEmpty)

        // 2. Wall switch becomes a socket model ("cuco.plug.v3") while modal is open.
        store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [wallSwitch()])))
        store.manualControlConfirmationHandler = { _ in
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [
                wallSwitch(name: "书房插座", model: "cuco.plug.v3")
            ])))
            return true
        }
        let restored = try #require(store.devices.first)
        #expect(store.togglePrimary(restored) == nil)
        #expect(await mock.executedCommands.isEmpty)

        // 3. Benign rename that stays a light-eligible wall switch ("左键" -> "玄关左键") still executes
        //    and keeps the post-modal room/name fields.
        store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [wallSwitch()])))
        store.manualControlConfirmationHandler = { _ in
            store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [
                wallSwitch(name: "玄关左键", roomName: "门厅")
            ])))
            return true
        }
        let benign = try #require(store.devices.first)
        let task = try #require(store.togglePrimary(benign))
        #expect(await task.value == true)
        #expect(await mock.executedCommands == [.setSwitch(entityId: "switch.wall_1", isOn: true)])
        #expect(store.devices.first?.name == "玄关左键")
        #expect(store.devices.first?.roomName == "门厅")
    }

    @Test("Batch undo re-evaluates switch-light marks and device categories changed during another device's modal")
    func batchUndoReevaluatesMarksAndCategoriesChangedDuringModal() async throws {
        let wallBefore = SmartDevice(
            id: "wall-before",
            name: "玄关左键",
            roomId: "hall",
            roomName: "玄关",
            model: "lumi.switch.b1nacn02",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.wall_before", isOn: true, powerWritable: true)),
            accountId: "acc-1"
        )
        let heaterPlug = SmartDevice(
            id: "plug-heater",
            name: "取暖器插座",
            roomId: "living",
            roomName: "客厅",
            model: "chuangmi.plug.212a01",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater_plug", isOn: true, powerWritable: true)),
            accountId: "acc-1"
        )
        let wallAfter = SmartDevice(
            id: "wall-after",
            name: "走廊右键",
            roomId: "hall",
            roomName: "玄关",
            model: "lumi.switch.b1nacn02",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.wall_after", isOn: true, powerWritable: true)),
            accountId: "acc-1"
        )

        var home = SynthesizedHome(devices: [wallBefore, heaterPlug, wallAfter])
        home.deviceBackends = [
            wallBefore.id: .xiaomiCloud,
            heaterPlug.id: .xiaomiCloud,
            wallAfter.id: .xiaomiCloud,
        ]
        let mock = MockHomeProvider(snapshot: home)
        let suiteName = "test.modal.undo.marks.\(UUID().uuidString)"
        let store = HomeStore(provider: mock, defaultsSuiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        store.markSwitchAsLight(wallBefore.id)
        store.markSwitchAsLight(wallAfter.id)
        store.setJoinsAllOff(true, deviceId: wallBefore.id)
        store.setJoinsAllOff(true, deviceId: heaterPlug.id)
        store.setJoinsAllOff(true, deviceId: wallAfter.id)

        _ = await store.turnAllOff()?.value
        store.pauseUndoBannerCountdown()
        let countAfterOff = await mock.executedCommands.count
        #expect(countAfterOff == 3)

        // While confirming `heaterPlug`'s undo, both marked switches are unmarked; user declines
        // the newly-required prompts for the two switches while approving `heaterPlug`.
        var promptedMessages: [String] = []
        store.manualControlConfirmationHandler = { prompt in
            promptedMessages.append(prompt.message)
            if prompt.message.contains("取暖器插座") {
                store.unmarkSwitchAsLight(wallBefore.id)
                store.unmarkSwitchAsLight(wallAfter.id)
                return true
            }
            return false
        }

        let undoTask = try #require(store.undoTurnAllOff())
        await undoTask.value

        let restoreCommands = Array((await mock.executedCommands).dropFirst(countAfterOff))
        #expect(
            restoreCommands == [.setSwitch(entityId: "switch.heater_plug", isOn: true)],
            "switches unmarked during the modal must be re-checked and not restored without confirmation"
        )
        #expect(promptedMessages.contains { $0.contains("玄关左键") })
        #expect(promptedMessages.contains { $0.contains("走廊右键") })
    }

    @Test("Assistant multi-intent confirmation re-checks earlier marked switches when marks or categories change during modal")
    func assistantIntentsRecheckMarksChangedDuringModal() async throws {
        let wall = SmartDevice(
            id: "wall-assist",
            name: "左键",
            roomId: "hall",
            roomName: "玄关",
            model: "lumi.switch.b1nacn02",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.wall_assist", isOn: false, powerWritable: true)),
            accountId: "acc-1"
        )
        let plug = SmartDevice(
            id: "plug-assist",
            name: "书房插座",
            roomId: "study",
            roomName: "书房",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.plug_assist", isOn: false, powerWritable: true)),
            accountId: "acc-1"
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [wall, plug]))
        let suiteName = "test.modal.assist.marks.\(UUID().uuidString)"
        let store = HomeStore(provider: mock, defaultsSuiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        store.markSwitchAsLight(wall.id)

        let suggestion = AssistantSuggestion(
            id: "sug-1",
            title: "打开两个开关",
            intents: [
                DeviceIntent(targetId: wall.id, operation: .power(true)),
                DeviceIntent(targetId: plug.id, operation: .power(true)),
            ]
        )

        store.manualControlConfirmationHandler = { prompt in
            if prompt.message.contains("书房插座") {
                // Unmark `wall` while `plug`'s confirmation modal is open; decline `wall` when re-asked.
                store.unmarkSwitchAsLight(wall.id)
                return true
            }
            return false
        }

        await store.applyAssistantSuggestion(suggestion)
        #expect(
            await mock.executedCommands == [.setSwitch(entityId: "switch.plug_assist", isOn: true)],
            "earlier switch unmarked during a sibling intent's modal must not execute unconfirmed"
        )
    }

    @Test("setFacetValue fails closed before optimistic write when reported start vanishes during modal")
    func setFacetValueFailsClosedWhenPostModalHazardEscalates() async throws {
        var home = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 40)])
        home.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(40))]]
        home.deviceBackends = ["wh": .xiaomiCloud]
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.modal.facet.escalate.\(UUID().uuidString)"
        )
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        // User approves `.warmer` (40 -> 50), but during the modal the water heater loses its
        // reported temperature reading (`value = nil`), which requires `.unknownStartTemperature`.
        store.manualControlConfirmationHandler = { _ in
            var missingStartDevice = Self.waterHeater(cardTarget: 40)
            if case .appliance(var spec) = missingStartDevice.kind {
                spec.targetTemperature = nil
                missingStartDevice.kind = .appliance(spec)
            }
            var nextHome = SynthesizedHome(devices: [missingStartDevice])
            var unknownSlider = Self.targetTemperatureSlider(value: .number(40))
            unknownSlider.value = nil
            nextHome.deviceFacets = ["wh": [unknownSlider]]
            nextHome.deviceBackends = ["wh": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(nextHome))
            return true
        }

        store.setFacetValue("wh", controlId: "2.5", value: .number(50))
        #expect(store.facetWrites.isEmpty)
        #expect(store.undoBanner == nil)
        #expect(store.deviceFacets["wh"]?.first(where: { $0.id == "2.5" })?.value == nil)
        #expect(await mock.executedCommands.isEmpty)
    }
}
