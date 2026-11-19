import Foundation
import Testing
import KeychainTestSupport
@testable import MijiaCore

/// #262：重置 LG 电视信任期间用户改了 LG 设置，旧配置或迟到的回调不能恢复旧信任，
/// 也不能让命令发到用户刚停用或换掉的电视。窗口由 `lgTrustResetSuspensionHookForTesting` 确定性地停住，
/// 不依赖任何固定 sleep。
@MainActor
struct LGTrustResetRaceTests {
    /// Parks the reset inside its suspension window until the test releases it.
    @MainActor private final class ResetWindow {
        private let parked: AsyncStream<Void>
        private let parkedSignal: AsyncStream<Void>.Continuation
        private let release: AsyncStream<Void>
        private let releaseSignal: AsyncStream<Void>.Continuation

        init() {
            (parked, parkedSignal) = AsyncStream<Void>.makeStream()
            (release, releaseSignal) = AsyncStream<Void>.makeStream()
        }

        func install(on store: HomeStore) {
            let parkedSignal = parkedSignal
            let release = release
            store.lgTrustResetSuspensionHookForTesting = {
                parkedSignal.yield()
                for await _ in release { break }
            }
        }

        func waitUntilParked() async {
            for await _ in parked { break }
        }

        func open() { releaseSignal.yield() }
    }

    private struct Fixture {
        let store: HomeStore
        let client: LGWebOSClient
        let defaults: UserDefaults
        let vault: CredentialVault?
        let suite: String
    }

    private func makeFixture(withVault: Bool) async throws -> Fixture {
        let vault: CredentialVault? = withVault ? CredentialVault(storage: MemoryVaultStorage().storage) : nil
        let suite = "test.lg-trust-reset-race.\(UUID().uuidString)"
        // Seed onboarding before the store exists, then reuse the store's own handle: a second
        // `UserDefaults(suiteName:)` instance reads through `cfprefsd` and can serve a stale cache
        // under CI load, making the assertions below flake.
        try #require(UserDefaults(suiteName: suite)).set(true, forKey: "has_completed_onboarding")
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [])),
            defaultsSuiteName: suite,
            credentialVault: vault
        )
        store.toastAutoDismissInterval = nil
        let initial = LGWebOSConfig(isEnabled: true, host: "192.0.2.10", clientKey: "saved-key")
        #expect(store.updateLGWebOSConfig(initial))
        let client = try #require(store.lgWebOSClient)
        let defaults = store.userDefaults
        return Fixture(store: store, client: client, defaults: defaults, vault: vault, suite: suite)
    }

    @Test("A reset keeps LG control disabled when the user disabled it mid-reset, and never restores the old key")
    func resetKeepsDisableMadeDuringReset() async throws {
        let f = try await makeFixture(withVault: true)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let window = ResetWindow()
        window.install(on: f.store)

        let resetTask = f.store.resetLGWebOSTrustAndPair()
        await window.waitUntilParked()

        // Exactly what the Settings toggle does: edit a copy of the (still old) in-memory config.
        var disabled = f.store.lgConfig
        disabled.isEnabled = false
        #expect(f.store.updateLGWebOSConfig(disabled))

        window.open()
        let result = await resetTask?.value

        #expect(result == true)
        #expect(f.store.lgConfig.isEnabled == false, "the reset must not resurrect LG control")
        #expect(f.store.lgConfig.clientKey.isEmpty)
        let persisted = LGWebOSConfig.load(from: f.defaults, vault: f.vault)
        #expect(persisted.isEnabled == false)
        #expect(persisted.clientKey.isEmpty, "the stale pairing key must not be written back")
        let clientConfig = await f.client.configForTesting
        #expect(clientConfig.isEnabled == false, "the client must not reconnect to a TV the user disabled")
        #expect(clientConfig.clientKey.isEmpty)
        #expect(await f.client.hasConnectionLoopForTesting == false)
        await f.client.shutdown()
        await f.store.shutdown()
    }

    @Test("A reset on the plain-defaults path keeps unrelated edits made mid-reset")
    func resetKeepsOtherEditsWithoutVault() async throws {
        let f = try await makeFixture(withVault: false)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let window = ResetWindow()
        window.install(on: f.store)

        let resetTask = f.store.resetLGWebOSTrustAndPair()
        await window.waitUntilParked()

        var edited = f.store.lgConfig
        edited.isEnabled = false
        edited.name = "Bedroom TV"
        #expect(f.store.updateLGWebOSConfig(edited))

        window.open()
        let result = await resetTask?.value

        #expect(result == true)
        #expect(f.store.lgConfig.isEnabled == false)
        #expect(f.store.lgConfig.name == "Bedroom TV")
        #expect(f.store.lgConfig.clientKey.isEmpty)
        let persisted = LGWebOSConfig.load(from: f.defaults)
        #expect(persisted.isEnabled == false)
        #expect(persisted.name == "Bedroom TV")
        #expect(persisted.clientKey.isEmpty)
        let clientConfig = await f.client.configForTesting
        #expect(clientConfig.isEnabled == false)
        #expect(clientConfig.name == "Bedroom TV")
        await f.client.shutdown()
        await f.store.shutdown()
    }

    @Test("A pairing-key callback that arrives while the reset is in flight cannot restore trust")
    func lateKeyCallbackDuringResetIsIgnored() async throws {
        let f = try await makeFixture(withVault: true)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let window = ResetWindow()
        window.install(on: f.store)

        let resetTask = f.store.resetLGWebOSTrustAndPair()
        await window.waitUntilParked()

        let accepted = f.store.applyLGClientKey("late-key", fromClientID: f.store.lgWebOSClientID)
        #expect(accepted == false, "a key from the pre-reset connection must be dropped")

        window.open()
        let result = await resetTask?.value

        #expect(result == true)
        #expect(f.store.lgConfig.clientKey.isEmpty)
        #expect(LGWebOSConfig.load(from: f.defaults, vault: f.vault).clientKey.isEmpty)
        #expect(await f.client.configForTesting.clientKey.isEmpty)
        await f.client.shutdown()
        await f.store.shutdown()
    }

    @Test("A reset stops and asks for a retry when the TV host changed mid-reset, without restoring the old key")
    func resetStopsWhenHostChangedMidReset() async throws {
        let f = try await makeFixture(withVault: true)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let window = ResetWindow()
        window.install(on: f.store)

        let resetTask = f.store.resetLGWebOSTrustAndPair()
        await window.waitUntilParked()

        var moved = f.store.lgConfig
        moved.host = "192.0.2.20"
        #expect(f.store.updateLGWebOSConfig(moved))

        window.open()
        let result = await resetTask?.value

        #expect(result == false)
        #expect(f.store.lgConfig.host == "192.0.2.20", "the newer TV choice must stay")
        #expect(f.store.lgConfig.clientKey.isEmpty, "the cleared TV's key must not follow the user to another host")
        #expect(LGWebOSConfig.load(from: f.defaults, vault: f.vault).host == "192.0.2.20")
        #expect(LGWebOSConfig.load(from: f.defaults, vault: f.vault).clientKey.isEmpty)
        let clientConfig = await f.client.configForTesting
        #expect(clientConfig.host == "192.0.2.20", "commands must follow the TV the user saved")
        #expect(clientConfig.clientKey.isEmpty)
        let notice = try #require(f.store.toastNotice)
        #expect(notice.isError)
        await f.client.shutdown()
        await f.store.shutdown()
    }
}
