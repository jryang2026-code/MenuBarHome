import Foundation

/// A snapshot read. It produces a reply, so it cannot be serialized as a device command.
struct StateQuery {
    private enum Kind {
        case status, contact, temperature, setpoint, humidity, fanSpeed, activeLights, lightCount, anyActive, unsupported
    }

    private static let patterns: [(Kind, NSRegularExpression)] = [
        (.activeLights, try! NSRegularExpression(pattern: #"^(?:现在哪些|哪些)(灯)(?:开着|亮着)$"#)),
        (.lightCount, try! NSRegularExpression(pattern: #"^(?:现在)?有几(?:个|盏)(灯)(?:开着|亮着)$"#)),
        (.anyActive, try! NSRegularExpression(pattern: #"^(?:家里|全屋)?有没有(设备)开着$"#)),
        (.contact, try! NSRegularExpression(pattern: #"^(.+?)(?:关好|关上)(?:了)?(?:吗|没有|没)$"#)),
        (.setpoint, try! NSRegularExpression(pattern: #"^(.+?)(?:现在)?(?:设置|设定|设为)(?:了|是)?(?:多少度|几度)$"#)),
        (.temperature, try! NSRegularExpression(pattern: #"^(.+?)(?:现在)?(?:室温|温度)(?:是)?(?:多少(?:度)?|几度)$"#)),
        (.humidity, try! NSRegularExpression(pattern: #"^(.+?)(?:现在)?湿度(?:是)?多少$"#)),
        (.temperature, try! NSRegularExpression(pattern: #"^(.+?)(?:现在)?(?:是)?(?:多少度|几度)$"#)),
        (.fanSpeed, try! NSRegularExpression(pattern: #"^(.+?)(?:现在)?(?:风速|在|是)?几档$"#)),
        (.status, try! NSRegularExpression(pattern: #"^(.+?)(?:现在)?(?:开着|亮着|关着|打开了|关闭了|开了|关了)(?:吗|没有|没)$"#)),
        (.status, try! NSRegularExpression(pattern: #"^(.+?)(?:现在)?(?:是什么状态|什么状态)$"#))
    ]

    private let kind: Kind
    private let target: String

    static func parse(_ text: String) -> StateQuery? {
        let polite = LocalIntentParser.removingPoliteWrappers(text)
        let asksWhether = polite.contains("是不是")
        let question = polite.replacingOccurrences(of: "是不是", with: "")
        let range = NSRange(question.startIndex..., in: question)
        for (kind, pattern) in patterns {
            if let match = pattern.firstMatch(in: question, range: range),
               let targetRange = Range(match.range(at: 1), in: question) {
                return StateQuery(kind: kind, target: String(question[targetRange]))
            }
        }
        if asksWhether,
           let match = question.wholeMatch(of: /^(.+?)(?:开着|亮着|关着|打开了|关闭了|开了|关了)$/) {
            return StateQuery(kind: .status, target: String(match.output.1))
        }
        let statusWords = #"开着|亮着|关着|开了|关了|关好|关上|什么状态|温度|湿度|几度|几档"#
        let mixedStatusQuestion = #"(?:"# + statusWords + #")(?:了)?(?:吗|没有|没)"#
        if (asksWhether && question.range(of: statusWords, options: .regularExpression) != nil)
            || question.range(of: mixedStatusQuestion, options: .regularExpression) != nil
            || question.range(of: #"扫地(?:机|机器人)在哪$"#, options: .regularExpression) != nil {
            return StateQuery(kind: .unsupported, target: "")
        }
        return nil
    }

    func answer(devices: [SmartDevice]) -> IntentPlan? {
        let reply: String
        switch kind {
        case .unsupported:
            return nil
        case .activeLights, .lightCount, .anyActive:
            let active = devices.filter { device in
                device.isActiveDevice && !device.isMomentaryButton
                    && (kind == .anyActive || IntentDeviceCategory(device) == .light)
            }
            switch kind {
            case .lightCount: reply = L10n.format("现在有 %@ 盏灯开着", "%@ lights are on", String(active.count))
            case .anyActive: reply = active.isEmpty
                    ? L10n.tr("家里没有设备开着", "No devices are on")
                    : L10n.format("家里有 %@ 台设备开着", "%@ devices are on", String(active.count))
            default: reply = active.isEmpty
                    ? L10n.tr("没有灯开着", "No lights are on")
                    : L10n.format("%@ 开着", "On: %@", shortList(active.map(\.name)))
            }
        default:
            let eligible = devices.filter { device in
                guard !device.kind.isCover, !device.isMomentaryButton else { return false }
                switch kind {
                case .contact:
                    if case .sensor(let sensor) = device.kind {
                        return sensor.observations.contains { $0.kind == .contact }
                    }
                    return false
                case .status:
                    if case .fridge = device.kind { return false }
                    if case .sensor = device.kind { return false }
                    return true
                case .fanSpeed:
                    if case .fan = device.kind { return true }
                    return false
                case .setpoint:
                    if case .climate = device.kind { return true }
                    return false
                default: return true
                }
            }
            let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let entries = PanelSearch.entries(devices: eligible)
            let normalized = PanelSearch.normalize(target)
            guard !normalized.isEmpty else { return nil }
            let exact = entries.filter { $0.name == normalized || $0.pinyin == normalized || $0.initials == normalized }
            let matches = exact.isEmpty ? PanelSearch.matches(target, entries: entries) : exact
            let candidates: [SmartDevice]
            if matches.isEmpty, target.hasSuffix("灯"), target.count > 1 {
                let room = String(target.dropLast())
                let lights = eligible.filter { IntentDeviceCategory($0) == .light }
                candidates = PanelSearch.matches(room, entries: PanelSearch.entries(devices: lights))
                    .compactMap { byID[$0.deviceId] }
            } else {
                candidates = matches.compactMap { byID[$0.deviceId] }
            }
            let statuses = candidates.compactMap { device in
                status(of: device).map { L10n.format("%@：%@", "%@: %@", device.name, $0) }
            }
            guard !statuses.isEmpty else { return nil }
            reply = shortList(statuses)
        }
        return IntentPlan(intents: [], reply: reply, source: .local)
    }

    private func status(of device: SmartDevice) -> String? {
        if !device.isOnline {
            return kind == .temperature || kind == .humidity ? nil : L10n.tr("离线", "Offline")
        }
        switch kind {
        case .status:
            if case .light(let light) = device.kind, light.isOn, let brightness = light.brightnessPercent {
                return L10n.format("开着，亮度 %@%", "On, brightness %@%", String(brightness))
            }
            return device.isActiveOn ? L10n.tr("开着", "On") : L10n.tr("关着", "Off")
        case .contact:
            guard case .sensor(let sensor) = device.kind else { return nil }
            let contacts = sensor.observations.filter { $0.kind == .contact }
            return contacts.contains(where: \.alarming) ? L10n.tr("已打开", "Open") : L10n.tr("关好", "Closed")
        case .temperature:
            // The reply speaks the display unit the user picked (#428), one decimal like the panel's
            // temperature-only status; the stored value stays Celsius.
            guard let temperature = device.environmentReading?.temperature, temperature.isFinite else { return nil }
            return L10n.temperature(temperature, fractionDigits: 1)
        case .humidity:
            guard let humidity = device.environmentReading?.humidity, humidity.isFinite else { return nil }
            return IntentReply.formatTemperature(humidity) + "%"
        case .setpoint:
            guard case .climate(let climate) = device.kind else { return nil }
            let target = climate.targetTemperature
            guard target.isFinite else { return nil }
            return L10n.format("设定 %@", "Set to %@", L10n.temperature(target))
        case .fanSpeed:
            guard case .fan(let fan) = device.kind else { return nil }
            if !fan.isOn { return L10n.tr("关着", "Off") }
            if let mode = fan.presetMode { return IntentReply.fanSpeedLabel(mode) }
            return fan.percentage.map { L10n.format("风速 %@%", "Fan speed %@%", String($0)) }
        default:
            return nil
        }
    }

    private func shortList(_ entries: [String]) -> String {
        let first = entries.prefix(3).joined(separator: L10n.tr("；", "; "))
        return entries.count > 3 ? L10n.format("%@ 等 %@ 台", "%@ (%@ total)", first, String(entries.count)) : first
    }
}
