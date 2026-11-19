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

    // MARK: - #143: Home Assistant form does not greet a Mi-only user with a default address and warning

    @Test("A fresh install shows an empty Home Assistant address; configured users keep theirs")
    func haURLDraftIsEmptyOnlyForUnconfiguredDefault() {
        let fallback = KeychainHelper.defaultNASURL
        #expect(HAConnectionSaveGuard.initialURLDraft(storedURL: fallback, hasHASource: false).isEmpty)
        #expect(HAConnectionSaveGuard.initialURLDraft(storedURL: "homeassistant.local:8123", hasHASource: false).isEmpty)
        #expect(HAConnectionSaveGuard.initialURLDraft(storedURL: fallback, hasHASource: true) == fallback)
        #expect(HAConnectionSaveGuard.initialURLDraft(storedURL: "https://ha.example", hasHASource: false) == "https://ha.example")
    }

    @Test("An empty address saves as the default; only a typed plain-http address warns")
    func haEmptyDraftMeansDefaultAndNeverWarns() {
        #expect(HAConnectionSaveGuard.effectiveURL("  ") == KeychainHelper.defaultNASURL)
        #expect(HAConnectionSaveGuard.effectiveURL("https://ha.example") == "https://ha.example")
        #expect(!HAConnectionSaveGuard.showsPlaintextWarning(forDraft: ""))
        #expect(!HAConnectionSaveGuard.showsPlaintextWarning(forDraft: "https://ha.example"))
        #expect(!HAConnectionSaveGuard.showsPlaintextWarning(forDraft: "http://localhost:8123"))
        #expect(HAConnectionSaveGuard.showsPlaintextWarning(forDraft: "http://ha.ddns.example:8123"))
        #expect(HAConnectionSaveGuard.showsPlaintextWarning(forDraft: "ha.ddns.example"))
    }

    @Test("Search jumps into the folded Home Assistant card expand it")
    func haCardAnchorsAreExpandedBySearch() {
        #expect(HAConnectionSaveGuard.collapsedAnchors.isSuperset(of: [.haServerAddress, .haToken, .haDiscovery]))
        #expect(!HAConnectionSaveGuard.collapsedAnchors.contains(.miAccount))
        // The highlight fades after ~1.6 s; the form latches open on the first hit instead.
        #expect(HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: .haToken))
        #expect(!HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: .miAccount))
        #expect(!HAConnectionSaveGuard.shouldLatchExpansion(forHighlight: nil))
    }

    @Test("Collapsed disclosures in General and Connections auto-expand for search hits and deep links")
    func settingsDisclosuresAutoExpandForSearchAndDeepLinks() {
        for anchor in [
            SettingsAnchor.panelTheme, .panelHeight, .compactGrid, .climatePanelModule, .hideGroupedLights
        ] {
            #expect(GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forHighlight: anchor))
        }
        #expect(!GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forHighlight: .language))
        #expect(!GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forHighlight: .appearanceMode))
        #expect(!GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forHighlight: nil))
        #expect(GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forRequestedTab: .appearance))
        #expect(!GeneralSettingsDisclosure.shouldExpandAdvancedDisplay(forRequestedTab: .general))

        for anchor in [SettingsAnchor.miMultiAccounts, .dualSourceFusion] {
            var state = ConnectionSettingsDisclosure.State()
            state.expandForHighlightIfNeeded(anchor)
            #expect(state.isExpanded)
        }
        var connHighlightState = ConnectionSettingsDisclosure.State()
        connHighlightState.expandForHighlightIfNeeded(.miAccount)
        #expect(!connHighlightState.isExpanded)
        connHighlightState.expandForHighlightIfNeeded(nil)
        #expect(!connHighlightState.isExpanded)

        var wakeHighlightState = LGWebOSSettingsSaveGuard.WakeDisclosureState()
        wakeHighlightState.expandForHighlightIfNeeded(.haServerAddress)
        #expect(!wakeHighlightState.isExpanded)
        wakeHighlightState.expandForHighlightIfNeeded(.lgTV)
        #expect(wakeHighlightState.isExpanded)

        var regionHighlightState = MiAccountSection.RegionDisclosureState()
        regionHighlightState.expandIfNeeded(isScanning: true)
        #expect(regionHighlightState.isExpanded)
        var regionAnchorState = MiAccountSection.RegionDisclosureState()
        regionAnchorState.expandIfNeeded(forHighlight: .miAccount)
        #expect(regionAnchorState.isExpanded)
        var regionDefaultState = MiAccountSection.RegionDisclosureState()
        regionDefaultState.applyInitialNonDefaultIfNeeded(region: .cn)
        regionDefaultState.expandIfNeeded(forHighlight: nil)
        #expect(!regionDefaultState.isExpanded)
    }

    @Test("Traditional Chinese translations match MiAccountSection region title and Advanced Display labels")
    func traditionalChineseSettingsLabelsUseShippedTranslations() {
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(L10n.tr(
                "面板主题、高度、紧凑网格与卡片显示细节",
                "Panel theme, height, compact grid and card layout options"
            ) == "面板主題、高度、緊湊網格與卡片顯示細節")
            #expect(L10n.tr(
                "专属连接钥匙 (Access Token)",
                "Dedicated Connection Key (Access Token)"
            ) == "專屬連線鑰匙 (Access Token)")
            #expect(L10n.tr("全部恢复显示", "Unhide All") == "全部恢復顯示")
            let hiddenLabel = L10n.tr("已手动隐藏 \(2) 台设备", "\(2) manually hidden device(s)")
            #expect(hiddenLabel == "已手動隱藏 2 臺裝置")
            #expect(!hiddenLabel.contains("手动"))
            #expect(!hiddenLabel.contains("台"))
            #expect(!hiddenLabel.contains("设备"))
            #expect(L10n.tr("继续扫码添加", "Scan Another Account") == "繼續掃碼新增")
            #expect(MiAccountSection.regionDisclosureTitle(for: .cn) == "進階：雲端伺服器地區（目前：中國大陸 (cn)）")
            #expect(MiAccountSection.regionDisclosureTitle(for: .sg) == "進階：雲端伺服器地區（目前：新加坡 / 國際 (sg)）")
        }

        L10n.$overrideLanguage.withValue(.en) {
            #expect(MiAccountSection.regionDisclosureTitle(for: .cn) == "Advanced: Cloud Region (Current: China Mainland (cn))")
            #expect(L10n.tr("继续扫码添加", "Scan Another Account") == "Scan Another Account")
        }
    }

    @Test("Appearance deep link opens Advanced Display and lets the user collapse it afterwards")
    func appearanceDeepLinkAllowsUserCollapse() {
        var state = GeneralSettingsDisclosure.State()
        state.expandIfNeeded(forRequestedTab: .appearance)
        #expect(state.isExpanded)

        // Initial default settings apply once without re-expanding after the user collapses.
        state.applyInitialNonDefaultIfNeeded(
            panelTheme: .classic,
            panelHeight: .standard,
            isCompactGridMode: true,
            climatePanelModule: true,
            hideGroupedLights: true
        )
        #expect(state.isExpanded)

        state.isExpanded = false
        #expect(!state.isExpanded)

        // Switching back to General must preserve the user's collapsed choice.
        state.applyInitialNonDefaultIfNeeded(
            panelTheme: .classic,
            panelHeight: .standard,
            isCompactGridMode: true,
            climatePanelModule: true,
            hideGroupedLights: true
        )
        #expect(!state.isExpanded)
    }

    @Test("Non-default display setting opens Advanced Display initially and stays collapsible")
    func nonDefaultDisplaySettingExpandsAdvancedDisplayInitially() {
        // Baseline: all five settings at their shipped defaults leave Advanced Display collapsed.
        #expect(!GeneralSettingsDisclosure.hasNonDefaultDisplaySettings(
            panelTheme: .classic,
            panelHeight: .standard,
            isCompactGridMode: true,
            climatePanelModule: true,
            hideGroupedLights: true
        ))

        var defaultState = GeneralSettingsDisclosure.State()
        defaultState.applyInitialNonDefaultIfNeeded(
            panelTheme: .classic,
            panelHeight: .standard,
            isCompactGridMode: true,
            climatePanelModule: true,
            hideGroupedLights: true
        )
        #expect(!defaultState.isExpanded)

        // Each non-default setting (compactGrid / climatePanelModule / hideGroupedLights default to true) expands initially.
        let nonDefaults: [(PanelTheme, PanelHeight, Bool, Bool, Bool)] = [
            (.liquidGlass, .standard, true, true, true),
            (.classic, .tall, true, true, true),
            (.classic, .standard, false, true, true),
            (.classic, .standard, true, false, true),
            (.classic, .standard, true, true, false)
        ]
        for (theme, height, compactGrid, climateModule, hideGroupedLights) in nonDefaults {
            var state = GeneralSettingsDisclosure.State()
            state.applyInitialNonDefaultIfNeeded(
                panelTheme: theme,
                panelHeight: height,
                isCompactGridMode: compactGrid,
                climatePanelModule: climateModule,
                hideGroupedLights: hideGroupedLights
            )
            #expect(state.isExpanded)

            // User collapse must stick on subsequent appearances.
            state.isExpanded = false
            state.applyInitialNonDefaultIfNeeded(
                panelTheme: theme,
                panelHeight: height,
                isCompactGridMode: compactGrid,
                climatePanelModule: climateModule,
                hideGroupedLights: hideGroupedLights
            )
            #expect(!state.isExpanded)
        }
    }

    @Test("Search highlight latches Advanced Display beyond highlight expiry and keeps user collapse")
    func searchHighlightLatchesAdvancedDisplayBeyondExpiry() {
        var state = GeneralSettingsDisclosure.State()
        state.expandIfNeeded(forHighlight: .language)
        #expect(!state.isExpanded)

        state.expandIfNeeded(forHighlight: .panelHeight)
        #expect(state.isExpanded)

        // Simulates the 1.6s highlight timer clearing `focus.highlight`.
        state.expandIfNeeded(forHighlight: nil)
        #expect(state.isExpanded)

        state.isExpanded = false
        #expect(!state.isExpanded)
    }

    @Test("Non-CN region expands Cloud Region picker once and preserves user collapse across highlight expiry and scan completion")
    func regionDisclosurePreservesUserCollapseAfterInitialNonCNExpansion() {
        var cnState = MiAccountSection.RegionDisclosureState()
        cnState.applyInitialNonDefaultIfNeeded(region: .cn)
        #expect(!cnState.isExpanded)

        var sgState = MiAccountSection.RegionDisclosureState()
        sgState.applyInitialNonDefaultIfNeeded(region: .sg)
        #expect(sgState.isExpanded)

        // User collapses the region picker while staying on `.sg`.
        sgState.isExpanded = false
        sgState.applyInitialNonDefaultIfNeeded(region: .sg)
        #expect(!sgState.isExpanded)

        // Search highlight expiring to `nil` or a scan finishing (`isScanning: false`) must not reopen it.
        sgState.expandIfNeeded(forHighlight: nil)
        sgState.expandIfNeeded(forHighlight: .haServerAddress)
        sgState.expandIfNeeded(isScanning: false)
        #expect(!sgState.isExpanded)

        // Explicit `.miAccount` jump or starting a new QR scan still expands it.
        sgState.expandIfNeeded(forHighlight: .miAccount)
        #expect(sgState.isExpanded)
        sgState.isExpanded = false
        sgState.expandIfNeeded(isScanning: true)
        #expect(sgState.isExpanded)
        sgState.isExpanded = false
        sgState.expandIfNeeded(isScanning: false)
        #expect(!sgState.isExpanded)
    }

    @MainActor
    @Test("Add Another Xiaomi Home Account bumps trigger and jumps scroll focus to the Xiaomi card")
    func addAnotherXiaomiAccountJumpsToXiaomiCard() {
        let focus = SettingsSearchFocus()
        var trigger = 0
        ConnectionSettingsDisclosure.requestAddMiAccount(trigger: &trigger, focus: focus)
        #expect(trigger == 1)
        #expect(focus.highlight == .miAccount)
        #expect(focus.generation == 1)
        focus.endHighlight()
    }

    @Test("Connection advanced disclosure auto-expands once for multi-account or dual-source and preserves user collapse")
    func connectionAdvancedDisclosurePreservesUserCollapseAndExpandsForDualSource() {
        // Default single-account or unconfigured setup remains collapsed.
        var unconfigured = ConnectionSettingsDisclosure.State()
        unconfigured.applyInitialDefaultsIfNeeded(accountCount: 0, isDualSourceActive: false)
        #expect(!unconfigured.isExpanded)

        var singleMiOnly = ConnectionSettingsDisclosure.State()
        singleMiOnly.applyInitialDefaultsIfNeeded(accountCount: 1, isDualSourceActive: false)
        #expect(!singleMiOnly.isExpanded)

        // Multi-account expands on first appearance and honors user collapse afterwards.
        var multiAccount = ConnectionSettingsDisclosure.State()
        multiAccount.applyInitialDefaultsIfNeeded(accountCount: 2, isDualSourceActive: false)
        #expect(multiAccount.isExpanded)

        multiAccount.isExpanded = false
        multiAccount.expandForHighlightIfNeeded(nil)
        multiAccount.expandForHighlightIfNeeded(.miAccount)
        multiAccount.applyInitialDefaultsIfNeeded(accountCount: 2, isDualSourceActive: true)
        #expect(!multiAccount.isExpanded)

        // Single Mi account + Home Assistant (dual-source active) also expands on first appearance.
        var dualSource = ConnectionSettingsDisclosure.State()
        dualSource.applyInitialDefaultsIfNeeded(accountCount: 1, isDualSourceActive: true)
        #expect(dualSource.isExpanded)

        dualSource.isExpanded = false
        dualSource.expandForHighlightIfNeeded(nil)
        dualSource.expandForHighlightIfNeeded(.haServerAddress)
        dualSource.applyInitialDefaultsIfNeeded(accountCount: 1, isDualSourceActive: true)
        #expect(!dualSource.isExpanded)

        // Explicit search jumps to either advanced anchor still expand it.
        dualSource.expandForHighlightIfNeeded(.dualSourceFusion)
        #expect(dualSource.isExpanded)
        dualSource.isExpanded = false
        dualSource.expandForHighlightIfNeeded(.miMultiAccounts)
        #expect(dualSource.isExpanded)
    }

    @Test("LG wake disclosure auto-expands once for non-empty MAC and preserves user collapse across highlight expiry and tab switch")
    func lgWakeDisclosurePreservesUserCollapseAcrossExpiryAndReappear() {
        var emptyMac = LGWebOSSettingsSaveGuard.WakeDisclosureState()
        emptyMac.applyInitialDefaultsIfNeeded(macAddress: "   ")
        #expect(!emptyMac.isExpanded)

        var configuredMac = LGWebOSSettingsSaveGuard.WakeDisclosureState()
        configuredMac.applyInitialDefaultsIfNeeded(macAddress: "AA:BB:CC:DD:EE:FF")
        #expect(configuredMac.isExpanded)

        // User collapses the wake section; highlight expiry or other anchors or re-appear must not reopen it.
        configuredMac.isExpanded = false
        configuredMac.expandForHighlightIfNeeded(nil)
        configuredMac.expandForHighlightIfNeeded(.haServerAddress)
        configuredMac.applyInitialDefaultsIfNeeded(macAddress: "AA:BB:CC:DD:EE:FF")
        #expect(!configuredMac.isExpanded)

        // Explicit search jump to .lgTV still expands it, and clearing highlight keeps user's later collapse.
        configuredMac.expandForHighlightIfNeeded(.lgTV)
        #expect(configuredMac.isExpanded)
        configuredMac.isExpanded = false
        configuredMac.expandForHighlightIfNeeded(nil)
        #expect(!configuredMac.isExpanded)
    }


    // MARK: - #148: unsaved edits are resolved, never dropped silently

    private func unsavedForm(
        _ title: String, dirty: Bool, saves: Bool = true,
        onSave: @escaping @MainActor () -> Void = {}, onDiscard: @escaping @MainActor () -> Void = {}
    ) -> SettingsUnsavedChanges.Form {
        .init(title: title, isDirty: dirty, save: { onSave(); return saves }, discard: onDiscard)
    }

    @Test("Nothing is asked while no form has unsaved edits")
    func unsavedChangesStaySilentWhenClean() {
        let unsaved = SettingsUnsavedChanges()
        unsaved.register("ha", unsavedForm("Home Assistant", dirty: false))
        var asked = false
        let go = unsaved.resolveBeforeLeaving(allowCancel: true) { _, _ in asked = true; return .cancel }
        #expect(go)
        #expect(!asked)
        #expect(!unsaved.isDirty)
    }

    @Test("Save runs every dirty form and blocks leaving when one cannot save")
    func unsavedChangesSaveChoice() {
        let unsaved = SettingsUnsavedChanges()
        var saved: [String] = []
        unsaved.register("ha", unsavedForm("Home Assistant", dirty: true, onSave: { saved.append("ha") }))
        unsaved.register("ai", unsavedForm("AI", dirty: true, onSave: { saved.append("ai") }))
        unsaved.register("clean", unsavedForm("Clean", dirty: false, onSave: { saved.append("clean") }))
        var titles: [String] = []
        let go = unsaved.resolveBeforeLeaving(allowCancel: true) { shown, _ in titles = shown; return .save }
        #expect(go)
        #expect(Set(saved) == ["ha", "ai"])
        #expect(titles == ["AI", "Home Assistant"])

        unsaved.register("ha", unsavedForm("Home Assistant", dirty: true, saves: false))
        let blocked = unsaved.resolveBeforeLeaving(allowCancel: true) { _, _ in .save }
        #expect(!blocked, "a refused save keeps the user on the page")
    }

    @Test("Discard resets the drafts and leaves; Cancel stays and touches nothing")
    func unsavedChangesDiscardAndCancel() {
        let unsaved = SettingsUnsavedChanges()
        var discarded = 0
        var saved = 0
        unsaved.register("ha", unsavedForm("Home Assistant", dirty: true, onSave: { saved += 1 }, onDiscard: { discarded += 1 }))

        #expect(!unsaved.resolveBeforeLeaving(allowCancel: true) { _, _ in .cancel })
        #expect(discarded == 0 && saved == 0)

        var offeredCancel = true
        let left = unsaved.resolveBeforeLeaving(allowCancel: false) { _, allowCancel in
            offeredCancel = allowCancel
            return .discard
        }
        #expect(left)
        #expect(!offeredCancel, "closing the window cannot be cancelled")
        #expect(discarded == 1 && saved == 0)

        unsaved.unregister("ha")
        #expect(!unsaved.isDirty)
    }

    @Test("LG Settings save guard snaps toggle back and stops pairing/reset when Keychain refuses saves")
    func lgSettingsSaveGuardReflectsRealSaveResult() async throws {
        final class RefusingVaultBox: @unchecked Sendable {
            private let lock = NSLock()
            var blob: Data?
            var readable = false
            var writable = false
            var storage: CredentialVault.Storage {
                CredentialVault.Storage(
                    read: { [self] in
                        lock.withLock {
                            guard readable else { return .unavailable }
                            return blob.map(CredentialVault.Storage.ReadResult.found) ?? .notFound
                        }
                    },
                    write: { [self] data in
                        lock.withLock {
                            guard writable else { return false }
                            blob = data
                            return true
                        }
                    }
                )
            }
        }

        let suite = "test.prerelease.lgsettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")

        let box = RefusingVaultBox()
        let vault = CredentialVault(storage: box.storage)
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil
        try await store.waitForTestSnapshot()

        var isEnabled = false
        var hostDraft = "192.0.2.50"
        var macDraft = "AA:BB:CC:DD:EE:FF"

        // 1. Toggling on while vault is unavailable snaps isEnabled back to false and keeps error toast.
        let toggled = LGWebOSSettingsSaveGuard.toggleEnabled(
            true,
            isEnabled: &isEnabled,
            hostDraft: hostDraft,
            macDraft: macDraft,
            in: store
        )
        #expect(toggled == false)
        #expect(isEnabled == false)
        #expect(store.lgConfig.isEnabled == false)
        #expect(store.toastNotice?.isError == true)

        // 2. Pair TV refuses to call triggerLGWebOSPairing when saveDrafts fails.
        isEnabled = true
        store.dismissToast()
        let paired = LGWebOSSettingsSaveGuard.pairTV(
            isEnabled: &isEnabled,
            hostDraft: &hostDraft,
            macDraft: &macDraft,
            in: store
        )
        #expect(paired == false)
        #expect(isEnabled == false)
        #expect(store.lgWebOSClient == nil)
        let pairNotice = try #require(store.toastNotice)
        #expect(pairNotice.isError)
        #expect(!pairNotice.message.contains("已向电视发送配对请求"))
        #expect(!pairNotice.message.contains("Pairing request sent"))

        // 3. Trust reset stops when saveDrafts fails.
        isEnabled = true
        store.dismissToast()
        let blockedReset = LGWebOSSettingsSaveGuard.resetTrustAndPair(
            isEnabled: &isEnabled,
            hostDraft: &hostDraft,
            macDraft: &macDraft,
            in: store
        )
        #expect(blockedReset == nil)
        #expect(isEnabled == false)
        #expect(store.toastNotice?.isError == true)

        // 4. Once unlocked and paired, refusing Keychain writes during reset keeps the pairing key intact.
        box.readable = true
        box.writable = true
        isEnabled = true
        #expect(LGWebOSSettingsSaveGuard.saveDrafts(
            isEnabled: &isEnabled,
            hostDraft: &hostDraft,
            macDraft: &macDraft,
            in: store
        ))
        #expect(store.applyLGClientKey("saved-key"))

        box.writable = false
        store.dismissToast()
        let resetTask = try #require(LGWebOSSettingsSaveGuard.resetTrustAndPair(
            isEnabled: &isEnabled,
            hostDraft: &hostDraft,
            macDraft: &macDraft,
            in: store
        ))
        #expect(await resetTask.value == false)
        #expect(store.lgConfig.clientKey == "saved-key")
        let resetNotice = try #require(store.toastNotice)
        #expect(resetNotice.isError)
        #expect(!resetNotice.message.contains("旧电视身份已清除"))
        await store.lgWebOSClient?.shutdown()
    }
}
}
