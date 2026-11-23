# 11 高口碑 macOS 应用的视觉与动效实现

- **调研日期**：2026-11-23
- **调研范围**：刘海/灵动岛类（`TheBoredTeam/boring.notch`、`MrKai77/DynamicNotchKit`、`Lakr233/NotchDrop`）、高口碑效率应用与设计剖析（`MrKai77/Loop`、`jordanbaird/Ice`、CleanShot X / Raycast / Arc / Things 3 公开工程分享）、macOS 26 Liquid Glass API 与性能边界、SF Symbols / `numericText` / `NSHapticFeedbackManager` / `accessibilityReduceMotion`、菜单栏状态图标渲染（`exelban/stats`、`sfsam/Itsycal`、One Thing），并对照审计 `Sources/MenuBarMijiaApp/` 与 `Classic/` 全量动效与视觉实现。
- **实际阅读的仓库与版本（`~/.cache/mbh-research-clones/`）**：
  - `TheBoredTeam/boring.notch` @ `b7611bb`（2026-10-31）
  - `MrKai77/DynamicNotchKit` @ `cd0b3e5`（2026-02-18）
  - `Lakr233/NotchDrop` @ `e70b3d7`（2026-05-19）
  - `MrKai77/Loop` @ `ad8564a`（2026-11-22）
  - `jordanbaird/Ice` @ `11edd39`（2025-09-20）
  - `exelban/stats` @ `f47dca1`（2026-11-22）
  - `sfsam/Itsycal` @ `287576c`（2026-11-13）

---

## 0. 结论先行

1. **展开与收起弹簧必须非对称**：`boring.notch` 展开用 `response: 0.42, dampingFraction: 0.8` 带轻微弹性反馈，收起用 `response: 0.45, dampingFraction: 1.0` 临界阻尼零回弹；`DynamicNotchKit` 区分刘海（`.bouncy(duration: 0.4)`）与无刘海悬浮（`.snappy(duration: 0.4)`），收起统一 `.smooth(duration: 0.4)`【源码：`TheBoredTeam_boring.notch/boringNotch/ContentView.swift:123-124`；`MrKai77_DynamicNotchKit/.../DynamicNotchStyle.swift:66-80`】。
2. **Hover 展开与关闭都需要时间窗口防抖**（`boring.notch` 进入等待 `minimumHoverDuration`、离开延迟 `100ms`、拖拽退出延迟 `500ms`），否则鼠标掠过或误触边缘会引发闪烁【源码：`TheBoredTeam_boring.notch/boringNotch/ContentView.swift:228-230, 530-557`】。
3. **`GlassEffectContainer` 严禁包裹整个滚动卡片列表，且需规避 macOS 26.0 早期材质过渡 Bug**：WWDC25 指南与 `Loop` 实战均表明，`GlassEffectContainer` 用于静态悬浮控制层合并边框以减少 draw call，包裹滚动列表会导致每帧光学采样掉帧；且 `Loop` 明确记录 `GlassEffectContainer` + materialize transition 在 macOS 26.0.0/26.0.1 会触发约束更新异常【源码：`MrKai77_Loop/.../RadialMenuView.swift:47-50`；【文档】WWDC25】。
4. **我们自己的动效体系已搭好骨架但存在「Token 漂移」**：`AppleMotion` 定义了 7 个标准曲线，但全仓 `293` 处动画调用中仍有 `60+` 处散落硬编码 `.spring(response:dampingFraction:)`（如 `0.45/0.8`、`0.42/0.82`、`0.3/0.7`、`0.6/0.8`），且 `DeviceCardView` 的设备列表整体包在 `AdaptiveGlassContainer` 中，存在滚动性能隐患【源码：`Sources/MenuBarMijiaApp/ThemeAndMotion.swift:154-179`；`Sources/MenuBarMijiaApp/ControlCenterPanelLayout.swift:700`】。
5. **`LiquidGlassSlider` 与 `BreathingDot` 名实不副**：`LiquidGlassSlider` 在 `ThemeAndMotion.swift` 只有 `classicBody`（手绘白色线性渐变滑块，未使用 macOS 26 `.glassEffect(.regular.interactive())` 原生滑块拇指），`BreathingDot` 则是完全静止的 `7pt` 圆点，未加呼吸动画【源码：`Sources/MenuBarMijiaApp/ThemeAndMotion.swift:747, 799-875`；`Sources/MenuBarMijiaApp/PanelDesign.swift:158-166`】。
6. **高口碑菜单栏图标靠「动态位图/NSView 自绘 + 等宽数字稳位」消除跳动**：`Itsycal` 用 `NSImage(size:flipped:drawingHandler:)` + `NSCompositingOperation.XOR` 挖空绘制矢量模板圆角徽章并用虚拟 `NSStatusBarButton` 算固定宽度；`Stats` 直接在 `statusItem.button` 内嵌 `canDrawConcurrently = true` 的 CoreGraphics `NSView` 绘制多色状态点与胶囊图形【源码：`sfsam_Itsycal/Itsycal/ViewController.m:741-775, 816-845`；`exelban_stats/Kit/Widgets/Dot.swift:14-56`】。
7. **触感反馈在全仓分散调用且未与 `Feedback.swift` 统一收敛**：目前 `NSHapticFeedbackManager.defaultPerformer.perform(...)` 散落在 6 个文件中（`.alignment` 与 `.levelChange`），而 `Feedback.swift` 仅管理 `SoundFeedback`【源码：`Sources/MenuBarMijiaApp/Feedback.swift:6-28`；`Sources/MenuBarMijiaApp/PanelDesign.swift:322, 353`】。
8. **先动效后显窗 / 窗口淡出遮盖残影是 `NSPanel` 零抖动的关键**：`DynamicNotchKit` 在 `orderFrontRegardless()` 前先用 `alphaValue = 0` 并触发 `withAnimation` 状态切换，再用 `0.15s easeOut` 淡入窗口；关闭时等待 `0.25s` 后用 `0.15s easeIn` 淡出再销毁，彻底消灭首帧闪烁【源码：`MrKai77_DynamicNotchKit/.../DynamicNotch.swift:188-195, 304-331, 395-408`】。

---

## 1. 刘海/灵动岛类：曲线、Hover 意图、几何融合与降级

### 1.1 `TheBoredTeam/boring.notch`（`b7611bb`）

