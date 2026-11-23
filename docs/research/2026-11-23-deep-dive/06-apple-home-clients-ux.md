# 06 Apple 平台优秀智能家居客户端的 UX/UI/动效与系统集成

> **调研日期**：2026-11-23  
> **调研范围**：`home-assistant/iOS`（含 Mac Catalyst / Widgets / Control Center / Live Activities / App Intents / Spotlight / Focus Filter / Watch）、`nickustinov/itsyhome-macos`（未覆盖部分：设置窗口、全局快捷键、HomeKit 后台刷新、分发更新机制、Core Animation 动效）、`home-assistant/frontend`（`ha-control-slider`、`ha-big-number`、`state-badge`、`hui-tile-card`、More Info 对话框与状态动效）、闭源 Apple 生态客户端（Apple 家庭 App、Controller for HomeKit、Eve、Home+ 6、HomeControl Menu、HomeBar），并逐点对照 MenuBarHome（`Sources/MenuBarMijiaApp/`、`Sources/MijiaCore/`、`Package.swift`）。  
> **实读仓库（commit）**：
> - `home-assistant/iOS` @ `ac2896d`（`~/.cache/mbh-research-clones/home-assistant__iOS`）
> - `nickustinov/itsyhome-macos` @ `5bd8dd8`（`~/.cache/mbh-research-clones/nickustinov__itsyhome-macos`）
> - `home-assistant/frontend` @ `9eb51a8`（`~/.cache/mbh-research-clones/home-assistant__frontend`）
> - 说明：已读过 `docs/research/2026-11-05-ecosystem-benchmark.md` 中对 `itsyhome-macos` 自动分组（`AutoGroups.swift`）和窗帘行（`BlindMenuItem.swift`）的分析，本文不再重复，仅作增量剖析。

---

## 0. 结论先行

1. **我们当前的 Apple 系统级扩展集成几乎为空白**：仓库构建清单 `Package.swift` 仅有主程序与库目标，全仓零 `WidgetKit`、`ControlWidget`、`SetFocusFilterIntent`、`CSSearchableItem`/`IndexedEntity`、`ActivityAttributes` 引用，而 `AppIntents.swift` 仅暴露 4 个全局 Intent 且未接入 Spotlight 索引与精确专注模式名称上报【源码】。
2. **交互式 Widget 必须带「幂等目标值 + 两步确认 + 并发限期 + 缓存兜底」才能上生产**：`home-assistant/iOS` 用 `WidgetOptimisticToggle` 携带目标 `targetValue` 防止连续误触翻转，`WidgetEntityStateProvider` 用 `withTaskGroup` 并发拉取并设 8 秒整批死线、单卡失败复用旧缓存、1 秒防重刷窗口对抗 WidgetKit 重复刷新 bug【源码】。
3. **macOS 14+ / 26 控制中心控件（`ControlWidget`）可直接复用现有 `AppIntents`**：`home-assistant/iOS` 的 `ControlLight` / `ControlCover` 采用 `AppIntentControlConfiguration` + `SetValueIntent` + `ControlRefreshDelay`（2 秒回读等待），MenuBarHome 若拆出 WidgetKit App Extension 即可同时解锁桌面/通知中心小组件与控制中心控件【源码 + 推断】。
4. **我们的「专注模式自动化」目前是半盲状态，可用 `SetFocusFilterIntent + LiveActivityIntent` 补齐精确模式名**：我们当前仅通过 `INFocusStatusCenter` 读布尔值 `isFocusActive`，不知道用户开启了“工作”还是“睡眠”；HA iOS 通过让 `SetFocusFilterIntent` 遵循 `LiveActivityIntent` 在应用未启动时也能被系统后台唤醒并上报具体专注模式名【源码】。
5. **我们的本地热键仅服务“面板呼出/语音”，缺少“高频设备/场景直达热键”**：`itsyhome-macos` 通过 `PreferencesManager+Shortcuts` 按家庭存储 `[favouriteId: ShortcutData]`，并用 Carbon `RegisterEventHotKey` + 行内录制按钮 `ShortcutButton` 让每个常用设备/场景都能一键直达【源码】。
6. **在“休眠/锁屏/网络恢复”三合一自愈与门禁节能方面，`itsyhome-macos` 的工程细节值得吸收**：其 `MacOSController` 用 3 秒 `DebouncedAction` 合并系统唤醒、屏幕唤醒、锁屏解锁和 `NWPathMonitor` 网络回归四路信号，并在菜单未打开时跳过 UI 树遍历（仅保留状态栏固定项、自动化、SSE、历史记录更新）【源码】。
7. **我们的 `LiquidGlassSlider` 已具备高水准，但在“点击直跳动画 vs 拖拽零延迟”、“双向中心滑块（色温）”、“亮暗色高饱和归一化”与“故障脉冲动效”上可向 HA Frontend 精准补强**：`ha-control-slider` 在非拖拽态使用 `180ms ease-in-out` 平滑滑移、拖拽 `.pressed` 时切换 `transition: none` 消除粘滞感；色温/位置支持 `centeredMode` 从中点双向填充；低饱和灯光色强制提纯（`S < 0.4 -> 0.4`）以保证亮色文字/图标对比度；警报与门锁卡住态有 `1s` 脉冲动效【源码】。
8. **分发更新链路无需羡慕 `itsyhome-macos`**：`itsyhome-macos` 走 Mac App Store（StoreKit 内购 + `ReviewPrompter`），源码中**并未使用 Sparkle**；MenuBarHome 自研的 Ed25519 验签自更新链路（`UpdateSection.swift`）已优于 MAS 审核延迟模式【源码】。
9. **Spotlight 直达与状态栏实时活动（Live Activity 类比）是高性价比差异化抓手**：HA iOS 的 `SpotlightEntityIndexer` 用 `CSSearchableIndex` + 2 秒防抖 + 内容签名哈希实现零冗余系统搜索；macOS 上虽然没有 iOS `ActivityKit` 灵动岛，但可在菜单栏常驻区类比出“状态胶囊（如洗衣机剩余时间、门铃响铃、全关倒计时撤销）”【源码 + 推断】。

---

## 1. `home-assistant/iOS` 深度剖析（Mac Catalyst、Widgets、Control Center、Live Activities、Focus Filter、Spotlight、Watch）

### 1.1 第一层：架构与系统能力版图
`home-assistant/iOS`（`@ac2896d`）以同一套 Swift 代码库覆盖 iOS、iPadOS、macOS（Mac Catalyst + 原生 `MacBridge` AppKit 插件）、watchOS 与独立 `WidgetsExtension`。其在 `WidgetsBundle18` 中同时注册了 13 类 `Widget`、13 类 `ControlWidget` 以及 `ActivityConfiguration`（仅 iOS 真机启用，排除 Mac Catalyst）【源码：`home-assistant__iOS:Sources/Extensions/Widgets/Widgets.swift:44-84`】。

### 1.2 第二/三层：关键机制与实现细节

#### A. Mac Catalyst 与菜单栏桥接（`MacBridge`）
- **状态栏插件架构**：因为 Catalyst 进程无法直接调用部分 AppKit 状态栏私有能力，HA iOS 将 AppKit 能力封装在独立的 `MacBridge` bundle 中。`MacBridgeStatusItem` 创建一个 `NSStatusBar.system.statusItem(withLength: .variableLength)`，`button.sendAction(on: [.leftMouseUp, .rightMouseDown])`：左键默认执行主动作（唤出或聚焦 Catalyst 主窗口），按住 `Control`/`Option`/`Command` 修饰键或右键则弹出 `NSMenu` 快捷菜单，并在 `menuDidClose` 时把 `statusItem.menu` 重置为 `nil`，避免阻塞后续左键事件【源码：`home-assistant__iOS:Sources/MacBridge/MacBridgeStatusItem.swift:3-67`】。
- **动态 Dock 策略切换**：`MacBridgeImpl.activationPolicy` 允许在 `.regular`（显示在 Dock）与 `.accessory`（纯菜单栏驻留）之间运行时切换，切换时同步调用 `NSApplication.shared.activate(ignoringOtherApps: true)`【源码：`home-assistant__iOS:Sources/MacBridge/MacBridgeImpl.swift:73-94`】。
- **工具栏白名单与确认弹窗**：`MacToolbarSettingsView` 允许用户将任意 `MagicItem` 钉到 Mac 工具栏/菜单，移除时触发 `.confirmationDialog`，配置写入共享 GRDB 数据库后通过 `NotificationCenter(.macToolbarConfigDidChange)` 实时通知桥接层【源码：`home-assistant__iOS:Sources/App/Settings/MacToolbar/MacToolbarSettingsView.swift:4-133`】。
- **局限对比**：HA iOS 的状态栏点击只是“唤出完整 WebView 窗口”，既不像我们直接挂出原生 `NSPanel` 面板，也没有原生 SwiftUI 磁贴网格。

