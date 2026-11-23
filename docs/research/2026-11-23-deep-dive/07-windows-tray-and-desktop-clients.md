# 07 Windows 托盘与跨平台桌面客户端

调研日期：2026-11-23
范围：Windows 11 托盘 flyout 的交互/定位/动效标杆，Home Assistant 桌面客户端的产品面，Tauri v2 托盘与 WebView2 的工程现实；全部结论落到我们 `windows/`（Tauri v2 + TS，Fluent 2 双悬浮岛）。
方法：先读文档，再浅克隆读源码，再追到具体机制（定位算法、状态机、动画参数、进程模型）。

实际读了源码的仓库（`git clone --depth 1 --filter=blob:none`，commit 为克隆时 HEAD）：

| 仓库 | commit | 日期 | 星数（GitHub API，2026-11-23） |
| --- | --- | --- | --- |
| `File-New-Project/EarTrumpet` | `17bbd57` | 2026-11-22 | 11,570 |
| `TranslucentTB/TranslucentTB` | `d4636e4` | 2026-08-31 | 20,917 |
| `ModernFlyouts-Community/ModernFlyouts` | `ecf5708` | 2024-11-17 | 4,014 |
| `Flow-Launcher/Flow.Launcher` | `58b7997` | 2026-11-15 | 16,075 |
| `LAB02-Research/HASS.Agent` | `08310c4` | 2023-07-01 | 1,898 |
| `tauri-apps/tray-icon` | `bd709f8` | 2026-11-05 | — |
| `tauri-apps/window-vibrancy` | `c93f682` | 2026-10-15 | 1,042 |
| `tauri-apps/plugins-workspace` | 工作区快照 | 2026-11-21 | 1,846 |
| `EcoPasteHub/EcoPaste` | `5139d30` | 2026-08-12 | 7,596 |
| `pqpxo/hass-claude-usage-taskbar` | `9514ebd` | 2026-07-15 | — |

标注：**【源码】** 读了实现（附 `仓库:路径:行号`）；**【文档】** 官方文档（附 URL）；**【检索】** 只看了搜索摘要/issue；**【推断】** 我的判断。

---

## 0. 结论先行

1. **托盘点击去抖我们比标杆做得细**：EarTrumpet 用「关窗后 300ms 内禁止再开」的一刀切去抖（`FlyoutViewModel.cs:47`），我们用「按下/抬起 + 光标距离 + 时长」判定这次点击是否是同一次点击（`window.rs:35-50, 123-165`），允许真正的新点击立刻重开。这块不用动，是可以写进文档的差异优势。【源码】
2. **真正的定位缺口是自动隐藏任务栏**：`taskbar_edge()` 把「work area == monitor」判成 `TaskbarEdge::None`（`placement.rs:51-63, 362`），面板于是贴着屏幕物理边，任务栏滑出时会盖住底部一排卡片。EarTrumpet 用 `SHAppBarMessage(ABM_GETTASKBARPOS)` + `ABS_AUTOHIDE` 显式补偿（`WindowsTaskbar.cs:44-79`、`FlyoutWindow.xaml.cs:128-131`）。这是本轮最该修的一条。【源码】
3. **动效参数我们已经和 WinUI 3 完全对齐，不要跟 EarTrumpet**：官方时长 250/167/83ms、进入 `cubic-bezier(0,0,0,1)`、退出 `cubic-bezier(1,0,1,1)`【文档】，我们 `styles.css:8-22` 一字不差；EarTrumpet 是 130ms 位移 + 140ms 淡入 + QuinticEase EaseOut（`WindowAnimationLibrary.cs:26-50`）、ModernFlyouts 是 367ms + `(0.1,0.9,0.2,1)`（`FlyoutWindow.Animations.cs:131-138`），都比规范慢且曲线不在规范内。【源码】
4. **首帧闪白/空帧的正确解法是「先画后显」而不是 cloak**：EarTrumpet 用 DWM cloak 把窗口藏到 `Show()` 之后（`FlyoutWindow.xaml.cs:29`），我们已有 `is-parked`（`app.ts:2225-2250, 2340-2352`）在冷启动时把 swapchain 停在 opacity 0。缺的是**反方向的握手**：WebView 还没跑起来时托盘点击已经 `show()`，此时屏幕上是一块空白窗口（WebView2 issue #4834 记录同类现象）。【源码 + 检索】
5. **通知是我们最容易补的一块体验债**：现在每次发通知都 `Command::new("powershell.exe")` 起一个新进程（`desktop_shell.rs:290-324`）；每次都要付一次完整 shell + CLR 启动开销（量级数百毫秒与数十 MB 峰值，**未实测**，属推论），而且 toast 没有激活回调，点了什么都没有。HASS.Agent 用进程内 WinRT toast + `ToastNotificationManagerCompat.OnActivated` 做可交互通知（`NotificationManager.cs:21-54`），这是最值得抄的一条。【源码】
6. **深色模式下设置窗口的标题栏是白的**：`decorations(true)` 创建（`window.rs:836-844`）且全仓没有 `DWMWA_USE_IMMERSIVE_DARK_MODE`。window-vibrancy 的 `apply_mica` 第一步就是设这个属性（`window-vibrancy:src/windows.rs`），说明这是 Win32 窗口进深色模式的必经步骤。成本 S。【源码 + 推断】
7. **焦点归还缺失**：Esc 关闭面板后焦点不回到任务栏（`appLifecycle.ts:1389-1391` 只 `hide_panel`）。EarTrumpet 在键盘关闭时调 `NIM_SETFOCUS` 把焦点还给托盘图标（`ShellNotifyIcon.cs:87-95`、`FlyoutViewModel.cs:255-261`）。另外我们的单实例转发走 HTTP、不带 pid，无法 `AllowSetForegroundWindow(pid)`（`companion.rs:396-419`），Tauri 官方插件是显式做的（`single-instance:.../windows.rs:105-112`）。【源码】
8. **WebView2 的官方内存旋钮我们用不上**：`MemoryUsageTargetLevel=Low` 与 `TrySuspendAsync` 都以「这个 WebView 一段时间不用」为前提【文档】，而我们的隐藏态仍要跑定时指令、云刷新与摄像机保温（`appLifecycle.ts:1499-1600`、`docs/agents/windows-camera.md` §2）。所以正确顺序是**先量化再谈优化**，`backgroundThrottling: "disabled"` 也是刻意为之（同类 Tauri 托盘应用的既有结论），不能为了省内存反手关掉。【源码 + 文档】
9. **生态空窗**：Windows 侧「PC 作为 HA 设备」的领跑者 HASS.Agent 最后一次提交是 2023-07-01【检索】，Flow Launcher 这类进程外插件协议是 ADR-0023 明确留了口子的方向。这一格目前没人占。【检索】

