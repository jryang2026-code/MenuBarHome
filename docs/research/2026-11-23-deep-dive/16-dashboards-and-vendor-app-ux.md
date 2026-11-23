# 16 面板 / 仪表盘信息架构与交互

**调研日期**：2026-11-23
**范围**：Home Assistant 新版自动生成策略（areas / home / security / energy）、HA 社区卡片（Mushroom、Bubble Card、button-card、UI Lovelace Minimalist、Dwains Dashboard）、厂商 App 信息架构（Apple 家庭为主，Google Home 为辅）、以及落到 `MenuBarHome` macOS 面板与 Windows 托盘的差距与清单。
**只读**：本报告只做调研，未改动任何代码。

**实际读过的仓库（commit 与日期）**

| 仓库 | commit | 日期 | 深度 |
| --- | --- | --- | --- |
| `home-assistant/frontend` | `9eb51a8c06ddf223a936630591d93d873e6f94eb` | 2026-11-22 | 三层：`src/panels/lovelace/strategies/` 全目录、`src/panels/security/`、`src/panels/energy/strategies/` 逐文件读源码 |
| `home-assistant/iOS` | `ac2896d2f14a0e80d18e612eef7633d06b5be501` | 2026-11-16 | 二层：`Sources/Shared/Notifications/LocalPush/LocalPushEvent.swift` |
| `piitaya/lovelace-mushroom` | `68bc1ba6d3e480caedae28635bec24701c3a26e2`（v5.3.0） | 2026-11-12 | 三层：卡/芯片清单、`src/utils/colors.ts`、`chips-card.ts` 更新扇出 |
| `Clooos/Bubble-Card` | `2c3b43d1168ca05701be15fd96e416609601ecfa` | 2026-10-31 | 三层：`src/cards/pop-up/slide-to-close.js` 手势常量与坐标注释 |
| `custom-cards/button-card` | `dfa304f93ab73b41011b624960657c568672e9c9` | 2025-11-13 | 三层：`src/button-card.ts` 的 `shouldUpdate` / `_monitoredEntities` |
| `UI-Lovelace-Minimalist/UI` | `089a6afa732a940e9926f7aac30ad787f6cb7abc` | 2026-11-21 | 一层半：CHANGELOG 版本线、`custom_cards/` 清单（64 个） |
| `dwainscheeren/dwains-lovelace-dashboard` | `36b93f94ad2a042998840baff8fd71fc7e338767` | 2026-09-04 | 一层半：README 停更公告、`custom_components/dwains_dashboard/` 结构 |
| `home-assistant/core` | `b6d170e22714866fdd8a50f865013bed9648f606` | 2026-11-23 | 只抓到 6 个 component 的部分克隆，**不足以支撑后端结论**，故本报告不使用 |

**文档 / 本地 SDK**
- `https://www.home-assistant.io/dashboards/`、`/dashboards/sidebar/`（访问 2026-11-23，站点版本 2026.11.2）
- Apple《Home User Guide》(macOS 27)：`welcome` / `home-screen` / `set-notifications` / `activity-history` / `view-electricity-usage-and-rates`
- Google《Home and Nest Help》根导航
- 本机 SDK：`MacOSX27.2.sdk/System/Library/Frameworks/UserNotifications.framework/Headers/{UNNotificationContent,UNNotificationSound,UNNotificationSettings}.h`

**证据标注约定**：【源码】附 `repo:path:行号`；【文档】附 URL；【检索】仅看摘要/评论；【推断】我的判断。查不到直接写「未查到」，不补营销话术。

---

## 0. 结论先行

1. **HA 新版仪表盘的核心不是"自动排版"，是"纯函数生成声明式配置"**：`dashboard → view → section` 三级策略，每级都是 `(config, hass) => Lovelace配置` 的纯函数，UI 只是一次解释执行。同一份配置在宽屏出「主列 + 右栏」，窄屏塌成单列同一顺序。【源码】`home-assistant/frontend:src/panels/lovelace/strategies/get-strategy.ts:41-58,347-380`；【文档】`https://www.home-assistant.io/dashboards/sidebar/`
2. **首屏优先级 HA 定得很死**：收藏（含使用频率补位）→ 摘要（灯/温控/安防/影音/维护/能耗/天气/在家情况）→ 楼层与区域网格；告警单独一层且默认侧栏、条件可见。顺序是常量数组 `HOME_SUMMARIES`，不是运行时打分。【源码】`src/panels/lovelace/strategies/home/helpers/home-summaries.ts:8-18`、`home/home-overview-view-strategy.ts:295-320,566-625`
3. **固定位永在、预测只填空位**：`common-controls` 先放用户 pin 的实体，再按使用频率填满剩余槽位，且**按卡片尺寸算预算**（摄像头占 2 槽）——不是按"台数"。【源码】`src/panels/lovelace/strategies/usage_prediction/common-controls-section-strategy.ts:26-38,113-118`、`helpers/favorite-cards.ts:11-13`
4. **区域页用 7 个固定分组**：`lights / climate / covers / media_players / security / actions / others`，顺序固定、图标固定，空组不渲染。【源码】`src/panels/lovelace/strategies/areas/helpers/areas-strategy-helper.ts:21-39`、`areas/area-view-strategy.ts:100-200`
5. **分组标题本身就是批量开关**：灯组标题挂一个 badge，任一灯开 → 显示"关灯"，全关 → 显示"开灯"，label 带区域名，用 `visibility` 条件切换。我们现在的「全关」是全局按钮，没有"按组/按房间"的动词随状态翻转。【源码】`home/home-area-view-strategy.ts:120-190`
6. **HA 的安全告警只有两级**：`alert`（红）/ `warning`（琥珀），且**由 `device_class` 推断而非用户配置**（烟感/燃气/漏水/一氧化碳/玻璃破碎/safety → alert），用户可覆盖。【源码】`src/panels/security/strategies/security-alerts.ts:15-51`、`common/entity/alert_active.ts:6-19`
7. **Apple 家庭的同类收敛可作交叉验证**：烟感与门锁通知默认开启、运动传感器默认关闭；8 秒内再点一次可撤销；瓷砖"实心=可操作 / 透明=只读"；烟雾/漏水/一氧化碳/二氧化碳归为一个告警类目。【文档】Apple `set-notifications`、`home-screen` 页；这条与我们 `SensorAlertKind.enabledByDefault`（漏/烟/气 true，门窗/人体 false）**独立撞车**，说明这个默认值是对的。
8. **我们最缺的不是卡片，是中间层**：面板从"系统提醒"直接跳到"单台设备卡片"，没有"这个家现在怎么样"的分组摘要。macOS 头部只有 `N 台开启` 一个数字（`PanelHeaderState.swift:21-34`），Windows 反而更全（`windows/src/ui/app.ts:1778-1791` 有"X 台开启中 · 共 Y 台在线"）。【源码】
9. **通知分级我们完全没用**：全仓库 `grep interruptionLevel` 无命中，所有通知落在默认 `active` 档——烟感告警和"已错过的定时"一样响。Apple 平台给了 4 档 + `relevanceScore`，HA iOS 端已按服务端字段完整映射。【源码】`Sources/MenuBarMijiaApp/HotkeyAndNotificationManager.swift:769-790`；`MacOSX27.2.sdk/.../UNNotificationContent.h:20-33,81-84`；`home-assistant/iOS:Sources/Shared/Notifications/LocalPush/LocalPushEvent.swift:111-113,201-215`
10. **社区那条路的终点是"被官方吸收"**：Dwains Dashboard（最经典的"按区域自动生成"）README 明写 DD3 停止功能开发、只维护，后继 `dwains-dashboard-next` 仍是 alpha；button-card 最新提交停在 2025-11-13；Minimalist 仍停在 `1.0.0-beta.11`。【源码】`dwainscheeren__dwains-lovelace-dashboard:README.md:5-19`、各仓 `git log -1`