- **第一层（定位）**：将 MacBook 刘海扩展为音乐胶囊、系统 HUD（音量/亮度）与文件暂存架（Shelf）。
- **第二层（架构）**：单 `ContentView` 驱动收起/展开/悬浮态，通过 `BoringViewModel` 管理状态与屏幕 UUID 映射，依赖 `NotchShape` 与 `NSWindow` 协同呈现。
- **第三层（关键机制与参数）**：
  - **非对称弹簧曲线**【源码：`TheBoredTeam_boring.notch/boringNotch/ContentView.swift:41, 123-128`；`boringNotch/animations/drop.swift:19-24`】：
    - 展开：`Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)`（轻度过冲带来弹性感）。
    - 收起：`Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)`（`dampingFraction: 1.0` 临界阻尼，避免边缘撞回屏幕顶部产生弹跳穿帮）。
    - 手势跟随：`Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)`，缩放进度用 `.animation(.smooth, value: gestureProgress)`。
    - `BoringAnimations` 默认兜底：macOS 14+ 刘海用 `.spring(.bouncy(duration: 0.4))`，老系统或无刘海回退到 `.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)`。
  - **Hover 意图判定与防抖状态机**【源码：`TheBoredTeam_boring.notch/boringNotch/ContentView.swift:150-182, 217-241, 513-558`】：
    - 指针进入（`hovering == true`）：先以 `animationSpring` 点亮 `isHovering` 与阴影（并触发一次 `.sensoryFeedback(.alignment, trigger: haptics)`），再起异步 `hoverTask` 睡 `Defaults[.minimumHoverDuration]`；若期间未取消且仍 `isHovering && !sneakPeek.show`，才执行 `doOpen()`。
    - 指针离开（`hovering == false`）：起 `100ms` 延迟任务，防止鼠标短暂擦过边缘或从刘海移向内部弹出层时误收起。
    - 拖拽文件离开（`anyDropZoneTargeting == false`）：延迟 `500ms` 再检查 `vm.dropEvent`，避免拖放释放瞬间触发关闭。
  - **`matchedGeometryEffect` 跨状态连续性**【源码：`TheBoredTeam_boring.notch/boringNotch/ContentView.swift:34, 398, 460`；`NotchHomeView.swift:88`；`TabSelectionView.swift:36-46`】：
    - 收起态左侧专辑封面与展开态 `AlbumArtView` 共享 `@Namespace var albumArtNamespace`（id `"albumArt"`），右侧频谱共享 id `"spectrum"`。
    - 底部 Tab 选中态胶囊使用“双支同 id + 非选中态 `.hidden()`”技巧（`matchedGeometryEffect(id: "capsule", in: animation)`），保证 SwiftUI 在切换首帧就能算准起止几何而不会从 `(0,0)` 飞入。
  - **刘海几何适配与无刘海屏回退**【源码：`TheBoredTeam_boring.notch/boringNotch/sizing/matters.swift:39-78`；`BoringViewModel.swift:106-129`】：
    - 有刘海判定：`screen.safeAreaInsets.top > 0`；宽度 = `screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width + 4`（两侧各补 2pt 消除亚像素缝隙，失败则回退 `185pt`）。
    - 无刘海屏回退：高度读取 `Defaults[.nonNotchHeight]` 或 `screen.frame.maxY - screen.visibleFrame.maxY`（菜单栏高度），在全屏模式下若无刘海则将 `effectiveClosedNotchHeight` 降为 `0`（收起隐藏），并在底部预留 `10pt` padding 承接投影。

### 1.2 `MrKai77/DynamicNotchKit`（`cd0b3e5`）

- **第一层（定位）**：开源可复用 SwiftUI 灵动岛框架（支持 `.expanded`、`.compact`、`.hidden` 三态）。
- **第二层（架构）**：`DynamicNotch` 持有 `DynamicNotchPanel`（`.borderless, .nonactivatingPanel`），按屏幕是否含刘海在 `NotchView` 与 `NotchlessView` 间自动切换。
- **第三层（关键机制与参数）**：
  - **风格化预设与覆盖层**【源码：`MrKai77_DynamicNotchKit/.../DynamicNotchStyle.swift:45-80`；`DynamicNotchTransitionConfiguration.swift:24-57`】：
    - `.notch` 默认圆角 `(topCornerRadius: 15, bottomCornerRadius: 20)`，收起态 `(top: 6, bottom: 14)`；`.floating` 默认 `cornerRadius: 20`。
    - 动画默认值：刘海打开 `.bouncy(duration: 0.4)`，悬浮打开 `.snappy(duration: 0.4)`，关闭 `.smooth(duration: 0.4)`，紧凑/展开切换 `.snappy(duration: 0.4)`；通过 `DynamicNotchTransitionConfiguration` 支持外部覆盖任意曲线及 `skipIntermediateHides`。
  - **消除 `NSPanel` 首帧闪烁的「先触发状态动画、再显窗」模式**【源码：`MrKai77_DynamicNotchKit/.../DynamicNotch.swift:185-195, 304-331, 395-408`】：
    - 首次弹出：`initializeWindow(..., orderFront: false)` → `withAnimation(effectiveOpeningAnimation) { self.state = .expanded }` → `showWindow()` 将窗口 `alphaValue = 0` 并 `orderFrontRegardless()`，随即 `NSAnimationContext` `0.15s` `.easeOut` 淡入 `alphaValue = 1`。
    - 隐藏时：先 `withAnimation(effectiveClosingAnimation) { state = .hidden }`，等待 `0.25s`（覆盖大部分形变时长）后执行 `0.15s` `.easeIn` `alphaValue -> 0`，最后 `deinitializeWindow()` 销毁控制器。
  - **`NotchShape` 与过冲兜底**【源码：`MrKai77_DynamicNotchKit/.../NotchShape.swift:10-119`；`NotchView.swift:58-76`】：
    - 实现 `AnimatablePair<CGFloat, CGFloat>` 同步插值 `topCornerRadius` 与 `bottomCornerRadius`，用两段 `addQuadCurve` 在顶部向两侧凹出贴合屏幕物理刘海的“耳廓”曲线；底层黑色背景故意 `.padding(-50)`，防止 `.bouncy` 过冲时边缘露白。
  - **非对称紧凑内容居中偏移补偿**【源码：`MrKai77_DynamicNotchKit/.../NotchView.swift:52-76, 111-125`】：
    - 通过 `.onGeometryChange(for: CGFloat.self, of: \.size.width)` 实时测量左右紧凑视图宽度，将整体水平偏移 `compactXOffset = (compactTrailingWidth - compactLeadingWidth) / 2`（`.animation(.smooth, ...)`），确保中间刘海槽位始终死死咬住硬件中心线。
  - **无刘海屏回退 (`NotchlessView`)**【源码：`MrKai77_DynamicNotchKit/.../NotchlessView.swift:28-55`】：
    - 不再贴顶绘制黑底刘海，而是改用 `VisualEffectView(material: .popover, blendingMode: .behindWindow)` + `1pt .quaternary` 描边，收起时用 `-windowHeight`（由 `onGeometryChange` 实时测量）垂直滑出屏幕顶部；并自动禁用 `.compact` 态（调用 `compact()` 直接 `hide()`）。

### 1.3 `Lakr233/NotchDrop`（`e70b3d7`）

- **第三层关键细节**：
  - **强回弹交互弹簧**：使用 `.interactiveSpring(duration: 0.5, extraBounce: 0.25, blendDuration: 0.125)` 驱动刘海微凸（`.popping`，宽不变、高度 `+4pt`、圆角 `8 → 10`）与全开（`.opened`，`600×160`、圆角 `32`）两级展开【源码：`Lakr233_NotchDrop/NotchDrop/NotchViewModel.swift:21-26`；`NotchView.swift:15-41`】。
  - **全局鼠标轮询 + 节流触感**：通过全局鼠标位置流检测是否进入 `deviceNotchRect.insetBy(dx: -4, dy: -4)` 触发 `.popping`，并用 Combine `.throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: false)` 限制 `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)` 频率，防止鼠标在边缘反复抖动导致触控板狂震【源码：`Lakr233_NotchDrop/NotchDrop/NotchViewModel+Events.swift:56-93`】。
  - **刘海硬件识别严谨度**：不仅检查 `safeAreaInsets.top > 0`，还同时校验 `auxiliaryTopLeftArea?.width > 0 && auxiliaryTopRightArea?.width > 0` 以及 `CGDisplayIsBuiltin(rid) == 1`【源码：`Lakr233_NotchDrop/NotchDrop/Ext+NSScreen.swift:10-33`】。

---

## 2. 窗口与菜单栏工具视觉/动效（Loop / Ice / 行业公开分享）

### 2.1 `MrKai77/Loop`（`ad8564a`）：径向菜单、预览窗与用户可选动效档位

- **五档时间曲线配置体系 (`AnimationConfiguration`)**【源码：`MrKai77_Loop/Loop/Utilities/AnimationConfiguration.swift:11-79`】：
  Loop 把“窗口预览”和“径向菜单”的动效解耦为 5 档供用户选（默认 `.snappy`）：

