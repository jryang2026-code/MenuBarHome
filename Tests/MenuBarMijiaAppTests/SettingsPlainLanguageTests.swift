import Foundation
import SwiftUI
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

@MainActor
struct SettingsPlainLanguageTests {
    private let issueURL = "https://github.com/jryang2026-code/MenuBarHome/issues/9"

    @Test("Update notes render bold lead-ins and links, and stop after five")
    func releaseNotesHideRawMarkdown() {
        let notes = """
        ## 1.2.0

        ### 亮点
        - **bold** [#9](\(issueURL))：后面还有 **secret** 和 [#8](https://example.com/8)
        - **two**
        - **three**
        - **four**
        - **five**: kept
        - **six**

        ### 其他
        - **seven**
        """

        let titles = ReleaseNotesDigest.titles(in: notes)
        #expect(titles.count == 5)
        #expect(titles[0] == "**bold** [#9](\(issueURL))")
        #expect(titles[4] == "**five**")
        #expect(titles.joined(separator: "\n").contains("six") == false)
        #expect(titles.joined(separator: "\n").contains("seven") == false)
        #expect(titles.joined(separator: "\n").contains("secret") == false)

        let rendered = ReleaseNotesDigest.render(titles[0])
        let plain = String(rendered.characters)
        #expect(plain.contains("bold"))
        #expect(plain.contains("#9"))
        #expect(plain.contains("**") == false)
        #expect(plain.contains("](") == false)
        #expect(plain.contains("secret") == false)
        #expect(rendered.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(rendered.runs.contains { run in
            run.link?.absoluteString == issueURL
        })
    }

    @Test("A note that is not a bullet list still does not show raw markdown")
    func paragraphNotesRenderMarkdown() {
        let notes = "**bold** [#9](\(issueURL))"
        let rendered = ReleaseNotesDigest.render(ReleaseNotesDigest.titles(in: notes)[0])
        let plain = String(rendered.characters)
        #expect(plain.contains("bold"))
        #expect(plain.contains("#9"))
        #expect(plain.contains("**") == false)
        #expect(plain.contains("](") == false)
        #expect(rendered.runs.contains { $0.link?.absoluteString == issueURL })
    }

    @Test("Release notes keep only https links and show other schemes as text")
    func releaseNotesDropUnsafeLinks() {
        for link in ["javascript:alert(1)", "menumijia://focus?device=light"] {
            let rendered = ReleaseNotesDigest.render("**[#9](\(link))**")
            let plain = String(rendered.characters)
            #expect(plain.contains("#9"), "\(link)")
            #expect(plain.contains("javascript:") == false, "\(link)")
            #expect(plain.contains("menumijia://") == false, "\(link)")
            #expect(rendered.runs.allSatisfy { $0.link == nil }, "\(link)")
        }
    }

    @Test("An unclosed markdown link shows its label without the raw target")
    func releaseNotesDropUnclosedLinks() {
        let rendered = ReleaseNotesDigest.render("**bold** [#9](https://example.com/9")
        let plain = String(rendered.characters)
        #expect(plain.contains("bold"))
        #expect(plain.contains("#9"))
        #expect(plain.contains("](") == false)
        #expect(plain.contains("[") == false)
        #expect(plain.contains("example.com") == false)
        #expect(rendered.runs.allSatisfy { $0.link == nil })
    }

    @Test("A release-note lead-in is capped at a readable length")
    func releaseNotesCapLongLeadIns() {
        let titles = ReleaseNotesDigest.titles(in: "- \(String(repeating: "长", count: 20_000))：说明")
        #expect(titles.count == 1)
        #expect(titles[0].count <= ReleaseNotesDigest.maximumLeadInLength)
        #expect(titles[0].hasSuffix("…"))
    }

    @Test("Ordered bullets and bare markers do not leak into the digest")
    func releaseNotesHandleOrderedListsAndMarkers() {
        let titles = ReleaseNotesDigest.titles(in: "### 亮点\n1. **one**：first\n2. **two**\n-\n- ")
        #expect(titles == ["**one**", "**two**"])
        #expect(ReleaseNotesDigest.titles(in: "-\n\nplain note") == ["plain note"])
    }

    @Test("The glass switch draws its label only when the row has no title of its own")
    func glassSwitchLabelDecision() {
        #expect(GlassSwitchToggleStyle.showsLabel(glassLabelHidden: false, labelsHidden: false))
        #expect(GlassSwitchToggleStyle.showsLabel(glassLabelHidden: true, labelsHidden: false) == false)
        #expect(GlassSwitchToggleStyle.showsLabel(glassLabelHidden: false, labelsHidden: true) == false)
        #expect(GlassSwitchToggleStyle.showsLabel(glassLabelHidden: true, labelsHidden: true) == false)
    }

    @Test("Switching to 自定义 clears the address so the previous provider's key survives Save")
    func customPresetSwitchKeepsSavedKey() throws {
        let suite = "test.settings.custom.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let openRouter = "https://openrouter.ai/api/v1"
        let savedKey = "sk-or-test-key"
        AssistantConfig(baseURL: openRouter, model: "~typesafe/jev-latest", apiKey: savedKey).save(to: defaults)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: openRouter, defaults: defaults) == savedKey)

        let switched = AssistantSettingsDraft.selecting(
            .custom,
            from: .openRouterJev,
            fields: .init(baseURL: openRouter, model: "~typesafe/jev-latest", apiKey: savedKey),
            storedKey: { AssistantConfig.userStoredAPIKey(forBaseURL: $0, defaults: defaults) }
        )
        #expect(switched.baseURL.isEmpty)
        #expect(switched.apiKey.isEmpty)

        let toSave = AssistantSettingsDraft.configToSave(preset: .custom, fields: switched)
        #expect(toSave == nil)
        toSave?.save(to: defaults)

        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: openRouter, defaults: defaults) == savedKey)

        // Entering a custom endpoint URL loads its own stored key (if any) and allows saving without touching OpenRouter.
        let customEndpoint = "https://llm.example.com/v1"
        let customUpdated = AssistantSettingsDraft.updatingBaseURL(
            customEndpoint,
            currentPreset: .custom,
            fields: switched,
            storedKey: { AssistantConfig.userStoredAPIKey(forBaseURL: $0, defaults: defaults) }
        )
        #expect(customUpdated.preset == .custom)
        #expect(customUpdated.fields.baseURL == customEndpoint)
        var withCustomKey = customUpdated.fields
        withCustomKey.apiKey = "sk-custom-key"
        let savedCustom = try #require(AssistantSettingsDraft.configToSave(preset: .custom, fields: withCustomKey))
        savedCustom.save(to: defaults)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: openRouter, defaults: defaults) == savedKey)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: customEndpoint, defaults: defaults) == "sk-custom-key")
    }
}
