import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { MI_CLOUD_REGIONS, normalizeMiCloudRegion } from "../core/miCloudClient.js";
import {
  TILE_SIZES,
  chosenSize,
  isDevicePinned,
  pinnedDeviceIds,
  roomDisplayName,
  tr3,
} from "./panelPrefs.js";
import { KIND_CHIP } from "./listCut.js";
import { SF_ICONS } from "./appConstants.js";
import { energyScopeForHost, syncEnergyHostOnRender } from "./energySettingsView.js";
import { renderSettingsModal as renderSettingsModalView } from "./settingsViews.js";
import {
  isRoomOrderEditorOpen,
  renderRoomOrderEditorModal,
  snapshotRoomsForHost,
} from "./roomOrderEditor.js";
import type { HomeBackend } from "../core/models.js";
import { MiAccountScope } from "../core/miAccountsStore.js";
import {
  currentSourceMenuTitle,
  offlineFallbackBadgeText,
} from "../core/dualSourceProvider.js";
import { getHostActivityCenter } from "./activityStackView.js";
import { getHostAutoSafetySession } from "./automationSettingsView.js";
import {
  getHostDualSourceCoordinator,
  getHostDualSourceState,
  isDualSourceEnabled,
} from "./cloudRefresh.js";
import {
  isConnectionsAndDiagModalOpen,
  renderConnectionsAndDiagModal,
  resolveHostMiAccounts,
} from "./connectionsAndDiagView.js";

export function renderHomeMenu(host: MenuMijiaWindowsApp): string {
    if (!host.isHomeMenuOpen) return "";
    const item = (id: string | null, label: string, count?: number) => `
      <button class="cc-menu-item ${host.settings.selectedHomeId === id ? "is-checked" : ""}" data-home="${host.escapeHtml(id ?? "")}">
        <span>${host.escapeHtml(label)}</span>${count !== undefined ? `<small>${count}</small>` : ""}
      </button>`;
    const accounts = resolveHostMiAccounts(host);
    const hasScopedHomes =
      accounts.length > 1 &&
      host.homes.some((h) => accounts.some((acc) => MiAccountScope.isOwned(h.id, acc.id)));
    const homesBlock =
      host.homes.length >= 2
        ? `${item(null, t("全部家庭"))}
           <div class="cc-menu-sep"></div>
           ${
             hasScopedHomes
               ? accounts
                   .map((acc) => {
                     const owned = host.homes.filter((h) => MiAccountScope.isOwned(h.id, acc.id));
                     if (owned.length === 0) return "";
                     return `<div class="cc-menu-label">${host.escapeHtml(acc.displayName)}</div>${owned
                       .map((h) => item(h.id, h.name, h.deviceCount))
                       .join("")}`;
                   })
                   .join("")
               : host.homes.map((h) => item(h.id, h.name, h.deviceCount)).join("")
           }
           <div class="cc-menu-sep"></div>`
        : "";
    return `
      <div class="cc-menu-scrim" data-close-menus></div>
      <div class="cc-menu cc-home-menu">
        ${homesBlock}
        <button class="cc-menu-item" data-open-conn-diag="accounts">
          <span>${host.escapeHtml(tr3("多账号与双源连接…", "多帳號與雙源連線…", "Multi-Account & Dual-Source…"))}</span>
        </button>
        <button class="cc-menu-item" data-open-conn-diag="title">
          <span>${host.escapeHtml(tr3("自定义面板标题…", "自訂面板標題…", "Custom Panel Title…"))}</span>
        </button>
        <button class="cc-menu-item" data-open-conn-diag="scanner">
          <span>${host.escapeHtml(tr3("扫描未能显示的设备…", "掃描未能顯示的裝置…", "Scan Hidden Devices…"))}</span>
        </button>
        <button class="cc-menu-item" data-open-conn-diag="diagnostics">
          <span>${host.escapeHtml(tr3("复制脱敏诊断报告…", "複製去識別化診斷報告…", "Copy Diagnostics Report…"))}</span>
        </button>
      </div>`;
  }