---

## 1. Home Assistant 策略系统（三层剖析）

### 1.1 架构：策略是纯函数，输出配置而不是像素

`get-strategy.ts` 里三张表定义了全部内置策略（`dashboard` / `view` / `section`），每一项都是动态 `import()`，按需加载：

```ts
const STRATEGIES = {
  dashboard: { "original-states": …, map: …, iframe: …, areas: …, home: …, energy: … },
  view: { …, area, "areas-overview", "home-overview", "home-media-players", "home-area",
             "home-other-devices", light, security, climate, maintenance },
  section: { "common-controls", device, entities },
}
```
【源码】`home-assistant/frontend:src/panels/lovelace/strategies/get-strategy.ts:41-58`

为什么这样做值得抄：

- **生成与渲染解耦**。策略返回的是 `LovelaceViewConfig`（`type: "sections"`、`cards: [...]`、`grid_options`），渲染器不知道有策略这回事。于是"自动布局"可以在没有 UI 的地方被测试、被 YAML 覆盖、被另一个策略复用（`home-dashboard` 就把 `home-overview`、`home-area`、`home-media-players`、`home-other-devices` 拼成一个 dashboard，见 `home/home-dashboard-strategy.ts:104-133`）。
- **强制降级路径**。生成失败不会白屏：`renderError` 注入一个 markdown 卡把错误文本画出来；`hass.config.state === STATE_NOT_RUNNING` 时返回 "starting" 卡，`recovery_mode` 返回 "recovery-mode" 卡。【源码】`get-strategy.ts:190-230`、`areas/areas-dashboard-strategy.ts:53-77`
- **重生成由注册表引用相等触发，而不是状态变化**。`checkStrategyShouldRegenerate` 默认比较 `entities / devices / areas / floors` 五个注册表对象的引用，策略可以声明 `registryDependencies` 收窄，也可以实现 `shouldRegenerate` 自定义（`home-overview` 额外比较告警实体的**严重度**是否变化）。【源码】`get-strategy.ts:34-39,291-322`；`home/home-overview-view-strategy.ts:117-135`

对照我们：`deviceStacks`（`Sources/MenuBarMijiaApp/ControlCenterPanelStacks.swift:188`）是一个**纯计算属性**，输入是 `visibleDevices / favoriteDevices / habitOrder / customOrder / groupMap / grouping`。这已经是"策略函数"的形状，但它直接返回 `[DeviceStack]`（视图模型），不是可持久化/可对比的配置，且没有 `shouldRegenerate` 之类的"什么变了才重算"的边界声明。详见 §6。

### 1.2 Areas 自动布局算法：7 个固定分组 + 能力阶梯

区域页把实体的 `domain/device_class` 映射到 7 个固定桶，**桶的顺序就是渲染顺序**，空桶不生成 section：

| 顺序 | 组 | 图标 |
| --- | --- | --- |
| 1 | `lights` | `mdi:lamps` |
| 2 | `climate` | `mdi:home-thermometer` |
| 3 | `covers` | `mdi:blinds-horizontal` |
| 4 | `media_players` | `mdi:multimedia` |
| 5 | `security` | `mdi:security` |
| 6 | `actions` | `mdi:robot` |
| 7 | `others` | `mdi:shape` |

【源码】`src/panels/lovelace/strategies/areas/helpers/areas-strategy-helper.ts:21-39`

桶的划分不是一对一 domain，而是**语义归并**，这点比按 domain 平铺高明：

- `covers` 同时收 `cover` 域和 `binary_sensor` 的 `door/garage_door/window`——因为用户心里"门窗开没开"和"窗帘开没开"是同一件事。
- `climate` 收 `climate / humidifier / water_heater / fan`——"能让房间变冷变热变干变湿的东西"。
- `security` 收 `alarm_control_panel / lock / camera`。
- `others` 收吸尘器、割草机、阀门，最后是 `switch/button/input_boolean/input_button` 与 `select/number/input_select/…`。
【源码】`areas-strategy-helper.ts:63-268`

**能力阶梯**决定每张卡显示哪种控件（先命中先用）：摄像头走 `picture-entity`（占 6×2 网格），其余先试 `light-brightness` → `cover-open-close` → `target-temperature` → `fan-speed` → `alarm-modes` → `lock-commands`，都不支持就退化成纯 `tile`。【源码】`areas-strategy-helper.ts:332-400`

还支持 `groups_options: { [group]: { hidden: [...], order: [...] } }`——**逐组隐藏与逐组排序**，而不是整页开关。【源码】`areas-strategy-helper.ts:415-437`、`areas/area-view-strategy.ts:24-30`

### 1.3 Home 首屏：优先级是常量，响应式是同一份配置的两种投影

`home-overview` 生成的 section 顺序（代码里 `sections` 数组的构造顺序，即渲染顺序）：

1. `emptyStateSection`（仅"什么都没有"时）
2. `mobileAlertsSection`（**仅窄屏** + 仅告警处于激活态时）
3. `favoritesSection`（`common-controls` 生成，见 §1.4）
4. `mobileSummarySection`（**仅窄屏**）
5. `...floorsSections`（按楼层分组的区域网格，`max_columns: 3`）
+  **右栏 `sidebar`**（**仅宽屏**）：摘要标题 + 告警卡 + 全部摘要卡（`grid_options: { columns: 12 }`）

【源码】`home/home-overview-view-strategy.ts:700-740`

关键数字与规则：

- `maxColumns = 3` —— 宽屏最多三列，硬上限。【源码】`:162`
- 摘要卡顺序常量 `HOME_SUMMARIES = ["alerts","light","climate","security","media_players","maintenance","energy","persons"]`，每项配固定图标与固定颜色（`alerts: red`、`light: amber`、`climate: deep-orange`、`security: blue-grey`、`media_players: blue`、`maintenance: grey`、`energy: amber`、`persons: green`）。【源码】`home/helpers/home-summaries.ts:8-40`
- 摘要卡不是无脑全出：`hasLights` 需要"灯面板存在且有灯实体"，`hasEnergy` 需要"能耗面板存在且至少有一个带 `stat_energy_from` 的电网来源"，`hasSecurity/hasMaintenance` 要求对应面板存在且找得到实体。**没有数据的摘要不出现**。【源码】`home-overview-view-strategy.ts:352-420`
- 系统健康三卡 `repairs / updates / discovered-devices` 全部 `hide_empty: true` 且只对管理员可见，固定排在最前。【源码】`:505-530`
- 楼层标题的三分支：多楼层用楼层名；只有一个楼层时用"区域"；无楼层有区域时用"区域"；都没有但有设备时用"设备"。**标题文案随结构变化，而不是永远写"区域"**。【源码】`:236-283`

