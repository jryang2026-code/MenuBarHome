import { normalizeSearch, panelQueryKind } from "../core/panelSearch.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { hasPendingUrlConfirmation, resumeUndoHoverPause } from "./speechGuard.js";
import { invokeTauriVoid } from "./transport.js";

function allTiles(host: MenuMijiaWindowsApp): HTMLElement[] {
  return [...host.root.querySelectorAll<HTMLElement>("[data-tile-id]")];
}

function tiles(host: MenuMijiaWindowsApp): HTMLElement[] {
  const subpage = host.root.querySelector<HTMLElement>(".cc-tile.is-subpage[data-tile-id]");
  if (subpage) return [subpage];
  return allTiles(host);
}

function selectedTile(host: MenuMijiaWindowsApp): HTMLElement | undefined {
  return tiles(host).find((tile) => tile.dataset.tileId === host.panelSearch.selectedDeviceId);
}

export function syncPanelSelection(host: MenuMijiaWindowsApp): void {
  const cards = tiles(host);
  if (!cards.some((card) => card.dataset.tileId === host.panelSearch.selectedDeviceId)) {
    host.panelSearch.selectedDeviceId = normalizeSearch(host.panelSearch.query) ? cards[0]?.dataset.tileId ?? null : null;
    host.panelSearch.explicitSelection = false;
  }
  const visibleCards = new Set(cards);
  allTiles(host).forEach((card) => {
    if (!visibleCards.has(card)) {
      card.removeAttribute("id");
      card.classList.remove("is-keyboard-selected");
      card.removeAttribute("aria-current");
    }
  });
  cards.forEach((card, index) => {
    card.id = `panel-device-${index}`;
    const selected = card.dataset.tileId === host.panelSearch.selectedDeviceId;
    card.classList.toggle("is-keyboard-selected", selected);
    if (selected) card.setAttribute("aria-current", "true");
    else card.removeAttribute("aria-current");
  });
  const hasQuery = Boolean(normalizeSearch(host.panelSearch.query));
  if (hasQuery && host.panelSearch.selectedDeviceId) {
    host.root.dataset.keyboardNav = "true";
  } else if (!host.panelSearch.selectedDeviceId) {
    delete host.root.dataset.keyboardNav;
  }
  const input = host.root.querySelector<HTMLInputElement>("#command-input");
  const selected = selectedTile(host);
  if (selected && hasQuery) input?.setAttribute("aria-activedescendant", selected.id);
  else input?.removeAttribute("aria-activedescendant");
}

function updateQuery(host: MenuMijiaWindowsApp, value: string): void {
  host.panelSearch.query = value;
  host.panelSearch.selectedDeviceId = null;
  host.panelSearch.explicitSelection = false;
  if (!host.panelSearch.isComposing) host.render();
}

export function bindPanelInput(host: MenuMijiaWindowsApp): void {
  const input = host.root.querySelector<HTMLInputElement>("#command-input");
  input?.addEventListener("compositionstart", () => {
    host.panelSearch.isComposing = true;
    host.panelSearch.compositionSourceRevision = host.sourceRevision;
  });
  input?.addEventListener("compositionend", () => {
    host.panelSearch.isComposing = false;
    updateQuery(host, input.value);
  });
  input?.addEventListener("input", () => updateQuery(host, input.value));
  input?.addEventListener("blur", () => finishPanelComposition(host));
  host.root.querySelector("#btn-send")?.addEventListener("click", () => submitPanelInput(host, true));
  host.root.querySelector("#btn-clear-search")?.addEventListener("click", () => {
    if (host.panelSearch.isComposing) return;
    if (input) input.value = "";
    updateQuery(host, "");
    host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
  });
  tiles(host).forEach((tile) => tile.addEventListener("pointerdown", () => {
    host.panelSearch.selectedDeviceId = tile.dataset.tileId ?? null;
    host.panelSearch.explicitSelection = true;
    delete host.root.dataset.keyboardNav;
    syncPanelSelection(host);
  }));
}

export function finishPanelComposition(host: MenuMijiaWindowsApp): void {
  if (!host.panelSearch.isComposing) return;
  host.panelSearch.isComposing = false;
  updateQuery(host, host.root.querySelector<HTMLInputElement>("#command-input")?.value ?? host.panelSearch.query);
}

