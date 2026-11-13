import Foundation
import SwiftUI
import MijiaCore

// MARK: - Anchors

/// One addressable setting row in the ⌘, window.
///
/// The sidebar lists categories; the search has to reach a single row, so every searchable row owns
/// an anchor. `SettingsSearch.entries()` maps an anchor to the words a person might type for it, and
/// the row itself attaches the anchor through `settingsRow(anchor:)`, which both registers the scroll
/// target and draws the landing highlight.
enum SettingsAnchor: String, CaseIterable, Hashable, Sendable {
    // 通用
    case language
    case temperatureUnit
    case dashboardTitle
    case menuBarReadout
    case compactGrid
    case hideOfflineDevices
    case hideGroupedLights
    case quickScenesBar
    case grokBall
    case soundFeedback
    case launchAtLogin
    case advancedDeviceWrites
    case globalHotkey
    case safetyAlerts
    case sensorAlerts
    case alertsOnlyWhenAway
    case doorbellAutoView
    case doorbellChime
    case doorbellAutoCloseSeconds
    case weeklyReport
    case notificationPermission
    case hiddenDevices
    case setupGuide
    case automationRules
    case allowURLControl
    case raycast
    case energyHistory

    // 连接
    case demoMode
    case haServerAddress
    case haToken
    case haDiscovery
    case miAccount
    case lgTV

    // 助手
    case askWhenUnsure
    case confidenceThreshold
    case assistantProvider
    case assistantAPIKey
    case assistantTest
    case habitMemory

    // 外观
    case appearanceMode
    case panelTheme
    case panelHeight
    case climatePanelModule

    // 隐私
    case copyDiagnostics
    case scanUnsupportedDevices
    case privacyNotes
    case blockControlWhileLocked
    case signOut

    // 关于
    case aboutVersion
    case softwareUpdate
    case quitApp

    /// The category page that renders this row.
    var tab: SettingsTab {
        switch self {
        case .language, .temperatureUnit, .dashboardTitle, .menuBarReadout, .compactGrid,
             .hideOfflineDevices, .hideGroupedLights, .quickScenesBar, .grokBall, .soundFeedback,
             .launchAtLogin, .advancedDeviceWrites, .globalHotkey, .safetyAlerts, .sensorAlerts,
             .alertsOnlyWhenAway, .doorbellAutoView, .doorbellChime, .doorbellAutoCloseSeconds,
             .weeklyReport, .notificationPermission, .hiddenDevices, .setupGuide,
             .automationRules, .allowURLControl, .raycast, .energyHistory:
            return .general
        case .demoMode, .haServerAddress, .haToken, .haDiscovery, .miAccount, .lgTV:
            return .connection
        case .askWhenUnsure, .confidenceThreshold, .assistantProvider, .assistantAPIKey,
             .assistantTest, .habitMemory:
            return .assistant
        case .appearanceMode, .panelTheme, .panelHeight, .climatePanelModule:
            return .appearance
        case .copyDiagnostics, .scanUnsupportedDevices, .privacyNotes, .blockControlWhileLocked,
             .signOut:
            return .privacy
        case .aboutVersion, .softwareUpdate, .quitApp:
            return .about
        }
    }
}

// MARK: - Reachability

/// Why a row in the index is not on screen right now.
///
/// Each case names a condition the window itself branches on, and doubles as the sentence the empty
/// state shows instead of pretending the setting does not exist.
enum SettingsSearchBlockReason: String, CaseIterable, Hashable, Sendable {
    /// The connection rows live behind `store.homeBackend != .demo`.
    case demoMode
    /// The hidden-devices card is only drawn when at least one device is hidden.
    case nothingHidden
    /// The panel-theme picker is inside `#available(macOS 26.0, *)`.
    case needsMacOS26
    /// The panel-height control only exists for the classic panel.
    case liquidGlassPanel

    var explanation: String {
        switch self {
        case .demoMode:
            return L10n.tr("关闭演示模式后可用", "Available once Demo Mode is off")
        case .nothingHidden:
            return L10n.tr("当前没有隐藏的设备", "No devices are hidden right now")
        case .needsMacOS26:
            return L10n.tr("需要 macOS 26 或更新版本", "Needs macOS 26 or later")
        case .liquidGlassPanel:
            return L10n.tr("切回「常规」面板主题后可用", "Available with the Classic panel theme")
        }
    }
}

