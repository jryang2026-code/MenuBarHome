import {
  GENERIC_CAMERA_KINDS,
  generateGenericCameraId,
  isGenericCameraKind,
  isPrivateOrLocalCameraHost,
  normalizeGenericCameraHost,
  redactGenericCameraUrl,
  sanitizeGenericCameraConfig,
  type GenericCameraConfig,
  type GenericCameraKind,
} from "../core/genericCameras.js";
import { currentLanguage, type AppLanguage, type LanguagePreference } from "../core/i18n.js";
import {
  genericCameraCredentialName,
  secureStoreDelete,
  secureStoreSet,
  serializeGenericCameraCredential,
} from "../core/secureStore.js";
import type { PersistedSettings } from "./appTypes.js";

export interface GenericCameraSettingsHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  saveSettings(): void;
  render(): void;
}

interface Draft {
  open: boolean;
  editingId: string | null;
  name: string;
  kind: GenericCameraKind;
  host: string;
  port: string;
  path: string;
  channel: string;
  username: string;
  password: string;
  confirmNonLocal: boolean;
  error: string | null;
  testing: boolean;
  testStatus: string | null;
  testPreviewDataUrl: string | null;
  /** Camera whose Remove was clicked once; the second click deletes it and its saved credentials. */
  armedDeleteId: string | null;
  deleteFailed: boolean;
  readonly pendingWrites: Set<string>;
}

const draftsByHost = new WeakMap<object, Draft>();
const emptyDraft = (): Omit<Draft, "pendingWrites"> => ({
  open: false, editingId: null, name: "", kind: "rtsp", host: "", port: "", path: "", channel: "1",
  username: "", password: "", confirmNonLocal: false, error: null, testing: false, testStatus: null, testPreviewDataUrl: null,
  armedDeleteId: null, deleteFailed: false,
});
const getDraft = (host: object): Draft => {
  let d = draftsByHost.get(host);
  if (!d) draftsByHost.set(host, (d = { ...emptyDraft(), pendingWrites: new Set() }));
  return d;
};
const escFallback = (v: string) => v.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const effLang = (pref?: LanguagePreference): AppLanguage =>
  pref === "en" || pref === "zh-Hant" || pref === "zh-Hans" ? pref : currentLanguage();
const tr = (zh: string, hant: string, en: string, lang: AppLanguage) => (lang === "en" ? en : lang === "zh-Hant" ? hant : zh);
const kindLabel = (k: GenericCameraKind, lang: AppLanguage) =>
  k === "isapi" ? tr("海康 ISAPI", "海康 ISAPI", "Hikvision ISAPI", lang) : k === "dahua" ? tr("大华", "大華", "Dahua", lang) : k === "tapo" ? "Tapo" : k.toUpperCase();
const removeLabel = (lang: AppLanguage) => tr("删除", "刪除", "Remove", lang);

export function clearGenericCameraRemovalConfirmation(host: GenericCameraSettingsHost): void {
  const d = draftsByHost.get(host);
  if (!d?.armedDeleteId) return;
  const button = [...host.root.querySelectorAll<HTMLButtonElement>("[data-generic-cam-delete]")]
    .find((el) => el.dataset.genericCamDelete === d.armedDeleteId);
  if (button) button.textContent = removeLabel(effLang(host.settings.interfaceLanguage));
  d.armedDeleteId = null;
}

