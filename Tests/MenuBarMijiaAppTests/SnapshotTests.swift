import Testing
import Foundation
import SwiftUI
import AppKit
import KeychainTestSupport
import PreferencesTestSupport
@testable import MijiaCore
@testable import MenuBarMijiaApp

extension PanelPresentationTests {
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    init() {
        SnapshotWindow.pinOverlayScrollers()
    }

    private var recordAll: Bool {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"
    }

    @Test("Panel renders in both themes")
    func panelSnapshot() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }

        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)

        #expect(fixture.store.panelHealth == .ok)
        for theme in PanelTheme.allCases {
            assertRendered(
                snapshotReady(themedPanel(theme, store: fixture.store)),
                size: CGSize(width: 376, height: 560),
                named: themedName(theme, "panel-zh-light")
            )
        }
    }

    @Test("A panel with no configured source names that instead of connected")
    func panelNoSourceSnapshot() async throws {
        let fixture = try await SnapshotFixture(configuredHASource: false)
        defer { fixture.restore() }

        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)
        #expect(fixture.store.panelHealth == .notConfigured)

        for theme in PanelTheme.allCases {
            assertRendered(
                snapshotReady(themedPanel(theme, store: fixture.store)),
                size: CGSize(width: 376, height: 560),
                named: themedName(theme, "panel-no-source-zh-light")
            )
        }
    }

    @Test("Panel shows the expired Mi session banner")
    func panelExpiredMiSessionSnapshot() async throws {
        let fixture = try await SnapshotFixture(
            miSession: MiSession(
                userId: "42",
                cUserId: "c",
                ssecurity: "c2VjcmV0",
                serviceToken: "tok",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            configuredHASource: false
        )
        defer { fixture.restore() }

        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)

        for theme in PanelTheme.allCases {
            assertRendered(
                snapshotReady(themedPanel(theme, store: fixture.store)),
                size: CGSize(width: 376, height: 560),
                named: themedName(theme, "panel-mi-session-expired-zh-light")
            )
        }
    }

    @Test("An unconnected first launch puts the demo in view above the connect form")
    func onboardingDemoEntrySnapshot() async throws {
        let fixture = try await SnapshotFixture(configuredHASource: false)
        defer { fixture.restore() }
        fixture.store.hasCompletedOnboarding = false
        fixture.store.switchBackend(.xiaomiCloud)
        fixture.store.connectionStatus = .disconnected("")
        #expect(!fixture.store.hasConnectedHomeSource)
        assertRendered(
            snapshotReady(
                OnboardingGuideView(store: fixture.store)
                    .frame(width: 400, height: 640)
            ),
            size: CGSize(width: 400, height: 640),
            named: "onboarding-demo-entry-zh-light"
        )
    }

    @Test("An expanded air-conditioner card lists its synthesized 更多设置 rows")
    func expandedClimateFacetSnapshot() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        let savedPanel = UserDefaults.standard.object(forKey: PanelPrefs.climatePanelKey)
        UserDefaults.standard.set(true, forKey: PanelPrefs.climatePanelKey)
        defer {
            if let savedPanel {
                UserDefaults.standard.set(savedPanel, forKey: PanelPrefs.climatePanelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PanelPrefs.climatePanelKey)
            }
        }

        let climate = try #require(fixture.store.devices.first { device in
            if case .climate = device.kind { return true } else { return false }
        })
        fixture.store.deviceFacets[climate.id] = [
            FacetControl(
                id: "4.1", kind: .toggle, name: "on", title: "新风", serviceName: "fresh-air",
                value: .bool(true), isWritable: true, writesByDefault: true, isHighValue: true,
                target: .property(entityId: "miot:\(climate.id):4", piid: 1)
            ),
            FacetControl(
                id: "3.1", kind: .select, name: "vertical-swing", title: "上下摆风", serviceName: "air-conditioner",
                value: .number(1),
                options: [MiotFacetOption(value: 0, label: "关"), MiotFacetOption(value: 1, label: "开")],
                isWritable: true, writesByDefault: true, isHighValue: true,
                target: .property(entityId: "miot:\(climate.id):3", piid: 1)
            ),
        ]
        fixture.store.expandedDeviceId = climate.id

        for theme in PanelTheme.allCases {
            assertRendered(
                snapshotReady(
                    themedCard(theme, device: climate, store: fixture.store)
                        .padding(8)
                        .frame(width: 360)
                ),
                size: CGSize(width: 376, height: 460),
                named: themedName(theme, "expanded-climate-facets-zh-light")
            )
        }
    }

    @Test("Settings tabs remain readable")
    func settingsSnapshots() async throws {
        let fixture = try await SnapshotFixture(configuredHASource: false)
        defer { fixture.restore() }
        for tab in [SettingsTab.general, .connection, .assistant, .appearance, .privacy, .about] {
            assertRendered(
                SettingsWindowView(store: fixture.store, selectedTab: tab)
                    .environment(\.colorScheme, .light)
                    .environment(\.reduceMotionOverride, true)
                    .environment(\.reduceTransparencyOverride, true),
                size: CGSize(width: 780, height: 680),
                named: "settings-\(tab.rawValue)-light",
                scheme: .light
            )
        }
    }

    @Test("Panel supports dark and expanded controls")
    func panelInteractionStates() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        fixture.store.isCompactGridMode = false
        for theme in PanelTheme.allCases {
            assertRendered(
                snapshotReady(themedPanel(theme, store: fixture.store), scheme: .dark),
                size: CGSize(width: 376, height: 560),
                named: themedName(theme, "panel-dark"),
                scheme: .dark
            )
        }
        fixture.store.isCompactGridMode = true
        let light = try #require(fixture.store.devices.first { if case .light = $0.kind { true } else { false } })
        fixture.store.expandedDeviceId = light.id
        for theme in PanelTheme.allCases {
            assertRendered(
                snapshotReady(
                    themedCard(theme, device: light, store: fixture.store).padding(8),
                    scheme: .light
                ),
                size: CGSize(width: 376, height: 260),
                named: themedName(theme, "expanded-light-light"),
                scheme: .light
            )
        }
    }

    @Test("The expanded live panel shows the camera switcher and dual-lens picker")
    func cameraSwitcherAndDualLensSnapshot() async throws {
        let fixture = try await SnapshotFixture(includeCamera: true, includeDualLensCamera: true)
        defer { fixture.restore() }
        let camera = try #require(fixture.store.devices.first { device in
            guard case .camera(let spec) = device.kind else { return false }
            return spec.lenses.count > 1
        })
        let controller = CameraLivePanelController()
        controller.isExpandedSize = true
        controller.configurePTZPreview(
            store: fixture.store,
            deviceId: camera.id,
            binding: nil,
            stream: .demo(deviceId: camera.id),
            notice: nil,
            ready: false
        )
        defer { controller.configurePTZPreview(deviceId: nil, binding: nil, stream: nil, notice: nil, ready: false) }

        assertRendered(
            snapshotReady(CameraLivePanelView(controller: controller, store: fixture.store), scheme: .dark),
            size: CGSize(width: CameraLivePanelController.expandedSize.width, height: CameraLivePanelController.expandedSize.height),
            named: "camera-switcher-dual-lens-dark",
            scheme: .dark
        )
    }

    private func themedPanel(_ theme: PanelTheme, store: HomeStore) -> AnyView {
        switch theme {
        case .classic:
            return AnyView(ClassicControlCenterPanel(store: store))
        case .liquidGlass:
            return AnyView(ControlCenterPanel(store: store))
        }
    }

    private func themedCard(
        _ theme: PanelTheme,
        device: SmartDevice,
        store: HomeStore,
        showRoomBadge: Bool = true
    ) -> AnyView {
        switch theme {
        case .classic:
            return AnyView(ClassicDeviceCardView(device: device, store: store, showRoomBadge: showRoomBadge))
        case .liquidGlass:
            return AnyView(DeviceCardView(device: device, store: store, showRoomBadge: showRoomBadge))
        }
    }

    private func themedName(_ theme: PanelTheme, _ name: String) -> String {
        "\(theme == .classic ? "classic" : "liquid")-\(name)"
    }

    private func snapshotReady<V: View>(_ view: V, scheme: ColorScheme = .light, reduceMotion: Bool = true) -> some View {
        view
            .environment(\.colorScheme, scheme)
            .environment(\.reduceMotionOverride, reduceMotion)
            .environment(\.reduceTransparencyOverride, true)
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
    }

    private func assertRendered<V: View>(
        _ view: V,
        size: CGSize,
        named name: String,
        scheme: ColorScheme = .light,
        fileID: StaticString = #fileID,
        file: StaticString = #filePath,
        testName: String = #function,
        line: Int = #line,
        column: Int = #column
    ) {
        _ = NSApplication.shared

        let speech = SpeechInputController.shared
        let savedListening = speech.isListening
        let savedHoldToTalk = speech.isHoldToTalk
        let savedDraft = speech.draft
        let savedError = speech.errorMessage
        speech.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
        defer {
            speech.setPreviewState(
                isListening: savedListening,
                isHoldToTalk: savedHoldToTalk,
                draft: savedDraft,
                errorMessage: savedError
            )
        }

        let hosting = NSHostingView(rootView: view.focusEffectDisabled())
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = SnapshotWindow.make(size: size)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            Issue.record("Could not create a 1x snapshot bitmap")
            return
        }
        bitmap.size = size
        SnapshotWindow.prepareForCapture(window)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        if let failure = SnapshotAssertion.verifyImage(
            image,
            named: name,
            recordAll: recordAll,
            file: file,
            testName: testName
        ) {
            Issue.record(
                Comment(rawValue: failure),
                sourceLocation: SourceLocation(
                    fileID: String(describing: fileID),
                    filePath: String(describing: file),
                    line: line,
                    column: column
                )
            )
        }

        window.contentView = nil
        window.orderOut(nil)
    }
}
}

