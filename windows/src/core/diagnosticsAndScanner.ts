import { HomeAssistantSynthesizer, type HAInvoke } from "./homeAssistant.js";
import { currentLanguage,
  resolveLanguage,
  type AppLanguage,
  type LanguagePreference,
} from "./i18n.js";
import { discoverMiAccountDevicesAndRooms,
  makeMiAccount,
  type MiAccount,
} from "./miAccountsStore.js";
import { isFallbackSpec } from "./miCloud/spec.js";
import { MiCloudClient,
  MiotSpecResolver,
  MiotSynthesizer,
  miotShortName,
  normalizeMiCloudRegion,
  parseMiotDeviceSpec,
  type HttpTransport,
  type MiDeviceRecord,
  type MiRoom,
  type MiSession,
  type MiotDeviceSpec,
} from "./miCloudClient.js";
import type { HomeBackend, SmartDevice, SynthesizedHome } from "./models.js";
import { getXiaomiBackoffUntilMs, isXiaomiRateLimitError } from "./pollingPolicy.js";

function tr3(zhHans: string,
  zhHant: string,
  en: string,
  params?: Readonly<Record<string, string | number>>,
  preference?: LanguagePreference,
): string { const lang: AppLanguage = preference !== undefined
      ? resolveLanguage(preference, globalThis.navigator?.languages ?? [])
      : resolveLanguage(currentLanguage(), []);
  const template = lang === "en" ? en : lang === "zh-Hant" ? zhHant : zhHans;
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole,
  );
}

function defaultStorage(): Storage | null { try { return typeof localStorage !== "undefined" ? localStorage : null;
  } catch { return null;
  }
}

export const GITHUB_UNSUPPORTED_DEVICE_ISSUE_URL =
  "https://github.com/jryang2026-code/MenuBarHome/issues/new";

export const DIAGNOSTICS_RING_BUFFER_CAPACITY = 50;
export const DIAGNOSTICS_RING_STORAGE_KEY = "menumijia.windows.diagnosticsErrors.v1";

const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*)?/g;
const BEARER_OR_API_KEY_PATTERN =
  /\b(?:Bearer\s+[A-Za-z0-9._~+/=-]{8,}|sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,})\b/gi;
const URL_SCHEME_PATTERN = /\b(?:https?|wss?|rtsp|rtsps):\/\/[^\s)`"'>]+/gi;
const MAC_ADDRESS_PATTERN = /\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b/g;
const PRIVATE_OR_LAN_IPV4_PATTERN =
  /\b(?:10(?:\.\d{1,3}){3}|127(?:\.\d{1,3}){3}|169\.254(?:\.\d{1,3}){2}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}|192\.0\.2\.\d{1,3}|198\.51\.100\.\d{1,3}|203\.0\.113\.\d{1,3})\b/g;
const ANY_IPV4_PATTERN = /\b(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}\b/g;
const PRIVATE_IPV6_PATTERN = /\b(?:fe80|fc[0-9a-f]{2}|fd[0-9a-f]{2}):[0-9a-f:]+/gi;
const MI_ACCOUNT_ID_PATTERN = /\bmi:[a-z0-9_-]+:[0-9a-f]{8,}\b/gi;
const MIOT_DID_PREFIX_PATTERN =
  /\b(?:miot(?:-action)?:[^\s)`"'>]+|blt\.[A-Za-z0-9._-]+|group\.\d{4,})\b/gi;
const LONG_NUMERIC_ID_PATTERN = /\b\d{6,}(?:\.s\d+)?\b/g;
const LONG_OPAQUE_TOKEN_PATTERN = /\b[A-Za-z0-9+/=_-]{32,}\b/g;
const SECRET_KV_PATTERN =
  /\b(?:serviceToken|ssecurity|passToken|haToken|bridgeToken|access_token|authorization)\s*[:=]\s*[^\s,;)"']+/gi;

export function redactSensitiveText(raw: string,
  extraForbiddenLiterals: readonly string[] = [],
): string { let out = raw;
  for (const literal of extraForbiddenLiterals) { const trimmed = literal.trim();
    if (trimmed.length >= 2) { out = out.split(trimmed).join("[redacted]");
    }
  }
  out = out
    .replace(SECRET_KV_PATTERN, "[redacted-secret]")
    .replace(JWT_PATTERN, "[redacted-jwt]")
    .replace(BEARER_OR_API_KEY_PATTERN, "[redacted-token]")
    .replace(URL_SCHEME_PATTERN, "[redacted-url]")
    .replace(MAC_ADDRESS_PATTERN, "[redacted-mac]")
    .replace(PRIVATE_OR_LAN_IPV4_PATTERN, "[redacted-ip]")
    .replace(ANY_IPV4_PATTERN, "[redacted-ip]")
    .replace(PRIVATE_IPV6_PATTERN, "[redacted-ip]")
    .replace(MI_ACCOUNT_ID_PATTERN, "[redacted-account]")
    .replace(MIOT_DID_PREFIX_PATTERN, "[redacted-did]")
    .replace(LONG_NUMERIC_ID_PATTERN, "[redacted-id]")
    .replace(LONG_OPAQUE_TOKEN_PATTERN, (candidate) => {
      if (candidate.includes(".")) return candidate;
      return "[redacted-token]";
    });
  return out;
}

export function findSensitiveLeaks(text: string,
  options: { readonly allowGitHubIssueURL?: boolean } = {},
): string[] { const target = options.allowGitHubIssueURL
    ? text.replace(/^https:\/\/github\.com\/jryang2026-code\/MenuBarHome\/issues\/new\?/, "")
    : text;

  const leaks: string[] = [];
  const check = (label: string, regex: RegExp) => { const clone = new RegExp(regex.source, regex.flags);
    const match = clone.exec(target);
    if (match) { leaks.push(`${label}:${match[0].slice(0, 24)}`);
    }
  };

  check("jwt", JWT_PATTERN);
  check("token", BEARER_OR_API_KEY_PATTERN);
  check("secret_kv", SECRET_KV_PATTERN);
  check("url", URL_SCHEME_PATTERN);
  check("mac", MAC_ADDRESS_PATTERN);
  check("private_ipv4", PRIVATE_OR_LAN_IPV4_PATTERN);
  check("ipv4", ANY_IPV4_PATTERN);
  check("private_ipv6", PRIVATE_IPV6_PATTERN);
  check("mi_account", MI_ACCOUNT_ID_PATTERN);
  check("miot_did", MIOT_DID_PREFIX_PATTERN);
  check("numeric_id", LONG_NUMERIC_ID_PATTERN);
  return leaks;
}

