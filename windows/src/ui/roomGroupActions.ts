import { ManualControlPolicy } from "../core/assistant.js";
import { t, tr3 } from "../core/i18n.js";
import { evaluateDeviceEntityWriteGate, evaluateIntentsWriteGate } from "../core/miAccountControl.js";
import type { DeviceCommand, DeviceIntent, SmartDevice } from "../core/models.js";
import { buildRoomAutoGroups, type RoomAutoGroup } from "../core/roomAutoGroup.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import type { UndoStep } from "./appTypes.js";
import { buildHostCapabilityContext, isDualSourceEnabled } from "./cloudRefresh.js";
import { effectiveCommandBackend } from "./commandDispatch.js";
import { withAliases } from "./panelPrefs.js";
import { isWorkstationLockBlockingControl } from "./transport.js";

export interface PendingRoomGroupConfirm {
  readonly group: RoomAutoGroup;
  readonly action: { readonly kind: "toggle" } | { readonly kind: "brightness"; readonly percent: number };
  readonly riskyNames: readonly string[];
  readonly sourceRevision: number;
}

function roomGroupWriteGate(
  host: MenuMijiaWindowsApp,
  device: SmartDevice,
  context = buildHostCapabilityContext(host),
): string | null {
  return evaluateDeviceEntityWriteGate({
    targetKind: "device",
    targetIdOrEntityId: device.id,
    resolvedActiveDeviceId: device.id,
    context,
    languagePreference: host.settings.interfaceLanguage,
  });
}

export function visibleRoomAutoGroups(host: MenuMijiaWindowsApp): RoomAutoGroup[] {
  const cut = host.listCut;
  if (cut.kind !== "room" || host.isEditingLayout || host.panelSearch.query.trim()) return [];
  const context = buildHostCapabilityContext(host);
  const eligible = withAliases(host.layout, host.devices).filter((device) =>
    device.roomId === cut.roomId && roomGroupWriteGate(host, device, context) === null,
  );
  return buildRoomAutoGroups(cut.roomId, cut.roomName, eligible);
}

export function renderRoomAutoGroupBar(host: MenuMijiaWindowsApp): string {
  const groups = visibleRoomAutoGroups(host);
  const confirm = host.pendingRoomGroupConfirm;
  if (groups.length === 0 && !confirm) return "";
  const pills = groups
    .map((g) => {
      const summary = g.statusSummary ? `<span class="cc-room-group-meta">${host.escapeHtml(g.statusSummary)}</span>` : "";
      const brightControl = g.kind === "light" && g.supportsBrightnessControl
        ? `<input type="range" class="cc-room-group-slider" min="1" max="100" value="${g.averageBrightness ?? 80}" data-room-group-brightness="${host.escapeHtml(g.id)}" aria-label="${host.escapeHtml(g.label)}" />`
        : "";
      return `<div class="cc-room-group-item">
        <button type="button" class="cc-room-group-pill ${g.isAnyOn ? "is-on" : ""}" data-room-group-toggle="${host.escapeHtml(g.id)}" aria-pressed="${g.isAnyOn}">
          <span>${host.escapeHtml(g.label)}</span>${summary}
        </button>${brightControl}
      </div>`;
    })
    .join("");
  const confirmBar = confirm
    ? `<div class="cc-diff-preview-card is-high-risk" role="alert">
        <div class="cc-diff-preview-title">${host.escapeHtml(t("确认群控「{name}」？（高风险：{devices}）", { name: confirm.group.label, devices: confirm.riskyNames.join("、") }))}</div>
        <div class="cc-diff-preview-actions">
          <button type="button" class="cc-inline-pill" id="btn-room-group-cancel">${t("取消")}</button>
          <button type="button" class="cc-inline-pill is-primary" id="btn-room-group-confirm">${t("确认执行")}</button>
        </div>
      </div>`
    : "";
  return `${pills ? `<div class="cc-room-group-bar" role="toolbar">${pills}</div>` : ""}${confirmBar}`;
}