export function renderGenericCamerasSettingsBlock(
  settings: PersistedSettings,
  host: object | null,
  esc: (v: string) => string = escFallback,
): string {
  const lang = effLang(settings.interfaceLanguage);
  const cameras = settings.genericCameras ?? [];
  const d = host ? getDraft(host) : emptyDraft();
  const needsConsent = d.host.trim() !== "" && !isPrivateOrLocalCameraHost(d.host);

  const listErrorHtml = d.deleteFailed
    ? `<p class="cc-field-hint" data-gc-delete-error role="alert" style="margin:4px 0 6px;color:#e74c3c;font-size:12px;">${esc(tr("删除凭据失败，请重试。", "刪除憑證失敗，請重試。", "Could not delete credentials. Try again.", lang))}</p>`
    : "";
  const listHtml = cameras.length === 0
    ? `<p class="cc-field-hint" data-generic-cameras-empty style="margin:4px 0 6px;">${esc(tr("暂未添加通用摄像机", "暫未新增通用攝影機", "No generic cameras yet", lang))}</p>`
    : cameras.map((c) => `<div class="cc-settings-account-card" data-generic-camera-row="${esc(c.id)}" style="padding:7px 10px;margin-bottom:6px;border-radius:10px;background:rgba(128,128,128,0.08);border:1px solid rgba(128,128,128,0.14);"><div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;"><strong style="font-size:12.5px;">${esc(c.name)}</strong><span class="cc-inline-pill" style="font-size:11px;padding:1px 6px;">${esc(kindLabel(c.kind, lang))}</span><span class="cc-field-hint" style="margin:0;font-size:11.5px;">${esc(c.port ? `${c.host}:${c.port}` : c.host)}</span><div style="margin-left:auto;display:flex;gap:6px;"><button type="button" class="cc-inline-pill" data-generic-cam-edit="${esc(c.id)}">${esc(tr("编辑", "編輯", "Edit", lang))}</button><button type="button" class="cc-btn-danger" data-generic-cam-delete="${esc(c.id)}" style="padding:2px 8px;font-size:11.5px;" title="${esc(tr("同时清除这台摄像机保存的登录凭据", "同時清除這台攝影機儲存的登入憑證", "Also deletes this camera's saved credentials", lang))}">${esc(d.armedDeleteId === c.id ? tr("再点一次确认移除", "再點一次確認移除", "Click again to remove", lang) : removeLabel(lang))}</button></div></div></div>`).join("");

  const formHtml = !d.open ? "" : `<div id="generic-camera-form" data-generic-camera-form style="margin-top:8px;padding:10px;border-radius:10px;background:rgba(128,128,128,0.08);display:flex;flex-direction:column;gap:8px;">
    <div class="cc-field-row" style="gap:8px;">
      <input id="gc-input-name" class="cc-input" type="text" placeholder="${esc(tr("名称", "名稱", "Name", lang))}" value="${esc(d.name)}" />
      <select id="gc-input-kind" class="cc-input" style="width:auto;">${GENERIC_CAMERA_KINDS.map((k) => `<option value="${k}" ${d.kind === k ? "selected" : ""}>${esc(kindLabel(k, lang))}</option>`).join("")}</select>
    </div>
    <div class="cc-field-row" style="gap:8px;">
      <input id="gc-input-host" class="cc-input" type="text" placeholder="192.168.1.50 / cam.local" value="${esc(d.host)}" />
      <input id="gc-input-port" class="cc-input" type="number" min="1" max="65535" placeholder="${esc(tr("端口", "連接埠", "Port", lang))}" value="${esc(d.port)}" style="width:92px;" />
    </div>
    ${d.kind === "rtsp" ? `<input id="gc-input-path" class="cc-input" type="text" placeholder="${esc(tr("RTSP 路径（如 /stream1）", "RTSP 路徑（如 /stream1）", "RTSP path (e.g. /stream1)", lang))}" value="${esc(d.path)}" />` : d.kind === "isapi" || d.kind === "dahua" ? `<input id="gc-input-channel" class="cc-input" type="number" min="1" max="999" placeholder="${esc(tr("通道号（默认 1）", "通道號（預設 1）", "Channel (default 1)", lang))}" value="${esc(d.channel)}" />` : ""}
    <div class="cc-field-row" style="gap:8px;">
      ${d.kind === "tapo" ? "" : `<input id="gc-input-user" class="cc-input" type="text" autocomplete="off" placeholder="${esc(d.editingId ? tr("用户名（留空不变）", "使用者名稱（留空不變）", "Username (blank keeps saved)", lang) : tr("用户名（可选）", "使用者名稱（選填）", "Username (opt)", lang))}" value="${esc(d.username)}" />`}
      <input id="gc-input-pass" class="cc-input" type="password" autocomplete="off" placeholder="${esc(d.editingId ? tr("密码（留空不变）", "密碼（留空不變）", "Password (blank keeps saved)", lang) : tr("密码（可选）", "密碼（選填）", "Password (opt)", lang))}" value="${esc(d.password)}" />
    </div>
    ${needsConsent ? `<label data-gc-nonlocal-consent style="display:flex;align-items:flex-start;gap:6px;font-size:12px;color:#e67e22;cursor:pointer;"><input id="gc-input-nonlocal" type="checkbox" ${d.confirmNonLocal ? "checked" : ""} /><span>${esc(tr("非局域网地址，凭据可能明文传输；我确认连接此地址。", "非區域網位址，憑證可能明文傳輸；我確認連線此位址。", "Non-local host; credentials may travel unencrypted. I confirm.", lang))}</span></label>` : ""}
    ${d.error ? `<p class="cc-field-hint" data-gc-error style="margin:0;color:#e74c3c;font-size:12px;">${esc(d.error)}</p>` : ""}
    ${d.testStatus ? `<p class="cc-field-hint" data-gc-test-status style="margin:0;font-size:12px;">${esc(d.testStatus)}</p>` : ""}
    ${d.testPreviewDataUrl ? `<img data-gc-test-preview src="${esc(d.testPreviewDataUrl)}" alt="Camera test preview" style="max-width:100%;max-height:140px;border-radius:8px;object-fit:contain;" />` : ""}
    <div style="display:flex;gap:6px;justify-content:flex-end;">
      <button type="button" class="cc-btn-secondary" id="btn-gc-cancel">${esc(tr("取消", "取消", "Cancel", lang))}</button>
      <button type="button" class="cc-btn-secondary" id="btn-gc-test" ${d.testing ? "disabled" : ""}>${esc(d.testing ? tr("测试中…", "測試中…", "Testing…", lang) : tr("测试连接", "測試連線", "Test Connection", lang))}</button>
      <button type="button" class="cc-btn-primary" id="btn-gc-save">${esc(tr("保存", "儲存", "Save", lang))}</button>
    </div>
  </div>`;

  return `<div class="cc-field" id="conn-diag-generic-cameras-section" data-settings-anchor="genericCameras">
    <div class="cc-field-row" style="margin-bottom:6px;">
      <label style="margin:0;font-weight:600;">${esc(tr("通用摄像机", "通用攝影機", "Generic Cameras", lang))}</label>
      <button type="button" class="cc-inline-pill" id="btn-gc-add">${esc(tr("添加摄像机", "新增攝影機", "Add Camera", lang))}</button>
    </div>${listErrorHtml}${listHtml}${formHtml}
  </div>`;
}