export function assertZeroSensitiveLeaks(text: string,
  options: { readonly allowGitHubIssueURL?: boolean } = {},
): void { const leaks = findSensitiveLeaks(text, options);
  if (leaks.length > 0) { throw new Error(`Diagnostics privacy check failed (${leaks.join(", ")})`);
  }
}

export interface SanitizedMiotSpecSummary { readonly urnType: string;
  readonly deviceType: string;
  readonly serviceNames: readonly string[];
  readonly propertyCount: number;
  readonly readablePropertyCount: number;
  readonly writablePropertyCount: number;
  readonly actionCount: number;
}

export function summarizeMiotSpec(spec: MiotDeviceSpec): SanitizedMiotSpecSummary { const serviceNames: string[] = [];
  let propertyCount = 0;
  let readablePropertyCount = 0;
  let writablePropertyCount = 0;
  let actionCount = 0;

  for (const svc of spec.services) { const short = miotShortName(svc.type);
    if (short && short !== "device-information" && !serviceNames.includes(short)) { serviceNames.push(short);
    }
    if (short === "device-information") continue;
    propertyCount += svc.properties.length;
    for (const prop of svc.properties) { if (prop.access.includes("read") || prop.access.includes("notify")) {
        readablePropertyCount += 1;
      }
      if (prop.access.includes("write")) { writablePropertyCount += 1;
      }
    }
    actionCount += svc.actions.length;
  }

  return {
    urnType: redactSensitiveText(spec.type),
    deviceType: redactSensitiveText(miotShortName(spec.type)),
    serviceNames: serviceNames.map((s) => redactSensitiveText(s)),
    propertyCount,
    readablePropertyCount,
    writablePropertyCount,
    actionCount,
  };
}

export function formatSpecSummaryText(summary: SanitizedMiotSpecSummary,
  preference?: LanguagePreference,
): string { const services = summary.serviceNames.length > 0 ? summary.serviceNames.join(", ") : "none";
  return tr3("MIoT 规格摘要：type={deviceType}，服务=[{services}]，属性={props}（可读 {readable} / 可写 {writable}），动作={actions}",
    "MIoT 規格摘要：type={deviceType}，服務=[{services}]，屬性={props}（可讀 {readable} / 可寫 {writable}），動作={actions}",
    "MIoT Spec Summary: type={deviceType}, services=[{services}], props={props} (read {readable} / write {writable}), actions={actions}",
    {
      deviceType: summary.deviceType || "unknown",
      services,
      props: summary.propertyCount,
      readable: summary.readablePropertyCount,
      writable: summary.writablePropertyCount,
      actions: summary.actionCount,
    },
    preference,
  );
}

export type UnsupportedDeviceReason = | "unknownModel"
  | "noControllableItems"
  | "unsupportedEntities"
  | "noActiveEntities"
  | "deviceDisabled"
  | "filteredDuplicate";

export function unsupportedReasonText(reason: UnsupportedDeviceReason,
  preference?: LanguagePreference,
): string { switch (reason) { case "unknownModel":
      return tr3("没有取到米家设备规格",
        "沒有取得米家裝置規格",
        "No Xiaomi device spec for this model",
        undefined,
        preference,
      );
    case "noControllableItems":
      return tr3("该设备没有向云端开放可控项",
        "該裝置沒有向雲端開放可控項目",
        "This device exposes no controllable items to the cloud",
        undefined,
        preference,
      );
    case "unsupportedEntities":
      return tr3("实体类型暂不支持",
        "實體類型暫不支援",
        "Entity type not supported yet",
        undefined,
        preference,
      );
    case "noActiveEntities":
      return tr3("实体已在 Home Assistant 中禁用或隐藏",
        "實體已在 Home Assistant 中停用或隱藏",
        "Entities are disabled or hidden in Home Assistant",
        undefined,
        preference,
      );
    case "deviceDisabled":
      return tr3("设备已在 Home Assistant 中禁用",
        "裝置已在 Home Assistant 中停用",
        "Device is disabled in Home Assistant",
        undefined,
        preference,
      );
    case "filteredDuplicate":
      return tr3("重复发现或网关指示灯，已按设计跳过",
        "重複發現或網關指示燈，已按設計略過",
        "Duplicate discovery or gateway indicator, skipped by design",
        undefined,
        preference,
      );
  }
}

export interface UnsupportedDevice {
    readonly id: string;
  readonly name: string;
  readonly model: string;
  readonly reason: UnsupportedDeviceReason;
  readonly reasonText: string;
  readonly specSummary?: SanitizedMiotSpecSummary | null;
  readonly feedbackURL?: string | null;
}

function sanitizeDeviceLabel(rawName: string,
  model: string,
  forbiddenLiterals: readonly string[] = [],
  preference?: LanguagePreference,
): string { const scrubbed = redactSensitiveText(rawName, forbiddenLiterals)
    .replace(/\[redacted(?:-[a-z]+)?\]/gi, "")
    .replace(/\s+/g, " ")
    .trim();
  if (scrubbed !== "") return scrubbed;
  if (model.trim() !== "") return redactSensitiveText(model.trim(), forbiddenLiterals);
  return tr3("未命名设备", "未命名裝置", "Unnamed Device", undefined, preference);
}

