# MenuBarHome 本仓基线与 Magpie 线索深度审计报告

- **审计对象**：`<repo-root>`（对应 GitHub `jryang2026-code/MenuBarHome` `main` 分支，同步至 `2026-11-24T07:25Z`，47★ / 8 Fork；最新正式 Release 为 `v1.4.0` `2026-11-22`，但 `main` 在随后 48 小时内已合入 PR #387–#459 共 40+ 项重大演进）
- **核验口径**：严格区分 **[源码证实]**（已核对具体文件、符号与行号）与 **[分析推断]**（基于源码指标与架构耦合得出的工程判断）。本审计全程只读，未改动本仓文件或任何 GitHub Issue/PR。

---

## 一、项目定位与代码库全景基线

### 1.1 代码规模与技术栈（[源码证实]）

MenuBarHome（原名 `MenuBarMijia`，1.2.0 起更名迁回 GitHub，见 `README.md:51-52`、`docs/adr/0018-back-to-github.md`）是一套双端原生实现的桌面智能家居控制中心，**不引入 Electron、不引入第三方 Swift 运行时依赖、Windows 前端不引入 React/Vue 框架**：

| 模块目录 | 技术栈与依赖特征 | 文件数 | 代码行数 | 角色 |
| :--- | :--- | ---: | ---: | :--- |
| `Sources/MijiaCore/` | Pure Swift 6 (`swift-tools-version: 6.0`)，**零第三方运行时依赖**，仅依赖 Foundation/CryptoKit/Network/Security，支持 Linux 无界面编译单测（`Package.swift:18-34`、`ADR-0003`） | 146 | 70,481 | macOS 业务核心、协议层、双源合成、状态主存、策略与安全边界 |
| `Sources/MenuBarMijiaApp/` | SwiftUI + AppKit (`NSStatusItem` + `NSPanel`)，macOS 14+（macOS 26+ 启用 Liquid Glass） | 80 | 44,901 | 菜单栏宿主、Classic / Liquid Glass 双主题面板、设置窗口、摄像机实况窗、App Intents |
| `windows/src/core/` | TypeScript 5.7（唯一生产依赖 `pinyin-pro@3.27.0`，见 `windows/package.json:23-25`） | 75 | 43,439 | Windows 端业务核心、HA/米家协议、双源融合、凭据边界、能力裁剪与助手 |
| `windows/src/ui/` | Vanilla TypeScript + 自研 DOM 协调器 (`reconciler.ts`) + 单体 CSS (`styles.css` 6,412 行) | 51 | 51,257 | Windows 11 托盘双主题面板（Classic / Fluent 2）、独立 5 页签设置窗口、动效与键盘路由 |
| `windows/src-tauri/src/` | Rust 2021 + Tauri v2 (`reqwest` / `tungstenite` / `ring` / `keyring` / `windows` WinRT / `windows-sys`)，见 `windows/src-tauri/Cargo.toml:15-43` | 15 | 12,732 | 原生托盘、窗口工作区定位、凭据管理器、HA WebSocket/HTTP、go2rtc 摄像机中继、WinRT Toast、单实例 IPC 与更新验签 |
| `raycast/src/` | TypeScript / React (Raycast Extension API) | 15 | 1,358 | 3 个视图命令 + 3 个 `no-view` 快捷键命令 + 3 个 Raycast AI Tools |
| `Shared/` | 纯 JSON 跨端数据契约（`capability-manifest.json`、`deviceLabels.json`、`deviceClaims.json`、`adapterManifest.schema.json`） | 4 | 985 | 双端单一事实源契约与门禁校验输入 |
| `Tests/` + `windows/tests/` | Swift Testing / XCTest + Node Test Runner (`happy-dom`) + 73 份共享黄金语料 `Tests/Fixtures/*.json` | 397 | 190,842 | 双端一致性防漂移回归网（含 20 张 `macos-26-intel` 托管视觉快照与确定性 fuzz） |

> **关键发现（[源码证实]）**：生产代码总计约 **22.4 万行**（Swift 11.5 万行 + TS 9.5 万行 + Rust 1.3 万行），测试与语料约 **19.1 万行**。仓库文档存在明显滞后：`README.md:237` 与 `GLOSSARY.md:22` 仍写「Windows 单账号/互斥单选」，但源码实证 Windows 自 v1.3.0 起已全面支持米家多账号与 HA 双源融合（`windows/src/core/miAccountsStore.ts`、`windows/src/core/dualSourceProvider.ts`）。全队在提建议时**必须以 `HEAD` 源码与已合入 PR 为准，不可轻信 `README.md` 旧表述**。

---

## 二、macOS Swift 源码架构深度解剖（[源码证实]）

### 2.1 设备模型与能力分层

- **15 类规范设备模型**：`Sources/MijiaCore/Models.swift:1201-1216` 定义 `DeviceKind` 封闭枚举：`.light`、`.climate`、`.fan`、`.plug`、`.fridge`、`.vacuum`、`.speaker`、`.tv`、`.camera`、`.sensor`、`.cover`、`.appliance`、`.generic`、`.humidifier`、`.valve`；`SmartDevice`（`Models.swift:1296`）作为面板最小逻辑单元。
- **24 项封闭指令集**：`DeviceCommand`（`Models.swift:1678-1711`）覆盖灯光/空调/风扇/开关/选择/数值/加湿/扫地机/媒体/按钮/播报/场景，外加两条底层 MIoT 通用写指令 `.setMiotProperty` 与 `.callMiotAction`。
- **多源合成与通用兜底**：
  - HA 侧由 `HAHomeSnapshot.swift` + `DeviceSynthesizer.swift`（2,135 行）+ `HAFacets.swift` 将 HA 区域/设备/实体注册表折叠为 `SmartDevice` 与「更多设置」辅助控件（`FacetControl`）。
  - 米家侧由 `MiotSpec.swift` + `MiotSynthesizer.swift`（1,869 行）+ `MiotFacets.swift` + `MiotFallbackSpec.swift` + `DeviceClaims.swift` 驱动；支持多键墙壁开关分键拆分（`splitParentDid`）、双轨窗帘拆轨（`MiotSynthesizer.plans:432` / `trackID:446`）、灯组折叠（`lightGroupOwners`）、以及共享 `Shared/deviceClaims.json`（认领阶梯）、`Shared/deviceLabels.json`（标题/状态/图标语义）、`Resources/deviceProfiles.json`（设备家族覆盖如鱼缸/喂食器/浴霸/油烟机/洗烘机）、`Resources/fallbackSpecs.json`（离线/缺失规格只读兜底）。
  - **唯一尚存的双端设备合成差异**：`Shared/deviceClaims.json:19-20` 中 `television` / `stb` 标记 `"renderers": ["windows"]`，对应 `Tests/Fixtures/miot_coverage_golden.json` 里仅剩的 1 条 `windowsDivergences`（`123888.tv.xhzn11`），已有 Open Issue `#442` 跟踪补齐 macOS `buildTV`。

