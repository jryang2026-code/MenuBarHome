# 控制中心改版（实验分支）规格与契约

分支：`exp/control-center-redesign`（从 `origin/main` 955ba23 切出）。所有子任务 PR 的 base 都是这个分支，**不碰 `main`**。全部阶段完成、用户实机确认后，再由总指挥从本分支向 `main` 开一个总 PR，是否合并由用户决定。

调研依据：`docs/research/` 下的 2026-11-10 UX 调研（会话内四份报告的结论），以及用户给的两张参考图：macOS Tahoe 控制中心、通知中心堆叠。

## 0. 设计方向（一句话）

面板从「套了玻璃皮的设备列表」变成「控制中心模块网格」：状态色只放在图标圆章、滑杆填充和状态文字上，底板始终是同一层安静的玻璃；所有提醒收进一个 3 层堆叠的「通知中心」，撤销与 Toast 收进底部的瞬时横幅栈，二者可以同时存在。

模式：Operate（工具面板）。克制优先，熟悉的苹果控件语法优先于新奇效果；动效只表达状态。

## 1. 设计令牌（双端同值，macOS 单位 pt，Windows 单位 px）

### 1.1 圆角与形状

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| `Radius.panel` | 22 | 面板外框（macOS `MenuBarPanelController.panelCornerRadius` 与 Windows `.cc-popover` 同值） |
| `Radius.module` | 18 | 整行卡片、2×2 主磁贴、通知卡片 |
| `Radius.card` | 12 | 抽屉内嵌区块、输入框、提示条（沿用） |
| `Radius.inset` | 8 | 抽屉里的字段（沿用） |
| 2×1 磁贴 | `Capsule(style: .continuous)` | 半行设备磁贴 |
| 1×1 按钮 | `Circle()` | 场景、快捷动作 |

`PanelLook.tileRadius`（14）删除，调用方改用 `Radius.module` 或胶囊。

### 1.2 表面（Surface）

一层面板玻璃 + 平的内容井，**任何模式下都不再出现整块白色底板**。

| 状态 | 深色 | 浅色 |
| --- | --- | --- |
| 关（well） | `white 0.07` | `white 0.42` |
| 开（lit well） | `white 0.13` | `white 0.72` |
| 开 + 家族色（空调等） | 家族色 `0.20` 渐变到 `white 0.08` | 家族色 `0.14` 渐变到 `white 0.70` |
| 文字 | `.primary` / `.secondary` | `.primary` / `.secondary` |

- 开启态的强调只来自：圆章填充家族色 + 白色图标、状态文字加粗、滑杆填充。
- 删除 `TileSurface.isBrightPlatter`、`PanelLook.platterInk`、`DesignTokens.Ink.onPlatter` 以及只为白底板存在的反色墨水逻辑。
- 抽屉（展开区）是平的内嵌区：`Color.primary.opacity(0.04)`，不再叠第二层材质。
- 只在一个 1 px 阴影上做层级：模块 `black 0.10, r 10, y 3`（深色 `0.28`）；关闭态不加阴影。

### 1.3 高光边（Specular Rim）

不是单一斜向渐变。实测 Tahoe 控制中心是**上下两条亮边、左右两条暗边**：

- 上、下边：1 pt，白色（深色 `0.22` / 浅色 `0.65`），向内 14 pt 渐隐。
- 左、右边：1 pt，黑色（深色 `0.25` / 浅色 `0.08`），向内 6 pt 渐隐。
- 圆角处两条渐变自然交叠，不做特殊处理。
- 只有一个实现：macOS `ThemeAndMotion.swift` 里的 `SpecularRim` 修饰符；Windows `styles.css` 里的 `.cc-rim::after`（`mask-composite: exclude`）。现有的 `GlassTileBackground` 顶部 1.5 pt 高光条、`ClassicGlass` 的统一白描边、`PillActionButtonStyle` 的斜向描边全部改用它。

### 1.4 玻璃

- macOS 26：`adaptiveGlass` 走 `.glassEffect(.regular.interactive(), in: shape)`，`AdaptiveGlassContainer` 走 `GlassEffectContainer(spacing:)`；macOS 14/15 维持现有 Material 回退。只能在 `ThemeAndMotion.swift` 里调用（CODING_STANDARDS §8，`check.sh` 机械检查）。
- 内容磁贴（设备卡）**不用**玻璃，用 1.2 的平井；玻璃只给浮在内容上的东西：通知卡、瞬时横幅、滑杆游标、圆形按钮。
- Windows：WebView2 采不到桌面，`.cc-popover` 的 `backdrop-filter` 删除；改用 Tauri 原生 `windowEffects`（Acrylic，Win11 22H2+ 可用 Mica），CSS 底色降到 `0.55–0.62` 透明度；不支持时回退到实色 `#1c1d24`。

### 1.5 字号

