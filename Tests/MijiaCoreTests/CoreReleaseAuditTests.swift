import Foundation
import KeychainTestSupport
import Testing
@testable import MijiaCore

@Suite("1.2.5 Core Release Audit Regressions")
struct CoreReleaseAuditTests {

    private actor AsyncGate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var enteredCount = 0

        func waitUntilEntered() async {
            if enteredCount > 0 { return }
            await withCheckedContinuation { cont in enteredContinuation = cont }
        }

        func enterAndWait() async {
            enteredCount += 1
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { cont in releaseContinuation = cont }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor AsyncSignal {
        private var continuation: CheckedContinuation<Void, Never>?
        private var signaled = false
        func wait() async {
            if signaled { return }
            await withCheckedContinuation { cont in continuation = cont }
        }
        func signal() {
            signaled = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor GatedFailingProvider: HomeProvider {
        private let initialSnapshot: SynthesizedHome
        private let gate: AsyncGate
        init(snapshot: SynthesizedHome, gate: AsyncGate) {
            self.initialSnapshot = snapshot
            self.gate = gate
        }
        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            let snap = initialSnapshot
            return AsyncStream { cont in
                cont.yield(.statusChanged(.connected))
                cont.yield(.snapshotUpdated(snap))
            }
        }
        func refreshNow() async {}
        func execute(_ command: DeviceCommand) async throws {
            await gate.enterAndWait()
            throw HomeProviderError.serviceCallFailed(500, "Simulated failure after context switch")
        }
        func triggerScene(_ sceneId: String) async throws {}
    }

    private actor HAProbeState {
        var attempts = 0
        var sleeps: [Duration] = []
        var suggestions: [HADiscoveredInstance] = []
        var scriptedOutcomes: [HAWebSocketProvider.ConnectTestOutcome]

        init(outcomes: [HAWebSocketProvider.ConnectTestOutcome]) { self.scriptedOutcomes = outcomes }
        func nextOutcome() -> HAWebSocketProvider.ConnectTestOutcome {
            attempts += 1
            return scriptedOutcomes.isEmpty ? .authenticatedStayConnected : scriptedOutcomes.removeFirst()
        }
        func replaceOutcomes(_ outcomes: [HAWebSocketProvider.ConnectTestOutcome]) { scriptedOutcomes = outcomes }
        func recordSleep(_ duration: Duration) { sleeps.append(duration) }
        func recordSuggestion(_ instance: HADiscoveredInstance) { suggestions.append(instance) }
    }

    private actor SelectiveCommandProvider: HomeProvider {
        private let initialSnapshot: SynthesizedHome
        private var failingCommands: [DeviceCommand] = []
        private(set) var executedCommands: [DeviceCommand] = []
        init(snapshot: SynthesizedHome) { self.initialSnapshot = snapshot }
        func setFailingCommands(_ commands: [DeviceCommand]) { failingCommands = commands }
        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            let snap = initialSnapshot
            return AsyncStream { cont in
                cont.yield(.statusChanged(.connected))
                cont.yield(.snapshotUpdated(snap))
            }
        }
        func refreshNow() async {}
        func execute(_ command: DeviceCommand) async throws {
            executedCommands.append(command)
            if failingCommands.contains(command) {
                throw HomeProviderError.serviceCallFailed(503, "Simulated command failure")
            }
        }
        func triggerScene(_ sceneId: String) async throws {}
    }

    private static func makeLamp(_ id: String = "lamp", brightness: Int = 20, kelvin: Int = 3000, effects: [String] = []) -> SmartDevice {
        SmartDevice(
            id: id,
            name: "台灯-\(id)",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.\(id)",
                isOn: true,
                brightnessPercent: brightness,
                colorTempKelvin: kelvin,
                minKelvin: 2700,
                maxKelvin: 6500,
                currentEffect: effects.first,
                availableEffects: effects
            ))
        )
    }

    @Test("Sibling manual adjustments keep pending debounced writes alive, power-off or mutually exclusive controls cancel them, and partial/dual failures roll back independently")
    @MainActor
    func siblingAndMutuallyExclusiveControlWritesAndRollback() async throws {
        let lamp = Self.makeLamp("lamp", brightness: 60, kelvin: 3000, effects: ["Day", "Night"])
        let fan = SmartDevice(id: "fan", name: "净化器", roomId: "living", roomName: "客厅", model: "zhimi.airpurifier.mb5", isOnline: true, kind: .fan(FanSpec(entityId: "fan.purifier", isOn: true, percentage: 35, presetMode: "Auto", availablePresetModes: ["Auto", "Sleep", "Favorite"])))
        let curtain = SmartDevice(id: "curtain", name: "客厅窗帘", roomId: "living", roomName: "客厅", model: "lumi.curtain.hagl04", isOnline: true, kind: .cover(CoverSpec(entityId: "cover.curtain", subtype: .curtain, positionPercent: 20, positionWritable: true, openDescription: "Open", closeDescription: "Close", pauseDescription: "Pause")))
        let ac = SmartDevice(id: "ac", name: "空调", roomId: "study", roomName: "书房", model: "xiaomi.aircondition.mt0", isOnline: true, kind: .climate(ClimateSpec(entityId: "climate.ac", isOn: true, hvacMode: "cool", availableModes: ["off", "cool", "heat"], targetTemperature: 26)))

        let suite = "test.audit.f1.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp, fan, curtain, ac]))
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.controlDebounceInterval = .zero

        store.setLightBrightness("lamp", percent: 70)
        let brightnessTask = store.debounceTasks["lamp.brightness"]
        store.setLightColorTemp("lamp", kelvin: 4500)
        let colorTask = store.debounceTasks["lamp.colortemp"]
        await brightnessTask?.value
        await colorTask?.value
        let commandsAfterLight = await provider.executedCommands
        #expect(commandsAfterLight.contains(.setLightBrightness(entityId: "light.lamp", percent: 70)))
        #expect(commandsAfterLight.contains(.setLightColorTemp(entityId: "light.lamp", kelvin: 4500)))

        store.controlDebounceInterval = .milliseconds(70)
        store.setLightColorTemp("lamp", kelvin: 4800)
        let lampColorTask = try #require(store.debounceTasks["lamp.colortemp"])
        store.setLightEffect("lamp", effect: "Night")
        #expect(store.debouncedWrites["lamp.colortemp"] == nil)

        store.setFanPercentage("fan", percent: 85)
        let fanPercentTask = try #require(store.debounceTasks["fan.fanpercent"])
        store.setFanPresetMode("fan", preset: "Sleep")
        #expect(store.debouncedWrites["fan.fanpercent"] == nil)

        store.setCoverPosition("curtain", percent: 80)
        let coverPosTask = try #require(store.debounceTasks["curtain.cover"])
        store.setCoverMotor("curtain", description: "Pause")
        #expect(store.debouncedWrites["curtain.cover"] == nil)

        await lampColorTask.value
        await fanPercentTask.value
        await coverPosTask.value

        store.controlDebounceInterval = .seconds(60)
        store.setLightBrightness("lamp", percent: 85)
        let pendingOff = store.debounceTasks["lamp.brightness"]
        _ = await store.togglePrimary(lamp)?.value
        await pendingOff?.value
        #expect(store.debouncedWrites.isEmpty)

        let selSuite = "test.audit.r2.sibling.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: selSuite)?.removePersistentDomain(forName: selSuite) }
        let selProvider = SelectiveCommandProvider(snapshot: SynthesizedHome(devices: [
            Self.makeLamp("l1", brightness: 20, kelvin: 3000),
            Self.makeLamp("l2", brightness: 25, kelvin: 3200),
            Self.makeLamp("l3", brightness: 30, kelvin: 3500),
        ]))
        let selStore = HomeStore(provider: selProvider, defaultsSuiteName: selSuite)
        selStore.toastAutoDismissInterval = nil
        try await selStore.waitForTestSnapshot()
        selStore.controlDebounceInterval = .zero

        await selProvider.setFailingCommands([.setLightBrightness(entityId: "light.l1", percent: 70)])
        selStore.setLightBrightness("l1", percent: 70)
        let l1B = selStore.debounceTasks["l1.brightness"]
        selStore.setLightColorTemp("l1", kelvin: 4500)
        let l1C = selStore.debounceTasks["l1.colortemp"]
        await l1B?.value
        await l1C?.value
        if case .light(let s1) = try #require(selStore.devices.first { $0.id == "l1" }).kind {
            #expect(s1.brightnessPercent == 20 && s1.colorTempKelvin == 4500)
        }
        #expect(selStore.optimisticLockUntil["l1"] != nil)

        await selProvider.setFailingCommands([
            .setLightBrightness(entityId: "light.l3", percent: 75),
            .setLightColorTemp(entityId: "light.l3", kelvin: 5500),
        ])
        selStore.setLightBrightness("l3", percent: 75)
        let l3B = selStore.debounceTasks["l3.brightness"]
        selStore.setLightColorTemp("l3", kelvin: 5500)
        let l3C = selStore.debounceTasks["l3.colortemp"]
        await l3B?.value
        await l3C?.value
        if case .light(let s3) = try #require(selStore.devices.first { $0.id == "l3" }).kind {
            #expect(s3.brightnessPercent == 30 && s3.colorTempKelvin == 3500)
        }
        #expect(selStore.optimisticLockUntil["l3"] == nil)

        let gate = AsyncGate()
        let gatedProvider = GatedFailingProvider(snapshot: SynthesizedHome(devices: [Self.makeLamp()]), gate: gate)
        let suite2 = "test.audit.sec5.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite2)?.removePersistentDomain(forName: suite2) }
        let store2 = HomeStore(provider: gatedProvider, defaultsSuiteName: suite2)
        store2.toastAutoDismissInterval = nil
        try await store2.waitForTestSnapshot()
        let task = store2.togglePrimary(Self.makeLamp())
        await gate.waitUntilEntered()
        store2.invalidateUndoContext()
        await gate.release()
        _ = await task?.value
        #expect(store2.toastNotice == nil)
    }

    @Test("DeviceDeduplicator canonical ID uniqueness on re-pairing, HAWebSocketProvider auth stop/backoff reset/cover clamp, and HAHomeSnapshot entity deletion on null state")
    func deduplicatorRePairingAndHAWebSocketAndSnapshotInvariants() async throws {
        let ha1 = SmartDevice(id: "light.desk", name: "书桌灯", roomId: "study", roomName: "书房", model: "yeelink.light.lamp4", isOnline: true, kind: .light(LightSpec(entityId: "light.desk", isOn: true)))
        let mi2 = SmartDevice(id: "1002", name: "书桌灯", roomId: "study", roomName: "书房", model: "yeelink.light.lamp4", isOnline: true, kind: .light(LightSpec(entityId: "miot:1002:2", isOn: true)))
        let mi3 = SmartDevice(id: "1003", name: "新书桌灯", roomId: "study", roomName: "书房", model: "yeelink.light.lamp4", isOnline: true, kind: .light(LightSpec(entityId: "miot:1003:2", isOn: true)))

        var homeHA1 = SynthesizedHome(devices: [ha1])
        homeHA1.deviceIdentities = ["light.desk": DeviceSourceIdentity(dids: [], macAddresses: ["AA:BB:CC:DD:EE:02"], uniqueIds: ["uid-desk"], model: "yeelink.light.lamp4", name: "书桌灯", roomName: "书房", kindTag: .light)]
        var homeMi1 = SynthesizedHome(devices: [mi2])
        homeMi1.deviceIdentities = ["1002": DeviceSourceIdentity(dids: ["1002"], macAddresses: ["AA:BB:CC:DD:EE:02"], uniqueIds: [], model: "yeelink.light.lamp4", name: "书桌灯", roomName: "书房", kindTag: .light)]

        let initial = DeviceDeduplicator.merge(homeAssistant: homeHA1, xiaomiCloud: homeMi1, knownPreferenceIDs: ["1002"])
        #expect(initial.home.devices.map(\.id) == ["1002"])

        var homeHA2 = SynthesizedHome(devices: [ha1])
        homeHA2.deviceIdentities = ["light.desk": DeviceSourceIdentity(dids: [], macAddresses: ["AA:BB:CC:DD:EE:03"], uniqueIds: ["uid-desk"], model: "yeelink.light.lamp4", name: "新书桌灯", roomName: "书房", kindTag: .light)]
        var homeMi2 = SynthesizedHome(devices: [mi2, mi3])
        homeMi2.deviceIdentities = [
            "1002": DeviceSourceIdentity(dids: ["1002"], macAddresses: ["AA:BB:CC:DD:EE:02"], uniqueIds: [], model: "yeelink.light.lamp4", name: "旧书桌灯", roomName: "书房", kindTag: .light),
            "1003": DeviceSourceIdentity(dids: ["1003"], macAddresses: ["AA:BB:CC:DD:EE:03"], uniqueIds: [], model: "yeelink.light.lamp4", name: "新书桌灯", roomName: "书房", kindTag: .light),
        ]
        let repaired = DeviceDeduplicator.merge(homeAssistant: homeHA2, xiaomiCloud: homeMi2, canonical: initial.canonical, knownPreferenceIDs: ["1002"])
        let ids = repaired.home.devices.map(\.id)
        #expect(ids.count == 2 && Set(ids).count == 2 && ids.contains("1002") && repaired.routes["1002"]?.sourceDeviceID == "1002")

        #expect(HAWebSocketProvider.mapCommandToService(.setNumberValue(entityId: "cover.blinds", value: .nan)).payload["position"] as? Int == 0)
        #expect(HAWebSocketProvider.mapCommandToService(.setNumberValue(entityId: "cover.blinds", value: 1e30)).payload["position"] as? Int == 100)

        let unauthState = HAProbeState(outcomes: [.failedBeforeAuth(HomeProviderError.unauthorized)])
        let unauthProvider = HAWebSocketProvider(baseURLString: "http://192.168.1.10:8123", token: "revoked-token", rediscover: { _ in [] }, allowsToken: { _ in true })
        await unauthProvider.setTestSeams(connectOverride: { await unauthState.nextOutcome() }, reconnectSleep: { await unauthState.recordSleep($0) })
        let (unauthLog, unauthTask) = consume(unauthProvider)
        defer { unauthTask.cancel() }
        #expect(await unauthLog.wait { await $0.statuses.contains { if case .disconnected = $0 { return true }; return false } })
        #expect(await unauthState.attempts == 1)
        #expect(await unauthState.sleeps.isEmpty)
        await unauthState.replaceOutcomes([.authenticatedStayConnected])
        await unauthProvider.updateCredentials(baseURLString: "http://192.168.1.10:8123", token: "fresh-token")
        #expect(await unauthLog.wait { await $0.statuses.contains(.connected) })
        await unauthProvider.shutdown()

        let backoffState = HAProbeState(outcomes: [
            .failedBeforeAuth(URLError(.cannotConnectToHost)),
            .authenticatedThenDisconnected(URLError(.networkConnectionLost)),
            .authenticatedStayConnected,
        ])
        let backoffProvider = HAWebSocketProvider(baseURLString: "http://192.168.1.10:8123", token: "valid-token", rediscover: { _ in [] }, allowsToken: { _ in true })
        await backoffProvider.setTestSeams(connectOverride: { await backoffState.nextOutcome() }, reconnectSleep: { await backoffState.recordSleep($0) })
        let (backoffLog, backoffTask) = consume(backoffProvider)
        defer { backoffTask.cancel() }
        #expect(await backoffLog.wait { _ in await backoffState.attempts == 3 })
        #expect(await backoffState.sleeps == [.seconds(0.8), .seconds(0.8)])
        await backoffProvider.shutdown()

        var projection = HAHomeSnapshot()
        func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
            ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
        }
        _ = try projection.receive(reply(1, .array([])))
        _ = try projection.receive(reply(2, .array([])))
        _ = try projection.receive(reply(3, .array([.object(["entity_id": .string("light.keep")]), .object(["entity_id": .string("light.removed")])])))
        _ = try projection.receive(reply(4, .array([
            .object(["entity_id": .string("light.keep"), "state": .string("on"), "attributes": .object(["friendly_name": .string("Keep")])]),
            .object(["entity_id": .string("light.removed"), "state": .string("on"), "attributes": .object(["friendly_name": .string("Removed")])]),
        ])))
        let afterRemove = try #require(try projection.receive([
            "type": .string("event"),
            "event": .object(["event_type": .string("state_changed"), "data": .object(["entity_id": .string("light.removed"), "new_state": .null])]),
        ]))
        #expect(afterRemove.devices.map(\.id) == ["light.keep"])
    }

    @Test("XiaomiCameraBridge startup coalescing, MiotSpecStore corrupt index protection, MiAccountLogin keepalive, MiCloudProvider readBack/shutdown, and DualSource shutdown")
    func cameraBridgeSpecStoreLoginAndMiCloudShutdown() async throws {
        let bridge = XiaomiCameraBridge()
        let gate = AsyncGate()
        let joined = AsyncSignal()
        await bridge.setEnsureRunningOverride({ await gate.enterAndWait() }, onJoinedStartup: { await joined.signal() })
        async let first: Void = {
            _ = try? await bridge.startBridge(did: "10001", model: "chuangmi.camera.061a01", localIP: "127.0.0.1", clientPublic: "aa", clientPrivate: "bb", devicePublic: "cc", sign: "dd", vendor: "cs2", uid: "T1", quality: .sd, channel: 0, subdid: nil)
        }()
        await gate.waitUntilEntered()
        async let second: Void = {
            _ = try? await bridge.startBridge(did: "10002", model: "chuangmi.camera.061a01", localIP: "127.0.0.1", clientPublic: "aa", clientPrivate: "bb", devicePublic: "cc", sign: "dd", vendor: "cs2", uid: "T2", quality: .sd, channel: 0, subdid: nil)
        }()
        await joined.wait()
        await gate.release()
        _ = await (first, second)
        #expect(await gate.enteredCount == 1)
        #expect(await bridge.activeRelayCount == 0)

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("MiotSpecAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        try Data(#"{"instances":[]}"#.utf8).write(to: cacheDir.appendingPathComponent("miot-instances.json"))
        let mirrorCount = MiotSpecStore.defaultMirrorBaseURLs.count
        let indexCalls = ScriptedTransport.Counter()
        let specTransport = ScriptedTransport { req in
            if req.url!.absoluteString.contains("instances?status=released") {
                if indexCalls.increment() <= mirrorCount { return (200, [:], "<html>Captive Portal</html>") }
                return (200, [:], #"{"instances":[{"model":"acme.light.test1","version":1,"type":"urn:miot-spec-v2:device:light:0000A001:acme-test1:1"}]}"#)
            }
            return (200, [:], MiotFixtures.ceiling22)
        }
        let specStore = MiotSpecStore(transport: specTransport, cacheDirectory: cacheDir)
        await #expect(throws: MiCloudError.self) { _ = try await specStore.spec(model: "acme.light.test1", specType: nil) }
        #expect(try await specStore.spec(model: "acme.light.test1", specType: nil) != nil)

        let polls = ScriptedTransport.Counter()
        let loginTransport = ScriptedTransport { req in
            if req.url!.absoluteString.hasPrefix("https://lp.example") {
                let step = polls.increment()
                if step <= 2 { return (200, [:], step == 1 ? "" : "  \r\n ") }
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","passToken":"p","location":"https://sts.api.io.mi.com/sts?x=1"}"#)
            }
            return (200, ["Set-Cookie": "serviceToken=tok-keepalive; path=/; domain=.mi.com"], "ok")
        }
        let ticket = QRLoginTicket(qrImageURL: URL(string: "https://qr.example/1")!, loginURL: URL(string: "https://login.example/1")!, longPollURL: URL(string: "https://lp.example/1")!, timeout: 30)
        let session = try await MiAccountLogin(transport: loginTransport, redirectlessTransport: loginTransport).waitForScan(ticket)
        #expect(session.serviceToken == "tok-keepalive")

        let camSpec = MiotFixtures.decode(#"{"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:1","services":[{"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]}]}]}"#)
        let camRecord = MiDeviceRecord(did: "9901", name: "客厅摄像机", model: "chuangmi.camera.061a01", isOnline: true, localIp: "192.168.50.10")
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord, camRecord],
            rooms: [MiRoom(id: "r1", name: "客厅", dids: ["123", "9901"])],
            values: MiotFixtures.lightValues.merging([MiotPropKey(did: "9901", siid: 2, piid: 1): .bool(true)]) { a, _ in a }
        )
        struct CombinedSpecs: MiotSpecSource {
            let map: [String: MiotDeviceSpec]
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? { map[model] }
        }
        let stubBridge = StubXiaomiCameraBridge()
        let miProvider = MiCloudProvider(
            sessionLoader: { session },
            apiFactory: { _ in api },
            specSource: CombinedSpecs(map: MiotFixtures.specs.merging(["chuangmi.camera.061a01": camSpec]) { a, _ in a }),
            cameraBridge: stubBridge,
            pollInterval: .seconds(60),
            followUpDelay: .seconds(60)
        )
        let (log, task) = consume(miProvider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let initial = try #require(await log.snapshots.first)
        #expect(initial.closesAwayGap == true)

        try await miProvider.execute(.setLightPower(entityId: "miot:123:2", isOn: false))
        #expect(await miProvider.readBack(deviceId: "123") == .published)
        #expect(await log.wait { await $0.snapshots.count >= 2 })
        #expect(await log.snapshots.last?.closesAwayGap == false)

        let camDevice = try #require(initial.devices.first { $0.id == "9901" })
        _ = try await miProvider.resolveCameraStream(for: camDevice)
        let dualProvider = DualSourceHomeProvider(homeAssistant: nil, xiaomiCloud: miProvider)
        await dualProvider.shutdown()
        #expect(await stubBridge.stopCalls == ["9901"])
    }

    @Test("HAFacets unknown select, SafetyMonitor removed-device pruning, MiotCommandMapper step/non-finite clamp, MiCloudClient history cache, EnergyHistory, LG client demo exit, and proactive context guard")
    @MainActor
    func facetsSafetyMapperHistoryAndStoreRegressions() async throws {
        let hostDevice = SmartDevice(id: "fan.living", name: "风扇", roomId: "living", roomName: "客厅", model: "dmaker.fan", isOnline: true, kind: .fan(FanSpec(entityId: "fan.living", isOn: true)))
        let facets = HAFacetEngine.controls(
            entities: [HAEntityEntry(entity_id: "select.oscillation_mode", device_id: "dev1")],
            states: ["select.oscillation_mode": HAEntityState(entityId: "select.oscillation_mode", state: "none", attributes: ["friendly_name": .string("摇头角度"), "options": .array([.string("30°"), .string("60°")])])],
            excluding: ["fan.living"],
            device: hostDevice
        )
        #expect(facets.first?.value == nil)

        let safetySuite = "test.audit.f30h.safety.\(UUID().uuidString)"
        let safetyDefaults = UserDefaults(suiteName: safetySuite)!
        defer { safetyDefaults.removePersistentDomain(forName: safetySuite) }
        var monitor = SafetyMonitor(defaults: safetyDefaults)
        let policy = SensorAlertPolicy(enabled: [:], onlyWhenAway: false, includesAway: false)
        let heater = SmartDevice(id: "heater", name: "取暖器", roomId: "study", roomName: "书房", model: "cuco.plug", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: true, powerWatts: 1200)))
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0).isEmpty)
        #expect(monitor.evaluate(devices: [], favorites: [], sensorPolicy: policy, now: t0 + 10 * 60).isEmpty)
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0 + 40 * 60).isEmpty)
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0 + 50 * 60).isEmpty)
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0 + 86 * 60).map(\.id) == ["longrun:heater"])

        let stepSpec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:air-conditioner:0000A004:test-step:1",
            services: [MiotService(iid: 2, type: "urn:miot-spec-v2:service:air-conditioner:0000780F:test-step:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:target-temperature:00000021:test:1", format: "float", access: ["read", "write"], valueRange: [16, 25, 0.4]),
                MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:test:1", format: "int32", access: ["read", "write"], valueRange: [-1e308, 1e308, .infinity]),
            ])]
        )
        if case .setProps(let writes) = try MiotCommandMapper.map(.setMiotProperty(entityId: "miot:1:2", piid: 1, value: .number(25)), spec: stepSpec) {
            #expect(abs((writes.first?.value.doubleValue ?? 0) - 24.8) < 1e-9)
        }
        for input in [Double.nan, .infinity, -.infinity, 50] {
            if case .setProps(let writes) = try MiotCommandMapper.map(.setMiotProperty(entityId: "miot:1:2", piid: 2, value: .number(input)), spec: stepSpec) {
                #expect(writes.first?.value.doubleValue?.isFinite == true)
            }
        }

        let ssecurity = "AQIDBAUGBwgJCgsMDQ4PEA=="
        let session = MiSession(userId: "42", cUserId: "c", ssecurity: ssecurity, serviceToken: "tok")
        let totalCalls = ScriptedTransport.Counter()
        let emptyTransport = ScriptedTransport { request in
            _ = totalCalls.increment()
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            var fields: [String: String] = [:]
            for pair in form.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            let signed = try MiCloudCrypto.signedNonce(ssecurity: ssecurity, nonce: fields["_nonce"] ?? "")
            return (200, [:], try MiCloudCrypto.encrypt(#"{"code":0,"message":"ok","result":[]}"#, signedNonce: signed))
        }
        let emptyClient = MiCloudClient(session: session, transport: emptyTransport)
        let now = Date(timeIntervalSince1970: 1_760_005_000)
        #expect(try await emptyClient.sensorHistory(did: "sensor.empty", temperatureKey: "2.1", humidityKey: nil, window: .last24Hours, now: now).isEmpty)
        let firstProbeCalls = totalCalls.increment() - 1
        #expect(try await emptyClient.sensorHistory(did: "sensor.empty", temperatureKey: "2.1", humidityKey: nil, window: .last24Hours, now: now.addingTimeInterval(30)).isEmpty)
        #expect(totalCalls.increment() - 2 == firstProbeCalls)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let energySuite = "test.audit.f30.\(UUID().uuidString)"
        let energyDefaults = try #require(UserDefaults(suiteName: energySuite))
        defer { energyDefaults.removePersistentDomain(forName: energySuite) }
        func date(_ day: Int, _ hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))! }
        func plug(_ kwh: Double) -> SmartDevice {
            SmartDevice(id: "plug1", name: "桌面插座", roomId: "study", roomName: "书房", model: "cuco.plug.v3", isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.plug1", isOn: true, energyKwh: kwh)))
        }
        let day1Session = EnergyHistory(defaults: energyDefaults, calendar: cal)
        day1Session.record(devices: [plug(10.0)], now: date(1, 22))
        day1Session.record(devices: [plug(10.0)], now: date(2, 8))
        let relaunched = EnergyHistory(defaults: energyDefaults, calendar: cal)
        relaunched.record(devices: [plug(11.5)], now: date(2, 12))
        #expect(abs(relaunched.dailyTotals(dayCount: 2, now: date(2, 12))[1].kwh - 1.5) < 1e-9)

        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let suiteHA = "test.audit.f30d.ha.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteHA)?.removePersistentDomain(forName: suiteHA) }
        UserDefaults(suiteName: suiteHA)?.set(HomeBackend.demo.rawValue, forKey: "home_backend")
        let storeHA = HomeStore(defaultsSuiteName: suiteHA, credentialVault: vault)
        storeHA.updateConnection(serverURL: "http://127.0.0.1:9", token: "")
        #expect(storeHA.homeBackend == .homeAssistant && storeHA.lgWebOSClient != nil)
        storeHA.switchBackend(.demo)

        #expect(CoverSubtype(haDeviceClass: nil, name: "阳台智能晾衣架") == .clothesAirer)
        #expect(CoverSubtype(haDeviceClass: nil, name: "Living Room Shade") == .curtain)
        #expect(CoverSubtype(haDeviceClass: nil, name: "Mystery Cover") == .windowOpener)
        #expect(AppURLParser.parse(URL(string: "menumijia://toggle/extra?device=dev_1")!) == nil)
        #expect(AppURLParser.parse(URL(string: "menumijia://temperature?device=dev_ac&celsius=2e1")!) == nil)
        #expect(AppURLParser.parse(URL(string: "menumijia://temperature?device=dev_ac&celsius=25.5")!) == .temperature(deviceId: "dev_ac", celsius: 25.5))

        let powerRule = AutomationRule(trigger: .powerConnected, action: .quickAction(.lightsOff))
        #expect(MacContextAutomation.events(for: powerRule, previous: MacContextSnapshot(powerSource: .unknown), current: MacContextSnapshot(powerSource: .ac), at: now).isEmpty)
        #expect(!MacContextAutomation.events(for: powerRule, previous: MacContextSnapshot(powerSource: .battery), current: MacContextSnapshot(powerSource: .ac), at: now).isEmpty)

        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "bath", name: "浴室")],
            devices: [HADeviceEntry(id: "dev_cover", area_id: "bath", name: "浴室窗帘")],
            entities: [
                HAEntityEntry(entity_id: "humidifier.bedroom", area_id: "bath", name: "加湿器"),
                HAEntityEntry(entity_id: "water_heater.bath", area_id: "bath", name: "热水器"),
                HAEntityEntry(entity_id: "cover.dup", device_id: "dev_cover", area_id: "bath", name: "窗帘"),
                HAEntityEntry(entity_id: "cover.dup", device_id: "dev_cover", area_id: "bath", name: "窗帘副本"),
            ],
            states: [
                "humidifier.bedroom": HAEntityState(entityId: "humidifier.bedroom", state: "unavailable", attributes: ["humidity": .number(55)]),
                "water_heater.bath": HAEntityState(entityId: "water_heater.bath", state: "unavailable", attributes: ["temperature": .number(45)]),
                "cover.dup": HAEntityState(entityId: "cover.dup", state: "open", attributes: ["device_class": .string("curtain"), "current_position": .number(100)]),
            ]
        )
        if case .humidifier(let hSpec) = home.devices.first(where: { $0.id == "humidifier.bedroom" })?.kind {
            #expect(hSpec.powerWritable && hSpec.targetHumidity == 55 && hSpec.humidityWritable)
        }
        #expect(home.devices.contains { $0.id == "dev_cover" })

        let c3Suite = "test.audit.c3.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: c3Suite)?.removePersistentDomain(forName: c3Suite) }
        let snapHome = SynthesizedHome(devices: home.devices, environmentReadings: [EnvironmentReading(id: "env1", label: "温湿度计", roomName: "浴室", temperature: 24.5, humidity: 58)])
        let c3Store = HomeStore(provider: MockHomeProvider(snapshot: snapHome), defaultsSuiteName: c3Suite, credentialVault: vault)
        try await c3Store.waitForTestSnapshot()
        let snap1 = c3Store.buildRaycastSnapshot(now: now)
        let snap2 = c3Store.buildRaycastSnapshot(now: now.addingTimeInterval(30))
        #expect(snap1 != snap2 && snap1.hasSameExportedContent(as: snap2))

        c3Store.setAIAssistantEnabled(true)
        c3Store.homeBackend = .xiaomiCloud
        c3Store.assistantConfig = AssistantConfig(baseURL: "http://127.0.0.1:9/v1", model: "local-test", apiKey: "")
        let jevGate = AsyncGate()
        let content = #"{"suggestions":[{"device":"d1","op":"power","value":false,"confidence":90}]}"#
        c3Store.assistantResolverOverride = ModelIntentResolver(
            config: c3Store.assistantConfig,
            transport: { req in
                await jevGate.enterAndWait()
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let jevTask = Task { await c3Store.requestProactiveJevSuggestions() }
        await jevGate.waitUntilEntered()
        c3Store.invalidateUndoContext()
        c3Store.assistantSuggestions = []
        await jevGate.release()
        await jevTask.value
        #expect(c3Store.assistantSuggestions.isEmpty && !c3Store.isProactiveRecommending)
    }
}
