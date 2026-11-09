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
            let visible = AssistantSettingsCopy.collapsedSurface(
                presetTitle: AssistantProviderPreset.openRouterJev.title
            ).joined(separator: "\n")
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
}
