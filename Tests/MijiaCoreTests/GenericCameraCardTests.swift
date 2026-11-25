import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct GenericCameraCardTests {
    @Test @MainActor func savedCameraIsAReadOnlyCardWithVaultCredentials() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        let vault = CredentialVault(storage: MemoryVaultStorage().storage)
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()),
                              credentialVault: vault, defaults: defaults)
        var camera = GenericCameraSource()
        camera.name = "Workshop Camera"
        camera.host = "camera.local"
        let credentials = GenericCameraSource.Credentials(username: "fixture-user", password: "fixture-pass")
        try #require(store.saveGenericCamera(camera, credentials: credentials, confirmedPlaintext: false))
        let persisted = try #require(defaults.data(forKey: HomeStore.genericCameraSourcesKey))
        let json = String(decoding: persisted, as: UTF8.self)
        #expect(!json.contains("fixture-user") && !json.contains("fixture-pass"))
        #expect(store.genericCameraCredentials(camera) == credentials)
        #expect(vault.data(for: "generic-camera:" + camera.id.uuidString.lowercased()) != nil)
        let card = try #require(store.visibleDevices.first(where: { $0.id == camera.deviceID }))
        #expect(card.name == camera.name)
        #expect(!card.isPrimaryToggleable)
        #expect(store.evaluateDeviceControlGate(deviceId: card.id).allowed)

        let reopened = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()),
                                 credentialVault: vault, defaults: defaults)
        #expect(reopened.genericCamera(for: camera.deviceID) == camera)
        #expect(reopened.genericCameraCredentials(camera) == credentials)
        #expect(reopened.visibleDevices.contains(where: { $0.id == camera.deviceID }))
        reopened.hasCompletedOnboarding = false
        #expect(!reopened.visibleDevices.contains(where: { $0.id == camera.deviceID }))

        camera.host = "camera.example"
        #expect(!store.saveGenericCamera(camera, credentials: credentials, confirmedPlaintext: false))
        #expect(defaults.data(forKey: HomeStore.genericCameraSourcesKey) == persisted)
        #expect(store.saveGenericCamera(camera, credentials: credentials, confirmedPlaintext: true))
        #expect(store.hasGenericCameraConsent(camera))
        camera.port = 8557
        #expect(!store.hasGenericCameraConsent(camera))
        #expect(store.removeGenericCamera(camera))
        #expect(store.genericCameraCredentials(camera) == nil)
        #expect(!store.visibleDevices.contains(where: { $0.id == camera.deviceID }))
    }
}
