import Foundation

public struct DDCCIDisplayDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let manufacturer: String
    public let model: String
    public let serialNumber: String?
    public let isExternal: Bool
    public let supportsMCDP29XXBridge: Bool

    public var isRedmiOrXiaomiMonitor: Bool {
        let models = ["REDMIG27U", "G27U", "A27U", "G27"]
        return ["XMI", "RED"].contains(manufacturer.uppercased()) || [name, model].contains {
            let normalized = $0.uppercased().filter { $0.isLetter || $0.isNumber }
            return models.contains(normalized) || normalized.hasPrefix("RMMNT")
        }
    }

    public init(id: String, name: String, manufacturer: String = "", model: String = "",
                serialNumber: String? = nil, isExternal: Bool = true, supportsMCDP29XXBridge: Bool = false) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.isExternal = isExternal
        self.supportsMCDP29XXBridge = supportsMCDP29XXBridge
    }
}

public enum DDCCIVCPCode: UInt8, Sendable {
    case luminance = 0x10
    case inputSource = 0x60
    case volume = 0x62
    case mute = 0x8D
}

public enum DDCCIVCPGuard {
    public static func validate(_ raw: UInt8) throws -> DDCCIVCPCode {
        guard raw != 0xD6 else { throw DDCCIError.forbiddenVCPCode(raw) }
        guard let code = DDCCIVCPCode(rawValue: raw) else { throw DDCCIError.unsupportedVCPCode(raw) }
        return code
    }
}

public enum DDCCIInputSource: RawRepresentable, Equatable, Sendable {
    case dp1, dp2, hdmi1, hdmi2, usbC, custom(UInt16)

    public init(rawValue: UInt16) {
        self = switch rawValue {
        case 0x0F: .dp1
        case 0x10: .dp2
        case 0x11: .hdmi1
        case 0x12: .hdmi2
        case 0x1B: .usbC
        default: .custom(rawValue)
        }
    }

    public var rawValue: UInt16 {
        switch self {
        case .dp1: 0x0F
        case .dp2: 0x10
        case .hdmi1: 0x11
        case .hdmi2: 0x12
        case .usbC: 0x1B
        case .custom(let value): value
        }
    }
}

public struct DDCCIDisplayState: Equatable, Sendable {
    public let brightnessPercent: Int?
    public let inputSource: DDCCIInputSource?
    public let supportedInputSources: [DDCCIInputSource]
    public let volumePercent: Int?
    public let isMuted: Bool?

    public init(brightnessPercent: Int?, inputSource: DDCCIInputSource?, supportedInputSources: [DDCCIInputSource], volumePercent: Int?, isMuted: Bool?) {
        self.brightnessPercent = brightnessPercent
        self.inputSource = inputSource
        self.supportedInputSources = supportedInputSources
        self.volumePercent = volumePercent
        self.isMuted = isMuted
    }
}

public enum DDCCIError: Error, Equatable, Sendable {
    case forbiddenVCPCode(UInt8), unsupportedVCPCode(UInt8), invalidReply
    case transportUnavailable, displayNotFound(String), ioFailure(Int32), invalidPercent(Int)
}

public enum DDCCIFrame {
    public static let dataAddress: UInt8 = 0x51

    public static func chipAddress(usesMCDP29XXBridge: Bool) -> UInt8 {
        usesMCDP29XXBridge ? 0xB7 : 0x37
    }

    public static func getVCP(_ raw: UInt8) throws -> [UInt8] {
        request([0x01, try DDCCIVCPGuard.validate(raw).rawValue])
    }

    public static func setVCP(_ raw: UInt8, value: UInt16) throws -> [UInt8] {
        request([0x03, try DDCCIVCPGuard.validate(raw).rawValue, UInt8(value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    public static func decodeVCP(_ frame: [UInt8], code: UInt8) throws -> (current: UInt16, maximum: UInt16) {
        _ = try DDCCIVCPGuard.validate(code)
        let payload = try reply(frame)
        guard payload.count == 8, payload[0] == 0x02, payload[2] == code else { throw DDCCIError.invalidReply }
        if payload[1] == 0x01 { throw DDCCIError.unsupportedVCPCode(code) }
        guard payload[1] == 0x00 else { throw DDCCIError.invalidReply }
        return (word(payload[6], payload[7]), word(payload[4], payload[5]))
    }

    static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        request([0xF3, UInt8(offset >> 8), UInt8(truncatingIfNeeded: offset)])
    }

    static func decodeCapabilities(_ frame: [UInt8], offset: UInt16) throws -> ArraySlice<UInt8> {
        let payload = try reply(frame)
        guard (3...35).contains(payload.count), payload[0] == 0xE3, word(payload[1], payload[2]) == offset else {
            throw DDCCIError.invalidReply
        }
        return payload.dropFirst(3)
    }

    private static func request(_ payload: [UInt8]) -> [UInt8] {
        // IOAVService takes the host data address separately from the length and payload bytes.
        let bytes = [0x80 | UInt8(payload.count)] + payload
        return bytes + [bytes.reduce(0x6E ^ dataAddress, ^)]
    }

    private static func reply(_ frame: [UInt8]) throws -> [UInt8] {
        guard frame.count >= 3, frame[0] == 0x6E, frame[1] & 0x80 != 0 else { throw DDCCIError.invalidReply }
        let end = 2 + Int(frame[1] & 0x7F)
        guard frame.count > end, frame[...end].reduce(0x50, ^) == 0 else { throw DDCCIError.invalidReply }
        return Array(frame[2..<end])
    }

    private static func word(_ high: UInt8, _ low: UInt8) -> UInt16 {
        UInt16(high) << 8 | UInt16(low)
    }
}

public enum DDCCICapabilities {
    public static func inputSources(in text: String) -> [DDCCIInputSource] {
        guard let vcp = text.firstMatch(of: /(?i)\bvcp\s*\(/) else { return [] }
        let tokens = text[vcp.range.upperBound...].matches(of: /[^\s()]+|[()]/).map(\.output)
        var depth = 0
        var feature: Substring?
        var sources: [DDCCIInputSource] = []
        for token in tokens {
            switch token {
            case "(": depth += 1
            case ")":
                if depth == 0 { return sources }
                depth -= 1
                if depth == 0 { feature = nil }
            default:
                if depth == 0 { feature = token }
                if depth == 1, feature == "60", let value = UInt16(token, radix: 16) {
                    let source = DDCCIInputSource(rawValue: value)
                    if !sources.contains(source) { sources.append(source) }
                }
            }
        }
        return sources
    }
}
