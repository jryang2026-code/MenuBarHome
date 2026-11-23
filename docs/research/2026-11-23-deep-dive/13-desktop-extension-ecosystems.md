# 13 桌面/菜单栏类应用的扩展生态设计

- **调研日期**：2026-11-23
- **调研范围**：Raycast 扩展生态、`@raycast/api` 与 Store 治理；SwiftBar / xbar 脚本协议与流式插件；Alfred Script Filter、Hammerspoon Spoons / `urlevent`、Übersicht 桌面小组件；Microsoft PowerToys Command Palette 进程外 WinRT/COM 扩展架构；Elgato Stream Deck SDK、Loupedeck SDK 与两种 Home Assistant Stream Deck 插件；Home Assistant 官方 `mcp_server`、社区 `ha-mcp` 与 `Do1e/mijia-api` MCP 服务；并落回 MenuBarHome 既有扩展契约（[ADR-0013](../../adr/0013-raycast-companion-contract.md)、[ADR-0020](../../adr/0020-backend-descriptor-table.md)、[ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md)）规划五层对外扩展面。
- **实际研读仓库与版本（均位于 `~/.cache/mbh-research-clones/`）**：
  - `raycast/extensions`：`08d2f847`（2026-11-23）
  - `swiftbar/SwiftBar`：`97f4f87`（2026-11-08）
  - `Hammerspoon/hammerspoon`：`f392895`（2026-11-22）
  - `felixhageloh/uebersicht`：`859a7d7`（2023-12-04）
  - `microsoft/PowerToys`：`0068588`（2026-11-23）
  - `elgatosf/streamdeck`：`650a5df`（2026-11-20）
  - `cgiesche/streamdeck-homeassistant`：`4a04d76`（2026-10-16）
  - `basnijholt/home-assistant-streamdeck-yaml`：`a87daa4`（2026-10-11）
  - `home-assistant/core`：`b6d170e`（2026-11-23）
  - `homeassistant-ai/ha-mcp`：`e8c0841`（2026-11-22）
  - `Do1e/mijia-api`：`2cc61f2`（2026-10-10）

---

## 0. 结论先行

1. **进程外隔离是桌面控制类应用扩展的行业铁律，MenuBarHome 已站对架构起点**：Raycast 用单子 Node 进程 + V8 Isolate + 声明式 React RPC 隔离扩展（`raycast/extensions:docs/information/security.md:17-19`）【源码】；PowerToys CmdPal 用 WinRT out-of-proc COM（`CoRegisterClassObject` `CLSCTX_LOCAL_SERVER`）隔离扩展（`microsoft/PowerToys:src/modules/cmdpal/extensionsdk/Microsoft.CommandPalette.Extensions.Toolkit/ExtensionServer.cs:33-38`）【源码】；Elgato Stream Deck 用本地 WebSocket 隔离插件进程（`elgatosf/streamdeck:packages/plugin/src/connection.ts:67-75`）【源码】。反观 Loupedeck 进程内加载 C# DLL 导致插件崩溃会拖垮宿主（【检索】https://github.com/Loupedeck/Loupedeck-SDK）。这直接印证了 [ADR-0020](../../adr/0020-backend-descriptor-table.md) 与 [ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md) 否决进程内第三方代码插件的正确性。
2. **「只读快照 + 受令牌保护的命令回写」已跑通，但 150ms 文件轮询与单向 URL 是高频交互的天花板**：MenuBarHome 当前靠 `raycast-snapshot.json`（`0.3s` 合并防抖写入）+ `menumijia://` URL + `150ms` 轮询 `lastCommandFeedback` 实现双向通信（`Sources/MijiaCore/RaycastSnapshot.swift:947-956`、`raycast/src/url.ts:57-83`）【源码】。这套零依赖模式对 Raycast/CLI/MCP 足够稳健，但无法承载 Stream Deck 旋钮调节、按键状态实时推送（需订阅态推送而非轮询）或小组件低成本读取。
3. **我们现有的 `raycast/` 扩展只用到了 `@raycast/api` 约 20% 的能力，极具低成本挖潜空间**：它目前仅有 3 个 `view` 命令，缺少高频刚需的 `no-view` 快捷开关/场景命令、`menu-bar` 轻量状态/灯光控制、Raycast AI `tools` 与 `ai.instructions`（像 `extensions/homeassistant` 那样让用户直接在 Raycast AI 中 `@menubarmijia` 控灯），也未补齐 Store 审核所需的 `help.md`、截图与 `platforms` 精确配置（`raycast/package.json:1-68` vs `raycast/extensions:extensions/homeassistant/package.json:596-612`）【源码】。
4. **SwiftBar 协议不适合作为 MenuBarHome「宿主加载第三方脚本」的接口，但极其适合作为 MenuBarHome「向外输出的脚本工具集」**：SwiftBar 靠任意脚本 stdout 文本 + `|` 参数行构建原生 `NSMenu`（`swiftbar/SwiftBar:SwiftBar/MenuBar/MenuLineParameters.swift:18-30`），但它必须通过登录 Shell 任意执行本地脚本（`RunScript.swift:136-144`）【源码】，若由持有钥匙串和米家凭据的 MenuBarHome 宿主直接执行外部插件脚本，会引入严重的权限扩散与系统命令注入面。相反，MenuBarHome 只需让 `scripts/mijia` 支持导出 SwiftBar / Alfred Script Filter 格式，即可零宿主风险接入两者的现成生态。
5. **Stream Deck 集成的核心难点不在按键发送，而在「状态订阅 + 旋钮合并 + 防陈旧渲染」**：`cgiesche/streamdeck-homeassistant` 证明了硬件面板必须有长连接事件订阅（带 `subscriptionGeneration` 防竞态）、异步图标渲染代次守卫（`renderGeneration`）、旋钮 300ms 分桶合并（`dialRotate`）与 300ms 长短按判别（`PluginComponent.vue:143-175, 303-338, 376-491`）【源码】；而 `menumijia://` 单次拉起进程式链接会抢焦点/产生延迟，必须配本地环回 WebSocket / IPC 轻量事件桥。
6. **MCP 设计上，MenuBarHome 的「强类型收敛工具 + 凭据剥离」优于社区重型实现，但缺少传输层与安全注解细化**：HA 官方 `mcp_server` 通过 `ToolAnnotations` 默认最不安全假设（`read_only=False, destructive=True`）并在服务端创建实例时直接剥离非只读工具（`home-assistant/core:homeassistant/helpers/llm.py:191-202`、`mcp_server/server.py:81-83`）【源码】；`ha-mcp`（87 个工具）已踩坑并明确警告 `stdio` 的连接稳定性问题，且用固定 URL 后缀区分 `/catalog/full` 与 `/catalog/search` 以规避客户端不刷新工具列表的缺陷（`homeassistant-ai/ha-mcp:README.md:95`、`src/ha_mcp/tool_catalog.py:1-18`）【源码】；`Do1e/mijia-api` 的 MCP 则直接把 `auth.json` 暴露在 MCP 进程内且无设备安全门（`Do1e/mijia-api:mijiaAPI/mcp_server.py:58-212`）【源码】。我们的 `scripts/mijia-mcp` 安全边界远胜后者，但高风险动作工具注解未标 `destructiveHint`，且仅有 stdio、尚无本地只读/受限 Streamable HTTP 端口与 `read-only` 模式开关。
7. **Windows 11 扩展面的长期正解是 PowerToys CmdPal（WinRT 进程外 COM）+ 既有本地单实例 IPC**：`windows/src-tauri/src/companion.rs:14-31` 已经用 `x-menubarhome-secret` 跑通了带时间预算的本地 HTTP 单实例转发【源码】。在 Windows 上，继续让 `raycast/` 复用 `raycast-snapshot.json`（已支持 `%LOCALAPPDATA%`）的同时，基于 `Microsoft.CommandPalette.Extensions.Toolkit` 提供「冻结（Frozen）缓存的命令桩 + 按需热加载」的 CmdPal 扩展，可让 Win11 用户在不常驻新进程的情况下获得系统级搜索控家体验（`initial-sdk-spec.md:291-419`）【源码】。
8. **在入口优先级上，应先做「零新协议面」的高杠杆收口（加深 `raycast/`、补全 App Intents 参数化、新增 `scripts/mijia alfred`），再视需要补「进程外长连接桥」（Stream Deck / 跨端桌面小组件），最后才考虑硬件/跨宿主适配器**。