---

## 1. EarTrumpet：一个 WPF 托盘 flyout 的全部细节

选它的理由：形态和我们最像——一个托盘图标 + 一个贴着任务栏的 flyout，没有主窗口，要求「点一下立刻出、点别处立刻收」。

### 1.1 窗口定位：靠 work area，但要为自动隐藏打补丁

`PositionWindowRelativeToTaskbar()`（`FlyoutWindow.xaml.cs:110-204`）的完整流程【源码】：

1. `UpdateLayout()` + `LayoutRoot.Measure(...)`——先强制布局，拿到真实内容高度（内容会随设备增减）。
2. 从 `WindowsTaskbar.Current` 拿任务栏矩形与边（`ABM_GETTASKBARPOS`），从 `Screen.WorkingArea` 拿工作区。
3. **自动隐藏补偿**（`:128-160`）：任务栏自动隐藏时它不给自己留工作区，所以如果工作区边缘已经探进任务栏矩形，就手动把那条边推到任务栏内侧。
4. Windows 11 上额外加 12px 内缩（`:178-181`，`xOffset`/`yOffset` 各 `12 * DpiX/Y`），贴齐 Win11 原生 flyout 的视觉位置。
5. 高度超过工作区就夹到工作区高（`:183-187`），最后 `SetWindowPos`。
6. `OnWindowsSizeInvalidated` 只在 `Open|Opening` 时重算（`:95-108`）——不可见时不做无用功。

**对我们**：`placement.rs` 的 `place()` 是纯函数 + 16 个单测，工程化程度其实高于这一版 WPF 代码；差距只在第 3 步。我们 `taskbar_edge()` 的注释写着「No reserved strip: an auto-hidden, floating, or missing taskbar」（`placement.rs:43-50`），设计上承认了这种情况，但**没有把它和「面板该躲开任务栏」区分开**——`None` 直接退化成「贴物理边」。

### 1.2 首帧：DWM cloak

`SourceInitialized` 里先 `this.Cloak()`（`:27-31`），整个生命周期内：显示前先算好位置、`Show()`、跑入场动画、动画完成才 `Cloak(false)`；隐藏时先 `Cloak()` 再 `Hide()`。同时在 `Initialize()` 里 `Show(); Hide();` 走一遍并加 `WS_EX_TOOLWINDOW`，一次性付掉创建窗口的代价、并把窗口排除在 Alt+Tab 外（`:34-42`）【源码】。

**这对我们意味着两件事**：
- 我们没有 cloak，但 WebView2 的等价物是「先渲染再 `show()`」。`app.ts:2340-2352` 的 parking 只覆盖了「冷启动进程还活着但面板没开过」这一种情况，方向是**对的**；缺的是反向保护：`present_panel_on_main_thread` 一旦被调用就无条件 `show()`（`window.rs:730-745`），如果此时 WebView 还在初始化，用户看到的是一块空白。
- `WS_EX_TOOLWINDOW`：EarTrumpet 明确用它防 Alt+Tab 出现幽灵窗口。我们靠 `skipTaskbar: true`（`tauri.conf.json:24`），语义不完全一样，是否也会进 Alt+Tab 需要实机验证（见 W12）。

### 1.3 动画参数（可以直接抄的只有「方向」）

| 维度 | EarTrumpet | 我们 |
| --- | --- | --- |
| 进入位移 | 25px（`WindowAnimationLibrary.cs:24`） | 36px（`styles.css:22` `--flyout-travel`） |
| 进入时长/曲线 | 130ms，`QuinticEase EaseOut`（`:26-31`） | 250ms，`cubic-bezier(0,0,0,1)`（`styles.css:5099-5101`） |
| 进入透明度 | 140ms 0.8→1（仅当系统开透明效果，`:40-50`） | 0→1，50% 处 0.92（`styles.css:5067-5079`） |
| 退出 | 150ms 位移 + 淡到 0.75（`:131-190`） | 167ms `cubic-bezier(1,0,1,1)`（`styles.css:5082-5094`） |
| 方向 | 按任务栏边决定（左/右/上/下，`:57-70`） | 同（`window.rs:215-226` `flyout_edge_name`） |

结论：**方向逻辑我们已对齐，时长/曲线我们更符合规范**。EarTrumpet 的 130ms 偏快是 2018 年的判断，不构成改进项。唯一可借的是「只在系统开启透明效果时才做淡入」——呼应 Fluent 的「尊重系统设置」，我们已经有 `prefers-reduced-transparency`（`styles.css:6273-6276`），但不是「按系统透明开关决定要不要淡入」。属于 P3 级细节。

### 1.4 状态机与托盘点击去抖（我们更强的地方）

EarTrumpet 的状态很干净：`NotLoaded → Hidden → Opening → Open → Closing_Stage1 → Closing_Stage2 → Hidden`（`FlyoutViewState.cs`），`ValidateStateChange` 里把合法迁移写成白名单并用 `Debug.Assert` 兜住（`FlyoutViewModel.cs:277-291`）【源码】。

去抖是它的核心妥协：进入 `Closing_Stage2` 时起一个 **300ms** 定时器，期间不允许再打开（`FlyoutViewModel.cs:47-51, 68-73`），理由是「点托盘想关掉面板时，Explorer 的焦点丢失消息和托盘的 Click 消息会打架，容易关掉又立刻弹出」。

我们的做法（`window.rs:68-165`）：记录 `Focused(false)` 发生的时刻与当时的光标位置；托盘按下时若「正在关闭 且 光标距那次焦点丢失 ≤36px 且 ≤250ms」，就把这次按下标记为 `dismissed`，抬起时返回 `Noop` 而不是 `Present`。效果是：**关掉面板的那一下不会反弹，但用户 280ms 后真心想再打开时可以立刻打开**（测试见 `main.rs:446-499`）。