| 档位 | 预览窗曲线 (`previewWindow`) | 径向菜单大小 (`radialMenuSize`) | 径向菜单角度 (`radialMenuAngle`) |
| --- | --- | --- | --- |
| `fluid` | `timingCurve(0, 0.26, 0.45, 1, duration: 0.325)` | `easeOut(0.20s)` | `timingCurve(0.22, 1, 0.36, 1, duration: 0.20s)` |
| `relaxed` | `timingCurve(0.15, 0.8, 0.46, 1, duration: 0.30)` | `easeOut(0.20s)` | 同上 |
| `snappy` (默认) | `timingCurve(0.22, 1, 0.47, 1, duration: 0.25)` | `easeOut(0.20s)` | 同上 |
| `brisk` | `timingCurve(0.25, 1, 0.48, 1, duration: 0.15)` | `easeOut(0.15s)` | 同上 |
| `instant` | `nil`（无动画） | `easeOut(0.10s)` | `.linear(0s)` |

  > 注：Loop 刻意使用高初速、零回弹的 `easeOutQuint/Cubic` 类贝塞尔曲线（起点控制点 `x1 = 0..0.25, y1 = 0.26..1.0`）做窗口框预览，避免窗口尺寸预览出现“来回抖动”干扰空间判断；这与我们 `MenuBarPanelController+Presentation.swift:26-27` 参考通知中心测得的 `fadeCurve (0.44, 1, 0.54, 0.98)` 思路高度一致。

- **径向菜单进场与 Liquid Glass 适配**【源码：`MrKai77_Loop/.../RadialMenuView.swift:45-94, 191-206`；`RadialMenuViewModel.swift:97-115`】：
  - 进场用 `.smooth(duration: 0.1)`，阴影延迟 `0.05s` 跟进（`shadowAnimationTrimFactor = 0.05`），配合 `.transition(.scale(scale: 1.25).combined(with: .opacity))` 从大向小收敛。
  - **macOS 26 环形玻璃边界修补**：把 `.glassEffect(.regular.tint(color1.opacity(0.025)), in: .rect(cornerRadius: radialMenuCornerRadius))` 先遮罩出环形（`strokeBorder` mask），再用 `0.5pt` `LinearGradient([.white, .clear, .white])` 手动补回内圈高光边缘（因为遮罩裁掉了原生内圈高光）。
  - **避坑实录**：注释明确指出 `GlassEffectContainer` + materialize transition 在 macOS 26.0.0/26.0.1 会引发 `NSWindow Update Constraints` 异常。
- **预览窗起手帧技巧与圆角匹配**【源码：`MrKai77_Loop/.../PreviewViewModel.swift:32-36, 68-82, 102-120`】：
  - 首次显示前先**无动画**将 `computedFrame` 设为起点（屏幕中心零尺寸或光标位置），再在下一行 `withAnimation` 赋值为目标矩形，确保每次呼出都从原点长出来。
  - macOS 26 上通过 `Self.getCornerRadius(for: window)` 实时读取目标窗口物理圆角再减去 `previewPadding`（`overrideCornerRadii?.inset(by: previewPadding)`），兜底 `16pt`，做到“同心圆角（Concentric Radii）”。

### 2.2 `jordanbaird/Ice`（`11edd39`）：菜单栏视觉叠加与透明层一致性

- **视觉实现架构**【源码：`jordanbaird_Ice/Ice/UI/IceBar/IceBar.swift:20-38, 173-181, 255-306`；`LayoutBarStyle.swift:14-55`；`MenuBarOverlayPanel.swift:82-98, 463-511`】：
  - **无闪色预计算**：`IceBarPanel` 在 `orderFrontRegardless()` **之前**同步更新 `updateOrigin(for:)` 和 `colorManager.updateAllProperties(with: frame, screen: screen)`，避免面板弹出瞬间背景色闪烁【源码：`IceBar.swift:173-181`】。
  - **壁纸采样 + 材质叠加**：通过 `ScreenCapture.captureWindow(wallpaperWindow.windowID, screenBounds: menuBarWindow.frame)` 截取菜单栏区域桌面壁纸算平均亮度（亮度 `> 0.67` 切黑色前景字，否则白色），再叠一层 `Material.bar.opacity(0.2..0.5).blendMode(.softLight)` 与可选 20% 实色/渐变 tint，最后用 `shadow(opacity: 0.33..0.5, radius: 2.5)` 收边【源码：`IceBar.swift:291-294`；`LayoutBarStyle.swift:19-34`；`MenuBarOverlayPanel.swift:294-305`】。
  - **胶囊 vs 圆角矩形自适应**：高度按真实菜单栏高度减 `inset * 2`，胶囊形用 `Capsule()` + `7pt` 横向内边距，圆角矩形用 `cornerRadius: frame.height / 5`（近似 20% 高度比例）+ `5pt` 横向内边距【源码：`IceBar.swift:255-279`】。

### 2.3 CleanShot X / Raycast / Arc / Things 3 公开设计与工程分享要点

- **Raycast**：官方架构复盘明确指出，早期版本为追求零延迟与精细键盘交互全部用 **AppKit + Swift** 手搓核心列表与快捷键面板（仅将 SwiftUI 用于 Wrapped 等独立展示页）；同时强调交互即时反馈、紧凑排版与高对比度层级【检索：`raycast.com/blog`】。
- **Arc Browser（The Browser Company）**：社区与团队公开讨论显示，Arc 早期重度采用 SwiftUI + TCA，但在侧边栏高频拖拽、标签切换与窗口缩放性能打磨中，关键性能路径回迁纯 AppKit 以换取零丢帧和可控的交互弹簧响应【检索：`mjtsai.com` / `fatbobman.com`】。
- **Things 3（Cultured Code）**：以 **Magic Plus** 拖拽定位插入、任务卡片由行内紧凑态原地无缝展开为“纸片”详情态闻名；核心设计原则是**动效必须作为空间因果线索**（告知“从哪里展开、拖到哪里去”），而非纯粹装饰，且配合高留白与强字重层级替代厚重分割线【检索：`culturedcode.com`】。
- **CleanShot X**：强调即时浮窗反馈（截图后缩略图滑入边缘停靠、快速标注工具条随选区弹出、零模态打断工作流）【检索：CleanShot X 公开设计特征，具体源码未开源，仅作交互范式参考】。

### 2.4 可借鉴的具体参数速查表

| 场景 / 机制 | 来源项目 | 具体参数 / API | 适用建议 |
| --- | --- | --- | --- |
| **浮层展开 vs 收起非对称弹簧** | `boring.notch` | 展开 `.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)`；收起 `.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)` | 展开带微弹性，收起临界阻尼防止撞边弹回 |
| **跟手交互弹簧** | `boring.notch` / `NotchDrop` | `boring.notch`: `.interactiveSpring(response: 0.38, dampingFraction: 0.8)`；`NotchDrop`: `.interactiveSpring(duration: 0.5, extraBounce: 0.25, blendDuration: 0.125)` | 拖拽/手势缩放类反馈 |
| **Hover 意图与离场防抖** | `boring.notch` | 进入等 `minimumHoverDuration`；离开防抖 `100ms`；拖拽离开防抖 `500ms` | 悬停抽屉（如搜索推荐抽屉 `inputDrawer`）防误关 |
| **无刘海屏回退材质与动画** | `DynamicNotchKit` | 展开 `.snappy(duration: 0.4)`；收起 `.smooth(duration: 0.4)`；材质 `VisualEffectView(.popover, .behindWindow)` + `1pt .quaternary` 描边 + `cornerRadius: 20` | 兼容 macOS 14/15 悬浮窗样式 |
| **NSPanel 首帧防闪与退场** | `DynamicNotchKit` | 创建不显窗 → 先 `withAnimation` 改状态 → `alpha=0` `orderFrontRegardless` + `0.15s .easeOut` 淡入；退场等 `0.25s` 后 `0.15s .easeIn` 淡出再销毁 | 替代无动画直切或消除首帧布局跳变 |
| **零回弹窗口预览曲线** | `Loop` (`snappy`) | `timingCurve(0.22, 1, 0.47, 1, duration: 0.25)`；角度切换 `timingCurve(0.22, 1, 0.36, 1, duration: 0.20)`；阴影滞后 `0.05s` | 尺寸预览与快速切换类控件 |
| **同心圆角公式** | `DynamicNotchKit` / `Loop` | `Outer Radius = Inner Radius + Padding`（`Loop` 实测 macOS 26 兜底 `16pt` 再 `inset(by: padding)`） | 卡片内嵌抽屉/子块圆角对齐 |
| **动态模板图标 + 防抖定宽** | `Itsycal` | `NSImage(size:flipped:drawingHandler:)` + `NSCompositingOperation.XOR` + `isTemplate = YES`；离线 `dummyButton` 配 `kMonospacedNumbersSelector` 算定宽 | 状态栏数字/告警徽章防左右位移 |
| **状态点与触感节流** | `Stats` / `NotchDrop` | `8×8pt` `DotWidget`（`canDrawConcurrently = true`）；Combine `.throttle(for: .seconds(0.5), latest: false)` 限频 `.levelChange` | 高频事件触感防狂震 + 状态小圆点 |