@MainActor
struct SnapshotFixture {
    struct MissingDefaults: Error {}

    let store: HomeStore
    private let previousAppearance: String?
    private let previousTemperatureUnit: String?
    private let previousRoomOrder: String?
    private let previousRoomAliases: String?
    private let previousKindOrder: String?
    private let previousPanelGrouping: String?
    private let previousGroups: String?
    private let previousAliases: String?
    private let previousPanelTheme: String?
    private let previousPanelHeight: String?
    private let previousQuickDrawerExpanded: Bool?
    private let previousAllowURLDirectControl: Bool?
    private let previousErrorTimestamps: [Date]

    init(
        miSession: MiSession? = nil,
        includeCamera: Bool = false,
        includeDualLensCamera: Bool = false,
        configuredHASource: Bool = true
    ) async throws {
        previousAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        previousTemperatureUnit = UserDefaults.standard.string(forKey: TemperatureUnitPreference.storageKey)
        previousRoomOrder = UserDefaults.standard.string(forKey: RoomPrefs.orderKey)
        previousRoomAliases = UserDefaults.standard.string(forKey: RoomPrefs.aliasesKey)
        previousKindOrder = UserDefaults.standard.string(forKey: KindOrderPrefs.orderKey)
        previousPanelGrouping = UserDefaults.standard.string(forKey: PanelGrouping.storageKey)
        previousGroups = UserDefaults.standard.string(forKey: GroupPrefs.groupsKey)
        previousAliases = UserDefaults.standard.string(forKey: GroupPrefs.aliasesKey)
        previousPanelTheme = UserDefaults.standard.string(forKey: PanelTheme.storageKey)
        previousPanelHeight = UserDefaults.standard.string(forKey: PanelHeight.storageKey)
        previousQuickDrawerExpanded = UserDefaults.standard.object(forKey: PanelPrefs.quickDrawerExpandedKey) as? Bool
        previousAllowURLDirectControl = UserDefaults.standard.object(forKey: URLDirectControl.allowDirectControlKey) as? Bool
        previousErrorTimestamps = AppDiagnosticsLog.shared.errorTimestamps
        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)
        UserDefaults.standard.set(TemperatureUnitPreference.celsius.rawValue, forKey: TemperatureUnitPreference.storageKey)
        UserDefaults.standard.set(PanelTheme.classic.rawValue, forKey: PanelTheme.storageKey)
        UserDefaults.standard.set(PanelHeight.standard.rawValue, forKey: PanelHeight.storageKey)
        UserDefaults.standard.set(PanelGrouping.room.rawValue, forKey: PanelGrouping.storageKey)
        UserDefaults.standard.removeObject(forKey: RoomPrefs.orderKey)
        UserDefaults.standard.removeObject(forKey: RoomPrefs.aliasesKey)
        UserDefaults.standard.removeObject(forKey: KindOrderPrefs.orderKey)
        UserDefaults.standard.removeObject(forKey: GroupPrefs.groupsKey)
        UserDefaults.standard.removeObject(forKey: GroupPrefs.aliasesKey)
        UserDefaults.standard.removeObject(forKey: PanelPrefs.quickDrawerExpandedKey)
        PanelQuickDrawerState.shared.reloadFromDefaults()
        UserDefaults.standard.removeObject(forKey: URLDirectControl.allowDirectControlKey)
        UnsupportedDeviceScanner.shared.reset()
        #if DEBUG
        LayoutUIState.shared.resetForTesting()
        AppDiagnosticsLog.shared.replaceTimestampsForTesting([])
        #endif

