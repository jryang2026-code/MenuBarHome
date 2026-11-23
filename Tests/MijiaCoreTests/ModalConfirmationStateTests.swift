import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ModalConfirmationStateTests {
    private typealias SleepGate = ScheduledCommandTestSupport.SleepGate

    private actor ScriptedProvider: HomeProvider {
        private let initialSnapshot: SynthesizedHome
        private(set) var executedCommands: [DeviceCommand] = []
        init(snapshot: SynthesizedHome) { self.initialSnapshot = snapshot }
        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            let snap = initialSnapshot
            return AsyncStream { cont in
                cont.yield(.statusChanged(.connected))
                cont.yield(.snapshotUpdated(snap))
            }
        }
        func execute(_ command: DeviceCommand) async throws { executedCommands.append(command) }
        func refreshNow() async {}
    }

    private static func makeStore(_ home: SynthesizedHome) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    private static func makeScriptedStore(_ home: SynthesizedHome) async throws -> (HomeStore, ScriptedProvider) {
        let mock = ScriptedProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaults: InMemoryUserDefaults())
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()
        return (store, mock)
    }

    private static func heaterClimate(
        id: String = "heater", name: String = "卧室取暖器", isOn: Bool = false, hvacMode: String = "off",
        currentTemp: Double = 18, targetTemp: Double = 20, fanMode: String = "low", accountId: String? = "acc-1"
    ) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: "bedroom", roomName: "卧室", model: "zhimi.heater.ma2", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.heater", isOn: isOn, hvacMode: hvacMode, availableModes: ["off", "heat", "auto"],
                targetTemperature: targetTemp, currentTemperature: currentTemp, minTemp: 16, maxTemp: 30, step: 1,
                fanMode: fanMode, availableFanModes: ["low", "high"], temperatureWritable: true
            )),
            accountId: accountId
        )
    }

    private static func garageDoor(
        id: String = "garage", name: String = "车库门", position: Int? = 0,
        motion: CoverMotion = .stopped, accountId: String? = "acc-1"
    ) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: "yard", roomName: "车库", model: "dooya.curtain.garage", isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.garage", subtype: .garageDoor, positionPercent: position, reportedPositionPercent: position,
                positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause", motion: motion
            )),
            accountId: accountId
        )
    }

    private static func waterHeater(id: String = "wh", cardTarget: Double? = 40, isOnline: Bool = true) -> SmartDevice {
        SmartDevice(
            id: id, name: "热水器", roomId: "bath", roomName: "卫生间", model: "viomi.waterheater.e1", isOnline: isOnline,
            kind: .appliance(ApplianceSpec(
                entityId: "miot:\(id):2", isOn: true, powerPresent: true, powerWritable: true,
                targetTemperature: cardTarget, minTemp: 30, maxTemp: 75, temperatureWritable: true, heats: true
            )),
            accountId: "acc-1"
        )
    }

    private static func targetTemperatureSlider(deviceId: String = "wh", value: JSONValue? = .number(40)) -> FacetControl {
        FacetControl(
            id: "2.5", kind: .slider, name: "target-temperature", title: "目标温度", serviceName: "water-heater",
            value: value, range: MiotFacetRange(min: 30, max: 75, step: 1),
            isWritable: true, writesByDefault: true, isHighValue: true,
            target: .property(entityId: "miot:\(deviceId):2", piid: 5)
        )
    }

    private static func childLockToggle(deviceId: String = "wh", value: JSONValue = .bool(false)) -> FacetControl {
        FacetControl(
            id: "2.6", kind: .toggle, name: "physical-controls-locked", title: "童锁",
            serviceName: "physical-controls-locked", value: value,
            isWritable: true, writesByDefault: true, isHighValue: false,
            target: .property(entityId: "miot:\(deviceId):3", piid: 1)
        )
    }

    private static func wallSwitch(
        id: String = "wall-1", name: String = "左键", model: String = "lumi.switch.b1nacn02",
        roomName: String = "玄关", isOn: Bool = false
    ) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: "hall", roomName: roomName, model: model, isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.\(id)", isOn: isOn, powerWritable: true)),
            accountId: "acc-1"
        )
    }

    @Test("togglePrimary preserves post-modal cloud fields on climate/cover, rolls back to post-modal cover origin, and aborts on vanish/source-switch/category-escalation")
    func togglePrimaryPostModalStateOriginAndGuards() async throws {
        var initialHome = SynthesizedHome(devices: [Self.heaterClimate()])
        initialHome.deviceBackends = ["heater": .xiaomiCloud]
        let (store, mock) = try await Self.makeScriptedStore(initialHome)

        store.manualControlConfirmationHandler = { _ in
            var cloudHome = SynthesizedHome(devices: [
                Self.heaterClimate(isOn: true, hvacMode: "auto", currentTemp: 23, targetTemp: 26, fanMode: "high")
            ])
            cloudHome.deviceBackends = ["heater": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(cloudHome))
            return true
        }
        let card = try #require(store.devices.first)
        #expect(await store.togglePrimary(card)?.value == true)
        #expect(await mock.executedCommands == [.setClimatePower(entityId: "climate.heater", isOn: true, fallbackMode: "auto")])
        if case .climate(let spec) = store.devices.first?.kind {
            #expect(spec.isOn && spec.hvacMode == "auto" && spec.currentTemperature == 23 && spec.targetTemperature == 26 && spec.fanMode == "high")
        } else {
            Issue.record("expected climate spec")
        }

        let (switchStore, switchMock) = try await Self.makeScriptedStore(initialHome)
        switchStore.manualControlConfirmationHandler = { _ in
            var switched = SynthesizedHome(devices: [Self.heaterClimate(currentTemp: 24)])
            switched.deviceBackends = ["heater": .homeAssistant]
            switchStore.handleProviderEvent(.snapshotUpdated(switched))
            return true
        }
        #expect(switchStore.togglePrimary(try #require(switchStore.devices.first)) == nil)
        #expect(await switchMock.executedCommands.isEmpty)

        let (vanishStore, _) = try await Self.makeScriptedStore(initialHome)
        vanishStore.manualControlConfirmationHandler = { _ in
            vanishStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [])))
            return true
        }
        #expect(vanishStore.togglePrimary(try #require(vanishStore.devices.first)) == nil)

        let (coverStore, coverMock) = try await Self.makeStore(SynthesizedHome(devices: [Self.garageDoor(position: 0)]))
        await coverMock.holdNextExecute()
        await coverMock.setFailingTargets(["cover.garage"])
        coverStore.manualControlConfirmationHandler = { _ in
            coverStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.garageDoor(position: 30, motion: .stopped)])))
            return true
        }
        let coverRow = try #require(coverStore.devices.first)
        let coverTask = try #require(coverStore.togglePrimary(coverRow))
        await waitUntil { await coverMock.executeStarted > 0 }
        #expect(coverStore.coverCommandOrigins["garage"] == 30)
        #expect(coverStore.devices.first?.coverSpec?.positionPercent == 100 && coverStore.devices.first?.coverSpec?.motion == .opening)
        await coverMock.releaseExecute()
        #expect(await coverTask.value == false)
        #expect(coverStore.devices.first?.coverSpec?.positionPercent == 30 && coverStore.coverCommandOrigins["garage"] == nil)

        let (wallStore, wallMock) = try await Self.makeScriptedStore(SynthesizedHome(devices: [Self.wallSwitch()]))
        wallStore.manualControlConfirmationHandler = { _ in
            wallStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.wallSwitch(name: "杀菌灯")])))
            return true
        }
        #expect(wallStore.togglePrimary(try #require(wallStore.devices.first)) == nil)
        wallStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.wallSwitch()])))
        wallStore.manualControlConfirmationHandler = { _ in
            wallStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.wallSwitch(name: "书房插座", model: "cuco.plug.v3")])))
            return true
        }
        #expect(wallStore.togglePrimary(try #require(wallStore.devices.first)) == nil)
        #expect((await wallMock.executedCommands).isEmpty)

        wallStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.wallSwitch()])))
        wallStore.manualControlConfirmationHandler = { _ in
            wallStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.wallSwitch(name: "玄关左键", roomName: "门厅")])))
            return true
        }
        #expect(await wallStore.togglePrimary(try #require(wallStore.devices.first))?.value == true)
        #expect(await wallMock.executedCommands == [.setSwitch(entityId: "switch.wall-1", isOn: true)])
        #expect(wallStore.devices.first?.name == "玄关左键" && wallStore.devices.first?.roomName == "门厅")
    }

    enum PostModalChange: CaseIterable {
        case primaryType, primaryWritable, coverPositionEntity, coverMotorEntity
        case coverPositionOffline, coverMotorOffline, climateOffline
    }

    @Test(arguments: PostModalChange.allCases, [AppLanguage.zhHans, .zhHant, .en])
    func changedCardCancelsWithFeedback(_ change: PostModalChange, language: AppLanguage) async throws {
        try await L10n.$overrideLanguage.withValue(language) {
            let climate = change == .climateOffline
            let initial = climate ? Self.heaterClimate(isOn: true, hvacMode: "heat") : Self.garageDoor()
            var updated = initial
            switch change {
            case .primaryType:
                updated.kind = .plug(PlugSpec(switchEntityId: "switch.new", isOn: false))
            case .primaryWritable:
                var spec = try #require(initial.coverSpec)
                spec.openDescription = nil
                updated.kind = .cover(spec)
            case .coverPositionEntity, .coverMotorEntity:
                var spec = try #require(initial.coverSpec)
                spec.entityId = "cover.replaced"
                updated.kind = .cover(spec)
            case .coverPositionOffline, .coverMotorOffline, .climateOffline:
                updated.isOnline = false
            }

            let (store, provider) = try await Self.makeStore(SynthesizedHome(devices: [initial]))
            var prompts = 0
            store.manualControlConfirmationHandler = { _ in
                prompts += 1
                store.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [updated])))
                return true
            }
            switch change {
            case .primaryType, .primaryWritable:
                #expect(store.togglePrimary(initial) == nil)
            case .coverPositionEntity, .coverPositionOffline:
                store.setCoverPosition(initial.id, percent: 50)
            case .coverMotorEntity, .coverMotorOffline:
                store.setCoverMotor(initial.id, description: "Open")
            case .climateOffline:
                store.stepClimateTemperature(initial.id, delta: 2)
            }

            let expected = if updated.isOnline {
                switch language {
                case .zhHans: "设备已变化，操作已取消"
                case .zhHant: "裝置已變更，操作已取消"
                default: "The device changed. The action was cancelled."
                }
            } else {
                switch language {
                case .zhHans: "\(initial.name) 当前离线（可能断电）"
                case .zhHant: "\(initial.name) 當前離線（可能斷電）"
                default: "\(initial.name) is offline (unplugged)"
                }
            }
            #expect(prompts == 1)
            #expect(store.toastNotice?.isError == true && store.toastNotice?.message == expected)
            #expect(store.manualWriteSessions.isEmpty && store.debounceTasks.isEmpty)
            #expect(store.undoBanner == nil && store.coverCommandOrigins.isEmpty)
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func undoConfirmationHoldsOnlyTheOriginalBanner(replaceBanner: Bool) async throws {
        let device = Self.wallSwitch()
        let (store, provider) = try await Self.makeStore(SynthesizedHome(devices: [device]))
        let restore = DeviceCommand.setSwitch(entityId: "switch.wall-1", isOn: true)
        store.scheduleUndoBanner(title: "Original", restoreCommands: [restore], previousDevices: [device], deviceCount: 1)
        let originalID = try #require(store.undoBanner?.id)
        let originalTimer = try #require(store.undoTimerTask)
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            #expect(originalTimer.isCancelled && store.undoTimerTask == nil)
            store.resumeUndoBannerCountdown()
            #expect(store.undoTimerTask == nil)
            if replaceBanner {
                store.scheduleUndoBanner(title: "Replacement", restoreCommands: [], previousDevices: [], deviceCount: 1)
            }
            return replaceBanner
        }

        L10n.$overrideLanguage.withValue(.en) { #expect(store.undoTurnAllOff() == nil) }
        #expect(prompts == 1 && store.undoTimerTask?.isCancelled == false)
        #expect(store.undoConfirmationCountdown == nil)
        #expect(await provider.executedCommands.isEmpty)
        if replaceBanner {
            #expect(store.undoBanner?.title == "Replacement" && store.undoBanner?.id != originalID)
            #expect(store.toastNotice?.message == "The undo item changed. Undo was cancelled.")
        } else {
            #expect(store.undoBanner?.id == originalID)
            #expect(store.toastNotice?.message == "Cancelled the action for 左键")
        }
    }

    @Test("Card and cover controls preserve post-modal cloud state, roll back to post-modal values, and fail closed on cover direction flip or in-flight reversal")
    func cardAndCoverControlsPostModalStateAndRollback() async throws {
        let gate = SleepGate()
        var initialHome = SynthesizedHome(devices: [
            Self.heaterClimate(isOn: true, hvacMode: "heat", currentTemp: 19, targetTemp: 22, fanMode: "low")
        ])
        initialHome.deviceBackends = ["heater": .xiaomiCloud]
        let (store, mock) = try await Self.makeStore(initialHome)
        await mock.setFailingTargets(["climate.heater"])
        store.controlDebounceSleep = { _ in await gate.sleep() }

        store.manualControlConfirmationHandler = { _ in
            var updatedHome = SynthesizedHome(devices: [
                Self.heaterClimate(isOn: true, hvacMode: "heat", currentTemp: 21, targetTemp: 26, fanMode: "high")
            ])
            updatedHome.deviceBackends = ["heater": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(updatedHome))
            return true
        }
        store.stepClimateTemperature("heater", delta: 2)
        if case .climate(let optSpec) = store.devices.first?.kind {
            #expect(optSpec.targetTemperature == 24 && optSpec.currentTemperature == 21 && optSpec.fanMode == "high")
        }
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await store.debounceTasks["heater.temp"]?.value
        if case .climate(let rbSpec) = store.devices.first?.kind {
            #expect(rbSpec.targetTemperature == 26 && rbSpec.currentTemperature == 21 && rbSpec.fanMode == "high")
        }

        await mock.setFailingTargets([])
        store.manualControlConfirmationHandler = { _ in
            var switchedHome = SynthesizedHome(devices: [Self.heaterClimate()])
            switchedHome.deviceBackends = ["heater": .homeAssistant]
            store.handleProviderEvent(.snapshotUpdated(switchedHome))
            return true
        }
        let countBefore = await mock.executedCommands.count
        store.setClimateMode("heater", mode: "heat")
        #expect(store.manualWriteSessions["heater"] == nil)
        #expect((await mock.executedCommands.count) == countBefore)

        let coverGate = SleepGate()
        let (coverStore, coverMock) = try await Self.makeStore(SynthesizedHome(devices: [Self.garageDoor(position: 0)]))
        coverStore.controlDebounceSleep = { _ in await coverGate.sleep() }
        await coverMock.holdNextExecute()
        await coverMock.setFailingTargets(["cover.garage"])

        coverStore.manualControlConfirmationHandler = { _ in
            coverStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.garageDoor(position: 25, motion: .stopped)])))
            return true
        }
        let exitsBefore = coverStore.manualWriteExits
        coverStore.setCoverMotor("garage", description: "Open")
        await waitUntil { await coverMock.executeStarted > 0 }
        #expect(coverStore.coverCommandOrigins["garage"] == 25)
        await coverMock.releaseExecute()
        await waitUntil { coverStore.manualWriteExits > exitsBefore }
        #expect(coverStore.devices.first?.coverSpec?.positionPercent == 25)

        await coverMock.setFailingTargets([])
        coverStore.manualControlConfirmationHandler = { _ in
            coverStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.garageDoor(name: "主车库门", position: 35, motion: .stopped)])))
            return true
        }
        coverStore.setCoverPosition("garage", percent: 60)
        #expect(coverStore.coverCommandOrigins["garage"] == 35 && coverStore.devices.first?.name == "主车库门")
        await waitUntil { coverGate.waiting == 1 }
        coverGate.release()
        await coverStore.debounceTasks["garage.cover"]?.value
        #expect(await coverMock.executedCommands.last == .setNumberValue(entityId: "cover.garage", value: 60))

        coverStore.clearManualWriteSession(for: "garage", bumpRevision: true)
        coverStore.clearOptimisticLockEntries(for: "garage")
        coverStore.coverCommandOrigins.removeValue(forKey: "garage")
        coverStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.garageDoor(position: 10, motion: .stopped)])))
        let sentBeforeFlip = await coverMock.executedCommands.count
        coverStore.manualControlConfirmationHandler = { _ in
            coverStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.garageDoor(position: 80, motion: .stopped)])))
            return true
        }
        coverStore.setCoverPosition("garage", percent: 50)
        if coverGate.waiting > 0 {
            coverGate.release()
            await coverStore.debounceTasks["garage.cover"]?.value
        }
        #expect(await coverMock.executedCommands.count == sentBeforeFlip && coverStore.devices.first?.coverSpec?.positionPercent == 80)

        await coverMock.holdNextExecute()
        coverStore.manualControlConfirmationHandler = { _ in true }
        coverStore.setCoverMotor("garage", description: "Open")
        await waitUntil { await coverMock.executeStarted > 0 }
        await coverMock.setFailingCommands { $0 == .setSelectOption(entityId: "cover.garage", option: "Close") }
        coverStore.manualControlConfirmationHandler = { _ in
            coverStore.handleProviderEvent(.snapshotUpdated(SynthesizedHome(devices: [Self.garageDoor(position: 40, motion: .opening)])))
            return true
        }
        let exitsBeforeClose = coverStore.manualWriteExits
        coverStore.setCoverMotor("garage", description: "Close")
        await waitUntil { coverStore.manualWriteExits > exitsBeforeClose }
        #expect(coverStore.devices.first?.coverSpec?.positionPercent == 40 && coverStore.coverCommandOrigins["garage"] == nil)
        await coverMock.releaseExecute()
    }

    @Test("Facet value and action controls update undo origin, clamp to post-modal range, fail closed on hazard escalation/source-switch, and toast on offline")
    func facetControlsPostModalUndoClampEscalationAndOffline() async throws {
        let gate = SleepGate()
        var home = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 40)])
        home.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(40)), Self.childLockToggle(value: .bool(false))]]
        home.deviceBackends = ["wh": .xiaomiCloud]
        let (store, mock) = try await Self.makeStore(home)
        store.controlDebounceSleep = { _ in await gate.sleep() }

        store.setFacetValue("wh", controlId: "2.5", value: .number(39))
        store.pauseUndoBannerCountdown()
        #expect(store.undoBanner?.restoreCommands == [.setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(40))])

        store.manualControlConfirmationHandler = { _ in
            var cloudHome = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 52)])
            cloudHome.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(52)), Self.childLockToggle(value: .bool(true))]]
            cloudHome.deviceBackends = ["wh": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(cloudHome))
            return true
        }
        store.setFacetValue("wh", controlId: "2.5", value: .number(75))
        store.pauseUndoBannerCountdown()
        #expect(store.deviceFacets["wh"]?.first { $0.id == "2.5" }?.value == .number(75))
        #expect(store.deviceFacets["wh"]?.first { $0.id == "2.6" }?.value == .bool(true))
        #expect(store.undoBanner?.restoreCommands == [.setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(52))])
        await waitUntil { gate.waiting == 1 }
        gate.release()
        await store.debounceTasks["wh.facet.2.5"]?.value
        #expect(await mock.executedCommands == [.setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(75))])
        await store.undoTurnAllOff()?.value
        #expect(await mock.executedCommands.last == .setMiotProperty(entityId: "miot:wh:2", piid: 5, value: .number(52)))

        store.optimisticFacetLocks.removeAll()
        var resetHome = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 40)])
        resetHome.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(40))]]
        resetHome.deviceBackends = ["wh": .xiaomiCloud]
        store.handleProviderEvent(.snapshotUpdated(resetHome))
        let sentCount = await mock.executedCommands.count

        store.manualControlConfirmationHandler = { _ in
            var unknownHome = SynthesizedHome(devices: [Self.waterHeater(cardTarget: nil)])
            unknownHome.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: nil)]]
            unknownHome.deviceBackends = ["wh": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(unknownHome))
            return true
        }
        store.setFacetValue("wh", controlId: "2.5", value: .number(50))
        #expect(store.facetWrites.isEmpty && store.undoBanner == nil)
        #expect((await mock.executedCommands.count) == sentCount)

        store.handleProviderEvent(.snapshotUpdated(resetHome))
        store.manualControlConfirmationHandler = { _ in
            var offlineHome = SynthesizedHome(devices: [Self.waterHeater(cardTarget: 40, isOnline: false)])
            offlineHome.deviceFacets = ["wh": [Self.targetTemperatureSlider(value: .number(40))]]
            offlineHome.deviceBackends = ["wh": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(offlineHome))
            return true
        }
        store.dismissToast()
        store.setFacetValue("wh", controlId: "2.5", value: .number(70))
        #expect(store.toastNotice?.isError == true)
        #expect((await mock.executedCommands.count) == sentCount)

        let feeder = SmartDevice(
            id: "feeder", name: "宠物喂食器", roomId: "living", roomName: "客厅", model: "mmgg.feeder.inland",
            isOnline: true, kind: .generic(GenericSpec(deviceType: "pet-feeder", typeTitle: "宠物喂食器", isReadOnly: false)), accountId: "acc-1"
        )
        func feedAction(maxPortion: Double) -> FacetControl {
            FacetControl(
                id: "2.1", kind: .button, name: "out-food", title: "出粮", serviceName: "pet-feeder",
                isWritable: true, writesByDefault: true, isHighValue: true, target: .action(entityId: "miot:feeder:2:1"),
                arguments: [MiotFacetArgument(propertyId: 1, name: "feeding-measure", format: "uint8", range: MiotFacetRange(min: 1, max: maxPortion, step: 1))],
                portionArgumentIndex: 0
            )
        }
        var feederHome = SynthesizedHome(devices: [feeder])
        feederHome.deviceFacets = ["feeder": [feedAction(maxPortion: 10)]]
        feederHome.deviceBackends = ["feeder": .xiaomiCloud]
        store.handleProviderEvent(.snapshotUpdated(feederHome))

        store.manualControlConfirmationHandler = { _ in
            var updatedSpecHome = SynthesizedHome(devices: [feeder])
            updatedSpecHome.deviceFacets = ["feeder": [feedAction(maxPortion: 3)]]
            updatedSpecHome.deviceBackends = ["feeder": .xiaomiCloud]
            store.handleProviderEvent(.snapshotUpdated(updatedSpecHome))
            return true
        }
        store.runFacetAction("feeder", controlId: "2.1", portion: 5)
        await store.debounceTasks["feeder.facet.2.1"]?.value
        #expect(await mock.executedCommands.last == .callMiotAction(entityId: "miot:feeder:2:1", arguments: [.number(3)]))
    }

    @Test("Batch undo, assistant multi-intent, pre-send source switch, raycastWrite await window, and screen lock during modal enforce confirmation invariants")
    func batchUndoAssistantPreSendRaycastAndScreenLockGuards() async throws {
        let wallBefore = Self.wallSwitch(id: "wall-before", name: "玄关左键", isOn: true)
        let heaterPlug = Self.wallSwitch(id: "plug-heater", name: "取暖器插座", model: "chuangmi.plug.212a01", isOn: true)
        let wallAfter = Self.wallSwitch(id: "wall-after", name: "走廊右键", isOn: true)
        var home = SynthesizedHome(devices: [wallBefore, heaterPlug, wallAfter])
        home.deviceBackends = [wallBefore.id: .xiaomiCloud, heaterPlug.id: .xiaomiCloud, wallAfter.id: .xiaomiCloud]
        let (store, mock) = try await Self.makeStore(home)

        store.markSwitchAsLight(wallBefore.id)
        store.markSwitchAsLight(wallAfter.id)
        for id in [wallBefore.id, heaterPlug.id, wallAfter.id] { store.setJoinsAllOff(true, deviceId: id) }
        _ = await store.turnAllOff()?.value
        store.pauseUndoBannerCountdown()
        let countAfterOff = await mock.executedCommands.count

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
        await store.undoTurnAllOff()?.value
        #expect(Array((await mock.executedCommands).dropFirst(countAfterOff)) == [.setSwitch(entityId: "switch.plug-heater", isOn: true)])
        #expect(promptedMessages.contains { $0.contains("玄关左键") } && promptedMessages.contains { $0.contains("走廊右键") })

        store.markSwitchAsLight(wallBefore.id)
        store.manualControlConfirmationHandler = { prompt in
            if prompt.message.contains("取暖器插座") {
                store.unmarkSwitchAsLight(wallBefore.id)
                return true
            }
            return false
        }
        await store.applyAssistantSuggestion(AssistantSuggestion(
            id: "sug-1", title: "打开两个开关",
            intents: [DeviceIntent(targetId: wallBefore.id, operation: .power(true)), DeviceIntent(targetId: heaterPlug.id, operation: .power(true))]
        ))
        #expect(await mock.executedCommands.last == .setSwitch(entityId: "switch.plug-heater", isOn: true))

        var coverHome = SynthesizedHome(devices: [Self.garageDoor(position: 0, accountId: "acc-1")])
        coverHome.deviceBackends = ["garage": .xiaomiCloud]
        let (coverStore, coverMock) = try await Self.makeStore(coverHome)
        coverStore.manualControlConfirmationHandler = { _ in true }
        let initialCoverRow = try #require(coverStore.devices.first)
        let coverTask = try #require(coverStore.togglePrimary(initialCoverRow))
        var switchedCoverHome = SynthesizedHome(devices: [Self.garageDoor(position: 65, accountId: "acc-2")])
        switchedCoverHome.deviceBackends = ["garage": .xiaomiCloud]
        coverStore.handleProviderEvent(.snapshotUpdated(switchedCoverHome))
        #expect(await coverTask.value == false)
        #expect((await coverMock.executedCommands).isEmpty)
        #expect(coverStore.coverCommandOrigins["garage"] == nil && coverStore.devices.first?.coverSpec?.positionPercent == 65)

        func deskLamp(accountId: String, brightness: Int, kelvin: Int) -> SmartDevice {
            SmartDevice(
                id: "lamp", name: "书房台灯", roomId: "study", roomName: "书房", model: "yeelink.light.lamp4", isOnline: true,
                kind: .light(LightSpec(entityId: "light.study", isOn: true, brightnessPercent: brightness, colorTempKelvin: kelvin, minKelvin: 2700, maxKelvin: 6500, powerWritable: true, brightnessWritable: true, colorWritable: true)),
                accountId: accountId
            )
        }
        var lampHome = SynthesizedHome(devices: [deskLamp(accountId: "acc-1", brightness: 80, kelvin: 5000)])
        lampHome.deviceBackends = ["lamp": .xiaomiCloud]
        let (lampStore, lampMock) = try await Self.makeStore(lampHome)
        await lampMock.holdSnapshots()
        await lampMock.holdNextExecute()
        let raycastTask = Task { await lampStore.executeRaycastDirectCommand("把书房台灯设为柔和月光模式") }
        await waitUntil { await lampMock.executeStarted == 1 }
        var switchedLampHome = SynthesizedHome(devices: [deskLamp(accountId: "acc-2", brightness: 90, kelvin: 5500)])
        switchedLampHome.deviceBackends = ["lamp": .homeAssistant]
        lampStore.handleProviderEvent(.snapshotUpdated(switchedLampHome))
        await lampMock.releaseExecute()
        let raycastResult = await raycastTask.value
        #expect(raycastResult.handled && raycastResult.isError)
        #expect(await lampMock.executedCommands == [.setLightBrightness(entityId: "light.study", percent: 15)])

        let (lockStore, lockMock) = try await Self.makeStore(SynthesizedHome(devices: [Self.heaterClimate(isOn: false)]))
        lockStore.manualControlConfirmationHandler = { _ in lockStore.setScreenLocked(true); return true }
        let plan = try #require(await lockStore.runAssistantCommand("打开卧室取暖器"))
        #expect(plan.intents.isEmpty && plan.reply == lockStore.screenLockBlockedMessage)
        #expect((await lockMock.executedCommands).isEmpty)
    }
}