export function renderDiffPreviewCard(host: MenuMijiaWindowsApp): string {
  const preview = host.pendingDiffPreview;
  if (!preview) return "";
  const title = preview.hasHighRiskDevice
    ? t("确认执行 {count} 项变更（含高风险设备）", { count: preview.items.length })
    : t("确认执行 {count} 项设备变更", { count: preview.items.length });
  const rows = preview.items
    .map((item) => `<div class="cc-diff-preview-row ${item.isHighRisk ? "is-high-risk" : ""}">
      <span class="cc-diff-preview-name">${host.escapeHtml(item.deviceName)}</span>
      <span class="cc-diff-preview-change">${host.escapeHtml(item.fromState)} → ${host.escapeHtml(item.toState)}</span>
    </div>`)
    .join("");
  return `<div class="cc-diff-preview-card ${preview.hasHighRiskDevice ? "is-high-risk" : ""}" id="assistant-diff-preview" role="region" aria-label="${host.escapeHtml(title)}">
    <div class="cc-diff-preview-title">${host.escapeHtml(title)}</div>
    <div class="cc-diff-preview-list">${rows}</div>
    <div class="cc-diff-preview-actions">
      <button type="button" class="cc-inline-pill" id="btn-diff-cancel">${t("取消")}</button>
      <button type="button" class="cc-inline-pill is-primary" id="btn-diff-confirm">${t("确认执行")}</button>
    </div>
  </div>`;
}

export async function confirmPendingDiffPreview(host: MenuMijiaWindowsApp): Promise<boolean> {
  const preview = host.pendingDiffPreview;
  if (!preview) return false;
  host.pendingDiffPreview = null;
  if (preview.sourceRevision !== host.sourceRevision) {
    host.render();
    return false;
  }
  if (await isWorkstationLockBlockingControl(host)) {
    host.replyBanner = { text: t("屏幕已锁定，已阻止控制操作"), source: t("控制失败"), isError: true };
    host.render();
    return false;
  }
  if (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)) {
    const gateMsg = evaluateIntentsWriteGate({
      intents: preview.intents,
      context: buildHostCapabilityContext(host),
      languagePreference: host.settings.interfaceLanguage,
    });
    if (gateMsg !== null) {
      host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
      host.render();
      return false;
    }
  }
  const ok = await host.executeIntents([...preview.intents], preview.replyText, preview.sourceLabel, {
    recordHabits: preview.recordHabits,
  });
  host.render();
  return ok;
}

export function cancelPendingDiffPreview(host: MenuMijiaWindowsApp): void {
  if (!host.pendingDiffPreview) return;
  host.pendingDiffPreview = null;
  host.replyBanner = { text: t("已取消"), source: t("已取消") };
  host.render();
}