### 2.2 Provider 协议、双源融合与多源演进状态

- **封闭后端与描述表（ADR-0020）**：`HomeBackend` 保持三值封闭枚举（`HomeProvider.swift:4-8`: `.homeAssistant` / `.xiaomiCloud` / `.demo`），由 `HomeBackendDescriptor.swift:43-87` 穷尽 `switch` 收敛标题、配置状态、作用域 ID 与工厂；`HomeBackendDescriptor.activeBackends`（`:29-40`）已于 PR #414 重构为接受 `Set<HomeBackend>`。
- **内置 `HomeAdapter` SPI（PR #439）**：`Sources/MijiaCore/HomeAdapter.swift:2-10` 新增进程内窄契约 `HomeAdapter`（`id`、`capabilities`、`snapshot()`、`events()`、`execute(command:) -> AdapterWriteResult`），并由 `HAHomeAdapter`（`:40-101`）首家适配 `HAWebSocketProvider`；同时 `HomeProvider.swift:82-129` 统一了 `AdapterErrorCode`（6 枚举值）与 `HomeProviderCapability`（5 能力位）。但**米家云端 `MiCloudProvider` / `MiAccountsProvider` 尚未接入 `HomeAdapter`**（Open Issue `#438`）。
- **核心传输实现**：
  - `HAWebSocketProvider`（`HomeProvider.swift:224-1357`）：持久 WebSocket 长连接 + 25s 心跳 + 事件合并防抖 + 局域网 mDNS 发现（`HADiscovery.swift`）+ 明文 HTTP 非局域网端点逐一同意（`HAPlaintextConsent.swift`）+ 局域网权限拒绝探测（`:562-568`）。
  - `MiAccountsProvider`（`MiAccountsProvider.swift:5`，1,048 行）聚合多个 `MiCloudProvider`（`MiCloudProvider.swift:6`，2,453 行）：支持 CN/SG/DE/US/RU 多账号多家庭（含共享家庭）、扫码登录（不存 `passToken`，`ADR-0004`）、RC4 签名请求、到期前 3 天预警与面板内重扫、离线拓扑持久化（`MiTopologyCache.swift`）及云端手动场景（`MiCloudScenes.swift`，PR #450）。
  - **局域网优先混合读写（ADR-0021）**：`LocalMiIOClient.swift:36` (`NWConnectionMiIOUDPTransport`) 实现 UDP `54321` AES-128-CBC 加解密、120s 握手 TTL、per-`did` 串行排队、广播自愈发现；`MiCloudProvider.fetchPropsHybrid`（`:1130`）与 `execute`（`:1986`）优先走 LAN（经 `lanEndpoint` `:1556` 校验 RFC1918 + 非共享 + 合法 32-hex token + 冷却状态），失败自动无缝回退云端，且非幂等 `action` 丢包抛出 `ambiguousActionOutcome` 不自动重放。
- **双源整卡去重与合并（ADR-0008）**：`DualSourceHomeProvider.swift`（2,184 行，内置 `DispatchFallbackRecheckTimer` `:20` 防 Swift 6 `x86_64` 并发释放崩溃、回退磁滞窗口、`DisabledBackendsGate` `:148`、`CanonicalSourceIDBox` `:226`）调用纯函数 `DeviceDeduplicator.merge`（`DeviceDeduplicator.swift:47-250+`），按强硬件键（`did`/`MAC`）→ 唯一同房间同型号 → 唯一同房间同名配对，按「在线 → 可控分 → 同分 HA 优先（摄像机优先能出画面者）」选出胜出源并保留 canonical ID 迁移本地偏好。
- **历史旁路（LG webOS 电视）**：`LGWebOSClient.swift` 仍未接入 `HomeProvider` / `HomeAdapter`，由 `HomeStore+Backend.swift:46-187` 直接持有并在快照后经 `applyLGDeviceUpdate` 注入面板（ADR-0020 第 3 节明确记载为典型历史特例）。

### 2.3 状态同步、写入控制与安全防误触边界

- **主存与分层轮询**：`HomeStore`（`HomeStore.swift:121-123`，`@Observable @MainActor`）跨越 **21 个文件共 17,897 行**。轮询节奏由 `PollingPolicy.swift:58-100` 统一管理（PR #405 扩充空闲衰减）：面板开 6s → 面板关 60s → 30min 无交互 120s → 2h 无交互 300s → 低电量 180s（开启安全告警或菜单栏实时读数时锁定 60s 防漏报）→ 休眠/锁屏完全暂停。
- **细粒度乐观写与失败回滚**：`HomeStore+ControlWrite.swift:18-67` (`OptimisticWrite`) 与 `OptimisticField.swift` 实现了按字段（`optimisticFieldLocks`）和按辅助控件（`optimisticFacetLocks`）的独立锁租约与修订号；连续滑块拖动采用防抖会话（`manualWriteSessions`）+ 发送前防漂移重验（`CoverDragPlan:109` / `FacetDragApproval`），失败仅在无更新写抢占时回滚；主开关另带 `ReadBackTickets`（`HomeStore.swift:228`）等待 800ms 回读确认。
- **内置能力开关与统一写入门（ADR-0023）**：`Shared/capability-manifest.json` 声明 2 个连接、8 个功能、14 个设备类型；`CapabilityReferenceVerdict.swift` 在停用前输出 `allowed / requiresPauseConfirmation / blocked` 判决，暂停受影响的定时/自动化/快捷动作；`HomeStore+Capabilities.swift` 持有宿主写入门，先拒绝关闭类型/已停用连接作用域的目标，同时对已开启安全提醒的隐藏传感器/门锁/阀门维持只读安全保留集评估。
- **防误触三道防线**：
  1. **高风险二次确认**：`ManualControlPolicy.swift:80-199` 与 `ModelActionPolicy.swift` 共享 `Tests/Fixtures/confirmation_golden.json` 风险表（开电暖器/插座/摄像机/热水器/扫地机/水气阀/车库门须确认，关闭保持直达）；照明用途墙壁开关可通过 `wallSwitchMayControlLight`（`:169`）+ `SwitchLightMarks`（`:48`）单卡标记「这是灯」。
  2. **锁屏拦截**：`HomeStore+Security.swift:249-261` (`rejectControlWhileLocked`) 默认在锁屏期间拦截手动控制、URL Scheme、App Intents、助手、通知动作与补执行定时，仅允许已武装定时与 Mac 事件自动化运行。
  3. **全关保护与撤销**：`allOffTargets` 默认排除插座、扫地机、摄像机、阀门、热水器、门窗与通用卡；0.6s 长按触发，提供 10–15s 撤销横幅（悬停暂停倒计时）与 10 分钟助手回滚。
