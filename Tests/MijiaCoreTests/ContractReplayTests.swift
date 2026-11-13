import Foundation
import Testing
@testable import MijiaCore

/// Replays sanitised recordings of the external payloads the app parses (#186).
///
/// Each fixture keeps the value types and envelope shape of the live response, with
/// identifiers, names and addresses replaced. When Xiaomi or Home Assistant changes a
/// field the app depends on, these assertions fail before a user reports a bug.
struct ContractReplayTests {
    private static func fixture(_ relativePath: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Linux copies test sources into scripts/linux-check/.work; fixtures stay at the repo root.
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Tests/Fixtures/contracts/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func decode(_ relativePath: String) throws -> JSONValue {
        let data = try fixture(relativePath)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let root) = value,
              case .object(let meta)? = root["_fixture"],
              meta["sanitised"]?.stringValue?.isEmpty == false else {
            throw ContractReplayError.missingFixtureMetadata(relativePath)
        }
        return value
    }

    private enum ContractReplayError: Error {
        case missingFixtureMetadata(String)
    }

    // MARK: - Mi cloud

    @Test("Device list page keeps the fields synthesis reads")
    func deviceListPage() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_device_list_page.json"))
        let records = MiCloudClient.parseDeviceList(result)

        // The record without a model is skipped instead of surfacing an unusable card.
        #expect(records == [
            MiDeviceRecord(
                did: "did-light-0001",
                name: "Contract Ceiling Light",
                model: "yeelink.light.ceiling22",
                isOnline: true,
                specType: "urn:miot-spec-v2:device:light:0000A001:yeelink-ceiling22:2",
                localIp: "192.0.2.10",
                mac: "02:00:00:00:00:01"
            ),
            MiDeviceRecord(
                did: "did-switch-0002.s2",
                name: "Contract Downlight",
                model: "lemesh.switch.sw2f12",
                isOnline: false,
                splitParentDid: "did-switch-0002",
                splitSiid: 2
            ),
            MiDeviceRecord(
                did: "did-camera-0003",
                name: "Contract Camera",
                model: "chuangmi.camera.81ac1",
                isOnline: true,
                localIp: "192.0.2.11",
                mac: "02:00:00:00:00:03"
            ),
        ])
        let split = try #require(records.first { $0.splitParentDid != nil })
        #expect(split.miotDid == "did-switch-0002")
        #expect(result["next_start_did"]?.stringValue == "")
        #expect(result["has_more"]?.boolValue == false)
    }

    @Test("Shared homes and their rooms survive the merge response")
    func sharedHomesAndRooms() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_home_rooms_merged.json"))
        let rooms = MiCloudClient.parseRooms(result)

        #expect(rooms == [
            MiRoom(id: "room-2001", name: "Living Room", dids: ["did-light-0001"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "room-2002", name: "Study", dids: ["did-camera-0003"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "home_home-1001", name: "", dids: ["did-light-0001", "did-switch-0002"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "room-2003", name: "Kitchen", dids: [], homeId: "home-1002", homeName: "Contract Beach House"),
            MiRoom(id: "room-2004", name: "Guest Room", dids: ["did-switch-0002.s2"], homeId: "home-1003", homeName: "Contract Shared Home", isSharedHome: true),
        ])
        // The same home id in share_home_list is an attachment, not a second home.
        #expect(!rooms.contains { $0.id == "room-9999" })
        #expect(MiCloudProvider.homeOptions(from: rooms) == [
            HomeOption(id: "home-1001", name: "Contract Home", deviceCount: 3),
            HomeOption(id: "home-1002", name: "Contract Beach House", deviceCount: 0),
            HomeOption(id: "home-1003", name: "Contract Shared Home", deviceCount: 1, isSharedHome: true),
        ])

        let page = try MiCloudClient.unwrapResult(Self.decode("mi_dev_room_page.json"))
        let merged = MiCloudClient.mergeRoomPage(page, into: rooms)
        #expect(merged == [
            MiRoom(id: "room-2001", name: "Living Room", dids: ["did-light-0001", "did-plug-0004"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "room-2002", name: "Study", dids: ["did-camera-0003", "did-fan-0006"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "home_home-1001", name: "", dids: ["did-light-0001", "did-switch-0002", "did-sensor-0005"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "room-2003", name: "Kitchen", dids: ["did-fridge-0008"], homeId: "home-1002", homeName: "Contract Beach House"),
            MiRoom(id: "room-2004", name: "Guest Room", dids: ["did-switch-0002.s2"], homeId: "home-1003", homeName: "Contract Shared Home", isSharedHome: true),
            MiRoom(id: "home_home-1002", name: "", dids: ["did-kettle-0007"], homeId: "home-1002", homeName: "Contract Beach House"),
        ])
    }

    @Test("Light-group status keeps the member dids and tolerates both membership spellings")
    func lightGroupStatus() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_group_query_status.json"))
        let members = MiCloudClient.parseLightGroupMembers(result)

        #expect(Set(members.keys) == ["group.1000001", "group.1000002"])
        #expect(members["group.1000001"]?.sorted() == ["did-light-0001", "did-light-0002"])
        #expect(members["group.1000002"] == ["did-light-0003"])
    }

    @Test("Property results keep values and drop per-property failures")
    func propertyValues() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_props_get.json"))
        let values = MiCloudClient.parsePropValues(result)

        #expect(values == [
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 1): .bool(true),
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 2): .number(80),
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 3): .number(4000),
            MiotPropKey(did: "did-camera-0003", siid: 2, piid: 1): .string("off"),
        ])
    }

    @Test("Numeric ids outside Int64 range are skipped instead of trapping")
    func hostileNumericIDs() {
        let result: JSONValue = .object(["list": .array([
            .object(["did": .number(1e308), "model": .string("contract.ghost")]),
            .object(["did": .number(42), "model": .string("contract.numeric")]),
            .object(["did": .string("did-light-0001"), "model": .string("contract.light")]),
        ])])
        #expect(MiCloudClient.parseDeviceList(result).map(\.did) == ["42", "did-light-0001"])

        // Int.min brightness delta uses unsigned `.magnitude` instead of trapping in `abs(Int.min)`.
        let reply = IntentReply.describe(
            [DeviceIntent(targetId: "did-light-0001", operation: .brightnessStep(Int.min))],
            devices: [],
            scenes: []
        )
        #expect(reply.contains(String(Int.min.magnitude)))
    }

    // MARK: - MIoT spec

    @Test("MIoT instance JSON keeps services, properties, ranges, value lists and action inputs")
    func miotSpec() throws {
        let data = try Self.fixture("miot_spec_light.json")
        let spec = try JSONDecoder().decode(MiotDeviceSpec.self, from: data)

        #expect(spec.shortName == "light")
        #expect(spec.description == "Light")
        let service = try #require(spec.service(iid: 2))
        #expect(service.shortName == "light")

        let on = try #require(service.property(named: "on"))
        #expect(on.format == "bool")
        #expect(on.isReadable && on.isWritable)
        #expect(on.rangeMin == nil && on.valueList == nil)

        let brightness = try #require(service.property(named: "brightness"))
        #expect(brightness.isIntegerFormat)
        #expect(brightness.unit == "percentage")
        #expect(brightness.rangeMin == 1)
        #expect(brightness.rangeMax == 100)
        #expect(brightness.rangeStep == 1)

        let colorTemperature = try #require(service.property(named: "color-temperature"))
        #expect(colorTemperature.rangeMin == 2700)
        #expect(colorTemperature.rangeMax == 6500)

        let mode = try #require(service.property(named: "mode"))
        #expect(mode.valueList?.map(\.value) == [0, 1])
        #expect(mode.description(forValue: 1) == "Sleep")
        #expect(mode.description(forValue: 42) == nil)

        #expect(service.action(named: "toggle")?.inputProperties == [])
        #expect(service.action(named: "set-brightness")?.inputProperties == [2])
    }

    @Test("MIoT instance index keeps the highest released version per model")
    func miotInstanceIndex() throws {
        let index = MiotSpecStore.parseInstanceIndex(try Self.fixture("miot_instance_index.json"))
        #expect(index == [
            "contract.light.ceiling": "urn:miot-spec-v2:device:light:0000A001:contract-light:3",
            "contract.plug.v1": "urn:miot-spec-v2:device:outlet:0000A002:contract-plug:2",
        ])
    }

    // MARK: - Home Assistant WebSocket

    @Test("HA WebSocket message sequence yields stable device fields")
    func homeAssistantMessages() throws {
        let document = try Self.decode("ha_websocket_messages.json")
        guard case .object(let root) = document,
              case .array(let messages)? = root["messages"] else {
            Issue.record("fixture is missing its messages array")
            return
        }

        var snapshot = HAHomeSnapshot()
        var homes: [SynthesizedHome] = []
        for message in messages {
            guard case .object(let object) = message else {
                Issue.record("fixture message is not an object")
                continue
            }
            if let home = try snapshot.receive(object) {
                homes.append(home)
            }
        }

        // Initial registries, the state_changed event, and the 1001 refresh each publish once.
        #expect(homes.count == 3)
        let initial = try #require(homes.first)
        #expect(initial.devices.map(\.id).sorted() == ["dev-light-01", "dev-thermo-02"])

        let light = try #require(initial.devices.first { $0.id == "dev-light-01" })
        #expect(light.name == "Contract Ceiling Light")
        #expect(light.roomName == "Living Room")
        guard case .light(let lightSpec) = light.kind else {
            Issue.record("expected a light")
            return
        }
        #expect(lightSpec.entityId == "light.ceiling")
        #expect(lightSpec.isOn)
        #expect(lightSpec.brightnessPercent == 50)
        #expect(lightSpec.availableEffects == ["Reading"])

        let thermometer = try #require(initial.devices.first { $0.id == "dev-thermo-02" })
        #expect(thermometer.roomName == "Study")
        guard case .sensor(let sensorSpec) = thermometer.kind else {
            Issue.record("expected a sensor")
            return
        }
        #expect(sensorSpec.temperature == 23.5)
        #expect(sensorSpec.humidity == 45)
        #expect(sensorSpec.battery == 87)

        // Hidden entities never synthesize a card.
        #expect(!initial.devices.contains { $0.id == "dev-hidden-03" })

        let afterEvent = try #require(homes.dropFirst().first)
        let lightAfterEvent = try #require(afterEvent.devices.first { $0.id == "dev-light-01" })
        guard case .light(let offSpec) = lightAfterEvent.kind else {
            Issue.record("expected a light after state_changed")
            return
        }
        #expect(!offSpec.isOn)

        let refreshed = try #require(homes.last)
        let lightRefreshed = try #require(refreshed.devices.first { $0.id == "dev-light-01" })
        guard case .light(let refreshedSpec) = lightRefreshed.kind else {
            Issue.record("expected a light after refresh")
            return
        }
        #expect(refreshedSpec.isOn)
        #expect(refreshedSpec.brightnessPercent == 100)
    }

    // MARK: - Local miIO UDP

    @Test("miIO get_properties keeps code-0 values, fills default did, and drops all-nonzero or null items")
    func miioPropValues() throws {
        let doc = try Self.decode("miio_get_properties.json")
        let mixedResult = try #require(doc["mixedReply"]?["result"])
        let mixed = LocalMiIOClient.parsePropValues(mixedResult, defaultDid: "did-light-0001")
        #expect(mixed == [
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 1): .bool(true),
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 2): .number(80),
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 3): .number(4200),
        ])

        let allNonzeroResult = try #require(doc["allNonzeroLockReply"]?["result"])
        #expect(LocalMiIOClient.parsePropValues(allNonzeroResult, defaultDid: "did-lock-0001").isEmpty)

        // Explicit non-integer code (outside Int) or code=0 with null value must also be ignored.
        let malformed: JSONValue = .array([
            .object(["did": .string("did-lock-0001"), "siid": .number(2), "piid": .number(1), "value": .number(1), "code": .number(1e308)]),
            .object(["did": .string("did-lock-0001"), "siid": .number(3), "piid": .number(1), "value": .null, "code": .number(0)]),
        ])
        #expect(LocalMiIOClient.parsePropValues(malformed, defaultDid: "did-lock-0001").isEmpty)
    }

    @Test("Empty LAN miIO reply replayed with failed cloud fallback clears cached door-state")
    func emptyLanReplyClearsStaleLockStateOnCloudFailure() async throws {
        let doc = try Self.decode("miio_get_properties.json")
        let mixedResult = try #require(doc["mixedReply"]?["result"])
        let allNonzeroLockResult = try #require(doc["allNonzeroLockReply"]?["result"])
        let tokenHex = "00112233445566778899aabbccddeeff"
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))

        try await Self.verifyLockClearedOnEmptyLanReply(
            includeCompanionLight: true,
            mixedLightResult: mixedResult,
            allNonzeroLockResult: allNonzeroLockResult,
            tokenHex: tokenHex,
            tokenData: tokenData
        )
        try await Self.verifyLockClearedOnEmptyLanReply(
            includeCompanionLight: false,
            mixedLightResult: mixedResult,
            allNonzeroLockResult: allNonzeroLockResult,
            tokenHex: tokenHex,
            tokenData: tokenData
        )
    }

    private static func verifyLockClearedOnEmptyLanReply(
        includeCompanionLight: Bool,
        mixedLightResult: JSONValue,
        allNonzeroLockResult: JSONValue,
        tokenHex: String,
        tokenData: Data
    ) async throws {
        let replayFailure = ReplayFlagBox(false)
        let udpTransport = ReplayMiIOUDPTransport { packet, host, _ in
            if packet == MiIOPacket.helloPacket {
                let deviceId: UInt32 = host == "192.0.2.21" ? 0x2222_0001 : 0x2222_0002
                return replayHelloPacket(deviceId: deviceId, stamp: 10)
            }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reqId = req["id"]?.intValue ?? 0
            let result: JSONValue
            if host == "192.0.2.21" {
                result = mixedLightResult
            } else if replayFailure.withValue({ $0 }) {
                result = allNonzeroLockResult
            } else {
                result = .array([
                    .object(["did": .string("did-lock-0001"), "siid": .number(2), "piid": .number(1), "value": .number(1), "code": .number(0)]),
                    .object(["did": .string("did-lock-0001"), "siid": .number(3), "piid": .number(1), "value": .number(85), "code": .number(0)]),
                ])
            }
            let envelope: JSONValue = .object(["id": .number(Double(reqId)), "result": result])
            return try MiIOPacket.encode(
                deviceId: header.deviceId,
                stamp: header.stamp,
                token: tokenData,
                payload: Data(envelope.compactJSONString.utf8)
            )
        }

        let lockRecord = MiDeviceRecord(
            did: "did-lock-0001",
            name: "Contract Front Lock",
            model: "xiaomi.lock.contract",
            isOnline: true,
            localIp: "192.0.2.20",
            token: tokenHex,
            isShared: false
        )
        let lightRecord = MiDeviceRecord(
            did: "did-light-0001",
            name: "Contract Ceiling Light",
            model: "yeelink.light.contract",
            isOnline: true,
            localIp: "192.0.2.21",
            token: tokenHex,
            isShared: false
        )
        let devices = includeCompanionLight ? [lockRecord, lightRecord] : [lockRecord]
        let roomDids = devices.map(\.did)
        let api = ReplayMockCloudAPI(
            devices: devices,
            rooms: [MiRoom(id: "room-contract", name: "Entry", dids: roomDids)]
        )
        let specs = [
            "xiaomi.lock.contract": lockSpecForReplay(),
            "yeelink.light.contract": lightSpecForReplay(),
        ]
        let session = MiSession(
            userId: "10001",
            cUserId: "c1",
            ssecurity: Data(repeating: 0x01, count: 16).base64EncodedString(),
            serviceToken: "tok",
            region: "cn"
        )
        let provider = MiCloudProvider(
            sessionLoader: { session },
            apiFactory: { _ in api },
            specSource: ReplaySpecSource(specs: specs),
            localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0),
            pollInterval: .seconds(3600),
            closedPollInterval: .seconds(3600),
            selectedHomeLoader: { nil }
        )

        let collector = ReplayEventCollector()
        let stream = provider.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
            await collector.finish()
        }
        defer { task.cancel() }

        #expect(await collector.wait { $0.statuses.last == .connected && !$0.snapshots.isEmpty })
        let initialLock = await collector.snapshots.last?.devices.first { $0.id == "did-lock-0001" }
        guard case .sensor(let initialSensor) = initialLock?.kind else {
            Issue.record("expected initial lock sensor card")
            await provider.shutdown()
            return
        }
        #expect(initialSensor.statusText == L10n.tr("已上锁", "Locked"))

        // Poll 2: LAN replies with all-nonzero fixture codes for did-lock-0001, then cloud fallback returns 503.
        replayFailure.withValue { $0 = true }
        await api.setGetPropsError(MiCloudError.http(503))
        await provider.refreshNow()

        let expectedSnapshotCount = await collector.snapshots.count + 1
        #expect(await collector.wait { state in
            guard state.snapshots.count >= expectedSnapshotCount,
                  let lastStatus = state.statuses.last,
                  case .disconnected = lastStatus else { return false }
            return true
        })

        let partialSnapshot = await collector.snapshots.last
        #expect(partialSnapshot?.closesAwayGap == false)
        let partialLock = partialSnapshot?.devices.first { $0.id == "did-lock-0001" }
        guard case .sensor(let clearedSensor) = partialLock?.kind else {
            Issue.record("expected lock sensor card after empty LAN reply")
            await provider.shutdown()
            return
        }
        #expect(clearedSensor.statusText == L10n.tr("锁状态未知", "Lock status unknown"))
        if includeCompanionLight {
            let light = partialSnapshot?.devices.first { $0.id == "did-light-0001" }
            #expect(light?.isActiveOn == true)
        }

        await provider.shutdown()
    }

    private static func lockSpecForReplay() -> MiotDeviceSpec {
        MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:lock:0000A038:contract:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:lock:00007855:contract:1",
                    properties: [
                        MiotProperty(
                            iid: 1,
                            type: "urn:miot-spec-v2:property:door-state:00000001:contract:1",
                            format: "uint8",
                            access: ["read", "notify"],
                            valueList: [
                                MiotValueListItem(value: 1, description: "Locked"),
                                MiotValueListItem(value: 2, description: "Unlocked"),
                            ]
                        ),
                    ]
                ),
                MiotService(
                    iid: 3,
                    type: "urn:miot-spec-v2:service:battery:00007805:contract:1",
                    properties: [
                        MiotProperty(
                            iid: 1,
                            type: "urn:miot-spec-v2:property:battery-level:00000014:contract:1",
                            format: "uint8",
                            access: ["read"]
                        ),
                    ]
                ),
            ]
        )
    }

    private static func lightSpecForReplay() -> MiotDeviceSpec {
        MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:light:0000A001:contract:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:light:00007802:contract:1",
                    properties: [
                        MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:contract:1", format: "bool", access: ["read", "write", "notify"]),
                        MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:contract:1", format: "uint8", access: ["read", "write", "notify"], valueRange: [1, 100, 1]),
                        MiotProperty(iid: 3, type: "urn:miot-spec-v2:property:color-temperature:0000000F:contract:1", format: "uint32", access: ["read", "write", "notify"], valueRange: [2700, 6500, 1]),
                    ]
                ),
            ]
        )
    }
}

