import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// The optional DDC/CI monitor control: silent while off, read on panel open, writes only the
/// four supported VCP codes and never power (0xD6).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExternalDisplayStoreTests {
    final class MockTransport: DDCCITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _listCalls = 0
        private var _requests: [[UInt8]] = []
        var failWrites = false
        let displays: [DDCCIDisplayDescriptor]

        init(displays: [DDCCIDisplayDescriptor]) { self.displays = displays }

        var listCalls: Int { lock.withLock { _listCalls } }
        var requests: [[UInt8]] { lock.withLock { _requests } }
        var callCount: Int { lock.withLock { _listCalls + _requests.count } }
        /// `(code, value)` of every Set VCP frame (`0x84 0x03 code hi lo`).
        var writes: [(UInt8, UInt16)] {
            requests.filter { $0.count > 4 && $0[0] == 0x84 && $0[1] == 0x03 }
                .map { ($0[2], UInt16($0[3]) << 8 | UInt16($0[4])) }
        }

        func listDisplays() throws -> [DDCCIDisplayDescriptor] {
            lock.withLock { _listCalls += 1 }
            return displays
        }

        func exchange(displayId: String, chipAddress: UInt8, request: [UInt8], replyLength: Int, readDelay: TimeInterval) throws -> [UInt8] {
            lock.withLock { _requests.append(request) }
            if request.count > 2, request[0] == 0x82, request[1] == 0x01 {
                let code = request[2]
                let (maximum, current): (UInt8, UInt8) = switch code {
                case 0x60: (0x1B, 0x0F)
                case 0x8D: (2, 2)
                default: (100, 60)
                }
                let reply = [UInt8(0x6E), 0x88, 0x02, 0x00, code, 0x00, 0x00, maximum, 0x00, current]
                return reply + [reply.reduce(0x50, ^)]
            }
            if request.first == 0x84, failWrites { throw DDCCIError.ioFailure(-1) }
            // Capabilities requests: answer an empty block so the controller stops asking.
            if request.count > 1, request[1] == 0xF3 {
                let reply = [UInt8(0x6E), 0x83, 0xE3, request[2], request[3]]
                return reply + [reply.reduce(0x50, ^)]
            }
            return []
        }
    }

    private static let g27u = DDCCIDisplayDescriptor(id: "g27u", name: "Redmi G27U", manufacturer: "RED", model: "G27U")

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.external-display.\(UUID().uuidString)")!
    }

    private func enabledStore(_ mock: MockTransport) async -> ExternalDisplayStore {
        let defaults = freshDefaults()
        defaults.set(true, forKey: ExternalDisplayStore.enabledKey)
        let store = ExternalDisplayStore(defaults: defaults, transport: mock)
        store.panelDidOpen()
        await store.waitForPendingWrites()
        return store
    }

    @Test("Off by default: opening the panel or refreshing never touches the transport")
    func disabledMakesNoCalls() async {
        let mock = MockTransport(displays: [Self.g27u])
        let store = ExternalDisplayStore(defaults: freshDefaults(), transport: mock)
        #expect(store.isEnabled == false)
        store.panelDidOpen()
        store.refresh()
        store.setBrightness(displayId: "g27u", percent: 40)
        store.setInputSource(displayId: "g27u", source: .hdmi1)
        store.setMute(displayId: "g27u", muted: true)
        await store.waitForPendingWrites()
        #expect(mock.callCount == 0)
        #expect(store.showsPanelCard == false)
    }

    @Test("Enabled + panel open lists the Redmi G27U with its state and default inputs")
    func panelOpenLoadsDisplays() async {
        let mock = MockTransport(displays: [Self.g27u])
        let store = await enabledStore(mock)
        #expect(mock.listCalls == 1)
        guard let display = store.displays.first else {
            Issue.record("expected the Redmi G27U to be listed")
            return
        }
        #expect(display.descriptor.name == "Redmi G27U")
        #expect(display.isRedmiOrXiaomi)
        #expect(display.brightnessPercent == 60)
        #expect(display.inputSource == .dp1)
        #expect(display.inputSources == [.dp1, .dp2, .hdmi1, .hdmi2, .usbC])
        #expect(display.volumePercent == 60)
        #expect(store.showsPanelCard)
    }

    @Test("Controls send brightness, HDMI 1 / DP 1, volume and mute — never 0xD6")
    func writesUseSupportedCodes() async {
        let mock = MockTransport(displays: [Self.g27u])
        let store = await enabledStore(mock)
        store.setBrightness(displayId: "g27u", percent: 40)
        await store.waitForPendingWrites()
        store.setInputSource(displayId: "g27u", source: .hdmi1)
        await store.waitForPendingWrites()
        store.setInputSource(displayId: "g27u", source: .dp1)
        await store.waitForPendingWrites()
        store.setVolume(displayId: "g27u", percent: 25)
        await store.waitForPendingWrites()
        store.setMute(displayId: "g27u", muted: true)
        await store.waitForPendingWrites()

        let writes = mock.writes
        #expect(writes.contains { $0 == (0x10, 40) })
        #expect(writes.contains { $0 == (0x60, 0x11) })
        #expect(writes.contains { $0 == (0x60, 0x0F) })
        #expect(writes.contains { $0 == (0x62, 25) })
        #expect(writes.contains { $0 == (0x8D, 1) })
        #expect(!mock.requests.contains { $0.contains(0xD6) && $0.count > 2 && $0[2] == 0xD6 })
        #expect(store.displays.first?.inputSource == .dp1)
        #expect(store.displays.first?.isMuted == true)
        #expect(store.errorMessage == nil)
    }

    @Test("A drag coalesces into one write of the latest value")
    func brightnessDragCoalesces() async {
        let mock = MockTransport(displays: [Self.g27u])
        let defaults = freshDefaults()
        defaults.set(true, forKey: ExternalDisplayStore.enabledKey)
        // Every set call lands before the write task gets to run, so no interval is needed.
        let store = ExternalDisplayStore(defaults: defaults, transport: mock)
        store.panelDidOpen()
        await store.waitForPendingWrites()
        for value in [10, 20, 30, 70] { store.setBrightness(displayId: "g27u", percent: value) }
        await store.waitForPendingWrites()
        #expect(mock.writes.filter { $0.0 == 0x10 }.map(\.1) == [70])
    }

    @Test("A failed write explains how to enable DDC/CI")
    func failedWriteShowsFriendlyMessage() async {
        let mock = MockTransport(displays: [Self.g27u])
        let store = await enabledStore(mock)
        mock.failWrites = true
        store.setInputSource(displayId: "g27u", source: .hdmi2)
        await store.waitForPendingWrites()
        #expect(store.errorMessage?.contains("DDC/CI") == true)
    }

    @Test("Turning the switch off clears everything and stops further reads")
    func disablingClearsState() async {
        let mock = MockTransport(displays: [Self.g27u])
        let store = await enabledStore(mock)
        #expect(!store.displays.isEmpty)
        store.setEnabled(false)
        #expect(store.displays.isEmpty)
        #expect(store.showsPanelCard == false)
        let callsAfterDisable = mock.callCount
        store.panelDidOpen()
        store.refresh()
        store.setVolume(displayId: "g27u", percent: 10)
        await store.waitForPendingWrites()
        #expect(mock.callCount == callsAfterDisable)
    }

    @Test("The preference persists under external_display_ddc_enabled")
    func preferencePersists() {
        let defaults = freshDefaults()
        ExternalDisplayStore(defaults: defaults, transport: MockTransport(displays: [])).setEnabled(true)
        #expect(defaults.bool(forKey: "external_display_ddc_enabled"))
        #expect(ExternalDisplayStore(defaults: defaults, transport: MockTransport(displays: [])).isEnabled)
    }
}