#### B. WidgetKit 时间线刷新与网络死线控制
- **单条目模板协议**：`WidgetSingleEntryTimelineProvider` 统一封装了 WidgetKit 生命周期：
  1. Preview/Placeholder 严格返回静态 Mock（`WidgetPreviewSample`），不读本地库、不打网络请求，避免在 Widget Gallery 滑动预览时浪费额度或泄露真实家庭数据；
  2. `timeline(for:in:)` 统一设置 `.after(Current.date() + expiration)`，其中实体小组件默认 `expiration = 15 分钟`【源码：`home-assistant__iOS:Sources/Extensions/Widgets/Common/WidgetTimelineProviderSupport.swift:38-86`、`WidgetEntitiesTimelineProvider.swift:130-134`】。
- **对抗 iOS WidgetKit 重复刷新 Bug**：iOS 系统常在短时间内对同一组件连续触发多次 `timeline` 回调。`WidgetEntitiesTimelineProvider` 设置 `cacheValiditySeconds = 1`，并且**按实体列表 SHA-256 前 8 字节指纹分文件缓存**（`entities-\(serverId)-\(fingerprint)`），防止桌面多个同类小组件互相覆盖或击穿缓存【源码：`home-assistant__iOS:Sources/Extensions/Widgets/Entities/WidgetEntitiesTimelineProvider.swift:15-17,119-127`】。
- **8 秒并发批处理与部分失败兜底**：
  `WidgetEntityStateProvider` 明确指出 REST 查询只能单实体并发，`fetchDeadline = 8` 秒放在独立竞争 Task 中约束整批 `withTaskGroup`，超时后立即 `group.cancelAll()`；对于单批中失败或超时的实体，从上次磁盘缓存 `cache?.states[item]` 回填而不留白，防止单个离线/超时设备拖垮整张 Widget【源码：`home-assistant__iOS:Sources/Extensions/Widgets/Common/WidgetTimelineProviderSupport.swift:97-208`】。

#### C. 交互式小组件：乐观状态、防误触幂等与原地二次确认
1. **分体式点击区域（Split Tile）**：`WidgetTileInteraction` 将单个按钮磁贴拆分为两块区域（对齐前端 Tile Card）：点击左侧图标执行 `iconInteractionType`（如切换开关），点击右侧文字主体通过 `.widgetURL(...)` 深链打开对应实体详情页【源码：`home-assistant__iOS:Sources/Extensions/Widgets/Common/WidgetTileInteraction.swift:12-14,60-72`】。
2. **乐观 Toggle 与防连击幂等**：
   - `WidgetOptimisticToggle` 仅对 `light` / `switch` / `inputBoolean` / `fan` 启用；
   - 渲染时使用 `Toggle(isOn: toggle.isOn, intent: intent)` 配合自定义 `WidgetEntityToggleStyle`（开启态透明度 1、关闭态 `0.65`），且**关键技巧**：`.disabled(configuration.isOn != initialIsOn)`——在系统还未完成下一次 Timeline 刷新期间锁定按钮，防止用户连续点击两次；
   - `CustomWidgetToggleAppIntent` 接收显式 `targetValue: Bool?`（而非盲目 `toggle`），注释写明 *"A repeated tap on the same timeline must not undo the first request"*【源码：`WidgetEntityToggleStyle.swift:15-25`、`WidgetTileInteraction.swift:128-146`、`CustomWidgetToggleAppIntent.swift:59-71`】。
3. **小组件原地二次确认（In-Widget Confirmation）**：
   不需要跳回 App 弹窗。点击敏感操作（`requiresConfirmation == true`）时，先触发 `UpdateWidgetItemConfirmationStateAppIntent` 将当前 Widget 条目状态翻转为确认视图（显示取消/确认两枚胶囊按钮，其他未确认磁贴自动降为 `opacityWhenDisabled = 0.3` 弱化聚焦）；确认按钮再执行真实 Intent，执行后统一等待 `Task.sleep(1_000_000_000)`（1 秒）以待服务端状态收敛后才交还控制权给系统重载时间线【源码：`WidgetTileInteraction.swift:249-280`、`WidgetTileView.swift:15-16`、`CustomWidgetToggleAppIntent.swift:87-93`】。

#### D. 控制中心控件（`ControlWidget`）与 Intent 参数实体
- **结构拆解**：以 `ControlLight` / `ControlCover` 为例，每个控制中心控件由 3 部分组成：
  1. `ControlWidget` + `AppIntentControlConfiguration(kind:provider:)`，内部使用 `ControlWidgetToggle(isOn:action:label:valueLabel:)` 或 `ControlWidgetButton`；
  2. `AppIntentControlValueProvider` 实现 `placeholder`、`previewValue` 和异步 `currentValue(configuration:)`；值得注意的是在 `currentValue` 开头调用 `ControlRefreshDelay.wait()`（固定休眠 2 秒 `2 * 1_000_000_000` ns），让控制中心点击后的异步回读等待服务端状态刷新再定格图标状态【源码：`ControlLight.swift:9-34`、`ControlCover.swift:8-42`、`ControlRefreshDelay.swift:3-11`、`ControlLightsValueProvider.swift:18-37`】；
  3. 动作 Intent 遵循 `SetValueIntent`（如 `LightIntent`），同时满足系统控制中心和快捷指令的双重接口。
- **级联实体参数查询（`@IntentParameterDependency`）**：`WidgetEntitiesAppEntityQuery` 与各 Control 配置 EntityQuery 使用 `@IntentParameterDependency<WidgetEntitiesAppIntent>(\.$server)`，让第二个参数（实体列表）根据用户已选第一个参数（服务器）动态过滤；未选服务器时按服务器分组返回 `IntentItemCollection(sections:)`，有上下文（房间/设备/楼层）的实体排在无上下文实体之前【源码：`WidgetEntitiesAppEntityQuery.swift:12-80`】。

#### E. Focus Filter（专注模式精确绑定）
- 普通 `SetFocusFilterIntent` 存在致命陷阱：**若 App 未在前台运行，iOS 在切换专注模式时经常静默跳过执行**。
- `FocusNameFocusFilterAppIntent` 巧妙让其遵循 `LiveActivityIntent`（`extension FocusNameFocusFilterAppIntent: LiveActivityIntent {}`），从而获准在 App 处于未启动/后台状态下被系统唤醒到 App 进程执行；执行时先调用 `Current.connectivity.refreshNetworkInformation()` 补齐冷启动尚未初始化的网络信息，再在 `backgroundTask(timeout: 20)` 中把选中的专注模式名称（`focusName?.name`）上报【源码：`FocusNameFocusFilterAppIntent.swift:10-111`】。
- 启动时还通过 `Self.current`（`FocusNameFocusFilterAppIntent.current`）主动向系统反查当前生效的专注模式，捕获 `SetFocusFilterIntentError.notFound` 判定为无匹配专注模式【源码：`FocusNameFocusFilterAppIntent.swift:44-62`】。

#### F. Spotlight 系统检索集成（`CoreSpotlight` + `IndexedEntity`）
- `HAAppEntityAppIntentEntity` 遵循 `IndexedEntity`（iOS 18+），在 `attributeSet` 中不仅写标题，还主动填入：
  - `contentDescription`（地区/设备/服务器上下文副标题，因为 Spotlight 不会自动回退读取 `DisplayRepresentation.subtitle`）；
  - `keywords`（区域、设备、楼层、服务器、Domain 本地化名、展开点分与下划线的 `entityId`）；
  - `alternateNames`（正向与反向拼接组合 `"Light living room"` + `"living room Light"`）；
  - `thumbnailData`（实体图标渲染缩略图）【源码：`HAAppEntityAppIntentEntity+IndexedEntity.swift:7-51`】。
- `SpotlightEntityIndexer` 做增量保护与防死锁治理：
  1. `coalescingDelay = 2s` 合并连续数据库刷新通知；
  2. 全量快照求 SHA256 签名并与 `formatVersion = 4` 比对，签名未变直接跳过写入；
  3. 非 Catalyst 端在进入后台时取消挂起任务（`needsReindexOnForeground = true`），避免后台挂起持有 SQLite 文件锁触发 `0xdead10cc` 崩溃；
  4. 适配 iOS 27 `IndexedEntityQuery` 按需回调单批或全量重建【源码：`SpotlightEntityIndexer.swift:15-199`、`HAAppEntityAppIntentEntityQuery+IndexedEntityQuery.swift:8-20`】。

#### G. Live Activities 与 Watch 轻量架构
- **Live Activities**：`HALiveActivityAttributes` 明确限制在 `#if os(iOS) && !targetEnvironment(macCatalyst)`，使用 `startedAt` 时间戳解决服务端重复 push-to-start 导致的同 tag 双卡片竞态（保留最大 `startedAt` 并关闭其余），`HALockScreenView` 严格遵守系统 **160 pt 硬高度截断上限**，支持正/倒计时计时器（`chronometerStart` + `countdownEnd`）与动态方向进度条（`increasing` / `decreasing`）【源码：`HALiveActivityAttributes.swift:1-149`、`HALockScreenView.swift:7-69`】。
- **Watch 独立轮询与极简小组件直连**：WatchApp 前台采用 `WatchEntityStatePoller`（**5 秒轮询，10 秒无响应标记 stale**，动作执行后支持短延迟补拉 `refresh(after:)`）；而 Watch 表盘复杂功能 `WatchWidgetLiveFetch` 故意不引入 Alamofire / HAKit / PromiseKit 重栈，直接用原生 `URLSession` + `Security` mTLS 读 App Group 凭据直连 REST `/api/states/{entity}`，并用 `NSLock` + 按 complicationID 独立时间戳做防并发雪崩节流【源码：`WatchEntityStatePoller.swift:29-106`、`WatchWidgetLiveFetch.swift:6-89`】。

