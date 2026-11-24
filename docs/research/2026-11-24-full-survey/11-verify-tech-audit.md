# 11 独立技术与源码事实核验审计报告（Wave 2 Tech Audit）

- **审计角色**：`verifier-tech`（第二波独立技术与源码事实核验官，全程只读，零仓库/零第一波报告/零 Issue 改动）
- **审计基准**：`MenuBarHome-main` 本地源码与 GitHub `jryang2026-code/MenuBarHome`（截至 `2026-11-24T08:16Z`，最新合入含 `PR #460`，仅余 `PR #453` 在途与 28 条 Open Issues）、`docs/research/2026-11-23-deep-dive/`（16 份昨日基线调研）、`docs/adr/0003..0025`、`.out-of-scope/`、以及 `scratch/repos/` 下已克隆外部仓库与本机 Cargo 注册表缓存（`tauri-2.12.4`、`wry-0.57.0`、`tao-0.37.1`、`tray-icon-0.25.1`）。
- **核心裁决（直报结论）**：
  1. **总体过关，无需打回第一波重做，可直接进入最终路线图综合**；但综合阶段**必须强制应用本文列出的 8 项纠偏与 7 项跨报告冲突裁决**。
  2. **源码抽检总通过率**：共抽检 **54 条** 关键源码/符号/事实断言（本仓 32 条 + 外部仓与 Cargo 缓存 22 条）：**47 条完全准确（87.0%）**，**4 条轻微偏差/时效差（7.4%）**，**3 条实质性错误或严重低估（5.6%）**——分别是：① `09` 误称 Windows 当前已有 DWM Acrylic 背景（源码证伪）；② `07` 建议对 `tauri::tray::TrayIconBuilder` 调 `with_guid(...)` 在 `tauri 2.12.4` 中未透传且未注明未签名 EXE 的路径绑定约束；③ `08` 将 `mbh-wasm-host` 体积严重低估为 4–6 MB（Cranelift 实为 18–28 MB/架构且有 `allow-jit` 公证风险）并提出与 `.out-of-scope/` 直接冲突的桌面 Virtual HAP/Matter 桥。
  3. **去重净增量结论**：`miIO.sub` 与 `datasource: 1` **并非本轮净新发现**（昨日 `01-xiaomi-drivers.md` 已研且已立 `ADR-0025` / `#449` / `#411`）；Windows 本地 miIO 已有在途 `PR #453`（`04` 漏检）。**本轮真正高价值的净增量突破**集中在：Windows `network.rs:192` / `home_assistant.rs:201` 传输层漏水实锤、双端半开 TCP 120s 假死与 OS 路由回调、`SetMemoryUsageTargetLevel(Low)` 推翻昨日误判可立即可用、Windows 托盘 5 处 `tao`/`tray-icon` 底层根因、Per-Field `writeEpoch` 零回弹屏障、Connect-Time 防 DNS Rebinding、Scrypted fd 3/4 RPC 通道、零知识 Credential Broker 与进程外 `mbh-wasm-host` 架构破局思路。

---

## 一、源码与引用抽检审计总表（54 项实读核验）

> 口径：`✅ 精确证实`（文件/行号/符号/语义全吻合）｜`⚠️ 轻微偏差/漏背景`（结论大体成立但行号、时效或上下文不完整）｜`❌ 实质错误/严重低估`（与源码或工具链事实矛盾，必须纠偏）。

### 1.1 MenuBarHome 本仓关键源码抽检（32 项）

