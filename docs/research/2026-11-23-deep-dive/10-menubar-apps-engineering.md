# 10 大众认可度高的开源 macOS 菜单栏应用的工程实现（系统效率与内部逻辑）

- 调研日期：2026-11-23
- 范围：NSStatusItem / NSPanel / NSPopover / MenuBarExtra 的取舍与已知坑、面板显示隐藏时机、多显示器与刘海、App Nap 与定时器合并、内存与空闲 CPU、崩溃与卡顿可观测、权限引导、首启引导、Sparkle 2 与我们的 Ed25519 自更新对比。
- 实际读取的仓库（浅克隆 `--depth 1`，只读，均未运行任何脚本/构建）：

| 仓库 | 本地 HEAD | 说明 |
| --- | --- | --- |
| `exelban/stats` | `f47dca1` 2026-11-22 | 模块化 widget 与读取调度 |
| `jordanbaird/Ice` | `main` `11edd39` 2025-09-20；另取 `macos-26` 分支 `6d74d25` 2026 | 菜单栏项管理。**注意 main 已落后**（远端 `pushed_at` 2026-10-06，开发在 `macos-26` 分支）【源码】`git ls-remote --heads` |
| `p0deje/Maccy` | `e24f997` 2026-11-23 | NSStatusItem + 自定义面板、搜索、SwiftData |
| `leits/MeetingBar` | `c8deee4` 2026-11-16 | 日历、NSMenu 构建、刷新管线 |
| `dwarvesf/hidden`（Hidden Bar） | `b10f93d` 2026-11-23 | 隐藏他人菜单栏图标（含 10 000 pt 上限、macOS 27 私有框架、刘海） |
| `steipete/CodexBar` | `a26ca57` 2026-11-21 | 现代菜单栏应用：自适应刷新、内存压力、卡顿看门狗 |
| `sfsam/Itsycal`（代码署名 mowglii.com） | 2026-11-13 推送 | 分钟边界定时器、单调时钟 |
| `AppHouseKitchen/AlDente-Charge-Limiter` | `8b93da2` 2026-10-08 | NSPopover 形态、特权 helper 反例 |
| `sindresorhus/KeyboardShortcuts` | `772133d` 2026-09-12 | Carbon 热键与现代并发 |
| `sindresorhus/LaunchAtLogin-Modern` / `orchetect/MenuBarExtraAccess` | 2026-08-05 | SMAppService 细节 / MenuBarExtra 可达性（即我们已放弃的路线） |
| `sparkle-project/Sparkle` | `b7debdb` 2026-11-20 | Sparkle 2 安全模型与调度 |

---

## 0. 结论先行

1. **菜单栏应用的“形态”基本决定它要自己重写多少系统行为**：NSMenu 形态（MeetingBar、CodexBar）白拿定位、键盘、Esc、外部点击关闭；自定义 NSPanel（我们、Stats、Maccy、Ice）要自己实现这四件事，而我们已经实现得比这四个项目都细（事件号、抑制窗口、代数计数）【源码】`Sources/MenuBarMijiaApp/MenuBarPanelController.swift:65`、`StatusItemEventDecision.swift:1-50`、`MenuBarPanelController+Presentation.swift:162-172`。
2. **我们最大的、可量化的系统效率问题不是面板，而是两个定时器**：状态栏标签 0.5 s 重复定时器没有 `tolerance`（`MenuBarPanelController.swift:743-752`），安全/报表/更新三合一的 60 s `Task.sleep` 循环在默认配置下永久运行（`HotkeyAndNotificationManager.swift:730-767`）。这两个都比 CodexBar/Stats 的做法激进。参照 `exelban/stats` 给 `DispatchSourceTimer` 设 200 ms leeway（`Kit/plugins/Repeater.swift:43`）。
3. **轮询策略我们只有 3 档（6 s / 60 s / 180 s），对照组有 5 档按“最近交互”衰减**：CodexBar 是 2 min → 5 min → 15 min → 30 min，低电量或热压力直接 30 min（`steipete/CodexBar:Sources/AdaptiveRefreshCore/AdaptiveRefreshPolicyCore.swift:56-66`）；MeetingBar 默认 180 s 并给整个刷新环加 120 s 超时（`leits/MeetingBar:MeetingBar/Calendar/CalendarSync.swift:60-69`）。我们的 `PollingPolicy` 结构已经就绪，加档位是纯策略改动（`Sources/MijiaCore/PollingPolicy.swift:19-48`）。
4. **“在我不知道的地方显示面板”这件事有成熟的兜底做法**：Ice 在空间切换、屏幕参数变化、菜单栏被系统自动隐藏时关闭面板（`jordanbaird/Ice:Ice/UI/IceBar/IceBar.swift:52-95`）；我们只在 `didChangeScreenParameters` 时重新定位，且 `classicFrame` 会把面板 clamp 到 `visibleFrame` 顶部，在“自动隐藏菜单栏”下会与图标脱开（`MenuBarPanelController+Presentation.swift:437-460`）。
5. **多显示器不是边缘情况，而是菜单栏的常态**：`NSStatusBarWindow` 每个显示器一份，其余是 `NSStatusItemReplicant`（`orchetect/MenuBarExtraAccess:Sources/MenuBarExtraAccess/MenuBarExtraUtils.swift:68-99`）；Hidden Bar 因此在计算折叠宽度时取**最宽**屏幕而不是 `NSScreen.main`（`dwarvesf/hidden:hidden/Features/StatusBar/Engine/LegacyLengthEngine.swift:68-76`）。我们有多处 `NSScreen.main` 兜底（`CameraLivePanelController.swift:348,1371`、`MenuBarPanelController+Presentation.swift:401`），在多屏下取错屏幕。
6. **macOS 26（Tahoe）有一个具体可验证的副作用**：每次状态栏窗口布局都会触发 `_refreshTilingConstraints`，而 Tahoe 的状态栏窗口在服务端没有真实窗口号，于是 WindowServer 每次都打印 `_CGXPackagesSetWindowConstraints: Invalid window`；Stats 直接 swizzle `NSStatusBarWindow._needsTilingConstraintUpdate` 返回 false（`exelban/stats:Stats/helpers.swift:384-403`）。我们已经用“值不变不写”缓存抑制了大部分写入（`MenuBarPanelController.swift:768-799`），但没有验证过是否仍有该日志。
7. **macOS 26/27 的菜单栏底层正在重写，我们的自绘面板反而更抗跌**：MenuBarExtra 在 macOS 27 改成 `NSStatusItemExpandedInterfaceSession`，窗口型 extra 的 `button.target/action` 变成 nil（`orchetect/MenuBarExtraAccess:Sources/MenuBarExtraAccess/NSStatusItem+ExpandedInterfaceSession.swift:14-38`）；Hidden Bar 的 10 000 pt 分隔条被 macOS 27 直接“挤出”菜单栏（`MenuBarEngineFactory.swift:23-30`）。我们只用一个自有 `NSStatusItem` + `NSPanel`，不依赖这些私有行为。
8. **自更新我们可以继续不合 Sparkle，但要偷它的三个机制**：默认 1 天检查 + 最小间隔、appcast 里的分阶段放量（`sparkle:phasedRolloutInterval`）、以及“调度检查时先申请通知授权 + 应用不活跃时只在通知里提示”（`jordanbaird/Ice:Ice/Updates/UpdatesManager.swift:120-145`）。我们目前是 6 h 固定间隔、无抖动、更新检查挂在 60 s 循环上（`HomeStore.swift:909`、`HotkeyAndNotificationManager.swift:764`）。
9. **崩溃/卡顿可观测是我们明确缺失的一环**：CodexBar 有主线程卡顿看门狗（ping + `/usr/bin/sample`）、内存压力 trim、IOPM assertion（`steipete/CodexBar:Sources/CodexBar/MainThreadHangWatchdog.swift:40-60`、`MemoryPressureMonitor.swift:44-70`、`AgentSessionPowerAssertion.swift:4-18`）；我们只有 20 条时间戳的本地环形缓冲（`Sources/MenuBarMijiaApp/AppDiagnosticsLog.swift:1-30`）。
10. **权限模型可以显著简化**：Ice 需要 Accessibility（必需）+ Screen Recording（可选），代价是 1 s 轮询权限并处理“部分授权”状态（`jordanbaird/Ice:Ice/Permissions/Permission.swift:52-64`）；我们的权限面是通知/麦克风/语音识别/日历/位置/专注，全部走系统 TCC 弹窗，无需 AX，因此**不必**引入 Ice 那套权限门禁，只需把“被拒绝后的引导”补齐（我们已有通知的部分，`HotkeyAndNotificationManager.swift:694-706`）。

