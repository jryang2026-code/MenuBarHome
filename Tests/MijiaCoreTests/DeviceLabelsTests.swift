import Foundation
import Testing
@testable import MijiaCore

/// #11: facet and device-type labels moved into `Shared/deviceLabels.json`. `Tests/Fixtures/
/// device_labels_golden.json` was exported from the old tables before they were deleted, so this
/// suite proves the migration changed no title and no glyph in any language. Windows reads its own
/// `windows` section of the same fixture: the two ends localize some labels differently and this
/// refactor must keep each end exactly as it was.
struct DeviceLabelsTests {
    private struct Golden: Decodable {
        struct Titles: Decodable {
            let zhHans: String
            let zhHant: String
            let en: String

            enum CodingKeys: String, CodingKey {
                case zhHans = "zh-Hans"
                case zhHant = "zh-Hant"
                case en
            }
        }

        struct Platform: Decodable {
            let facetTitles: [String: Titles]
            let deviceTypes: [String: Titles?]
        }

        let version: Int
        let defaultSymbol: String
        let symbols: [String: String]
        let macos: Platform
    }

    private func repoFile(_ relative: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let file = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: repoFile("Tests/Fixtures/device_labels_golden.json"))
    }

    private func inLanguage(_ language: AppLanguage, _ body: () -> String) -> String {
        L10n.$overrideLanguage.withValue(language) { body() }
    }

    private func spec(forDeviceType deviceType: String) -> MiotDeviceSpec {
        MiotDeviceSpec(type: "urn:miot-spec-v2:device:\(deviceType):0000A001:1", services: [])
    }

    @Test("Bundled deviceLabels.json loads and matches the shared document byte for byte")
    func bundledCopyMatchesSharedDocument() throws {
        let shared = try repoFile("Shared/deviceLabels.json")
        let bundled = try repoFile("Sources/MijiaCore/Resources/deviceLabels.json")
        #expect(shared == bundled)
        #expect(DeviceLabels.shared.schemaVersion == DeviceLabels.supportedSchemaVersion)
        #expect(DeviceLabels.shared.facetTitles.count == 41)
        #expect(DeviceLabels.shared.familyFacetTitles.count == 42)
        #expect(DeviceLabels.shared.deviceTypes.count == 32)
    }

    @Test("Every facet title matches the pre-migration table in Chinese and English")
    func facetTitlesMatchGolden() throws {
        let golden = try golden()
        #expect(golden.version == 1)
        #expect(golden.macos.facetTitles.count == 83)
        for (name, expected) in golden.macos.facetTitles {
            let comment = Comment(rawValue: name)
            #expect(inLanguage(.zhHans) { MiotFacetText.title(name: name, title: nil) } == expected.zhHans, comment)
            #expect(inLanguage(.zhHant) { MiotFacetText.title(name: name, title: nil) } == expected.zhHant, comment)
            #expect(inLanguage(.en) { MiotFacetText.title(name: name, title: nil) } == expected.en, comment)
        }
    }

    @Test("Every device-type title and symbol matches the pre-migration table")
    func deviceTypesMatchGolden() throws {
        let golden = try golden()
        #expect(golden.macos.deviceTypes.count == 32)
        for (deviceType, expected) in golden.macos.deviceTypes {
            let comment = Comment(rawValue: deviceType)
            let model = spec(forDeviceType: deviceType)
            if let expected {
                #expect(inLanguage(.zhHans) { MiotSynthesizer.genericTypeTitle(for: model) } == expected.zhHans, comment)
                #expect(inLanguage(.zhHant) { MiotSynthesizer.genericTypeTitle(for: model) } == expected.zhHant, comment)
                #expect(inLanguage(.en) { MiotSynthesizer.genericTypeTitle(for: model) } == expected.en, comment)
            } else {
                // `chair` and `bike` only ever contributed an icon, so the name is humanized.
                let humanized = MiotFacetText.humanized(deviceType)
                #expect(inLanguage(.zhHans) { MiotSynthesizer.genericTypeTitle(for: model) } == humanized, comment)
                #expect(inLanguage(.en) { MiotSynthesizer.genericTypeTitle(for: model) } == humanized, comment)
            }
            #expect(MiotSynthesizer.genericSymbolName(for: deviceType) == golden.symbols[deviceType], comment)
        }
        #expect(MiotSynthesizer.genericSymbolName(for: "unknown-device-type") == golden.defaultSymbol)
    }

    @Test("An unlisted facet still falls back to the spec description, then the humanized name")
    func unlistedFacetKeepsFallback() {
        #expect(MiotFacetText.title(name: "vendor-only", title: " Vendor Name ") == "Vendor Name")
        #expect(MiotFacetText.title(name: "vendor-only", title: nil) == "Vendor only")
    }
}