export function renderContextMenu(host: MenuMijiaWindowsApp): string {
    const m = host.ctxMenu;
    if (!m) return "";
    const pos = `left:${Math.max(8, Math.min(m.x, window.innerWidth - 246))}px; top:${Math.max(8, Math.min(m.y, window.innerHeight - 350))}px`;
    if (m.groupId) {
      const g = host.layout.groups.find((x) => x.id === m.groupId);
      if (!g) return "";
      const gid = host.escapeHtml(g.id);
      return `
        <div class="cc-menu-scrim" data-close-menus></div>
        <div class="cc-menu" style="${pos}">
          <div class="cc-menu-title">${host.escapeHtml(g.name)}</div>
          <button class="cc-menu-item" data-group-action="rename:${gid}">${t("重命名")}</button>
          <button class="cc-menu-item" data-group-action="up:${gid}">${t("上移分组")}</button>
          <button class="cc-menu-item" data-group-action="down:${gid}">${t("下移分组")}</button>
          <div class="cc-menu-sep"></div>
          <button class="cc-menu-item is-danger" data-group-action="delete:${gid}">${t("删除分组")}</button>
        </div>`;
    }
    if (!m.deviceId) {
      if (m.roomTarget) {
        const rid = host.escapeHtml(m.roomTarget.roomId);
        const shown = roomDisplayName(host.layout, m.roomTarget.roomId, m.roomTarget.originalName);
        const canMove = snapshotRoomsForHost(host.devices).length >= 2;
        return `
          <div class="cc-menu-scrim" data-close-menus></div>
          <div class="cc-menu" style="${pos}">
            <div class="cc-menu-title">${host.escapeHtml(shown)}</div>
            <button class="cc-menu-item" data-open-room-rename="${rid}">${host.escapeHtml(tr3("重命名房间…", "重新命名房間…", "Rename Room…"))}</button>
            ${
              canMove
                ? `<button class="cc-menu-item" data-quick-room-move="${rid}:-1">${host.escapeHtml(tr3("向前移动房间", "向前移動房間", "Move Room Earlier"))}</button>
                   <button class="cc-menu-item" data-quick-room-move="${rid}:1">${host.escapeHtml(tr3("向后移动房间", "向後移動房間", "Move Room Later"))}</button>`
                : ""
            }
            <div class="cc-menu-sep"></div>
            <button class="cc-menu-item" data-open-room-editor="rooms">${host.escapeHtml(tr3("调整房间与分类顺序…", "調整房間與分類順序…", "Reorder Rooms & Categories…"))}</button>
          </div>`;
      }
      if (m.kindTarget) {
        const chipTitle = t(KIND_CHIP[m.kindTarget].title);
        return `
          <div class="cc-menu-scrim" data-close-menus></div>
          <div class="cc-menu" style="${pos}">
            <div class="cc-menu-title">${host.escapeHtml(chipTitle)}</div>
            <button class="cc-menu-item" data-open-room-editor="kinds">${host.escapeHtml(tr3("调整设备分类顺序…", "調整設備分類順序…", "Reorder Category Pills…"))}</button>
            <button class="cc-menu-item" data-open-room-editor="rooms">${host.escapeHtml(tr3("调整房间与重命名…", "調整房間與重新命名…", "Reorder & Rename Rooms…"))}</button>
          </div>`;
      }
      if (!m.roomBar) return "";
      return `
        <div class="cc-menu-scrim" data-close-menus></div>
        <div class="cc-menu" style="${pos}">
          <div class="cc-menu-title">${host.escapeHtml(tr3("房间与分类栏", "房間與分類欄", "Rooms & Categories"))}</div>
          <button class="cc-menu-item" data-open-room-editor="rooms">${host.escapeHtml(tr3("调整房间与重命名…", "調整房間與重新命名…", "Reorder & Rename Rooms…"))}</button>
          <button class="cc-menu-item" data-open-room-editor="kinds">${host.escapeHtml(tr3("调整设备分类顺序…", "調整設備分類順序…", "Reorder Category Pills…"))}</button>
        </div>`;
    }
    const dev = host.devices.find((d) => d.id === m.deviceId);
    if (!dev) return "";
    const id = host.escapeHtml(dev.id);
    const size = chosenSize(host.layout, host.pageKey, dev.id);
    const current = host.layout.groupMap[dev.id];
    const pinned = isDevicePinned(dev.id, host.layout);
    const pinnedList = pinnedDeviceIds(host.layout);
    const pinIdx = pinnedList.indexOf(dev.id);
    const dualState = getHostDualSourceState(host);
    const dualEnabled = isDualSourceEnabled(host);
    const route = dualState?.routes[dev.id] ?? null;
    const activeBackend: HomeBackend | null =
      route?.backend ??
      (dev.sourceBackend === "homeAssistant" || dev.sourceBackend === "xiaomiCloud"
        ? dev.sourceBackend
        : null);
    const storedPin =
      dualEnabled || dualState !== null
        ? getHostDualSourceCoordinator(host).pinStorage.get(dev.id)
        : null;
    const pinnedBackend: HomeBackend | null =
      storedPin ?? route?.pinnedBackend ?? dev.pinnedBackend ?? null;
    const fallbackActive = Boolean(route?.fallbackActive ?? dev.fallbackActive);
    const showDualSourcePin =
      activeBackend !== null &&
      (Boolean(dualState?.pairedDeviceIds.has(dev.id)) ||
        (route !== null && route.alternateBackend !== null) ||
        pinnedBackend !== null ||
        fallbackActive);
    const dualSourceSection =
      showDualSourcePin && activeBackend
        ? `
          <div class="cc-menu-label" data-dual-source-header="${id}">
            <span>${host.escapeHtml(tr3("数据源锁定", "資料來源鎖定", "Data Source Pin"))}</span>
            ${
              fallbackActive
                ? `<span class="cc-inline-pill" data-dual-source-fallback="true" style="margin-left:6px;font-size:10.5px;padding:1px 6px;color:#e67e22;background:rgba(230,126,34,0.16);border:1px solid rgba(230,126,34,0.35);">${host.escapeHtml(
                    offlineFallbackBadgeText(host.settings.interfaceLanguage),
                  )}</span>`
                : ""
            }
          </div>
          <div class="cc-field-hint" data-dual-source-status="${id}" style="padding:0 10px 4px;margin:0;font-size:11px;">
            ${host.escapeHtml(
              currentSourceMenuTitle(
                activeBackend,
                pinnedBackend,
                fallbackActive,
                host.settings.interfaceLanguage,
              ),
            )}
          </div>
          <button class="cc-menu-item ${pinnedBackend === null ? "is-checked" : ""}" data-pin-device-id="${id}" data-pin-device-source="auto">
            <span>${host.escapeHtml(tr3("自动优先（HA）", "自動優先（HA）", "Automatic (Prefer HA)"))}</span>
          </button>
          <button class="cc-menu-item ${pinnedBackend === "homeAssistant" ? "is-checked" : ""}" data-pin-device-id="${id}" data-pin-device-source="homeAssistant">
            <span>${host.escapeHtml(tr3("固定走 Home Assistant", "固定走 Home Assistant", "Pin to Home Assistant"))}</span>
          </button>
          <button class="cc-menu-item ${pinnedBackend === "xiaomiCloud" ? "is-checked" : ""}" data-pin-device-id="${id}" data-pin-device-source="xiaomiCloud">
            <span>${host.escapeHtml(tr3("固定走米家云端", "固定走米家雲端", "Pin to Xiaomi Cloud"))}</span>
          </button>
          <div class="cc-menu-sep"></div>`
        : "";
    return `
      <div class="cc-menu-scrim" data-close-menus></div>
      <div class="cc-menu" style="${pos}">
        <div class="cc-menu-title">${host.escapeHtml(host.layout.aliases[dev.id] ?? dev.name)}</div>
        ${dualSourceSection}
        <div class="cc-menu-label">${t("卡片大小（本页）")}</div>
        <div class="cc-menu-chips">
          ${TILE_SIZES.map((sz) => `<button class="cc-menu-chip ${size === sz.id ? "is-active" : ""}" data-set-size="${id}:${sz.id}">${sz.title}</button>`).join("")}
        </div>
        <div class="cc-menu-label">${t("移到分组")}</div>
        <div class="cc-menu-chips">
          ${host.layout.groups.map((g) => `<button class="cc-menu-chip ${current === g.id ? "is-active" : ""}" data-set-group="${id}:${host.escapeHtml(g.id)}">${host.escapeHtml(g.name)}</button>`).join("")}
          ${current ? `<button class="cc-menu-chip" data-set-group="${id}:">${t("不分组")}</button>` : ""}
          <button class="cc-menu-chip is-add" data-new-group="${id}">${t("＋ 新建")}</button>
        </div>
        <div class="cc-menu-sep"></div>
        <button class="cc-menu-item ${pinned ? "is-checked" : ""}" data-toggle-pin="${id}">
          <span>${host.escapeHtml(pinned ? tr3("取消常用（置顶）", "取消常用（置頂）", "Remove from Favorites") : tr3("设为常用（置顶）", "設為常用（置頂）", "Pin to Favorites"))}</span>
        </button>
        ${
          pinned && pinnedList.length > 1
            ? `<div class="cc-menu-chips">
                <button class="cc-menu-chip" data-move-pin="${id}:-1" ${pinIdx <= 0 ? "disabled" : ""}>${host.escapeHtml(tr3("↑ 常用前移", "↑ 常用前移", "↑ Move Earlier"))}</button>
                <button class="cc-menu-chip" data-move-pin="${id}:1" ${pinIdx >= pinnedList.length - 1 ? "disabled" : ""}>${host.escapeHtml(tr3("↓ 常用后移", "↓ 常用後移", "↓ Move Later"))}</button>
              </div>`
            : ""
        }
        <button class="cc-menu-item" data-rename-device="${id}">${t("重命名…")}</button>
        <button class="cc-menu-item" data-open-room-editor="rooms">${host.escapeHtml(tr3("调整房间与分类顺序…", "調整房間與分類順序…", "Reorder Rooms & Categories…"))}</button>
        <button class="cc-menu-item" data-start-editing>${t("编辑布局")}</button>
        <div class="cc-menu-sep"></div>
        <button class="cc-menu-item is-danger" data-hide-device="${id}">${host.escapeHtml(tr3("隐藏此设备", "隱藏此設備", "Hide This Device"))}</button>
      </div>`;
  }

