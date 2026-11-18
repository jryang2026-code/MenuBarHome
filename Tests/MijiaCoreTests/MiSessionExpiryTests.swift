import Foundation
import Testing
@testable import MijiaCore

struct MiSessionExpiryPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("An undated session is valid at any date; no lifetime is guessed")
    func undatedSessionNeverExpires() {
        #expect(MiSessionExpiryPolicy.state(expiresAt: nil, now: .distantPast) == .valid)
        #expect(MiSessionExpiryPolicy.state(expiresAt: nil, now: .distantFuture) == .valid)

        let undated = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "t")
        #expect(undated.expiresAt == nil)
        #expect(undated.expiryState(at: .distantFuture) == .valid)
    }

    @Test("Outside the lead is valid, inside and exactly at the lead warn, at or past the end expires")
    func leadTimeBoundaries() {
        let lead = MiSessionExpiryPolicy.warningLeadTime
        let now = Self.now

        let outside = now.addingTimeInterval(lead + 1)
        #expect(MiSessionExpiryPolicy.state(expiresAt: outside, now: now) == .valid)

        let inside = now.addingTimeInterval(lead - 1)
        #expect(MiSessionExpiryPolicy.state(expiresAt: inside, now: now) == .expiringSoon(expiresAt: inside))

        let exactlyAtLead = now.addingTimeInterval(lead)
        #expect(MiSessionExpiryPolicy.state(expiresAt: exactlyAtLead, now: now) == .expiringSoon(expiresAt: exactlyAtLead))

        #expect(MiSessionExpiryPolicy.state(expiresAt: now, now: now) == .expired)
        #expect(MiSessionExpiryPolicy.state(expiresAt: now.addingTimeInterval(-1), now: now) == .expired)
    }

    @Test("A session saved before expiresAt existed still decodes as undated")
    func legacyJSONDecodesUndated() throws {
        let json = #"{"userId":"42","cUserId":"c","ssecurity":"s","serviceToken":"t","region":"cn"}"#
        let session = try JSONDecoder().decode(MiSession.self, from: Data(json.utf8))
        #expect(session.expiresAt == nil)
        #expect(session.expiryState(at: .distantFuture) == .valid)
    }

    @Test("Shared session_expiry_golden.json corpus matches macOS MiSessionExpiryPolicy and maskedUserId (#46)")
    func matchesSessionExpiryGoldenCorpus() throws {
        struct PolicyCase: Decodable { let id: String; let expiresAtOffsetSeconds: Double?; let expectedState: String }
        struct MaskedCase: Decodable { let userId: String; let expected: String }
        struct GoldenFile: Decodable {
            let warningLeadSeconds: Double; let nowEpochSeconds: Double
            let policyCases: [PolicyCase]; let maskedUserIdCases: [MaskedCase]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/session_expiry_golden.json")
        let golden = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
        #expect(MiSessionExpiryPolicy.warningLeadTime == golden.warningLeadSeconds)
        let now = Date(timeIntervalSince1970: golden.nowEpochSeconds)
        for item in golden.policyCases {
            let expiresAt = item.expiresAtOffsetSeconds.map { now.addingTimeInterval($0) }
            let state = MiSessionExpiryPolicy.state(expiresAt: expiresAt, now: now)
            switch item.expectedState {
            case "valid": #expect(state == .valid, "\(item.id)")
            case "expiringSoon": #expect(state == .expiringSoon(expiresAt: try #require(expiresAt)), "\(item.id)")
            default: #expect(state == .expired, "\(item.id)")
            }
        }
        for item in golden.maskedUserIdCases {
            #expect(MiSession(userId: item.userId, cUserId: "c", ssecurity: "s", serviceToken: "t").maskedUserId == item.expected)
        }
    }
}

