[English](README.md) | 简体中文

<p align="center">
  <a href="https://trendshift.io/repositories/309141?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-309141" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/309141/daily?language=Swift" alt="jryang2026-code%2FMenuBarHome | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/309141?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-309141" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/309141/weekly?language=Swift" alt="jryang2026-code%2FMenuBarHome | Trendshift" width="250" height="55"/></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/logo-light.svg">
    <img src="docs/assets/logo.svg" width="120" alt="MenuBarHome Logo">
  </picture>
</p>

<h1 align="center">MenuBarHome</h1>

<p align="center">
  <b>不用掏手机，在电脑上就能管好整个家。</b><br>
  住在 Mac 菜单栏里的米家控制中心，也有 Windows 11 托盘版。<br>
  用米家 App 扫一下码就能连上，不必先搭 Home Assistant。
</p>

<p align="center">
  <a href="https://github.com/jryang2026-code/MenuBarHome/stargazers"><img src="https://img.shields.io/github/stars/jryang2026-code/MenuBarHome?style=social" alt="GitHub Stars"></a>
  <a href="https://github.com/jryang2026-code/MenuBarHome/releases/latest"><img src="https://img.shields.io/github/v/release/jryang2026-code/MenuBarHome?color=0A84FF&label=release" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Windows_11-Tauri_v2-0078D4?logo=windows11&logoColor=white" alt="Windows 11">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
</p>

<p align="center">
  <a href="https://github.com/jryang2026-code/MenuBarHome/releases/latest"><b>下载最新版本</b></a> ·
  <a href="#快速开始">安装与连接</a> ·
  <a href="#功能概览与双端对照">双端能力对照</a> ·
  <a href="#安全隐私与限制">安全与隐私</a> ·
  <a href="CHANGELOG.md">更新日志</a>
</p>

<p align="center">
  <img src="docs/assets/readme-v3/keyboard-search.gif" alt="macOS 演示：按 ⌥M 呼出面板，输入 sftd 找到书房台灯，回车开灯" width="420">
</p>

<p align="center"><sub>按 <code>⌥M</code> 呼出面板，敲 <code>sftd</code>（书房台灯的拼音首字母），回车开灯。画面来自 macOS 演示模式，设备均为虚拟。</sub></p>