export function renderPrompt(host: MenuMijiaWindowsApp): string {
    if (isRoomOrderEditorOpen(host)) {
      return renderRoomOrderEditorModal(host);
    }
    if (isConnectionsAndDiagModalOpen(host)) {
      return renderConnectionsAndDiagModal(host);
    }
    const p = host.prompt;
    if (!p) return "";
    let title = t("新建分组");
    let value = "";
    let placeholder = t("例如：灯光、电器、环境");
    if (p.kind === "renameGroup") {
      title = t("重命名分组");
      value = host.layout.groups.find((g) => g.id === p.groupId)?.name ?? "";
    } else if (p.kind === "renameDevice") {
      title = t("重命名设备");
      const dev = host.devices.find((d) => d.id === p.deviceId);
      placeholder = dev?.name ?? "";
      value = host.layout.aliases[p.deviceId] ?? dev?.name ?? "";
    }
    const hasAlias = p.kind === "renameDevice" && Boolean(host.layout.aliases[p.deviceId]);
    return `
      <div class="cc-prompt-backdrop" data-prompt-cancel></div>
      <div class="cc-prompt">
        <strong>${title}</strong>
        <input id="prompt-input" class="cc-prompt-input" type="text" value="${host.escapeHtml(value)}" placeholder="${host.escapeHtml(placeholder)}" />
        ${p.kind === "renameDevice" ? `<small>${t("只在本 App 显示，不会修改米家里的名字")}</small>` : ""}
        <div class="cc-prompt-actions">
          ${hasAlias ? `<button class="cc-btn-secondary" id="btn-prompt-reset">${t("恢复原名")}</button>` : ""}
          <button class="cc-btn-secondary" data-prompt-cancel>${t("取消")}</button>
          <button class="cc-btn-primary" id="btn-prompt-save">${t("保存")}</button>
        </div>
      </div>`;
  }

