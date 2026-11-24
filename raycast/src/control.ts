import type { RaycastDevice } from "./snapshot";
import type { CommandParams } from "./url-builder";

/**
 * `on` / `off` are absolute requests, so they are sent as `power` with the requested state and stay
 * idempotent. `toggle` is sent as the app's own `toggle` route: the app resolves the current state at
 * execution time, so a snapshot that is a few hundred milliseconds old can never turn a flip into a
 * no-op or the opposite action.
 */
export type PowerAction = "on" | "off" | "toggle";

export interface PowerCommand {
  route: "power" | "toggle";
  params: CommandParams;
}

export function normalizePowerAction(raw: unknown): PowerAction | undefined {
  const value = String(raw ?? "")
    .trim()
    .toLowerCase();
  return value === "on" || value === "off" || value === "toggle" ? value : undefined;
}

export function powerCommand(device: RaycastDevice, action: PowerAction): PowerCommand {
  if (action === "toggle") {
    return { route: "toggle", params: [["device", device.id]] };
  }
  return {
    route: "power",
    params: [
      ["device", device.id],
      ["on", action === "on" ? "true" : "false"],
    ],
  };
}