沿用 `DesignTokens.TypeSize`。新增用法：2×1 磁贴标题 `body`(13) semibold、副标题 `caption`(12)；通知卡标题 `body` semibold、正文 `caption`、时间 `micro`(10)。

### 1.6 动效（`AppleMotion`）

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| `press` | easeOut 0.12，scale 0.97 | 一切可按元素 |
| `control` | spring 0.24 / 0.86 | 开关、圆章、选中态 |
| `reveal` | spring 0.34 / 0.86 | 抽屉展开、网格重排 |
| `stack` | spring 0.38 / 0.84 | 堆叠展开 / 收起 / 补位 |
| `dismiss` | spring 0.28 / 1.0 | 滑走、关闭 |
| `snappySpring` | 保留 0.26 / 0.94 | 现有调用方，逐步迁移 |

- 键盘触发的动作不加动画。
- 减弱动态效果：位移、缩放、模糊一律去掉，只保留 0.2 s 透明度渐变。
- Windows 用 `cubic-bezier(0.32, 0.72, 0, 1)` 近似 `stack`/`reveal`，`cubic-bezier(0.23, 1, 0.32, 1)` 做 `press`。

## 2. 通知中心（ActivityStack）契约

### 2.1 两个表面

| 表面 | 位置 | 内容 | 是否占布局 |
| --- | --- | --- | --- |
| **通知中心** `ActivityStackView` | 头部之下、搜索框之上 | 系统提醒（米家过期/将过期、HA 明文令牌、HA 地址）、主动守护告警、门铃记录 | 占；空时高度为 0 |
| **瞬时横幅栈** `TransientStackView` | 底部浮层（现 `overlayNotifications` 位置） | 撤销横幅、Toast，**可同时存在** | 不占，浮在内容上 |

两者共用同一个几何助手 `StackedCardGeometry`（CODING_STANDARDS §10：几何只有一个来源）。

### 2.2 堆叠几何

- 最多可见 3 张：`depth = min(index, 2)`。
- 缩放锚点 `.bottom`：depth 0 `scale 1.0, y 0, opacity 1`；depth 1 `0.94, +8, 0.78`；depth 2 `0.88, +15, 0.55`。
- 后两张只露底边：用遮罩隐藏文字，只留玻璃边缘与高光边。
- 容器高度 = 首卡高度 + 15，不是所有卡片之和。
- 只有首卡投阴影。
- 收起态点首卡或标题：用 `stack` 弹簧展开成竖排列表；列表底部「收起」。
- 首卡横向拖动超过宽度 40% 或抛掷速度足够即移除，下一张从 0.94 弹到 1.0。
- 指针悬停在栈上时暂停撤销倒计时（复用 `pauseUndoBannerCountdown` / `resumeUndoBannerCountdown`）。

### 2.3 头部

- 左：`通知中心`（`title` bold）+ 数量。
- 右：28 pt 圆形玻璃 `×`，清除所有**可清除**项。米家已过期（`.miBlocked`）与等待决定的 HA 明文令牌（`.haPlaintext(.asking)`）不可清除，清除全部后它们仍在。
- 只有 1 条时不显示头部，直接显示卡片。

### 2.4 数据模型（`MijiaCore`，纯值、可测、不 import SwiftUI）

```swift
public struct PanelActivity: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case notice(PanelNoticeSlot.Kind)
        case safety(SafetyAlert)
        case doorbell(DoorbellRing)
    }
    public let id: String          // 稳定：notice 用种类名，safety 用 alert.id，doorbell 用 ring.key
    public let kind: Kind
    public let date: Date?
    public var isDismissible: Bool
}

public enum PanelActivityFeed {
    /// 优先级：notice（沿用 PanelNotice.kinds 的顺序）> safety（新到旧）> doorbell（新到旧）。
    /// `dismissedIds` 里的可清除项被过滤；不可清除项忽略它。
    public static func items(notices: [PanelNoticeSlot.Kind], safety: [SafetyAlert],
                             doorbells: [DoorbellRing], dismissedIds: Set<String>) -> [PanelActivity]
}
```

- `HomeStore` 新增 `recentSafetyAlerts`（上限 10，在 `HomeStore+Backend.swift` 触发 `onSafetyAlert` 的同一处写入，开关关闭时不写）与 `dismissedActivityIds`。
- 每个新字段要写明清除点（CODING_STANDARDS §13）：切换后端（`invalidateUndoContext`）清空 `recentSafetyAlerts` 与 `dismissedActivityIds`；设备消失时对应告警移除。
- 撤销与 Toast 不进入这个模型，继续由 `undoBanner` / `toastNotice` 驱动，`TransientStackView` 只负责把它们同时画出来。

### 2.5 删除项（clean cutover）

- `PanelNoticeSlot.extraCount`、`PanelNotice.extraReminderLabel`、`ControlCenterPanel.noticeIndex` / `advanceNotice` / `pinnedNotice` / `scrollingNotice`、「还有 N 条提醒」按钮。
- `overlayNotifications` 的 `if undo else if toast` 互斥。
- `NoticeToastBanner` 动作按钮一律红色的写法：只有 `isError` 才用红色，否则用 `accentColor`。