function encodeFormQueryParam(value: string): string {
  return encodeURIComponent(value)
    .replace(/\+/g, "%2B")
    .replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

export const UnsupportedDeviceFeedbackURL = {
    make(device: Pick<UnsupportedDevice, "name" | "model" | "reason" | "specSummary"> & { readonly id?: string;
    },
    options: { readonly platform?: "Windows" | "macOS";
      readonly forbiddenLiterals?: readonly string[];
      readonly languagePreference?: LanguagePreference;
    } = {},
  ): string | null { const backend = this.backendOptionForReason(device.reason);
    if (backend === null) return null;

    const platform = options.platform ?? "Windows";
    const pref = options.languagePreference;
    const forbidden = [
      ...(device.id ? [device.id] : []),
      ...(options.forbiddenLiterals ?? []),
    ];
    const cleanModel = redactSensitiveText(device.model.trim(), forbidden);
    const cleanName = sanitizeDeviceLabel(device.name, cleanModel, forbidden, pref);

    const title = tr3("[设备不支持] {name} ({model})",
      "[裝置不支援] {name} ({model})",
      "[Unsupported device] {name} ({model})",
      { name: cleanName, model: cleanModel || "unknown" },
      pref,
    );

    const reasonLine = unsupportedReasonText(device.reason, pref);
    const specLine = device.specSummary
      ? `\n${formatSpecSummaryText(device.specSummary, pref)}`
      : "";
    const promptLine = tr3("期望支持的功能（开关、亮度、温度…）：",
      "期望支援的功能（開關、亮度、溫度…）：",
      "What should it support (power, brightness, temperature…):",
      undefined,
      pref,
    );
    const symptom = `${reasonLine}${specLine}\n\n${promptLine}`;

    const params: ReadonlyArray<readonly [string, string]> = [
      ["template", "unsupported_device.yml"],
      ["title", title],
      ["platform", platform],
      ["backend", backend],
      ["model", cleanModel],
      ["symptom", symptom],
    ];

    const query = params
      .map(([k, v]) => `${encodeFormQueryParam(k)}=${encodeFormQueryParam(v)}`)
      .join("&");
    const fullUrl = `${GITHUB_UNSUPPORTED_DEVICE_ISSUE_URL}?${query}`;
    assertZeroSensitiveLeaks(decodeURIComponent(query));
    return fullUrl;
  },

    backendOptionForReason(reason: UnsupportedDeviceReason): string | null { switch (reason) { case "unknownModel":
      case "noControllableItems":
        return "小米云（扫码登录）";
      case "unsupportedEntities":
        return "Home Assistant";
      case "noActiveEntities": case "deviceDisabled": case "filteredDuplicate":
        return null;
    }
  },
} as const;

function sortUnsupportedDevices(devices: UnsupportedDevice[]): UnsupportedDevice[] {
  return [...devices].sort((a, b) => { if (a.name !== b.name) return a.name < b.name ? -1 : 1;
    return a.model < b.model ? -1 : a.model > b.model ? 1 : 0;
  });
}

function isDoorbellEventState(state: Record<string, unknown> | undefined): boolean { if (!state) return false;
  const entityId = typeof state["entityId"] === "string"
    ? state["entityId"]
    : typeof state["entity_id"] === "string"
      ? state["entity_id"]
      : "";
  if (!entityId.startsWith("event.")) return false;
  const attrs = state["attributes"] && typeof state["attributes"] === "object"
      ? (state["attributes"] as Record<string, unknown>)
      : {};
  if (attrs["device_class"] === "doorbell") return true;
  if (Array.isArray(attrs["event_types"])) { return attrs["event_types"].some(
      (t) => typeof t === "string" && (t === "ring" || t.includes("doorbell")),
    );
  }
  return false;
}

export const UnsupportedDeviceCollector = {
  miCloud(devices: readonly MiDeviceRecord[],
    specs: Readonly<Record<string, MiotDeviceSpec>>,
    synthesized: SynthesizedHome,
    options: { readonly rooms?: readonly MiRoom[];
      readonly forbiddenLiterals?: readonly string[];
      readonly languagePreference?: LanguagePreference;
    } = {},
  ): UnsupportedDevice[] { const splitParents = new Set(devices
        .map((d) => d.splitParentDid)
        .filter((x): x is string => typeof x === "string" && x.length > 0),
    );
    const synthesizedIds = new Set(synthesized.devices.map((d) => d.id));
    const synthesizedBaseDids = new Set(synthesized.devices.map((d) => d.id.replace(/\.s\d+$/, "")),
    );
    const homeNames = (options.rooms ?? [])
      .map((r) => r.homeName?.trim() ?? "")
      .filter((n) => n.length > 0);
    const baseForbidden = [...homeNames, ...(options.forbiddenLiterals ?? [])];

    const out: UnsupportedDevice[] = [];
    for (const record of devices) { if (splitParents.has(record.did)) continue;
      const candidateSpec = specs[record.model];
      const realSpec = candidateSpec && !isFallbackSpec(candidateSpec) ? candidateSpec : undefined;
      if (realSpec &&
        (synthesizedIds.has(record.did) || synthesizedBaseDids.has(record.did))
      ) { continue;
      }
      const reason: UnsupportedDeviceReason = realSpec
        ? "noControllableItems"
        : "unknownModel";
      const specSummary = realSpec ? summarizeMiotSpec(realSpec) : null;
      const forbidden = [
        ...baseForbidden,
        record.did,
        ...(record.mac ? [record.mac] : []),
        ...(record.localIp ? [record.localIp] : []),
      ];
      const cleanName = sanitizeDeviceLabel(record.name,
        record.model,
        forbidden,
        options.languagePreference,
      );
      const cleanModel = redactSensitiveText(record.model, forbidden);
      const feedbackURL = UnsupportedDeviceFeedbackURL.make({
          id: record.did,
          name: cleanName,
          model: cleanModel,
          reason,
          specSummary,
        },
        {
          forbiddenLiterals: forbidden,
          languagePreference: options.languagePreference,
        },
      );
      out.push({
        id: record.did,
        name: cleanName,
        model: cleanModel,
        reason,
        reasonText: unsupportedReasonText(reason, options.languagePreference),
        specSummary,
        feedbackURL,
      });
    }
    return sortUnsupportedDevices(out);
  },

  homeAssistant(rawSnapshot: unknown,
    synthesized: SynthesizedHome,
    options: { readonly forbiddenLiterals?: readonly string[];
      readonly languagePreference?: LanguagePreference;
    } = {},
  ): UnsupportedDevice[] { if (!rawSnapshot || typeof rawSnapshot !== "object" || Array.isArray(rawSnapshot)) {
      return [];
    }
    const snap = rawSnapshot as Record<string, unknown>;
    const rawDevices = Array.isArray(snap["devices"]) ? snap["devices"] : [];
    const rawEntities = Array.isArray(snap["entities"]) ? snap["entities"] : [];
    const rawStates = Array.isArray(snap["states"]) ? snap["states"] : [];

    const statesById = new Map<string, Record<string, unknown>>();
    for (const st of rawStates) { if (st && typeof st === "object" && !Array.isArray(st)) {
        const rec = st as Record<string, unknown>;
        const eid = typeof rec["entity_id"] === "string"
            ? rec["entity_id"]
            : typeof rec["entityId"] === "string"
              ? rec["entityId"]
              : "";
        if (eid) statesById.set(eid, rec);
      }
    }

    const synthesizedIds = new Set(synthesized.devices.map((d) => d.id));
    const activeEntitiesByDevice = new Map<string, number>();
    const doorbellDevices = new Set<string>();

    for (const ent of rawEntities) { if (!ent || typeof ent !== "object" || Array.isArray(ent)) continue;
      const rec = ent as Record<string, unknown>;
      if (rec["disabled_by"] != null || rec["hidden_by"] != null) continue;
      const devId = typeof rec["device_id"] === "string" ? rec["device_id"] : "";
      if (!devId) continue;
      const entityId = typeof rec["entity_id"] === "string" ? rec["entity_id"] : "";
      if (entityId && isDoorbellEventState(statesById.get(entityId))) { doorbellDevices.add(devId);
        continue;
      }
      activeEntitiesByDevice.set(devId, (activeEntitiesByDevice.get(devId) ?? 0) + 1);
    }

    const out: UnsupportedDevice[] = [];
    for (const dev of rawDevices) { if (!dev || typeof dev !== "object" || Array.isArray(dev)) continue;
      const rec = dev as Record<string, unknown>;
      const id = typeof rec["id"] === "string" ? rec["id"] : "";
      if (!id) continue;
      const rawName = typeof rec["name_by_user"] === "string" && rec["name_by_user"].trim() !== ""
          ? rec["name_by_user"]
          : typeof rec["name"] === "string" && rec["name"].trim() !== ""
            ? rec["name"]
            : tr3("未命名设备",
                "未命名裝置",
                "Unnamed Device",
                undefined,
                options.languagePreference,
              );
      const model = typeof rec["model"] === "string" ? rec["model"] : "";
      const forbidden = [id, ...(options.forbiddenLiterals ?? [])];

      let reason: UnsupportedDeviceReason | null = null;
      if (rec["disabled_by"] != null) { reason = "deviceDisabled";
      } else if (model === "hyperDLNA" ||
        model.startsWith("Apple TV") ||
        model.startsWith("lumi.gateway")
      ) { reason = "filteredDuplicate";
      } else { const activeCount = activeEntitiesByDevice.get(id) ?? 0;
        if (activeCount === 0 && doorbellDevices.has(id)) { continue;
        } else if (activeCount === 0) { reason = "noActiveEntities";
        } else { const shownAsSplit = [...synthesizedIds].some((sid) =>
            sid.startsWith(`${id}#`),
          );
          if (!synthesizedIds.has(id) && !shownAsSplit) { reason = "unsupportedEntities";
          }
        }
      }

      if (!reason) continue;
      const cleanModel = redactSensitiveText(model, forbidden);
      const cleanName = sanitizeDeviceLabel(rawName,
        cleanModel,
        forbidden,
        options.languagePreference,
      );
      out.push({
        id,
        name: cleanName,
        model: cleanModel,
        reason,
        reasonText: unsupportedReasonText(reason, options.languagePreference),
        specSummary: null,
        feedbackURL: UnsupportedDeviceFeedbackURL.make({ id, name: cleanName, model: cleanModel, reason },
          {
            forbiddenLiterals: forbidden,
            languagePreference: options.languagePreference,
          },
        ),
      });
    }

    return sortUnsupportedDevices(out);
  },
} as const;

export interface UnsupportedScanContext { readonly backend: HomeBackend | "demo" | "dualSource";
  readonly miAccountIds: readonly string[];
  readonly haBaseURL: string;
}

export interface ScanUnsupportedOptions { readonly connectionMode?: HomeBackend | "demo";
  readonly dualSourceEnabled?: boolean;
  readonly miAccounts?: readonly MiAccount[];
  readonly miSessions?: readonly MiSession[];
  readonly transport?: HttpTransport;
  readonly specResolver?: MiotSpecResolver;
  readonly haBaseURL?: string;
  readonly haToken?: string;
  readonly haInvoke?: HAInvoke;
  readonly languagePreference?: LanguagePreference;
  readonly clientFactory?: (session: MiSession, transport: HttpTransport) => MiCloudClient;
}

export interface ScanUnsupportedResult { readonly devices: UnsupportedDevice[];
  readonly miHomeCount: number | null;
  readonly miSharedHomeCount: number | null;
  readonly errors: readonly string[];
  readonly scannedAtMs: number;
}

async function fetchRawSpecByUrn(specType: string,
  transport: HttpTransport,
): Promise<MiotDeviceSpec | null> { try {
    const url = `https://miot-spec.org/miot-spec-v2/instance?type=${encodeURIComponent(specType)}`;
    const resp = await transport({ url, method: "GET", timeoutMs: 8_000 });
    if (resp.status < 200 || resp.status >= 300) return null;
    const json: unknown = JSON.parse(resp.body);
    return parseMiotDeviceSpec(json);
  } catch { return null;
  }
}

export class UnsupportedDeviceScanner { public devices: UnsupportedDevice[] = [];
  public isScanning = false;
  public errorMessage: string | null = null;
  public lastScannedAtMs: number | null = null;
  public miHomeCount: number | null = null;
  public miSharedHomeCount: number | null = null;
  private lastContextKey: string | null = null;
  private scanGeneration = 0;

  reset(): void { this.scanGeneration += 1;
    this.devices = [];
    this.errorMessage = null;
    this.lastScannedAtMs = null;
    this.miHomeCount = null;
    this.miSharedHomeCount = null;
    this.lastContextKey = null;
    this.isScanning = false;
  }

  invalidateIfContextChanged(options: ScanUnsupportedOptions): void {
    const nextKey = UnsupportedDeviceScanner.contextKey(options);
    if (this.lastContextKey !== null && this.lastContextKey !== nextKey) { this.reset();
    }
  }

  static contextKey(options: ScanUnsupportedOptions): string { const accounts = options.miAccounts
      ? options.miAccounts.map((a) => a.id)
      : (options.miSessions ?? []).map((s) => makeMiAccount(s).id);
    return JSON.stringify({
      mode: options.connectionMode ?? "xiaomiCloud",
      dual: Boolean(options.dualSourceEnabled),
      mi: accounts,
      ha: (options.haBaseURL ?? "").trim().replace(/\/+$/, "").toLowerCase(),
    });
  }

  async scan(options: ScanUnsupportedOptions): Promise<ScanUnsupportedResult> {
    this.invalidateIfContextChanged(options);
    const generation = ++this.scanGeneration;
    this.lastContextKey = UnsupportedDeviceScanner.contextKey(options);
    this.isScanning = true;
    this.errorMessage = null;

    if (options.connectionMode === "demo") { this.isScanning = false;
      this.devices = [];
      this.lastScannedAtMs = Date.now();
      return {
        devices: [],
        miHomeCount: null,
        miSharedHomeCount: null,
        errors: [],
        scannedAtMs: this.lastScannedAtMs,
      };
    }

    const accounts: MiAccount[] = options.miAccounts
      ? [...options.miAccounts]
      : (options.miSessions ?? []).map((s) => makeMiAccount(s));
    const hasMi = accounts.length > 0;
    const hasHA = Boolean(options.haBaseURL?.trim() && options.haToken?.trim() && options.haInvoke,
    );
    const scanMi = hasMi &&
      (Boolean(options.dualSourceEnabled) ||
        options.connectionMode !== "homeAssistant" ||
        !hasHA);
    const scanHA = hasHA &&
      (Boolean(options.dualSourceEnabled) ||
        options.connectionMode === "homeAssistant" ||
        !hasMi);

    const collected: UnsupportedDevice[] = [];
    const errors: string[] = [];
    const seenMiDids = new Set<string>();
    const seenHomeScopes = new Set<string>();
    const seenSharedHomeScopes = new Set<string>();

    try { if (scanMi) { if (!options.transport) { throw new Error("Missing HTTP transport for Xiaomi Cloud scan");
        }
        const transport = options.transport;
        const specResolver = options.specResolver ?? new MiotSpecResolver(transport);
        const clientFactory = options.clientFactory ?? ((session, tp) => new MiCloudClient(session, tp));

        for (const account of accounts) { try { const client = clientFactory(account.session, transport);
            const discovery = await discoverMiAccountDevicesAndRooms(client);
            for (const room of discovery.rooms) { if (room.homeId) { const scopedHome = `${account.id}/${room.homeId}`;
                seenHomeScopes.add(scopedHome);
                if (room.isSharedHome) seenSharedHomeScopes.add(scopedHome);
              }
            }

            const resolvedSpecs = await specResolver.resolveForDevices(discovery.devices);
            const specs: Record<string, MiotDeviceSpec> = {};
            for (const [model, spec] of Object.entries(resolvedSpecs)) { if (!isFallbackSpec(spec)) specs[model] = spec;
            }
            for (const rec of discovery.devices) { if (!specs[rec.model] && rec.specType) {
                const fetched = await fetchRawSpecByUrn(rec.specType, transport);
                if (fetched && !isFallbackSpec(fetched)) specs[rec.model] = fetched;
              }
            }

            const recordsWithRealSpec = discovery.devices.filter((d) => Boolean(specs[d.model]));
            const home = MiotSynthesizer.synthesize(recordsWithRealSpec,
              discovery.rooms,
              specs,
              new Map<string, unknown>(),
            );
            const forbidden = [
              account.id,
              account.session.userId,
              account.session.cUserId,
              account.session.serviceToken,
              account.session.ssecurity,
            ].filter((x) => x.length > 0);
            const accountSkipped = UnsupportedDeviceCollector.miCloud(discovery.devices,
              specs,
              home,
              {
                rooms: discovery.rooms,
                forbiddenLiterals: forbidden,
                languagePreference: options.languagePreference,
              },
            );
            for (const item of accountSkipped) { if (!seenMiDids.has(item.id)) { seenMiDids.add(item.id);
                collected.push(item);
              }
            }
          } catch (err) { const msg = err instanceof Error ? err.message : String(err);
            errors.push(redactSensitiveText(msg, [account.id, account.session.userId]));
          }
        }
      }

      if (scanHA && options.haInvoke && options.haBaseURL && options.haToken) { try {
          const rawHA = await options.haInvoke<unknown>("ha_snapshot", {
            baseUrl: options.haBaseURL,
            token: options.haToken,
          });
          const synthesizedHA = HomeAssistantSynthesizer.synthesize(rawHA);
          const haSkipped = UnsupportedDeviceCollector.homeAssistant(rawHA,
            synthesizedHA,
            {
              forbiddenLiterals: [options.haBaseURL, options.haToken],
              languagePreference: options.languagePreference,
            },
          );
          collected.push(...haSkipped);
        } catch (err) { const msg = err instanceof Error ? err.message : String(err);
          errors.push(redactSensitiveText(msg, [options.haBaseURL, options.haToken]),
          );
        }
      }

      const sorted = sortUnsupportedDevices(collected);
      const scannedAtMs = Date.now();
      const miHomeCount = scanMi ? seenHomeScopes.size : null;
      const miSharedHomeCount = scanMi ? seenSharedHomeScopes.size : null;

      if (this.scanGeneration === generation) { this.devices = sorted;
        this.miHomeCount = miHomeCount;
        this.miSharedHomeCount = miSharedHomeCount;
        this.errorMessage = errors[0] ?? null;
        this.lastScannedAtMs = scannedAtMs;
        this.isScanning = false;
      }
      return {
        devices: sorted,
        miHomeCount,
        miSharedHomeCount,
        errors,
        scannedAtMs,
      };
    } finally { if (this.scanGeneration === generation) { this.isScanning = false;
      }
    }
  }
}

export type DiagnosticsErrorCategory = | "miCloud"
  | "homeAssistant"
  | "camera"
  | "command"
  | "auth"
  | "rateLimit"
  | "network"
  | "unknown";

export interface DiagnosticsErrorSnapshot { readonly timestampMs: number;
  readonly category: DiagnosticsErrorCategory;
  readonly statusCode?: number | null;
  readonly summary: string;
}

export class DiagnosticsLog { private entries: DiagnosticsErrorSnapshot[] = [];
  private lastDedupeKey: string | null = null;

  constructor(private readonly storage: Storage | null = defaultStorage(),
    private readonly capacity: number = DIAGNOSTICS_RING_BUFFER_CAPACITY,
  ) { this.entries = this.loadFromStorage();
  }

  getSnapshots(): readonly DiagnosticsErrorSnapshot[] { return [...this.entries];
  }

  count(): number { return this.entries.length;
  }

  lastErrorAtMs(): number | null { return this.entries.length > 0
      ? (this.entries[this.entries.length - 1]?.timestampMs ?? null)
      : null;
  }

  categoryCounts(): Record<DiagnosticsErrorCategory, number> {
    const counts: Record<DiagnosticsErrorCategory, number> = {
      miCloud: 0,
      homeAssistant: 0,
      camera: 0,
      command: 0,
      auth: 0,
      rateLimit: 0,
      network: 0,
      unknown: 0,
    };
    for (const item of this.entries) { counts[item.category] = (counts[item.category] ?? 0) + 1;
    }
    return counts;
  }

  record(input: { readonly error?: unknown;
    readonly summary?: string;
    readonly category?: DiagnosticsErrorCategory;
    readonly statusCode?: number | null;
    readonly timestampMs?: number;
    readonly dedupeId?: string;
    readonly forbiddenLiterals?: readonly string[];
  }): DiagnosticsErrorSnapshot | null { if (input.dedupeId && input.dedupeId === this.lastDedupeKey) { return null;
    }
    if (input.dedupeId) { this.lastDedupeKey = input.dedupeId;
    }

    const rawText = input.summary ??
      (input.error instanceof Error
        ? input.error.message
        : input.error !== undefined
          ? String(input.error)
          : "error");
    const inferredCategory: DiagnosticsErrorCategory = input.category ??
      (isXiaomiRateLimitError(input.error) ? "rateLimit" : "unknown");
    const sanitizedSummary = redactSensitiveText(rawText,
      input.forbiddenLiterals ?? [],
    ).slice(0, 160);

    const snapshot: DiagnosticsErrorSnapshot = {
      timestampMs: input.timestampMs ?? Date.now(),
      category: inferredCategory,
      ...(typeof input.statusCode === "number"
        ? { statusCode: input.statusCode }
        : {}),
      summary: sanitizedSummary,
    };

    this.entries.push(snapshot);
    if (this.entries.length > this.capacity) { this.entries.splice(0, this.entries.length - this.capacity);
    }
    this.saveToStorage();
    return snapshot;
  }

  clear(): void { this.entries = [];
    this.lastDedupeKey = null;
    if (this.storage) { try { this.storage.removeItem(DIAGNOSTICS_RING_STORAGE_KEY);
      } catch {
      }
    }
  }

  private loadFromStorage(): DiagnosticsErrorSnapshot[] { if (!this.storage) return [];
    try { const raw = this.storage.getItem(DIAGNOSTICS_RING_STORAGE_KEY);
      if (!raw) return [];
      const parsed: unknown = JSON.parse(raw);
      if (!Array.isArray(parsed)) return [];
      const valid: DiagnosticsErrorSnapshot[] = [];
      for (const item of parsed) { if (!item || typeof item !== "object" || Array.isArray(item)) continue;
        const rec = item as Record<string, unknown>;
        const ts = rec["timestampMs"];
        const cat = rec["category"];
        if (typeof ts !== "number" || !Number.isFinite(ts)) continue;
        const category: DiagnosticsErrorCategory = cat === "miCloud" ||
          cat === "homeAssistant" ||
          cat === "camera" ||
          cat === "command" ||
          cat === "auth" ||
          cat === "rateLimit" ||
          cat === "network"
            ? cat
            : "unknown";
        valid.push({
          timestampMs: ts,
          category,
          ...(typeof rec["statusCode"] === "number"
            ? { statusCode: rec["statusCode"] }
            : {}),
          summary: typeof rec["summary"] === "string"
              ? redactSensitiveText(rec["summary"]).slice(0, 160)
              : category,
        });
      }
      return valid.slice(-this.capacity);
    } catch { return [];
    }
  }

  private saveToStorage(): void { if (!this.storage) return;
    try {
      const minimal = this.entries.map((e) => ({
        timestampMs: e.timestampMs,
        category: e.category,
        ...(e.statusCode !== undefined ? { statusCode: e.statusCode } : {}),
      }));
      this.storage.setItem(DIAGNOSTICS_RING_STORAGE_KEY, JSON.stringify(minimal));
    } catch {
    }
  }
}

export const appDiagnosticsLog = new DiagnosticsLog();

export type CameraStreamMode = | "xiaomi_p2p_mjpeg"
  | "xiaomi_gateway_p2p_mjpeg"
  | "ha_hls_bridge_mjpeg"
  | "ha_proxy_mjpeg"
  | "custom_stream"
  | "direct_video"
  | "idle";

export type CameraAudioSupport = | "none_mjpeg"
  | "muted_video"
  | "active_video"
  | "unsupported";

export interface CameraDiagnosticsEntry { readonly model: string;
  readonly streamMode: CameraStreamMode;
  readonly audioSupport: CameraAudioSupport;
  readonly lensCount?: number;
  readonly isOnline?: boolean;
}

export function deriveCameraDiagnostics(devices: readonly SmartDevice[],
  options: { readonly defaultBackend?: HomeBackend | "demo";
    readonly deviceBackends?: Readonly<Record<string, HomeBackend>>;
    readonly customStreamDeviceIds?: ReadonlySet<string>;
    readonly activeLiveCameraId?: string | null;
    readonly activeLiveMode?: "mjpeg" | "video" | null;
    readonly activeLiveMuted?: boolean;
  } = {},
): CameraDiagnosticsEntry[] { const out: CameraDiagnosticsEntry[] = [];
  for (const dev of devices) { if (dev.kind.kind !== "camera") continue;
    const isLive = options.activeLiveCameraId === dev.id;
    const hasCustomUrl = options.customStreamDeviceIds?.has(dev.id) === true;
    const backend = options.deviceBackends?.[dev.id] ??
      (dev.kind.entityId.startsWith("miot:") ? "xiaomiCloud" : options.defaultBackend ?? "xiaomiCloud");

    let streamMode: CameraStreamMode;
    if (isLive && options.activeLiveMode === "video") { streamMode = "direct_video";
    } else if (hasCustomUrl) { streamMode = "custom_stream";
    } else if (backend === "homeAssistant") { streamMode = dev.kind.streamEntityId
        ? "ha_hls_bridge_mjpeg"
        : "ha_proxy_mjpeg";
    } else if (dev.kind.gatewayModel) { streamMode = "xiaomi_gateway_p2p_mjpeg";
    } else { streamMode = "xiaomi_p2p_mjpeg";
    }

    const audioSupport: CameraAudioSupport = streamMode === "direct_video"
        ? options.activeLiveMuted !== false
          ? "muted_video"
          : "active_video"
        : "none_mjpeg";

    out.push({
      model: redactSensitiveText(dev.model || "unknown"),
      streamMode,
      audioSupport,
      lensCount: dev.kind.lenses?.length ?? 1,
      isOnline: dev.isOnline,
    });
  }
  return out;
}

export interface PollingBackoffDiagnostics { readonly active: boolean;
  readonly remainingSeconds: number;
  readonly cadenceSeconds?: number | null;
  readonly pausedReason?: "workstation_locked" | "session_expired" | "demo_offline" | null;
}

export function derivePollingBackoffDiagnostics(options: { readonly host?: object | null;
  readonly primarySession?: MiSession | null;
  readonly accountBackoffUntilMs?: readonly (number | null)[];
  readonly cadenceMs?: number | null;
  readonly workstationLocked?: boolean;
  readonly sessionExpired?: boolean;
  readonly isDemo?: boolean;
  readonly nowMs?: number;
}): PollingBackoffDiagnostics { const nowMs = options.nowMs ?? Date.now();
  const untilCandidates: number[] = [];
  if (options.host && options.primarySession) {
    const primaryUntil = getXiaomiBackoffUntilMs(options.host, options.primarySession);
    if (primaryUntil !== null && primaryUntil > nowMs) { untilCandidates.push(primaryUntil);
    }
  }
  for (const until of options.accountBackoffUntilMs ?? []) { if (typeof until === "number" && until > nowMs) {
      untilCandidates.push(until);
    }
  }
  const maxUntil = untilCandidates.length > 0 ? Math.max(...untilCandidates) : null;
  const pausedReason = options.isDemo
    ? "demo_offline"
    : options.workstationLocked
      ? "workstation_locked"
      : options.sessionExpired
        ? "session_expired"
        : null;

  return {
    active: maxUntil !== null,
    remainingSeconds: maxUntil !== null ? Math.max(1, Math.ceil((maxUntil - nowMs) / 1000)) : 0,
    cadenceSeconds: typeof options.cadenceMs === "number" && options.cadenceMs > 0
        ? Math.round(options.cadenceMs / 1000)
        : null,
    pausedReason,
  };
}

export interface DiagnosticsModelCount { readonly model: string;
  readonly count: number;
}

export function summarizeModelCounts(devices: readonly SmartDevice[],
): DiagnosticsModelCount[] { const map = new Map<string, number>();
  for (const dev of devices) { const key = redactSensitiveText(dev.model.trim());
    map.set(key, (map.get(key) ?? 0) + 1);
  }
  return [...map.entries()]
    .map(([model, count]) => ({ model, count }))
    .sort((a, b) => (a.count !== b.count ? b.count - a.count : a.model < b.model ? -1 : 1));
}

export interface DiagnosticsReportInput { readonly appVersion: string;
  readonly buildNumber?: string;
  readonly osVersion?: string;
  readonly language?: AppLanguage;
  readonly languagePreference?: LanguagePreference;
  readonly backendTitle: string;
  readonly miCloudRegions?: readonly string[];
  readonly miAccountCount?: number | null;
  readonly miHomeCount?: number | null;
  readonly miSharedHomeCount?: number | null;
  readonly isMiHomeFiltered?: boolean;
  readonly deviceCount: number;
  readonly onlineDeviceCount: number;
  readonly hiddenDeviceCount: number;
  readonly models: readonly DiagnosticsModelCount[];
  readonly unsupported?: readonly UnsupportedDevice[];
  readonly cameras?: readonly CameraDiagnosticsEntry[];
  readonly pollingBackoff?: PollingBackoffDiagnostics;
  readonly recentErrorCount?: number;
  readonly lastErrorAtMs?: number | null;
  readonly errorSnapshots?: readonly DiagnosticsErrorSnapshot[];
  readonly extraSettings?: readonly string[];
  readonly forbiddenLiterals?: readonly string[];
}

function formatUtcMinuteStamp(timestampMs: number): string { const d = new Date(timestampMs);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} UTC`;
}

export const DiagnosticsReportBuilder = {
  markdown(input: DiagnosticsReportInput): string { const pref = input.languagePreference ?? input.language;
    const uiLang = input.language ??
      (pref !== undefined
        ? resolveLanguage(pref, globalThis.navigator?.languages ?? [])
        : resolveLanguage(currentLanguage(), []));
    const forbidden = input.forbiddenLiterals ?? [];

    const versionPart = input.buildNumber
      ? `${redactSensitiveText(input.appVersion, forbidden)} (${redactSensitiveText(input.buildNumber, forbidden)})`
      : redactSensitiveText(input.appVersion, forbidden);
    const osPart = redactSensitiveText(input.osVersion ?? "Windows", forbidden);
    const backendPart = redactSensitiveText(input.backendTitle, forbidden);
    const regions = (input.miCloudRegions ?? [])
      .map((r) => normalizeMiCloudRegion(r))
      .filter((r, idx, arr) => arr.indexOf(r) === idx);

    const lines: string[] = [];
    lines.push(`## MenuBarHome ${tr3("诊断信息", "診斷資訊", "Diagnostics", undefined, uiLang)}`,
    );
    lines.push("");
    lines.push(`- ${tr3("版本", "版本", "Version", undefined, uiLang)}: ${versionPart}`,
    );
    lines.push(`- ${tr3("平台", "平台", "Platform", undefined, uiLang)}: ${osPart}`,
    );
    lines.push(`- ${tr3("语言", "語言", "Language", undefined, uiLang)}: ${uiLang}`,
    );
    lines.push(`- ${tr3("当前后端", "目前後端", "Backend", undefined, uiLang)}: ${backendPart}`,
    );

    if (regions.length > 0) { const accountSuffix = typeof input.miAccountCount === "number" && input.miAccountCount > 0
          ? ` (${tr3("已登录 {count} 个账号",
              "已登入 {count} 個帳號",
              "{count} account(s) signed in",
              { count: input.miAccountCount },
              uiLang,
            )})`
          : "";
      lines.push(
        `- ${tr3("米家地区", "米家地區", "Mi Cloud Region", undefined, uiLang)}: ${regions.join(", ")}${accountSuffix}`,
      );
    }

    if (typeof input.miHomeCount === "number") {
      let homeLine = `- ${tr3("米家家庭", "米家家庭", "Mi Homes", undefined, uiLang)}: ${input.miHomeCount}`;
      if (typeof input.miSharedHomeCount === "number" && input.miSharedHomeCount > 0) { homeLine += ` (${tr3(
          "共享 {count}",
          "共享 {count}",
          "shared {count}",
          { count: input.miSharedHomeCount },
          uiLang,
        )})`;
      }
      if (input.isMiHomeFiltered) { homeLine += ` · ${tr3("已筛选单个家庭",
          "已篩選單一家庭",
          "filtered to one home",
          undefined,
          uiLang,
        )}`;
      }
      lines.push(homeLine);
    }

    lines.push(
      `- ${tr3("设备", "裝置", "Devices", undefined, uiLang)}: ${input.deviceCount} (${tr3("在线", "在線", "online", undefined, uiLang)} ${input.onlineDeviceCount}, ${tr3("隐藏", "隱藏", "hidden", undefined, uiLang)} ${input.hiddenDeviceCount})`,
    );

    if (input.pollingBackoff) { const pb = input.pollingBackoff;
      let pbText: string;
      if (pb.active) { pbText = tr3("限流退避中（剩余 {seconds} 秒）",
          "限流退避中（剩餘 {seconds} 秒）",
          "Rate-limit backoff active ({seconds}s remaining)",
          { seconds: pb.remainingSeconds },
          uiLang,
        );
      } else if (pb.pausedReason === "workstation_locked") { pbText = tr3("已暂停（系统锁屏）",
          "已暫停（系統鎖屏）",
          "Paused (workstation locked)",
          undefined,
          uiLang,
        );
      } else if (pb.pausedReason === "session_expired") { pbText = tr3("已暂停（会话已过期）",
          "已暫停（工作階段已過期）",
          "Paused (session expired)",
          undefined,
          uiLang,
        );
      } else if (pb.pausedReason === "demo_offline") { pbText = tr3("离线演示（不轮询）",
          "離線展示（不輪詢）",
          "Offline demo (polling disabled)",
          undefined,
          uiLang,
        );
      } else if (typeof pb.cadenceSeconds === "number") { pbText = tr3("正常（间隔 {seconds} 秒）",
          "正常（間隔 {seconds} 秒）",
          "Normal ({seconds}s cadence)",
          { seconds: pb.cadenceSeconds },
          uiLang,
        );
      } else { pbText = tr3("正常", "正常", "Normal", undefined, uiLang);
      }
      lines.push(`- ${tr3("轮询与退避", "輪詢與退避", "Polling & Backoff", undefined, uiLang)}: ${pbText}`,
      );
    }

    if (input.extraSettings && input.extraSettings.length > 0) { const cleanExtra = input.extraSettings.map((s) =>
        redactSensitiveText(s, forbidden),
      );
      lines.push(`- ${tr3("设置", "設定", "Settings", undefined, uiLang)}: ${cleanExtra.join(" · ")}`,
      );
    }

    lines.push("");
    lines.push(`### ${tr3("设备型号", "裝置型號", "Device Models", undefined, uiLang)}`,
    );
    if (input.models.length === 0) { lines.push(`- ${tr3("暂无设备", "暫無裝置", "No devices", undefined, uiLang)}`);
    } else { const sortedModels = [...input.models].sort((a, b) =>
        a.count !== b.count ? b.count - a.count : a.model < b.model ? -1 : 1,
      );
      for (const entry of sortedModels) { const cleanModel = redactSensitiveText(entry.model.trim(), forbidden);
        const label = cleanModel === ""
            ? tr3("未知型号", "未知型號", "Unknown model", undefined, uiLang)
            : cleanModel;
        lines.push(`- \`${label}\`: ${entry.count}`);
      }
    }

    lines.push("");
    lines.push(`### ${tr3("未能显示在面板的设备",
        "未能顯示在面板的裝置",
        "Devices Not Shown in the Panel",
        undefined,
        uiLang,
      )}`,
    );
    const unsupported = input.unsupported ?? [];
    if (unsupported.length === 0) { lines.push(`- ${tr3("未发现", "未發現", "None found", undefined, uiLang)}`);
    } else { for (const dev of unsupported) { const itemForbidden = [...forbidden, dev.id];
        const cleanModel = redactSensitiveText(dev.model.trim(), itemForbidden);
        const modelLabel = cleanModel === ""
            ? tr3("未知型号", "未知型號", "Unknown model", undefined, uiLang)
            : cleanModel;
        const reason = unsupportedReasonText(dev.reason, uiLang);
        const specSuffix = dev.specSummary
          ? ` · type=\`${redactSensitiveText(dev.specSummary.deviceType, itemForbidden)}\` (props=${dev.specSummary.propertyCount}, writable=${dev.specSummary.writablePropertyCount}, actions=${dev.specSummary.actionCount})`
          : "";
        lines.push(`- \`${modelLabel}\` — ${reason}${specSuffix}`);
      }
    }

    lines.push("");
    lines.push(`### ${tr3("摄像机诊断", "攝影機診斷", "Camera Diagnostics", undefined, uiLang)}`,
    );
    const cameras = input.cameras ?? [];
    if (cameras.length === 0) { lines.push(`- ${tr3("无摄像机设备", "無攝影機裝置", "No cameras", undefined, uiLang)}`);
    } else { for (const cam of cameras) { const cleanModel = redactSensitiveText(cam.model.trim(), forbidden) ||
          tr3("未知型号", "未知型號", "Unknown model", undefined, uiLang);
        const lensPart = typeof cam.lensCount === "number" && cam.lensCount > 1
            ? `, lenses=${cam.lensCount}`
            : "";
        lines.push(
          `- \`${cleanModel}\`: stream_mode=\`${cam.streamMode}\`, audio_support=\`${cam.audioSupport}\`${lensPart}`,
        );
      }
    }

    lines.push("");
    lines.push(`### ${tr3("近期错误", "近期錯誤", "Recent Errors", undefined, uiLang)}`,
    );
    const snapshots = (input.errorSnapshots ?? []).slice(-DIAGNOSTICS_RING_BUFFER_CAPACITY,
    );
    const errorCount = input.recentErrorCount !== undefined
        ? Math.min(DIAGNOSTICS_RING_BUFFER_CAPACITY, Math.max(0, input.recentErrorCount))
        : snapshots.length;
    const lastAtMs = input.lastErrorAtMs ??
      (snapshots.length > 0
        ? (snapshots[snapshots.length - 1]?.timestampMs ?? null)
        : null);

    if (errorCount === 0) { lines.push(`- ${tr3("无", "無", "None", undefined, uiLang)}`);
    } else { const stampPart = lastAtMs !== null
          ? tr3("{count} 次（最近一次 {stamp}）",
              "{count} 次（最近一次 {stamp}）",
              "{count} time(s), last at {stamp}",
              { count: errorCount, stamp: formatUtcMinuteStamp(lastAtMs) },
              uiLang,
            )
          : tr3("{count} 次",
              "{count} 次",
              "{count} time(s)",
              { count: errorCount },
              uiLang,
            );
      lines.push(`- ${stampPart}`);
      if (snapshots.length > 0) { const byCat = new Map<DiagnosticsErrorCategory, number>();
        for (const s of snapshots) { byCat.set(s.category, (byCat.get(s.category) ?? 0) + 1);
        }
        const breakdown = [...byCat.entries()]
          .map(([cat, cnt]) => `${cat}=${cnt}`)
          .join(", ");
        lines.push(`- categories: ${breakdown}`);
      }
    }

    lines.push("");
    lines.push(`_${tr3("此报告不包含设备 ID、令牌、服务器地址、局域网 IP、MAC 地址、账号信息或家庭名称。",
        "此報告不包含裝置 ID、權杖、伺服器位址、區域網路 IP、MAC 位址、帳號資訊或家庭名稱。",
        "This report contains no device IDs, tokens, server addresses, LAN IPs, MAC addresses, account information, or home names.",
        undefined,
        uiLang,
      )}_`,
    );

    const rendered = lines.join("\n");
    assertZeroSensitiveLeaks(rendered);
    return rendered;
  },
} as const;
