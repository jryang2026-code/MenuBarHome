# macOS 顶级菜单栏应用工程与体验深潜报告（源码三层扒皮）

> **调研范围**：5 个开源 Swift 标杆仓库一手源码深读（`jordanbaird/Ice`、`exelban/stats`、`MonitorControl/MonitorControl`、`p0deje/Maccy`、`TheBoredTeam/boring.notch`）+ 10 款大众封神商业标杆拆解（Raycast、Bartender、BetterDisplay、CleanShot X、Dato、iStat Menus、AirBuddy、Alcove、Dropover、Klack）+ 对照本仓 `MenuBarHome` macOS 端真实源码（`Sources/MenuBarMijiaApp/`、`Sources/MijiaCore/`）逐项映射可落地改造清单。  
> **证据标注**：文中「源码证实」均附真实 `repo/path#symbol` 与行号；商业软件未开源部分明确区分「官方工程分享/文档事实」与「社区口碑与行为推断」。

---

## 一、核心结论（直报摘要）

顶级 macOS 菜单栏软件之所以让人“用过就回不去”，并非靠单一视觉特效，而是**三层隐形工程的叠加**：
1. **窗口层零打扰**：清一色放弃 `MenuBarExtra` 与标准 `NSPopover`，改用**自持 `NSStatusItem` + `.nonactivatingPanel` 定制 `NSPanel`**——打开时不抢前台窗口焦点（不让 IDE/全屏视频标题栏变灰）、跨全屏 Space 跟随、首次点击直达按钮（`acceptsFirstMouse`）、支持拖出钉住（Tear-off），并能一键隐藏于录屏之外（`sharingType = .none`）。
2. **资源与响应双极限**：后台常驻用 `DispatchSourceTimer(leeway:)` / `NSBackgroundActivityScheduler` 与整秒对齐降低 CPU 唤醒，面板关闭时彻底暂停重型视图、详情采集器与事件监听；高频操控（如亮度/音量滑块）用**槽位覆盖式串行合并**替代无脑排队，既跟手又不拖尾。
3. **细节与系统代际护城河**：解决键盘导航与鼠标悬停抢焦、中文 IME / 系统 Emoji 面板抢方向键、非英键盘布局 `⌘,` 失灵、设置窗动态 Dock 切回、以及 **macOS 26 Tahoe（Liquid Glass）** 上的三类真实坑点（`NSGlassEffectView` / `.glassEffect` 分支身份重置、无背景透明层悬停失效、`NSStatusBarWindow` 触发 WindowServer 日志风暴）。

**对照本仓现状**：MenuBarHome macOS 端工程起点已经非常高（源码证实已迁移到自持 `NSStatusItem` + `MenuBarPanel`、已有 macOS 26 跨进程菜单栏长按适配、已做 `dropPanelContent()` 释放与 `NSBackgroundActivityScheduler` 更新调度、已有 `AppleMotion` 弹簧体系与触感分级）。但与上述顶级大师对照，仍存在 **8 项高收益、可直接落地的质感跃迁点**（见第六章改造清单）。

---

## 二、5 大开源 Swift 标杆三层源码扒皮

### 2.1 第一层：窗口宿主工程（`NSPanel` vs `NSPopover` vs `MenuBarExtra`）

#### 1. 三种宿主路线工程权衡矩阵（源码实证）

| 维度 | `NSStatusItem` + 自定义 `NSPanel`（5 仓中有 4 仓核心采用） | `NSPopover`（如 `Ice` 仅用于局部颜色编辑器） | SwiftUI `MenuBarExtra`（仅 `boring.notch` 用于极简设置菜单） |
| :--- | :--- | :--- | :--- |
| **代表源码** | `Maccy/Maccy/FloatingPanel.swift#FloatingPanel`<br>`Ice/Ice/UI/IceBar/IceBar.swift#IceBarPanel`<br>`stats/Kit/module/popup.swift#PopupWindow`<br>`boring.notch/.../BoringNotchWindow.swift#BoringNotchWindow` | `Ice/Ice/MenuBar/Appearance/MenuBarAppearanceEditor/MenuBarAppearanceEditorPanel.swift#MenuBarAppearanceEditorPopover` | `boring.notch/boringNotch/boringNotchApp.swift#DynamicNotchApp.body` (L32)<br>`Maccy/Maccy/MaccyApp.swift` (仅空壳隐藏菜单 L13) |
| **非抢焦点输入** | **满分**：`.nonactivatingPanel` + `canBecomeKey = true` + `orderFrontRegardless()` + `makeKey()`，可打字/方向键但不激活 App | 弱：默认激活进程或丢失键盘焦点，边缘行为受 AppKit 私有实现制约 | 差：窗口与状态项封装在私有类里，macOS 26 跨进程后甚至难以拿到真实 frame |
| **全屏 Space 跟随** | **满分**：自由组合 `.fullScreenAuxiliary`、`.moveToActiveSpace` / `.canJoinAllSpaces`、`.stationary`、`.ignoresCycle` | 中：全屏切换易失位或被系统强行收起 | 弱：无法自定义 `level` 与 `collectionBehavior` |
| **动态高度与入场动效** | **满分**：`NSAnimationContext` 顶边锚定高度插值、`CATransaction`、独立阴影窗 | 弱：高度变化抖动、强制带尖角箭头与默认弹性 | 差：窗口尺寸常与 SwiftUI 布局死循环打架 |
| **拖出钉住（Tear-off）** | **原生支持**：监听 `windowWillMove` 切锁定态即可脱离菜单栏常驻 | 需实现 `popoverShouldDetach`，视觉仍受限 | 不支持 |
| **macOS 26 材质控制** | **满分**：直接挂载 `NSGlassEffectView` 或透明容器 + `.glassEffect()` | 受系统 popover 壳限制 | 仅默认样式 |

#### 2. 非抢焦点 `NSPanel` 黄金配方（源码证实）

- **标准交互式浮动面板（`Maccy` 范式）** — `Maccy/Maccy/FloatingPanel.swift#FloatingPanel.init` (L25-54, L85-101, L210-233)：
  - `styleMask`: `[.nonactivatingPanel, .resizable, .closable, .fullSizeContentView]`（隐藏红黄绿三灯 `standardWindowButton(...)?.isHidden = true`）。
  - 窗口行为：`isFloatingPanel = true`、`level = .statusBar`、`hidesOnDeactivate = false`、`animationBehavior = .none`、`collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]`、`override var canBecomeKey: Bool { true }`。
  - **关键唤起时序（L92-93）**：调用 `orderFrontRegardless()` + `makeKey()`，**绝不调用 `NSApp.activate(ignoringOtherApps: true)`**！用户当前 IDE/浏览器的窗口标题栏不会变灰、不会退出全屏空间，同时 Maccy 面板内的搜索框依然获得 Key 焦点，可立即盲打过滤。
  - **点击外部收起（L210-216）**：覆写 `resignKey()`，若无模态弹窗且未抑制关闭则调用 `close()`；并在 `ContentView.swift` (L69-86) 通过监听 `NSWindow.didBecomeKeyNotification` / `didResignKeyNotification` 自行维护 SwiftUI `scenePhase`（因为独立 `NSPanel` 不是 SwiftUI `Scene`，系统不会自动推进 `scenePhase`）。