---

## 2. `nickustinov/itsyhome-macos` 未覆盖部分深度剖析

> 仅剖析此前 `2026-11-05-ecosystem-benchmark.md` 未覆盖的五大模块：设置窗口、全局快捷键、HomeKit 后台刷新、分发与更新机制、AppKit 底层动效参数。

### 2.1 设置窗口（`SettingsWindowController` / `SettingsView`）
- **窗口约束**：固定宽度 `750 pt`（`contentMinSize = (750, 350)`，`contentMaxSize = (750, .greatestFiniteMagnitude)`），**仅允许垂直拉伸**，防止用户拉宽后表单控件跨屏失衡；采用 `.fullSizeContentView` + `titlebarAppearsTransparent = true`【源码：`itsyhome-macos:macOSBridge/Settings/SettingsWindowController.swift:18-36`】。
- **AppKit 侧边栏设计**：`200 pt` 宽的 `NSVisualEffectView(material: .sidebar, blendingMode: .behindWindow)` 配合 `NSTableView(style: .sourceList, rowHeight: 36)`；选中态通过 `SidebarRowView.drawSelection` 自绘 `insetBy(dx: 8, dy: 2)`、`cornerRadius: 6` 的 `.systemBlue` 圆角胶囊并反转子视图文字/图标颜色为白色（PRO 蓝底徽标跳过反转）【源码：`itsyhome-macos:macOSBridge/Settings/SettingsView.swift:17-55,187-241`】。
- **平台条件剪枝**：12 个设置分类通过 `isAvailableForCurrentPlatform` 按当前所选后端（HomeKit / HA）动态裁剪（例如 HA 模式下隐藏 `homeKitBridge`），且切换后端时通过 `/usr/bin/open -n` 重启自身进程并保留另一端的凭据【源码：`SettingsView.swift:123-144`、`GeneralSection.swift:128-163`】。
- **对比我们**：我们的 `SettingsWindowView` 用纯 SwiftUI 实现了原生 `236 pt` 侧栏 + `620 pt` 固定内容列宽 + 跨窗格行级搜索（`SettingsSearch`）+ 未保存更改守卫（`SettingsUnsavedChanges`），交互深度显著优于 Itsyhome（Itsyhome 无设置搜索、切换后端需重启）。

