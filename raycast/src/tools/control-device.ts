import { Action, type Tool } from "@raycast/api";
import { normalizePowerAction, powerCommand, type PowerAction } from "../control";
import { describeDevice, matchDevice } from "../match";
import { loadSnapshot } from "../snapshot";
import { runCommand } from "../url";

type Input = {
  /** Device name, room-prefixed name, id or pinyin initials, as returned by list-devices. */
  device: string;
  /** "on", "off" or "toggle": an absolute state, or a flip resolved by the app at execution time. */
  action: string;
};

function verb(action: PowerAction | undefined): string {
  if (action === "on") {
    return "Turn on";
  }
  if (action === "off") {
    return "Turn off";
  }
  return action === "toggle" ? "Toggle" : "Change";
}

/**
 * Raycast asks the user to confirm before this tool runs. A device write can turn off a heater, a
 * socket or a lock, so it is always presented as destructive, and the app's own capability gate,
 * lock-screen block and high-risk confirmation still run on top of it.
 */
export const confirmation: Tool.Confirmation<Input> = async (input) => {
  const action = normalizePowerAction(input.action);
  let target = (input.device ?? "").trim() || "unknown device";
  try {
    const snapshot = await loadSnapshot();
    const match = matchDevice(snapshot, input.device ?? "");
    if (match.ok) {
      target = describeDevice(match.device);
    }
  } catch {
    // The tool reports a missing snapshot itself; the prompt still names what was asked for.
  }
  return {
    style: Action.Style.Destructive,
    message: `${verb(action)} this device through MenuBarHome?`,
    info: [
      { name: "Device", value: target },
      { name: "Action", value: verb(action) },
    ],
  };
};

/**
 * The only write tool. It resolves the device locally, sends a `menumijia://` link and waits for the
 * app's own result, so the AI can report exactly what happened. `on` / `off` go out as explicit
 * `power` states; `toggle` uses the app's `toggle` route so the app decides from live state.
 */
export default async function tool(input: Input): Promise<{
  device: string;
  room: string;
  action: PowerAction;
  message: string;
}> {
  const action = normalizePowerAction(input.action);
  if (!action) {
    throw new Error(`Unknown action "${input.action}". Use "on", "off" or "toggle".`);
  }
  const snapshot = await loadSnapshot();
  const match = matchDevice(snapshot, input.device ?? "");
  if (!match.ok) {
    throw new Error(match.error);
  }
  const device = match.device;
  if (!device.isPrimaryToggleable) {
    throw new Error(`${device.name} has no switch to toggle. Use Search Devices to see what it offers.`);
  }
  const command = powerCommand(device, action);
  const result = await runCommand(command.route, command.params);
  if (result.isError) {
    throw new Error(result.message || "MenuBarHome refused the command.");
  }
  return {
    device: device.name,
    room: device.roomName,
    action,
    message: result.message,
  };
}
