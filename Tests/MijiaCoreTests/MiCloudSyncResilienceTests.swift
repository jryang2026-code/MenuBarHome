import Foundation
import Testing
@testable import MijiaCore

/// #76 / #67: an account whose devices live in a home the unfiltered list leaves out used to show
/// "connected, nothing to display". These tests pin the parts that make that state either resolve or
/// surface as the error it is: how a response body is classified, how the room and device endpoints
/// page, and what the provider reports when the room list fails.
struct MiCloudSyncResilienceTests {
    // MARK: - Response classification

    @Test("A body without a code is classified by its HTTP status and by its own message")
    func responseClassification() {
        // Every case here is plain JSON, which `decodeResponse` classifies before it ever decrypts.
        func decode(_ json: String, _ status: Int) throws -> JSONValue {
            try MiCloudClient.decodeResponse(Data(json.utf8), statusCode: status, signedNonce: "")
        }

        // 200 with no `code`: a gateway page or an unknown envelope, never a success payload.
        #expect(throws: MiCloudError.badResponse("缺少状态码")) {
            try decode(#"{"result":{"list":[]}}"#, 200)
        }
        // A 5xx keeps its status instead of turning into "synced, no devices".
        #expect(throws: MiCloudError.http(502)) {
            try decode(#"{"error":"Bad Gateway"}"#, 502)
        }
        // The same shape, but the message names a rejected session.
        #expect(throws: MiCloudError.sessionExpired) {
            try decode(#"{"message":"invalid_token"}"#, 200)
        }
        #expect(throws: MiCloudError.sessionExpired) {
            try decode(#"{"desc":"Unauthorized"}"#, 200)
        }
        // A coded error carries the server's code even when the status is a 4xx.
        #expect(throws: MiCloudError.api(code: -8, message: "bad")) {
            try decode(#"{"code":-8,"message":"bad"}"#, 400)
        }
        // `code: 0` without the encrypted body is not a payload this client can use.
        #expect(throws: MiCloudError.http(500)) {
            try decode(#"{"code":0}"#, 500)
        }
    }

    // MARK: - Room page

    @Test("homeRooms sends app_ver 9 and merges max_id pages without repeating a did")
    func homeRoomsPaging() async throws {
        let log = RequestLog()
        let transport = cloudTransport { path, data in
            log.append(path, data)
            switch path {
            case "/v2/homeroom/gethome_merged":
                return #"{"homelist":[{"id":"h1","name":"我的家","dids":["1"],"roomlist":[{"id":"r1","name":"客厅","dids":["1","2"]}]}],"has_more":true,"max_id":"50"}"#
            case "/v2/homeroom/get_dev_room_page":
                return #"{"info":[{"id":"h1","dids":["2","3"],"roomlist":[{"id":"r1","dids":["3","4"]}]}]}"#
            default:
                throw UnexpectedPath(path)
            }
        }
        let rooms = try await MiCloudClient(session: Self.session, transport: transport).homeRooms()

        #expect(log.paths == ["/v2/homeroom/gethome_merged", "/v2/homeroom/get_dev_room_page"])
        #expect(try jsonObject(log.data[0])["app_ver"] as? Int == 9)
        #expect(try jsonObject(log.data[1])["start_id"] as? String == "50")
        // Home dids and room dids both grow, and neither keeps a repeat.
        #expect(rooms.first { $0.id == "home_h1" }?.dids == ["1", "2", "3"])
        #expect(rooms.first { $0.id == "r1" }?.dids == ["1", "2", "3", "4"])
    }

    // MARK: - Device endpoints

    @Test("deviceList asks for third-party devices; homeDevices pages by (home id, owner uid)")
    func deviceAndHomePaging() async throws {
        let log = RequestLog()
        let transport = cloudTransport { path, data in
            log.append(path, data)
            switch path {
            case "/v2/home/device_list_page":
                return #"{"list":[{"did":"1","name":"灯","model":"yeelink.light.ceiling22","isOnline":true}]}"#
            case "/v2/home/home_device_list":
                let page = try jsonObject(data)
                return page["start_did"] == nil
                    ? #"{"device_info":[{"did":"7","name":"卧室灯","model":"yeelink.light.ceiling22","isOnline":true}],"has_more":true,"max_did":"7"}"#
                    : #"{"device_info":[{"did":"8","name":"客厅灯","model":"yeelink.light.ceiling22","isOnline":true}]}"#
            default:
                throw UnexpectedPath(path)
            }
        }
        let client = MiCloudClient(session: Self.session, transport: transport)

        let listed = try await client.deviceList()
        #expect(listed.map(\.did) == ["1"])
        let listPage = try jsonObject(log.data[0])
        #expect(listPage["get_third_device"] as? Bool == true)

        let home = try await client.homeDevices(homeId: "1234567", ownerUid: "2000000001")
        #expect(home.map(\.did) == ["7", "8"])
        // Safe ids travel as numbers, exactly as the Mi Home app sends them.
        let firstHomePage = try jsonObject(log.data[1])
        #expect(firstHomePage["home_id"] as? Int == 1234567)
        #expect(firstHomePage["home_owner"] as? Int == 2000000001)
        #expect(try jsonObject(log.data[2])["start_did"] as? String == "7")

        // An id too large or negative (including Int64.min) stays a string without trapping.
        _ = try await client.homeDevices(homeId: "9000000000000001", ownerUid: String(Int64.min))
        #expect(try jsonObject(log.data[3])["home_id"] as? String == "9000000000000001")
        #expect(try jsonObject(log.data[3])["home_owner"] as? String == String(Int64.min))
    }