- **凭据隔离**：`CredentialVault.swift:53-105` 将所有凭据（米家多账号会话、HA 令牌、按服务商分槽的 AI API Key、LG 配对密钥）合并存入**单个 Keychain 条目** `credential_vault_v1`（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），避免自签名构建每次升级触发多条 Keychain ACL 连环弹窗；读取失败严格 fail-closed 绝不覆盖已有条目，唤醒后节流复读恢复（PR #387）。

### 2.4 UI、面板宿主、动效、快捷指令与定时

- **自持 `NSStatusItem + NSPanel`（放弃 `MenuBarExtra`）**：`MenuBarPanelController.swift:33-250` 彻底摆脱 `MenuBarExtra` 私有 API，公开 API 实现左键切换、0.5s 长按语音（hold-to-talk）、右键菜单（实况/演示切换、连接状态）、状态化菜单栏图标 + 宽度收缩防抖 + 钉选实时读数（PR #417）、刘海屏与自动隐藏菜单栏定位修正（PR #403），且面板隐藏后卸载 SwiftUI 视图树以将待机 CPU 压至 ~1.2%（PR #354）。
- **双主题与动效收敛**：默认 Classic（376pt 居中悬挂）+ macOS 26+ Liquid Glass（380pt 右侧滑入 + `PanelAdaptiveHeightProbe` `ThemeAndMotion.swift:54-111` 避免 `ViewGraph` 布局循环）；PR #427 将散落弹簧收敛至 `AppleMotion`（`ThemeAndMotion.swift:154`）并统一遵循 `effectiveReduceMotion`（`ThemeAndMotion.swift:30`）。面板首屏新增「我家现在」摘要行与按卡片尺寸记账的槽位预算（PR #436）及静默的「未能显示的设备」计数行（PR #423）。
- **语音、本地意图与 AI 助手**：支持按住说话 / 免提语音（Apple Speech 端侧识别 + 设备/房间/场景热词提示 `SpeechRecognitionHints.swift`）；日常口令与只读状态查询（PR #426 `StateQuery.swift`）纯本地解析（`LocalIntentParser.swift`，0 token）；复杂口令在 macOS 26+ 优先走本机 Apple Intelligence Foundation Models 引导生成（`FoundationModelIntentResolver.swift`），或外接用户自选云端/Ollama 模型（`ModelIntentResolver.swift`）。
- **自动化、定时与系统生态集成**：
  - `AutomationEngine.swift` + `MacContextObserver.swift` 支持锁屏/解锁/睡眠/唤醒/合盖/外接显示器/摄像头与麦克风/电源电量/Wi-Fi SSID/深夜用机/专注模式/日历会议前 + 每日生效时段条件 + 运行历史与重启模式（PR #434）。**尚缺**：定时触发（`#430`）、「持续 N 分钟」条件（`#431`）、Windows 侧事件源守卫移植（`#432`）。
  - `AssistantSchedule.swift` (`ScheduledCommand`) 持久化延时任务并绑定 `sourceScopes`（ADR-0019）；合盖/睡眠超时 >60s 转入 `missedScheduledCommands` 等待人工确认，绝不后台静默补发。
  - `AppIntents.swift` + `SpotlightIndexer.swift` + `FocusFilter.swift`（PR #441）：支持 8 个参数化快捷指令动作、可选 Spotlight 索引（仅名称不含凭据）、专注模式过滤（生命安全告警永不压制），并配套 2 级统一 `AlertSeverity`（`alert`/`warning`，PR #418）与 `NotificationDeliveryPolicy`（PR #398）。
  - 伴生生态（ADR-0013）：写 `0600` 权限只读快照 `raycast-snapshot.json` + 常量时间校验 `bridgeToken`，统一服务 `raycast/` 扩展、`scripts/mijia` CLI（含 `--format alfred` / `swiftbar`，PR #435）与 `scripts/mijia-mcp` stdio MCP Server（带 `destructiveHint: true` 与 `--read-only`，PR #401）。

### 2.5 摄像机实况与自更新链路

- **摄像机桥接与进程监督**：`XiaomiCameraBridge.swift` 拉起本机绑定随机回环端口 + Basic 鉴权的 `go2rtc` 子进程；PR #425 落地通用子进程监督器 `ProcessSupervisor.swift:4-187`（指数退避 `1s..60s` + 抖动 + `120s` 内 5 次失败熔断 + `300s` 稳定期复位）与防 PID 复用孤儿清理 `SupervisedProcess.swift:8-120`（校验 `pid + executablePath + startTime + euid`，`O_NOFOLLOW` `0600` PID 文件）；支持 fMP4 原生解码（`FragmentedMP4Demuxer.swift`）、MJPEG 兜底、双镜头切换、拖拽 PTZ 云台、画中画、门铃带缩略图通知（PR #408）、以及本地事件库 `CameraEvent.swift:4-120`（7 天 / 500 条上限）与 2×2 静帧墙（PR #448）。
- **应用内自更新（ADR-0005）**：`UpdateSignature.swift:6-26` 使用离线 Ed25519 公钥（支持主公钥 + 过渡公钥轮换，见 `docs/security/update-signing-key-rotation.md`）验签绑定版本号的发布清单；PR #454 落地 `BackgroundUpdateScheduler`（`UpdateScheduler.swift:68-150`，基于 `NSBackgroundActivityScheduler` + 30 min 启动抖动 + 分阶段放量 `UpdateRollout.swift`）；PR #459 补齐大陆镜像（Gitee/GitCode）同步脚本。

---

## 三、Windows Tauri + TypeScript 源码架构深度解剖（[源码证实]）

### 3.1 Rust 宿主层（`windows/src-tauri/src/`，15 文件 12,732 行）

`windows/src-tauri/src/main.rs:247-297` 注册了 **50 个 Tauri 原生命令**，形成清晰的宿主能力边界：

