import Foundation
import Testing
@testable import MijiaCore

@Suite("MIoT spec status=all, specPatches.json, and LAN pid filter")
struct MiotSpecContractTests {
    private static func repoFile(_ relative: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let file = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("parseInstanceIndex prefers released > omitted > preview > debug and highest version within status")
    func parseInstanceIndexPriorities() {
        let payload = Data(#"""
        {"instances":[
            {"model":"acme.ac.v1","version":3,"status":"debug","type":"urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:3"},
            {"model":"acme.ac.v1","version":1,"status":"released","type":"urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:1"},
            {"model":"acme.ac.v1","version":2,"status":"released","type":"urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:2"},
            {"model":"acme.kettle.dbg","version":1,"status":"debug","type":"urn:miot-spec-v2:device:kettle:0000A009:acme-dbg:1"},
            {"model":"acme.fresh.mix","version":4,"status":"debug","type":"urn:miot-spec-v2:device:air-fresh:0000A012:acme-mix:4"},
            {"model":"acme.fresh.mix","version":1,"status":"preview","type":"urn:miot-spec-v2:device:air-fresh:0000A012:acme-mix:1"}
        ]}
        """#.utf8)

        let index = MiotSpecStore.parseInstanceIndex(payload)
        #expect(index["acme.ac.v1"] == "urn:miot-spec-v2:device:air-conditioner:0000A004:acme-v1:2")
        #expect(index["acme.kettle.dbg"] == "urn:miot-spec-v2:device:kettle:0000A009:acme-dbg:1")
        #expect(index["acme.fresh.mix"] == "urn:miot-spec-v2:device:air-fresh:0000A012:acme-mix:1")
    }

    @Test("MiotSpecStore fetches status=all, isolates v2 cache from legacy miot-instances.json, and falls back to status=released")
    func statusAllFetchFallbackAndCacheVersion() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecV2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // A fresh legacy status=released cache must NOT prevent fetching status=all.
        let legacyFile = cacheDir.appendingPathComponent("miot-instances.json")
        try Data(#"{"instances":[{"model":"legacy.only","version":1,"status":"released","type":"urn:miot-spec-v2:device:light:0000A001:legacy:1"}]}"#.utf8)
            .write(to: legacyFile)

        let debugUrn = "urn:miot-spec-v2:device:kettle:0000A009:yunmi-v1:1"
        let kettleSpec = #"{"type":"urn:miot-spec-v2:device:kettle:0000A009:yunmi-v1:1","services":[{"iid":2,"type":"urn:miot-spec-v2:service:kettle:00007813:yunmi-v1:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:temperature:00000020:yunmi-v1:1","format":"float","access":["read"]}]}]}"#

        let seenURLs = ScriptedTransport.URLRecorder()
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            seenURLs.append(url)
            if url.contains("instances?status=all") {
                return (200, [:], #"{"instances":[{"model":"yunmi.kettle.v1","version":1,"status":"debug","type":"urn:miot-spec-v2:device:kettle:0000A009:yunmi-v1:1"}]}"#)
            }
            if url.contains("instance?type=") {
                return (200, [:], kettleSpec)
            }
            return (404, [:], "")
        }

        let store = MiotSpecStore(transport: transport, cacheDirectory: cacheDir)
        let resolved = try await store.spec(model: "yunmi.kettle.v1", specType: nil)
        #expect(resolved?.type == debugUrn)
        #expect(seenURLs.values.contains { $0.contains("instances?status=all") })
        #expect(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(MiotSpecStore.indexCacheFileName).path))

        // When status=all is unavailable across mirrors, fall back to status=released.
        let fallbackDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fallbackDir) }

        let fallbackURLs = ScriptedTransport.URLRecorder()
        let fallbackTransport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            fallbackURLs.append(url)
            if url.contains("instances?status=all") {
                return (503, [:], "unavailable")
            }
            if url.contains("instances?status=released") {
                return (200, [:], #"{"instances":[{"model":"yunmi.kettle.v1","version":1,"status":"released","type":"urn:miot-spec-v2:device:kettle:0000A009:yunmi-v1:1"}]}"#)
            }
            return (200, [:], kettleSpec)
        }
        let fallbackStore = MiotSpecStore(transport: fallbackTransport, cacheDirectory: fallbackDir)
        let fallbackSpec = try await fallbackStore.spec(model: "yunmi.kettle.v1", specType: nil)
        #expect(fallbackSpec?.type == debugUrn)
        #expect(fallbackURLs.values.contains { $0.contains("instances?status=all") })
        #expect(fallbackURLs.values.contains { $0.contains("instances?status=released") })
    }

    @Test("Bundled specPatches.json matches Shared/specPatches.json byte-for-byte")
    func bundledSpecPatchesMatchShared() throws {
        let shared = try Self.repoFile("Shared/specPatches.json")
        let bundled = try #require(MiotSpecPatches.bundledData())
        #expect(bundled == shared)
        #expect(MiotSpecPatches.shared.schemaVersion == MiotSpecPatches.supportedSchemaVersion)
    }

    @Test("specPatches golden fixture produces identical patched spec and is idempotent")
    func specPatchesGoldenFixture() async throws {
        struct Golden: Decodable {
            let model: String
            let patches: MiotSpecPatches
            let input: MiotDeviceSpec
            let expected: MiotDeviceSpec
        }
        let fixtureData = try Self.repoFile("Tests/Fixtures/spec_patches_golden.json")
        let golden = try JSONDecoder().decode(Golden.self, from: fixtureData)

        let patched = golden.patches.apply(to: golden.input, model: golden.model)
        #expect(patched == golden.expected)
        #expect(golden.patches.apply(to: patched, model: golden.model) == golden.expected)

        // Also verify MiotSpecStore applies patches end-to-end when returning a resolved spec.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotSpecPatchStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let inputJSON = String(decoding: try JSONEncoder().encode(golden.input), as: UTF8.self)
        let store = MiotSpecStore(
            transport: ScriptedTransport { _ in (200, [:], inputJSON) },
            cacheDirectory: cacheDir,
            patches: golden.patches
        )
        let viaStore = try await store.spec(model: golden.model, specType: golden.input.type)
        #expect(viaStore == golden.expected)
    }

    @Test("LAN pid filter allows [0, 8, 12, 23] and nil, excludes non-LAN pids")
    func lanEligiblePIDFilter() {
        for pid in [0, 8, 12, 23] {
            #expect(LocalMiIOClient.isLANEligiblePID(pid))
        }
        #expect(LocalMiIOClient.isLANEligiblePID(nil))
        for pid in [3, 6, 7, 15, 16, 17, 21] {
            #expect(!LocalMiIOClient.isLANEligiblePID(pid))
        }
    }
}

private extension ScriptedTransport {
    final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ url: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(url)
        }
        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}