        // One instance for the seed, the store and the assertions: a second
        // `UserDefaults(suiteName:)` reads through cfprefsd and can serve a stale cache (#309).
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(AppLanguagePreference.zhHans.rawValue, forKey: "app_language")
        defaults.set(TemperatureUnitPreference.celsius.rawValue, forKey: TemperatureUnitPreference.storageKey)
        defaults.set(false, forKey: "automatically_checks_for_updates")
        #expect(KeychainHelper.loadToken(defaults: defaults).isEmpty)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: AssistantConfig.defaultBaseURL, defaults: defaults).isEmpty)
        if let miSession {
            defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
            guard MiSessionStore.save(miSession, defaults: defaults) else { throw MissingDefaults() }
        }

        store = HomeStore(
            provider: MockHomeProvider(snapshot: Self.home(
                includeCamera: includeCamera,
                includeDualLensCamera: includeDualLensCamera
            )),
            defaults: defaults
        )

        var attempts = 0
        while store.devices.isEmpty && attempts < 200 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }
        #expect(!store.devices.isEmpty)
        let favorites = [
            "demo_living_light", "demo_living_climate", "demo_living_plug",
            "demo_living_tv", "demo_bedroom_light", "demo_bedroom_climate"
        ]
        store.favoriteDeviceIds = Set(favorites)
        store.favoriteOrder = favorites
        if configuredHASource {
            store.hasHASource = true
        }
    }

    private static func home(
        includeCamera: Bool = false,
        includeDualLensCamera: Bool = false
    ) -> SynthesizedHome {
        var home = DemoHomeProvider.defaultHome(includeCamera: includeCamera)
        if includeDualLensCamera {
            let room = home.rooms.first
            let roomName = room?.name ?? "书房"
            home.devices.append(
                SmartDevice(
                    id: "demo_study_camera",
                    name: "书房双摄",
                    roomId: room?.id ?? "study",
                    roomName: roomName,
                    model: "isa.camera.500dh",
                    isOnline: true,
                    kind: .camera(CameraSpec(
                        entityId: "camera.demo_study_camera",
                        isOn: true,
                        streamEntityId: "camera.demo_study_camera",
                        lenses: [
                            CameraLens(role: .main, channel: 0),
                            CameraLens(role: .secondary, channel: 1),
                        ]
                    ))
                )
            )
        }
        return home
    }

    func restore() {
        if let previousAppearance {
            UserDefaults.standard.set(previousAppearance, forKey: AppAppearance.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppAppearance.storageKey)
        }
        if let previousTemperatureUnit {
            UserDefaults.standard.set(previousTemperatureUnit, forKey: TemperatureUnitPreference.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TemperatureUnitPreference.storageKey)
        }
        if let previousRoomOrder {
            UserDefaults.standard.set(previousRoomOrder, forKey: RoomPrefs.orderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: RoomPrefs.orderKey)
        }
        if let previousRoomAliases {
            UserDefaults.standard.set(previousRoomAliases, forKey: RoomPrefs.aliasesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: RoomPrefs.aliasesKey)
        }
        if let previousKindOrder {
            UserDefaults.standard.set(previousKindOrder, forKey: KindOrderPrefs.orderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: KindOrderPrefs.orderKey)
        }
        if let previousPanelGrouping {
            UserDefaults.standard.set(previousPanelGrouping, forKey: PanelGrouping.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelGrouping.storageKey)
        }
        if let previousGroups {
            UserDefaults.standard.set(previousGroups, forKey: GroupPrefs.groupsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: GroupPrefs.groupsKey)
        }
        if let previousAliases {
            UserDefaults.standard.set(previousAliases, forKey: GroupPrefs.aliasesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: GroupPrefs.aliasesKey)
        }
        if let previousPanelTheme {
            UserDefaults.standard.set(previousPanelTheme, forKey: PanelTheme.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelTheme.storageKey)
        }
        if let previousPanelHeight {
            UserDefaults.standard.set(previousPanelHeight, forKey: PanelHeight.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelHeight.storageKey)
        }
        if let previousQuickDrawerExpanded {
            UserDefaults.standard.set(previousQuickDrawerExpanded, forKey: PanelPrefs.quickDrawerExpandedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanelPrefs.quickDrawerExpandedKey)
        }
        PanelQuickDrawerState.shared.reloadFromDefaults()
        if let previousAllowURLDirectControl {
            UserDefaults.standard.set(previousAllowURLDirectControl, forKey: URLDirectControl.allowDirectControlKey)
        } else {
            UserDefaults.standard.removeObject(forKey: URLDirectControl.allowDirectControlKey)
        }
        UnsupportedDeviceScanner.shared.reset()
        #if DEBUG
        LayoutUIState.shared.resetForTesting()
        AppDiagnosticsLog.shared.replaceTimestampsForTesting(previousErrorTimestamps)
        #endif
    }
}

@MainActor
enum SnapshotWindow {
    static func make(size: CGSize) -> NSWindow {
        pinOverlayScrollers()
        let window = CaptureWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    static func pinOverlayScrollers() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard arguments["AppleShowScrollBars"] as? String != "WhenScrolling" else { return }
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    private final class CaptureWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            super.makeFirstResponder(nil)
        }
    }

    static func prepareForCapture(_ window: NSWindow) {
        for _ in 0..<2 {
            flushLayoutAndDisplay(window)
        }
        var extraPasses = 0
        while extraPasses < 2, let contentView = window.contentView, subtreeNeedsLayout(contentView) {
            flushLayoutAndDisplay(window)
            extraPasses += 1
        }
        window.makeFirstResponder(nil)
    }

    private static func flushLayoutAndDisplay(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        window.displayIfNeeded()
    }

    private static func subtreeNeedsLayout(_ view: NSView) -> Bool {
        view.needsLayout || view.subviews.contains(where: subtreeNeedsLayout)
    }
}
