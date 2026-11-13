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

        let mirrorCount = MiotSpecStore.defaultMirrorBaseURLs.count
        let indexCalls = ScriptedTransport.Counter()
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.contains("instances?status=released") {
                if indexCalls.increment() <= mirrorCount {
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
        #expect(indexCalls.increment() == mirrorCount + 2)
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
}
