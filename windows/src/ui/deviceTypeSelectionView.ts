import { AutomationRuleStore } from "../core/automationEngine.js";
import {
  ALL_CAPABILITY_IDS, DEVICE_CATEGORY_IDS, deviceCategoryForDevice,
  type CapabilityID, type DeviceCategoryID,
} from "../core/capabilityManifest.js";
import {
  DELIVERED_DEVICE_CATEGORY_IDS, deviceCategoryLabel, deviceCategorySelectionFor, deviceCategorySelectionMode,
  capabilityDisplayLabel, deviceCategorySelectionModeLabel, affectedReferenceKindLabel, sameDeviceCategories,
  safetySignalLabel, toggleDeviceCategory,
  type DeviceCategorySelectionMode, type DeviceTypeSelectionPreview,
} from "../core/deviceTypeSelection.js";
import { capabilitySoftNoticeMessage, type AffectedReferenceItem } from "../core/capabilityReferenceVerdict.js";
import { currentLanguage, tr3, type AppLanguage } from "../core/i18n.js";
import { applyPauseItemsFromVerdict, previewDeviceCategorySelection, writeMiAccountSelectionMutation, revalidateAfterMiAccountReenable } from "../core/miAccountControl.js";
import type { SmartDevice } from "../core/models.js";
import { SCHEDULED_COMMANDS_STORAGE_KEY, ScheduledCommandStore } from "../core/scheduledCommands.js";
import { buildHostCapabilityContext, hostMiotTypePruneOptions, resolveHostMiSelectionState } from "./cloudRefresh.js";
import { scheduledCommandIdentity } from "./scheduledCommands.js";
import type { SettingsEventsHost } from "./settingsEvents.js";

/** The host seams the device-type picker needs; every production host is the app class. */
export interface DeviceTypeSelectionHost extends SettingsEventsHost {
  readonly scheduledCommandStore?: ScheduledCommandStore;
  /** Persists one choice. Returns false when nothing was stored, so the caller keeps the old one. */
  setEnabledDeviceCategories?(categories: readonly DeviceCategoryID[], pausedQuickActionIds: readonly string[]): boolean;
}

interface DeviceTypeSelectionSession {
  /** What the user is looking at; `null` means "mirror the stored selection". */
  mode: DeviceCategorySelectionMode | null;
  customCategories: readonly DeviceCategoryID[] | null;
  shownGeneration: string | null;
  error: string | null;
  status: string | null;
  /** Set when a change was written and references were paused, so the next render says so. */
  appliedNow: boolean;
}

const sessionByHost = new WeakMap<object, DeviceTypeSelectionSession>();

export function clearDeviceTypeSelectionSession(host: object): void {
  sessionByHost.delete(host);
}

function getSession(host: object): DeviceTypeSelectionSession {
  let session = sessionByHost.get(host);
  if (!session) {
    session = { mode: null, customCategories: null, shownGeneration: null, error: null, status: null, appliedNow: false };
    sessionByHost.set(host, session);
  }
  return session;
}

/** The device types the app is drawing right now — the value every consumer already reads. */
export function appliedDeviceCategories(host: DeviceTypeSelectionHost): readonly DeviceCategoryID[] {
  return resolveHostMiSelectionState(host as unknown as Parameters<typeof resolveHostMiSelectionState>[0]).selection.enabledCategories;
}

export interface DeviceTypeSelectionDraft {
  readonly mode: DeviceCategorySelectionMode;
  readonly categories: readonly DeviceCategoryID[];
  readonly isDirty: boolean;
  readonly isCustomOpen: boolean;
}

export function deviceTypeSelectionDraft(host: DeviceTypeSelectionHost): DeviceTypeSelectionDraft {
  const session = getSession(host);
  const applied = appliedDeviceCategories(host);
  const mode = session.mode ?? deviceCategorySelectionMode(applied);
  const custom = session.customCategories ?? applied;
  const categories = deviceCategorySelectionFor(mode, custom);
  return { mode, categories, isDirty: !sameDeviceCategories(categories, applied), isCustomOpen: mode === "custom" };
}