---

## 1. 先立框架：四种菜单栏界面形态与实际代价

| 形态 | 代表 | 白拿的东西 | 必须自己实现的 | 已知坑 |
| --- | --- | --- | --- | --- |
| `NSMenu` 挂 `statusItem.menu` | MeetingBar、CodexBar | 定位、键盘上下、Esc、外部点击关闭、菜单跟踪期间的键事件路由 | 动态构建成本、菜单项高度/自定义视图限制 | 菜单打开时不能更新菜单（MeetingBar 直接 `if statusItem.menu != nil { return }`）【源码】`leits/MeetingBar:MeetingBar/UI/StatusBar/StatusBarItemController.swift:316-330` |
| `NSPopover` | AlDente、Itsycal 的新建事件 | 箭头指向、`.transient` 自动关闭、`enclosingPopover` | 内容尺寸、popover 内再嵌 popover 的手工管理 | `.transient` 下“点外部”由系统判定，无法区分“点了自己的另一个窗口”【源码】`AppHouseKitchen/AlDente-Charge-Limiter:AlDente/AppDelegate.swift:56-60` |
| 自绘 `NSPanel` | 我们、Stats、Maccy、Ice | 无 | 定位/夹取、Esc 阶梯、外部点击、key 状态、屏幕变化、高亮、动画 | 见 §3–§6 每个项目的踩坑清单 |
| SwiftUI `MenuBarExtra` | 大量新项目 | 同 NSMenu（`.menu`）或窗口（`.window`） | 想拿 `NSStatusItem`/`NSWindow` 就必须私有 API | `.menu` 阻塞 runloop；`.window` 在 macOS 27 换实现【源码】`orchetect/MenuBarExtraAccess:README.md:60-66`、`NSStatusItem+ExpandedInterfaceSession.swift:14-38` |

我们 2025 年在 #56 从 `MenuBarExtra` 迁到自有 `NSStatusItem` + `NSPanel` 的判断，被 `MenuBarExtraAccess` 这个库的演化完整验证：它到今天仍要靠 KVC 取 `_statusItem`（`NSWindow Extensions.swift:12-18`）、按类名筛 `NSStatusBarWindow`（`MenuBarExtraUtils.swift:68-99`）、并在 macOS 27 上改用 `_beginExpandedInterfaceSession:` 这条 SPI（`NSStatusItem+ExpandedInterfaceSession.swift:60-90`）。**结论：这条路我们不走回头路。**

---

## 2. exelban/stats：模块化、读取调度、低功耗

### 2.1 模块与 Reader 的三态

每个模块 = `Module`（widget + popup + settings + preview）持有若干 `Reader<T>`。Reader 有三个独立开关：`popup`（弹窗需要）、`preview`（设置预览需要）、`sleep`（仅在“单 widget 且是文本”时才允许休眠）【源码】`exelban/stats:Kit/module/reader.swift:44-53`、`Kit/module/module.swift:298-330`。

关键设计是**“有没有可见消费者”驱动采集**，而不是“用户开关”：

```swift
private func readerHasVisibleConsumer(_ reader: Reader_p) -> Bool {
    let shared = reader.sleep || (!reader.popup && !reader.preview)
    return self.enabled && (
        (self.popupVisible && (reader.popup || shared)) ||
        (self.settingsVisible && (reader.preview || shared)))
}
```

【源码】`Kit/module/module.swift:298-305`。可见消费者变化时 `unlock()`/`lock()`，并对 `popup/preview/sleep` 三类 Reader 真正 `pause()`（停定时器）【源码】`Kit/module/module.swift:307-333`。

**可借鉴点**：我们把“面板可见性”传给了 provider（`PollingContext.panelVisible`，已经对了），但没有“某个 UI 区域是否真的在看”这一层。例如摄像机页面关闭后 `CameraLivePanelController` 是否真的停止轮询，需要单独确认（见 §11 推进清单）。

### 2.2 定时器：DispatchSourceTimer + 200 ms leeway + 对齐秒边界

```swift
self.timer.schedule(deadline: .now() + Double(interval),
                    repeating: .seconds(interval),
                    leeway: .milliseconds(200))
```

【源码】`Kit/plugins/Repeater.swift:37-46`。另有 `alignToSecondBoundary`：先异步对齐到下一个秒边界（+5 ms 安全余量）再起重复定时器，代价是精度、收益是多个 Reader 的唤醒被系统合并【源码】`Kit/module/reader.swift:222-260`。

**对照我们**：`MacContextObserver` 做到了（`timer.tolerance = 2`，`MacContextObserver.swift:61`），但 `MenuBarPanelController` 的 0.5 s 标签定时器和 `subMinuteWakeTimer` 都没有 tolerance（`MenuBarPanelController.swift:689-712,743-752`），`DualSourceHomeProvider` 的 `DispatchSourceTimer` 也没设 leeway（`DualSourceHomeProvider.swift:106-118`）。

### 2.3 只渲染可见内容：PopupCache

```swift
public func apply(_ value: T, visible: Bool, render: (T) -> Void) {
    self.value = value
    if visible || !self.initialized { render(value); self.initialized = true }
}
```

【源码】`Kit/module/popup.swift:12-33`。不可见时只更新缓存、不碰视图；`prepareForDisplay()` 才 `loadContent()`、`releaseContent()` 释放控件【源码】`Kit/module/popup.swift:58-75`。

**这是“面板关闭后不该有 SwiftUI 重算”的另一种写法。** 我们的做法是 `dropPanelContent()` 把 hosting 树整个丢掉（`MenuBarPanelController+Presentation.swift:162-172`、`MenuBarPanelController.swift:921`），更彻底，但代价是每次打开重建（首帧成本）。这也是我们需要 `layoutSubtreeIfNeeded` + `CATransaction.flush` 才能不漏掉动画前半段的原因（`+Presentation.swift:118-126`）。

### 2.4 状态栏项：把自定义 NSView 塞进 button，自己算宽度

```swift
self.menuBarItem = NSStatusBar.system.statusItem(withLength: self.item.frame.width)
self.menuBarItem?.autosaveName = "\(self.module)_\(self.type.rawValue)"
self.menuBarItem?.button?.addSubview(self.item)
self.menuBarItem?.button?.image = NSImage()
```

【源码】`Kit/module/widget.swift:325-350`；宽度变化时 `item.length = width`【源码】`Kit/module/widget.swift:280-287`，合并且多 widget 时按 `Constants.Widget.spacing` 重算总宽【源码】`Kit/module/widget.swift:468-482`。

`autosaveName` 之外还要手工保存/恢复位置，因为**移除状态栏项会连带删掉 preferredPosition**：

```swift
internal func saveNSStatusItemPosition(id: String) {
    guard let position = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(id)") as? NSNumber else { return }
    Store.shared.set(key: "NSStatusItem Restore Position \(id)", value: position.intValue)
}
```