function readDraft(root: HTMLElement, d: Draft): void {
  const val = (s: string) => root.querySelector<HTMLInputElement | HTMLSelectElement>(s)?.value;
  if (val("#gc-input-name") !== undefined) d.name = val("#gc-input-name")!;
  if (isGenericCameraKind(val("#gc-input-kind"))) d.kind = val("#gc-input-kind") as GenericCameraKind;
  if (val("#gc-input-host") !== undefined) d.host = val("#gc-input-host")!;
  if (val("#gc-input-port") !== undefined) d.port = val("#gc-input-port")!;
  if (val("#gc-input-path") !== undefined) d.path = val("#gc-input-path")!;
  if (val("#gc-input-channel") !== undefined) d.channel = val("#gc-input-channel")!;
  if (val("#gc-input-user") !== undefined) d.username = val("#gc-input-user")!;
  if (val("#gc-input-pass") !== undefined) d.password = val("#gc-input-pass")!;
  const nl = root.querySelector<HTMLInputElement>("#gc-input-nonlocal");
  if (nl) d.confirmNonLocal = nl.checked;
}

function validateDraft(d: Draft, lang: AppLanguage): { config: GenericCameraConfig; allowNonLocal: boolean } | { error: string } {
  const host = d.host.trim();
  const isLocal = isPrivateOrLocalCameraHost(host);
  if (!isLocal && !d.confirmNonLocal) {
    return { error: tr("非局域网地址需先勾选风险确认。", "非區域網位址需先勾選風險確認。", "Confirm the non-local host risk checkbox first.", lang) };
  }
  const port = d.port.trim() === "" ? undefined : Number(d.port.trim());
  if (port !== undefined && (!Number.isInteger(port) || port < 1 || port > 65535)) {
    return { error: tr("端口必须是 1–65535 的整数。", "連接埠必須是 1–65535 的整數。", "Port must be 1–65535.", lang) };
  }
  const channel = d.kind === "isapi" || d.kind === "dahua" ? (d.channel.trim() === "" ? 1 : Number(d.channel.trim())) : undefined;
  const config = sanitizeGenericCameraConfig({
    id: d.editingId ?? generateGenericCameraId(),
    name: d.name,
    kind: d.kind,
    host,
    ...(port !== undefined ? { port } : {}),
    ...(d.kind === "rtsp" && d.path.trim() ? { path: d.path.trim() } : {}),
    ...(channel !== undefined ? { channel } : {}),
  });
  return config ? { config, allowNonLocal: !isLocal } : { error: tr("请填写有效的名称与主机地址。", "請填寫有效的名稱與主機位址。", "Enter a valid name and host.", lang) };
}