private func replayHelloPacket(deviceId: UInt32, stamp: UInt32) -> Data {
    var packet = Data([0x21, 0x31, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00])
    var didBE = deviceId.bigEndian
    var stampBE = stamp.bigEndian
    packet.append(Data(bytes: &didBE, count: 4))
    packet.append(Data(bytes: &stampBE, count: 4))
    packet.append(Data(repeating: 0xFF, count: 16))
    return packet
}

private final class ReplayFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ flag: Bool) { self.flag = flag }

    func withValue<T>(_ body: (inout Bool) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&flag)
    }
}

private actor ReplayMiIOUDPTransport: MiIOUDPTransport {
    private let handler: @Sendable (Data, String, UInt16) async throws -> Data

    init(handler: @escaping @Sendable (Data, String, UInt16) async throws -> Data) {
        self.handler = handler
    }

    func send(_ packet: Data, to host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await handler(packet, host, port)
    }
}

private actor ReplayMockCloudAPI: MiCloudAPI {
    private let devicesList: [MiDeviceRecord]
    private let roomsList: [MiRoom]
    private var getPropsError: (any Error)?

    init(devices: [MiDeviceRecord], rooms: [MiRoom]) {
        self.devicesList = devices
        self.roomsList = rooms
    }

    func setGetPropsError(_ error: (any Error)?) {
        getPropsError = error
    }

    func deviceList() async throws -> [MiDeviceRecord] { devicesList }
    func homeRooms() async throws -> [MiRoom] { roomsList }

    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        if let getPropsError {
            throw getPropsError
        }
        return [:]
    }

    func setProps(_ writes: [MiotPropWrite]) async throws {}
    func action(_ call: MiotActionCall) async throws {}
}