/// The runtime facts that decide which rows the ⌘, window renders.
///
/// A hit that points at an absent row is the quietest failure this feature has: the jump clears the
/// query, switches to the pane and then lands on a page where the promised row does not exist, so it
/// reads as "this setting is gone". Search is therefore filtered by this value. It is a plain value
/// type so every branch — demo mode, nothing hidden, macOS 26, the classic-only height control — can
/// be pinned without rendering a window.
struct SettingsSearchAvailability: Equatable, Sendable {
    var backend: HomeBackend
    var hiddenDeviceCount: Int
    /// The stored `panel_theme` value, not an already-resolved theme: `AppearanceSettingsTab` reads
    /// the stored value and resolves it, so the height control follows the *resolved* theme. Taking
    /// the raw string here keeps that resolution in one place instead of trusting each caller.
    var storedPanelTheme: String?
    var liquidGlassAvailable: Bool

    init(
        backend: HomeBackend,
        hiddenDeviceCount: Int,
        storedPanelTheme: String?,
        liquidGlassAvailable: Bool
    ) {
        self.backend = backend
        self.hiddenDeviceCount = hiddenDeviceCount
        self.storedPanelTheme = storedPanelTheme
        self.liquidGlassAvailable = liquidGlassAvailable
    }

    /// The theme the appearance pane actually renders, the same value the height control branches on.
    var panelTheme: PanelTheme {
        PanelTheme.resolved(from: storedPanelTheme, liquidGlassAvailable: liquidGlassAvailable)
    }

    /// Every row assumed to be on screen. Only for tests that pin matching and ranking; the window
    /// always builds the live value from the store, which `conditionalRowsAreDeclared` scans for.
    static var unrestricted: SettingsSearchAvailability {
        SettingsSearchAvailability(
            backend: .homeAssistant,
            hiddenDeviceCount: 1,
            storedPanelTheme: PanelTheme.classic.rawValue,
            // Fixed rather than read from the host so the index tests assert on the index, not on
            // which macOS the test runner happens to be.
            liquidGlassAvailable: true
        )
    }

    func blockReason(for anchor: SettingsAnchor) -> SettingsSearchBlockReason? {
        switch anchor {
        // Rendered inside `if store.homeBackend != .demo` in `ConnectionSettingsTab`, including
        // `haToken` (attached inside `homeAssistantForm`, which only that branch calls) and `lgTV`
        // (`LGWebOSSettingsSection`, whose call site is inside the same branch).
        case .haServerAddress, .haToken, .haDiscovery, .miAccount, .lgTV:
            return backend == .demo ? .demoMode : nil
        case .hiddenDevices:
            return hiddenDeviceCount > 0 ? nil : .nothingHidden
        case .panelTheme:
            return liquidGlassAvailable ? nil : .needsMacOS26
        case .panelHeight:
            return panelTheme == .classic ? nil : .liquidGlassPanel
        default:
            return nil
        }
    }

    func isReachable(_ anchor: SettingsAnchor) -> Bool {
        blockReason(for: anchor) == nil
    }
}

// MARK: - Search Index Entries

/// One searchable row: what it is called, which card it sits in, and the words people use for it.
///
/// Synonyms are collected for both interface languages at once, so a Chinese query still works in an
/// English window and the index never has to be rebuilt when the language changes.
struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    let anchor: SettingsAnchor
    let section: String
    let title: String
    let synonyms: [String]

    var id: SettingsAnchor { anchor }
}

struct SettingsSearchHit: Identifiable, Hashable, Sendable {
    let entry: SettingsSearchEntry
    let score: Int

    var id: SettingsAnchor { entry.anchor }
    var anchor: SettingsAnchor { entry.anchor }
    var title: String { entry.title }
    var section: String { entry.section }
}

/// A row that matched the query but is not on screen, with the condition that hides it.
struct SettingsSearchBlocked: Equatable, Sendable {
    let anchor: SettingsAnchor
    let reason: SettingsSearchBlockReason
}

/// What one query produced: the rows that are on screen now, and the best row that matched but is not.
///
/// Unreachable hits are kept rather than dropped so the empty state can say *why* — the difference
/// between "no such setting" and "this setting needs Demo Mode off" is the whole point of the split.
struct SettingsSearchOutcome: Equatable, Sendable {
    var hits: [SettingsSearchHit] = []
    var blocked: SettingsSearchBlocked?