---

## 1. Raycast 扩展生态（`raycast/extensions` & `@raycast/api`）

### 1.1 三层机制剖析

- **第一层（定位与形态）**：Raycast 是 macOS / Windows（已扩至 Windows）的原生快速启动器，通过开放 TypeScript + React 生态统一所有第三方生产力工具入口。社区与官方扩展全部集中在单体仓库 `raycast/extensions`，以 PR 审核进入官方 Store。
- **第二层（Manifest 契约与命令模式）**：
  - 扩展清单即 `package.json` 的超集（`raycast/extensions:docs/information/manifest.md:3-26`）【源码】，由 JSON Schema 强校验。核心扩展元数据包含 `name`、`title`、`description`、`icon`（512×512 PNG，支持 `@dark` 变体）、`author`、`platforms`（`["macOS", "Windows"]`）、`categories`、`preferences` 与 `commands`。
  - **三种命令模式**（`manifest.md:64-65`）【源码】：
    1. `view`：推入 Raycast 主导航栈，渲染原生映射的 React 视图（`List`、`Grid`、`Form`、`Detail`）。
    2. `no-view`：默认导出为 `async function`，不打开主界面，直接执行逻辑并用 `showToast`/`showHUD` 反馈，支持参数（`arguments`）与后台周期执行（`interval`）。
    3. `menu-bar`（仅 macOS）：渲染 `<MenuBarExtra>` 驻留菜单栏，同样支持 `interval` 后台刷新。
  - **后台调度与能耗节流**（`docs/information/lifecycle/background-refresh.md:14-78`）【源码】：`no-view` 与 `menu-bar` 可声明 `interval`（文档写最低支持 `10s`，但建议尽量设大；Store 新安装的扩展默认**关闭**后台刷新，必须等用户首次运行或在偏好里显式启用后才激活）。实际调度由 macOS 能效策略决定，超时会被系统强杀。
  - **AI 原生集成（Tools / MCP / Skills / ResourceProvider）**（`manifest.md:42-44, 118-166`）【源码】：扩展可在 `package.json` 声明 `tools`（映射到 `src/tools/<name>.ts`）、`resourceProvider`（`src/read-item.ts`，供 AI Chat `@` 提及检索）、`ai.skills`（遵循 `agentskills.io` 的 `SKILL.md`）乃至直接声明一个 `ai.mcp`（stdio 或 HTTP + OAuth）服务，赋予用户 `@<extension>` 直接对话控制的能力。
  - **Deeplink 与跨命令拉起**（`docs/information/lifecycle/deeplinks.md:8-32`）【源码】：格式为 `raycast://extensions/<author>/<extension>/<command>?launchType=background&arguments=...&context=...`。外部触发 Deeplink 时，Raycast 默认弹确认框防钓鱼（与 MenuBarHome `URLCommandHandler` 的安全逻辑高度一致）。
- **第三层（运行时进程隔离、偏好存储与 Store 审核流水线）**：
  - **进程与隔离模型**（`docs/information/security.md:17-27`）【源码】：Raycast 启动**单个受托管的 Node.js 子进程**（并校验 Node 二进制完整性），通过标准文件句柄与轻量 RPC 协议向原生宿主通信；**每个扩展运行在独立的 V8 Isolate（Worker Thread）中**，拥有隔离的事件循环、JS 引擎实例与受限堆内存，互不拖垮也无法直接操作主进程内存。但需注意：**Node Worker 内并没有做 OS 级文件系统或网络沙盒**——访问受保护目录或屏幕录制受父进程 Raycast 的 macOS TCC 权限约束，而安全存储则通过声明 `type: "password"` 偏好或 `LocalStorage` API 写入本地加密数据库（宿主密钥存 Keychain），做到扩展之间存储隔离。
  - **Store 审核与发布链路**（`docs/basics/prepare-an-extension-for-store.md:11-200`、`.github/workflows/extensions_build_publish.yml:31-69`）【源码】：
    - 强制 MIT 协议、提供 `package-lock.json`（CI 复现锁版本）、`npm run build` 分布构建零报错与 `ray lint` 通过。
    - 强制 Apple Style Guide 标题规范、描述 50–155 字符、禁堆砌关键词、2000×1250 PNG 截图（最多 6 张，使用 `Capture Window` 统一壁纸）、`CHANGELOG.md` 必须使用 `{PR_MERGE_DATE}` 占位符、需额外配置时提供 `help.md`（直接渲染在首次偏好表单旁）与 `README.md`。
    - 合并到主干后，GitHub Actions 在 `macos-26` 上运行 `raycast/github-actions/ray@v1.18.0` 自动编译归档并推送到 Raycast Store，同时自动回帖并给贡献者发奖励。

### 1.2 深度对标：`extensions/homeassistant` vs 我们的 `raycast/`

`raycast/extensions` 中的 `extensions/homeassistant`（`package.json:1-756`）【源码】是一个非常成熟的智能家居扩展样本：
- 它提供了 35+ 个命令，包含多类 `view` 视图（按域拆分 `lights`/`climate`/`covers`/`vacuums`）、`no-view` 动作（`dashboard`、`toggle-ac-menu`、`runService` 支持 `LaunchProps<{ launchContext }>` 无感执行，见 `runService.tsx:6-28`）、以及多个 `menu-bar` 命令（如 `lightsmenu.tsx`、`acmenu.tsx`，`interval: "1m"`）。
- 它同时声明了 3 个 Raycast AI `tools`（`get-entities`、`get-attributes`、`run-service`），并在 JSDoc 中明确教导模型「不要混批不同操作」「先拉实体列表并只拉一次」（`src/tools/get-entities.ts:17-22`、`src/tools/run-service.ts:25-44`）【源码】。
- **缺点也很明显**：它要求用户在 Raycast 加密库里直接填写 Home Assistant 长效令牌和内网/外网 URL，凭据与连接逻辑（WS + mDNS + Ping）在 Node Worker 里重做了一遍，无法共享桌面主控端的设备去重、米家直连和防误触确认。

**对照我们现有的 `raycast/`（[raycast/package.json](../../../raycast/package.json)、[raycast/src/](../../../raycast/src/)）**：
- **优势**：严格遵守 [ADR-0013](../../adr/0013-raycast-companion-contract.md)，零凭据、复用双端主控、支持拼音首字母、三层精确数值边界校验、高风险二次确认与锁屏拦截不绕过。
- **明显差距**：
  1. **缺少 `no-view` 与快捷绑定能力**：目前 3 个命令全为 `mode: "view"`（`search-devices`、`search-scenes`、`ask`）。用户无法直接给「一键全关」「全屋关灯」「运行某场景」或「切换某设备」绑一个全局快捷键或一键静默执行，必须先打开列表或表单。
  2. **缺少 `tools` 与 `ai.instructions`**：Raycast 用户如果开了 Raycast AI，目前无法 `@menubarmijia` 自然语言查状态、调灯光；只要新增 `src/tools/` 复用现有 `snapshot.ts` + `url.ts`（并调用 `publicSnapshot` 剥离 `bridgeToken`），就能零凭据接入 Raycast AI。
  3. **缺少 `preferences` 内的 `help.md` 与 `menu-bar` 轻量开关（可选）**：目前未提供 `help.md`，也未准备 2000×1250 截图和 `{PR_MERGE_DATE}` 格式 `CHANGELOG.md`，且 `package.json` 的 `author: "jryang1997"`（注意仓库 `AGENTS.md` 已停用该账号，应核对 Raycast Store handle）、`icon.png` 缺少 `@dark` 变体与 Store 上架合规性检查。
  4. **交互粒度与反馈方式可再精细**：`search-devices.tsx:6-8` 把亮度、色温、风速硬编码为有限步进菜单；但借助 `Action.Push` 或 `LaunchContext` 参数化 `no-view` 命令，以及支持 `Toast.Style.Animated` 执行态提示（目前 `runCommandWithToast` 只有执行完才弹 Toast，`url.ts:41-51`），响应感会好很多。