export function submitPanelInput(host: MenuMijiaWindowsApp, forceCommand = false): void {
  if (host.panelSearch.isComposing || host.isResolvingIntent) return;
  const input = host.root.querySelector<HTMLInputElement>("#command-input");
  const query = input?.value ?? host.panelSearch.query;
  if (!normalizeSearch(query)) return;
  // Button submission and paste use the live field, even before an input event arrives.
  if (query !== host.panelSearch.query) updateQuery(host, query);
  const kind = panelQueryKind(query, host.devices, host.scenes, host.layout.aliases);
  const hasSelection = selectedTile(host) !== undefined;
  if (forceCommand || ((kind === "command" || !hasSelection) && !(host.panelSearch.explicitSelection && hasSelection))) {
    host.panelSearch.query = "";
    host.panelSearch.selectedDeviceId = null;
    host.panelSearch.explicitSelection = false;
    const liveInput = host.root.querySelector<HTMLInputElement>("#command-input");
    const restoreFocus = document.activeElement === liveInput;
    if (input) input.value = "";
    if (liveInput) liveInput.value = "";
    void host.handleNaturalCommand(query).finally(() => {
      if (!restoreFocus || document.activeElement !== null && document.activeElement !== document.body && document.activeElement !== liveInput) return;
      host.root.querySelector<HTMLInputElement>("#command-input")?.focus({ preventScroll: true });
    });
    return;
  }
  toggleSelection(host);
}

function toggleSelection(host: MenuMijiaWindowsApp): void {
  const id = host.panelSearch.selectedDeviceId;
  const device = host.devices.find((item) => item.id === id);
  if (!device?.isOnline || host.waitingDeviceIds.has(device.id) || host.valuesAreStale) return;
  const card = selectedTile(host);
  const toggle = card?.querySelector<HTMLButtonElement>("[data-toggle-device]");
  if (toggle) toggle.click();
  else card?.querySelector<HTMLButtonElement>("[data-body-device], [data-expand-device]")?.click();
}

function expandSelection(host: MenuMijiaWindowsApp): void {
  if (!selectedTile(host) || host.expandedDeviceId === host.panelSearch.selectedDeviceId) return;
  host.expandedDeviceId = host.panelSearch.selectedDeviceId;
  host.render();
}

function adjustSelection(host: MenuMijiaWindowsApp, direction: number): void {
  const device = host.devices.find((item) => item.id === host.panelSearch.selectedDeviceId);
  if (!device?.isOnline || host.waitingDeviceIds.has(device.id) || host.valuesAreStale) return;
  if (host.expandedDeviceId !== device.id) expandSelection(host);
  const card = selectedTile(host);
  const step = [...(card?.querySelectorAll<HTMLButtonElement>("[data-acstep]") ?? [])]
    .find((button) => button.dataset.acstep === `${device.id}:${direction}`);
  if (step) { step.click(); return; }
  const range = card?.querySelector<HTMLInputElement>("[data-brightness], [data-actemp], [data-fanpercent], [data-volume]");
  if (!range || range.disabled) return;
  const delta = range.hasAttribute("data-actemp") ? Number(range.step) || 1 : 5;
  range.value = String(Math.min(Number(range.max), Math.max(Number(range.min), Number(range.value) + delta * direction)));
  range.dispatchEvent(new Event("change", { bubbles: true }));
}