这是本轮唯一一个「标杆不如我们」的地方。同类问题在 `ha-tray-panel`、`EcoPaste` 里都没处理（EcoPaste 干脆让窗口不可聚焦 + 全局鼠标钩子，见 §7.5）【源码】。

### 1.5 焦点：两段式抢占 + `NIM_SETFOCUS`

入场动画期间它做了一件反直觉的事【源码】：

```csharp
window.Topmost = false;
window.Activate();
BringTaskbarToFront();        // SetForegroundWindow(Shell_TrayWnd)
... 动画结束后 ...
window.Topmost = true;
window.Focus();
User32.SetForegroundWindow(window.GetHandle());
```

`WindowAnimationLibrary.cs:33-46, 208-211`、`FlyoutWindow.xaml.cs`（`TaskbarIconSource` 触发）。配套的 `ShellNotifyIcon.SetFocus()` 发的是 `NIM_SETFOCUS`（`ShellNotifyIcon.cs:87-95`），用于键盘关闭后把焦点还给托盘图标，这样键盘用户不会「掉到桌面上」。

**对我们的含义**：`present_panel_on_main_thread` 目前只有 `show() + set_focus()`（`window.rs:742-743`）。Windows 的 `SetForegroundWindow` 有前台锁规则，从托盘菜单/URL 转发进来的路径不保证成功；失败时窗口可见但不接收键盘输入——表现是「面板出来了，打字没反应」，而且因为从未获得焦点也不会有 `Focused(false)`，面板会一直挂着。这条必须实机验证（W4）。

### 1.6 Acrylic 只在该亮的时候亮

`EnableAcrylicIfApplicable`（`:206-218`）只在 `Opening|Open` 时启用 accent policy，其余状态显式 disable，理由是「Hidden+cloaked 状态下开 Acrylic 会出现一块可见的亚克力面板」；主题切换时重新应用（构造里挂 `ThemeChanged`）【源码】。

我们没用系统 backdrop（双岛是 CSS 自绘），这条对我们的直接价值是：**如果哪天给设置窗口上 Mica/Acrylic，也必须跟着「窗口可见性」开关，而不是创建时就开**。

---

## 2. ModernFlyouts：对齐旗标 + 展开方向 + DPI 变更

它把 flyout 抽象成「对齐旗标（上下左右）+ 边距 + 展开方向」：

- `PositionOnScreenFlyout`（`FlyoutWindow.OnScreen.cs:8-71`）：命中 `Left/Right/Top/Bottom` 就直接贴工作区对应边（加边距），都没命中才居中；居中时还会把 `margin.Left/Right` 的差值算进偏移。
- `CalculateActualExpandDirectionOnScreen`（`:73-125`）：根据哪条边距更小决定往哪个方向展开，再喂给动画的起始位移。
- DPI：`UpdateDpiScale(GetDpiForWindow(...)/96.0)` → `OnDpiChanged()` → `UpdateSize(true)`（`BandWindow.cs:471-476`），并且手动把 `WM_DPICHANGED` 转发给 `HwndSource`（`:404, 439-441`）。
- 动画：位移 40px / **367ms** / `KeySpline(0.1, 0.9, 0.2, 1)`，透明度 `0 → 83ms 0 → 166ms 1`（`FlyoutWindow.Animations.cs:131-138, 173-181`）。

**对我们的含义**：EMS 那套「对齐旗标 + 展开方向」我们已经用更结构化的方式实现了（`PanelAnchor` + `flyout_edge_name` + `resized_top/resized_x`），不必改。真正缺的是 **DPI 变更的响应**：全仓没有 `ScaleFactorChanged` 监听，`set_panel_height/geometry` 每次都用 `monitor.scale_factor()` 现算（`window.rs:509, 538`），但窗口尺寸用的是 `LogicalSize`，Tauri 按**窗口当前**的 scale 换算；把面板从 150% 屏拖到 100% 屏、或外接屏热插拔后，尺寸与位置可能算错一次（下次 present 自愈）。成本很小，收益是「换显示器不会歪一次」。

---

## 3. WinUI 3 / Fluent：时长与曲线，我们已在规范内

微软官方《Timing and easing》给的定值【文档】：

| ThemeResource | 值 | 用途 |
| --- | --- | --- |
| `ControlNormalAnimationDuration` | 250ms | 常规进入/退出 |
| `ControlFastAnimationDuration` | 167ms | 快速反馈、退出 |
| `ControlFasterAnimationDuration` | 83ms | 微交互 |

缓动只有两条基线：进入 `cubic-bezier(0, 0, 0, 1)`（Fast Out, Slow In），退出 `cubic-bezier(1, 0, 1, 1)`（Slow Out, Fast In）。

对照我们 `windows/src/ui/styles.css`：

```css
--dur-faster: 83ms;  --dur-fast: 167ms;  --dur-normal: 250ms;  --dur-slow: 333ms;
--ease-decelerate: cubic-bezier(0, 0, 0, 1);
--ease-accelerate: cubic-bezier(1, 0, 1, 1);
```
（`styles.css:8-22`）——**逐字对齐**。`--dur-slow: 333ms` 不在那份文档里，但它对得上 WinUI 的内部常量，属于合理延伸。

真正值得讨论的是 `src/ui/motionSpring.ts`：整套 `APPLE_SPRINGS`（`responseSec/dampingFraction`）把 SwiftUI 弹簧采样成 17 帧 `translate3d/scale` 关键帧，用在卡片堆叠、玻璃镜头、orb 回弹（`motionSpring.ts:8-18, 57-118`）。在 Fluent 主题里出现「带过冲的弹簧」与 WinUI 的「不收过冲、只做位移+透明度」是两个语系。【源码 + 推断】

**建议**：不改实现，但在 Fluent 主题下把 `orbBounce`（阻尼 0.68，肉眼可见过冲）换成 `snappy`（0.94），或者在 review 时明确「这是刻意的品牌动效」。P3。

---

## 4. Flow Launcher：插件边界怎么划

Flow 支持三种插件【源码】：

- **.NET 插件**：实现 `Flow.Launcher.Plugin.IPlugin`，**加载进主进程**（`Plugins/` 下官方插件即如此）。
- **Python / Node 插件**：`PythonPlugin : JsonRPCPlugin`，`ProcessStartInfo` 里 `RedirectStandardOutput/Error` + `CreateNoWindow`，通过 **stdio JSON-RPC** 与宿主通信（`Flow.Launcher.Core/Plugin/PythonPlugin.cs:12-31`）。
- 官方插件目录 + 社区插件源（`Flow.Launcher.Core/ExternalPlugins/CommunityPluginStore.cs`）。