- **非激活面板的两个“防双点与防失声”必杀技（`Ice` 范式）** — `Ice/Ice/UI/IceBar/IceBar.swift`：
  1. `IceBarPanel.init` (L31)：`self.allowsToolTipsWhenApplicationIsInactive = true` —— 否则 `.nonactivatingPanel` 在后台不激活状态下，所有按钮的悬浮 Tooltip 全部失效！
  2. `IceBarHostingView#acceptsFirstMouse(for:)` (L227-229) 返回 `true` —— 否则用户从别的应用移过来点面板里的开关，**第一下点击会被吃掉只用于激活，第二下才触发**，手感立刻掉档！
  3. `IceBarHostingView#safeAreaInsets` (L195-197) 返回空 `NSEdgeInsets()` —— 消除 `.fullSizeContentView` 顶部隐形标题栏安全区把内容往下顶的错位。
  4. `IceBarPanel#configureCancellables()` (L48-55)：合并监听 `NSWorkspace.activeSpaceDidChangeNotification` 与 `NSApplication.didChangeScreenParametersNotification` 自动关闭，防切换桌面后幽灵窗口残留。

- **纯展示/悬浮 HUD 窗口（`boring.notch` 范式）** — `boring.notch/boringNotch/components/Notch/BoringNotchWindow.swift` (L10-50) & `BoringNotchSkyLightWindow.swift` (L34-114)：
  - 覆写 `canBecomeKey = false`、`canBecomeMain = false`，`level = .mainMenu + 3`，`collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`，彻底与键盘焦点解耦。
  - **隐私录屏隐藏开关**（`BoringNotchSkyLightWindow.swift#updateSharingType` L88-94）：根据用户偏好设置 `window.sharingType = .none`，屏幕共享或录屏时该浮窗对观众完全隐身。
  - **锁屏级显示隔离**（`boringNotchApp.swift#onScreenLocked` / `onScreenUnlocked` L91-145）：通过分布式通知监测锁屏状态，按需启用/卸载私有 SkyLight 委托并在解锁后延迟 150ms 撤销以消除闪烁（注：涉及私有框架 `SkyLight.framework`，App Store 不可用，适合非沙盒直发且应做成可选开关）。

- **弹窗高度动态丝滑动效与 Tear-off 拖出钉住（`Maccy` + `Stats` 范式）**：
  - **顶边锚定平滑缩放** — `Maccy/Maccy/FloatingPanel.swift#verticallyResize(to:)` (L103-113)：AppKit 坐标系原点在左下角，直接改 `height` 会导致顶边下移或抖动；Maccy 先计算 `newOrigin.y += (frame.height - newSize.height)` 锁定顶边，再包进 `NSAnimationContext.runAnimationGroup { context.duration = 0.2; animator().setFrame(..., display: true) }`，展开/收起丝滑如抽屉。同时在 `Maccy/Maccy/Views/HeightReaderModifier.swift#SizeReaderModifier` (L3-15) 使用现代 `.onGeometryChange(for:)` 取代 `GeometryReader` 实时读取内容高度，避免布局循环。
  - **一拖即钉（Tear-off Pinning）** — `stats/Kit/module/popup.swift#PopupWindow` (L165-179) & `HeaderView#setCloseButton` (L492-497)：用户直接拖动弹窗标题栏时，`windowWillMove(_:)` 自动将 `self.locked = true` 并将左上角图标切为 `xmark.circle.fill`；随后 `windowDidResignKey(_:)` 遇到 `guard !self.locked else { return }` 直接放行——窗口秒变桌面置顶监视器！再点一次菜单栏图标则重置 `locked = false` 恢复自动收起。而 `Maccy/Maccy/FloatingPanel.swift#saveWindowPosition()` (L122-131) 将撕下后的位置存为相对 `screen.visibleFrame` 的归一化比例 `(0...1)`，更换分辨率或外接屏也不丢位置。

---

### 2.2 第二层：极致低资源占用、零闪烁响应与硬件级跟手手感

#### 1. 后台低 CPU / 低 Energy Impact 调度体系（`Stats` 范式）

`exelban/stats` 同时监控 CPU/GPU/RAM/网络/电池/传感器/蓝牙 10 个模块，却能保持常驻 CPU 接近 0%、极低能耗，源码揭示了 4 层秘诀：
1. **带合并宽容度的 GCD 定时器** — `stats/Kit/plugins/Repeater.swift#Repeater` (L19-76)：
   - 使用 `DispatchSource.makeTimerSource` + `leeway: .milliseconds(200)`（允许内核将唤醒与其他系统任务合并，大幅降低 Energy Impact）。
   - 严格区分 `pause()`（`timer.suspend()`）与 `start()`（`timer.resume()`），并在 `deinit` (L30-37) 中先 `resume()` 再 `cancel()` 规避 GCD 挂起态销毁必崩陷阱。
2. **多模块整秒边界对齐（Lockstep Coalescing）** — `stats/Kit/module/reader.swift#Reader.delayToNextSecondBoundary()` (L225-263)：
   - 各模块默认错峰唤醒会令 CPU 每秒醒来十几次；`Stats` 计算到下一个整秒边界的延迟（+5ms 安全余量），把所有模块的采样对齐到同一节拍一起醒、一起睡。
3. **弹窗不可见即冻结重型 Reader** — `stats/Kit/module/module.swift#Module.readerHasVisibleConsumer(_:)` & `updateReaderVisibility()` (L298-336)：
   - 每个 `Reader` 标记自己是常驻状态栏必需（`popup == false`）还是仅弹窗/预览详情所需（`popup == true` / `preview == true`）。一旦 `popupVisible == false && settingsVisible == false`，立刻执行 `reader.lock()` + `reader.pause()`，彻底停掉详情进程表、细分传感器等重型轮询。
4. **系统级零唤醒后台作业** — `stats/Stats/helpers.swift#defaultValues()` (L114-155)：
   - 版本检查等低频任务不用常驻 `Timer`，而是交给 `NSBackgroundActivityScheduler`（macOS DAS 调度器，插电/空闲时才唤醒）。

