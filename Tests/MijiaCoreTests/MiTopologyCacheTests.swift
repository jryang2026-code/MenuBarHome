import CryptoKit
import Foundation
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

        let suite = "test.topology.logout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

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
            defaultsSuiteName: suite,
            topologyCache: cache
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
        var binding = MiCloudProvider.LANEndpointBinding(
            cloudIP: "192.168.1.10",
            discoveredIP: "192.168.1.88",
            token: "00112233445566778899aabbccddeeff"
        )
        #expect(binding.effectiveIP == "192.168.1.88")
        #expect(binding.usedBroadcastRecovery == true)

        let resetOnStaleCloud = binding.reconcile(
            newCloudIP: "192.168.1.10",
            newToken: "00112233445566778899aabbccddeeff"
        )
        #expect(resetOnStaleCloud == false)
        #expect(binding.effectiveIP == "192.168.1.88")
        #expect(binding.usedBroadcastRecovery == true)

        let resetOnCaughtUpCloud = binding.reconcile(
            newCloudIP: "192.168.1.88",
            newToken: "00112233445566778899aabbccddeeff"
        )
        #expect(resetOnCaughtUpCloud == false)
        #expect(binding.discoveredIP == nil)
        #expect(binding.effectiveIP == "192.168.1.88")
        #expect(binding.usedBroadcastRecovery == false)

        binding.discoveredIP = "192.168.1.99"
        let resetOnNewCloudIP = binding.reconcile(
            newCloudIP: "192.168.1.120",
            newToken: "00112233445566778899aabbccddeeff"
        )
        #expect(resetOnNewCloudIP == true)
        #expect(binding.discoveredIP == nil)
        #expect(binding.effectiveIP == "192.168.1.120")

        binding.discoveredIP = "192.168.1.130"
        let resetOnNewToken = binding.reconcile(
            newCloudIP: "192.168.1.120",
            newToken: "112233445566778899aabbccddeeff00"
        )
        #expect(resetOnNewToken == true)
        #expect(binding.discoveredIP == nil)
        #expect(binding.token == "112233445566778899aabbccddeeff00")
    }
}
