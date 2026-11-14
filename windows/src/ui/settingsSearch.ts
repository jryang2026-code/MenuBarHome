import { currentLanguage, type AppLanguage } from "../core/i18n.js";
import type { SettingsTab } from "./settingsViews.js";

export type SettingsAnchor =
  | "appearanceMode"
  | "panelOpacity"
  | "language"
  | "temperatureUnit"
  | "panelHeight"
  | "panelAnchor"
  | "climatePanelModule"
  | "hideOfflineDevices"
  | "hideGroupedLights"
  | "quickScenesBar"
  | "launchAtLogin"
  | "globalHotkey"
  | "voiceControl"
  | "setupGuide"
  | "dataSource"
  | "demoMode"
  | "haServerAddress"
  | "haToken"
  | "miCloudRegion"
  | "miAccount"
  | "assistantProvider"
  | "assistantBaseURL"
  | "assistantModel"
  | "assistantAPIKey"
  | "assistantEnvImport"
  | "assistantTest"
  | "askWhenUnsure"
  | "cloudConsent"
  | "habitMemory"
  | "habitShare"
  | "blockControlWhileLocked"
  | "raycast"
  | "allowURLControl"
  | "advancedDeviceWrites"
  | "allOffDevices"
  | "signOut"
  | "softwareUpdate"
  | "aboutVersion"
  | "quitApp";

export type SettingsSearchBlockReason = "noCloudConsent";

export interface SettingsSearchAvailability {
  readonly hasCloudConsentEndpoints: boolean;
  readonly hasAvailableUpdate: boolean;
}

export const UNRESTRICTED_SETTINGS_AVAILABILITY: SettingsSearchAvailability = {
  hasCloudConsentEndpoints: true,
  hasAvailableUpdate: false,
};

export interface SettingsSearchEntry {
  readonly anchor: SettingsAnchor;
  readonly tab: SettingsTab;
  readonly section: string;
  readonly title: string;
  readonly synonyms: readonly string[];
}

export interface SettingsSearchHit {
  readonly entry: SettingsSearchEntry;
  readonly anchor: SettingsAnchor;
  readonly tab: SettingsTab;
  readonly section: string;
  readonly title: string;
  readonly score: number;
}

export interface SettingsSearchBlocked {
  readonly anchor: SettingsAnchor;
  readonly reason: SettingsSearchBlockReason;
  readonly explanation: string;
}

export interface SettingsSearchOutcome {
  readonly hits: readonly SettingsSearchHit[];
  readonly blocked: SettingsSearchBlocked | null;
  readonly isEmpty: boolean;
}

export const SETTINGS_SEARCH_RESULT_LIMIT = 12;

const WEIGHT_TITLE = 3;
const WEIGHT_SYNONYM = 2;
const WEIGHT_SECTION = 1;

const QUALITY_EXACT = 100;
const QUALITY_PREFIX = 70;
const QUALITY_WORD_START = 60;
const QUALITY_CONTAINS = 45;

function tr3(lang: AppLanguage, zhHans: string, zhHant: string, en: string): string {
  if (lang === "en") return en;
  if (lang === "zh-Hant") return zhHant;
  return zhHans;
}

export function blockReasonExplanation(
  reason: SettingsSearchBlockReason,
  lang: AppLanguage = currentLanguage(),
): string {
  switch (reason) {
    case "noCloudConsent":
      return tr3(
        lang,
        "当前还没有已授权的云端 AI 服务",
        "目前還沒有已授權的雲端 AI 服務",
        "No cloud AI endpoints have been authorized yet",
      );
  }
}

