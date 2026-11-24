import Foundation
import Testing
@testable import MijiaCore

@Suite("MIoT official multiLanguage cache and card labels")
struct MiotSpecMultiLanguageTests {
    struct Golden: Decodable {
        let urn: String
        let model: String
        let spec: MiotDeviceSpec
        let multiLanguage: MiotSpecMultiLanguage
        let expected: [String: [String: String]]
        let patches: MiotSpecPatches
        let patchedLabel: String
    }

    private static func repoFile(_ relative: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let file = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixture() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: repoFile("Tests/Fixtures/miot_multi_language_golden.json"))
    }

    private static func labels(_ spec: MiotDeviceSpec) -> [String: String] {
        var out: [String: String] = [:]
        for service in spec.services {
            if let text = service.description { out[MiotSpecLocalization.serviceKey(service.iid)] = text }
            for property in service.properties {
                if let text = property.description {
                    out[MiotSpecLocalization.propertyKey(service: service.iid, property: property.iid)] = text
                }
                for (index, item) in (property.valueList ?? []).enumerated() {
                    out[MiotSpecLocalization.valueListKey(
                        service: service.iid, property: property.iid, index: index
                    )] = item.description
                }
            }
        }
        return out
    }

    @Test("shared golden fixture labels match on both platforms and patches still win")
    func goldenFixture() throws {
        let golden = try Self.fixture()
        for (tag, expected) in golden.expected {
            let language = AppLanguage(rawValue: tag)
            let translated = MiotSpecLocalization.apply(
                to: golden.spec, translations: golden.multiLanguage, language: language
            )
            #expect(Self.labels(translated) == expected)
            let patched = golden.patches.apply(to: translated, model: golden.model)
            #expect(Self.labels(patched)["service:002:property:001"] == golden.patchedLabel)
            #expect(golden.spec.services.first?.description == "Device Information")
        }
        #expect(MiotSpecLocalization.valueListKey(service: 2, property: 2, index: 0)
            == "service:002:property:002:valuelist:000")
    }

    @Test("store fetches multiLanguage only with the spec and caches it under a versioned key")
    func fetchesAlongsideSpecAndCaches() async throws {
        let golden = try Self.fixture()
        let specJSON = String(decoding: try JSONEncoder().encode(golden.spec), as: UTF8.self)
        let languageJSON = String(decoding: try JSONEncoder().encode(golden.multiLanguage), as: UTF8.self)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotMultiLanguage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let transport = ScriptedTransport { request in
            let url = request.url!.absoluteString
            if url.contains("/instance?type=") { return (200, [:], specJSON) }
            if url.contains("/instance/v2/multiLanguage?urn=") { return (200, [:], languageJSON) }
            return (404, [:], "")
        }
        let store = MiotSpecStore(transport: transport, cacheDirectory: cacheDir)
        let resolved = try await L10n.$overrideLanguage.withValue(.zhHans) {
            try await store.spec(model: golden.model, specType: golden.urn)
        }
        #expect(Self.labels(resolved!) == golden.expected["zh-Hans"])
        #expect(transport.requests.contains {
            $0.url!.absoluteString.contains("/instance/v2/multiLanguage?urn=")
        })
        let safeName = golden.urn.replacingOccurrences(of: ":", with: "_") + ".json"
        #expect(FileManager.default.fileExists(atPath: cacheDir
            .appendingPathComponent("multiLanguage-v1/\(safeName)").path))

        // A fresh spec cache must not trigger a standalone translation request.
        let count = transport.requests.count
        _ = try await store.spec(model: golden.model, specType: golden.urn)
        #expect(transport.requests.count == count)
    }

    @Test("translation failure never blocks the spec and offline refresh reuses stale caches")
    func staleCacheAndFailureIsolation() async throws {
        let golden = try Self.fixture()
        let specJSON = String(decoding: try JSONEncoder().encode(golden.spec), as: UTF8.self)
        let languageJSON = String(decoding: try JSONEncoder().encode(golden.multiLanguage), as: UTF8.self)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiotMultiLanguageStale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let brokenTranslations = ScriptedTransport { request in
            let url = request.url!.absoluteString
            if url.contains("/instance?type=") { return (200, [:], specJSON) }
            if url.contains("/instance/v2/multiLanguage?urn=") { return (503, [:], "unavailable") }
            return (404, [:], "")
        }
        let first = MiotSpecStore(transport: brokenTranslations, cacheDirectory: cacheDir, specMaxAge: 0)
        let raw = try await first.spec(model: golden.model, specType: golden.urn)
        #expect(raw?.type == golden.urn)
        #expect(Self.labels(raw!) == Self.labels(golden.spec))

        let online = ScriptedTransport { request in
            let url = request.url!.absoluteString
            if url.contains("/instance?type=") { return (200, [:], specJSON) }
            if url.contains("/instance/v2/multiLanguage?urn=") { return (200, [:], languageJSON) }
            return (404, [:], "")
        }
        let refreshed = MiotSpecStore(transport: online, cacheDirectory: cacheDir, specMaxAge: 0)
        _ = try await refreshed.spec(model: golden.model, specType: golden.urn)

        let offline = ScriptedTransport { _ in throw URLError(.notConnectedToInternet) }
        let staleStore = MiotSpecStore(transport: offline, cacheDirectory: cacheDir, specMaxAge: 0)
        let stale = try await L10n.$overrideLanguage.withValue(.zhHans) {
            try await staleStore.spec(model: golden.model, specType: golden.urn)
        }
        #expect(Self.labels(stale!) == golden.expected["zh-Hans"])
    }
}