#### 2. 弹窗内存释放 vs 零闪烁预热的三种流派（源码对比）

| 流派 | 代表源码 | 关窗动作 | 开窗动作 | 内存占用 | 唤起体感 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **彻底卸载派** | `Ice/Ice/UI/IceBar/IceBar.swift#close()` (L184-189)<br>`Ice/.../MenuBarSearchPanel.swift#close()` (L137-143) | `contentView = nil`、停掉事件监听 | 每次重建 `NSHostingView`、`colorManager.updateAllProperties` 防首帧色闪 | 最低（静置几乎 0 视图内存） | 轻视图无感；复杂 SwiftUI 树有 30–80ms 重建抖动 |
| **卸载控件 + 保留快照派** | `stats/Kit/module/popup.swift#PopupWrapper.releaseContent()` (L72-78) + `PopupCache<T>` (L14-31) | 销毁全部子视图，但 `PopupCache` 在内存中保留最新读数 | `prepareForDisplay()` 在 `orderFront` 前重建并立刻 `replay` 缓存值 + `layoutSubtreeIfNeeded()` | 极低 | **零空白闪烁**，一睁眼就是最新数据 |
| **常驻温热派** | `Maccy/Maccy/AppDelegate.swift` (L113-120) + `ContentView.swift` (L68-86) | 仅 `orderOut`/隐藏，`scenePhase = .background`，保留 `NSHostingView` | 直接 `setFrameOrigin` + `orderFrontRegardless()` + `makeKey()` | 稍高（但列表精简，常驻仍可控制在 ~25-40MB） | **亚 10ms 毫秒级零延迟秒开** |

> **关键发现（`IceBarColorManager` 防闪技巧）**：`Ice/Ice/UI/IceBar/IceBar.swift#show` (L175-181) 在 `orderFrontRegardless()` **之前**同步调用一次 `colorManager.updateAllProperties(with: frame, screen: screen)`，注释点破玄机：异步主队列更新会在首帧已经上屏后才到达，造成肉眼可见的“先灰后亮”色闪！

#### 3. 硬件级滑块跟手交互与防抖合并（`MonitorControl` 范式）

`MonitorControl` 面临与智能家居极其相似的难题：**UI 滑块拖动是 60–120Hz，但底层硬件（DDC/CI 协议，类似米家云/局域网调光）写入耗时数十到数百毫秒**。它的三板斧堪称教科书：
1. **槽位覆盖式串行写入合并（Latest-Value Coalescing）** — `MonitorControl/MonitorControl/Model/OtherDisplay.swift#writeDDCValues` & `asyncPerformWriteDDCValues` (L380-419)：
   - 拖动产生的高频值绝不逐条排进队列，而是加 barrier 覆盖写入最新目标槽 `writeDDCNextValue[command] = value`，并在串行 `globalDDCQueue` 上异步触发执行。
   - 串行队列真正执行时，读出**此刻最新的 `writeDDCNextValue`**；若与 `writeDDCLastSavedValue` 相同则直接 `return` 跳过！结果：拖动中连续触发且零排队积压，松手时的终值 100% 必达，绝不会出现“手松开 2 秒后灯光还在自己一跳一跳”。
2. **原生控制中心风格滑块 + 滚轮直调 + 软磁吸** — `MonitorControl/MonitorControl/Support/SliderHandler.swift`：
   - `MCSlider#scrollWheel(with:)` (L184-202)：光标悬停滑块上直接双指滑动/滚动滚轮即可精细调值，自动处理自然滚动方向反转（`event.isDirectionInvertedFromDevice`）与 RTL 布局。
   - `ClickThroughImageView#hitTest(_:)` (L205-210)：嵌在滑块轨道左端的图标透传点击，不遮挡 0% 端点的拖拽热区。
   - 磁吸刻度（L313-322）：每 25% 设 ±3% 磁吸区间，盲拖轻松对齐常用档位；多设备联动时用 `displayHighlightItems` (L122-132) 在同一滑块轨道内标出各设备当前点位。
   - 步进平滑插值（`Display.swift#setSmoothBrightness` L116-160）：按快捷键步进调节时每 20ms 按 1/6 差值指数逼近目标值，避免硬件亮度硬阶跃刺眼。
3. **非侵入 OSD 反馈** — `MonitorControl/MonitorControl/Support/OSDUtils.swift` (L25-145)：
   - 用快捷键调节时弹出系统 OSD，且在 macOS 26 Tahoe 上通过直连 `com.apple.OSDUIHelper` 的 `NSXPCConnection`（带断线重连 `interruptionHandler` / `invalidationHandler`）维持传统 16 格视觉反馈。

#### 4. 弹性物理动效与连续形态变换（`boring.notch` 范式）

- **不对称开合弹簧曲线** — `boring.notch/boringNotch/ContentView.swift` (L41, L123-128)：
  - 打开态：`Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)`（轻度过冲带来灵动感）；
  - 关闭态：`Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)`（临界阻尼 `1.0`，收起利落绝不回弹拖泥带水）；
  - 交互态：`Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8)`（可随时打断重定位）。
- **跨态元素共享几何连续性** — `ContentView.swift` (L398, L460) + `NotchHomeView.swift` (L88)：通过 `@Namespace` + `.matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)` 让收起态迷你封面与展开态大封面无缝变形过渡，并配合 `NotchShape` (`NotchShape.swift#animatableData` L23-34) 声明 `AnimatablePair<CGFloat, CGFloat>` 同步插值上下圆角半径，以及 `.compositingGroup()` (L207) 防止半透明子视图在缩放时相互透底。
- **防误触悬停延迟 + 触感反馈** — `ContentView.swift#handleHover(_:)` (L513-550)：进入悬停先播 `.sensoryFeedback(.alignment, trigger: haptics)` 轻触感，等待 `Defaults[.minimumHoverDuration]` 再展开，离开延迟 100ms 取消任务，避免鼠标划过屏幕顶部时意外弹出打断视线。

---

### 2.3 第三层：键盘流、辅助功能、设置/更新礼仪与 macOS 26 坑点治理

#### 1. 极致纯键盘流工程细节（`Maccy` 范式）

- **键鼠防抢焦状态机（Hover-vs-Keyboard Guard）** — `Maccy/Maccy/Observables/NavigationManager.swift` (L75-88, L212-228) & `ContentView.swift` (L44-46)：
  - 键盘按 `↑↓` 导航时置 `isKeyboardNavigating = true`；期间鼠标若恰好停在列表某行上（或列表滚过静止光标），`hoverSelectionWhileKeyboardNavigating` 只记录 ID **不立即抢走高亮**；直到 `.onMouseMove` 捕获到真实鼠标移动才把 `isKeyboardNavigating` 置 `false` 并接管选中！