export function resolveSettingsAnchorTab(anchor: SettingsAnchor, hasAvailableUpdate: boolean): SettingsTab {
  if (anchor === "softwareUpdate" || anchor === "aboutVersion") {
    return hasAvailableUpdate ? "general" : "system";
  }
  switch (anchor) {
    case "appearanceMode":
    case "panelOpacity":
    case "language":
    case "temperatureUnit":
    case "panelHeight":
    case "panelAnchor":
    case "climatePanelModule":
    case "hideOfflineDevices":
    case "hideGroupedLights":
    case "quickScenesBar":
    case "launchAtLogin":
    case "globalHotkey":
    case "voiceControl":
    case "setupGuide":
      return "general";
    case "dataSource":
    case "demoMode":
    case "haServerAddress":
    case "haToken":
    case "miCloudRegion":
    case "miAccount":
      return "connection";
    case "assistantProvider":
    case "assistantBaseURL":
    case "assistantModel":
    case "assistantAPIKey":
    case "assistantEnvImport":
    case "assistantTest":
    case "askWhenUnsure":
    case "cloudConsent":
    case "habitMemory":
    case "habitShare":
      return "assistant";
    case "blockControlWhileLocked":
    case "raycast":
    case "allowURLControl":
    case "advancedDeviceWrites":
    case "allOffDevices":
    case "signOut":
    case "quitApp":
      return "system";
  }
}

interface RawAnchorSpec {
  readonly anchor: SettingsAnchor;
  readonly section: readonly [string, string, string];
  readonly title: readonly [string, string, string];
  readonly synonyms: readonly string[];
}

const SEC_GENERAL: readonly [string, string, string] = ["外观与面板", "外觀與面板", "Appearance & Panel"];
const SEC_CONNECTION: readonly [string, string, string] = ["数据源", "資料來源", "Data Source"];
const SEC_ASSISTANT: readonly [string, string, string] = ["AI 与习惯", "AI 與習慣", "AI & Habits"];
const SEC_SYSTEM: readonly [string, string, string] = ["全关与更新", "全關與更新", "All Off & Updates"];
const SEC_SECURITY: readonly [string, string, string] = ["安全与权限", "安全與權限", "Security & Permissions"];