- **凭据管理（`credentials.rs:1-200`）**：通过 `keyring` 封装 Windows Credential Manager（服务名 `com.jryang.menubarmijia`），`allowed_credential_name`（`:7-32`）强制白名单（`mi_session`、`ha_token`、`assistant_api_key`、`assistant_api_key_*`、`mi_session_*`），拒绝退化为通用 KV 存储；`secure_store_list_mi_account_slots`（`:74-119`）经 `spawn_blocking` 调用 Win32 `CredEnumerateW` 只枚举槽名不返明文，配合 TS 侧 `WIN32_CRED_MAX_BLOB_BYTES = 2560` 字节守卫（`secureStore.ts:23-71`）。
- **托盘窗口与多屏定位（`window.rs` 1,218 行 + `placement.rs` 772 行）**：
  - `PanelVisibilityState`（`window.rs:52-168`）精细仲裁托盘按压与失焦同一次点击防闪烁、隐藏动画代次与 Esc 归还托盘焦点（PR #400）。
  - `placement.rs` 纯整数物理像素计算：`taskbar_edge`（`:51-64`）读取 `Monitor::work_area`（`rcWork`）支持上下左右任意任务栏边缘；PR #400 新增 `autohide_taskbar_on_monitor`（`:103-148`）与 `inset_work_area_for_autohide_taskbar`（`:153-197`），通过 `SHAppBarMessage(ABM_GETTASKBARPOS)` + `Shell_SecondaryTrayWnd` 补偿自动隐藏任务栏，并支持拖拽吸附工作区四角持久化。
  - 双主题宽度对齐：`PanelTheme::Classic`（默认 440px）与 `PanelTheme::Fluent`（380px 双悬浮岛，`window.rs:177-196`），独立设置窗口启用 `DWMWA_USE_IMMERSIVE_DARK_MODE` 深色标题栏（PR #400）。
- **网络、HA 与原生存根（`home_assistant.rs` 1,132 行 + `network.rs`）**：
  - `HaConnections`（`home_assistant.rs:36-109`）用单调 `generation` + `CancellationToken` + `RwLock` 7s 排空预算保证切换/停用 HA 时在途请求绝不串源（PR #393）；**但 Windows HA 仍采用按需短连接快照 + 按操作调用服务**，而非 macOS 的常驻 WebSocket 事件推送（见 `platform-matrix.md:13` 与 `homeProvider.ts:58-82`，PR #439 仅在 TS 包装层新增了快照事件回调）。
  - 外部来源采用原生系统弹窗审批并持久化至 `authorized-http-origins.json`（`main.rs:303-307`），拦截未授权明文 HTTP 凭据外发。
- **系统事件与原生通知（`system_events.rs` 371 行 + `wifi.rs` + `desktop_shell.rs` 654 行）**：
  - `system_events.rs` 通过 `GetSystemPowerStatus`、`QueryDisplayConfig`（区分内屏与外接显示器）、`PowerRegisterSuspendResumeNotification` 与 `PowerSettingRegisterNotification(GUID_CONSOLE_DISPLAY_STATE)` 捕获电源/外显/休眠/熄屏事件，经 `menumijia:*` DOM 事件推入 WebView；`is_workstation_locked` 探测桌面锁屏态。
  - **PR #433 已升级原生 WinRT Toast**：`desktop_shell.rs:409-488` (`show_winrt_toast` / `send_desktop_notification`) 在已注册 AUMID 的发布构建中改用进程内 WinRT `ToastNotificationManager`（生命安全告警设 `ToastNotificationPriority::High` + `scenario="alarm"`），点击通知通过 `menumijia://notification/<kind>/<deviceId>` 唤醒并聚焦目标设备；仅在未注册或开发态降级回 PowerShell 兜底。
- **摄像机中继与进程清理（`camera.rs` 2,193 行 + `camera_stream.rs` 395 行 + `job_object.rs`）**：
  - 内置 `go2rtc` + 最小 LGPL FFmpeg（含 Win32 Job Object 绑定退出回收），`camera.rs:2064` (`spawn_cs2_udp_relay`) 实现本地 CS2 UDP 中继与 DRW ACK，支持双镜头、电池机室内网关子设备（`subdid`）、画质切换、90° 旋转、MJPEG 灰帧过滤与自适应拉帧。**缺口**：尚未移植 macOS 的 `ProcessSupervisor` 崩溃退避/熔断状态机（Open Issue `#424`）及事件库/2×2 静帧墙（Open Issue `#447`）。
- **单实例转发与伴生集成（`companion.rs` 1,360 行）**：会话级 Win32 Mutex + 本地回环带 `x-menubarhome-secret` 头的 IPC 端点（并发上限 4、1.5s 连接截止）转发外部 `menumijia://` / `menubarhome://` 链接至运行中托盘实例；宿主持有 `CompanionRegistration` 代次锁，关闭集成瞬间原子删除 `%LOCALAPPDATA%\MenuBarMijia\raycast-snapshot.json` 并防旧代次回写。
- **应用内更新（`update.rs` 734 行 + `update_manifest.rs`）**：限制 URL 仅允许 `https://github.com/jryang2026-code/MenuBarHome/releases/download/`、64 KiB 清单上限、256 MiB 安装包上限 + 60s 分块空闲超时 + Ed25519（含过渡公钥）验签。

### 3.2 TypeScript 核心层与无框架前端 UI（94,696 行）

- **核心业务对齐度极高**：`windows/src/core/` 完整镜像了 Swift `MijiaCore` 的核心域模型与黄金语料测试——包括 15 类 `DeviceKind`（含米家电视 `TvSpec`，`models.ts:176`）、`DualSourceCoordinator`（`dualSourceProvider.ts`）、`MiAccountsStore`（多账号）、`PollingPolicy` 空闲衰减（`pollingPolicy.ts:86-182`，PR #421 接入调度）、`CapabilityManifest` & `CapabilityReferenceVerdict`、传感器 24h/7d 趋势、插座 31 天电费账本、自动化引擎（含定时触发与持续时长）、安全守护、家庭健康周报、米家云手动场景（PR #450）以及 `CredentialVault`（`secureStore.ts:295-641`，清理 `localStorage` 明文并按服务商分槽）。
- **Provider 接缝半成品状态**：`windows/src/core/homeProvider.ts:21-35` 定义了 `HomeCommandProvider`（仅 `execute`）与 `HomeProvider`（补充 `snapshot()` + `subscribe()`），但目前**只有 `HomeAssistantProvider` 实现了 `HomeProvider`，`MiCloudProvider` 与 `DemoHomeProvider` 仍只实现 `HomeCommandProvider`**（`:52`, `:107`），大量刷新与双源编排逻辑仍散落在 `ui/cloudRefresh.ts`（2,100 行）与 `core/miAccountControl.ts`（2,178 行）中（Open Issue `#438`）。
- **并发防竞态基石 `SourceEpoch`**：`windows/src/ui/sourceEpoch.ts:68-142` 设计了 `source ⊃ home ⊃ localWrite` 三级级联失效代际 + 独立 `SyncRunToken`，统一由 `ui/sourceSwitch.ts` 推进，有效消除了异步切换源/家庭时的过期快照覆盖问题。
- **无框架自研 DOM 协调器**：`windows/src/ui/reconciler.ts`（1,743 行）通过 `data-tile-id` / `data-upper-card-id` 等稳定身份键对整页 HTML 字符串进行局部 DOM morphing（`morphMatchingDom`）、退出幽灵元素（`GHOST_CLASS_RENAMES`）与 WAAPI/弹簧关键帧动画（`motionSpring.ts`），搭配 `app.ts`（2,649 行）、`connectionsAndDiagView.ts`（3,543 行）、`activityStackView.ts`（2,878 行）、`bindEvents.ts`（2,103 行）与 `styles.css`（6,412 行）。