这正是 ADR-0023 里那句「进程外扩展协议（如独立进程 MCP/HTTP 桥）是允许重启评估的方向」的现成参照：**宿主进程不加载第三方代码，第三方作为子进程跑 JSON-RPC，超时/重启/配额由宿主掌管**。

我们的对应物是 `companion.rs` 的本地 IPC（带 secret 的 HTTP + 授权头，`companion.rs:558-586`）与 MCP 只读快照。两者形态已经很接近 Flow 的 JSON-RPC 通道，**只是反向**（我们是"外部来调我们"，Flow 是"我们去调插件"）。这条留到「设想」里展开。

---

## 5. HASS.Agent：HA 桌面客户端的产品面（本地最值得抄的一条）

一个 .NET 6 / WinForms 的托盘应用，README 自称的核心能力【文档】：通知（含可交互按钮、图片）、媒体播放器实体、Quick Actions（热键唤出的按钮面板）、24 个命令、37 个传感器、任意网页 WebView、卫星服务（未登录也能采数据/执行命令）。

### 5.1 通知：入站通道 + WinRT toast + 激活回调

`NotificationManager.Initialize()`（`Managers/NotificationManager.cs:21-58`）【源码】：

1. 必须「本地 API 启用」或「MQTT 启用」至少一项，否则直接不启动通知（`:29-37`）——即**通知必须有入站通道**。
2. MQTT 启用时 `SubscribeNotificationsAsync()` 订阅主题（`:39-42`）。
3. `ToastNotificationManagerCompat.CreateToastNotifier()` 建 toast 通知器；先查 `Setting != Enabled` 并记日志（用户可能关了通知）（`:45-53`）。
4. `ToastNotificationManagerCompat.OnActivated += OnNotificationButtonPressed`——**按钮点击回到本进程**（`:54`）。
5. 展示侧 `ShowNotification(Notification)`（`:69+`）把 HA 传下来的按钮渲染成 toast 动作。

**我们的现状**：`send_desktop_notification` 用一段 PowerShell 脚本构造 toast XML 再 `Show`（`desktop_shell.rs:290-296`），`format_windows_toast_xml`（`desktop_shell.rs:279-288`）只填 title/body。三个可量化的代价：

- 每次通知 spawn 一个 `powershell.exe`（`desktop_shell.rs:304-316`）——进程启动 + CLR 初始化的固定开销，远大于通知本身。
- 因为不是自己进程发的 toast，**没有激活回调**，点击无反应；也没法带按钮。
- toast 的 AppUserModelID 写死为 `com.jryang.menubarmijia`（`:296`），与安装器注册的 AUMID 是否一致未经校验（不一致时通知可能根本不显示，需实机确认）。

### 5.2 把 PC 变成 HA 设备

37 个传感器（CPU/GPU/活跃窗口/麦克风占用…）+ 24 个命令（关机、锁屏、启动程序）+ 媒体播放器实体。这套「PC 是 HA 里的一等公民」的思路，和我们「PC 是控制器」的定位互补。【文档】

### 5.3 卫星服务

「未登录也能采数据/执行命令」的服务形态——对应到我们，就是「锁屏/未登录时定时指令与自动化还跑不跑」。我们已经有 `is_workstation_locked` 与 `RegisterSuspendResumeNotification`（`desktop_shell.rs:174-197`、`system_events.rs`），但没有服务形态。【源码 + 推断】

### 5.4 停更与启示

最后一次提交 2023-07-01，README 里还挂着「需要帮助」的招募【检索】。含义：**这个赛道不缺需求，缺持续维护**。我们要抢的不是功能数量，而是「通知回传 + 托盘体验」这两件用户每天都会碰的事。

---

## 6. 小体量同类：动态托盘图标 & Electron 对照

**`pqpxo/hass-claude-usage-taskbar`**（2026-07，.NET 单文件 exe，1 个托盘图标 + hover 弹窗）【源码 + 文档】：

- 托盘图标**本身就是数据面**：hover 时把图标重绘成「当前用量百分比」，离开恢复 logo（README 的 GIF 演示）。实现是 WinForms 动态绘制图标位图。
- hover 弹窗里跑实时倒计时（`Reset in 3h 24m` → `42m` → `due`）。
- token 用 **DPAPI** 加密落盘；轮询 HA REST 默认 60s；单文件自包含发布。

**对我们的含义**：我们的托盘图标是静态的，只有 tooltip 带实时摘要（`desktop_shell.rs:229-258`）。Win11 的托盘区默认把图标收进溢出区，**tooltip 要悬停才看得到**，而图标本身天天在任务栏上。「图标 = 一个比特的信息」（有设备开着 / 有告警）是极低成本的高频触点。见 W6。

**Electron 对照**：`emre-pn/ha-tray-panel`（2026-10，Electron + 命令面板 + 全局热键，1 star）与 `Sammyjo20/home-assistant-tray`（教学级）说明「Electron 做这个形态」的代价：一份 Chromium 常驻 + 每个窗口一套渲染进程。我们选 Tauri 的方向不需要重议，**但 WebView2 也带着同一套多进程结构**（见 §8），差距没有宣传的那么大——这一点值得在 README 里诚实表达。

---

## 7. Tauri v2 托盘实战

### 7.1 `tray-icon` 其实给了我们更多东西

Windows 实现里，每个鼠标事件都会同时给出 **光标位置**和**图标矩形**（`Shell_NotifyIconGetRect`）：

```rust
let position = PhysicalPosition::new(cursor.x as f64, cursor.y as f64);
let rect = match get_tray_rect(userdata.internal_id, userdata.guid, hwnd) {
    Some(rect) => Rect::from(rect),
    None => return 0,          // 拿不到就直接不派发事件
};
```
（`tray-icon:src/platform_impl/windows/mod.rs:409-430, 680-700`）【源码】

两点直接可用：

