import type { HttpRequest, HttpResponse, HttpTransport } from "../core/miCloudClient.js";
import { haConnectionScope, mapNativeHaTransportError } from "../core/haTransportGate.js";

export function createTransport(): HttpTransport {
  return async (req: HttpRequest): Promise<HttpResponse> => {
    if (window.__TAURI_INTERNALS__?.invoke) {
      if (req.haConnection) {
        // `ha_http` is a read-only bridge: the native command carries no method/body/redirect
        // arguments. Refuse a write instead of silently sending it as a GET, and honour an
        // already-aborted lease before spending an IPC round trip.
        req.haConnection.signal.throwIfAborted();
        if ((req.method ?? "GET") !== "GET" || req.body !== undefined) {
          throw new Error("Home Assistant native transport only supports GET requests");
        }
        try {
          return await window.__TAURI_INTERNALS__.invoke<HttpResponse>("ha_http", {
            baseUrl: req.haConnection.baseUrl,
            generation: req.haConnection.generation,
            url: req.url,
            headers: req.headers ?? {},
            timeoutMs: req.timeoutMs ?? 15000,
          });
        } catch (error) {
          throw mapNativeHaTransportError(error, haConnectionScope(req.haConnection.baseUrl));
        }
      }
      return window.__TAURI_INTERNALS__.invoke<HttpResponse>("native_http", {
        url: req.url,
        method: req.method ?? "GET",
        headers: req.headers ?? {},
        body: req.body ?? null,
        followRedirects: req.followRedirects ?? true,
        timeoutMs: req.timeoutMs ?? 15000,
      });
    }
    const response = await fetch(req.url, {
      method: req.method ?? "GET",
      headers: req.headers,
      body: req.body,
      ...(req.haConnection ? { signal: req.haConnection.signal } : {}),
    });
    const headers: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    return {
      status: response.status,
      headers,
      body: await response.text(),
    };
  };
}

export function invokeTauriVoid(cmd: string, args?: Record<string, unknown>): void {
  if (window.__TAURI_INTERNALS__?.invoke) {
    void window.__TAURI_INTERNALS__.invoke(cmd, args).catch((error: unknown) => {
      console.error(`[tauri] ${cmd} failed`, error);
    });
  }
}

export async function isWorkstationLocked(): Promise<boolean> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return false;
  try {
    return Boolean(await invoke<boolean>("is_workstation_locked"));
  } catch {
    return false;
  }
}

export async function isWorkstationLockBlockingControl(host: {
  readonly settings: { readonly blockControlWhileLocked?: boolean };
}): Promise<boolean> {
  if (!host.settings.blockControlWhileLocked) return false;
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return false;
  try {
    return Boolean(await invoke<boolean>("is_workstation_locked"));
  } catch {
    return true;
  }
}

/**
 * Reads one power sample from `system_events.rs` (GetSystemPowerStatus).
 * `null` means “no native host or the call failed”: the poller keeps the previous sample instead
 * of inventing a transition. Desktops report `hasBattery: false` and no percentage, which is what
 * keeps low-battery rules from firing on a machine with no battery.
 */
export async function readNativeSystemPower(): Promise<{
  readonly hasBattery: boolean;
  readonly onExternalPower: boolean | null;
  readonly batteryPercent: number | null;
} | null> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return null;
  try {
    const raw = await invoke<{
      hasBattery?: unknown;
      onExternalPower?: unknown;
      batteryPercent?: unknown;
    } | null>("system_power_status");
    if (!raw) return null;
    const hasBattery = raw.hasBattery === true;
    const percent = raw.batteryPercent;
    return {
      hasBattery,
      onExternalPower: hasBattery
        ? typeof raw.onExternalPower === "boolean"
          ? raw.onExternalPower
          : null
        : true,
      batteryPercent:
        hasBattery && typeof percent === "number" && Number.isFinite(percent)
          ? Math.min(100, Math.max(0, Math.trunc(percent)))
          : null,
    };
  } catch {
    return null;
  }
}

/** Number of active displays that are not the built-in panel (`QueryDisplayConfig`). */
export async function readNativeExternalDisplayCount(): Promise<number | null> {
  const invoke = typeof window !== "undefined" ? window.__TAURI_INTERNALS__?.invoke : undefined;
  if (!invoke) return null;
  try {
    const raw = await invoke<number | null>("external_display_count");
    return typeof raw === "number" && Number.isFinite(raw) ? Math.max(0, Math.trunc(raw)) : null;
  } catch {
    return null;
  }
}