---

## 四、双端（macOS vs Windows）功能对齐矩阵（截至 `HEAD 2026-11-24`）

> 符号说明：`✅` 完整支持 | `⚠️` 部分支持/有差异 | `🚧` Open PR 在途 | `❌` 未实现。标 `*` 项表示 **`main` 已领先 `v1.4.0` 发布版文档**。

| 功能域 | macOS (`HEAD`) | Windows (`HEAD`) | 真实差距与源码依据 |
| :--- | :---: | :---: | :--- |
| 米家扫码多账号 + 跨区合并 | ✅ | ✅* | **文档滞后**：Windows 自 v1.3.0 起已支持多账号与凭据分槽枚举（`secureStore.ts:260`、`credentials.rs:74`），但 `README.md:237` 仍误写「单账号」 |
| 米家 + HA 双源去重融合 | ✅ | ✅* | 双端均支持整卡去重、固定源与回退（`DeviceDeduplicator.swift` vs `dualSourceProvider.ts`），但 `GLOSSARY.md:22` 仍写 Windows 互斥单选 |
| Home Assistant 连接形态 | ✅ 持久 WS 推送 | ⚠️ 按需 WS 快照 | macOS `HAWebSocketProvider` 保持长连接实时推送 + mDNS 局域网发现；Windows `home_assistant.rs` 按需抓快照 + 无 mDNS 自动发现（Open `#294`） |
| 米家局域网直连（miIO UDP 54321） | ✅ 已上线 | 🚧 PR #453 在途 | macOS `LocalMiIOClient.swift`（ADR-0021）已支持局域网优先混合读写；Windows Part 1 Rust 协议层在 Open PR `#453`，Part 2 TS 混合路由尚未开 PR（另见 `#457` 写回确认） |
| LG webOS 局域网电视 | ✅（旁路） | ❌ | macOS `LGWebOSClient.swift` 直接挂在 `HomeStore+Backend.swift:46`；Windows 无对应客户端 |
| MIoT 电视 / 机顶盒卡片 | ❌（Open `#442`） | ✅ | 唯一一条反向差异：`Shared/deviceClaims.json:19-20` 仅对 Windows 启用 `television`/`stb`，`miot_coverage_golden.json` 剩 1 条 `windowsDivergences` |
| 米家云端手动场景 | ✅* | ✅* | PR #450 已双端合入（`MiCloudScenes.swift`、`windows/src/core/miCloud/scenes.ts`） |
| 内置能力启停 / 设备类型裁剪 / 写入门 | ✅ | ✅ | 共读 `Shared/capability-manifest.json` 与 `capability_selection_golden.json`（ADR-0023） |
| 语音交互 | ✅ 按住说 + 免提（端侧） | ⚠️ 仅免提（WebView） | Windows 缺少系统级全局长按语音与端侧热词提示 |
| 本地意图 + 只读查询 + AI 助手 | ✅（含 macOS 26 端侧 AI） | ✅（云端/Ollama） | 双端均已合入只读状态查询（PR #426）；macOS 26+ 独享 Apple Intelligence Foundation Models 引导生成 |
| 小爱音箱播报 / 指令 | ✅ | ⚠️ 仅指令/媒体，无独立 TTS 差异 | `platform-matrix.md:34` 注明部分 TTS 能力 macOS 独有，Windows 1.3.0 已补齐小爱音箱播报/指令双模式（`speakerActions.ts`） |
| 自动化触发源与条件 | ⚠️ 缺定时/持续 N 分钟 | ⚠️ 缺音视频/专注/日历/合盖 | **双向差异**：macOS 独有摄像头/麦克风、专注模式、日历、合盖；Windows 反而领先拥有定时触发、持续 N 分钟条件与触发器事件源守卫（macOS Open `#430`/`#431`/`#432`） |
| 系统生态（Shortcuts / Spotlight / Focus） | ✅* | ❌ | macOS 已支持 8 个参数化 App Intents + Spotlight + FocusFilter（PR #441）；Windows 无 PowerToys Command Palette / WinRT JumpList |
| 系统原生通知与点击跳转 | ✅*（分级 + 缩略图） | ✅*（WinRT Toast） | macOS PR #398/#408 已做严重度分级与门铃缩略图；Windows PR #433 已改进程内 WinRT Toast + 点击跳转设备（无门铃缩略图） |
| 菜单栏/托盘常驻读数与状态图标 | ✅* | ⚠️ 仅悬停 Tooltip | macOS PR #417 支持状态图标、防抖宽度与钉选实时读数；Windows 受托盘图标形态限制仅支持 Tooltip 摘要（`desktop_shell.rs:502`） |
| 摄像机实况 / PTZ / 事件与静帧墙 | ✅*（含监督+静帧墙） | ⚠️ 缺监督熔断与静帧墙 | 双端均内置 go2rtc + 双镜头 + 电池机网关 + 画质；macOS 领先 `ProcessSupervisor`（PR #425）与 `CameraEventStore`/2×2 静帧墙（PR #448），Windows 待补 `#424`/`#447` |
| 伴生集成（Raycast / CLI / MCP / URL） | ✅* | ✅* | 双端共用 `raycast-snapshot.json` + `menumijia://`/`menubarhome://`；PR #401/#435 补齐 MCP `--read-only`、`destructiveHint` 与 Alfred/SwiftBar 输出 |
| 商业代码签名 / 公证 | ❌（自签 + Gatekeeper） | ❌（未签 + SmartScreen） | 均为开源项目最大首装流失源（Open `#11`/`#12`），PR #460 实测无 Developer ID 无法上架 WidgetKit / ControlWidget |
| 桌面小组件 / 控制中心控件 | ❌（PR #460 证伪 ad-hoc） | ❌ | 依赖付费 Apple Developer ID 签名（`chronod` 驱逐 ad-hoc `.appex`） |