struct MiSessionRejectionTests {
    @Test("A rejection from a stale userId or serviceToken leaves the stored session untouched")
    func staleRejectionIsIgnored() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-rejection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let stored = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "current")
        #expect(MiSessionStore.save(stored, defaults: defaults))

        let olderToken = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "older")
        let otherUser = MiSession(userId: "43", cUserId: "c", ssecurity: "s", serviceToken: "current")
        #expect(MiSessionStore.markRejected(olderToken, at: Date(), defaults: defaults) == nil)
        #expect(MiSessionStore.markRejected(otherUser, at: Date(), defaults: defaults) == nil)
        #expect(MiSessionStore.load(defaults: defaults) == stored)
    }

    @Test("A rejection records its time over a stored future end for the current credential")
    func rejectionOverwritesFutureEnd() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-rejection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let future = Date(timeIntervalSince1970: 2_000_000_000)
        let stored = MiSession(userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "tok", expiresAt: future)
        #expect(MiSessionStore.save(stored, defaults: defaults))

        let rejectedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let updated = try #require(MiSessionStore.markRejected(stored, at: rejectedAt, defaults: defaults))
        #expect(updated.expiresAt == rejectedAt)
        #expect(MiSessionStore.load(defaults: defaults)?.expiresAt == rejectedAt)
    }
}

struct MiAccountLoginExpiryTests {
    @Test("Combined cookies keep expiry attributes with their owner", arguments: [
        "other=x; Max-Age=99, serviceToken=t; Max-Age=3600",
        "serviceToken=t; Max-Age=3600, other=x; Max-Age=99",
        "serviceToken=t; Max-Age=3600; Expires=Wed, 09 Jun 2021 10:18:14 GMT, other=x; Max-Age=99",
        "serviceToken=t; Max-Age=3600"
    ])
    func combinedCookieExpiryBelongsToTarget(_ header: String) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try #require(HTTPURLResponse(url: URL(string: "https://sts.example")!, statusCode: 200,
                                                   httpVersion: nil, headerFields: ["Set-Cookie": header]))
        #expect(MiAccountLogin.parseSetCookieExpiry(named: "serviceToken", in: response, now: now) == now.addingTimeInterval(3600))
    }

    @Test("Another cookie cannot supply an undated or missing target's expiry", arguments: [
        "serviceToken=t; Path=/, other=x; Max-Age=99",
        "other=x; Max-Age=99, serviceToken=t; Path=/",
        "other=x; Max-Age=99"
    ])
    func unrelatedCookieExpiryIsIgnored(_ header: String) throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://sts.example")!, statusCode: 200,
                                                   httpVersion: nil, headerFields: ["Set-Cookie": header]))
        #expect(MiAccountLogin.parseSetCookieExpiry(named: "serviceToken", in: response) == nil)
    }

    @Test("An Expires date retains its weekday comma in combined headers")
    func combinedCookiePreservesExpiresDate() throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://sts.example")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Set-Cookie": "other=x; Max-Age=99, serviceToken=t; Expires=Wed, 09 Jun 2021 10:18:14 GMT, last=y; Max-Age=1"]))
        #expect(MiAccountLogin.parseSetCookieExpiry(named: "serviceToken", in: response) == Date(timeIntervalSince1970: 1_623_233_894))
    }

    @Test("Login captures the serviceToken cookie expiry when the response carries Max-Age")
    func loginCapturesCookieExpiry() async throws {
        let maxAge = 30 * 24 * 60 * 60
        let cookieEndsAt = Date().addingTimeInterval(TimeInterval(maxAge))
        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(secondsFromGMT: 0)
        httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        // `Version=1` lets swift-corelibs-foundation apply Max-Age; `Expires` carries the same instant
        // for any parser that skips it.
        let setCookie = "serviceToken=tok123; Version=1; Max-Age=\(maxAge); Expires=\(httpDate.string(from: cookieEndsAt)); path=/"
        let transport = ScriptedTransport { request in
            let url = request.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","location":"https://sts.example/sts?x=1"}"#)
            }
            if url.hasPrefix("https://sts.example") {
                return (200, ["Set-Cookie": setCookie], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport)
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )

        let session = try await login.waitForScan(ticket)
        #expect(session.serviceToken == "tok123")
        let expiresAt = try #require(session.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince(cookieEndsAt)) < 120)
    }

    @Test("A serviceToken cookie without an end leaves the session undated")
    func loginWithoutCookieEndStaysUndated() async throws {
        let transport = ScriptedTransport { request in
            let url = request.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","location":"https://sts.example/sts?x=1"}"#)
            }
            if url.hasPrefix("https://sts.example") {
                return (200, ["Set-Cookie": "serviceToken=tok123; path=/"], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport)
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )

        let session = try await login.waitForScan(ticket)
        #expect(session.serviceToken == "tok123")
        #expect(session.expiresAt == nil)
    }

    @Test("Max-Age without Version=1 or Expires is parsed directly from Set-Cookie")
    func maxAgeWithoutVersion1IsParsed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = URL(string: "https://sts.example/sts")!
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "serviceToken=tok_max; Max-Age=3600; Path=/; HttpOnly"]
        ))
        let parsed = try #require(MiAccountLogin.serviceTokenCookie(in: response, url: url, now: now))
        #expect(parsed.token == "tok_max")
        #expect(parsed.expiresAt == now.addingTimeInterval(3600))
    }

    @Test("Max-Age takes precedence over Expires per RFC 6265")
    func maxAgeOverridesExpires() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = URL(string: "https://sts.example/sts")!
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Set-Cookie": "serviceToken=tok_rfc; Max-Age=7200; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/"
            ]
        ))
        let parsed = try #require(MiAccountLogin.serviceTokenCookie(in: response, url: url, now: now))
        #expect(parsed.token == "tok_rfc")
        #expect(parsed.expiresAt == now.addingTimeInterval(7200))
    }
}