const RAW_SPECS: readonly RawAnchorSpec[] = [
  {
    anchor: "appearanceMode",
    section: SEC_GENERAL,
    title: ["外观模式", "外觀模式", "Appearance Mode"],
    synonyms: ["外观", "外觀", "浅色", "深色", "暗黑", "夜间", "跟随系统", "主题", "appearance", "theme", "light", "dark", "system", "waiguan", "shense"],
  },
  {
    anchor: "panelOpacity",
    section: SEC_GENERAL,
    title: ["面板不透明度", "面板不透明度", "Panel Opacity"],
    synonyms: ["不透明度", "透明度", "毛玻璃", "背景透出", "opacity", "transparency", "glass", "alpha", "toumingdu"],
  },
  {
    anchor: "language",
    section: SEC_GENERAL,
    title: ["界面语言", "介面語言", "Interface Language"],
    synonyms: ["语言", "語言", "中文", "简体", "繁体", "繁體", "英文", "多语言", "language", "locale", "chinese", "english", "i18n", "yuyan"],
  },
  {
    anchor: "temperatureUnit",
    section: SEC_GENERAL,
    title: ["温度单位", "溫度單位", "Temperature Unit"],
    synonyms: ["温度", "溫度", "摄氏度", "华氏度", "攝氏", "華氏", "单位", "temperature", "celsius", "fahrenheit", "unit", "wendu"],
  },
  {
    anchor: "panelHeight",
    section: SEC_GENERAL,
    title: ["面板高度", "面板高度", "Panel Height"],
    synonyms: ["高度", "尺寸", "大小", "紧凑", "加高", "面板大小", "height", "size", "compact", "tall", "standard", "gaodu"],
  },
  {
    anchor: "panelAnchor",
    section: SEC_GENERAL,
    title: ["面板位置", "面板位置", "Panel Position"],
    synonyms: ["位置", "角落", "吸附", "拖动", "左上", "右上", "左下", "右下", "position", "anchor", "corner", "location", "drag", "weizhi"],
  },
  {
    anchor: "climatePanelModule",
    section: SEC_GENERAL,
    title: ["空调使用整行控制条", "空調使用整行控制列", "Full-Width Climate Control Bar"],
    synonyms: ["空调", "空調", "整行", "温控", "冷气", "climate", "ac", "air conditioner", "full width", "panel module", "kongtiao"],
  },
  {
    anchor: "hideOfflineDevices",
    section: SEC_GENERAL,
    title: ["隐藏离线/未通电的设备", "隱藏離線/未通電的裝置", "Hide Offline / Unpowered Devices"],
    synonyms: ["离线", "離線", "隐藏", "隱藏", "未通电", "断电", "掉线", "offline", "hide", "unpowered", "disconnected", "lixian"],
  },
  {
    anchor: "hideGroupedLights",
    section: SEC_GENERAL,
    title: ["灯组内的单灯不重复显示", "燈組內的單燈不重複顯示", "Fold Individual Lights Inside Light Groups"],
    synonyms: ["灯组", "燈組", "单灯", "重复", "折叠", "合并", "light group", "grouped", "duplicate", "fold", "dengzu"],
  },
  {
    anchor: "quickScenesBar",
    section: SEC_GENERAL,
    title: ["显示顶部快捷场景栏", "顯示頂部捷徑場景列", "Show Top Quick Actions Bar"],
    synonyms: ["快捷场景", "场景栏", "顶部栏", "快捷栏", "quick actions", "quick scenes", "scene bar", "shortcut bar", "changjing"],
  },
  {
    anchor: "launchAtLogin",
    section: SEC_GENERAL,
    title: ["开机自动启动", "開機自動啟動", "Launch at Login"],
    synonyms: ["开机", "開機", "自启", "自啟", "自动启动", "开机启动", "登录启动", "启动项", "launch at login", "startup", "autostart", "boot", "login item", "kaiji", "ziqi"],
  },
  {
    anchor: "globalHotkey",
    section: SEC_GENERAL,
    title: ["全局呼出快捷键", "全域呼出快速鍵", "Global Shortcut"],
    synonyms: ["快捷键", "快速鍵", "热键", "组合键", "呼出", "alt+m", "hotkey", "shortcut", "keyboard", "keybind", "kuaiejiejian", "kuaijiejian"],
  },
  {
    anchor: "voiceControl",
    section: SEC_GENERAL,
    title: ["语音指令与长按说话", "語音指令與長按說話", "Voice Dictation & Hold-to-Speak"],
    synonyms: ["语音", "語音", "麦克风", "麥克風", "说话", "听写", "长按说话", "录音", "voice", "mic", "microphone", "speech", "dictation", "speak", "yuyin", "maikefeng"],
  },
  {
    anchor: "setupGuide",
    section: SEC_GENERAL,
    title: ["重新查看新手引导", "重新查看新手引導", "Reopen Setup Guide"],
    synonyms: ["新手引导", "新手引導", "首次设置", "引导", "教程", "上手", "三步上手", "onboarding", "setup guide", "tutorial", "walkthrough", "welcome", "xinshou", "yindao"],
  },
  {
    anchor: "dataSource",
    section: SEC_CONNECTION,
    title: ["设备数据源", "裝置資料來源", "Device Data Source"],
    synonyms: ["数据源", "資料來源", "连接方式", "后端", "切换数据源", "data source", "backend", "connection mode", "provider", "shujuyuan"],
  },
  {
    anchor: "demoMode",
    section: SEC_CONNECTION,
    title: ["演示设备预览", "示範裝置預覽", "Demo Mode Preview"],
    synonyms: ["演示", "示範", "演示模式", "虚拟设备", "离线体验", "预览", "demo", "demo mode", "virtual", "preview", "sample", "yanshi"],
  },
  {
    anchor: "haServerAddress",
    section: SEC_CONNECTION,
    title: ["Home Assistant 服务器地址", "Home Assistant 伺服器位址", "Home Assistant Server URL"],
    synonyms: ["服务器", "地址", "局域网", "代理", "链接", "home assistant", "ha", "server", "url", "nabu casa", "8123", "websocket", "daili", "dizhi"],
  },
  {
    anchor: "haToken",
    section: SEC_CONNECTION,
    title: ["Home Assistant 访问令牌", "Home Assistant 存取權杖", "Home Assistant Access Token"],
    synonyms: ["令牌", "访问令牌", "长期令牌", "权杖", "密钥", "token", "access token", "ha token", "long-lived", "credential", "key", "lingpai"],
  },
  {
    anchor: "miCloudRegion",
    section: SEC_CONNECTION,
    title: ["米家云端服务器地区", "米家雲端伺服器地區", "Xiaomi Cloud Region"],
    synonyms: ["地区", "地區", "服务器地区", "国区", "欧区", "美区", "新加坡", "region", "country", "server region", "cn", "de", "sg", "us", "diqu"],
  },
  {
    anchor: "miAccount",
    section: SEC_CONNECTION,
    title: ["米家扫码登录与账号", "米家掃碼登入與帳號", "Xiaomi Home QR Login & Account"],
    synonyms: ["米家", "小米", "扫码", "掃碼", "二维码", "登录", "账号", "退出米家", "xiaomi", "mijia", "mi home", "qr", "qrcode", "login", "sign in", "account", "saoma"],
  },
  {
    anchor: "assistantProvider",
    section: SEC_ASSISTANT,
    title: ["AI 服务商预设", "AI 服務商預設", "AI Provider Preset"],
    synonyms: ["服务商", "預設", "预设", "大模型", "自定义", "openrouter", "jev", "deepseek", "qwen", "千问", "glm", "智谱", "kimi", "openai", "gemini", "groq", "ollama", "custom", "provider", "preset"],
  },
  {
    anchor: "assistantBaseURL",
    section: SEC_ASSISTANT,
    title: ["AI 服务地址（接口代理 URL）", "AI 服務位址（介面代理 URL）", "AI Endpoint Base URL"],
    synonyms: ["接口地址", "服务地址", "代理", "反代", "中转", "地址", "base url", "endpoint", "proxy", "url", "api url", "systemone", "chat completions", "daili", "jiekou"],
  },
  {
    anchor: "assistantModel",
    section: SEC_ASSISTANT,
    title: ["AI 决策模型", "AI 決策模型", "AI Decision Model"],
    synonyms: ["模型", "模型名", "决策模型", "model", "llm", "jev-latest", "deepseek-chat", "gpt-4o", "moxing"],
  },
  {
    anchor: "assistantAPIKey",
    section: SEC_ASSISTANT,
    title: ["AI API Key（密钥）", "AI API Key（金鑰）", "AI API Key"],
    synonyms: ["密钥", "金鑰", "秘钥", "口令", "api key", "apikey", "key", "token", "secret", "sk-", "miyao"],
  },
  {
    anchor: "assistantEnvImport",
    section: SEC_ASSISTANT,
    title: ["从环境变量导入 API Key", "從環境變數匯入 API Key", "Import API Key from Environment"],
    synonyms: ["环境变量", "環境變數", "导入密钥", "自动导入", "env", "environment variable", "import key", "openrouter_api_key", "deepseek_api_key", "openai_api_key", "huanjingbianliang"],
  },
  {
    anchor: "assistantTest",
    section: SEC_ASSISTANT,
    title: ["测试 AI 连接", "測試 AI 連線", "Test AI Connection"],
    synonyms: ["测试", "測試", "测试连接", "连通性", "延迟", "耗时", "探针", "test", "test connection", "ping", "verify", "latency", "probe", "ceshi"],
  },
  {
    anchor: "askWhenUnsure",
    section: SEC_ASSISTANT,
    title: ["AI 不确定时先让我确认", "AI 不確定時先讓我確認", "Ask Me When AI Is Unsure"],
    synonyms: ["不确定", "不確定", "先问我", "确认", "把握度", "防误触", "ask when unsure", "unsure", "confirm", "confidence", "ask me", "buqueding"],
  },
  {
    anchor: "cloudConsent",
    section: SEC_ASSISTANT,
    title: ["云端 AI 发送授权", "雲端 AI 傳送授權", "Cloud AI Sending Consent"],
    synonyms: ["云端授权", "撤销授权", "隐私授权", "cloud consent", "revoke consent", "privacy", "authorize"],
  },
  {
    anchor: "habitMemory",
    section: SEC_ASSISTANT,
    title: ["习惯记忆与逐条管理", "習慣記憶與逐條管理", "Habit Memory & Per-Item Management"],
    synonyms: ["习惯", "習慣", "记忆", "記憶", "口头禅", "猜你想控", "时段习惯", "先后习惯", "清空习惯", "删除习惯", "habit", "habits", "memory", "learned", "forget", "xiguan", "jiyi"],
  },
  {
    anchor: "habitShare",
    section: SEC_ASSISTANT,
    title: ["发送习惯摘要与预览", "傳送習慣摘要與預覽", "Habit Summary Sharing & Preview"],
    synonyms: ["习惯摘要", "发送习惯", "摘要预览", "habit share", "habit summary", "preview", "zhaiyao"],
  },
  {
    anchor: "blockControlWhileLocked",
    section: SEC_SECURITY,
    title: ["锁屏时禁止控制设备", "鎖定螢幕時禁止控制裝置", "Block Device Control While Locked"],
    synonyms: ["锁屏", "鎖屏", "锁定", "禁止控制", "防误控", "安全锁", "lock", "locked", "lock screen", "workstation lock", "block", "security", "suoping"],
  },
  {
    anchor: "raycast",
    section: SEC_SECURITY,
    title: ["Raycast 与本地 CLI / MCP 集成", "Raycast 與本機 CLI / MCP 整合", "Raycast & Local CLI / MCP Integration"],
    synonyms: ["raycast", "cli", "mcp", "快照", "本机令牌", "本地集成", "外部工具", "integration", "bridge", "snapshot"],
  },
  {
    anchor: "allowURLControl",
    section: SEC_SECURITY,
    title: ["允许 menumijia:// 外部链接免确认直控", "允許 menumijia:// 外部連結免確認直控", "Allow menumijia:// Direct URL Control"],
    synonyms: ["外部链接", "直控", "免确认", "协议链接", "代理链接", "url", "menumijia", "deeplink", "deep link", "direct control", "scheme", "lianjie"],
  },
  {
    anchor: "advancedDeviceWrites",
    section: SEC_SECURITY,
    title: ["允许写入高级/高风险设备属性", "允許寫入進階/高風險裝置屬性", "Allow Secondary / High-Risk Controls"],
    synonyms: ["高级属性", "高风险", "更多设置", "次要控件", "门锁", "取暖", "水阀", "advanced", "facets", "more settings", "secondary", "high risk", "heater", "valve", "gaoji"],
  },
  {
    anchor: "allOffDevices",
    section: SEC_SYSTEM,
    title: ["「全关」包含哪些设备", "「全關」包含哪些裝置", "Devices Included in All Off"],
    synonyms: ["全关", "全關", "一键全关", "全屋关", "插座", "扫地机", "白名单", "all off", "turn all off", "master off", "exclude", "quanguan"],
  },
  {
    anchor: "signOut",
    section: SEC_SECURITY,
    title: ["退出并清除所有账号与密钥", "登出並清除所有帳號與金鑰", "Sign Out & Revoke All Credentials"],
    synonyms: ["退出所有", "清除密钥", "吊销", "注销", "清除凭据", "重置账号", "sign out", "logout", "revoke", "revoke all", "clear credentials", "wipe tokens", "zhuxiao", "diaoxiao"],
  },
  {
    anchor: "softwareUpdate",
    section: SEC_SYSTEM,
    title: ["软件更新与自动检查", "軟體更新與自動檢查", "Software Update & Auto Check"],
    synonyms: ["更新", "升级", "检查更新", "自动更新", "新版本", "下载更新", "update", "upgrade", "software update", "auto update", "check update", "release", "gengxin", "shengji"],
  },
  {
    anchor: "aboutVersion",
    section: SEC_SYSTEM,
    title: ["当前版本号", "目前版本號", "Current App Version"],
    synonyms: ["版本", "版本号", "关于", "version", "about", "build", "banben"],
  },
  {
    anchor: "quitApp",
    section: SEC_SYSTEM,
    title: ["退出 MenuBarHome", "結束 MenuBarHome", "Quit MenuBarHome"],
    synonyms: ["退出", "关闭软件", "退出应用", "结束进程", "quit", "exit", "close app", "tuichu"],
  },
];