---

## 五、已暴露的技术债与架构瓶颈（Top 8）

### 瓶颈 1：双端完全平行实现带来的「结构性漂移税」（[源码证实] + [分析推断]）
- **源码证实**：`Sources/`（11.5 万行 Swift）与 `windows/src/`（9.5 万行 TS + 1.3 万行 Rust）各自独立实现全部协议、设备合成、去重、意图解析、自动化、安全策略与 UI。ADR-0020 统计显示 55% 以上修改 `windows/` 的提交同时改了 `Sources/`。尽管通过 73 份 `Tests/Fixtures/*.json` 与 4 份 `Shared/*.json` 遏制了漂移，但仍出现反向不对称（Windows 有定时/持续条件和 MIoT TV 卡，macOS 有局域网 miIO、HA 长连接、摄像机静帧墙和 `ProcessSupervisor`）。
- **架构影响**：每接入一个新家居平台或复杂设备协议，都要在 Swift 与 TS/Rust 中各写一套协议客户端、测试夹具与 UI 适配，边际成本翻倍。这也是推动 **ADR-0024 进程外统一适配器协议** 的最根本动因。

### 瓶颈 2：多源组合槽位仍硬编码为双源 + LG 电视历史旁路（[源码证实]）
- **源码证实**：
  - `Sources/MijiaCore/HomeStore+Backend.swift:1060-1126` 中 `makeLiveProvider` 与 `makeComposite(homeAssistant:xiaomiCloud:)` 仍写死两个具名槽位，直接构造双源专用类 `DualSourceHomeProvider`。
  - `DeviceDeduplicator.merge`（`DeviceDeduplicator.swift:47-56`）输入签名写死 `homeAssistant: SynthesizedHome?, xiaomiCloud: SynthesizedHome?`，无法直接容纳第 3..N 个源或 `ExternalAdapterSlot`。
  - `LGWebOSClient` 仍绕开 `HomeProvider` 直接挂在 `HomeStore+Backend.swift:46-187`，在 `HomeStore+ControlWrite.swift:127-136`、ADR-0019 和 ADR-0023 中处处需要特判豁免。
  - `HomeAdapter` SPI（`HomeAdapter.swift:2-10`）目前仅包装了 HA，米家尚未接入（`#438`）；Windows 侧 `MiCloudProvider` 仍未实现 `HomeProvider` 的 `snapshot()`/`subscribe()` 接口（`homeProvider.ts:107`）。

### 瓶颈 3：`HomeStore` 单体状态膨胀与多处超大型文件（[源码证实] + [分析推断]）
- **源码证实**：
  - macOS `HomeStore` 虽拆为 21 个文件，但全部挂载在单一 `@Observable @MainActor public final class HomeStore` 实例下，总计 **17,897 行**，集中持有设备、连接、能力开关、安全确认、乐观锁、助手、定时、自动化、门铃、诊断、更新、Spotlight、Raycast 导出等全部可变状态。
  - 超大单文件密集：`windows/src/ui/styles.css`（6,412 行）、`SettingsWindowView.swift`（3,740 行）、`connectionsAndDiagView.ts`（3,543 行）、`activityStackView.ts`（2,878 行）、`app.ts`（2,649 行）、`MiCloudProvider.swift`（2,453 行）、`CameraLivePanelController.swift`（2,343 行）、`camera.rs`（2,193 行）。
- **分析推断**：随着外部适配器、多平台认证 UI 与事件流加入，单一 `@Observable` 根对象的观测颗粒度与跨文件隐式状态耦合将迅速恶化，易诱发隐蔽重绘或竞态（如历史中频繁出现的宽限期/撤销/代次测试抖动，见 Open `#314`）。

### 瓶颈 4：Windows 前端无框架自研 DOM Reconciler 的维护上限（[源码证实] + [分析推断]）
- **源码证实**：Windows UI 依赖字符串拼接 HTML + `windows/src/ui/reconciler.ts`（1,743 行，手工维护 `STATE_ONLY_DATA_ATTRS`、`GHOST_CLASS_RENAMES` 与近百条 `extractControlIdentityKey` 规则）+ `bindEvents.ts`（2,103 行）手动事件委托 + 6,412 行全局样式表。
- **分析推断**：该设计换取了极低的包体积与启动内存，但每次新增交互组件（如后续适配器安装/权限确认页、摄像机 2×2 静帧墙、设备多维度诊断）都必须同步手写 HTML 模板、DOM 身份键、事件绑定与防闪烁规则，心智与回归成本持续攀升。

### 瓶颈 5：Windows 端 Home Assistant 缺少常驻 WebSocket 推送与局域网发现（[源码证实]）
- **源码证实**：`windows/src-tauri/src/home_assistant.rs` 的 `ha_snapshot` 每次按需建立短连接拉全量注册表与状态，未维持持久 WebSocket 事件订阅；`windows/src/core/homeProvider.ts:59-61` 明确未声明 `"pushEvents"` 能力位；同时缺少 mDNS 局域网发现（Open `#294`）。
- **分析推断**：在 Windows 上只连 HA 时，面板外状态变化与门铃/漏水实时告警响应延迟天然受限于轮询周期，无法像 macOS 一样亚秒级触发。

### 瓶颈 6：签名公证缺失是分发转化与原生系统扩展的硬天花板（[源码证实]）
- **源码证实**：
  - 无 Apple Developer ID 与 Windows Authenticode 签名（Open `#11`/`#12`），导致 macOS Gatekeeper 阻断、每次自签名升级触发 Keychain ACL 弹窗（`CredentialVault.swift:45-49`）、Windows SmartScreen 蓝屏拦截。
  - Open PR `#460` 实测证实：`chronod` 会立即驱逐 ad-hoc 签名的 `.appex`，且 ad-hoc 沙箱无法写 App Group（`NSCocoaErrorDomain Code=513`），**直接封死了无 Developer ID 情况下的 macOS WidgetKit 与 macOS 26 `ControlWidget` 路线**。

