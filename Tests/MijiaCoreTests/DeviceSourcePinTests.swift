import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct DeviceSourcePinTests {
    @Test("Pinning a card persists immediately and clearing it returns to automatic")
    func pinAndClearPersist() {
        let suite = "test.source.pin.store.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: DemoHomeProvider(), defaultsSuiteName: suite)

        store.pinDeviceSource("card-a", to: .xiaomiCloud)
        #expect(store.pinnedSource(for: "card-a") == .xiaomiCloud)
        let defaults = UserDefaults(suiteName: suite)!
        #expect(DeviceSourcePinStorage.load(defaults: defaults)["card-a"] == .xiaomiCloud)
        #expect(DevicePreferenceIndex.referencedIDs(defaults: defaults).contains("card-a"))

        store.pinDeviceSource("card-a", to: nil)
        #expect(store.pinnedSource(for: "card-a") == nil)
        #expect(DeviceSourcePinStorage.load(defaults: defaults)["card-a"] == nil)
    }
}
