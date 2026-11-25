import Foundation
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct HAEndpointAddressTests {
    @Test(arguments: [
        ("0.0.0.0", EndpointAddressClass.prohibited),
        ("0.1.2.3", .prohibited),
        ("127.255.0.1", .prohibited),
        ("::", .prohibited),
        ("::1", .prohibited),
        ("::ffff:127.0.0.1", .prohibited),
        ("169.254.1.2", .lan),
        ("::ffff:192.168.1.2", .lan),
        ("fe80::1%en0", .lan),
        ("febf::1", .lan),
        ("fc00::1", .lan),
        ("fdff::1", .lan),
        ("100.64.0.1", .lan),
        ("100.127.255.255", .lan),
        ("100.128.0.1", .publicNetwork),
        ("::ffff:8.8.8.8", .publicNetwork),
        ("2001:4860::8888", .publicNetwork)
    ])
    func addressClassification(_ input: (String, EndpointAddressClass)) {
        #expect(EndpointAddressClass(numericAddress: input.0) == input.1)
    }

    @Test(arguments: [
        ("https://home.example", "100.64.0.1", nil as HAEndpointResolutionError?),
        ("http://home.example", "192.0.2.10", nil),
        ("https://home.example", "127.0.0.1", .prohibitedAddress),
        ("http://home.lan", "192.0.2.10", .publicAddressForLocalPlaintext),
        ("https://home.lan", "192.0.2.10", nil),
        ("ws://home.local", "192.0.2.10", .publicAddressForLocalPlaintext),
        ("wss://home.local", "192.0.2.10", nil),
        ("http://192.168.1.10", "192.0.2.10", .publicAddressForLocalPlaintext),
        ("http://[::ffff:192.168.1.10]", "192.0.2.10", .publicAddressForLocalPlaintext),
        ("http://home.lan", "::ffff:127.0.0.1", .prohibitedAddress)
    ])
    func validatesMixedAnswers(_ test: (String, String, HAEndpointResolutionError?)) throws {
        let url = try #require(URL(string: test.0))
        let validate = {
            try HAPlaintextConsent.validateConnectionAddress(url) { _ in ["192.168.1.10", test.1] }
        }
        if let expected = test.2 {
            #expect(throws: expected) { try validate() }
        } else {
            try validate()
        }
    }

    @Test
    func systemLookupAndLiteralValidation() async throws {
        try await HAPlaintextConsent.validateConnectionAddress(#require(URL(string: "http://192.168.1.10")))
        for raw in ["http://127.1:8123", "wss://[::ffff:127.0.0.1]:8123", "http://localhost:8123"] {
            let url = try #require(URL(string: raw))
            await #expect(throws: HAEndpointResolutionError.prohibitedAddress) {
                try await HAPlaintextConsent.validateConnectionAddress(url)
            }
        }
    }
}
