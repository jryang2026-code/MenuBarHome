import { t } from "../core/i18n.js";
import { invokeTauriVoid } from "./transport.js";

export interface HaDiscoveredInstance {
  readonly name: string;
  readonly host: string;
  readonly port: number;
  readonly baseUrl: string;
  readonly version?: string;
  readonly uuid?: string;
}

export const DEFAULT_HA_DISCOVERY_TIMEOUT_MS = 3000;

export function normalizeDiscoveredInstances(raw: unknown): HaDiscoveredInstance[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: HaDiscoveredInstance[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const record = item as Record<string, unknown>;
    const baseUrl = typeof record.baseUrl === "string" ? record.baseUrl.trim() : "";
    const host = typeof record.host === "string" ? record.host.trim() : "";
    const port = typeof record.port === "number" && Number.isFinite(record.port) ? Math.trunc(record.port) : 0;
    const rawName = typeof record.name === "string" ? record.name.trim() : "";
    if (!baseUrl || !host || port <= 0 || port > 65535) continue;
    const dedupeKey = baseUrl.toLowerCase();
    if (seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);
    const version =
      typeof record.version === "string" && record.version.trim() !== ""
        ? record.version.trim()
        : undefined;
    const uuid =
      typeof record.uuid === "string" && record.uuid.trim() !== ""
        ? record.uuid.trim()
        : undefined;
    out.push({
      name: rawName || "Home Assistant",
      host,
      port,
      baseUrl,
      ...(version !== undefined ? { version } : {}),
      ...(uuid !== undefined ? { uuid } : {}),
    });
  }
  return out;
}

export async function discoverHomeAssistantOnLan(
  timeoutMs: number = DEFAULT_HA_DISCOVERY_TIMEOUT_MS,
): Promise<HaDiscoveredInstance[] | null> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return null;
  const raw = await invoke<unknown>("discover_home_assistant", { timeoutMs });
  return normalizeDiscoveredInstances(raw);
}

export function cancelHomeAssistantDiscovery(): void {
  invokeTauriVoid("cancel_ha_discovery");
}

export function formatDiscoveredCandidateDetail(item: HaDiscoveredInstance): string {
  return item.version ? `${item.baseUrl} · v${item.version}` : item.baseUrl;
}

export function resolveHaDiscoveryOutcome(found: HaDiscoveredInstance[] | null): {
  readonly results: HaDiscoveredInstance[];
  readonly status: { readonly text: string; readonly isError: boolean };
} {
  if (found === null) {
    return {
      results: [],
      status: { text: t("当前环境不支持局域网发现，请手动输入地址"), isError: true },
    };
  }
  if (found.length === 0) {
    return {
      results: [],
      status: { text: t("未在局域网发现 Home Assistant，请手动填写地址"), isError: true },
    };
  }
  return {
    results: found,
    status: {
      text: t("已发现 {count} 个 Home Assistant，点击填入地址", { count: found.length }),
      isError: false,
    },
  };
}

export function haDiscoveryFailureStatus(): { readonly text: string; readonly isError: boolean } {
  return { text: t("局域网查找失败，请检查网络连接或手动填写地址"), isError: true };
}

export function renderHaDiscoveredCandidates(
  candidates: readonly HaDiscoveredInstance[],
  escapeHtml: (raw: string) => string,
  buttonAttr: string,
): string {
  if (candidates.length === 0) return "";
  return candidates
    .map((item) => {
      const detail = formatDiscoveredCandidateDetail(item);
      return `<button type="button" class="cc-ha-candidate-btn" ${buttonAttr}="${escapeHtml(item.baseUrl)}">
        <span class="cc-ha-candidate-name">${escapeHtml(item.name)}</span>
        <span class="cc-ha-candidate-url">${escapeHtml(detail)}</span>
      </button>`;
    })
    .join("");
}
