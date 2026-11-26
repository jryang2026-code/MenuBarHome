import Testing
@testable import MijiaCore

struct DDCCITests {
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
}
