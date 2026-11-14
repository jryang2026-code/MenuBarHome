import { MiCloudError } from "./miCloud/session.js";
import { trText } from "./quickActions.js";

/**
 * MIoT per-item error code for "device offline" (`ControlFailure.deviceOfflineMiotCode` on macOS).
 * Other negative per-item MIoT codes represent device/gateway rejections rather than offline state.
 */
export const MIOT_DEVICE_OFFLINE_CODE = -704042011;

export type ControlFailureKind =
  | "cancelled"
  | "deviceOffline"
  | "rateLimited"
  | "sessionExpired"
  | "signedOut"
  | "tokenRejected"
  | "deviceRejected"
  | "network";

export type ClassifiedControlFailure =
  | { readonly kind: "cancelled"; readonly isCancellation: true }
  | { readonly kind: "deviceOffline"; readonly isCancellation: false }
  | { readonly kind: "rateLimited"; readonly isCancellation: false }
  | { readonly kind: "sessionExpired"; readonly isCancellation: false }
  | { readonly kind: "signedOut"; readonly isCancellation: false }
  | { readonly kind: "tokenRejected"; readonly isCancellation: false }
  | { readonly kind: "deviceRejected"; readonly code: number; readonly isCancellation: false }
  | { readonly kind: "network"; readonly isCancellation: false };

export interface ClassifyControlFailureOptions {
  /** Last known online state of the target device; mirrors `ControlFailure.swift` `isDeviceOnline`. */
  readonly isDeviceOnline?: boolean;
}

export interface ControlFailureFormatOptions extends ClassifyControlFailureOptions {
  readonly deviceName?: string;
  readonly adjustment?: boolean;
  /** Returned when the failure does not fit any structured bucket (e.g. generic HTTP 500). */
  readonly fallback?: string;
}

interface ExtractedErrorShape {
  readonly name: string;
  readonly message: string;
  readonly code: number | string | null;
  readonly status: number | null;
}

function extractErrorShape(error: unknown): ExtractedErrorShape {
  if (typeof error === "string") {
    return { name: "", message: error.trim(), code: null, status: null };
  }
  if (!error || typeof error !== "object") {
    return { name: "", message: error == null ? "" : String(error), code: null, status: null };
  }
  const rec = error as Record<string, unknown>;
  const name = typeof rec["name"] === "string" ? rec["name"].trim() : "";
  const message =
    typeof rec["message"] === "string"
      ? rec["message"].trim()
      : error instanceof Error
        ? error.message.trim()
        : "";
  const rawCode = rec["code"];
  const code =
    typeof rawCode === "number" && Number.isFinite(rawCode)
      ? Math.trunc(rawCode)
      : typeof rawCode === "string" && rawCode.trim() !== ""
        ? rawCode.trim()
        : null;
  const rawStatus = rec["status"] ?? rec["statusCode"] ?? rec["httpStatus"];
  const status =
    typeof rawStatus === "number" && Number.isFinite(rawStatus)
      ? Math.trunc(rawStatus)
      : null;
  return { name, message, code, status };
}

/**
 * Returns `true` when an error comes from an aborted/preempted slider debounce or cancelled task,
 * which callers must silently ignore without surfacing an error banner (`ControlFailure.isCancellation`).
 */
export function isCancellationError(error: unknown): boolean {
  if (error == null) return false;
  const { name, message, code } = extractErrorShape(error);
  if (name === "AbortError" || name === "CancellationError") return true;
  if (code === "ABORT_ERR" || code === "ERR_CANCELED" || code === -999) return true;
  // DOMException.ABORT_ERR === 20 in browser / JSDOM environments.
  if (code === 20 && (name.toLowerCase().includes("abort") || /abort/i.test(message))) {
    return true;
  }
  if (!message) return false;
  const lower = message.toLowerCase();
  if (
    /\baborterror\b/.test(lower) ||
    /\baborted\b/.test(lower) ||
    /\bcancell?ed\b/.test(lower) ||
    lower.includes("the operation was aborted") ||
    lower.includes("signal is aborted") ||
    message.includes("请求已取消") ||
    message.includes("操作已取消")
  ) {
    return true;
  }
  return false;
}

