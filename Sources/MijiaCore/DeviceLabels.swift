import Foundation

/// One title from `Shared/deviceLabels.json`. Traditional Chinese stays in
/// `Resources/Localizations/zh-Hant.json`, keyed by the Simplified text, like every other label.
public struct DeviceLabelTitle: Codable, Equatable, Sendable {
    public let zhHans: String
    public let en: String

    enum CodingKeys: String, CodingKey {
        case zhHans = "zh-Hans"
        case en
    }
}

/// A device type's titles and its semantic icon id. `chair` and `bike` only ever contributed an
/// icon, so their title is absent.
public struct DeviceTypeLabel: Codable, Equatable, Sendable {
    public let zhHans: String?
    public let en: String?
    /// Neutral icon vocabulary (`fish`, `tv`), never a platform glyph. `DeviceIconSymbols` turns it
    /// into an SF Symbol here and `windows/src/core/deviceIconSymbols.ts` does the same on Windows.
    public let icon: String?

    enum CodingKeys: String, CodingKey {
        case zhHans = "zh-Hans"
        case en, icon
    }
}

/// `Shared/deviceLabels.json` decoded once (#11). Both platforms read the same document: Windows
/// imports it through `windows/src/core/deviceLabels.ts`, macOS ships a byte-identical copy in
/// `Resources/` and loads it here. The document carries the two facet groups the Windows card
/// distinguishes; macOS has always shown one merged list, so `title(forFacet:)` reads both.
public struct DeviceLabels: Decodable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    public let schemaVersion: Int
    public let defaultIcon: String
    public let facetTitles: [String: DeviceLabelTitle]
    public let familyFacetTitles: [String: DeviceLabelTitle]
    public let deviceTypes: [String: DeviceTypeLabel]

    public static let shared: DeviceLabels = {
        guard let data = bundledData(), let labels = try? JSONDecoder().decode(DeviceLabels.self, from: data) else {
            preconditionFailure("deviceLabels.json is missing from the MijiaCore bundle")
        }
        guard labels.schemaVersion == supportedSchemaVersion else {
            preconditionFailure("deviceLabels.json schemaVersion \(labels.schemaVersion) is not \(supportedSchemaVersion)")
        }
        return labels
    }()

    /// Simplified Chinese title for a MIoT property or action short name, if the shared file lists it.
    public func title(forFacet name: String) -> String? {
        (facetTitles[name] ?? familyFacetTitles[name])?.zhHans
    }

    /// Simplified Chinese title for a MIoT device type (`fish-tank`), if the shared file lists it.
    public func title(forDeviceType type: String) -> String? {
        deviceTypes[type]?.zhHans
    }

    /// The device type's neutral icon id, falling back to the document's own default.
    public func semanticIcon(forDeviceType type: String) -> String {
        deviceTypes[type]?.icon ?? defaultIcon
    }

    /// Bytes of the bundled document, so a test can prove it matches `Shared/deviceLabels.json`.
    /// Resolved through runtime bundle paths only: a compile-time source-location fallback would
    /// write the build machine's checkout into the release binary, which `scripts/build_app.sh`
    /// rejects (#275).
    static func bundledData() -> Data? {
        var urls: [URL] = []
        #if !os(macOS)
        if let url = Bundle.module.url(forResource: "deviceLabels", withExtension: "json", subdirectory: "Resources") {
            urls.append(url)
        }
        if let url = Bundle.module.url(forResource: "deviceLabels", withExtension: "json") {
            urls.append(url)
        }
        if let root = Bundle.module.resourceURL {
            urls.append(root.appendingPathComponent("Resources/deviceLabels.json"))
            urls.append(root.appendingPathComponent("deviceLabels.json"))
        }
        #endif
        for base in L10n.translationSearchBases {
            urls.append(base.appendingPathComponent("Resources/deviceLabels.json"))
            urls.append(base.appendingPathComponent("deviceLabels.json"))
            for name in L10n.resourceDirectoryNames(in: base) {
                let bundle = base.appendingPathComponent(name)
                urls.append(bundle.appendingPathComponent("Resources/deviceLabels.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/Resources/deviceLabels.json"))
                urls.append(bundle.appendingPathComponent("Contents/Resources/deviceLabels.json"))
                urls.append(bundle.appendingPathComponent("deviceLabels.json"))
            }
        }
        for url in urls {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }
}

/// Semantic icon id (`Shared/deviceLabels.json`) → SF Symbol name. The shared document never
/// stores a platform glyph; this switch is macOS's own mapping.
enum DeviceIconSymbols {
    static let genericSymbol = "square.grid.2x2"

    static func sfSymbol(for icon: String) -> String {
        switch icon {
        case "bed": return "bed.double.fill"
        case "bike": return "bicycle"
        case "car-seat": return "car.fill"
        case "clock": return "clock.fill"
        case "coffee": return "cup.and.saucer.fill"
        case "drop": return "drop.fill"
        case "fish": return "fish.fill"
        case "generic": return "square.grid.2x2"
        case "location": return "location.fill"
        case "lock": return "lock.fill"
        case "mirror": return "rectangle.portrait.fill"
        case "pawprint": return "pawprint.fill"
        case "projector": return "projector.fill"
        case "scale": return "scalemass.fill"
        case "seat": return "chair.lounge.fill"
        case "toothbrush": return "mouth.fill"
        case "treadmill": return "figure.run"
        case "tv": return "tv"
        case "watch": return "applewatch"
        case "water": return "water.waves"
        case "wifi": return "wifi"
        default: return genericSymbol
        }
    }
}
