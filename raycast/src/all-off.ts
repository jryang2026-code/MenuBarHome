import { AlertActionStyle, confirmAlert, showHUD } from "@raycast/api";
import { errorMessage, runCommandWithHUD } from "./url";

/**
 * The built-in 一键全关 quick action behind a global hotkey. It turns every controllable device off at
 * once, so Raycast asks first; the app still applies its own capability gate, lock-screen block and
 * high-risk device confirmations to each write.
 */
export default async function AllOff() {
  try {
    const confirmed = await confirmAlert({
      title: "Turn everything off?",
      message: "Runs MenuBarHome's built-in All Off quick action.",
      primaryAction: { title: "All Off", style: AlertActionStyle.Destructive },
    });
    if (!confirmed) {
      await showHUD("Cancelled");
      return;
    }
    await runCommandWithHUD("scene", [["name", "quick:allOff"]]);
  } catch (error) {
    await showHUD(`⚠️ ${errorMessage(error)}`);
  }
}
