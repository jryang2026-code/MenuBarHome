import Foundation

/// Official MIoT `instance/v2/multiLanguage` document (`{"data":{"zh_cn":{...}},"timestamp":"..."}`).
/// Keys are `service:<siid>`, `service:<siid>:property:<piid>` and
/// `service:<siid>:property:<piid>:valuelist:<index>`; the value-list suffix is the 0-based
/// position in the spec's `value-list`, not the property value.
public struct MiotSpecMultiLanguage: Codable, Equatable, Sendable {
    public var data: [String: [String: String]]
    public var timestamp: String?

    enum CodingKeys: String, CodingKey { case data, timestamp }

    public init(data: [String: [String: String]] = [:], timestamp: String? = nil) {
        self.data = data
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? c.decode([String: [String: String]].self, forKey: .data)) ?? [:]
        timestamp = try? c.decode(String.self, forKey: .timestamp)
    }
}

/// Applies official descriptions to a resolved spec. Pure: the cached spec is never mutated, so a
/// language change takes effect on the next resolution. `Shared/specPatches.json` is applied by the
/// caller *after* this step and therefore keeps priority.
public enum MiotSpecLocalization {
    /// Chinese UI prefers the locale's own table, then the other Chinese table, then English.
    /// English UI never picks up a Chinese description.
    public static func languageKeys(for language: AppLanguage) -> [String] {
        if language == .zhHant { return ["zh_tw", "zh_cn", "en"] }
        if language == .zhHans { return ["zh_cn", "en"] }
        return ["en"]
    }

    private static func padded(_ value: Int) -> String {
        let digits = String(max(0, value))
        return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }

    public static func serviceKey(_ siid: Int) -> String { "service:\(padded(siid))" }

    public static func propertyKey(service siid: Int, property piid: Int) -> String {
        "\(serviceKey(siid)):property:\(padded(piid))"
    }

    public static func valueListKey(service siid: Int, property piid: Int, index: Int) -> String {
        "\(propertyKey(service: siid, property: piid)):valuelist:\(padded(index))"
    }

    public static func apply(
        to spec: MiotDeviceSpec,
        translations: MiotSpecMultiLanguage?,
        language: AppLanguage
    ) -> MiotDeviceSpec {
        guard let translations, !translations.data.isEmpty else { return spec }
        let chain = languageKeys(for: language)

        func label(_ key: String) -> String? {
            for lang in chain {
                if let value = translations.data[lang]?[key], !value.isEmpty { return value }
            }
            return nil
        }

        var updated = spec
        updated.services = spec.services.map { service in
            var result = service
            if let text = label(serviceKey(service.iid)) { result.description = text }
            result.properties = service.properties.map { property in
                var result = property
                let key = propertyKey(service: service.iid, property: property.iid)
                if let text = label(key) { result.description = text }
                if let list = property.valueList {
                    result.valueList = list.enumerated().map { index, item in
                        var item = item
                        if let text = label(valueListKey(service: service.iid, property: property.iid, index: index)) {
                            item.description = text
                        }
                        return item
                    }
                }
                return result
            }
            return result
        }
        return updated
    }
}