> [!NOTE]
> **改名与搬家：** 从 1.2.0 起，MenuBarMijia 改名为 MenuBarHome，仓库迁到 [github.com/jryang2026-code/MenuBarHome](https://github.com/jryang2026-code/MenuBarHome)。1.1.7 及更早版本收不到这次更新，请手动下载安装一次；登录和设置都会保留，装好后删掉旧的 `MenuBarMijia` 即可（Windows 请先卸载旧版）。

> [!IMPORTANT]
> **非小米官方产品，与小米无关联。** MenuBarHome 是独立开源项目，并非小米或米家官方客户端，与小米科技有限责任公司及其关联公司不存在隶属、合作、赞助或背书关系。「小米」「米家」「Xiaomi」「Mijia」「Mi Home」是小米科技有限责任公司及其关联公司的商标。本项目仅在说明与小米 / 米家设备的兼容性时使用这些名称，不暗示任何背书或认可。

---

## 为什么值得装一个

写代码、改稿子、开会的时候，想关个灯还得解锁手机、找 App、翻房间。MenuBarHome 把这件事缩短成一个快捷键。

- **扫码就能用。** 在设置里点「米家云端直连」，用手机米家 App 扫一下屏幕上的二维码，家里所有房间和设备就同步过来了。不用装 Home Assistant，不用抓 token。已经在用 Home Assistant 的，也能直接连。
- **手不离开键盘。** `⌥M` 呼出面板，直接打字找设备，名字、房间、拼音首字母都认。回车开关，方向键调亮度、调温度。
- **按住说话，松手就办。** 没有唤醒词，也不用等它回话。开关、调光、调温、定时这些常用说法在本机就能听懂，不填 AI Key 也能用。
- **关错了能撤销。** 「全关」默认放过插座、扫地机和摄像机；关完之后点一下「撤销」，刚才亮着的灯原样回来。
- **跟着你的 Mac 走。** 锁屏自动关灯，接上外接显示器打开台灯，日历里的会议快开始了就把灯调好。规则默认全关，开哪条由你决定。
- **原生、安静。** macOS 版用 Swift 写成，不带浏览器内核；面板开着不操作时 CPU 占用约 0.1%。

---

## 1.2.0：从里到外重新做了一遍

### 新的面板

搜索框放到了最上面，找设备和说一句话都在这里。常用设备排成磁贴，空调可以直接在卡片上加减温度，房间切换、排序和紧凑视图都在手边。浅色、深色跟随系统；在 macOS 26 及更新的系统上，还可以换成「液态玻璃」主题。

<p align="center">
  <img src="docs/assets/readme-v3/panel-themes.gif" alt="macOS 面板的常规与液态玻璃两种主题，分别在浅色和深色下的样子" width="900">
</p>

### 偏好设置换成了「系统设置」的样子

左侧分类、彩色图标、分组卡片，用起来和 Mac 自带的「系统设置」一样顺手。顶部的搜索框认中英文关键词和同义词，选中结果会直接跳过去，并把那一项高亮出来。

<p align="center">
  <img src="docs/assets/readme-v3/settings.gif" alt="macOS 偏好设置：在家居连接、外观、隐私与诊断之间切换，再搜索 dark 直接跳到外观模式设置" width="900">
</p>

### 按住说话

按住 `⌥M` 或菜单栏图标开口说，说完松手。听到的话会实时出现在搜索框里，松手立刻执行。常用指令在本机解析，几乎没有等待；说法复杂一些的，可以交给你自己配置的 AI 服务。

<p align="center">
  <img src="docs/assets/readme-v3/hold-to-talk.gif" alt="macOS 演示：按住 ⌥M 说「把客厅灯调到百分之四十」，松手后客厅吸顶灯调到 40%" width="900">
</p>

### 一键全关，随时撤销

出门或睡前，按住「全关」0.6 秒，当前视图里亮着的设备一起关掉。插座、扫地机和摄像机默认不参与，可以在设置里改。关完会出现「撤销」，点一下就回到关之前的样子。

<p align="center">
  <img src="docs/assets/readme-v3/all-off-undo.gif" alt="macOS 演示：按住全关关掉 3 台设备，插座保持开启，再点撤销全部恢复" width="420">
</p>

### Windows 11 也换了新衣服

托盘版按 Windows 11 的 Fluent 2 风格重新设计成上下两座「浮岛」：上面是家庭状态、猜你想控和摄像机速览，下面是搜索、快捷动作和设备磁贴。键盘搜索、`Alt+M` 呼出、深浅色都有。

<p align="center">
  <img src="docs/assets/readme-v3/windows-fluent.png" alt="Windows 11 托盘版的浅色与深色面板" width="820">
</p>

---

## 还能做什么

- **能认的设备很多。** 灯、空调、风扇、插座、电视、窗帘、晾衣架、净化器、加湿器、冰箱、热水器、洗烘设备、浴霸、油烟机、扫地机、摄像机、门锁和各类传感器；没有专属卡片的米家设备，也会有一张通用卡。
- **摄像机小窗。** 点开卡片弹出置顶的实时画面，双摄机型可以切镜头，带云台的直接拖动画面转方向。
- **温湿度曲线和用电账本。** 传感器能看 24 小时 / 7 天趋势，插座按天记用电量，填上电价还能估算电费。
- **猜你想控。** 根据你平时什么时候开什么，把可能要做的操作提前摆出来。习惯只记在本机，随时可以查看和清空。
- **多账号、双数据源。** 可以同时登录多个米家账号，也可以让米家和 Home Assistant 一起工作，同一台设备会自动合并。
- **安全提醒和家庭周报。** 大功率电器开太久、常用设备突然掉线，都会弹通知提醒；每周还能生成一份家庭健康周报，看看哪些设备总掉线、哪些插座在偷偷耗电。
- **接进你的工具。** 支持 Apple 快捷指令、`menumijia://` 链接、Raycast 扩展、命令行和 MCP 服务，Claude、Cursor 这类 AI 工具也能查询和控制家里的设备，全程拿不到你的账号凭据。

两端各支持哪些能力，见下方的[双端能力对照](#功能概览与双端对照)。

---

## 快速开始

### 1. 安装

- **macOS：** macOS 14 (Sonoma) 及以上，Apple Silicon 与 Intel 通用。
- **Windows：** Windows 11（64 位）。

**macOS · Homebrew**

```bash
brew tap jryang2026-code/tap
brew trust --cask jryang2026-code/tap/menubarhome
brew install --cask jryang2026-code/tap/menubarhome
```

**macOS · 下载 DMG**

从 [GitHub Releases](https://github.com/jryang2026-code/MenuBarHome/releases/latest) 下载最新的 DMG，把 `MenuBarHome.app` 拖进「应用程序」。

> 本项目没有加入付费的 Apple 开发者计划，安装包未经公证。第一次打开如果被拦下，到 **「系统设置 → 隐私与安全性」** 页面底部点 **「仍要打开」** 就好。

**Windows 11**

从 [GitHub Releases](https://github.com/jryang2026-code/MenuBarHome/releases/latest) 下载 `.exe` 或 `.msi` 安装包。

> 安装包没有商业代码签名证书。如果弹出「Windows 已保护你的电脑」，点 **「更多信息」→「仍要运行」**。每个版本的 SHA-256 都公布在 Releases 页面，可以自行核对。

### 2. 连接你的家

点菜单栏（或托盘）图标打开面板，进入设置 `⚙️`，三种方式任选：

- **米家云端直连（推荐）：** 选「米家云端直连」，用手机米家 App 扫屏幕上的二维码，确认后全屋的家庭、房间和设备自动同步。支持中国大陆、新加坡、德国、美国、俄罗斯服务器；macOS 上可以「添加账号」，把多个小米账号的设备合到一个面板里。登录快过期时会提前 3 天提醒，在面板里重新扫一次码就能续上。
- **Home Assistant：** 填上实例地址（如 `http://192.168.1.100:8123`，也支持反向代理子路径）和长期访问令牌即可；macOS 还能自动发现局域网里的 Home Assistant。令牌存进 macOS 钥匙串或 Windows 凭据管理器。<br>
  macOS 如果提示「局域网连接被系统拦截」，到 **「系统设置 → 隐私与安全性 → 本地网络」** 里允许 MenuBarHome。
- **演示模式：** 不登录任何账号，用一套虚拟设备先把界面玩一遍。

---

## 常用操作与口令参考

### 键盘快捷操作

macOS 默认按 `⌥M` 呼出面板，Windows 默认按 `Alt+M`。打字盲搜、`↑`/`↓` 选择、`Return`/`Space` 开关或展开、`→`/`←` 调节参数与 `Esc` 返回双端通用；`Tab` 轮转房间标签适用于 macOS。

| 按键 | 功能 |
| :--- | :--- |
| `⌥M` / `Alt+M` | 全局呼出 / 收起控制面板（macOS / Windows） |
| 直接输入字母 | 搜索设备名称、房间或拼音首字母（如 `sftd` 匹配书房台灯） |
| `↑` / `↓` | 在搜索结果或设备卡片列表中切换光标 |
| `Return` / `Space` | 开关当前选中的设备；对不可直接开关的设备展开详情控制抽屉 |
| `→` / `←` | 右方向键展开详情；展开后用左右方向键调节灯光亮度、空调温度、窗帘位置或音量（Windows 另可调风速） |
| `Tab` | 在不同房间标签之间快速轮转切换（macOS） |
| `Esc` | 退出搜索输入、收起控制抽屉，或关闭面板 |

### 本地支持的常用自然语言口令

以下口令由本机规则引擎直接解析执行，**不需要配置云端 AI**，不消耗 API Token：

- **开关设备：** 「关客厅灯」「打开书房空调」「turn off all lights」
- **调节情景模式：** 「书房吸顶灯月光模式」「日光模式」「daylight mode」
- **微调亮度与色温：** 「再暗一点」「主卧灯调到 40%」「brighter」
- **温度与风速控制：** 「空调调到 26 度」「调高两度」「风扇开自然风」
- **延时定时执行：** 「10 分钟后关灯」「半小时后关空调」「取消定时」
- **撤销误操作：** 「撤销」「刚才那个撤销」（10 分钟内支持语音或快捷撤销）

---

## 功能概览与双端对照

MenuBarHome 的 macOS 版本采用 Swift 6 原生开发，Windows 11 版本基于 Tauri v2 / TypeScript 独立实现。两端均经过共享测试集（`Tests/Fixtures/`）断言基础协议的一致性，但系统级能力存在平台差异。

<details>
<summary><b>展开完整对照表</b></summary>

| 功能维度 | macOS 原生版 (14+) | Windows 11 托盘版 | 说明 |
| :--- | :---: | :---: | :--- |
| **米家云端扫码直连** | ✅ 支持 | ✅ 支持 | 手机米家 App 扫码登录，支持中/欧/美/俄/新加坡多区域服务器；同时加载自有家庭与被分享给该账号的家庭 |
| **Home Assistant 接入** | ✅ 支持 | ✅ 支持 | macOS 保持长连接 WebSocket 实时事件流并支持局域网 mDNS 发现；Windows 按刷新与控制请求建立 WebSocket 会话。双端均支持官方 `xiaomi_home` 物理设备聚合 |
| **键盘搜索与设备控制** | ✅ 支持 | ✅ 支持 | 按设备名、房间或拼音首字母（如 `sftd`）搜索；方向键选择与调节，回车切换设备或执行口令 |
| **全局快捷键呼出** | ✅ `⌥M`（支持自定义） | ✅ `Alt+M`（支持自定义） | 1.1.4 Windows 版已补齐自定义热键录制与占用冲突检测 |
| **语音控制方式** | ✅ 菜单栏按住 / 快捷键按住 / 免提 | ⚠️ 仅免提听写 | macOS 支持系统原生听写与按住说话；Windows 使用 WebView 听写 |
| **本地口令解析** | ✅ 支持 | ✅ 支持 | 开关、调光、调温、风速、延时等常规口令双端均在本地解析 |
| **自选 AI 决策助手** | ✅ 支持 | ✅ 支持 | 可接入 Jev、DeepSeek、千问、GLM、Ollama 或自定义端点，API Key 按服务商独立分槽保存；macOS 另提供「不确定时先问我」开关与高级阈值调节 |
| **「猜你想控」主动推荐** | ✅ 最多 4 项 | ✅ 最多 4 项 | 手动点卡片也按时段与工作日/周末计入习惯记忆，带 14 天半衰期衰减与动作序列预测（撤销同步回滚，详见 [ADR-0009](docs/adr/0009-habit-ranking-algorithm.md)）；本地推荐立即显示，大模型在后台刷新。可执行动作不足四项时显示实际数量。 |
| **GrokBall 情绪球与侧边推荐** | ✅ 原生 Canvas | — 暂不支持 | macOS 下轻点小球展开最多四项可撤销设备推荐，支持自由拖动与长按 0.5 秒进入语音输入，默认黑球白眼跟随光标（减弱动态效果下静态显示），基于 [TyCoding/grok-ball](https://github.com/TyCoding/grok-ball)（MIT）；Windows 端推荐统一收纳在顶部通知岛中。 |
| **顶部快捷动作与场景栏** | ✅ 3 个动作 | ✅ 3 个动作 | macOS 通过设置里的「输入框里显示快捷场景」开关（点击输入框时在下方展开），Windows 通过「显示顶部快捷场景栏」开关。双端都提供 全屋关灯 / 柔和夜灯 / 关温控风扇（家里有对应设备时才显示），Windows 演示模式另用四个示例动作；接入 Home Assistant 后双端都会追加你的场景胶囊。macOS 下动作与场景合计不超过四项时等宽铺满，更多则支持普通鼠标滚轮横向滚动。 |
| **批量全关与即刻撤销** | ✅ 支持 | ✅ 支持 | 长按 0.6 秒触发；插座与扫地机默认不参与，可调整；操作可撤销时提供 10–15 秒横幅 |
| **Mac 状态自动化** | ✅ 支持 | — 暂不支持 | 支持锁屏、唤醒、外接显示器，以及摄像头 / 麦克风占用、电源与电量、Wi-Fi、专注模式、日历与深夜使用等 Mac 专属触发（默认关闭） |
| **系统快捷指令集成** | ✅ 支持 (4 个动作) | — 暂不支持 | 提供设备切换、执行场景、一句话控制、查询温湿度 4 项 App Intents |
| **URL Scheme 控制** | ✅ 支持 | ✅ 支持 | `menumijia://toggle`（及 `power`、`brightness`、`color-temp`、`temperature`、`fan`、`scene`、`ask`、`focus`）调用默认需确认，可在设置中允许直接执行；Windows 通过单实例转发交给运行中的托盘程序处理 |
| **Raycast 扩展、本地 CLI 与 MCP 服务** | ✅ 支持 | ✅ 支持 | `raycast/`、`scripts/mijia` 与 `scripts/mijia-mcp` 只读应用写出的 `raycast-snapshot.json`（macOS 为 `~/Library/Application Support/MenuBarMijia/`，Windows 为 `%LOCALAPPDATA%\MenuBarMijia\`），通过 `menumijia://` 链接控制设备、场景与快捷动作，不持有任何凭据；MCP 响应自动剥离 `bridgeToken`，高风险二次确认与锁屏拦截仍在应用内执行 |
| **传感器历史折线图** | ✅ 24h / 7d 趋势 | ✅ 24h / 7d 趋势 | 双端均支持切换温度、湿度、PM2.5 或光照指标及 24h / 7d 时间范围，结合本地分桶采样与米家 / HA 历史回填绘制趋势曲线 |
| **插座电量统计** | ✅ 支持 | ✅ 支持 | 双端均按插座上报的真实累计电量增量记录逐日账本并支持电费估算，无数据不凭空估算 |
| **米家空净 / 新风机 / 加湿器** | ✅ 支持 | ✅ 支持 | 双端合成 `air-purifier`、`air-fresh`、`humidifier` 规格：PM2.5 / 空气质量 / 温湿度 / 滤芯余量，风速 1–100% 联动最爱挡位 |
| **冰箱与厨房家电** | ✅ 支持 | ✅ 支持 | 冰箱按冷藏、冷冻分室显示当前与目标温度，支持 手动 / 智能 / 假日 / 速冷 / 速冻 模式；电水壶、饮水机、电饭煲、空气炸锅、烤箱、微波炉、养生壶显示工作状态、温度与剩余分钟数，带 `start-cook` / `pause` 动作的机型可直接启停 |
| **热水器** | ✅ 支持 | ✅ 支持 | 米家热水器合成为通用家电卡：电源、模式、目标温度（范围与步长取自规格）、状态、故障条、剩余时间与无参的开始 / 暂停动作，规格里有才显示；当前水温作为主读数。打开或调高温度需确认，关闭直接执行；热水器默认不参与「全关」 |
| **HA 加湿器、热水器与阀门** | ✅ 支持 | ✅ 支持 | Home Assistant 通道合成 `humidifier`（电源、模式、目标湿度与自带湿度读数）、`water_heater`（复用通用家电卡，打开或调高温度需确认）与 `valve`（开 / 关，打开水阀或燃气阀需确认）。未被主卡片认领的 `switch`、`select`、`number`、`button`、`sensor`、`binary_sensor` 实体进入「更多设置」，支持乐观写入（macOS 同时提供撤销）；`text` 实体跳过 |
| **浴霸与油烟机** | ✅ 支持 | ✅ 支持 | 米家浴霸把 PTC 暖风、风量、室温读数与灯光合成一张家电卡：电源、目标温度、规格里的模式列表、风量、灯光开关、室温与湿度；油烟机把排风电源、风量与照明合成一张卡。副服务的灯只作为卡内开关，不再单独成卡。规格里没有的控件不显示 |
| **洗衣机、烘干机与洗碗机** | ✅ 支持 | ✅ 支持 | `washer`、`dryer`、`clothes-dryer`、`dishwasher` 规格合成为通用家电卡：卡片主区显示程序、洗涤阶段与剩余分钟（如「洗涤中 · 剩余 42 分」），另有故障条与无参的开始 / 暂停 / 停止。程序多达二十几项时在抽屉里横向滚动，不平铺成一片。开始需再确认，暂停与停止直接执行；规格里带参数的动作直接忽略，不会让整张卡报错 |
| **除湿机 / 水暖毯 / 香氛机 / 音箱** | ✅ 支持 | ✅ 支持 | 除湿机合成为风扇卡，按其上报的模式列表切换并读取自身温湿度，水暖毯合成为温控卡，香氛机作为可开关插座，音箱作为媒体卡支持音量、静音、播放状态、睡眠模式与文本播报（文本播报仅 macOS；Windows 音箱卡支持音量、静音、播放状态与睡眠模式） |
| **门锁与人体、环境传感器** | ✅ 只读卡片 | ✅ 只读卡片 | 门锁显示电量。读到 `door-state` 或 Home Assistant 的 `lock` 实体时展示已上锁、已开锁、虚掩或卡住；没有可靠状态时显示「锁状态未知」，不再固定写成「守护中」。人体移动/存在、门窗磁、水浸、光照与空气质量监测合成为传感器卡片；MIoT 不开放远程开锁，门锁只作状态展示。macOS 上，米家网关、路由器、中继器在有可用规格项时改为通用卡片（只读或低风险写入），没有规格或没有可用项时才进入「未显示设备」列表 |
| **通用兜底卡片** | ✅ 支持 | ✅ 支持 | 米家规格里没有专用类型、但仍有可用控件或读数的设备显示一张通用卡：名称与房间、最多两个关键读数、一个低风险主开关，其余控件进入「更多设置」；只读设备明确标注「只读」。门锁、加热类与路由器配置默认只读，放开次要写入需二次确认；通用卡默认不参与「全关」与助手批量指令。Windows 的「更多设置」写入即时生效，但不提供撤销 |
| **智能鱼缸与宠物喂食器** | ✅ 支持 | ✅ 支持 | 双端米家 `fish-tank`、`pet-feeder` 规格接入通用卡：卡片主区显示整机开关与水温（喂食器显示余粮），「更多设置」优先列出水泵开关与档位、灯光（模式 / 亮度）、按份投喂、滤芯寿命与水温告警。投喂先选份数，确认框会一并说明今日已投喂多少；水泵未插入、低水位、堵塞、故障直接显示为红色提示。厂商私有服务与内部属性继续隐藏。 |
| **摄像机实时画面** | ✅ 支持 | ✅ 支持 | 点击卡片放大弹出置顶实时小窗：macOS 走 HLS / HA 抓拍流，可在同一窗口切换摄像机，已验证的米家双摄型号提供主摄 / 副摄切换；Windows 内置私有 P2P 桥（安装包内置组件，可选流畅 / 高清 / 超清）。米家 P2P、MJPEG 与抓拍流只传画面，HUD 会标注「仅画面」；带音轨的 HLS 流提供静音 / 开启声音切换（macOS） |
| **布局编辑调大小** | ✅ 支持 | ✅ 支持 | 编辑模式下卡片右下角显示 iOS 控制中心风格圆弧手柄：向外/向内拖拽逐档切换 半行 ↔ 整行 ↔ 展开面板，轻点则循环切换 |
| **界面外观** | ✅ 常规 / 液态玻璃双主题 | ✅ Win11 Fluent 2 双悬浮岛 | macOS 默认「常规」位于菜单栏图标下方（可选四档高度），macOS 26+ 可切换「液态玻璃」右侧整列面板；Windows 采用原生 Windows 11 Fluent 2 双悬浮岛（上方 `Win+N` 动态通知岛 + 下方 `Win+A` 快速设置胶囊岛），随任务栏停靠边缘原生滑入滑出。 |
| **窗帘与开窗器** | ✅ 开合中状态 + 两端 2% 吸附 | ✅ 开合中状态 + 两端 2% 吸附 | 双端都显示真实开合中状态（含厂商拼写 `Dowm` / `Fallin` 与 `Up` / `Down`），位置落在两端 2% 内吸附为 0%/100%，移动中点卡片停止。晾衣架显示的是高度，因此双端都把米家的「下降距离」反转。打开开窗器或晾衣架需再点一次确认，车库门两个方向都要确认 |
| **安装签名与更新机制** | ⚠️ 本地签名 + Ed25519 验签更新 | ⚠️ 未签名安装包 + Ed25519 验签更新 | 双端应用内更新均使用离线公钥校验 Ed25519 清单签名；macOS 需手动允许首次打开，Windows 首次安装有 SmartScreen 提示 |

</details>

---

## Raycast 扩展、本地 CLI 与 MCP 服务

在 macOS 打开 **设置 → 通用 → 自动化与外部控制 → Raycast 集成**（或在 Windows 打开 **设置 → 全关与更新 → Raycast 与本地 CLI / MCP 集成**）后，应用会把设备、场景、快捷动作、环境读数、上一条命令结果和一个本机随机令牌写到 `~/Library/Application Support/MenuBarMijia/raycast-snapshot.json`（macOS，权限 `0600`）或 `%LOCALAPPDATA%\MenuBarMijia\raycast-snapshot.json`（Windows）。带令牌的 `menumijia://` 链接不再弹外部链接确认；双端的高风险设备仍会先问，锁屏拦截照旧。关闭该开关会立即删除文件并作废令牌，伴生端拿不到任何米家或 Home Assistant 凭据；契约与取舍见 [ADR-0013](docs/adr/0013-raycast-companion-contract.md)。

<details>
<summary><b>命令行、MCP 服务与 Raycast 的具体用法</b></summary>

### 本地 CLI

`scripts/mijia` 是只依赖 Python 3 标准库的脚本，使用时保持 MenuBarHome 运行即可。

| 命令 | 作用 |
| :--- | :--- |
| `scripts/mijia list [--room 书房] [--json]` | 按房间列出面板里可见的设备、在线状态与读数 |
| `scripts/mijia status [--json]` | 连接状态、设备数量、环境读数与上一条命令的结果 |
| `scripts/mijia toggle 书房台灯` | 翻转主开关，支持设备名、ID 或拼音首字母（`sftd`） |
| `scripts/mijia on 客厅射灯` / `scripts/mijia off 客厅射灯` | 按目标状态开关，不再依赖当前状态 |
| `scripts/mijia brightness 书房台灯 60` | 按百分比调节灯光亮度（`0`–`100`%） |
| `scripts/mijia color-temp 书房台灯 4000` | 按开尔文调节灯光色温（`1000`–`20000` K） |
| `scripts/mijia temperature 书房空调 25` | 设定目标温度（`-30`–`100` ℃） |
| `scripts/mijia fan 客厅风扇 --percent 60` / `--preset 自然风` | 设定风速百分比（`1`–`100`%）或设备上报的档位 |
| `scripts/mijia focus 书房台灯` | 在面板中定位到设备所在房间并展开详情抽屉（不操作硬件） |
| `scripts/mijia scene 观影模式` | 执行 Home Assistant 场景或内置快捷动作（全屋关灯、一键全关、撤销……） |
| `scripts/mijia ask "把客厅灯调到 40%"` | 一句话指令，复用应用自己的解析与确认规则 |
| `scripts/mijia mcp`（或 `scripts/mijia-mcp`） | 以 stdio 方式运行本地 MCP 服务 |

退出码：`0` 成功；`1` 应用报告执行失败；`2` 本地错误（快照缺失、设备找不到、集成未开启）；`3` 等待结果超时。`--dry-run` 只打印链接（令牌打码），`--no-wait` 发完不等结果，`MENUBARMIJIA_SNAPSHOT_PATH` 可覆盖快照路径。

### 本地 MCP 服务（Claude Desktop / Claude Code / Cursor）

`scripts/mijia-mcp`（或 `scripts/mijia mcp`）仅用 Python 3 标准库实现 stdio JSON-RPC 2.0 MCP 服务，提供只读资源（`mijia://status`、`mijia://devices`、`mijia://scenes`）与结构化工具（`list_devices`、`get_home_status`、`toggle_device`、`set_device_power`、`set_light_brightness`、`set_light_color_temp`、`set_temperature`、`set_fan`、`run_scene`、`ask_home`、`focus_device`）。服务在进程内使用 `bridgeToken` 派发 `menumijia://` 链接，并从所有返回给模型的资源与工具结果中剥离 `bridgeToken`，不向模型暴露任何令牌或云端凭据。

```json
{
  "mcpServers": {
    "menubarmijia": {
      "command": "/ABSOLUTE/PATH/TO/MenuBarHome/scripts/mijia-mcp"
    }
  }
}
```

### Raycast 扩展

`raycast/` 是标准 Raycast 扩展，提供三个命令：**搜索设备**、**场景与快捷动作**、**问 MenuBarHome**。在 Raycast 的扩展页按 `+` → **Import Extension** 选择 `raycast/` 即可，或在 Raycast 打开时运行 `cd raycast && npm ci && npm run dev`。开关、亮度、色温、目标温度与风速都按精确值下发（`menumijia://power`、`brightness`、`color-temp`、`temperature`、`fan`），滑条不会靠猜当前状态去翻转设备；每条命令都会用 toast 显示应用的执行结果。

</details>

---

## 安全、隐私与限制

- 账号凭据只存在 macOS 钥匙串或 Windows 凭据管理器里，不写进明文配置，也不进日志。
- 打开电暖器、切换插座、启动扫地机这类操作一定会先问你；把它们关掉则直接执行。
- Mac 锁屏期间默认拒绝所有手动控制，离开座位也不怕被人乱点。
- 常用指令在本机解析。只有你配置了 AI 服务、而且这句话本机听不懂时，才会把指令和相关设备信息发给你选的服务。
- 应用内更新用 Ed25519 签名校验，签名私钥离线保存。

<details>
<summary><b>凭据存放、高风险确认、锁屏与吊销的完整说明</b></summary>

MenuBarHome 是独立开源项目，并非小米官方客户端。米家云直连需要联网；已有 Home Assistant 时，可在 macOS 或 Windows 上连接自己的实例。

### 凭据存放在哪

| 凭据 | 保存的内容 | 位置 |
| :--- | :--- | :--- |
| 米家 / Xiaomi Home | 已登录账号的 `userId`、`cUserId`、`ssecurity`、`serviceToken`、云端地区与声明的到期时间（登录时即丢弃 `passToken`；macOS 支持多账号，Windows 为单账号） | macOS 钥匙串（一条通用密码项）或 Windows 凭据管理器（`mi_session`） |
| Home Assistant | 长期访问令牌（实例地址不属于机密） | macOS 钥匙串或 Windows 凭据管理器（`ha_token`） |
| AI 助手 | 按服务商预设隔离保存的 API 密钥，以及非机密的导入来源标记、自定义端点绑定与已允许的云端授权地址 | 各服务商 API 密钥保存在 macOS 钥匙串或 Windows 凭据管理器（`assistant_api_key_<preset>`）；非机密元数据保存在应用偏好中 |
| LG webOS 电视 | 电视签发的配对客户端密钥 | macOS 钥匙串 |

macOS 会将这些钥匙串项加密保存，并由登录钥匙串保护；MenuBarHome 写入时使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，首次解锁后可用，但不会同步到 iCloud 或另一台 Mac。双端都不会把这些机密写进明文 `UserDefaults`、WebView `localStorage` 或日志。macOS 更新后可能询问一次钥匙串授权（构建签名发生变化）；选择「始终允许」即可覆盖之后的读写。

macOS 上 1.0.6 及更早版本曾把凭据镜像到明文 `UserDefaults`；升级后首次启动时，每个旧明文值都会先写入钥匙串，写入成功后才删除对应明文键，钥匙串不可用时保留旧副本以便下次重试。Windows 上从早期 `localStorage` 版本升级时，会先剥离机密字段并重写 `localStorage`，再异步持久化到 Windows 凭据管理器，确保凭据管理器写入失败时也不会在 WebView 存储中残留明文令牌（当前进程内存会话继续保持可用）；凭据管理器中旧版单槽 `assistant_api_key` 也会先迁移到所属服务商分槽，确认写入成功后才删除旧条目。

### 高风险控制、锁屏与吊销

高风险设备的手动操作也需要二次确认，而不只是 AI 建议的操作：打开电暖器、切换插座或摄像机、启动扫地机，或打开热水器 / 调高热水器温度。关闭这些设备的操作保持直接执行，避免「想让家里更安全却先被弹窗拦住」。门窗与燃气报警在本应用中只是只读状态卡片，无法在这里被操作。确认规则在双端通过共享基线对齐（`Tests/Fixtures/confirmation_golden.json`、`Sources/MijiaCore/ModelActionPolicy.swift`）。

macOS 的设置 → 「隐私」中有 **「锁屏时禁止控制设备」**，默认开启。Mac 锁屏期间，卡片与详情控制、`menumijia://` 链接、快捷指令 / App Intent、助手命令、守护提醒通知的「立即关闭」以及「错过的定时」里的「立即补执行」都会被拒绝并提示；按时间自动触发的定时任务与 Mac 事件自动化规则仍然执行。开关保存在本机，锁屏状态来自系统的锁屏通知。

同一 macOS 设置页提供 **「退出并吊销令牌」**，需要先经过破坏性确认。它会退出全部米家账号、删除 Home Assistant 令牌并断开连接，同时清除已保存的 AI 密钥与云端授权记录，保留设备名称、房间布局与本地历史；也可在各分区单独吊销。Windows 端可在四栏偏好设置中按服务逐项清空凭据与授权记录（清空 HA 令牌或某服务商 API Key 会同步删除 Windows 凭据管理器中的对应条目，「AI 与习惯」页签提供一键撤销云端 AI 发送授权）。

macOS 上，Home Assistant 令牌只会直接发往 `https` 地址或局域网端点；其他明文 `http` 地址（例如公网 DDNS 域名）在连接前会先说明「令牌会以明文传输」，点击「仍然连接」后才会连接（按地址记住，可由「退出并吊销令牌」一并清空）。Windows 上，每个新增的 Home Assistant 或自定义 AI 来源都需在系统原生对话框中确认授权（写入 `authorized-http-origins.json`）；若非局域网地址使用明文 `http`，原生确认框会显式附带明文传输警告。

常用指令由本地规则处理。你也可以接入自己选择的 AI 服务，处理更复杂的说法；发送给服务的内容包括指令、设备及环境信息，以及你启用的习惯摘要。手动点卡片操作也会在本机学习时段习惯（只用于「猜你想控」推荐）；学习开关可随时关闭，已学内容可在设置中查看并一键清空，点击撤销横幅会同步回滚对应习惯记录。语音识别使用系统服务；macOS 上支持的语言可开启「语音只在本机识别」，并将设备名、房间名和场景名作为识别提示交给系统语音服务。

为了避免误操作，开启电暖器、切换插座或启动扫地机等高风险操作始终要求确认，AI 低把握度猜测则会作为待点击建议展示（macOS 设置中的「不确定时先问我」默认开启）。macOS 的 URL 控制默认也会先确认，可在设置中开启直控。

macOS 安装包尚未经过 Apple 公证，首次打开时可能需要在系统设置中允许；Windows 安装包可能触发 SmartScreen。双端应用内更新均使用离线保管私钥的 Ed25519 签名清单进行验签。更多连接方式说明见 [ADR-0007](docs/adr/0007-lan-direct-deferred.md)。

GitHub Actions 构建的正式发布产物附带构建溯源证明（build provenance）与 SPDX SBOM 清单，校验方式见 [SECURITY.md](SECURITY.md#verifying-release-artifacts)。

私下报告漏洞的步骤写在英文的 [Security policy](SECURITY.md)。

</details>

---

## 参与开发与技术架构

- **架构理念：** macOS 端为纯 Swift 6 开发，**运行时代码无第三方 Swift 依赖**，开启严格并发检查；核心协议解析与状态合成抽象为独立模块 `MijiaCore`（可脱离 UI 单独运行全量单元测试）。Windows 端基于 Tauri v2 (Rust + TypeScript + Vite) 构建独立托盘程序。
- **跨平台一致性保证：** 双端使用 `Tests/Fixtures/` 目录下的共享 Golden 语料（意图、规格书、区域、服务商测试数据）进行各自断言，确保解析规则不分叉（详见 [ADR-0006](docs/adr/0006-dual-platform-implementation.md)）。

### 本地构建与验证

```bash
# macOS 本地全量测试与代码门禁检查
bash scripts/check.sh

# 编译、打包并启动 macOS 本地构建
bash scripts/build_app.sh

# Windows 托盘版本地构建与测试
cd windows
npm install
npm test
npm run build
```

在提交 Pull Request 前，请先阅读 [CODING_STANDARDS.md](CODING_STANDARDS.md) 了解代码规范；项目领域概念见 [GLOSSARY.md](GLOSSARY.md)。

---

## 贡献者与致谢

感谢为 MenuBarHome 提交代码、修补协议细节与打磨交互体验的贡献者：

- [@jryang2026-code](https://github.com/jryang2026-code)（一群小羊说）— 项目发起与维护
- [@almightyYantao](https://github.com/almightyYantao)（Alimighty.Yantao）— 多键 Mesh 开关分键设备识别与合成（GitHub #6、GitHub #7）、米家多家庭切换与灯组情景过滤（GitHub #8）、多主题面板皮肤、空调/温湿度计独立模块、长按拖拽自由布局与自定义分组（GitHub #9）、macOS 应用图标打包集成（GitHub #10）、面板下落动画、本地设备重命名与房间栏细节打磨（GitHub #11）、Windows 功能对齐与跨端界面修复（GitHub #12），以及连接源快照的冗余写入优化（GitHub #66）
- [@htx996](https://github.com/htx996)（han）— macOS 菜单栏状态项右键菜单：实时连接 / 演示模式切换、双源连接状态展示，以及与长按语音、键盘操作互不干扰的点击处理（GitHub #250）

## 协议与致谢

- **开源协议：** 本项目采用 [MIT License](LICENSE) 开源。
- **第三方集成说明：** 本仓库不分发任何第三方官方组件。涉及 Home Assistant 模式下的 [xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home) 与 [midea_ac_lan](https://github.com/wuwentao/midea_ac_lan) 分别来自小米及其各自维护者，版权归各自作者所有。
- **商标声明：** 「小米」「米家」「Xiaomi」「Mijia」等为小米科技有限责任公司注册商标；「美的」为美的集团股份有限公司注册商标。本文档与本项目仅用于描述设备兼容性。

感谢所有为 MenuBarHome 提交代码、报告缺陷与改进建议的贡献者！如果这个小工具让你在工作时少掏了几次手机，欢迎在 GitHub 上点一个 ⭐ Star。

---

## 常见问题（FAQ）

### MenuBarHome 占用多少内存和 CPU？

macOS 版是单个原生 AppKit / SwiftUI 进程，没有内嵌浏览器内核。以下为 2026-11-07 在 Apple 芯片 Mac（10 核，macOS 27.0.1）上使用 MenuBarHome 1.1.7 (426) 的实测值（已接入十余台设备，含 1 台摄像机）：

| 状态 | RSS 常驻内存 | CPU（单核占比） |
| --- | --- | --- |
| 后台静置（面板关闭） | 159 MB | 0.1% |
| 面板展开（无操作） | 147 MB | 0.1% |
| 按住 Option-M 语音输入 | 152 MB | 26% |

- **RSS** 来自 `ps` 的常驻集大小；活动监视器「内存」列（物理内存占用）同一状态下约为 146 MB。
- **CPU** 为单核占比，由连续三个采样窗口（默认每段 5 秒）的 CPU 时间增量计算得出。`ps %cpu` 是进程全生命周期平均值，忙碌结束后很长时间仍会偏高，因此测量脚本不采用它。
- 展开面板复用同一进程，无交互时 RSS 基本不变，CPU 接近于零。
- 只有语音输入期间有明显 CPU 占用：`AVAudioEngine` 采集麦克风音频并交由系统语音框架识别；系统进程 `corespeechd` 负责底层识别，其 CPU 不计入应用自身数字。
- 实际内存取决于已接入内容：摄像机实时流、大量 MIoT 设备规格书与复杂场景都会增加占用。

### Windows 11 端占用如何？

Windows 版基于 Tauri v2 与系统 WebView2：一个宿主进程运行托盘程序（安装版为 `MenuBarHome.exe`，本地 Tauri 构建为 `menubarmijia-windows.exe`），并由一个或多个 `msedgewebview2.exe` 子进程渲染界面。`scripts/measure_footprint.py` 会汇总宿主进程及其所属渲染子进程，自动忽略其他应用的 WebView2 进程。

表格暂未收录 Windows 11 实机数据，需在 Windows 机器上托盘程序运行时执行同一脚本采集：

```powershell
python scripts\measure_footprint.py --state idle
python scripts\measure_footprint.py --state panel
python scripts\measure_footprint.py --state voice
```

### 接入 20 台以上设备时，首次展开要多久？

| 平台 | 设备数 | 状态合成（中位数） | 范围 | 轮数 |
| --- | --- | --- | --- | --- |
| macOS (MijiaCore) | 24 | 2.10 ms | 2.02–2.69 ms | 31 |
| Windows (TypeScript core) | 24 | 0.10 ms | 0.07–0.13 ms | 31 |

双端对同一份快照（6 个房间共 18 盏灯与 6 个开关）执行状态合成。设备合成是纯函数，耗时仅毫秒级；首次打开若感觉慢，主要来自网络拉取与视图构建，而非状态合成。

### 如何复现这些测量数据？

`scripts/measure_footprint.py` 只对已在运行的进程采样，不会自行启动应用，也无法自动判断界面处于哪种状态，因此请先将应用置于对应状态再运行：

```bash
# 静置状态：关闭面板，静置一分钟后采样
python3 scripts/measure_footprint.py --state idle

# 面板展开：按 Option-M 展开面板后采样
python3 scripts/measure_footprint.py --state panel

# 语音输入：按住 Option-M 出现麦克风提示期间采样
python3 scripts/measure_footprint.py --state voice

# 输出仓库已记录基线的机器可读 JSON
python3 scripts/measure_footprint.py --no-live --json
```

实测行在 `Source` 列标记为 `live`；应用未运行时脚本会打印已提交基线并标为 `recorded`。采样前请先退出多开的副本（脚本默认采样找到的第一个 `MenuBarMijiaApp` 进程）。

---

