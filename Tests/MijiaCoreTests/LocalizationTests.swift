import Foundation
import PreferencesTestSupport
import Testing
@testable import MijiaCore

struct LocalizationTests {
    // MARK: - Fixtures

    /// The shipped resource tables, located relative to this file so the tests read the real files
    /// that `Package.swift` copies into the app (#52).
    static var shippedTablesDirectory: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Sources/MijiaCore/Resources/Localizations")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// A throwaway directory of tables used to prove a *new* language needs no Swift change.
    static func withTemporaryTables<T>(
        _ files: [String: String],
        _ body: (URL) throws -> T
    ) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("L10nTables.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, json) in files {
            try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return try L10n.$overrideTranslationDirectory.withValue(dir) { try body(dir) }
    }

    static let frenchTable = """
    {
      "id": "fr",
      "nativeName": "Français",
      "speechLocale": "fr-FR",
      "order": 20,
      "strings": {
        "已关闭": "Éteint",
        "跟随系统": "Système",
        "已同步 * 台真实米家设备": "J'ai synchronisé * appareils",
        "亮度 %@": "Luminosité %@"
      }
    }
    """

    // MARK: - Language detection

    @Test("AppLanguage detects Chinese vs English system locales")
    func systemLanguageDetection() {
        let tables = Self.shippedTablesDirectory
        L10n.$overrideTranslationDirectory.withValue(tables) {
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .zhHans)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["zh-Hant-HK"]) == .zhHant)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["zh-TW"]) == .zhHant)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["en-US", "zh-Hans"]) == .en)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["fr-FR"]) == .en)
            #expect(AppLanguagePreference.system.resolved(preferredLanguages: ["en-GB"]) == .en)
            #expect(AppLanguagePreference.zhHans.resolved(preferredLanguages: ["en-US"]) == .zhHans)
            #expect(AppLanguagePreference.en.resolved(preferredLanguages: ["zh-Hans"]) == .en)
            #expect(AppLanguagePreference(rawValue: "zh-Hant")?.resolved(preferredLanguages: ["en-US"]) == .zhHant)
        }
    }

    @Test("Language tags are canonicalised and unsupported preferences fall back")
    func tagCanonicalisation() {
        #expect(AppLanguage(rawValue: "zh_hant_tw").rawValue == "zh-Hant-TW")
        #expect(AppLanguage(rawValue: "EN").rawValue == "en")
        #expect(AppLanguage(rawValue: "  ").rawValue == "en")
        #expect(AppLanguage.zhHant.isChinese)
        #expect(!AppLanguage.en.isChinese)
        #expect(AppLanguagePreference(rawValue: "system") == .system)
        #expect(AppLanguagePreference(rawValue: "not a tag") == nil)
        // A saved tag whose table is missing is kept, so reinstalling the table restores the choice.
        #expect(AppLanguagePreference(rawValue: "ja-JP")?.rawValue == "ja-JP")
        #expect(AppLanguagePreference(rawValue: "ja-JP")?.resolved(preferredLanguages: ["en-US"]) == .en)
    }

    // MARK: - Resources

    @Test("Packaged tables are found without a source-directory override")
    func packagedTablesAreDiscovered() {
        #expect(L10n.availableLanguages.contains(.zhHant))
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(L10n.tr("已关闭", "Off") == "已關閉")
        }
    }

    @Test("Camera toolbar labels ship in Traditional Chinese, not the Simplified fallback")
    func cameraToolbarLabelsShipInTraditionalChinese() {
        let tables = Self.shippedTablesDirectory
        L10n.$overrideTranslationDirectory.withValue(tables) {
            L10n.$overrideLanguage.withValue(.zhHant) {
                #expect(L10n.tr("置顶小窗", "Pin window") == "置頂小窗")
                #expect(L10n.tr("取消置顶", "Unpin") == "取消置頂")
                #expect(L10n.tr("旋转画面", "Rotate picture") == "旋轉畫面")
                #expect(L10n.tr("仅画面", "Video only") == "僅畫面")
                #expect(L10n.tr("开启声音", "Unmute audio") == "開啟聲音")
                #expect(L10n.tr("关闭声音", "Mute audio") == "關閉聲音")
                #expect(L10n.tr("最大化画面窗口", "Maximize camera window") == "最大化畫面視窗")
                #expect(L10n.tr("恢复窗口大小", "Restore window size") == "恢復視窗大小")
                #expect(L10n.tr("关闭摄像头小窗", "Close camera window") == "關閉攝影機小窗")
                #expect(L10n.tr("画面操作", "Picture controls") == "畫面操作")
            }
            L10n.$overrideLanguage.withValue(.en) {
                #expect(L10n.tr("置顶小窗", "Pin window") == "Pin window")
                #expect(L10n.tr("取消置顶", "Unpin") == "Unpin")
                #expect(L10n.tr("旋转画面", "Rotate picture") == "Rotate picture")
            }
            let p2pZh = "正在建立 P2P 加密通道并解码实时画面…"
            let p2pEn = "Establishing P2P encrypted channel & decoding live video…"
            let mjpegZh = "正在接收 MJPEG 画面流…"
            let mjpegEn = "Receiving the MJPEG picture stream…"
            L10n.$overrideLanguage.withValue(.zhHans) {
                #expect(L10n.tr(mjpegZh, mjpegEn) != L10n.tr(p2pZh, p2pEn))
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                #expect(L10n.tr(mjpegZh, mjpegEn) == "正在接收 MJPEG 畫面流…")
                #expect(L10n.tr(mjpegZh, mjpegEn) != L10n.tr(p2pZh, p2pEn))
            }
            L10n.$overrideLanguage.withValue(.en) {
                #expect(L10n.tr(mjpegZh, mjpegEn) == mjpegEn)
                #expect(L10n.tr(mjpegZh, mjpegEn) != L10n.tr(p2pZh, p2pEn))
            }
        }
    }

    @Test("Transport readouts, stale sensor labels, and local network status localize across zh-Hans, zh-Hant, and en")
    func transportAndStaleSensorLabelsShipInAllBuiltInLanguages() {
        let tables = Self.shippedTablesDirectory
        L10n.$overrideTranslationDirectory.withValue(tables) {
            let cases: [(zhHans: String, zhHant: String, en: String)] = [
                ("米家云端", "米家雲端", "Xiaomi Cloud"),
                ("可能过期", "可能過期", "Possibly stale"),
                ("卧室传感器，可能过期", "卧室传感器，可能過期", "Bedroom Sensor, possibly stale"),
                ("卧室传感器，离线", "卧室传感器，離線", "Bedroom Sensor, offline"),
                ("自动择优（默认）", "自動擇優（預設）", "Automatic (Default)"),
                ("数据来源", "資料來源", "Data Source"),
                ("当前没有检测到本地网络受阻", "目前沒有偵測到本機網路受阻", "No local network block detected right now"),
                ("局域网直连", "區域網路直連", "LAN Direct"),
                ("通信通道：局域网直连（12 ms）", "通訊通道：區域網路直連（12 ms）", "Transport: LAN Direct (12 ms)"),
                ("通信通道：米家云端", "通訊通道：米家雲端", "Transport: Xiaomi Cloud"),
                ("通信通道：云端回退（局域网重连中）", "通訊通道：雲端回退（區域網路重連中）", "Transport: Cloud Fallback (reconnecting LAN)"),
                ("通信通道：本地网络权限受阻", "通訊通道：本機網路權限受阻", "Transport: Local network blocked"),
            ]
            for item in cases {
                L10n.$overrideLanguage.withValue(.zhHans) {
                    #expect(L10n.tr(item.zhHans, item.en) == item.zhHans)
                }
                L10n.$overrideLanguage.withValue(.zhHant) {
                    #expect(L10n.tr(item.zhHans, item.en) == item.zhHant)
                }
                L10n.$overrideLanguage.withValue(.en) {
                    #expect(L10n.tr(item.zhHans, item.en) == item.en)
                }
            }
        }
    }

    @Test("Shipped tables are found and listed without Swift cases")
    func shippedTablesAreDiscovered() throws {
        let dir = Self.shippedTablesDirectory
        let tableURL = dir.appendingPathComponent("zh-Hant.json")
        #expect(FileManager.default.fileExists(atPath: tableURL.path))

        let data = try Data(contentsOf: tableURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] as? String == "zh-Hant")
        #expect(json["nativeName"] as? String == "繁體中文")
        let strings = try #require(json["strings"] as? [String: String])
        #expect(strings.count > 500, "the table should cover the inline tr() call sites")
        // Spot-check that the table really translates rather than echoing Simplified Chinese.
        #expect(strings["已关闭"] == "已關閉")
        #expect(strings["跟随系统"] == "跟隨系統")
        #expect(strings["当前室温 %@"] == "當前室溫 %@")
        for (key, value) in strings {
            #expect(!key.isEmpty && !value.isEmpty)
            #expect(key.filter { $0 == "*" }.count == value.filter { $0 == "*" }.count, "Wildcard mismatch for \(key)")
            #expect(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, "Format mismatch for \(key)")
        }

        L10n.$overrideTranslationDirectory.withValue(dir) {
            #expect(L10n.availableLanguages.contains(.zhHant))
            #expect(L10n.availableLanguages.prefix(2) == [.zhHans, .en])
            #expect(L10n.nativeName(for: .zhHant) == "繁體中文")
            #expect(L10n.speechLocaleIdentifier(for: .zhHant) == "zh-TW")
            L10n.$overrideLanguage.withValue(.zhHans) {
                #expect(L10n.tr("已关闭", "Off") == "已关闭")
            }
            L10n.$overrideLanguage.withValue(.zhHant) {
                #expect(L10n.tr("缺少状态码", "Missing status code") == "缺少狀態碼")
                #expect(L10n.tr("设备未响应或离线", "Device did not respond or is offline") == "裝置未響應或離線")
                #expect(L10n.tr("全屋设备均关闭", "All devices are off") == "全屋裝置均關閉")
            }
            L10n.$overrideLanguage.withValue(.en) {
                #expect(L10n.tr("已关闭", "Off") == "Off")
            }
        }
    }

    @Test("Adding a language is a resource file, not a Swift change")
    func newLanguageFromResourceOnly() throws {
        try Self.withTemporaryTables(["fr.json": Self.frenchTable]) { _ in
            #expect(L10n.availableLanguages.contains(AppLanguage(rawValue: "fr")))
            #expect(AppLanguagePreference.allCases.contains(AppLanguagePreference(rawValue: "fr")!))
            #expect(AppLanguagePreference(rawValue: "fr")?.resolved(preferredLanguages: ["en-US"]) == AppLanguage(rawValue: "fr"))
            #expect(AppLanguagePreference(rawValue: "fr-CA")?.resolved(preferredLanguages: ["en-US"]) == AppLanguage(rawValue: "fr"))
            #expect(L10n.nativeName(for: AppLanguage(rawValue: "fr")) == "Français")
            #expect(L10n.speechLocaleIdentifier(for: AppLanguage(rawValue: "fr")) == "fr-FR")

            L10n.$overrideLanguage.withValue(AppLanguage(rawValue: "fr")) {
                #expect(L10n.tr("已关闭", "Off") == "Éteint")
                #expect(L10n.tr("跟随系统", "System Default") == "Système")
                // A string the table does not carry falls back to English, never to an empty label.
                #expect(L10n.tr("打开设置", "Open Settings") == "Open Settings")
                // `*` patterns absorb the interpolated part.
                #expect(L10n.tr("已同步 5 台真实米家设备", "Synced 5 devices") == "J'ai synchronisé 5 appareils")
                // Positional `%@` is filled from the arguments, not `String(format:)`.
                #expect(L10n.format("亮度 %@", "Brightness %@", "60") == "Luminosité 60")
            }
        }
    }

    @Test("Chinese tables fall back to Simplified Chinese, not English")
    func chineseFallback() throws {
        try Self.withTemporaryTables([
            "zh-Hant.json": """
            { "id": "zh-Hant", "nativeName": "繁體中文", "speechLocale": "zh-TW",
              "strings": { "已关闭": "已關閉" } }
            """
        ]) { _ in
            L10n.$overrideLanguage.withValue(.zhHant) {
                #expect(L10n.tr("已关闭", "Off") == "已關閉")
                // Missing from the Traditional table: Chinese text, not the English one.
                #expect(L10n.tr("打开设置", "Open Settings") == "打开设置")
            }
        }
    }

    @Test("Malformed or empty tables are ignored instead of breaking the picker")
    func malformedTablesIgnored() throws {
        try Self.withTemporaryTables([
            "broken.json": "{ not json",
            "empty.json": #"{ "id": "de", "strings": {} }"#,
            "notes.txt": "ignored",
        ]) { _ in
            let languages = L10n.availableLanguages
            #expect(languages.prefix(2) == [.zhHans, .en])
            #expect(languages.contains(AppLanguage(rawValue: "de")))
            #expect(!languages.contains(AppLanguage(rawValue: "broken")))
            L10n.$overrideLanguage.withValue(AppLanguage(rawValue: "de")) {
                #expect(L10n.tr("已关闭", "Off") == "Off")
            }
        }
    }

    @Test("Translation directories are discovered through the documented bundle names")
    func directoryDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("L10nBundle.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root
            .appendingPathComponent("MenuBarMijia_MijiaCore.bundle/Contents/Resources/Localizations")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try #"{ "id": "nl", "strings": { "已关闭": "Uit" } }"#
            .write(to: nested.appendingPathComponent("nl.json"), atomically: true, encoding: .utf8)

        let candidates = [
            root.appendingPathComponent("MenuBarMijia_MijiaCore.bundle/Contents/Resources/Localizations"),
            root.appendingPathComponent("MenuBarMijia_MijiaCore.bundle/Localizations"),
        ]
        #expect(L10n.firstTranslationDirectory(in: candidates)?.path == nested.path)
        var visited: [URL] = []
        let lazyCandidates = candidates.lazy.map { candidate in
            visited.append(candidate)
            return candidate
        }
        #expect(L10n.firstTranslationDirectory(in: lazyCandidates)?.path == nested.path)
        #expect(visited == [candidates[0]])
        // A base directory with no tables at all yields nothing rather than a wrong path.
        #expect(L10n.firstTranslationDirectory(in: [root.appendingPathComponent("Missing")]) == nil)
        // Package-specific names are recognised (`<Package>_MijiaCore.bundle|.resources`).
        #expect(L10n.resourceDirectoryNames(in: root).contains("MenuBarMijia_MijiaCore.bundle"))
    }

    @Test("Numeric runs collapse so one table entry serves every value")
    func numericNormalisation() {
        #expect(L10n.normalizedNumbers("已同步 12 台设备") == "已同步 # 台设备")
        #expect(L10n.normalizedNumbers("室温 26.5°C") == "室温 #°C")
        #expect(L10n.normalizedNumbers("当前设定 25°C，请确认") == "当前设定 #°C，请确认")
        #expect(L10n.normalizedNumbers("没有数字") == "没有数字")
        #expect(L10n.captures(pattern: "已同步 * 台设备", against: "已同步 12 台设备") == ["12"])
        #expect(L10n.captures(pattern: "已同步 * 台设备", against: "别的句子") == nil)
        #expect(L10n.fill("亮度 *%（*）", with: ["60", "书房"]) == "亮度 60%（书房）")
    }

    @Test("Traditional Chinese timer descriptions use the shipped resource table")
    func traditionalTimerDescriptions() {
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(DelayPhrase.describe(30) == "30 秒後")
            #expect(DelayPhrase.describe(90) == "1 分鐘 30 秒後")
            #expect(DelayPhrase.describe(600) == "10 分鐘後")
            #expect(DelayPhrase.describe(3600) == "1 小時後")
            #expect(DelayPhrase.describe(3630) == "1 小時 30 秒後")
            #expect(DelayPhrase.describe(3690) == "1 小時 1 分鐘 30 秒後")
            #expect(DelayPhrase.describe(5400) == "1 小時 30 分鐘後")
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(DelayPhrase.describe(30) == "30 秒后")
            #expect(DelayPhrase.describe(90) == "1 分钟 30 秒后")
            #expect(DelayPhrase.describe(600) == "10 分钟后")
            #expect(DelayPhrase.describe(3600) == "1 小时后")
            #expect(DelayPhrase.describe(3630) == "1 小时 30 秒后")
            #expect(DelayPhrase.describe(3690) == "1 小时 1 分钟 30 秒后")
            #expect(DelayPhrase.describe(5400) == "1 小时 30 分钟后")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(DelayPhrase.describe(30) == "In 30s: ")
            #expect(DelayPhrase.describe(90) == "In 1m 30s: ")
            #expect(DelayPhrase.describe(600) == "In 10m: ")
            #expect(DelayPhrase.describe(3600) == "In 1h: ")
            #expect(DelayPhrase.describe(3630) == "In 1h 30s: ")
            #expect(DelayPhrase.describe(3690) == "In 1h 1m 30s: ")
            #expect(DelayPhrase.describe(5400) == "In 1h 30m: ")
        }
    }

    @Test("Traditional Chinese voice input toggle and descriptions use the shipped resource table")
    func traditionalVoiceInputToggle() {
        let toggleCaptionZh = "开启后，面板顶部显示麦克风按钮，也能按 V 或长按菜单栏图标、全局快捷键说话。关闭后隐藏麦克风按钮，也不会启动语音识别。"
        let toggleCaptionEn = "When on, the panel shows the microphone button and lets you speak by pressing V or holding the menu bar icon or global shortcut. When off, the microphone button is hidden and voice recognition never starts."

        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(L10n.tr("语音输入", "Voice Input") == "語音輸入")
            #expect(L10n.tr(toggleCaptionZh, toggleCaptionEn) == "開啟後，面板頂部顯示麥克風按鈕，也能按 V 或長按選單欄圖示、全域快捷鍵說話。關閉後隱藏麥克風按鈕，也不會啟動語音識別。")
            #expect(L10n.tr("启用全局快捷键 ⌥M（短按面板，长按语音）", "Global shortcut ⌥M (tap for dashboard, hold to speak)") == "啟用全域性快捷鍵 ⌥M（短按面板，長按語音）")
            #expect(L10n.tr("启用全局快捷键 ⌥M（打开/收起面板）", "Global shortcut ⌥M (open or close dashboard)") == "啟用全域性快捷鍵 ⌥M（開啟/收起面板）")
            #expect(L10n.tr("搜索设备，或直接说一句话", "Search devices, or say a command") == "搜尋裝置，或直接說一句話")
            #expect(L10n.tr("搜索设备，或输入一句话", "Search devices, or type a command") == "搜尋裝置，或輸入一句話")
            #expect(L10n.tr("轻点展开或收起建议，拖动调整位置，长按开始语音输入", "Click to toggle suggestions, drag to reposition, or hold to start voice input") == "輕點展開或收起建議，拖動調整位置，長按開始語音輸入")
            #expect(L10n.tr("轻点展开或收起建议，拖动调整位置", "Click to toggle suggestions or drag to reposition") == "輕點展開或收起建議，拖動調整位置")
            #expect(L10n.tr("轻点推荐 · 拖动移位 · 长按说话", "Click for suggestions · Drag to move · Hold to speak") == "輕點推薦 · 拖動移位 · 長按說話")
            #expect(L10n.tr("轻点推荐 · 拖动移位", "Click for suggestions · Drag to move") == "輕點推薦 · 拖動移位")
        }

        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(L10n.tr("语音输入", "Voice Input") == "语音输入")
            #expect(L10n.tr(toggleCaptionZh, toggleCaptionEn) == toggleCaptionZh)
            #expect(L10n.tr("启用全局快捷键 ⌥M（打开/收起面板）", "Global shortcut ⌥M (open or close dashboard)") == "启用全局快捷键 ⌥M（打开/收起面板）")
        }

        L10n.$overrideLanguage.withValue(.en) {
            #expect(L10n.tr("语音输入", "Voice Input") == "Voice Input")
            #expect(L10n.tr(toggleCaptionZh, toggleCaptionEn) == toggleCaptionEn)
            #expect(L10n.tr("启用全局快捷键 ⌥M（打开/收起面板）", "Global shortcut ⌥M (open or close dashboard)") == "Global shortcut ⌥M (open or close dashboard)")
        }
    }

    @Test("Habit readable items and offline bare-category replies follow active UI language (C13, F30h)")
    func habitDayTypeSuffixAndOfflineReplyLocalization() throws {
        var memory = UserHabitMemory()
        let cal = Calendar.current
        // 2026-10-16 is a Friday (weekday).
        let fridayEvening = try #require(
            cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 21, minute: 0))
        )
        memory.record(
            utterance: nil,
            intents: [DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true))],
            devices: AssistantTests.devices,
            scenes: AssistantTests.scenes,
            now: fridayEvening
        )
        L10n.$overrideLanguage.withValue(.en) {
            let items = memory.readableItems(devices: AssistantTests.devices, scenes: AssistantTests.scenes)
            #expect(items.first?.text.hasPrefix("Evening (Weekday):") == true)
            #expect(items.first?.text.contains("（") == false)
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            let items = memory.readableItems(devices: AssistantTests.devices, scenes: AssistantTests.scenes)
            #expect(items.first?.text.hasPrefix("夜晚常做（工作日）：") == true)
        }

        let offlineLight = SmartDevice(
            id: "dev_offline_light",
            name: "书房吸顶灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.ceiling20",
            isOnline: false,
            kind: .light(LightSpec(entityId: "light.offline", isOn: true))
        )
        try L10n.$overrideLanguage.withValue(.en) {
            let plan = try #require(LocalIntentParser.parse("turn off the lights", devices: [offlineLight], scenes: []))
            #expect(plan.intents.isEmpty)
            #expect(plan.reply == "The lights are offline")
        }
    }

    // MARK: - Temperature units

    @Test(
        "Display unit follows the system region, never the stored value",
        arguments: zip(
            [
                "en-US", "en_US", "zh-Hans-CN", "zh-Hant-TW", "de-DE",
                "my-MM", "en", "en-u-ca-gregory", "en-US@calendar=gregorian",
            ],
            [
                TemperatureUnit.fahrenheit, .fahrenheit, .celsius, .celsius, .celsius,
                .fahrenheit, .celsius, .celsius, .fahrenheit,
            ]
        )
    )
    func unitFromLocale(identifier: String, expected: TemperatureUnit) {
        #expect(TemperatureUnit.resolved(localeIdentifier: identifier) == expected)
        #expect(TemperatureUnitPreference.system.resolved(localeIdentifier: identifier) == expected)
        #expect(TemperatureUnitPreference.celsius.resolved(localeIdentifier: identifier) == .celsius)
        #expect(TemperatureUnitPreference.fahrenheit.resolved(localeIdentifier: identifier) == .fahrenheit)
    }

    @Test("Celsius values render in the display unit without touching the stored value")
    func temperatureFormatting() {
        L10n.$overrideTemperatureUnit.withValue(.celsius) {
            #expect(L10n.temperature(24) == "24°C")
            #expect(L10n.temperature(25.5) == "25.5°C")
            #expect(L10n.temperatureValue(24.5) == "24.5")
            #expect(L10n.temperature(26.5, fractionDigits: 1) == "26.5°C")
            #expect(L10n.temperatureValue(26.5, fractionDigits: 1) == "26.5")
            #expect(L10n.temperatureSymbol == "°C")
            #expect(L10n.temperatureNumber(24) == 24)
        }
        L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
            #expect(L10n.temperature(0) == "32°F")
            #expect(L10n.temperature(100) == "212°F")
            #expect(L10n.temperature(24) == "75°F")
            #expect(L10n.temperatureSymbol == "°F")
        }
    }

    @Test("Thermostat steps stay Celsius in the core and 1°F per tap in Fahrenheit")
    func temperatureSteps() {
        L10n.$overrideTemperatureUnit.withValue(.celsius) {
            #expect(L10n.celsiusStep(0.5) == 0.5)
        }
        L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
            #expect(abs(L10n.celsiusStep(0.5) - 5.0 / 9.0) < 0.0001)
            let start = 24.0
            let stepped = start + L10n.celsiusStep(0.5)
            #expect(abs((L10n.temperatureNumber(stepped) - L10n.temperatureNumber(start)) - 1) < 0.0001)
        }
    }

    // MARK: - Existing inline API

    @Test("Device subtitles follow the display unit while the model stays Celsius")
    func subtitleUsesDisplayUnit() {
        let ac = SmartDevice(
            id: "dev_ac", name: "AC", roomId: "living", roomName: "客厅",
            model: "xiaomi.aircondition.mt0", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.ac", isOn: true, hvacMode: "cool",
                availableModes: ["cool"], targetTemperature: 25.0, currentTemperature: 22.0
            ))
        )
        let sensor = SmartDevice(
            id: "dev_sensor", name: "Sensor", roomId: "living", roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t2", isOnline: true,
            kind: .sensor(SensorSpec(temperature: 22.0, humidity: 48))
        )
        L10n.$overrideLanguage.withValue(.zhHans) {
            L10n.$overrideTemperatureUnit.withValue(.celsius) {
                #expect(ac.statusSubtitle.contains("25°C"))
                #expect(ac.statusSubtitle.contains("22°C"))
                #expect(sensor.statusSubtitle == "22.0°C · 48%")
            }
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
                #expect(ac.statusSubtitle.contains("77°F"))
                #expect(ac.statusSubtitle.contains("72°F"))
                #expect(sensor.statusSubtitle == "71.6°F · 48%")
                // The underlying spec is untouched.
                guard case .climate(let spec) = ac.kind else { return }
                #expect(spec.targetTemperature == 25.0)
            }
        }
    }

    @Test("LocalIntentParser parses English smart home commands and replies in English")
    func englishLocalIntentParsing() throws {
        try L10n.$overrideLanguage.withValue(.en) {
            let onPlan = try #require(AssistantTests.parse("turn on study light"))
            #expect(onPlan.source == .local)
            #expect(onPlan.intents == [
                DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true)),
                DeviceIntent(targetId: "dev_study_desk", operation: .power(true))
            ])
            #expect(onPlan.reply == "Turned on 书房吸顶灯, 书房台灯")

            let moonPlan = try #require(AssistantTests.parse("study light moonlight mode"))
            #expect(moonPlan.intents == [
                DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night"))
            ])
            #expect(moonPlan.reply == "Switched 书房吸顶灯 to Moonlight mode")

            let tempPlan = try #require(L10n.$overrideTemperatureUnit.withValue(.celsius) {
                AssistantTests.parse("set living room ac to 24 degrees")
            })
            #expect(tempPlan.intents == [
                DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(24))
            ])
            #expect(tempPlan.reply == "Set 客厅空调 to 24°C")
            let fahrenheitPlan = try #require(L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
                AssistantTests.parse("set living room ac to 24 degrees")
            })
            #expect(fahrenheitPlan.intents == tempPlan.intents)
            #expect(fahrenheitPlan.reply == "Set 客厅空调 to 75.2°F")

            let coolPlan = try #require(AssistantTests.parse("living room ac cool mode"))
            #expect(coolPlan.intents == [
                DeviceIntent(targetId: "dev_living_ac", operation: .hvacMode("cool"))
            ])
            #expect(coolPlan.reply == "Switched 客厅空调 to Cool")

            let dimPlan = try #require(AssistantTests.parse("dimmer"))
            #expect(dimPlan.intents == [
                DeviceIntent(targetId: "dev_bedside", operation: .brightness(60))
            ])
        }
    }

    @Test("DelayPhrase and UndoPhrase support English spoken timers and undo commands")
    func englishDelayAndUndoPhrases() throws {
        try L10n.$overrideLanguage.withValue(.en) {
            let match = try #require(DelayPhrase.extract("in 10 minutes turn off study light"))
            #expect(match.delay == 600)
            #expect(match.remainder == "turn off study light")
            #expect(DelayPhrase.describe(match.delay) == "In 10m: ")

            let secMatch = try #require(DelayPhrase.extract("after 30 seconds turn on bedside lamp"))
            #expect(secMatch.delay == 30)
            #expect(secMatch.remainder == "turn on bedside lamp")

            #expect(DelayPhrase.isCancel("cancel timer"))
            #expect(DelayPhrase.isCancel("clear all timers"))
            #expect(UndoPhrase.isUndo("undo"))
            #expect(UndoPhrase.isUndo("undo that"))
            #expect(UndoPhrase.isUndo("revert"))
        }
    }

    // MARK: - Persistence

    @Test("HomeStore persists appLanguagePreference and miCloudRegion")
    @MainActor
    func homeStoreLanguageAndRegionPersistence() throws {
        // One instance for the store and for the assertions: a second `UserDefaults(suiteName:)`
        // reads through cfprefsd and can serve a stale cache (#309).
        let defaults = InMemoryUserDefaults()

        let store = HomeStore(provider: MockHomeProvider(), defaults: defaults)
        #expect(store.appLanguagePreference == .system)
        #expect(store.miCloudRegion == .cn)

        store.appLanguagePreference = .en
        store.miCloudRegion = .sg
        #expect(store.effectiveLanguage == .en)
        #expect(store.homeName == "My Home")
        #expect(defaults.string(forKey: "app_language") == "en")
        #expect(defaults.string(forKey: "mi_cloud_region") == "sg")

        store.appLanguagePreference = .zhHans
        #expect(store.effectiveLanguage == .zhHans)
        #expect(store.homeName == "我的家")

        // Traditional Chinese is a first-class stored preference now (#52).
        store.appLanguagePreference = .zhHant
        #expect(store.effectiveLanguage == .zhHant)
        #expect(defaults.string(forKey: "app_language") == "zh-Hant")
        #expect(AppLanguagePreference(rawValue: defaults.string(forKey: "app_language") ?? "") == .zhHant)
    }

    /// The English scope is task-local. A concurrent reader that did not opt in keeps Simplified Chinese.
    @Test("An English override on one task leaves another task in Simplified Chinese")
    func englishOverrideStaysOnItsTask() async {
        let mismatches = await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var bad = 0
                for _ in 0..<8000 {
                    if L10n.tr("已上锁", "Locked") != "已上锁" { bad += 1 }
                    let unknown = L10n.tr("锁状态未知", "Lock status unknown")
                    if unknown != "锁状态未知" { bad += 1 }
                }
                return bad
            }
            group.addTask {
                var bad = 0
                for _ in 0..<8000 {
                    let saw = L10n.$overrideLanguage.withValue(.en) {
                        L10n.tr("已上锁", "Locked")
                    }
                    if saw != "Locked" { bad += 1 }
                }
                return bad
            }
            var total = 0
            for await count in group { total += count }
            return total
        }
        #expect(mismatches == 0)
    }
}