---

## 2. SwiftBar / xbar：脚本 stdout 协议与轻量插件模式

### 2.1 三层机制剖析

- **第一层（定位与形态）**：SwiftBar 是 macOS 原生菜单栏脚本宿主（BitBar / xbar 继承者），核心哲学是「**任何语言写的脚本只要往 stdout 打印文本，就能变成一个菜单栏插件**」。
- **第二层（文本协议与元数据头）**：
  - **行协议（`MenuLineParameters`）**（`swiftbar/SwiftBar:SwiftBar/MenuBar/MenuLineParameters.swift:18-129, 206-249`）【源码】：
    - `---` 以上为状态栏标题区（多行自动每 5 秒轮播，见 `MenuBarItem.swift:37`），`---` 以下为下拉菜单树（`--` 表示子菜单层级）。
    - 每行以 `|` 分隔「展示文本」与 `key=value` 参数表（手写状态机解析带引号与转义的值）。核心交互参数：`href=`（打开 URL 或弹窗 WebView）、`bash=` / `shell=` + `param1..N`（点击执行脚本）、`terminal=true|false`、`refresh=true`、`stdin=`（向长驻流式进程喂入一行输入）、`sfimage=`/`sfconfig=`（JSON 编码的 SF Symbols 渲染配置）。
  - **元数据头（`PluginMetadata`）**（`SwiftBar/Plugin/PluginMetadata.swift:37-220`）【源码】：解析脚本注释中的 XML 标签：
    - `<xbar.var>string|number|boolean|select(VAR="default"): desc [opt1,opt2]</xbar.var>`：声明强类型变量，由宿主自动生成配置 UI 并作为环境变量注入脚本。
    - `<swiftbar.type>Streamable</swiftbar.type>`、`<swiftbar.schedule>* * * * *</swiftbar.schedule>`（SwifCron 表达式，或用文件名 `plugin.10s.py` 声明周期）、`<swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>`、`<swiftbar.environment>[K=V]</swiftbar.environment>`。
  - **四种插件类型**（`Plugin.swift:9-14`）：`Executable`（定时拉起一次性脚本）、`Streamable`（长驻子进程，stdout 以 `~~~` 分隔帧实时刷新，支持双向 `stdin`）、`Shortcut`（触发 Apple Shortcuts）、`Ephemeral`（URL Scheme 动态创建的临时插件）。
- **第三层（调度、并发与进程生命周期）**：
  - **文件同步与 `.swiftbar` 包机制**（`PluginManger.swift:10-248`）【源码】：通过文件大小 + 修改时间比对同步脚本，并支持 `.swiftbar` 目录包（主入口为 `plugin.*`，执行时将 `Process.currentDirectoryURL` 设为包目录，便于携带虚拟环境或资源）。
  - **定时与唤醒退避调度（`RunPluginOperation`）**（`PluginUtilities.swift:128-250`、`ExecutablePlugin.swift:83-195`）【源码】：每次定时或手动刷新都在主队列分配递增的 `timerGeneration`，只有当前代次匹配且未取消才会执行；若在唤醒后刷新失败，启动指数退避重试链，期间不占用 `OperationQueue` 槽位，且把定时器重装权移交给后继重试任务，防止短周期定时器打断退避窗口。
  - **流式插件管道与强杀兜底**（`StreamablePlugin.swift:8-39, 130-190`、`RunScript.swift:7-55`）【源码】：`UTF8ChunkDecoder` 处理跨块多字节 UTF-8 截断；`StreamContentParser` 按 `\n` 与 `~~~` 切帧并支持尾随/前置分隔符模式；停止或重启旧流时先关闭 `stdin`、发 `SIGTERM`，并在 1 秒后若仍在运行则强制 `SIGKILL`（精准捕获 `previous` 实例引用，绝不误杀已换上的新进程）。
  - **Shell 包装执行**：默认走登录 Shell `-l -c`（`RunScript.swift:136-144`）以继承用户 `PATH` 和环境变量，可由 `<swiftbar.runInBash>false</swiftbar.runInBash>` 绕过直接 `exec`。

### 2.2 能否作为 MenuBarHome 的轻量扩展口？

**结论：不能让 MenuBarHome 作为 SwiftBar 宿主去执行第三方脚本，但应反向让 `scripts/mijia` 成为 SwiftBar 的「零成本数据源与动作生产者」**【推断 + 源码】：
1. **安全与公证边界（为什么不能内嵌执行）**：SwiftBar 本身就是通用脚本启动器，用户对「脚本有我的 Shell 全权限」有心理预期；但 MenuBarHome 持有用户的**米家会话、HA 长效令牌、局域网设备 Token**，且在 macOS 下没有付费开发者公证，一旦在 App 进程内引入类似 `runScript` 的任意脚本目录扫描和登录 Shell 执行，等于给任意下载脚本开辟直通核心资产的横向通道，且与 [ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md) 第 1 条「不做第三方代码插件」正面冲突。
2. **协议表现力局限**：SwiftBar 协议面向 `NSMenu` 纯文本列表，不支持 MenuBarHome 主打的滑条（亮度/色温/窗帘开合度）、温控步进卡片、实时摄像机小窗和 Fluent 2 / 液态玻璃交互。
3. **正确借鉴点**：
   - 借鉴其 **`StreamablePlugin` 的代次防错与 `SIGTERM → 1s → SIGKILL` 回收模型**，强化我们 Windows/macOS 伴生进程（如未来的 go2rtc 或本地适配器）生命周期管理。
   - **反向接入 SwiftBar 生态**：只要在 `scripts/mijia` 增加一个不到 80 行的 `mijia swiftbar` 子命令（读 `raycast-snapshot.json` 输出设备菜单文本，点击项用 `href="menumijia://..."` 或 `bash=".../mijia" param1=toggle ... terminal=false refresh=true`），不改宿主一行代码，SwiftBar 用户就能把任意房间/设备直接钉在系统菜单栏上。

---

## 3. 桌面自动化与微组件生态（Alfred / Hammerspoon / Übersicht / PowerToys CmdPal）

### 3.1 Alfred Workflows（Script Filter JSON 协议）

- **协议核心**（【文档】https://www.alfredapp.com/help/workflows/inputs/script-filter/json/）：
  - **按需拉起 + 声明式渲染**：用户在 Alfred 敲关键词时才拉起一次外部脚本（任意语言），脚本输出单个 JSON 对象 `{ items: [...] }` 即退出，**零常驻内存开销**。
  - **交互与状态机制**：
    - `uid` + 宿主 Frecency 学习：提供 `uid` 时 Alfred 自动把常用设备排在前面；需要固定排序（如按房间/收藏）可设 `skipknowledge: true`。
    - `mods`（修饰键覆写）：同一条设备项，直接回车（`arg`）开关、按住 `⌘` 进详情（`focus`）、按住 `⌥` 调亮度/温度，天然契合智能家居「同设备多动作」。
    - `rerun`（`0.1`–`5.0` 秒）+ 顶层 `variables`：窗口打开期间自动重跑脚本并透传状态变量，实现「触发后原地等 `lastCommandFeedback` 刷新结果图标」而无需常驻守护进程。
    - `cache.seconds`：由宿主缓存慢查询结果，毫秒级首屏渲染。
- **对我们的启发**：`scripts/mijia` 只需加一个 `mijia alfred [--room ...]` 子命令读取 `raycast-snapshot.json` 输出 Script Filter JSON（带 `mods` 区分 `power`/`focus`），即可一行命令打包出完整的 `.alfredworkflow`，复用拼音首字母匹配和零凭据安全模型。

### 3.2 Hammerspoon Spoons & `urlevent`