export function handlePanelKey(host: MenuMijiaWindowsApp, event: KeyboardEvent): boolean {
  if (event.defaultPrevented) return true;
  if (event.isComposing || event.keyCode === 229 || host.panelSearch.isComposing) return true;
  if (
    host.activeSheet !== "none" ||
    hasPendingUrlConfirmation(host) ||
    (host.cameraLive.activeLiveCameraId !== null && !host.cameraLive.liveCameraHidden)
  ) {
    return false;
  }
  if (host.prompt) {
    if (event.key === "Escape") { event.preventDefault(); host.closePrompt(); }
    return true;
  }
  if (host.isEditingLayout || host.ctxMenu || host.isHomeMenuOpen) return false;
  const input = host.root.querySelector<HTMLInputElement>("#command-input");
  const active = document.activeElement;
  const inInput = active === input;
  const isEditable = Boolean(
    active?.matches(
      "input:not([type='range']):not([type='checkbox']):not([type='radio']):not([type='button']), textarea, select, [contenteditable='true']",
    ),
  );
  const isNonTextInput = Boolean(active?.matches("input")) && !inInput && !isEditable;
  if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key === ",") {
    event.preventDefault();
    if (!event.repeat) host.openSettingsSheet();
    return true;
  }
  if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key.toLowerCase() === "f") {
    if (isEditable && !inInput) return false;
    event.preventDefault();
    host.isShowingAssistantBar = true;
    host.expandedDeviceId = null;
    host.render();
    host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
    return true;
  }
  if (event.ctrlKey || event.metaKey || event.altKey) return false;
  if (isEditable && !inInput) return true;
  const hasSubpage = Boolean(host.root.querySelector(".cc-tile.is-subpage"));
  if (!hasSubpage && !inInput && !isEditable && !isNonTextInput && event.key === "Tab") {
    const roomPills = [...host.root.querySelectorAll<HTMLButtonElement>(".cc-room-pill[data-room]")];
    if (roomPills.length > 0) {
      event.preventDefault();
      if (!event.repeat) {
        const activeIdx = roomPills.findIndex(
          (pill) => pill.classList.contains("is-active") || pill.getAttribute("aria-pressed") === "true",
        );
        const delta = event.shiftKey ? -1 : 1;
        const nextIdx =
          activeIdx < 0
            ? event.shiftKey
              ? roomPills.length - 1
              : 0
            : (activeIdx + delta + roomPills.length) % roomPills.length;
        roomPills[nextIdx]?.click();
      }
      return true;
    }
  }
  if (active?.closest("button, a[href], [role='button'], [role='link']") &&
      [" ", "Enter", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)) return true;
  if (event.key === "Escape" && host.expandedDeviceId && (hasSubpage || !inInput)) {
    event.preventDefault(); host.expandedDeviceId = null; host.render(); return true;
  }
  if (event.key === "Escape" && (host.panelSearch.query || inInput)) {
    event.preventDefault();
    if (input) input.value = "";
    updateQuery(host, "");
    host.root.querySelector<HTMLInputElement>("#command-input")?.blur();
    return true;
  }
  if (event.key === "Escape" && host.expandedDeviceId) {
    event.preventDefault(); host.expandedDeviceId = null; host.render(); return true;
  }
  if (event.key === "Escape" && host.panelSearch.selectedDeviceId) {
    event.preventDefault(); host.panelSearch.selectedDeviceId = null; syncPanelSelection(host); return true;
  }
  if (event.key === "Escape" && !isEditable) {
    event.preventDefault();
    resumeUndoHoverPause(host);
    invokeTauriVoid("hide_panel");
    return true;
  }
  if (isNonTextInput) return true;
  const hasQuery = Boolean(normalizeSearch(host.panelSearch.query));
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    const cards = tiles(host);
    const index = cards.findIndex((card) => card.dataset.tileId === host.panelSearch.selectedDeviceId);
    const next = index < 0 ? (event.key === "ArrowDown" ? 0 : cards.length - 1)
      : Math.max(0, Math.min(cards.length - 1, index + (event.key === "ArrowDown" ? 1 : -1)));
    host.panelSearch.selectedDeviceId = cards[next]?.dataset.tileId ?? null;
    host.panelSearch.explicitSelection = true;
    host.root.dataset.keyboardNav = "true";
    event.preventDefault(); syncPanelSelection(host);
    selectedTile(host)?.scrollIntoView?.({ block: "nearest" });
    return true;
  }
  if (event.key === "Enter" && (inInput || active === document.body || active === host.root)) {
    event.preventDefault();
    if (!event.repeat) { if (hasQuery) submitPanelInput(host); else toggleSelection(host); }
    return true;
  }
  if (event.key === "ArrowRight" && inInput && input && input.selectionStart === input.value.length && input.selectionEnd === input.selectionStart && hasQuery && host.panelSearch.selectedDeviceId) {
    event.preventDefault(); expandSelection(host);
    host.root.querySelector<HTMLInputElement>("#command-input")?.blur();
    return true;
  }
  if (!inInput && !isEditable && (event.key === "ArrowLeft" || event.key === "ArrowRight") && host.panelSearch.selectedDeviceId) {
    event.preventDefault(); adjustSelection(host, event.key === "ArrowRight" ? 1 : -1); return true;
  }
  if (!inInput && !isEditable && event.key === " " && host.panelSearch.selectedDeviceId) {
    event.preventDefault(); if (!event.repeat) toggleSelection(host); return true;
  }
  if (!inInput && !isEditable && event.key === "/") {
    event.preventDefault();
    host.isShowingAssistantBar = true;
    host.expandedDeviceId = null;
    host.render();
    const field = host.root.querySelector<HTMLInputElement>("#command-input");
    field?.focus();
    field?.setSelectionRange(field.value.length, field.value.length);
    return true;
  }
  if (!hasSubpage && !inInput && !isEditable && /^[1-9]$/.test(event.key) && !hasQuery) {
    const roomPills = host.root.querySelectorAll<HTMLButtonElement>(".cc-room-pill[data-room]");
    const targetPill = roomPills[Number(event.key) - 1];
    if (targetPill) {
      event.preventDefault();
      if (!event.repeat) targetPill.click();
      return true;
    }
  }
  if (!inInput && !isEditable && event.key.length === 1 && event.key !== " " && !/^[1-9/]$/.test(event.key)) {
    event.preventDefault();
    host.isShowingAssistantBar = true;
    host.expandedDeviceId = null;
    updateQuery(host, host.panelSearch.query + event.key);
    const field = host.root.querySelector<HTMLInputElement>("#command-input");
    field?.focus(); field?.setSelectionRange(field.value.length, field.value.length);
    return true;
  }
  return false;
}
