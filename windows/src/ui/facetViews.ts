import { t } from "../core/i18n.js";
import {
  clampedPortionForControl,
  facetServiceTitle,
  isAdvancedWriteLocked,
  portionOptionsForControl,
} from "../core/miCloud/feedAction.js";
import { facetTitle, facetValue, formatReading } from "../core/miotFacetText.js";
import type { FacetControl } from "../core/models.js";
import { SF_ICONS } from "./appConstants.js";
import type { DeviceListCut } from "./listCut.js";

/**
 * 更多设置 rows (#5, #7): rendered from the shared `deviceProfiles.json` rules with 2-stage folding:
 * 1) Collapsed by default while a drawer opens; persists open/secondary-expanded/portion state
 *    across re-renders while that drawer stays open, and clears when the drawer closes, the room /
 *    kind filter changes, the panel blurs/hides, or the backend `sourceRevision` changes (§13).
 * 2) Highlighted (`isHighValue`) facets come first; secondary overflow (>6) folds behind
 *    `还有 {count} 项次要设置`.
 */
export const MORE_SETTINGS_VISIBLE_LIMIT = 6;

const LOCK_BADGE_SVG = `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path d="M10 3a4 4 0 00-4 4v2H5a1.5 1.5 0 00-1.5 1.5v5A1.5 1.5 0 005 17h10a1.5 1.5 0 001.5-1.5v-5A1.5 1.5 0 0015 9h-1V7a4 4 0 00-4-4zm-2.5 6V7a2.5 2.5 0 015 0v2h-5z"/></svg>`;

export interface MoreSettingsLifecycleHost {
  readonly root: HTMLElement;
  readonly settings: {
    readonly connectionMode: string;
    readonly selectedHomeId: string | null;
  };
  readonly sourceRevision: number;
  readonly listCut: DeviceListCut;
  readonly expandedDeviceId: string | null;
}

interface MoreSettingsState {
  host: MoreSettingsLifecycleHost | null;
  backendKey: string | null;
  listCutKey: string | null;
  expandedDeviceId: string | null;
  openDevices: Set<string>;
  restDevices: Set<string>;
  portions: Map<string, number>;
  revealed: { deviceId: string; controlId: string } | null;
}

const state: MoreSettingsState = {
  host: null,
  backendKey: null,
  listCutKey: null,
  expandedDeviceId: null,
  openDevices: new Set<string>(),
  restDevices: new Set<string>(),
  portions: new Map<string, number>(),
  revealed: null,
};

function serializeListCut(cut: DeviceListCut): string {
  if (cut.kind === "all") return "all";
  if (cut.kind === "room") return `room:${cut.roomId}`;
  return `kind:${cut.tag}`;
}

function clearDeviceState(deviceId: string): void {
  state.openDevices.delete(deviceId);
  state.restDevices.delete(deviceId);
  for (const key of [...state.portions.keys()]) {
    if (key.startsWith(`${deviceId}|`)) state.portions.delete(key);
  }
  if (state.revealed?.deviceId === deviceId) {
    state.revealed = null;
  }
}

export function resetMoreSettingsState(): void {
  state.openDevices.clear();
  state.restDevices.clear();
  state.portions.clear();
  state.revealed = null;
}

/** Reconciles lifecycle transitions before rendering or binding so stale drawer state never leaks (§13). */
export function syncMoreSettingsHost(host?: MoreSettingsLifecycleHost): void {
  if (host && state.host !== host) {
    resetMoreSettingsState();
    state.host = host;
    state.backendKey = `${host.settings.connectionMode}|${host.settings.selectedHomeId ?? ""}|${host.sourceRevision}`;
    state.listCutKey = serializeListCut(host.listCut);
    state.expandedDeviceId = host.expandedDeviceId;
    return;
  }
  const active = host ?? state.host;
  if (!active) return;
  if (!active.root.isConnected) {
    resetMoreSettingsState();
    state.host = null;
    state.backendKey = null;
    state.listCutKey = null;
    state.expandedDeviceId = null;
    return;
  }
  const nextBackend = `${active.settings.connectionMode}|${active.settings.selectedHomeId ?? ""}|${active.sourceRevision}`;
  const nextCut = serializeListCut(active.listCut);
  if (
    (state.backendKey !== null && state.backendKey !== nextBackend) ||
    (state.listCutKey !== null && state.listCutKey !== nextCut)
  ) {
    resetMoreSettingsState();
  } else if (state.expandedDeviceId !== active.expandedDeviceId) {
    if (state.expandedDeviceId !== null) {
      clearDeviceState(state.expandedDeviceId);
    }
  }
  state.backendKey = nextBackend;
  state.listCutKey = nextCut;
  state.expandedDeviceId = active.expandedDeviceId;
}