响应式那一段值得单独说：`LARGE_SCREEN_CONDITION = { condition: "view_columns", min: 2 }`、`SMALL_SCREEN_CONDITION = { max: 1 }`，**同一个数组 `summaryCards` 投影两次**——窄屏每张 `columns: 6` 塞进主列，宽屏每张 `columns: 12` 塞进右栏。没有第二套逻辑，没有两套文案。【源码】`helpers/view-columns-conditions.ts:4-11`、`home-overview-view-strategy.ts:560-625`

### 1.4 固定位 + 预测填空：一个可复用的槽位预算模型

```ts
const limit = config.limit ?? DEFAULT_LIMIT;                       // 8
const includedEntities = (config.include_entities || []).filter(e => e in hass.states);
const freeSlots = limit - computeFavoriteCardsSize(includedEntities);
// Pinned entities always show. Predictions only fill the free slots.
```
【源码】`src/panels/lovelace/strategies/usage_prediction/common-controls-section-strategy.ts:113-118`

填空时按尺寸记账，装不下就跳过继续试下一台（不是截断）：

```ts
const fitToLimit = (entities, limit) => {
  const result = []; let size = 0;
  for (const entity of entities) {
    const entitySize = computeFavoriteCardSize(entity);   // camera => 2, 其它 => 1
    if (size + entitySize > limit) continue;
    result.push(entity); size += entitySize;
  }
  return result;
};
```
【源码】`common-controls-section-strategy.ts:26-38`、`helpers/favorite-cards.ts:11-13`

调用方给的预算是 `Math.max(8, computeFavoriteCardsSize(favoriteEntities))`——**用户 pin 得越多，预算越大，pin 永不被预测挤掉**。【源码】`home/home-overview-view-strategy.ts:294-320`

过滤顺序也有讲究：不存在 → `hidden` → 用户 `exclude_entities` → 与 pin 重复，前三条都在算预算之前。【源码】`common-controls-section-strategy.ts:126-140`

### 1.5 安全告警分级：两级、可推断、可覆盖

```ts
export type SecurityAlertSeverity = "alert" | "warning";
const DANGER_BINARY_SENSOR_DEVICE_CLASSES = ["carbon_monoxide","gas","glass_break","moisture","safety","smoke"];
// alarm_control_panel => "alert"；binary_sensor 命中危险类 => "alert"；其余 => "warning"
export const computeDefaultSecurityAlertSeverity = (stateObj) => { … };
export const resolveSecurityAlertSeverity = (cfg, stateObj) => cfg.severity ?? computeDefaultSecurityAlertSeverity(stateObj);
```
【源码】`src/panels/security/strategies/security-alerts.ts:15-51,76`、`src/data/frontend.ts:47-52`

"是否激活"也不是字符串比较，而是**按 domain 给出激活状态集合**：

```ts
alarm_control_panel → ["triggered"]
cover              → ["open"]
lock               → ["jammed","unlocked","open"]
默认                → ["on"]
```
【源码】`src/common/entity/alert_active.ts:6-19`

告警卡的 `alert_color` 直接由严重度推出（`alert → red`、`warning → amber`），可见性由激活状态集合生成 `StateCondition`，**没有硬编码的状态字符串散落在各处**。【源码】`security-alerts.ts:95-111`

为什么只有两级：告警是"要打断你"的东西，级别越多用户越难预测后果。两级 + "由设备类别自动推断 + 允许逐实体覆盖"是在**减少用户配置**和**保留例外**之间最省心的点。我们目前是 `SensorAlertKind` 五种（漏/烟/气/门窗/人体）× 三个布尔开关（`enabledByDefault` / `colorsMenuBar` / `honorsAwayLimit`），语义正确但没有"严重度"这个可直接驱动 UI 与通知的一维。

### 1.6 能耗：数据模型 + 卡片目录

数据模型是**来源（source）+ 设备消费（device_consumption）**两层，不是"一个总数"：

- `GridSourceTypeEnergyPreference`：`stat_energy_from`（用电）/ `stat_energy_to`（回网）/ `stat_cost` / `stat_compensation` / 四种电价字段（实体或数值，进出口各一套）
- `SolarEnergyPreference`（+ `config_entry_solar_forecast`）、`HomeEnergyPreference`、`GasEnergyPreference`、`WaterEnergyPreference`
- `DeviceConsumptionEnergyPreference`：`stat_consumption` / `stat_rate` / `name` / `included_in_stat`（**"已包含在总表里"标记，避免重复计入**）
【源码】`src/data/energy.ts:52-150`

卡片不是 if-else 堆出来的，而是一张 `ENERGY_CARD_CATALOG`：每条 `{ view, key, isApplicable(prefs) }`，策略只调 `isEnergyCardVisible(view, cardType, prefs, hidden)`，并且源码注释明说这样"策略永远不会重新推导条件、也就永远不会和目录打架"。【源码】`src/panels/energy/strategies/energy-cards.ts:19-60,340-352`

概览页顺序：`energy-compare` → `energy-distribution` → `energy-sources-table`（`show_only_totals: true`）→ `power-sources-graph` → `energy-usage-graph` → …，`max_columns: 3`，`dense_section_placement: true`，日期选择器钉在 `footer`。【源码】`src/panels/energy/strategies/energy-overview-view-strategy.ts:27-140`

同时有一处**明确的性能手法**：`preloadHomeEnergyPreferences` 用 `WeakMap<connection, Promise>` 提前并发拉取能源偏好，生成完毕再 `delete`——一次性预取，避免 `await` 串在生成流程中间造成瀑布。【源码】`home/home-overview-view-strategy.ts:63-84,400-404`

### 1.7 社区卡片三层剖析

**Mushroom（v5.3.0）**：`src/cards/` 下 19 个卡片目录（`alarm-control-panel / climate / cover / fan / humidifier / light / lock / media-player / number / person / select / template / title / update / vacuum / entity / empty` + `chips-card` + `legacy-template-card`）+ 11 种芯片（`action / alarm-control-panel / back / conditional / entity / light / menu / quickbar / spacer / template / weather`）。【源码】`piitaya__lovelace-mushroom:src/cards/`、`src/cards/chips-card/chips/`

- 色板是 26 个具名色（`primary/accent/red/…/blue-grey/black/white/disabled`），全部落在 CSS 变量 `--rgb-<name>`，自定义 hex 走 `culori` 的 `rgb()` 现算。【源码】`src/utils/colors.ts:4-30,32-46`
- `chips-card` 的布局只有一句 `flex-wrap: wrap`（`src/cards/chips-card/chips-card.ts:131`），密集状态靠横向换行而不是横向滚动。
- **更新扇出很讲究**：父卡 `set hass` 时不重渲染自己，而是 `querySelectorAll("div > *")` 把 `hass` 直接赋给每个子芯片，父级只处理暗色模式切换的 `toggleAttribute`。【源码】`src/cards/chips-card/chips-card.ts:66-78`

**Bubble Card**：popup 走 **URL hash 路由**（`#kitchen-popup`），浏览器后退即关；代价是 33 个 popup 相关文件、约 2 万行代码去对抗 HA 自己的 `touchend.preventDefault()`。【源码】`Clooos__Bubble-Card:src/cards/pop-up/`（`helpers.js` 3239 行 + 4625 行测试）

真正值得抄的是它**抄自 HA 底部抽屉的手势参数与踩坑记录**（注释里写明"Numbers below are HA's"）：

