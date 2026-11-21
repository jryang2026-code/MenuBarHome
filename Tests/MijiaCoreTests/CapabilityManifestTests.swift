import Foundation
import Testing
@testable import MijiaCore

struct CapabilityManifestTests {
    private struct DocsCapabilities: Decodable {
        struct Row: Decodable { let id: String }
        let rows: [Row]
    }

    @Test("Shared capability manifest parses cleanly and matches docs/capabilities.json")
    func sharedManifestMatchesDocsMatrix() throws {
        let manifest = try CapabilityManifest.parse(from: loadRepoData("Shared/capability-manifest.json"))
        let docs = try JSONDecoder().decode(DocsCapabilities.self, from: loadRepoData("docs/capabilities.json"))
        let docIDs = Set(docs.rows.map(\.id))

        #expect(CapabilityManifest.shared == manifest)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.entries.count == CapabilityID.allCases.count)
        #expect(manifest.entry(for: .feature(.cameraLive)).dependsOn == [.deviceCategory(.camera)])
        #expect(manifest.entry(for: .connection(.xiaomiCloud)).defaultOnFreshInstall == false)
        #expect(manifest.entry(for: .connection(.homeAssistant)).defaultOnFreshInstall == false)
        #expect(manifest.entry(for: .feature(.voiceInput)).defaultOnFreshInstall == false)
        #expect(manifest.entry(for: .deviceCategory(.light)).defaultOnFreshInstall == true)

        var covered = Set(manifest.hostCoreCapabilityMatrixIds)
        for entry in manifest.entries {
            covered.formUnion(entry.capabilityMatrix.rowIds)
            for rowID in entry.capabilityMatrix.rowIds { #expect(docIDs.contains(rowID)) }
        }
        #expect(covered.isSubset(of: docIDs))
    }

    @Test("HomeBackend and DeviceKind mappings round-trip exhaustively")
    func exhaustiveDomainMappings() {
        for conn in ConnectionCapabilityID.allCases { #expect(conn.homeBackend.connectionCapabilityID == conn) }
        #expect(HomeBackend.demo.connectionCapabilityID == nil)
        let demoCategories = Set(DemoHomeProvider.defaultHome().devices.map(\.capabilityCategoryID))
        #expect(demoCategories.isSuperset(of: [.light, .climate, .camera]))
        #expect(DeviceKind.humidifier(HumidifierSpec(entityId: "humidifier.room", isOn: true, targetHumidity: 50)).capabilityCategoryID == .fan)
        #expect(DeviceKind.valve(ValveSpec(entityId: "valve.water", isOpen: false)).capabilityCategoryID == .valve)
        for category in DeviceCategoryID.allCases { #expect(category.primaryListCutTag.rank >= 1) }
    }

    @Test("Parser rejects unknown IDs, duplicate IDs, cycles, missing entries, and forbidden keys")
    func parserRejectsInvalidManifests() throws {
        let base = try loadRepoData("Shared/capability-manifest.json")

        #expect(throws: CapabilityManifestError.unknownCapabilityID("third-party-plugin")) {
            _ = try CapabilityManifest.parse(from: try mutate(base) { caps in
                var extra = caps[0]; extra["id"] = "third-party-plugin"; caps.append(extra)
            })
        }
        #expect(throws: CapabilityManifestError.duplicateCapabilityID("xiaomi-cloud")) {
            _ = try CapabilityManifest.parse(from: try mutate(base) { caps in caps.append(caps[0]) })
        }
        #expect(throws: CapabilityManifestError.dependencyCycle([.feature(.voiceInput), .feature(.aiAssistant), .feature(.voiceInput)])) {
            _ = try CapabilityManifest.parse(from: try mutate(base) { caps in
                caps[2]["dependsOn"] = ["ai-assistant"]; caps[3]["dependsOn"] = ["voice-input"]
            })
        }
        #expect(throws: CapabilityManifestError.missingCapabilities([.deviceCategory(.generic)])) {
            _ = try CapabilityManifest.parse(from: try mutate(base) { caps in _ = caps.popLast() })
        }
        #expect(throws: CapabilityManifestError.invalidDefaultDependency(id: .feature(.cameraLive), dependency: .deviceCategory(.camera))) {
            _ = try CapabilityManifest.parse(from: try mutate(base) { caps in
                for i in caps.indices where caps[i]["id"] as? String == "camera" { caps[i]["defaultOnFreshInstall"] = false }
            })
        }
        #expect(throws: CapabilityManifestError.unexpectedKeys(scope: "capabilities[0]", keys: ["hazardLevel"])) {
            _ = try CapabilityManifest.parse(from: try mutate(base) { caps in caps[0]["hazardLevel"] = "critical" })
        }
    }

    private func mutate(_ data: Data, edit: (inout [[String: Any]]) -> Void) throws -> Data {
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var caps = try #require(root["capabilities"] as? [[String: Any]])
        edit(&caps)
        root["capabilities"] = caps
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test("Production sources carry no compile-time file paths into the release binary")
    func productionSourcesHaveNoCompileTimeFilePaths() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Shared/capability-manifest.json").path) {
            dir.deleteLastPathComponent()
        }
        let sources = dir.appendingPathComponent("Sources")
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("#filePath") || line.contains("= #file") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        // `scripts/build_app.sh` rejects a release binary containing "/Users/"; a compile-time
        // `#filePath` fallback is how that path gets in (#275).
        #expect(offenders.isEmpty, "compile-time file paths in production sources: \(offenders)")
        #expect(CapabilityManifest.bundledData() != nil)
    }

    private func loadRepoData(_ relative: String) throws -> Data {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Shared/capability-manifest.json").path) {
                return try Data(contentsOf: dir.appendingPathComponent(relative))
            }
            dir.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
