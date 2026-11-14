import Foundation
import KeychainTestSupport
import Testing
@testable import MijiaCore

extension CoreReleaseAuditTests {
    // MARK: - F30g: HAHomeSnapshot Entity Removal on null new_state

    @Test("F30g: HAHomeSnapshot removes deleted entities when state_changed carries new_state: null")
    func haSnapshotRemovesEntityOnNullNewState() throws {
        var projection = HAHomeSnapshot()
        func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
            ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
        }
        _ = try projection.receive(reply(1, .array([])))
        _ = try projection.receive(reply(2, .array([])))
        _ = try projection.receive(reply(3, .array([
            .object(["entity_id": .string("light.keep")]),
            .object(["entity_id": .string("light.removed")]),
        ])))
        let initial = try #require(try projection.receive(reply(4, .array([
            .object(["entity_id": .string("light.keep"), "state": .string("on"), "attributes": .object(["friendly_name": .string("Keep")])]),
            .object(["entity_id": .string("light.removed"), "state": .string("on"), "attributes": .object(["friendly_name": .string("Removed")])]),
        ]))))
        #expect(Set(initial.devices.map(\.id)) == ["light.keep", "light.removed"])

        let updated = try #require(try projection.receive([
            "type": .string("event"),
            "event": .object([
                "event_type": .string("state_changed"),
                "data": .object([
                    "entity_id": .string("light.removed"),
                    "new_state": .null,
                ]),
            ]),
        ]))
        #expect(updated.devices.map(\.id) == ["light.keep"])
    }

    // MARK: - F30h: HAFacets, SafetyMonitor, MiotCommandMapper, MiCloudClient History Cache

    @Test("F30h: HAFacets nil unknown select, SafetyMonitor removed-device pruning, MiotCommandMapper step clamp, and MiCloudClient history route eviction")
    func f30hFixes() async throws {
        // 1) HAFacets: unknown select state produces nil value instead of masquerading as index 0.
        let hostDevice = SmartDevice(
            id: "fan.living",
            name: "风扇",
            roomId: "living",
            roomName: "客厅",
            model: "dmaker.fan",
            isOnline: true,
            kind: .fan(FanSpec(entityId: "fan.living", isOn: true))
        )
        let facets = HAFacetEngine.controls(
            entities: [HAEntityEntry(entity_id: "select.oscillation_mode", device_id: "dev1")],
            states: [
                "select.oscillation_mode": HAEntityState(
                    entityId: "select.oscillation_mode",
                    state: "none",
                    attributes: [
                        "friendly_name": .string("摇头角度"),
                        "options": .array([.string("30°"), .string("60°"), .string("90°")]),
                    ]
                )
            ],
            excluding: ["fan.living"],
            device: hostDevice
        )
        let selectFacet = try #require(facets.first)
        #expect(selectFacet.value == nil)

        // 2) SafetyMonitor: removing a high-draw plug prunes its active timer so re-adding starts fresh.
        let suite = "test.audit.f30h.safety.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var monitor = SafetyMonitor(defaults: defaults)
        let policy = SensorAlertPolicy(enabled: [:], onlyWhenAway: false, includesAway: false)
        let heater = SmartDevice(
            id: "heater",
            name: "取暖器",
            roomId: "study",
            roomName: "书房",
            model: "cuco.plug",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.heater", isOn: true, powerWatts: 1200))
        )
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0).isEmpty)
        #expect(monitor.evaluate(devices: [], favorites: [], sensorPolicy: policy, now: t0 + 10 * 60).isEmpty)
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0 + 40 * 60).isEmpty)
        // Only 10 minutes since re-appearing at t0+40m: must NOT fire a 45-minute alert at t0+50m.
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0 + 50 * 60).isEmpty)
        #expect(monitor.evaluate(devices: [heater], favorites: [], sensorPolicy: policy, now: t0 + 86 * 60).map(\.id) == ["longrun:heater"])

        // 3) MiotCommandMapper: step rounding that overshoots max is stepped back into [min, max].
        let stepSpec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:air-conditioner:0000A004:test-step:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:air-conditioner:0000780F:test-step:1",
                    properties: [
                        MiotProperty(
                            iid: 2,
                            type: "urn:miot-spec-v2:property:target-temperature:00000021:test-step:1",
                            format: "float",
                            access: ["read", "write"],
                            valueRange: [16, 25, 0.4]
                        )
                    ]
                )
            ]
        )
        let mapped = try MiotCommandMapper.map(
            .setMiotProperty(entityId: "miot:1:2", piid: 2, value: .number(25)),
            spec: stepSpec
        )
        guard case .setProps(let writes) = mapped,
              let coerced = writes.first?.value.doubleValue else {
            Issue.record("Expected numeric setProps")
            return
        }
        #expect(coerced <= 25.0)
        #expect(abs(coerced - 24.8) < 1e-9)

        let intStepSpec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:light:0000A001:test-intstep:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:light:00007802:test-intstep:1",
                    properties: [
                        MiotProperty(
                            iid: 3,
                            type: "urn:miot-spec-v2:property:brightness:0000000D:test-intstep:1",
                            format: "uint8",
                            access: ["read", "write"],
                            valueRange: [1, 99, 2]
                        )
                    ]
                )
            ]
        )
        let intMapped = try MiotCommandMapper.map(
            .setMiotProperty(entityId: "miot:1:2", piid: 3, value: .number(4)),
            spec: intStepSpec
        )
        if case .setProps(let intWrites) = intMapped {
            #expect(intWrites.first?.value.doubleValue == 5)
        } else {
            Issue.record("Expected integer step-snapped setProps")
        }

        // 4) MiCloudClient.sensorHistory: evicts stale cached route when empty and avoids querying it twice.
        let ssecurity = "AQIDBAUGBwgJCgsMDQ4PEA=="
        let session = MiSession(userId: "42", cUserId: "c", ssecurity: ssecurity, serviceToken: "tok")
        final class RouteCounter: @unchecked Sendable {
            private let lock = NSLock()
            var phase = 1
            var phase2Key21Count = 0

            func recordAndRespond(path: String, body: String) -> String {
                lock.withLock {
                    guard path == "/v2/user/statistics",
                          let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                          let key = obj["key"] as? String else {
                        return "[]"
                    }
                    if phase == 1 {
                        if key == "2.1" {
                            return #"[{"time":1760000000,"value":"[23.5]"}]"#
                        }
                        return "[]"
                    } else {
                        if key == "2.1" {
                            phase2Key21Count += 1
                            return "[]"
                        }
                        if key == "4c01" {
                            return #"[{"time":1760003600,"value":"[24.0]"}]"#
                        }
                        return "[]"
                    }
                }
            }
        }
        let routeCounter = RouteCounter()
        let transport = ScriptedTransport { request in
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            var fields: [String: String] = [:]
            for pair in form.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            let signed = try MiCloudCrypto.signedNonce(ssecurity: ssecurity, nonce: fields["_nonce"] ?? "")
            let plain = String(
                data: try MiCloudCrypto.decryptResponse(fields["data"] ?? "", signedNonce: signed),
                encoding: .utf8
            ) ?? ""
            let path = String((request.url?.path ?? "").dropFirst("/app".count))
            let result = routeCounter.recordAndRespond(path: path, body: plain)
            let reply = #"{"code":0,"message":"ok","result":"# + result + "}"
            return (200, [:], try MiCloudCrypto.encrypt(reply, signedNonce: signed))
        }
        let client = MiCloudClient(session: session, transport: transport)
        let now = Date(timeIntervalSince1970: 1_760_005_000)
        let firstSamples = try await client.sensorHistory(
            did: "sensor.1",
            temperatureKey: "2.1",
            humidityKey: nil,
            window: .last24Hours,
            now: now
        )
        #expect(firstSamples.count == 1)

        routeCounter.phase = 2
        let secondSamples = try await client.sensorHistory(
            did: "sensor.1",
            temperatureKey: "2.1",
            humidityKey: nil,
            window: .last24Hours,
            now: now
        )
        #expect(secondSamples.count == 1)
        #expect(routeCounter.phase2Key21Count == 1)

        // Sensors with no history at all enter short negative cooldown instead of firing ~16 probes every open.
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
        let emptyFirst = try await emptyClient.sensorHistory(
            did: "sensor.empty",
            temperatureKey: "2.1",
            humidityKey: nil,
            window: .last24Hours,
            now: now
        )
        #expect(emptyFirst.isEmpty)
        let firstProbeCalls = totalCalls.increment() - 1
        #expect(firstProbeCalls > 0)

        let emptySecond = try await emptyClient.sensorHistory(
            did: "sensor.empty",
            temperatureKey: "2.1",
            humidityKey: nil,
            window: .last24Hours,
            now: now.addingTimeInterval(30)
        )
        #expect(emptySecond.isEmpty)
        // Second call within 5-minute cooldown issues 0 network requests.
        #expect(totalCalls.increment() - 2 == firstProbeCalls)
    }

    // MARK: - P2, P3, P8, P9, Sec5 MacContext & C3 Raycast Dedup

    @Test("P2, P3, P8, P9, PR#103 #6 sibling, Sec5 & C3: Cross-platform parity, URL strictness, continuation room names, power transitions, and Raycast dedup")
    @MainActor
    func p2P3DuplicateCoverAndRaycastDedup() async throws {
        // P2: Explicit airer/shade names match Windows haCoverSubtype while unknown stays fail-closed .windowOpener.
        #expect(CoverSubtype(haDeviceClass: nil, name: "阳台智能晾衣架") == .clothesAirer)
        #expect(CoverSubtype(haDeviceClass: nil, name: "阳台晒衣机") == .clothesAirer)
        #expect(CoverSubtype(haDeviceClass: "airer", name: "Balcony") == .clothesAirer)
        #expect(CoverSubtype(haDeviceClass: nil, name: "Living Room Shade") == .curtain)
        #expect(CoverSubtype(haDeviceClass: nil, name: "Mystery Cover") == .windowOpener)

        // P8: Reject extra path segments and exponent notation in menumijia:// URLs.
        #expect(AppURLParser.parse(URL(string: "menumijia://toggle/extra?device=dev_1")!) == nil)
        #expect(AppURLParser.parse(URL(string: "menumijia:/toggle/extra?device=dev_1")!) == nil)
        #expect(AppURLParser.parse(URL(string: "menumijia://temperature?device=dev_ac&celsius=2e1")!) == nil)
        #expect(AppURLParser.parse(URL(string: "menumijia://temperature?device=dev_ac&celsius=25.5")!) == .temperature(deviceId: "dev_ac", celsius: 25.5))

        // P9: mergeRoomPage preserves continuation room names, and incomplete split metadata does not hide parent device.
        let mergedRooms = MiCloudClient.mergeRoomPage(
            .object([
                "info": .array([
                    .object([
                        "id": .string("h1"),
                        "roomlist": .array([
                            .object([
                                "id": .string("r2"),
                                "name": .string("次卧"),
                                "dids": .array([.string("d2")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            into: [MiRoom(id: "r1", name: "主卧", dids: ["d1"], homeId: "h1", homeName: "我的家")]
        )
        #expect(mergedRooms.first { $0.id == "r2" }?.name == "次卧")

        let parsedSplit = MiCloudClient.parseDeviceList(.object([
            "list": .array([
                .object([
                    "did": .string("child-without-siid"),
                    "model": .string("lemesh.switch.sw2f12"),
                    "extra": .object(["split": .object(["parentId": .string("parent-1")])]),
                ]),
            ]),
        ]))
        #expect(parsedSplit.first?.splitParentDid == nil)
        #expect(parsedSplit.first?.splitSiid == nil)

        // Sec5 MacContextAutomation: .unknown -> .ac or .ac -> .unknown on wake does not false-trigger power rules.
        let powerRule = AutomationRule(trigger: .powerConnected, action: .quickAction(.lightsOff))
        let disconnectRule = AutomationRule(trigger: .powerDisconnected, action: .quickAction(.lightsOff))
        let unknownSnap = MacContextSnapshot(powerSource: .unknown)
        let acSnap = MacContextSnapshot(powerSource: .ac)
        let batterySnap = MacContextSnapshot(powerSource: .battery)
        let evalTime = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(MacContextAutomation.events(for: powerRule, previous: unknownSnap, current: acSnap, at: evalTime).isEmpty)
        #expect(MacContextAutomation.events(for: disconnectRule, previous: acSnap, current: unknownSnap, at: evalTime).isEmpty)
        #expect(!MacContextAutomation.events(for: powerRule, previous: batterySnap, current: acSnap, at: evalTime).isEmpty)

        // P3 & PR #103 #6 sibling: HA humidifier falls back to `humidity` attribute and offline HA humidifier/water_heater preserve writable flags; duplicate cover registry entries do not trap.
        let areas = [HAAreaEntry(area_id: "bath", name: "浴室")]
        let devices = [HADeviceEntry(id: "dev_cover", area_id: "bath", name: "浴室窗帘")]
        let entities = [
            HAEntityEntry(entity_id: "humidifier.bedroom", area_id: "bath", name: "加湿器"),
            HAEntityEntry(entity_id: "water_heater.bath", area_id: "bath", name: "热水器"),
            HAEntityEntry(entity_id: "cover.dup", device_id: "dev_cover", area_id: "bath", name: "窗帘"),
            HAEntityEntry(entity_id: "cover.dup", device_id: "dev_cover", area_id: "bath", name: "窗帘副本"),
        ]
        let states: [String: HAEntityState] = [
            "humidifier.bedroom": HAEntityState(
                entityId: "humidifier.bedroom",
                state: "unavailable",
                attributes: ["humidity": .number(55)]
            ),
            "water_heater.bath": HAEntityState(
                entityId: "water_heater.bath",
                state: "unavailable",
                attributes: ["temperature": .number(45)]
            ),
            "cover.dup": HAEntityState(
                entityId: "cover.dup",
                state: "open",
                attributes: ["device_class": .string("curtain"), "current_position": .number(100)]
            ),
        ]
        let home = DeviceSynthesizer.synthesize(
            areas: areas,
            devices: devices,
            entities: entities,
            states: states
        )
        let hum = try #require(home.devices.first { $0.id == "humidifier.bedroom" })
        if case .humidifier(let spec) = hum.kind {
            #expect(spec.powerWritable == true)
            #expect(spec.targetHumidity == 55)
            #expect(spec.humidityWritable == true)
        } else {
            Issue.record("Expected humidifier card")
        }

        let heater = try #require(home.devices.first { $0.id == "water_heater.bath" })
        if case .appliance(let spec) = heater.kind {
            #expect(spec.powerWritable == true)
            #expect(spec.temperatureWritable == true)
        } else {
            Issue.record("Expected appliance card for water_heater")
        }
        #expect(home.devices.contains { $0.id == "dev_cover" })

        // C3: RaycastSnapshot.hasSameExportedContent ignores climate/environmentReadings updatedAt drift.
        let suite = "test.audit.c3.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let snapHome = SynthesizedHome(
            devices: home.devices,
            environmentReadings: [
                EnvironmentReading(id: "env1", label: "温湿度计", roomName: "浴室", temperature: 24.5, humidity: 58)
            ]
        )
        let provider = MockHomeProvider(snapshot: snapHome)
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        let t1 = Date(timeIntervalSince1970: 1_760_000_000)
        let t2 = t1.addingTimeInterval(30)
        let snap1 = store.buildRaycastSnapshot(now: t1)
        let snap2 = store.buildRaycastSnapshot(now: t2)
        #expect(!snap1.environmentReadings.isEmpty)
        #expect(snap1 != snap2)
        #expect(snap1.hasSameExportedContent(as: snap2))
    }

    // MARK: - Round 2 Review Regressions (#33)

    private actor SelectiveCommandProvider: HomeProvider {
        private let initialSnapshot: SynthesizedHome
        private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
        private var failingCommands: [DeviceCommand] = []
        private(set) var executedCommands: [DeviceCommand] = []

        init(snapshot: SynthesizedHome) {
            self.initialSnapshot = snapshot
        }

        func setFailingCommands(_ commands: [DeviceCommand]) {
            failingCommands = commands
        }

        nonisolated func events() -> AsyncStream<HomeProviderEvent> {
            AsyncStream { cont in
                Task { await self.attach(cont) }
            }
        }

        private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
            self.continuation = cont
            cont.yield(.statusChanged(.connected))
            cont.yield(.snapshotUpdated(initialSnapshot))
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

    @Test("Round2 #1a: Sibling manual writes roll back independently on partial or dual failure without dropping surviving locks")
    @MainActor
    func siblingManualAdjustmentsRollbackIndependently() async throws {
        func makeLamp(_ id: String, brightness: Int, kelvin: Int) -> SmartDevice {
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
                    maxKelvin: 6500
                ))
            )
        }
        let ac = SmartDevice(
            id: "ac",
            name: "书房空调",
            roomId: "study",
            roomName: "书房",
            model: "xiaomi.aircondition.mt0",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.ac",
                isOn: true,
                hvacMode: "cool",
                availableModes: ["off", "cool", "heat"],
                targetTemperature: 24
            ))
        )

        let provider = SelectiveCommandProvider(snapshot: SynthesizedHome(devices: [
            makeLamp("l1", brightness: 20, kelvin: 3000),
            makeLamp("l2", brightness: 25, kelvin: 3200),
            makeLamp("l3", brightness: 30, kelvin: 3500),
            ac,
        ]))
        let suite = "test.audit.r2.sibling.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()
        store.controlDebounceInterval = .zero

        // (i) First write fails, second write succeeds -> brightness rolls back to 20, kelvin stays 4500, lock stays active.
        await provider.setFailingCommands([
            .setLightBrightness(entityId: "light.l1", percent: 70),
        ])
        store.setLightBrightness("l1", percent: 70)
        let l1BrightnessTask = store.debounceTasks["l1.brightness"]
        store.setLightColorTemp("l1", kelvin: 4500)
        let l1ColorTask = store.debounceTasks["l1.colortemp"]
        await l1BrightnessTask?.value
        await l1ColorTask?.value

        if case .light(let spec1) = try #require(store.devices.first { $0.id == "l1" }).kind {
            #expect(spec1.brightnessPercent == 20)
            #expect(spec1.colorTempKelvin == 4500)
        } else {
            Issue.record("Expected light l1")
        }
        #expect(store.optimisticLockUntil["l1"] != nil)

        // (ii-a) First write succeeds, second write fails -> brightness stays 80, kelvin rolls back to 3200, lock stays active.
        await provider.setFailingCommands([
            .setLightColorTemp(entityId: "light.l2", kelvin: 5000),
        ])
        store.setLightBrightness("l2", percent: 80)
        let l2BrightnessTask = store.debounceTasks["l2.brightness"]
        store.setLightColorTemp("l2", kelvin: 5000)
        let l2ColorTask = store.debounceTasks["l2.colortemp"]
        await l2BrightnessTask?.value
        await l2ColorTask?.value

        if case .light(let spec2) = try #require(store.devices.first { $0.id == "l2" }).kind {
            #expect(spec2.brightnessPercent == 80)
            #expect(spec2.colorTempKelvin == 3200)
        } else {
            Issue.record("Expected light l2")
        }
        #expect(store.optimisticLockUntil["l2"] != nil)

        // (ii-b) Debouncing write1 + immediate failing non-debounced write2 -> write2 rolls back without dropping write1's lock.
        store.controlDebounceInterval = .milliseconds(90)
        await provider.setFailingCommands([
            .setClimateMode(entityId: "climate.ac", hvacMode: "heat"),
        ])
        store.stepClimateTemperature("ac", delta: 2)
        let acTempTask = store.debounceTasks["ac.temp"]
        store.setClimateMode("ac", mode: "heat")
        await waitUntil { store.toastNotice?.message.contains("书房空调") == true }
        if case .climate(let midAC) = try #require(store.devices.first { $0.id == "ac" }).kind {
            #expect(midAC.hvacMode == "cool")
            #expect(midAC.targetTemperature == 26)
        } else {
            Issue.record("Expected climate ac")
        }
        #expect(store.optimisticLockUntil["ac"] != nil, "pending debounced write1 must keep its optimistic lock")
        await acTempTask?.value
        if case .climate(let finalAC) = try #require(store.devices.first { $0.id == "ac" }).kind {
            #expect(finalAC.hvacMode == "cool")
            #expect(finalAC.targetTemperature == 26)
        }

        // (iii) Both writes fail -> card rolls all the way back to pre-session base and releases optimistic lock.
        store.controlDebounceInterval = .zero
        await provider.setFailingCommands([
            .setLightBrightness(entityId: "light.l3", percent: 75),
            .setLightColorTemp(entityId: "light.l3", kelvin: 5500),
        ])
        store.setLightBrightness("l3", percent: 75)
        let l3BrightnessTask = store.debounceTasks["l3.brightness"]
        store.setLightColorTemp("l3", kelvin: 5500)
        let l3ColorTask = store.debounceTasks["l3.colortemp"]
        await l3BrightnessTask?.value
        await l3ColorTask?.value

        if case .light(let spec3) = try #require(store.devices.first { $0.id == "l3" }).kind {
            #expect(spec3.brightnessPercent == 30)
            #expect(spec3.colorTempKelvin == 3500)
        } else {
            Issue.record("Expected light l3")
        }
        #expect(store.optimisticLockUntil["l3"] == nil)
    }

    @Test("Round2 #1b: Mutually exclusive manual controls cancel conflicting pending slider debounces")
    @MainActor
    func mutuallyExclusiveControlsCancelPendingDebounces() async throws {
        let lamp = SmartDevice(
            id: "lamp",
            name: "氛围灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.strip6",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.lamp",
                isOn: true,
                brightnessPercent: 60,
                colorTempKelvin: 3000,
                minKelvin: 2700,
                maxKelvin: 6500,
                currentEffect: "Day",
                availableEffects: ["Day", "Night"]
            ))
        )
        let fan = SmartDevice(
            id: "fan",
            name: "净化器",
            roomId: "living",
            roomName: "客厅",
            model: "zhimi.airpurifier.mb5",
            isOnline: true,
            kind: .fan(FanSpec(
                entityId: "fan.purifier",
                isOn: true,
                percentage: 35,
                presetMode: "Auto",
                availablePresetModes: ["Auto", "Sleep", "Favorite"]
            ))
        )
        let curtain = SmartDevice(
            id: "curtain",
            name: "客厅窗帘",
            roomId: "living",
            roomName: "客厅",
            model: "lumi.curtain.hagl04",
            isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "cover.curtain",
                subtype: .curtain,
                positionPercent: 20,
                positionWritable: true,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Pause"
            ))
        )

        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp, fan, curtain]))
        let suite = "test.audit.r2.mutex.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.controlDebounceInterval = .milliseconds(70)

        // 1) setLightEffect cancels pending colortemp debounce (but keeps unrelated brightness if any).
        store.setLightColorTemp("lamp", kelvin: 4800)
        let lampColorTask = try #require(store.debounceTasks["lamp.colortemp"])
        #expect(store.debouncedWrites["lamp.colortemp"] != nil)
        store.setLightEffect("lamp", effect: "Night")
        #expect(store.debouncedWrites["lamp.colortemp"] == nil)

        // 2) setFanPresetMode cancels pending fanpercent debounce.
        store.setFanPercentage("fan", percent: 85)
        let fanPercentTask = try #require(store.debounceTasks["fan.fanpercent"])
        #expect(store.debouncedWrites["fan.fanpercent"] != nil)
        store.setFanPresetMode("fan", preset: "Sleep")
        #expect(store.debouncedWrites["fan.fanpercent"] == nil)

        // 3) setCoverMotor("Pause") cancels pending cover position debounce.
        store.setCoverPosition("curtain", percent: 80)
        let coverPosTask = try #require(store.debounceTasks["curtain.cover"])
        #expect(store.debouncedWrites["curtain.cover"] != nil)
        store.setCoverMotor("curtain", description: "Pause")
        #expect(store.debouncedWrites["curtain.cover"] == nil)

        await lampColorTask.value
        await fanPercentTask.value
        await coverPosTask.value
        await waitUntil { await provider.executedCommands.count >= 3 }
        let cmds = await provider.executedCommands
        #expect(cmds.contains(.setLightEffect(entityId: "light.lamp", effect: "Night")))
        #expect(!cmds.contains(.setLightColorTemp(entityId: "light.lamp", kelvin: 4800)))
        #expect(cmds.contains(.setFanPresetMode(entityId: "fan.purifier", presetMode: "Sleep")))
        #expect(!cmds.contains(.setFanPercentage(entityId: "fan.purifier", percent: 85)))
        #expect(cmds.contains(.setSelectOption(entityId: "cover.curtain", option: "Pause")))
        #expect(!cmds.contains(.setNumberValue(entityId: "cover.curtain", value: 80)))

        if case .light(let lampSpec) = try #require(store.devices.first { $0.id == "lamp" }).kind {
            #expect(lampSpec.currentEffect == "Night")
            #expect(lampSpec.colorTempKelvin == 3000)
        }
        if case .fan(let fanSpec) = try #require(store.devices.first { $0.id == "fan" }).kind {
            #expect(fanSpec.presetMode == "Sleep")
            #expect(fanSpec.percentage == 35)
        }
        if case .cover(let coverSpec) = try #require(store.devices.first { $0.id == "curtain" }).kind {
            #expect(coverSpec.positionPercent == 20)
            #expect(coverSpec.motion == .stopped)
        }
    }

    @Test("Round2 #2: MiotCommandMapper.coerce guards non-finite valueRange/step and inputs so JSONSerialization never sees NaN/Inf")
    func miotCommandMapperGuardsNonFiniteNumbersAndSteps() throws {
        let nonFiniteSpec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:air-conditioner:0000A004:test-nonfinite:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:air-conditioner:0000780F:test-nonfinite:1",
                    properties: [
                        MiotProperty(
                            iid: 1,
                            type: "urn:miot-spec-v2:property:target-temperature:00000021:test-nonfinite:1",
                            format: "float",
                            access: ["read", "write"],
                            valueRange: [0, .infinity, .infinity]
                        ),
                        MiotProperty(
                            iid: 2,
                            type: "urn:miot-spec-v2:property:brightness:0000000D:test-nonfinite:1",
                            format: "int32",
                            access: ["read", "write"],
                            valueRange: [-1e308, 1e308, .infinity]
                        ),
                    ]
                )
            ]
        )

        let cases: [(piid: Int, input: Double)] = [
            (1, 24.5),
            (1, .nan),
            (1, .infinity),
            (2, 50),
            (2, -.infinity),
        ]
        for (piid, input) in cases {
            let op = try MiotCommandMapper.map(
                .setMiotProperty(entityId: "miot:1:2", piid: piid, value: .number(input)),
                spec: nonFiniteSpec
            )
            guard case .setProps(let writes) = op,
                  let write = writes.first,
                  let out = write.value.doubleValue else {
                Issue.record("Expected numeric setProps for piid=\(piid)")
                continue
            }
            #expect(out.isFinite)
            let payload = try JSONSerialization.data(withJSONObject: ["value": out])
            #expect(!payload.isEmpty)
        }
    }

    @Test("Round2 #3: DualSourceHomeProvider.shutdown awaits child MiCloudProvider bridge teardown before returning")
    func dualSourceShutdownAwaitsChildProviders() async throws {
        actor DelayedCameraBridge: XiaomiCameraBridging {
            private(set) var stopCompleted: [String] = []

            func startBridge(
                did: String,
                model: String,
                localIP: String,
                clientPublic: String,
                clientPrivate: String,
                devicePublic: String,
                sign: String,
                vendor: String,
                uid: String?,
                quality: XiaomiCameraStreamQuality,
                channel: Int,
                subdid: String?
            ) async throws -> XiaomiCameraStreamEndpoints {
                XiaomiCameraStreamEndpoints(
                    mp4: URL(string: "http://127.0.0.1:43123/api/stream.mp4?src=cam_\(did)")!,
                    mjpeg: URL(string: "http://127.0.0.1:43123/api/stream.mjpeg?src=cam_\(did)")!
                )
            }

            func stopBridge(did: String, subdid: String?) async {
                try? await Task.sleep(for: .milliseconds(50))
                stopCompleted.append(did)
            }
        }

        let camSpec = MiotFixtures.decode(#"""
        {"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:1","services":[
          {"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[
            {"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]}
          ]}
        ]}
        """#)
        let camRecord = MiDeviceRecord(
            did: "9902",
            name: "门口摄像机",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            localIp: "192.168.50.11"
        )
        let session = MiSession(userId: "42", cUserId: "c", ssecurity: "c2VjcmV0", serviceToken: "tok")
        let api = StubMiCloudAPI(
            devices: [camRecord],
            rooms: [MiRoom(id: "r1", name: "玄关", dids: ["9902"])],
            values: [MiotPropKey(did: "9902", siid: 2, piid: 1): .bool(true)]
        )
        struct SingleSpec: MiotSpecSource {
            let spec: MiotDeviceSpec
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? { spec }
        }
        let bridge = DelayedCameraBridge()
        let miProvider = MiCloudProvider(
            sessionLoader: { session },
            apiFactory: { _ in api },
            specSource: SingleSpec(spec: camSpec),
            cameraBridge: bridge,
            pollInterval: .seconds(60),
            followUpDelay: .seconds(60)
        )
        let dualProvider = DualSourceHomeProvider(homeAssistant: nil, xiaomiCloud: miProvider)
        let (log, task) = consume(dualProvider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let camDevice = try #require(await log.snapshots.first?.devices.first { $0.id == "9902" })
        _ = try await dualProvider.resolveCameraStream(for: camDevice)
        #expect(await bridge.stopCompleted.isEmpty)

        // Must await the 50ms stopBridge inside miProvider before returning.
        await dualProvider.shutdown()
        #expect(await bridge.stopCompleted == ["9902"])
    }
}
