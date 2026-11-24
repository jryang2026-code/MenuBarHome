/**
 * Roadmap P1-3: "收敛主面板首屏至 ≤3 层（折叠 `For You`/快捷条）".
 *
 * Mirrors macOS PR #491's `PanelQuickDrawer`: one `快捷` affordance folds the quick-action/scene
 * strip together with the "For You" suggestion cards. New installs start folded; the user's last
 * choice is kept under the Windows-style `menumijia.windows.*.v1` key space.
 */

import type { MenuMijiaWindowsApp } from "./app.js";
import { isProactiveSuggestionsEnabled } from "../core/assistant/lifecycle.js";
import { tr3 } from "../core/i18n.js";
import { SF_ICONS } from "./appConstants.js";

export const PANEL_QUICK_DRAWER_STORAGE_KEY = "menumijia.windows.panelQuickDrawerExpanded.v1";

interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function defaultStorage(): StorageLike | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

/** Missing, malformed, or unavailable storage means folded — the ≤3-layer first screen. */
export function readPanelQuickDrawerExpanded(storage: StorageLike | null = defaultStorage()): boolean {
  try {
    return storage?.getItem(PANEL_QUICK_DRAWER_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

export function writePanelQuickDrawerExpanded(expanded: boolean, storage: StorageLike | null = defaultStorage()): void {
  try {
    if (!storage) return;
    if (expanded) storage.setItem(PANEL_QUICK_DRAWER_STORAGE_KEY, "1");
    else storage.removeItem(PANEL_QUICK_DRAWER_STORAGE_KEY);
  } catch {
    // Private-mode storage failures must not take the panel down.
  }
}

export function togglePanelQuickDrawerExpanded(storage: StorageLike | null = defaultStorage()): boolean {
  const next = !readPanelQuickDrawerExpanded(storage);
  writePanelQuickDrawerExpanded(next, storage);
  return next;
}

/** The Windows twin of macOS `PanelQuickDrawerPolicy.hasContent`. */
export function panelQuickDrawerHasContent(
  host: Pick<MenuMijiaWindowsApp, "settings" | "scenes" | "pendingSuggestions">,
): boolean {
  return (
    host.settings.showQuickActionsBar === true ||
    host.scenes.length > 0 ||
    host.pendingSuggestions.length > 0 ||
    isProactiveSuggestionsEnabled(host.settings)
  );
}

export function renderPanelQuickDrawerToggle(
  host: Pick<MenuMijiaWindowsApp, "settings" | "scenes" | "pendingSuggestions" | "escapeHtml">,
  expanded: boolean,
): string {
  if (!panelQuickDrawerHasContent(host)) return "";
  const label = tr3("快捷操作与为你推荐", "快捷操作與為你推薦", "Shortcuts & For You");
  const hint = expanded
    ? tr3("收起快捷场景与推荐（Ctrl+K）", "收起快捷場景與推薦（Ctrl+K）", "Collapse shortcuts and suggestions (Ctrl+K)")
    : tr3("展开快捷场景与推荐（Ctrl+K）", "展開快捷場景與推薦（Ctrl+K）", "Expand shortcuts and suggestions (Ctrl+K)");
  return `<button
                type="button"
                id="btn-quick-drawer-toggle"
                class="cc-quick-drawer-toggle"
                data-quick-drawer-toggle
                aria-expanded="${expanded}"
                aria-label="${host.escapeHtml(label)}"
                title="${host.escapeHtml(hint)}"
              >
                <span class="cc-quick-drawer-icon" aria-hidden="true">${SF_ICONS.sparkles}</span>
                <span>${tr3("快捷", "快捷", "Shortcuts")}</span>
                <span class="cc-quick-drawer-chevron" aria-hidden="true">${expanded ? SF_ICONS.chevronUp : SF_ICONS.chevronDown}</span>
              </button>`;
}

/** Toggles persistence, re-renders, and puts focus back on the capsule for keyboard/screen-reader users. */
export function togglePanelQuickDrawer(host: Pick<MenuMijiaWindowsApp, "render" | "root">): boolean {
  const expanded = togglePanelQuickDrawerExpanded();
  host.render();
  host.root.querySelector<HTMLButtonElement>("#btn-quick-drawer-toggle")?.focus({ preventScroll: true });
  return expanded;
}