1. **我们只用 `position`，丢了 `rect`**（`main.rs:364-382`）。`rect` 是图标真实矩形，比光标点更稳（点击瞬间手抖、图标在溢出面板里、鼠标在图标边缘）。对 `place()` 里的 `main_width/2` 居中锚点尤其有意义：用 rect 中心就不必假设「光标 == 图标中心」。
2. **`Enter/Leave` 事件存在**，且用定时器 + 矩形包含判定实现（`:505-545`），并在「锁屏、图标被收进关闭的溢出区、Explorer 重启」时判定为离开并停止定时器。我们没订阅这些事件——hover 预览（P3 设想）在技术上不需要额外钩子。

另外，`Shell_NotifyIconGetRect` 失败时它**直接不派发事件**（`:419-422`）。这类「图标不可见时点了没反应」的场景，我们的 `handle_tray_mouse_down` 依赖 Tauri 已经过滤过一次，无需重复处理，但值得知道。

### 7.2 单实例：我们更安全，但它有一行我们缺

我们：`CreateMutexW` 命名互斥 + 本地 IPC（secret 授权的 HTTP）转发 URL/激活请求（`companion.rs:396-419, 436-485`）【源码】。安全面比 `WM_COPYDATA` 强得多（有授权头、有 URL 白名单）。

官方插件（`plugins/single-instance/src/platform_impl/windows.rs`）【源码】：

- 第二个实例用 `FindWindowW` **有界重试 40×25ms** 找主实例的事件窗口（`:96-105`），注释写的是「并发双击时主实例还没建好窗口」。
- 转发前 `GetWindowThreadProcessId` + **`AllowSetForegroundWindow(pid)`**（`:105-112`），注释：「Windows 允许我们把窗口提到前台，但不允许第一个实例自己这么做，所以先把权利交过去」。

**我们缺的就是最后这一步**：`menumijia://` 链接从浏览器/其他程序唤起时，主实例拿到请求后 `show_panel_for_url` → `present_panel` → `set_focus()`，但前台锁可能不让它抢焦点。我们的转发是 HTTP，拿不到对端 pid——最小修法是第二实例在转发前 `AllowSetForegroundWindow(ASFW_ANY)`（`-1`），或者在 URL 里带上 pid。见 W4。

### 7.3 开机自启：Run 键的已知盲区

我们直接写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MenuBarHome`（`desktop_shell.rs:6-7, 63-100, 153-171`），读回也是读同一个值。官方 `tauri-plugin-autostart` 走 `auto_launch` crate，本质相同【源码】。

共同的盲区：用户在**任务管理器 → 启动**里禁用我们时，Windows 写的是 `HKCU\...\Explorer\StartupApproved\Run`，Run 键本身不动。于是我们的设置页会显示「已开启」，实际登录不启动。修法是同时读 `StartupApproved\Run`（REG_BINARY，首字节表示启用状态，具体取值需实机确认）。成本 S，属于「用户会骂但不会报 bug」的类型。见 W11。

### 7.4 Mica / Acrylic：给谁用，不给谁用

`window-vibrancy` 的 Windows 路径【源码】（`src/windows.rs`）：

- `apply_acrylic`：Win11 22H2+ 用 `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE, DWMSBT_TRANSIENTWINDOW)`；否则退到未公开的 `SetWindowCompositionAttribute(ACCENT_ENABLE_ACRYLICBLURBEHIND)`。
- `apply_mica`：先设 `DWMWA_USE_IMMERSIVE_DARK_MODE`（跟随深色），再 `DWMSBT_MAINWINDOW`，或退到 `DWMWA_MICA_EFFECT`。
- 文档要求：Tauri 下 `html, body { background: transparent }` + `"transparent": true`。

**我们的判断**：

- **双岛 flyout 不要用系统 backdrop**。系统 backdrop 是「整窗一块」的材质，我们是两块圆角岛 + 16px 透明间隙，套上去会在间隙处露出一条材质，破坏形态。CSS 自绘（现在这样）是对的。
- **设置窗口应该用**。它 `decorations(true)` 是标准窗口（`window.rs:836-844`），现在完全是纯色，Mica 能免费拿到「像系统应用」的观感；顺带解决 §1.6 的暗色标题栏。注意 Win10 上会落到 SWCA acrylic，有已知的拖动卡顿，所以**只在 Win11 22H2+ 开**。

### 7.5 EcoPaste 的两处生产教训（7.6k 星，仍会踩）

1. **logical / physical 混用**：`window/position.rs:17-31` 把光标 `to_logical::<f64>(scale)` 之后传给 `monitor_from_point(x, y)`——Tauri 的 `monitor_from_point` 要的是物理坐标。100% 缩放看不出问题，150% 屏上会算错显示器。我们 `window.rs:561-590` 传的是 `PhysicalPosition` 的原始值，是对的——**这条是给我们自己的提醒：跨 DPI 的坐标换算必须有测试**（`placement.rs` 现有单测全是纯物理像素，覆盖得很好，继续保持）。
2. **不可聚焦窗口 + 全局鼠标钩子**：剪贴板窗口 `set_focusable(false)`，然后用 `mouse::enable_outside_click_hide()` 自己实现「点外面关闭」（`window/windows.rs:15-33`）【源码】。这条路能避免抢焦点，但代价是键盘输入要临时 `set_focusable(true)` 再还原（`set_clipboard_window_editing`，`:35-68`），复杂且容易漏。**我们的「可聚焦 + `Focused(false)` 关闭」更简单，保持。**

---

## 8. 性能：WebView2 的现实

### 8.1 官方口径（可引用的硬事实）

《Performance》【文档】（learn.microsoft.com/microsoft-edge/webview2/concepts/performance）：

- 进程模型：一个 WebView2 进程组 = 1 个 browser 进程 + ≥1 renderer + GPU/audio 等辅助进程；**每个 WebView2 控件各起一套**（process-model 文档）。
- 冷启动：首次创建控件 + 导航是常见瓶颈，「WebView2 必须拉起进程和磁盘缓存」。
- **「不要用 WebView2 渲染启动画面/简单对话框」**——启动成本与资源争用；只在真正展示网页内容时初始化。
- 内存旋钮：**`MemoryUsageTargetLevel = Low` 用于"非活跃" WebView**（引擎会丢缓存甚至换出到磁盘），恢复活跃时设回 `Normal`；**`TrySuspendAsync()` 用于"一段时间不用"**（挂起脚本），`Resume()` 恢复；两者都是 best-effort。
- 复用环境（一个 `CoreWebView2Environment`）、避免多余实例、进程优先级管理。

相关 bug 记录（说明这些不是理论问题）：`WebView2Feedback#4834` 初始化期间出现空白窗口（open，2026）；`#5792` 显示变化/Dpi 恢复失败后控件留白（open，2026-08 起）【检索】。