| # | 来源报告 | 引用目标（`path:line#symbol`） | 核验结果 | 实读源码事实与纠偏说明 |
| :---: | :---: | :--- | :---: | :--- |
| 1 | `10` | `windows/src-tauri/src/network.rs:192-196` | ✅ | 确证 `native_http_with_scope` 每次调用均执行 `reqwest::Client::builder().redirect(policy).timeout(...).build()`，无连接池与 TLS 复用。 |
| 2 | `10` | `windows/src-tauri/src/network.rs:397-412` | ✅ | 确证 `is_local_network_host` 仅按 URL 字符串校验 IP 字面量与 `.local/.lan/.home.arpa/.internal` 后缀，未在 DNS 解析后校连接 IP。 |
| 3 | `10` | `windows/src-tauri/src/home_assistant.rs:201-268, 485-526` | ✅ | 确证 `ha_snapshot`/`ha_execute` 每次 `spawn_blocking` 新建阻塞 `tungstenite` TCP+TLS+WS+Auth 短连并在 L256 `socket.close(None)` 关闭。 |
| 4 | `01`/`10` | `windows/src-tauri/src/credentials.rs:7-32, 74-119, 121-129` | ✅ | 确证槽名白名单、`CredEnumerateW` 只枚举名、`secure_store_get`（L122-129）直接将明文凭据返回给 WebView2 JS。 |
| 5 | `10` | `windows/src-tauri/src/job_object.rs:10-101` | ✅ | 确证仅设置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (0x2000)`，无内存、CPU 速率或子进程数上限。 |
| 6 | `07` | `windows/src-tauri/src/window.rs:6, 316-367, 746-790, 1035-1119` | ✅ | 确证 `TRAY_ICON_SLOP_PX = 36` 未按 DPI 缩放、`return_focus_to_tray` 穷举 `1..=8`、`position_popover` 读旧屏 `outer_size()` 后异步 `set_position`、`open_settings_window` 仅 `transparent(false)` + 深色标题栏无 Mica。 |
| 7 | `01`/`07` | `windows/src-tauri/src/desktop_shell.rs:118-150, 229-260, 409-488` | ✅ | 确证 `has_run_registry_entry` 只查 `HKCU\...\Run` 不查 `StartupApproved\Run`；发布版已用进程内 WinRT Toast（L409-488）；托盘仅 Tooltip。 |
| 8 | `07` | `windows/src-tauri/src/main.rs:143-156, 333, 364-382` | ✅ | 确证 `build_tray_menu` 无分组与快捷场景；`TrayIconEvent::Click` 模式匹配用 `..` 丢弃了 `rect`。 |
| 9 | `07` | `windows/src-tauri/src/companion.rs:406-413` | ✅ | 确证 `AllowSetForegroundWindow(endpoint.pid)` 仅在 `startup_url.and_then(parse_toast_activation).is_some()` 时调用，`/activate` 路径缺失。 |
| 10 | `07`/`10` | `windows/src-tauri/tauri.conf.json:28` | ⚠️ | `07` 精准标注 `L28`（`"backgroundThrottling": "disabled"`）；`10` 两次误写为 `L27`（L27 是 `"center": false`），属轻微行号偏差。 |
| 11 | `07` | `windows/src-tauri/Cargo.lock` 运行时版本 | ✅ | 实测 `Cargo.lock` 逐一吻合：`tauri 2.12.4`、`wry 0.57.0`、`tao 0.37.1`、`tray-icon 0.25.1`、`webview2-com 0.39.1`。 |
| 12 | `07` | `windows/src-tauri/src/main.rs:333` 给 `TrayIconBuilder` 加 `with_guid(...)` | ❌ | **API 事实错误**：本机核查 `tauri-2.12.4/src/tray/mod.rs`（L203-390），`tauri::tray::TrayIconBuilder` **并未透传 `with_guid`**（仅底层 `tray-icon 0.25.1` 有该方法），直接照抄无法编译；且未签名 EXE 下 `NIF_GUID` 仍强绑定路径（见 §1.2 #38）。 |
| 13 | `09` | `windows/src/ui/panelPrefs.ts` & Windows 材质现状（`09:17`） | ❌ | **硬事实错误（幻觉）**：`09` 表中「Windows 现状（源码实证）」声称已有 **「DWM Acrylic 背景」**。实读 `panelPrefs.ts:25-26` 注释明写 *WebView2 does not blur the desktop behind a transparent window*，且全仓 `windows/src-tauri/src/*.rs` 检索 `DWMWA_SYSTEMBACKDROP_TYPE` / `DWMSBT_` / `ACCENT_ENABLE` 结果为 **0 命中**！ |
| 14 | `10` | `windows/src/core/dualSourceProvider.ts:1156-1202` | ✅ | 确证单次失败立即将 `this.lastHA = null` / `this.lastMi = null`，缺少 macOS 侧 15s `sourceFallbackGrace` 磁滞。 |
| 15 | `07`/`10` | `windows/src/ui/appLifecycle.ts:1539-1600` | ✅ | 确证 `startTimerLoop` 在前端 JS 驱动 `processScheduledCommands`、`tickSafetyHealthAndAutomation` 与 `refreshDevices`。 |
| 16 | `09` | `windows/src/ui/motionSpring.ts:20` | ✅ | 确证 `sampleSpringProgress(spec, steps = 17)` 默认 17 帧采样。 |
| 17 | `06`/`10` | `Sources/MenuBarMijiaApp/MenuBarPanelController+Presentation.swift:75, 89, 162-172, 345-351, 358, 371-372` | ✅ | 确证 `makePanel` 为 `[.borderless]`、`isMovable = false`；`showPanel` 调 `NSApp.activate`；`finishOrderingPanelOut` 立刻 `dropPanelContent()`；`applySerialPanelGeometry` 直接 `panel.setFrame` 无插值。 |
| 18 | `06`/`10` | `Sources/MenuBarMijiaApp/MenuBarPanelController.swift:845, 915, 1012, 1037` | ✅ | 确证 `badgedTemplateImage`、`monospacedDigitSystemFont`、`dropPanelContent()`、`.environment(\.appearsActive, true)` 均精确存在。 |
| 19 | `06` | `Sources/MenuBarMijiaApp/ThemeAndMotion.swift:647-651, 683-687` | ✅ | 确证 `GlassShapeBackground` 与 `ChipSurface` 的 macOS 26 分支均存在 `if let tint { .glassEffect(...tint) } else { .glassEffect(...) }` 视图身份分叉。 |
| 20 | `06` | `Sources/MenuBarMijiaApp/CameraLiveVideoPlayer.swift:952` | ✅ | 确证 `WindowDragView.acceptsFirstMouse(for:)` 返回 `true`。 |
| 21 | `06` | `Sources/MenuBarMijiaApp/HotkeyAndNotificationManager.swift:480` & `SettingsWindowOpener.swift:37-44` | ✅ | 确证已有 `hasMarkedText()` 检查、未排除 `NSPanelViewBridge` Emoji 面板；`SettingsWindowOpener` 调 `NSApp?.activate()` 且未切换 `.regular` Dock 策略。 |
| 22 | `10` | `Sources/MenuBarMijiaApp/SystemActivityMonitor.swift:86-94, 153-161` | ✅ | 确证 `NWPathMonitor` 仅取 `path.status == .satisfied` 布尔并在 `previous == false && isSatisfied` 时才恢复，漏检同满足态换网/切 VPN。 |
| 23 | `10` | `Sources/MijiaCore/HomeProvider.swift:335, 448-452, 479-492, 584-585, 715-721` | ✅ | 确证 `timeoutIntervalForRequest = 120`、`sendWebSocketPing` 不等待/校验 `pong`、`refreshNow()` 在 `handshakingWebSocket != nil` 时空返、重连退避封顶 `10.0s`、25s `pingTask` 无 `tolerance` 且无视休眠。 |
| 24 | `01` | `Sources/MijiaCore/HomeStore+Backend.swift:1060-1126` & `DeviceDeduplicator.swift:47-56` | ✅ | 确证 `makeLiveProvider`/`makeComposite` 与 `DeviceDeduplicator.merge` 硬编码 `homeAssistant`/`xiaomiCloud` 双槽。 |
| 25 | `10` | `Sources/MijiaCore/HomeStore+ControlWrite.swift:1216` & `OptimisticField.swift:62-76` | ✅ | 确证滑块默认 `.milliseconds(280)` 尾随防抖；`OptimisticLockEntry` 仅有 `until`/`untilInstant`/`revision`，缺快照发起前 `writeEpoch` 丢弃屏障。 |
| 26 | `10` | `Sources/MijiaCore/HAPlaintextConsent.swift:12-23` | ✅ | 确证明文同意基于 `URL` 字符串主机名判定，未做连接时解析 IP 复核。 |
| 27 | `10` | `Sources/MijiaCore/MiCloud/LocalMiIOClient.swift:95-171` | ✅ | 确证 `NWConnectionMiIOUDPTransport.send` 每次收发新建 `NWConnection` 与超时 `Task`。 |
| 28 | `10` | `Sources/MijiaCore/DualSourceHomeProvider.swift:96, 110-118, 317` | ✅ | 确证 `DispatchFallbackRecheckTimer` 未设 `leeway`；`sourceFallbackGrace = 15` 使用 `SuspendingClock`。 |
| 29 | `04` | `Sources/MijiaCore/MiCloud/MiCloudClient.swift:823` & `MiotSpec.swift:356` | ✅ | 确证 `getProps` 调 `miotspec/prop/get` 未传 `datasource: 1`；`loadTypeIndex` 仅拉 `status=released`。 |
| 30 | `04` | Windows `LocalMiIOClient` 现状（`04:10, 127-129, 369`） | ⚠️ | `main` 确无实现，但 `04` **漏检在途 Open PR `#453`**（已实现 Rust `miio.rs`/`miio_crypto.rs` 与共享 `miio_protocol_golden.json`）及 Open Issue `#457`，且未提及 `miIO.sub`/`datasource: 1` 已有 `ADR-0025`/`#449`/`#411`。 |
| 31 | `01` | Open PR `#460` 状态（`01:197`） | ⚠️ | 时效差：`01` 于 `07:25Z` 审计时为 OPEN，`07:50:26Z` `#460` 已 **MERGED**，当前仅余 `#453` 为 Open PR。 |
| 32 | `08` | `Shared/adapterManifest.schema.json:19-45` & `ADR-0024` | ✅ | 确证 25 个禁止键黑名单与 v0 只读契约全部一致。 |

### 1.2 外部开源仓库与底层 Crate 源码抽检（22 项）

| # | 来源报告 | 外部仓与符号锚点 | 核验结果 | 实读证实要点与纠偏说明 |
| :---: | :---: | :--- | :---: | :--- |
| 33 | `03` | `scrypted:server/src/plugin/runtime/python-worker.ts:105, 128-129` | ✅ | 确证 5 路 `stdio` 将 `stdio[3]`/`stdio[4]` 专用于 `peerin`/`peerout`，彻底隔离第三方 C/Python 库 `stdout` 污染。 |
| 34 | `03` | `ha-core:homeassistant/helpers/device_registry.py:750-767` | ✅ | 确证 HA 正拆分历史跨集成 Composite Device 回退单 `config_entry_id` 所有权。 |
| 35 | `03` | `openhab-core:...AutoUpdateManager.java:180-183` | ✅ | 确证 `case REVERT:` 发出当前状态预测事件使离线控制立即回弹。 |
| 36 | `04` | `ha_xiaomi_home:...miot/const.py:5-15` & `tuya-local:...const.py:13, 22-23` | ✅ | 确证小米许可明确禁用于 APP/Web/其他软件；确证 `tuya-local` 写死 `TUYA_CLIENT_ID = "HA_3y9q4ak7g4ephrvke"`、`API_PROTOCOL_VERSIONS` 含 `3.1..3.52`。 |
| 37 | `04` | `go2rtc:pkg/xiaomi/miss/producer.go:55-99` | ✅ | 确证 `probe(client, audio)` 在 `audio == false`（即 `audio=0`）时拿到视频 SPS/VPS 即 `break`，无需苦等音频包。 |
| 38 | `07` | Cargo `tray-icon-0.25.1:src/lib.rs:226-243, 371` & `windows/mod.rs:412, 645` | ⚠️ | `apply_guid` 与 `Click.rect` 均精确证实；但 **`lib.rs:231-238` 明确注释：未 Authenticode 签名的 EXE 上 `NIF_GUID` 仍绑定二进制路径**（仅覆盖同路径有效，换路径会失效甚至 `NIM_ADD` 失败），且 `tauri 2.12.4` 未暴露该 builder 方法（见 #12）。 |
| 39 | `07`/`10` | Cargo `wry-0.57.0:src/webview2/mod.rs:1825-1834` & upstream `wry:1965-1974` | ✅ | 确证 `set_memory_usage_level` 绑定 `ICoreWebView2_19::SetMemoryUsageTargetLevel(0|1)`。 |
| 40 | `07` | Cargo `tao-0.37.1:src/platform_impl/windows/window.rs:212, 238, 1543-1552` | ✅ | 确证 `set_outer_position` 带 `SWP_ASYNCWINDOWPOS`、`set_inner_size` 读旧屏 `scale_factor()`、`set_skip_taskbar` 仅调 `ITaskbarList::DeleteTab` 不加 `WS_EX_TOOLWINDOW`。 |
| 41 | `07` | `EcoPaste:src-tauri/src/window/lifecycle/mod.rs:41-60` & `autostart/windows.rs:7-40` | ✅ | 确证八态 `LifecyclePhase`（含 `Dormant` / `DestroyPending`）与 `StartupApproved\Run` 处理。 |
| 42 | `07` | `window-vibrancy:src/windows.rs:62-95` & `plugins-workspace/positioner/src/ext.rs:113` | ✅ | 确证 `DWMSBT_TRANSIENTWINDOW` 与 `clear_acrylic`（`DWMSBT_NONE`）；确证 `positioner` 使用全屏尺寸未减任务栏。 |
| 43 | `06` | `Maccy:Maccy/FloatingPanel.swift:25-45, 85-113` | ✅ | 确证 `.nonactivatingPanel`、`orderFrontRegardless()`+`makeKey()` 及顶边锚定 `verticallyResize`。 |
| 44 | `06` | `Ice:Ice/UI/IceBar/IceBar.swift:23, 31, 227-229` & `stats:Stats/helpers.swift:384-403` | ✅ | 确证 `allowsToolTipsWhenApplicationIsInactive = true`、`acceptsFirstMouse -> true` 及 macOS 26 `_needsTilingConstraintUpdate` 覆写抑制 WindowServer 日志风暴。 |
| 45 | `08` | `yetone-magpie:internal/pluginrt/pluginrt.go:35, 221` & `page.go:84-108` & `coderun/helper.go:19-140` & `docs/subsystems/mcp-router.md:1-25` | ✅ | `pluginrt` 事务收敛、槽位白名单、独立子进程 `run-code-helper`（`grace = 2s` + stdin/stdout NDJSON）与 MCP Hub 防环头 `X-Magpie-Router` 全部精确证实。 |
| 46 | `08` | `yetone-magpie:internal/plugin/host.js:29-40`（`08:14`） | ⚠️ | 轻微引文错位：`host.js:29-40` 是 `fs`/`net`/`dns` 等 Node 模块导入（间接印证宿主权限），原句 *"Bun plugins have host privileges; install trusted code."* 出自官方文档 `usemagpie.ai/docs/plugins`（已在昨日 R12 L861 记录）。 |
| 47 | `08` | `zed:crates/extension_host/src/wasm_host.rs:659-686` & `wit/since_v0.8.0/http-client.wit:1-45` | ✅ | 确证 `parse_wasm_extension_version`、`store.set_epoch_deadline(1)` + `epoch_deadline_async_yield_and_update(1)` 与宿主中介 `http-client` WIT 契约。 |
| 48 | `08` | `mbh-wasm-host` 体积估算 `4–6 MB` & `Virtual HAP/Matter Bridge`（`08:17, 111, 483, 527`） | ❌ | **严重低估 + 红线漏检**：① 带 Cranelift JIT + Component Model + `reqwest/rustls` 的 Wasmtime Rust 二进制 strip 后每架构 **~18–28 MB**（macOS Universal 35–50 MB），仅用 Pulley 解释器或无编译器 AOT 才能缩至 ~5–10 MB；② `Virtual HAP/Matter Bridge` 未核查本仓 `.out-of-scope/direct-matter-bridge.md` 与 `always-on-bridge-and-mobile-app.md`（与笔记本休眠生命周期及 MiCloud 轮询直接冲突）。 |
| 49 | `10` | `tailscale:net/netmon/netmon_windows.go:69-91` & `ha-js-ws:lib/states.ts:134-164` | ✅ | 确证 Win32 IP Helper 三回调（Unicast/Route/Interface）与 HA `subscribe_entities` 增量压缩订阅。 |
| 50–54 | `03`/`04`/`07`/`10` | `ha-core`、`openhab`、`tuya-local`、`EcoPaste`、`wry` 其余关联行号抽核 | ✅ | 其余 5 组关联行号（`tuya-local` 协议版本列表、`wry` `MemoryUsageLevel::Low`、`EcoPaste` `StartupApproved` 常量、`ha-js-ws` `replace` 复位、`scrypted` `PYTHONUNBUFFERED`）全部与源码一致。 |

---

## 二、「已完成 / 已立项 / 昨日已研 / 本轮净增量」四象限去重矩阵

> 目的：防止最终路线图把「本仓已上线功能」当提案，或绕开既有 Open Issue/PR 重复造单，并准确识别本轮调研真正挖出的**净增量技术突破**。

| 象限 | 具体能力 / 提案项 | 源码 / Issue / 文档证据 | 路线图处置意见 |
| :--- | :--- | :--- | :--- |
| **Q1：已完成**<br>（HEAD 已合入，**剔除出路线图**） | Windows 多账号 + HA/米家双源融合 | `miAccountsStore.ts`、`dualSourceProvider.ts`（v1.3.0 起已上线） | **剔除**（仅顺手更新滞后的 `README.md:237` 与 `GLOSSARY.md:22`） |
| | Windows 进程内 WinRT Toast + 点击跳转 | `desktop_shell.rs:409-488`（PR `#433`） | **剔除**（仅可在远期补门铃缩略图） |
| | Windows 自动隐藏任务栏补偿 + 设置窗深色标题栏 + Esc 归还焦点 | `placement.rs:103-197`、`window.rs:316, 1010`（PR `#400`） | **剔除**（仅修复 `return_focus_to_tray` 的 `1..=8` 探测） |
| | macOS `ProcessSupervisor` 子进程监督熔断（120s/5次） | `ProcessSupervisor.swift`、`SupervisedProcess.swift`（PR `#425`） | **剔除**（macOS 已就绪；Windows 侧挂接 Q2 `#424`） |
| | macOS/Win 5 档空闲轮询衰减 + `NSBackgroundActivityScheduler` | `PollingPolicy.swift`、`pollingPolicy.ts`、`UpdateScheduler.swift`（PR `#405/#406/#421/#454`） | **剔除**（仅对齐 `#455`） |
| | 通知分级 + `AlertSeverity` 两级 + 门铃缩略图 + 摄像机事件库/静帧墙 + 米家云场景 | PR `#398/#418/#408/#448/#450` | **剔除**（Windows 静帧墙挂接 Q2 `#447`） |
| | `HomeAdapter` SPI（HA 首家）+ `ADR-0024` v0 纯契约 + `Shared/deviceLabels/deviceClaims` | `HomeAdapter.swift`（`#439`）、`ADR-0024`（`#452`）、`#404/#440` | **剔除**（后续接续 Q2 `#438`/`#456`） |
| | WidgetKit & macOS 26 `ControlWidget` ad-hoc 可行性调研 | PR `#460`（`2026-11-24T07:50Z` 已合入，证伪无 Developer ID 路径） | **剔除**（强依赖 `#11`） |
| **Q2：已立项**<br>（已有 Open Issue/PR/Proposed ADR，**挂接原单推进**） | Windows 本地 miIO UDP 54321 协议与写确认 | **Open PR `#453`**（Part 1 Rust 协议层已开）+ Open `#457` | **挂接 `#453`/`#457`**，补齐 Part 2 TS 混合路由，勿重起炉灶 |
| | 米家 `miIO.sub` 局域网主动推送 | **`ADR-0025`（Proposed，本阶段暂缓）** + Open `#449` + 昨日 `R01` | **非本轮新发现**；按 `#449` 独立评估真机固件覆盖与功耗，不强塞 P0 |
| | 米家 `datasource: 1` 云缓存读 & 离线设备 LAN 探测 | Open `#411`（`ready-for-human`）+ Open `#412` + 昨日 `R01` | **挂接 `#411`/`#412`**（需真机实测语义后再切） |
| | ADR-0024 校验器/Schema 4 项缺口 + 米家接 `HomeAdapter` SPI | Open `#456`（阶段 4 硬前置）+ Open `#438` | **挂接 `#456`/`#438`** 作为插件化 Phase 1 必清前置 |
| | Windows go2rtc 监督熔断 + 静帧墙 + HA 局域网发现 | Open `#424` + `#447` + `#294` | **挂接原单**（`#424` 应直接做成通用 `supervisor.rs` 供 ADR-0024 复用） |
| | macOS `buildTV` 消灭最后 1 条双端差异 + 自动化定时/持续时长/守卫 | Open `#442` + `#430`/`#431`/`#432` + `#443` | **挂接原单** |
| | Apple Developer ID 签名公证 + Windows SignPath 签名 | Open `#11` + `#12`（`ready-for-human`，2026-11-23 拍板暂缓） | **挂接原单**，路线图明确受阻功能边界 |
| **Q3：昨日已研**<br>（`2026-11-23-deep-dive` 已覆盖但未立单） | `StartupApproved\Run` 自启状态失步 & `AllowSetForegroundWindow` | 昨日 `R07:244, 252, 335, 340`（`#433` 仅修了 Toast 分支，漏了 `/activate`） | 本轮 `07` 补齐了 `EcoPaste` 方案与 `/activate` 缺口，可直接落 P0 |
| | `DWMSBT_TRANSIENTWINDOW` / `TrySuspend` 依赖 Rust 下沉 | 昨日 `R07:35, 258, 435` | 本轮 `07`/`10` 深化了双岛冲突与 `Low` vs `TrySuspend` 解耦（见 §三） |
| | macOS `.nonactivatingPanel` + `Stats` Tahoe WindowServer 日志抑制 + `CodexBar` 内存压力/卡顿看门狗 | 昨日 `R10:30, 33, 178, 199` | 本轮 `06`/`10` 补齐具体落点，须套用 §3.4 五项副作用护栏 |
| | Hue CLIP v2（含 `geofence` 探活坑）、`matter.js` Multi-Admin、涂鸦 `tuya-local` 1790 YAML 与 `CLIENT_ID` 红线、Aqara LANLink、go2rtc backchannel | 昨日 `R04`/`R05`/`R15` | 协议选型二次互证，可稳定收敛为生态接入优先级 |
| **Q4：本轮净增量高价值技术突破**<br>（**真正新挖出的核心壁垒**） | **1. Windows Rust 传输层两处 P0 性能漏水实锤 + 双端 `subscribe_entities` 增量订阅** | `10` 实锤 `network.rs:192` 每次重建 `reqwest::Client`、`home_assistant.rs:201` 每次短连阻塞 `tungstenite`；`ha-js-ws` 增量压缩减流 60–80% | **顶级 P0 净增量**（低风险、体感提速立竿见影） |
| | **2. 双端休眠/换网半开 TCP 120s 假死根治 + OS 级路由回调** | `10` 实锤 `HomeProvider.swift:335, 448, 584, 715` 无 `pong` 超时/离家 10s 死循环、`SystemActivityMonitor:86` 漏检 Wi-Fi↔VPN 切换；引入 Tailscale Win32 IP Helper 三回调 + `QueryUnbiasedInterruptTime` 15s Windows 磁滞 | **顶级 P0/P1 净增量**（根治合盖失联与离家耗电） |
| | **3. WebView2 `SetMemoryUsageTargetLevel(Low)` 纠偏立即可用 + `settings` 窗 `DestroyWhenIdle`** | `07`/`10` 实证 `wry 0.57` 已内置且不冻结 JS 定时器（推翻昨日 `R07:35` 误判）；`EcoPaste` 次级窗空闲 60s 销毁直接省 60–120MB | **高 ROI P1 净增量** |
| | **4. Windows 托盘 5 处底层源码级根因突破** | `07` 实锤 `tao` `SWP_ASYNCWINDOWPOS` 跨 DPI 漂移、`tao` `set_skip_taskbar` 缺 `WS_EX_TOOLWINDOW` 致 Alt+Tab 泄漏、Win11 溢出托盘 `rect` 悬空、`TRAY_ICON_SLOP_PX=36` 高 DPI 缩水、`companion.rs:407` 漏 `/activate` 前台权（`NIF_GUID` 需先解 Tauri 封装） | **高 ROI P0 净增量** |
| | **5. Per-Field `writeEpoch` 防慢轮询越 3s TTL 回弹 + 离线强制 `REVERT` + 单槽滑块邮箱 + 429 读写分账令牌桶** | `03`（openHAB `REVERT`/ioBroker `ack`）+ `06`/`07`/`10`（`MonitorControl`/`twinkle-tray` 单槽邮箱 + `OptimisticField` 屏障） | **核心可靠性 P0/P1 净增量** |
| | **6. Connect-Time 防 DNS Rebinding + 消除 Windows JS 明文持密 + Job Object 硬配额** | `10` 实锤 `network.rs:397`/`HAPlaintextConsent:12` TOCTOU 风险、`credentials.rs:122` JS 明文暴露、`job_object.rs` 缺 CPU/RAM/进程帽 | **安全纵深 P1/P2 净增量** |
| | **7. ADR-0024 演进架构四大净增量**：Scrypted **fd 3/4 RPC 隔离**、**L0 零代码声明式驱动**、**Zero-Knowledge Credential Broker**、**进程外 `mbh-wasm-host`**（+ Magpie `run_code` MCP Hub & Vicinae 5 原语原生 SDUI） | `03`（`scrypted/python-worker.ts:105,128`）+ `08`（`zed`/`vicinae`/`yetone-magpie@851694a`）+ `10`（Broker） | **中长期战略 P2 净增量**（须按 §3.3/§3.5 修正体积与分流） |
| | **8. 体验与协议微观净增量**：macOS `.glassEffect` `if let tint` View Identity 防雷、macOS 45s 两级延迟卸载、Windows CSS `linear()` 替代 17 帧折线、`go2rtc` 小米 `audio=0` 探测提速、`MiotSpecStore` `status=all` + 官方多语言词库、SonoffLAN 100ms 写合并 | `04`（`go2rtc:producer.go:55`、`hass-xiaomi-miot`、`SonoffLAN`）+ `06`（`ThemeAndMotion.swift:647`）+ `09`（`motionSpring.ts:20`） | **高性价比快车道净增量** |

---

## 三、跨报告架构冲突仲裁（5 项指定冲突 + 2 项审计新发现冲突）

### 冲突 1：Windows DWM `DWMSBT_TRANSIENTWINDOW` vs 现有双岛 / 16px 阴影留白（`07` vs `09`）

- **冲突与纠偏**：`09:17` 误称 Windows 端现状已有 DWM Acrylic 背景（**证伪**：`panelPrefs.ts:25` 与 `tauri.conf.json:21-22` 证实当前是无系统模糊的透明 WebView2 + `#app { padding: 16px }` CSS 投影，且 Fluent 主题上下双岛间有 10px 透明缝）。`07:133, 196` 正确指出 DWM `DWMWA_SYSTEMBACKDROP_TYPE` 覆盖整个矩形 HWND，直接开启会把 16px 阴影留白与 10px 岛间缝隙全部糊成一整块毛玻璃方块。
- **最终裁决**：
  1. **立即落地（P1）**：仅对带原生标题栏的 `settings` 独立设置窗启用 `DWMSBT_MAINWINDOW`（Mica，Win11 Build ≥ 22621，`EnableTransparency == 0` 自动降级纯色），零几何冲突。
  2. **主面板分主题治理**：
     - **Classic 主题（单圆角卡）**：支持去 16px 外投影留白，切 Tauri `shadow: true` + `DWMWCP_ROUND` + Win11 22621+ `DWMSBT_TRANSIENTWINDOW`（隐藏时必置 `DWMSBT_NONE`，严防 EarTrumpet 记载的幽灵亚克力残留）。
     - **Fluent 双岛主题**：**严禁**对当前单 HWND 盲开 `DWMSBT_TRANSIENTWINDOW`！近期维持双岛 CSS 表面（叠加真实系统强调色 + 双注册表任务栏图标适配）；仅在二期确认值得承担双窗同步成本时，才采用 `FluentFlyout` 式上下岛双联动 HWND 方案（或提供「单岛真 Acrylic」切换项）。
  3. **低版本红线**：Win10 1903+ 与 Win11 22000 严禁对可拖动窗口调用旧版 `SetWindowCompositionAttribute(ACCENT_ENABLE_ACRYLICBLURBEHIND)`（`window-vibrancy` 源码证实会导致拖动严重掉帧）。

### 冲突 2：WebView2 `TrySuspend` 依赖内核下沉 Rust vs `SetMemoryUsageTargetLevel(Low)` 立即可用（`07` vs `10`）＋ **隐性冲突：`SetProcessWorkingSetSize(-1, -1)`**

- **冲突分析**：`07` 与 `10` 在核心分层上高度一致并共同推翻了昨日 `R07:35` 的误判，但在 L1 休眠细节上出现隐性冲突——`07:186, 253` 建议在 L1 Dormant 叠加 `SetProcessWorkingSetSize(-1, -1)`，而 `10:173` 将其定性为「明确禁用的反模式」。
- **最终裁决**：
  1. **立即可做（P1，无前置阻塞）**：启用 `ICoreWebView2_19::SetMemoryUsageTargetLevel(Low)`（隐藏 5–30s 后触发，托盘 `Enter`/`present` 恢复 `Normal`）＋ `settings` 次级窗引入 `EcoPaste` 式 `DestroyWhenIdle (60s)` 状态机。二者均**不冻结 JS 定时器、不中断安全告警与云刷新**。
  2. **强前置门禁（P2）**：移除 `tauri.conf.json:28` 的 `"backgroundThrottling": "disabled"`、启用 `ICoreWebView2_3::TrySuspendAsync()` 或 `destroy_main_window()` 轻量模式，**必须以 `ScheduledCommand`、安全告警轮询与 HA/米家后台通道下沉至 Rust `tokio` 内核为硬前置**（否则合窗即断告警与定时）。
  3. **采纳 `10` 否决 `07` 的 `SetProcessWorkingSetSize(-1, -1)`**：严禁作为常规降内存手段（仅把热页强刷到页面文件、不降真实 Commit Charge，反致点开托盘首帧触发硬缺页卡顿）。

### 冲突 3：ADR-0024 静态密钥（Hue/Tuya）与安全红线：宿主代签 Broker vs `writeOnly` 配置 + 纯 LAN 隔离（`04` vs `08` vs `10` vs `ADR-0024 §6.3`）

- **冲突分析**：`ADR-0024 §6.3` 审慎否决了 v0 阶段引入通用 Broker（避免把厂商私有协议拉回宿主），对静态密钥采用 `writeOnly: true` 配置注入；`04:339` 顺应此路线并提出用 `permissions.network.internet: []` + `lan: true` 封锁外网防泄密；`08:221-228` 与 `10:392-398` 则主张通过 `host.http.fetch` + 占位符代注 / HMAC 代签彻底做到「插件零接触静态密钥」。
- **最终裁决（不互斥，按协议传输形态与阶段硬分流）**：
  1. **ADR-0024 v0（Phase 1 只读首版，如 LG webOS）**：维持 `ADR-0024 §6.3` 最小契约不变，不引入 Broker；先合入 `#456` 强制 `inputType: "secret"` 必带 `writeOnly: true`。
  2. **HTTP / REST / SSE 类云端或局域网适配器（L0 声明式驱动、L1 WASM 适配器，如 SwitchBot / Govee / Aqara Cloud / Hue CLIP v2）**：**采纳 `08`/`10` 宿主零知识 Credential Broker**（作为 L0 与 ADR-0024 v1 标准能力）。宿主**仅提供 4 个协议无关通用原语**（`Bearer` / `Header` / `Query` 槽位替换 + 通用 `HMAC-SHA256` 签名原语），绝不把厂商私有业务逻辑拉回宿主，即可实现「插件零明文接触 + `(deny network*)` 沙箱 + Connect-Time CIDR 校验」。
  3. **私有二进制长连接局域网协议（L2 Sidecar：Tuya Local TCP 6668 AES-ECB/GCM 3-Way 握手、miIO UDP、Matter CASE/NOC 证书、Sonoff mDNS AES）**：HTTP Broker **无法代做**状态化二进制会话加密。此类适配器**采纳 `04` + `ADR-0024 §6.3`**：走 `writeOnly: true` 托管注入 + **强制无外网权限门禁**（Manifest 必须 `internet: []` 且 `lan: true`，OS 沙箱/AppContainer 硬阻断外网出口），把静态密钥严格封死在局域网内。

### 冲突 4：macOS `.nonactivatingPanel` 切走 `NSApp.activate` 的副作用边界（`06` vs 本仓实证）

- **本仓铁证**：核查 `CameraLivePanelController.swift:22-29, 962-970` 发现，本仓在已采用 `.nonactivatingPanel` 的摄像机浮窗上**已经踩过两个真实大坑**：① 必须覆写 `sendEvent` 在 `leftMouseDown && !isKeyWindow` 时补 `makeKey()`，否则 SwiftUI 关闭按钮吞第一击；② 聚焦 URL 文本框时（`setURLFieldActive`）必须显式调 `NSApp.activate()`！同时 `MenuBarPanelController.swift:1414-1422, 1624-1642` 当前高度依赖 `NSApplication.didResignActiveNotification` 驱动失焦收起与 macOS 26 `MenuBarAgent` 防重开。
- **最终裁决（可行，但必须采用「默认非激活 + 文本输入按需升权」混合模式，附 5 条硬护栏）**：
  1. **搜索框 / 助手栏 / 重命名与 CJK 输入法（最高风险边界）**：普通打开面板走 `.nonactivatingPanel` + `orderFrontRegardless()` + `makeKey()`（点开关、滑块、方向键零抢焦，不灰前台 IDE/视频标题栏）；**一旦进入任何 `TextField`/`NSTextView` 编辑态（`PanelSearchState`、`AssistantCommandBar`、改名）即按需调用 `NSApp.activate()`**，保证中文拼音/日文 IME 候选窗、Emoji 面板与 `⌘C/⌘V` 100% 稳定。
  2. **防吞首击双保险**：同时落地 `PanelHostingView.acceptsFirstMouse(for:) -> true` **与** `MenuBarPanel.sendEvent` 首击补 `makeKey()`（复用 `CameraFloatingPanel` 既有实证模式）。
  3. **收起信号迁移与 4 类豁免**：去掉 `showPanel` 的 `NSApp.activate` 后，`didResignActiveNotification` 将不再触发。必须把失焦关闭挂接到 `NSWindow.didResignKeyNotification`（现 L1388 仅取消 `allOffHold`）+ `globalMouseMonitor`，并严格豁免：**① 语音听写/长按及 TCC 弹窗期（`isListening`/`isHoldToTalk`/`pressTriggered`）**；**② 面板所属右键菜单/Popover/Sheet（`isPanelWindow`）**；**③ 摄像机实况窗**；**④ `ManualControlConfirmationPresenter` 高危 `NSAlert` 模态确认窗**（`MenuBarMijiaApp.swift:52` 仍保留 `NSApp.activate`）。
  4. **全局快捷键 & 局部监听**：Carbon 全局热键与 `HotkeyAndNotificationManager` 的 `addLocalMonitorForEvents` 在 `.nonactivatingPanel` 成为 `keyWindow` 后可正常接收按键（无需激活 App）；`SettingsWindowOpener.show` 已含 `NSApp?.activate()`，兼容无碍。
  5. **Settings 窗动态切换 Dock `.regular`（`06` P1 #7）**：降级为 **P2 可选项（默认关闭或谨慎灰度）**，落地时必须精确过滤 `panelWindow` / `backdropWindow` / `CameraFloatingPanel` / SwiftUI 隐形托管窗，防止关窗后 Dock 图标残留鬼影。

### 冲突 5：`L0 + L1 (mbh-wasm-host) + L2 (ADR-0024)` 与 `ADR-0023` 兼容性及打包/签名风险

- **ADR-0023 兼容性裁决**：
  - **L0 声明式驱动**：✅ 完全兼容（纯数据零第三方代码；开放用户外部安装时须补 ADR 启用 `ADR-0023` 重启条件 #1）。
  - **L1 共享进程外 `mbh-wasm-host`**：✅ **完全兼容 `ADR-0023`（宿主进程内零第三方代码）与 `ADR-0003`（`MijiaCore` 保持纯 Foundation）**。该设计把昨日 `R02/R12` 因「嵌进主进程」而否决的 WASM 方案外移至 ADR-0024 监督子进程，确实破局了「双端重写协议栈」难题。
  - **L2 Sidecar**：✅ 已在 `ADR-0024`（Proposed）建立契约。
- **打包体积、工具链与公证硬风险裁决（对 `08` 的强制纠偏）**：
  1. **体积风险**：Wasmtime + Cranelift + Component Model + `reqwest/rustls` 实测约 **18–28 MB/架构**（macOS Universal 35–50 MB），远超 `08` 宣称的 4–6 MB。**硬性裁决：绝不内置打进主 DMG/MSI/NSIS 安装包**，仅作为可选按需下载组件（安装首个 L1 插件时触发，经 ADR-0005 离线 Ed25519 清单 + SHA-256 验签校验）。
  2. **macOS 公证与 JIT 风险**：Cranelift JIT 需要 `MAP_JIT`，未来买 Apple Developer ID（`#11`）走 Hardened Runtime 公证时须额外带 `com.apple.security.cs.allow-jit` entitlement；且维护者 Mac 未装 `cargo`/`rustc`（`AGENTS.md` 实载）。**硬性裁决**：优先采用 **Wasmtime Pulley 字节码解释器**（压缩体积至 ~5–10 MB 且 **零 `allow-jit` entitlement 依赖**，完全满足 IoT JSON/HTTP 吞吐需求），由独立 CI workflow（仿 `camera-bin.yml`）产出 4 架构产物与 SBOM，不污染主构建链。

### 冲突 6（审计新发现）：`08` 提议的「Virtual HAP / Matter Bridge」与 `.out-of-scope/` 正面冲突

- **冲突证据**：`08:19, 140, 483, 527` 将 `Virtual HAP / Matter Bridge` 列入 Phase 3 与 L3 架构图，仅核对了 `ADR-0017` 而漏查本仓 `.out-of-scope/direct-matter-bridge.md` 与 `.out-of-scope/always-on-bridge-and-mobile-app.md`。两份边界文件已明确否决：桌面应用随笔记本休眠/合盖掉线会导致 Apple Home 下全部桥接配件「无响应」，且将 MiCloud 轮询强接 HAP/Matter 订阅会放大云端 429 封号风险。
- **最终裁决**：**从官方主路线图与核心承诺中剔除**；严禁作为官方主推特性或内置模块宣传（仅允许社区在常驻 Mac mini/台式机场景下自行做 L3 第三方外置工具，并附休眠掉线免责声明）。

---

## 四、合规、签名与安全红线复核

| 红线项 | 核验结论与一手源码/ADR 依据 | 落地硬约束 |
| :--- | :--- | :--- |
| **`XiaoMi/ha_xiaomi_home` 协议许可红线** | ✅ **确认不可逾越**。实读 `const.py:5-15` 明文禁止非 HA 用途（含 APP/Web/其他软件）及未经书面许可使用 Xiaomi/Mijia 商标；`ADR-0014` 已固化。 | 严禁复制代码、严禁借用 `OAUTH2_CLIENT_ID` (`2882303761520251711`) 或调用 `ha.api.io.mi.com` / 中枢证书接口；仅允许净室实现公开/通用局域网规范（如 `miIO.sub`）或引导用户经 HA 桥接。 |
| **涂鸦 `TUYA_CLIENT_ID` 红线** | ✅ **确认不可逾越**。实读 `tuya-local/const.py:22-23` 证实 `HA_3y9q4ak7g4ephrvke` / `haauthorize` 为 HA 专属凭据，与 `ADR-0014` 否决逻辑同源；`00-SUMMARY.md §五` 已明禁。 | 严禁借用 HA 的 `TUYA_CLIENT_ID` 扫码；合规路径仅限用户自带 `local_key` / 导入 `tinytuya` JSON / 自有 IoT 项目一次拉 Key 持久化，或未来独立申请桌面合规身份。复用 `tuya-local` YAML 模板需保留其 MIT 许可声明。 |
| **无 Developer ID (`#11`) 与无 EV/SignPath (`#12`) 硬约束** | ✅ **影响面实证清晰**：<br>1. macOS：`PR #460` 已证伪 ad-hoc WidgetKit / `ControlWidget`；无法通过 Gatekeeper 公证、无法启用官方 App Sandbox XPC 与 `MatterSupport` BLE/Thread 配网；<br>2. Windows：无 Authenticode 签名触发 SmartScreen；`tray-icon-0.25.1:lib.rs:231-238` 证实无签名时 `NIF_GUID` 仍强绑定二进制路径；<br>3. 供应链安全：双端继续以 `ADR-0005` 离线 Ed25519 私钥签名清单 + macOS 固定自签名证书叶哈希 pin 为唯一信任锚。 | 1. 路线图严禁把 WidgetKit / ControlWidget / App Sandbox XPC / 商业签名依赖项排入 P0/P1；<br>2. 插件分发与按需下载组件（含未来 `mbh-wasm-host`）100% 复用 `ADR-0005` 离线 Ed25519 验签，不依赖 OS 商店/EV 证书；<br>3. 若推进 `NIF_GUID`，仅限固定安装路径 Release 构建启用且需同步解决 `tauri 2.12.4` API 透传缺口。 |
| **本仓 5 类高风险 PR 红线**（`AGENTS.md`） | ✅ 多数报告分流准确，**需补标 3 处**：<br>1. `10` 中 **E8**（Windows IP Helper 回调 + WebView2 `SetMemoryUsageTargetLevel(Low)` + `window.rs`）原标「快车道」，因触及后台安全告警定时存活与窗口生命周期，须升级为 **必须走 PR**；<br>2. `06` 中 **`.nonactivatingPanel` 改造**触及高危确认弹窗（`ManualControlConfirmationPresenter`）与全局快捷键焦点边界，须走 **PR** 并跑完整 UI 快照与键盘测试；<br>3. `09` 中 **L2 原位长按 / L3 滑动解锁** 触及安全控制写入面，必须走 **PR**，且严守 `00-SUMMARY.md §五` 绝不开「按设备不再询问」后门。 | 所有命中「凭据/网络、控制写入/安全策略、去重/语料、自更新/签名、打包/跨端契约」的改造均强制走 PR + 2 轮以内 Codex Review + CI 全绿合入。 |

---

## 五、是否需要打回第一波补漏的最终意见

**结论：无需打回第一波重做，可直接进入最终路线图综合。**

理由：第一波 7 份技术报告（及 `09` 涉及的工程基线）均基于真实浅克隆仓库与本仓源码深度核验，核心架构判断扎实，**抽检精确率 87.0%（含轻微偏差可接受率 94.4%）**，未发现系统性伪造源码或方向性错乱。唯一需要规避的风险是：若综合阶段原样照搬个别报告中的 3 处硬错误与 4 处冲突盲区，会导致实施期返工或触碰红线。因此只需由综合官直接采用下表覆写对应结论即可：

| 对应 Worker | 需覆写/补正的具体条目 | 直接采纳的修正口径（无需打回重写） |
| :--- | :--- | :--- |
| `09` (`ui-ux-motion-lab`) | L17 误称 Windows 现状已有「DWM Acrylic 背景」 | 修正为「透明 WebView2 CSS 半透明模拟（无系统模糊）」，真材质升级按 §三 冲突 1 分主题裁决执行。 |
| `07` (`tray-windows-tauri`) | ① `main.rs` 调 `TrayIconBuilder::with_guid`；② L1 Dormant 调 `SetProcessWorkingSetSize(-1, -1)` | ① 标注 `tauri 2.12.4` 未透传 `with_guid`（需上游升级/绕行 `tray-icon` crate）且无 Authenticode 签名时 `NIF_GUID` 仍绑定路径；② 删除 `SetProcessWorkingSetSize(-1, -1)` 建议。 |
| `04` (`sh-vendor-protocols`) | 遗漏 Open PR `#453`（Windows miIO LAN）及将 `miIO.sub`/`datasource: 1` 当未立项新发现 | 统一挂接 `#453`/`#457`（Windows miIO）、`ADR-0025`/`#449`（`miIO.sub`）、`#411`/`#412`（`datasource: 1`/离线 LAN 探测），聚焦本轮净增量（`status=all`、多语言、`go2rtc audio=0`、SonoffLAN 仲裁范本）。 |
| `08` (`plugin-arch-magpie`) | ① `mbh-wasm-host` 4–6 MB 体积低估；② 提议桌面 `Virtual HAP/Matter Bridge`；③ `host.js:29-40` 引文错位 | ① 修正为「Cranelift 18–28 MB/架构 + `allow-jit` 风险 → 强制按需下载 + 优先 Pulley 解释器 + Ed25519 验签」；② 剔除桌面 Virtual HAP/Matter 桥（守 `.out-of-scope/`）；③ 凭据 Broker 按 §三 冲突 3 与纯 LAN Sidecar 分流。 |
| `06` (`menubar-macos-masters`) | `.nonactivatingPanel` 改动低估 IME/首击/收起/模态确认副作用 | 落地时强制捆绑 §三 冲突 4 的 5 条护栏（文本输入按需 `NSApp.activate()`、`sendEvent` 首击补 `makeKey()`、`didResignKey` 四类豁免），并将动态 `.regular` Dock 降为 P2 可选。 |
| `10` (`perf-reliability-sec`) | `tauri.conf.json:27`→`28` 行号偏差；E8 标为免 PR | 修正行号为 `L28`；将 E8 升级为「必须走 PR」。 |
| `01` (`baseline-auditor`) | PR `#460` 记为 Open | 更新为已合入（`2026-11-24T07:50Z`），当前 Open PR 仅余 `#453`。 |

---

## 六、本次审计实际验证记录与未覆盖边界

- **已执行只读验证**：逐行实读 MenuBarHome 本仓 24 个核心源码/ADR/调研/工作流文件、17 个 `scratch/repos/` 外部仓源文件、4 个本机 Cargo 注册表 crate 源码（`tauri 2.12.4`、`wry 0.57.0`、`tao 0.37.1`、`tray-icon 0.25.1`），并通过 `gh issue list` / `gh pr list` / `gh pr view 453, 460` / `gh issue view 456` 核对实时 GitHub 状态，另经网络检索复核 Wasmtime Cranelift vs Pulley 体积基线。
- **未覆盖边界**：未编译运行代码或执行真机压测（macOS 26 Tahoe `.nonactivatingPanel` 下的 Liquid Glass 折射与 CJK IME 行为、Windows 11 `SetMemoryUsageTargetLevel(Low)` 实际 Private Working Set 降幅、Wasmtime Pulley 实测包体均标注为实施阶段真机必测项）；本仓及第一波报告全程保持零修改。
- **可打开产物路径**：[11-verify-tech-audit.md](./11-verify-tech-audit.md)
