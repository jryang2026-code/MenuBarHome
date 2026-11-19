import { DUAL_SOURCE_ENABLED_STORAGE_KEY } from "../core/dualSourceProvider.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import type { LanguagePreference } from "../core/i18n.js";
import { miSessionExpiryState } from "../core/miCloud/session.js";
import { tr3 } from "../core/safetyAndHealth.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { SF_ICONS } from "./appConstants.js";
/** Plain-language connection state for the footer and its keyboard-reachable detail card. */
export type ConnectionBadge = "online" | "connecting" | "degraded" | "reauth" | "offline" | "demo" | "unconfigured";
export interface ConnectionSourceItem {
  readonly id: "mi" | "ha" | "demo";
  readonly name: string;
  readonly statusText: string;
  readonly badge: ConnectionBadge;
}
export type ConnectionStatusActionKind = "retry" | "settings" | "qr" | "leaveDemo";
export interface ConnectionStatusAction { readonly kind: ConnectionStatusActionKind; readonly label: string; }
export type ConnectionTone = "online" | "syncing" | "degraded" | "offline" | "demo" | "unconfigured";
export interface ConnectionStatusPresentation {
  readonly tone: ConnectionTone;
  readonly icon: string;
  readonly text: string;
  readonly action: ConnectionStatusAction | null;
  readonly sources: readonly ConnectionSourceItem[];
}
const BADGE_ICON: Readonly<Record<ConnectionBadge, string>> = {
  online: SF_ICONS.checkmarkCircleFill,
  connecting: SF_ICONS.arrowClockwise,
  degraded: SF_ICONS.wifi,
  reauth: SF_ICONS.qrcode,
  offline: SF_ICONS.wifiSlash,
  demo: SF_ICONS.sparkles,
  unconfigured: SF_ICONS.link,
};
const BADGE_LABEL: Readonly<Record<ConnectionBadge, readonly [string, string, string]>> = {
  online: ["在线", "線上", "Online"],
  connecting: ["连接中", "連線中", "Connecting"],
  degraded: ["部分可用", "部分可用", "Degraded"],
  reauth: ["需重新登录", "需重新登入", "Sign-in required"],
  offline: ["不可用", "不可用", "Unavailable"],
  demo: ["演示", "示範", "Demo"],
  unconfigured: ["未启用", "未啟用", "Not in use"],
};
/** "system" must follow the resolved UI language, not Node's `navigator.languages` in tests. */
const prefOf = (host: MenuMijiaWindowsApp): LanguagePreference | undefined =>
  host.settings.interfaceLanguage === "system" ? undefined : host.settings.interfaceLanguage;
function tr(host: MenuMijiaWindowsApp, hans: string, hant: string, en: string, params?: Readonly<Record<string, string | number>>): string {
  return tr3(hans, hant, en, params, prefOf(host));
}
const hasMi = (host: MenuMijiaWindowsApp): boolean =>
  host.settings.miSession !== null || (host.miAccountsOverride?.length ?? 0) > 0;
const hasHA = (host: MenuMijiaWindowsApp): boolean =>
  homeAssistantIdentity(host.settings.haBaseURL, host.settings.haToken) !== null;