### 2.2 全局快捷键（设备/场景直达快捷键）
- **设计定位**：与我们“全局一个热键呼出面板”不同，Itsyhome 支持为**任意单个收藏设备/场景/分组**单独绑定系统级全局快捷键【源码：`PreferencesManager+Shortcuts.swift:15-68`】。
- **录制控件（`ShortcutButton`）**：行内轻量 `NSButton`，点击进入录制态监听 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`：
  - `Esc`（keyCode 53）取消录制；
  - `Delete`/`Backspace`（51 / 117）或**直接右键点击**清除快捷键；
  - 强制要求至少包含 `⌘ / ⌃ / ⌥ / ⇧` 之一，否则 `NSSound.beep()` 拒绝；
  - 缺点：未做系统占用冲突提示【源码：`ShortcutButton.swift:45-118`】。
- **注册与分发（`HotkeyManager`）**：使用 Carbon `RegisterEventHotKey` 安装在 `GetEventDispatcherTarget()`（签名 `"ITSY"`），以递增 `UInt32` ID 映射 `[hotkeyId: favouriteId]`；触发后切回主队列直接执行切换/调光/场景动作，无需打开面板【源码：`HotkeyManager.swift:18-126`】。

### 2.3 HomeKit 后台刷新、唤醒防抖与空闲门禁
- **四合一唤醒防抖（3 秒去抖）**：Mac 在无中枢（无 Apple TV/HomePod）直连 HomeKit 桥接器时，锁屏或休眠后配件常变灰不可用。`MacOSController` 监听 4 个系统事件：
  1. `NSWorkspace.didWakeNotification`（系统唤醒）
  2. `NSWorkspace.screensDidWakeNotification`（仅显示器休眠唤醒）
  3. `DistributedNotificationCenter` `"com.apple.screenIsUnlocked"`（仅锁屏解锁）
  4. `NWPathMonitor` 网络从非 `.satisfied` 恢复为 `.satisfied`
  四者统一收敛到 `homeKitResumeRefresh = DebouncedAction(delay: 3)`；且执行前检查 `guard !menuIsOpen else { homeKitResumeRefresh.trigger(); return }`，防止用户正展开菜单点击时整树重建导致行跳位【源码：`itsyhome-macos:macOSBridge/MacOSController.swift:64-66,200-220,318-357`】。
- **防连接恢复读风暴（Characteristic 白名单）**：当配件从离线恢复在线（`accessoryDidUpdateReachability`）时，Itsyhome 只读取 `HomeKitManager.observedCharacteristicTypes` 白名单中的运行时特征，跳过固件版本/厂商/型号等静态元数据特征，防止桥接器恢复时引发读风暴【源码：`HomeKitManager+DataFetching.swift:166-200`、`HomeKitManager.swift:195-210`】。
- **菜单关闭态 UI 零遍历门禁（#113 省电优化）**：`MacOSController+MenuUpdates.swift` 在收到特征变更通知时，先更新必须后台常驻的 4 条链路（Pinned 菜单栏常驻项、`WebhookServer` SSE 推送、`AutomationEngine` 状态持续时长触发器、`HistoryStore` 历史采样），随后立即执行 `guard menuIsOpen || isLocalChange else { return }`——菜单关闭期间完全跳过全菜单项更新，等 `menuWillOpen` 时再按**菜单展示顺序**去重读取刷新，让顶部可见行优先呈现最新状态【源码：`MacOSController+MenuUpdates.swift:14-46,109-123`】。
- **Catalyst 幽灵窗口修复**：用 Objective-C runtime swizzle `NSWindow.makeKeyAndOrderFront(_:)`，拦截 Catalyst 隐藏 1×1 主窗进入窗口列表，避免调度中心（Mission Control）出现空白幽灵窗【源码：`MacOSController.swift:248-258`】。

### 2.4 分发与更新机制（无 Sparkle 核实）
- **核实结果**：检视 `project.yml`、`CHANGELOG.md` 与全部源码后确认，`itsyhome-macos` **未使用 Sparkle**（仓库内零 `Sparkle` / `SUUpdater` / `appcast` 引用）；它通过 Mac App Store 分发，采用 `StoreKit` 内购（`ItsyhomeProducts.storekit`）解锁 Pro，并在 `CHANGELOG.md` 3.4.0 中记录了针对登录启动时 App Store 凭证延迟的 `10s -> 1m -> 5m` 阶梯重试及内置评分弹窗（每 120 天最多一次）【源码：`project.yml:57`、`CHANGELOG.md:5-7`】。

### 2.5 AppKit 底层动效与交互细节
| 组件 | 实现与参数 | 设计意图与可借鉴点 | 源码依据 |
| :--- | :--- | :--- | :--- |
| **全局动效 Token** | `fast = 0.15s`，`normal = 0.25s`，`slow = 0.35s`，`springDamping = 0.7`，`springVelocity = 0.5` | 统一 AppKit 层时长梯度 | `DesignSystem.swift:182-189` |
| **开关与三段窗帘按钮 (`ToggleSwitch` / `CoverControl`)** | Thumb 位移用 `CASpringAnimation(keyPath: "position")`：**`damping = 15, stiffness = 300, mass = 1`**，`duration = settlingDuration`；轨道颜色用 `CABasicAnimation` `0.15s`；窗帘按钮上图标与底座共用 `NSAnimationContext(0.2s)` | AppKit 手动 `CALayer` 弹簧曲线轻快跟手；三段式（关/停/开）比弹出抽屉更省一步 | `ToggleSwitch.swift:183-208`、`CoverControl.swift:263-288` |
| **现代滑块 (`ModernSlider`)** | 鼠标悬停时 Thumb 通过 `CASpringAnimation("transform.scale")`（`damping = 15, stiffness = 300`）放大至 **`1.1×`**；支持 **`centeredMode`**（从中点向左右双向填充，适合冷暖色温或偏差值）；离开时仅在 `!isDragging` 才缩回 `1.0` | `1.1×` 悬停呼吸感 + 中点双向填充模式极具参考价值 | `ModernSlider.swift:51-54,149-167,215-273` |
| **防误触穿透 (`NSView+MouseTracking`)** | `CHANGELOG 3.4.0` 修复并代码落地：按住开关/窗帘/颜色按钮后移出松手，控件内部吞掉释放事件 (`trackClick(from:)`) 并取消操作，防止释放落到底层整行触发锁/车库门开关 | 滑块/小按钮点击或拖拽绝不能透传触发父卡片点击 | `CoverControl.swift:320-325`、`HighlightingMenuItemView.swift:136-142` |

---

## 3. `home-assistant/frontend` 深度剖析（Tile Card、Slider、Big Number、State Badge 与 More Info）

### 3.1 `ha-control-slider`：零延迟拖拽与状态反馈机制
- **交互与手势工程**：使用 Hammer.js 组合 `Pan(threshold: 10)` + `Tap` + `Press`，并动态设置 `touchAction = vertical ? "pan-x" : "pan-y"`，确保横向滑块不拦截页面竖向滚动（纵向滑块不拦截横向翻页）；支持 `pancancel` 自动回滚至 `savedValue`【源码：`ha-control-slider.ts:194-248`】。
- **三种填充模式**：
  - `start`（默认）：从起点填满到当前值（亮度/音量）；
  - `end`：从当前值填满到终点（适合窗帘从上向下遮蔽）；
  - `cursor`：仅渲染一个游标块（`--cursor-size = thickness / 4`，适合色温条，不遮挡底部渐变色带）【源码：`ha-control-slider.ts:37,412-431,638-710`】。
- **关键动效曲线（为什么拖拽不跟手 vs 跟手）**：
  - 正常/点击/外部状态刷新时，轨道填充条 `transform: translate3d(...)` 带有 **`transition: transform 180ms ease-in-out, background-color 180ms ease-in-out`**，点击轨道任一点时滑块会平滑滑移过去；
  - 一旦进入拖拽态（`.pressed` class），CSS 立即覆盖为 **`.pressed .slider-track-bar, .pressed .slider-track-cursor { transition: none; }`**，完全消除 180ms 滞后，实现指哪跟哪的零延迟；
  - 键盘微调（方向键 ±1 step，`PageUp/Down` ±10%，`Home/End` 极值）会弹出浮动数值气泡（`.tooltip`），松键后延时 **500 ms** 淡出（`opacity 180ms ease-in-out`）；
  - 针对风扇等非整数步长（如 `100/91 ≈ 1.0989%`），提供 `roundValue` 属性：**内部计算仍精确吸附原始步长，仅展示与读屏四舍五入为整数**【源码：`ha-control-slider.ts:83-92,257-321,487-490,601-604,728-734`】。

### 3.2 `hui-tile-card`、`ha-tile-icon` 与状态色/动效逻辑
- **分体点击与按压反馈**：
  - `ha-tile-container` 区分 `icon` slot 与整卡背景（带有 Material `ha-ripple`：悬停透明度 **`0.04`**、按下 **`0.12`**）；
  - 可交互图标 `ha-tile-icon[interactive]` 在悬停时背景不透明度从 **`0.2` 提升至 `0.35`**（`180ms ease-in-out`），在按下（`:active`）时图标整体 **`transform: scale(1.2)`**（`180ms ease-in-out`）【源码：`ha-tile-icon.ts:79-103`、`ha-tile-container.ts:98-100`】。
- **灯光颜色感知与防惨白算法**：
  - 在 `hui-tile-card.ts` 与 `ha-state-control-light-brightness.ts` 中，当灯光报告 `rgb_color` 时，先转为 HSV：**若饱和度 `S < 0.4`（偏白光）且 `< 0.1`（纯白），强制将明度 `V` 压到 `225/255`；若 `0.1 <= S < 0.4` 则提纯饱和度至 `0.4`**，防止白光或淡色在浅色卡片上完全消失【源码：`hui-tile-card.ts:214-230`、`ha-state-control-light-brightness.ts:63-76`】。
  - `stateColorBrightness` 对 `state-badge` 应用亮度滤镜 `brightness((brightness + 245) / 5%)`，即亮度 1 时仍有 **~49.2% 基准亮度**，避免调暗到 1% 时图标彻底黑掉看不清【源码：`state_color.ts:131-141`】。
- **状态驱动关键帧动效**：
  - **高危/异常脉冲**：`alarm_control_panel` 的 `pending` / `arming` / `triggered` 以及 `lock` 的 `jammed` 状态，触发 **`@keyframes pulse`（`1s infinite`，opacity `1 -> 0 -> 1`）**【源码：`icon_color_css.ts:4-21`、`hui-tile-card.ts:410-415,452-462`】；
  - **计时器结束提示**：`timerJustFinished` 触发 **`timer-finished-pulse`（`0.5s ease-in-out 2` 次，将 `--tile-icon-color` 闪烁为 `--error-color`）**，并在 `prefers-reduced-motion: reduce` 时把动画时长清零【源码：`hui-tile-card.ts:106-115,417-431`】；
  - **扫地机拟态 SVG 动效**：`ha-state-control-vacuum-status.ts` 在清扫态运行 12 秒无限漫游动画（`vacuum-wander 12s ease-in-out infinite`）、0.6 秒边刷旋转（`brush-spin 0.6s linear infinite`）及 8 颗错峰粒子吸入动画（`particle-suck 2.4s ease-in infinite`，延迟 `-0.3s` 递减）【源码：`ha-state-control-vacuum-status.ts:340-380`】。

### 3.3 `ha-big-number` 与 More Info 对话框
- **`ha-big-number` 读数排版**：主整数 **`57 px`**（`line-height: 1.12, letter-spacing: -0.25px`），小数部分（`0.42 em`）与单位（`0.33 em`）采用垂直反向弹性堆叠（`flex-direction: column-reverse`，可选 `bottom` 基线对齐），同时用 `.visually-hidden` 输出完整读屏字符串，兼顾大字号视觉冲击与屏幕阅读器语义完整【源码：`ha-big-number.ts:42-107`】。
- **More Info 对话框（`ha-more-info-dialog` & `more-info-light`）**：
  - `ha-state-control-light-brightness` 将 `ha-control-slider` 设为大尺寸垂直胶囊（宽 `--control-slider-thickness: 130px`，高 `45vh`、限幅 `200px–320px`，大圆角 `--ha-border-radius-6xl`），居中成为视觉绝对主角；下方用紧凑图标按钮组切换 `brightness | color | color_temp` 模式及常用色块【源码：`ha-state-control-light-brightness.ts:78-115`、`more-info-light.ts:154-250`】；
  - 对话框顶部主读数采用 `36px`（`ha-more-info-state-header`），下方副行显示相对更新时间（如“3 分钟前”），**点击该行即可原位切换为绝对时间戳**（`_toggleAbsolute`），并用 `withViewTransition` 衔接 Info / History / Settings 子视图栈【源码：`ha-more-info-state-header.ts:51-107`、`ha-more-info-dialog.ts:51,302-398`】。

---

## 4. 闭源 Apple 生态客户端横向扫描（官网/评测/更新日志检索）

> 本节均为公开资料检索结果，按方法要求降级标注为 **【检索】**（2026-11-23 检索）。闭源细节与具体动画数值不可查证处已注明“未查到”。

| 客户端 | 平台形态 | UX / UI / 动效亮点 | 系统集成亮点 | 可借鉴点 / 局限 |
| :--- | :--- | :--- | :--- | :--- |
| **Apple 家庭 App** (iOS 18–26 / macOS / tvOS) | 系统原生全端（macOS 无菜单栏版） | - **分体式磁贴**：左图标轻点切换、右文字区轻点弹出详情控制卡<br>- **长按（Haptic Touch）与控制中心调光**：在控制中心/Home 中长按亮度或音量模块展开全尺寸垂直大滑块，拖拽带触觉反馈；iOS 18+ 支持自由网格缩放磁贴尺寸<br>- *具体弹簧参数未公开*【检索】 | - 原生控制中心多页可调尺寸磁贴<br>- Siri / 家庭中枢本地自动化<br>- tvOS 遥控器快捷侧边栏与画中画门铃弹窗【检索】 | **对标**：我们已在 `DeviceCardView` 实现左图标开关 + 右区展开抽屉、编辑模式圆弧拖拽调大小；仍缺桌面/控制中心外部入口与长按大滑块直出【推断】 |
| **Controller for HomeKit** (v7.2 – v10) | iOS / iPadOS / macOS / Watch | - **3D 平面图导航**与可配置条件显隐仪表盘<br>- **Home Sharing**：家庭内共享整套自定义界面与工作流布局<br>- *具体动画时长未查到*【检索】 | - **控制中心控件**（v7.2 起）：直接在 iOS 控制中心放工作流按钮、Apple TV 遥控、3D 平面图直达入口<br>- **Live Activities & 锁屏/桌面小组件**：实时盯防传感器异常或流程进度<br>- **Controller Hub**：Mac 常驻跑复杂后台工作流【检索】 | **借鉴**：Mac 常驻本地自动化网关思路与我们 `AutomationEngine` 高度同构；可参考其“按设备/人条件隐藏/置顶磁贴”与“流程执行 Live 状态卡片”【推断】 |
| **Eve for HomeKit & Matter** | iOS / iPadOS / macOS (Catalyst) | - **Touch & Hold 连续滑动菜单**：长按任何设备/房间触发上下文菜单，**手指不抬起直接滑选菜单项并松手执行**，极高操作吞吐<br>- **数据历史曲线优先**：点击任何读数进入日/月/年交互趋势折线【检索】 | - 较早完成 Mac Catalyst 三栏原生适配，配合 Thread/Matter 能源与空气质量遥测展示【检索】 | **借鉴**：我们传感器已有 24h/7d 折线，可借鉴 Eve 的“长按/右键菜单内直接列常用预设（亮度 20%/50%/100% 等）”减少展开抽屉步骤【推断】 |
| **Home+ 6** | iOS / iPadOS / macOS | - **高信息密度看板**：直接暴露 HomeKit 隐藏特征<br>- **Battery Smart Section / Widget**：专门聚合全屋电池设备并按低电量标红排序，桌面小组件直接充当维护仪表盘【检索】 | - 小组件（多尺寸，早期/部分操作以 Deep Link 跳回 App 为主）与自定义壁纸房间【检索】 | **借鉴**：可参考 Battery Smart Section 在我们面板/设置中加“低电量/异常设备置顶提示”，而不必等用户翻到底部“未显示/离线”抽屉【推断】 |
| **HomeControl Menu** | macOS 菜单栏 (MAS) | - 经典菜单栏下拉结构、房间智能分组一键全关、自定义隐藏与移入子菜单【检索】 | - **每设备/每场景独立全局快捷键**<br>- 支持 `x-callback-url`、AppleScript、CLI 与 Keyboard Maestro 联动【检索】 | **对比**：我们已有 `menumijia://` URL Scheme（缺标准 `x-callback-url` 成功/失败回调）与全屋/当前房间长按全关；缺单设备全局热键【源码 + 检索】 |
| **HomeBar** | macOS 菜单栏 + iOS (MAS) | - 复古目录卡美学、自然语言筛选（如“楼上开着的灯”、“功率 >100W”）<br>- **自动化失败诊断日志**（显示哪条条件未命中）与**设备健康总览徽标**（离线/低电/固件更新直接在菜单栏图标带徽标提醒）【检索】 | - 全局快捷键、AppleScript、Raycast、Alfred、CLI 与 **MCP Server**；能耗电费估算与每周 AI 建议【检索】 | **对比**：我们在 Raycast/CLI/MCP/电费统计/AI 口令方面已齐平甚至超前（双数据源+米家直连）；**自动化失败原因可视日志**与**菜单栏健康徽标**值得补齐【源码 + 检索】 |