---

## 3. macOS 26 Liquid Glass：`glassEffect` / `GlassEffectContainer` / `NSGlassEffectView` 实战与性能

综合 WWDC25 官方 Session（*Meet Liquid Glass* / *Build a SwiftUI app with the new design*）及 `MrKai77/Loop`、社区开源实践：

1. **光学原理与层级定位（Control Layer Only）**【文档：WWDC25；检索：`dev.to` / `apple.com`】：
   - Liquid Glass（`NSGlassEffectView` / `.glassEffect(_:in:)`）不是传统高斯模糊（`NSVisualEffectView`），而是实时桌面采样 + 光学折射/透镜边缘高光（lensing）。
   - **禁止 Glass-on-Glass 堆叠**：两层原生玻璃直接叠放会导致内层无法正确采样桌面折射，引发严重重绘性能下降与灰暗伪影。
   - **禁止贴在滚动内容区或长列表项上**：苹果明确要求 Liquid Glass 只属于**导航/悬浮控制层**（工具栏、浮窗、标题栏、浮动按钮），滚动区域应保持无玻璃或轻量材质，让内容在静止的玻璃下方滚动（配合 `.scrollEdgeEffectStyle(.soft, for: .top)` 柔化滚动边缘）。
2. **`GlassEffectContainer` / `NSGlassEffectContainerView` 的正确用法与坑点**：
   - **正确用途**：把**紧邻的静态控制组**（如头部操作按钮组、底部工具条、分组胶囊）放进 `GlassEffectContainer(spacing:)`，让引擎合并相邻玻璃边缘并批处理渲染着色器【源码：`ThemeAndMotion.swift:648-651`；文档：WWDC25】。
   - **状态变形**：结合 `@Namespace` + `.glassEffectID(_:in:)`（或 `.glassEffectUnion(id:namespace:)`）在形态切换（如折叠胶囊 ↔ 展开搜索框 / Segmented Control 选区）时实现液态融合变形【检索：GitHub macOS 26 sample apps】。
   - **已知系统坑点**：
     - `Loop` 实测 macOS 26.0.0/26.0.1 中 `GlassEffectContainer` + materialize transition 会报 `Update Constraints` 异常【源码：`MrKai77_Loop/.../RadialMenuView.swift:47-50`】。
     - `NSPanel` + `NSHostingView` 使用 `NSGlassEffectView` 或 `.glassEffect()` 时，必须设 `hosting.sizingOptions = []` 避免 SwiftUI 内在尺寸与窗口边界互相争抢导致边缘闪烁（我们已经在 `MenuBarPanelController.swift:903` 做对了这一步！）【源码：`MenuBarPanelController.swift:903`；检索：`reddit.com` macOS 26 `NSGlassEffectView`】。
     - 若窗口在不可见/离屏状态下触发快照，玻璃无真实背景可采样会退化为暗色或空白底【检索：GitHub / Reddit macOS 26 issues】。

---

## 4. 微交互四件套：SF Symbols 动效、数字滚动、触感与减弱动态

| 维度 | 行业标杆做法（已读源码） | 我们当前实现（已读源码） | 差距与可优化点 |
| --- | --- | --- | --- |
| **SF Symbols 动效** | `Loop` 径向图标用 `.transition(.symbolEffect(.drawOn, options: .speed(2)))` + `.contentTransition(.symbolEffect(.replace, options: .speed(2)))`【源码：`RadialMenuView.swift:196-197`】；`boring.notch` `HoverButton` 统一封装 `.contentTransition(.symbolEffect)`【源码：`HoverButton.swift:15, 34`】 | 仅 5 处使用：`searchButton`（`.contentTransition(.symbolEffect(.replace))`）、`SmallDeviceTile` & `ClassicDeviceCardView` & `ClimatePanelModule`（`.symbolEffect(.bounce, value: isOn)`）、`omnibar`（`.variableColor.iterative` / `.pulse`）【源码：`ControlCenterPanelChrome.swift:148`；`SmallDeviceTile.swift:34`；`ControlCenterPanel.swift:623-624`】 | 1）未在 `.symbolEffect` 传 `isActive` 或检查 `reduceMotion`（`.transaction { disablesAnimations }` 对部分 `symbolEffect` 重复动画效果有限）；2）缺 `.replace` 应用于图标切换（如窗帘开/合、风速档位、展开箭头 `chevron.right`/`down` 还在硬切） |
| **数字滚动 (`numericText`)** | `Loop` 更新进度、版本号全部加 `.contentTransition(.numericText())`，悬停倒计时用 `countsDown:` 参数控制滚动方向【源码：`AboutConfiguration.swift:206, 264`；`UpdateView.swift:184, 234`】 | 仅 4 处使用：`ClimatePanelModule` 目标温度、`SensorCardView`（含 Classic）温度读数、`ControlCenterPanelStacks`（含 Classic）分组设备计数【源码：`ClimatePanelModule.swift:159`；`SensorCardView.swift:768`；`ControlCenterPanelStacks.swift:559`】 | 漏掉了几个高频变化数字：`SensorCardView` 的**湿度环百分比**（有 `.spring(0.6, 0.8)` 弧度动画但文字无 `.numericText()`）、`LiquidGlassSlider` 的 `formattedValue`、`DeviceCardView` 瓦数/电量/亮度文本 |
| **触感反馈 (`NSHapticFeedbackManager`)** | `DynamicNotchKit` 仅在首次 hover 进入时触发 `.alignment`；`NotchDrop` 用 Combine `throttle(0.5s)` 节流 `.levelChange`；`Loop` 在窗口吸附切换时触发 `.alignment`【源码：`DynamicNotch.swift:163-166`；`NotchViewModel+Events.swift:84-93`；`LoopManager.swift:619`】 | 全部直调 `NSHapticFeedbackManager.defaultPerformer`：滑块每 10% 分桶 `.alignment`、拖拽重排 `.alignment`、All Off 确认 `.levelChange`【源码：`ThemeAndMotion.swift:783-796`；`PanelDesign.swift:322, 353`；`ControlCenterPanelLayout.swift:565`】 | 1）`Feedback.swift` 只管声音不管触感，缺乏统一 `HapticFeedback` 入口与开关；2）`ClimatePanelModule` 步进温度（`+/-`）、房间 pill 切换、设备开关点击均无触感；3）长按 `HoldToConfirmButton` 在 0.6s 完成瞬触发 `.levelChange` 很好，但按下开始没有轻微 `.generic`/`.alignment` 提示 |
| **减弱动态效果 (`accessibilityReduceMotion`)** | 系统级建议：用交叉淡入/即时状态替换位移与缩放，关闭 `symbolEffect` 弹跳与循环脉冲【文档：Apple HIG】 | `ThemeAndMotion.swift:11-36` 自建可测试的 `effectiveReduceMotion` 覆盖键；`ControlCenterPanel` 根部加 `.transaction { if reduceMotion { $0.disablesAnimations = true } }`【源码：`ControlCenterPanel.swift:130`】 | 1）Settings 窗口与部分子组件未挂根部 `.transaction`，且存在 60+ 处裸 `withAnimation(.spring(...))` 未经 `reduceMotion` 守卫；2）`GlassHoverHighlight` 与 `PressableCardButtonStyle` 做了守卫，但 `LiquidGlassSlider` 拖拽拇指变宽与 `.symbolEffect(.bounce)` 未显式随 `reduceMotion` 关闭 |