export function settingsSearchEntries(
  availability: SettingsSearchAvailability = UNRESTRICTED_SETTINGS_AVAILABILITY,
  lang: AppLanguage = currentLanguage(),
): SettingsSearchEntry[] {
  return RAW_SPECS.map((spec) => {
    const [zhHansSec, zhHantSec, enSec] = spec.section;
    const [zhHansTitle, zhHantTitle, enTitle] = spec.title;
    const mergedSynonyms = [
      zhHansTitle,
      zhHantTitle,
      enTitle,
      zhHansSec,
      zhHantSec,
      enSec,
      ...spec.synonyms,
    ];
    return {
      anchor: spec.anchor,
      tab: resolveSettingsAnchorTab(spec.anchor, availability.hasAvailableUpdate),
      section: tr3(lang, zhHansSec, zhHantSec, enSec),
      title: tr3(lang, zhHansTitle, zhHantTitle, enTitle),
      synonyms: mergedSynonyms,
    };
  });
}

export function blockReasonForAnchor(
  anchor: SettingsAnchor,
  availability: SettingsSearchAvailability,
): SettingsSearchBlockReason | null {
  if (anchor === "cloudConsent" && !availability.hasCloudConsentEndpoints) {
    return "noCloudConsent";
  }
  return null;
}