- **`⌘Tab` 式修饰键连按快选** — `Maccy/Maccy/Observables/Popup.swift` (L6-16, L122-196)：
  - 全局快捷键按下进入 `.opening` 状态并临时禁用全局注册改由局部监听接管；若用户不松开修饰键再次连按主键，自动切入 `.cycle` 模式循环切换高亮项，**松开修饰键瞬间直接执行选中项并收起**；若直接松开修饰键则进入常规 `.toggle` 停留模式。
- **多语言键盘布局 + IME + Emoji 面板三重防护** — `Maccy/Maccy/Views/KeyHandlingView.swift` (L14-31, L82-110)：
  - 注释直言 SwiftUI `.onKeyPress` 拿不到物理 `keyCode`，在非英文输入法下 `⌘,` 等快捷键失效，因此用 `Sauce`（物理键码映射）+ `NSApp.currentEvent` 解析 `KeyChord`。
  - 检查 `NSApp.keyWindow?.firstResponder as? NSTextInputClient` 的 `hasMarkedText()`，确保拼音/日文候选词上屏前不截获回车和方向键。
  - 检查 `NSApp.characterPickerWindow == nil`（`NSApplication+Windows.swift:5` 检测 `className == "NSPanelViewBridge"`），确保系统 Emoji 选择器弹出时方向键不会误操作主列表！
- **多策略混合搜索** — `Maccy/Maccy/Search.swift#mixedSearch` (L115-132)：精确子串 → 正则 → `Fuse` 模糊匹配（并截断超长文本 `fuzzySearchLimit = 5_000` 保帧率），同时返回高亮匹配区间 `ranges`。

#### 2. 设置窗口、权限引导与“绝不打扰”的更新礼仪（`Ice` + `Stats` 范式）

- **代理应用动态 Dock 切回** — `Ice/Ice/Main/AppDelegate.swift` (L62-66, L84-94) & `Stats/Stats/AppDelegate.swift#updateDockIcon()` (L115-123)：
  - 菜单栏常驻 App 平时是 `.accessory`（不占 Dock），但一旦打开独立 `SettingsWindow` 或引导窗，立刻切换 `NSApp.setActivationPolicy(.regular)`（进入 `⌘Tab` 列表并展示完整菜单栏，支持用户切去浏览器拷贝 Token 再切回来）；当最后一个常规窗口关闭时（`applicationShouldTerminateAfterLastWindowClosed`）自动切回 `.accessory`。
- **尊重系统侧边栏行高** — `Ice/Ice/Settings/SettingsView.swift` (L10-37)：读取 `@Environment(\.sidebarRowSize)`（`.small`/`.medium`/`.large`）动态适配侧栏宽、行高与字号，与 macOS 系统设置完全同频；设置项封装统一 `IceForm` (`Ice/Ice/UI/IceUI/IceForm.swift`) + `IceLabeledContent`，视觉零割裂。
- **温和自动更新 & 忙时免打扰检测**：
  - `Ice/Ice/Updates/UpdatesManager.swift` (L105-142)：遵循 Sparkle `SPUStandardUserDriverDelegate`，实现 `supportsGentleScheduledUpdateReminders = true`，**仅在 App 处于活跃态时才弹出更新框**，后台静默发现更新时只发系统通知或在面板角标提示，绝不凭空跳出模态窗抢用户键盘。
  - `Stats/Stats/helpers.swift#tryToShowSupportWindow` (L272-307)：弹出任何非紧急窗口前，在后台线程检查 `UserContext.isScreenLocked()`、`secondsSinceLastInput() > 60` 以及 `UserContext.busyReason()`（全屏/专注/演示中则延后）。

#### 3. macOS 26 Tahoe（Liquid Glass）一线踩坑实证（来自 5 仓真实代码）

1. **WindowServer `_CGXPackagesSetWindowConstraints: Invalid window` 日志风暴** — `stats/Stats/helpers.swift#suppressStatusBarTilingConstraintUpdates()` (L384-403)：
   - **成因（源码实证）**：macOS 26 Tahoe 上 `NSStatusBarWindow` 每次布局更新（比如状态栏文字/图标变化）都会在应用非活跃时触发 `-[NSWindow(NSFullScreen) _needsTilingConstraintUpdate]` → `SLSPackagesSetWindowConstraints`。但状态栏窗口在 Tahoe 上无常规服务端窗口号（低 32 位为 0），导致每次更新都被 WindowServer 拒收并狂刷控制台日志与无谓 IPC。`Stats` 在 macOS 26 上仅对 `NSStatusBarWindow` 覆盖 `_needsTilingConstraintUpdate` 返回 `false` 根治该问题。
2. **无背景透明层悬停/手势失效** — `Maccy/Maccy/Views/ListItemView.swift` (L125-130) & `SlideoutView.swift` (L52)：
   - macOS 26 上如果列表行或透明交互区域没有实际填充背景，`.onHover` 与手势会失效；`Maccy` 用 `.white.opacity(0.001)` 兜底解决。
3. **AppKit `NSGlassEffectView` 桥接与尺寸打架**：
   - `Maccy/Maccy/Views/VisualEffectView.swift#GlassEffectView` (L19-32) 直接封装 `NSGlassEffectView(style: .regular)` 作为 `NSPanel` 底层玻璃。
   - 在 `NSPanel` 中宿主 SwiftUI 时必须设 `hostingView.sizingOptions = []` 防止 SwiftUI 内在尺寸与 `NSPanel` 抢布局；且 SwiftUI `.glassEffect()` 严禁放在 `if/else` 分支切换视图身份（会销毁锚点甚至令弹窗闪退，应保持单一节点树改变参数或用 `.identity`）。
4. **CoreText 特殊 Unicode 字符卡死防护** — `Maccy/Maccy/Extensions/String+UnsafeForTitleLayout.swift` (L5)：macOS 26 CoreText 渲染特定非法标量序列可能挂死主线程，外部不可信文本（如米家/HA 用户自定义设备名或异常传感器字符串）在渲染前宜做安全清洗。

---

## 三、10 款大众封神商业标杆深度拆解

> 说明：以下 10 款商业软件均为闭源（或部分闭源），表格与拆解结合其官方工程博客、开发者公开分享（如 Raycast Blog、Bjango 文章、Henrik Ruscon/Guilherme Rambo/Sindre Sorhus 公开介绍）以及 Reddit (`r/macapps`)、少数派、V2EX 高频口碑归纳，文中已区分「公开技术事实」与「体验与工程推断」。