### 8.2 我们的现状

| 我们做的事 | 位置 | 判断 |
| --- | --- | --- |
| `backgroundThrottling: "disabled"` | `tauri.conf.json:27` | **刻意为之**：隐藏态仍要跑定时指令/云刷新/摄像机保温，节流会让心跳迟滞。同类 Tauri 托盘应用（peek）也是这么配的，见既有调研 [`similar-projects-analysis.md`](../similar-projects-analysis.md) 第 1.2 节的横向矩阵。保留。 |
| 只有需要时开 1s 快定时器，否则排单个 timeout | `appLifecycle.ts:1424-1470, 1561-1600`（`needsFastTimerInterval` / `nextHiddenWakeTargetMs` / `syncTimerSchedule`） | 已经是「按需唤醒」模型，比多数同类应用好。 |
| 系统信号只在有规则等待时采样 | `systemContextPoll.ts:80-105`（`systemSignalNeed`） | 好。 |
| 隐藏时摄像机只降频不停止（400ms 一帧，120s） | `docs/agents/windows-camera.md` §2 + `cameraLive.ts` | 每帧走 IPC + Base64，2.5 次/秒的常驻开销；只在用户开过摄像头后的 2 分钟内存在。可接受，但要量。 |
| 透明窗口 + 双岛 CSS | `tauri.conf.json:21-22`、`styles.css:171-181` | 透明 WebView2 无法被系统判定为遮挡，renderer 不会进入 occluded 省电路径。与 `backgroundThrottling: disabled` 叠加，隐藏态也可能继续出帧。 |
| parked 时关掉所有动画 | `styles.css:5092-5096`（`#app.is-parked > .cc-popover { animation: none }`） | 好，减少了隐藏态的无谓合成。 |

**结论**：我们已经做了「按需唤醒」这一层，剩下的空间在 **渲染层**（隐藏时是否还在出帧）和 **内存层**（能不能在不牺牲后台定时器的前提下压低常驻）。两者都必须先测量。

### 8.3 怎么量（可直接执行的脚本）

进程树常驻内存（PowerShell，在孩子进程上递归累加）：

```powershell
function Get-TreeMemory([int]$rootId) {
  $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, WorkingSetSize
  $ids = @($rootId); $sum = 0; $rows = @()
  for ($i = 0; $i -lt $ids.Count; $i++) {
    $cur = $ids[$i]
    foreach ($p in $all | Where-Object { $_.ParentProcessId -eq $cur }) { $ids += $p.ProcessId }
  }
  foreach ($id in $ids) { $p = $all | Where-Object ProcessId -eq $id; if ($p) { $sum += $p.WorkingSetSize; $rows += [pscustomobject]@{ Pid=$id; Name=$p.Name; MB=[math]::Round($p.WorkingSetSize/1MB,1) } } }
  [pscustomobject]@{ TotalMB = [math]::Round($sum/1MB,1); Rows = $rows }
}
Get-TreeMemory (Get-Process MenuBarHome).Id
```

要采集的 5 个点：① 登录后 0s（隐藏、未开过面板）② 空闲 10 分钟（隐藏）③ 面板打开 10 秒 ④ 面板打开 + 摄像头 ⑤ 唤醒后 30 秒。CPU 用 `Get-Counter '\Process(MenuBarHome*)\% Processor Time'` 取同样的点。

冷启动时延：在 `present_panel_on_main_thread` 打一个 `QueryPerformanceCounter`，前端 `panel-present` 回一个 ack（现在只有单向 eval），差值就是从点击到"有画面"。成本 S，但**没有这个数，后面所有性能建议都是猜**。

---

## 9. 对照我们：差距表

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `src-tauri/src/placement.rs:51-63` + `window.rs:561-600` | 自动隐藏任务栏判为 `None`，面板贴物理屏幕边 | EarTrumpet `ABM_GETTASKBARPOS` + `ABS_AUTOHIDE` 补偿（`WindowsTaskbar.cs:44-79`） | 读任务栏真实矩形与自动隐藏状态，隐藏任务栏时把面板从边内缩一个任务栏厚度 | S/M |
| `src-tauri/src/window.rs:729-745` | present 无条件 `show()` | EarTrumpet cloak 到动画开始前（`FlyoutWindow.xaml.cs:29`） | 前端 ready 前不 show；已 show 则 ready 后补一次 `panel-present` eval | S |
| `src-tauri/src/desktop_shell.rs:290-324` | 每次通知 spawn powershell 发 toast，无点击回调 | HASS.Agent 进程内 WinRT toast + `OnActivated`（`NotificationManager.cs:21-54`） | 换成进程内 toast（WinRT 绑定），注册激活回调走深链 | M |
| `src-tauri/src/window.rs:836-844` | 设置窗口 `decorations(true)`，无 DWM 暗色设置 | `window-vibrancy` 先设 `DWMWA_USE_IMMERSIVE_DARK_MODE` | 给设置窗口加暗色标题栏；Win11 22H2+ 顺带上 Mica | S |
| `src-tauri/src/main.rs:364-382` | 只用光标位置当锚点 | tray-icon 同时给图标 `rect`（`tray-icon:...windows/mod.rs:409-430`） | 用 `rect` 中心做锚点，光标点只作后备 | S |
| `src/ui/appLifecycle.ts:1389-1391` | Esc 关闭只 `hide_panel` | EarTrumpet `NIM_SETFOCUS` 归还焦点（`ShellNotifyIcon.cs:87-95`） | 键盘关闭后把焦点还给 Shell_TrayWnd | S/M |
| `src-tauri/src/companion.rs:396-419` | 单实例转发不带前台权 | 官方插件 `AllowSetForegroundWindow(pid)` | 转发前 `AllowSetForegroundWindow(ASFW_ANY)` 或带 pid | S |
| 全仓 | 无 `ScaleFactorChanged` 处理 | ModernFlyouts `UpdateDpiScale` + `WM_DPICHANGED`（`BandWindow.cs:471-476`） | 监听后重排几何，且不重播入场动画 | S/M |
| `src-tauri/src/main.rs:331-390` + `desktop_shell.rs:229-258` | 托盘图标静态，只有 tooltip 带摘要 | `hass-claude-usage-taskbar` 把图标画成数据 | 图标叠加一个小角标（活动设备数/告警点） | M |
| `src-tauri/tauri.conf.json:21-27` | 透明 + alwaysOnTop + 不节流 | — | 保留，但补测量与基线 | S |
| `src/ui/motionSpring.ts:8-18` | Fluent 主题里用过冲弹簧 | Fluent 只做位移+透明度 | Fluent 主题下把 `orbBounce` 降到近临界阻尼 | S |
| `src-tauri/src/desktop_shell.rs:153-171` | 只读 Run 键判断自启 | — | 兼读 `StartupApproved\Run` | S |