- **机制剖析**（`Hammerspoon/hammerspoon:extensions/urlevent/urlevent.lua:1-135`）【源码】：
  - Hammerspoon 是基于嵌入式 Lua 运行时的 macOS 自动化中枢，**Spoon** 是其标准化的 Lua 插件包格式（`init.lua` + `docs.json`）。
  - 其 `hs.urlevent` 暴露 `hammerspoon://<eventName>?k=v`，并向回调传递 **`senderPID`**（方便按调用方来源做策略区分），但源码明确注释了一个关键限制（`urlevent.lua:11-15`）：**`urlevent` 无法向调用方返回任何数据**，且冷启动时会丢失首条未绑定回调的 URL；需要双向返回必须改用 `hs.ipc`（Mach Port / CLI）。
- **对照 MenuBarHome**：我们通过 `lastCommandFeedback` 写回 `raycast-snapshot.json` 解决了 URL Scheme 单向无返回的问题（`URLCommandHandler.swift:646-668`），并且靠 `waitForInitialSnapshot()`（`URLCommandHandler.swift:134-139`）解决了冷启动首条 URL 丢失的问题。但我们目前**没有利用调用方身份/来源区分**（macOS `NSAppleEventDescriptor` / 进程上下文无法可靠覆盖浏览器跳转，所以我们用 `bridgeToken` 解决同用户授权，这是更可靠的做法）。

### 3.3 Übersicht 桌面小组件

- **机制剖析**（`felixhageloh/uebersicht:server/src/VirtualDomWidget.js:10-120`、`server/src/runShellCommand.js:1-38`）【源码】：
  - Übersicht 在桌面上层嵌入透明 WebView，通过本地 Node HTTP/WebSocket 服务驱动 React VirtualDOM Widget：每个 Widget 声明 `command`（字符串命令或 JS 函数）、`refreshFrequency`（毫秒）、`updateState` 与 `render`。
  - **高危反面教材**：`runShellCommand.js:7-36` 在本地 HTTP 服务器暴露 `POST /run/` 路由，**直接把 HTTP 请求体喂给 `spawn('bash', ['-l'])` 的 stdin 执行**。这对纯本机美化工具或许可接受，但放在管理家庭门锁/插座/电源的智能家居软件中是灾难性的——任何本地网页或未隔离脚本都能通过该端点执行任意 Shell。
- **对我们的启发**：桌面小组件只适合消费 **Layer 2 只读快照**（例如 Übersicht Widget 直接读 `raycast-snapshot.json` 或 macOS 原生 WidgetKit App Group 快照，点击按钮走带确认的 `menumijia://`），绝不能开放未鉴权的本地指令/Shell 执行 HTTP 接口。

### 3.4 Microsoft PowerToys Command Palette（WinRT 进程外 COM）

- **三层机制剖析**（`microsoft/PowerToys:src/modules/cmdpal/`）：
  - **发现与隔离（`.appxmanifest` + WinRT over COM）**（`doc/initial-sdk-spec/initial-sdk-spec.md:170-267`、`ExtensionServer.cs:17-54`）【源码】：扩展作为独立进程（支持 MSIX 包通过 `AppExtensionCatalog` 查询 `com.microsoft.commandpalette` 发现，也支持非打包应用通过特定注册表键声明 CLSID），宿主通过 `CoCreateInstance` 拉起扩展的 `IExtension` WinRT 接口；扩展侧借助 `StrategyBasedComWrappers` + `CoRegisterClassObject(..., CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE | REGCLS_SUSPENDED)` 暴露本地进程外 COM 服务。
  - **接口契约（IDL 强类型）**（`Microsoft.CommandPalette.Extensions.idl:10-145`）【源码】：定义 `IExtension` → `ICommandProvider` → `IInvokableCommand` / `IPage` / `IFilters`，并通过 `INotifyPropChanged` / `INotifyItemsChanged` 实现跨进程事件推送。值得注意的是 `CommandResultKind` 原生内建了 `ShowToast` 与 **`Confirm`**（`IConfirmationArgs`，含 `IsPrimaryCommandCritical` 危险标记，IDL 第 68-114 行）——**高风险二次确认是 SDK 的一等公民**！
  - **「冻结缓存 + 懒热身」生命周期**（`initial-sdk-spec.md:282-419`）【源码】：为了不让用户装 10 个扩展就常驻 10 个进程，CmdPal 引入 `Frozen=true` 机制——初次加载后将扩展的顶层命令树（`pfn`、`clsid`、`id`、`title`、`subtitle`）落盘缓存为轻量 **Stub（桩项）** 并释放 COM 实例；冷启动先展示桩项，等用户真正点击该桩项时才通过 COM 懒拉起扩展进程（"reheating"）。动态状态类扩展可标为 `Frozen=false`（Fresh）。
  - **严格 URI 激活流水线**（`doc/command-links.md:48-150`）【源码】：`x-cmdpal://` 将路由严格划分为「内置安全导航白名单（无需确认）」与「触发扩展行为的路由（需 Consent 确认，排队上限 16、合并重复项）」，并执行 **250ms 超时显示可取消加载框 → 授权 → 派发前再次重校验命令/包身份/缓存形态**。
- **对 MenuBarHome（Windows 11）的价值**：Windows 版 MenuBarHome 已经解决了托盘双悬浮岛与单实例 IPC，但在 Windows 全局入口上，用户只能按 `Alt+M`。如果我们未来为 Windows 提供一个轻量的 PowerToys CmdPal 扩展（或直接让桌面应用自身在用户开启集成时注册一个 Out-of-Proc COM Provider），就能把「搜设备、开关、调温、执行场景」原生塞进 Windows 11 的 PowerToys Command Palette（微软正在推进的 Windows 新一代启动器），且直接复用 `ConfirmableCommand` 对齐高风险确认语义。

---

## 4. 硬件控制面：Stream Deck SDK、Loupedeck 与 HA 实践

### 4.1 Elgato Stream Deck SDK vs Loupedeck / Logi SDK

| 维度 | Elgato Stream Deck SDK（`elgatosf/streamdeck`） | Loupedeck / Logi Plugin SDK |
| :--- | :--- | :--- |
| **执行隔离模型** | **进程外子进程 + 本地 WebSocket**（`connection.ts:67-75`，`ws://127.0.0.1:<port>`，CLI 传入 `-port -pluginUUID -registerEvent -info`）【源码】 | **进程内动态加载 C# `.NET` DLL** 到宿主服务进程【检索】 |
| **语言与生态** | 语言无关（协议为 JSON over WS），官方第一方 SDK 主推 Node.js/TypeScript（`@elgato/streamdeck` + `.sdPlugin` bundle）【源码】 | 强绑定 C# / .NET【检索】 |
| **故障域** | 插件崩溃/内存泄漏不影响 Stream Deck 宿主；宿主重启或重连即可恢复【源码】 | 未捕获异常或内存泄漏直接拖垮整个硬件控制宿主【检索】 |
| **旋钮 / 触控支持** | `Controllers: ["Keypad", "Encoder"]`，`dialRotate` / `dialDown` / `touchTap` + 声明式 JSON Touch Strip Layout（如 `$A0`/`$A1`）【源码】 | 原生围绕旋钮 `Turn`（含加速度）与触控屏设计，无序列化开销，高频响应略占优【检索】 |
| **配置 UI** | 独立的 HTML5 WebView（**Property Inspector** `pi.html`），通过宿主中转的 WebSocket 与插件后台双向通信及读写 `GlobalSettings`/`Settings`【源码】 | 依赖 SDK Hook 或原生配置界面【检索】 |

### 4.2 两种 Home Assistant Stream Deck 实操范式

1. **官方软件内嵌插件范式：`cgiesche/streamdeck-homeassistant`（Vue 3 + WebSocket + SVG 栅格化）**【源码】：
   - **按页订阅与竞态消除**（`PluginComponent.vue:121-141, 303-338`）：只在 `willAppear` 时收集可见按键的 `entityId`，`willDisappear` 时剔除并重算；`resubscribeEntities()` 维护递增的 `subscriptionGeneration`，防止旧的异步订阅覆盖新的订阅列表；若发生认证错误（`isAuthError`）则立刻停止重连退避并标红叹号，等待用户在 Property Inspector 更新令牌（第 266-276 行）。
   - **防陈旧渲染代次（`renderGeneration`）**（第 375-491 行）：由于拉取设备封面图（`fetchEntityPictureAsDataUri`）和将动态 SVG 转为 Canvas Data URI 是异步的，每个按键上下文维护自增 `renderGeneration`，任何异步步骤返回前校验 `isStale()`，防止网络慢导致的旧状态覆写新状态。
   - **旋钮分桶与长短按**（第 143-175, 493-523 行）：`dialRotate` 按 `rotationTickBucketSizeMs = 300ms` 累积刻度后再调一次服务，避免物理旋钮一格一发请求打爆设备；按键通过 `buttonDown`/`buttonUp` + 300ms `setTimeout` 区分短按与长按。
   - **内置动作扩展**：甚至支持 `streamdeck.open_url`（第 538-545 行），可触发自定义 URL Scheme。