export function bindGenericCameraSettingsEvents(host: GenericCameraSettingsHost): void {
  const sec = host.root.querySelector<HTMLElement>("#conn-diag-generic-cameras-section");
  if (!sec) return;
  const d = getDraft(host);
  const lang = effLang(host.settings.interfaceLanguage);
  const on = <T extends Element>(el: T | null, ev: string, fn: (t: T) => void) => el?.addEventListener(ev, () => fn(el));

  on(sec.querySelector<HTMLButtonElement>("#btn-gc-add"), "click", () => { Object.assign(d, emptyDraft(), { open: true }); host.render(); });
  sec.querySelectorAll<HTMLButtonElement>("[data-generic-cam-edit]").forEach((btn) => on(btn, "click", (el) => {
    const c = (host.settings.genericCameras ?? []).find((x) => x.id === el.dataset.genericCamEdit);
    if (!c) return;
    Object.assign(d, emptyDraft(), {
      open: true, editingId: c.id, name: c.name, kind: c.kind, host: c.host,
      port: c.port !== undefined ? String(c.port) : "", path: c.path ?? "", channel: c.channel !== undefined ? String(c.channel) : "1",
      confirmNonLocal: (host.settings.genericCameraConsentHosts ?? []).includes(normalizeGenericCameraHost(c.host)),
    });
    host.render();
  }));
  sec.querySelectorAll<HTMLButtonElement>("[data-generic-cam-delete]").forEach((btn) => on(btn, "click", async (el) => {
    const id = el.dataset.genericCamDelete;
    if (!id || d.pendingWrites.has(id)) return;
    // Removing also wipes the saved credentials, so the first click only arms it (as AI provider removal does).
    if (d.armedDeleteId !== id) {
      d.armedDeleteId = id;
      host.render();
      return;
    }
    clearGenericCameraRemovalConfirmation(host);
    d.pendingWrites.add(id);
    try {
      await secureStoreDelete(genericCameraCredentialName(id));
    } catch {
      d.deleteFailed = true;
      host.render();
      return;
    } finally {
      d.pendingWrites.delete(id);
    }
    d.deleteFailed = false;
    host.settings.genericCameras = (host.settings.genericCameras ?? []).filter((c) => c.id !== id);
    if (d.editingId === id) Object.assign(d, emptyDraft());
    host.saveSettings();
    host.render();
  }));
  on(sec.querySelector<HTMLSelectElement>("#gc-input-kind"), "change", () => { readDraft(sec, d); host.render(); });
  on(sec.querySelector<HTMLInputElement>("#gc-input-host"), "blur", () => { readDraft(sec, d); host.render(); });
  on(sec.querySelector<HTMLButtonElement>("#btn-gc-cancel"), "click", () => { Object.assign(d, emptyDraft()); host.render(); });

  on(sec.querySelector<HTMLButtonElement>("#btn-gc-test"), "click", () => {
    readDraft(sec, d);
    const v = validateDraft(d, lang);
    if ("error" in v) { d.error = v.error; host.render(); return; }
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) { d.error = tr("仅 Windows 桌面端支持测试连接。", "僅 Windows 桌面端支援測試連線。", "Test requires Windows desktop app.", lang); host.render(); return; }
    Object.assign(d, { error: null, testing: true, testStatus: tr("正在拉取预览帧…", "正在擷取預覽影格…", "Fetching preview frame…", lang), testPreviewDataUrl: null });
    host.render();
    void invoke<string>("test_generic_camera_connection", {
      id: d.editingId, kind: v.config.kind, host: v.config.host, port: v.config.port ?? null, path: v.config.path ?? null,
      channel: v.config.channel ?? 1, customSource: v.config.subStream ?? null,
      username: d.username || null, password: d.password || null, allowNonLocal: v.allowNonLocal,
    }).then((b64) => {
      Object.assign(d, { testing: false, testPreviewDataUrl: b64 ? `data:image/jpeg;base64,${b64}` : null, testStatus: tr("连接成功。", "連線成功。", "Connected.", lang) });
      host.render();
    }).catch((err: unknown) => {
      Object.assign(d, { testing: false, testStatus: null, error: redactGenericCameraUrl(err instanceof Error ? err.message : String(err ?? "")) || tr("连接失败。", "連線失敗。", "Connection failed.", lang) });
      host.render();
    });
  });

  on(sec.querySelector<HTMLButtonElement>("#btn-gc-save"), "click", () => {
    readDraft(sec, d);
    const v = validateDraft(d, lang);
    if ("error" in v) { d.error = v.error; host.render(); return; }
    const id = v.config.id;
    if (d.pendingWrites.has(id)) return;
    void (async () => {
      const creds = serializeGenericCameraCredential({ username: d.kind === "tapo" ? "" : d.username, password: d.password });
      if (creds !== "") {
        d.pendingWrites.add(id);
        try { await secureStoreSet(genericCameraCredentialName(id), creds); } catch (err) {
          d.error = redactGenericCameraUrl(err instanceof Error ? err.message : String(err ?? ""));
          host.render();
          return;
        } finally {
          d.pendingWrites.delete(id);
        }
      }
      const next = [...(host.settings.genericCameras ?? [])];
      const idx = next.findIndex((c) => c.id === v.config.id);
      if (idx >= 0) next[idx] = v.config; else next.push(v.config);
      host.settings.genericCameras = next;
      if (v.allowNonLocal) {
        host.settings.genericCameraConsentHosts = [...new Set([...(host.settings.genericCameraConsentHosts ?? []), normalizeGenericCameraHost(v.config.host)])];
      }
      Object.assign(d, emptyDraft());
      host.saveSettings();
      host.render();
    })();
  });
}
