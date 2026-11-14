import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { deviceCanTogglePower, hasDetailDrawer, isDeviceActiveOn, type SmartDevice } from "../core/models.js";
import { normalizeSearch } from "../core/panelSearch.js";
import { availableQuickActions, trText, type QuickActionId } from "../core/quickActions.js";
import { bindActivityStackAfterRender, renderActivityStack } from "./activityStackView.js";
import { SF_ICONS } from "./appConstants.js";
import { applyPanelOpacity, withAliases } from "./panelPrefs.js";
import { quickActions } from "./demo.js";
import { quickActionScopeDevices, reconcileUndoBannerHoverAfterRender } from "./speechGuard.js";
import { renderProactiveInlinePill } from "./proactive.js";
import { renderEditLayoutToolbar, renderHiddenDevicesTray } from "./roomOrderEditor.js";
import { effectivePanelHomeTitle } from "./connectionsAndDiagView.js";
import { syncEnergyHostOnRender } from "./energySettingsView.js";
import { syncSensorHistoryHost } from "./sensorHistoryView.js";
import { renderPersistentUndoPill, tr3 } from "./undoTracker.js";

export function renderPanel(host: MenuMijiaWindowsApp): void {
  syncSensorHistoryHost(host);
  syncEnergyHostOnRender(host);
  const isDemo = host.settings.connectionMode === "demo";
  const scheme = host.effectiveAppearance;
  host.root.dataset.scheme = scheme;
  applyPanelOpacity(host.root, host.settings.panelOpacity);
  host.root.classList.toggle("is-native-host", Boolean(window.__TAURI_INTERNALS__));
  const popoverClass = `cc-popover scheme-${scheme} ${host.isEditingLayout ? "is-editing" : ""}`.trim();
  const notifStack = renderNotificationStack(host);
  const innerContent = `
      <section class="win-island win-island--top" aria-label="${t("家庭状态与动态通知")}">
        <header class="cc-header">
          <div class="cc-header-top">
            <div class="cc-title-group">
              <div class="cc-home-emblem cc-home-badge ${host.activeDeviceCount > 0 ? "is-active" : ""}" aria-hidden="true">${SF_ICONS.houseFill}</div>
              <div class="cc-title-stack">
                <div class="cc-title-row">
                  <button class="cc-home-switch" id="btn-home-menu" type="button" aria-expanded="${host.isHomeMenuOpen}" aria-label="${t("切换家庭")}">
                    <span class="cc-home-title">${host.escapeHtml(effectivePanelHomeTitle(host))}</span>
                    <span class="cc-home-caret ${host.isHomeMenuOpen ? "is-open" : ""}">${SF_ICONS.chevronDown}</span>
                  </button>
                  <span class="cc-mode-pill ${isDemo ? "is-demo" : "is-cloud"}">
                    ${isDemo ? t("演示预览") : host.settings.connectionMode === "homeAssistant" ? "Home Assistant" : t("Miot 直连")}
                  </span>
                </div>
                <div class="cc-subtitle">${host.escapeHtml(host.isEditingLayout ? t("拖动卡片排序 · 点右下角圆弧手柄改大小") : host.statusSummaryText)}</div>
              </div>
            </div>

            <div class="cc-header-controls">
              ${renderPersistentUndoPill(host)}
              ${
                host.isEditingLayout
                  ? `<button type="button" class="cc-edit-done-chip" data-done-editing="true">${host.escapeHtml(trText("完成", "Done"))}</button>`
                  : ""
              }
              <button
                class="cc-circle-btn ${host.isListeningVoice ? "is-recording" : ""}"
                id="btn-mic"
                title="${t("语音控制")}"
                aria-label="${t("语音控制")}"
                aria-pressed="${host.isListeningVoice}"
              >
                ${SF_ICONS.micFill}
              </button>
              <button
                class="cc-circle-btn ${host.isShowingAssistantBar ? "is-selected" : ""}"
                id="btn-toggle-assistant"
                title="${t("显示建议和定时")}"
                aria-label="${t("显示建议和定时")}"
                aria-pressed="${host.isShowingAssistantBar}"
              >
                ${SF_ICONS.sparkles}
              </button>
              <button
                class="cc-circle-btn"
                id="btn-hide-panel"
                title="${t("收起面板到右下角托盘 (Esc)")}"
                aria-label="${t("收起面板")}"
              >
                ${SF_ICONS.chevronDown}
              </button>
            </div>
          </div>

          ${host.renderEnvironmentStrip()}
        </header>
        ${notifStack}
      </section>

      <section class="win-island win-island--bottom" aria-label="${t("快速设置与设备控制")}">
        <div class="win-island-controls">
          <div class="cc-assistant-section">
            <div class="cc-spotlight-bar">
              <span class="cc-spotlight-icon">${SF_ICONS.search}</span>
              <input
                id="command-input"
                class="cc-spotlight-input"
                type="text"
                placeholder="${t("搜索设备，或直接说一句话")}"
                value="${host.escapeHtml(host.panelSearch.query)}"
                autocomplete="off"
                aria-description="${t("Ctrl+F 聚焦，↑↓ 选择，回车开关或执行口令，→ 展开，Esc 清空")}"
                aria-label="${t("搜索设备或输入指令")}"
                ${host.isResolvingIntent ? "disabled" : ""}
              />
              ${host.panelSearch.query ? `<span class="cc-search-count" role="status">${host.presentationDevices.length}</span><button class="cc-circle-btn is-small" id="btn-clear-search" aria-label="${t("清空输入")}">×</button>` : ""}
              <button
                id="btn-send"
                class="cc-spotlight-send"
                title="${t("执行指令 (Enter)")}"
                aria-label="${t("执行指令")}"
                ${host.isResolvingIntent ? "disabled" : ""}
              >
                ${SF_ICONS.arrowUpCircle}
              </button>
            </div>
          </div>

          ${quickStrip(host)}

          <div class="cc-room-bar">
            <div class="cc-room-track">
              <div class="cc-room-scroll">
                ${[{ id: null, name: t("全部") }, ...host.roomOptions]
                  .map((room) => {
                    const pressed = room.id === null
                      ? host.listCut.kind === "all"
                      : host.listCut.kind === "room" && host.listCut.roomId === room.id;
                    return `
                  <button
                    class="cc-room-pill ${pressed ? "is-active" : ""}"
                    data-room="${host.escapeHtml(room.id === null ? "全部" : room.name)}"
                    ${room.id === null ? "" : `data-room-id="${host.escapeHtml(room.id)}"`}
                    aria-pressed="${pressed}"
                  >
                    ${host.escapeHtml(room.id === null ? t("全部") : room.name)}
                  </button>
                `;
                  })
                  .join("")}${host.renderKindBar()}
              </div>
            </div>
            <div class="cc-room-tools">
              <button
                class="cc-circle-btn is-small"
                id="btn-toggle-grid"
                title="${host.settings.isCompactGridMode ? t("切换为单列详情视图") : t("切换为胶囊控制网格")}"
                aria-label="${host.settings.isCompactGridMode ? t("切换为单列详情视图") : t("切换为胶囊控制网格")}"
                aria-pressed="${host.settings.isCompactGridMode}"
              >
                ${host.settings.isCompactGridMode ? SF_ICONS.grid2x2 : SF_ICONS.grid1x2}
              </button>
              <button
                class="cc-circle-btn is-small ${host.settings.hideOfflineDevices ? "is-selected" : ""}"
                id="btn-toggle-hide-offline"
                title="${host.settings.hideOfflineDevices ? t("当前只显示在线设备（点击显示全部）") : t("点击隐藏未通电/离线设备")}"
                aria-label="${t("只显示在线设备")}"
                aria-pressed="${host.settings.hideOfflineDevices}"
              >
                ${host.settings.hideOfflineDevices ? SF_ICONS.wifi : SF_ICONS.wifiSlash}
              </button>
              <button
                class="cc-circle-btn is-small"
                id="btn-room-order-editor"
                title="${tr3("房间与类别顺序", "房間與類別順序", "Room & Category Order")}"
                aria-label="${tr3("房间与类别顺序", "房間與類別順序", "Room & Category Order")}"
              >
                ${SF_ICONS.sliderHorizontal}
              </button>
            </div>
          </div>
        </div>

        <main class="cc-scroll-area" aria-label="${t("设备列表")}">
          ${renderEditLayoutToolbar(host)}
          ${host.renderDeviceGrid()}
          ${renderHiddenDevicesTray(host)}
        </main>

        ${renderSliderDeck(host)}

        <footer class="cc-footer">
          <div class="cc-footer-status">
            ${footerStatus(host)}
            ${host.renderAllOffControl()}
          </div>

          <div class="cc-footer-actions">
            ${
              host.availableUpdate
                ? `<button class="cc-footer-pill is-accent" id="btn-footer-update" title="${t("发现新版本 v{version}", { version: host.availableUpdate.version })}">
                    <span>${t("更新 v{version}", { version: host.availableUpdate.version })}</span>
                  </button>`
                : ""
            }
            ${
              host.settings.connectionMode !== "homeAssistant" && (!host.settings.miSession || isDemo)
                ? `<button class="cc-footer-pill is-accent" id="btn-footer-qr" title="${t("用手机米家 App 扫码直连真实设备")}">
                    ${SF_ICONS.qrcode}
                    <span>${t("扫码直连")}</span>
                  </button>`
                : ""
            }
            <button
              class="cc-footer-icon-btn"
              id="btn-toggle-appearance"
              title="${scheme === "light" ? t("切换深色模式") : t("切换浅色模式")}"
              aria-label="${scheme === "light" ? t("切换深色模式") : t("切换浅色模式")}"
            >
              ${scheme === "light" ? SF_ICONS.moonStarsFill : SF_ICONS.sunMaxFill}
            </button>
            <button
              class="cc-footer-icon-btn ${host.isSyncingCloud ? "is-spinning" : ""}"
              id="btn-refresh"
              title="${t("立即同步最新设备状态")}"
              aria-label="${t("立即同步最新设备状态")}"
            >
              ${SF_ICONS.arrowClockwise}
            </button>
            <button
              class="cc-footer-icon-btn"
              id="btn-settings"
              title="${t("连接设置与 AI 决策配置")}"
              aria-label="${t("打开设置")}"
            >
              ${SF_ICONS.sliderHorizontal}
            </button>
            <button
              class="cc-footer-icon-btn is-danger"
              id="btn-quit-app"
              title="${t("完全退出 MenuBarHome")}"
              aria-label="${t("退出")}"
            >
              ${SF_ICONS.power}
            </button>
          </div>
        </footer>
      </section>

      ${host.activeSheet === "onboarding" ? host.renderOnboardingModal() : ""}
      ${host.activeSheet === "settings" ? host.renderSettingsModal() : ""}
      ${host.cameraLive.activeLiveCameraId !== null ? host.cameraLive.renderCameraLiveModal() : ""}
      ${host.renderHomeMenu()}
      ${host.renderContextMenu()}
      ${host.renderPrompt()}
  `;
  host.pipeline.patchPopover(host, popoverClass, innerContent);
  host.pipeline.eventScope.rebind(host.root, () => {
    host.bindEvents();
    reconcileUndoBannerHoverAfterRender(host);
    bindActivityStackAfterRender(host);
    host.root.querySelectorAll<HTMLElement>("[data-done-editing]").forEach((btn) => {
      btn.addEventListener("click", () => host.stopEditing());
    });
  });
}

