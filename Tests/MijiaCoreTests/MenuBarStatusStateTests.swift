import Foundation
import Testing
@testable import MijiaCore

@Suite("Menu bar icon state, width anti-jitter, and pinned readouts")
struct MenuBarStatusStateTests {

    // MARK: - MenuBarIconState

    @Test("Normal idle and active states use template house symbols with no badge")
    func iconStateNormal() {
        let idle = MenuBarIconState.resolve(MenuBarIconStateInput(
            activeDeviceCount: 0,
            panelHealth: .ok
        ))
        #expect(idle == MenuBarIconState(symbolName: "house", badge: .none))
        #expect(idle.usesTemplateRendering)

        let active = MenuBarIconState.resolve(MenuBarIconStateInput(
            activeDeviceCount: 2,
            panelHealth: .ok
        ))
        #expect(active == MenuBarIconState(symbolName: "house.fill", badge: .none))
        #expect(active.usesTemplateRendering)
    }

    @Test("Connecting and notConfigured do not raise an attention badge")
    func iconStateTransientAndUnconfigured() {
        let connecting = MenuBarIconState.resolve(MenuBarIconStateInput(panelHealth: .connecting))
        #expect(connecting.badge == .none)
        #expect(connecting.usesTemplateRendering)

        let unconfigured = MenuBarIconState.resolve(MenuBarIconStateInput(panelHealth: .notConfigured))
        #expect(unconfigured.badge == .none)
        #expect(unconfigured.usesTemplateRendering)
    }

    @Test("Offline, stale, or auth problems raise a template attention dot")
    func iconStateAttentionBadge() {
        let degraded = MenuBarIconState.resolve(MenuBarIconStateInput(
            activeDeviceCount: 1,
            panelHealth: .degraded(reason: "Device states may be out of date")
        ))
        #expect(degraded == MenuBarIconState(symbolName: "house.fill", badge: .attention))
        #expect(degraded.usesTemplateRendering)

        let disconnected = MenuBarIconState.resolve(MenuBarIconStateInput(
            activeDeviceCount: 0,
            panelHealth: .blocked(reason: "Disconnected", action: .openConnectionSettings)
        ))
        #expect(disconnected == MenuBarIconState(symbolName: "house", badge: .attention))
        #expect(disconnected.usesTemplateRendering)

        let expired = MenuBarIconState.resolve(MenuBarIconStateInput(
            miSessionBlocksControl: true,
            activeDeviceCount: 3,
            panelHealth: .blocked(reason: "Expired", action: .presentMiReauth)
        ))
        #expect(expired == MenuBarIconState(symbolName: "house.slash", badge: .attention))
        #expect(expired.usesTemplateRendering)
    }

    @Test("Active safety alert takes priority over attention and opts out of template rendering")
    func iconStateSafetyAlertPriority() {
        let hazardWhileBlocked = MenuBarIconState.resolve(MenuBarIconStateInput(
            miSessionBlocksControl: true,
            activeDeviceCount: 0,
            hasSafetyAlert: true,
            panelHealth: .blocked(reason: "Expired", action: .presentMiReauth)
        ))
        #expect(hazardWhileBlocked == MenuBarIconState(symbolName: "house.slash", badge: .safetyAlert))
        #expect(!hazardWhileBlocked.usesTemplateRendering)
    }

    @Test("Listening overrides the symbol to waveform while keeping badge semantics")
    func iconStateListening() {
        let listening = MenuBarIconState.resolve(MenuBarIconStateInput(
            isListening: true,
            activeDeviceCount: 1,
            hasSafetyAlert: false,
            panelHealth: .ok
        ))
        #expect(listening == MenuBarIconState(symbolName: "waveform", badge: .none))

        let listeningWithAlert = MenuBarIconState.resolve(MenuBarIconStateInput(
            isListening: true,
            hasSafetyAlert: true,
            panelHealth: .ok
        ))
        #expect(listeningWithAlert == MenuBarIconState(symbolName: "waveform", badge: .safetyAlert))
    }

    // MARK: - MenuBarWidthStabilizer

