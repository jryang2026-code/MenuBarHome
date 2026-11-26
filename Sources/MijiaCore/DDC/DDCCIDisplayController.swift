import Foundation

public protocol DDCCITransport: Sendable {
    func listDisplays() throws -> [DDCCIDisplayDescriptor]
    func exchange(displayId: String, chipAddress: UInt8, request: [UInt8],
                  replyLength: Int, readDelay: TimeInterval) throws -> [UInt8]
}

public actor DDCCIDisplayController {
    private let transport: any DDCCITransport
    private var displays: [DDCCIDisplayDescriptor] = []
    private var values: [String: [DDCCIVCPCode: (current: UInt16, maximum: UInt16)]] = [:]
    private var inputs: [String: [DDCCIInputSource]] = [:]

    public init(transport: any DDCCITransport) { self.transport = transport }

    public func listDisplays() throws -> [DDCCIDisplayDescriptor] {
        displays = try transport.listDisplays().filter(\.isExternal)
        let ids = Set(displays.map(\.id))
        values = values.filter { ids.contains($0.key) }
        inputs = inputs.filter { ids.contains($0.key) }
        return displays
    }

    public func readState(displayId: String) throws -> DDCCIDisplayState {
        let display = try display(displayId)
        let brightness = try? read(.luminance, on: display)
        let input = try? read(.inputSource, on: display)
        let volume = try? read(.volume, on: display)
        let mute = try? read(.mute, on: display).current
        if inputs[displayId] == nil, let sources = try? readInputs(on: display) {
            inputs[displayId] = sources
        }
        return DDCCIDisplayState(brightnessPercent: brightness.flatMap(percent),
                                inputSource: input.map { DDCCIInputSource(rawValue: $0.current) },
                                supportedInputSources: inputs[displayId] ?? [],
                                volumePercent: volume.flatMap(percent),
                                isMuted: mute == 1 ? true : mute == 2 ? false : nil)
    }

    public func setBrightness(displayId: String, percent: Int) throws {
        try setPercent(.luminance, percent, on: display(displayId))
    }

    public func setVolume(displayId: String, percent: Int) throws {
        try setPercent(.volume, percent, on: display(displayId))
    }

    public func setInputSource(displayId: String, source: DDCCIInputSource) throws {
        try write(.inputSource, value: source.rawValue, on: display(displayId))
    }

    public func setMute(displayId: String, muted: Bool) throws {
        try write(.mute, value: muted ? 1 : 2, on: display(displayId))
    }

    private func display(_ id: String) throws -> DDCCIDisplayDescriptor {
        if let known = displays.first(where: { $0.id == id }) { return known }
        guard let found = try listDisplays().first(where: { $0.id == id }) else {
            throw DDCCIError.displayNotFound(id)
        }
        return found
    }

    private func percent(_ value: (current: UInt16, maximum: UInt16)) -> Int? {
        guard value.maximum > 0, value.current <= value.maximum else { return nil }
        return (Int(value.current) * 100 + Int(value.maximum) / 2) / Int(value.maximum)
    }

    private func setPercent(_ code: DDCCIVCPCode, _ percent: Int, on display: DDCCIDisplayDescriptor) throws {
        guard (0...100).contains(percent) else { throw DDCCIError.invalidPercent(percent) }
        let maximum: UInt16
        do {
            maximum = try read(code, on: display).maximum
        } catch let error as DDCCIError where display.isRedmiOrXiaomiMonitor && isRetryable(error) {
            maximum = 100
        }
        let value = UInt16((Int(maximum) * percent + 50) / 100)
        try write(code, value: value, maximum: maximum, on: display)
    }

    private func read(_ code: DDCCIVCPCode, on display: DDCCIDisplayDescriptor) throws -> (current: UInt16, maximum: UInt16) {
        let request = try DDCCIFrame.getVCP(code.rawValue)
        do {
            let value = try transact(on: display, request: request, replyLength: 12) { frame in
                let value = try DDCCIFrame.decodeVCP(frame, code: code.rawValue)
                if code == .luminance || code == .volume {
                    guard value.maximum > 0, value.current <= value.maximum else { throw DDCCIError.invalidReply }
                }
                return value
            }
            values[display.id, default: [:]][code] = value
            return value
        } catch let error as DDCCIError where display.isRedmiOrXiaomiMonitor && isRetryable(error) {
            guard let cached = values[display.id]?[code] else { throw error }
            return cached
        }
    }

    private func write(_ code: DDCCIVCPCode, value: UInt16, maximum: UInt16 = 0,
                       on display: DDCCIDisplayDescriptor) throws {
        let request = try DDCCIFrame.setVCP(code.rawValue, value: value)
        try transact(on: display, request: request, replyLength: 0) { _ in }
        values[display.id, default: [:]][code] = (value, maximum)
    }

    private func readInputs(on display: DDCCIDisplayDescriptor) throws -> [DDCCIInputSource] {
        var bytes: [UInt8] = []
        while bytes.count < 4096 {
            let offset = UInt16(bytes.count)
            let part = try transact(on: display, request: DDCCIFrame.capabilitiesRequest(offset: offset),
                                    replyLength: 38) { try DDCCIFrame.decodeCapabilities($0, offset: offset) }
            bytes.append(contentsOf: part.prefix { $0 != 0 })
            if part.isEmpty || part.contains(0) {
                return DDCCICapabilities.inputSources(in: String(decoding: bytes, as: UTF8.self))
            }
        }
        throw DDCCIError.invalidReply
    }

    private func transact<T>(on display: DDCCIDisplayDescriptor, request: [UInt8], replyLength: Int,
                             decode: ([UInt8]) throws -> T) throws -> T {
        let bridge = display.supportsMCDP29XXBridge
        let retries = bridge || display.isRedmiOrXiaomiMonitor ? 4 : 1
        for attempt in 0...retries {
            do {
                let frame = try transport.exchange(displayId: display.id,
                                                   chipAddress: DDCCIFrame.chipAddress(usesMCDP29XXBridge: bridge),
                                                   request: request, replyLength: replyLength, readDelay: 0.05)
                return try decode(frame)
            } catch let error as DDCCIError where attempt < retries && isRetryable(error) {
                continue
            }
        }
        throw DDCCIError.invalidReply
    }

    private func isRetryable(_ error: DDCCIError) -> Bool {
        switch error {
        case .invalidReply, .ioFailure: true
        default: false
        }
    }
}