struct MiSessionExpiryHomeStoreTests {
    @MainActor
    @Test("An expired stored session shows the slash icon and opens re-auth until a new login")
    func expiredStoredSessionSurfacesReauth() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-expiry-store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let expiredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = MiSession(
            userId: "1234567890",
            cUserId: "cu",
            ssecurity: "s",
            serviceToken: "tok",
            expiresAt: expiredAt
        )
        #expect(MiSessionStore.save(expired, defaults: defaults))

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(store.homeBackend == .xiaomiCloud)
        #expect(store.miSessionExpiresAt == expiredAt)
        #expect(store.miSessionExpiryState == .expired)
        #expect(store.miSessionShowsExpired)
        #expect(store.miSessionExpiringSoonDate == nil)
        #expect(store.menuBarSymbolName == "house.slash")

        store.presentMiReauth()
        #expect(store.isShowingMiReauth)
        store.dismissMiReauth()
        #expect(!store.isShowingMiReauth)
        store.presentMiReauth()
        #expect(store.isShowingMiReauth)

        store.completeMiLogin(MiSession(userId: "1234567890", cUserId: "cu", ssecurity: "s", serviceToken: "new"))
        #expect(!store.isShowingMiReauth)
        #expect(store.miSessionExpiresAt == nil)
        #expect(!store.miSessionShowsExpired)
        #expect(store.menuBarSymbolName == "house")
    }

    @MainActor
    @Test("One expired account among several warns without slashing the menu bar icon until all expire")
    func partialAccountExpiryDoesNotBlockControl() throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-expiry-multi.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let expiredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let farEnd = Date(timeIntervalSince1970: 4_000_000_000)
        let expiredCN = MiSession(
            userId: "10010001",
            cUserId: "c-cn",
            ssecurity: "s-cn",
            serviceToken: "tok-cn",
            region: "cn",
            expiresAt: expiredAt
        )
        let validDE = MiSession(
            userId: "20020002",
            cUserId: "c-de",
            ssecurity: "s-de",
            serviceToken: "tok-de",
            region: "de",
            expiresAt: farEnd
        )
        #expect(MiSessionStore.saveAccounts([MiAccount(session: expiredCN), MiAccount(session: validDE)], defaults: defaults))

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(store.miAccounts.count == 2)
        #expect(store.miSessionShowsExpired)
        #expect(!store.miSessionBlocksControl)
        #expect(store.menuBarSymbolName == "house")

        store.presentMiReauth()
        #expect(store.miCloudRegion == .cn)
        store.dismissMiReauth()

        let expiredDE = MiSession(
            userId: "20020002",
            cUserId: "c-de",
            ssecurity: "s-de",
            serviceToken: "tok-de",
            region: "de",
            expiresAt: expiredAt
        )
        #expect(MiSessionStore.saveAccounts([MiAccount(session: expiredCN), MiAccount(session: expiredDE)], defaults: defaults))
        let allExpiredStore = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(allExpiredStore.miSessionShowsExpired)
        #expect(allExpiredStore.miSessionBlocksControl)
        #expect(allExpiredStore.menuBarSymbolName == "house.slash")
    }
}