【源码】`Kit/helpers.swift:1510-1520`。Ice 在 `ControlItem.deinit` 里做同一件事并留了注释【源码】`jordanbaird/Ice:Ice/MenuBar/ControlItem/ControlItem.swift:129-137`。

**对我们的价值**：我们只有一个图标，不做重排，所以不需要这套；但如果将来做“图标位置记忆/隐藏”，这是必须踩过的坑。

### 2.5 更新：NSBackgroundActivityScheduler + 自家 updater（不用 Sparkle）

```swift
internal let updateActivity = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.updateCheck")
...
self.updateActivity.repeats = true
self.updateActivity.interval = 60 * 60 * 24   // oncePerDay
self.updateActivity.schedule { completion in self.checkForNewVersion(); completion(.finished) }
```

【源码】`Stats/AppDelegate.swift:43-45`、`Stats/helpers.swift:117-160`。检查本身还有 10 分钟去重窗口【源码】`Kit/plugins/Updater.swift:84-96`，并支持“silent”模式自动下载安装【源码】`Stats/helpers.swift:196-215`。

**这是我们更新调度最该抄的一条**：`NSBackgroundActivityScheduler` 由系统合并唤醒、感知电量与充电状态，比我们挂在 60 s 循环里的 `checkForUpdatesIfNeeded()`（`HotkeyAndNotificationManager.swift:764`）规范。

### 2.6 持久化：UserDefaults 全量缓存 + 30 s 写节流 + 分钟桶历史

- `Store` 启动时把 `persistentDomain` 整个读进内存字典，读走内存、写同时落 UserDefaults【源码】`Kit/plugins/Store.swift:15-46`。
- `DB.insert` 有 30 s 节流（`force` 可绕过）【源码】`Kit/plugins/DB.swift:132-148`；历史按**分钟桶**合并（加权平均、min/max、count、duration），保留 24 h【源码】`Kit/plugins/DB.swift:157-196`。

**对照我们**：`EnergyHistory` 是同类需求（`Sources/MijiaCore/EnergyHistory.swift`），值得核对是否也做了“分钟桶 + 合并”而不是逐笔写。

---

## 3. jordanbaird/Ice：菜单栏项管理的全部现实

> 只读目的：了解 NSStatusItem 的私有行为边界；我们**不打算**管理他人图标，但 Ice 的“面板何时关、权限怎么要、macOS 升级怎么破”直接适用。

### 3.1 枚举与移动（main 分支，旧方案）

- 枚举靠 CGS 私有 `CGSGetProcessMenuBarWindowList`【源码】`Ice/Bridging/Shims/Private.swift:100-110`、`Ice/Bridging/Bridging.swift:150-190`。
- 移动靠**伪造 ⌘-拖拽的 CGEvent**：事件里除了坐标，还必须写上 `.eventTargetUnixProcessID`、`.windowID`、`.mouseEventWindowUnderMousePointer`，否则接收方收不到；`⌘` 修饰符只加在 `leftMouseDown` 上（`leftMouseUp` 为空）【源码】`Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift:1531-1536,1638-1660`。投递时要“scromble”：先发一个带唯一 `eventSourceUserData` 的空事件触发 tap，再从监听 tap 里把真事件投到目标 pid 的事件队列【源码】`MenuBarItemManager.swift:761-870`。
- 失败重试 5 次，每次先 `wakeUpItem`；移动前后隐藏光标并还原【源码】`MenuBarItemManager.swift:1075-1140`。

这套东西必须 Accessibility 授权，且随系统版本反复失效——所以 `macos-26` 分支把 CGS 桥接整体删掉（`Ice/Bridging/*` 全部 `D`），改成：

- 用公共 `CGWindowList` 拿窗口，另加一个 **XPC 服务** `MenuBarItemService` 专门回答“这个窗口是哪个进程创建的”（`sourcePID`）——因为 Control Center 托管的 extra，窗口 owner 与真正创建者不是同一个 pid【源码】`MenuBarItemServiceConnection.swift:50-88`、`Shared/Services/MenuBarItemService.swift:12-20`。
- 事件投递从“双 tap 互踢”改成“entry/exit 空事件做屏障的顺序投递”【源码】`macos-26:Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift:576-670`。

**结论（对我们的意义）**：如果哪天要做“识别某个菜单栏图标属于哪个 app”，正确做法是 `ownerPID` + XPC 查 `sourcePID`，而不是拿窗口 owner 硬猜。

### 3.2 用“超长分隔条”实现隐藏（自己也被这条坑到）

`ControlItem.Lengths.expanded = 10_000`，隐藏时把分隔条撑到 1 万点，把左侧图标挤出屏幕；显示时回到 `NSStatusItem.variableLength`【源码】`Ice/MenuBar/ControlItem/ControlItem.swift:22-30,150-172`。

为了让分隔条在“不显示分隔条”时仍能当边界，它还要把“状态栏按钮不允许零宽”的那条约束拆掉，代码里直接写了 `FIXME: Find a replacement for this.`【源码】`ControlItem.swift:100-122`。

### 3.3 面板何时关（这段直接可抄）

```swift
Publishers.Merge(
  NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
  NotificationCenter.default.publisher(for: .didChangeScreenParametersNotification))
.sink { [weak self] _ in self?.close() }
```

【源码】`Ice/UI/IceBar/IceBar.swift:52-62`；另外在“菜单栏被系统自动隐藏且控制项窗口离屏”时关闭【源码】`IceBar.swift:70-95`。

面板本身：`styleMask [.nonactivatingPanel, .fullSizeContentView, .borderless]`、`level = .mainMenu + 1`、`hasShadow = false`、`animationBehavior = .none`、`collectionBehavior [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]`【源码】`IceBar.swift:20-40`。

### 3.4 重隐（rehide）与已知 UX 坑

- 三种策略：smart / timed / focusedApp【源码】`Ice/Utilities/RehideStrategy.swift:1-27`；timed 用 event monitor 判断鼠标离开菜单栏区域后才启动计时器【源码】`Ice/MenuBar/MenuBarSection.swift:241-292`（注意：`Timer.scheduledTimer` 没设 tolerance，这段本身也不完美）。
- `FREQUENT_ISSUES.md` 记了三个真实坑：新图标总被塞进 always-hidden（因为 macOS 把新项放在最左）、Ice 会“移除”图标（其实是 macOS 放的）、**开启自动隐藏菜单栏时无法整理菜单栏**（必须临时改成 Never）【文档】`jordanbaird/Ice:FREQUENT_ISSUES.md:1-40`。

**对我们的价值**：最后一条正是 §0 结论 4 的依据——自动隐藏菜单栏时，菜单栏窗口会离屏，任何“按 status item 窗口位置定位”的自绘面板都会失准。

### 3.5 权限与 Sparkle

- 权限对象把“检查/申请/打开设置面板/轮询”封装成统一 `Permission`，必需项 Accessibility，可选项 Screen Recording，UI 分“缺全部/缺可选/全有”三态【源码】`Ice/Permissions/Permission.swift:1-120`、`PermissionsManager.swift:16-40`。
- Sparkle 用法见 §9。

---

## 4. p0deje/Maccy：NSStatusItem + 自定义面板的教科书

### 4.1 面板

```swift
styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView]
level = .statusBar
collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
hidesOnDeactivate = false; animationBehavior = .none
orderFrontRegardless(); makeKey()
```

【源码】`Maccy/FloatingPanel.swift:20-95`。关闭靠 `resignKey()`（而不是全局点击监视）：`if NSApp.alertWindow == nil && !AppState.shared.suppressPopupAutoClose { close() }`【源码】`FloatingPanel.swift:208-216`，并要求 `canBecomeKey = true` 才能让搜索框拿焦点【源码】`FloatingPanel.swift:231-234`。