function renderNotificationStack(host: MenuMijiaWindowsApp): string {
  const cards: string[] = [];
  const live = liveBanner(host);
  if (live) cards.push(live);

  if (host.haConnectionError) {
    cards.push(
      `<div class="win-notif-card cc-feedback-card is-error" role="alert" data-ha-error><div class="cc-feedback-row"><span class="cc-feedback-badge">Home Assistant</span><span class="cc-feedback-text">${host.escapeHtml(host.haConnectionError)}</span></div></div>`,
    );
  }

  const activityStack = renderActivityStack(host);
  if (activityStack) cards.push(activityStack);

  if (host.pendingSuggestions.length > 0) {
    cards.push(
      `<div class="win-notif-card cc-feedback-card"><div class="cc-suggestion-row">${host.pendingSuggestions
        .map(
          (item) => `<button class="cc-inline-pill" data-suggestion-id="${host.escapeHtml(item.id)}">${host.escapeHtml(item.title)}${
            item.confidencePercent !== null ? ` · ${item.confidencePercent}%` : ""
          }</button>`,
        )
        .join("")}</div></div>`,
    );
  }

  if (host.missedScheduledCommands.length > 0) {
    cards.push(
      `<div class="win-notif-card cc-feedback-card is-warning"><div class="cc-timers-stack">${host.missedScheduledCommands
        .map(
          (item) => `<div class="cc-timer-row"><span>${t("已错过定时：{command}（没有自动执行，请确认后运行）", { command: host.escapeHtml(item.command) })}</span><button class="cc-inline-pill" data-run-missed="${host.escapeHtml(item.id)}">${t("立即执行")}</button><button class="cc-inline-pill" data-dismiss-missed="${host.escapeHtml(item.id)}">${t("忽略")}</button></div>`,
        )
        .join("")}</div></div>`,
    );
  }

  // Active timers, proactive AI suggestions, and quick camera card follow Win+N collapsible groups
  // when the assistant bar toggle is active.
  if (host.isShowingAssistantBar) {
    if (host.pendingSuggestions.length === 0) {
      const items = host.currentProactiveSuggestions();
      if (items.length > 0) {
        const openAttr = host.collapsedNotifCards.has("proactive") ? "" : "open";
        cards.push(
          `<details class="win-notif-card cc-feedback-card" data-notif-card="proactive" ${openAttr}>
            <summary class="win-notif-summary">
              <span class="win-notif-icon">${SF_ICONS.sparkles}</span>
              <span class="win-notif-app">${t("猜你想控")}</span>
              <span class="win-notif-count">${items.length}</span>
              <span class="win-notif-chevron">${SF_ICONS.chevronDown}</span>
            </summary>
            <div class="cc-suggestion-row" data-proactive-bar>${items
              .map((item) => renderProactiveInlinePill(host, item))
              .join("")}</div>
          </details>`,
        );
      }
    }

    if (host.scheduledCommands.length > 0) {
      const openAttr = host.collapsedNotifCards.has("timers") ? "" : "open";
      cards.push(
        `<details class="win-notif-card cc-feedback-card" data-notif-card="timers" ${openAttr}>
          <summary class="win-notif-summary">
            <span class="win-notif-icon">${SF_ICONS.clock}</span>
            <span class="win-notif-app">${t("定时指令")}</span>
            <span class="win-notif-count">${host.scheduledCommands.length}</span>
            <span class="win-notif-chevron">${SF_ICONS.chevronDown}</span>
          </summary>
          <div class="cc-timers-stack">${host.scheduledCommands
            .map(
              (item) => `<div class="cc-timer-row"><span>${host.escapeHtml(item.command)} ${t("· 剩余 {remaining}", { remaining: host.formatRemainingMs(item.fireTimestampMs - Date.now()) })}</span><button class="cc-inline-pill" data-cancel-timer="${host.escapeHtml(item.id)}">${t("取消")}</button></div>`,
            )
            .join("")}</div>
        </details>`,
      );
    }

    if (host.cameraLive.activeLiveCameraId === null || host.cameraLive.liveCameraHidden) {
      const onlineCameras = withAliases(host.layout, host.devices).filter(
        (d) => d.kind.kind === "camera" && d.isOnline,
      );
      const cam =
        onlineCameras.find((d) => d.id === host.cameraLive.activeLiveCameraId) ?? onlineCameras[0];
      if (cam && cam.kind.kind === "camera") {
        const camId = host.escapeHtml(cam.id);
        const camOn = isDeviceActiveOn(cam);
        const isWarmStandby =
          host.cameraLive.activeLiveCameraId === cam.id && host.cameraLive.liveCameraHidden;
        const canToggleCam = deviceCanTogglePower(cam);
        const canExpandCam = hasDetailDrawer(cam, host.deviceFacets[cam.id] ?? []);
        const summaryState = isWarmStandby
          ? trText("120s 保活", "120s warm")
          : camOn
            ? trText("实时 · 高清", "Live · HD")
            : trText("镜头休眠", "Sleeping");
        const summaryMeta = cam.roomName ? `${cam.roomName} · ${summaryState}` : summaryState;
        const detailStatus = isWarmStandby
          ? trText("P2P 120s 保活就绪", "P2P 120s warm standby")
          : !camOn
            ? trText("镜头隐私休眠中", "Privacy sleep active")
            : cam.kind.isMotionDetectionOn
              ? trText("移动侦测开启 · 点击速览", "Motion alert on · Tap to view")
              : trText("实时画面就绪 · 点击速览", "Live stream ready · Tap to view");
        const liveBadge = isWarmStandby
          ? trText("120s 保活", "120s warm")
          : camOn
            ? trText("高清", "HD")
            : trText("已休眠", "Asleep");
        const openAttr = host.collapsedNotifCards.has("camera") ? "" : "open";
        cards.push(
          `<details class="win-notif-card cc-feedback-card win-camera-card" data-notif-card="camera" ${openAttr}>
            <summary class="win-notif-summary">
              <span class="win-notif-icon">${SF_ICONS.videoFill}</span>
              <span class="win-notif-app">${host.escapeHtml(cam.name)}</span>
              <span class="win-notif-meta">${host.escapeHtml(summaryMeta)}</span>
              <span class="win-notif-chevron">${SF_ICONS.chevronDown}</span>
            </summary>
            <div class="win-camera-deck">
              <button
                type="button"
                class="win-camera-preview ${camOn ? "is-live-ready" : "is-sleeping"} ${isWarmStandby ? "is-warm" : ""}"
                data-open-camera="${camId}"
                aria-label="${host.escapeHtml(t("查看实时画面"))} · ${host.escapeHtml(cam.name)}"
              >
                <svg class="win-camera-wireframe" viewBox="0 0 160 90" aria-hidden="true">
                  <rect x="14" y="18" width="44" height="34" rx="2" />
                  <line x1="36" y1="18" x2="36" y2="52" />
                  <rect x="68" y="42" width="76" height="30" rx="3" stroke-dasharray="3 2" />
                  <line x1="8" y1="74" x2="152" y2="74" />
                </svg>
                <span class="win-camera-live-pill">
                  <span class="win-camera-live-dot"></span>
                  <span>${host.escapeHtml(liveBadge)}</span>
                </span>
                ${cam.roomName ? `<span class="win-camera-room-tag">${host.escapeHtml(cam.roomName)}</span>` : ""}
              </button>
              <div class="win-camera-side">
                <div class="win-camera-status" title="${host.escapeHtml(detailStatus)}">${host.escapeHtml(detailStatus)}</div>
                <div class="win-camera-actions">
                  ${
                    canToggleCam
                      ? `<button type="button" class="cc-inline-pill ${camOn ? "is-accent" : ""}" data-toggle-device="${camId}" aria-pressed="${camOn}">${camOn ? trText("休眠", "Sleep") : trText("唤醒", "Wake")}</button>`
                      : ""
                  }
                  ${
                    canExpandCam
                      ? `<button type="button" class="cc-inline-pill win-camera-icon-pill" data-reveal-device="${camId}" title="${host.escapeHtml(t("展开 {name} 详细控制", { name: cam.name }))}" aria-label="${host.escapeHtml(t("展开 {name} 详细控制", { name: cam.name }))}">${SF_ICONS.sliderHorizontal}</button>`
                      : ""
                  }
                  <button type="button" class="cc-inline-pill ${camOn ? "" : "is-accent"}" data-open-camera="${camId}">${t("实时画面")}</button>
                </div>
              </div>
            </div>
          </details>`,
        );
      }
    }
  }

  if (cards.length === 0) return "";
  return `<div class="win-notif-stack">${cards.join("")}</div>`;
}