/** A cheap signature of everything the block renders, for the inactive-tab cache. */
export function deviceTypeSelectionRenderKey(host: DeviceTypeSelectionHost): string {
  const draft = deviceTypeSelectionDraft(host);
  const session = getSession(host);
  return JSON.stringify([
    draft.mode, draft.categories, draft.isDirty,
    session.error, session.status, session.appliedNow, appliedDeviceCategories(host),
  ]);
}

function ruleStoreFor(host: DeviceTypeSelectionHost): AutomationRuleStore {
  const store = (host as { readonly activityCenter?: { readonly automationEngine?: { readonly store?: AutomationRuleStore } } })
    .activityCenter?.automationEngine?.store;
  return store ?? new AutomationRuleStore();
}

function storeFor(host: DeviceTypeSelectionHost): ScheduledCommandStore {
  const provided = (host as { readonly scheduledCommandStore?: ScheduledCommandStore }).scheduledCommandStore;
  if (provided) return provided;
  const fallback = typeof localStorage !== "undefined" ? localStorage : { getItem: () => null, setItem: () => {} };
  return new ScheduledCommandStore(fallback);
}

/**
 * The confirmation preview, from the shared P2b verdict engine the connection previews already use.
 * Every call re-reads references and the device index, so what the user confirms is what was just
 * computed — a preview never stands in for the state it described.
 */
export function deviceTypeSelectionPreview(
  host: DeviceTypeSelectionHost,
  proposedCategories: readonly DeviceCategoryID[],
  expectedGeneration?: string,
): DeviceTypeSelectionPreview {
  const context = buildHostCapabilityContext(host as unknown as Parameters<typeof buildHostCapabilityContext>[0]);
  const prune = hostMiotTypePruneOptions(host as unknown as Parameters<typeof hostMiotTypePruneOptions>[0]);
  // Favorites, aliases and the custom order survive a trimmed type; saying so is the difference
  // between "hidden" and "lost" (architecture.md §B).
  const layout = host.layout;
  const preferences = {
    favoriteDeviceIds: layout?.pinnedDeviceIds ?? [],
    aliasDeviceIds: Object.keys(layout?.aliases ?? {}),
    customOrderDeviceIds: layout?.order ?? [],
  };
  return previewDeviceCategorySelection({
    proposedCategories,
    context,
    scheduledCommandStore: storeFor(host),
    activeTimerIdentity: scheduledCommandIdentity(host.settings),
    ruleStore: ruleStoreFor(host),
    safetyPolicy: { enabledSignals: prune.safetySignals, starredDeviceIds: prune.starredDeviceIds },
    preferences,
    ...(expectedGeneration !== undefined ? { expectedGeneration } : {}),
    languagePreference: host.settings.interfaceLanguage,
  });
}

function countByCategory(devices: readonly SmartDevice[]): Map<DeviceCategoryID, number> {
  const counts = new Map<DeviceCategoryID, number>();
  for (const device of devices) {
    const category = deviceCategoryForDevice(device);
    counts.set(category, (counts.get(category) ?? 0) + 1);
  }
  return counts;
}