    @Test("Width stabilizer reserves initial width and grows immediately without clipping")
    func widthStabilizerGrowsImmediately() {
        var state = MenuBarWidthState()
        state = MenuBarWidthStabilizer.update(state: state, text: "24.5°", measuredWidth: 52.3)
        #expect(state.reservedWidth == 53)
        #expect(state.anchorCharCount == 5)
        #expect(state.pendingShrinkCount == 0)

        // Wider reading grows on the first update.
        state = MenuBarWidthStabilizer.update(state: state, text: "24.5° 55%", measuredWidth: 81.2)
        #expect(state.reservedWidth == 82)
        #expect(state.anchorCharCount == 9)
        #expect(state.pendingShrinkCount == 0)
    }

    @Test("Width stabilizer ignores small character-count fluctuations below threshold")
    func widthStabilizerIgnoresSmallDrops() {
        var state = MenuBarWidthStabilizer.update(state: MenuBarWidthState(), text: "10.0°", measuredWidth: 54)
        // Drop of 1 char ("9.9°" has 4 chars vs 5) is below default threshold (2): never shrinks.
        state = MenuBarWidthStabilizer.update(state: state, text: "9.9°", measuredWidth: 48)
        #expect(state.reservedWidth == 54)
        #expect(state.pendingShrinkCount == 0)

        state = MenuBarWidthStabilizer.update(state: state, text: "9.8°", measuredWidth: 48)
        #expect(state.reservedWidth == 54)
        #expect(state.pendingShrinkCount == 0)
    }

    @Test("Width stabilizer requires hysteresis before shrinking on a large char-count drop")
    func widthStabilizerShrinkHysteresis() {
        var state = MenuBarWidthStabilizer.update(state: MenuBarWidthState(), text: "24.5° 55%", measuredWidth: 82)

        // First shorter update (9 -> 5 chars, drop 4 >= 2): holds width and increments pending count.
        state = MenuBarWidthStabilizer.update(state: state, text: "24.5°", measuredWidth: 53)
        #expect(state.reservedWidth == 82)
        #expect(state.pendingShrinkCount == 1)

        // If it bounces back to a longer string, pending shrink resets.
        state = MenuBarWidthStabilizer.update(state: state, text: "24.5° 56%", measuredWidth: 82)
        #expect(state.reservedWidth == 82)
        #expect(state.pendingShrinkCount == 0)

        // Two consecutive shorter updates commit the shrink.
        state = MenuBarWidthStabilizer.update(state: state, text: "24.5°", measuredWidth: 53)
        #expect(state.reservedWidth == 82)
        #expect(state.pendingShrinkCount == 1)

        state = MenuBarWidthStabilizer.update(state: state, text: "24.4°", measuredWidth: 53)
        #expect(state.reservedWidth == 53)
        #expect(state.anchorCharCount == 5)
        #expect(state.pendingShrinkCount == 0)
    }

    @Test("Icon-only clears reserved width back to variable length")
    func widthStabilizerResetsOnEmpty() {
        let initial = MenuBarWidthStabilizer.update(state: MenuBarWidthState(), text: "24.5°", measuredWidth: 53)
        #expect(initial.reservedWidth == 53)

        let cleared = MenuBarWidthStabilizer.update(state: initial, text: nil, measuredWidth: 0)
        #expect(cleared == MenuBarWidthState(reservedWidth: nil, anchorCharCount: 0, pendingShrinkCount: 0))
    }

    // MARK: - MenuBarPinnedReadout

    @Test("Pinned readout normalization deduplicates, trims, and caps at 2")
    func pinnedReadoutNormalize() {
        let normalized = MenuBarPinnedReadout.normalize([
            "  ",
            "temp:env1",
            "temp:env1",
            " switch:light1 ",
            "hum:env2"
        ])
        #expect(normalized == ["temp:env1", "switch:light1"])
    }