    var isEmpty: Bool { hits.isEmpty && blocked == nil }
}

// MARK: - Search Engine

/// Pure ranking over the settings index: no view state, no observable store, so the tests can pin
/// what a query matches and what it must not match.
enum SettingsSearch {
    static let resultLimit = 12

    /// Weights keep a title hit above a synonym hit above a section hit for the same quality of match.
    private enum Weight {
        static let title = 3
        static let synonym = 2
        static let section = 1
    }

    private enum Quality {
        static let exact = 100
        static let prefix = 70
        static let wordStart = 60
        static let contains = 45
    }

    static func entries() -> [SettingsSearchEntry] {
        [
            entry(.language, section: generalSection, zhTitle: "界面语言", enTitle: "Language",
                  synonyms: ["语言", "中文", "英文", "language", "locale", "chinese", "english"]),
            entry(.temperatureUnit, section: generalSection, zhTitle: "温度单位", enTitle: "Temperature Unit",
                  synonyms: ["温度", "摄氏度", "华氏度", "temperature", "celsius", "fahrenheit"]),
            entry(.dashboardTitle, section: generalSection, zhTitle: "面板标题", enTitle: "Dashboard Title",
                  synonyms: ["标题", "名字", "命名", "title", "name", "naming"]),
            entry(.menuBarReadout, section: generalSection, zhTitle: "菜单栏旁显示", enTitle: "Menu Bar Readout",
                  synonyms: ["菜单栏", "温度显示", "状态栏", "menu bar", "readout", "status item"]),
            entry(.compactGrid, section: generalSection, zhTitle: "双列紧凑磁贴视图", enTitle: "2-Column Compact Grid",
                  synonyms: ["紧凑", "双列", "网格", "磁贴", "密度", "compact", "grid", "tile", "density"]),
            entry(.hideOfflineDevices, section: generalSection,
                  zhTitle: "隐藏离线/未通电的设备", enTitle: "Hide Offline / Unpowered Devices",
                  synonyms: ["离线", "隐藏", "未通电", "offline", "hide", "unpowered"]),
            entry(.hideGroupedLights, section: generalSection,
                  zhTitle: "灯组内的单灯不重复显示", enTitle: "Hide Individual Lights Inside Groups",
                  synonyms: ["灯组", "重复", "折叠", "group", "light group", "duplicate", "fold"]),
            entry(.quickScenesBar, section: generalSection,
                  zhTitle: "输入框里显示快捷场景", enTitle: "Show Scenes Under the Input",
                  synonyms: ["快捷场景", "场景栏", "输入框", "quick action", "scene bar", "shortcut"]),
            entry(.grokBall, section: generalSection, zhTitle: "启用侧边情绪智能球",
                  enTitle: "Enable Sidecar Grok Ball",
                  synonyms: ["情绪球", "智能球", "侧边球", "grok", "ball", "sidecar", "emotion"]),
            entry(.soundFeedback, section: generalSection, zhTitle: "操作声音反馈", enTitle: "Play Feedback Sounds",
                  synonyms: ["声音", "提示音", "音效", "sound", "audio", "chime", "beep"]),
            entry(.launchAtLogin, section: generalSection, zhTitle: "登录 Mac 时自动启动",
                  enTitle: "Launch at Login",
                  synonyms: ["开机启动", "自动启动", "登录项", "启动项", "launch at login", "login item",
                             "startup", "autostart", "boot"]),
            entry(.advancedDeviceWrites, section: generalSection,
                  zhTitle: "允许「更多设置」写入次要控件", enTitle: "Allow Secondary Controls Under More Settings",
                  synonyms: ["更多设置", "次要控件", "高级写入", "more settings", "advanced", "secondary",
                             "writes"]),
            entry(.globalHotkey, section: generalSection, zhTitle: "全局快捷键", enTitle: "Global Shortcut",
                  synonyms: ["快捷键", "热键", "组合键", "hotkey", "shortcut", "keyboard", "key chord"]),
            entry(.safetyAlerts, section: generalSection, zhTitle: "主动安全与低电量提醒",
                  enTitle: "Safety & Low Battery Alerts",
                  synonyms: ["安全提醒", "低电量", "告警", "safety", "battery", "low battery", "alert"]),
            entry(.sensorAlerts, section: generalSection, zhTitle: "传感器提醒", enTitle: "Sensor Alerts",
                  synonyms: ["门窗", "移动", "烟感", "漏水", "水浸", "sensor", "door", "window", "motion",
                             "smoke", "leak"]),
            entry(.alertsOnlyWhenAway, section: generalSection,
                  zhTitle: "门窗和移动只在离开时提醒", enTitle: "Door and Motion Only When Away",
                  synonyms: ["离开", "锁屏", "睡眠", "away", "locked", "asleep", "switched away"]),
            entry(.doorbellAutoView, section: generalSection,
                  zhTitle: "门铃响时自动弹出摄像头画面", enTitle: "Show the Doorbell Camera When It Rings",
                  synonyms: ["门铃", "摄像头", "弹出", "doorbell", "camera", "popup", "ring"]),
            entry(.doorbellChime, section: generalSection, zhTitle: "门铃响时播放提示音",
                  enTitle: "Play a Chime When the Doorbell Rings",
                  synonyms: ["门铃提示音", "门铃声音", "doorbell chime", "bell sound"]),
            entry(.doorbellAutoCloseSeconds, section: generalSection, zhTitle: "门铃画面自动收起",
                  enTitle: "Close the Doorbell View After",
                  synonyms: ["自动收起", "门铃时长", "auto close", "doorbell timeout", "seconds"]),
            entry(.weeklyReport, section: generalSection, zhTitle: "每周家庭健康周报",
                  enTitle: "Weekly Home Health Report",
                  synonyms: ["周报", "健康报告", "weekly", "report", "digest", "health"]),
            entry(.notificationPermission, section: generalSection, zhTitle: "通知权限",
                  enTitle: "Notification Permission",
                  synonyms: ["通知", "权限", "提醒", "notification", "permission", "allow", "authorize"]),
            entry(.hiddenDevices, section: generalSection, zhTitle: "已隐藏的设备", enTitle: "Hidden Devices",
                  synonyms: ["隐藏设备", "恢复显示", "取消隐藏", "hidden", "unhide", "restore", "show"]),
            entry(.setupGuide, section: generalSection, zhTitle: "首次设置与新手引导",
                  enTitle: "Setup Guide",
                  synonyms: ["新手引导", "引导", "教程", "onboarding", "guide", "tutorial", "setup"]),
            entry(.automationRules, section: automationSection,
                  zhTitle: "Mac 状态自动化规则", enTitle: "Mac State Automation Rules",
                  synonyms: ["自动化", "规则", "合盖", "休眠", "唤醒", "外接显示器", "专注模式", "日历",
                             "电量阈值", "wifi", "automation", "rule", "trigger", "lid", "sleep",
                             "wake", "focus", "calendar"]),
            entry(.allowURLControl, section: automationSection,
                  zhTitle: "允许 URL 直控（跳过确认）", enTitle: "Allow URL Control Without Confirmation",
                  synonyms: ["url", "直控", "链接", "menumijia", "deeplink", "confirmation"]),
            entry(.raycast, section: automationSection, zhTitle: "Raycast 集成",
                  enTitle: "Raycast Integration",
                  synonyms: ["raycast", "集成", "integration", "extension"]),
            entry(.energyHistory, section: energySection,
                  zhTitle: "插座用电统计", enTitle: "Plug Energy",
                  synonyms: ["用电", "电量", "能耗", "电费", "energy", "power", "consumption",
                             "electricity", "kwh"]),

            entry(.demoMode, section: connectionSection,
                  zhTitle: "演示模式", enTitle: "Demo Mode",
                  synonyms: ["演示", "虚拟设备", "离线模式", "demo", "virtual", "sample"]),
            entry(.haServerAddress, section: connectionSection,
                  zhTitle: "Home Assistant 服务器地址", enTitle: "Home Assistant Server URL",
                  synonyms: ["服务器", "地址", "home assistant", "server", "url", "nabu casa", "ha"]),
            entry(.haToken, section: connectionSection,
                  zhTitle: "长期访问令牌", enTitle: "Long-Lived Access Token",
                  synonyms: ["令牌", "密钥", "token", "key", "access token", "credential"]),
            entry(.haDiscovery, section: connectionSection, zhTitle: "扫描局域网 HA",
                  enTitle: "Scan LAN for HA",
                  synonyms: ["扫描", "局域网", "发现", "scan", "discover", "lan", "mdns", "bonjour"]),
            entry(.miAccount, section: connectionSection, zhTitle: "米家云端直连",
                  enTitle: "Xiaomi Cloud Direct",
                  synonyms: ["米家", "小米", "账号", "登录", "mi", "xiaomi", "account", "sign in",
                             "cloud"]),
            entry(.lgTV, section: connectionSection, zhTitle: "LG webOS 电视局域网直连",
                  enTitle: "LG webOS TV Direct LAN",
                  synonyms: ["电视", "lg", "webos", "ssap", "wake on lan", "wol", "tv"]),

            entry(.askWhenUnsure, section: assistantSection, zhTitle: "AI 不确定时先问我",
                  enTitle: "Ask Me When Unsure",
                  synonyms: ["不确定", "先问我", "确认", "把握", "unsure", "confirm", "confidence"]),
            entry(.confidenceThreshold, section: assistantSection, zhTitle: "把握度阈值",
                  enTitle: "Confidence Threshold",
                  synonyms: ["阈值", "把握度", "高级", "threshold", "confidence", "advanced"]),
            entry(.assistantProvider, section: assistantSection, zhTitle: "AI 服务商与模型",
                  enTitle: "AI Provider & Model",
                  synonyms: ["模型", "服务商", "提供商", "provider", "model", "openrouter", "endpoint",
                             "assistant", "助手"]),
            entry(.assistantAPIKey, section: assistantSection, zhTitle: "AI 密钥", enTitle: "AI API Key",
                  synonyms: ["密钥", "令牌", "api key", "apikey", "token", "key", "credential", "secret"]),
            entry(.assistantTest, section: assistantSection, zhTitle: "测试 AI 连接",
                  enTitle: "Test the AI Connection",
                  synonyms: ["测试", "连接", "test", "connection", "verify", "check"]),
            entry(.habitMemory, section: assistantSection, zhTitle: "习惯记忆", enTitle: "Habit Memory",
                  synonyms: ["习惯", "记忆", "偏好", "习惯学习", "habit", "memory", "learn"]),

            entry(.appearanceMode, section: appearanceSection, zhTitle: "外观模式", enTitle: "Appearance",
                  synonyms: ["外观", "浅色", "深色", "跟随系统", "appearance", "light", "dark", "system",
                             "day", "night"]),
            entry(.panelTheme, section: appearanceSection, zhTitle: "面板主题", enTitle: "Panel Theme",
                  synonyms: ["主题", "玻璃", "经典", "theme", "liquid glass", "classic", "panel style"]),
            entry(.panelHeight, section: appearanceSection, zhTitle: "面板高度", enTitle: "Panel Height",
                  synonyms: ["高度", "面板大小", "height", "size", "compact", "tall", "max"]),
            entry(.climatePanelModule, section: appearanceSection,
                  zhTitle: "空调使用整行面板模块", enTitle: "Full-Width Climate Panel",
                  synonyms: ["空调", "整行", "climate", "module", "full width", "panel module"]),

            entry(.copyDiagnostics, section: privacySection, zhTitle: "复制诊断信息",
                  enTitle: "Copy Diagnostics",
                  synonyms: ["诊断", "复制", "反馈", "diagnostics", "copy", "report", "debug"]),
            entry(.scanUnsupportedDevices, section: privacySection, zhTitle: "扫描不支持的设备",
                  enTitle: "Scan Skipped Devices",
                  synonyms: ["不支持", "跳过", "未识别", "unsupported", "skipped", "scan", "missing"]),
            entry(.privacyNotes, section: privacySection, zhTitle: "隐私说明", enTitle: "Privacy Notes",
                  synonyms: ["隐私", "本机", "privacy", "local", "data", "offline"]),
            entry(.blockControlWhileLocked, section: securitySection,
                  zhTitle: "锁屏时禁止控制设备", enTitle: "Block Device Control While Locked",
                  synonyms: ["锁屏", "禁止控制", "安全", "lock", "locked", "block", "security"]),
            entry(.signOut, section: securitySection, zhTitle: "退出并吊销令牌",
                  enTitle: "Sign Out & Revoke Tokens",
                  synonyms: ["退出登录", "吊销", "注销", "sign out", "logout", "revoke", "token"]),

            entry(.aboutVersion, section: aboutSection, zhTitle: "版本与更新",
                  enTitle: "Version & Updates",
                  synonyms: ["版本", "更新", "升级", "新版本", "version", "update", "upgrade",
                             "release", "changelog"]),
            entry(.softwareUpdate, section: aboutSection, zhTitle: "自动检查更新与安装包升级",
                  enTitle: "Check for Updates Automatically",
                  synonyms: ["检查更新", "自动更新", "软件更新", "下载安装", "check for updates",
                             "auto update", "software update", "download"]),
            entry(.quitApp, section: aboutSection, zhTitle: "退出应用", enTitle: "Quit the App",
                  synonyms: ["退出", "关闭应用", "quit", "exit", "terminate"])
        ]
    }