2. **脱离官方软件的独立守护进程范式：`basnijholt/home-assistant-streamdeck-yaml`**【源码】：
   - 用 Python `StreamDeck`（HID 驱动）+ `websockets` + `Jinja2` + `PIL` 直接通过 USB HID 接管物理设备（`home_assistant_streamdeck_yaml.py:1-180`），配置全写在带 Pydantic 校验的 YAML 中。
   - **适用场景**：无头 Linux / NAS / Docker，或者不想受 Elgato 客户端捆绑的用户；**局限**：会独占 USB HID 句柄，与官方 Stream Deck 软件互斥，不适合普通桌面用户日常桌面切 Profile 的使用习惯。

**对 MenuBarHome 的启示**：
- 如果普通用户要在桌面用 Stream Deck 控制米家/HA，**Elgato 标准 `.sdPlugin`（Node.js / WebSocket）才是正确形态**。
- 但如果插件通过 `menumijia://` URL 调 MenuBarHome，会遇到三个硬伤：① 每转一格旋钮或按一下键都要走 OS URL 拉起链路；② 无法接收实时状态变更推送（只能疯狂轮询 `raycast-snapshot.json`）；③ 即使加了 `bridgeToken` 不弹窗口，在 Windows/macOS 高频调光时进程转发开销也很大。因此 Stream Deck 插件需要 **Layer 5 本地环回 WebSocket / IPC 桥** 才能做到与 `streamdeck-homeassistant` 同等丝滑。

---

## 5. MCP 智能家居生态对比与工具设计

### 5.1 三种典型实现的三层源码对比

| 维度 | HA 官方 `mcp_server`（`home-assistant/core`） | 社区重型 `ha-mcp`（`homeassistant-ai/ha-mcp`） | 社区直连 `Do1e/mijia-api` MCP | **MenuBarHome `scripts/mijia-mcp`** |
| :--- | :--- | :--- | :--- | :--- |
| **定位与规模** | 复用 HA 既有 `AssistAPI` / `IntentTool` / `ActionTool`（`llm.py:391-450, 824-892`）【源码】 | 87 个全能工具，覆盖实体控制、配置流、自动化/仪表盘 YAML、备份与最佳实践指南（`README.md:11`）【源码】 | 10 余个原生 Python 工具直调米家云端接口（`mcp_server.py:74-250+`）【源码】 | 11 个强收敛工具 + 3 个只读资源（`scripts/mijia:872-1263`）【源码】 |
| **传输层** | **Streamable HTTP**（`/api/mcp` 无状态请求响应）+ 旧 SSE（`http.py:8-27`）【源码】 | Streamable HTTP 为主，**明确警示 `stdio` 有连接挂起等已知传输问题（#1713）**（`README.md:95`）【源码】 | `FastMCP`（默认 stdio）【源码】 | 仅 **stdio JSON-RPC 2.0**（同时兼容 `Content-Length` 与 NDJSON 行帧，`scripts/mijia:1433-1520`）【源码】 |
| **凭据与安全模型** | 运行在 HA 进程内；`require_admin` 校验管理员身份；`read_only` 模式在构建 `APIInstance` 时直接剔除写工具（`server.py:81-83`）【源码】 | 需传入 HA 管理员 Long-Lived Token 或 Secret URL；支持 `/readonly` 后缀与 OIDC【源码】 | **MCP 进程直接持有 `auth.json` 登录态并执行 `_refresh_token`**；无高风险确认、无锁屏隔离（`mcp_server.py:45-71`）【源码】 | **零凭据**：只读 `0600` 快照并剥离 `bridgeToken`，写操作全走应用内 `URLCommandHandler`（锁屏 + 能力门 + 高风险弹窗）（`scripts/mijia:130-132, 925-936`）【源码】 |
| **ToolAnnotations 与安全默认** | `ToolAnnotations` 默认最不安全假设：`read_only=False, destructive=True, idempotent=False, open_world=True`（`llm.py:191-202`）【源码】 | 工具独立标注 `read_only_hints` 等（`server.py:46`）【源码】 | 未显式配置细粒度安全注解【源码】 | 已配 `readOnlyHint`/`idempotentHint`，但**高风险/全关等写工具 `destructiveHint` 全设为 `false`**（`scripts/mijia:1067-1084`）【源码】 |
| **上下文与性能治理** | 暴露 `homeassistant://assist/context-snapshot` 资源，支持 `io.home-assistant/device_id` 元数据做区域就近匹配（`server.py:28-31, 103-109`）【源码】 | **懒加载工具模块**；**固定 URL 分流 `/catalog/full` 与 `/catalog/search`**（因客户端不动态刷新工具列表，小上下文客户端改用搜索发现工具）（`tool_catalog.py:1-18`）【源码】 | `get_device_spec` 先拉 MIoT 规格再 `set_device_property`，两步发现但可能返回长尾冗余属性【源码】 | 快照已由主应用预合成并带中文/拼音索引与能力区间（`minKelvin/maxKelvin/minTemp/maxTemp`），CLI 侧直接做前置严格校验，不浪费 LLM 轮次【源码】 |

### 5.2 我们 `scripts/mijia-mcp` 的核心发现

1. **安全设计显著领先同类米家 MCP**：`Do1e/mijia-api` 把 `auth.json` 和设备控制直权交给 MCP 进程，模型一旦产生幻觉调用 `set_device_property` 或误触插座/取暖器/扫地机，没有任何拦截；MenuBarHome 将状态合成、能力裁切（[ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md) 第 4 条）、锁屏拦截、高风险二次确认全部收口在宿主 App 内，MCP 层仅做无凭据投影与严格参数校验，是非常稳健的架构。
2. **三个可立刻改进的细节**：
   - **注解与只读开关**：`CONTROL_NON_IDEMPOTENT_ANNOTATIONS` 与 `CONTROL_IDEMPOTENT_ANNOTATIONS`（`scripts/mijia:1073-1084`）把 `destructiveHint` 统一写死为 `false`；参考 HA `ToolAnnotations` 的严谨态度，至少对支持触发 `allOff` 的 `run_scene` 与无约束的 `ask_home` 标为或提示潜在破坏性，并参照 HA `CONF_READ_ONLY` 为 `mijia-mcp` 增加 `--read-only` 启动参数（只暴露 `list_devices`、`get_home_status`、`focus_device` 与只读 Resources），方便只做家居状态问答的 AI 客户端最小授权。
   - **传输与执行延迟**：`scripts/mijia` 当前在 `tools/call` 时每次执行都会调用 `open(url)` + 150ms 间隔轮询文件等待反馈（`scripts/mijia:350-366`）。短时多步调用（例如「把客厅三盏灯分别调成不同色温」）会连弹多次系统 URL 调度。
   - **缺少高频复合/批操作提示与 Prompt 模板**：HA 官方 `mcp_server` 提供 `prompts/list` & `prompts/get` 暴露系统提示词（`server.py:111-144`），帮助接入方 LLM 理解设备语义；而我们的 `prompts/list` 目前返回空数组（`scripts/mijia:1334-1335`），仅靠 `initialize.instructions` 承载规则。

---

## 6. 落到 MenuBarHome：五层「对外扩展面」演进蓝图