export function renderSliderDeck(host: MenuMijiaWindowsApp): string {
  if (
    host.isEditingLayout ||
    Boolean(normalizeSearch(host.panelSearch.query)) ||
    host.expandedDeviceId !== null ||
    host.valuesAreStale
  ) {
    return "";
  }
  const scoped = withAliases(host.layout, host.presentationDevices);
  const dimmableLights = scoped.filter(
    (d): d is SmartDevice & { kind: Extract<SmartDevice["kind"], { kind: "light" }> } =>
      d.kind.kind === "light" && d.isOnline && d.kind.brightnessWritable !== false,
  );
  const primaryLight =
    (host.lastManuallyUsedLightId
      ? dimmableLights.find((d) => d.id === host.lastManuallyUsedLightId)
      : undefined) ??
    dimmableLights.find((d) => isDeviceActiveOn(d)) ??
    dimmableLights[0];

  const writableSpeakers = scoped.filter(
    (d): d is SmartDevice & { kind: Extract<SmartDevice["kind"], { kind: "speaker" }> } =>
      d.kind.kind === "speaker" && d.isOnline && d.kind.volumeWritable,
  );
  const primarySpeaker = writableSpeakers[0];

  if (!primaryLight && !primarySpeaker) return "";

  const rows: string[] = [];
  if (primaryLight) {
    const bri = primaryLight.kind.isOn ? (primaryLight.kind.brightnessPercent ?? 80) : 0;
    const id = host.escapeHtml(primaryLight.id);
    const name = host.escapeHtml(primaryLight.name);
    const canToggle = primaryLight.kind.powerWritable !== false;
    const canExpand = hasDetailDrawer(primaryLight, host.deviceFacets[primaryLight.id] ?? []);
    rows.push(
      `<div class="win-slider-row">
        ${
          canToggle
            ? `<button type="button" class="win-deck-btn ${primaryLight.kind.isOn ? "is-active" : ""}" data-deck-toggle="${id}" title="${name}" aria-label="${host.escapeHtml(t("{name} 开关", { name: primaryLight.name }))}" aria-pressed="${primaryLight.kind.isOn}">${SF_ICONS.sunMaxFill}</button>`
            : `<span class="win-deck-btn" title="${name}" aria-hidden="true">${SF_ICONS.sunMaxFill}</span>`
        }
        <input
          class="cc-range win-deck-range"
          type="range"
          min="1"
          max="100"
          value="${Math.max(1, bri || 80)}"
          style="--val:${bri}%"
          data-deck-brightness="${id}"
          title="${name}"
          aria-label="${host.escapeHtml(t("{name} 亮度", { name: primaryLight.name }))}"
          aria-valuemin="1"
          aria-valuemax="100"
          aria-valuenow="${Math.max(1, bri || 80)}"
        />
        <span class="win-deck-val">${bri}%</span>
        ${
          canExpand
            ? `<button type="button" class="win-deck-more" data-deck-expand="${id}" title="${name}" aria-label="${host.escapeHtml(t("展开 {name} 详细控制", { name: primaryLight.name }))}">${SF_ICONS.chevronRight}</button>`
            : ""
        }
      </div>`,
    );
  }

  if (primarySpeaker) {
    const vol = primarySpeaker.kind.volumePercent;
    const muted = Boolean(primarySpeaker.kind.isMuted);
    const id = host.escapeHtml(primarySpeaker.id);
    const name = host.escapeHtml(primarySpeaker.name);
    const canMute = Boolean(primarySpeaker.kind.muteSwitchEntityId);
    const canExpand = hasDetailDrawer(primarySpeaker, host.deviceFacets[primarySpeaker.id] ?? []);
    rows.push(
      `<div class="win-slider-row">
        ${
          canMute
            ? `<button type="button" class="win-deck-btn ${!muted ? "is-active" : ""}" data-deck-mute="${id}" title="${name}" aria-label="${host.escapeHtml(muted ? t("取消静音") : t("静音"))}" aria-pressed="${muted}">${muted ? SF_ICONS.speakerSlash : SF_ICONS.speakerWave}</button>`
            : `<span class="win-deck-btn" title="${name}" aria-hidden="true">${muted ? SF_ICONS.speakerSlash : SF_ICONS.speakerWave}</span>`
        }
        <input
          class="cc-range win-deck-range"
          type="range"
          min="0"
          max="100"
          value="${vol}"
          style="--val:${muted ? 0 : vol}%"
          data-deck-volume="${id}"
          title="${name}"
          aria-label="${host.escapeHtml(t("{name} 音量", { name: primarySpeaker.name }))}"
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow="${vol}"
        />
        <span class="win-deck-val">${vol}%</span>
        ${
          canExpand
            ? `<button type="button" class="win-deck-more" data-deck-expand="${id}" title="${name}" aria-label="${host.escapeHtml(t("展开 {name} 详细控制", { name: primarySpeaker.name }))}">${SF_ICONS.chevronRight}</button>`
            : ""
        }
      </div>`,
    );
  }

  return `<section class="win-slider-deck" aria-label="${t("快捷滑杆")}">${rows.join("")}</section>`;
}