| 软件 | 封神标签 | 核心杀手级体验与审美秘诀 | 可复用的工程/交互范式（对标 MenuBarHome） |
| :--- | :--- | :--- | :--- |
| **Raycast** | 键盘流天花板 / 毫秒级响应 | **公开工程事实**：v1 纯 Swift + AppKit 自研几乎所有列表行与快捷键控制；v2 跨端仍保留纯原生 Swift/AppKit 宿主层负责全局热键、窗口与焦点，确保按键零输入延迟。<br>**体验精髓**：所有操作统一收敛到“单行搜索 + `⌘K` 操作面板 + 底部快捷键提示条”，新老手无缝进阶。 | 强化 MenuBarHome 的「直打搜索 + 单键/组合键指令面板 + 底部上下文快捷键提示」；设备搜索不仅能找设备，还能直接出动作（如搜“空调”直接回车开关、`⌘K` 调温/定时）。 |
| **Bartender** | 空间极简 / 无形之手 | **口碑与行为分析**：把“克制”做到极致——自动收起菜单栏杂乱图标，提供触发条件（Triggers，如电量低/特定网络自动浮现图标）与平滑的物理位移曲线；不该出现时完全消失，需要时一扫即出。 | 菜单栏图标**条件显隐与信息分级**：平时极简图标+关键数值，仅在异常告警/高功耗/倒计时最后 1 分钟或特定 Wi-Fi 下才自动展开摘要文字。 |
| **BetterDisplay** | 硬核控制中心化 | **口碑与行为分析**：把极其复杂的显示硬件参数（HiDPI、DDC、EDID、虚拟屏）收纳成酷似 macOS 原生 Control Center 的分级滑块与折叠抽屉；且允许用户自定义展开动效速度（甚至调成 0 追求极限干脆）。 | 复杂家电（空调、新风、多路开关、扫地机）**默认只露 1 个主控/主滑块，高频次级能力藏进一级抽屉，低频工程项进设置或子菜单**；保证首屏绝对清爽。 |
| **CleanShot X** | 动效流与浮动工作台 | **公开技术/口碑**：截图后不抢焦点弹出 **Quick Access Overlay 浮动小卡片**（支持 Pin 置顶、直接拖走、悬停出快捷按钮、一键收起），用 ScreenCaptureKit 实现瞬间抓帧与顺滑拖拽物理感。 | 摄像机抓拍/门铃提醒/一键场景执行后，可借鉴「轻量可交互浮窗/HUD」：无需打开整个主面板，直接完成查看、关灯、回看或一键置顶。 |
| **Dato** | 极高信息密度与零卡顿 | **公开背景（Sindre Sorhus）与口碑**：在极小弹窗里优雅塞进月历、多时区时钟、日程倒计时与一键入会按钮，全面遵守系统本地化、字体数字等宽（tabular numerals）、全局快捷键与极简偏好架构。 | 传感器/能耗/温湿度摘要坚持**等宽数字（`monospacedDigit`）**、紧凑信息层级与一键直达（点温度直接跳对应房间/折线，MenuBarHome 已初具雏形，可进一步做多房间横向微对比）。 |
| **iStat Menus (v7)** | 像素级数据可视化标杆 | **公开背景（Bjango）与口碑**：菜单栏里的微型折线图、饼图、柱状图做到 1px 级锐利对齐；悬停即现微图表，颜色克制地仅用于阈值语义（绿→琥珀→红），零无意义弹窗与音效噪音。 | 菜单栏可提供可选**微型状态可视化**（如极简开灯指示点/微型温湿度趋势线），色彩克制只表达告警与运行态，绝不花哨。 |
| **AirBuddy** | 苹果官方既视感（Apple-like） | **公开背景（Guilherme Rambo）与口碑**：把 iOS AirPods 弹窗的物理阻尼、圆角、毛玻璃与低功耗蓝牙状态机原汁原味带到 macOS，极度克制 CPU 唤醒以保护 MacBook 续航；首次引导按需请求权限而非一启动弹出权限墙。 | 保持 MenuBarHome **按需请求权限（通知/麦克风/局域网）**的优良实践；给高危确认、设备重连与扫码弹窗赋予更统一的原生弹簧与触感层次。 |
| **Alcove** | 刘海美学与克制灵动岛 | **公开背景（Henrik Ruscon）与口碑**：纯 Swift 编写，被社区公认为“最像 Apple 亲手做的灵动岛”——不做大杂烩，专注丝滑胶囊形变、Duo 双活动分栏、两指触控板手势切歌/展开与替代系统 HUD。 | 借鉴其**克制哲学与流畅胶囊过渡**：在控制中心主面板与顶部“正在运行活动/倒计时”条之间建立流畅形态过渡，避免生硬切块。 |
| **Dropover** | 空间物理与动作确认感 | **口碑与行为分析**：摇晃鼠标召唤临时文件架，文件拖入时弹簧放大承接、落位时伴随极其克制的闷响（soft thud），让虚拟拖拽产生“放在桌面上”的真实触觉错觉。 | 卡片拖拽排序、群组合并、全关长按确认等高仪式感操作，结合 `NSHapticFeedbackManager` + 极短促微音效建立物理落位感。 |
| **Klack** | 零延迟声学与拟真触觉错觉 | **公开背景（Henrik Ruscon）与口碑**：分离按下（key-down）与抬起（key-up）音效并引入微小随机音高抖动（randomized pitch），把薄膜键盘“听”出了机械轴的物理段落感，证明**低于 15ms 的同步微反馈能创造强烈质感错觉**。 | MenuBarHome 已有 `SoundFeedback`，可进一步区分“轻点开关 / 滑块刻度触感 / 成功确认 / 失败提醒”的细微声学与触感层次（且默认克制、支持开关）。 |

---

## 四、顶级 macOS 菜单栏应用的 6 条底层黄金铁律（跨项目共性提炼）