function neverLeftClient(shape: ExtractedErrorShape): boolean {
  const lower = shape.message.toLowerCase();
  return (
    lower.includes("invalid url") ||
    lower.includes("backend not configured") ||
    lower.includes("backendnotconfigured") ||
    lower.includes("unsupported miot") ||
    shape.message.includes("未配置连接地址") ||
    shape.message.includes("地址格式无效") ||
    shape.message.includes("不支持此控制项")
  );
}

function classifyHttpStatus(
  status: number,
  authKind: "sessionExpired" | "tokenRejected",
): ClassifiedControlFailure | null {
  if (status === 401 || status === 403) {
    return { kind: authKind, isCancellation: false };
  }
  if (status === 429) {
    return { kind: "rateLimited", isCancellation: false };
  }
  if (status === 408 || status === 502 || status === 503 || status === 504) {
    return { kind: "network", isCancellation: false };
  }
  return null;
}

function parseHttpStatusFromMessage(message: string): number | null {
  const match =
    message.match(/\bHTTP\s+(\d{3})\b/i) ??
    message.match(/\bstatus(?:\s+code)?\s*[:=]?\s*(\d{3})\b/i);
  if (!match?.[1]) return null;
  const parsed = Number.parseInt(match[1], 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function classifyRawError(error: unknown, shape: ExtractedErrorShape): ClassifiedControlFailure | null {
  if (isCancellationError(error)) {
    return { kind: "cancelled", isCancellation: true };
  }

  if (error instanceof MiCloudError) {
    switch (error.kind) {
      case "notLoggedIn":
        return { kind: "signedOut", isCancellation: false };
      case "sessionExpired":
        return { kind: "sessionExpired", isCancellation: false };
      case "http":
        if (typeof error.code === "number") {
          return classifyHttpStatus(error.code, "sessionExpired");
        }
        break;
      case "api":
        if (error.code === 2 || error.code === 3) {
          return { kind: "sessionExpired", isCancellation: false };
        }
        if (typeof error.code === "number" && error.code < 0) {
          if (error.code === MIOT_DEVICE_OFFLINE_CODE) {
            return { kind: "deviceOffline", isCancellation: false };
          }
          return { kind: "deviceRejected", code: error.code, isCancellation: false };
        }
        // Positive envelope error codes are cloud-envelope errors, not device rejections.
        return null;
      case "badResponse":
        return null;
    }
  }

  if (typeof shape.code === "number") {
    if (shape.code === MIOT_DEVICE_OFFLINE_CODE) {
      return { kind: "deviceOffline", isCancellation: false };
    }
    if (shape.code === 2 || shape.code === 3) {
      return { kind: "sessionExpired", isCancellation: false };
    }
    if (shape.code < 0) {
      return { kind: "deviceRejected", code: shape.code, isCancellation: false };
    }
  }

  if (typeof shape.code === "string") {
    const upper = shape.code.toUpperCase();
    if (
      upper === "ETIMEDOUT" ||
      upper === "ESOCKETTIMEDOUT" ||
      upper === "ECONNREFUSED" ||
      upper === "ECONNRESET" ||
      upper === "ENOTFOUND" ||
      upper === "EHOSTUNREACH" ||
      upper === "ENETUNREACH" ||
      upper === "ECONNABORTED" ||
      upper === "EAI_AGAIN" ||
      upper === "UND_ERR_CONNECT_TIMEOUT"
    ) {
      return { kind: "network", isCancellation: false };
    }
  }

  const msg = shape.message;
  const lower = msg.toLowerCase();
  const isMijiaContext =
    error instanceof MiCloudError ||
    lower.includes("mi cloud") ||
    lower.includes("micloud") ||
    lower.includes("xiaomi") ||
    lower.includes("miot") ||
    msg.includes("米家");

  if (shape.status !== null) {
    const byStatus = classifyHttpStatus(
      shape.status,
      isMijiaContext ? "sessionExpired" : "tokenRejected",
    );
    if (byStatus) return byStatus;
  }

  const embeddedStatus = parseHttpStatusFromMessage(msg);
  if (embeddedStatus !== null) {
    const byEmbedded = classifyHttpStatus(
      embeddedStatus,
      isMijiaContext ? "sessionExpired" : "tokenRejected",
    );
    if (byEmbedded) return byEmbedded;
  }

  if (!msg) return null;

  if (
    /\b429\b/.test(lower) ||
    lower.includes("too many requests") ||
    lower.includes("rate limit") ||
    lower.includes("rate_limit") ||
    lower.includes("ratelimit") ||
    msg.includes("请求过于频繁") ||
    msg.includes("请求太频繁") ||
    msg.includes("限流")
  ) {
    return { kind: "rateLimited", isCancellation: false };
  }

  if (
    lower.includes("notlogged") ||
    lower.includes("not logged in") ||
    lower.includes("not signed in") ||
    msg.includes("未登录米家") ||
    msg.includes("请先扫码登录米家")
  ) {
    return { kind: "signedOut", isCancellation: false };
  }

  if (
    lower.includes("sessionexpired") ||
    lower.includes("session expired") ||
    lower.includes("servicetoken_expired") ||
    lower.includes("token expired") ||
    /\bcode\s*[:=]?\s*[23]\b/.test(lower) ||
    msg.includes("米家登录已过期") ||
    msg.includes("登录已过期") ||
    msg.includes("米家云指令失败 (2)") ||
    msg.includes("米家云指令失败 (3)")
  ) {
    return { kind: "sessionExpired", isCancellation: false };
  }

  if (
    /\b(?:401|403)\b/.test(lower) ||
    lower.includes("unauthorized") ||
    lower.includes("forbidden") ||
    lower.includes("invalid_token") ||
    lower.includes("invalid access token") ||
    lower.includes("token rejected") ||
    lower.includes("authentication rejected") ||
    lower.includes("auth err") ||
    msg.includes("访问令牌无效") ||
    msg.includes("令牌已失效") ||
    msg.includes("令牌无效")
  ) {
    return {
      kind: isMijiaContext ? "sessionExpired" : "tokenRejected",
      isCancellation: false,
    };
  }

  if (
    msg.includes(String(MIOT_DEVICE_OFFLINE_CODE)) ||
    /\boffline\b/.test(lower) ||
    /\bunavailable\b/.test(lower) ||
    msg.includes("设备未响应或离线") ||
    msg.includes("设备离线") ||
    msg.includes("当前离线")
  ) {
    return { kind: "deviceOffline", isCancellation: false };
  }

  const negMijiaMatch =
    msg.match(/米家(?:错误码|云指令失败)\s*\(?(-[1-9]\d*)\)?/) ??
    msg.match(/\bmiot\s+error\s+(-[1-9]\d*)\b/i);
  if (negMijiaMatch?.[1]) {
    const negCode = Number.parseInt(negMijiaMatch[1], 10);
    if (Number.isFinite(negCode) && negCode < 0) {
      if (negCode === MIOT_DEVICE_OFFLINE_CODE) {
        return { kind: "deviceOffline", isCancellation: false };
      }
      return { kind: "deviceRejected", code: negCode, isCancellation: false };
    }
  }

  if (
    lower.includes("timeout") ||
    lower.includes("timed out") ||
    lower.includes("etimedout") ||
    lower.includes("econnrefused") ||
    lower.includes("econnreset") ||
    lower.includes("enotfound") ||
    lower.includes("ehostunreach") ||
    lower.includes("enetunreach") ||
    lower.includes("econnaborted") ||
    lower.includes("connection refused") ||
    lower.includes("socket hang up") ||
    lower.includes("failed to fetch") ||
    lower.includes("fetch failed") ||
    lower.includes("networkerror") ||
    lower.includes("network error") ||
    /\bnetwork\b/.test(lower) ||
    /\bunreachable\b/.test(lower) ||
    msg.includes("网络超时") ||
    msg.includes("网络连接超时") ||
    msg.includes("网络异常") ||
    msg.includes("网络不可达") ||
    msg.includes("连接超时")
  ) {
    return { kind: "network", isCancellation: false };
  }

  return null;
}

/**
 * Classifies a raw control failure into an actionable bucket (`ControlFailure.swift` parity).
 * Account-wide verdicts (`sessionExpired`, `signedOut`, `tokenRejected`, `rateLimited`) win even if
 * the device was marked offline; otherwise an offline device overrides generic transport/device errors.
 */
export function classifyControlFailure(
  error: unknown,
  options: ClassifyControlFailureOptions = {},
): ClassifiedControlFailure | null {
  const shape = extractErrorShape(error);
  const direct = classifyRawError(error, shape);
  if (direct?.isCancellation) {
    return direct;
  }
  if (
    direct &&
    (direct.kind === "sessionExpired" ||
      direct.kind === "signedOut" ||
      direct.kind === "tokenRejected" ||
      direct.kind === "rateLimited")
  ) {
    return direct;
  }
  if (options.isDeviceOnline === false && !neverLeftClient(shape)) {
    return { kind: "deviceOffline", isCancellation: false };
  }
  return direct;
}

export function controlFailureVerb(deviceName: string, adjustment = false): string {
  const trimmed = deviceName.trim();
  if (!trimmed) {
    return adjustment
      ? trText("调节未生效", "Adjustment failed")
      : trText("操作未生效", "Action failed");
  }
  return adjustment
    ? trText("{name} 调节未生效", "{name} adjustment failed", { name: trimmed })
    : trText("{name} 操作未生效", "{name} action failed", { name: trimmed });
}

export function formatControlFailureReason(
  failure: Exclude<ClassifiedControlFailure, { readonly kind: "cancelled" }>,
): string {
  switch (failure.kind) {
    case "deviceOffline":
      return trText(
        "设备当前离线，请等它重新上线后再试",
        "device is currently offline, try again when it reconnects",
      );
    case "rateLimited":
      return trText(
        "请求过于频繁，请稍后再试",
        "too many requests, please try again shortly",
      );
    case "sessionExpired":
      return trText(
        "登录已过期，请前往设置重新连接",
        "sign-in has expired, reconnect in Settings",
      );
    case "signedOut":
      return trText(
        "未登录米家，请前往设置重新连接",
        "not signed in to Xiaomi Home, sign in from Settings",
      );
    case "tokenRejected":
      return trText(
        "登录状态或访问令牌已失效，请前往设置重新连接",
        "sign-in or access token is invalid, reconnect in Settings",
      );
    case "deviceRejected":
      return trText(
        "设备拒绝了这次操作（米家错误码 {code}）",
        "the device rejected this command (Mijia error code {code})",
        { code: failure.code },
      );
    case "network":
      return trText(
        "网络连接超时或不可达，请检查网络后重试",
        "network connection timed out or is unreachable, check the connection and try again",
      );
  }
}

/**
 * Formats a user-facing bilingual control failure message, or returns `null` when the error is a
 * preemption/debounce cancellation (`isCancellation === true`) so the caller stays silent.
 */
export function controlFailureUserMessage(
  error: unknown,
  options: ControlFailureFormatOptions = {},
): string | null {
  const failure = classifyControlFailure(error, options);
  if (failure?.isCancellation) {
    return null;
  }
  const deviceName = options.deviceName?.trim() ?? "";
  const adjustment = options.adjustment === true;
  if (!failure) {
    if (options.fallback !== undefined && options.fallback.trim() !== "") {
      return options.fallback;
    }
    return controlFailureVerb(deviceName, adjustment);
  }
  const reason = formatControlFailureReason(failure);
  if (!deviceName) {
    return reason.charAt(0).toUpperCase() + reason.slice(1);
  }
  return trText("{verb}：{reason}", "{verb}: {reason}", {
    verb: controlFailureVerb(deviceName, adjustment),
    reason,
  });
}