---

## 5. 可直接借鉴的交互/动效清单（带具体参数）

以下均已对照我们 `Sources/MenuBarMijiaApp/` 现有实现（`DesignTokens.swift`、`ThemeAndMotion.swift`、`DeviceCardView.swift`、`SmallDeviceTile.swift`、`ControlCenterPanel*.swift`、`MenuBarPanelController+Presentation.swift`），剔除已实现项，仅列高价值可落地改进：

| # | 交互 / 动效项 | 对标来源与实证参数 | 我们现状 | 落地建议（带参数） |
| :--- | :--- | :--- | :--- | :--- |
| 1 | **滑块「点击平滑滑移 + 拖拽零延迟」双态** | `ha-control-slider.ts:601-604,731-734`：常态 `transition: transform 180ms ease-in-out`；拖拽 `.pressed` 时 `transition: none` | `LiquidGlassSlider` (`ThemeAndMotion.swift:799-875`)：`DragGesture(minimumDistance: 0)` 更新 `value` 无过渡动画，点击轨道任一位置是瞬跳 | 给 `LiquidGlassSlider` 进度宽与 Thumb `x` 坐标加 `withAnimation(isDragging || reduceMotion ? nil : .easeInOut(duration: 0.18))`；拖拽中 `isDragging == true` 保持 `nil`（零延迟），外部同步或单击轨道跳变时 `0.18s` 丝滑过渡 |
| 2 | **滑块悬浮呼吸放大 + 点击/拖拽不透传保护** | `itsyhome` `ModernSlider.swift:215-273`：Hover 时 Thumb `CASpringAnimation(damping: 15, stiffness: 300)` 放大至 **`1.1×`**；`CoverControl.swift:320-325` 吞掉滑出释放事件 | `LiquidGlassSlider` 仅在 `isDragging` 时将 Thumb 宽度 `22 -> 28`（`glassLensSpring` `response: 0.20, damping: 0.88`），无指针 Hover 预反馈 | 为 `LiquidGlassSlider` 增加 `@State isHovering`，Hover 时 Thumb 轻度放大 `1.08×`（`AppleMotion.pressFeedback` `0.12s` easeOut），并确认外层卡片 `GlassHoverHighlight` 在滑块区域被禁用（目前仅在 `inlinePrimarySlider == nil` 时开启） |
| 3 | **色温/位置滑块「中点双向填充」与「游标模式」** | `itsyhome` `ModernSlider.swift:51-54,149-167`（`centeredMode` 从中点向两侧填色）；`ha-control-slider.ts:412-431`（`cursor` 模式白条游标不遮渐变色带） | `LiquidGlassSlider` 支持 `isSpectrumTrack: true` 显示全幅色温渐变，但 Thumb 仍是半透明白胶囊，视觉重点偏弱 | `isSpectrumTrack == true` 时改用 `ha-control-slider` 的 `cursor` 风格高对比白游标（或带 1.5 pt 深色描边），提升色温指示清晰度 |
| 4 | **亮/白光饱和度归一化（防发光色在浅色界面隐身）** | `hui-tile-card.ts:214-230`：`S < 0.1 -> V = 225/255`，`0.1 <= S < 0.4 -> S = 0.4`；`state_color.ts:138`：图标最低亮度地板 **`~50%`**（`(b + 245)/5%`） | `DevicePalette.accentColor` (`ThemeAndMotion.swift:237-255`) 固定使用 `DesignTokens.Orb.*` 静态色，不随灯光 RGB 或亮度动态变化 | 若后续支持 RGB 灯色反映在 `DeviceIconOrb` 上，必须套用 HSV 下限归一化（`S >= 0.4` 或白光降 `V` 至 `0.88`），亮度映射保持 `max(0.5, ...)` 防止极暗状态图标发黑 |
| 5 | **卡片图标「按压瞬时弹跳」与「异常脉冲」** | `ha-tile-icon.ts:98-100`：`:active` **`scale(1.2)` `180ms`**；`hui-tile-card.ts:410-462`：警报/卡锁 **`pulse 1s infinite`**（opacity 1↔0），计时结束 **`0.5s × 2`** 变红提示 | `DeviceIconOrb` (`SmallDeviceTile.swift:34`) 仅在 `isOn` 变化时有 `.symbolEffect(.bounce)`；`PressableCardButtonStyle` 整体缩至 `0.972`（`0.12s`）；无故障/锁卡住脉冲动效 | 对安全告警设备（门锁卡住/虚掩、漏水/烟雾报警、鱼缸低水位/水泵故障）的 `DeviceIconOrb` 外环或图标增加可控的 `1.0s` `easeInOut` 呼吸脉冲（`reduceMotion` 下改为静态红/橙描边） |
| 6 | **风扇/整数显示但底层精确步长（`roundValue`）** | `ha-control-slider.ts:83-92,126-135`：内部步长精准，tooltip 与 VoiceOver 四舍五入为整数 | `SliderStepSnap` (`ThemeAndMotion.swift:660-695`) 与 `LiquidGlassSlider` 直接格式化 `formattedValue` | 对非整数步长设备（如多挡风扇百分比、华氏度/小数温度步长）在显示层与 `accessibilityValue` 保持整洁取整，底层命令仍保留规格精确步长 |
| 7 | **大号状态读数排版（整数 + 垂直堆叠小数/单位）** | `ha-big-number.ts:42-95`：主数 `57px`，小数 `0.42em`，单位 `0.33em` 垂直堆叠 | `ClimatePanelModule` / `DeviceCardView` (`609-611`) 用 `24pt` `.rounded` `.bold` 同字号混排 | 温湿度传感器展开卡或空调大卡主读数可试行“大整数 + 小字号上标小数/单位”（如 `24` + `.5 / °C`）提高一瞥可读性 |
| 8 | **三段式窗帘行内胶囊（关 / 停 / 开）** | `itsyhome` `CoverControl.swift:12-42,262-288`：`42pt` 宽三段药丸滑块（`CASpringAnimation damping 15, stiffness 300`），针对无位置上报的开合类设备直接操作 | `CoverDetailDrawer` 需展开抽屉操作，且无位置百分比的窗帘/晾衣架交互偏重 | 对无 `current-position` 仅支持 `open/stop/close` 的窗帘/晾衣架，在卡片主区右侧直接放置 3 段胶囊按钮（`↓ / ⏸ / ↑`），免展开直接可控 |
| 9 | **键盘单手调节时数值悬浮气泡（500ms 自动隐去）** | `ha-control-slider.ts:310-321,475-524`：键盘方向键调整触发 Tooltip 显示，松键 **500 ms** 后淡出 | `LiquidGlassSlider` 已支持方向键步进 + `.alignment` 触觉反馈，但数值始终固定在轨道右端，紧凑空间下易被手/指针或狭窄视图遮挡 | 保持右端常驻数字，在键盘焦点调节时加轻微高亮胶囊反馈（`0.5s` 延时还原），或为 `SmallDeviceTile` 键盘聚焦增加简短状态 HUD |
| 10 | **空闲省电与唤醒自愈（3 秒四合一去抖）** | `itsyhome` `MacOSController.swift:64-66,200-220,318-357` & `MacOSController+MenuUpdates.swift:32`：系统唤醒/屏幕唤醒/锁屏解锁/网络恢复四合一 3s 去抖；面板未打开时仅维护后台自动化/事件，不做无用视图刷新 | 我们有 `SystemActivityMonitor`、`HotkeyAndNotificationManager` 与 `HomeStore`，需确认是否在锁屏/显示唤醒/网络恢复后统一合并触发云端与局域网 miIO 重握手（`Hello`） | 借鉴 3 秒合并去抖模型处理 macOS 唤醒 + `com.apple.screenIsUnlocked` + `NWPathMonitor` 回归后的 `LocalMiIOClient` Stamp 重校准与 HA WebSocket 保活探针 |