    /// Ranks the index against a raw field value. An empty or whitespace-only query matches nothing:
    /// the window then shows categories again instead of a list of everything.
    static func search(
        _ query: String,
        limit: Int = resultLimit,
        entries: [SettingsSearchEntry]? = nil
    ) -> [SettingsSearchHit] {
        ranked(query, limit: limit, entries: entries)
    }

    /// The search the window runs: the same ranking, minus the rows this window is not drawing.
    ///
    /// When every match is hidden by a condition, the best one comes back as `blocked` so the empty
    /// state can name the condition instead of claiming the setting does not exist.
    static func search(
        _ query: String,
        availability: SettingsSearchAvailability,
        limit: Int = resultLimit,
        entries: [SettingsSearchEntry]? = nil
    ) -> SettingsSearchOutcome {
        let ranked = ranked(query, limit: Int.max, entries: entries)
        var outcome = SettingsSearchOutcome()
        for hit in ranked {
            guard let reason = availability.blockReason(for: hit.anchor) else {
                if outcome.hits.count < max(0, limit) {
                    outcome.hits.append(hit)
                }
                continue
            }
            // `ranked` is sorted best-first, so the first blocked row is the one worth explaining.
            if outcome.blocked == nil {
                outcome.blocked = SettingsSearchBlocked(anchor: hit.anchor, reason: reason)
            }
        }
        // A query that reaches a real row must not be reported as blocked just because a hidden row
        // scored higher: the explanation is only for "everything you asked for is behind a condition".
        if !outcome.hits.isEmpty { outcome.blocked = nil }
        return outcome
    }

