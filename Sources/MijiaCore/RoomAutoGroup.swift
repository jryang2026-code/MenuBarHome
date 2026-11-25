import Foundation

public enum HueMath {
    /// Circular mean of hue angles in degrees, normalized to `[0, 360)`.
    public static func circularMean(_ hues: [Double]) -> Double? {
        var sumSin = 0.0, sumCos = 0.0, count = 0
        for hue in hues where hue.isFinite {
            let rad = hue * .pi / 180.0
            sumSin += sin(rad); sumCos += cos(rad); count += 1
        }
        guard count > 0, hypot(sumSin, sumCos) > 1e-9 else { return nil }
        var deg = atan2(sumSin, sumCos) * 180.0 / .pi
        if deg < 0 { deg += 360.0 }
        return deg >= 360.0 - 1e-9 ? 0.0 : deg
    }
}

public enum RoomAutoGroupKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case light, cover, plug, fan, climate

    public var sfSymbolName: String {
        switch self {
        case .light: return "lightbulb.fill"
        case .cover: return "blinds.horizontal.closed"
        case .plug: return "poweroutlet.type.b.fill"
        case .fan: return "fan.fill"
        case .climate: return "air.conditioner.horizontal.fill"
        }
    }

    public static func from(_ device: SmartDevice) -> RoomAutoGroupKind? {
        switch device.kind {
        case .light(let s): return (s.powerWritable || s.brightnessWritable) ? .light : nil
        case .cover(let s): return (s.positionWritable || s.canMove) ? .cover : nil
        case .plug(let s): return (s.powerWritable && !device.isMomentaryButton) ? .plug : nil
        case .fan(let s): return s.powerWritable ? .fan : nil
        case .climate(let s): return s.powerWritable ? .climate : nil
        default: return nil
        }
    }

    public func label(roomName: String, count: Int) -> String {
        let prefix = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit: String = L10n.isEnglish
            ? (self == .light ? "lights" : self == .cover ? "covers" : self == .plug ? "plugs" : self == .fan ? "fans" : "ACs")
            : (self == .light ? "盏灯" : self == .cover ? "个窗帘" : self == .plug ? "个插座" : self == .fan ? "台风扇" : "台空调")
        return prefix.isEmpty ? "\(count) \(unit)" : "\(prefix) \(count) \(unit)"
    }
}

public struct RoomAutoGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let roomId: String
    public let roomName: String
    public let kind: RoomAutoGroupKind
    public let deviceIds: [String]
    public let isAnyOn: Bool
    public let activeCount: Int
    public let averageBrightness: Int?
    public let averageHueDegrees: Double?
    public let averageCoverPosition: Int?
    public let supportsBrightnessControl: Bool

    public var count: Int { deviceIds.count }
    public var label: String { kind.label(roomName: roomName, count: count) }

    public var statusSummary: String? {
        switch kind {
        case .light: return (isAnyOn ? averageBrightness.map { "\($0)%" } ?? "\(activeCount)/\(count)" : nil)
        case .cover: return averageCoverPosition.map { "\($0)%" } ?? (isAnyOn ? "\(activeCount)/\(count)" : nil)
        case .plug, .fan, .climate: return isAnyOn ? "\(activeCount)/\(count)" : nil
        }
    }

    /// Groups controllable online devices in a room by kind whenever `>= 2` share a kind.
    public static func build(roomId: String, roomName: String, devices: [SmartDevice]) -> [RoomAutoGroup] {
        var buckets: [RoomAutoGroupKind: [SmartDevice]] = [:]
        for device in devices where device.roomId == roomId && device.isOnline {
            if let kind = RoomAutoGroupKind.from(device) { buckets[kind, default: []].append(device) }
        }
        return RoomAutoGroupKind.allCases.compactMap { kind in
            guard let members = buckets[kind], members.count >= 2 else { return nil }
            let activeMembers = members.filter { isMemberActive($0, kind: kind) }
            let isAnyOn = !activeMembers.isEmpty
            var averageBrightness: Int?
            var averageHueDegrees: Double?
            var supportsBrightnessControl = false
            if kind == .light {
                let source = isAnyOn ? activeMembers : members
                let brightness = source.compactMap { if case .light(let s) = $0.kind { return s.brightnessPercent }; return nil }
                if isAnyOn && !brightness.isEmpty {
                    averageBrightness = Int((Double(brightness.reduce(0, +)) / Double(brightness.count)).rounded())
                }
                let hues = source.compactMap { if case .light(let s) = $0.kind { return s.hueDegrees }; return nil }
                averageHueDegrees = HueMath.circularMean(hues)
                supportsBrightnessControl = members.contains { if case .light(let s) = $0.kind { return s.brightnessWritable }; return false }
            }
            var averageCoverPosition: Int?
            if kind == .cover {
                let positions = members.compactMap { if case .cover(let s) = $0.kind { return s.positionPercent }; return nil }
                if !positions.isEmpty {
                    averageCoverPosition = Int((Double(positions.reduce(0, +)) / Double(positions.count)).rounded())
                }
            }
            return RoomAutoGroup(
                id: "\(roomId):\(kind.rawValue)", roomId: roomId, roomName: roomName, kind: kind,
                deviceIds: members.map(\.id), isAnyOn: isAnyOn, activeCount: activeMembers.count,
                averageBrightness: averageBrightness, averageHueDegrees: averageHueDegrees,
                averageCoverPosition: averageCoverPosition, supportsBrightnessControl: supportsBrightnessControl
            )
        }
    }

    private static func isMemberActive(_ device: SmartDevice, kind: RoomAutoGroupKind) -> Bool {
        switch (kind, device.kind) {
        case (.light, .light(let s)): return s.isOn
        case (.plug, .plug(let s)): return s.isOn
        case (.fan, .fan(let s)): return s.isOn
        case (.climate, .climate(let s)): return s.isOn && s.hvacMode != "off"
        case (.cover, .cover(let s)): return (s.positionPercent ?? 0) > 0
        default: return false
        }
    }
}
