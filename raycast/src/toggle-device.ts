import { showHUD } from "@raycast/api";
import { describeDevice, matchDevice } from "./match";
import { loadSnapshot } from "./snapshot";
import { errorMessage, runCommandWithHUD } from "./url";

type Props = {
  arguments: {
    device?: string;
  };
};

/**
 * One global-hotkey toggle. The command resolves the device against the read-only snapshot, then sends
 * an explicit `power` link (never `toggle`) so the app can name the exact action it is about to run.
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
    await runCommandWithHUD("power", [
      ["device", device.id],
      ["on", device.isActiveOn ? "false" : "true"],
    ]);
  } catch (error) {
    await showHUD(`⚠️ ${errorMessage(error)}`);
  }
}
