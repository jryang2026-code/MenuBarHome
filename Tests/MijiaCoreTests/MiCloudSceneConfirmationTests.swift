import Foundation
import Testing
@testable import MijiaCore

/// The Mi cloud scene confirmation is a write gate, but declining it is a user choice, not a
/// failed execution: `executeDeviceCommand` throws `CancellationError` and `triggerScene` must
/// stay silent instead of raising the generic 「执行失败」 toast.
@MainActor
struct MiCloudSceneConfirmationTests {
    private static let session = MiSession(
        userId: "10010001",
        cUserId: "c-scene-test",
        ssecurity: "ssec-scene-test",
        serviceToken: "tok-scene-test",
        region: "cn"
    )
    private static let account = MiAccount(session: session)

    private static var scene: HomeScene {
        let id = "\(account.id)/mi-scene:home-1:11"
        return HomeScene(id: id, name: "回家", entityId: id)
    }

    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(scenes: [Self.scene]))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.miscene.\(UUID().uuidString)")
        store.assistantAutoResetTiming = .never
        try await store.waitForTestSnapshot()
        store.miAccounts = [Self.account]
        store.miSessionMaskedUserId = Self.account.maskedUserId
        store.homeBackend = .xiaomiCloud
        store.syncInMemoryConfiguredCapabilities()
        return (store, mock)
    }

    @Test("Declining the confirmation runs nothing and shows no failure toast")
    func declineIsSilent() async throws {
        let (store, mock) = try await makeStore()
        #expect(store.scenes.contains(Self.scene))
        #expect(store.evaluateSceneControlGate(sceneId: Self.scene.id).allowed)
        store.manualControlConfirmationHandler = { _ in false }

        let triggered = await store.triggerScene(Self.scene).value

        #expect(triggered == false)
        #expect(store.toastNotice == nil, "a declined confirmation is not an execution failure")
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Accepting the confirmation still runs the scene")
    func acceptRunsTheScene() async throws {
        let (store, mock) = try await makeStore()
        store.manualControlConfirmationHandler = { _ in true }

        let triggered = await store.triggerScene(Self.scene).value

        #expect(triggered)
        #expect(store.toastNotice?.isError == false)
        #expect(await mock.executedCommands == [.activateScene(entityId: Self.scene.entityId)])
    }

    @Test("Declining a scene from an intent plan is not reported as a device failure")
    func intentPlanDeclineIsCancelled() async throws {
        let (store, mock) = try await makeStore()
        store.manualControlConfirmationHandler = { _ in false }
        let plan = IntentPlan(
            intents: [DeviceIntent(targetId: Self.scene.id, operation: .activateScene)],
            reply: "执行回家场景",
            source: .local
        )

        _ = await store.executeIntentPlan(plan, recordedUtterance: nil, origin: .userInitiated)

        if case .failed = store.assistantState {
            Issue.record("a declined confirmation must not become a device failure")
        }
        #expect(await mock.executedCommands.isEmpty)
    }
}