function normalizeSearchText(value: string): string {
  return value
    .normalize("NFKC")
    .toLowerCase()
    .trim();
}

export function tokenizeSettingsQuery(query: string): string[] {
  const normalized = normalizeSearchText(query);
  if (!normalized) return [];
  return normalized
    .split(/[\s\p{P}\p{S}]+/u)
    .filter((part) => part.length > 0);
}

function hasWordStart(token: string, haystack: string): boolean {
  const idx = haystack.indexOf(token);
  if (idx < 0) return false;
  if (idx === 0) return true;
  const prev = haystack[idx - 1];
  return prev === " " || prev === "/" || prev === "·" || prev === "（" || prev === "(" || prev === "-" || prev === "_";
}

function fieldScore(token: string, field: string, weight: number): number {
  const haystack = normalizeSearchText(field);
  if (!haystack) return 0;
  let quality = 0;
  if (haystack === token) {
    quality = QUALITY_EXACT;
  } else if (haystack.startsWith(token)) {
    quality = QUALITY_PREFIX;
  } else if (hasWordStart(token, haystack)) {
    quality = QUALITY_WORD_START;
  } else if (haystack.includes(token)) {
    quality = QUALITY_CONTAINS;
  } else {
    return 0;
  }
  return quality * 10 + weight;
}