| 常量 | 值 | 作用 |
| --- | --- | --- |
| `VELOCITY_SWIPE_THRESHOLD` | 0.5 px/ms | 甩动优先判定的速度门限 |
| `MOVEMENT_TIME_THRESHOLD` | 100 ms | 抬手前停住的慢拖按"位置"判，不算甩动 |
| `CLOSE_HEIGHT_RATIO` | 0.5 | 拖过自身高度一半即关闭 |
| `DRAG_START_SLOP` | 8 px | 抖动不移动 |
| `CLOSE_DURATION` | 300 ms `ease` | 与样式表一致，避免"松手瞬间刹车" |
| `RELEASE_SPEED_WINDOW` | 50 ms | 释放速度的采样窗 |
| `MIN_RELEASE_DURATION` | 80 ms | 最短退出动画，防闪没 |

【源码】`Clooos__Bubble-Card:src/cards/pop-up/slide-to-close.js:28-55`；同样的 0.5 / 100 出现在 HA 前端 `src/common/util/swipe-gesture-recognizer.ts:13-14` 与 `src/components/ha-bottom-sheet.ts:312-336`（速度优先、位置 50% 兜底）。

**button-card**：一张卡支持 6 种动作 × tap/hold/double-tap、面板级 JS 模板、`javascript` 自定义动作。性能靠 `_monitoredEntities`：解析配置时把用到的实体记下来，`shouldUpdate` 只在**被监视实体**变化时返回 true；复杂卡可设 `update_timer` 按 ≥100ms 节流。【源码】`custom-cards__button-card:src/button-card.ts:189,273-274,422-424,477-519`

这套机制是"订阅粒度"的教科书：**卡片声明它依赖什么，而不是被动接收整个世界**。SwiftUI 里对应的做法是让每个卡片只读自己的 `device` 值 + 少量全局开关，而不是把 `store.devices` 传进去。

**UI Lovelace Minimalist**：70 个 `custom_card_*` / `custom_chip_*` / `custom_template_*` 目录，本质是 YAML 模板市场；CHANGELOG 顶部仍是 `1.0.0-beta.11`。【源码】`UI-Lovelace-Minimalist__UI:CHANGELOG.md:1-3`、`custom_cards/`（70 项）

**Dwains Dashboard**：README 2026-06 公告——"DD3 is no longer under active feature development and will slowly be phased out"，后续 `dwains-dashboard-next` 仍 alpha。【源码】`dwainscheeren__dwains-lovelace-dashboard:README.md:5-19`

**这五个项目连起来读出一个结论**：社区侧"自动生成 + 模板化"的探索已经被核心吸收（areas/home/security/energy 四套策略），剩下的社区项目退化成夹具。我们如果要做自动布局，正解是抄**算法与常量**，不是抄那套插件/模板架构——ADR-0020 也已经排除进程内第三方代码插件。

---

## 2. 厂商 App 的信息架构

**先声明证据边界**：米家 App、Aqara Home、SmartThings、涂鸦智能生活的界面结构，本次**没能取得可信一手证据**（`home.mi.com` 只吐 "You need to enable JavaScript"；`www.mi.com/cn/support/` 返回"页面不见了"；`www.aqara.com/cn/support/` 只有营销导航；`support.smartthings.com` 返回 403；涂鸦官网是开发者门户）。**这几家一律标注「未查到」**，不用二手评测去补。下面只写我真的读到的。

### 2.1 Apple 家庭（macOS 27 用户指南，访问 2026-11-23）

官方目录即信息架构：

```
Welcome → Set up rooms (Add / Arrange / Group rooms) → Add accessories
        → Control accessories (Overview / Cameras / Lights / HomePod)
        → Home screen → Scenes → Automations → Desktop widgets → Activity history
        → Apple Intelligence with cameras and notifications
        → Use Grid Forecast → View electricity usage and rates
        → Access away from home → Set notifications → Share control → Configure a router
```
【文档】`support.apple.com/en-us/guide/home/welcome/mac`

从具体页里读到四条硬规则：

1. **首屏 = 收藏（配件 + 场景）+ 拖动重排**。"The first eight scenes you add to Home are automatically shown on the Home screen"——**场景默认上限也是 8**，与 HA 的 `DEFAULT_LIMIT = 8` 撞车。【文档】`…/home-screen-hme725726702/mac`；【源码】`common-controls-section-strategy.ts:26`
2. **瓷砖外观 = 交互模型**：实心瓷砖点图标即开/关，**"a delay of 8 seconds allows you to undo your action by clicking again"**；透明瓷砖只读，点击进详情。Control-click / force click 进详情。【文档】同上
3. **同类传感器聚合为一个类目**："Climate sensor accessories are grouped together under one accessory category. Alarm sensor accessories (smoke, leak, carbon monoxide, and carbon dioxide) are also grouped together under one accessory category."【文档】同上
4. **通知默认值按类别给**："Some accessories, like smoke sensors and door locks, have notifications enabled by default… like motion sensors"（默认关）。通知设置分两处：配件内 `Status and Notifications`，以及系统设置里按 App 统一改；临时关闭或"只收关键告警"走系统专注模式。【文档】`…/set-notifications-hme25d1d9fd9/mac`
5. **能耗是"账户级"，且诚实披露延迟**：电力用量在 `Home Settings → Energy → Connect Account` 关联电力账户，页面明写 "Electricity usage data is typically displayed with a lag of 24 to 72 hours"，且标注 "participating U.S. providers only"。【文档】`…/view-electricity-usage-and-rates-hmef4ecff6d2/mac`
6. **活动记录有独立入口且限期**：`Home Settings → Safety & Security → Activity History`，最多 30 天（"One Month"），也可从 Home → Security 类目进。【文档】`…/activity-history-hme415fb4f77/mac`

### 2.2 Google Home（帮助中心导航，访问 2026-11-23）

根导航把 App 相关主题拆成 8 个并列项：`Get started with the Google Home app` / `Add or remove devices` / `Share and manage your home` / `Control your home` / `Automate your home and devices` / `Change your personal settings` / `Change home and device settings` / `Fix a problem`。【文档】`support.google.com/googlenest/?hl=en`

可提炼的只有一处结构性判断（我标注为【推断】）：Google 把「控制」(Control your home)、「自动化」(Automate your home and devices)、「个人设置」(personal settings)、「家庭与设备设置」(home and device settings) 拆成四个互不重叠的入口——**"控制"与"自动化"在导航上平级，不在同一页混排**。我们目前自动化在设置里（`AutomationSettingsSection`），面板只做控制，方向是一致的。

> Gemini / 新版卡片的具体形态：**未查到**（`blog.google` 可访问但本次未检索到描述 App 结构的一手页面；搜索引擎被反爬拦截，不做二手转述）。

---

## 3. 通知与安全分级：把三处证据拼成一张表

### 3.1 Apple 平台给了几档（本地 SDK 原文）

