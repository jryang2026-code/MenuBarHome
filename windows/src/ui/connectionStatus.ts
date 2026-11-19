import { DUAL_SOURCE_ENABLED_STORAGE_KEY } from "../core/dualSourceProvider.js";
import { homeAssistantIdentity } from "../core/homeAssistant.js";
import type { LanguagePreference } from "../core/i18n.js";
import type { ConnectionStatus } from "../core/models.js";
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
const haErrorMessage = (host: MenuMijiaWindowsApp): string => host.haConnectionError ?? "";

interface SourcePresentation {
  readonly badge: ConnectionBadge;
  readonly text: string;
}

/**
 * Every configured Xiaomi account reports its own connection, so one broken account can never hide behind a
 * healthy first entry. `undefined` means "no per-account data" (single legacy session).
 */
function miAccountStatuses(host: MenuMijiaWindowsApp): readonly { readonly kind: string }[] {
  const dual = host.dualSourceCoordinator?.getLastMerged()?.accountStatuses;
  const statuses = dual && Object.keys(dual).length > 0 ? dual : host.multiAccountState?.merged?.accountStatuses;
  return statuses ? Object.values(statuses) : [];
}

function miAccountsConnected(host: MenuMijiaWindowsApp): number {
  return miAccountStatuses(host).filter((status) => status.kind === "connected").length;
}

/**
 * `cloudValuesStale` belongs to Xiaomi Cloud alone. Home Assistant reads its own coordinator status or its own
 * error message, never this flag and never `valuesAreStale` (which follows the active connection mode).
 */
function miSourcePresentation(host: MenuMijiaWindowsApp, dual: boolean, statuses: Readonly<Record<string, ConnectionStatus>> | null): SourcePresentation {
  if (!IS_ACTIVE_MI(host) && !dual) return { badge: "unconfigured", text: tr(host, "未启用", "未啟用", "Not in use") };
  if (miExpired(host)) return { badge: "reauth", text: tr(host, "登录已过期 · 需要重新扫码", "登入已過期 · 需要重新掃碼", "Session expired · re-scan required") };
  if (host.isSyncingCloud) return { badge: "connecting", text: tr(host, "正在连接…", "正在連線…", "Connecting…") };
  const cloud = dual ? statuses?.xiaomiCloud ?? null : null;
  if (cloud?.kind === "connecting") return { badge: "connecting", text: tr(host, "正在连接…", "正在連線…", "Connecting…") };
  if (cloud?.kind === "disconnected") return { badge: "offline", text: unavailableText(host, tr(host, "米家", "米家", "Xiaomi Home")) };
  if (host.cloudValuesStale) return { badge: "degraded", text: tr(host, "暂不可用 · 设备状态可能过期", "暫時不可用 · 裝置狀態可能過期", "Unavailable · device states may be stale") };
  const total = miAccountStatuses(host).length;
  if (total > 0) {
    const connected = miAccountsConnected(host);
    if (connected === 0) return { badge: "offline", text: unavailableText(host, tr(host, "米家", "米家", "Xiaomi Home")) };
    if (connected < total) {
      return {
        badge: "degraded",
        text: tr(host, "部分米家账号异常 · 部分设备暂无数据", "部分米家帳號異常 · 部分裝置暫無資料", "Some Xiaomi Home accounts unavailable · some devices have no data"),
      };
    }
  }
  return dual
    ? { badge: "online", text: tr(host, "已连接", "已連線", "Connected") }
    : { badge: "online", text: tr(host, "已连接 · {count} 台设备", "已連線 · {count} 台裝置", "Connected · {count} devices", { count: host.devices.length }) };
}