export function isMoreSettingsExpanded(deviceId: string): boolean {
  syncMoreSettingsHost();
  return state.openDevices.has(deviceId);
}

export function toggleMoreSettingsExpanded(deviceId: string): boolean {
  syncMoreSettingsHost();
  if (state.openDevices.has(deviceId)) {
    state.openDevices.delete(deviceId);
    state.restDevices.delete(deviceId);
    if (state.revealed?.deviceId === deviceId) state.revealed = null;
    return false;
  }
  state.openDevices.add(deviceId);
  return true;
}

export function isMoreSettingsRestExpanded(deviceId: string): boolean {
  syncMoreSettingsHost();
  return state.restDevices.has(deviceId);
}

export function toggleMoreSettingsRest(deviceId: string): boolean {
  syncMoreSettingsHost();
  if (state.restDevices.has(deviceId)) {
    state.restDevices.delete(deviceId);
    return false;
  }
  state.openDevices.add(deviceId);
  state.restDevices.add(deviceId);
  return true;
}

export function revealFacetRow(
  deviceId: string,
  controlId: string,
  facets: readonly FacetControl[],
): void {
  syncMoreSettingsHost();
  state.openDevices.add(deviceId);
  const ordered = orderFacets(facets);
  const folded = ordered.slice(MORE_SETTINGS_VISIBLE_LIMIT);
  if (controlId && folded.some((control) => control.id === controlId)) {
    state.restDevices.add(deviceId);
  }
  state.revealed = controlId ? { deviceId, controlId } : null;
}

export function selectedPortionForControl(deviceId: string, control: FacetControl): number {
  const chosen = state.portions.get(`${deviceId}|${control.id}`);
  return clampedPortionForControl(control, chosen);
}

export function setSelectedPortionForControl(
  deviceId: string,
  control: FacetControl,
  portion: number,
): number {
  const clamped = clampedPortionForControl(control, portion);
  state.portions.set(`${deviceId}|${control.id}`, clamped);
  return clamped;
}

export function facetRowDomId(deviceId: string, controlId: string): string {
  const clean = (raw: string) => raw.replace(/[^a-zA-Z0-9_-]/g, "_");
  return `facet-row-${clean(deviceId)}-${clean(controlId)}`;
}

export function orderFacets(facets: readonly FacetControl[]): FacetControl[] {
  return [
    ...facets.filter((control) => control.isHighValue),
    ...facets.filter((control) => !control.isHighValue),
  ];
}

/**
 * False for a write outside the low-risk whitelist while 允许写入高级属性 is off — except for
 * `isConfirmedWrite` (`FeedAction`), which relies on its own confirmation prompt instead (#7).
 */
export function facetWriteEnabled(
  control: FacetControl,
  allowAdvanced: boolean,
  isOnline = true,
): boolean {
  return (
    isOnline &&
    control.isWritable &&
    control.target !== null &&
    (control.writesByDefault || control.isConfirmedWrite === true || allowAdvanced)
  );
}

function duplicateFacetTitles(ordered: readonly FacetControl[]): Set<string> {
  const seen = new Set<string>();
  const duplicates = new Set<string>();
  for (const control of ordered) {
    const title = facetTitle(control);
    if (seen.has(title)) duplicates.add(title);
    else seen.add(title);
  }
  return duplicates;
}

export function displayFacetTitle(
  control: FacetControl,
  duplicateTitles: ReadonlySet<string>,
): string {
  const title = facetTitle(control);
  if (!duplicateTitles.has(title)) return title;
  const service = facetServiceTitle(control.serviceName);
  return service ? `${title} · ${service}` : title;
}