private actor TransientExpiryMiCloudAPI: MiCloudAPI {
    var devices: [MiDeviceRecord]
    var rooms: [MiRoom]
    var values: [MiotPropKey: JSONValue]
    var remainingFailures: Int
    var remainingRoomFailures: Int
    private(set) var homeRoomsCalls = 0
    private(set) var deviceListCalls = 0
    private(set) var getPropsCalls = 0

    init(
        devices: [MiDeviceRecord] = [MiotFixtures.lightRecord],
        rooms: [MiRoom] = [],
        values: [MiotPropKey: JSONValue] = MiotFixtures.lightValues,
        remainingFailures: Int,
        remainingRoomFailures: Int = 0
    ) {
        self.devices = devices
        self.rooms = rooms
        self.values = values
        self.remainingFailures = remainingFailures
        self.remainingRoomFailures = remainingRoomFailures
    }

    func setRemainingFailures(_ count: Int) {
        remainingFailures = count
    }

    func deviceList() async throws -> [MiDeviceRecord] {
        deviceListCalls += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw MiCloudError.sessionExpired
        }
        return devices
    }

    func homeRooms() async throws -> [MiRoom] {
        homeRoomsCalls += 1
        if remainingRoomFailures > 0 {
            remainingRoomFailures -= 1
            throw MiCloudError.sessionExpired
        }
        return rooms
    }
    func devices(dids: [String]) async throws -> [MiDeviceRecord] { devices.filter { dids.contains($0.did) } }
    func lightGroupMembers(groupDids: [String]) async throws -> [String: [String]] { [:] }

    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        getPropsCalls += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw MiCloudError.sessionExpired
        }
        return values.filter { keys.contains($0.key) }
    }

    func setProps(_ writes: [MiotPropWrite]) async throws {}
    func action(_ call: MiotActionCall) async throws {}
    func callAction(_ call: MiotActionCall) async throws -> JSONValue { .object(["code": .number(0)]) }
    func cameraLocalIP(did: String) async throws -> String? { nil }
    func cameraP2PVendor(did: String, appPublicKey: String) async throws -> MiCameraP2PVendor {
        MiCameraP2PVendor(vendorName: "cs2", p2pId: "p", devicePublicKey: "k", sign: "s")
    }
}

struct ProviderResilienceAndPerfTests {
    private static let session = MiSession(
        userId: "90010001",
        cUserId: "c-90010001",
        ssecurity: "c2VjcmV0",
        serviceToken: "tok-live",
        region: "cn"
    )