function scoreEntry(entry: SettingsSearchEntry, tokens: readonly string[]): number | null {
  let weakest: number | null = null;
  for (const token of tokens) {
    let best = fieldScore(token, entry.title, WEIGHT_TITLE);
    for (const synonym of entry.synonyms) {
      best = Math.max(best, fieldScore(token, synonym, WEIGHT_SYNONYM));
    }
    best = Math.max(best, fieldScore(token, entry.section, WEIGHT_SECTION));
    if (best <= 0) return null;
    weakest = weakest === null ? best : Math.min(weakest, best);
  }
  return weakest;
}

export function searchSettings(
  query: string,
  availability: SettingsSearchAvailability = UNRESTRICTED_SETTINGS_AVAILABILITY,
  limit: number = SETTINGS_SEARCH_RESULT_LIMIT,
  lang: AppLanguage = currentLanguage(),
): SettingsSearchOutcome {
  const tokens = tokenizeSettingsQuery(query);
  if (tokens.length === 0) {
    return { hits: [], blocked: null, isEmpty: true };
  }

  const entries = settingsSearchEntries(availability, lang);
  const ranked: SettingsSearchHit[] = [];
  for (const entry of entries) {
    const score = scoreEntry(entry, tokens);
    if (score === null) continue;
    ranked.push({
      entry,
      anchor: entry.anchor,
      tab: entry.tab,
      section: entry.section,
      title: entry.title,
      score,
    });
  }

  ranked.sort((lhs, rhs) => {
    if (lhs.score !== rhs.score) return rhs.score - lhs.score;
    if (lhs.title !== rhs.title) return lhs.title < rhs.title ? -1 : 1;
    return lhs.anchor < rhs.anchor ? -1 : lhs.anchor > rhs.anchor ? 1 : 0;
  });

  const hits: SettingsSearchHit[] = [];
  let blocked: SettingsSearchBlocked | null = null;
  for (const hit of ranked) {
    const reason = blockReasonForAnchor(hit.anchor, availability);
    if (reason === null) {
      if (hits.length < Math.max(0, limit)) {
        hits.push(hit);
      }
    } else if (blocked === null) {
      blocked = {
        anchor: hit.anchor,
        reason,
        explanation: blockReasonExplanation(reason, lang),
      };
    }
  }

  if (hits.length > 0) {
    blocked = null;
  }

  return {
    hits,
    blocked,
    isEmpty: hits.length === 0 && blocked === null,
  };
}

