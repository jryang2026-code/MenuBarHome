import Foundation
import os

// MARK: - Cloud Records

public struct MiDeviceRecord: Equatable, Sendable {
    public var did: String
    public var name: String
    public var model: String
    public var isOnline: Bool
    public var specType: String?
    /// Set on a split key of a multi-key panel (did like `<parent>.s2`): MIoT reads and writes
    /// go to the parent did, limited to the switch service `splitSiid`.
    public var splitParentDid: String?
    public var splitSiid: Int?
    public var localIp: String?
    public var mac: String?

    public init(did: String, name: String, model: String, isOnline: Bool, specType: String? = nil,
                splitParentDid: String? = nil, splitSiid: Int? = nil, localIp: String? = nil,
                mac: String? = nil) {
        self.did = did
        self.name = name
        self.model = model
        self.isOnline = isOnline
        self.specType = specType
        self.splitParentDid = splitParentDid
        self.splitSiid = splitSiid
        self.localIp = localIp
        self.mac = mac
    }

    /// The did MIoT property and action calls address.
    public var miotDid: String { splitParentDid ?? did }
}

public struct MiRoom: Equatable, Sendable {
    public var id: String
    public var name: String
    public var dids: [String]
    public var homeId: String
    public var homeName: String
    public var isSharedHome: Bool
    /// The uid that owns this home. A home shared with this account belongs to another uid, and
    /// `v2/home/home_device_list` only answers for the pair (home id, owner uid) (#76, #67).
    public var ownerUid: String?

    public init(
        id: String,
        name: String,
        dids: [String],
        homeId: String = "",
        homeName: String = "",
        isSharedHome: Bool = false,
        ownerUid: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dids = dids
        self.homeId = homeId
        self.homeName = homeName
        self.isSharedHome = isSharedHome
        self.ownerUid = ownerUid
    }
}

public struct MiotPropKey: Hashable, Sendable {
    public var did: String
    public var siid: Int
    public var piid: Int

    public init(did: String, siid: Int, piid: Int) {
        self.did = did
        self.siid = siid
        self.piid = piid
    }
}

public struct MiotPropWrite: Equatable, Sendable {
    public var did: String
    public var siid: Int
    public var piid: Int
    public var value: JSONValue

    public init(did: String, siid: Int, piid: Int, value: JSONValue) {
        self.did = did
        self.siid = siid
        self.piid = piid
        self.value = value
    }
}

public struct MiotActionCall: Equatable, Sendable {
    public var did: String
    public var siid: Int
    public var aiid: Int
    public var inputs: [JSONValue]

    public init(did: String, siid: Int, aiid: Int, inputs: [JSONValue] = []) {
        self.did = did
        self.siid = siid
        self.aiid = aiid
        self.inputs = inputs
    }
}

public struct MiCameraP2PVendor: Equatable, Sendable {
    public var vendorName: String
    public var p2pId: String?
    public var devicePublicKey: String
    public var sign: String

    public init(vendorName: String, p2pId: String? = nil, devicePublicKey: String, sign: String) {
        self.vendorName = vendorName
        self.p2pId = p2pId
        self.devicePublicKey = devicePublicKey
        self.sign = sign
    }
}

public enum MiCloudError: LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case sessionExpired
    case http(Int)
    /// A cloud-envelope error. The code is the server wrapper's code, not a device verdict.
    case api(code: Int, message: String)
    /// A per-item MIoT result from a write. Negative codes are device or gateway errors.
    case deviceError(code: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return L10n.tr("请在设置中扫码登录米家账号", "Scan QR code in Settings to sign in to Xiaomi Home")
        case .sessionExpired: return L10n.tr("米家登录已过期，请重新扫码", "Xiaomi Home session expired; please scan again")
        case .http(429): return L10n.tr("米家云提示请求太频繁，已放慢刷新，稍后自动重试", "Xiaomi Cloud is rate limiting; refreshing less often and retrying later")
        case .http(let code): return L10n.tr("米家云服务 HTTP \(code)", "Xiaomi Cloud HTTP \(code)")
        case .api(let code, let message), .deviceError(let code, let message):
            return L10n.tr("米家云指令失败 (\(code))：\(message)", "Xiaomi Cloud command failed (\(code)): \(message)")
        case .badResponse(let what): return L10n.tr("米家云响应异常：\(what)", "Invalid Xiaomi Cloud response: \(what)")
        }
    }
}

// MARK: - API Seam

public protocol MiCloudAPI: Sendable {
    func deviceList() async throws -> [MiDeviceRecord]
    func homeRooms() async throws -> [MiRoom]
    /// Looks up specific devices by did, including those in homes shared with this account.
    func devices(dids: [String]) async throws -> [MiDeviceRecord]
    /// Every device of one Mi Home, addressed by the pair (home id, owner uid). The unfiltered
    /// device list leaves out homes shared with this account, and `devices(dids:)` can only find a
    /// did the home list already named (#76, #67).
    func homeDevices(homeId: String, ownerUid: String) async throws -> [MiDeviceRecord]
    /// Maps each `group.*` did among `groupDids` to its member device dids.
    func lightGroupMembers(groupDids: [String]) async throws -> [String: [String]]
    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue]
    func setProps(_ writes: [MiotPropWrite]) async throws
    func action(_ call: MiotActionCall) async throws
    func callAction(_ call: MiotActionCall) async throws -> JSONValue
    func sensorHistory(
        did: String,
        temperatureKey: String?,
        humidityKey: String?,
        window: SensorHistoryWindow,
        now: Date
    ) async throws -> [SensorHistorySample]
    func cameraLocalIP(did: String) async throws -> String?
    func cameraP2PVendor(did: String, appPublicKey: String) async throws -> MiCameraP2PVendor
}