/** Home Assistant owns only its own coordinator status, error message and sync state. */
function haSourcePresentation(host: MenuMijiaWindowsApp, dual: boolean, statuses: Readonly<Record<string, ConnectionStatus>> | null): SourcePresentation {
  if (!IS_ACTIVE_HA(host) && !dual) return { badge: "unconfigured", text: tr(host, "未启用", "未啟用", "Not in use") };
  const message = haErrorMessage(host);
  if (message.includes("Home Assistant authentication rejected")) {
    return { badge: "reauth", text: tr(host, "凭据或地址需更新", "憑證或地址需更新", "Credentials or address need attention") };
  }
  if (message.includes("Home Assistant endpoint has not been approved") || message.includes("未授权的网络来源")) {
    return { badge: "offline", text: tr(host, "未连接（已拒绝明文 http）", "未連線（已拒絕明文 http）", "Not connected (plaintext http declined)") };
  }
  const status = dual ? statuses?.homeAssistant ?? null : null;
  if (status?.kind === "connecting") return { badge: "connecting", text: tr(host, "正在连接…", "正在連線…", "Connecting…") };
  if (status?.kind === "disconnected") return { badge: "offline", text: unavailableText(host, "Home Assistant") };
  if (!dual) {
    if (message !== "") return { badge: "offline", text: unavailableText(host, "Home Assistant") };
    // In single-source Home Assistant mode `valuesAreStale` is Home Assistant's own staleness, never Xiaomi's.
    if (IS_ACTIVE_HA(host) && host.valuesAreStale) {
      return { badge: "degraded", text: tr(host, "设备状态可能过期，正在等待同步", "裝置狀態可能過期，正在等待同步", "Device states may be stale; waiting to sync") };
    }
  }
  if (host.isSyncingCloud) return { badge: "connecting", text: tr(host, "正在连接…", "正在連線…", "Connecting…") };
  return dual
    ? { badge: "online", text: tr(host, "已连接", "已連線", "Connected") }
    : { badge: "online", text: tr(host, "已连接 · {count} 台设备", "已連線 · {count} 台裝置", "Connected · {count} devices", { count: host.devices.length }) };
}
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
  const dualStatuses = dual ? host.dualSourceCoordinator?.getSourceStatuses() ?? null : null;
  const miView = hasMi(host) ? miSourcePresentation(host, dual, dualStatuses) : null;
  const haView = hasHA(host) ? haSourcePresentation(host, dual, dualStatuses) : null;
  const sources: ConnectionSourceItem[] = [];
  if (miView) sources.push({ id: "mi", name: tr(host, "米家", "米家", "Xiaomi Home"), statusText: miView.text, badge: miView.badge });
  if (haView) sources.push({ id: "ha", name: "Home Assistant", statusText: haView.text, badge: haView.badge });
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
    // Each platform stands on its own status; `cloudValuesStale` and `valuesAreStale` never cross over here.
    const miBadge = miView?.badge ?? "online";
    const haBadge = haView?.badge ?? "online";
    const miUp = miBadge === "online";
    const haUp = haBadge === "online";
    // A stale Xiaomi cache names Xiaomi in the footer; partial accounts keep their own specific copy.
    const miDegradedText = host.cloudValuesStale ? unavailableText(host, tr(host, "米家", "米家", "Xiaomi Home")) : miView?.text ?? unavailableText(host, tr(host, "米家", "米家", "Xiaomi Home"));
    if (!miUp && haUp) {
      if (miBadge === "connecting") return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在连接米家…", "正在連線米家…", "Connecting to Xiaomi Home…"), null);
      return present("degraded", SF_ICONS.wifi, miDegradedText, actions.retry);
    }
    if (miUp && !haUp) {
      if (haBadge === "connecting") return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在连接 Home Assistant…", "正在連線 Home Assistant…", "Connecting to Home Assistant…"), null);
      return present("degraded", SF_ICONS.wifi, haView?.text ?? unavailableText(host, "Home Assistant"), actions.retry);
    }
    if (!miUp && !haUp) {
      if (miBadge === "connecting" || haBadge === "connecting") {
        return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在连接家居平台…", "正在連線家居平台…", "Connecting to smart home platforms…"), null);
      }
      // A partially reachable account is not a total outage: keep the degraded tone and name the dead platform.
      if (miBadge === "degraded" || haBadge === "degraded") {
        return present("degraded", SF_ICONS.wifi, unavailableText(host, haBadge === "offline" ? "Home Assistant" : tr(host, "米家", "米家", "Xiaomi Home")), actions.retry);
      }
      return present("offline", SF_ICONS.wifiSlash, tr(host, "米家与 Home Assistant 均不可用", "米家與 Home Assistant 均不可用", "Xiaomi Home and Home Assistant are both unavailable"), actions.settings);
    }
    if (host.isSyncingCloud) return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在同步家居平台…", "正在同步家居平台…", "Syncing smart home platforms…"), null);
    return present("online", SF_ICONS.checkmarkCircleFill, tr(host, "设备同步正常", "裝置同步正常", "Devices synced"), null);
  }
  if (IS_ACTIVE_HA(host) && haView) {
    if (haView.badge === "offline") return present("offline", SF_ICONS.wifiSlash, unavailableText(host), actions.settings);
    if (haView.badge === "degraded") return present("degraded", SF_ICONS.wifi, haView.text, actions.retry);
    if (haView.badge === "connecting") {
      return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在连接{platform}…", "正在連線{platform}…", "Connecting to {platform}…", { platform: platformName(host) }), null);
    }
    return present("online", SF_ICONS.checkmarkCircleFill, tr(host, "设备同步正常", "裝置同步正常", "Devices synced"), null);
  }
  if (miView) {
    if (miView.badge === "offline") return present("offline", SF_ICONS.wifiSlash, miView.text, actions.retry);
    if (miView.badge === "degraded") {
      const text = host.cloudValuesStale ? unavailableText(host, tr(host, "米家", "米家", "Xiaomi Home")) : miView.text;
      return present("degraded", SF_ICONS.wifi, text, actions.retry);
    }
    if (miView.badge === "connecting") {
      return present("syncing", SF_ICONS.arrowClockwise, tr(host, "正在连接{platform}…", "正在連線{platform}…", "Connecting to {platform}…", { platform: platformName(host) }), null);
    }
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
