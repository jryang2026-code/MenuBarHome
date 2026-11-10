# 控制中心改版（实验分支）规格与契约（v2 · 无背景纯液态玻璃）

分支：`exp/control-center-redesign`。所有子任务 PR 的 base 都是这个分支，**不碰 `main`**。当前阶段**只改 macOS 端**（除非触及双端共享测试契约文件，如 `TileResizeGestureMath` 与 `windows/src/ui/panelPrefs.ts`）。

## 0. 核心设计转向（最高优先级）

用户实机看过第一阶段试用版后明确指出：**不要底板大背景！要完全对标 macOS Tahoe 原生控制中心——窗口本身全透明（无背景、无外框裁切），每一颗胶囊（`Capsule`）、方砖（`RoundedRectangle`）、圆钮（`Circle`）、滑杆模块都是独立的液态玻璃（Liquid Glass），直接悬浮在桌面壁纸之上！**

大刀阔斧砍掉过去「传统弹窗 App」的外壳与遗留包袱：
1. **彻底移除面板背景板（Window Background = Clear）**：
   - `PanelRoot` 在正常模式下**不画任何底板或遮罩**（删掉 `Color.clear.panelRootGlass()`、删掉 `Rectangle().fill(.ultraThinMaterial)`、删掉 `0.30 / 0.18` 的整窗黑/白遮罩）；仅在 `reduceTransparency == true` 时保留 `Color(nsColor: .windowBackgroundColor).clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous))` 无障碍回退。
   - `MenuBarPanelController.swift`：`panel.hasShadow = false`（去掉矩形大窗阴影），`hosting.layer?.cornerRadius = 0` 且 `hosting.layer?.masksToBounds = false`（让每个独立液态玻璃模块自带的柔和阴影与折射高光自然向外发散，不被矩形边框一刀切）。
2. **每一个模块自己就是真液态玻璃（Module = Independent Liquid Glass）**：
   - 推翻旧版「卡片不用玻璃、只用平井」的妥协！因为面板没有大背景，每一张卡片/胶囊/方砖都直接面对桌面壁纸，**必须自身就是完整的 Liquid Glass 折射体**。
   - `GlassTileBackground<S: InsettableShape>` 支持任意形状（`Capsule(style: .continuous)`、`RoundedRectangle(cornerRadius: DesignTokens.Radius.module, style: .continuous)`、`Circle()`）：
     - 在 macOS 26 且 `!reduceTransparency` 时：底层叠加 `shape.fill(surface.fill)`（提供微妙的明暗与家族色情绪基底），再直接走 `.glassEffect(isActive ? .regular.interactive().tint(tint) : .regular.interactive(), in: shape)`，外加 `.specularRim(shape, strength: isActive ? 1.25 : 1.0)` 与模块独立投影 `.shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: isActive ? 12 : 8, y: isActive ? 4 : 2)`（关闭态也有轻柔悬浮阴影，因为直接浮在桌面上！）。
     - 在 macOS 14/15 或快照回退时：`shape.fill(.ultraThinMaterial)` + `shape.fill(surface.fill)` + `.specularRim(shape)` + 同款独立阴影。
   - 每个分组/网格外层用 `AdaptiveGlassContainer(spacing: 8)` 包裹，让相邻液态玻璃模块在 macOS 26 下拥有原生的光学边缘交互。
3. **砍掉旧 App 式的「五层头部 + 分割线 + 底栏」**：
   - **删掉所有 `Divider()`**（液态玻璃控制中心里绝不允许出现横穿屏幕的实线分割线）。
   - **删掉传统底栏 `footerBar`**（底栏那排刷新、设置、退出按钮和连接文字全部收进顶部或右键菜单，释放宝贵垂直空间并消除「窗口底边」感）。
   - **顶部浓缩为苹果原生控制中心同款「悬浮灵动胶囊栏」**：
     - 居中或左对齐一颗 28pt 高的独立液态玻璃小胶囊（如参考图顶部的 `UURemoteService` 胶囊）：显示 `🏠 家庭名 · 4 台开启 · 25.8°`（点击可切换家庭或定位传感器）；右侧并排悬浮小巧的圆形液态玻璃按钮（搜索/语音 `magnifyingglass`、全关确认 `power`、更多菜单 `ellipsis` 含打开设置/立即刷新/排序/退出/更新角标）。
     - 搜索框（`omnibar`）和房间筛选胶囊同样是独立悬浮的液态玻璃胶囊，不再镶嵌在大底板上。

---

## 1. 视觉与几何规格（严格对齐 macOS Tahoe 控制中心参考图）

### 1.1 四种原生几何模块（12 列混排网格）

内容区净宽 `350pt`（左右各 `13pt` 留白供模块阴影自然呼吸），列间距与行间距统一为 `8pt`：

