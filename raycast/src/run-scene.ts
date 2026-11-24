import { showHUD } from "@raycast/api";
import { matchScene } from "./match";
import { loadSnapshot } from "./snapshot";
import { errorMessage, runCommandWithHUD } from "./url";

type Props = {
  arguments: {
    scene?: string;
  };
};

/** Run a Home Assistant scene or a built-in quick action by name, id or pinyin initials. */
export default async function RunScene({ arguments: args }: Props) {
  const query = (args.scene ?? "").trim();
  if (!query) {
    await showHUD("⚠️ Type a scene or quick action name");
    return;
  }
  try {
    const snapshot = await loadSnapshot();
    const match = matchScene(snapshot, query);
    if (!match.ok) {
      await showHUD(`⚠️ ${match.error}`);
      return;
    }
    await runCommandWithHUD("scene", [
      ["name", match.kind === "quick" ? `quick:${match.id}` : match.id],
    ]);
  } catch (error) {
    await showHUD(`⚠️ ${errorMessage(error)}`);
  }
}