function footerStatus(host: MenuMijiaWindowsApp): string {
  const health = host.panelHealth();
  const dot = `<span class="cc-status-dot ${health.dot}"></span>`;
  const escaped = host.escapeHtml(health.label);
  if (health.kind === "offline" && health.recovery === "qr") {
    return `${dot}<button type="button" class="cc-footer-label is-action" id="btn-footer-health" title="${escaped}">${escaped}</button>`;
  }
  return `${dot}<span class="cc-footer-label" title="${escaped}">${escaped}</span>`;
}

function liveBanner(host: MenuMijiaWindowsApp): string {
  const reply = host.replyBanner;
  const undo = host.undoButtonVisible();
  if (!reply && !undo && !host.pendingCloudConsent) return "";
  const role = reply?.isError ? "alert" : "status";
  return `<div class="win-notif-card cc-live-banner cc-feedback-card ${reply?.isError ? "is-error" : ""}" role="${role}">
    <div class="cc-feedback-row">
      ${reply ? `<span class="cc-feedback-badge">${host.escapeHtml(reply.source)}</span><span class="cc-feedback-text">${host.escapeHtml(reply.text)}</span>` : ""}
      ${
        host.pendingCloudConsent
          ? `<button class="cc-inline-pill" id="btn-cloud-allow">${t("允许并发送")}</button><button class="cc-inline-pill" id="btn-cloud-decline">${t("不用了")}</button>`
          : ""
      }
      ${undo ? `<button class="cc-inline-pill" id="btn-undo">${t("撤销")}</button>` : ""}
      ${reply?.isError ? `<button type="button" class="cc-inline-pill" id="btn-dismiss-banner" aria-label="${t("忽略")}">×</button>` : ""}
    </div>
  </div>`;
}