| 模块类型 | `TileSize` 枚举 | 网格跨度 | 尺寸与形状 | 适用设备与视觉布局 |
| --- | --- | --- | --- | --- |
| **2×1 液态胶囊** | `.half`（紧凑默认） | 6 列 × 1 行 | `171 × 58pt`<br>`Capsule(style: .continuous)` | **Wi-Fi / 蓝牙 / 专注模式同款**：左侧 `42×42pt` 饱满圆形图标章（距左边缘 `8pt`），开启时白底（`Color.white.opacity(0.95)`）配家族色图标或家族色实心圆配纯白图标（带柔和发光阴影），关闭时半透明暗槽（`Color.primary.opacity(0.10)`）配次要色图标；右侧紧凑两行：主标题 `13pt semibold` + 状态副标题 `12pt medium`。尾部最多 1 个元素（展开详情的小箭头或快捷键角标）。 |
| **2×2 液态大方砖** | `.hero`（新增） | 6 列 × 2 行 | `171 × 124pt`<br>`RoundedRectangle(22pt)` | **右上角「正在播放」同款方砖**：用于主空调、温湿度计、摄像机、音箱。左上角大号圆章或温湿度/封面，中部设备名与核心大字号读数（`24pt rounded bold`），底部内嵌快捷控制行（如空调 `− 26° +` 或音箱播放/暂停、传感器湿度条）。 |
| **1×1 液态正圆钮** | `.small`（新增） | 3 列 × 1 行 | `58 × 58pt`（或双圆并排）<br>`Circle()` | **台前调度 / 屏幕镜像同款正圆按钮**：用于快捷场景（全屋关灯、柔和夜灯、睡眠模式）或用户设为 `.small` 的单键开关/触发器。开启时整颗圆钮呈亮白/高光玻璃态+彩色图标，悬停/辅助功能显示名称。 |
| **4×1 内嵌滑杆大胶囊** | `.full` / `.panel` | 12 列 × 1 行 | `350 × 64pt`<br>`RoundedRectangle(22pt)` 或厚胶囊 | **「声音 / 显示器」同款全宽滑杆模块**：用于整行灯光、风扇、窗帘、加湿器。模块内部上方 `13pt semibold` 标题 + 右侧状态，下方直接内嵌 **28pt 满幅液态玻璃滑杆轨道**（左侧图标内嵌在轨道内，右侧内嵌 `26pt` 圆形更多/展开按钮），**无需点开二级抽屉就能直接滑动调光/调风速/调窗帘**！ |

### 1.2 表面与色彩令牌（`PanelDesign.swift` & `ThemeAndMotion.swift`）

- **`TileSurface`**：
  - 关闭态玻璃基底（`isActive == false`）：深色 `Color.black.opacity(0.22)` 叠 `Color.white.opacity(0.08)`；浅色 `Color.white.opacity(0.38)` 叠 `Color.black.opacity(0.04)`——保证在任何亮/暗桌面壁纸上，无背景悬浮胶囊都有温润的烟熏/磨砂玻璃体量感（如图中左侧 Wi-Fi/蓝牙/隔空投送的半透明灰玻质感）。
  - 开启态玻璃基底（`isActive == true`）：
    - 若带家族 `tint`（如专注模式/空调/彩色灯）：家族色 `0.26` 渐变到 `Color.white.opacity(scheme == .dark ? 0.14 : 0.48)`。
    - 普通开启态：深色 `Color.white.opacity(0.18)`，浅色 `Color.white.opacity(0.62)`。
  - 圆章（Icon Orb）：
    - 开启态：直径 `42pt`（紧凑胶囊）或 `38pt`（全宽模块），填充饱满家族色 `accent`（或白色圆章配 `accent` 图标），内部图标纯白，带 `accent.opacity(0.42), radius: 8, y: 2` 辉光。
    - 关闭态：直径同上，填充 `Color.primary.opacity(scheme == .dark ? 0.12 : 0.08)`，内部图标 `.primary.opacity(0.78)`。
- **双轴折射高光边（`SpecularRim`）**：
  - 强化棱镜折射感：上下亮边 `litEdge` 在深色下提高到 `0.34 * strength`（浅色 `0.75 * strength`），左右暗边 `shadedEdge` 深色 `0.28`（浅色 `0.10`），让每颗悬浮胶囊的上下玻璃厚边一眼可见（完全还原参考图里每颗胶囊周圈的明亮折射银边）。

---

## 2. 交互契约（纯正 Apple Control Center 手感）

1. **统一点击契约（全尺寸一致）**：
   - **点左侧圆章** = 立即切换开关（`togglePrimary`）。
   - **点右侧标题/状态文字或尾部圆形按钮** = 展开/收起详细控制抽屉（若设备无二级抽屉，则整颗胶囊点击均为切换开关）。
2. **移除 450ms 长按误进抖动编辑**：
   - 删掉 `ControlCenterPanelLayout.swift` 中 `pressTask`（450ms 长按卡片进入抖动编辑）的逻辑与状态，防止用户想拖动滑杆或慢点卡片时误触发全屏抖动。
   - 进入「编辑布局」统一走：卡片右键菜单「编辑布局…」或顶部胶囊栏的「…」菜单。