---

## 5. 菜单栏图标本身：动态状态图标、模板图像与多状态徽章

### 5.1 对标实现剖析

1. **`sfsam/Itsycal`（`287576c`）：模板图像像素级控制 + 宽度防抖**
   - **矢量动态绘制 + `NSCompositingOperation.XOR` 挖空模板**【源码：`sfsam_Itsycal/Itsycal/ViewController.m:782-846`】：
     - 用 `NSImage(size:flipped:drawingHandler:)` 按需缓存（`setName:` 存入缓存表）。
     - 先在居中偏移 `y: -1` 绘制 `11.5pt Bold/Semibold` 日期文字，再开启 `NSCompositingOperation.XOR` 填充 `cornerRadius: 4` 的圆角实心框（或描边 `insetBy(1, 1)` 空心框），最后设 `image.isTemplate = YES`。
     - **核心价值**：macOS 会自动根据浅色/深色壁纸、全屏菜单栏与选中高亮态完美反色，文字永远是透明镂空，绝不出现“黑底黑字”或“半透明灰字模糊”。
   - **虚拟按钮预测量消除数字跳动**【源码：`ViewController.m:606-625, 741-775`】：
     - 若用户开启带时间的标题但未开秒针，用带 `kMonospacedNumbersSelector` 的离线 `dummyButton` 计算 `sizeToFit()` 后固定 `_statusItem.length = NSWidth(dummyButton.frame) - 8`，防止时间从 `11:11` 跳到 `12:08` 时菜单栏右侧所有图标左右抖动。
2. **`exelban/stats`（`f47dca1`）：`NSStatusItem.button` 托管 `NSView` 实现多色复合微件**
   - **原理**：设置 `menuBarItem.button?.image = NSImage()` 占位，将自定义 `NSView`（`canDrawConcurrently = true`）直接 `addSubview` 到 `button` 并由 `widthHandler` 同步 `menuBarItem.length`【源码：`exelban_stats/Kit/module/widget.swift:280-285, 329-337`】。
   - **多状态徽章与颜色策略**：`DotWidget` 仅占用 `8×8pt`（加左右 margin）绘制 `.systemGreen` / `.systemRed` 状态圆点；`BatteryWidget` 在 `22×12pt` 电量框内嵌入百分比/充电闪电图标，且在设置项中显式区分 `colorState`（彩色告警 vs 单色适应系统）【源码：`exelban_stats/Kit/Widgets/Dot.swift:31-56`；`Battery.swift:133-160`】。
3. **`sindresorhus/One Thing`：极简纯文本状态项**
   - 官方 CLI 与产品定位表明其直接在 `NSStatusBarButton` 渲染单行简洁文本，依靠系统原生 `NSStatusBarButton` 渲染管线自动适配壁纸明暗，无额外图标重绘开销【检索：`sindresorhus.com/one-thing`；`github.com/sindresorhus/one-thing`】。

### 5.2 我们目前的菜单栏图标与痛点

当前实现在 `Sources/MenuBarMijiaApp/MenuBarPanelController.swift:768-810` 与 `Sources/MijiaCore/HomeStore+Metrics.swift:166-215` / `HomeStore+Alerts.swift:21-31`：
- **图标状态过于单一**：只有 `house`（全关）、`house.fill`（至少 1 台开启）、`house.slash`（米家会话失效阻塞控制）和 `waveform`（语音聆听中）。
- **告警染红破坏模板适配**：`hazard == true` 时把 `image.isTemplate = false` 并套 `.systemRed`（`MenuBarPanelController.swift:780-785`），虽然醒目，但无法区分**危及生命安全（烟雾/燃气/漏水）**与**普通提醒（门窗未关/长开超时）**，且失去高亮态（按下面板打开时系统高亮反色会发暗不协调）。
- **缺连接态与更新态微弱提示**：后台重连中、局域网/云端离线、有待重启应用更新、或正在执行自动化/定时任务时，图标完全无感知。
- **数字跳动**：`statusTitle` 虽已用 `.monospacedDigitSystemFont(ofSize: 12, weight: weight)`【源码：`MenuBarPanelController.swift:829-830`】，但 `statusItem` 仍为 `variableLength`，从 `"24.5°C"` 变成 `"Possibly stale"` 或从 `"9W"` 变成 `"120W"` 时会瞬间挤压相邻图标。

---

## 6. 我们的动效与视觉全量审计

### 6.1 动效曲线与时长清单（`rg` 全量盘点）

全仓 `Sources/MenuBarMijiaApp/` 共命中 `293` 处 `withAnimation` / `.spring` / `.animation` / `CA*Animation` / `CAMediaTimingFunction`：

| 类别 | 参数值 | 出现次数（约） | 主要位置与用途 | 评价 |
| --- | --- | --- | --- | --- |
| **Token: `AppleMotion.snappySpring`** | `spring(response: 0.26, dampingFraction: 0.94, blendDuration: 0.08)` | `139` 处（含 `withAnimation` 117 + `.animation` 17 + 带 `reduceMotion` 5） | 按钮点击、搜索框展开/清除、设备开关、Reauth 弹窗 | 核心主力曲线，参数极克制，接近无回弹 |
| **Token: `AppleMotion.control`** | `spring(response: 0.24, dampingFraction: 0.86)` | `9` 处 | `DeviceIconOrb` 亮灯、`GlassShapeBackground`、`DeviceLayout` hover 显隐 | 适合微控件状态切换 |
| **Token: `AppleMotion.reveal`** | `spring(response: 0.34, dampingFraction: 0.86)` | `11` 处 | `ControlCenterPanel` 列表裁剪、展开详情抽屉、网格重构 | 适合高度变化类容器 |
| **Token: `AppleMotion.stack`** | `spring(response: 0.38, dampingFraction: 0.84)` | `3` 处（`ActivityStackView` / `TransientStackView` / `Stacks`） | 通知堆叠卡片展开/收起 | 略柔和，贴合通知中心 |
| **Token: `AppleMotion.dismiss`** | `spring(response: 0.28, dampingFraction: 1.0)` | 定义于 `StackedCardGeometry.swift:40` | 卡片横扫消除 | 临界阻尼防弹回 |
| **Token: `AppleMotion.glassLensSpring`** | `spring(response: 0.20, dampingFraction: 0.88, blendDuration: 0.05)` | `4` 处 | `LiquidGlassSlider` / `ClassicLiquidGlassSlider` 按下拖拽变形 | 快速响应手势 |
| **Token: `AppleMotion.pressFeedback`** | `easeOut(duration: 0.12)` | `10+` 处 | `PressableCardButtonStyle`（scale `0.972`）与 `PillActionButtonStyle`（scale `0.97`） | 符合极速按压反馈 |
| **窗口级 AppKit 曲线** | `fadeIn`: `0.365s` `cubicBezier(0.44, 1, 0.54, 0.98)`<br>`close`: `0.217s` `cubicBezier(0.20, 0, 0.50, 1)`<br>`reduceMotion`: `0.2s` 淡入淡出 | 1 处（`MenuBarPanelController+Presentation.swift:24-27, 190-191`） | Liquid Glass 右侧列滑入/滑出（Classic 无入场动画） | 实测对齐 macOS 通知中心，非常专业 |
| **编辑抖动 `CAKeyframeAnimation`** | `±1.1°`, `1/3.6 s` (`~0.278s`), `.easeInEaseOut` | `ClassicLayoutEditing.swift:268-283` | 仅 Classic 遗留文件；Liquid Glass 新编辑模式已取消抖动 | 注意：`ClassicLayoutEditing` 需确认是否仍随 `reduceMotion` 关闭 |
| **散落硬编码弹簧（未 Token 化）** | `.spring(0.45, 0.8)` (12)<br>`.spring(0.42, 0.82)` (11)<br>`.spring(0.3, 0.85)` (10)<br>`.spring(0.4, 0.82)` (8)<br>`.spring(0.3, 0.8)` (5)<br>`.spring(0.3, 0.7)` (5)<br>`.spring(0.4, 0.8)` (4)<br>`.spring(0.50, 1.0)` (3)<br>`.spring(0.35, 0.75)` (3)<br>`.spring(0.6, 0.8)` (2) 等 | **70+ 处** | 集中分布于 `ControlCenterPanelLayout.swift`、`ClassicControlCenterPanelLayout.swift`、`ClimatePanelModule.swift`、`SensorCardView.swift`、`ControlCenterPanelChrome.swift` | **主要技术债**：同为重命名弹窗关闭与分组编辑，却同时存在 `0.45/0.8`、`0.42/0.82`、`0.3/0.85`、`0.4/0.82` 四套微调数值，且多处未显式判断 `reduceMotion` |

