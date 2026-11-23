# ADR-0013：伴生端（Raycast 扩展、本地 CLI 与 MCP 服务）只读快照 + 精确值链接

日期：2026-11-06　状态：已接受（依赖 #57 的 `menumijia://` 链接与 #20 的伴生快照；#19 在同一契约上补齐本地 MCP 服务）

## 背景

#176（迁入后为 #20）与 #177（迁入后为 #19）要求 Raycast 扩展、「一句话 CLI」与本地 MCP 服务能搜索设备、开关、调亮度 / 色温 / 温度 / 风速、执行场景与快捷动作。三条路都要「复用 App Intents 与 URL Scheme，不单独持有凭据」。已合并的伴生快照（`RaycastSnapshot.swift`）解决了「伴生端怎么知道有哪些设备」：应用把设备、场景、快捷动作、环境读数与随机 `bridgeToken` 写到 `~/Library/Application Support/MenuBarMijia/raycast-snapshot.json`（`0600`），带令牌的链接跳过外部链接确认。

剩下两个问题：

1. **拿不到结果**：链接是单向的，扩展、CLI 与 MCP 工具无法知道设备是否真的执行了，误报「已打开」等于让用户对家失去信任。
2. **只有 `toggle` 没有「按值」**：滑条与结构化工具要知道目标值，而 `toggle` 依赖「当前状态」，伴生端读到的是最多 0.3 秒前的快照；两边各猜一次就会把设备翻来覆去。

## 决定

1. **结果回写**：每条命令带 `id=<requestId>`，应用执行完把 `RaycastCommandFeedback{requestId, command, message, isError, completedAt}` 写回同一个快照并立即落盘。伴生端只认与自己 `requestId` 相同的反馈，过期结果不会冒充本次执行。`requestId` 是本地随机值，不参与授权。
2. **精确值三层数值边界契约**：新增 `power` / `brightness` / `color-temp` / `temperature` / `fan`，按调用层级执行三层校验与归一化：
   - **第一层：协议外边界拦截（`AppURLParser`，Swift `AppURLCommand.swift` 与 TS `appUrlCommand.ts`）**：在 URL 解析阶段拒绝非数字输入及超出协议外边界的值（亮度 `0…100%`、色温 `1000…20000 K`、温度 `−30…100 °C`、风速 `1…100%`）。
   - **第二层：交互界面、AI 与伴生执行端按设备能力夹紧（`HomeStore`、`IntentValidator`、`RaycastControls.swift` 与 `appUrlCommand.ts`）**：通过协议外边界的指令在落到具体设备时，按该设备在快照中声明的实际能力区间（`minKelvin…maxKelvin`、`minTemp…maxTemp`）夹紧，并将目标温度按设备 `step` 步长对齐（`snappedTemperature`）。
   - **第三层：本地 CLI 与 MCP 前置严格校验（`scripts/mijia` 与 `scripts/mijia-mcp`）**：在拼装 `menumijia://` 链接前先读取 `raycast-snapshot.json` 中目标设备的能力边界，若参数超出设备支持的色温/温度范围则直接抛出显式 `CliError` 拒绝执行，不静默夹紧。
3. **关灯用 `power`**：`brightness=0` 也映射为关灯命令，不把 0 发给 Home Assistant（其 `brightness_pct` 会被夹到 1，反而把灯点亮）。
4. **一条安全路径与 `bridgeToken` 免外部链接确认边界**：
   - **外部链接边界（`URLDirectControl.requiresConfirmation`）**：带有效 `bridgeToken` 的本地 CLI（`scripts/mijia`）、MCP（`scripts/mijia-mcp`）与 Raycast 写操作在 `URLDirectControl` 入口有意设计为非交互免弹窗。因为 `bridgeToken` 仅保存在当前登录用户本机 `0600` 权限的 `raycast-snapshot.json` 中，持有该令牌即证明调用方是同一操作系统的本机同用户进程，无需防范浏览器或第三方应用的跨站伪造跳转。
   - **核心安全策略保持强制执行**：跳过外部链接来源弹窗不等于跳过设备安全守卫。所有路由进入 `HomeStore` 后，仍然强制执行锁屏拦截、`ManualControlPolicy` 高风险设备（取暖器、插座、阀门、车库门等）二次确认与乐观写入。
   - **`power` 路由语义**：`power` 对普通设备复用 `togglePrimary`，但窗帘 / 窗户 / 卷帘门 / 晾衣架改走显式的「开到 100% / 关到 0%」：三态磁贴的 `togglePrimary` 对移动中的窗帘语义是暂停，若 `on` / `off` 也照此执行，「关闭」会变成「停在半路」，与链接的字面承诺不符。按钮类触发与阀门仍走 `togglePrimary`。
5. **`focus` 不算控制**：`menumijia://focus?device=<id>` 只切换房间筛选并展开抽屉，不写设备，因此不弹外部链接确认；但仍受锁屏拦截。
6. **不猜档位**：`fan?preset=` 必须是设备 `availablePresetModes` 里的值，否则报错并列出可选档位，避免把固件没有的模式发下去；`percent` 与 `preset` 只能二选一，同时出现视为歧义直接拒绝，`percent` 越界也不会被同时给出的 `preset` 掩盖。
7. **MCP 服务不向模型暴露 `bridgeToken`**：`scripts/mijia-mcp`（或 `scripts/mijia mcp`）以 stdio JSON-RPC 2.0 暴露只读资源（`mijia://status`、`mijia://devices`、`mijia://scenes`）与精确值工具，下发指令时在本机进程内部读取 `bridgeToken` 拼装 `menumijia://` 链接并轮询 `lastCommandFeedback`，但所有返回给模型上下文的 JSON 都剥离 `bridgeToken`。会改变设备状态的工具一律标注 `destructiveHint: true`（MCP 规范默认值），让客户端自行弹确认；`--read-only` 启动参数则把 `tools/list` 收窄到 `list_devices` / `get_home_status` / `focus_device`，写工具调用在本地直接拒绝，用于只读 AI 会话的最小授权隔离。

## 后果

- 伴生端（Raycast、CLI、Claude Desktop / Claude Code / Cursor MCP）仍然不持有任何米家 / Home Assistant 凭据；关闭「Raycast 集成」即删除快照并作废令牌，三条路径同时失效。
- 快照字段与 schema 版本成为对外契约：改名字段必须升 `RaycastSnapshot.currentSchemaVersion`，两端（Swift 与 `raycast/src/snapshot.ts`、`scripts/mijia`）同步。
- 新增了与面板并行的控制入口，因此每次扩展路由都要走同一套安全模块；测试覆盖「高风险设备未确认不执行」「未授权链接必须弹确认」「MCP 响应不泄露 `bridgeToken`」三条边界。
- 已知取舍：`temperature` 只设目标温度、不开机（与详情抽屉一致）；要开机仍需 `power=true`。
- **URL scheme 别名（#166，2026-11-15）**：`menubarhome://` 作为 `menumijia://` 的**完全等价**别名被两端接受（macOS 在 `Info.plist` 注册两个 scheme，`AppURLParser` 接受两者；Windows 在注册表写两份协议处理项，`companion.rs` 与 `appUrlCommand.ts` 接受两者）。别名不绕过任何校验：bridge token、外部链接确认、高风险二次确认、锁屏拦截都按同一条路径执行，黄金语料 `app_url_command_golden.json` 含别名用例。伴生端（Raycast、CLI、MCP）**继续发送 `menumijia://`**，这样新版 CLI 对旧版应用仍然有效；别名只给手写链接和快捷指令的使用者。