### 瓶颈 7：米家私有云协议的风控、无推送与 BLE/Mesh 局域网硬约束（[源码证实]）
- **源码证实**：
  - `MiCloudProvider` 依赖非官方 RC4 云 API，受小米风控与令牌过期约束（不存 `passToken`，`ADR-0004`）；离线/空设备问题曾多次引发用户流失（`#67`/`#76`，现已补 PR #402 诊断引导）。
  - `ADR-0016` 实测确认脱离 HA 无法局域网直连覆盖 BLE/Mesh 中枢网关子设备；`miIO.sub` 局域网推送存在跨固件兼容与状态机复杂度问题，`ADR-0025`（Proposed）与 `#449` 明确本阶段暂缓。
  - Windows `Credential Manager` 单条凭据存在 `WIN32_CRED_MAX_BLOB_BYTES = 2560` 字节硬上限（`secureStore.ts:23`），未来如承载复杂 OAuth/多租约结构需注意分槽规划。

### 瓶颈 8：外部适配器生态尚停留在「纯契约 v0」，且缺乏写路径与沙箱执行层（[源码证实]）
- **源码证实**：PR #452 合入的 `ADR-0024` 与 `Shared/adapterManifest.schema.json` 仅为**零运行时代码的只读 v0 契约**，且 Open Issue `#456` 记录了 4 项必须在阶段 4 前修补的校验/Schema 缺口（`inputType: "secret"` 强制 `writeOnly: true`、`snapshot` 允许空 `devices: []`、校验协商版本在宿主支持列表中、拆分校验 JSON-RPC `error` 与 `result` 响应）。此外 Windows 侧尚无对应 `ProcessSupervisor` 的 Rust 通用子进程监督熔断器（`#424` 仅提到待补 go2rtc 监督）。

---

## 六、现有规划、已交付进展与 Open Backlog 摸底（[源码证实]）

### 6.1 发版节奏与 `v1.4.0` 后的高密度演进（防全队重复建议！）

- **正式版本**：`v1.2.0`（2026-11-08，改名迁回 GitHub）→ `v1.3.0`（2026-11-16，Liquid Glass / Win11 Fluent 2 / Win 多账号双源 / 趋势电量自动化）→ `v1.4.0`（2026-11-22，按需能力裁剪与写入门 / 三卡首启 / Win 经典默认面板与独立 5 页签设置窗）。
- **`v1.4.0` 后 48 小时内 `main` 已合入的重要能力（PR #387–#459，来自 `2026-11-23-deep-dive` P0/P1 清单，切勿再当成「缺失功能」建议！）**：
  - **多源与插件底座**：`#414` `activeBackends` 集合化与错误码/能力声明、`#425` macOS 通用 `ProcessSupervisor` 监督 go2rtc、`#439` 内置 `HomeAdapter` SPI（HA 首家）+ Windows HA 快照事件、`#452` **ADR-0024 进程外适配器协议 v0 契约 + Schema + 黄金语料 + 静态校验脚本**。
  - **共享数据层收口**：`#404` `Shared/deviceLabels.json`、`#440` `Shared/deviceClaims.json` 与 `windowsDivergences` 棘轮（降至 1 条）。
  - **体验、安全与通知**：`#398` 通知分级与专注模式降噪、`#418` 统一 `alert/warning` 两级告警、`#402` 已登录 0 设备面板自检、`#408` 门铃缩略图通知、`#417` macOS 状态化菜单栏图标与钉选读数、`#423` 未能显示设备静默计数行、`#427` `AppleMotion` 动效收敛、`#433` **Windows 进程内 WinRT Toast + 点击跳转**、`#436` 首屏「我家现在」摘要行与尺寸槽位预算、`#400`/`#403` 双端面板定位与自动隐藏任务栏补偿。
  - **生态、摄像机、场景与运维**：`#401` MCP `destructiveHint` + `--read-only`、`#435` Alfred/SwiftBar CLI 输出 + Raycast no-view/AI tools、`#426` 本地只读状态查询、`#434` 自动化运行历史与重启模式、`#441` Spotlight + 参数化 AppIntents + FocusFilter、`#448` macOS 摄像机事件库与 2×2 静帧墙、`#450` 米家云端手动场景、`#405`/`#406`/`#421` 双端空闲轮询衰减与按下次时刻调度、`#454` `NSBackgroundActivityScheduler` + 抖动 + 分阶段放量、`#458` 应用内一键反馈、`#459` 大陆镜像同步。

### 6.2 当前全部 Open PRs（2 个）与 Open Issues（28 个）分类清单

**Open PRs**：
1. **`#453`**：`feat(windows): native Rust miIO LAN protocol, UDP transport, and shared golden corpus`（Windows 局域网 miIO 直连 Part 1，新增 `miio.rs`/`miio_crypto.rs`/`miio_protocol_golden.json`，Part 2 TS 路由待后续 PR）。
2. **`#460`**：`docs(research): WidgetKit & macOS 26 ControlWidget ad-hoc signing feasibility spike`（实证无 Developer ID 无法运行 WidgetKit / ControlWidget）。

**Open Issues（共 28 个，按主题归类）**：
- **插件化与多源底座（3 个）**：`#456` ADR-0024 validator/schema 4 项 follow-ups（阶段 4 前置）；`#438` 米家云端接入内置 `HomeAdapter` SPI + Windows `HomeProvider` 补齐；`#305` 米家多账号写入过滤只读共享账号。
- **双端对齐与 Windows 追平（6 个）**：`#442` macOS 补 MIoT `buildTV` 消灭最后 1 条 `windowsDivergences`；`#447` Windows 摄像机事件库与静帧墙；`#424` Windows go2rtc 进程退出监督与熔断；`#457` Windows 本地 miIO 要求显式写确认；`#294` Windows 宿主侧 HA 局域网发现；`#293` Windows 引导无障碍与水合细节。
- **米家底层与局域网演进（4 个）**：`#449` 评估并实现 `miIO.sub` 局域网推送（ADR-0025）；`#412` 米家离线设备只读 LAN 可达性探测；`#411` 真机实测 `datasource:1`（`ready-for-human`）；`#451` 米家场景缺 `uid` 回退登录用户 ID。
- **自动化与系统集成补齐（5 个）**：`#430` macOS 自动化定时触发；`#431` macOS 自动化「持续 N 分钟」条件；`#432` macOS 移植触发器事件源守卫；`#443` 专注模式跨模式切换沿用旧 profile；`#437` Raycast Store 上架合规。
- **摄像机体验（2 个）**：`#445` 摄像机仅听音频模式；`#446` go2rtc CS2 close 补丁与配置收敛。
- **商业分发签名（2 个，`ready-for-human`）**：`#11` macOS Apple Developer ID 签名与公证；`#12` Windows SignPath Foundation 免费开源签名。
- **质量与细节收口（6 个）**：`#455` `BackgroundUpdateScheduler` 周期对齐、`#429` `reduceMotionOverride` 覆盖非 View 调用、`#428` 助手温度查询遵循 C/F 偏好、`#420` 菜单栏宽度收缩滞回、`#397` 手动恢复暂停分组收尾、`#314` 间歇性测试稳定化。