**与我们对比**：`resignKey` 方案代码最少，但处理不了“点击菜单栏图标本身时既要关闭又要 toggle”的时序——这正是我们需要 `suppressStatusItemReopenUntil = 0.35` + 事件号比对的根本原因（`MenuBarPanelController.swift:65`、`1191-1210`）。Maccy 之所以能用最简方案，是因为它用全局热键调出、不常驻菜单栏图标交互。

### 4.2 位置持久化（多屏正确）

窗口位置按**屏幕可视区比例**存，不存绝对坐标：

```swift
let anchorX = frame.minX + width/2 - screenFrame.minX
let anchorY = frame.maxY - screenFrame.minY
Defaults[.windowPosition] = NSPoint(x: anchorX/screenFrame.width, y: anchorY/screenFrame.height)
```

【源码】`Maccy/FloatingPanel.swift:127-134`；屏幕选择是用户偏好索引，越界回退 `NSScreen.main`【源码】`Maccy/Extensions/NSScreen+ForPopup.swift:5-12`；`statusItem` 形态定位后还会 `constrained()` 夹到该屏可视区，避免跨屏溢出【源码】`Maccy/PopupPosition.swift:33-72`。

### 4.3 搜索性能

- Fuse 模糊匹配，`threshold: 0.7`（注释：试出来的）【源码】`Maccy/Search.swift:36`。
- 超长文本先截断到 5 000 字符再模糊匹配【源码】`Search.swift:37,70-76`。
- 四种模式，`mixed` = 先精确、无结果再模糊【源码】`Search.swift:40-52`。
- 输入节流 0.2 s（自实现 Throttler，用 DispatchWorkItem + 上次执行时间）【源码】`Maccy/Observables/History.swift:40,73`、`Maccy/Throttler.swift:16-33`。

**对我们的价值**：我们的 `PanelSearchState`（面板内搜索）与 Settings 搜索若用 SwiftUI `onChange` 直接过滤，输入快时会每键一次全量计算。0.2 s 节流 + 模式降级是很低成本的改进。

### 4.4 存储

SwiftData，落 `~/Library/Application Support/Maccy/Storage.sqlite`；启动时清理“孤儿内容”（`HistoryItemContent.item == nil`）与“不可持久化的粘贴板类型”【源码】`Maccy/Storage.swift:5-80`。

---

## 5. leits/MeetingBar：刷新管线与“设置即触发器”

### 5.1 刷新管线（可直接照搬的结构）

```swift
let trigger = Publishers.Merge3(defaultsPub, timerPub, manualPub)
    .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: false)
trigger.flatMap(maxPublishers: .max(1)) { ... }   // 一次只跑一个刷新
```

- `Timer.publish(every: refreshInterval)`，默认 **180 s**【源码】`MeetingBar/Calendar/CalendarSync.swift:69,236-244`。
- 设置变化（`Defaults.publisher(keys: ...)`）也当触发器，一次改多个键被 throttle 合成一次【源码】`CalendarSync.swift:227-258`。
- 整个刷新环有 **120 s 超时**，理由写在注释里：串行化后，一个永不结束的刷新会永久堵死后续所有触发（定时器、改设置、手动按钮）【源码】`CalendarSync.swift:58-66,190-205`。
- provider 切换用 generation 计数丢弃过期结果，超时/取消不覆盖现有数据【源码】`CalendarSync.swift:38-52,86-110`。

**对照我们**：`DualSourceHomeProvider` + `HomeStore+Resume` 已有“合并恢复、代次丢弃”的思路（`DebouncedResumeCoordinator.swift`、`HomeStore+Resume.swift:83-130`），但对“单次轮询超时”没有统一上限。Mi 云请求卡住时是否会拖慢后续轮询，值得在 provider 层加一个与 MeetingBar 同款的 per-cycle 超时。

### 5.2 菜单构建

`updateMenu()` 先 `if statusItem.menu != nil { return }`（打开时不动），再 `removeAllItems()` 全量重建，`autoenablesItems = false` 精确控制启用态【源码】`StatusBarItemController.swift:316-356`。菜单状态由纯值 `StatusBarMenuState.make(from:)` 计算、`MenuBuilder` 纯构建，测试可直接断言【源码】`MeetingBar/UI/StatusBar/StatusBarMenuState.swift`、`MenuBuilder.swift:1-40`。

**这和我们 `StatusItemEventDecision` 的思路一致：把决策与副作用分离。值得作为团队规范固化。**

### 5.3 我们该学的最后一点

`Defaults.publisher(keys:)` 让“改了哪个键就只重算对应视图”，而不是监听 `UserDefaults.didChangeNotification` 全量刷新。我们用 `WatchedPreferences` 做了等价物（`MenuBarPanelController.swift:140-155`），但对 Settings 窗口内的很多开关仍可能是全量 `objectWillChange`。

---

## 6. dwarvesf/hidden（Hidden Bar）：隐藏机制的三代演进与硬件边界

### 6.1 已知硬上限与多屏陷阱

```swift
// The menubar replicates across every attached display, so the collapse
// length must cover the WIDEST screen, not NSScreen.main (the focused one)
let screenWidth = screenWidths().max() ?? 1728
return max(500, min(screenWidth * 2, 10_000))   // macOS 硬上限 10 000 pt
```

【源码】`hidden/Features/StatusBar/Engine/LegacyLengthEngine.swift:68-76`。还有“折叠后下一轮 runloop 验证分隔条真的变宽了没有”的自检，失败则降级（`verifyHideMechanismIfNeeded`，同文件 126-140）。

### 6.2 macOS 27 的两条断点

- 10 000 pt 分隔条被系统“挤出”菜单栏（#360）→ 需要另一条路【源码】`MenuBarEngineFactory.swift:23-30`。
- 新路是私有框架 `MenuBarClientCore.framework` 的**评估模式（考试锁定）允许列表**：`MBAssessmentModeConfiguration(allowedSystemItems:allowedBundleIdentifiers:)` + `MBAssessmentModeAssertion.activateWithConfiguration:completionHandler:`，用 `dlopen` + `objc_msgSend` 动态调用，缺失即降级【源码】`hidden/Features/StatusBar/Engine/Native/HBNativeVisibilityShim.m:22-70`。

代价（作者逐条实测写在注释里，非常值得一读）：只支持“按 app”隐藏；系统项（时钟/Wi-Fi/控制中心）不能隐藏；**评估模式会让系统忽略时钟点击**，所以点时钟得临时抬升限制、替它按一下再降回去；还会隐藏“某 app 正在使用麦克风/摄像头”的胶囊提示【源码】`hidden/Features/StatusBar/Engine/NativeVisibilityEngine.swift:22-70`。

**对我们的意义**：这是一条**明确不走**的路（私有框架 + 会改变系统行为）。记录它只是为了：① 判断第三方“菜单栏整理”类工具在 macOS 27 上的可靠性；② 若用户反馈我们图标被这类工具隐藏后异常，知道原因。

### 6.3 刘海几何（可直接用的两个 API）

```swift
let hasNotch = screen.safeAreaInsets.top > 0
let thresholdX = screen.auxiliaryTopRightArea?.minX   // Apple 给的“安全区右边界”
```

【源码】`hidden/Features/NotchOverflow/NotchOverflowController.swift:44-58`。

**对照我们**：全仓没有任何 `safeAreaInsets` / `auxiliaryTopRightArea` 使用（`grep` 结果仅一处注释提到 notched wheel）。我们靠 `visibleFrame` 夹取，在刘海屏上 `visibleFrame.maxY` 已经在刘海下方，因此**面板顶边不会钻进刘海**——这一点是对的；但**菜单栏图标过多时我们的图标可能被挤到刘海下**，此时 `statusItem.button.window.frame` 仍是屏幕坐标，面板会出现在“图标看不见的位置”。低成本对策见 §11。