1. **焦点敬畏铁律（Never Steal Focus Unless Asked）**：菜单栏是“随手工具”不是“主工作台”。主面板用 `.nonactivatingPanel` + `canBecomeKey = true` + `acceptsFirstMouse = true` + `allowsToolTipsWhenApplicationIsInactive = true`，让人**不打断前台窗口就能完成 90% 操作**；只有打开独立 Settings 窗口时，才切 `.regular` 进 `⌘Tab`。
2. **首帧零抖动铁律（Zero-Flash First Frame）**：任何异步数据/颜色/高度计算若推迟到窗口 `orderFront` 之后，肉眼都会捕捉到“灰一下/跳一下”。上屏前完成缓存快照回放、色彩采样与初始尺寸定型，同时关窗后采用**短时温热保留 + 空闲彻底卸载**兼顾秒开与低内存。
3. **输入绝对跟手铁律（UI Never Waits for I/O）**：滑块拖动、按键导航、搜索过滤 100% 在本地 60/120fps 响应；慢速硬件/云端 I/O 走**最新值槽位覆盖合并**（Leading 响应 + Coalesced Trailing 必达），杜绝队列积压拖尾。
4. **静默低耗铁律（Zero Idle Tax）**：面板一关，立刻停掉详情高频轮询、重型 SwiftUI 树与多余鼠标监听；常驻任务统一设 `Timer.tolerance` / `DispatchSourceTimer.leeway`、整秒对齐或下放 `NSBackgroundActivityScheduler`。
5. **键盘与无障碍一等公民铁律**：键盘流必须与鼠标悬停互斥防抢焦、避让 CJK 输入法候选框与系统 Emoji 面板、不受非英键盘布局影响，并全面尊重系统 `Reduce Motion` / `Reduce Transparency` / `sidebarRowSize`。
6. **场景克制与隐私礼仪铁律**：非紧急提示（更新、引导、续期）避让锁屏/演示/全屏忙碌态；支持投屏防窥（`sharingType = .none`）；动效开合不对称（开有微弹性、合必临界阻尼干脆收束）。

---

## 五、MenuBarHome macOS 端现状审计（实事求是对标）

通过只读核查本仓 `Sources/MenuBarMijiaApp/` 与 `Sources/MijiaCore/` 源码，确认 MenuBarHome **已达到行业中上至一线水准的既有优势**（以下项无需重复造轮子）：
- **宿主已去 `MenuBarExtra` 化**（源码证实）：`MenuBarPanelController.swift` + `MenuBarPanelController+Presentation.swift` 已自建 `NSStatusItem` + `MenuBarPanel: NSPanel`，且深度攻克了 macOS 26 跨进程菜单栏长按（`configureStatusItemLongPress`）、右键 settle 与防二次弹开（`statusItemReopenSuppressionWindow`）。
- **macOS 26 Liquid Glass 原生适配领先**（源码证实）：`ThemeAndMotion.swift` 已封装 `.glassEffect` + `GlassEffectContainer`（`AdaptiveGlassContainer`）、`GlassHoverHighlight`、`SpecularRim`、以及 `ReduceMotion`/`ReduceTransparency` 完整回退。
- **状态栏防抖动排版专业**（源码证实）：`MenuBarPanelController.swift#statusTitle` (L915) 使用 `.monospacedDigitSystemFont` + `MenuBarWidthStabilizer` 防数字变动引起菜单栏整体左右跳动；状态图标使用 template cutout dot (`badgedTemplateImage` L845)。
- **能耗与调度已有扎实基础**（源码证实）：`UpdateScheduler.swift#BackgroundUpdateScheduler` 已接入 `NSBackgroundActivityScheduler` + 30 分钟启动抖动；`MenuBarPanelController.swift` 仅在语音/Toast/最后 60 秒倒计时时运行 `labelTimer`（且配 `tolerance = 0.1`）；`HomeProvider.swift#setPollingContext` 已区分 `panelVisible` 与 `systemActive`。
- **键盘与触感已具雏形**（源码证实）：`HotkeyAndNotificationManager.swift` + `PanelKeyRouter.swift` 已做完备键盘路由和 `hasMarkedText()` 中文输入法保护；`ThemeAndMotion.swift#LiquidGlassSlider` 已实现 10% 分桶 `.alignment` 触感反馈与拖拽零延迟/点轨 180ms 缓动分流。

**但对照 5 大开源标杆与 10 大商业大师，暴露出 8 项非常清晰的高价值短板**（详见第六章）。

---

## 六、可直接落地到 MenuBarHome macOS 端的具体改进清单

> 注：所有改动均指向本仓现有真实文件与符号；遵循仓库协作约定，涉及全局快捷键/安全/窗口宿主底层边界的改造建议走独立 PR 并跑 `bash scripts/check.sh`（macOS UI 改动含快照比对验收）。

### P0｜直接跃升“原生无打扰手感”的核心改造

#### 1. 主面板升级为 `.nonactivatingPanel` 非抢焦点架构（对标 `Maccy` + `Ice`）
- **现状定位（源码证实）**：
  - `Sources/MenuBarMijiaApp/MenuBarPanelController+Presentation.swift#makePanel(theme:)` (L358) 使用 `styleMask: [.borderless]`；
  - `showPanel()` (L75, L89) 强制执行 `NSApp.activate(ignoringOtherApps: true)`，导致每次打开控制中心都把前台 Xcode/浏览器/会议窗口变灰失焦。
- **落地改动**：
  1. `makePanel(theme:)` 将 `styleMask` 改为 `[.borderless, .nonactivatingPanel]`，增加 `panel.allowsToolTipsWhenApplicationIsInactive = true`（对标 `IceBar.swift:31`）；保留 `MenuBarPanel.canBecomeKey = true`、`canBecomeMain = false`。
  2. 为 `NSHostingView` 创建极薄子类 `PanelHostingView<Content>: NSHostingView<Content>`，覆写 `acceptsFirstMouse(for:) -> Bool { true }`（对标 `IceBar.swift:227`，同时本仓 `CameraLiveVideoPlayer.swift:952` 已有成功先例！），确保后台非激活态下单击开关直接生效，绝不吞第一击。
  3. `showPanel()` 改用 `panel.orderFrontRegardless()` + `panel.makeKey()`（不再强行 `NSApp.activate`）；由于 `MenuBarPanelController.swift:1037` 已注入 `.environment(\.appearsActive, true)`，macOS 26 Liquid Glass 首帧仍能维持激活态折射（*待 macOS 26 实机验证：若系统某些原生 `Menu`/`TextField` 在非激活态存在焦点或玻璃材质差异，可按交互类型动态回退或仅在打开 `NSAlert`/系统表单时按需 `NSApp.activate`*）。
  4. 点击外部收起逻辑：在 `MenuBarPanel` 覆写 `resignKey()`（或监听 `NSWindow.didResignKeyNotification`）协同现有 `localMouseMonitor`/`globalMouseMonitor`，确保不依赖 `NSApplication.didResignActiveNotification` 也能精准收起；同时注意保留“语音听写中/摄像机浮窗/上下文菜单打开中”不误关。