---

## 10. 推进清单

> 高风险面按 `AGENTS.md`：登录凭据 / 设备写入 / 数据迁移 / 自动更新与签名 / 跨平台契约。本轮清单**全部不落在**这五类里（通知、定位、焦点、DPI、动效、托盘图标均属本地呈现层）。

### P0

**W1 · 自动隐藏任务栏的定位补偿**
价值：开了任务栏自动隐藏的用户（小屏笔记本、平板模式、喜欢全屏的人不少）现在会被滑出来的任务栏盖住底部一排版；这是可见的布局缺陷，不是审美问题。
成本：S/M（新增一次 `SHAppBarMessage` 调用 + 纯函数算「需要内缩多少」+ 单测）。
高风险面：否。
依据：`placement.rs:51-63, 362` 把 auto-hide 判成 `None`；EarTrumpet 的补偿逻辑与注释（`FlyoutWindow.xaml.cs:128-131`、`WindowsTaskbar.cs:44-79`）。

**W2 · 设置窗口暗色标题栏（+ Win11 Mica）**
价值：深色模式下设置窗口顶一条白，是第一眼就能看出的"不像系统应用"。
成本：S（一次 `DwmSetWindowAttribute`，失败静默回退）。
高风险面：否。
依据：`window.rs:836-844` 无任何 DWM 调用；`window-vibrancy:src/windows.rs` 的 `apply_mica` 首步即设 `DWMWA_USE_IMMERSIVE_DARK_MODE`。

**W3 · 性能基线（先测量）**
价值：把「WebView2 常驻多少、隐藏态有没有在出帧、冷启动几百毫秒」变成数字，否则 W4/W5 无从判断收益。
成本：S（一段 PowerShell + 一个 `QueryPerformanceCounter` 日志 + 一页记录进 `docs/agents/`）。
高风险面：否。
依据：§8.3；WebView2 《Performance》的内存与启动章节【文档】。

### P1

**W4 · 前台焦点与"点了没反应"**
价值：修「面板出来但打字没响应」和「URL 唤起后键盘焦点在别处」两处静默失败；同时给 `menumijia://` 一条确定的可聚焦路径。
成本：M（`AllowSetForegroundWindow` + 必要时 `AttachThreadInput` 兜底 + 实机验证矩阵）。
高风险面：否。
依据：`window.rs:742-743` 只有 `set_focus()`；官方插件 `AllowSetForegroundWindow(pid)`（`single-instance:.../windows.rs:105-112`）；EarTrumpet 两段式抢焦点（`WindowAnimationLibrary.cs:33-46`）。

**W5 · 通知改为进程内 toast + 可交互**
价值：去掉每次通知一个 `powershell.exe` 的开销，并让「点击通知打开面板/设备」成立——这是每日触点。
成本：M（WinRT 绑定或成熟 crate；AUMID 与安装器对齐；按钮 → 深链 → 面板）。
高风险面：否（不涉及凭据与设备写入；动作最终仍走既有确认链路）。
依据：`desktop_shell.rs:290-324`；HASS.Agent `NotificationManager.cs:21-54`。

**W6 · 托盘图标变成数据面**
价值：Win11 默认把托盘图标收进溢出区，tooltip 要悬停才看得到；图标本身是唯一天天可见的那一个像素。
成本：M（前端 canvas 画 → IPC → `tray.set_icon`；注意 DPI 与深浅色两套图标）。
高风险面：否。
依据：`desktop_shell.rs:229-258` 现在只更新 tooltip；`hass-claude-usage-taskbar` 的 hover 动态图标【文档】。

**W7 · 焦点归还与跨 DPI 重排**
价值：键盘用户 Esc 后不掉焦点；换显示器/改缩放后面板不歪一次。
成本：M（`ScaleFactorChanged` 监听 + 关闭路径给 Shell_TrayWnd 焦点）。
高风险面：否。
依据：`appLifecycle.ts:1389-1391`；ModernFlyouts `BandWindow.cs:471-476`；EarTrumpet `ShellNotifyIcon.cs:87-95`。

### P2

**W8 · 用图标 `rect` 而非光标做锚点**
价值：图标在溢出面板、鼠标点击时微动、任务栏在侧面时锚点更准。
成本：S。
高风险面：否。依据：`tray-icon:...windows/mod.rs:409-430`；我们 `main.rs:364-382`。

**W9 · WebView ready 握手（首帧不空白）**
价值：冷启动后立刻点托盘不会看到空窗。
成本：S。高风险面：否。
依据：`window.rs:729-745`；WebView2 `#4834`【检索】。

**W10 · 面板外 16px 阴影带的点击行为**
价值：现在窗口比可见双岛大 16px（`styles.css:171-175` + `window.rs:153`），那一圈半透明阴影会吞掉点击。是否可感知需实机确认（点面板边缘的桌面图标、点任务栏附近）。
成本：S 验证 / M 修复（收缩 padding 或按矩形裁窗口区域）。
高风险面：否。依据：`#app { padding: 16px }` 与 `PANEL_PADDING` 注释互指；WebView2 透明窗口默认仍参与命中测试（`WebView2Feedback#5668` 是同类问题的极端案例）【检索】。

**W11 · 开机自启状态与任务管理器同步**
价值：用户在任务管理器关掉自启后，我们的设置页不再显示"已开启"。
成本：S。高风险面：否。依据：`desktop_shell.rs:153-171` 只读 Run 键。

### P3