### 6.3 明确的架构红线与 `.out-of-scope` 边界（[源码证实]）

1. **`.out-of-scope/always-on-bridge-and-mobile-app.md`**：不做配套手机端，不做阻止睡眠的 24/7 常驻桥，过期定时宁可错过询问也不静默补发。
2. **`.out-of-scope/direct-matter-bridge.md`**：不内置 MIoT-to-Matter 网桥（生命周期与云轮询模型与 Matter Fabric 24/7 订阅冲突）。
3. **ADR-0004 / 0014 / 0017 / 0020 / 0023 / 0024 红线**：不存 `passToken`；不搬用 `ha_xiaomi_home` 私有 OAuth2/MQTT 客户端凭据；不做原生 HomeKit 后端；**宿主进程内零第三方代码、永不支持适配器自带 HTML/JS/WebView 页面**；写入门、危险分级、高风险二次确认、锁屏拦截、告警严重度与长期凭据库永远归宿主持有。
4. **`docs/research/2026-11-23-deep-dive/00-SUMMARY.md` §五明确不做**：不接纯云轮询生态（小度/天猫精灵/华为 HiLink/萤石）；不借用涂鸦扫码 SDK 写死的 HA `client_id`；不为高风险确认加「按设备不再询问」后门；不换回 `MenuBarExtra`、不引 Sparkle。

---

## 七、「Magpie 插件化思路」线索终极查证（[源码证实]）

### 7.1 唯一确凿指向：`yetone/magpie`（非 `Blinue/Magpie` / 非 Antigravity）

经全仓全文检索、ADR 追溯与公开社区核验，用户上下文中的 **「Magpie 插件化思路」唯一且明确指向 `yetone/magpie`（官网 `usemagpie.ai`，社区插件仓 `magpie-community/plugins`）**——一个由 `avante.nvim` 作者 yetone 开发的本地 AI 模型网关与菜单栏调度应用（macOS `LSUIElement` / 跨平台）。**它既不是 Windows 超分工具 `Blinue/Magpie`，也不是 Antigravity 插件体系、Apache Magpie 或 Open Raven Magpie。**

### 7.2 本仓内已有的 Magpie 研究与架构转化证据（[源码证实]）

本仓并非首次接触 Magpie，而是**已经在 2026-11-23～24 完成了三层源码剖析与首版协议转化**：

1. **`docs/research/2026-11-23-deep-dive/12-magpie-plugin-model.md`（897 行）**：已对本机 Magpie `0.1.4696`、`yetone/magpie`（`d510779`）与 `magpie-community/plugins`（`18fa146`，127 个市场插件）做了完整源码拆解，提炼出 Magpie 的核心结构：
   - **两套互不混用的插件体系**：Go 进程内编译期模块系统 `pluginrt`（`ID`/`API "^1"`/`Requires`/`Provides`/`Essential` + `Reconcile` 依赖顺序与失败回滚，与 MenuBarHome ADR-0023 内置能力模型同构）vs 第三方 OpenCode 插件（npm 包格式 + `package.json` `magpie.*` 增量声明）。
   - **三种执行面**：Provider/Hook/Tool 进独立 **Bun 子进程**（stdin/stdout NDJSON，24 个 RPC handler + `AsyncLocalStorage` 账户级隔离 + 512MB RSS 回收 + 20s 加载/调用时间闸，但**不是安全沙箱**，官方明言 `"Bun plugins have host privileges; install trusted code."`）；同步 Gateway Middleware 用 Go 内嵌 **moejs** 进程内执行；UI Page 关进**沙箱 iframe**（`connect-src 'none'` + 3 种无秘密只读权限）。
   - **四层文件分离**：用户意图（`plugins.json` `@latest`） / 实际安装态（`package.json` + `bun.lock` sha512 pin） / 运行时缓存（`plugin-providers.json`） / 能力状态分文件；市场走 PR 审核 `registry.json` + `dist` tarball sha512 + `withdrawn` 仅阻新装机制。
   - **最关键的可迁移哲学——「事实/判决分离」**：插件只声明和上报**事实**（登录方式、模型、额度、设备与读数、健康），宿主独占**策略与判决**（路由、写入门、危险分级、二次确认、锁屏拦截、告警分级、凭据库）。
2. **`docs/plans/optional-features/architecture.md:141`**：已在本仓 v1.4.0 内置能力停用设计中借鉴了 Magpie 的启用意愿、在用提示与逆序释放。
3. **`docs/adr/0024-out-of-process-adapter-protocol.md`（PR #452 已合入）+ `Shared/adapterManifest.schema.json` + `Tests/Fixtures/adapter-protocol/` + `scripts/check_adapter_protocol.py`**：已将 `12-magpie-plugin-model.md` §12 落地为正式的 **进程外适配器协议 v0 纯契约**（stdio NDJSON JSON-RPC 2.0、8 MiB 帧上限、严格只读方法集、25 个禁止字段黑名单、上游强制过期短期租约 vs 静态 API Key `writeOnly` 配置注入、`sourceScope = adapter:<adapterId>`、内置源去重优先权、安全不变量与 `ProcessSupervisor` 复用）。

### 7.3 线索同步状态与对后续调研的建议

- 已于公告板 `#12` 第一时间通知 `@plugin-arch-magpie`，共享了 `yetone/magpie` 唯一指向、本仓既有 `12-magpie-plugin-model.md` 与 `ADR-0024` 落地状态以及 `#456`/`#438` 缺口。
- **对全队的关键提示（[分析推断]）**：
  1. 本仓在 2026-11-23 已完成过一轮 16 专题深度调研（`docs/research/2026-11-23-deep-dive/00`–`16`），且其中绝大部分 P0 与 P1 项在 11-23～11-24 已极速合入 `main`。本次蜂群的增量价值在于：**站在 `HEAD (PR #459)` 的真实水位线上**，重点突破已识别但未落地的深水区——即 **ADR-0024 阶段 4→6（从纯契约走向跨双端真运行时、LG webOS 参考适配器、受控写 `control.execute` + 网络/进程沙箱、Ed25519 签名与分级市场、多平台如 Matter/Hue/涂鸦/Aqara 适配器生态、以及反向作为 MCP/AI/桌面生态中枢的长期愿景）**。
