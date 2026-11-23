import CryptoKit
import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

@Suite("MiTopologyCache Encryption & Lifecycle")
struct MiTopologyCacheTests {
    private let sampleSession = MiSession(
        userId: "888812345",
        cUserId: "c-888812345",
        ssecurity: Data((0..<16).map { UInt8($0 + 1) }).base64EncodedString(),
        serviceToken: "svc-tok",
        region: "cn"
    )

    private func makeTempCache() -> (MiTopologyCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiTopologyCacheTests-\(UUID().uuidString)", isDirectory: true)
        return (MiTopologyCache(directory: dir), dir)
    }

    @Test("AES-GCM round-trip, hashed filename, POSIX modes, and tamper/key/version rejection")
    func roundTripPermissionsAndTamperRejection() throws {
        let (cache, dir) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tokenHex = "00112233445566778899aabbccddeeff"
        let topology = CachedMiTopology(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            devices: [
                MiDeviceRecord(
                    did: "101",
                    name: "Desk Lamp",
                    model: "yeelink.light.color4",
                    isOnline: true,
                    localIp: "192.168.1.50",
                    mac: "AA:BB:CC:DD:EE:FF",
                    token: tokenHex
                )
            ],
            rooms: [
                MiRoom(id: "r1", name: "Study", dids: ["101"], homeId: "h1", homeName: "Home")
            ],
            groupMembersByGroup: ["group.1": ["101"]]
        )

        cache.save(topology, for: sampleSession)
        let loaded = try #require(cache.load(for: sampleSession))
        #expect(loaded == topology)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let fileURL = try #require(files.first)
        #expect(!fileURL.lastPathComponent.contains(sampleSession.userId))
        #expect(fileURL.pathExtension == "bin")

        let rawCiphertext = try Data(contentsOf: fileURL)
        #expect(rawCiphertext.range(of: Data(tokenHex.utf8)) == nil)
        #expect(rawCiphertext.range(of: Data(sampleSession.userId.utf8)) == nil)

        #if !os(Windows)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let dirMode = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let fileMode = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((dirMode & 0o777) == 0o700)
        #expect((fileMode & 0o777) == 0o600)
        #endif

        let wrongKeySession = MiSession(
            userId: sampleSession.userId,
            cUserId: sampleSession.cUserId,
            ssecurity: Data(repeating: 0xAA, count: 16).base64EncodedString(),
            serviceToken: sampleSession.serviceToken,
            region: sampleSession.region
        )
        #expect(cache.load(for: wrongKeySession) == nil)

        var futureVersion = topology
        futureVersion.version = 99
        cache.save(futureVersion, for: sampleSession)
        #expect(cache.load(for: sampleSession) == nil)

        cache.save(topology, for: sampleSession)
        #expect(cache.load(for: sampleSession) == topology)
        var tampered = try Data(contentsOf: fileURL)
        tampered[tampered.count - 1] ^= 0x01
        try tampered.write(to: fileURL)
        #expect(cache.load(for: sampleSession) == nil)

        cache.save(topology, for: sampleSession)
        let accountID = MiAccount(session: sampleSession).id
        cache.remove(accountID: accountID)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        cache.save(topology, for: sampleSession)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @MainActor
    @Test("HomeStore logoutMiAccount(id:), logoutMiAccount(), and signOutAndRevokeAll() purge cached topologies")
    func homeStoreLogoutRemovesTopologyFiles() throws {
        let (cache, dir) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let defaults = InMemoryUserDefaults()

        let sessionA = sampleSession
        let sessionB = MiSession(
            userId: "999900001",
            cUserId: "c-999900001",
            ssecurity: Data((0..<16).map { UInt8($0 + 21) }).base64EncodedString(),
            serviceToken: "svc-tok-b",
            region: "cn"
        )
        _ = MiSessionStore.upsert(sessionA, defaults: defaults)
        _ = MiSessionStore.upsert(sessionB, defaults: defaults)

        let dummyTopology = CachedMiTopology(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            devices: [MiDeviceRecord(did: "101", name: "Lamp", model: "yeelink.light.color4", isOnline: true)],
            rooms: []
        )
        cache.save(dummyTopology, for: sessionA)
        cache.save(dummyTopology, for: sessionB)
        #expect(cache.load(for: sessionA) != nil)
        #expect(cache.load(for: sessionB) != nil)

        let store = HomeStore(
            provider: DemoHomeProvider(),
            topologyCache: cache,
            defaults: defaults
        )

        let idA = MiAccount(session: sessionA).id
        store.logoutMiAccount(id: idA)
        #expect(cache.load(for: sessionA) == nil)
        #expect(cache.load(for: sessionB) != nil)

        _ = store.logoutMiAccount()
        #expect(cache.load(for: sessionB) == nil)

        cache.save(dummyTopology, for: sessionA)
        #expect(cache.load(for: sessionA) != nil)
        _ = store.signOutAndRevokeAll()
        #expect(cache.load(for: sessionA) == nil)
    }

    @Test("LANEndpointBinding preserves broadcast-discovered IP against unchanged stale cloud IP and resets when cloud IP or token changes")
    func lanEndpointBindingReconciliation() {
        let tokA = "00112233445566778899aabbccddeeff", tokB = "112233445566778899aabbccddeeff00"
        var binding = MiCloudProvider.LANEndpointBinding(cloudIP: "192.168.1.10", discoveredIP: "192.168.1.88", token: tokA)
        #expect(binding.effectiveIP == "192.168.1.88" && binding.usedBroadcastRecovery)

        #expect(binding.reconcile(newCloudIP: "192.168.1.10", newToken: tokA) == false)
        #expect(binding.effectiveIP == "192.168.1.88" && binding.usedBroadcastRecovery)

        #expect(binding.reconcile(newCloudIP: "192.168.1.88", newToken: tokA) == false)
        #expect(binding.discoveredIP == nil && binding.effectiveIP == "192.168.1.88" && !binding.usedBroadcastRecovery)

        binding.discoveredIP = "192.168.1.99"
        #expect(binding.reconcile(newCloudIP: "192.168.1.120", newToken: tokA) == true)
        #expect(binding.discoveredIP == nil && binding.effectiveIP == "192.168.1.120")

        binding.discoveredIP = "192.168.1.130"
        #expect(binding.reconcile(newCloudIP: "192.168.1.120", newToken: tokB) == true)
        #expect(binding.discoveredIP == nil && binding.token == tokB)
    }

    @Test("Cached topology preserves cloud vs broadcast-discovered IP provenance across restarts and reads legacy v1 payloads without losing tokens")
    func cachedLANProvenanceAcrossRestartsAndLegacyCompatibility() async throws {
        let (cache, dir) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenHex = "00112233445566778899aabbccddeeff"
        let tokenData = try #require(MiIOPacket.validateToken(tokenHex))

        let accountID = MiAccount(session: sampleSession).id
        let key = SymmetricKey(data: SHA256.hash(data: Data("MenuBarHome.MiTopologyCache.v1|\(accountID)|\(sampleSession.ssecurity)".utf8)))
        let legacyJSON = Data(#"{"version":1,"savedAt":1000,"devices":[{"did":"101","name":"Lamp","model":"yeelink.light.color4","isOnline":true,"localIp":"192.168.1.40","token":"\#(tokenHex)","isShared":false}],"rooms":[{"id":"r1","name":"Study","dids":["101"],"homeId":"h1","homeName":"Home","isSharedHome":false}],"groupMembersByGroup":{"group.1":["101"]}}"#.utf8)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #require(try AES.GCM.seal(legacyJSON, using: key).combined).write(to: cache.fileURL(forAccountID: accountID))
        let legacyLoaded = try #require(cache.load(for: sampleSession))
        #expect(legacyLoaded.devices.first?.token == tokenHex && legacyLoaded.devices.first?.localIp == "192.168.1.40")
        #expect(legacyLoaded.groupMembersByGroup == ["group.1": ["101"]] && legacyLoaded.discoveredLANIPsByDid.isEmpty)

        final class Box<T>: @unchecked Sendable {
            private let lock = NSLock(); private var val: T; init(_ val: T) { self.val = val }
            func get() -> T { lock.lock(); defer { lock.unlock() }; return val }
            func set(_ v: T) { lock.lock(); val = v; lock.unlock() }
        }
        let activeIP = Box("192.168.1.88"), lanBrightness = Box(71)
        let udpTransport = MockUDPTransport { packet, host, _ in
            guard host == activeIP.get() else { throw MiIOError.timeout }
            if packet == MiIOPacket.helloPacket { return makeHelloResponse(deviceId: 101, stamp: 10) }
            let (header, plaintext) = try MiIOPacket.decode(packet, token: tokenData)
            let req = try JSONDecoder().decode(JSONValue.self, from: plaintext)
            let reply = #"{"id":\#(req["id"]?.intValue ?? 0),"result":[{"did":"101","siid":2,"piid":1,"value":true,"code":0},{"did":"101","siid":2,"piid":2,"value":\#(lanBrightness.get()),"code":0}]}"#
            return try MiIOPacket.encode(deviceId: header.deviceId, stamp: header.stamp, token: tokenData, payload: Data(reply.utf8))
        }
        await udpTransport.setBroadcastHandler { _, _, _ in [MiIOBroadcastReply(sourceIP: activeIP.get(), packet: makeHelloResponse(deviceId: 101, stamp: 20))] }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let staleRecord = MiDeviceRecord(did: "101", name: "Lamp", model: "yeelink.light.color4", isOnline: true, localIp: "192.168.1.40", token: tokenHex, isShared: false)
        let rooms = [MiRoom(id: "r1", name: "Study", dids: ["101"])]
        let api = HybridMockCloudAPI(devices: [staleRecord], rooms: rooms)
        func startSession() -> (MiCloudProvider, EventCollector, Task<Void, Never>) {
            let p = MiCloudProvider(
                sessionLoader: { self.sampleSession }, apiFactory: { _ in api },
                specSource: HybridMockSpecSource(specs: ["yeelink.light.color4": lightSpec()]),
                localClient: LocalMiIOClient(transport: udpTransport, maxRetries: 0, now: { clock.now() }), topologyCache: cache,
                lanFailureThreshold: 1, lanCooldownDuration: 30, broadcastSweepMinInterval: 60,
                now: { clock.now() }, pollInterval: .seconds(3600), closedPollInterval: .seconds(3600), deviceRefreshEveryPolls: 1, selectedHomeLoader: { nil }
            )
            let c = EventCollector()
            let t = Task { for await ev in p.events() { await c.append(ev) }; await c.finish() }
            return (p, c, t)
        }
        func wake(_ p: MiCloudProvider) async {
            await p.setPollingContext(PollingContext(panelVisible: true, systemActive: false, lowPower: false))
            await p.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))
        }

        let (p1, c1, t1) = startSession()
        #expect(await c1.wait { lightBrightness($0.snapshots.last?.devices.first) == 71 })
        #expect(await p1.lanTransportState(for: "101").effectiveIP == "192.168.1.88")
        await p1.shutdown(); t1.cancel()

        let cacheFiles = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(cacheFiles.count == 1)
        let encryptedBytes = try Data(contentsOf: cacheFiles[0])
        #expect(encryptedBytes.range(of: Data(tokenHex.utf8)) == nil && encryptedBytes.range(of: Data("192.168.1.88".utf8)) == nil)

        await api.setDiscoveryError(URLError(.notConnectedToInternet)); await api.setGetPropsError(URLError(.notConnectedToInternet))
        lanBrightness.set(78)
        let (p2, c2, t2) = startSession()
        #expect(await c2.wait { lightBrightness($0.snapshots.last?.devices.first) == 78 })
        let s2Offline = await p2.lanTransportState(for: "101")
        #expect(s2Offline.effectiveIP == "192.168.1.88" && s2Offline.usedBroadcastRecovery); #expect(await udpTransport.broadcastCalls == 1)

        clock.advance(by: 65); await api.setDiscoveryError(nil); await api.setGetPropsError(nil); lanBrightness.set(83)
        await wake(p2)
        #expect(await c2.wait { lightBrightness($0.snapshots.last?.devices.first) == 83 && $0.snapshots.last?.closesAwayGap == true })
        let s2Online = await p2.lanTransportState(for: "101")
        #expect(s2Online.effectiveIP == "192.168.1.88" && s2Online.usedBroadcastRecovery); #expect(await udpTransport.broadcastCalls == 1)
        await p2.shutdown(); t2.cancel()

        lanBrightness.set(89)
        let (p3, c3, t3) = startSession()
        #expect(await c3.wait { lightBrightness($0.snapshots.last?.devices.first) == 89 })
        #expect(await p3.lanTransportState(for: "101").effectiveIP == "192.168.1.88"); #expect(await udpTransport.broadcastCalls == 1)

        activeIP.set("192.168.1.120"); lanBrightness.set(94)
        var movedRecord = staleRecord; movedRecord.localIp = "192.168.1.120"
        await api.setTopology(devices: [movedRecord], rooms: rooms)
        await wake(p3)
        #expect(await c3.wait { lightBrightness($0.snapshots.last?.devices.first) == 94 })
        // The 94 read has two routes to the new address: the cloud device list reconciles the
        // binding to the new cloud IP, or the broadcast self-heal binds that same IP first. Only the
        // cloud reconcile clears `usedBroadcastRecovery`, so a loaded runner that answers the
        // broadcast before the device list lands samples a binding that still carries the marker.
        // Wait for the reconciled binding instead of sampling it once.
        await waitUntil {
            let state = await p3.lanTransportState(for: "101")
            return state.effectiveIP == "192.168.1.120" && !state.usedBroadcastRecovery
        }
        let finalState = await p3.lanTransportState(for: "101")
        #expect(finalState.effectiveIP == "192.168.1.120" && !finalState.usedBroadcastRecovery)
        await p3.shutdown(); t3.cancel()
    }
}