结合 [ADR-0013](../../adr/0013-raycast-companion-contract.md)、[ADR-0020](../../adr/0020-backend-descriptor-table.md) 与 [ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md) 确立的边界（**宿主独占凭据、设备合成、能力门与安全守卫；拒绝进程内第三方代码插件**），建议将 MenuBarHome 的外部扩展面明确划分为五层架构：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    MenuBarHome 宿主（macOS Swift / Win11 Tauri）            │
│  凭据Vault / 米家+HA连接 / DeviceDeduplicator / 能力写入门 / 锁屏&高风险确认  │
└───────▲──────────────────────┬───────────────────────▲──────────────────┘
        │ L1: 命令入口           │ L2: 只读状态投影         │ L5: 本地实时桥(按需)
        │ menumijia://          │ raycast-snapshot.json  │ 127.0.0.1 WS/IPC
        │ (or AppIntents)       │ (0600, 剥离敏感凭据)      │ (x-menubarhome-secret)
┌───────┴─────────┐    ┌────────┴─────────┐    ┌───────┴──────────────────┐
│ 外部触发器/快捷指令 │    │ L3: MCP Server   │    │ L4/L5: 伴生宿主与硬件面板  │
│ 网页/Shortcuts/  │    │ scripts/mijia-mcp│    │ Raycast / Alfred /       │
│ URI 书签         │    │ (--read-only /   │    │ SwiftBar / Win11 CmdPal /│
│                 │    │  Streamable HTTP)│    │ Stream Deck 插件         │
└─────────────────┘    └──────────────────┘    └──────────────────────────┘
```

### 各层定位、安全模型与工程成本

| 分层 | 协议与载体 | 核心能力与适用场景 | 安全模型（不妥协底线） | 维护与演进成本 |
| :--- | :--- | :--- | :--- | :--- |
| **L1：URL Scheme & 系统 Intents** | `menumijia://` / `menubarhome://`（`AppURLCommand.swift`、`companion.rs`）+ macOS `AppIntents` | 单向命令触发、快捷指令、Siri、焦点定位（`focus`）、带 `requestId` 的异步命令 | **零隐式信任**：无有效 `bridgeToken` 的外部链接必须弹确认窗（除非用户显式全局开启直控）；进入 `HomeStore` 后强制走能力写入门、锁屏拦截、高风险二次确认 | **极低（已就位）**。需补齐 `AppIntents` 精确控光/调温/场景，Windows 侧暂无系统级等同物 |
| **L2：只读本地快照** | `raycast-snapshot.json`（macOS `0600`、Windows `%LOCALAPPDATA%`） | 设备列表、中文拼音索引、能力边界（`minKelvin`/`minTemp`/`availablePresetModes`）、环境读数与 `lastCommandFeedback` | **凭据隔离 + 最小可见集**：不导出任何米家/HA 凭据；受 [ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md) 设备类型开关裁切；关闭集成即原子删除并递增 `companionGeneration` 作废令牌 | **低（已就位）**。仅需按需增补快照字段（升 `schemaVersion`）及剥离/保护 `bridgeToken` 给只读消费方 |
| **L3：MCP 语义工具层** | `scripts/mijia-mcp`（当前 stdio，可扩本地可选 Streamable HTTP） | AI 桌面客户端（Claude/Cursor/Raycast AI）查询与受控操作 | **宿主代理执行 + `bridgeToken` 剥离**：所有 JSON 返回必经 `public_snapshot`；新增 `--read-only` 模式；完善 `destructiveHint` 与 `prompts/get` 家居指令上下文 | **低–中**。纯 Python 零三方依赖继续守住跨平台一致性 |
| **L4：无常驻伴生插件层** | Raycast 扩展、Alfred Script Filter、SwiftBar 导出器、Windows PowerToys CmdPal（Frozen Stub） | 借助成熟桌面启动器/菜单栏生态承接高频快捷键、搜索、AI `@` 提及与轻量菜单 | **外部进程自隔离**：Raycast 跑在 V8 Isolate；Alfred/SwiftBar 由宿主按需拉起；CmdPal 跑独立进程外 COM；全部只消费 L2 快照并发起 L1（或 L5）控制，**宿主不执行任何第三方脚本** | **低–中**。Raycast 加深为 S–M；`mijia alfred/swiftbar` 为 S；CmdPal 扩展为 M |
| **L5：进程外长连接适配器（按需开启）** | Loopback HTTP + WebSocket（借鉴 `companion.rs` 的 `ipc-endpoint.json` + `x-menubarhome-secret`）/ UDS | 解决 L1+L2 的两项硬瓶颈：① **实时推送**（Stream Deck 按键亮灭同步、桌面实时小组件）；② **免 OS URL 调度的高频连续调节**（旋钮、滑条）与未来第三方设备源桥接（[ADR-0020](../../adr/0020-backend-descriptor-table.md) 重启条件） | **本地回环强鉴权 + 最小权限**：仅绑定 `127.0.0.1` 随机端口或 `0600` UDS；鉴权密钥从不落入快照可读字段或单独分权签发（只读订阅 token vs 控制 token）；仍强制经过宿主统一写入门与高风险确认 | **中–高（M–L）**。需要双端对等实现，且需配合独立 `ADR` 界定本地接口契约与限流 |

> **关键安全辨析（L2 `bridgeToken` 的权限收口）**：目前任何能读本机 `raycast-snapshot.json`（`0600`）的同用户进程都能拿到 `bridgeToken` 从而跳过外部链接弹窗。对于只读展示类插件（如桌面 Widget、SwiftBar 状态展示），应引导走不依赖 `bridgeToken` 的只读视角；若未来演进到 L5 本地 HTTP/WS，建议将「只读事件流订阅」与「设备写控制」拆分成不同能力开关或独立会话校验。

### 外部入口优先级排序

1. **P0（最高优先级，立即可做）**：**深化既有 `raycast/` 扩展 + `AppIntents` 补齐**。用户基数大、零新协议风险、全复用已有 L1/L2 契约。
2. **P1（高性价比生态扩面）**：**`scripts/mijia` 原生输出 Alfred Script Filter & SwiftBar 协议 + `mijia-mcp` 安全注解/`--read-only` 补强**。无需修改主应用二进制，几十行 Python 即可覆盖两大 macOS 老牌极客入口并加固 MCP。
3. **P2（跨平台与硬件刚需时启动）**：**L5 本地 WebSocket/HTTP 状态与控制桥 → 支撑 Elgato Stream Deck `.sdPlugin` 与 Windows 11 PowerToys CmdPal 扩展**。由于涉及新增本机网络监听端口与控制传输层（触及高风险面 1/2），必须另立 ADR 后实施。
4. **P3（远期/锦上添花）**：**macOS WidgetKit 桌面小组件 / 独立硬件 HID 守护进程（如无官方软件的 Linux/Stream Deck Python 桥）**。macOS 自带 WidgetKit 需申请 App Group 共享容器与签名配置（对未加入付费 Apple Developer 计划的本项目存在现实签名阻碍，见 `README.zh-CN.md:90`），优先级低于桌面伴生扩展。

---