```objc
// Added to the notification list; does not light up screen or play sound
UNNotificationInterruptionLevelPassive,
// Presented immediately; Lights up screen and may play a sound
UNNotificationInterruptionLevelActive,
// …; May be presented during Do Not Disturb
UNNotificationInterruptionLevelTimeSensitive,
// …; Always presented during Do Not Disturb; Bypasses mute switch; Includes default critical alert sound
UNNotificationInterruptionLevelCritical,
```
另有 `relevanceScore`（0.0–1.0，"determines the sorting for the notification across app notifications"）和 `criticalAlertSetting`（单独的用户设置项）。【源码】`MacOSX27.2.sdk/System/Library/Frameworks/UserNotifications.framework/Headers/UNNotificationContent.h:20-33,81-84`、`UNNotificationSettings.h:74`

`criticalSoundNamed:` 在 macOS 上可用，但 `defaultCriticalSound` 的语义是"绕过静音与专注"——**关键告警音需要系统侧的 Critical Alerts 能力，属付费开发者计划范围**；本项目 README 明写未加入付费开发者计划（`README.zh-CN.md`「本项目没有加入付费的 Apple 开发者计划」）。因此**我们能可靠到达的天花板是 `timeSensitive`**，`.critical` 只作降级兼容分支。【推断】（依据：README 声明 + SDK 可用性注释；未查到 entitlement 的直接文档，故标推断）

### 3.2 HA iOS 端怎么用这四档

服务端下发 `aps.interruption-level` 字符串，客户端一对一映射，未知值一律回落 `.active`：

```swift
case "passive": self = .passive
case "active": self = .active
case "time-sensitive": self = .timeSensitive
case "critical": self = .critical
default: self = .active
```
【源码】`home-assistant/iOS:Sources/Shared/Notifications/LocalPush/LocalPushEvent.swift:201-215`；`thread-id` / `badge` / `category` 也一并映射（`:95-113`）

### 3.3 我们现在的做法

- 面板内已有**三层**：`pinned`（`notice` / `doorbell` / 安全类，其中 `isUrgentLifeSafetyHazard` 再提一级）、`ordinary`（折叠成一行胶囊，"第一条 等 N 条提醒"）、`toast/undo`。【源码】`Sources/MenuBarMijiaApp/ActivityStackView.swift:8-30,54-72,249-260`
- `SensorAlertKind` 已把"能不能被专注/离家抑制"编码为 `honorsAwayLimit`（漏/烟/气 = false 即不可抑制，门窗/人体 = true）。【源码】`Sources/MijiaCore/Models.swift:456-500`
- 系统通知侧：`deliverNotification(for:)` 只设 `title/body/sound/categoryIdentifier`，**没有 `interruptionLevel`、没有 `relevanceScore`、没有 `threadIdentifier`**。【源码】`Sources/MenuBarMijiaApp/HotkeyAndNotificationManager.swift:769-790`；周报 `:793-806`；外部队列 `:812-826`；错过的定时 `:828-847`
- 已经读到了系统专注状态（`INFocusStatusCenter`），但只喂给自动化，**没有用于抑制通知**。【源码】`Sources/MenuBarMijiaApp/MacContextObserver.swift:32-33,266-272`；`Sources/MijiaCore/MacContextAutomation.swift:162-167`

### 3.4 拼出来的分级表（可直接实现）

| 事件 | 面板层 | 系统通知档 | 声音 | 依据 |
| --- | --- | --- | --- | --- |
| 漏水/烟雾/燃气（`honorsAwayLimit == false`） | pinned 最高 | `.timeSensitive` | 默认声 | HA 危险 device_class → `alert`；我们 `honorsAwayLimit` |
| 门锁异常 / 门铃 | pinned | `.timeSensitive` | 默认声 | Apple 门锁默认开通知 |
| 门窗/人体（离家时才报） | pinned 或 ordinary | `.active`（专注中降 `.passive`） | 默认声 | `honorsAwayLimit == true` |
| 错过的定时 | 独立卡（橙色 + 立即执行/忽略） | `.active` | 默认声 | 需要动作，不能静默 |
| 外部队列执行结果（URL / App Intents） | toast | `.passive` | 无声 | 不是告警，是回执 |
| 周报 | 无 | `.passive` | 无声 | 汇总性质 |

`relevanceScore` 建议：安全 1.0、错过定时 0.7、回执 0.3——同一 App 多条通知时，系统按它排序而不是按时间。

---

## 4. 新手引导

- **HA**：首屏"什么都没有"时给 `empty-state` 卡，标题 + 说明 + **两个按钮**（"添加设备" fire `home_panel: add_integration`、"编辑区域" 跳 `/config/areas/dashboard`），且只在管理员且 `home_panel` 场景才挂按钮；告警已激活时用一个 `conditional` 卡**把空状态换掉**（有事就不教育用户）。【源码】`home-assistant/frontend:src/panels/lovelace/strategies/home/home-overview-view-strategy.ts:635-700`
- **Apple**：目录把 `Set up rooms` 放在 `Add accessories` **之前**（先建房间，加配件时才有地方放），并且 `Add rooms / Arrange rooms / Group rooms` 三个独立主题。【文档】Apple `welcome` 页目录
- **我们**：引导是**两层**的——首次全屏 `OnboardingGuideView`（4 条路由 `choosePlatform / connectMi / connectHA / connectedSummary`，`Advanced` 折叠，`Sources/MenuBarMijiaApp/OnboardingGuideView.swift:6-11,52-79`）+ 面板内一行 44pt 的 `OnboardingChecklistCard`（3 步 `connectAccount / searchDevice / allOffAndUndo`，带「试试」按钮和「×」，`Sources/MijiaCore/OnboardingChecklist.swift:3-7`、`Sources/MenuBarMijiaApp/OnboardingChecklistCard.swift:9-60`）。

这套"全屏一次 + 常驻一行 + 用真实动作判定完成"的组合，比 HA 的空状态卡更强，**不需要重做**。缺的是"何时停止"与"下一步教什么"：

- `OnboardingStep` 只有 3 步，且 `connectAccount` 直接读连接状态（这本该如此）。但**"撤销"能力**（我们最独特的功能）没有被引导覆盖——虽然 `OnboardingMilestone` 里有 `undidAllOff` / `rehearsedAllOff`，`OnboardingStep` 却没有对应 step。【源码】`Sources/MijiaCore/OnboardingChecklist.swift:3-17`
- 没有"引导分层"：新手和有 40 台设备的老用户看到同一行。

---

## 5. 对照我们：差距表

