import Foundation
import KeychainTestSupport
import Testing
@testable import MijiaCore

struct GenericCameraTests {
    @Test func sharedSourcesAndEncoding() throws {
        struct Corpus: Decodable {
            struct Case: Decodable {
                let input: GenericCameraSource
                let main: String
                let sub: String
            }
            let cases: [Case]
        }
        let fixture = try GoldenCorpusTests.locateGoldenFixture("Tests/Fixtures/generic_camera_sources_golden.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
        for item in corpus.cases {
            #expect(item.input.isValid, "\(item.input.kind)")
            #expect(item.input.source(.main) == item.main)
            #expect(item.input.source(.sub) == item.sub)
            let credentials = GenericCameraSource.Credentials(username: "viewer@a:b", password: "é/@?# %")
            #expect(item.input.source(.main, credentials: credentials) == item.main
                .replacingOccurrences(of: "{user}", with: "viewer%40a%3Ab")
                .replacingOccurrences(of: "{pass}", with: "%C3%A9%2F%40%3F%23%20%25"))
        }
    }

    @Test func credentialsRoundTripWithoutEnteringTheSourceConfig() throws {
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let camera = GenericCameraSource()
        let credentials = GenericCameraSource.Credentials(username: "fixture-user", password: "fixture-pass")
        #expect(camera.storeCredentials(credentials, vault: vault))
        #expect(camera.credentials(vault: vault) == credentials)
        #expect(vault.data(for: "generic-camera:" + camera.id.uuidString.lowercased()) != nil)
        let config = String(decoding: try JSONEncoder().encode(camera), as: UTF8.self)
        #expect(!config.contains("fixture-user") && !config.contains("fixture-pass"))
        #expect(camera.storeCredentials(nil, vault: vault))
        #expect(camera.credentials(vault: vault) == nil)
    }

    @Test func invalidHostsAndNonPathOverridesFailClosed() {
        var camera = GenericCameraSource()
        camera.name = "Camera"
        camera.host = "camera.local@camera.example"
        #expect(!camera.isValid)
        camera.host = "camera.local"
        camera.subStream = "rtsp://camera.example/stream"
        #expect(!camera.isValid)
        camera.subStream = "/stream#backchannel=1"
        #expect(!camera.isValid)
    }
}