---

## 7. steipete/CodexBar：把“省电”和“可观测”当一等公民

### 7.1 自适应刷新（纯函数决策表）

| 距上次开面板 | 间隔 |
| --- | --- |
| ≤ 5 min | 2 min |
| ≤ 60 min | 5 min |
| < 4 h | 15 min |
| ≥ 4 h（含从未打开） | 30 min |
| 低电量 / 热压力 serious+ | 30 min |
| 最近 5 min 有编码活动 | 上限 5 min |

【源码】`Sources/AdaptiveRefreshCore/AdaptiveRefreshPolicyCore.swift:52-105`。策略是 `struct` + `Input` 纯值，因此可用离线回放工具回归（`Sources/AdaptiveReplayKit`）。

另有兜底：低电量时任何自动间隔不得小于 30 min【源码】`Sources/CodexBar/BackgroundWorkPowerPolicy.swift:3-14`。

### 7.2 内存与卡顿

- `DispatchSourceMemoryPressure` 监听内存压力 → 裁掉可重建缓存（菜单卡高度、宽度、复用的视图等），并 `malloc_zone_pressure_relief` 归还空闲页【源码】`Sources/CodexBar/MemoryPressureMonitor.swift:44-80`、`MemoryPressureRelief`。
- 主线程看门狗：定时 ping 主队列，超过阈值就异步 `sample` 本进程（避免采样本身拖慢恢复），并带“面包屑”记录当时在干什么【源码】`Sources/CodexBar/MainThreadHangWatchdog.swift:1-90`。
- 需要保证会话存活时才取 IOPM assertion（`kIOPMAssertPreventUserIdleSystemSleep`），而不是全程持有【源码】`Sources/CodexBar/AgentSessionPowerAssertion.swift:4-18`。

### 7.3 形态选择

仍然是 `NSMenu` + 菜单内嵌 SwiftUI 视图（文件头注释：“AppKit-hosted icons, SwiftUI popovers”，`Sources/CodexBar/StatusItem/StatusItemController.swift:8`），并为此付出大量“菜单重建最小化”的复杂度（`menuContentVersion`、readiness 签名、仅在菜单打开时重建，`StatusItemController+MenuRefreshScheduling.swift:1-80`）。

**这反证了我们的选择**：如果我们用 NSMenu，就要写这套几百行的重建节流；自绘面板反而是更短的路——前提是把 §1 表里那四件事做对（我们做了）。

### 7.4 更新

Sparkle 2.10.1，`UpdaterProviding` 抽象 + debug/非 bundle 运行时的 no-op updater，避免调试时弹 Sparkle 窗口【源码】`Package.swift:47`、`Sources/CodexBar/CodexbarApp.swift:180-260`。

---

## 8. 小件库与两个小应用

### 8.1 KeyboardShortcuts（我们已在用 Carbon，可补两块）

- 底层仍是 Carbon `RegisterEventHotKey`，但加了 `HotKeyCenter` 统一路由，并有一个 **menuOpen 模式**：菜单跟踪期间 Carbon 热键收不到，改用 `RunLoopLocalEventMonitor(events: [.keyDown, .keyUp], runLoopMode: .eventTracking)` 走原始键事件【源码】`sindresorhus/KeyboardShortcuts:Sources/KeyboardShortcuts/HotKey.swift:60-140`。
- 注册失败（组合已被别的 app 占用）有明确回调 `onRegistrationFailed`，并文档化“Carbon 同一组合只能注册一次”【源码】`HotKey.swift:14-20,44-50`。

**对照我们**：`HotkeyAndNotificationManager` 用 Carbon + 本地 `keyDown/keyUp/flagsChanged` 三个 monitor 实现了按住说话（`HotkeyAndNotificationManager.swift:300-350`）。缺的是“注册失败/冲突”的显式 UI 反馈（`HotkeySettingsState` 里有 disabled 状态，但没有“被别的 app 占用”这一态）——低成本可补。

### 8.2 LaunchAtLogin-Modern（一个真实细节）

```swift
if newValue {
    if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
    try SMAppService.mainApp.register()
}
```

【源码】`sindresorhus/LaunchAtLogin-Modern:LaunchAtLogin.swift:20-33`。先注销再注册，是为了让登录项记录跟随 app 的新路径（app 被移动后尤其重要）。另外 `wasLaunchedAtLogin` 用 AppleEvent `keyAELaunchedAsLogInItem` 判断【源码】同文件 `38-46`。

**对照我们**：`SystemLaunchAtLogin` 只做 register/unregister，没有“路径变化后刷新注册”的处理（`LaunchAtLoginLive.swift:1-37`）。若用户把 app 从 Downloads 拖到 /Applications，登录项可能失效——值得在启动时检测一次 bundle 路径变化。

### 8.3 Itsycal：分钟边界定时器与单调时钟（我们 subMinuteWakeTimer 的教科书版本）

- 每次都只排一个**一次性**定时器，落在“下一个整分/整秒”（`nextDateAfterDate:matchingComponents:`），触发后重排——自我纠偏，不累积漂移【源码】`sfsam/Itsycal:Itsycal/ViewController.m:1491-1501`。
- 倒计时用**单调时钟**存 deadline（`MonotonicClockTime()`），睡眠期间照常计时，唤醒后重排；另外监听 `NSWorkspaceDidWakeNotification` 重排、`NSSystemClockDidChangeNotification` 重存日期【源码】`Itsycal/MenuTimer.m:12-80`。
- 为了不让 App Nap / 空闲睡眠推迟 deadline，仅在计时器运行期间取 `beginActivityWithOptions:NSActivityUserInitiated`【源码】`MenuTimer.m:160-170`。
- 迟到超过 10 s 就不再响（`kLateAlarmGrace`），避免睡醒后突然报警【源码】`MenuTimer.m:14-20`。

**对照我们**：`subMinuteWakeTimer` 是 `nextFire - now - 60` 的一次性定时器（`MenuBarPanelController.swift:700-712`），思路正确，但没有 tolerance、也没处理“睡眠跨越”场景（`Task.sleep` 与 `Timer` 睡眠期间行为不同，我们的定时器在睡眠期间不推进，唤醒后可能立即触发一次——需要用 `systemUptime` 二次校验）。

### 8.4 AlDente：反面教材

- `NSPopover(behavior: .transient)` + `NSStatusItem.squareLength`，最小实现【源码】`AppHouseKitchen/AlDente-Charge-Limiter:AlDente/AppDelegate.swift:54-60`。
- 启动时**强制** `LaunchAtLogin.isEnabled = true`【源码】同文件 `69`——不该学。
- 5 s 重复 `Timer` 无条件轮询电池信息【源码】同文件 `84-95`——菜单栏常驻应用的空闲成本大头。
- 特权 helper 仍是 `SMJobBless`（已被 `SMAppService.daemon` 取代）【源码】`AlDente/Helper.swift:179`。

---

## 9. Sparkle 2 vs 我们的 Ed25519 自更新