function quickActionIcon(id: QuickActionId): string {
  switch (id) {
    case "lightsOff":
      return SF_ICONS.lightbulbFill;
    case "softNightLight":
      return SF_ICONS.moonStarsFill;
    case "climateSleepOff":
      return SF_ICONS.snowflake;
  }
}

function quickStrip(host: MenuMijiaWindowsApp): string {
  if (!host.settings.showQuickActionsBar) return "";
  if (host.settings.connectionMode === "demo") {
    const pills = quickActions().map(
      (act) => `<button class="cc-quick-pill tint-${act.tint}" data-scene-cmd="${host.escapeHtml(act.command)}"><span class="cc-quick-icon">${act.icon}</span><span>${host.escapeHtml(act.title)}</span></button>`,
    ).join("");
    return `<section class="cc-quick-strip">${pills}</section>`;
  }
  const builtIns = availableQuickActions(quickActionScopeDevices(host)).map(
    (act) =>
      `<button class="cc-quick-pill tint-${act.tint}" data-scene-cmd="${host.escapeHtml(act.command)}"><span class="cc-quick-icon">${quickActionIcon(act.id)}</span><span>${host.escapeHtml(act.title)}</span></button>`,
  );
  const haScenes =
    host.settings.connectionMode === "homeAssistant"
      ? host.scenes.map(
          (scene) =>
            `<button class="cc-quick-pill tint-blue" data-ha-scene="${host.escapeHtml(scene.id)}"><span class="cc-quick-icon">${SF_ICONS.sparkles}</span><span>${host.escapeHtml(scene.name)}</span></button>`,
        )
      : [];
  const allPills = [...builtIns, ...haScenes];
  if (allPills.length === 0) return "";
  return `<section class="cc-quick-strip">${allPills.join("")}</section>`;
}
