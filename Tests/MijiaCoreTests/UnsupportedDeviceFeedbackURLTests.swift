import Foundation
import Testing
@testable import MijiaCore

/// #284: the "report this device" link prefills the fields of `unsupported_device.yml`.
struct UnsupportedDeviceFeedbackURLTests {
    private struct Form {
        let url: URL
        let items: [String: String]

        init(_ url: URL) {
            self.url = url
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            items = Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }

        subscript(name: String) -> String? { items[name] }
    }

    private func form(language: AppLanguage, device: UnsupportedDevice) throws -> Form {
        let url = try L10n.$overrideLanguage.withValue(language) {
            try #require(UnsupportedDeviceFeedbackURL.make(for: device))
        }
        return Form(url)
    }

    @Test("Chinese UI: the title and symptom are localized and no device id is sent")
    func chinesePrefill() throws {
        let device = UnsupportedDevice(
            id: "did-700000001",
            name: "客厅新风机",
            model: "acme.fan.v1",
            reason: .unknownModel
        )
        let form = try form(language: .zhHans, device: device)

        #expect(form["template"] == "unsupported_device.yml")
        #expect(form["title"] == "[设备不支持] 客厅新风机 (acme.fan.v1)")
        #expect(form["platform"] == "macOS")
        #expect(form["backend"] == "小米云（扫码登录）")
        #expect(form["model"] == "acme.fan.v1")
        #expect(form["symptom"] == "没有取到米家设备规格\n\n期望支持的功能（开关、亮度、温度…）：")
        #expect(form["did"] == nil)
        #expect(form["did-format"] == nil)
        #expect(!form.items.values.contains { $0.contains(device.id) })
    }

    @Test("Special characters in the name and model survive URL encoding")
    func specialCharactersRoundTrip() throws {
        let name = "客厅 & 灯 = #1 100%"
        let model = "acme model=v1&x#y%2F"
        let device = UnsupportedDevice(id: "did-secret", name: name, model: model, reason: .unknownModel)
        let form = try form(language: .zhHans, device: device)

        #expect(form["title"] == "[设备不支持] \(name) (\(model))")
        #expect(form["model"] == model)

        let encoded = URLComponents(url: form.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        #expect(!encoded.contains(" "))
        for escape in ["%26", "%3D", "%23", "%25"] {
            #expect(encoded.contains(escape))
        }
    }

    @Test("Plus signs survive form-urlencoded decoding")
    func plusSignsSurviveFormDecoding() throws {
        let name = "客厅 & 灯 = #1 100% + plus?"
        let model = "acme model=v1&x#y%2F+z"
        let device = UnsupportedDevice(id: "did-secret", name: name, model: model, reason: .unknownModel)
        let form = try form(language: .zhHans, device: device)

        let encoded = URLComponents(url: form.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        #expect(encoded.contains("%2B"))
        #expect(!encoded.contains("+"))

        // WHATWG form-urlencoded decoders read a raw "+" as a space.
        let formDecoded = encoded
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? ""
        #expect(formDecoded.contains("[设备不支持] \(name) (\(model))"))
        #expect(formDecoded.contains("model=\(model)"))
    }

    @Test("Intentional skips (duplicates, devices disabled or hidden in HA) get no feedback link")
    func intentionalSkipsHaveNoLink() {
        for reason: UnsupportedDevice.Reason in [.filteredDuplicate, .deviceDisabled, .noActiveEntities] {
            let device = UnsupportedDevice(
                id: "did-gateway",
                name: "网关",
                model: "lumi.gateway.mgl03",
                reason: reason
            )
            #expect(UnsupportedDeviceFeedbackURL.make(for: device) == nil, "\(reason)")
        }
    }
}