#### 2. 动态高度变化增加顶边锚定平滑插值动画（对标 `Maccy/FloatingPanel.swift#verticallyResize`）
- **现状定位（源码证实）**：
  - `Sources/MenuBarMijiaApp/MenuBarPanelController+Presentation.swift#applySerialPanelGeometry()` (L345-351) 直接调用 `panel.setFrame(target, display: true)` 和 `presentBackdropShadow(around: target, under: panel)`，在展开设备详情抽屉、切换房间、打开搜索栏或展开提醒堆叠时，面板底部会**生硬闪跳**。
- **落地改动**：
  1. 在 `applySerialPanelGeometry()` 中区分「首次展示/Reduce Motion/屏幕参数突变」（瞬切）与「可见态内容增减引起的高度变化」（插值）。
  2. 可见态高度变化时，用 `NSAnimationContext.runAnimationGroup`（`duration: 0.20`，`timingFunction: CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)`）同步动画 `panel.animator().setFrame(target, display: true)` 与 `backdropWindow?.animator().setFrame(target.insetBy(dx: -backdropBleed, dy: -backdropBleed), display: true)`，保持顶边不动、底边丝滑伸缩。
  3. 在 `ThemeAndMotion.swift#AdaptiveSliceWriter` (L113-139) 中对 `#available(macOS 15.0, *)` 分支改用 `.onGeometryChange(for: CGFloat.self)`（对标 `Maccy/HeightReaderModifier.swift`），降低 `GeometryReader` 带来的额外布局遍数。

#### 3. 主面板「双阶延迟卸载」（兼得 `Maccy` 秒开手感与 `Ice`/`Stats` 低内存）
- **现状定位（源码证实）**：
  - `Sources/MenuBarMijiaApp/MenuBarPanelController+Presentation.swift#finishOrderingPanelOut` (L162-172) 每次关闭立即 `dropPanelContent()` 销毁整个 `NSHostingView`；用户连续调两盏灯（关了又点开）时每次都要冷重建整棵 SwiftUI 视图树。
- **落地改动**：
  1. 关闭面板时立即停止鼠标监听、重置搜索/编辑瞬态、调用 `store.setPanelVisible(false)`（暂停高频轮询）并通知内部冻结一切动画；但**延迟 45 秒**再执行 `dropPanelContent()`（期间若有新 `showPanel()` 则取消延迟任务，实现亚 16ms 零闪烁秒开！）。
  2. 注册 `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`，系统内存吃紧时立刻强制执行 `dropPanelContent()`，守住后台常驻 <15–20MB 的内存预算。

#### 4. macOS 26 Tahoe 三项防雷与前瞻加固（对标 `Stats` + `Maccy`）
- **现状定位（源码证实）**：
  - `Sources/MenuBarMijiaApp/ThemeAndMotion.swift#GlassShapeBackground.surfaceBody` (L647-651) 存在 `if let tint { content.glassEffect(.regular.tint(tint), in: shape) } else { content.glassEffect(.regular, in: shape) }` 条件分支；一旦未来开启卡片动态 `tint`，会触发 SwiftUI View Identity 重建导致闪动或锚点丢失。
  - `MenuBarPanelController.swift#syncStatusItem` 频繁更新状态栏文字/图标时，在 macOS 26 Tahoe 上可能触发与 `Stats` 同款的 WindowServer `_CGXPackagesSetWindowConstraints: Invalid window` 日志风暴（*待 macOS 26 实机日志验证*）。
- **落地改动**：
  1. 将 `GlassShapeBackground` (L647-651) 与 `ChipSurface` (L683-687) 的 `if let tint` 改为单分支表达式：`content.glassEffect(tint.map { glassStyle.tint($0) } ?? glassStyle, in: shape)`，彻底锁死 View Identity。
  2. 核查面板内透明可悬停行（如搜索结果、离线折叠行、房间排序行）在 macOS 26 下是否有背景填充，必要时补 `.background(.white.opacity(0.001))` 防止 `.onHover` 失效（对标 `Maccy/ListItemView.swift:125`）。
  3. 在 macOS 26 实机用 `/usr/bin/log stream` 核查状态栏更新是否产生 `_CGXPackagesSetWindowConstraints: Invalid window`；若确认命中且影响功耗/日志，按 `Stats/helpers.swift#suppressStatusBarTilingConstraintUpdates()` 评估受控规避方案（或先减少不必要的状态栏属性重赋，MenuBarHome 已做 `contentChanged` 守卫，可进一步校验 `attributedTitle` 等值性）。

---

### P1｜高频交互与生产力进阶（从“好用”到“爱不释手”）

#### 5. Tear-off 拖出钉住浮动模式（对标 `Stats/PopupWindow` + `Maccy/FloatingPanel`）
- **现状定位（源码证实）**：`MenuBarPanelController+Presentation.swift#makePanel` (L371-372) 硬编码 `isMovable = false`、`isMovableByWindowBackground = false`。
- **落地改动**：
  1. 在 `ControlCenterPanelChrome.swift#panelHeader` 增加可拖拽手柄区（或右上角 Pin 图钉按钮），`MenuBarPanel` 支持按需解锁 `isMovable = true` + 监听 `NSWindowDelegate.windowWillMove(_:)`。
  2. 一旦拖离菜单栏锚点即置 `isPinned = true`：屏蔽 `resignKey()` / 点击外部自动收起，并把按钮切为“归位/取消钉住”图标；位置按 `Maccy` 归一化比例持久化（仅限本次会话或可选记住）；再次点击菜单栏图标可一键归位或关闭。

#### 6. 滑块支持滚轮/双指微调 + 局域网写入槽位合并（对标 `MonitorControl`）
- **现状定位（源码证实）**：`ThemeAndMotion.swift#LiquidGlassSlider` (L838-1049) 仅支持 `DragGesture` 和键盘方向键，不支持光标悬停滚轮微调；且高频拖拽主要靠时间窗防抖。
- **落地改动**：
  1. 复用现有 `HorizontalWheelScrollMonitor` 架构模式，给 `LiquidGlassSlider` 注册滚轮微调探针（仅当水平滚动主导 `abs(deltaX) > abs(deltaY)` 或按住 `⌥` 滚动滚轮时拦截，绝不破坏主列表垂直滚动！），参考 `MonitorControl/SliderHandler.swift#MCSlider.scrollWheel` 适配自然滚动反转与精准/有级步长，配合 10% 分桶 `.alignment` 触感。
  2. 对局域网低延迟后端（Home Assistant WebSocket / `LocalMiIOClient`）引入 `MonitorControl/OtherDisplay.swift#writeDDCValues` 式的**单槽位覆盖串行合并**：首个变化立刻下发（Leading），执行期间的拖动值覆盖最新槽位，前一条返回后若槽位有新值立刻发最新值（避免纯 trailing debounce 等松手才亮灯的迟滞感，同时维持云端限流安全）。