private struct ReplaySpecSource: MiotSpecSource {
    let specs: [String: MiotDeviceSpec]
    func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
        specs[model]
    }
}

private actor ReplayEventCollector {
    struct State: Sendable {
        var snapshots: [SynthesizedHome] = []
        var statuses: [ConnectionStatus] = []
        var isFinished = false
    }

    private struct Waiter {
        let id: UUID
        let predicate: @Sendable (State) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var state = State()
    private var waiters: [Waiter] = []

    var snapshots: [SynthesizedHome] { state.snapshots }
    var statuses: [ConnectionStatus] { state.statuses }

    func append(_ event: HomeProviderEvent) {
        switch event {
        case .snapshotUpdated(let home):
            state.snapshots.append(home)
        case .statusChanged(let status):
            state.statuses.append(status)
        case .doorbellRang, .sessionExpired, .sourceStatusesChanged:
            break
        }
        resolveWaiters()
    }

    func finish() {
        state.isFinished = true
        resolveWaiters()
        let remaining = waiters
        waiters.removeAll()
        for waiter in remaining {
            waiter.continuation.resume(returning: waiter.predicate(state))
        }
    }

    func wait(until predicate: @escaping @Sendable (State) -> Bool) async -> Bool {
        if predicate(state) { return true }
        if state.isFinished { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if predicate(state) {
                    continuation.resume(returning: true)
                    return
                }
                if state.isFinished {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func resolveWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(state) {
                waiter.continuation.resume(returning: true)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(returning: false)
    }
}