    // MARK: - Room-less shared home

    @Test("A room-less shared home resolves its devices through homeDevices(homeId:ownerUid:)")
    func roomlessSharedHome() async throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"share_home_list":[{"id":"h2","name":"爸妈家","uid":"999","roomlist":[],"dids":[]}]}
        """#.utf8))
        let rooms = MiCloudClient.parseRooms(json)
        // Nothing to attach devices to yet, but the owner uid is enough for the per-home lookup.
        #expect(rooms == [MiRoom(id: "home_h2", name: "", dids: [], homeId: "h2", homeName: "爸妈家",
                                isSharedHome: true, ownerUid: "999")])

        let api = ResilienceAPI(rooms: rooms, records: [])
        await api.setPerHome(["h2": [MiDeviceRecord(did: "7", name: "卧室灯", model: "yeelink.light.ceiling22", isOnline: true)]])
        let outcome = try await MiCloudDiscovery.devices(api, rooms: rooms, retryUnresolved: true)

        let calls = await api.homeDeviceCalls
        #expect(calls.map { "\($0.homeId)/\($0.ownerUid)" } == ["h2/999"])
        #expect(outcome.devices.map(\.did) == ["7"])
        // The did joins the home, so selecting 爸妈家 still shows the device.
        #expect(outcome.rooms.first { $0.id == "home_h2" }?.dids == ["7"])

        // If the per-home lookup itself fails and no other devices exist, surface the error rather
        // than reporting an empty home as connected.
        let failingApi = ResilienceAPI(rooms: rooms, records: [], homeDevicesError: .http(502))
        await #expect(throws: MiCloudError.http(502)) {
            _ = try await MiCloudDiscovery.devices(failingApi, rooms: rooms, retryUnresolved: true)
        }
    }

    // MARK: - What the provider reports

    @Test("A failed room list with an empty device list surfaces as disconnected, not connected-and-empty")
    func brokenRoomsSurfaces() async throws {
        let api = ResilienceAPI(rooms: [], records: [], roomsError: .http(500))
        let provider = Self.provider(api)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let surfaced = await log.wait { log in
            await log.statuses.contains { status in
                if case .disconnected = status { return true }
                return false
            }
        }
        #expect(surfaced)
        let statuses = await log.statuses
        #expect(!statuses.contains(.connected))
        #expect(await log.snapshots.isEmpty)
        await provider.shutdown()
    }

    @Test("A failed room list still connects when the device list has devices, and puts them in 全屋")
    func brokenRoomsStillConnects() async throws {
        let api = ResilienceAPI(
            rooms: [],
            records: [MiotFixtures.lightRecord],
            roomsError: .http(500),
            values: MiotFixtures.lightValues
        )
        let provider = Self.provider(api)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { log in await !log.snapshots.isEmpty })
        let snapshot = await log.snapshots.first
        #expect(snapshot?.devices.first?.roomName == "全屋")
        #expect(await log.statuses.last == .connected)
        await provider.shutdown()
    }

    // MARK: - Diagnostics and store

    @Test("The empty-panel home hint counts only the other homes")
    @MainActor
    func otherHomesCount() async throws {
        let suite = "test.micloud.resilience.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome()), defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        store.homes = [
            HomeOption(id: "acc/h1", name: "我的家", deviceCount: 0),
            HomeOption(id: "acc/h2", name: "爸妈家", deviceCount: 3, isSharedHome: true),
        ]
        store.devices = []
        store.hasReceivedInitialSnapshot = true
        // Every home: the hint has nothing to offer, so it stays out of the way.
        store.selectedMiHomeId = nil
        #expect(store.otherMiHomesDeviceCountWhenSelectedEmpty == nil)

        store.selectedMiHomeId = "acc/h1"
        #expect(store.otherMiHomesDeviceCountWhenSelectedEmpty == 3)

        // A home that does show devices is not the state the hint is for.
        store.devices = [MiotFixtures.expectedLight]
        #expect(store.otherMiHomesDeviceCountWhenSelectedEmpty == nil)
    }

    @Test("The report names the home count, the shared ones and the filter, in both Chinese tables")
    func diagnosticsHomeLine() {
        let input = DiagnosticsReportBuilder.Input(
            appVersion: "1.0.6",
            buildNumber: "42",
            macOSVersion: "Version 14.5.0 (Build 23F79)",
            backendTitle: "Xiaomi Cloud",
            miCloudRegion: "cn",
            deviceCount: 0,
            onlineDeviceCount: 0,
            hiddenDeviceCount: 0,
            models: [],
            miHomeCount: 2,
            miSharedHomeCount: 1,
            isMiHomeFiltered: true
        )
        L10n.$overrideTranslationDirectory.withValue(LocalizationTests.shippedTablesDirectory) {
            L10n.$overrideLanguage.withValue(.zhHans) {
                let report = DiagnosticsReportBuilder.markdown(input) 
                #expect(report.contains("- 米家家庭: 2 (共享 1) · 已筛选单个家庭"))
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                let report = DiagnosticsReportBuilder.markdown(input)
                #expect(report.contains("- 米家家庭: 2 (共享 1) · 已篩選單一家庭"))
            }
        }
    }

    // MARK: - Fixtures

    fileprivate static let sessionSsecurity = Data(repeating: 7, count: 16).base64EncodedString()

    private static let session = MiSession(
        userId: "42", cUserId: "c", ssecurity: sessionSsecurity, serviceToken: "tok"
    )

    private static func provider(_ api: ResilienceAPI) -> MiCloudProvider {
        MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            closedPollInterval: .seconds(60),
            deviceRefreshEveryPolls: 1000,
            followUpDelay: .milliseconds(10),
            selectedHomeLoader: { nil }
        )
    }
}

/// The path a stubbed request reached that the test does not answer.
private struct UnexpectedPath: Error {
    let path: String
    init(_ path: String) { self.path = path }
}

/// Enough of `MiCloudAPI` to steer discovery: which half fails, and which home answers.
private actor ResilienceAPI: MiCloudAPI {
    private let rooms: [MiRoom]
    private let records: [MiDeviceRecord]
    private let values: [MiotPropKey: JSONValue]
    private let roomsError: MiCloudError?
    private let homeDevicesError: MiCloudError?
    private var perHome: [String: [MiDeviceRecord]] = [:]
    private(set) var homeDeviceCalls: [(homeId: String, ownerUid: String)] = []

    init(
        rooms: [MiRoom],
        records: [MiDeviceRecord],
        roomsError: MiCloudError? = nil,
        homeDevicesError: MiCloudError? = nil,
        values: [MiotPropKey: JSONValue] = [:]
    ) {
        self.rooms = rooms
        self.records = records
        self.roomsError = roomsError
        self.homeDevicesError = homeDevicesError
        self.values = values
    }

    func setPerHome(_ devices: [String: [MiDeviceRecord]]) { perHome = devices }

    func homeRooms() async throws -> [MiRoom] {
        if let roomsError { throw roomsError }
        return rooms
    }

    func deviceList() async throws -> [MiDeviceRecord] { records }

    func devices(dids: [String]) async throws -> [MiDeviceRecord] { [] }

    func homeDevices(homeId: String, ownerUid: String) async throws -> [MiDeviceRecord] {
        homeDeviceCalls.append((homeId, ownerUid))
        if let homeDevicesError { throw homeDevicesError }
        return perHome[homeId] ?? []
    }

    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        values.filter { keys.contains($0.key) }
    }

    func setProps(_ writes: [MiotPropWrite]) async throws {}

    func action(_ call: MiotActionCall) async throws {}
}

// MARK: - Request helpers

/// The (path, decrypted body) of every call, in order.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(path: String, data: String)] = []

    func append(_ path: String, _ data: String) { lock.withLock { entries.append((path, data)) } }

    var paths: [String] { lock.withLock { entries.map(\.path) } }
    var data: [String] { lock.withLock { entries.map(\.data) } }
}

/// Answers each call with a signed, RC4-encrypted `{"code":0,"result":…}` envelope, and hands the
/// handler the decrypted path and body. `handler` returns the `result` payload.
private func cloudTransport(
    _ handler: @escaping @Sendable (String, String) throws -> String
) -> ScriptedTransport {
    ScriptedTransport { request in
        let fields = try formFields(request)
        let signed = try MiCloudCrypto.signedNonce(
            ssecurity: MiCloudSyncResilienceTests.sessionSsecurity,
            nonce: fields["_nonce"] ?? ""
        )
        let plain = String(
            data: try MiCloudCrypto.decryptResponse(fields["data"] ?? "", signedNonce: signed),
            encoding: .utf8
        ) ?? ""
        let path = String((request.url?.path ?? "").dropFirst("/app".count))
        let result = try handler(path, plain)
        let reply = #"{"code":0,"message":"ok","result":"# + result + "}"
        return (200, [:], try MiCloudCrypto.encrypt(reply, signedNonce: signed))
    }
}

private func formFields(_ request: URLRequest) throws -> [String: String] {
    let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    var fields: [String: String] = [:]
    for pair in form.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        if kv.count == 2 { fields[kv[0]] = kv[1] }
    }
    return fields
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return object
}