function row(
  control: FacetControl,
  deviceId: string,
  allowAdvanced: boolean,
  isOnline: boolean,
  duplicateTitles: ReadonlySet<string>,
  escapeHtml: (v: string) => string,
): string {
  const id = escapeHtml(deviceId);
  const controlId = escapeHtml(control.id);
  const rawTitle = displayFacetTitle(control, duplicateTitles);
  const label = escapeHtml(rawTitle);
  const value = escapeHtml(facetValue(control));
  const enabled = facetWriteEnabled(control, allowAdvanced, isOnline);
  const locked = isAdvancedWriteLocked(control, allowAdvanced);
  const disabledAttr = enabled ? "" : ' disabled aria-disabled="true"';
  const highRisk = !control.writesByDefault && control.isWritable;
  const isRevealed =
    state.revealed?.deviceId === deviceId && state.revealed.controlId === control.id;
  const rowDomId = escapeHtml(facetRowDomId(deviceId, control.id));
  const rowClasses = (kindClass: string) =>
    `cc-facet-row ${kindClass}${locked ? " is-locked" : ""}${isRevealed ? " is-revealed" : ""}`;
  const lockBadge = locked
    ? `<span class="cc-facet-lock" title="${t("默认只读")}" aria-label="${t("默认只读")}">${LOCK_BADGE_SVG}</span>`
    : "";

  if (control.kind === "reading" || !control.isWritable) {
    return `<div id="${rowDomId}" class="${rowClasses("is-reading")}">
      <span class="cc-facet-label">${label}</span>
      <strong class="cc-facet-value">${value}</strong>
    </div>`;
  }
  if (control.kind === "select" && control.options.length > 0) {
    const current = typeof control.value === "number" ? Math.trunc(control.value) : null;
    return `<div id="${rowDomId}" class="${rowClasses("is-select")}">
      <div class="cc-slider-label">
        <span class="cc-facet-label">${label}</span>
        ${lockBadge}
      </div>
      <div class="cc-segmented-pills">
        ${control.options
          .map(
            (option) => `<button class="cc-seg-pill ${current === option.value ? "is-active" : ""}"
              data-facet-select="${id}|${controlId}|${option.value}"${disabledAttr}
              aria-pressed="${current === option.value}">
              ${escapeHtml(option.label)}
            </button>`,
          )
          .join("")}
      </div>
    </div>`;
  }
  if (control.kind === "slider" && control.range) {
    const current = typeof control.value === "number" ? control.value : control.range.min;
    return `<div id="${rowDomId}" class="${rowClasses("is-slider")}">
      <div class="cc-slider-label">
        <span class="cc-facet-label">${label}</span>
        <span class="cc-facet-slider-meta"><strong class="cc-facet-value">${value}</strong>${lockBadge}</span>
      </div>
      <input class="cc-range is-blue" type="range"
        min="${formatReading(control.range.min)}" max="${formatReading(control.range.max)}"
        step="${formatReading(control.range.step)}" value="${formatReading(current)}"
        data-facet-number="${id}|${controlId}" aria-label="${label}"
        aria-valuemin="${formatReading(control.range.min)}" aria-valuemax="${formatReading(control.range.max)}"
        aria-valuenow="${formatReading(current)}" aria-valuetext="${value}"${disabledAttr} />
    </div>`;
  }
  if (control.kind === "button") {
    const portions = portionOptionsForControl(control);
    const selectedPortion = portions.length > 0 ? selectedPortionForControl(deviceId, control) : null;
    const portionPicker =
      portions.length > 0
        ? `<select class="cc-facet-portion-select" data-facet-portion="${id}|${controlId}" aria-label="${t("投喂份数")}"${disabledAttr}>
            ${portions
              .map(
                (count) =>
                  `<option value="${count}"${count === selectedPortion ? " selected" : ""}>${escapeHtml(t("{count} 份", { count }))}</option>`,
              )
              .join("")}
          </select>`
        : "";
    const fedToday = control.fedToday
      ? `<span class="cc-facet-fed-today">${escapeHtml(t("今日已投喂 {fed}", { fed: control.fedToday }))}</span>`
      : "";
    return `<div id="${rowDomId}" class="${rowClasses("is-button")}">
      <div class="cc-facet-button-bar">
        <button class="cc-seg-pill" data-facet-action="${id}|${controlId}"${disabledAttr}>
          ${label}
        </button>
        ${portionPicker}
        ${lockBadge}
      </div>
      ${fedToday}
    </div>`;
  }
  return `<div id="${rowDomId}" class="${rowClasses("is-toggle")}">
    <span class="cc-facet-label">${label}</span>
    <button class="cc-seg-pill ${control.value === true || control.value === 1 ? "is-active" : ""} ${highRisk ? "is-high-risk" : ""}"
      data-facet-toggle="${id}|${controlId}" aria-pressed="${control.value === true || control.value === 1}"${disabledAttr}>
      ${value}
    </button>
    ${lockBadge}
  </div>`;
}

