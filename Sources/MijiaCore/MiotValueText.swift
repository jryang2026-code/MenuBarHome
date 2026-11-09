import Foundation

/// How a MIoT value-list description is shown. The spec keeps the vendor's English word, because
/// that word is what a write sends. This table only changes the text a person reads.
public enum MiotValueText {
    public struct FaultNotice: Equatable, Sendable {
        /// The sentence in the fault banner.
        public var message: String
        /// The text the copy button places on the pasteboard. A code when the spec published one.
        public var copyText: String

        public init(message: String, copyText: String) {
            self.message = message
            self.copyText = copyText
        }
    }

    /// English passes through. Simplified and Traditional Chinese use the table, then `LevelN`.
    public static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MiotDisplayScript.current != .en else { return trimmed }
        let key = normalize(trimmed)
        if let phrase = programmes[key] {
            return MiotDisplayScript.current == .hant ? phrase.hant : phrase.hans
        }
        if let level = levelNumber(key) {
            return MiotDisplayScript.current == .hant ? "\(level) 檔" : "\(level) 档"
        }
        return trimmed
    }

    /// A fault banner. A bare code explains what to do next. A known value-list description
    /// keeps its code when the spec comment published one: `故障 E3 · 衣物分布不平衡`.
    public static func faultNotice(_ raw: String) -> FaultNotice {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = faultCode(text) {
            return FaultNotice(message: codeFallback(code), copyText: code)
        }
        let key = normalize(text)
        if let phrase = faults[key] {
            return describedFault(phrase, raw: text)
        }
        return FaultNotice(message: unknownFault(text), copyText: text)
    }

    static func spacedUnit(hans: String, hant: String, en: String) -> String {
        switch MiotDisplayScript.current {
        case .en: return " \(en)"
        case .hant: return " \(hant)"
        case .hans: return " \(hans)"
        }
    }

    private static func describedFault(_ phrase: Phrase, raw: String) -> FaultNotice {
        let script = MiotDisplayScript.current
        if script == .en {
            if let code = phrase.code {
                return FaultNotice(message: "Fault \(code) · \(raw)", copyText: code)
            }
            return FaultNotice(message: "Fault · \(raw)", copyText: raw)
        }
        let detail = script == .hant ? phrase.hant : phrase.hans
        if let code = phrase.code {
            return FaultNotice(message: "故障 \(code) · \(detail)", copyText: code)
        }
        return FaultNotice(message: "故障 · \(detail)", copyText: raw)
    }

    private static func codeFallback(_ code: String) -> String {
        switch MiotDisplayScript.current {
        case .en:
            return "The device reported fault code \(code). Check the manual or the Mi Home app."
        case .hant:
            return "裝置回報故障代碼 \(code)，請查看說明書或米家 App"
        case .hans:
            return "设备上报故障代码 \(code)，请查看说明书或米家 App"
        }
    }

    private static func unknownFault(_ text: String) -> String {
        switch MiotDisplayScript.current {
        case .en:
            return "The device reported a fault (\(text)). Check the manual or the Mi Home app."
        case .hant:
            return "裝置回報故障「\(text)」，請查看說明書或米家 App"
        case .hans:
            return "设备上报故障「\(text)」，请查看说明书或米家 App"
        }
    }

    /// `E3`, `FC2`, or a bare number. A word with no digits is a description, not a code.
    private static func faultCode(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if text.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) { return text }
        guard text.range(of: #"^[A-Za-z]{1,4}\d{1,4}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return text
    }

    private static func levelNumber(_ key: String) -> Int? {
        guard let match = key.wholeMatch(of: /level\s*(\d+)/) else { return nil }
        return Int(match.1)
    }

    private static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private struct Phrase: Sendable {
        var hans: String
        var hant: String
        var code: String?

        init(_ hans: String, _ hant: String, code: String? = nil) {
            self.hans = hans
            self.hant = hant
            self.code = code
        }
    }

    /// Xiaomi washer programme comments from `mibx5.washer.f27vn`, plus the words the drawer
    /// shows for lights and fans. A description whose vendors disagree (Daily Wash) stays English.
    private static let programmes: [String: Phrase] = [
        "mix": Phrase("混合洗", "混合洗"),
        "quick wash": Phrase("快速洗", "快速洗"),
        "delicate wash": Phrase("轻柔洗", "輕柔洗"),
        "heavy wash": Phrase("大件洗", "大件洗"),
        "rinse spin": Phrase("漂加脱", "漂加脫"),
        "spin": Phrase("单脱水", "單脫水"),
        "intensive": Phrase("强力洗", "強力洗"),
        "baby care": Phrase("婴童洗", "嬰童洗"),
        "drum clean": Phrase("筒清洁", "筒清潔"),
        "wool": Phrase("羊毛洗", "羊毛洗"),
        "down coat": Phrase("羽绒洗", "羽絨洗"),
        "cotton": Phrase("棉麻洗", "棉麻洗"),
        "synthetic": Phrase("化纤洗", "化纖洗"),
        "underwear": Phrase("内衣洗", "內衣洗"),
        "jacket": Phrase("冲锋衣", "衝鋒衣"),
        "smart": Phrase("智能洗", "智能洗"),
        "sportswear": Phrase("运动服", "運動服"),
        "new clothes wash": Phrase("新衣洗", "新衣洗"),
        "silk": Phrase("真丝洗", "真絲洗"),
        "jeans": Phrase("牛仔服", "牛仔服"),
        "pleased wash": Phrase("随心洗", "隨心洗"),
        "turban": Phrase("头巾洗", "頭巾洗"),
        "user define": Phrase("自定义", "自訂"),
        "bedding": Phrase("被子洗", "被子洗"),
        "shirt": Phrase("衬衣洗", "襯衣洗"),
        "rinse": Phrase("漂洗", "漂洗"),
        "day": Phrase("白天", "白天"),
        "night": Phrase("夜晚", "夜晚"),
        "night light": Phrase("夜灯", "夜燈"),
        "auto": Phrase("自动", "自動"),
        "sleep": Phrase("睡眠", "睡眠"),
        "favorite": Phrase("最爱", "最愛"),
        "favourite": Phrase("最爱", "最愛"),
        "silent": Phrase("静音", "靜音"),
        "strong": Phrase("强力", "強力"),
    ]

    /// Fault descriptions whose spec comment is the same on every fixture that publishes them.
    /// The trailing code in the comment is the code the banner can name.
    private static let faults: [String: Phrase] = [
        "dehydration fault": Phrase("衣物分布不平衡", "衣物分佈不平衡", code: "E3"),
        "door lock malfunction": Phrase("门未关好", "門未關好", code: "E2"),
        "motor driver board communication malfunction": Phrase("电脑板通讯异常", "電腦板通訊異常", code: "FC2"),
        "overflow malfunction": Phrase("水位过高", "水位過高", code: "E6"),
        "water level sensor malfunction": Phrase("水位异常", "水位異常", code: "F1"),
        "water temperature sensor malfunction": Phrase("水温异常", "水溫異常", code: "E8"),
        "water weating tube malfunction": Phrase("洗涤加热管异常", "洗滌加熱管異常", code: "E7"),
        "aquastopoccured": Phrase("防漏水系统已激活", "防漏水系統已啟動"),
        "containerfull": Phrase("冷凝水盒已满", "冷凝水盒已滿"),
        "doornotlock": Phrase("门锁无法使用", "門鎖無法使用"),
        "errors": Phrase("家电故障", "家電故障"),
        "excessive vibration": Phrase("整机震动过大", "整機震動過大"),
        "fan fault": Phrase("风机故障", "風機故障"),
        "faults": Phrase("出现异常", "出現異常"),
        "light panel fault": Phrase("灯板开合故障", "燈板開合故障"),
        "lintfilter": Phrase("绒毛收集器已满", "絨毛收集器已滿"),
        "low power": Phrase("低电量", "低電量"),
        "abnormal voltage": Phrase("电源电压异常", "電源電壓異常"),
        "power error": Phrase("电源故障", "電源故障"),
        "temp humidity sensor fault": Phrase("温湿度传感器故障", "溫溼度感測器故障"),
        "the pump is short circuited or disconnected": Phrase("水泵短路或断路", "水泵短路或斷路"),
        "uneven load": Phrase("衣物分布不均", "衣物分佈不均"),
        "motor fault": Phrase("电机故障", "電機故障"),
        "water draining malfunction": Phrase("排水故障", "排水故障"),
        "water intake malfunction": Phrase("进水故障", "進水故障"),
        "encounter obstacles": Phrase("遇阻", "遇阻"),
        "overweight": Phrase("超重", "超重"),
    ]
}

enum MiotDisplayScript: Equatable {
    case hans, hant, en

    static var current: MiotDisplayScript {
        if L10n.isEnglish { return .en }
        let id = L10n.currentLanguage.rawValue.lowercased()
        if id.contains("hant") || id.contains("-tw") || id.contains("-hk") || id.contains("-mo") {
            return .hant
        }
        return .hans
    }
}