## 7. 对照我们：差距表

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| :--- | :--- | :--- | :--- | :---: |
| [raycast/package.json](../../../raycast/package.json)<br>[raycast/src/](../../../raycast/src/) | 仅 3 个 `view` 命令；无 `no-view`、无 `menu-bar`、无 AI `tools`、无 `help.md` 与截图；`author` 仍为停用旧名 `jryang1997` | `raycast/extensions`（`extensions/homeassistant`）：`no-view` 静默命令（支持 `LaunchContext`）+ `menu-bar` + `tools` + `ai.instructions` + `help.md` | 新增 `run-quick-action`（`no-view`）、`devices-menu`（`menu-bar`，可选开关）、AI `tools`（`list-devices`/`control-device`/`run-scene`）；补齐 `help.md`、`@dark` 图标与 Store 规范检查（修正 `author`） | **M** |
| [raycast/src/url.ts](../../../raycast/src/url.ts)<br>[raycast/src/search-devices.tsx](../../../raycast/src/search-devices.tsx) | 发令后死等 150ms 轮询写回结果才弹 Toast；亮度/色温固定阶梯选项 | `@raycast/api`：`Toast.Style.Animated` 即时反馈 + `useCachedPromise` 本地瞬时渲染 | 点击动作先弹 `Animated` Toast「正在执行…」，拿到 `lastCommandFeedback` 再原地更新为 Success/Failure；常用设备支持 Action 置顶或 `LaunchContext` 直达 | **S** |
| [scripts/mijia](../../../scripts/mijia)<br>[scripts/mijia-mcp](../../../scripts/mijia-mcp) | `mijia-mcp` 仅支持 stdio；写工具 `destructiveHint` 全 `false`；无 `--read-only`；`prompts/list` 为空；无 Alfred/SwiftBar 输出子命令 | HA `mcp_server`（`ToolAnnotations` 保守默认、`read_only` 剥离写工具、`prompts` 引导）、`ha-mcp`（指出 stdio 脆弱性并推 Streamable HTTP）、Alfred Script Filter JSON | ① 为 `mijia-mcp` 增加 `--read-only` 与更准确的 `destructiveHint`（`run_scene` 含 `allOff` / `ask_home`）、填充 `prompts/list` 提供家居语义提示；② 新增 `mijia alfred` 与 `mijia swiftbar` 只读/URL 输出子命令 | **S** |
| [Sources/MenuBarMijiaApp/AppIntents.swift](../../../Sources/MenuBarMijiaApp/AppIntents.swift) | 仅 4 个 Intent（`ToggleDevice`、`RunScene`、`AskAssistant`、`GetRoomClimate`），缺少按值调节（亮度/色温/空调温度/风扇）与内置快捷动作执行 | 对齐 [ADR-0013](../../adr/0013-raycast-companion-contract.md) 已落地的精确值契约与 `BuiltInURLScene` | 补齐 `SetBrightnessIntent`、`SetTemperatureIntent`、`RunQuickActionIntent`，全部复用 `HomeStore` 执行口与安全守卫 | **S** |
| [Sources/MijiaCore/AppURLCommand.swift](../../../Sources/MijiaCore/AppURLCommand.swift)<br>[Sources/MijiaCore/RaycastSnapshot.swift](../../../Sources/MijiaCore/RaycastSnapshot.swift)<br>[Sources/MenuBarMijiaApp/URLCommandHandler.swift](../../../Sources/MenuBarMijiaApp/URLCommandHandler.swift) | 依赖 OS URL Scheme + 单文件快照轮询实现 IPC，无实时事件推送、高频旋钮调光开销大 | Stream Deck WS（`willAppear` 精准订阅 + `dialRotate` 300ms 分桶）+ PowerToys `x-cmdpal://` 队列上限与重校验 + Windows `companion.rs` 本地环回 HTTP | 保持 L1/L2 契约稳定；后续评估新增 **L5 本地环回 WS/HTTP 桥**（独立 Token 与限流），支撑 Stream Deck 插件与未来独立 MCP HTTP 传输 | **L** |
| [windows/src-tauri/src/companion.rs](../../../windows/src-tauri/src/companion.rs) | 已实现带 `x-menubarhome-secret` 的本地 HTTP 单实例转发与 `raycast-snapshot.json` 原子写入，但仅用于内部转发与 Raycast/CLI，未接入 Windows 原生启动器生态 | Microsoft PowerToys CmdPal（WinRT out-of-proc COM + `Frozen` 桩缓存 + `ConfirmableCommand`） | 中远期基于 `Microsoft.CommandPalette.Extensions.Toolkit` 构建 Windows 伴生扩展，读同一份 `%LOCALAPPDATA%\MenuBarMijia\raycast-snapshot.json` 并通过本地 IPC/URI 转发指令 | **M** |

---

## 8. 推进清单

### P0-1：深化 `raycast/` 扩展（`no-view` 快捷指令、AI Tools 与 Store 合规）
- **价值**：让 Raycast 用户能绑全局快捷键一键开关/执行场景，并在 Raycast AI 对话中直接 `@menubarmijia` 控家，同时具备提审 Raycast Store 的条件。
- **成本**：M（全在 `raycast/` 目录内，不触及主程序核心安全模块）。
- **优先级**：P0
- **涉及高风险面？**：否（仍只读 `raycast-snapshot.json` 并走已有 `menumijia://` 路径；不涉及凭据或控制门变更，按仓库交付分流可直接验证后推 `main`）。
- **依据**：`raycast/package.json:12-34`、`raycast/extensions:extensions/homeassistant/package.json:142-155, 596-612`、`raycast/extensions:docs/basics/prepare-an-extension-for-store.md:11-200`【源码】。

### P0-2：`scripts/mijia-mcp` 安全注解修正、`--read-only` 模式与执行态 UX 优化
- **价值**：修复写工具 `destructiveHint` 乐观标记问题，补齐面向只读 AI 会话的最小授权隔离，并在 `raycast/src/url.ts` 补充 `Animated` Toast 消除 0.3–1s 静默等待感。
- **成本**：S
- **优先级**：P0
- **涉及高风险面？**：否（MCP 工具只收紧权限注解与增设只读过滤，不放宽控制边界）。
- **依据**：`scripts/mijia:1067-1263`、`home-assistant/core:homeassistant/helpers/llm.py:191-202`、`home-assistant/core:homeassistant/components/mcp_server/server.py:81-83`【源码】。

### P1-1：`scripts/mijia` 增加 `alfred` 与 `swiftbar` 无宿主风险输出命令
- **价值**：用不到 150 行纯 Python 零依赖代码，把 MenuBarHome 既有状态与 `menumijia://` 能力直接接入 Alfred 与 SwiftBar 两大 macOS 成熟生态，主应用零侵入、零凭据暴露。
- **成本**：S
- **优先级**：P1
- **涉及高风险面？**：否（只读 L2 快照并发出 L1 链接）。
- **依据**：Alfred Script Filter JSON 规范（`items`/`mods`/`rerun`/`skipknowledge`）【文档】、`swiftbar/SwiftBar:SwiftBar/MenuBar/MenuLineParameters.swift:206-249`【源码】。

### P1-2：补齐 macOS `AppIntents` 参数化动作
- **价值**：让 Apple 快捷指令与 Siri 支持「调节书房灯亮度到 40%」「空调设 25 度」「执行一键全关/柔和夜灯」，与 CLI/MCP/Raycast 能力对齐。
- **成本**：S
- **优先级**：P1
- **涉及高风险面？**：中（涉及 `AppIntents.swift` 新增控制入口，须确保全部经 `HomeStore` 写入门、锁屏守卫与高风险确认——涉及「设备控制写入与安全策略」高风险面，应走 PR + 单测）。
- **依据**：`Sources/MenuBarMijiaApp/AppIntents.swift:179-370`、[ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md) 第 4 条【源码】。

### P2-1：评估并立项「L5 本地环回 WebSocket / HTTP 桥」（需新 ADR）
- **价值**：打通高频连续控制（Stream Deck 旋钮 300ms 分桶调光调温）与实时状态推送（Stream Deck 按键态同步、MCP 可选 Streamable HTTP 替代脆弱 stdio、以及落实 [ADR-0020](../../adr/0020-backend-descriptor-table.md) 预留的第三方进程外后端接缝）。
- **成本**：L（跨 Swift `Network.framework` / Rust `companion.rs` 双端实现、鉴权模型、限流与速率保护）。
- **优先级**：P2
- **涉及高风险面？**：**是**（触及高风险面 1 网络与令牌边界、高风险面 2 设备控制写入，必须走完整 PR 审查与安全测试）。
- **依据**：`elgatosf/streamdeck:packages/plugin/src/connection.ts`、`cgiesche/streamdeck-homeassistant:PluginComponent.vue`、`homeassistant-ai/ha-mcp:README.md:95`、`windows/src-tauri/src/companion.rs:14-31`、[ADR-0020](../../adr/0020-backend-descriptor-table.md) 第 94 行【源码】。