---

## 6. 系统集成缺口深度分析（对照 `home-assistant/iOS` 与竞品）

我们当前工程构建形态为纯 SwiftPM（`Package.swift` 仅定义 `MijiaCore` 与 `MenuBarMijiaApp` 可执行程序），未配置 Xcode `.appex` 扩展目标，因此全仓搜索 `WidgetCenter` / `ControlWidget` / `SetFocusFilterIntent` / `CSSearchableItem` / `ActivityAttributes` 均为 `NONE_FOUND`【源码】。逐项梳理缺口与可行路径如下：

| 系统能力 | 对标做法（`home-assistant/iOS` / 竞品） | 我们现状 | 技术约束与落地方案 | 改造难度与风险 |
| :--- | :--- | :--- | :--- | :--- |
| **1. 交互式桌面/通知中心 Widget（WidgetKit）** | `WidgetsExtension`（`.appex`）共享 App Group 存储；`WidgetSingleEntryTimelineProvider`（15m 刷新 + 1s 防重刷 + 8s 批死线）+ `WidgetOptimisticToggle`（携带 `targetValue` 幂等切换 + 锁按钮防连击）+ 小组件原地二次确认 | **缺失**。macOS 桌面上不能放常用开关或环境传感器卡片 | **必要前置**：在 Xcode 打包链（`scripts/build_app.sh`）引入 WidgetKit App Extension + App Group（例如 `group.com.jryang2026.MenuBarHome`），复用 `MijiaCore` 与无凭据快照（或共享 Keychain Access Group）。**高风险检查**：凭据跨进程共享需严格守住 Keychain Access Group 边界；敏感设备复用原地二步确认或 `requiresConfirmation` 锁 | **L（大）**；涉及打包链与钥匙串共享（命中高风险面 1、5） |
| **2. macOS / iOS 控制中心控件（`ControlWidget`）** | `ControlLight` / `ControlCover` / `ControlScene`（macOS 26 Tahoe 与 iOS 18+ 已开放控制中心 `ControlWidget`）：`ControlWidgetToggle` + `AppIntentControlValueProvider` + `SetValueIntent` + 2s `ControlRefreshDelay` | **缺失**。我们已有 `PanelTheme.liquidGlass` 对齐 macOS 26 控制中心视觉，但尚未真正住进系统控制中心本身 | 与 WidgetKit **共享同一个 `.appex` 扩展包**！在 macOS 26+ 控制中心可直接钉选“全屋关灯”、“一键情景”或“客厅主灯开关”，点击通过 `SetValueIntent` 执行。注意米家云端延迟（300–800ms）下必须借鉴 `ControlRefreshDelay`（1.5–2s 等待后回读），且若启用局域网 miIO 则可 <100ms 收敛 | **M–L**（随 WidgetKit 扩展一并解锁；需 macOS 26+ SDK） |
| **3. 专注模式精确过滤（`SetFocusFilterIntent`）** | `FocusNameFocusFilterAppIntent` 遵循 `SetFocusFilterIntent` + **`LiveActivityIntent`**（确保 App 未开时也可后台唤醒），把用户选的专注模式名直接绑定为触发器 | **半缺失**。`MacContextAutomation.swift:42-167` 仅通过 `INFocusStatusCenter` 拿布尔值 `isFocusActive: Bool?`，无法区分“工作”还是“睡眠”专注模式 | 可直接在主 App 的 `AppIntents.swift` 新增 `FocusProfileFilterIntent: SetFocusFilterIntent`（无需 `.appex`），暴露“专注模式标签”参数，让用户在系统“专注模式 → 添加过滤条件”中绑定“MenuBarHome 自动化场景/配置文件”，切换即精准触发对应规则 | **S–M**（纯主进程 AppIntents 扩展，收益极高） |
| **4. Spotlight 全局直达（`CoreSpotlight` + `IndexedEntity`）** | `HAAppEntityAppIntentEntity: IndexedEntity` + `SpotlightEntityIndexer`（2s 防抖 + 内容签名哈希 + `formatVersion`），在系统 Spotlight 搜“客厅灯”可直接打开控制详情或触发快捷指令 | **缺失**。仅支持呼出我们自己的面板后打字搜索；系统 Spotlight 搜不到具体设备和房间 | 在 `AppIntents.swift` 中让现有的 `DeviceEntity`、`SceneEntity`、`RoomEntity` 在 macOS 15+/26 上遵循 `IndexedEntity`（或通过 `CSSearchableIndex` 写入），附带房间名/拼音首字母/别名作为 `keywords` 与 `alternateNames`，点击结果通过 `menumijia://focus?device=<id>` 呼出面板并精准高亮展开该设备 | **M**（需注意 `BridgeToken` 与只读索引脱敏） |
| **5. Live Activity 类比（macOS 状态栏实时活动胶囊）** | iOS 端 `HALiveActivityConfiguration` 160pt 锁屏/灵动岛卡片跟踪洗衣/倒计时/进度（`Mac Catalyst` 明确排除） | 我们已有 `MenuBarPanelController` 驱动的菜单栏图标+动态文字（如语音听写波形），及面板内的 `ActivityStackView`（安全告警、门铃、漏跑定时） | macOS 原生无 `ActivityKit` 灵动岛，但在 MenuBarHome 上最贴切的**本地类比**是「**菜单栏常驻实时胶囊（Status Bar Live Pill）**」：当家里有**正在运行的延时/倒计时指令、洗衣机/烘干机剩余时间 <15m、门铃 60s 内刚响铃、或全屋撤销倒计时（10–15s）**时，在菜单栏图标旁动态挂载紧凑状态胶囊（如 `🫧 12m` / `↩︎ 撤销 9s`），点击直达对应卡片或执行撤销，结束自动收起 | **M**（纯 AppKit `NSStatusItem` 扩展，零外部依赖） |
| **6. 单个高频设备/场景全局热键** | `itsyhome` `PreferencesManager+Shortcuts` + `HotkeyManager` + `ShortcutButton`；`HomeControl Menu` 同款 | `HotkeyAndNotificationManager.swift` 仅支持 1 个全局热键（默认 `⌥M` 呼出面板 / 长按语音） | 在现有 Carbon `RegisterEventHotKey` 管理器中扩展多热键注册表（复用已有的 `HotkeyShortcutRecorder` 与冲突检测），允许在设置或设备右键菜单为高频设备/场景绑定独立快捷键（如 `⌃⌥L` 切换桌面台灯） | **S–M**（复用现有基础设施，注意与 `ScreenLockPolicy` 和二次确认守卫对齐） |

---