export async function executeRoomGroupAction(
  host: MenuMijiaWindowsApp,
  group: RoomAutoGroup,
  action: { readonly kind: "toggle" } | { readonly kind: "brightness"; readonly percent: number },
  confirmedHighRisk = false,
): Promise<boolean> {
  const sourceRevision = host.sourceRevision;
  const homeRevision = host.homeRevision;
  const contextChanged = () => sourceRevision !== host.sourceRevision || homeRevision !== host.homeRevision;
  const lockedMessage = t("屏幕已锁定，已阻止控制操作");
  const staleMessage = t("设备列表已更新，请重新执行");
  const fail = (text: string) => {
    host.replyBanner = { text, source: t("控制失败"), isError: true };
    host.render();
    return false;
  };

  host.pendingRoomGroupConfirm = null;
  if (await isWorkstationLockBlockingControl(host)) return fail(lockedMessage);
  if (contextChanged()) return false;
  const aliased = withAliases(host.layout, host.devices);
  const byId = new Map<string, SmartDevice>(aliased.map((d) => [d.id, d]));
  const members = group.deviceIds.map((id) => byId.get(id)).filter((d): d is SmartDevice => Boolean(d?.isOnline));
  if (members.length === 0) return fail(staleMessage);

  const targetOn = action.kind === "toggle" ? !group.isAnyOn : true;
  const clampedBrightness = action.kind === "brightness" ? Math.max(1, Math.min(100, Math.round(action.percent))) : null;

  const intents: DeviceIntent[] = [];
  const coverTargets: SmartDevice[] = [];
  for (const dev of members) {
    if (dev.kind.kind === "cover") {
      coverTargets.push(dev);
    } else if (action.kind === "brightness" && clampedBrightness !== null) {
      intents.push({ targetId: dev.id, operation: { kind: "brightness", percent: clampedBrightness } });
    } else {
      intents.push({ targetId: dev.id, operation: { kind: "power", isOn: targetOn } });
    }
  }

  if (intents.length > 0 && (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host))) {
    const gateMsg = evaluateIntentsWriteGate({
      intents,
      context: buildHostCapabilityContext(host),
      languagePreference: host.settings.interfaceLanguage,
    });
    if (gateMsg !== null) return fail(gateMsg);
  }

  if (coverTargets.length > 0) {
    const context = buildHostCapabilityContext(host);
    for (const cover of coverTargets) {
      const gateMsg = roomGroupWriteGate(host, cover, context);
      if (gateMsg !== null) return fail(gateMsg);
    }
  }

  const riskyNames: string[] = [];
  for (const intent of intents) {
    if (ManualControlPolicy.requiresConfirmation(intent, aliased)) {
      const name = byId.get(intent.targetId)?.name ?? intent.targetId;
      if (!riskyNames.includes(name)) riskyNames.push(name);
    }
  }
  for (const cover of coverTargets) {
    if (ManualControlPolicy.requiresConfirmation({ targetId: cover.id, operation: { kind: "power", isOn: targetOn } }, aliased)) {
      if (!riskyNames.includes(cover.name)) riskyNames.push(cover.name);
    }
  }

  if (riskyNames.length > 0 && !confirmedHighRisk) {
    host.pendingRoomGroupConfirm = { group, action, riskyNames, sourceRevision: host.sourceRevision };
    host.render();
    return false;
  }

  const title = action.kind === "brightness" && clampedBrightness !== null
    ? `${group.label} ${clampedBrightness}%`
    : targetOn ? `${t("已打开")} ${group.label}` : `${t("已关闭")} ${group.label}`;

  if (coverTargets.length > 0) {
    const targetPos = targetOn ? 100 : 0;
    const undoSteps: UndoStep[] = [];
    let failure: string | null = null;
    for (const cover of coverTargets) {
      if (cover.kind.kind !== "cover") continue;
      const locked = await isWorkstationLockBlockingControl(host);
      if (contextChanged()) return false;
      if (locked) {
        failure = lockedMessage;
        break;
      }
      const live = host.devices.find((device) => device.id === cover.id);
      if (!live?.isOnline || live.roomId !== group.roomId || live.kind.kind !== "cover" ||
          live.kind.entityId !== cover.kind.entityId || live.kind.subtype !== cover.kind.subtype) {
        failure = staleMessage;
        continue;
      }
      const gateMsg = roomGroupWriteGate(host, live);
      if (gateMsg !== null) {
        failure = gateMsg;
        continue;
      }
      const { positionPercent, positionWritable, entityId, openDescription, closeDescription } = live.kind;
      const option = targetOn ? openDescription : closeDescription;
      const command: DeviceCommand | null = positionWritable
        ? { kind: "setNumberValue", entityId, value: targetPos }
        : option ? { kind: "setSelectOption", entityId, option } : null;
      if (!command) {
        failure = staleMessage;
        continue;
      }
      if (host.miSessionExpired && effectiveCommandBackend(host, command) === "xiaomiCloud") {
        failure = tr3("米家登录已过期，请先重新扫码登录", "米家登入已過期，請先重新掃碼登入", "Xiaomi Home session expired. Please sign in again.", undefined, host.settings.interfaceLanguage);
        continue;
      }
      const previousBanner = host.replyBanner;
      const ok = await host.applyCommand(command, false, true, { roomGroupCover: true });
      if (contextChanged()) return false;
      if (!ok) {
        failure = host.replyBanner !== previousBanner && host.replyBanner?.isError
          ? host.replyBanner.text : t("设备未响应");
        continue;
      }
      if (positionWritable && positionPercent !== null) {
        undoSteps.push({ deviceId: live.id, commands: [{ kind: "setNumberValue", entityId, value: positionPercent }] });
      }
    }
    if (undoSteps.length > 0) {
      host.lastUndoAction = { summary: title, steps: undoSteps, expiresAtMs: Date.now() + 10_000 };
    }
    if (failure !== null) return fail(failure);
    host.replyBanner = { text: title, source: t("房间群控") };
    host.render();
    return true;
  }

  return host.executeIntents(intents, title, t("房间群控"), { recordHabits: false });
}