export function renderOnboardingModal(host: MenuMijiaWindowsApp): string {
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet" role="dialog" aria-modal="true" aria-label="${t("首次设置")}">
          <div class="cc-sheet-header">
            <h2 class="cc-sheet-title">${t("扫码直连你的真实米家设备")}</h2>
            <button class="cc-circle-btn is-small" id="btn-close-onboarding" title="${t("关闭引导")}" aria-label="${t("关闭引导")}">
              ${SF_ICONS.xmark}
            </button>
          </div>

          <p class="cc-sheet-desc">
            ${t("手机打开「米家 App → 扫一扫」即可直接同步全屋真实设备；常驻 Windows 右下角系统托盘，点击图标或按 Alt+M 随时弹出，点击外部自动收起。")}
          </p>

          <div class="cc-field">
            <label>${t("云端服务器地区")}</label>
            <select class="cc-input" data-mi-region>
              ${MI_CLOUD_REGIONS.map(
                (region) => `<option value="${region.code}" ${normalizeMiCloudRegion(host.settings.miCloudRegion) === region.code ? "selected" : ""}>${host.escapeHtml(t(region.label))}</option>`,
              ).join("")}
            </select>
            <p class="cc-field-hint">${t("欧洲、印度、俄罗斯、新加坡、美区的米家账号请先选择对应地区，再扫码登录。")}</p>
          </div>

          <div class="cc-qr-box">
            <button class="cc-btn-primary is-full" id="btn-start-qr" ${host.isPollingQR ? "disabled" : ""}>
              ${SF_ICONS.qrcode}
              <span>${host.isPollingQR ? t("正在等待手机米家扫码确认...") : t("获取米家登录二维码")}</span>
            </button>
            <div class="cc-qr-status">${host.escapeHtml(host.qrStatusText)}</div>
            ${
              host.qrTicket
                ? `<div class="cc-qr-frame">
                    <img src="${host.escapeHtml(host.qrTicket.qrImageURL)}" alt="Xiaomi QR" />
                  </div>`
                : ""
            }
          </div>

          <div class="cc-field">
            <label>${t("OpenRouter API Key（可选，用于 Jev SystemOne 模糊意图决策）")}</label>
            <input
              id="onboarding-api-key"
              class="cc-input"
              type="password"
              placeholder="sk-or-v1-..."
              value="${host.escapeHtml(host.apiKeyFor(host.settings.assistantBaseURL))}"
            />
          </div>

          <div class="cc-sheet-footer">
            <button class="cc-btn-secondary" id="btn-close-onboarding-alt">${t("先看演示预览")}</button>
            <button class="cc-btn-primary" id="btn-finish-onboarding">${t("进入控制中心")}</button>
          </div>
        </div>
      </div>
    `;
  }

export function renderSettingsModal(host: MenuMijiaWindowsApp): string {
    syncEnergyHostOnRender(host);
    return renderSettingsModalView({
      settings: host.settings,
      devices: host.devices,
      scenes: host.scenes,
      availableUpdate: host.availableUpdate,
      activeTab: host.settingsTab,
      apiKeyFor: (baseURL) => host.apiKeyFor(baseURL),
      habitSequences: () => host.habitSequences(),
      hotkeyNeedsHint: host.hotkeyNeedsHint,
      hotkeyRegistrationError: host.hotkeyRegistrationError,
      isPollingQR: host.isPollingQR,
      isRecordingHotkey: host.isRecordingHotkey,
      panelAnchor: host.panelAnchor,
      qrStatusText: host.qrStatusText,
      qrTicket: host.qrTicket,
      isCheckingUpdate: host.isCheckingUpdate,
      isInstallingUpdate: host.isInstallingUpdate,
      updateStatusMessage: host.updateStatusMessage,
      energyScope: energyScopeForHost(host),
      energySession: host.energySession,
      autoSafetySession: getHostAutoSafetySession(host),
      activityCenter: getHostActivityCenter(host),
      sourceRevision: host.sourceRevision,
      connDiagHost: host,
      layout: host.layout,
      escapeHtml: (value) => host.escapeHtml(value),
    });
  }