extension MiCloudAPI {
    public func devices(dids: [String]) async throws -> [MiDeviceRecord] { [] }
    /// Mocks and older conformances have no per-home lookup; the provider degrades to the did list.
    public func homeDevices(homeId: String, ownerUid: String) async throws -> [MiDeviceRecord] { [] }
    public func lightGroupMembers(groupDids: [String]) async throws -> [String: [String]] { [:] }
    public func callAction(_ call: MiotActionCall) async throws -> JSONValue {
        try await action(call)
        return .null
    }
    public func sensorHistory(
        did: String,
        temperatureKey: String?,
        humidityKey: String?,
        window: SensorHistoryWindow,
        now: Date
    ) async throws -> [SensorHistorySample] {
        []
    }
    public func cameraLocalIP(did: String) async throws -> String? {
        nil
    }
    public func cameraP2PVendor(did: String, appPublicKey: String) async throws -> MiCameraP2PVendor {
        MiCameraP2PVendor(vendorName: "cs2", p2pId: nil, devicePublicKey: "", sign: "")
    }
}

// MARK: - Live Client

/// Numeric bounds for the ids this client sends as JSON numbers.
public enum MiIdLimits {
    /// Above this, a Mi id is sent as a string. The Mi Home app itself switches at this bound, and a
    /// larger value loses precision as a JSON number.
    public static let maxNumericId: Int64 = 9_000_000_000_000_000
}