function esc(host: DeviceTypeSelectionHost, value: string): string {
  if (typeof host.escapeHtml === "function") return host.escapeHtml(value);
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Names are content, not markup: four is enough to recognise the change without a wall of text. */
/** Names are content, not markup: four is enough to recognise the change without a wall of text. */
function summarizeNames(names: readonly string[], lang: AppLanguage): string {
  const separator = lang === "en" ? ", " : "、";
  const head = names.slice(0, 4).join(separator);
  return names.length > 4
    ? tr3(`${head} 等 ${names.length} 台`, `${head} 等 ${names.length} 台`, `${head} and ${names.length - 4} more`, lang)
    : head;
}

function referenceSummary(items: readonly AffectedReferenceItem[], lang: AppLanguage): string[] {
  const byKind = new Map<AffectedReferenceItem["kind"], string[]>();
  for (const item of items) byKind.set(item.kind, [...(byKind.get(item.kind) ?? []), item.name]);
  return [...byKind.entries()].map(([kind, names]) => {
    const label = affectedReferenceKindLabel(kind, lang);
    const shown = summarizeNames(names, lang);
    return tr3(`${label} ${names.length} 项：${shown}`, `${label} ${names.length} 項：${shown}`, `${label} (${names.length}): ${shown}`, lang);
  });
}

function previewHtml(host: DeviceTypeSelectionHost, preview: DeviceTypeSelectionPreview, lang: AppLanguage): string {
  const verdict = preview.verdict;
  const lines: string[] = [];
  if (preview.hiddenCards.length > 0) {
    const names = preview.hiddenCards.map((card) => card.name);
    lines.push(
      tr3(
        `从面板、搜索与 AI 目录隐藏 ${names.length} 张卡片：${summarizeNames(names, lang)}`,
        `從面板、搜尋與 AI 目錄隱藏 ${names.length} 張卡片：${summarizeNames(names, lang)}`,
        `${names.length} card(s) leave the panel, search and AI catalogue: ${summarizeNames(names, lang)}`,
        lang,
      ),
    );
  } else if (preview.proposedCategories.length < preview.currentCategories.length) {
    lines.push(
      tr3("当前没有这类卡片，关闭后暂不影响显示。", "目前沒有這類卡片，關閉後暫不影響顯示。", "No cards of this type are shown right now.", lang),
    );
  }
  if (preview.retainedSafetySignals.length > 0) {
    const signals = preview.retainedSafetySignals.map((kind) => safetySignalLabel(kind, lang)).join("、");
    lines.push(
      tr3(
        `仍会读取 ${preview.retainedSafetyCards.length} 台隐藏设备的信号：${signals}。这些提醒照常触发，但不会出现在面板或搜索结果里。`,
        `仍會讀取 ${preview.retainedSafetyCards.length} 台隱藏裝置的訊號：${signals}。這些提醒照常觸發，但不會出現在面板或搜尋結果裡。`,
        `Signals from ${preview.retainedSafetyCards.length} hidden device(s) are still read: ${signals}. Those alerts keep firing but never appear as cards or search hits.`,
        lang,
      ),
    );
  }
  const affected = referenceSummary(preview.affectedReferences, lang);
  if (affected.length > 0) {
    lines.push(
      tr3(
        "应用时会先暂停这些项，重新开启对应类型后按原计划重验：",
        "套用時會先暫停這些項，重新開啟對應類型後按原計畫重驗：",
        "Applying pauses these first; turning the types back on revalidates them:",
        lang,
      ),
    );
    for (const line of affected) lines.push(`· ${line}`);
  }
  for (const notice of verdict.softNotices) {
    if (notice.kind === "safetyReadsRetained") continue;
    const message = capabilitySoftNoticeMessage(notice.kind, lang);
    if (notice.kind === "dependentCapabilitiesCascaded") {
      // Name what turns off with the type instead of the generic "子功能".
      const names = notice.affectedIds.map((id) =>
        (ALL_CAPABILITY_IDS as readonly string[]).includes(id) ? capabilityDisplayLabel(id as CapabilityID, lang) : id,
      );
      lines.push(
        tr3(
          `${names.join("、")}也会一并停用。`,
          `${names.join("、")}也會一併停用。`,
          `${names.join(", ")} turns off as well.`,
          lang,
        ),
      );
      continue;
    }
    lines.push(notice.kind === "manualScenesMayControlHiddenDevices" ? tr3(`${message}。`, `${message}。`, `${message}.`, lang) : message);
  }
  for (const reason of verdict.blockingReasons) {
    lines.push(
      reason.kind === "corruptedReferenceStore"
        ? tr3("本地的定时或自动化数据读不出来，暂时不能更改设备类型。", "本地的定時或自動化資料讀不出來，暫時不能變更裝置類型。", "Stored timers or automations cannot be read, so the device types cannot change yet.", lang)
        : tr3("有引用的归属无法确认，请先处理后再更改设备类型。", "有引用的歸屬無法確認，請先處理後再變更裝置類型。", "A reference's owner cannot be confirmed; resolve it before changing device types.", lang),
    );
  }
  if (lines.length === 0) {
    lines.push(tr3("不会改动当前显示。", "不會改動目前顯示。", "Nothing on screen changes.", lang));
  }
  return `
    <div data-device-type-preview role="status" aria-live="polite" style="display: flex; flex-direction: column; gap: 4px; margin-top: 8px; padding: 8px 10px; border-radius: 8px; background: rgba(128, 128, 128, 0.1);">
      ${lines
        .map((line) => {
          const color = verdict.canDeactivate ? "var(--text-primary)" : "var(--win-caution, #c87400)";
          return `<p class="cc-field-hint" style="margin: 0; color: ${color}; font-size: 12px;">${esc(host, line)}</p>`;
        })
        .join("")}
    </div>`;
}

/**
 * The device-type block, rendered identically in Settings and the first-run guide (P4b-W): the three
 * choices, the per-type list under 自己选, and — once the draft differs from what is stored — the
 * impact preview with 应用/取消. Nothing is written until 应用, so a fresh install shows every type
 * and an upgrade keeps its own value (architecture.md §A, §I).
 */
export function renderDeviceTypeSelectionSection(
  host: DeviceTypeSelectionHost,
  options: { readonly heading?: string; readonly showHeading?: boolean } = {},
): string {
  const lang = currentLanguage();
  const session = getSession(host);
  const draft = deviceTypeSelectionDraft(host);
  const counts = countByCategory(host.devices ?? []);
  const preview = draft.isDirty ? deviceTypeSelectionPreview(host, draft.categories) : null;
  session.shownGeneration = preview?.generation ?? null;
  const canApply = preview === null || preview.verdict.canDeactivate;
  const heading = options.heading ?? tr3("设备类型", "裝置類型", "Device Types", lang);
  const modeLabel = (mode: DeviceCategorySelectionMode): string => deviceCategorySelectionModeLabel(mode, lang);
  const modes: readonly DeviceCategorySelectionMode[] = ["allSupportedTypes", "lightAndSwitch", "custom"];
  const modeHints: Readonly<Record<DeviceCategorySelectionMode, string>> = {
    allSupportedTypes: tr3("显示全部已支持类型，和现在一样", "顯示全部已支援類型，和現在一樣", "Show every supported type, as now", lang),
    lightAndSwitch: tr3("只留灯和开关，其他类型一并收起", "只留燈和開關，其他類型一併收起", "Keep only lights and switches", lang),
    custom: tr3("自己逐类勾选", "自己逐類勾選", "Pick each type yourself", lang),
  };
  const applyLabel = session.appliedNow
    ? tr3("已应用", "已套用", "Applied", lang)
    : preview !== null && preview.affectedReferences.length > 0
      ? tr3("暂停这些项并应用", "暫停這些項並套用", "Pause These and Apply", lang)
      : tr3("应用设备类型", "套用裝置類型", "Apply Device Types", lang);

  return `
    <section class="cc-settings-group" data-general-section="deviceTypes" data-device-types style="display: flex; flex-direction: column; gap: 8px;">
      ${
        options.showHeading === false
          ? ""
          : `<div class="cc-group-title" style="font-size: 12px; font-weight: 600; padding: 0 2px;">${esc(host, heading)}</div>`
      }
      <div class="cc-field" data-settings-anchor="deviceTypes">
        <div class="cc-segmented-pills" role="group" aria-label="${esc(host, heading)}" style="flex-wrap: wrap; gap: 4px;">
          ${modes
            .map((mode) => {
              const active = draft.mode === mode;
              return `<button type="button" class="cc-seg-pill ${active ? "is-active" : ""}" data-device-type-mode="${mode}" aria-pressed="${active}" title="${esc(host, modeHints[mode])}">${esc(host, modeLabel(mode))}</button>`;
            })
            .join("")}
        </div>
        <p class="cc-field-hint" style="margin: 4px 0 0 0;">${esc(host, modeHints[draft.mode])}</p>
        <p data-device-type-safety-note role="note" style="margin: 6px 0 0 0; font-size: 12px; line-height: 16px; color: var(--text-primary);">
          ${esc(
            host,
            tr3(
              "为了继续提供已开启的安全提醒，仍会读取部分隐藏设备；可在「安全与提醒」单独关闭提醒。",
              "為了繼續提供已開啟的安全提醒，仍會讀取部分隱藏裝置；可在「安全與提醒」單獨關閉提醒。",
              "Some hidden devices are still read so enabled safety alerts keep working; turn an alert off in Safety & Alerts.",
              lang,
            ),
          )}
        </p>
      </div>
      ${
        draft.isCustomOpen
          ? `<div class="cc-field" data-device-type-categories style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px;">
              ${DELIVERED_DEVICE_CATEGORY_IDS.map((category) => {
                const checked = draft.categories.includes(category);
                const count = counts.get(category) ?? 0;
                return `<label class="cc-field-row" data-device-type-category-row="${category}" style="justify-content: flex-start; gap: 6px; padding: 4px 6px; border-radius: 6px; background: rgba(128, 128, 128, 0.08);">
                  <input type="checkbox" data-device-type-category="${category}" ${checked ? "checked" : ""} aria-label="${esc(host, deviceCategoryLabel(category, lang))}" />
                  <span style="min-width: 0; overflow: hidden; text-overflow: ellipsis;">${esc(host, deviceCategoryLabel(category, lang))}</span>
                  <span class="cc-field-hint" style="margin-left: auto; font-size: 11px;">${count}</span>
                </label>`;
              }).join("")}
            </div>`
          : ""
      }
      ${preview ? previewHtml(host, preview, lang) : ""}
      ${
        draft.isDirty
          ? `<div class="cc-field-row" data-device-type-actions style="justify-content: flex-end; gap: 6px; margin-top: 2px;">
              <button type="button" class="cc-btn-secondary" data-device-type-cancel>${esc(host, tr3("取消", "取消", "Cancel", lang))}</button>
              <button type="button" class="cc-btn-primary" data-device-type-apply ${canApply ? "" : "disabled"}>${esc(host, applyLabel)}</button>
            </div>`
          : ""
      }
      ${
        session.error
          ? `<p class="cc-field-hint" data-device-type-error role="alert" tabindex="-1" style="margin: 4px 0 0 0; font-size: 12px; color: var(--win-caution, #c87400);">${esc(host, session.error)}</p>`
          : ""
      }
      ${
        session.status
          ? `<p class="cc-field-hint" data-device-type-status tabindex="-1" role="status" style="margin: 4px 0 0 0; font-size: 12px; color: var(--text-primary);">${esc(host, session.status)}</p>`
          : ""
      }
    </section>`;
}

/** Focuses the first match, and says whether it found one, so a caller can fall back. */
/** Ends the transient state of the last action so the next one starts clean. */
function clearTransient(session: DeviceTypeSelectionSession): void {
  session.shownGeneration = null;
  session.error = null;
  session.status = null;
  session.appliedNow = false;
}

function focusAfterRender(host: DeviceTypeSelectionHost, selector: string): boolean {
  const target = host.root.querySelector<HTMLElement>(selector);
  target?.focus({ preventScroll: true });
  return target !== null;
}

export type DeviceTypeSelectionApplyStatus = "applied" | "blocked" | "stalePreview" | "saveFailed" | "pauseFailed";

export interface DeviceTypeSelectionApplyOutcome {
  readonly status: DeviceTypeSelectionApplyStatus;
  readonly preview: DeviceTypeSelectionPreview;
}

function readRawStorageItem(key: string): string | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage.getItem(key);
  } catch {
    return null;
  }
}