### 6.2 Liquid Glass 主题（`ThemeAndMotion.swift` + `ControlCenterPanel*`）深度诊断

1. **做对的地方**：
   - `MenuBarPanelController.swift:903` 设置了 `hosting.sizingOptions = []`，避开了 `NSPanel` 尺寸争抢 Bug；
   - `ThemeAndMotion.swift:504-511` 注释清晰强调不在 `.glassEffect` 前涂不透明 `.background`，保证桌面折射；
   - `GlassHoverHighlight`（`+0.03 white .plusLighter` 填充 + 顶部/底部 `1.5pt` 渐变边缘高光）与 `SpecularRim` 还原度极高；
   - `MenuBarPanelController+Presentation.swift:464-508` 用独立 `backdropWindow`（`.blur(radius: 32)`）承接暗色可读性衬底而非破坏卡片自身的玻璃质感；
   - `ControlCenterPanelLayout.swift:742-745` 明确把编辑 `−` 角标放到 `AdaptiveGlassContainer` 外部，避开了容器合成遮挡子视图溢出部分的问题。
2. **明确改进点（高价值）**：
   - **【性能风险】滚动设备区整体套了 `AdaptiveGlassContainer`**：`ControlCenterPanelLayout.swift:700` 把整个 `TileFlowLayout`（包含数十张可滚动设备卡）包在 `AdaptiveGlassContainer(spacing: 8)` 内，且 `DeviceCardView` 本身带 `.glassTile`（即 `.glassEffect`）与大量子按钮 `AdaptiveGlassContainer`。按 WWDC25 指南，**滚动视图内的卡片不应放进 `GlassEffectContainer` 做动态光学合并**，而应保留仅在固定头部 `panelHeader` / 工具栏使用 `AdaptiveGlassContainer`，或验证卡片区去掉外层 `AdaptiveGlassContainer` 后滚动帧率与 GPU 占用变化。
   - **【交互质感缺失】`LiquidGlassSlider` 缺少原生交互式玻璃拇指与滑轨膨胀**：`ThemeAndMotion.swift:799-875` 中的 `LiquidGlassSlider` 目前 `bodyWithChrome` 直接调 `classicBody`，拇指是用 `LinearGradient` 画的死白圆角矩形（`22→28pt` 宽），没有像 `GlassSwitch`（`ThemeAndMotion.swift:1115`）那样在 macOS 26+ 使用 `.glassEffect(.regular.interactive(), in: Capsule())`；拖动时没有真正的折射放大与 `isDragging` 光晕。
   - **【缺少 `glassEffectID` / `matchedGeometryEffect` 透镜滑动】**：`GlassSegmentedControl`（`ThemeAndMotion.swift:1250-1314`）目前选中态是个纯白静态胶囊（`.fill(.white)`），切换时靠布局重绘，没有用 `matchedGeometryEffect` 或 macOS 26 `.glassEffectID` 让白色/玻璃透镜在分段间丝滑滑动。同理，顶部房间筛选条（`ControlCenterPanelChrome.swift`）与分组栏切换也可享受透镜滑动。
   - **【假动画命名】`BreathingDot`**（`PanelDesign.swift:158-166`）无呼吸动画；当处于「重连中 / 语音聆听 / 严重告警」态时加入克制的 `opacity / scale` 周期呼吸（并在 `reduceMotion` 下关闭），能让状态点真正活起来。
   - **【背景渲染方式】`ControlCenterReadabilityBackdrop`**（`MenuBarPanelController+Presentation.swift:497-508`）使用 SwiftUI `.blur(radius: 32)` 套在额外一个 `NSPanel`（`backdropWindow`）上，每次面板滑入/高度自适应都在动态重算大半径高斯模糊；可评估改用预渲染径向/圆角渐变遮罩或 `NSShadow` / CALayer 静态阴影图片以降低离屏渲染开销。

---