public actor MiCloudClient: MiCloudAPI {
    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "MiCloud")
    private let session: MiSession
    private let transport: any MiHTTPTransport
    private let userAgent: String
    public static let propChunkSize = 100
    private static let emptyHistoryCooldown: TimeInterval = 300
    private var resolvedHistoryRouteByMetric: [String: HistoryRoute] = [:]
    private var emptyHistoryRetryAfterByMetric: [String: Date] = [:]

    private struct HistoryRoute: Equatable, Sendable {
        enum Endpoint: Equatable, Sendable {
            case statistics
            case deviceData(group: String?)
        }
        var endpoint: Endpoint
        var key: String
    }

    public init(session: MiSession, transport: any MiHTTPTransport = URLSessionMiTransport()) {
        self.session = session
        self.transport = transport
        self.userAgent = Self.makeUserAgent()
    }

    static func makeUserAgent() -> String {
        let lower = Array("abcdefghijklmnopqrstuvwxyz")
        let upper = Array("ABCDE")
        let a = String((0..<18).map { _ in lower.randomElement()! })
        let b = String((0..<13).map { _ in upper.randomElement()! })
        return "\(a)-\(b) APP/com.xiaomi.mihome APPV/10.5.201"
    }

    /// Signed RC4 POST to `<apiBase>/<api>`; returns the decrypted `result` payload.
    public func request(_ api: String, data: JSONValue) async throws -> JSONValue {
        let path = "/" + api.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: session.apiBaseURL + path) else { throw MiCloudError.badResponse("URL") }
        let nonce = MiCloudCrypto.makeNonce()
        let signed = try MiCloudCrypto.signedNonce(ssecurity: session.ssecurity, nonce: nonce)
        let fields = try MiCloudCrypto.encryptParams(path: path, data: data.compactJSONString, ssecurity: session.ssecurity, nonce: nonce)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("PROTOCAL-HTTP2", forHTTPHeaderField: "x-xiaomi-protocal-flag-cli")
        req.setValue("ENCRYPT-RC4", forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        req.httpBody = Data(MiCloudCrypto.formURLEncode(fields).utf8)

        let (body, http) = try await transport.send(req)
        do {
            return try Self.decodeResponse(body, statusCode: http.statusCode, signedNonce: signed)
        } catch let error as MiCloudError {
            logger.error("\(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func cookieHeader() -> String {
        [
            ("userId", session.userId),
            ("serviceToken", session.serviceToken),
            ("yetAnotherServiceToken", session.serviceToken),
            ("locale", "zh_CN"),
            ("timezone", "GMT+08:00"),
            ("is_daylight", "0"),
            ("dst_offset", "0"),
            ("channel", "MI_APP_STORE"),
        ].map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    static func decodeResponse(_ body: Data, statusCode: Int, signedNonce: String) throws -> JSONValue {
        if statusCode == 401 || statusCode == 403 { throw MiCloudError.sessionExpired }
        // Errors come back as plain JSON; successes are base64(RC4(json)). A plain object is never a
        // success payload, so it must carry an explicit verdict: either an integer `code`, or a
        // message that names the real reason (#76, #67).
        if let plain = try? JSONDecoder().decode(JSONValue.self, from: body), case .object = plain {
            if let code = plain["code"]?.intValue {
                if code != 0 { return try unwrapResult(plain) }
                // `{"code":0}` without the encrypted body is not a payload this client can use.
                guard statusCode == 200 else { throw MiCloudError.http(statusCode) }
                return try unwrapResult(plain)
            }
            if Self.isAuthRejection(plain) { throw MiCloudError.sessionExpired }
            guard statusCode == 200 else { throw MiCloudError.http(statusCode) }
            // A 200 object with no `code` is a gateway error page or an unknown envelope shape. The
            // old code read it as `code: 0` and returned `.null`, which surfaced as "synced, no devices".
            throw MiCloudError.badResponse("缺少状态码")
        }
        guard statusCode == 200 else { throw MiCloudError.http(statusCode) }
        guard let text = String(data: body, encoding: .utf8),
              let decrypted = try? MiCloudCrypto.decryptResponse(text, signedNonce: signedNonce),
              let json = try? JSONDecoder().decode(JSONValue.self, from: decrypted) else {
            throw MiCloudError.badResponse("无法解密")
        }
        return try unwrapResult(json)
    }

    /// True when a response body names an expired session or a rejected token without a `code`.
    static func isAuthRejection(_ json: JSONValue) -> Bool {
        let keys = ["message", "desc", "description", "error", "reason"]
        let text = keys.compactMap { json[$0]?.stringValue }.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        return text.contains("auth err")
            || text.contains("servicetoken_expired")
            || text.contains("token expired")
            || text.contains("invalid signature")
            || text.contains("invalid_token")
            || text.contains("unauthorized")
    }

    static func unwrapResult(_ json: JSONValue) throws -> JSONValue {
        // An envelope without an integer `code` has no verdict, so it is never a success (#76, #67).
        guard let code = json["code"]?.intValue else {
            if Self.isAuthRejection(json) { throw MiCloudError.sessionExpired }
            throw MiCloudError.badResponse("缺少状态码")
        }
        let message = json["message"]?.stringValue ?? json["desc"]?.stringValue ?? ""
        if code == 0 { return json["result"] ?? .null }
        let lower = message.lowercased()
        if code == 2 || code == 3
            || lower.contains("auth err")
            || lower.contains("servicetoken_expired")
            || lower.contains("token expired")
            || lower.contains("invalid signature") {
            throw MiCloudError.sessionExpired
        }
        throw MiCloudError.api(code: code, message: message)
    }

    // MARK: Endpoints

    /// `v2/home/device_list_page` also returns the split keys of multi-key Mesh panels, which
    /// `home/device_list` omits even with `get_split_device`; fall back to the latter on failure.
    public func deviceList() async throws -> [MiDeviceRecord] {
        do {
            return try await deviceListPaged()
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            return try await legacyDeviceList()
        }
    }

    /// Devices of homes shared with this account are missing from the unfiltered list; the cloud
    /// returns them only when asked for by did, as Xiaomi's own `xiaomi_home` integration does (#134).
    public func devices(dids: [String]) async throws -> [MiDeviceRecord] {
        var records: [MiDeviceRecord] = []
        var start = 0
        while start < dids.count {
            let chunk = Array(dids[start..<min(start + Self.didChunkSize, dids.count)])
            start += Self.didChunkSize
            records += try await deviceListPaged(dids: chunk)
        }
        var seen: Set<String> = []
        return records.filter { seen.insert($0.did).inserted }
    }

    static let didChunkSize = 150
    static let groupChunkSize = 100

    /// Maps each `group.*` did among `groupDids` to its deduplicated member device dids (#189).
    /// The cloud answers `v2/groupv2/query_status` with `result[].member_ship` (the plug-in SDK
    /// spells it `membership`); both keys are accepted, and `member_ship` wins when both appear.
    public func lightGroupMembers(groupDids: [String]) async throws -> [String: [String]] {
        var seen: Set<String> = []
        let unique = groupDids.filter { $0.hasPrefix("group.") && seen.insert($0).inserted }
        var members: [String: [String]] = [:]
        var start = 0
        while start < unique.count {
            let chunk = Array(unique[start..<min(start + Self.groupChunkSize, unique.count)])
            start += Self.groupChunkSize
            let result = try await request("v2/groupv2/query_status", data: .object([
                "group_did": .array(chunk.map(JSONValue.string)),
            ]))
            for (groupDid, memberDids) in Self.parseLightGroupMembers(result) {
                var merged = members[groupDid] ?? []
                for did in memberDids where !merged.contains(did) { merged.append(did) }
                members[groupDid] = merged
            }
        }
        return members
    }

    /// `result[]` rows carry the group did and an object keyed by member did. Missing, malformed or
    /// non-object memberships are skipped rather than failing the whole refresh.
    static func parseLightGroupMembers(_ result: JSONValue) -> [String: [String]] {
        guard let rows = result.arrayValue else { return [:] }
        var groups: [String: [String]] = [:]
        for row in rows {
            guard let groupDid = row["group_did"]?.idString, !groupDid.isEmpty else { continue }
            let membership = [row["member_ship"], row["membership"]]
                .compactMap { $0 }
                .first { value in
                    if case .object = value { return true }
                    return false
                }
            guard let membership, case .object(let memberDids) = membership else { continue }
            var members = groups[groupDid] ?? []
            for did in memberDids.keys where !did.isEmpty && !members.contains(did) {
                members.append(did)
            }
            groups[groupDid] = members
        }
        return groups
    }

    private func deviceListPaged(dids: [String]? = nil) async throws -> [MiDeviceRecord] {
        var records: [MiDeviceRecord] = []
        var startDid = ""
        for _ in 0..<20 {
            var data: [String: JSONValue] = [
                "get_split_device": .bool(true),
                "support_smart_home": .bool(true),
                // Without this the page omits third-party devices merged into Mi Home, which is how
                // several accounts report an empty panel (#76, #67).
                "get_third_device": .bool(true),
                "limit": .number(200),
            ]
            if let dids { data["dids"] = .array(dids.map(JSONValue.string)) }
            if !startDid.isEmpty { data["start_did"] = .string(startDid) }
            let result = try await request("v2/home/device_list_page", data: .object(data))
            records += Self.parseDeviceList(result)
            let next = result["next_start_did"]?.idString ?? ""
            guard result["has_more"]?.boolValue == true, !next.isEmpty, next != startDid else { break }
            startDid = next
        }
        var seen: Set<String> = []
        return records.filter { seen.insert($0.did).inserted }
    }

    /// Every device of one home, addressed by (home id, owner uid). The unfiltered list covers the
    /// signed-in uid's own homes only, so a home shared with this account is invisible until asked
    /// for this way (#76, #67).
    public func homeDevices(homeId: String, ownerUid: String) async throws -> [MiDeviceRecord] {
        var records: [MiDeviceRecord] = []
        var startDid = ""
        for _ in 0..<20 {
            var data: [String: JSONValue] = [
                "home_owner": Self.miIdValue(ownerUid),
                "home_id": Self.miIdValue(homeId),
                "limit": .number(300),
                "get_split_device": .bool(true),
                "support_smart_home": .bool(true),
                "get_cariot_device": .bool(true),
                "get_third_device": .bool(true),
            ]
            if !startDid.isEmpty { data["start_did"] = .string(startDid) }
            let result = try await request("v2/home/home_device_list", data: .object(data))
            records += Self.parseHomeDeviceList(result)
            let next = result["max_did"]?.idString ?? result["next_start_did"]?.idString ?? ""
            guard result["has_more"]?.boolValue == true, !next.isEmpty, next != startDid else { break }
            startDid = next
        }
        var seen: Set<String> = []
        return records.filter { seen.insert($0.did).inserted }
    }

    /// Mi ids travel as numbers when they fit the app's integer range, as strings otherwise.
    static func miIdValue(_ raw: String) -> JSONValue {
        guard let value = Int64(raw),
              value > 0,
              value < MiIdLimits.maxNumericId else { return .string(raw) }
        return .number(Double(value))
    }

    /// `home_device_list` answers under `device_info`, newer builds under `list`.
    static func parseHomeDeviceList(_ result: JSONValue) -> [MiDeviceRecord] {
        let items = result["device_info"]?.arrayValue ?? result["list"]?.arrayValue ?? []
        return Self.parseDeviceList(.object(["list": .array(items)]))
    }

    private func legacyDeviceList() async throws -> [MiDeviceRecord] {
        let result = try await request("home/device_list", data: .object([
            "getVirtualModel": .bool(true),
            "getHuamiDevices": .number(1),
            "get_split_device": .bool(false),
            "support_smart_home": .bool(true),
        ]))
        return Self.parseDeviceList(result)
    }

    static func parseDeviceList(_ result: JSONValue) -> [MiDeviceRecord] {
        (result["list"]?.arrayValue ?? []).compactMap { item in
            guard let did = item["did"]?.idString, let model = item["model"]?.stringValue else { return nil }
            let split = item["extra"]?["split"]
            let rawSplitParent = split?["parentId"]?.idString
            let rawSplitSiid = split?["moduleId"]?.intValue
            return MiDeviceRecord(
                did: did,
                name: item["name"]?.stringValue ?? model,
                model: model,
                isOnline: item["isOnline"]?.boolValue ?? true,
                specType: item["spec_type"]?.stringValue,
                splitParentDid: rawSplitSiid != nil ? rawSplitParent : nil,
                splitSiid: rawSplitParent != nil ? rawSplitSiid : nil,
                localIp: item["localip"]?.stringValue,
                mac: item["mac"]?.stringValue
            )
        }
    }

    public func cameraLocalIP(did: String) async throws -> String? {
        let records = try await legacyDeviceList()
        return records.first(where: { $0.did == did || $0.miotDid == did })?.localIp
    }

    public func cameraP2PVendor(did: String, appPublicKey: String) async throws -> MiCameraP2PVendor {
        let result = try await request("v2/device/miss_get_vendor", data: .object([
            "did": .string(did),
            "app_pubkey": .string(appPublicKey),
            "support_vendors": .string("TUTK_CS2_MTP"),
        ]))
        let vendorObj = result["vendor"]
        let vendorId = vendorObj?["vendor"]?.intValue ?? 4
        let vendorName: String
        switch vendorId {
        case 1: vendorName = "tutk"
        case 4: vendorName = "cs2"
        default: vendorName = String(vendorId)
        }
        let p2pId = vendorObj?["vendor_params"]?["p2p_id"]?.stringValue
        let devicePublic = result["public_key"]?.stringValue ?? ""
        let sign = result["sign"]?.stringValue ?? ""
        return MiCameraP2PVendor(
            vendorName: vendorName,
            p2pId: p2pId,
            devicePublicKey: devicePublic,
            sign: sign
        )
    }

    public func homeRooms() async throws -> [MiRoom] {
        let merged: JSONValue
        do {
            merged = try await request("v2/homeroom/gethome_merged", data: .object([
                "fg": .bool(true), "fetch_share": .bool(true), "fetch_share_dev": .bool(true),
                "limit": .number(300), "app_ver": .number(9), "plat_form": .number(0),
            ]))
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            merged = try await request("v2/homeroom/gethome", data: .object([
                "fg": .bool(true), "fetch_share": .bool(true), "fetch_share_dev": .bool(true),
                "limit": .number(300), "app_ver": .number(9), "plat_form": .number(0),
            ]))
        }
        var rooms = Self.parseRooms(merged)
        // An account with many homes gets the first page only; the rest arrive by `max_id`. Without
        // them the device list names dids no room owns, and the panel shows nothing (#76, #67).
        var visited: Set<String> = []
        var maxId = merged["max_id"]?.idString ?? ""
        guard Self.hasMoreRooms(merged), !maxId.isEmpty else { return rooms }
        for _ in 0..<20 {
            guard visited.insert(maxId).inserted else { break }
            let page: JSONValue
            do {
                page = try await request("v2/homeroom/get_dev_room_page", data: .object([
                    "start_id": .string(maxId), "limit": .number(150),
                ]))
            } catch MiCloudError.sessionExpired {
                throw MiCloudError.sessionExpired
            } catch {
                logger.notice("Room continuation page failed, keeping \(rooms.count, privacy: .public) parsed rooms: \(error.localizedDescription, privacy: .public)")
                break
            }
            rooms = Self.mergeRoomPage(page, into: rooms)
            let nextMaxId = page["max_id"]?.idString ?? ""
            guard Self.hasMoreRooms(page), !nextMaxId.isEmpty else { break }
            maxId = nextMaxId
        }
        return rooms
    }

    /// `has_more` comes back as a real boolean or as 1/0 depending on the endpoint; Windows
    /// (`client.ts:hasMoreHomes`) accepts both, so a `1` must not end the room pages early.
    static func hasMoreRooms(_ result: JSONValue) -> Bool {
        switch result["has_more"] {
        case .bool(let flag)?: return flag
        case .number(let number)?: return number == 1
        default: return false
        }
    }

    /// Merges one `v2/homeroom/get_dev_room_page` page into the rooms already parsed from
    /// `gethome_merged`. A page repeats the home shape under `info` (`id`, `dids`, `roomlist`) but
    /// omits the names, so it only adds dids — never a second room, and never a did twice.
    static func mergeRoomPage(_ page: JSONValue, into rooms: [MiRoom]) -> [MiRoom] {
        var result = rooms
        func appendDids(_ dids: [String], toRoom roomId: String, homeId: String, roomName: String = "") {
            guard !dids.isEmpty, !roomId.isEmpty else { return }
            guard let index = result.firstIndex(where: { $0.id == roomId }) else {
                // The page can name a home or room whose first page omitted it. Preserve any room
                // name carried by the continuation page and inherit home metadata from a sibling.
                let sibling = result.first { $0.homeId == homeId }
                result.append(MiRoom(
                    id: roomId,
                    name: roomName,
                    dids: [],
                    homeId: homeId,
                    homeName: sibling?.homeName ?? "",
                    isSharedHome: sibling?.isSharedHome ?? false,
                    ownerUid: sibling?.ownerUid
                ))
                appendDids(dids, toRoom: roomId, homeId: homeId, roomName: roomName)
                return
            }
            var room = result[index]
            if room.name.isEmpty, !roomName.isEmpty {
                room.name = roomName
            }
            for did in dids where !room.dids.contains(did) {
                room.dids.append(did)
            }
            result[index] = room
        }

        for info in page["info"]?.arrayValue ?? [] {
            guard let homeId = info["id"]?.idString, !homeId.isEmpty else { continue }
            appendDids(
                (info["dids"]?.arrayValue ?? []).compactMap(\.idString),
                toRoom: "home_\(homeId)",
                homeId: homeId
            )
            for room in info["roomlist"]?.arrayValue ?? [] {
                guard let roomId = room["id"]?.idString else { continue }
                appendDids(
                    (room["dids"]?.arrayValue ?? []).compactMap(\.idString),
                    toRoom: roomId,
                    homeId: homeId,
                    roomName: room["name"]?.stringValue ?? ""
                )
            }
        }
        return result
    }

    /// Homes another account shared with this one arrive under `share_home_list`, not `homelist` (#134).
    static func parseRooms(_ result: JSONValue) -> [MiRoom] {
        var rooms: [MiRoom] = []
        var seenHomes: Set<String> = []
        func appendHomes(_ homes: [JSONValue], shared: Bool) {
            for home in homes {
                let homeId = home["id"]?.idString ?? ""
                if !homeId.isEmpty, !seenHomes.insert(homeId).inserted { continue }
                let homeName = home["name"]?.stringValue ?? ""
                let ownerUid = home["uid"]?.idString
                for room in home["roomlist"]?.arrayValue ?? [] {
                    guard let id = room["id"]?.idString else { continue }
                    rooms.append(MiRoom(
                        id: id,
                        name: room["name"]?.stringValue ?? "",
                        dids: (room["dids"]?.arrayValue ?? []).compactMap(\.idString),
                        homeId: homeId,
                        homeName: homeName,
                        isSharedHome: shared,
                        ownerUid: ownerUid
                    ))
                }
                let homeDids = (home["dids"]?.arrayValue ?? []).compactMap(\.idString)
                if !homeDids.isEmpty {
                    rooms.append(MiRoom(
                        id: "home_\(homeId)",
                        name: "",
                        dids: homeDids,
                        homeId: homeId,
                        homeName: homeName,
                        isSharedHome: shared,
                        ownerUid: ownerUid
                    ))
                }
                // A home with no rooms and no dids still matters when the cloud names its owner:
                // only `MiCloudDiscovery.homeFallback` can list its devices, and it needs a room to
                // learn the pair (home id, owner uid) from. Without this entry such a home is
                // invisible, which is the empty panel of #76 / #67.
                if !homeId.isEmpty, homeDids.isEmpty,
                   (home["roomlist"]?.arrayValue ?? []).isEmpty,
                   ownerUid != nil {
                    rooms.append(MiRoom(
                        id: "home_\(homeId)",
                        name: "",
                        dids: [],
                        homeId: homeId,
                        homeName: homeName,
                        isSharedHome: shared,
                        ownerUid: ownerUid
                    ))
                }
            }
        }
        appendHomes(result["homelist"]?.arrayValue ?? [], shared: false)
        appendHomes(result["share_home_list"]?.arrayValue ?? [], shared: true)
        return rooms
    }

    public func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        var values: [MiotPropKey: JSONValue] = [:]
        var start = 0
        while start < keys.count {
            let chunk = keys[start..<min(start + Self.propChunkSize, keys.count)]
            start += Self.propChunkSize
            let params: [JSONValue] = chunk.map {
                .object(["did": .string($0.did), "siid": .number(Double($0.siid)), "piid": .number(Double($0.piid))])
            }
            let result = try await request("miotspec/prop/get", data: .object(["params": .array(params)]))
            values.merge(Self.parsePropValues(result)) { _, new in new }
        }
        return values
    }

    static func parsePropValues(_ result: JSONValue) -> [MiotPropKey: JSONValue] {
        var values: [MiotPropKey: JSONValue] = [:]
        for item in result.arrayValue ?? [] {
            guard let did = item["did"]?.idString,
                  let siid = item["siid"]?.intValue,
                  let piid = item["piid"]?.intValue,
                  (item["code"]?.intValue ?? 0) == 0,
                  let value = item["value"] else { continue }
            values[MiotPropKey(did: did, siid: siid, piid: piid)] = value
        }
        return values
    }

    public func setProps(_ writes: [MiotPropWrite]) async throws {
        let params: [JSONValue] = writes.map {
            .object([
                "did": .string($0.did), "siid": .number(Double($0.siid)),
                "piid": .number(Double($0.piid)), "value": $0.value,
            ])
        }
        let result = try await request("miotspec/prop/set", data: .object(["params": .array(params)]))
        try Self.checkWriteCodes(result.arrayValue ?? [])
    }

    public func action(_ call: MiotActionCall) async throws {
        _ = try await callAction(call)
    }

    public func callAction(_ call: MiotActionCall) async throws -> JSONValue {
        let result = try await request("miotspec/action", data: .object(["params": .object([
            "did": .string(call.did), "siid": .number(Double(call.siid)),
            "aiid": .number(Double(call.aiid)), "in": .array(call.inputs),
        ])]))
        try Self.checkWriteCodes([result])
        return result
    }

    /// MIoT per-item codes: 0 = done, 1 = accepted (async); negatives are device/gateway errors such as -704042011 (offline).
    static func checkWriteCodes(_ items: [JSONValue]) throws {
        for item in items {
            let code = item["code"]?.intValue ?? 0
            if code < 0 {
                throw MiCloudError.deviceError(code: code, message: "设备未响应或离线")
            }
        }
    }

    // MARK: - Sensor History (`v2/user/statistics` + `user/get_user_device_data`)

    public struct MetricSamplePoint: Equatable, Sendable {
        public let timestamp: Date
        public let value: Double
        public let minValue: Double
        public let maxValue: Double

        public init(timestamp: Date, value: Double, minValue: Double? = nil, maxValue: Double? = nil) {
            self.timestamp = timestamp
            self.value = value
            self.minValue = minValue ?? value
            self.maxValue = maxValue ?? value
        }
    }

    public func sensorHistory(
        did: String,
        temperatureKey: String?,
        humidityKey: String?,
        window: SensorHistoryWindow,
        now: Date
    ) async throws -> [SensorHistorySample] {
        let timeEnd = Int(now.timeIntervalSince1970)
        let spanSeconds = window == .last24Hours ? 25 * 3600 : 8 * 86400
        let timeStart = max(0, timeEnd - spanSeconds)

        let tempPoints = try await fetchMetricSeries(
            did: did,
            miotKey: temperatureKey,
            isTemperature: true,
            window: window,
            timeStart: timeStart,
            timeEnd: timeEnd,
            now: now
        )
        let humPoints = try await fetchMetricSeries(
            did: did,
            miotKey: humidityKey,
            isTemperature: false,
            window: window,
            timeStart: timeStart,
            timeEnd: timeEnd,
            now: now
        )
        return Self.combineMetricSeries(temperature: tempPoints, humidity: humPoints)
    }

    private func fetchMetricSeries(
        did: String,
        miotKey: String?,
        isTemperature: Bool,
        window: SensorHistoryWindow,
        timeStart: Int,
        timeEnd: Int,
        now: Date
    ) async throws -> [MetricSamplePoint] {
        let cacheId = "\(did)|\(isTemperature ? "temp" : "hum")|\(window.rawValue)"
        let cachedRoute = resolvedHistoryRouteByMetric[cacheId]
        if let cachedRoute {
            let pts = try await queryHistoryRoute(
                cachedRoute,
                did: did,
                isTemperature: isTemperature,
                window: window,
                timeStart: timeStart,
                timeEnd: timeEnd
            )
            if !pts.isEmpty { return pts }
            resolvedHistoryRouteByMetric.removeValue(forKey: cacheId)
        } else if let retryAfter = emptyHistoryRetryAfterByMetric[cacheId] {
            if now < retryAfter { return [] }
            emptyHistoryRetryAfterByMetric.removeValue(forKey: cacheId)
        }

        let statCandidates = Self.candidateKeysForStatistics(miotKey: miotKey, isTemperature: isTemperature)
        for key in statCandidates {
            let route = HistoryRoute(endpoint: .statistics, key: key)
            if route == cachedRoute { continue }
            let pts = try await queryHistoryRoute(
                route,
                did: did,
                isTemperature: isTemperature,
                window: window,
                timeStart: timeStart,
                timeEnd: timeEnd
            )
            if !pts.isEmpty {
                emptyHistoryRetryAfterByMetric.removeValue(forKey: cacheId)
                resolvedHistoryRouteByMetric[cacheId] = route
                return pts
            }
        }

        let dataCandidates = Self.candidateKeysForDeviceData(miotKey: miotKey, isTemperature: isTemperature)
        let groups: [String?] = [window == .last24Hours ? "hour" : "day", "raw"]
        for group in groups {
            for key in dataCandidates {
                let route = HistoryRoute(endpoint: .deviceData(group: group), key: key)
                if route == cachedRoute { continue }
                let pts = try await queryHistoryRoute(
                    route,
                    did: did,
                    isTemperature: isTemperature,
                    window: window,
                    timeStart: timeStart,
                    timeEnd: timeEnd
                )
                if !pts.isEmpty {
                    emptyHistoryRetryAfterByMetric.removeValue(forKey: cacheId)
                    resolvedHistoryRouteByMetric[cacheId] = route
                    return pts
                }
            }
        }
        emptyHistoryRetryAfterByMetric[cacheId] = now.addingTimeInterval(Self.emptyHistoryCooldown)
        return []
    }

    private func queryHistoryRoute(
        _ route: HistoryRoute,
        did: String,
        isTemperature: Bool,
        window: SensorHistoryWindow,
        timeStart: Int,
        timeEnd: Int
    ) async throws -> [MetricSamplePoint] {
        do {
            let result: JSONValue
            switch route.endpoint {
            case .statistics:
                let dataType = window == .last24Hours ? "stat_hour_v3" : "stat_day_v3"
                let limit = window == .last24Hours ? 48 : 14
                result = try await request("v2/user/statistics", data: .object([
                    "did": .string(did),
                    "key": .string(route.key),
                    "data_type": .string(dataType),
                    "time_start": .number(Double(timeStart)),
                    "time_end": .number(Double(timeEnd)),
                    "limit": .number(Double(limit)),
                ]))
            case .deviceData(let group):
                var payload: [String: JSONValue] = [
                    "uid": .string(session.userId),
                    "did": .string(did),
                    "type": .string("prop"),
                    "key": .string(route.key),
                    "time_start": .number(Double(timeStart)),
                    "time_end": .number(Double(timeEnd)),
                    "limit": .number(group == "raw" ? 200 : 48),
                ]
                if let group {
                    payload["group"] = .string(group)
                }
                result = try await request("user/get_user_device_data", data: .object(payload))
            }
            return Self.parseHistoryMetricPoints(result, key: route.key, isTemperature: isTemperature)
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            return []
        }
    }

    static func candidateKeysForStatistics(miotKey: String?, isTemperature: Bool) -> [String] {
        var keys: [String] = []
        if let miotKey, !miotKey.isEmpty {
            keys.append(miotKey)
        } else {
            keys.append(isTemperature ? "2.1" : "2.2")
        }
        keys.append(isTemperature ? "4c01" : "4c08")
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    static func candidateKeysForDeviceData(miotKey: String?, isTemperature: Bool) -> [String] {
        var keys: [String] = []
        if let miotKey, !miotKey.isEmpty {
            keys.append(miotKey)
            keys.append("prop.\(miotKey)")
        }
        if isTemperature {
            keys += ["4c01", "4100", "1004", "temperature"]
        } else {
            keys += ["4c08", "4102", "1006", "humidity", "relative-humidity"]
        }
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    /// Parses Xiaomi Cloud `v2/user/statistics` or `user/get_user_device_data` responses into time-sorted points.
    public static func parseHistoryMetricPoints(
        _ result: JSONValue,
        key: String,
        isTemperature: Bool
    ) -> [MetricSamplePoint] {
        let items: [JSONValue]
        if let array = result.arrayValue {
            items = array
        } else if let nested = result["list"]?.arrayValue ?? result["data"]?.arrayValue ?? result["result"]?.arrayValue {
            items = nested
        } else {
            return []
        }

        var points: [MetricSamplePoint] = []
        points.reserveCapacity(items.count)

        for item in items {
            guard let rawTime = item["time"]?.doubleValue ?? item["timestamp"]?.doubleValue,
                  rawTime > 0,
                  let rawValue = item["value"] else { continue }
            let seconds = rawTime > 10_000_000_000 ? rawTime / 1000.0 : rawTime
            let decoded = decodeHistoryValues(rawValue, key: key, isTemperature: isTemperature)
            guard !decoded.isEmpty else { continue }
            let lo = decoded.min()!
            let hi = decoded.max()!
            let avg = ((decoded.reduce(0, +) / Double(decoded.count)) * 10).rounded() / 10
            points.append(MetricSamplePoint(
                timestamp: Date(timeIntervalSince1970: seconds),
                value: avg,
                minValue: lo,
                maxValue: hi
            ))
        }
        points.sort { $0.timestamp < $1.timestamp }
        return points
    }

    private struct ExtractedHistoryNumber {
        let value: Double
        /// `true` when the value was already converted from a hex representation (e.g. `Int16` tenths
        /// or `Float32` bytes) or parsed from a decimal string with a fractional point, so it must
        /// not be divided by 10 again.
        let isPreScaled: Bool
    }

    static func decodeHistoryValues(_ raw: JSONValue, key: String, isTemperature: Bool) -> [Double] {
        let extracted = extractRawNumbers(raw, key: key)
        let usesTenthsScale = ["4100", "4102", "1004", "1006"].contains(key.lowercased())
        return extracted.compactMap { item -> Double? in
            guard item.value.isFinite else { return nil }
            var adjusted = item.value
            if usesTenthsScale, !item.isPreScaled {
                adjusted /= 10.0
            }
            if isTemperature {
                return SensorHistory.sanitizeTemperature(adjusted)
            } else {
                return SensorHistory.sanitizeHumidity(adjusted)
            }
        }
    }

    private static func extractRawNumbers(_ raw: JSONValue, key: String) -> [ExtractedHistoryNumber] {
        switch raw {
        case .number(let d):
            return [ExtractedHistoryNumber(value: d, isPreScaled: d.rounded() != d)]
        case .array(let arr):
            return arr.flatMap { extractRawNumbers($0, key: key) }
        case .object(let obj):
            if let v = obj["avg"] ?? obj["value"] ?? obj["temp"] ?? obj["humidity"] {
                return extractRawNumbers(v, key: key)
            }
            return []
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !trimmed.isEmpty else { return [] }
            if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) || (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")),
               let data = trimmed.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return extractRawNumbers(parsed, key: key)
            }
            let lowerKey = key.lowercased()
            if (lowerKey == "4c01" || lowerKey == "4c08"),
               let floatVal = decodeLittleEndianFloat32Hex(trimmed) {
                return [ExtractedHistoryNumber(value: floatVal, isPreScaled: true)]
            }
            if ["4100", "4102", "1004", "1006"].contains(lowerKey),
               trimmed.range(of: ".", options: .literal) == nil,
               let int16Tenths = decodeLittleEndianInt16Hex(trimmed) {
                return [ExtractedHistoryNumber(value: int16Tenths, isPreScaled: true)]
            }
            if let d = Double(trimmed) {
                let hasDecimalPoint = trimmed.contains(".")
                return [ExtractedHistoryNumber(value: d, isPreScaled: hasDecimalPoint || d.rounded() != d)]
            }
            if let floatVal = decodeLittleEndianFloat32Hex(trimmed) {
                return [ExtractedHistoryNumber(value: floatVal, isPreScaled: true)]
            }
            return []
        case .bool, .null:
            return []
        }
    }

    /// Decodes an 8-character hex string (e.g. `"cdccbc41"` from MiBeacon v5 `0x4C01`/`0x4C08`) as a
    /// little-endian IEEE 754 `Float32`.
    static func decodeLittleEndianFloat32Hex(_ hex: String) -> Double? {
        guard hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        var idx = hex.startIndex
        for _ in 0..<4 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let f = Float(bitPattern: bits)
        guard f.isFinite else { return nil }
        return ((Double(f) * 10).rounded()) / 10
    }

    /// Decodes a 4-character hex string containing at least one a-f hex letter (or little-endian high byte `00`–`03`)
    /// as a little-endian `Int16` scaled by 0.1 (MiBeacon v2/v3 `0x1004`/`0x1006`).
    /// Excludes `"1000"` so a decimal 100.0% humidity reading (`1000` tenths) is not misread as `0x0010` (`1.6%`).
    static func decodeLittleEndianInt16Hex(_ hex: String) -> Double? {
        guard hex.count == 4, hex != "1000", hex.allSatisfy(\.isHexDigit) else { return nil }
        let hasHexLetter = hex.contains { ("a"..."f").contains($0.lowercased()) }
        let hasValidLittleEndianHighByte = hex.hasSuffix("00") || hex.hasSuffix("01") || hex.hasSuffix("02") || hex.hasSuffix("03")
        guard hasHexLetter || hasValidLittleEndianHighByte else { return nil }
        let b0 = UInt8(hex.prefix(2), radix: 16)
        let b1 = UInt8(hex.suffix(2), radix: 16)
        guard let b0, let b1 else { return nil }
        let raw = Int16(bitPattern: UInt16(b0) | (UInt16(b1) << 8))
        return Double(raw) / 10.0
    }

    static func combineMetricSeries(
        temperature: [MetricSamplePoint],
        humidity: [MetricSamplePoint]
    ) -> [SensorHistorySample] {
        var samples: [SensorHistorySample] = []
        samples.reserveCapacity(temperature.count + humidity.count)
        for pt in temperature {
            samples.append(SensorHistorySample(
                timestamp: pt.timestamp,
                temperature: pt.value,
                minTemperature: pt.minValue,
                maxTemperature: pt.maxValue
            ))
        }
        for pt in humidity {
            samples.append(SensorHistorySample(
                timestamp: pt.timestamp,
                humidity: pt.value,
                minHumidity: pt.minValue,
                maxHumidity: pt.maxValue
            ))
        }
        return samples
    }
}
