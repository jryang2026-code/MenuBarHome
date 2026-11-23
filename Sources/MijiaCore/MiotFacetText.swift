import Foundation

/// Display text for a generic facet, shared by the card's readouts and the 更多设置 drawer (#5, #6).
/// Keeping it in `MijiaCore` means the synthesized card and the drawer cannot format the same
/// value differently.
public enum MiotFacetText {
    public static func title(name: String, title: String?) -> String {
        // Common MIoT short names live in `Shared/deviceLabels.json`; a localized title there
        // beats the spec's vendor description.
        if !L10n.isEnglish, let chinese = DeviceLabels.shared.title(forFacet: name) {
            return chinese
        }
        let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? humanized(name) : raw
    }

    public static func humanized(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "-", with: " ")
        guard let first = words.first else { return raw }
        return first.uppercased() + String(words.dropFirst())
    }

    public static func value(_ control: FacetControl) -> String {
        value(
            kind: control.kind,
            value: control.value,
            unit: control.unit,
            scale: control.scale,
            options: control.options
        )
    }

    public static func value(
        kind: MiotFacetKind,
        value: JSONValue?,
        unit: String?,
        scale: Double?,
        options: [MiotFacetOption]
    ) -> String {
        if let raw = value?.intValue, let option = options.first(where: { $0.value == raw }) {
            return MiotValueText.display(option.label)
        }
        if kind == .toggle {
            return value?.miotBool == true ? L10n.tr("开", "On") : L10n.tr("关", "Off")
        }
        guard let raw = value?.doubleValue else {
            if let isOn = value?.miotBool {
                return isOn ? L10n.tr("开", "On") : L10n.tr("关", "Off")
            }
            if let text = value?.stringValue { return text }
            return "—"
        }
        let scaled = raw * (scale ?? 1)
        if kind == .reading, unit?.lowercased() == "celsius" {
            return L10n.temperature(scaled, fractionDigits: 1)
        }
        return number(scaled) + unitSuffix(unit)
    }

    private static func number(_ value: Double) -> String {
        if value.rounded() == value, let exact = Int(exactly: value) { return "\(exact)" }
        return String(format: "%.1f", value)
    }

    private static func unitSuffix(_ raw: String?) -> String {
        let unit = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !unit.isEmpty, unit.lowercased() != "none" else { return "" }
        switch unit.lowercased() {
        case "celsius": return L10n.isEnglish ? " °C" : "°C"
        case "percentage", "percent": return "%"
        case "ppm": return " ppm"
        case "lux": return " lx"
        case "minutes": return MiotValueText.spacedUnit(hans: "分钟", hant: "分鐘", en: "min")
        case "seconds": return MiotValueText.spacedUnit(hans: "秒", hant: "秒", en: "s")
        case "hour", "hours": return MiotValueText.spacedUnit(hans: "小时", hant: "小時", en: "h")
        default: return " \(unit)"
        }
    }

    /// The locked control a person can open to deal with this alert, when one is still read-only.
    /// An alert with no locked control returns nil, so the banner does not offer a dead end.
    public static func lockedControlID(
        forAlert alert: String,
        controls: [FacetControl],
        allowsAdvancedWrites: Bool
    ) -> String? {
        guard let source = controls.first(where: { alertSentences($0).contains(alert) }) else { return nil }
        let stem = relatedControlName(source.name)
        let locked = controls.filter { isAdvancedWriteLocked($0, allowsAdvancedWrites: allowsAdvancedWrites) }
        if let match = locked.first(where: { $0.name == stem }) { return match.id }
        if let match = locked.first(where: {
            $0.serviceName == source.serviceName && $0.name == "on"
        }) {
            return match.id
        }
        return nil
    }

    /// Every wording synthesis may have stored for this reading. The banner keeps the sentence
    /// from the language that was current then, so the match cannot use only the language now.
    private static func alertSentences(_ control: FacetControl) -> [String] {
        guard control.kind == .reading,
              let raw = control.value?.intValue,
              let option = control.options.first(where: { $0.value == raw }),
              MiotFacetEngine.isAlertLabel(option.label) else { return [] }
        return [AppLanguage.zhHans, .zhHant, .en].map { language in
            L10n.$overrideLanguage.withValue(language) {
                let name = title(name: control.name, title: control.title)
                return MiotFacetEngine.alertText(
                    title: name,
                    propertyName: control.name,
                    label: option.label
                )
            }
        }
    }

    /// The high-risk explanation. It is true only when every writable facet still needs the
    /// advanced-write opt-in. A facet that writes by default means the device is not view-only.
    public static func showsAdvancedViewOnlyCopy(
        controls: [FacetControl],
        allowsAdvancedWrites: Bool
    ) -> Bool {
        let writable = controls.filter(\.isWritable)
        guard !writable.isEmpty else { return false }
        return writable.allSatisfy { isAdvancedWriteLocked($0, allowsAdvancedWrites: allowsAdvancedWrites) }
    }

    private static func relatedControlName(_ name: String) -> String {
        for suffix in ["-status", "-alarm", "-fault"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// True when the row is writable in the spec but the advanced-write opt-in still blocks it.
    /// Callers keep using this for presentation. It does not decide whether a write is sent.
    public static func isAdvancedWriteLocked(
        _ control: FacetControl,
        allowsAdvancedWrites: Bool
    ) -> Bool {
        guard control.isWritable, !allowsAdvancedWrites else { return false }
        return !control.writesByDefault && !control.isConfirmedWrite
    }
}