export const SettingsSearchSelection = {
  moved(index: number | null, delta: number, count: number): number | null {
    if (count <= 0) return null;
    if (index === null) return delta > 0 ? 0 : count - 1;
    return Math.min(Math.max(index + delta, 0), count - 1);
  },

  commitIndex(index: number | null, count: number): number | null {
    if (count <= 0) return null;
    if (index === null || index < 0 || index >= count) return 0;
    return index;
  },

  clamped(index: number | null, count: number): number | null {
    if (count <= 0 || index === null) return null;
    return Math.min(Math.max(index, 0), count - 1);
  },
};

interface HighlightTimerState {
  timerId: number | null;
  anchor: SettingsAnchor | null;
}

const highlightStateByRoot = new WeakMap<HTMLElement, HighlightTimerState>();

export const SETTINGS_HIGHLIGHT_DURATION_MS = 1600;

export function clearSettingsHighlight(root: HTMLElement): void {
  const ownerWin = root.ownerDocument?.defaultView ?? window;
  const existing = highlightStateByRoot.get(root);
  if (existing && existing.timerId !== null) {
    ownerWin.clearTimeout(existing.timerId);
    existing.timerId = null;
  }
  if (existing) {
    existing.anchor = null;
  }
  root.querySelectorAll<HTMLElement>("[data-settings-highlighted]").forEach((el) => {
    el.classList.remove("is-search-highlighted");
    el.removeAttribute("data-settings-highlighted");
    el.style.removeProperty("outline");
    el.style.removeProperty("outline-offset");
    el.style.removeProperty("background-color");
    el.style.removeProperty("transition");
  });
}

export function highlightSettingsAnchor(
  root: HTMLElement,
  anchor: SettingsAnchor,
  durationMs: number = SETTINGS_HIGHLIGHT_DURATION_MS,
): HTMLElement | null {
  clearSettingsHighlight(root);
  const target = root.querySelector<HTMLElement>(`[data-settings-anchor="${anchor}"]`);
  if (!target) return null;

  let ancestorDetails = target.closest("details");
  while (ancestorDetails) {
    ancestorDetails.open = true;
    ancestorDetails = ancestorDetails.parentElement?.closest("details") ?? null;
  }

  target.classList.add("is-search-highlighted");
  target.setAttribute("data-settings-highlighted", anchor);
  target.style.transition = "outline-color 180ms ease, background-color 180ms ease";
  target.style.outline = "2px solid rgba(59, 130, 246, 0.85)";
  target.style.outlineOffset = "3px";
  target.style.backgroundColor = "rgba(59, 130, 246, 0.10)";

  if (typeof target.scrollIntoView === "function") {
    try {
      target.scrollIntoView({ block: "center", behavior: "smooth" });
    } catch {
      target.scrollIntoView();
    }
  }

  const body = root.querySelector<HTMLElement>(".cc-sheet-body");
  if (body && body.contains(target)) {
    const targetTop = target.offsetTop;
    const bodyHeight = body.clientHeight;
    if (bodyHeight > 0 && targetTop > 0) {
      body.scrollTop = Math.max(0, targetTop - Math.floor(bodyHeight / 3));
    }
  }

  const focusable = target.matches("input, select, textarea, button")
    ? target
    : target.querySelector<HTMLElement>("input, select, textarea, button");
  focusable?.focus({ preventScroll: true });

  const ownerWin = root.ownerDocument?.defaultView ?? window;
  const state: HighlightTimerState = { timerId: null, anchor };
  highlightStateByRoot.set(root, state);
  state.timerId = ownerWin.setTimeout(() => {
    if (highlightStateByRoot.get(root)?.anchor === anchor) {
      clearSettingsHighlight(root);
    }
  }, durationMs);

  return target;
}