3. **直出式控制中心滑杆（`CCSlider` / 升级 `LiquidGlassSlider`）**：
   - 复刻参考图「声音 / 显示器」滑杆：胶囊轨道高 `28pt`，左端内嵌小图标（`sun.max.fill` / `wind` / `window.vertical.open`），拖动时填充条圆润跟随，游标采用立体液态透镜（`Capsule` 宽 `26pt` 高 `22pt`），右侧可带圆形「更多」按钮展开色温/模式等次级选项。

---

## 3. 第二阶段并行拆解（3 个独立 Worktree，只攻 macOS）

| 线程 | 任务代号 | 通道 / 模型 | 负责范围与文件边界（互不冲突） |
| --- | --- | --- | --- |
| **线程 1** | **P2-GlassShell**<br>无背景透明窗 + 真液态玻璃表面 + 悬浮顶部胶囊栏 | 攻坚 · OMP (`Codex Sol`) | **文件**：`MenuBarPanelController.swift`、`PanelDesign.swift`、`ThemeAndMotion.swift`、`ControlCenterPanel.swift`、`ControlCenterPanelChrome.swift`、`ActivityStackView.swift`、`TransientStackView.swift`、`PanelFoldLayoutTests.swift`<br>**内容**：<br>1. 去掉窗口大背景与外框圆角裁切（`PanelRoot` 透明化、`MenuBarPanelController` 关掉大窗阴影与 `masksToBounds`）；<br>2. 新增 `glassModule(in: shape, isActive:tint:)`，所有模块直接走真 `.glassEffect` + 强化版 `SpecularRim` + 独立悬浮阴影；<br>3. 升级 `LiquidGlassSlider` 为控制中心内嵌图标厚胶囊滑杆（高 28pt，图标在轨道内）；<br>4. 砍掉所有 `Divider()` 与底部 `footerBar`，将顶部改造为参考图同款「居中/置顶灵动状态胶囊 + 悬浮圆形工具钮（搜索、全关、更多菜单含设置/刷新/退出/更新）」；快捷场景栏改为紧凑液态玻璃胶囊/圆钮。 |
| **线程 2** | **P2-CapsuleCards**<br>2×1 真胶囊磁贴 + 42pt 发光圆章 + 直出滑杆大模块 + 统一点击契约 | 执行 A · OMP (`CommandCode DeepSeek`) | **文件**：`DeviceCardView.swift`、`ClimatePanelModule.swift`、`SensorCardView.swift`、`CoverDetailDrawer.swift`、`OnboardingChecklistCard.swift`<br>**内容**：<br>1. 半行设备卡（`isCompactTile == true`）外框彻底改为 `Capsule(style: .continuous)`（高 `58pt`），左侧 `42×42pt` 圆形图标章（距左 `8pt`），右侧两行标题+状态，去掉杂乱角标（星标/房间移入右键或副标题）；<br>2. 整行灯具、风扇、窗帘、加湿器卡片做成像参考图「声音 / 显示器」那样的直出滑杆大模块（上半行标题+开关圆章+右侧展开圆形钮，下半行直接内嵌滑杆，无需展开抽屉即可滑动！）；<br>3. 空调模块（`ClimatePanelModule`）与传感器卡（`SensorCardView`）升级为圆润 `22pt` 液态玻璃方砖，去掉生硬细线分割；<br>4. 统一单双列点击契约：左圆章=开关，右文字/圆形展开钮=展开详情。 |
| **线程 3** | **P2-GridLayout**<br>12 列网格 + `1×1 / 2×2` 模块尺寸 + 移除 450ms 长按抖动陷阱 | 执行 B · OMP (`OpenCode DeepSeek`) | **文件**：`DeviceLayout.swift`、`ControlCenterPanelLayout.swift`、`MenuBarPanelControllerTests.swift`、`windows/src/ui/panelPrefs.ts`、`windows/tests/panelPrefs.test.ts`<br>**内容**：<br>1. `TileSize` 扩展并支持 `.small`、`half`（2×1 胶囊）、`.hero`（2×2 方砖）、`.full`、`.panel`；`TileFlowLayout` 升级为 12 列网格并支持 `2×2` 方砖混排，四周留出阴影呼吸间距；<br>2. 彻底删除 `ControlCenterPanelLayout.swift` 中 450ms 长按卡片触发抖动编辑的 `pressTask` 逻辑（保留右键菜单「编辑布局…」与顶部菜单入口），更新 `MenuBarPanelControllerTests.swift` 中对应测试为通过 `LayoutUIState.shared.beginDeviceLayoutEditing()` 进入编辑并验证右下角圆弧手柄缩放；<br>3. 同步 `TileResizeGestureMath` 与 `windows/src/ui/panelPrefs.ts` 的共享契约测试。 |

---

## 4. 合并与实机交付顺序

1. 三个线程在独立 worktree 开发并跑通各自定向测试；
2. 先合 **P2-GlassShell** 与 **P2-GridLayout**，再合 **P2-CapsuleCards**，在集成分支统一重录快照基线并跑通全量 `bash scripts/check.sh`；
3. 立即使用 `screencapture -x -o -l<windowid>` 抓取桌面壁纸上的**真实上屏合成图**（检验无背景透明悬浮与 `.glassEffect` 真折射），并重新打包更新 `~/Applications/MenuBarHome-试用.app` 供用户实机体验。