### P2-2：基于 Elgato Stream Deck SDK 发布官方伴生 `.sdPlugin` & Windows PowerToys CmdPal 扩展
- **价值**：占领桌面硬件控制面板（Stream Deck / Stream Deck+）与 Windows 11 新一代系统级启动器两大高频入口。
- **成本**：M（Stream Deck 插件可复用 L5 本地 WS；CmdPal 扩展基于 `Microsoft.CommandPalette.Extensions.Toolkit`）。
- **优先级**：P2（Stream Deck 强依赖 P2-1；CmdPal 可先基于 L2+L1 独立推进）。
- **涉及高风险面？**：中（Windows COM 注册与安装包路径变更可能触及高风险面 5 构建/安装链路）。
- **依据**：`cgiesche/streamdeck-homeassistant`、`microsoft/PowerToys:src/modules/cmdpal/doc/initial-sdk-spec/initial-sdk-spec.md`【源码】。

---

## 9. 设想（不受现有 ADR 约束的探索）

以下设想用于拓展产品想象空间，落地前需评估其带来的架构代价与安全约束：

1. **「MenuBarHome as a Local MCP + Stream Deck Hub」——把嵌入式轻量局部网关直接放进主应用**
   - *设想*：不在外层挂 Python 脚本，而是在 Swift / Rust 主应用内直接监听一个仅本机可访问的 Unix Domain Socket（macOS）或 Named Pipe / 受秘钥保护的 Loopback HTTP/WS 端口，**同时讲两种标准方言**：`/mcp`（Streamable HTTP，供 Claude/Cursor/Raycast 直连免配置 Python 环境）和 `/ws/companion`（推状态给 Stream Deck、桌面浮窗和命令行）。
   - *冲突 ADR*：与 **[ADR-0013](../../adr/0013-raycast-companion-contract.md)**「全部走只读文件快照 + URL Scheme，不开放本地常驻网络端口」不同，也与 **[ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md)** 重启条件 1 一致——需要单独起草一份关于「本地受鉴权进程间服务边界」的新 ADR 来替换或扩充 ADR-0013。
2. **「App Store / 开发者签名破冰后的 WidgetKit + Control Center 扩展」**
   - *设想*：若未来引入 Apple Developer ID 公证与 App Group，macOS 端直接提供原生 **Control Center 磁贴（macOS 18+ ControlWidget）** 与桌面 **WidgetKit** 交互小组件，不经过任何中间文件或 URL 跳转，直接在系统控制中心开关客厅灯、看温湿度。
   - *冲突/前提*：目前 `README.zh-CN.md:90` 明确未加入付费 Apple 开发者计划（无公证、无系统级 App Group Entitlements），且与 **[ADR-0005](../../adr/0005-update-signing-trust-chain.md)** 自签名更新体系的权限前提相关。
3. **「声明式设备渲染包（Declarative Card Packs）」——折中实现「可分享扩展」而不执行代码**
   - *设想*：在绝对禁止加载第三方可执行代码（[ADR-0020](../../adr/0020-backend-descriptor-table.md)、[ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md)）的前提下，允许社区分享纯 JSON 的 **Stream Deck 按键/主题包** 或 **桌面微卡片布局模板**（类似 `cgiesche/streamdeck-homeassistant` 的 `default-display-config.yml` + `deviceProfiles.json`），只映射已有快照字段与 SVG 模板，彻底零代码执行风险。
   - *冲突 ADR*：不与现有安全底线冲突，但若扩展到主面板自定义卡片 UI 布局则会突破 **[ADR-0023](../../adr/0023-host-owned-builtin-capabilities.md)** 的封闭内置界面范围。

---

## 10. 来源清单

**已精读源码的仓库**：
- `raycast/extensions`（`08d2f847`）：`docs/information/manifest.md`、`docs/information/security.md`、`docs/information/lifecycle/background-refresh.md`、`docs/information/lifecycle/deeplinks.md`、`docs/basics/prepare-an-extension-for-store.md`、`.github/workflows/extensions_build_publish.yml`、`extensions/homeassistant/package.json`、`extensions/homeassistant/src/runService.tsx`、`extensions/homeassistant/src/lightsmenu.tsx`、`extensions/homeassistant/src/tools/get-entities.ts`、`extensions/homeassistant/src/tools/run-service.ts`
- `swiftbar/SwiftBar`（`97f4f87`）：`SwiftBar/Plugin/Plugin.swift`、`SwiftBar/Plugin/ExecutablePlugin.swift`、`SwiftBar/Plugin/StreamablePlugin.swift`、`SwiftBar/Plugin/PluginMetadata.swift`、`SwiftBar/Plugin/PluginManger.swift`、`SwiftBar/MenuBar/MenuLineParameters.swift`、`SwiftBar/MenuBar/MenuBarItem.swift`、`SwiftBar/Utility/RunScript.swift`、`SwiftBar/Utility/PluginUtilities.swift`
- `Hammerspoon/hammerspoon`（`f392895`）：`extensions/urlevent/urlevent.lua`
- `felixhageloh/uebersicht`（`859a7d7`）：`server/src/Widget.js`、`server/src/VirtualDomWidget.js`、`server/src/runShellCommand.js`
- `microsoft/PowerToys`（`0068588`）：`src/modules/cmdpal/doc/initial-sdk-spec/initial-sdk-spec.md`、`src/modules/cmdpal/doc/command-links.md`、`src/modules/cmdpal/extensionsdk/Microsoft.CommandPalette.Extensions/Microsoft.CommandPalette.Extensions.idl`、`src/modules/cmdpal/extensionsdk/Microsoft.CommandPalette.Extensions.Toolkit/ExtensionServer.cs`
- `elgatosf/streamdeck`（`650a5df`）：`packages/plugin/src/connection.ts`
- `cgiesche/streamdeck-homeassistant`（`4a04d76`）：`public/manifest.json`、`src/components/PluginComponent.vue`、`src/components/PiComponent.vue`
- `basnijholt/home-assistant-streamdeck-yaml`（`a87daa4`）：`home_assistant_streamdeck_yaml.py`
- `home-assistant/core`（`b6d170e`）：`homeassistant/components/mcp_server/server.py`、`homeassistant/components/mcp_server/http.py`、`homeassistant/components/mcp_server/config_flow.py`、`homeassistant/helpers/llm.py`
- `homeassistant-ai/ha-mcp`（`e8c0841`）：`README.md`、`src/ha_mcp/server.py`、`src/ha_mcp/tool_catalog.py`
- `Do1e/mijia-api`（`2cc61f2`）：`mijiaAPI/mcp_server.py`

**MenuBarHome 本仓库引用文件**：
- [docs/adr/0013-raycast-companion-contract.md](../../adr/0013-raycast-companion-contract.md)
- [docs/adr/0020-backend-descriptor-table.md](../../adr/0020-backend-descriptor-table.md)
- [docs/adr/0023-host-owned-builtin-capabilities.md](../../adr/0023-host-owned-builtin-capabilities.md)
- [Sources/MijiaCore/AppURLCommand.swift](../../../Sources/MijiaCore/AppURLCommand.swift)
- [Sources/MijiaCore/RaycastSnapshot.swift](../../../Sources/MijiaCore/RaycastSnapshot.swift)
- [Sources/MenuBarMijiaApp/URLCommandHandler.swift](../../../Sources/MenuBarMijiaApp/URLCommandHandler.swift)
- [Sources/MenuBarMijiaApp/AppIntents.swift](../../../Sources/MenuBarMijiaApp/AppIntents.swift)
- [windows/src-tauri/src/companion.rs](../../../windows/src-tauri/src/companion.rs)
- [raycast/package.json](../../../raycast/package.json)、[raycast/src/snapshot.ts](../../../raycast/src/snapshot.ts)、[raycast/src/url.ts](../../../raycast/src/url.ts)、[raycast/src/url-builder.ts](../../../raycast/src/url-builder.ts)、[raycast/src/search-devices.tsx](../../../raycast/src/search-devices.tsx)、[raycast/src/search-scenes.tsx](../../../raycast/src/search-scenes.tsx)、[raycast/src/ask.tsx](../../../raycast/src/ask.tsx)
- [scripts/mijia](../../../scripts/mijia)、[scripts/mijia-mcp](../../../scripts/mijia-mcp)

**外部文档与检索来源（2026-11-23）**：
- Alfred Script Filter JSON Format：https://www.alfredapp.com/help/workflows/inputs/script-filter/json/
- Loupedeck / Logi Plugin SDK vs Stream Deck SDK 架构对比检索摘要（2026-11-23）