function restoreRawStorageItem(key: string, previous: string | null, restored: boolean): boolean {
  try {
    if (typeof localStorage === "undefined") return restored;
    if (localStorage.getItem(key) === previous) return true;
    if (previous === null) localStorage.removeItem(key);
    else localStorage.setItem(key, previous);
    return true;
  } catch {
    return restored;
  }
}

/**
 * Writes the draft. The impact preview is recomputed first, so a timer or automation added since the
 * preview cannot slip through; a write that cannot be stored leaves the stored value untouched and
 * reports it, and a pause that cannot be stored puts the previous selection and stores back.
 */
export function applyDeviceTypeSelection(host: DeviceTypeSelectionHost): DeviceTypeSelectionApplyOutcome {
  const lang = currentLanguage();
  const session = getSession(host);
  const draft = deviceTypeSelectionDraft(host);
  const previous = appliedDeviceCategories(host);
  const preview = deviceTypeSelectionPreview(host, draft.categories, session.shownGeneration ?? "");
  clearTransient(session);
  if (preview.verdict.blockingReasons.some((reason) => reason.kind === "stalePreviewGeneration")) {
    session.error = tr3(
      "设备类型的影响刚刚发生变化，请查看更新后的预览并重新确认。",
      "裝置類型的影響剛剛發生變化，請查看更新後的預覽並重新確認。",
      "The impact of changing device types has changed. Review the updated preview and confirm again.",
      lang,
    );
    return { status: "stalePreview", preview };
  }
  if (!preview.verdict.canDeactivate) {
    session.error = tr3(
      "还无法更改设备类型：请先处理被阻塞的引用。",
      "還無法變更裝置類型：請先處理被封鎖的引用。",
      "Device types cannot change yet: resolve the blocked references first.",
      lang,
    );
    return { status: "blocked", preview };
  }
  if (sameDeviceCategories(draft.categories, previous)) {
    session.mode = null;
    session.customCategories = null;
    session.appliedNow = true;
    session.status = tr3("设备类型未变化。", "裝置類型未變更。", "Device types are unchanged.", lang);
    return { status: "applied", preview };
  }
  const contextHost = host as unknown as Parameters<typeof buildHostCapabilityContext>[0];
  const timerStore = storeFor(host);
  const ruleStore = ruleStoreFor(host);
  const identity = scheduledCommandIdentity(host.settings);
  const needsPause = preview.verdict.itemsToPause.length > 0;
  const timerSnapshot = needsPause ? timerStore.snapshotQueues() : null;
  const prevRules = needsPause ? ruleStore.load() : [];
  const rawTimers = readRawStorageItem(SCHEDULED_COMMANDS_STORAGE_KEY);
  const rawRules = readRawStorageItem(AutomationRuleStore.storageKey);
  const restoreReferences = (): boolean => {
    if (timerSnapshot === null) return true;
    const timersRestored = restoreRawStorageItem(
      SCHEDULED_COMMANDS_STORAGE_KEY, rawTimers, timerStore.restoreQueues(timerSnapshot),
    );
    const rulesRestored = restoreRawStorageItem(
      AutomationRuleStore.storageKey, rawRules, ruleStore.save(prevRules),
    );
    return timersRestored && rulesRestored;
  };
  const rollbackError = tr3(
    "无法完整恢复定时或自动化，请检查这些项目后再试。",
    "無法完整恢復定時或自動化，請檢查這些項目後再試。",
    "Could not fully restore the timers or automations. Check them before retrying.",
    lang,
  );
  const paused = needsPause ? applyPauseItemsFromVerdict({
    verdict: preview.verdict,
    scheduledCommandStore: timerStore,
    ruleStore,
    activeTimerIdentity: identity,
    activeConnectionScopes: buildHostCapabilityContext(contextHost).state.selection.enabledConnectionScopes,
  }) : { ok: true, pausedQuickActionIds: [] };
  if (!paused.ok) {
    session.error = restoreReferences() ? tr3(
      "无法暂停被引用的定时或自动化，设备类型保持原样。",
      "無法暫停被引用的定時或自動化，裝置類型維持原樣。",
      "Could not pause the affected timers or automations. Device types are unchanged.",
      lang,
    ) : rollbackError;
    return { status: "pauseFailed", preview };
  }
  const written = host.setEnabledDeviceCategories
    ? host.setEnabledDeviceCategories(draft.categories, paused.pausedQuickActionIds)
    : writeMiAccountSelectionMutation({
        mutate: (prev) => ({
          ...prev,
          extraFields: { ...prev.extraFields, enabledCategories: [...draft.categories] },
          pausedQuickActionIds: [...new Set([...prev.pausedQuickActionIds, ...paused.pausedQuickActionIds])],
        }),
      });
  if (!written) {
    session.error = restoreReferences() ? tr3(
      "本地设置暂时无法保存，设备类型保持原样。请检查磁盘空间或重启应用后再试。",
      "本機設定暫時無法儲存，裝置類型保持原樣。請檢查磁碟空間或重新啟動應用程式後再試。",
      "Could not save the setting, so the device types are unchanged. Check disk space or restart the app and try again.",
      lang,
    ) : rollbackError;
    return { status: "saveFailed", preview };
  }
  if (host.settings.connectionMode === "demo" && draft.categories.some((id) => !previous.includes(id))) {
    const context = buildHostCapabilityContext(contextHost);
    if (!context.dualSourceEnabled) {
      revalidateAfterMiAccountReenable({ context, scheduledCommandStore: timerStore, activeTimerIdentity: identity, ruleStore });
    }
  }
  session.mode = null;
  session.customCategories = null;
  session.appliedNow = true;
  session.status = tr3(
    `已应用：显示 ${draft.categories.length} 个设备类型，正在刷新设备。`,
    `已套用：顯示 ${draft.categories.length} 個裝置類型，正在重新整理裝置。`,
    `Applied: ${draft.categories.length} device type(s) shown; refreshing devices.`,
    lang,
  );
  refreshAfterSelectionChange(host);
  return { status: "applied", preview };
}

