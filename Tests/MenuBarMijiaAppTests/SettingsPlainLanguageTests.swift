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
    }

    @Test("The read-more link names the release notes")
    func readMoreTitle() {
        let previous = L10n.currentLanguage
        defer { L10n.currentLanguage = previous }
        L10n.currentLanguage = .zhHans
        #expect(ReleaseNotesDigest.readMoreTitle == "查看完整更新记录 →")
        L10n.currentLanguage = .en
        #expect(ReleaseNotesDigest.readMoreTitle == "See the full release notes →")
    }

    @Test("The collapsed assistant tab is plain language")
    func collapsedAssistantHidesDeveloperVocabulary() {
        let previous = L10n.currentLanguage
        defer { L10n.currentLanguage = previous }
        for language in [AppLanguage.zhHans, AppLanguage.en] {
            L10n.currentLanguage = language
            let header = AssistantSettingsCopy.headerStatus(isInsecure: false, hasKey: true, isLoopback: false)
            #expect(header == AssistantSettingsCopy.keySaved)
            let visible = AssistantSettingsCopy.collapsedSurface(
                presetTitle: AssistantProviderPreset.openRouterJev.title,
                hasKey: true
            ).joined(separator: "\n")
            #expect(visible.contains(AssistantSettingsCopy.keySaved))
            #expect(visible.contains("CodexBar") == false)
            #expect(visible.contains("OPENROUTER_API_KEY") == false)
            #expect(
                AssistantSettingsCopy.containsDeveloperJargon(visible) == false,
                "\(language.rawValue) shows developer vocabulary: \(visible)"
            )
            #expect(AssistantSettingsCopy.containsDeveloperJargon(AssistantSettingsCopy.protocolNote))
            #expect(visible.contains(AssistantSettingsCopy.learnHabits))
            #expect(visible.contains(AssistantSettingsCopy.shareHabits))
            #expect(visible.contains(AssistantSettingsCopy.onDeviceSpeech))
        }
        L10n.currentLanguage = .zhHans
        #expect(AssistantSettingsCopy.title == "AI 助手（可选）")
        #expect(AssistantSettingsCopy.subtitle.contains("不填也能用：开关、调光、温度等常规指令在本机解析"))
        #expect(AssistantSettingsCopy.advancedTitle == "高级")
        #expect(AssistantSettingsCopy.modelLabel == "模型")
        #expect(AssistantSettingsCopy.serviceAddressLabel == "服务地址")
        #expect(AssistantSettingsCopy.learnHabits.hasPrefix("学习我的使用习惯"))
        #expect(AssistantSettingsCopy.shareHabits.hasPrefix("发送习惯摘要"))
        #expect(AssistantSettingsCopy.onDeviceSpeech.hasPrefix("语音只在本机识别"))
    }

    @Test("The new card copy is translated into Traditional Chinese")
    func newCardCopyHasHantTranslations() {
        let previous = L10n.currentLanguage
        defer { L10n.currentLanguage = previous }
        L10n.currentLanguage = .zhHant
        #expect(AssistantSettingsCopy.title == "AI 助手（可選）")
        #expect(AssistantSettingsCopy.subtitle == "不填也能用：開關、調光、溫度等常規指令在本機解析")
        #expect(AssistantSettingsCopy.providerLabel == "服務商")
        #expect(AssistantSettingsCopy.advancedTitle == "進階")
        #expect(AssistantSettingsCopy.serviceAddressLabel == "服務地址")
        #expect(AssistantSettingsCopy.modelLabel == "模型")
        #expect(AssistantSettingsCopy.apiKeyPlaceholder == "貼上 API Key，沒有也能用")
        #expect(AssistantSettingsCopy.keySaved == "已填寫")
        #expect(AssistantSettingsCopy.loopback == "本機免密")
        #expect(AssistantSettingsCopy.httpsRequired == "需用 https，否則不會傳送")
        #expect(AssistantSettingsCopy.customAddressRequired == "請先填寫自定義服務地址")
        #expect(ReleaseNotesDigest.readMoreTitle == "檢視完整更新記錄 →")
    }
}