/** The 更多设置 section appended to every detail drawer; empty when the device has no facets. */
export function renderMoreSettings(options: {
  readonly deviceId: string;
  readonly facets: readonly FacetControl[];
  readonly allowAdvanced: boolean;
  readonly isOnline?: boolean;
  readonly escapeHtml: (value: string) => string;
}): string {
  if (options.facets.length === 0) return "";
  syncMoreSettingsHost();
  const isOnline = options.isOnline ?? true;
  const id = options.escapeHtml(options.deviceId);
  const ordered = orderFacets(options.facets);
  const visible = ordered.slice(0, MORE_SETTINGS_VISIBLE_LIMIT);
  const folded = ordered.slice(MORE_SETTINGS_VISIBLE_LIMIT);
  const duplicates = duplicateFacetTitles(ordered);
  const isExpanded = state.openDevices.has(options.deviceId);
  const showsRest = state.restDevices.has(options.deviceId);
  const hasLockedRow = ordered.some((control) =>
    isAdvancedWriteLocked(control, options.allowAdvanced),
  );
  const lockNotice = hasLockedRow
    ? `<div class="cc-facet-lock-notice">
        <span>${t("部分高级项默认只读，防止误操作")}</span>
        <button class="cc-inline-pill" data-open-facet-settings="${id}">${t("允许修改…")}</button>
      </div>`
    : "";
  const restToggle =
    folded.length > 0
      ? `<button class="cc-facet-more-btn" data-more-settings-rest="${id}" aria-expanded="${showsRest}">
          <span>${showsRest ? t("收起次要设置") : t("还有 {count} 项次要设置", { count: folded.length })}</span>
          <i class="cc-mini-caret ${showsRest ? "is-open" : ""}" aria-hidden="true">${SF_ICONS.chevronDown}</i>
        </button>`
      : "";
  const foldedRows =
    folded.length > 0 && showsRest
      ? folded
          .map((control) =>
            row(control, options.deviceId, options.allowAdvanced, isOnline, duplicates, options.escapeHtml),
          )
          .join("")
      : "";

  return `<div class="cc-facet-section ${isExpanded ? "is-open" : "is-collapsed"}">
    <button class="cc-facet-header" data-more-settings-toggle="${id}" aria-expanded="${isExpanded}">
      <span class="cc-icon-inline cc-facet-header-icon" aria-hidden="true">${SF_ICONS.sliderHorizontal}</span>
      <span class="cc-facet-header-title">${t("更多设置")}</span>
      <span class="cc-facet-header-count">${ordered.length}</span>
      <i class="cc-mini-caret ${isExpanded ? "is-open" : ""}" aria-hidden="true">${SF_ICONS.chevronRight}</i>
    </button>
    <div class="cc-facet-body"${isExpanded ? "" : " hidden"}>
      ${lockNotice}
      ${visible
        .map((control) =>
          row(control, options.deviceId, options.allowAdvanced, isOnline, duplicates, options.escapeHtml),
        )
        .join("")}
      ${restToggle}
      ${foldedRows}
    </div>
  </div>`;
}
