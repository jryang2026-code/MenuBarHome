import Foundation
import Testing
@testable import MijiaCore

struct DDCCITests {
    final class MockTransport: DDCCITransport, @unchecked Sendable {
        var displays: [DDCCIDisplayDescriptor]
        var failures = 0
        var exchanges: [(String, UInt8, [UInt8])] = []

        init(displays: [DDCCIDisplayDescriptor]) { self.displays = displays }
        func listDisplays() throws -> [DDCCIDisplayDescriptor] { displays }
        func exchange(displayId: String, chipAddress: UInt8, request: [UInt8], replyLength: Int, readDelay: TimeInterval) throws -> [UInt8] {
            exchanges.append((displayId, chipAddress, request))
            if request.count > 2, request[0] == 0x82 {
                if failures > 0 { failures -= 1; throw DDCCIError.invalidReply }
                let reply = [UInt8(0x6E), 0x88, 0x02, 0x00, request[2], 0x00, 0x00, 0x64, 0x00, 0x32]
                return reply + [reply.reduce(0x50, ^)]
            }
            return []
        }
    }

    private func monitor(id: String = "g27u", external: Bool = true, bridge: Bool = false) -> DDCCIDisplayDescriptor {
        DDCCIDisplayDescriptor(id: id, name: "Redmi G27U", manufacturer: "RED", model: "G27U", isExternal: external, supportsMCDP29XXBridge: bridge)
    }

    @Test func vcpGuardAndFrames() throws {
        #expect(throws: DDCCIError.forbiddenVCPCode(0xD6)) { try DDCCIVCPGuard.validate(0xD6) }
        #expect(try DDCCIFrame.getVCP(0x10) == [0x82, 0x01, 0x10, 0xAC])
        #expect(DDCCIFrame.chipAddress(usesMCDP29XXBridge: true) == 0xB7)
    }

    @Test func capabilitiesParseInputSources() {
        #expect(DDCCICapabilities.inputSources(in: "vcp(10 12 60(0F 10 11 12 1B) 62 8D)") == [.dp1, .dp2, .hdmi1, .hdmi2, .usbC])
    }

    @Test func invalidReplyIsRejected() throws {
        #expect(throws: DDCCIError.invalidReply) { try DDCCIFrame.decodeVCP([0, 0, 0], code: 0x10) }
    }

    @Test func controllerFiltersBuiltInDisplaysAndUsesBridgeAddress() async throws {
        let mock = MockTransport(displays: [monitor(), monitor(id: "built-in", external: false), monitor(id: "bridge", bridge: true)])
        let controller = DDCCIDisplayController(transport: mock)
        #expect(try await controller.listDisplays().map(\.id) == ["g27u", "bridge"])
        try await controller.setBrightness(displayId: "bridge", percent: 50)
        #expect(mock.exchanges.contains { $0.0 == "bridge" && $0.1 == 0xB7 })
    }

    @Test func controllerWritesAllSupportedControls() async throws {
        let mock = MockTransport(displays: [monitor()])
        let controller = DDCCIDisplayController(transport: mock)
        _ = try await controller.listDisplays()
        try await controller.setBrightness(displayId: "g27u", percent: 40)
        for source: DDCCIInputSource in [.dp1, .dp2, .hdmi1, .hdmi2, .usbC] {
            try await controller.setInputSource(displayId: "g27u", source: source)
        }
        try await controller.setVolume(displayId: "g27u", percent: 20)
        try await controller.setMute(displayId: "g27u", muted: true)
        #expect(mock.exchanges.filter { $0.2.count > 1 && $0.2[0] == 0x84 }.count == 8)
    }

    @Test func redmiReadFailureUsesCachedValueForBlindWrite() async throws {
        let mock = MockTransport(displays: [monitor()])
        let controller = DDCCIDisplayController(transport: mock)
        _ = try await controller.listDisplays()
        try await controller.setBrightness(displayId: "g27u", percent: 50)
        mock.failures = 4
        try await controller.setBrightness(displayId: "g27u", percent: 60)
        #expect(mock.exchanges.contains { $0.2.count > 1 && $0.2[0] == 0x84 })
    }
}
