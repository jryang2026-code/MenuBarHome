import Foundation
import KeychainTestSupport
import Testing
@testable import MijiaCore

@Suite("1.2.5 Core Release Audit Regressions")
struct CoreReleaseAuditTests {
    // MARK: - Helpers

    private actor AsyncGate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var enteredCount = 0

        func waitUntilEntered() async {
            if enteredCount > 0 { return }
            await withCheckedContinuation { cont in
                enteredContinuation = cont
            }
        }

        func enterAndWait() async {
            enteredCount += 1
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { cont in
                releaseContinuation = cont
            }
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
            await withCheckedContinuation { cont in
                continuation = cont
            }
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
        private var continuation: AsyncStream<HomeProviderEvent>.Continuation?

        init(snapshot: SynthesizedHome, gate: AsyncGate) {
            self.initialSnapshot = snapshot
            self.gate = gate
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

        init(outcomes: [HAWebSocketProvider.ConnectTestOutcome]) {
            self.scriptedOutcomes = outcomes
        }

        func nextOutcome() -> HAWebSocketProvider.ConnectTestOutcome {
            attempts += 1
            if !scriptedOutcomes.isEmpty {
                return scriptedOutcomes.removeFirst()
            }
            return .authenticatedStayConnected
        }

        func replaceOutcomes(_ outcomes: [HAWebSocketProvider.ConnectTestOutcome]) {
            scriptedOutcomes = outcomes
        }

        func recordSleep(_ duration: Duration) {
            sleeps.append(duration)
        }

        func recordSuggestion(_ instance: HADiscoveredInstance) {
            suggestions.append(instance)
        }
    }

    // MARK: - F1 & F2 & Section 5: HomeStore+ControlWrite

    @Test("F1: Sibling manual adjustments on one device keep pending debounced slider writes alive")
    @MainActor
    func siblingManualAdjustmentsKeepDebouncedSliderWrite() async throws {
        let lamp = SmartDevice(
            id: "lamp",
            name: "台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "light.lamp",
                isOn: true,
                brightnessPercent: 20,
                colorTempKelvin: 3000,
                minKelvin: 2700,
                maxKelvin: 6500
            ))
        )
        let ac = SmartDevice(
            id: "ac",
            name: "空调",
            roomId: "study",
            roomName: "书房",
            model: "xiaomi.aircondition.mt0",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.ac",
                isOn: true,
                hvacMode: "cool",
                availableModes: ["off", "cool", "heat"],
                targetTemperature: 26
            ))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp, ac]))
        let suite = "test.audit.f1.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.controlDebounceInterval = .zero

        // 1) Brightness + color-temp sliders dragged back-to-back on the same light.
        store.setLightBrightness("lamp", percent: 70)
        let brightnessTask = store.debounceTasks["lamp.brightness"]
        store.setLightColorTemp("lamp", kelvin: 4500)
        let colorTask = store.debounceTasks["lamp.colortemp"]
        await brightnessTask?.value
        await colorTask?.value

        let commandsAfterLight = await provider.executedCommands
        #expect(commandsAfterLight.contains(.setLightBrightness(entityId: "light.lamp", percent: 70)))
        #expect(commandsAfterLight.contains(.setLightColorTemp(entityId: "light.lamp", kelvin: 4500)))

        // 2) Temperature step followed by non-debounced HVAC mode button on the same climate card.
        store.stepClimateTemperature("ac", delta: -2.5)
        let tempTask = store.debounceTasks["ac.temp"]
        store.setClimateMode("ac", mode: "heat")
        await tempTask?.value
        let switchedToHeat = await EventLog().wait { _ in
            let cmds = await provider.executedCommands
            return cmds.contains(.setClimateMode(entityId: "climate.ac", hvacMode: "heat"))
        }
        #expect(switchedToHeat)
        let allCommands = await provider.executedCommands
        #expect(allCommands.contains(.setClimateTemperature(entityId: "climate.ac", temperature: 23.5)))
        #expect(allCommands.contains(.setClimateMode(entityId: "climate.ac", hvacMode: "heat")))
    }

    @Test("F1 safety: Powering off a device immediately cancels any pending debounced slider write")
    @MainActor
    func powerOffCancelsPendingDebouncedSliderWrite() async throws {
        let lamp = SmartDevice(
            id: "lamp",
            name: "台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 40))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp]))
        let suite = "test.audit.f1.off.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.controlDebounceInterval = .seconds(60)

        store.setLightBrightness("lamp", percent: 85)
        let pending = store.debounceTasks["lamp.brightness"]
        #expect(pending != nil)
        #expect(!store.debouncedWrites.isEmpty)

        if let toggleTask = store.togglePrimary(lamp) {
            _ = await toggleTask.value
        }
        await pending?.value

        #expect(store.debouncedWrites.isEmpty)
        #expect(await provider.executedCommands == [.setLightPower(entityId: "light.lamp", isOn: false)])
    }

    @Test("F2 & Sec5: Failed consecutive slider drags roll back to pre-drag origin and stale context suppresses failure toast")
    @MainActor
    func failedConsecutiveSliderDragsRestoreOriginAndStaleContextSuppressesToast() async throws {
        let lamp = SmartDevice(
            id: "lamp",
            name: "台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 20))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [lamp]))
        await provider.setShouldFail(true)
        let suite = "test.audit.f2.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()
        store.controlDebounceInterval = .zero

        store.setLightBrightness("lamp", percent: 50)
        store.setLightBrightness("lamp", percent: 80)
        await store.debounceTasks["lamp.brightness"]?.value

        guard case .light(let spec) = store.devices.first?.kind else {
            Issue.record("Expected light")
            return
        }
        #expect(spec.brightnessPercent == 20)
        #expect(store.debouncedWrites.isEmpty)
        #expect(store.toastNotice?.isError == true)

        // Section 5: Switching control context while a write is in flight suppresses stale failure toast.
        let gate = AsyncGate()
        let gatedProvider = GatedFailingProvider(snapshot: SynthesizedHome(devices: [lamp]), gate: gate)
        let suite2 = "test.audit.sec5.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite2)?.removePersistentDomain(forName: suite2) }
        let store2 = HomeStore(provider: gatedProvider, defaultsSuiteName: suite2)
        store2.toastAutoDismissInterval = nil
        try await store2.waitForTestSnapshot()

        let task = store2.togglePrimary(lamp)
        await gate.waitUntilEntered()
        store2.invalidateUndoContext()
        #expect(store2.toastNotice == nil)
        await gate.release()
        if let task {
            _ = await task.value
        }
        #expect(store2.toastNotice == nil)
    }

    // MARK: - F3: DeviceDeduplicator Canonical ID Uniqueness

    @Test("F3: Re-pairing an HA device while its former Mi partner stays online never emits duplicate canonical IDs")
    func deduplicatorNeverEmitsDuplicateCanonicalIDsOnRePairing() {
        let ha1 = SmartDevice(
            id: "light.desk",
            name: "书桌灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.desk", isOn: true))
        )
        let mi2 = SmartDevice(
            id: "1002",
            name: "书桌灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:1002:2", isOn: true))
        )
        var homeHA1 = SynthesizedHome(devices: [ha1])
        homeHA1.deviceIdentities = [
            "light.desk": DeviceSourceIdentity(
                dids: [],
                macAddresses: ["AA:BB:CC:DD:EE:02"],
                uniqueIds: ["uid-desk"],
                model: "yeelink.light.lamp4",
                name: "书桌灯",
                roomName: "书房",
                kindTag: .light
            )
        ]
        var homeMi1 = SynthesizedHome(devices: [mi2])
        homeMi1.deviceIdentities = [
            "1002": DeviceSourceIdentity(
                dids: ["1002"],
                macAddresses: ["AA:BB:CC:DD:EE:02"],
                uniqueIds: [],
                model: "yeelink.light.lamp4",
                name: "书桌灯",
                roomName: "书房",
                kindTag: .light
            )
        ]

        // Step 1: Prefer "1002" as canonical for the (light.desk, 1002) pair via knownPreferenceIDs.
        let initial = DeviceDeduplicator.merge(
            homeAssistant: homeHA1,
            xiaomiCloud: homeMi1,
            knownPreferenceIDs: ["1002"]
        )
        #expect(initial.home.devices.map(\.id) == ["1002"])

        // Step 2: light.desk now pairs with Mi device "1003" (MAC 03), while Mi device "1002" (MAC 02) stays online unpaired.
        let mi3 = SmartDevice(
            id: "1003",
            name: "新书桌灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "miot:1003:2", isOn: true))
        )
        var homeHA2 = SynthesizedHome(devices: [ha1])
        homeHA2.deviceIdentities = [
            "light.desk": DeviceSourceIdentity(
                dids: [],
                macAddresses: ["AA:BB:CC:DD:EE:03"],
                uniqueIds: ["uid-desk"],
                model: "yeelink.light.lamp4",
                name: "新书桌灯",
                roomName: "书房",
                kindTag: .light
            )
        ]
        var homeMi2 = SynthesizedHome(devices: [mi2, mi3])
        homeMi2.deviceIdentities = [
            "1002": DeviceSourceIdentity(
                dids: ["1002"],
                macAddresses: ["AA:BB:CC:DD:EE:02"],
                uniqueIds: [],
                model: "yeelink.light.lamp4",
                name: "旧书桌灯",
                roomName: "书房",
                kindTag: .light
            ),
            "1003": DeviceSourceIdentity(
                dids: ["1003"],
                macAddresses: ["AA:BB:CC:DD:EE:03"],
                uniqueIds: [],
                model: "yeelink.light.lamp4",
                name: "新书桌灯",
                roomName: "书房",
                kindTag: .light
            ),
        ]

        let repaired = DeviceDeduplicator.merge(
            homeAssistant: homeHA2,
            xiaomiCloud: homeMi2,
            canonical: initial.canonical,
            knownPreferenceIDs: ["1002"]
        )
        let ids = repaired.home.devices.map(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.contains("1002"))
        #expect(repaired.routes["1002"]?.sourceDeviceID == "1002")
    }

    // MARK: - F4 & F5 & PR #103 #1 sibling: HAWebSocketProvider

    @Test("F4, F5 & cover clamp: HAWebSocketProvider stops retrying on unauthorized, resets backoff after auth_ok, and safely clamps cover positions")
    func haWebSocketUnauthorizedStopAndBackoffResetAndCoverClamp() async throws {
        // PR #103 #1 sibling: non-finite / out-of-range cover position clamps without trapping.
        let nanMapped = HAWebSocketProvider.mapCommandToService(.setNumberValue(entityId: "cover.blinds", value: .nan))
        #expect(nanMapped.payload["position"] as? Int == 0)
        let hugeMapped = HAWebSocketProvider.mapCommandToService(.setNumberValue(entityId: "cover.blinds", value: 1e30))
        #expect(hugeMapped.payload["position"] as? Int == 100)

        // F4: Unauthorized halts reconnect loop instead of hammering Home Assistant every 10s.
        let unauthState = HAProbeState(outcomes: [.failedBeforeAuth(HomeProviderError.unauthorized)])
        let unauthProvider = HAWebSocketProvider(
            baseURLString: "http://192.168.1.10:8123",
            token: "revoked-token",
            rediscover: { _ in [] },
            allowsToken: { _ in true }
        )
        await unauthProvider.setTestSeams(
            connectOverride: { await unauthState.nextOutcome() },
            reconnectSleep: { duration in await unauthState.recordSleep(duration) }
        )
        let (unauthLog, unauthTask) = consume(unauthProvider)
        defer { unauthTask.cancel() }

        let sawDisconnected = await unauthLog.wait { log in
            await log.statuses.contains {
                if case .disconnected = $0 { return true }
                return false
            }
        }
        #expect(sawDisconnected)
        #expect(await unauthState.attempts == 1)
        #expect(await unauthState.sleeps.isEmpty)

        await unauthState.replaceOutcomes([.authenticatedStayConnected])
        await unauthProvider.updateCredentials(baseURLString: "http://192.168.1.10:8123", token: "fresh-token")
        let sawConnected = await unauthLog.wait { log in
            await log.statuses.contains(.connected)
        }
        #expect(sawConnected)
        #expect(await unauthState.attempts == 2)
        await unauthProvider.shutdown()

        // F5: auth_ok resets consecutiveFailures and backoffSeconds before post-auth drop.
        let otherInstance = HADiscoveredInstance(
            baseURL: "http://192.168.1.99:8123",
            locationName: "Other HA",
            version: nil,
            uuid: "uuid-other"
        )
        let backoffState = HAProbeState(outcomes: [
            .failedBeforeAuth(URLError(.cannotConnectToHost)),
            .authenticatedThenDisconnected(URLError(.networkConnectionLost)),
            .authenticatedStayConnected,
        ])
        let backoffProvider = HAWebSocketProvider(
            baseURLString: "http://192.168.1.10:8123",
            token: "valid-token",
            onAddressSuggestion: { candidate in
                Task { await backoffState.recordSuggestion(candidate) }
            },
            rediscover: { _ in [otherInstance] },
            allowsToken: { _ in true }
        )
        await backoffProvider.setTestSeams(
            connectOverride: { await backoffState.nextOutcome() },
            reconnectSleep: { duration in await backoffState.recordSleep(duration) }
        )
        let (backoffLog, backoffTask) = consume(backoffProvider)
        defer { backoffTask.cancel() }

        let settled = await backoffLog.wait { _ in
            await backoffState.attempts == 3
        }
        #expect(settled)
        #expect(await backoffState.sleeps == [.seconds(0.8), .seconds(0.8)])
        #expect(await backoffState.suggestions.isEmpty)
        await backoffProvider.shutdown()
    }

    // MARK: - F25 & F26: XiaomiCameraBridge

    @Test("F25 & F26: XiaomiCameraBridge coalesces concurrent go2rtc startup and releases UDP relays when startBridge fails")
    func cameraBridgeCoalescesStartupAndReleasesRelayOnFailure() async {
        let bridge = XiaomiCameraBridge()
        let gate = AsyncGate()
        let joined = AsyncSignal()
        await bridge.setEnsureRunningOverride(
            { await gate.enterAndWait() },
            onJoinedStartup: { await joined.signal() }
        )

        async let first: Void = {
            _ = try? await bridge.startBridge(
                did: "10001",
                model: "chuangmi.camera.061a01",
                localIP: "127.0.0.1",
                clientPublic: "aa",
                clientPrivate: "bb",
                devicePublic: "cc",
                sign: "dd",
                vendor: "cs2",
                uid: "TICK-1",
                quality: .sd,
                channel: 0,
                subdid: nil
            )
        }()
        await gate.waitUntilEntered()

        async let second: Void = {
            _ = try? await bridge.startBridge(
                did: "10002",
                model: "chuangmi.camera.061a01",
                localIP: "127.0.0.1",
                clientPublic: "aa",
                clientPrivate: "bb",
                devicePublic: "cc",
                sign: "dd",
                vendor: "cs2",
                uid: "TICK-2",
                quality: .sd,
                channel: 0,
                subdid: nil
            )
        }()

        await joined.wait()
        await gate.release()
        _ = await (first, second)

        #expect(await gate.enteredCount == 1)
        #expect(await bridge.activeRelayCount == 0)
    }

    // MARK: - F27: MiotSpecStore Corrupt Index Protection

    @Test("F27: MiotSpecStore rejects corrupt or empty instance index without poisoning disk or in-memory cache")
    func miotSpecStoreRejectsCorruptIndexWithoutPoisoningCache() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Pre-seed an empty/corrupt cache file on disk: loadTypeIndex must ignore it and fetch remotely.
        let indexFile = cacheDir.appendingPathComponent("miot-instances.json")
        try Data(#"{"instances":[]}"#.utf8).write(to: indexFile)

        let indexCalls = ScriptedTransport.Counter()
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.contains("instances?status=released") {
                if indexCalls.increment() == 1 {
                    return (200, [:], "<html>Captive Portal Login</html>")
                }
                return (
                    200,
                    [:],
                    #"{"instances":[{"model":"acme.light.test1","version":1,"type":"urn:miot-spec-v2:device:light:0000A001:acme-test1:1"}]}"#
                )
            }
            return (200, [:], MiotFixtures.ceiling22)
        }

        let store = MiotSpecStore(transport: transport, cacheDirectory: cacheDir)
        await #expect(throws: MiCloudError.self) {
            _ = try await store.spec(model: "acme.light.test1", specType: nil)
        }
        let diskAfterBadFetch = try String(contentsOf: indexFile, encoding: .utf8)
        #expect(!diskAfterBadFetch.contains("Captive Portal"))

        // Subsequent call retries cleanly instead of staying stuck on an empty memoized dictionary.
        let loaded = try await store.spec(model: "acme.light.test1", specType: nil)
        #expect(loaded != nil)
        #expect(indexCalls.increment() == 3)
    }

    // MARK: - F28: MiAccountLogin Empty Long-Poll Keepalive

    @Test("F28: MiAccountLogin.waitForScan treats empty HTTP 200 long-poll bodies as keepalives")
    func miAccountLoginSkipsEmptyLongPollKeepalive() async throws {
        let polls = ScriptedTransport.Counter()
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                let step = polls.increment()
                if step == 1 { return (200, [:], "") }
                if step == 2 { return (200, [:], "  \r\n ") }
                return (
                    200,
                    [:],
                    #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","passToken":"p","location":"https://sts.example/sts?x=1"}"#
                )
            }
            return (200, ["Set-Cookie": "serviceToken=tok-keepalive; path=/; domain=.example"], "ok")
        }
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example/1")!,
            loginURL: URL(string: "https://login.example/1")!,
            longPollURL: URL(string: "https://lp.example/1")!,
            timeout: 30
        )
        let session = try await MiAccountLogin(transport: transport, redirectlessTransport: transport).waitForScan(ticket)
        #expect(session.serviceToken == "tok-keepalive")
        #expect(polls.increment() == 4)
    }

    // MARK: - F29 & Section 5: MiCloudProvider Single-Device ReadBack & Shutdown

    @Test("F29 & Sec5: MiCloudProvider single-device readBack keeps awayGap open and shutdown stops active camera bridges")
    func miCloudSingleDeviceReadBackAndShutdownCleanup() async throws {
        let camSpec = MiotFixtures.decode(#"""
        {"type":"urn:miot-spec-v2:device:camera:0000A01C:chuangmi-061a01:1","services":[
          {"iid":2,"type":"urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-061a01:1","properties":[
            {"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:chuangmi-061a01:1","format":"bool","access":["read","write","notify"]}
          ]}
        ]}
        """#)
        let camRecord = MiDeviceRecord(
            did: "9901",
            name: "客厅摄像机",
            model: "chuangmi.camera.061a01",
            isOnline: true,
            localIp: "192.168.50.10"
        )
        let session = MiSession(userId: "42", cUserId: "c", ssecurity: "c2VjcmV0", serviceToken: "tok")
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord, camRecord],
            rooms: [MiRoom(id: "r1", name: "客厅", dids: ["123", "9901"])],
            values: MiotFixtures.lightValues.merging([MiotPropKey(did: "9901", siid: 2, piid: 1): .bool(true)]) { a, _ in a }
        )
        let specs = MiotFixtures.specs.merging(["chuangmi.camera.061a01": camSpec]) { a, _ in a }
        struct CombinedSpecs: MiotSpecSource {
            let map: [String: MiotDeviceSpec]
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? { map[model] }
        }
        let bridge = StubXiaomiCameraBridge()
        let provider = MiCloudProvider(
            sessionLoader: { session },
            apiFactory: { _ in api },
            specSource: CombinedSpecs(map: specs),
            cameraBridge: bridge,
            pollInterval: .seconds(60),
            followUpDelay: .seconds(60)
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let initial = try #require(await log.snapshots.first)
        #expect(initial.closesAwayGap == true)

        // Single-device readBack after execute must NOT close the away gap for unpolled devices.
        try await provider.execute(.setLightPower(entityId: "miot:123:2", isOn: false))
        let rb = await provider.readBack(deviceId: "123")
        #expect(rb == .published)
        #expect(await log.wait { await $0.snapshots.count >= 2 })
        let afterWrite = try #require(await log.snapshots.last)
        #expect(afterWrite.closesAwayGap == false)

        // Active camera bridge is torn down on shutdown().
        let camDevice = try #require(initial.devices.first { $0.id == "9901" })
        _ = try await provider.resolveCameraStream(for: camDevice)
        #expect(await bridge.stopCalls.isEmpty)
        await provider.shutdown()
        #expect(await bridge.stopCalls == ["9901"])
    }

    // MARK: - F30: EnergyHistory Persists New-Day Observation Timestamp

    @Test("F30: EnergyHistory persists new-day lastSampleAt even when cumulative kWh is unchanged")
    @MainActor
    func energyHistoryPersistsNewDayObservationTimestamp() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let suite = "test.audit.f30.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        func date(_ day: Int, _ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
        }
        func plug(_ kwh: Double) -> SmartDevice {
            SmartDevice(
                id: "plug1",
                name: "桌面插座",
                roomId: "study",
                roomName: "书房",
                model: "cuco.plug.v3",
                isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.plug1", isOn: true, energyKwh: kwh))
            )
        }

        let day1Session = EnergyHistory(defaults: defaults, calendar: cal)
        day1Session.record(devices: [plug(10.0)], now: date(1, 22))
        // Next morning: counter is still 10.0 (zero overnight draw), then the app quits and relaunches.
        day1Session.record(devices: [plug(10.0)], now: date(2, 8))

        let relaunched = EnergyHistory(defaults: defaults, calendar: cal)
        let observedBeforeDraw = relaunched.dailyTotals(dayCount: 2, now: date(2, 9))
        #expect(observedBeforeDraw.map(\.isObserved) == [true, true])

        // Later on Day 2 the plug consumes 1.5 kWh: because Day 2's 08:00 timestamp survived relaunch,
        // the delta is recognized as same-day consumption rather than a multi-day gap.
        relaunched.record(devices: [plug(11.5)], now: date(2, 12))
        let totals = relaunched.dailyTotals(dayCount: 2, now: date(2, 12))
        #expect(abs(totals[1].kwh - 1.5) < 1e-9)
    }

    // MARK: - F30d: Leaving Demo Mode Resumes/Creates LG WebOS Client

    @Test("F30d: Leaving demo mode via updateConnection or completeMiLogin creates LGWebOSClient")
    @MainActor
    func leavingDemoViaHAConnectionOrMiLoginCreatesLGClient() {
        let vaultStorage = MemoryVaultStorage()
        let vault = CredentialVault(storage: vaultStorage.storage)

        // 1) Leaving .demo via Home Assistant updateConnection
        let suiteHA = "test.audit.f30d.ha.\(UUID().uuidString)"
        let udHA = UserDefaults(suiteName: suiteHA)!
        defer { udHA.removePersistentDomain(forName: suiteHA) }
        udHA.set(HomeBackend.demo.rawValue, forKey: "home_backend")

        let storeHA = HomeStore(defaultsSuiteName: suiteHA, credentialVault: vault)
        #expect(storeHA.homeBackend == .demo)
        #expect(storeHA.lgWebOSClient == nil)
        storeHA.updateConnection(serverURL: "http://127.0.0.1:9", token: "")
        #expect(storeHA.homeBackend == .homeAssistant)
        #expect(storeHA.lgWebOSClient != nil)
        storeHA.switchBackend(.demo)

        // 2) Leaving .demo via Xiaomi Cloud completeMiLogin
        let suiteMi = "test.audit.f30d.mi.\(UUID().uuidString)"
        let udMi = UserDefaults(suiteName: suiteMi)!
        defer { udMi.removePersistentDomain(forName: suiteMi) }
        udMi.set(HomeBackend.demo.rawValue, forKey: "home_backend")

        let storeMi = HomeStore(defaultsSuiteName: suiteMi, credentialVault: vault)
        #expect(storeMi.homeBackend == .demo)
        #expect(storeMi.lgWebOSClient == nil)
        storeMi.completeMiLogin(MiSession(userId: "42", cUserId: "c", ssecurity: "c2VjcmV0", serviceToken: "tok"))
        #expect(storeMi.homeBackend == .xiaomiCloud)
        #expect(storeMi.lgWebOSClient != nil)
        storeMi.switchBackend(.demo)
    }

    // MARK: - F30e: requestProactiveJevSuggestions Guards Control Context

    @Test("F30e: requestProactiveJevSuggestions discards recommendations after control context invalidation")
    @MainActor
    func proactiveJevSuggestionsDiscardStaleContext() async throws {
        let ceiling = SmartDevice(
            id: "dev_ceiling",
            name: "客厅吸顶灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.ceiling20",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80))
        )
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: [ceiling]))
        let suite = "test.audit.f30e.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let vaultStorage = MemoryVaultStorage()
        let store = HomeStore(
            provider: provider,
            defaultsSuiteName: suite,
            credentialVault: CredentialVault(storage: vaultStorage.storage)
        )
        try await store.waitForTestSnapshot()
        store.homeBackend = .xiaomiCloud
        store.assistantConfig = AssistantConfig(baseURL: "http://127.0.0.1:9/v1", model: "local-test", apiKey: "")

        let gate = AsyncGate()
        let content = #"{"suggestions":[{"device":"d1","op":"power","value":false,"confidence":90}]}"#
        store.assistantResolverOverride = ModelIntentResolver(
            config: store.assistantConfig,
            transport: { req in
                await gate.enterAndWait()
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )

        let task = Task { await store.requestProactiveJevSuggestions() }
        await gate.waitUntilEntered()
        store.invalidateUndoContext()
        store.assistantSuggestions = []
        await gate.release()
        await task.value

        #expect(store.assistantSuggestions.isEmpty)
        #expect(store.isProactiveRecommending == false)
        #expect(store.assistantState == .idle)
    }

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