> 现状列的行号均指向本仓当前 worktree；成本 S ≤ 0.5 天、M ≤ 2 天、L > 2 天（含评审与回归）。

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `ControlCenterPanel.swift:494-580` | 滚动顺序：活动栈 → 新手行 → 收藏/分组/房间栈 → 长尾条 → 离线抽屉 | HA：收藏 → 摘要 → 区域；摘要是一整行可点卡片（灯/温控/安防/影音/能耗） | 在活动栈之后、收藏之前插一行**"我家现在"摘要胶囊**（2–4 个），数据来自现成 `activeDeviceCount` 与分域计数 | M |
| `PanelHeaderState.swift:21-34` | 头部只有 `N 台开启` / `全屋待机` + 一条环境读数（`ViewThatFits` 降级） | HA 摘要 8 类常量顺序 + 固定图标色；Apple 首屏 = 收藏 | 保持 `ViewThatFits` 降级链，把候选文案从"数字"扩成"数字 + 最需要的一条分域事实（如 `2 盏灯亮`）" | S |
| `windows/src/ui/app.ts:1778-1791` | Windows 头部是 `X 台开启中 · 共 Y 台在线`，比 macOS 多"在线总数" | 双端应一致 | 统一两端口径（要么都带在线数，要么都不带）；顺手把摘要胶囊两端同构 | S |
| `DeviceLayout.swift:135-140` | `.auto` 只区分 `compactGrid ? .half : .full`，唯一例外是 `climate` + 面板开启 → `.full` | HA `computeFavoriteCardSize`：摄像头占 2 槽；区域页按能力阶梯选控件 | 给 `.auto` 加**内在尺寸表**：摄像头 → `.hero`；纯读数传感器（温湿/门窗磁）→ 一行紧凑；插座/开关 → `.small` | S–M |
| `PanelSplitTileShared.swift:338,424-455` | `initialOverviewLimit = 8` 按**台数**截断，`keepingVisibleIds` 保证被聚焦设备不消失 | HA 按**槽位宽度**记账（pin 永不挤掉、预测填空槽、装不下跳过而非截断） | 预算从"台数"改为"槽位"：`small=1`、`half/hero=2`、`full=4`；pin 先占位，习惯填剩余，装不下就试下一台 | M |
| `windows/src/ui/panelSplitTiles.ts:25` | Windows 镜像同一常量 `INITIAL_ALL_OVERVIEW_LIMIT = 8` 与同一 `auto` 解析规则（`panelPrefs.ts:468`） | — | 改预算/尺寸属**跨端契约变更**，须两端同步 + 走 PR | M |
| `ControlCenterPanelStacks.swift:186-330` | 分组顺序：收藏 → 自定义组 → 房间/类型栈；房间内按 习惯 → 活跃 → 快照序 | HA 区域页 7 个固定语义组 + 组内固定顺序 + 空组不渲染 | 保留"房间优先"的外部结构，在**房间/类型栈内部**引入 7 组语义分组（灯 / 温控 / 遮阳 / 影音 / 安防 / 场景动作 / 其他） | M |
| `ControlCenterPanelLayout.swift:651-659` | `gridSpan`：`small=3`、`half/hero=6`、`full/panel/auto=12`（12 列，面板宽 376pt，`MenuBarPanelController.swift:44`） | HA `max_columns: 3`；Apple 自适应用户拖动重排 | 布局本身够用；**不要**追 HA 的 3 列，376pt 下三列只够 82pt 圆钮——这与 `small=3/12` 已经一致 | — |
| `ControlCenterPanelStacks.swift:300-355` | 单设备栈超过 8 张卡折叠成长尾条（"展开其余 N 台"） | HA 用独立"其它设备"子视图 + `hasOtherDevices` 判定后才出入口 | 把"长尾条 + 按房间找"升级为**独立二级页**（现在靠 `PanelLongTailBar` 的菜单）；或至少给长尾条加分组摘要 | M |
| `ActivityStackView.swift:8-72` | 面板三层：urgent pinned / pinned / ordinary（折叠胶囊） | HA：安全告警两级（alert/warning）+ 系统健康三卡；Apple：同类聚合 | 引入显式 `PanelAlertSeverity { alert, warning }`，由 `SensorAlertKind` 推断（漏/烟/气 = alert；门窗/人体 = warning），驱动颜色与文案 | S |
| `HotkeyAndNotificationManager.swift:769-847` | 四个投递点均未设 `interruptionLevel` / `relevanceScore` / `threadIdentifier` | Apple 4 档 + relevance；HA iOS 端完整映射 | 按 §3.4 表逐类设置；`threadIdentifier` 按家庭分组 | S |
| `MacContextObserver.swift:266-272` | 专注状态只喂自动化 | Apple 明确"临时关闭或只收关键告警走专注模式" | 专注中把非关键通知降为 `.passive`（面板内不变），关键类（`honorsAwayLimit == false`）不受影响 | S |
| `EnergySettingsSection.swift:11-40` | 能耗**只在设置页**：今日/7 日/设备排名/电价/清除，保留 31 天，数据来自插座真实累计电量 | HA 能耗是**一级仪表盘**（来源/设备两层模型 + 卡片目录 + 3 列 + 日期选择器）；Apple 是账户级 + 明示 24–72h 延迟 | 面板内加一张"今日用电"卡（今日 kWh + 环比 + 点开进设置页）；数据模型不动 | M |
| `Sources/MijiaCore/EnergyHistory.swift` | 单一口径（插座累计电量增量），无"已计入总表"去重标记 | HA `included_in_stat` 防重复计入 | 若将来接 HA 能源实体，须先加去重标记，否则总表 + 分项会双算 | S（现在做）/ L（接 HA 后） |
| `UnsupportedDeviceScanner.swift:40` + `SettingsWindowView.swift:2833` | "未显示设备"只在设置里可见 | HA `discovered-devices / repairs / updates` 三卡在首屏、`hide_empty`、仅管理员 | 面板加**一行**`N 台设备未能显示 · 查看`，点开进设置对应锚点（`SettingsSearch` 已有锚点机制） | S |
| `OnboardingChecklist.swift:3-7` | 3 步（连接 / 搜索 / 全关撤销） | HA 空状态带两个直接动作按钮；Apple 先建房间再加配件 | 保留结构，新增第 4 步"按房间找设备"（`browseByRoomTitle` 文案已存在），并让 `rehearsedAllOff` 真正挂到一个 step 上 | S |
| `RoomOrderEditor.swift`（全文件） | 房间可排序、可改名（alias）、可切到类型序；没有"隐藏房间" | HA `areas_display.hidden`；Apple 可 `Arrange rooms` | 加"隐藏房间"（隐藏只影响面板分组，不影响设备可见性） | M |
| `docs/platform-matrix.zh-CN.md` | 双端能力表详尽 | — | 摘要条 / 能耗卡 / 通知分级落地后需同步该表 | S |

---

## 6. 推进清单

> 「高风险面」指 `AGENTS.md` 列的 5 类（凭据与传输 / 设备写入与安全策略 / 数据迁移与去重 / 自动更新与签名 / 跨平台契约与打包链）。命中即须走 PR，不直接推 `main`。

### P0

**P0-1 通知分级：接上 `interruptionLevel` + `relevanceScore`**
- 价值：烟感告警与"错过的定时"现在完全同档；这是安全语义缺口，不是美化。
- 成本：S。单文件 `HotkeyAndNotificationManager.swift` 四个投递点 + 一个 `severity → level` 纯函数（放进 `MijiaCore` 便于测试）。
- 高风险面：**是**（安全策略：改的是告警强度语义，与 `SensorAlertKind.honorsAwayLimit` 绑定）。→ PR。
- 依据：§3.1–3.4；`UNNotificationContent.h:20-33`；`LocalPushEvent.swift:201-215`；`HotkeyAndNotificationManager.swift:769-847`。

**P0-2 专注模式抑制非关键通知**
- 价值：信号已经免费拿到（`INFocusStatusCenter`），却被闲置；这是"勿扰"的完整答案，不必自建免打扰日程。
- 成本：S。`MacContextObserver` 已发布 `isFocusActive`，投递前读一次即可。
- 高风险面：**是**（安全策略：忘了把漏/烟/气排除就会压低真实告警）。→ PR，且必须带"关键类必须仍发"的测试。
- 依据：`MacContextObserver.swift:32-33,266-272`；Apple `set-notifications` 页；`Models.swift:487-492`。

