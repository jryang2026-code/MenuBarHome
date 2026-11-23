import { showHUD } from "@raycast/api";
import { powerCommand } from "./control";
import { describeDevice, matchDevice } from "./match";
import { loadSnapshot } from "./snapshot";
import { errorMessage, runCommandWithHUD } from "./url";

type Props = {
  arguments: {
    device?: string;
  };
};

/**
 * One global-hotkey toggle. The device is resolved against the read-only snapshot, then the app's own
 * `toggle` route flips whatever state the device is in when the command actually runs.
 */
export default async function ToggleDevice({ arguments: args }: Props) {
  const query = (args.device ?? "").trim();
  if (!query) {
    await showHUD("⚠️ Type a device name, id or pinyin initials");
    return;
  }
  try {
    const snapshot = await loadSnapshot();
    const match = matchDevice(snapshot, query);
    if (!match.ok) {
      await showHUD(`⚠️ ${match.error}`);
      return;
    }
    const device = match.device;
    if (!device.isPrimaryToggleable) {
      await showHUD(`⚠️ ${describeDevice(device)}: no switch to toggle`);
      return;
    }
    const command = powerCommand(device, "toggle");
    await runCommandWithHUD(command.route, command.params);
  } catch (error) {
    await showHUD(`⚠️ ${errorMessage(error)}`);
  }
}