## 3. 模块网格契约（阶段 2）

- `TileFlowLayout` 改为 12 列（内容宽 350 时单位 ≈ 22.4），支持行跨度：`TileSize` 增加 `.small`（1×1，3 列）与 `.hero`（2×2，6 列 × 2 行）；`.half` = 6 列（2×1 胶囊），`.full`/`.panel` = 12 列。已有保存的布局值保持含义不变。
- 行高固定：模块行 56，2×2 = 56×2 + 间距。设备列表里展开抽屉的卡片按内容高度。
- 点击契约，所有尺寸一致：**圆章 = 开关；名称/状态 = 打开详情；箭头 = 打开详情**；没有详情的设备，名称区也是开关。
- 进入布局编辑只走右键菜单「编辑布局…」与头部按钮；删掉卡片容器上 450 ms 长按进入编辑的路径。
- 2×1 胶囊：高 56，左侧 40 pt 圆章距边 8，标题 + 副标题两行，尾部最多 1 个元素（箭头）。星标、PiP、房间徽标移入右键菜单或副标题。
- `CCSlider`（替代 `LiquidGlassSlider`）：胶囊高 34，图标在轨道内左端，数值在轨道内右端或拖动时浮出，尾部可选 28 pt 圆形「更多」按钮；保留 10% 触感刻度、方向键与 VoiceOver 调节，并补可见的键盘焦点描边。
- Windows `panelPrefs.ts` 的 `spans()` / `targetSize` 与 macOS `TileResizeGestureMath` 同步改，二者是共享契约。

## 4. 阶段与分工

| 阶段 | 任务 | 平台 | 通道 |
| --- | --- | --- | --- |
| 1 | P1-A 表面、高光边、圆角、玻璃、动效令牌 | macOS | 执行 A |
| 1 | P1-B 通知中心 + 瞬时横幅栈 | macOS | 攻坚 |
| 1 | P1-C 原生 Acrylic、阴影、表面令牌、焦点环、减弱动态、解封动效 | Windows | 执行 B |
| 2 | P2-A 12 列网格 + 行跨度 + 1×1 / 2×2 | macOS（+ Windows 契约） | 攻坚 |
| 2 | P2-B 2×1 胶囊卡片 + 点击契约 + 删除长按编辑 | macOS | 执行 A |
| 2 | P2-C Windows 通知中心 + 瞬时横幅栈 | Windows | 执行 B |
| 3 | P3-A `CCSlider` 内嵌滑杆，灯/风扇/窗帘整行卡直出 | 双端 | 执行 A |
| 3 | P3-B 顶部状态胶囊（最近操作、摄像头/麦克风占用）、页脚收进溢出菜单、去分割线、打开即刷新 + 入场动效 | macOS | 执行 B |
| 3 | P3-C Windows 胶囊卡片、网格、滑杆对齐 | Windows | 攻坚 |
| 4 | 同房间多灯堆叠卡、灯组成员列表、分组总开关、摄像机 2×2 封面、菜单栏组合读数与告警角标 | 双端 | 按复杂度分配 |
| 5 | impeccable critique / polish、Codex 本地审查、实机验收清单 | — | 总指挥 + 审查 |

## 5. 每个子任务的交付规则

1. 在自己的 worktree 里，从 `origin/exp/control-center-redesign` 切出 `exp/cc-<任务号>-<短名>`。
2. 动 UI 前读：`.cursor/skills/poteto-mode/SKILL.md`、`~/.agents/skills/apple-design/SKILL.md`、`~/.agents/skills/emil-design-eng/SKILL.md`、`~/.agents/skills/impeccable/reference/craft-floor.md`；本文件是契约，冲突时以本文件为准，本文件与 `CODING_STANDARDS.md` 冲突时停下上报。
3. 调试只跑定向测试（`swift test --filter …`、`cd windows && npm test`）；提 PR 前跑一次 `bash scripts/check.sh`。
4. 界面变化：`bash scripts/record_snapshots.sh` 重录，逐张看过变化的 PNG，与代码同一个 commit。新增的条件视图带自己的快照用例（CODING_STANDARDS §12）。
5. 合并顺序在先的 PR 合进集成分支后，后到的 PR 用 `git merge origin/exp/control-center-redesign` 同步（不 rebase、不强推），PNG 冲突取对方版本后重录。
6. `gh pr create --base exp/control-center-redesign`，正文写：改了什么、新测试名、`check.sh` 汇总原文、截图前后对比、未验证项。
7. 跟进 Codex Auto Review 与 CI，修完评论 `@codex review`；同一问题 2 轮不收敛就停下上报。
8. 新术语写进 `GLOSSARY.md`；改到 CODING_STANDARDS 列出的不变量要同步改那一条。