| 维度 | Sparkle 2 | 我们（`Sources/MijiaCore/UpdateChecker.swift`） |
| --- | --- | --- |
| 元数据 | appcast.xml（RSS），`SPUFeedURL` | GitHub Releases API `releases/latest`（`UpdateChecker.swift:428`）+ 自有清单 |
| 签名 | EdDSA(Ed25519) 签名 + 归档解包校验；Apple 代码签名只当“备份校验”，并要求同 Team ID【文档】`sparkle-project/Sparkle:Documentation/Security.md:40-46` | Ed25519 清单签名 + SHA256 + 暂存 app 校验（`UpdateSignature.swift`、`VerifiedStagedApp`） |
| 调度 | 默认 1 天，最小间隔可配；上次检查时间持久化；schedule 时回调 delegate【源码】`Sparkle/SPUUpdaterSettings.m:403-413`、`SPUUpdater.m:511-560` | 6 h 固定（`HomeStore.swift:909`），检查挂在 60 s 循环上（`HotkeyAndNotificationManager.swift:764`），无抖动 |
| 分阶段放量 | `sparkle:phasedRolloutInterval` × 用户分组，未到的组不算“有更新”【源码】`Sparkle/SUAppcastDriver.m:657-670` | 无 |
| 用户提示 | 应用活跃就弹窗，不活跃只发通知；`supportsGentleScheduledUpdateReminders` 让“自动下载完成”不再打扰【源码】`jordanbaird/Ice:Ice/Updates/UpdatesManager.swift:96-145` | 面板/设置里的状态机 `AppUpdateState`（`.available`/`.readyToRelaunch`…）+ toast，无系统通知 |
| 安装 | 独立 installer agent + launchd，privilege separation（不再用 `AuthorizationExecuteWithPrivileges`）【文档】`Security.md:30-40` | 就地暂存 + 校验 + 替换 + 重启，带 relaunch watchdog（`UpdateChecker.swift`，`HomeStore+Update.swift:240-250`） |

**判断**：我们已经具备 Sparkle 的核心安全属性（Ed25519 + 摘要 + 暂存校验），不必引入 Sparkle（会带 XPC/launcher/Info.plist 配置与签名要求，成本 L）。值得偷的是三件小事：

1. **调度**换成 `NSBackgroundActivityScheduler`（系统合并唤醒，见 §2.5），并把 6 h 间隔加 0–30 min 抖动，避免全体用户在同一个整点打 GitHub API（未认证 60 次/小时的配额对少量用户无碍，但集中请求会 403）。
2. **分阶段放量**：清单里加 `rolloutPercentage`，客户端用安装 ID 的稳定哈希取模决定“这次算不算有更新”。成本 S（清单解析 + 一个纯函数），价值是坏版本只影响一部分人。
3. **温和提醒**：应用不活跃时不弹面板，只发一条通知；用户在处理别的窗口时被打断是 Sparkle 明确优化掉的体验。

---

## 10. 横向机制表（一屏看完对照组怎么做）

| 机制 | Stats | Ice | Maccy | MeetingBar | CodexBar | 我们 |
| --- | --- | --- | --- | --- | --- | --- |
| 采集定时器 | `DispatchSourceTimer` + 200 ms leeway，可对齐秒边界 | 无持续采集 | 无 | Combine `Timer.publish`（无 tolerance） | `Task`/timer + 自适应间隔 | `DispatchSourceTimer`（无 leeway）+ `Task.sleep` 循环 |
| 定时器 tolerance | 显式 200 ms | rehide timer 未设 | — | 未设 | 间隔自适应 | 仅 `MacContextObserver` 设 2 s |
| 空闲成本控制 | “可见消费者”驱动 lock/unlock/pause | 面板关即停 | 面板关即停（`resignKey`） | 180 s 刷新 + 120 s 超时 | 4 档衰减 + 低电量下限 30 min | 3 档（6/60/180 s）+ 睡眠即停 |
| 面板关闭 | `windowDidResignKey`（可拖动锁） | 空间/屏幕变化/菜单栏隐藏 | `resignKey` + `alertWindow` 例外 | 系统菜单 | 系统菜单 | 全局+本地点击监视 + 失活 + 事件号抑制窗口 |
| 面板层级 | `NSPanel`（`.nonactivatingPanel`） | `.mainMenu + 1` | `.statusBar` | — | — | `.statusBar` |
| 多显示器 | 按 widget 所在窗口 | 每屏一个 `NSStatusBarWindow`（replicant） | 位置按屏比例存 + 屏索引偏好 | 单屏假设 | 单屏假设 | 按 status item 所在屏，但多处 `NSScreen.main` 兜底 |
| 刘海 | 无处理 | 目标 macOS 14+，未处理 | 未处理 | 未处理 | 未处理 | 未处理（靠 `visibleFrame` 间接回避） |
| 权限 | 无（读 SMC 需 helper） | AX 必需 + 录屏可选 + 1 s 轮询 | AX（粘贴事件） | 日历 | 无 | 通知/麦克风/语音/日历/位置/专注，全部 TCC |
| 崩溃/卡顿 | 无专门机制 | 无 | 无 | 无 | 主线程看门狗 + 内存压力 + 面包屑 | 20 条错误时间戳环形缓冲 |
| 更新 | 自家 updater + `NSBackgroundActivityScheduler` | Sparkle 2 | Sparkle 2 | 无 | Sparkle 2.10.1 | 自研 Ed25519 |

---

## 11. 对照我们：差距表

