import { t, tr3 } from "../core/i18n.js";
import type { DeviceCommand, HomeScene } from "../core/models.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import type { PendingHighRiskConfirmation } from "./appTypes.js";

const requests = new WeakMap<MenuMijiaWindowsApp, {
  pending: PendingHighRiskConfirmation;
  resolve: (approved: boolean) => void;
}>();

export function requestMiSceneConfirmation(
  host: MenuMijiaWindowsApp,
  scene: HomeScene,
  command: DeviceCommand,
): Promise<boolean> {
  const pending: PendingHighRiskConfirmation = {
    deviceId: scene.id,
    actionKey: JSON.stringify(command),
    sourceRevision: host.sourceRevision,
    expiresAtMs: Date.now() + 8_000,
    confirm: {
      command,
      summary: scene.name,
      intent: { targetId: scene.id, operation: { kind: "activateScene" } },
    },
  };
  host.setPendingHighRisk(pending);
  const answer = new Promise<boolean>((resolve) => requests.set(host, { pending, resolve }));
  host.replyBanner = {
    text: tr3("确认执行场景「{name}」？", "確認執行場景「{name}」？", "Run scene “{name}”?", { name: scene.name }),
    source: t("需要确认"),
  };
  host.render();
  return answer;
}

export function finishMiSceneConfirmation(host: MenuMijiaWindowsApp, approved: boolean): void {
  const request = requests.get(host);
  if (!request) return;
  requests.delete(host);
  request.resolve(approved && request.pending === host.pendingHighRisk &&
    request.pending.sourceRevision === host.sourceRevision && Date.now() < request.pending.expiresAtMs);
}

export function renderMiSceneConfirmation(host: MenuMijiaWindowsApp): string {
  if (!requests.has(host)) return "";
  return `<button class="cc-inline-pill" data-mi-scene-answer="confirm">${t("确认执行")}</button><button class="cc-inline-pill" data-mi-scene-answer="cancel">${t("取消")}</button>`;
}