    @Test("A rejected credential is never retried: one 401 stops polling and reports the re-scan once (#6)")
    func rejectedCredentialIsNotRetried() async throws {
        // The old retry hid this failure and kept polling on the same dead serviceToken.
        let api = TransientExpiryMiCloudAPI(remainingFailures: 0, remainingRoomFailures: 1)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.expiredSessions.isEmpty })
        #expect(await api.homeRoomsCalls == 1, "the same dead token must reach the cloud once")
        #expect(await api.deviceListCalls == 0)
        #expect(await log.snapshots.isEmpty)
        #expect(await log.expiredSessions == [Self.session])

        // Wake and panel-open refreshes keep the account quiet instead of re-sending the credential.
        await provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true))
        await provider.refreshNow()
        #expect(await api.homeRoomsCalls == 1)
        #expect(await api.deviceListCalls == 0)
        #expect(await log.expiredSessions == [Self.session])
        await provider.shutdown()
    }

    @Test("A refused control write is sent once and later taps never reach the dead session (#6)")
    func refusedControlWriteIsNotResent() async throws {
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord],
            rooms: [],
            values: MiotFixtures.lightValues
        )
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })

        await api.setSetPropsFailure(.sessionExpired)
        await #expect(throws: MiCloudError.sessionExpired) {
            try await provider.execute(.setLightPower(entityId: "miot:123:2", isOn: false))
        }
        #expect(await api.setPropsCalls.count == 1, "the refused write must not be sent a second time")
        #expect(await log.wait { await $0.expiredSessions == [Self.session] })

        // Once the credential is condemned, another tap is refused locally instead of on the wire.
        await #expect(throws: MiCloudError.sessionExpired) {
            try await provider.execute(.setLightPower(entityId: "miot:123:2", isOn: false))
        }
        #expect(await api.setPropsCalls.count == 1)
        await provider.shutdown()
    }

    @Test("Only a different stored credential lifts the stop and resumes polling (#6)")
    func differentCredentialResumesPolling() async throws {
        final class SessionBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: MiSession
            init(_ session: MiSession) { value = session }
            func get() -> MiSession { lock.withLock { value } }
            func set(_ next: MiSession) { lock.withLock { value = next } }
        }
        let stored = SessionBox(Self.session)
        let rejectedAPI = TransientExpiryMiCloudAPI(remainingFailures: 0, remainingRoomFailures: 1)
        let rescannedAPI = TransientExpiryMiCloudAPI(remainingFailures: 0)
        let rescanned = MiSession(
            userId: Self.session.userId,
            cUserId: Self.session.cUserId,
            ssecurity: Self.session.ssecurity,
            serviceToken: "tok-rescanned",
            region: Self.session.region
        )
        let provider = MiCloudProvider(
            sessionLoader: { stored.get() },
            apiFactory: { $0.serviceToken == rescanned.serviceToken ? rescannedAPI : rejectedAPI },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.expiredSessions.isEmpty })
        #expect(await log.snapshots.isEmpty)

        stored.set(rescanned)
        await provider.refreshNow()
        #expect(await log.wait { await !$0.snapshots.isEmpty })
        #expect(await rescannedAPI.deviceListCalls > 0)
        await provider.shutdown()
    }

    @Test("One account's rejection keeps the other account polling and stops the rejected child (#6)")
    func rejectedAccountStopsOnlyItself() async throws {
        let healthy = MiSession(
            userId: "90020002",
            cUserId: "c-90020002",
            ssecurity: "c2VjcmV0",
            serviceToken: "tok-healthy",
            region: "de"
        )
        let healthyAPI = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "de-plug", name: "Plug", model: "cuco.plug.v3", isOnline: true)],
            rooms: [],
            values: [MiotFixtures.key("de-plug", 2, 1): .bool(false)]
        )
        let rejectedAPI = StubMiCloudAPI(devices: [], rooms: [], values: [:], failure: .sessionExpired)
        let provider = MiAccountsProvider(
            accounts: [MiAccount(session: Self.session), MiAccount(session: healthy)],
            apiFactory: { $0.region == "de" ? healthyAPI : rejectedAPI },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60)
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { await $0.expiredSessions == [Self.session] })
        #expect(await log.wait { events in await events.snapshots.last?.devices.map(\.id) == ["de-plug"] })
        let rejectedCalls = await rejectedAPI.deviceListCalls

        await provider.refreshNow()
        #expect(await rejectedAPI.deviceListCalls == rejectedCalls, "the dead account is not woken again")
        #expect(await healthyAPI.deviceListCalls > 0)
        #expect(await log.snapshots.last?.devices.map(\.id) == ["de-plug"])
        await provider.shutdown()
    }

    @Test("The store records the rejection once and rebuilds the account's child from the stored credential (#6)")
    @MainActor
    func storeRebuildsRejectedChild() async throws {
        let suite = "com.jryang1997.MenuBarMijia.mi-rejected-child.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        #expect(MiSessionStore.save(Self.session, defaults: defaults))

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord],
            rooms: [],
            values: MiotFixtures.lightValues
        )
        let account = MiAccount(session: Self.session)
        let provider = MiAccountsProvider(
            accounts: [account],
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60)
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })
        store.activeMiAccountsProvider = provider
        store.activeMiProviderAccounts = [account]
        store.miAccounts = [account]
        #expect(!store.miSessionShowsExpired)
        #expect(await provider.childProviderIdentityForTesting(accountId: account.id) != nil)

        store.handleMiSessionRejected(Self.session)
        await store.providerShutdownTask?.value

        #expect(store.miSessionShowsExpired, "the re-scan state must not fall back")
        #expect(store.miAccounts.first?.session.expiresAt != nil)
        #expect(store.activeMiProviderAccounts.first?.session.expiresAt != nil)
        // The parent now treats the account as ended instead of leaving the dead child running.
        #expect(await provider.isExpiredAccountForTesting(account.id),
                "the child is rebuilt around the stored rejection, not left on the dead session")
        await store.shutdown()
    }

    @Test("Shut-down MiCloudProvider, MiAccountsProvider, and DualSourceHomeProvider latch isShutDown and never restart (#20)")
    func providerShutdownLatchesPreventRestart() async throws {
        let api = TransientExpiryMiCloudAPI(remainingFailures: 0)
        let cloud = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        await cloud.shutdown()
        #expect(await cloud.isShutDownForTesting)
        await cloud.start()
        await cloud.refreshNow()
        await cloud.setPollingContext(PollingContext(panelVisible: true))
        var cloudEvents = 0
        for await _ in cloud.events() { cloudEvents += 1 }
        #expect(cloudEvents == 0)
        #expect(await api.deviceListCalls == 0)

        let accounts = MiAccountsProvider(
            accounts: [MiAccount(session: Self.session)],
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60)
        )
        await accounts.shutdown()
        #expect(await accounts.isShutDownForTesting)
        await accounts.start()
        await accounts.refreshNow()
        await accounts.updateAccounts([MiAccount(session: Self.session)])
        var accountEvents = 0
        for await _ in accounts.events() { accountEvents += 1 }
        #expect(accountEvents == 0)
        #expect(await api.deviceListCalls == 0)

        let dual = DualSourceHomeProvider(homeAssistant: nil, xiaomiCloud: accounts)
        await dual.shutdown()
        #expect(await dual.isShutDownForTesting)
        await dual.start()
        await dual.refreshNow()
        var dualEvents = 0
        for await _ in dual.events() { dualEvents += 1 }
        #expect(dualEvents == 0)
    }

    @Test("Wake poll and immediate refreshNow coalesce into one poll on MiCloudProvider while scope changes still refresh (#33a)")
    func wakePollAndRefreshNowCoalesce() async throws {
        final class SelectionBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
            func set(_ next: String?) { lock.lock(); value = next; lock.unlock() }
        }
        let selection = SelectionBox()
        let api = TransientExpiryMiCloudAPI(
            rooms: [MiRoom(id: "r1", name: "客厅", dids: ["123"], homeId: "h1", homeName: "家")],
            remainingFailures: 0
        )
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            closedPollInterval: .seconds(60),
            deviceRefreshEveryPolls: 1000,
            selectedHomeLoader: { selection.get() }
        )
        let log = EventLog()
        let stream = provider.events()
        let task = Task { for await event in stream { await log.append(event) } }
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        await provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false))
        let snapshotsBeforeWake = await log.snapshots.count
        let callsBeforeWake = await api.getPropsCalls

        await provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))
        await provider.refreshNow()
        #expect(await log.wait { await $0.snapshots.count == snapshotsBeforeWake + 1 })
        await provider.refreshNow()
        #expect(await api.getPropsCalls == callsBeforeWake + 1)

        selection.set("h1")
        await provider.refreshNow()
        #expect(await api.getPropsCalls == callsBeforeWake + 2)
        await provider.shutdown()
    }

    @Test("MiAccountsProvider.updateAccounts keeps unchanged account child provider live while adding and removing accounts (#33b)")
    func incrementalAccountUpdatesKeepUnchangedChildLive() async throws {
        let cnAccount = MiAccount(session: Self.session)
        let deAccount = MiAccount(session: MiSession(
            userId: "90020002",
            cUserId: "c-de",
            ssecurity: "c2VjcmV0",
            serviceToken: "tok-de",
            region: "de"
        ))
        let cnApi = StubMiCloudAPI(devices: [MiotFixtures.lightRecord], rooms: [], values: MiotFixtures.lightValues)
        let deApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "de-plug", name: "Plug", model: "cuco.plug.v3", isOnline: true)],
            rooms: [],
            values: [MiotFixtures.key("de-plug", 2, 1): .bool(true)]
        )
        let provider = MiAccountsProvider(
            accounts: [cnAccount],
            apiFactory: { $0.region == "de" ? deApi : cnApi },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60)
        )
        let log = EventLog()
        let stream = provider.events()
        let task = Task { for await event in stream { await log.append(event) } }
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let initialCnIdentity = try #require(await provider.childProviderIdentityForTesting(accountId: cnAccount.id))

        await provider.updateAccounts([cnAccount, deAccount])
        #expect(await log.wait { events in await events.snapshots.contains { $0.devices.count == 2 } })
        let afterAddCnIdentity = try #require(await provider.childProviderIdentityForTesting(accountId: cnAccount.id))
        #expect(afterAddCnIdentity == initialCnIdentity)
        #expect(await provider.childProviderIdentityForTesting(accountId: deAccount.id) != nil)

        await provider.updateAccounts([cnAccount])
        #expect(await log.wait { events in await events.snapshots.last?.devices.map(\.id) == ["123"] })
        #expect(await provider.childProviderIdentityForTesting(accountId: cnAccount.id) == initialCnIdentity)
        #expect(await provider.childProviderIdentityForTesting(accountId: deAccount.id) == nil)
        await provider.shutdown()
    }

    @Test("UserHabitMemory memoizes decoded memory per UserDefaults instance and invalidates on external byte mutation (#35a)")
    func habitMemoryDecodeMemoization() throws {
        let suite = "com.jryang1997.MenuBarMijia.habit-memo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = UserHabitMemory(
            lastAction: UserHabitMemory.LastAction(
                targetId: "lamp-1",
                operationKey: "power:on",
                recordedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        memory.save(to: defaults)

        let baselineDecodes = UserHabitMemory.decodeCountForTesting
        let first = UserHabitMemory.load(from: defaults)
        let second = UserHabitMemory.load(from: defaults)
        #expect(first == second)
        #expect(UserHabitMemory.decodeCountForTesting == baselineDecodes)

        let external = UserHabitMemory(
            lastAction: UserHabitMemory.LastAction(
                targetId: "lamp-2",
                operationKey: "power:off",
                recordedAt: Date(timeIntervalSince1970: 1_800_000_060)
            )
        )
        let rawExternal = try JSONEncoder().encode(external)
        defaults.set(rawExternal, forKey: UserHabitMemory.storageKey)

        let third = UserHabitMemory.load(from: defaults)
        #expect(UserHabitMemory.decodeCountForTesting == baselineDecodes + 1)
        #expect(third.lastAction?.targetId == "lamp-2")

        let fourth = UserHabitMemory.load(from: defaults)
        #expect(UserHabitMemory.decodeCountForTesting == baselineDecodes + 1)
        #expect(fourth == third)
    }

    @MainActor
    @Test("Automatic HA LAN discovery is gated by unconfigured non-Xiaomi state and session cooldown while manual scan always runs (#35b)")
    func autoHADiscoveryGatingAndCooldown() async throws {
        let suite = "com.jryang1997.MenuBarMijia.ha-scan-gate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        defaults.set("", forKey: "ha_base_url")
        defaults.set("", forKey: "ha_token")

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        var scanCalls = 0
        store.haLANDiscoverer = { @MainActor _ in
            scanCalls += 1
            return []
        }

        #expect(store.shouldAutoDiscoverHomeAssistantOnLAN)
        await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
        #expect(scanCalls == 1)

        #expect(!store.shouldAutoDiscoverHomeAssistantOnLAN)
        await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
        #expect(scanCalls == 1)

        await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
        #expect(scanCalls == 2)

        store.lastAutoHADiscoveryAt = nil
        store.homeBackend = .xiaomiCloud
        #expect(!store.shouldAutoDiscoverHomeAssistantOnLAN)
        await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
        #expect(scanCalls == 2)
    }

    @MainActor
    @Test("HomeStore completeMiLogin and logoutMiAccount propagate account changes to activeMiAccountsProvider (#33b)")
    func homeStoreIncrementalAccountPropagation() async throws {
        let suite = "com.jryang1997.MenuBarMijia.live-mi-prop.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstAccountId = MiAccount(session: Self.session).id
        let secondSession = MiSession(
            userId: "90020002",
            cUserId: "c-de",
            ssecurity: "c2VjcmV0",
            serviceToken: "tok-de",
            region: "de"
        )
        let secondAccountId = MiAccount(session: secondSession).id
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let store = HomeStore(defaultsSuiteName: suite)
        store.completeMiLogin(Self.session)
        let activeProvider = try #require(store.activeMiAccountsProvider)
        await store.providerShutdownTask?.value
        #expect(store.activeMiProviderAccounts.map(\.id) == [firstAccountId])
        #expect(await activeProvider.childProviderIdentityForTesting(accountId: firstAccountId) != nil)

        store.completeMiLogin(secondSession)
        await store.providerShutdownTask?.value
        #expect(store.activeMiAccountsProvider === activeProvider)
        #expect(store.activeMiProviderAccounts.count == 2)
        #expect(await activeProvider.childProviderIdentityForTesting(accountId: secondAccountId) != nil)

        store.logoutMiAccount(id: secondAccountId)
        await store.providerShutdownTask?.value
        #expect(store.activeMiProviderAccounts.map(\.id) == [firstAccountId])
        #expect(await activeProvider.childProviderIdentityForTesting(accountId: secondAccountId) == nil)
        #expect(await activeProvider.childProviderIdentityForTesting(accountId: firstAccountId) != nil)
        await store.shutdown()
    }
}