function usesDualSource(host: MenuMijiaWindowsApp): boolean {
  if (host.settings.connectionMode === "demo" || !hasMi(host) || !hasHA(host)) return false;
  if (host.dualSourceEnabledOverride !== null) return host.dualSourceEnabledOverride;
  if (typeof host.settings.dualSourceEnabled === "boolean") return host.settings.dualSourceEnabled;
  try {
    return globalThis.localStorage?.getItem(DUAL_SOURCE_ENABLED_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}
function miExpired(host: MenuMijiaWindowsApp): boolean {
  return host.miSessionExpired
    || (host.settings.miSession !== null && miSessionExpiryState(host.settings.miSession).kind === "expired");
}
const IS_ACTIVE_MI = (host: MenuMijiaWindowsApp): boolean => host.settings.connectionMode !== "homeAssistant";
const IS_ACTIVE_HA = (host: MenuMijiaWindowsApp): boolean => host.settings.connectionMode === "homeAssistant";
function platformName(host: MenuMijiaWindowsApp): string {
  return IS_ACTIVE_HA(host) ? "Home Assistant" : tr(host, "米家", "米家", "Xiaomi Home");
}
function unavailableText(host: MenuMijiaWindowsApp, platform = platformName(host)): string {
  // A Latin platform name needs a space before Chinese copy; 米家 does not.
  const gap = /^[\x00-\x7f]/.test(platform) ? " " : "";
  return tr(host, `{platform}${gap}暂不可用，部分设备暂无数据`, `{platform}${gap}暫時不可用，部分裝置暫無資料`, "{platform} unavailable; some devices have no data", { platform });
}
function miStatusText(host: MenuMijiaWindowsApp, dual: boolean): string {
  if (!IS_ACTIVE_MI(host) && !dual) return tr(host, "未启用", "未啟用", "Not in use");
  if (miExpired(host)) return tr(host, "登录已过期 · 需要重新扫码", "登入已過期 · 需要重新掃碼", "Session expired · re-scan required");
  if (host.isSyncingCloud) return tr(host, "正在连接…", "正在連線…", "Connecting…");
  if (host.cloudValuesStale) return tr(host, "暂不可用 · 设备状态可能过期", "暫時不可用 · 裝置狀態可能過期", "Unavailable · device states may be stale");
  return dual
    ? tr(host, "已连接", "已連線", "Connected")
    : tr(host, "已连接 · {count} 台设备", "已連線 · {count} 台裝置", "Connected · {count} devices", { count: host.devices.length });
}
const haErrorMessage = (host: MenuMijiaWindowsApp): string => host.haConnectionError ?? "";
function haStatusText(host: MenuMijiaWindowsApp, dual: boolean): string {
  if (!IS_ACTIVE_HA(host) && !dual) return tr(host, "未启用", "未啟用", "Not in use");
  const message = haErrorMessage(host);
  if (message.includes("Home Assistant authentication rejected")) {
    return tr(host, "凭据或地址需更新", "憑證或地址需更新", "Credentials or address need attention");
  }
  if (message.includes("Home Assistant endpoint has not been approved") || message.includes("未授权的网络来源")) {
    return tr(host, "未连接（已拒绝明文 http）", "未連線（已拒絕明文 http）", "Not connected (plaintext http declined)");
  }
  if (message !== "") return unavailableText(host, "Home Assistant");
  if (host.isSyncingCloud) return tr(host, "正在连接…", "正在連線…", "Connecting…");
  return dual
    ? tr(host, "已连接", "已連線", "Connected")
    : tr(host, "已连接 · {count} 台设备", "已連線 · {count} 台裝置", "Connected · {count} devices", { count: host.devices.length });
}
const sourceBadge = (host: MenuMijiaWindowsApp, id: "mi" | "ha", dual: boolean): ConnectionBadge => {
  const message = haErrorMessage(host);
  if (id === "mi") {
    if (!IS_ACTIVE_MI(host) && !dual) return "unconfigured";
    if (miExpired(host)) return "reauth";
    if (host.isSyncingCloud) return "connecting";
    return host.cloudValuesStale ? "degraded" : "online";
  }
  if (!IS_ACTIVE_HA(host) && !dual) return "unconfigured";
  if (message.includes("Home Assistant authentication rejected")) return "reauth";
  if (message.includes("Home Assistant endpoint has not been approved") || message.includes("未授权的网络来源")) return "offline";
  if (message !== "" || host.valuesAreStale) return "degraded";
  return host.isSyncingCloud ? "connecting" : "online";
};
const miConnectionKind = (statuses: Readonly<Record<string, { readonly kind: string }>>): string =>
  Object.entries(statuses).find(([key]) => key !== "homeAssistant")?.[1].kind ?? "connected";
export function resolveConnectionStatus(host: MenuMijiaWindowsApp): ConnectionStatusPresentation {
  if (host.settings.connectionMode === "demo") {
    return {
      tone: "demo",
      icon: SF_ICONS.sparkles,
      text: tr(host, "示例家庭，不会控制真实设备", "範例家庭，不會控制真實裝置", "Demo home; won't control real devices"),
      action: { kind: "leaveDemo", label: tr(host, "连接真实家庭", "連線真實家庭", "Connect a real home") },
      sources: [{ id: "demo", name: tr(host, "示例家庭", "範例家庭", "Demo home"), statusText: tr(host, "本地演示数据", "本機示範資料", "Local demo data"), badge: "demo" }],
    };
  }
  if (!hasMi(host) && !hasHA(host)) {
    return {
      tone: "unconfigured",
      icon: SF_ICONS.link,
      text: tr(host, "还没连接家居平台", "還沒連線家居平台", "No smart home platform connected"),
      action: { kind: "settings", label: tr(host, "去连接", "去連線", "Connect") },
      sources: [],
    };
  }
  const dual = usesDualSource(host);
  const sources: ConnectionSourceItem[] = [];
  if (hasMi(host)) sources.push({ id: "mi", name: tr(host, "米家", "米家", "Xiaomi Home"), statusText: miStatusText(host, dual), badge: sourceBadge(host, "mi", dual) });
  if (hasHA(host)) sources.push({ id: "ha", name: "Home Assistant", statusText: haStatusText(host, dual), badge: sourceBadge(host, "ha", dual) });
  const actions = {
    retry: { kind: "retry" as const, label: tr(host, "重试连接", "重試連線", "Retry connection") },
    settings: { kind: "settings" as const, label: tr(host, "查看连接", "查看連線", "Check connection") },
    qr: { kind: "qr" as const, label: tr(host, "重新扫码", "重新掃碼", "Re-scan") },
  };
  const present = (tone: ConnectionTone, icon: string, text: string, action: ConnectionStatusAction | null) =>
    ({ tone, icon, text, action, sources });
  if (hasMi(host) && miExpired(host) && (IS_ACTIVE_MI(host) || dual)) {
    return present("offline", SF_ICONS.qrcode, tr(host, "米家登录已过期 · 重新扫码", "米家登入已過期 · 重新掃碼", "Xiaomi Home session expired · re-scan"), actions.qr);
  }
  const haMessage = haErrorMessage(host);
  if ((IS_ACTIVE_HA(host) || dual) && haMessage.includes("Home Assistant authentication rejected")) {
    return present("offline", SF_ICONS.exclamationTriangleFill, tr(host, "Home Assistant 凭据或地址需更新", "Home Assistant 憑證或地址需更新", "Home Assistant credentials or address need attention"), actions.settings);
  }
  if ((IS_ACTIVE_HA(host) || dual) && (haMessage.includes("Home Assistant endpoint has not been approved") || haMessage.includes("未授权的网络来源"))) {
    return present("offline", SF_ICONS.wifiSlash, tr(host, "Home Assistant 未连接（已拒绝明文 http）", "Home Assistant 未連線（已拒絕明文 http）", "Home Assistant not connected (plaintext http declined)"), actions.settings);
  }
  if (dual) {
    const statuses = host.dualSourceCoordinator?.getSourceStatuses();
    if (statuses) {
      const haDown = statuses.homeAssistant.kind !== "connected";
      const miDown = miConnectionKind(statuses) !== "connected";
      if (haDown !== miDown) {
        return present("degraded", SF_ICONS.wifi, unavailableText(host, haDown ? "Home Assistant" : tr(host, "米家", "米家", "Xiaomi Home")), actions.retry);
      }
      if (haDown) {
        return present("offline", SF_ICONS.wifiSlash, tr(host, "米家与 Home Assistant 均不可用", "米家與 Home Assistant 均不可用", "Xiaomi Home and Home Assistant are both unavailable"), actions.settings);
      }
      if (host.isSyncingCloud) return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在同步家居平台…", "正在同步家居平台…", "Syncing smart home platforms…"), null);
      return present("online", SF_ICONS.checkmarkCircleFill, tr(host, "设备同步正常", "裝置同步正常", "Devices synced"), null);
    }
  }
  if (IS_ACTIVE_HA(host) && haMessage !== "") {
    return present("offline", SF_ICONS.wifiSlash, unavailableText(host), actions.settings);
  }
  if (host.cloudValuesStale) return present("degraded", SF_ICONS.wifi, unavailableText(host), actions.retry);
  if (host.isSyncingCloud) {
    return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在连接{platform}…", "正在連線{platform}…", "Connecting to {platform}…", { platform: platformName(host) }), null);
  }
  if (host.valuesAreStale) {
    return present("degraded", SF_ICONS.wifi, tr(host, "设备状态可能过期，正在等待同步", "裝置狀態可能過期，正在等待同步", "Device states may be stale; waiting to sync"), actions.retry);
  }
  return present("online", SF_ICONS.checkmarkCircleFill, tr(host, "设备同步正常", "裝置同步正常", "Devices synced"), null);
}
const dotClass = (tone: ConnectionTone): string =>
  tone === "syncing" ? "is-syncing" : tone === "degraded" ? "is-degraded" : tone === "demo" ? "is-demo" : tone === "online" ? "is-online" : "is-offline";
/** The footer trigger and its detail card; rendered inside the footer so both themes keep one DOM shape. */
export function renderConnectionStatus(host: MenuMijiaWindowsApp): string {
  const status = resolveConnectionStatus(host);
  const label = host.escapeHtml(status.text);
  const title = host.escapeHtml(tr(host, "连接详情", "連線詳情", "Connection details"));
  const open = host.connectionDetailsOpen;
  const action = status.action
    ? `<button type="button" class="cc-footer-action" id="btn-connection-action" data-connection-action="${status.action.kind}">${host.escapeHtml(status.action.label)}</button>`
    : "";
  const sources = status.sources.length
    ? status.sources.map((source) => `<li class="cc-conn-source" data-connection-source="${source.id}"><span class="cc-conn-badge" data-connection-badge="${source.badge}" aria-label="${host.escapeHtml(tr3(...BADGE_LABEL[source.badge], undefined, prefOf(host)))}">${BADGE_ICON[source.badge]}</span><span class="cc-conn-name">${host.escapeHtml(source.name)}</span><span class="cc-conn-state">${host.escapeHtml(source.statusText)}</span></li>`).join("")
    : `<li class="cc-conn-source is-empty">${host.escapeHtml(tr(host, "还没连接家居平台", "還沒連線家居平台", "No smart home platform connected"))}</li>`;
  const details = open
    ? `<div class="cc-conn-popover" id="cc-connection-details" data-connection-details role="dialog" aria-label="${title}">
        <div class="cc-conn-popover-header"><strong>${title}</strong><button type="button" class="cc-conn-close" data-close-connection-details aria-label="${host.escapeHtml(tr(host, "关闭连接详情", "關閉連線詳情", "Close connection details"))}">${SF_ICONS.xmark}</button></div>
        <ul class="cc-conn-sources">${sources}</ul>
        <div class="cc-conn-actions"><button type="button" class="cc-inline-pill" data-connection-retry>${host.escapeHtml(tr(host, "重试连接", "重試連線", "Retry connection"))}</button><button type="button" class="cc-inline-pill" data-connection-settings>${host.escapeHtml(tr(host, "连接设置…", "連線設定…", "Connection settings…"))}</button></div>
      </div>`
    : "";
  return `<button type="button" class="cc-status-trigger" id="btn-connection-status" data-connection-status-trigger aria-expanded="${open}" aria-controls="cc-connection-details" aria-label="${title}" title="${label}"><span class="cc-status-dot ${dotClass(status.tone)}" aria-hidden="true"></span><span class="cc-status-icon" aria-hidden="true">${status.icon}</span><span class="cc-footer-label">${label}</span></button>${action}${details}`;
}