| 我们的文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `Sources/MenuBarMijiaApp/MenuBarPanelController.swift:743-752` | 标签定时器 0.5 s 重复、无 tolerance；仅在语音/撤销条/60 s 内有定时任务时运行 | Stats `Repeater` 200 ms leeway；Itsycal 一次性对齐下一分钟 | 加 `tolerance = 0.1`；把“撤销条倒计时”改用 `TimelineView` 或 0.25 s→1 s；语音转录改为事件驱动（`SpeechInputController` 已有 draft 变更回调） | S |
| `MenuBarPanelController.swift:689-712` | `subMinuteWakeTimer` 用 `Timer`，无 tolerance，不处理跨睡眠 | Itsycal 单调时钟 + 唤醒重排 + 迟到宽限 | 用 `ProcessInfo.systemUptime` 校验触发时刻；`tolerance = 1`；监听 `NSWorkspace.didWakeNotification` 后重算 | S |
| `HotkeyAndNotificationManager.swift:730-767` | `enableSafetyAlerts`、`enableWeeklyHealthReport`、`automaticallyChecksForUpdates` 任一为真就跑 60 s 循环（默认全真 → 永久 60 s 唤醒） | CodexBar 按“下一次需要做什么”算延迟；Stats 用 `NSBackgroundActivityScheduler` 做更新 | 拆成两个：① 事件驱动的“下一告警/报表时刻”（`DispatchSourceTimer` + 200 ms leeway，`schedule(deadline:)` 单次）；② 更新检查改用 `NSBackgroundActivityScheduler`，6 h + 抖动 | M |
| `Sources/MijiaCore/PollingPolicy.swift:19-48` | 三档：面板开 6 s / 关 60 s / 低电 180 s；睡眠即停 | CodexBar 四档按“最近交互”衰减（2/5/15/30 min） | 增加 `lastPanelOpenAt`、`lastControlAt` 两个输入，闭面板后 15 min 内保持 60 s → 之后 180 s → 低电 300 s；`PollingContext` 加字段即可，测试已在 `Tests/MijiaCoreTests` | S/M |
| `MenuBarPanelController+Presentation.swift:437-460`、`401` | `classicFrame` 用 `anchor.minY` 但 `y = max(top - height - topGap, visible.minY+margin)`；`NSScreen.main` 兜底 | Ice 在菜单栏自动隐藏/离屏时直接关闭面板；Maccy 用 `constrained()` 夹屏 | ① 用 `NSApp.currentSystemPresentationOptions` 检测 `.autoHideMenuBar`/`.hideMenuBar`，此时改为“贴屏幕右侧固定位置”；② 去掉 `NSScreen.main` 兜底，status item 无窗口时就不显示 | S |
| 同上（空间切换） | 未监听 `NSWorkspace.activeSpaceDidChangeNotification` | Ice/IceBar 在空间变化时关闭 | 面板可见时才监听，空间变化即 `hidePanel(animated: false)`（避免面板跟随到另一个桌面留下残影） | S |
| 刘海/图标被挤出 | 无 `safeAreaInsets` / `auxiliaryTopRightArea` 使用 | Hidden Bar 的 `NotchBoundary` 纯几何 | 计算 `anchor.minX < screen.auxiliaryTopRightArea?.minX` 时，把面板改为右对齐屏幕（而不是居中对齐图标） | S |
| 多显示器 | `CameraLivePanelController.swift:348,1371` 用 `NSScreen.main` | Maccy 屏索引偏好 + 比例坐标 | 统一走“宿主窗口所在屏 → 首个屏”的取屏 helper，禁止 `NSScreen.main` 兜底 | S |
| `Sources/MenuBarMijiaApp/AppDiagnosticsLog.swift` | 只存 20 条错误时间戳 | CodexBar 主线程看门狗 + `sample` + 面包屑 | 加简化版：主队列 ping 每 2 s，>1 s 记一条“卡顿”（含时长与当前 `PanelKeyRouter`/`HomeStore` 写入标签），仅当“诊断模式”开启时 `sample` 本进程 | M |
| `Sources/MijiaCore/HomeStore+Update.swift:21-35`、`HomeStore.swift:909` | 6 h 固定间隔，检查挂在 60 s 循环 | Sparkle 1 天 + 最小间隔 + 分阶段放量 + 温和提醒 | 抖动 + `NSBackgroundActivityScheduler` + 清单加 `rolloutPercentage` + 不活跃时改发通知 | M |
| `Sources/MenuBarMijiaApp/LaunchAtLoginLive.swift` | 只 register/unregister | LaunchAtLogin-Modern 先注销再注册以跟随路径 | 启动时比对上次记录的 bundle 路径，变化则重注册；`requiresApproval` 已处理 ✓（`LaunchAtLogin.swift:46-52`） | S |
| `HotkeyAndNotificationManager.swift:300-350` | Carbon + 三个本地 monitor | KeyboardShortcuts 的“已占用”回调 + menuOpen 模式 | 补注册失败态并在设置里显示“该快捷键已被其他应用占用” | S |
| 面板内搜索 / Settings 搜索 | SwiftUI 直接按输入过滤 | Maccy 0.2 s 节流 + 精确优先的 mixed 模式 | 加 0.2 s 节流；模糊匹配前截断长文本 | S |
| `MenuBarPanelController.swift:768-799` | 值不变不写（已做 ✓） | Stats 在 macOS 26 swizzle 抑制 tiling 约束同步 | 先验证：`/usr/bin/log stream --predicate 'eventMessage CONTAINS "_CGXPackagesSetWindowConstraints"'`，确认有该日志再决定是否值得跟（不建议上 swizzle，风险高于收益） | S（仅验证） |
| 权限引导 | 通知有拒绝态引导（`HotkeyAndNotificationManager.swift:694-706`）；麦克风/语音/日历/位置只有请求，无拒绝后的说明入口 | Ice 的 `Permission` 统一对象 + 设置页总览 | 在 Settings 加一张“权限体检”卡：逐项显示 已授权/已拒绝/未请求 + “打开系统设置”按钮（`x-apple.systempreferences:com.apple.preference.security?Privacy_*`） | M |
| 首启引导 | `OnboardingGuideView` 四步（选平台/连米家/连 HA/完成） | Ice 的 PermissionsWindow（必需/可选两级） | 在“完成”步骤前插入“权限与常驻设置”一页（通知、开机启动、菜单栏显示文本），复用现有 checklist 卡 | M |

---

## 12. 推进清单

| # | 标题 | 价值 | 成本 | 优先级 | 高风险面 | 依据 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 给两个自绘定时器加 tolerance（标签 0.5 s、subMinuteWake） | 直接降低空闲唤醒与主线程抖动 | S | P0 | 否 | §2.2、§8.3；`MenuBarPanelController.swift:743-752,689-712` |
| 2 | 把 60 s 安全/更新循环改成“算下一次时刻”的单次调度 | 去掉永久 60 s 唤醒（默认配置下每个用户都受影响） | M | P0 | 否（涉及通知时机，需回归 `ScheduledCommand`/安全告警） | §2.5、§7.1、§8.3；`HotkeyAndNotificationManager.swift:730-767` |
| 3 | `PollingPolicy` 增加“久未交互”衰减档 | 夜间/挂机场景网络与电量开销明显下降 | S | P0 | 否 | §7.1；`PollingPolicy.swift:19-48` |
| 4 | 面板定位：检测自动隐藏菜单栏 + 去掉 `NSScreen.main` 兜底 + 刘海右对齐 | 修 3 个可稳定复现的“面板出现在错误位置” | S | P0 | 否（纯 UI 定位） | §3.3、§6.3；`+Presentation.swift:401,437-460` |
| 5 | 空间切换即关闭面板 | 修“切桌面后残留可交互空面板” | S | P1 | 否 | §3.3；`IceBar.swift:52-62` |
| 6 | 更新：`NSBackgroundActivityScheduler` + 抖动 + 分阶段放量 + 温和提醒 | 降低集中请求风险、坏版本可控 | M | P1 | 是（`UpdateChecker.swift` 属“自动更新”高风险面，需 PR） | §9 |
| 7 | 主线程卡顿看门狗（诊断模式） | 把“用户说卡”变成可读数据 | M | P1 | 否 | §7.2；`AppDiagnosticsLog.swift` |
| 8 | 设置页“权限体检”卡 | 减少“为什么没有通知/麦克风不说话”的困惑 | M | P1 | 否 | §3.5；`HotkeyAndNotificationManager.swift:694-706` |
| 9 | 热键“已被占用”状态 | 修静默失效 | S | P1 | 否 | §8.1 |
| 10 | 搜索 0.2 s 节流 + 长文本截断 | 输入流畅度 | S | P2 | 否 | §4.3 |
| 11 | 登录项路径变化后重注册 | 修“app 换位置后开机不自启” | S | P2 | 是（登录项属凭据/系统边界相邻，按 AGENTS.md 走 PR 更稳） | §8.2 |
| 12 | 首启引导插入权限页 | 首次体验闭环 | M | P2 | 否 | §3.5、§11 |
| 13 | 验证 macOS 26 tiling constraint 日志是否影响我们 | 决定是否需要额外规避 | S | P3 | 否 | §2.6、§0 结论 6 |
| 14 | 面板首帧优化（复用 hosting 树 vs 每次重建） | 打开手感 | L | P3 | 否 | §2.3 |

---

## 13. 设想（天马行空，与现有 ADR 无关或冲突会注明）

1. **菜单栏迷你趋势图**：像 Stats 那样把自定义 `NSView` 塞进 `statusItem.button`，直接画 24 h 能耗/温度 sparkline（`Kit/module/widget.swift:325-350` 的做法）。成本 M；风险是我们要放弃 `attributedTitle` 的电量/文本布局，且 macOS 26 的布局同步问题会放大。**不与任何 ADR 冲突**。
2. **分阶段放量 + 回滚阈值**：`UpdateManifest` 增加 `rolloutPercentage` 与 `minimumSuccessfulLaunches`（客户端下次启动成功才上报/继续放量）。需要服务端有统计，我们目前只有 GitHub Releases，可以用“用户端本地计数 + 不可用时静默跳过”实现纯客户端版本。**与 `docs/adr` 无冲突**，但与 `release.sh` 流程有改动。
3. **“隐身模式”**：借用 Hidden Bar 的私有 `MBAssessmentModeConfiguration` 只保留我们的图标（演示/专注场景）。**与 ADR-0020（否决进程内第三方代码）无关，但与项目“不使用私有 API 改变系统行为”的既有取向冲突**，列为不建议。
4. **把面板渲染搬到独立进程**（对付 SwiftUI 首帧抖动）：成本 L，收益不明显，**不建议**。
5. **本地“菜单栏预算”诊断**：在 About 页显示“本次启动以来状态栏写入次数 / 定时器唤醒次数 / 面板重建次数”，用 `os_signpost` 采集。这是把 §10 表格变成我们自己的长期指标，成本 S。**推荐作为 P2 落地**。