    @Test("Pinned readout formats sensor temp/humidity and switch on/off states")
    func pinnedReadoutFormatting() {
        let readings = [
            EnvironmentReading(id: "env1", label: "客厅", roomName: "客厅", temperature: 24.6, humidity: 53)
        ]
        let devices = [
            SmartDevice(
                id: "light1",
                name: "客厅吸顶主灯光",
                roomId: "r1",
                roomName: "客厅",
                model: "yeelink.light.ceiling1",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.living", isOn: true))
            ),
            SmartDevice(
                id: "plug1",
                name: "书桌插座",
                roomId: "r2",
                roomName: "书房",
                model: "cuco.plug.cp1",
                isOnline: true,
                kind: .plug(PlugSpec(switchEntityId: "switch.desk", isOn: false))
            ),
            SmartDevice(
                id: "plug2",
                name: "阳台插座",
                roomId: "r3",
                roomName: "阳台",
                model: "cuco.plug.cp1",
                isOnline: false,
                kind: .plug(PlugSpec(switchEntityId: "switch.balcony", isOn: false))
            )
        ]

        L10n.$overrideTemperatureUnit.withValue(.celsius) {
            L10n.$overrideLanguage.withValue(.zhHans) {
                let formatted = MenuBarPinnedReadout.format(
                    pinnedIDs: ["temp:env1", "switch:light1"],
                    environmentReadings: readings,
                    devices: devices
                )
                #expect(formatted == "24.6°C · 客厅吸顶主灯… 开")

                let humAndOff = MenuBarPinnedReadout.format(
                    pinnedIDs: ["hum:env1", "switch:plug1"],
                    environmentReadings: readings,
                    devices: devices
                )
                #expect(humAndOff == "53% · 书桌插座 关")

                let offlineSwitch = MenuBarPinnedReadout.format(
                    pinnedIDs: ["switch:plug2"],
                    environmentReadings: readings,
                    devices: devices
                )
                #expect(offlineSwitch == "阳台插座 离线")
            }

            L10n.$overrideLanguage.withValue(.en) {
                let formatted = MenuBarPinnedReadout.format(
                    pinnedIDs: ["temp_hum:env1", "switch:plug1"],
                    environmentReadings: readings,
                    devices: devices
                )
                #expect(formatted == "24.6°C 53% · 书桌插座 Off")
            }
        }
    }

    @Test("HomeStore keeps existing readout when nothing is pinned and switches when pinned")
    @MainActor
    func storePinnedReadoutsIntegration() async throws {
        let suite = "MenuBarStatusStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: DemoHomeProvider(), defaults: defaults)
        store.startListening()
        try await store.waitForTestSnapshot()

        // Default: nothing pinned, existing behavior untouched.
        #expect(store.menuBarPinnedReadouts.isEmpty)
        let baselineText = store.menuBarText
        #expect(baselineText != nil)

        // Pinning a sensor and a switch overrides menuBarText and forces live polling.
        let sensor = try #require(store.environmentReadings.first(where: { $0.temperature != nil }))
        let light = try #require(store.devices.first(where: { $0.isPinnableMenuBarSwitch }))
        store.menuBarTargetId = "icon:only"
        #expect(store.menuBarText == nil)
        #expect(!store.menuBarShowsLiveReading)

        store.setMenuBarPinnedReadout("temp:\(sensor.id)", at: 0)
        store.setMenuBarPinnedReadout("switch:\(light.id)", at: 1)
        #expect(store.menuBarPinnedReadouts == ["temp:\(sensor.id)", "switch:\(light.id)"])
        #expect(store.menuBarShowsLiveReading)
        let pinnedText = try #require(store.menuBarText)
        #expect(pinnedText.contains(" · "))

        // Referenced IDs include pinned devices/sensors for dual-source canonical preservation.
        let referenced = DevicePreferenceIndex.referencedIDs(defaults: defaults)
        #expect(referenced.contains(sensor.id))
        #expect(referenced.contains(light.id))

        // Clearing both slots returns to icon:only.
        store.setMenuBarPinnedReadout("", at: 1)
        store.setMenuBarPinnedReadout("", at: 0)
        #expect(store.menuBarPinnedReadouts.isEmpty)
        #expect(store.menuBarText == nil)
    }
}