## 7. 对照我们：差距表

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `Sources/MenuBarMijiaApp/ThemeAndMotion.swift` | 1) `AppleMotion` 7 个 Token 外还有 70+ 处裸 `.spring` 散落在各文件；<br>2) `LiquidGlassSlider` 仅画梯度白胶囊；<br>3) `GlassSegmentedControl` 选中态无滑动过渡；<br>4) `GlassHoverHighlight` 无防抖 | `Loop` 统一 `AnimationConfiguration` 曲线表；`DynamicNotchKit` `DynamicNotchTransitionConfiguration`；`boring.notch` `matchedGeometryEffect` 胶囊滑动 & Hover 防抖 | 1) 将散落 `.spring` 收敛到 `AppleMotion`（补 `reorder` `0.50/1.0`、`panelEntry` 等语义 Token）；<br>2) macOS 26 下给 `LiquidGlassSlider` 拇指升级 `.glassEffect(.regular.interactive())`；<br>3) `GlassSegmentedControl` 选中白透镜加 `matchedGeometryEffect`（26+ 可探 `.glassEffectID`） | **M** |
| `Sources/MenuBarMijiaApp/ControlCenterPanelLayout.swift` | 第 700 行将滚动区域内全部设备卡片包在 `AdaptiveGlassContainer(spacing: 8)` 中；拖拽/尺寸切换混用 `0.42/0.82`、`0.45/0.8`、`0.3/0.85`、`0.50/1.0` | WWDC25 Liquid Glass 规范：`GlassEffectContainer` 仅包裹静态悬浮导航/控制栏，不包滚动列表；`Loop` 规避容器过度合成 | 移除 `deviceCollectionView` 外层的 `AdaptiveGlassContainer`（保留每张卡自身 `.glassTile` 及顶部/抽屉内小胶囊组容器），并统一重排动画为 `AppleMotion.reveal` / `AppleMotion.reorder` | **S** |
| `Sources/MenuBarMijiaApp/PanelDesign.swift` | `BreathingDot` 为静态 7pt `Circle`；`HoldToConfirmButton` 按下无起始微触感 | `boring.notch` / `NotchDrop` 在状态激活态采用轻呼吸或脉冲并尊重 `reduceMotion` | 为 `BreathingDot` 在「重连/报警/思考」态增加轻柔周期脉冲（`reduceMotion` 下保持静态）；为 `HoldToConfirmButton` 按下与完成分别配轻/重触感 | **S** |
| `Sources/MenuBarMijiaApp/Feedback.swift` | 仅封装 `SoundFeedback`；`NSHapticFeedbackManager` 散落 6 个文件硬编码调用 | `NotchDrop` 统一 `hapticSender` + Combine `throttle(0.5s)` 节流；`Loop` 动作节点统一触发 `.alignment` | 在 `Feedback.swift` 新增 `HapticFeedback`（提供 `.tick()`、`.alignment()`、`.confirm()` 及节流/开关支持），清理散落直调，为气候步进/房间切换补微触感 | **S** |
| `Sources/MenuBarMijiaApp/SensorCardView.swift` & `ControlCenterPanelChrome.swift` | 仅目标温度/传感器温度/分组计数有 `.contentTransition(.numericText)`；卡片展开箭头与湿度百分比文本无过渡 | `Loop` 所有动态数字加 `.contentTransition(.numericText())`，图标切换加 `.contentTransition(.symbolEffect(.replace))` | 为湿度百分比、滑块读数、瓦数/设备开启数补充 `.numericText()`；为展开箭头与开关图标补 `.symbolEffect(.replace)` 并统一受 `reduceMotion` 控制 | **S** |
| `Sources/MenuBarMijiaApp/MenuBarPanelController.swift` | 仅 `house`/`house.fill`/`house.slash`/`waveform`；`hazard` 时关掉 `isTemplate` 强染红；`variableLength` 随数字长度变化引发状态栏邻近图标轻微位移 | `Itsycal` 用 `XOR` 挖空绘制矢量 `isTemplate = true` 徽章 + 离线测宽固定宽度；`Stats` 用 `NSView` 子视图绘制小尺寸状态色点（`8×8pt`）且区分颜色与模板态 | 拆分「基础模板图标 + 可选右侧小徽章/状态点」，区分生命安全告警（红点/叹号徽章）与连接离线/待更新/执行中状态；对高频变化读数采用等宽数字 + 宽度锁定滞回（防抖动） | **M** |
| `Sources/MenuBarMijiaApp/MenuBarPanelController+Presentation.swift` | `backdropWindow` 用实时 `.blur(radius: 32)` 做阴影衬底；Classic 主题完全无入场/退场动画 | `DynamicNotchKit`“先触发状态动画再 0.15s 淡入窗口”消除闪烁；`Loop` `timingCurve(0.22, 1, 0.47, 1, 0.25s)` 轻量稳态 | 1) 评估 `backdropWindow` 改用预绘制渐变阴影图替代每帧大半径 `.blur(radius: 32)`；<br>2) 可选为 Classic 弹窗补超短 `0.12s` 淡入（或维持零延迟但优化首帧 `displayIfNeeded`） | **S–M** |
| `Sources/MenuBarMijiaApp/Classic/` | 单独维护一套 `ClassicThemeAndMotion` / `ClassicPanelDesign` / `ClassicControlCenterPanel*`，含较多硬编码 `.spring` 与 `CAKeyframeAnimation` 抖动 | `DynamicNotchKit` 通过 `Style` 枚举共享动画管线；`Loop` 通过 `if #available(macOS 26.0, *)` 单一视图分支 | 逐步让 `Classic/` 复用 `AppleMotion` Token 与 `HapticFeedback`，避免同一行为在两套主题出现不同的阻尼手感 | **M** |

---

## 8. 推进清单（按优先级排序）

1. **收敛散落 `.spring` 曲线至 `AppleMotion` 并全面对齐 `effectiveReduceMotion`**
   - **价值**：消除同一弹窗/卡片在不同交互路径下弹跳不一致的割裂感，保证减弱动态效果无障碍合规。
   - **成本**：S–M（机械替换 + 局部快照检查）
   - **优先级**：**P0**
   - **涉及高风险面？**：否（纯局部 UI/交互调整，默认快车道可先做）。
   - **依据**：`rg` 审计实测全仓 293 处动画中有 70+ 处散落硬编码弹簧参数，且多处缺少 `reduceMotion` 分支【源码：`ControlCenterPanelLayout.swift`、`ClimatePanelModule.swift`、`Classic/`】。

2. **移除设备滚动区外层 `AdaptiveGlassContainer`，仅保留静态悬浮控制层容器**
   - **价值**：消除大量卡片在滚动与重排时的无效光学边缘合并计算，直接改善 macOS 26 GPU 帧率与发热。
   - **成本**：S（1 处包裹剥离 + `macos-test` 快照/性能验证）
   - **优先级**：**P0**
   - **涉及高风险面？**：否（视觉微调需跑 `bash scripts/check.sh` 确认 macOS 26 快照）。
   - **依据**：WWDC25 Liquid Glass 性能规范与 `ControlCenterPanelLayout.swift:700` 现状【源码：`ControlCenterPanelLayout.swift:700`；文档：WWDC25】。

3. **升级 `LiquidGlassSlider` 原生交互式玻璃拇指与 `GlassSegmentedControl` 滑动透镜**
   - **价值**：让 Liquid Glass 主题最核心的两类高频控件（调光/色温滑块、房间/分组分段器）真正具备 macOS 26 原生质感与连续空间过渡。
   - **成本**：M（需在 macOS 26 实机/CI 核对 `.glassEffect(.regular.interactive())` 视觉表现与快照）
   - **优先级**：**P1**
   - **涉及高风险面？**：否（需跑全量视觉快照与 Slider 交互测试）。
   - **依据**：`ThemeAndMotion.swift:747, 799-875, 1250-1314` 现状 vs `GlassSwitch`（`1115` 行）及 `boring.notch` `matchedGeometryEffect` 用法。

4. **统一 `Feedback.swift`（新增 `HapticFeedback` 节流工具）+ 补齐 `.numericText()` / `.symbolEffect(.replace)` / `BreathingDot` 脉冲**
   - **价值**：微交互完整度直接跃升至 Things 3 / Loop 级别（数字顺滑滚动、符号形态渐变、克制的触觉回馈）。
   - **成本**：S
   - **优先级**：**P1**
   - **涉及高风险面？**：否。
   - **依据**：`Feedback.swift` 现状、`NotchDrop` 触感节流【源码：`NotchViewModel+Events.swift:84-93`】、`Loop` `numericText`/`symbolEffect`【源码：`RadialMenuView.swift:196-197`】。

5. **菜单栏图标状态化重构（模板主图标 + 动态状态徽章 + 读数宽度防抖）**
   - **价值**：用户无需点开面板即可一眼分辨「设备开启/连接中/离线阻塞/安全告警/待重启更新」，且彻底解决数字变化导致的菜单栏整体左右抽动。
   - **成本**：M
   - **优先级**：**P1**
   - **涉及高风险面？**：否（状态栏图标属于 UI 表现，但需测试 `statusItem` 点击、右键与 Out-of-Process 菜单栏兼容性）。
   - **依据**：`MenuBarPanelController.swift:768-830` 现状 vs `Itsycal` `XOR` 模板绘制+固定宽度测算【源码：`ViewController.m:741-846`】与 `Stats` `DotWidget`【源码：`Dot.swift:14-69`】。

6. **优化 `ControlCenterReadabilityBackdrop` 衬底渲染（预绘梯度替代实时 `.blur(radius: 32)`）**
   - **价值**：降低面板滑入动画与自适应高度调整期间的离屏模糊合成开销。
   - **成本**：S–M
   - **优先级**：**P2**
   - **涉及高风险面？**：否。
   - **依据**：`MenuBarPanelController+Presentation.swift:497-508` 现状。

---

## 9. 设想（菜单栏图标状态化与跨端视觉探索，单列）

### 9.1 菜单栏图标「四态徽章矩阵」（可不改架构直接落地，与现有 ADR 无冲突）