/**
 * Refreshes so the Mi/HA pruning plans (P3a-W, P3b-W) pick the new selection up. A sync that started
 * before this change already captured the previous one, so it is superseded first: its snapshot is
 * dropped by `cloudSnapshotIsStale` instead of drawing cards the user just hid (or omitting the ones
 * they just enabled).
 */
function refreshAfterSelectionChange(host: DeviceTypeSelectionHost): void {
  if (host.settings.connectionMode === "demo" && !buildHostCapabilityContext(host as unknown as Parameters<typeof buildHostCapabilityContext>[0]).dualSourceEnabled) return;
  if (host.isSyncingCloud) {
    host.sourceEpoch.claimSyncRun();
    host.isSyncingCloud = false;
  }
  void host.refreshDevices(false);
}

/**
 * Binds one device-type block. The guide and the Settings sheet each call this once per render, and
 * focus moves to the block's own status or error line after the re-render it triggers, so a keyboard
 * user never lands back at the top of the sheet.
 */
export function bindDeviceTypeSelectionEvents(host: DeviceTypeSelectionHost): void {
  const root = host.root;
  const session = getSession(host);
  root.querySelectorAll<HTMLElement>("[data-device-type-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      const mode = button.dataset.deviceTypeMode as DeviceCategorySelectionMode | undefined;
      if (!mode) return;
      const applied = appliedDeviceCategories(host);
      session.mode = mode;
      // 自己选 starts from what is stored, so unchecking one type is one click, not thirteen.
      if (mode === "custom") session.customCategories = session.customCategories ?? applied;
      clearTransient(session);
      host.render();
      focusAfterRender(host, `[data-device-type-mode="${mode}"]`);
    });
  });

  root.querySelectorAll<HTMLInputElement>("[data-device-type-category]").forEach((input) => {
    input.addEventListener("change", () => {
      const category = input.dataset.deviceTypeCategory as DeviceCategoryID | undefined;
      if (!category || !(DEVICE_CATEGORY_IDS as readonly string[]).includes(category)) return;
      const current = session.customCategories ?? appliedDeviceCategories(host);
      const next = toggleDeviceCategory(current, category);
      if (next.length === 0) {
        // An empty list would render as "everything checked" and the next toggle would act on it, so
        // the last type cannot be turned off: 全部 already means "show every type".
        clearTransient(session);
        session.error = tr3(
          "至少要保留一个设备类型。",
          "至少要保留一個裝置類型。",
          "Keep at least one device type.",
          currentLanguage(),
        );
        host.render();
        focusAfterRender(host, "[data-device-type-error]");
        return;
      }
      session.customCategories = next;
      session.mode = "custom";
      clearTransient(session);
      host.render();
      focusAfterRender(host, `[data-device-type-category="${category}"]`);
    });
  });

  root.querySelector("[data-device-type-cancel]")?.addEventListener("click", () => {
    session.mode = null;
    session.customCategories = null;
    clearTransient(session);
    host.render();
    focusAfterRender(host, "[data-device-type-mode]");
  });

  root.querySelector("[data-device-type-apply]")?.addEventListener("click", () => {
    const outcome = applyDeviceTypeSelection(host);
    host.render();
    if (outcome.status !== "applied") {
      focusAfterRender(host, "[data-device-type-error]");
      return;
    }
    // The status line is the answer the user just asked for; without it, the chosen mode keeps focus.
    if (!focusAfterRender(host, "[data-device-type-status]")) focusAfterRender(host, "[data-device-type-mode]");
  });
}

/** Whether the guide should offer the step at all: a platform is connected, or the demo home is open. */
export function deviceTypeSelectionIsAvailable(host: DeviceTypeSelectionHost): boolean {
  if (host.settings.connectionMode === "demo") return true;
  const state = resolveHostMiSelectionState(host as unknown as Parameters<typeof resolveHostMiSelectionState>[0]);
  return state.selection.enabledConnectionScopes.length > 0;
}

