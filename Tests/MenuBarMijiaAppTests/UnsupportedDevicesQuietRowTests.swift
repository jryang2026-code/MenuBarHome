import AppKit
import Foundation
import PreferencesTestSupport
import SwiftUI
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@MainActor
@Suite("UnsupportedDevicesQuietRow (#15)", .serialized)
struct UnsupportedDevicesQuietRowTests {
    private actor MockScanRecorder {
        var callCount = 0
        var nextResult: [UnsupportedDevice]

        init(nextResult: [UnsupportedDevice] = []) {
            self.nextResult = nextResult
        }

        func setNextResult(_ devices: [UnsupportedDevice]) {
            nextResult = devices
        }

        func recordAndReturn() -> [UnsupportedDevice] {
            callCount += 1
            return nextResult
        }
    }

    private func makeHAStore() async throws -> HomeStore {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(HomeBackend.homeAssistant.rawValue, forKey: "home_backend")
        defaults.set(true, forKey: "ha_connection_configured")
        defaults.set("https://ha.example.local:8123", forKey: "ha_server_url")

        let device = SmartDevice(
            id: "dev_supported",
            name: "客厅灯",
            roomId: "living",
            roomName: "客厅",
            model: "yeelink.light.color4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true))
        )
        var snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 0)],
            devices: [device]
        )
        snapshot.isInitialLoadComplete = true
        let store = HomeStore(provider: MockHomeProvider(snapshot: snapshot), defaults: defaults)
        try await store.waitForTestSnapshot()
        return store
    }

    @Test("Count 0 or uncached scan stays hidden and never triggers an extra network scan")
    func hiddenWhenCountZeroOrUncached() async throws {
        let store = try await makeHAStore()
        let scanner = UnsupportedDeviceScanner.makeForTesting()
        let recorder = MockScanRecorder()
        scanner.homeAssistantScanOverride = { _, _, _ in
            await recorder.recordAndReturn()
        }

        // 1. No cached scan -> hidden, 0 scan calls.
        #expect(scanner.cachedUnsupportedCount(for: store) == 0)
        #expect(UnsupportedDevicesQuietRow.labelText(count: 0) == "")
        let zeroHost = NSHostingView(rootView: UnsupportedDevicesQuietRow(count: 0) {}.frame(width: 320))
        #expect(zeroHost.fittingSize.height == 0)

        _ = NSHostingView(rootView: ControlCenterPanel(store: store).frame(width: 360, height: 500))
        _ = NSHostingView(rootView: ClassicControlCenterPanel(store: store).frame(width: 360, height: 500))
        #expect(await recorder.callCount == 0)

        // 2. Cached scan with 0 unsupported devices -> still hidden.
        await scanner.scan(store: store)
        #expect(await recorder.callCount == 1)
        #expect(scanner.lastScannedAt != nil)
        #expect(scanner.cachedUnsupportedCount(for: store) == 0)

        // 3. Cached scan with 3 devices becomes hidden when context changes.
        scanner.seedCachedScanForTesting(
            devices: [
                UnsupportedDevice(id: "u1", name: "设备1", model: "m1", reason: .unsupportedEntities),
                UnsupportedDevice(id: "u2", name: "设备2", model: "m2", reason: .unsupportedEntities),
                UnsupportedDevice(id: "u3", name: "设备3", model: "m3", reason: .unsupportedEntities),
            ],
            store: store
        )
        #expect(scanner.cachedUnsupportedCount(for: store) == 3)
        store.serverURLString = "https://other-ha.example.local:8123"
        #expect(scanner.cachedUnsupportedCount(for: store) == 0)
        #expect(await recorder.callCount == 1)
    }

    @Test("Count N renders localized text and clicking opens Settings at scanUnsupportedDevices")
    func rendersLocalizedCountAndOpensSettings() async throws {
        let store = try await makeHAStore()
        let scanner = UnsupportedDeviceScanner.makeForTesting()
        let opener = SettingsWindowOpener.shared
        let prevTab = opener.requestedTab
        let prevAnchor = opener.requestedAnchor
        let prevOpen = opener.open
        defer {
            opener.requestedTab = prevTab
            opener.requestedAnchor = prevAnchor
            opener.open = prevOpen
        }

        let mockDevices = [
            UnsupportedDevice(id: "u1", name: "割草机", model: "vendor.bot.1", reason: .unsupportedEntities),
            UnsupportedDevice(id: "u2", name: "泳池泵", model: "vendor.pump.2", reason: .unsupportedEntities),
            UnsupportedDevice(id: "u3", name: "灌溉阀", model: "vendor.valve.3", reason: .unsupportedEntities),
        ]
        let recorder = MockScanRecorder(nextResult: Array(mockDevices.prefix(1)))
        scanner.homeAssistantScanOverride = { _, _, _ in
            await recorder.recordAndReturn()
        }

        // Count = 1
        await scanner.scan(store: store)
        #expect(await recorder.callCount == 1)
        #expect(scanner.cachedUnsupportedCount(for: store) == 1)
        #expect(L10n.$overrideLanguage.withValue(.zhHans) {
            UnsupportedDevicesQuietRow.labelText(count: 1)
        } == "1 台设备暂不支持显示")
        #expect(L10n.$overrideLanguage.withValue(.zhHant) {
            UnsupportedDevicesQuietRow.labelText(count: 1)
        } == "1 臺裝置暫不支援顯示")
        #expect(L10n.$overrideLanguage.withValue(.en) {
            UnsupportedDevicesQuietRow.labelText(count: 1)
        } == "1 device not supported yet")

        // Count = 3
        await recorder.setNextResult(mockDevices)
        await scanner.scan(store: store)
        #expect(await recorder.callCount == 2)
        #expect(scanner.cachedUnsupportedCount(for: store) == 3)
        #expect(L10n.$overrideLanguage.withValue(.zhHans) {
            UnsupportedDevicesQuietRow.labelText(count: 3)
        } == "3 台设备暂不支持显示")
        #expect(L10n.$overrideLanguage.withValue(.zhHant) {
            UnsupportedDevicesQuietRow.labelText(count: 3)
        } == "3 臺裝置暫不支援顯示")
        #expect(L10n.$overrideLanguage.withValue(.en) {
            UnsupportedDevicesQuietRow.labelText(count: 3)
        } == "3 devices not supported yet")

        let rowHost = NSHostingView(
            rootView: UnsupportedDevicesQuietRow(count: 3) {
                SettingsWindowOpener.shared.show(tab: .about, anchor: .scanUnsupportedDevices)
            }.frame(width: 320)
        )
        #expect(rowHost.fittingSize.height >= DesignTokens.minHitTarget)

        var didInvokeOpen = false
        opener.open = { didInvokeOpen = true }
        SettingsWindowOpener.shared.show(tab: .about, anchor: .scanUnsupportedDevices)
        #expect(didInvokeOpen)
        #expect(opener.requestedTab == .about)
        #expect(opener.requestedAnchor == .scanUnsupportedDevices)
        #expect(await recorder.callCount == 2)
    }
}