## 7. 对照我们：差距表

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| :--- | :--- | :--- | :--- | :---: |
| [Package.swift](../../../Package.swift) | 纯 SwiftPM 单可执行目标，无 `.appex` 扩展目标 | `home-assistant/iOS` 独立 `WidgetsExtension` 承载 Home/Desktop Widgets + Control Center `ControlWidget` + App Group 共享 | 评估为 Xcode/打包脚本增加 WidgetKit 扩展目标 + App Group 只读快照通道，先出桌面传感器/开关小组件与控制中心 `ControlWidget` | **L** |
| [AppIntents.swift](../../../Sources/MenuBarMijiaApp/AppIntents.swift) | 4 个基础 Intent（切换设备/执行场景/一句话/查温湿度）；未接 Spotlight `IndexedEntity`，无 `SetFocusFilterIntent`，无 `SetValueIntent` | HA iOS `IndexedEntity`（带上下文正反组合词 + 2s 签名防抖索引）+ `SetFocusFilterIntent` + `SetValueIntent` | ① 主进程新增 `SetFocusFilterIntent` 补全专注模式名称识别；② 让 `DeviceEntity`/`SceneEntity` 接入 `CSSearchableIndex` 支持 Spotlight 直达面板聚焦；③ 补 `SetDevicePowerIntent: SetValueIntent` 服务控制中心 | **M** |
| [MacContextAutomation.swift](../../../Sources/MijiaCore/MacContextAutomation.swift#L42-L167) | 专注模式触发器仅判断 `isFocusActive: Bool?`，无法区分专注模式名称 | HA iOS `FocusNameFocusFilterAppIntent` 显式上报用户所选模式名 | 保留现有开关兜底，新增按 Focus Filter 名称/ID 匹配的自动化条件 | **S** |
| [ThemeAndMotion.swift](../../../Sources/MenuBarMijiaApp/ThemeAndMotion.swift#L698-L892) | `LiquidGlassSlider` 支持步长吸附与 10% 触觉，但单击轨道无平滑动画，无 Hover 预放大，色温滑块 Thumb 偏大且非游标态 | `ha-control-slider.ts`（常态 `180ms` 过渡 + `.pressed` 关闭过渡 + `cursor` 模式）；`ModernSlider.swift`（Hover `1.1×` 放大） | ① 非拖拽态开启 `0.18s easeInOut`，`isDragging` 置 `nil`；② 增加 Hover Thumb `1.08×` 微放（`0.12s`）；③ 色温模式改用高对比游标滑块 | **S** |
| [SmallDeviceTile.swift](../../../Sources/MenuBarMijiaApp/SmallDeviceTile.swift#L6-L40) & [DeviceCardView.swift](../../../Sources/MenuBarMijiaApp/DeviceCardView.swift#L421-L506) | `DeviceIconOrb` 仅在开/关切换时 `.bounce`；全关/告警依赖顶部横幅与面板活动栈，卡片图标无危险脉冲；无位置窗帘需进抽屉 | `hui-tile-card.ts`（告警/锁卡住 `1s` 呼吸脉冲、计时结束闪红）；`itsyhome` `CoverControl`（行内 3 段药丸） | ① 安全告警/门锁卡住/滤芯耗尽/设备故障时给 `DeviceIconOrb` 加 `1s` 脉冲（兼容 `effectiveReduceMotion`）；② 无位置窗帘/晾衣架行内提供 3 段 `关/停/开` 胶囊 | **M** |
| [HotkeyAndNotificationManager.swift](../../../Sources/MenuBarMijiaApp/HotkeyAndNotificationManager.swift#L111-L180) | Carbon `RegisterEventHotKey` 仅注册 1 个全局快捷键（呼出面板/按住语音） | `itsyhome` `HotkeyManager` 支持为任意常用设备/场景分别绑定全局快捷键 | 扩展 `HotkeyManager` 为多快捷键映射表（复用意图路由 + 现有 `HotkeyShortcutRecorder` + 锁屏与二次确认门禁） | **M** |
| [MenuBarPanelController.swift](../../../Sources/MenuBarMijiaApp/MenuBarPanelController.swift#L33-L180) & `HomeStore` | 状态栏文本仅展示主信息与听写态；面板关闭时仍需验证唤醒/解锁/网络恢复防抖与空闲跳过渲染情况 | `itsyhome` 3 秒四合一唤醒去抖 + 面板不可见跳过 UI 树更新；iOS Live Activities 进度/倒计时胶囊 | ① 在菜单栏图标旁实现“Live Activity 实时状态胶囊”（定时剩余/撤销倒计时/家电完工倒计时/门铃响铃）；② 确认唤醒+解锁+网络恢复收口至单次去抖刷新 | **M** |

---

## 8. 推进清单

### P0（低成本高价值 / 体验立竿见影）

1. **`LiquidGlassSlider` 补齐“点击 180ms 滑移 + 拖拽零延迟 + Hover 1.08× 呼吸”**
   - **价值**：消除单击滑块轨道时的生硬瞬跳，同时保持拖拽绝对跟手，补齐桌面鼠标悬停触感。
   - **成本**：S（仅改 `ThemeAndMotion.swift` 约 30 行）。
   - **优先级**：P0
   - **涉及高风险面？**：否（纯样式/交互微调，可直推 `main`）。
   - **依据**：`home-assistant/frontend` `ha-control-slider.ts:601-604,731-734`；`itsyhome-macos` `ModernSlider.swift:215-273`【源码】。

2. **新增 `SetFocusFilterIntent` 补齐“精确专注模式名称”触发器**
   - **价值**：解决当前 `MacContextAutomation` 只能感知“开/关专注模式”而分不清“工作/睡眠/勿扰”的半盲痛点，且完全在主 App 进程实现、无需拆 `.appex`。
   - **成本**：S–M（`AppIntents.swift` + `MacContextAutomation.swift`）。
   - **优先级**：P0
   - **涉及高风险面？**：是（`AutomationRule` / 状态自动化执行边界，建议走 PR 附带单测，对齐 `ScreenLockPolicy`）。
   - **依据**：`home-assistant/iOS` `FocusNameFocusFilterAppIntent.swift:10-111`；我们 `MacContextAutomation.swift:42-167`【源码】。

3. **异常状态图标脉冲动效（告警/锁卡住/水泵故障）与 `roundValue` 整数化显示**
   - **价值**：让危险或故障设备在卡片墙中一瞥即见，风扇/多挡百分比不再出现怪异小数；严格兼容 `effectiveReduceMotion`。
   - **成本**：S。
   - **优先级**：P0
   - **涉及高风险面？**：否（UI 展示层，需补充对应状态快照验证）。
   - **依据**：`home-assistant/frontend` `hui-tile-card.ts:410-462`、`ha-control-slider.ts:83-92`【源码】。

### P1（值得做的结构 / 系统能力补全）

4. **Spotlight 设备/房间/场景索引与直达（`CoreSpotlight` + `menumijia://focus`）**
   - **价值**：用户按下 `⌘Space` 搜“客厅空调”或“ktkt”可直接打开面板并高亮展开该设备，补齐与 HA iOS / Raycast 齐平的系统级入口。
   - **成本**：M（新增 `SpotlightEntityIndexer`，复用 `MijiaCore` 拼音索引与签名哈希防重刷）。
   - **优先级**：P1
   - **涉及高风险面？**：否（只读索引 + 跳转导航，不绕过确认门禁；需控制 `CSSearchableItemAttributeSet` 不含敏感凭据）。
   - **依据**：`home-assistant/iOS` `SpotlightEntityIndexer.swift:15-199`、`HAAppEntityAppIntentEntity+IndexedEntity.swift:7-51`【源码】。

5. **菜单栏“Live Activity 实时状态胶囊”（macOS 端对标 iOS 灵动岛）**
   - **价值**：将“全屋撤销倒计时（12s）”、“洗衣机/电饭煲最后 15 分钟”、“定时指令即将执行”、“刚响铃的门铃”直接外显到菜单栏图标旁，实现不打开面板也一眼掌握家中正在发生的动态事件。
   - **成本**：M（`MenuBarPanelController.swift` + `HomeStore` 派生轻状态）。
   - **优先级**：P1
   - **涉及高风险面？**：否（UI 状态外显；点击执行敏感动作仍走 `HomeStore` 既有确认路径）。
   - **依据**：`home-assistant/iOS` `HALiveActivityAttributes.swift`、`HALockScreenView.swift` 类比【源码 + 推断】。

6. **高频设备/场景独立全局快捷键（`HotkeyManager` 多热键扩展）**
   - **价值**：对齐 `itsyhome-macos` 与 `HomeControl Menu`，让常用桌面灯或“下班回家”场景可一键盲操。
   - **成本**：M（扩展 `HotkeyAndNotificationManager.swift` 与 `SettingsWindowView.swift` 设备/快捷键列表）。
   - **优先级**：P1
   - **涉及高风险面？**：是（触发真实设备控制写入，必须经过 `ScreenLockPolicy` 与高风险二次确认拦截，建议走 PR）。
   - **依据**：`itsyhome-macos` `HotkeyManager.swift:18-126`、`PreferencesManager+Shortcuts.swift:15-68`【源码】。

7. **无位置窗帘/晾衣架行内三段胶囊（`关 / 停 / 开`）+ 唤醒四合一 3 秒去抖加固**
   - **价值**：减少基础窗帘/晾衣架操作点击次数；保证 Mac 锁屏/唤醒/断网恢复后米家局域网 miIO 与 HA WebSocket 同步稳健恢复且不重复轰炸。
   - **成本**：S–M。
   - **优先级**：P1
   - **涉及高风险面？**：部分涉及（`Cover` 写入遵循现有安全确认策略，唤醒重连需防并发风暴）。
   - **依据**：`itsyhome-macos` `CoverControl.swift`、`MacOSController.swift:64-66,318-357`【源码】。

### P2（高价值但跨构建链，可独立立项）

8. **WidgetKit 桌面小组件 + macOS 26 控制中心 `ControlWidget` 扩展包（`.appex`）**
   - **价值**：补齐桌面固定监控（温湿度/电池/开关）以及 macOS 控制中心原生系统级按钮，彻底融入 Apple 原生生态。
   - **成本**：L（需要把 `scripts/build_app.sh` / 签名发布链从纯 SwiftPM 可执行体扩展为带 `.appex` 与 App Group Entitlements 的包结构）。
   - **优先级**：P2
   - **涉及高风险面？**：是（命中高风险面 1、4、5：跨进程共享凭据/快照、代码签名与更新打包链，**必须走 PR**，严格采用 `WidgetOptimisticToggle` 幂等 `targetValue`、8s 并发超时、旧缓存兜底与 1s 防重刷）。
   - **依据**：`home-assistant/iOS` `Widgets.swift`、`WidgetTimelineProviderSupport.swift:97-208`、`ControlLight.swift`、`WidgetTileInteraction.swift`【源码】。

### P3（远期 / 锦上添花）

9. **自动化失败原因可读日志面板 & 菜单栏健康告警微标 + 传感器大数字排版试验**
   - **价值**：对齐 `HomeBar` 的诊断可观测性与 `ha-big-number` 的数据阅读层次。
   - **成本**：S–M。
   - **优先级**：P3
   - **涉及高风险面？**：否。
   - **依据**：`HomeBar`【检索】、`ha-big-number.ts`【源码】。

---

## 9. 设想（天马行空，标明 ADR 冲突）

1. **「MenuBarHome 双向硬件旋钮与系统级 Focus/Shortcut 联动网关」**：借鉴 `itsyhome` 内置 `HAP` 虚拟桥接思路，让 MenuBarHome 不止做控制端，还能把 Mac 的“外接显示器接入、摄像头麦克风占用、专注模式、电池电量”直接暴露成米家/HA 虚拟传感器或 HomeKit 配件，供手机米家/Apple 家庭反向联动。
   - **与现有 ADR 冲突**：**可能与 ADR-0017（不引入原生 HomeKit 后端）存在边界张力**（ADR-0017 否决的是消费 HomeKit 配件作为第三控制源，而非暴露虚拟桥；但引入 `HAP` 服务栈仍会打破“零三方依赖”及扩大网络攻击面），若推进需新立 ADR 评审。
2. **「macOS 桌面隐形磁贴悬浮墙（Widget + 跨设备 Live Mirroring）」**：利用 macOS 26+ 控制中心与桌面小组件，加上把面板内正在运行的洗衣机/扫地机/门铃状态通过本地加密信标推送到用户 iPhone（作为 iOS Live Activity 或 iPhone 镜像联动），实现跨苹果设备无感接力。
   - **与现有 ADR 冲突**：当前项目核心定位在 macOS 14+ 与 Windows 11 桌面端（ADR-0006），引入独立 iOS/watchOS 伴侣端将大幅扩展维护矩阵，暂无对应 ADR 支持。
3. **「用户自定义 SwiftUI/Web 渲染器插件卡片（如第三方 3D 户型图、高级仪表盘）」**：像 `Controller for HomeKit` / HA Lovelace 自定义卡片那样允许社区编写动态卡片视图加载进面板。
   - **与现有 ADR 冲突**：**直接冲突 ADR-0023（宿主统一持有内置能力、明确排除进程内第三方代码插件）**。若要开放仅能走 ADR-0023 允许的进程外独立扩展协议（如本地 HTTP/MCP 提供的声明式 JSON 卡片描述，由宿主沙盒内组件安全渲染，严禁加载外部可执行代码）。

---

## 10. 来源清单

### 源码（本地只读浅克隆，已核对路径与行号）
- `home-assistant/iOS`（commit `ac2896d`）：
  - `Sources/Extensions/Widgets/Widgets.swift`
  - `Sources/Extensions/Widgets/ControlRefreshDelay.swift`
  - `Sources/Extensions/Widgets/Common/WidgetTimelineProviderSupport.swift`
  - `Sources/Extensions/Widgets/Common/WidgetTileInteraction.swift`
  - `Sources/Extensions/Widgets/Common/WidgetOptimisticToggle.swift`
  - `Sources/Extensions/Widgets/Custom/AppIntents/CustomWidgetToggleAppIntent.swift`
  - `Sources/Extensions/Widgets/Entities/WidgetEntitiesTimelineProvider.swift`
  - `Sources/Extensions/Widgets/Entities/WidgetEntitiesAppEntityQuery.swift`
  - `Sources/Extensions/Widgets/Entities/WidgetEntitiesAppIntent.swift`
  - `Sources/Extensions/Widgets/Controls/Light/{ControlLight.swift,ControlLightsValueProvider.swift,LightIntent.swift}`
  - `Sources/Extensions/Widgets/Controls/Cover/ControlCover.swift`
  - `Sources/Extensions/Widgets/LiveActivity/{HALiveActivityConfiguration.swift,HALockScreenView.swift}`
  - `Sources/Shared/LiveActivity/HALiveActivityAttributes.swift`
  - `Sources/HADesignSystem/Sources/Widgets/Common/{WidgetTileView.swift,WidgetEntityToggleStyle.swift}`
  - `Sources/App/Settings/Focus/FocusNameFocusFilterAppIntent.swift`
  - `Sources/App/Utilities/Spotlight/{SpotlightEntityIndexer.swift,HAAppEntityAppIntentEntity+IndexedEntity.swift,HAAppEntityAppIntentEntityQuery+IndexedEntityQuery.swift}`
  - `Sources/App/Settings/MacToolbar/MacToolbarSettingsView.swift`
  - `Sources/App/BackgroundRefreshManager.swift`
  - `Sources/MacBridge/{MacBridgeImpl.swift,MacBridgeStatusItem.swift}`
  - `Sources/WatchApp/Utilities/WatchEntityStatePoller.swift`
  - `Sources/WatchWidgets/WatchWidgetLiveFetch.swift`
- `nickustinov/itsyhome-macos`（commit `5bd8dd8`）：
  - `project.yml`、`CHANGELOG.md`
  - `macOSBridge/MacOSController.swift`
  - `macOSBridge/MacOSController+MenuUpdates.swift`
  - `macOSBridge/HotkeyManager.swift`
  - `macOSBridge/Controls/ShortcutButton.swift`
  - `macOSBridge/Settings/{SettingsWindowController.swift,SettingsView.swift,PreferencesManager+Shortcuts.swift}`
  - `macOSBridge/Settings/Sections/{GeneralSection.swift,AboutSection.swift}`
  - `macOSBridge/DesignSystem/{DesignSystem.swift,ToggleSwitch.swift,CoverControl.swift,ModernSlider.swift,HighlightingMenuItemView.swift}`
  - `Itsyhome/iOS/{HomeKitManager.swift,HomeKitManager+DataFetching.swift}`
- `home-assistant/frontend`（commit `9eb51a8`）：
  - `src/components/ha-control-slider.ts`
  - `src/components/ha-big-number.ts`
  - `src/components/ha-state-icon.ts`
  - `src/components/entity/state-badge.ts`
  - `src/components/tile/{ha-tile-icon.ts,ha-tile-container.ts}`
  - `src/common/entity/state_color.ts`
  - `src/common/style/icon_color_css.ts`
  - `src/panels/lovelace/cards/hui-tile-card.ts`
  - `src/panels/lovelace/cards/tile/tile-card-style.ts`
  - `src/panels/lovelace/card-features/hui-light-brightness-card-feature.ts`
  - `src/state-control/ha-state-control-toggle.ts`
  - `src/state-control/light/ha-state-control-light-brightness.ts`
  - `src/state-control/vacuum/ha-state-control-vacuum-status.ts`
  - `src/dialogs/more-info/{ha-more-info-dialog.ts,controls/more-info-light.ts,components/ha-more-info-state-header.ts}`

### 本仓库对照源码
- `Package.swift`
- `Sources/MenuBarMijiaApp/{DesignTokens.swift,PanelDesign.swift,ThemeAndMotion.swift,DeviceCardView.swift,SmallDeviceTile.swift,AppIntents.swift,ControlCenterPanel.swift,ControlCenterPanelChrome.swift,ControlCenterPanelLayout.swift,ControlCenterPanelStacks.swift,ControlCenterPanelActivities.swift,MenuBarPanelController.swift,MenuBarPanelController+Presentation.swift,HotkeyAndNotificationManager.swift,SettingsWindowView.swift,UpdateSection.swift}`
- `Sources/MijiaCore/{HomeStore.swift,MacContextAutomation.swift}`
- `docs/adr/INDEX.md`、`docs/platform-matrix.zh-CN.md`、`docs/research/2026-11-05-ecosystem-benchmark.md`

### 公开检索资料（2026-11-23）
- Apple Home / Control Center (iOS 18–26, tvOS): Apple Support / MacRumors / Reddit 公开 UX 说明
- Controller for HomeKit (v7.2–v10): `controllerforhomekit.com` 更新日志与控制中心功能介绍
- Eve for HomeKit & Matter: `evehome.com`、AppleInsider、9to5Mac Catalyst 与 Touch & Hold 交互评测
- Home+ 6: MacStories 与 App Store 详情页
- HomeControl Menu: App Store 与 Automators 讨论
- HomeBar: `homebar.industries` 官网与 App Store（id6742761358）页面