---

## 14. 来源清单

**源码（本地浅克隆，`~/.cache/mbh-research-clones/`）**

- `exelban/stats` @ `f47dca1`（2026-11-22）：`Kit/plugins/Repeater.swift:37-46`、`Kit/module/reader.swift:44-53,156-260`、`Kit/module/module.swift:298-333`、`Kit/module/popup.swift:12-33,118-160`、`Kit/module/widget.swift:280-350,468-482`、`Kit/helpers.swift:1510-1520`、`Kit/plugins/Store.swift:15-46`、`Kit/plugins/DB.swift:132-196`、`Kit/plugins/Updater.swift:84-96`、`Stats/AppDelegate.swift:43-45`、`Stats/helpers.swift:117-160,384-403`。
- `jordanbaird/Ice` @ `main 11edd39`（2025-09-20）与 `macos-26 6d74d25`（2026）：`Ice/Bridging/Shims/Private.swift:100-110`、`Ice/Bridging/Bridging.swift:150-190`、`Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift:761-870,985-1140`、`Ice/MenuBar/ControlItem/ControlItem.swift:22-30,100-172`、`Ice/MenuBar/MenuBarSection.swift:241-292`、`Ice/UI/IceBar/IceBar.swift:20-95`、`Ice/Permissions/Permission.swift:1-120`、`Ice/Permissions/PermissionsManager.swift:16-40`、`Ice/Updates/UpdatesManager.swift:96-145`、`Ice/Utilities/RehideStrategy.swift:1-27`、`FREQUENT_ISSUES.md:1-40`；分支侧：`Ice/MenuBar/MenuBarItems/MenuBarItemServiceConnection.swift:20-90`、`Shared/Services/MenuBarItemService.swift:1-25`、`macos-26:Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift:576-670`。
- `p0deje/Maccy` @ `e24f997`（2026-11-23）：`Maccy/FloatingPanel.swift:20-135,208-234`、`Maccy/PopupPosition.swift:33-72`、`Maccy/Extensions/NSScreen+ForPopup.swift:5-12`、`Maccy/Search.swift:36-76`、`Maccy/Throttler.swift:16-33`、`Maccy/Observables/History.swift:40,73`、`Maccy/Storage.swift:5-80`、`Maccy/SoftwareUpdater.swift:1-40`。
- `leits/MeetingBar` @ `c8deee4`（2026-11-16）：`MeetingBar/Calendar/CalendarSync.swift:45-110,190-300`、`MeetingBar/UI/StatusBar/StatusBarItemController.swift:60-120,316-356`、`MeetingBar/UI/StatusBar/MenuBuilder.swift`。
- `dwarvesf/hidden` @ `b10f93d`（2026-11-23）：`hidden/Features/StatusBar/Engine/LegacyLengthEngine.swift:60-140`、`hidden/Features/StatusBar/Engine/MenuBarEngineFactory.swift:14-40`、`hidden/Features/StatusBar/Engine/NativeVisibilityEngine.swift:10-75`、`hidden/Features/StatusBar/Engine/Native/HBNativeVisibilityShim.m:22-80`、`hidden/Features/NotchOverflow/NotchOverflowController.swift:36-62`。
- `steipete/CodexBar` @ `a26ca57`（2026-11-21）：`Sources/AdaptiveRefreshCore/AdaptiveRefreshPolicyCore.swift:40-110`、`Sources/CodexBar/BackgroundWorkPowerPolicy.swift:1-15`、`Sources/CodexBar/MemoryPressureMonitor.swift:44-80`、`Sources/CodexBar/MainThreadHangWatchdog.swift:1-90`、`Sources/CodexBar/AgentSessionPowerAssertion.swift:1-20`、`Sources/CodexBar/StatusItem/StatusItemController.swift:8-60`、`Sources/CodexBar/CodexbarApp.swift:180-270`、`Package.swift:47`。
- `sfsam/Itsycal`（2026-11-13）：`Itsycal/MenuTimer.m:12-80,160-175`、`Itsycal/ViewController.m:1491-1501`。
- `AppHouseKitchen/AlDente-Charge-Limiter` @ `8b93da2`（2026-10-08）：`AlDente/AppDelegate.swift:54-95`、`AlDente/Helper.swift:179`。
- `sindresorhus/KeyboardShortcuts` @ `772133d`（2026-09-12）：`Sources/KeyboardShortcuts/HotKey.swift:14-50,60-140`。
- `sindresorhus/LaunchAtLogin-Modern`：`LaunchAtLogin.swift:20-46`。
- `orchetect/MenuBarExtraAccess` @ `e93e3a5`（2026-08-05）：`README.md:60-66`、`Sources/MenuBarExtraAccess/MenuBarExtraUtils/MenuBarExtraUtils.swift:68-120`、`Sources/MenuBarExtraAccess/NSWindow Extensions.swift:12-18`、`Sources/MenuBarExtraAccess/NSStatusItem+ExpandedInterfaceSession.swift:14-130`。
- `sparkle-project/Sparkle` @ `b7debdb`（2026-11-20）：`Documentation/Security.md:1-50`、`Sparkle/SPUUpdaterSettings.m:377-430`、`Sparkle/SPUUpdater.m:511-560`、`Sparkle/SUAppcastDriver.m:657-670`。

**我们仓库**

- `Sources/MenuBarMijiaApp/MenuBarPanelController.swift`、`MenuBarPanelController+Presentation.swift`、`PanelKeyRouter.swift`、`StatusItemEventDecision.swift`、`HotkeyAndNotificationManager.swift`、`LaunchAtLoginLive.swift`、`MacContextObserver.swift`、`AppDiagnosticsLog.swift`、`SystemActivityMonitor.swift`、`CameraLivePanelController.swift`、`MenuBarMijiaApp.swift`。
- `Sources/MijiaCore/PollingPolicy.swift`、`HomeStore.swift`、`HomeStore+Update.swift`、`UpdateChecker.swift`、`LaunchAtLogin.swift`、`DualSourceHomeProvider.swift`、`HomeStore+Resume.swift`。
- `scripts/build_app.sh:260-330`（Info.plist 与用法描述）。

**未查到 / 未能验证**

- `AppHouseKitchen/AlDente-Charge-Limiter` 与 `dwarvesf/hidden` 的 GitHub star 数：本次 API 匿名配额耗尽，返回 `null`，故报告不引用星数。
- 我们对 macOS 26 `_CGXPackagesSetWindowConstraints: Invalid window` 日志的实际暴露情况：需要在本机用 `log stream` 实测，报告未断言。
- Why `jordanbaird/Ice` main 分支停在 2025-09：只确认了远端存在 `macos-26`、`macos-26-old`、`profiles` 分支且 `macos-26` 有新提交，未确认维护者公开说明（无文档依据）。

---

## 摘要

1. **最该马上改的是两处定时器**：状态栏 0.5 s 标签定时器与默认永久运行的 60 s 安全/更新循环，加 tolerance 或改成“算下一次时刻”，空闲唤醒立刻下降（成本 S）。
2. **轮询加“久未交互”衰减档**：照 CodexBar 的四档表把 `PollingPolicy` 从 3 档扩到 5 档，纯策略改动、测试可覆盖（成本 S）。
3. **面板定位补三条兜底**：自动隐藏菜单栏、刘海右对齐、去掉 `NSScreen.main`，都是一行判断能修的可见 bug（成本 S）。
4. 更新链路建议只偷 Sparkle 的调度与放量（`NSBackgroundActivityScheduler` + 抖动 + `rolloutPercentage`），不引入 Sparkle 本体（成本 M）。
5. 报告路径：`docs/research/2026-11-23-deep-dive/10-menubar-apps-engineering.md`。