    /// The full ranking, before any reachability filter. Sorted best-first.
    private static func ranked(
        _ query: String,
        limit: Int,
        entries: [SettingsSearchEntry]?
    ) -> [SettingsSearchHit] {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty else { return [] }
        let index = entries ?? self.entries()
        var hits: [SettingsSearchHit] = []
        hits.reserveCapacity(index.count)
        for entry in index {
            guard let score = score(of: entry, tokens: tokens) else { continue }
            hits.append(SettingsSearchHit(entry: entry, score: score))
        }
        return hits
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.title != rhs.entry.title { return lhs.entry.title < rhs.entry.title }
                return lhs.entry.anchor.rawValue < rhs.entry.anchor.rawValue
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Every token has to land somewhere on the same row, in any field, so "launch login" matches
    /// "Launch at Login" and "开机启动" matches through the Chinese synonym of the same row.
    private static func score(of entry: SettingsSearchEntry, tokens: [String]) -> Int? {
        var weakest: Int?
        for token in tokens {
            let best = bestScore(of: token, in: entry)
            guard best > 0 else { return nil }
            weakest = Swift.min(weakest ?? best, best)
        }
        return weakest
    }

    private static func bestScore(of token: String, in entry: SettingsSearchEntry) -> Int {
        var best = 0
        best = Swift.max(best, fieldScore(token, field: entry.title, weight: Weight.title))
        for synonym in entry.synonyms {
            best = Swift.max(best, fieldScore(token, field: synonym, weight: Weight.synonym))
        }
        best = Swift.max(best, fieldScore(token, field: entry.section, weight: Weight.section))
        return best
    }

    private static func fieldScore(_ token: String, field: String, weight: Int) -> Int {
        let haystack = normalize(field)
        guard !haystack.isEmpty else { return 0 }
        let quality: Int
        if haystack == token {
            quality = Quality.exact
        } else if haystack.hasPrefix(token) {
            quality = Quality.prefix
        } else if hasWordStart(token, in: haystack) {
            quality = Quality.wordStart
        } else if haystack.contains(token) {
            quality = Quality.contains
        } else {
            return 0
        }
        return quality * 10 + weight
    }

    /// Splits on whitespace and punctuation so "launch-at-login" and "launch, login" rank like
    /// "launch login"; Chinese queries stay one token and match by substring.
    static func tokens(in query: String) -> [String] {
        let normalized = normalize(query)
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return normalized
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A token that starts a word ranks above one buried mid-word, so "lock" prefers
    /// "Block Device Control" over a spelling that only contains those letters mid-word.
    private static func hasWordStart(_ token: String, in haystack: String) -> Bool {
        guard let range = haystack.range(of: token) else { return false }
        guard range.lowerBound != haystack.startIndex else { return true }
        let previous = haystack[haystack.index(before: range.lowerBound)]
        return previous == " " || previous == "/" || previous == "·" || previous == "（" || previous == "("
    }

    private static func entry(
        _ anchor: SettingsAnchor,
        section: String,
        zhTitle: String,
        enTitle: String,
        synonyms: [String]
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(anchor: anchor, section: section, title: L10n.tr(zhTitle, enTitle),
                            synonyms: synonyms)
    }

    // Section names are read through `L10n` so the second line of a hit matches the card it jumps to.
    private static var generalSection: String { L10n.tr("通用", "General") }
    private static var automationSection: String { L10n.tr("自动化与外部控制", "Automation & External Control") }
    private static var connectionSection: String { L10n.tr("连接", "Connections") }
    private static var assistantSection: String { L10n.tr("AI 助手", "AI Assistant") }
    private static var appearanceSection: String { L10n.tr("外观", "Appearance") }
    private static var energySection: String { L10n.tr("插座用电统计", "Plug Energy") }
    private static var privacySection: String { L10n.tr("隐私与诊断", "Privacy & Diagnostics") }
    private static var securitySection: String { L10n.tr("安全", "Security") }
    private static var aboutSection: String { L10n.tr("关于与更新", "About & Updates") }
}

// MARK: - Focus State

/// Where a search hit wants the window to go, and which row, if any, is drawing its landing highlight.
///
/// Single owner (§13): `endHighlight()` is the only clearing site. It runs when the pulse timer
/// fires, when the user types a different query, when the category changes, and when the window goes
/// away — a highlight can never outlive the search that produced it.
@MainActor
@Observable
final class SettingsSearchFocus {
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            endHighlight()
        }
    }

