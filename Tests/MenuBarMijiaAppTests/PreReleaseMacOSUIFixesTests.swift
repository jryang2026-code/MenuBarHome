import AppKit
import Foundation
import Testing
@testable import MijiaCore
@testable import MenuBarMijiaApp

extension PanelPresentationTests {
@MainActor
@Suite("Pre-release macOS UI & integration fixes", .serialized)
struct PreReleaseMacOSUIFixesTests {

    // MARK: - F6 & F7: Quick-index & keyboard navigation follow drawn order per theme

    @Test("PanelQuickIndexState scopes registrations per theme and drives focus/Space across >9 drawn cards")
    func quickIndexNavigationFollowsDrawnOrderPerTheme() async throws {
        let suite = "test.prerelease.quicknav.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            PanelQuickIndexState.shared.clear()
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")

        let room = RoomArea(id: "r1", name: "客厅", sortOrder: 0)
        let devices = (1...11).map { idx in
            SmartDevice(
                id: "d\(idx)",
                name: "灯 \(idx)",
                roomId: room.id,
                roomName: room.name,
                model: "test.light",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.d\(idx)", isOn: true))
            )
        }
        let mock = MockHomeProvider(snapshot: SynthesizedHome(rooms: [room], devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        // Reversed drawn order of 11 cards: badges stop at 9, but ↑/↓ and Space still reach d2 and d1.
        let drawnIds = devices.map(\.id).reversed().map { $0 }
        let drawnOrder = PanelQuickIndexOrder(deviceIds: drawnIds)
        #expect(drawnOrder.deviceIds.count == 9)
        #expect(drawnOrder.navigableIds.count == 11)

        PanelQuickIndexState.shared.register(drawnOrder, theme: .classic)
        // Liquid Glass has no registration, so clearing `.liquidGlass` must leave `.classic` intact.
        PanelQuickIndexState.shared.clear(theme: .liquidGlass)
        #expect(PanelQuickIndexState.shared.registeredTheme == .classic)

        // First Down arrow focuses the first drawn card (`d11`), not `store.orderedVisibleDevices[0]` (`d1`).
        PanelQuickIndexState.shared.moveFocus(delta: 1, store: store, theme: .classic)
        #expect(store.focusedDeviceId == "d11")

        // Wrapping backwards reaches the 11th drawn card (`d1`), proving >9 cards remain keyboard-reachable.
        PanelQuickIndexState.shared.moveFocus(delta: -1, store: store, theme: .classic)
        #expect(store.focusedDeviceId == "d1")

        // Space with no focus toggles the first drawn card (`d11`).
        store.focusedDeviceId = nil
        let before = await mock.executedCommands.count
        PanelQuickIndexState.shared.toggleFocusedDevice(store: store, theme: .classic)
        for _ in 0..<100 {
            let count = await mock.executedCommands.count
            if count > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let commands = await mock.executedCommands
        #expect(commands.last == .setLightPower(entityId: "light.d11", isOn: false))
    }

    // MARK: - F13 & PR #103 #7: Slider step snapping, symmetric downward step, and finite overflow guard

    @Test("SliderStepSnap steps symmetrically from lowerBound/upperBound and guards extreme finite span overflow")
    func sliderStepSnapFromLowerBoundAndUpperBound() {
        // Odd step starting at 1: steps land on 1, 3, 5, ..., 99 (never 0, 2, 4).
        #expect(SliderStepSnap.snap(1.0, in: 1...99, step: 2) == 1)
        #expect(SliderStepSnap.snap(2.1, in: 1...99, step: 2) == 3)
        #expect(SliderStepSnap.snap(98.4, in: 1...99, step: 2) == 99)

        // Kelvin range 2000...6535 with step 100: grid hits 2000, 2100, ..., 6500, and top end reaches 6535.
        #expect(SliderStepSnap.snap(2040, in: 2000...6535, step: 100) == 2000)
        #expect(SliderStepSnap.snap(2060, in: 2000...6535, step: 100) == 2100)
        #expect(SliderStepSnap.snap(6510, in: 2000...6535, step: 100) == 6500)
        #expect(SliderStepSnap.snap(6520, in: 2000...6535, step: 100) == 6535)
        #expect(SliderStepSnap.snap(6535, in: 2000...6535, step: 100) == 6535)

        // Keyboard / VoiceOver discrete stepping does not skip `lastGrid` (`6500` / `8`) when stepping down from `upperBound`.
        #expect(SliderStepSnap.step(from: 6500, by: 100, in: 2000...6535, step: 100) == 6535)
        #expect(SliderStepSnap.step(from: 6535, by: -100, in: 2000...6535, step: 100) == 6500)
        #expect(SliderStepSnap.step(from: 6500, by: -100, in: 2000...6535, step: 100) == 6400)

        #expect(SliderStepSnap.step(from: 0, by: 8, in: 0...10, step: 8) == 8)
        #expect(SliderStepSnap.step(from: 8, by: 8, in: 0...10, step: 8) == 10)
        #expect(SliderStepSnap.step(from: 10, by: -8, in: 0...10, step: 8) == 8)
        #expect(SliderStepSnap.step(from: 8, by: -8, in: 0...10, step: 8) == 0)

        // Extreme finite bounds whose difference overflows to `+infinity` must never produce `NaN`.
        let extreme: ClosedRange<Double> = -1e308...1e308
        #expect((extreme.upperBound - extreme.lowerBound).isInfinite)
        #expect(SliderStepSnap.snap(0, in: extreme, step: 1) == -1e308)
        #expect(SliderStepSnap.step(from: 0, by: 1, in: extreme, step: 1) == -1e308)
    }

    // MARK: - F23: Confirmed URL toggle does not invert when device already flipped

    @Test("Confirming an untrusted toggle link does not reverse a device whose state already changed")
    func confirmedToggleSkipsWhenStateAlreadyFlipped() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.prerelease.urltoggle.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let lamp = SmartDevice(
                id: "dev_lamp",
                name: "Study Lamp",
                roomId: "study",
                roomName: "Study",
                model: "test.light",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.lamp", isOn: true))
            )
            let mock = MockHomeProvider(snapshot: SynthesizedHome(
                rooms: [RoomArea(id: "study", name: "Study", sortOrder: 0)],
                devices: [lamp]
            ))
            let store = HomeStore(provider: mock, defaultsSuiteName: suite)
            try await store.waitForTestSnapshot()

            let handler = URLCommandHandler()
            handler.windowVisibilityHandler = {}
            handler.confirmationHandler = { _ in
                // Simulate a background poll reporting that the lamp was already turned off via a wall switch
                // while the user was reading "Turn off Study Lamp?" on the confirmation sheet.
                store.devices = [
                    SmartDevice(
                        id: "dev_lamp",
                        name: "Study Lamp",
                        roomId: "study",
                        roomName: "Study",
                        model: "test.light",
                        isOnline: true,
                        kind: .light(LightSpec(entityId: "light.lamp", isOn: false))
                    )
                ]
                return true
            }

            let link = try #require(URL(string: "menumijia://toggle?device=dev_lamp&id=ext-1"))
            await handler.handle(link, in: store)

            // No reverse toggle command was sent; the lamp stays off and feedback reports it is already off.
            let commands = await mock.executedCommands
            #expect(commands.isEmpty)
            #expect(store.devices.first(where: { $0.id == "dev_lamp" })?.isActiveOn == false)
            #expect(store.lastRaycastCommandFeedback?.isError == false)
            #expect(store.lastRaycastCommandFeedback?.message == "Study Lamp is already off")
        }
    }

    // MARK: - F30a: UnsupportedDeviceScanner invalidates cached findings when context changes offscreen

    @Test("UnsupportedDeviceScanner.invalidateIfContextChanged clears stale scan findings after offscreen context change")
    func unsupportedScannerResetClearsState() async throws {
        let suite = "test.prerelease.scanner.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let scanner = UnsupportedDeviceScanner.shared
        defer {
            scanner.reset()
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        store.homeBackend = .demo

        await scanner.scan(store: store)
        #expect(scanner.lastScannedAt != nil)

        // Same context -> keeps cached scan timestamp.
        scanner.invalidateIfContextChanged(for: store)
        #expect(scanner.lastScannedAt != nil)

        // Changing backend or HA server URL while PrivacySettingsTab is unmounted invalidates the stale scan.
        store.serverURLString = "https://other-ha.example:8123"
        scanner.invalidateIfContextChanged(for: store)
        #expect(scanner.devices.isEmpty)
        #expect(scanner.errorMessage == nil)
        #expect(scanner.lastScannedAt == nil)
        #expect(scanner.isScanning == false)
    }

    // MARK: - F30f: moveFavorite inside a room cut preserves global favorite order

    @Test("Reordering favorites inside a filtered room preserves other rooms' global favorite positions")
    func moveFavoriteInRoomPreservesGlobalOrder() async throws {
        let suite = "test.prerelease.favorder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")

        let living = RoomArea(id: "living", name: "客厅", sortOrder: 0)
        let bedroom = RoomArea(id: "bedroom", name: "卧室", sortOrder: 1)
        let study = RoomArea(id: "study", name: "书房", sortOrder: 2)
        let devices = [
            SmartDevice(id: "l1", name: "客厅灯", roomId: "living", roomName: "客厅", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.l1", isOn: true))),
            SmartDevice(id: "b1", name: "主灯", roomId: "bedroom", roomName: "卧室", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.b1", isOn: true))),
            SmartDevice(id: "s1", name: "台灯", roomId: "study", roomName: "书房", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.s1", isOn: true))),
            SmartDevice(id: "b2", name: "床头灯", roomId: "bedroom", roomName: "卧室", model: "m", isOnline: true, kind: .light(LightSpec(entityId: "light.b2", isOn: true)))
        ]
        let mock = MockHomeProvider(snapshot: SynthesizedHome(rooms: [living, bedroom, study], devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()

        let initialOrder = ["l1", "b1", "s1", "b2"]
        store.favoriteDeviceIds = Set(initialOrder)
        store.favoriteOrder = initialOrder

        // Filter to Bedroom (`b1`, `b2`) and move `b2` left ahead of `b1`.
        #expect(store.selectRoom("bedroom"))
        store.moveFavorite(deviceId: "b2", direction: -1)

        // `l1` stays at index 0 and `s1` stays after Bedroom's pair; Bedroom was NOT hoisted ahead of Living!
        #expect(store.favoriteOrder == ["l1", "b2", "b1", "s1"])
    }

    // MARK: - C2: Context polling only runs when enabled rules require it

    @Test("AutomationEngine.needsContextPolling skips polling when no enabled rule uses hardware/context sensors")
    func needsContextPollingSkipsIdleRules() {
        #expect(AutomationEngine.needsContextPolling([]) == false)

        // Disabled camera rule -> no polling.
        let disabledCamera = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: ["d1"], isOn: true),
            isEnabled: false
        )
        #expect(AutomationEngine.needsContextPolling([disabledCamera]) == false)

        // Enabled notification-driven rules without network-specific Wi-Fi -> no polling.
        let awayRule = AutomationRule(
            trigger: .away,
            action: .devices(ids: ["d1"], isOn: false),
            isEnabled: true
        )
        let displayRule = AutomationRule(
            trigger: .externalDisplayConnected,
            action: .devices(ids: ["d1"], isOn: true),
            isEnabled: true
        )
        #expect(AutomationEngine.needsContextPolling([awayRule, displayRule]) == false)

        // Away rule constrained to a specific Wi-Fi SSID needs `lastKnownWiFi` polling.
        let wifiScopedAway = AutomationRule(
            trigger: .away,
            action: .devices(ids: ["d1"], isOn: false),
            isEnabled: true,
            conditions: AutomationConditions(wifi: .inAny(["HomeWiFi"]))
        )
        #expect(AutomationEngine.needsContextPolling([wifiScopedAway]) == true)

        // Enabled camera rule needs context polling.
        let activeCamera = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: ["d1"], isOn: true),
            isEnabled: true
        )
        #expect(AutomationEngine.needsContextPolling([activeCamera]) == true)
    }

    // MARK: - Section 5: HAConnectionSaveGuard protects stored token when Keychain is temporarily unavailable

    @Test("HAConnectionSaveGuard never wipes a stored token when initial Keychain lookup was unavailable")
    func haConnectionSaveGuardProtectsUnavailableKeychainToken() {
        // Still unavailable on Save -> block instead of writing `""`.
        let blocked = HAConnectionSaveGuard.resolve(
            draftToken: "   ",
            initialLookupWasUnavailable: true,
            retryLookup: { .unavailable }
        )
        #expect(blocked == .blockedKeychainUnavailable)

        // Keychain unlocked before Save -> recover existing token automatically.
        let recovered = HAConnectionSaveGuard.resolve(
            draftToken: "",
            initialLookupWasUnavailable: true,
            retryLookup: { .value(Data("secret-ha-token".utf8)) }
        )
        #expect(recovered == .proceed(token: "secret-ha-token", clearUnavailableFlag: true))

        // User explicitly typed a new token despite initial unavailability -> save user's new token.
        let replaced = HAConnectionSaveGuard.resolve(
            draftToken: "new-token",
            initialLookupWasUnavailable: true,
            retryLookup: { .unavailable }
        )
        #expect(replaced == .proceed(token: "new-token", clearUnavailableFlag: true))

        // Initial lookup succeeded (not unavailable) and user cleared field -> intentional clear proceeds.
        let intentionalClear = HAConnectionSaveGuard.resolve(
            draftToken: "",
            initialLookupWasUnavailable: false,
            retryLookup: { .unavailable }
        )
        #expect(intentionalClear == .proceed(token: "", clearUnavailableFlag: false))
    }

    @Test("HAConnectionSaveGuard protects an injected CredentialVault on HomeStore and recovers once unlocked")
    func haConnectionSaveGuardProtectsInjectedVaultEndToEnd() async throws {
        final class ToggleableVaultBox: @unchecked Sendable {
            private let lock = NSLock()
            var blob: Data?
            var isReadable: Bool

            init(blob: Data?, isReadable: Bool) {
                self.blob = blob
                self.isReadable = isReadable
            }

            var storage: CredentialVault.Storage {
                CredentialVault.Storage(
                    read: { [self] in
                        lock.withLock {
                            guard isReadable else { return .unavailable }
                            return blob.map(CredentialVault.Storage.ReadResult.found) ?? .notFound
                        }
                    },
                    write: { [self] data in
                        lock.withLock {
                            guard isReadable else { return false }
                            blob = data
                            return true
                        }
                    }
                )
            }
        }

        let suite = "test.prerelease.havault.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")

        let seeded = try #require(CredentialVault.encode([
            HAConnectionSaveGuard.haTokenAccount: Data("secret-ha-token".utf8)
        ]))
        let box = ToggleableVaultBox(blob: seeded, isReadable: false)
        let vault = CredentialVault(storage: box.storage)

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        store.credentialVault = vault
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        // 1. Settings opens while injected vault is unreadable: draft is empty, unavailable flag is latched.
        //    Conversely, if an environment override (`HA_ACCESS_TOKEN`) supplied a non-empty token while
        //    the vault was unreadable, `isInitialLookupUnavailable` stays false so an explicit clear is honored.
        #expect(HAConnectionSaveGuard.isInitialLookupUnavailable(loadedToken: "env-token", vault: vault) == false)
        let initial = HAConnectionSaveGuard.loadInitialToken(from: store)
        #expect(initial.token == "")
        #expect(initial.lookupWasUnavailable == true)

        // 2. Saving a new URL while vault is still unreadable refuses to overwrite the vault with `""`.
        var draft = initial.token
        var wasUnavailable = initial.lookupWasUnavailable
        HAConnectionSaveGuard.save(
            serverURL: "https://new-ha.example:8123",
            tokenDraft: &draft,
            initialLookupWasUnavailable: &wasUnavailable,
            in: store
        )
        #expect(wasUnavailable == true)
        #expect(store.toastNotice?.isError == true)
        #expect(box.blob == seeded)

        // 3. Once the user unlocks Keychain, clicking Save again recovers `secret-ha-token` and saves the new URL.
        box.isReadable = true
        HAConnectionSaveGuard.save(
            serverURL: "https://new-ha.example:8123",
            tokenDraft: &draft,
            initialLookupWasUnavailable: &wasUnavailable,
            in: store
        )
        #expect(wasUnavailable == false)
        #expect(draft == "secret-ha-token")
        #expect(store.serverURLString == "https://new-ha.example:8123")
        #expect(store.loadHAToken() == "secret-ha-token")
    }
}
}
