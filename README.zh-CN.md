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
  用米家 App 扫一下码就能连上，不必先搭 Home Assistant。<br>
  <sub>本项目原名 <b>MenuBarMijia</b>。</sub>
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
  <a href="docs/supported-devices.zh-CN.md">我的设备能用吗？</a> ·
  <a href="docs/platform-matrix.zh-CN.md">双端能力对照</a> ·
  <a href="#安全隐私与限制">安全与隐私</a> ·
  <a href="CHANGELOG.md">更新日志</a>
</p>

<p align="center">
  <img src="docs/assets/readme-v3/keyboard-search.gif" alt="macOS 演示：按 ⌥M 呼出面板，输入 sftd 找到书房台灯，回车开灯" width="420">
</p>

<p align="center"><sub>按 <code>⌥M</code> 呼出面板，敲 <code>sftd</code>（书房台灯的拼音首字母），回车开灯。画面来自 macOS 演示模式，设备均为虚拟。</sub></p>

**三步上手：** [安装](#1-安装)（Homebrew、DMG，或 Windows 安装包）→ [连接](#2-连接你的家)（扫一个二维码，或先用不需要账号的演示模式）→ 按 `⌥M`（Windows 是 `Alt+M`）。

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
- **原生、安静。** macOS 版用 Swift 写成，不带浏览器内核；后台静置（面板关闭）时实测 CPU 占用约 1.2%，内存约 113 MB（详情见 [FAQ](docs/faq.zh-CN.md)）。

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

从 [GitHub Releases](https://github.com/jryang2026-code/MenuBarHome/releases/latest) 下载 `MenuBarHome-<版本>.dmg`（例如 `MenuBarHome-1.5.0.dmg`），打开后将 `MenuBarHome.app` 拖进「应用程序」。

> 本项目没有加入付费的 Apple 开发者计划，安装包未经 Apple 公证。首次打开如果被 macOS Gatekeeper 拦截，按以下步骤放行：
> 1. 双击打开 `/Applications/MenuBarHome.app`，弹出「无法验证开发者」或拦截提示时先点 **「完成」**（或 **「好」**）关闭弹窗。
> 2. 在 macOS 15 及以上系统，打开 **「系统设置 → 隐私与安全性」**，向下滚动到「安全性」区域。
> 3. 找到 `MenuBarHome` 被阻止的提示，点击 **「仍要打开」**，并在确认框中再次点击 **「仍要打开」** 后输入密码或使用触控 ID。
> 4. **备选方式**：若仍无法打开或未看到「仍要打开」按钮，可在终端执行以下命令移除隔离属性：
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/MenuBarHome.app
>    ```

校验 DMG 下载完整性（将输出哈希对照 Release 中的 `MenuBarHome-1.5.0.dmg.sha256`）：

```bash
shasum -a 256 MenuBarHome-1.5.0.dmg
# 若同时下载了同名 .sha256 文件到同一目录，也可直接校验：
shasum -a 256 -c MenuBarHome-1.5.0.dmg.sha256
```

**Windows 11**

从 [GitHub Releases](https://github.com/jryang2026-code/MenuBarHome/releases/latest) 下载 `MenuBarHome-<版本>-windows-x64-setup.exe`（例如 `MenuBarHome-1.5.0-windows-x64-setup.exe`）或 `MenuBarHome-<版本>-windows-x64.msi`（例如 `MenuBarHome-1.5.0-windows-x64.msi`）。

> 安装包没有商业代码签名证书。如果触发 Windows SmartScreen 拦截，按以下步骤放行：
> 1. 弹出蓝色 **「Windows 已保护你的电脑」** 提示框时，点击文字下方的 **「更多信息」**。
> 2. 在展开的窗口底部点击 **「仍要运行」** 继续安装。

校验 Windows 安装包完整性（在 PowerShell 中运行，并将输出哈希与 Release 中的 `.sha256` 文件对照）：

```powershell
# 核对 EXE（对应 MenuBarHome-1.5.0-windows-x64-setup.exe.sha256）
Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.5.0-windows-x64-setup.exe

# 若下载的是 MSI（对应 MenuBarHome-1.5.0-windows-x64.msi.sha256）
Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.5.0-windows-x64.msi
```

### 2. 连接你的家

点菜单栏（或托盘）图标打开面板，进入设置 `⚙️`，三种方式任选：

- **米家云端直连（推荐）：** 选「米家云端直连」，用手机米家 App 扫屏幕上的二维码，确认后全屋的家庭、房间和设备自动同步。支持中国大陆、新加坡、德国、美国、俄罗斯服务器；macOS 与 Windows 都可以继续「添加账号」，把多个小米账号的设备合到一个面板里。登录快过期时会提前 3 天提醒，在面板里重新扫一次码就能续上。
- **Home Assistant（聚合多生态）：** 填上实例地址（如 `http://192.168.1.100:8123`，也支持反向代理子路径）和长期访问令牌即可；macOS 与 Windows 都能在局域网里自动发现 Home Assistant。令牌存进 macOS 钥匙串或 Windows 凭据管理器。**生态边界**：MenuBarHome 内置直连米家与 Home Assistant（另提供可选本机只读通用网络摄像机、DDC/CI 外接显示器与局域网多品牌电视桥）；**Google Home、Apple HomeKit（HomeKit Device）、涂鸦、Aqara/Matter/Zigbee** 等生态均通过 Home Assistant 聚合接入。<br>
  macOS 如果提示「局域网连接被系统拦截」，到 **「系统设置 → 隐私与安全性 → 本地网络」** 里允许 MenuBarHome。
- **演示模式：** 不登录任何账号，用一套虚拟设备先把界面玩一遍。

---

## 看一圈

### 新的面板

搜索框放到了最上面，找设备、问状态和说一句话都在这里。常用设备排成磁贴，空调可以直接在卡片上加减温度，房间切换、房间同品类分组胶囊、排序和紧凑视图都在手边。快捷动作与「猜你想控」统一折叠在 **快捷** 胶囊里（macOS 按 `⌘K`、Windows 按 `Ctrl+K` 展开），让首屏保持清爽。浅色、深色跟随系统；在 macOS 26 及更新的系统上，还可以换成「液态玻璃」主题，且打开 macOS 面板时不再让当前工作应用变暗。

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

托盘版默认采用与 macOS 一致的经典双列分体磁贴面板，也支持切换为 Windows 11 Fluent 2 风格的双悬浮岛：上面是家庭状态、猜你想控和摄像机速览，下面是搜索、快捷动作和设备磁贴。键盘搜索、`Alt+M` 呼出、Windows 11 22H2+ 原生 Mica/Acrylic 背景与系统强调色、独立置顶摄像机画中画小窗以及深浅色都有。

<p align="center">
  <img src="docs/assets/readme-v3/windows-fluent.png" alt="Windows 11 托盘版的浅色与深色面板" width="820">
</p>

---

## 还能做什么

- **能认的设备很多。** 灯、空调、风扇、插座、电视（含 MIoT 电视与机顶盒）、窗帘、晾衣架、净化器、加湿器、冰箱、热水器、洗烘设备、浴霸、油烟机、扫地机、音箱（双端支持正在播放及小爱「播报 / 指令」文本控制）、摄像机、门锁和各类传感器；没有专属卡片的米家设备，也会有一张通用卡。[查一查你家的设备。](docs/supported-devices.zh-CN.md)
- **电视与显示器控制、正在播放与可选多品牌电视桥。** HA 电视/音箱与米家电视双端支持**正在播放**（播放态、媒体元数据、同源鉴权 HA 封面与 SHA-256 LRU 缓存，协议同时上报 `canSeek` + `duration` + `position` 时提供带 2 秒防回跳的可拖拽进度条）以及可折叠方向键遥控板（HA 按生态自适应 Apple TV / Android TV / Sony Bravia / Roku / 通用遥控键，米家走经校验的 MIoT 遥控动作）。双端设置 → 常规另提供默认关闭的**外接显示器控制（DDC/CI）**（未开启零后台开销，支持亮度、DP/HDMI/USB-C 输入源切换与可回读时的音量/静音，刻意禁止 `0xD6` 电源关屏码保护显示器固件）以及可选进程外**多品牌电视桥接插件**（`mbh-tv-bridge`，纯局域网 Go 单二进制，面板收起后自动停止且绝不劫持 HA/米家已接入的同一台电视），默认聚焦 **LG webOS**（SSAP 握手 + WoL 开机）、**小米 / Redmi**（HTTP 6095）与**海信**（海外 VIDAA MQTT 3.1.1），其余品牌收进实验性开关。
- **本机 AI 与桌面情境感知。** 常用口令（现已覆盖 `0–100%` 窗帘/开合设备与 `1–100%` 无级风扇风速）直接在本机完成拼音/同音字兜底解析与三路未命中诊断；macOS 连续 3 次一致命中后还支持 0ms 习惯短语直达。在开启 Apple Intelligence 的 **macOS 26+** 上，设置 → AI 显性展示 **Apple Foundation Models** 本机模型状态卡，支持一键设为默认、免 API Key 测试连接与本机主动建议。双端均通过受控布尔/枚举**桌面情境感知**（`inMeeting` / `externalDisplayConnected` / `focusActive` / `lateNightWork` / `mediaPlaying`，绝不上传窗口名、日历标题或 Wi-Fi SSID）优化 AI 提示与「猜你想控」排序；Windows 语音新增面板内 `Ctrl+M` 切换（`Esc` 取消）、家中词表同音热词后纠偏与语音变更预览。
- **摄像机小窗、静态墙与画中画。** 点开卡片弹出置顶实时画面（Windows 另支持独立置顶画中画窗口，门铃自适应 3:4 竖屏，门铃/告警触发时可按倒计时自动弹出并固定最多 2 个联动开关，支持音轨的流可开启仅收听声音）。2×2 静态墙保留近照与 7 天摄像机事件历史；双摄机型可以切镜头，带云台的直接拖动画面转方向。非米家网络摄像机（RTSP、ONVIF、海康 ISAPI、大华、Tapo）可在设置的高级连接里添加为**只读通用摄像机**：只看实时画面和画中画（不支持云台、对讲和改摄像机设置）；默认只允许局域网或 `.local` 地址，公网地址需要你明确允许；密码只存在钥匙串 / Windows 凭据管理器，不写进配置文件。
- **温湿度曲线和用电账本。** 传感器卡片悬停可直接看 24 小时迷你曲线，展开看完整 24 小时 / 7 天趋势；插座按天记用电量，填上电价还能估算电费。
- **本地氛围、房间分组与猜你想控。** 可把当前房间的设备状态存成本地「氛围」（最多 32 个），一键或用全局快捷键恢复；同房间同品类达到 2 台及以上可控设备会自动聚合成房间分组胶囊。系统还会结合你的时段习惯与桌面情境，把可能要做的操作提前摆出来；习惯只记在本机，随时可以查看和清空。
- **多账号、双数据源与局域网优先。** 可以同时登录多个米家账号，也可以让米家和 Home Assistant 一起工作，同一台设备会自动合并。符合条件的 Wi-Fi 米家设备优先走局域网 miIO 直连并要求明确写回执（旧款非 MIoT 局域网设备自动回退云端）；macOS 上云端离线的米家设备还会做只读局域网可达性探测提示。
- **情境感知自动化、交互通知与家庭周报。** 自动化规则支持定时、持续状态与 macOS 前台应用触发（macOS 内置一键「开会」「观影」模板），双端均支持上下文结束自动恢复原有开关状态；安全与门铃通知支持直接点击「立即关闭」「查看画面」「立即补执行」（受锁屏保护）；每周还能生成一份家庭健康周报，看看哪些设备总掉线、哪些插座在偷偷耗电。
- **接进你的工具。** 双端支持最多 8 组设备 / 场景 / 快捷动作 / 氛围自定义全局快捷键（macOS 带不抢焦点的 HUD 提示），并支持 Apple 快捷指令、`menumijia://` 链接、Raycast 扩展、随包自带的命令行（含 `mijia doctor` 一行自检）与 **MCP Server 2.0**（设置页「复制配置」零占位路径即粘即用），Claude、Cursor 这类 AI 工具也能查询和控制家里的设备，全程拿不到你的账号凭据。

两端各支持哪些能力，见[双端能力对照](docs/platform-matrix.zh-CN.md)。

---

## 常用操作与口令参考

### 键盘快捷操作

macOS 默认按 `⌥M` 呼出面板，Windows 默认按 `Alt+M`；双端还支持为单个设备、场景、快捷动作或氛围绑定最多 8 组自定义全局快捷键。打字盲搜、`↑`/`↓` 选择、`Return`/`Space` 开关或展开、`→`/`←` 调节参数、`Tab` 轮转房间标签、`⌘K` / `Ctrl+K` 展开或收起快捷抽屉与 `Esc` 返回双端通用；Windows 面板聚焦时按 `Ctrl+M` 切换免提语音听写。

| 按键 | 功能 |
| :--- | :--- |
| `⌥M` / `Alt+M` | 全局呼出 / 收起控制面板（macOS / Windows） |
| `⌘K` / `Ctrl+K` | 展开或收起「快捷」抽屉（快捷动作、场景与猜你想控） |
| 按住 `⌥M` / `Ctrl+M` | macOS 按住说话；Windows 面板聚焦时切换免提语音听写（`Esc` 取消） |
| 自定义全局快捷键（最多 8 组） | 全局触发已绑定的设备开关、场景、快捷动作或氛围（高风险目标仍需确认） |
| 直接输入字母 | 搜索设备名称、房间或拼音首字母（如 `sftd` 匹配书房台灯） |
| `↑` / `↓` | 在搜索结果或设备卡片列表中切换光标 |
| `Return` / `Space` | 开关当前选中的设备；对不可直接开关的设备展开详情控制抽屉 |
| `→` / `←` | 右方向键展开详情；展开后用左右方向键调节灯光亮度、空调温度、窗帘位置或音量（Windows 另可调风速） |
| `Tab` | 在不同房间标签之间快速轮转切换（macOS 与 Windows） |
| `Esc` | 退出搜索输入、取消语音听写、收起控制抽屉，或关闭面板 |

### 本地支持的常用自然语言口令

以下口令由本机规则引擎直接解析执行，**不需要配置云端 AI**，不消耗 API Token（支持拼音 / 首字母 / 同音字兜底匹配）：

- **开关设备：** 「关客厅灯」「打开书房空调」「turn off all lights」
- **调节情景模式：** 「书房吸顶灯月光模式」「日光模式」「daylight mode」
- **微调亮度与色温：** 「再暗一点」「主卧灯调到 40%」「brighter」
- **温度、风速与窗帘控制：** 「空调调到 26 度」「调高两度」「风扇开自然风」「客厅风扇调到 60%」「客厅窗帘开到 50%」（车库门、开窗器与晾衣架始终要求高风险确认）
- **只读状态查询：** 「现在哪些灯开着」「书房台灯开着吗」「客厅室温是多少」（直接读取当前状态在本地回答）
- **延时定时执行：** 「10 分钟后关灯」「半小时后关空调」「取消定时」
- **撤销误操作：** 「撤销」「刚才那个撤销」（10 分钟内支持语音或快捷撤销）

涉及 2 台及以上设备或任意高风险设备的指令，执行前会在命令栏内联展示「当前状态 → 目标状态」变更预览供确认。

---

## 双端能力对照

macOS 版是 Swift 6 原生应用，Windows 11 版是另一套 Tauri v2 实现。两端共用黄金测试集，但功能并不完全一致：

| 维度 | macOS 14+ | Windows 11 |
| :--- | :---: | :---: |
| 米家扫码直连 | ✅ | ✅ |
| Home Assistant（聚合 HomeKit / Google Home / 涂鸦 / Matter） | ✅ | ✅ |
| 键盘搜索与全局热键 | ✅ `⌥M` | ✅ `Alt+M` |
| 语音 | ✅ 按住说话或免提 | ⚠️ 仅免提（`Ctrl+M` + 热词纠偏） |
| 本地口令与 AI 助手 | ✅ + Apple Foundation Models（macOS 26+） | ✅ 本地规则 + 云端 / Ollama |
| 一键全关与撤销 | ✅ | ✅ |
| 电视正在播放、进度、遥控板与可选电视桥 | ✅ | ✅ |
| 外接显示器控制（DDC/CI） | ✅ | ✅ |
| 摄像机实时画面 | ✅ | ✅ |
| 只读通用网络摄像机（RTSP/ONVIF/ISAPI/大华/Tapo） | ✅ | ✅ |
| 同时登录多个小米账号 | ✅ | ✅ |
| 米家 + Home Assistant 双源合并 | ✅ | ✅ |
| 事件自动化 | ✅ | ⚠️ 部分支持 |
| Apple 快捷指令 | ✅ | — |
| 签名安装包 | ⚠️ 自签名 | ⚠️ 未签名 |

逐项、逐设备品类的完整对照表见 [docs/platform-matrix.zh-CN.md](docs/platform-matrix.zh-CN.md)。

---

## Raycast 扩展、本地 CLI 与 MCP 服务

在 macOS 打开 **设置 → 通用 → 自动化与外部控制 → 高级 → Raycast / CLI / MCP 集成**（或在 Windows 打开 **设置 → 安全与提醒 → Raycast / CLI / MCP 集成**）后，应用会把设备、场景、快捷动作、环境读数、脱敏自动化摘要、上一条命令结果和一个本机随机令牌写到 `~/Library/Application Support/MenuBarMijia/raycast-snapshot.json`（macOS，权限 `0600`）或 `%LOCALAPPDATA%\MenuBarMijia\raycast-snapshot.json`（Windows）。带令牌的 `menumijia://` 链接不再弹外部链接确认；双端的高风险设备仍会先问，锁屏拦截照旧。关闭该开关会立即删除文件并作废令牌，伴生端拿不到任何米家或 Home Assistant 凭据；契约与取舍见 [ADR-0013](docs/adr/0013-raycast-companion-contract.md)。

macOS 应用包（`MenuBarHome.app/Contents/Resources/cli/`）与 Windows 安装包（`cli/` 资源目录）均已随包内置 `scripts/mijia` 与 `scripts/mijia-mcp`。在设置页点击 **复制配置** 会自动填入本机真实安装路径，无需手动替换占位路径。

**为什么还能看到旧名字。** 应用叫 MenuBarHome，但对外的集成接口保留了原来的名字，这样已有的 Raycast 命令、快捷指令、脚本和 MCP 配置都不会失效：

| 你会看到 | 它是什么 | 该怎么用 |
| :--- | :--- | :--- |
| `menumijia://…` | 所有伴生工具发来的 URL scheme，是兼容契约（见 [ADR-0013](docs/adr/0013-raycast-companion-contract.md)），伴生工具会继续发它 | 继续用 `menumijia://`；`menubarhome://` 也被接受，两者完全等价 |
| `scripts/mijia`、`scripts/mijia-mcp` | 随包内置的命令行与 MCP 服务 | `scripts/menubarhome` 是同一个命令行的新名字，`mijia` 照常可用 |
| `MenuBarMijia/` 数据目录、`MenuBarMijiaApp` 进程 | 应用的数据目录与进程名 | 无需操作；你的登录和设置都在里面 |
| MCP 配置键 `menubarmijia` | MCP 客户端配置里的一个标签，也是服务端上报的名字 | 随便起名；下面的示例用 `menubarhome` |

<details>
<summary><b>命令行、MCP 服务与 Raycast 的具体用法</b></summary>

### 本地 CLI

`scripts/mijia` 是只依赖 Python 3 标准库的脚本（已随应用安装包内置，也可在源码目录直接运行），使用时保持 MenuBarHome 运行即可。

| 命令 | 作用 |
| :--- | :--- |
| `scripts/mijia doctor [--json]` | 一行健康自检：检查伴生集成状态、快照新鲜度与 CLI/MCP 可执行路径（等价于 `scripts/mijia mcp --doctor`） |
| `scripts/mijia list [--room 书房] [--json]` | 按房间列出面板里可见的设备、在线状态与读数 |
| `scripts/mijia list --format alfred [--room 书房]` | Alfred Script Filter JSON：每台设备一条，回车翻转主开关，⌘ 在面板里定位 |
| `scripts/mijia list --format swiftbar [--room 书房]` | SwiftBar / xbar 插件文本：菜单栏标题 + 每台设备一行带状态的 `href=` 链接 |
| `scripts/mijia status [--json]` | 连接状态、设备数量、环境读数与上一条命令的结果 |
| `scripts/mijia toggle 书房台灯` | 翻转主开关，支持设备名、ID 或拼音首字母（`sftd`） |
| `scripts/mijia on 客厅射灯` / `scripts/mijia off 客厅射灯` | 按目标状态开关，不再依赖当前状态 |
| `scripts/mijia brightness 书房台灯 60` | 按百分比调节灯光亮度（`0`–`100`%） |
| `scripts/mijia color-temp 书房台灯 4000` | 按开尔文调节灯光色温（`1000`–`20000` K） |
| `scripts/mijia temperature 书房空调 25` | 设定目标温度（`-30`–`100` ℃） |
| `scripts/mijia fan 客厅风扇 --percent 60` / `--preset 自然风` | 设定风速百分比（`1`–`100`%）或设备上报的档位 |
| `scripts/mijia cover-position 客厅窗帘 50` | 设定窗帘/开合设备位置（`0`–`100`%；车库门与开窗器在应用内强制确认） |
| `scripts/mijia volume 客厅电视 35` / `mute 客厅电视 on` / `media-play-pause 客厅电视` | 控制电视或音箱音量（`0`–`100`%）、静音与播放/暂停 |
| `scripts/mijia focus 书房台灯` | 在面板中定位到设备所在房间并展开详情抽屉（不操作硬件） |
| `scripts/mijia scene 观影模式` | 执行 Home Assistant 场景或内置快捷动作（全屋关灯、一键全关、撤销……） |
| `scripts/mijia ask "把客厅灯调到 40%"` | 一句话指令，复用应用自己的解析与确认规则 |
| `scripts/mijia mcp`（或 `scripts/mijia-mcp`） | 以 stdio 方式运行本地 MCP Server 2.0 |

`scripts/menubarhome` 运行的是同一个程序：`scripts/menubarhome list` 就是 `scripts/mijia list`。

退出码：`0` 成功；`1` 应用报告执行失败；`2` 本地错误（快照缺失、设备找不到、集成未开启）；`3` 等待结果超时。`--dry-run` 只打印链接（令牌打码），`--no-wait` 发完不等结果，`MENUBARMIJIA_SNAPSHOT_PATH` 可覆盖快照路径。

### Alfred 与 SwiftBar

`--format alfred` / `--format swiftbar` 渲染的是同一份只读快照：不写设备、不联网。每一条都带 `menumijia://` 链接，点下去仍然在应用内走外部链接确认、高风险设备二次确认与锁屏拦截。

SwiftBar：在插件目录放一个两行脚本（文件名里的 `1m` 表示每分钟刷新），例如
`~/Library/Application Support/SwiftBar/plugins/menubarhome.1m.sh`：

```sh
#!/bin/sh
exec /Applications/MenuBarHome.app/Contents/Resources/cli/mijia list --format swiftbar
```

Alfred：新建 **Script Filter**，关键字填 `mijia`，脚本命令写
`/Applications/MenuBarHome.app/Contents/Resources/cli/mijia list --format alfred`，再接一个 **Open URL** 动作打开选中的
`arg`；每条的 ⌘ 变体是「在面板中查看」，不会翻转设备。应用不在 `/Applications` 下时用
`--icon` 指定图标位置；不给就用已安装应用的图标，再退回 Alfred 工作流图标。

两种格式的链接都带本机桥令牌，和其他 CLI 命令一致：令牌只免去「外部链接请求执行」那一次通用确认，
高风险设备仍会先问，锁屏时照样拒绝。


### 本地 MCP Server 2.0（Claude Desktop / Claude Code / Cursor）

`scripts/mijia-mcp`（或 `scripts/mijia mcp`）仅用 Python 3 标准库实现 stdio JSON-RPC 2.0 MCP 服务，提供 **5 项只读资源**（`mijia://status`、`mijia://devices`、`mijia://scenes`、`mijia://sensors`、`mijia://automations`）与 **17 个结构化工具**——5 个只读工具（`list_devices`、`get_home_status`、`get_sensor_summary`、`get_automation_status`、`focus_device`）与 12 个控制工具（`toggle_device`、`set_device_power`、`set_light_brightness`、`set_light_color_temp`、`set_temperature`、`set_fan`、`set_cover_position`、`set_media_volume`、`set_media_mute`、`media_play_pause`、`run_scene`、`ask_home`）。服务在进程内使用 `bridgeToken` 派发 `menumijia://` 链接，并从所有返回给模型的资源与工具结果中剥离 `bridgeToken` 与系统自由文本（日历标题、窗口名、Wi-Fi SSID），不向模型暴露任何令牌或云端凭据。

在设置页点击 **复制配置** 即可获得指向随包 `mijia-mcp` 的开箱即用片段（零占位路径）。以 macOS 安装在 `/Applications` 为例：

```json
{
  "mcpServers": {
    "menubarhome": {
      "command": "/Applications/MenuBarHome.app/Contents/Resources/cli/mijia-mcp"
    }
  }
}
```

随时可运行 `mijia doctor`（或 `mijia-mcp --doctor`）一行排查接入状态。所有控制类工具都标了 `destructiveHint: true`（`ask_home` 额外标注 `openWorldHint: true`），遵守注解的 MCP 客户端会在执行前弹确认。只想让 AI 会话只读时，在同一份配置里加 `--read-only`（即 `"args": ["--read-only"]`，或直接跑 `scripts/mijia mcp --read-only`）：此时 `tools/list` 只暴露 5 个只读工具（`list_devices`、`get_home_status`、`get_sensor_summary`、`get_automation_status`、`focus_device`），任何控制调用都会直接返回错误并点名该参数，不会碰到设备。

### Raycast 扩展

`raycast/` 是标准 Raycast 扩展，提供三个视图命令（**搜索设备**、**场景与快捷动作**、**问 MenuBarHome**）、三个可绑全局热键的 `no-view` 命令（**切换设备**、**执行场景**、**全部关闭**，最后一个会先确认），以及三个给 Raycast AI 的功能（`list-devices`、`get-device-state`、`control-device`）。在 Raycast 的扩展页按 `+` → **Import Extension** 选择 `raycast/` 即可，或在 Raycast 打开时运行 `cd raycast && npm ci && npm run dev`。开关、亮度、色温、目标温度与风速都按精确值下发（`menumijia://power`、`brightness`、`color-temp`、`temperature`、`fan`），滑条不会靠猜当前状态去翻转设备；视图命令先弹「正在执行」的 toast 再更新结果，`no-view` 命令用 HUD 反馈，`control-device` 在发链接前先由 Raycast 弹确认。

</details>

---

## 安全、隐私与限制

### 连接之前请先知道

- **米家云端直连用的是非官方接口。** 它不是小米官方集成，小米随时可能限制请求频率或对账号做风控，本项目无法保证不会发生。面板关闭、锁屏时应用会降低轮询频率来减少请求量，并会为手动控制写入预留限流配额、在触发限流时指数退避；符合条件的 Wi-Fi 设备也会优先走局域网 miIO 直连（旧款非 MIoT 局域网设备自动回退云端）。如果你不想承担这个风险，请改用 Home Assistant，并接入小米官方的 [xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home) 集成。
- **会过期，需要重新扫码。** 应用不保存长期凭证 `passToken`，也不做静默续期（见 [ADR-0004](docs/adr/0004-no-pass-token-storage.md)）。登录能撑多久由小米服务器决定，拿到到期时间时会显示在设置里；到期前 3 天面板会提醒你，重新扫码只要几秒。
- **生态边界。** 内置直连来源为米家与 Home Assistant（另含可选本机只读通用网络摄像机、DDC/CI 外接显示器与局域网多品牌电视桥）；**Google Home、Apple HomeKit（HomeKit Device）、涂鸦、Aqara/Matter/Zigbee** 等平台统一通过 **Home Assistant** 聚合接入。
- **安装包没有商业代码签名。** macOS 首次启动需要点「仍要打开」，Windows 会弹 SmartScreen 提示（见[安装](#1-安装)）。
- **Windows 平台差异。** 仅支持 Windows 11；语音采用免提听写（支持面板内 `Ctrl+M` 切换、热词纠偏与变更预览，不支持按住说话）；事件自动化已覆盖锁屏/电源/显示器/休眠/摄像头与麦克风/专注与全屏/Wi-Fi/定时/传感器规则与上下文恢复（暂不支持日历、合盖休眠与前台应用触发）；无 Apple Foundation Models 与 Apple 快捷指令。详见[平台对比](#双端能力对照)。

### 安全与隐私

- 账号凭据只存在 macOS 钥匙串或 Windows 凭据管理器里，不写进明文配置，也不进日志。
- 打开电暖器、切换插座、启动扫地机这类操作一定会先问你；把它们关掉则直接执行。
- 电脑锁屏期间，macOS 与 Windows 均默认拒绝手动控制，离开座位也不怕被人乱点。
- 常用指令在本机解析（开启 Apple Intelligence 的 macOS 26+ 还可通过 Apple Foundation Models 在本机解析复杂指令）。只有你配置了云端 AI 服务、而且这句话本机听不懂时，才会把指令、相关设备信息与纯布尔桌面情境标签发给你选的服务。
- 应用内更新用 Ed25519 签名校验，签名私钥离线保存。

<details>
<summary><b>凭据存放、高风险确认、锁屏与吊销的完整说明</b></summary>

MenuBarHome 是独立开源项目，并非小米官方客户端。米家云直连需要联网；已有 Home Assistant 时，可在 macOS 或 Windows 上连接自己的实例。

### 凭据存放在哪

| 凭据 | 保存的内容 | 位置 |
| :--- | :--- | :--- |
| 米家 / Xiaomi Home | 已登录账号的 `userId`、`cUserId`、`ssecurity`、`serviceToken`、云端地区与声明的到期时间（登录时即丢弃 `passToken`；macOS 与 Windows 均支持多账号） | macOS 钥匙串（一条通用密码项）或 Windows 凭据管理器（`mi_session` 与 `mi_session_<slotId>`） |
| Home Assistant | 长期访问令牌（实例地址不属于机密） | macOS 钥匙串或 Windows 凭据管理器（`ha_token`） |
| AI 助手 | 按服务商预设隔离保存的 API 密钥，以及非机密的导入来源标记、自定义端点绑定与已允许的云端授权地址 | 各服务商 API 密钥保存在 macOS 钥匙串或 Windows 凭据管理器（`assistant_api_key_<preset>`）；非机密元数据保存在应用偏好中 |
| 只读通用摄像机 | 各 RTSP / ONVIF / ISAPI / 大华 / Tapo 摄像机凭据（仅在内存中传给 go2rtc，绝不写入 `go2rtc.yaml`） | macOS 钥匙串或 Windows 凭据管理器（`generic-camera:<id>`） |
| LG webOS 电视（内置） | 电视签发的配对客户端密钥 | macOS 钥匙串 |
| 多品牌电视桥（`mbh-tv-bridge`） | 各电视配对客户端密钥 / 桥接凭据（仅运行时注入） | macOS 钥匙串（`tvBridge.cred.<nativeId>`）或 Windows 凭据管理器（`tv-bridge:<id>`） |

macOS 会将这些钥匙串项加密保存，并由登录钥匙串保护；MenuBarHome 写入时使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，首次解锁后可用，但不会同步到 iCloud 或另一台 Mac。双端都不会把这些机密写进明文 `UserDefaults`、WebView `localStorage` 或日志。macOS 更新后可能询问一次钥匙串授权（构建签名发生变化）；选择「始终允许」即可覆盖之后的读写。

macOS 上 1.0.6 及更早版本曾把凭据镜像到明文 `UserDefaults`；升级后首次启动时，每个旧明文值都会先写入钥匙串，写入成功后才删除对应明文键，钥匙串不可用时保留旧副本以便下次重试。Windows 上从早期 `localStorage` 版本升级时，会先剥离机密字段并重写 `localStorage`，再异步持久化到 Windows 凭据管理器，确保凭据管理器写入失败时也不会在 WebView 存储中残留明文令牌（当前进程内存会话继续保持可用）；凭据管理器中旧版单槽 `assistant_api_key` 也会先迁移到所属服务商分槽，确认写入成功后才删除旧条目。

### 高风险控制、锁屏与吊销

高风险设备的手动操作也需要二次确认，而不只是 AI 建议的操作：打开电暖器、切换插座或摄像机、启动扫地机，或打开热水器 / 调高热水器温度（macOS 面板指针操作提供长按 0.65 秒或右滑确认手势，键盘与旁白仍保留显式确认弹窗）。关闭这些设备的操作保持直接执行，避免「想让家里更安全却先被弹窗拦住」。门窗与燃气报警在本应用中只是只读状态卡片，无法在这里被操作。确认规则在双端通过共享基线对齐（`Tests/Fixtures/confirmation_golden.json`、`Sources/MijiaCore/ModelActionPolicy.swift`）。

macOS 的设置 → 「隐私」中有 **「锁屏时禁止控制设备」**，默认开启，同页还提供 **「共享屏幕时隐藏面板与摄像机窗口」**（`NSWindow.sharingType = .none`）。Mac 锁屏期间，卡片与详情控制、自定义快捷键、`menumijia://` 链接、快捷指令 / App Intent、助手命令、守护提醒通知的「立即关闭」以及「错过的定时」里的「立即补执行」都会被拒绝并提示；按时间自动触发的定时任务与 Mac 事件自动化规则仍然执行。开关保存在本机，锁屏状态来自系统的锁屏通知。

同一 macOS 设置页提供 **「退出并吊销令牌」**，需要先经过破坏性确认。它会退出全部米家账号、删除 Home Assistant 令牌并断开连接，同时清除已保存的 AI 密钥与云端授权记录，保留设备名称、房间布局与本地历史；也可在各分区单独吊销。Windows 端可在设置窗口按服务逐项清空凭据与授权记录（清空 HA 令牌或某服务商 API Key 会同步删除 Windows 凭据管理器中的对应条目，「AI 与习惯」相关分区提供一键撤销云端 AI 发送授权）。

macOS 上，Home Assistant 令牌只会直接发往 `https` 地址或局域网端点；其他明文 `http` 地址（例如公网 DDNS 域名）在连接前会先说明「令牌会以明文传输」，点击「仍然连接」后才会连接（按地址记住，可由「退出并吊销令牌」一并清空）。Windows 上，每个新增的 Home Assistant 或自定义 AI 来源都需在系统原生对话框中确认授权（写入 `authorized-http-origins.json`）；若非局域网地址使用明文 `http`，原生确认框会显式附带明文传输警告。双端还会在建立连接前校验 DNS 解析结果（macOS `HAPlaintextConsent.validateConnectionAddress`，Windows `PolicyAwareResolver`），拒绝受禁地址并防范局域网明文端点遭遇 DNS 重绑定攻击。

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

---

## 常见问题（FAQ）

- [首次打开被 macOS Gatekeeper 或 Windows SmartScreen 拦截怎么办？怎么校验安装包？](docs/faq.zh-CN.md#首次打开被-macos-gatekeeper-或-windows-smartscreen-拦截怎么办怎么校验安装包)
- [占用多少内存和 CPU，怎么自己测？](docs/faq.zh-CN.md)
- [Windows 11 端占用如何？](docs/faq.zh-CN.md#windows-11-端占用如何)