参考 `Itsycal` 的 `NSImage(size:flipped:drawingHandler:)` 矢量模板绘制 + `Stats` 的小圆点状态指示，为 MenuBarHome 设计一套「主宅图标始终保持 `isTemplate = true`，只在右下角或右侧挂接 5–6pt 语义微章」的状态系统：
1. **常规态（`isTemplate = true`）**：`house`（0 台运行）→ `house.fill`（≥1 台运行）；若显示数值（如功率/温度），采用 `Itsycal` 的离线等宽预测量 + `maxWidth` 滞回锁宽（例如 2 秒内只在宽度增加时扩宽，收缩延迟 5 秒执行），彻底消除数字小数位或单位切换引起的菜单栏跳动。
2. **后台活动态**：当执行场景、批量全关或自动化刚触发时，在图标右下角用微动画绘制短暂的弧形进度/闪烁点，1.2s 后自动淡出（或直接复用 SF Symbol `.variableColor` 渲染单色模板帧）。
3. **连接/离线态**：米家/HA 断连或重连中，在右下角叠一个 `4.5pt` 琥珀色实心点或镂空斜杠（仅徽章带色，主房子保持模板黑白自适应），避免整颗图标失去对比度。
4. **安全告警分级态**：
   - 普通提醒（门窗未关/设备超时）：主图标保持模板，右下角亮 `4.5pt` 琥珀圆点；
   - 生命安全告警（烟雾/燃气/漏水）：切换为实心带感叹号的高对比红底白字胶囊（`XOR` 镂空字体 + `.systemRed` 胶囊底，类似 `Itsycal` 实心圆角框），一眼击穿视线。

### 9.2 「MacBook 刘海实时家居状态条（Notch Live Strip）」探索（仅探索设想）

> 说明：本设想仅作远期探索。若引入独立刘海常驻窗体，需新增一个类似 `DynamicNotchKit` 的顶部非激活 `NSPanel` 管理器；与现有双端一致性（[ADR-0006](../../adr/0006-dual-platform-implementation.md)）不直接冲突（Windows 端可对应任务栏悬浮小条），但会显著增加多屏/全屏避让复杂度，当前不建议优先投入。

- **设想**：仅在有刘海的 MacBook 上（检测 `NSScreen.hasNotch` = `safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil`），当触发**门铃呼叫、严重传感器告警或空调/扫地机运行摘要**时，从刘海两侧平滑伸出 `boring.notch` 式的双翼胶囊（使用 `DynamicNotchKit` 的“先 `alpha=0` 设动画状态再 `0.15s` 淡入”机制，离开悬停 `100ms` 自动收回），点击直接展开或静音；无刘海屏则完全静默回退到现有的面板顶部通知堆栈，零额外打扰。

---

## 10. 来源清单

- **本地克隆源码（均位于 `~/.cache/mbh-research-clones/`）**：
  - `TheBoredTeam/boring.notch` (`b7611bb`): `boringNotch/ContentView.swift`, `boringNotch/sizing/matters.swift`, `boringNotch/models/BoringViewModel.swift`, `boringNotch/animations/drop.swift`, `boringNotch/components/Notch/NotchHomeView.swift`, `boringNotch/components/Notch/NotchShape.swift`, `boringNotch/components/Tabs/TabSelectionView.swift`, `boringNotch/components/HoverButton.swift`
  - `MrKai77/DynamicNotchKit` (`cd0b3e5`): `Sources/DynamicNotchKit/DynamicNotch/DynamicNotch.swift`, `DynamicNotchStyle.swift`, `DynamicNotchTransitionConfiguration.swift`, `DynamicNotchHoverBehavior.swift`, `Utility/NSScreen+Extensions.swift`, `Views/NotchView.swift`, `Views/NotchlessView.swift`, `Views/NotchShape.swift`, `DynamicNotchInfo/DynamicNotchInfo+HelperViews.swift`
  - `Lakr233/NotchDrop` (`e70b3d7`): `NotchDrop/NotchView.swift`, `NotchDrop/NotchViewModel.swift`, `NotchDrop/NotchViewModel+Events.swift`, `NotchDrop/Ext+NSScreen.swift`
  - `MrKai77/Loop` (`ad8564a`): `Loop/Utilities/AnimationConfiguration.swift`, `Loop/Window Action Indicators/Radial Menu/RadialMenuView.swift`, `RadialMenuViewModel.swift`, `Loop/Window Action Indicators/Preview Window/PreviewView.swift`, `PreviewViewModel.swift`, `Loop/Settings Window/Loop/AboutConfiguration.swift`, `Loop/Core/LoopManager.swift`
  - `jordanbaird/Ice` (`11edd39`): `Ice/UI/IceBar/IceBar.swift`, `Ice/UI/ViewModifiers/LayoutBarStyle.swift`, `Ice/MenuBar/Appearance/MenuBarOverlayPanel.swift`
  - `exelban/stats` (`f47dca1`): `Kit/module/widget.swift`, `Kit/Widgets/Dot.swift`, `Kit/Widgets/Battery.swift`
  - `sfsam/Itsycal` (`287576c`): `Itsycal/ViewController.m`
- **本仓审计文件（均位于 `/Users/yangzhiyuan/.t3/worktrees/menubarmijia/t3-e4c137df-9ad4c84a8bb3350e/`）**：
  - `Sources/MenuBarMijiaApp/DesignTokens.swift`
  - `Sources/MenuBarMijiaApp/PanelDesign.swift`
  - `Sources/MenuBarMijiaApp/ThemeAndMotion.swift`
  - `Sources/MenuBarMijiaApp/StackedCardGeometry.swift`
  - `Sources/MenuBarMijiaApp/Feedback.swift`
  - `Sources/MenuBarMijiaApp/ActivityStackView.swift`
  - `Sources/MenuBarMijiaApp/ControlCenterPanel.swift`
  - `Sources/MenuBarMijiaApp/ControlCenterPanelChrome.swift`
  - `Sources/MenuBarMijiaApp/ControlCenterPanelLayout.swift`
  - `Sources/MenuBarMijiaApp/ControlCenterPanelStacks.swift`
  - `Sources/MenuBarMijiaApp/DeviceCardView.swift`
  - `Sources/MenuBarMijiaApp/DeviceLayout.swift`
  - `Sources/MenuBarMijiaApp/SmallDeviceTile.swift`
  - `Sources/MenuBarMijiaApp/ClimatePanelModule.swift`
  - `Sources/MenuBarMijiaApp/SensorCardView.swift`
  - `Sources/MenuBarMijiaApp/MenuBarPanelController.swift`
  - `Sources/MenuBarMijiaApp/MenuBarPanelController+Presentation.swift`
  - `Sources/MenuBarMijiaApp/Classic/ClassicThemeAndMotion.swift`
  - `Sources/MenuBarMijiaApp/Classic/ClassicPanelDesign.swift`
  - `Sources/MenuBarMijiaApp/Classic/ClassicControlCenterPanel.swift`
  - `Sources/MenuBarMijiaApp/Classic/ClassicLayoutEditing.swift`
  - `Sources/MijiaCore/HomeStore+Metrics.swift`, `Sources/MijiaCore/HomeStore+Alerts.swift`
- **公开文档与技术文章（检索核验）**：
  - Apple WWDC25 *Meet Liquid Glass* / *Build a SwiftUI app with the new design*（`GlassEffectContainer` 合并原理、禁止嵌套玻璃与禁止直接覆盖滚动列表）
  - Raycast Architecture Blog（[raycast.com](https://www.raycast.com/blog)）、Cultured Code Things 3（[culturedcode.com](https://culturedcode.com)）、One Thing（[sindresorhus.com/one-thing](https://sindresorhus.com/one-thing)）、The Browser Company Arc AppKit/SwiftUI 公开讨论（[mjtsai.com](https://mjtsai.com)）