**W12 · Alt+Tab / 虚拟桌面行为核对**
`skipTaskbar: true`（`tauri.conf.json:24`）是否等价于 EarTrumpet 的 `WS_EX_TOOLWINDOW`（`FlyoutWindow.xaml.cs:37-40`），需要实机按一次 Alt+Tab 确认。成本 S。

**W13 · Fluent 主题下的弹簧降级**
`orbBounce`（阻尼 0.68）在 Fluent 主题里改成 `snappy`（0.94），或明确保留为品牌动效。成本 S。依据：`motionSpring.ts:8-18`。

**W14 · 把 `--panel-inset` 与原生 12px 对齐**
我们可见间隙 16px，EarTrumpet 在 Win11 用 12px（`FlyoutWindow.xaml.cs:178-181`）。截图对比 Win+A 后再定。成本 S。

---

## 11. 设想（不受现有 ADR 约束，注明冲突）

1. **可交互通知作为一等能力**（与 ADR 无关）：HA 自动化 → `notify` 到 PC → toast 带按钮（"开灯 / 稍后 / 关掉"）→ 按钮回调走我们已有的确认链路。它把「手机上的通知」搬到桌面上，且不需要任何新协议（本地 IPC 已有 secret 授权，`companion.rs:558-586`）。
2. **进程外"设备卡提供者"**（ADR-0023 允许重启评估）：照 Flow 的 JSON-RPC-over-stdio（`PythonPlugin.cs:12-31`），第三方用任意语言写一个子进程，宿主只认「查询 → 候选结果 → 执行」三件事，超时/重启/权限由宿主掌管。与 ADR-0023 不冲突（它排除的是**进程内**第三方代码），但需要新 ADR 定义协议与信任边界。
3. **PC 作为 HA 传感器源**（与 ADR-0014「不迁 MQTT」冲突）：把活跃窗口、麦克风占用、当前场景推给 HA。替代路径是不碰 MQTT 而走 HA 的 `webhook` 触发器 + 我们本地 IPC——需要 HA 侧一个蓝图，成本低于自定义集成。
4. **托盘 hover 预览**（技术上已具备，`tray-icon` 的 Enter/Leave 现成）：hover 300ms 弹一个 240px 的迷你岛，显示「3 台开着 + 温湿度」。风险是与 Win11 托盘自身 tooltip 打架，需要先做原型。
5. **卫星服务形态**（HASS.Agent 的路线）：把定时指令与自动化下沉到一个 Windows 服务（或计划任务），锁屏/未登录也执行。与我们「不收集远端遥测」的 ADR-0015 不冲突，但要让用户明确知道"未登录也在跑"。
6. **把后台定时器整体下沉到 Rust**，让 WebView 在隐藏态可以 `TrySuspendAsync()`（WebView2 官方内存旋钮）——收益是把常驻内存降一档，代价是所有 `setTimeout` 语义要在 Rust 侧重写一遍。成本 L，只在 W3 测出「隐藏态确实占着可观内存」时才值得。

---

## 12. 来源清单

**源码（本地克隆，`~/.cache/mbh-research-clones/`）**

- EarTrumpet：`EarTrumpet/UI/Views/FlyoutWindow.xaml.cs:27-42, 95-235`；`EarTrumpet/UI/Helpers/WindowAnimationLibrary.cs:24-211`；`EarTrumpet/Interop/Helpers/WindowsTaskbar.cs:14-91`；`EarTrumpet/UI/ViewModels/FlyoutViewModel.cs:45-51, 209-291, 320-360`；`EarTrumpet/UI/Helpers/ShellNotifyIcon.cs:87-95, 316-328`；`EarTrumpet/UI/Helpers/FlyoutViewState.cs`
- ModernFlyouts：`ModernFlyouts.Core/UI/FlyoutWindow/FlyoutWindow.OnScreen.cs:8-125`；`.../FlyoutWindow.Animations.cs:131-138, 173-181`；`ModernFlyouts.Core/Interop/BandWindow.cs:404, 439-441, 471-476`
- tray-icon：`src/platform_impl/windows/mod.rs:409-430, 505-545, 680-700`
- Tauri 插件：`plugins/single-instance/src/platform_impl/windows.rs:96-150`；`plugins/autostart/src/lib.rs`；`plugins/notification/src/desktop.rs:100-166`
- window-vibrancy：`src/windows.rs`（apply_blur / apply_acrylic / apply_mica 三套实现）
- Flow Launcher：`Flow.Launcher.Core/Plugin/PythonPlugin.cs:12-31`；`Flow.Launcher.Core/ExternalPlugins/CommunityPluginStore.cs`
- HASS.Agent：`Managers/NotificationManager.cs:21-58, 69+`；`Forms/Main.cs:765-800`；`README.md`
- EcoPaste：`src-tauri/src/window/position.rs:17-31`；`src-tauri/src/window/windows.rs:15-68`
- hass-claude-usage-taskbar：`README.md`

**文档**

- WinUI 3 时长与缓动：https://learn.microsoft.com/en-us/windows/apps/design/motion/timing-and-easing
- WebView2 性能：https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/performance
- WebView2 进程模型：https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model

**检索（issue / 仓库元数据，2026-11-23）**

- https://github.com/MicrosoftEdge/WebView2Feedback/issues/4834 （初始化期间空白窗口）
- https://github.com/MicrosoftEdge/WebView2Feedback/issues/5668 （透明 WebView2 窗口吞点击）
- https://github.com/MicrosoftEdge/WebView2Feedback/issues/5792 （显示变化后控件留白）
- https://github.com/emre-pn/ha-tray-panel （Electron + HA 托盘，2026-10）
- https://github.com/Sammyjo20/home-assistant-tray （Electron 教学级）
- 星数/最后提交时间来自 `gh api repos/<owner>/<repo>`

**未查到 / 需实机确认**

- Win11 原生 `Win+A` 的精确内缩值（我们用 16px，EarTrumpet 用 12px，官方未公开）。
- `StartupApproved\Run` 的 REG_BINARY 首字节取值语义。
- 自动隐藏任务栏时 `rcWork` 是否恒等于 `rcMonitor`（EarTrumpet 注释如此陈述，我用它作二手证据）。
- 我们 toast 的 AUMID `com.jryang.menubarmijia` 与安装器注册值是否一致。
- 透明 WebView2 是否逐像素命中测试（关系到 W10 是否成立）。
