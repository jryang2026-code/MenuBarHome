/**
 * #104: the user's per-device «这其实是灯» marks. Wall switches the user marked as ordinary
 * lights stop the manual high-risk confirmation; every other kind keeps asking even with a
 * stale id, because `ManualControlPolicy` re-checks the wall-switch rule at its single decision
 * point (`windows/src/core/assistant/actionPolicy.ts`).
 *
 * Stored under its own `localStorage` key — never inside the settings blob and never holding a
 * credential — like the pinned-source and canonical-id registries beside it, so a dual-source
 * merge preserves the ids (`cloudRefresh.ts` reports them as known preference ids).
 */

export const SWITCH_LIGHT_MARKS_STORAGE_KEY = "menumijia.windows.switchLightIds.v1";

let storageOverride: Storage | null | undefined;

function markStorage(): Storage | null {
  if (storageOverride !== undefined) return storageOverride;
  try {
    return typeof localStorage !== "undefined" && localStorage !== null ? localStorage : null;
  } catch {
    return null;
  }
}

/** Tests inject an isolated store; `undefined` restores the auto-detected WebView storage. */
export function setSwitchLightMarkStorage(next: Storage | null | undefined): void {
  storageOverride = next;
}

function readIds(): string[] {
  const store = markStorage();
  if (!store) return [];
  try {
    const parsed: unknown = JSON.parse(store.getItem(SWITCH_LIGHT_MARKS_STORAGE_KEY) ?? "[]");
    if (!Array.isArray(parsed)) return [];
    const seen = new Set<string>();
    const out: string[] = [];
    for (const item of parsed) {
      if (typeof item !== "string") continue;
      const trimmed = item.trim();
      if (trimmed === "" || seen.has(trimmed)) continue;
      seen.add(trimmed);
      out.push(trimmed);
    }
    return out;
  } catch {
    return [];
  }
}

function writeIds(ids: readonly string[]): void {
  const store = markStorage();
  if (!store) return;
  try {
    store.setItem(SWITCH_LIGHT_MARKS_STORAGE_KEY, JSON.stringify(ids));
  } catch {
    // A quota error only costs the mark; the confirmation gate still works.
  }
}

export function switchLightMarkIds(): ReadonlySet<string> {
  return new Set(readIds());
}

export function isSwitchMarkedAsLight(deviceId: string): boolean {
  return switchLightMarkIds().has(deviceId);
}

export function markSwitchAsLight(deviceId: string): void {
  const id = deviceId.trim();
  if (!id) return;
  const ids = readIds();
  if (ids.includes(id)) return;
  writeIds([...ids, id]);
}

export function unmarkSwitchAsLight(deviceId: string): void {
  const id = deviceId.trim();
  const ids = readIds();
  if (!ids.includes(id)) return;
  writeIds(ids.filter((item) => item !== id));
}
