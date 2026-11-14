import Foundation
import Testing
@testable import MijiaCore

/// 方案 v1 第 1 步：看得懂的错误提示。
struct AssistantErrorMessageTests {
    @Test("A failing model call surfaces the plain message in the command bar")
    @MainActor
    func storeShowsPlainMessage() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [AssistantScheduleTests.ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.err.\(UUID().uuidString)")
        try await store.waitForTestSnapshot()
        store.assistantResolverOverride = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://example.invalid/v1", model: "m", apiKey: "k"),
            transport: { _ in throw URLError(.timedOut) }
        )
        let message = await L10n.$overrideLanguage.withValue(.zhHans) {
            _ = await store.runAssistantCommand("我有点冷怎么办")
            guard case .failed(let message) = store.assistantState else {
                Issue.record("expected failure")
                return ""
            }
            return message
        }
        #expect(message.hasPrefix("AI 服务 10 秒没回应"))
    }
}