**P0-3 `.auto` 尺寸引入设备内在尺寸**
- 价值：现在摄像头、温湿度计、插座全都一样宽；摄像头缩在 6 列里只能看缩略图，温湿度计却占半行空白。
- 成本：S–M。改 `DeviceLayoutPrefs.resolved`，加一张 `DeviceKind → TileSize` 表 + 单元测试。
- 高风险面：**是**（跨端契约：`windows/src/ui/panelPrefs.ts:465-470` 有同一 `auto` 规则）。→ PR，两端同改。
- 依据：`DeviceLayout.swift:135-140`；`favorite-cards.ts:11-13`；`areas-strategy-helper.ts:344-352`。

**P0-4 面板内暴露"未能显示的设备"一行**
- 价值：现在用户只会在"怎么少了几台"时去翻设置；HA 把它当首屏管理员通知。
- 成本：S。复用 `UnsupportedDeviceScanner` + `SettingsSearch` 锚点。
- 高风险面：否。
- 依据：`home-overview-view-strategy.ts:505-530`；`UnsupportedDeviceScanner.swift:40`；`SettingsWindowView.swift:2833`。

### P1

**P1-1 首屏"我家现在"摘要行**
- 价值：补上从"系统提醒"到"单台设备"之间缺失的中间层；也是 Windows 头部信息的结构化升级。
- 成本：M。新的 `HomeSummaryStrip`（2–4 个胶囊，点击=筛选到该组），数据全部来自现成 `activeDeviceCount` + `kindChips` 计数。
- 高风险面：否（只要不改 `allOffTargets`）。
- 依据：§1.3；`home-summaries.ts:8-40`；`PanelHeaderState.swift:21-34`；`windows/src/ui/app.ts:1778-1791`。

**P1-2 槽位预算模型（pin 永在 / 习惯填槽 / 按尺寸记账）**
- 价值：现在 8 台的上限会被一张 2×2 摄像头"吃掉半屏"，而第 9 台明明放得下；pin 与预测会互相挤。
- 成本：M。`overviewSlice` 换成按 span 记账，`windows/src/ui/panelSplitTiles.ts:440-471` 同步。
- 高风险面：**是**（跨端契约）。→ PR。
- 依据：§1.4；`PanelSplitTileShared.swift:338,424-455`；`common-controls-section-strategy.ts:26-38,113-118`。

**P1-3 房间/类型栈内部 7 组语义分组**
- 价值：一个房间 20 台设备现在按"习惯 + 活跃"排，用户找不到"那个灯"；HA 用固定语义组让位置可预测。
- 成本：M。改 `appendOnlineGroupAndCategoryStacks`（`ControlCenterPanelStacks.swift:262-330`），复用 `DeviceKindTag` 到 7 组的映射。
- 高风险面：否。
- 依据：§1.2；`areas-strategy-helper.ts:21-39`、`area-view-strategy.ts:100-200`。

**P1-4 组标题 = 批量开关（动词随状态翻转）**
- 价值：把"全关"从全局按钮下沉到每组/每房间，并让动词自己说明后果（"关掉客厅 3 盏灯"）。
- 成本：M（要接 `allOffTargets` 既有作用域规则）。
- 高风险面：**是**（设备写入与安全策略：`allOffTargets`、二次确认、锁屏拦截）。→ PR。
- 依据：`home-area-view-strategy.ts:120-190`。

**P1-5 显式告警严重度两级**
- 价值：面板颜色/排序/通知档现在各自推断，统一成 `alert/warning` 一维后三处共用一张表，减少不一致。
- 成本：S–M。
- 高风险面：**是**（安全策略）。
- 依据：§1.5；`security-alerts.ts:15-51`；`alert_active.ts:6-19`。

**P1-6 面板内"今日用电"卡**
- 价值：能耗现在埋在 设置 → 通用 → 插座用电统计；Apple 与 HA 都把它当一级信息。
- 成本：M（只读展示，不动 `EnergyHistory` 账本）。
- 高风险面：否。
- 依据：§1.6；`EnergySettingsSection.swift:11-40`；Apple `view-electricity-usage-and-rates` 页。

### P2

**P2-1 房间可隐藏**（HA `areas_display.hidden`）——影响面板分组但不影响设备可见性；M。
**P2-2 布局密度预设**（紧凑/标准/舒展，一次性写整张 size map）——与已有 `PanelHeight` 四档呼应；M。
**P2-3 房间内"场景"组**（HA 每个区域页都有 scenes 段；我们场景只在输入框快捷栏）——M。
**P2-4 引导第 4 步"按房间找设备" + 撤销专门一课**——S（`browseByRoomTitle` 文案已存在）。
**P2-5 长尾"展开其余 N 台"升级为独立二级页**（HA `home-other-devices` 子视图）——M。

### P3

**P3-1 安全中心页**（门锁/门磁/水浸/烟感/燃气/摄像头 + 24h 活动 + 30 天）——L，需要后端事件流与留存策略。
**P3-2 布局策略化**：把 `deviceStacks` 与尺寸解析收敛成一个纯函数 `PanelLayoutStrategy(input) -> [Section]`，带 `shouldRegenerate` 式的"什么变了才重算"边界——为将来的多套布局（工作 / 客厅平板 / 客人模式）铺路。L。与 ADR-0023 不冲突。
**P3-3 能耗接 HA 能源实体**（`recorder/get_statistics`）——L，且必须先有 `included_in_stat` 类去重标记，否则双算。命中"数据迁移/跨源去重"高风险面。

---

## 7. 设想（不受现有 ADR 约束，注明冲突）

1. **菜单栏摘要**：状态栏图标旁可选显示 `2`（开启台数）或一个小圆点按严重度变色。我们已经在 `SensorAlertKind.colorsMenuBar` 里区分了"能不能改菜单栏颜色"，但只用于告警；可以扩展成"菜单栏摘要密度"三档。无 ADR 冲突，但需要新的偏好项。
2. **"撤销"作为一等公民**：Apple 的 8 秒瓷砖撤销是**逐次操作内联**的；我们的撤销是"全关后 10–15 秒横幅"。可以把 `UndoAvailabilityTracker` 的窗口做成**任何单设备写入都可撤销**（不只是全关），并在卡片上放一个短暂的"↺"角标。与 ADR 无冲突，但会扩大撤销栈的语义范围，需重新审 `ScheduledCommand` 作用域。
3. **"演练模式"**：`OnboardingMilestone.rehearsedAllOff` 已存在但没入口。做成"关一次虚拟的家"，零真实指令，专门教撤销。与 ADR-0015（本地优先/隐私）一致。
4. **布局即文件**：把 `PanelLayoutStore` 的 order/sizes/groupMap 三个 JSON 合成一份带 version 的 `layout.json`，可导入导出、可出现在备份里。**冲突提示**：属"数据迁移"，必须按 AGENTS.md 第 3 类走 PR + 迁移测试。
5. **按情境切换布局**：读 Apple 的 `Grid Forecast`/`electricity rates` 思路——情境（电价高峰/离家/专注）不只是触发自动化，还可以**改变首屏排序**（电价高峰时把能耗卡提到第一位）。这是"策略化布局"（P3-2）的下游应用；当前 ADR 未覆盖，不冲突。
6. **通知的"家庭频道"**：用 `threadIdentifier` 把同一家庭的告警串成一组，并在面板活动栈里显示"今天 3 条安全、2 条回执"的日汇总——HA 用 `logbook` 卡 + `hours_to_show: 24` 表达同一件事。【源码】`security-view-strategy.ts:356-380`。

