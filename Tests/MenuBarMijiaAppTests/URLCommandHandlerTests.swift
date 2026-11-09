import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #20: the Raycast/CLI links land on the same handler as hand-written ones, so the bridge token, the
/// confirmation sheet, the high-risk gate and the command feedback have to hold for them too.
@MainActor
struct URLCommandHandlerTests {
    private static let lamp = SmartDevice(
        id: "dev_lamp",
        name: "Study Lamp",
        roomId: "study",
        roomName: "Study",
        model: "test.light",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 80))
    )
    private static let airConditioner = SmartDevice(
        id: "dev_ac",
        name: "Study AC",
        roomId: "study",
        roomName: "Study",
        model: "test.aircondition",
        isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.ac",
            isOn: true,
            hvacMode: "cool",
            availableModes: ["off", "cool"],
            targetTemperature: 25
        ))
    )

    private static func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let suite = "test.urlhandler.\(UUID().uuidString)"
        let provider = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "study", name: "Study", sortOrder: 0)],
            devices: [lamp, airConditioner]
        ))
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForTestSnapshot()
        return (store, provider)
    }

    private static func url(_ raw: String) throws -> URL {
        try #require(URL(string: raw))
    }

    @Test("A power link carrying the bridge token skips the sheet and reports its result")
    func trustedPowerLinkSkipsTheSheet() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()
            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)

            let handler = URLCommandHandler()
            var asked = false
            handler.confirmationHandler = { _ in
                asked = true
                return false
            }

            let link = try Self.url("menumijia://power?device=dev_lamp&on=false&id=cli-1&token=\(token)")
            await handler.handle(link, in: store)

            #expect(!asked, "a trusted companion link must not show the confirmation sheet")
            #expect(store.devices.first { $0.id == "dev_lamp" }?.isActiveOn == false)
            #expect(await provider.executedCommands.count == 1)
            #expect(store.lastRaycastCommandFeedback?.requestId == "cli-1")
            #expect(store.lastRaycastCommandFeedback?.isError == false)
            #expect(store.lastRaycastCommandFeedback?.message.contains("Turned off") == true)
        }
    }

    @Test("A blocked Mi write keeps the scan toast while the link still reports the error")
    func blockedWriteKeepsPersistentToast() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.urlhandler.blocked.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
            let provider = MockHomeProvider(snapshot: SynthesizedHome(
                rooms: [RoomArea(id: "study", name: "Study", sortOrder: 0)],
                devices: [Self.lamp]
            ))
            let expired = MiSession(
                userId: "1234567890",
                cUserId: "cu",
                ssecurity: "s",
                serviceToken: "tok",
                expiresAt: Date().addingTimeInterval(-60)
            )
            #expect(MiSessionStore.save(expired, defaults: defaults))
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            try await store.waitForTestSnapshot()
            #expect(store.miSessionBlocksControl)
            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)

            let handler = URLCommandHandler()
            handler.confirmationHandler = { _ in true }
            let link = try Self.url(
                "menumijia://brightness?device=dev_lamp&percent=40&id=cli-blocked&token=\(token)"
            )
            await handler.handle(link, in: store)

            #expect(store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.lastRaycastCommandFeedback?.message == "Xiaomi Home session expired")
            #expect(store.toastNotice?.message == "Xiaomi Home session expired")
            #expect(store.toastNotice?.persistent == true, "the scan action must survive the link result")
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("A power link keeps a stale scan toast while still reporting the refusal")
    func blockedPowerLinkKeepsStaleToast() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.urlhandler.blocked-power.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
            let provider = MockHomeProvider(snapshot: SynthesizedHome(
                rooms: [RoomArea(id: "study", name: "Study", sortOrder: 0)],
                devices: [Self.lamp]
            ))
            let expired = MiSession(
                userId: "1234567890",
                cUserId: "cu",
                ssecurity: "s",
                serviceToken: "tok",
                expiresAt: Date().addingTimeInterval(-60)
            )
            #expect(MiSessionStore.save(expired, defaults: defaults))
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            try await store.waitForTestSnapshot()
            store.setRaycastIntegration(enabled: true)
            let token = try #require(store.raycastBridgeToken)
            // An earlier Mi tap left the toast on screen before the link arrives, so the refusal
            // does not create a new id for a previous-toast-id check to notice.
            let lamp = try #require(store.devices.first)
            #expect(store.togglePrimary(lamp) == nil)
            #expect(store.toastNotice?.persistent == true)

            let handler = URLCommandHandler()
            let link = try Self.url(
                "menumijia://power?device=dev_lamp&on=false&id=cli-blocked-power&token=\(token)"
            )
            await handler.handle(link, in: store)

            #expect(store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.lastRaycastCommandFeedback?.message == "Xiaomi Home session expired")
            #expect(store.toastNotice?.message == "Xiaomi Home session expired")
            #expect(store.toastNotice?.persistent == true)
            #expect(await provider.executedCommands.isEmpty)
        }
    }

    @Test("An untrusted value link names the device and the value, and a refusal sends nothing")
    func untrustedLinkAsksWithTheExactValue() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()
            // Integration off: there is no bridge token, so the link must be confirmed.
            #expect(store.raycastBridgeToken == nil)

            let handler = URLCommandHandler()
            var prompt: String?
            handler.confirmationHandler = { description in
                prompt = description
                return false
            }

            let link = try Self.url("menumijia://brightness?device=dev_lamp&percent=40&id=cli-2&token=stale")
            await handler.handle(link, in: store)

            let sheet = try #require(prompt)
            #expect(sheet.contains("Study Lamp"))
            #expect(sheet.contains("40%"))
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.lastRaycastCommandFeedback?.isError == true)
            #expect(store.lastRaycastCommandFeedback?.message.contains("Cancelled") == true)
        }
    }

    @Test("A focus link opens the panel on the device without asking and without sending a command")
    func focusLinkOpensThePanel() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let (store, provider) = try await Self.makeStore()

            let handler = URLCommandHandler()
            var asked = false
            handler.confirmationHandler = { _ in
                asked = true
                return false
            }
            var windowShown = 0
            handler.windowVisibilityHandler = { windowShown += 1 }

            let link = try Self.url("menumijia://focus?device=dev_ac&id=cli-3")
            await handler.handle(link, in: store)

            #expect(!asked, "showing a drawer is navigation, not a device control")
            #expect(store.expandedDeviceId == "dev_ac")
            #expect(windowShown == 1)
            #expect(await provider.executedCommands.isEmpty)
            #expect(store.lastRaycastCommandFeedback?.isError == false)
        }
    }
}
