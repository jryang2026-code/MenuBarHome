import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

/// P5a-M acceptance 4: the AI switch, its off hint, the off banner and the removal wording
/// ship in zh-Hans, zh-Hant and en (P5a-W parity).
struct AssistantToggleWordingTests {
    @Test("AI toggle and removal wording ships in all three languages")
    func toggleWordingShipsInThreeLanguages() async throws {
        for language in [AppLanguage.zhHans, AppLanguage.zhHant, AppLanguage.en] {
            try await L10n.$overrideLanguage.withValue(language) {
                #expect(AssistantSettingsCopy.enableTitle.isEmpty == false)
                #expect(AssistantSettingsCopy.disabledHint.isEmpty == false)
                #expect(AssistantSettingsCopy.removeProvider.isEmpty == false)
                #expect(AssistantSettingsCopy.removeProviderConfirm.isEmpty == false)
                // zh-Hant must come from the translation table, not fall back to zh-Hans.
                if language == .zhHant {
                    #expect(AssistantSettingsCopy.enableTitle == "啟用 AI 一句話控制")
                    #expect(AssistantSettingsCopy.disabledHint == "關閉後不再傳送 AI 請求，指令只在本機解析；已儲存的服務商設定與金鑰會保留。")
                    #expect(AssistantSettingsCopy.removeProvider == "移除此服務商")
                    #expect(AssistantSettingsCopy.removeProviderConfirm == "再點一次確認移除")
                }
                if language == .en {
                    #expect(AssistantSettingsCopy.enableTitle == "Enable AI command control")
                    #expect(AssistantSettingsCopy.disabledHint == "When off, no AI requests are sent; commands are parsed on this Mac. Saved provider settings and keys are kept.")
                    #expect(AssistantSettingsCopy.removeProvider == "Remove this provider")
                    #expect(AssistantSettingsCopy.removeProviderConfirm == "Click again to confirm removal")
                }
            }
        }
    }

    @Test("Proactive-suggestions switch wording ships in all three languages (P5b-M)")
    func proactiveWordingShipsInThreeLanguages() async throws {
        let refused = (zh: "无法保存主动建议开关状态，请重试", en: "Could not save the suggestions switch; try again")
        let stageOff = (zh: "主动建议已关闭，可在设置中重新开启", en: "Proactive suggestions are off. Turn them back on in Settings.")
        for language in [AppLanguage.zhHans, AppLanguage.zhHant, AppLanguage.en] {
            try await L10n.$overrideLanguage.withValue(language) {
                switch language {
                case .zhHant:
                    #expect(AssistantSettingsCopy.proactiveTitle == "主動建議（猜你想做）")
                    #expect(AssistantSettingsCopy.proactiveHint == "關閉後，面板不再顯示建議，也不再為建議做後台推斷；安全提醒、撤銷和定時照常運行。")
                    #expect(L10n.tr(refused.zh, refused.en) == "無法儲存主動建議開關狀態，請重試")
                    #expect(L10n.tr(stageOff.zh, stageOff.en) == "主動建議已關閉，可在設定中重新開啟")
                case .en:
                    #expect(AssistantSettingsCopy.proactiveTitle == "Proactive suggestions")
                    #expect(AssistantSettingsCopy.proactiveHint == "When off, the panel shows no suggestions and makes no background inference for them; safety alerts, undo and timers keep running.")
                    #expect(L10n.tr(refused.zh, refused.en) == refused.en)
                    #expect(L10n.tr(stageOff.zh, stageOff.en) == stageOff.en)
                default:
                    #expect(AssistantSettingsCopy.proactiveTitle == "主动建议（猜你想做）")
                    #expect(L10n.tr(stageOff.zh, stageOff.en) == stageOff.zh)
                }
            }
        }
    }

    @Test("The AI-off banner and probe wording ships in all three languages")
    func bannerWordingShipsInThreeLanguages() async throws {
        let offBanner = (
            zh: "AI 一句话控制已关闭，指令只在本机解析；可在设置中重新开启。",
            en: "AI command control is off; commands are parsed on this Mac only. You can turn it back on in Settings."
        )
        let probeOff = (
            zh: "AI 一句话控制已关闭，测试连接不可用",
            en: "AI command control is off; the connection check is unavailable"
        )
        let probeAbort = (
            zh: "AI 已关闭或服务商已切换，测试中止",
            en: "AI was disabled or the provider changed; the check was aborted"
        )
        for language in [AppLanguage.zhHans, AppLanguage.zhHant, AppLanguage.en] {
            try await L10n.$overrideLanguage.withValue(language) {
                #expect(L10n.tr(offBanner.zh, offBanner.en).isEmpty == false)
                #expect(L10n.tr(probeOff.zh, probeOff.en).isEmpty == false)
                #expect(L10n.tr(probeAbort.zh, probeAbort.en).isEmpty == false)
                // zh-Hant must come from the translation table, not fall back to zh-Hans.
                if language == .zhHant {
                    #expect(L10n.tr(offBanner.zh, offBanner.en) == "AI 一句話控制已關閉，指令只在本機解析；可在設定中重新開啟。")
                    #expect(L10n.tr(probeOff.zh, probeOff.en) == "AI 一句話控制已關閉，測試連線不可用")
                    #expect(L10n.tr(probeAbort.zh, probeAbort.en) == "AI 已關閉或服務商已切換，測試中止")
                }
            }
        }
    }
}