    private(set) var highlight: SettingsAnchor?
    /// Bumped on every jump so re-picking the same hit scrolls again instead of doing nothing.
    private(set) var generation: Int = 0

    @ObservationIgnored private var clearTask: Task<Void, Never>?

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }

    func jump(to anchor: SettingsAnchor) {
        endHighlight()
        highlight = anchor
        generation &+= 1
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            guard let self, self.highlight == anchor else { return }
            self.highlight = nil
        }
    }

    func endHighlight() {
        clearTask?.cancel()
        clearTask = nil
        highlight = nil
    }

    func clearQuery() {
        query = ""
        endHighlight()
    }
}

// MARK: - Keyboard Selection

/// Moving through the suggestion list with the arrow keys. Pure so the wrap and clamp rules can be
/// pinned without rendering a window.
enum SettingsSearchSelection {
    /// Down/up move one row and stop at the ends; an empty list has no selection.
    static func moved(_ index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta > 0 ? 0 : count - 1 }
        return min(max(index + delta, 0), count - 1)
    }

    /// Return acts on the highlighted row, or the best match when nothing has been moved to yet.
    static func commitIndex(_ index: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index, index >= 0, index < count else { return 0 }
        return index
    }

    /// A shrinking result list must not leave the cursor pointing past its end.
    static func clamped(_ index: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return nil }
        return min(max(index, 0), count - 1)
    }
}

// MARK: - Environment

private struct SettingsSearchFocusKey: EnvironmentKey {
    static let defaultValue: SettingsSearchFocus? = nil
}

extension EnvironmentValues {
    var settingsSearchFocus: SettingsSearchFocus? {
        get { self[SettingsSearchFocusKey.self] }
        set { self[SettingsSearchFocusKey.self] = newValue }
    }
}