#### 7. 键鼠悬停防抢焦 + Emoji 面板防护 + 设置窗动态 Dock 切回（对标 `Maccy` + `Ice`）
- **现状定位（源码证实）**：
  - `DeviceCardView.swift` 与 `ControlCenterPanel` 在键盘 `↑↓` 移动 `store.focusedDeviceId` 时，未与鼠标静止悬停高亮隔离；
  - `HotkeyAndNotificationManager.swift#keyContext` (L480) 已防护 `hasMarkedText()`，但未排除系统 Emoji 面板（`NSPanelViewBridge`）；
  - `SettingsWindowView.swift:10` 设计目标明确提到“方便用户切去浏览器复制 HA Token”，但 `SettingsWindowOpener.swift` 未在打开设置窗时切 `NSApp.setActivationPolicy(.regular)`（切去浏览器后 `⌘Tab` 看不到 MenuBarHome 设置窗）。
- **落地改动**：
  1. 引入 `PanelInputMode`（`.keyboard` / `.pointer`）：键盘导航切 `.keyboard` 暂停 `GlassHoverHighlight` 抢焦，收到 `NSEvent` `.mouseMoved`（位移 > 2pt）再恢复 `.pointer`（对标 `Maccy/NavigationManager.swift:76`）。
  2. 在 `HotkeyAndNotificationManager.swift#keyContext` 增加 `isCharacterPickerOpen = NSApp.windows.contains { $0.className == "NSPanelViewBridge" && $0.isVisible }`，为 `true` 时方向键与回车放行给系统表情选择器（对标 `Maccy/KeyHandlingView.swift:83`）。
  3. 在 `SettingsWindowOpener.swift` 打开设置窗时调用 `NSApp.setActivationPolicy(.regular)`，监听设置窗关闭且无其他主窗口可见时自动切回 `.accessory`（对标 `Ice/AppDelegate.swift:64,91` 与 `Stats/AppDelegate.swift:115`）。

---

### P2｜差异化惊艳与隐私礼仪（对标 `Alcove` / `CleanShot X` / `boring.notch`）

#### 8. 盲操轻量悬浮 HUD + 投屏防窥隐私开关 + 忙时免打扰提醒
- **非抢焦点盲操 HUD（对标 `MonitorControl/OSDUtils` + `Alcove`）**：当用户通过全局快捷键、Spotlight、`menumijia://` URL Scheme 或 Raycast 触发设备开关/场景时，不必每次弹出 380pt 全量面板，提供一个 `canBecomeKey = false`、`ignoresMouseEvents = true` 的**迷你玻璃胶囊 HUD**（显示设备图标 + 状态变化 + 1.2 秒弹簧收起，可选极轻确认音），做到“按完就走、心流零中断”。
- **投屏/录屏防窥模式（对标 `boring.notch/BoringNotchSkyLightWindow.swift:89`）**：在「设置 → 隐私/高级」提供「录屏与屏幕共享时隐藏控制面板与摄像机窗口」开关，底层一键切换 `panelWindow.sharingType = .none` 与 `CameraLivePanelController.panelWindow.sharingType = .none`——开会共享屏幕时随时控灯看门铃，对方屏幕完全不可见！
- **忙时免打扰提醒（对标 `Stats/helpers.swift:288` + `Ice/UpdatesManager.swift:106`）**：更新提醒、米家 Session 即将过期提醒等非安全类提示，引入“活跃态+非全屏演示”守卫，绝不在用户开会/全屏看片时打扰。

---

## 七、参考源码索引（核验路径清单）

- **开源剖析仓库**（均只读克隆于 `<local-brain>\scratch\repos\menubar-macos\`）：
  1. `Ice`: `Ice/UI/IceBar/IceBar.swift`、`Ice/UI/IceBar/IceBarColorManager.swift`、`Ice/MenuBar/Search/MenuBarSearchPanel.swift`、`Ice/Settings/SettingsWindow.swift`、`Ice/Settings/SettingsView.swift`、`Ice/UI/IceUI/IceForm.swift`、`Ice/Events/EventMonitors/UniversalEventMonitor.swift`、`Ice/Main/AppDelegate.swift`、`Ice/Updates/UpdatesManager.swift`
  2. `stats`: `Kit/plugins/Repeater.swift`、`Kit/module/module.swift`、`Kit/module/reader.swift`、`Kit/module/popup.swift`、`Kit/module/window.swift`、`Stats/AppDelegate.swift`、`Stats/helpers.swift`
  3. `MonitorControl`: `MonitorControl/Support/SliderHandler.swift`、`MonitorControl/Support/MenuHandler.swift`、`MonitorControl/Support/OSDUtils.swift`、`MonitorControl/Model/OtherDisplay.swift`、`MonitorControl/Model/Display.swift`、`MonitorControl/Support/UpdaterDelegate.swift`
  4. `Maccy`: `Maccy/FloatingPanel.swift`、`Maccy/AppDelegate.swift`、`Maccy/Observables/Popup.swift`、`Maccy/Observables/NavigationManager.swift`、`Maccy/Views/ContentView.swift`、`Maccy/Views/KeyHandlingView.swift`、`Maccy/Views/VisualEffectView.swift`、`Maccy/Views/ListItemView.swift`、`Maccy/Views/HeightReaderModifier.swift`、`Maccy/Search.swift`、`Maccy/Throttler.swift`、`Maccy/Clipboard.swift`
  5. `boring.notch`: `boringNotch/components/Notch/BoringNotchWindow.swift`、`boringNotch/components/Notch/BoringNotchSkyLightWindow.swift`、`boringNotch/ContentView.swift`、`boringNotch/BoringViewCoordinator.swift`、`boringNotch/components/Notch/NotchShape.swift`、`boringNotch/components/Notch/NotchHomeView.swift`、`boringNotch/boringNotchApp.swift`
- **本仓对照只读文件**：
  - `Sources/MenuBarMijiaApp/MenuBarMijiaApp.swift`、`MenuBarPanelController.swift`、`MenuBarPanelController+Presentation.swift`、`ThemeAndMotion.swift`、`HotkeyAndNotificationManager.swift`、`ControlCenterPanel.swift`、`ControlCenterPanelChrome.swift`、`DeviceCardView.swift`、`SettingsWindowView.swift`、`OnboardingGuideView.swift`
  - `Sources/MijiaCore/HomeStore+ControlWrite.swift`、`UpdateScheduler.swift`