---

## 8. 来源清单

**源码（浅克隆，只读）**

| 引用 | 位置 |
| --- | --- |
| HA 策略注册与重生成 | `home-assistant/frontend:src/panels/lovelace/strategies/get-strategy.ts:31-58,190-230,291-322,347-380` |
| HA home 首屏顺序 | `…/strategies/home/home-overview-view-strategy.ts:63-84,117-135,162,236-283,294-320,352-420,505-530,560-625,635-700,700-740` |
| HA home dashboard 组装 | `…/strategies/home/home-dashboard-strategy.ts:104-133` |
| HA 摘要常量 | `…/strategies/home/helpers/home-summaries.ts:8-40` |
| HA 其它设备过滤 | `…/strategies/home/helpers/other-devices-filters.ts:4-30` |
| HA 区域 7 组 | `…/strategies/areas/helpers/areas-strategy-helper.ts:21-39,63-268,332-400,415-437` |
| HA 区域页顺序 | `…/strategies/areas/area-view-strategy.ts:24-30,100-200` |
| HA 区域概览 | `…/strategies/areas/areas-overview-view-strategy.ts`（全文件 182 行） |
| HA areas dashboard | `…/strategies/areas/areas-dashboard-strategy.ts:53-104` |
| HA 槽位预算 | `…/strategies/usage_prediction/common-controls-section-strategy.ts:26-38,113-140` |
| HA 卡片尺寸 | `…/strategies/helpers/favorite-cards.ts:11-40` |
| HA 区域页批量开关 | `…/strategies/home/home-area-view-strategy.ts:120-200,267-280` |
| HA 设备 section 类目 | `…/strategies/device/device-section-strategy.ts:34-52` |
| HA 响应式条件 | `…/strategies/helpers/view-columns-conditions.ts:4-11` |
| HA 告警激活状态 | `src/common/entity/alert_active.ts:6-19` |
| HA 告警严重度 | `src/panels/security/strategies/security-alerts.ts:15-51,95-111`；`src/data/frontend.ts:47-52` |
| HA 安全页 | `src/panels/security/strategies/security-view-strategy.ts:36-100,306-380` |
| HA 能耗数据模型 | `src/data/energy.ts:52-150` |
| HA 能耗卡片目录 | `src/panels/energy/strategies/energy-cards.ts:19-60,340-352` |
| HA 能耗概览顺序 | `src/panels/energy/strategies/energy-overview-view-strategy.ts:27-140` |
| HA 手势参数 | `src/common/util/swipe-gesture-recognizer.ts:13-14`；`src/components/ha-bottom-sheet.ts:312-336` |
| HA iOS 通知映射 | `home-assistant/iOS:Sources/Shared/Notifications/LocalPush/LocalPushEvent.swift:95-113,201-215` |
| Mushroom 色板 / 更新扇出 | `piitaya__lovelace-mushroom:src/utils/colors.ts:4-46`；`src/cards/chips-card/chips-card.ts:66-78,131` |
| Bubble 手势常量 | `Clooos__Bubble-Card:src/cards/pop-up/slide-to-close.js:1-100` |
| button-card 订阅粒度 | `custom-cards__button-card:src/button-card.ts:189,273-274,422-424,477-519` |
| Minimalist 版本线 | `UI-Lovelace-Minimalist__UI:CHANGELOG.md:1-3`；`custom_cards/` |
| Dwains 停更公告 | `dwainscheeren__dwains-lovelace-dashboard:README.md:5-19` |

**本仓（现状基线）**

`Sources/MenuBarMijiaApp/ControlCenterPanel.swift:70,360-452,494-580,616-733`、`ControlCenterPanelChrome.swift:84-130,341-363,755-770`、`ControlCenterPanelLayout.swift:600-700`、`ControlCenterPanelStacks.swift:186-355`、`PanelSplitTileShared.swift:337-455`、`DeviceLayout.swift:1-200`、`PanelLayoutStore.swift`（全文件）、`RoomOrderEditor.swift:7-50`、`ActivityStackView.swift:8-330`、`PanelHeaderState.swift:5-55`、`HotkeyAndNotificationManager.swift:630-660,769-847`、`MacContextObserver.swift:32-33,266-272`、`OnboardingGuideView.swift:6-79`、`OnboardingChecklistCard.swift:9-60`、`EnergySettingsSection.swift:11-90`、`UnsupportedDeviceScanner.swift:40`、`MenuBarPanelController.swift:44-53`、`DesignTokens.swift:5-16,108-114`；`Sources/MijiaCore/Models.swift:456-500`、`OnboardingChecklist.swift:3-17`、`MacContextAutomation.swift:162-167`、`HomeStore+Metrics.swift:5-12,133-150`、`EnergyHistory.swift`；Windows：`windows/src/ui/panelView.ts:60-140`、`windows/src/ui/app.ts:1770-1800`、`windows/src/ui/panelSplitTiles.ts:25,197-240,440-471`、`windows/src/ui/panelPrefs.ts:78-93,465-470`。

**文档（访问 2026-11-23）**

- `https://www.home-assistant.io/dashboards/`（站点版本 2026.11.2）
- `https://www.home-assistant.io/dashboards/sidebar/`
- Apple《Home User Guide》(macOS 27)：`https://support.apple.com/en-us/guide/home/welcome/mac`、`…/home-screen-hme725726702/mac`、`…/set-notifications-hme25d1d9fd9/mac`、`…/activity-history-hme415fb4f77/mac`、`…/view-electricity-usage-and-rates-hmef4ecff6d2/mac`
- `https://support.google.com/googlenest/?hl=en`（帮助中心导航）
- 本地 SDK：`MacOSX27.2.sdk/System/Library/Frameworks/UserNotifications.framework/Headers/UNNotificationContent.h:20-33,81-84`、`UNNotificationSound.h:1-45`、`UNNotificationSettings.h:74`

**未查到（明确失败）**

- 米家 App、Aqara Home、SmartThings、涂鸦智能生活 的界面信息架构一手资料（页面 JS 渲染 / 403 / 无内容）；Google Home 新版卡片与 Gemini 的官方结构说明（搜索引擎被反爬拦截，未取到一手页）。
- `com.apple.developer.usernotifications.critical-alerts` entitlement 的官方文档（本机 Xcode 未找到该字符串），故 Critical Alerts 可达性只作【推断】。

---

## 摘要

1. **通知要分级**（P0）：全仓没设过 `interruptionLevel`，烟感和"错过的定时"同档响起；按 §3.4 那张表分四类改，顺手用已经拿到的系统专注状态压非关键通知。
2. **首屏缺中间层**（P1）：从"系统提醒"直接跳单台设备；补一行 2–4 个"我家现在"摘要胶囊，数据全是现成计数。
3. **固定位 + 按尺寸记账的槽位预算**（P1）：把 `initialOverviewLimit = 8` 从"台数"改成"槽位宽度"，pin 永在、习惯填槽——注意 Windows 有镜像常量，属跨端契约须走 PR。

报告：`docs/research/2026-11-23-deep-dive/16-dashboards-and-vendor-app-ux.md`
