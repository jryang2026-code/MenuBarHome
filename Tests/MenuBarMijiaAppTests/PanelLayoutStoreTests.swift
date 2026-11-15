import Foundation
import Testing
@testable import MenuBarMijiaApp

/// The panel's saved order, sizes and group membership: published at once, persisted to the same keys.
@MainActor
struct PanelLayoutStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.panellayout.\(UUID().uuidString)")!
    }

    @Test("Writes show immediately and land on the existing keys")
    func writesPersistToKeys() {
        let defaults = freshDefaults()
        let layout = PanelLayoutStore(defaults: defaults)
        layout.setOrder(["b", "a"])
        layout.setSize(.full, of: "a", scope: "all")
        layout.assign("a", toGroup: "g1")

        #expect(layout.order == ["b", "a"])
        #expect(layout.size(of: "a", scope: "all") == .full)
        #expect(layout.groupMap == ["a": "g1"])
    }

    @Test("A new instance reads what an earlier one saved")
    func reloadsSavedLayout() {
        let defaults = freshDefaults()
        PanelLayoutStore(defaults: defaults).setSize(.panel, of: "ac", scope: "room-1")
        let reopened = PanelLayoutStore(defaults: defaults)
        #expect(reopened.size(of: "ac", scope: "room-1") == .panel)
        #expect(reopened.size(of: "ac", scope: "all") == .auto)
    }

    @Test("Deleting a group sends its devices back to the ungrouped section")
    func removeGroup() {
        let layout = PanelLayoutStore(defaults: freshDefaults())
        layout.assign("a", toGroup: "g1")
        layout.assign("b", toGroup: "g2")
        layout.removeGroup("g1")
        #expect(layout.groupMap == ["b": "g2"])
    }

    @Test("A key written elsewhere reaches the store")
    func externalWriteReloads() async throws {
        let defaults = freshDefaults()
        let layout = PanelLayoutStore(defaults: defaults)
        defaults.set(DeviceLayoutPrefs.encodeOrder(["x", "y"]), forKey: DeviceLayoutPrefs.orderKey)
        // The change notification may be delivered on the next main-queue turn.
        for _ in 0..<200 where layout.order != ["x", "y"] {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(layout.order == ["x", "y"])
        #expect(layout.externalDecodeCount == 1)
    }

    @Test("Self-writes and unrelated UserDefaults keys skip JSON decoding")
    func selfWritesAndUnrelatedKeysSkipExternalDecode() {
        let defaults = freshDefaults()
        let otherDefaults = freshDefaults()
        let layout = PanelLayoutStore(defaults: defaults)

        layout.setOrder(["a", "b"])
        layout.setSize(.full, of: "a", scope: "all")
        layout.assign("a", toGroup: "g1")
        defaults.set("unrelated", forKey: "some_other_preference")
        otherDefaults.set(DeviceLayoutPrefs.encodeOrder(["z"]), forKey: DeviceLayoutPrefs.orderKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: otherDefaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        #expect(layout.externalDecodeCount == 0)
        #expect(layout.order == ["a", "b"])
    }
}
