# ADR-0024：进程外适配器协议 v0（Out-of-Process Adapter Protocol v0）

日期：2026-11-24　状态：Proposed（关联 [ADR-0003](0003-core-builds-on-linux.md)、[ADR-0005](0005-update-signing-trust-chain.md)、[ADR-0006](0006-dual-platform-implementation.md)、[ADR-0008](0008-dual-source-device-deduplication.md)、[ADR-0013](0013-raycast-companion-contract.md)、[ADR-0019](0019-scheduled-command-source-scope.md)、[ADR-0020](0020-backend-descriptor-table.md)、[ADR-0023](0023-host-owned-builtin-capabilities.md)）

## 背景

[ADR-0020](0020-backend-descriptor-table.md) 确立了 `HomeBackend` 三值封闭枚举与 `HomeBackendDescriptor` 描述表，[ADR-0023](0023-host-owned-builtin-capabilities.md) 确立了宿主独占能力选择、写入门与安全策略的边界，两份文档同时明确禁止在宿主进程内加载第三方代码，并预留了「评估进程外扩展协议」的重启条件。

2026-11-23 深度调研（`docs/research/2026-11-23-deep-dive/00-SUMMARY.md` 第四节及 R02、R05、R12、R13）指出：在多源打底（`HomeAdapter` SPI、Windows `HomeProvider`、`AdapterErrorCode` 归一）与通用子进程监督器（`ProcessSupervisor` / `SupervisedProcess`，#425）落地之后，需要一份**纯契约、零运行时代码**的 v0 协议规范，为后续只读参考适配器（阶段 4）与受控写能力（阶段 5）定下不可妥协的传输、生命周期、清单、身份、凭据与安全边界。

本 ADR 仅定义契约（协议规范、Manifest JSON Schema、黄金语料与静态校验脚本），**不包含任何 Swift / TypeScript / Rust 运行时实现**。

## 决策总览

1. **宿主进程内零第三方代码**：进程外适配器作为受管子进程独立运行，通过 `stdio` JSON-RPC 2.0 与宿主通信；`HomeBackend` 保持三值封闭枚举不变，`Shared/capability-manifest.json` 不写入第三方适配器条目。
2. **v0 严格只读**：v0 方法集仅覆盖握手初始化、能力声明、快照拉取、事件订阅、健康探针与优雅退出；**不包含任何设备控制写入能力**。
3. **宿主是唯一的策略与安全判决者**：设备危险等级、写入门、锁屏守卫、高风险二次确认、通知分级与告警严重度（`AlertSeverity`）、去重规范身份（`DeviceDeduplicator`）与长期凭据库永远归宿主持有；适配器只上报事实与证据。

---

## 一、传输层与帧格式（Transport & Framing）

- **主通道**：宿主拉起适配器子进程，以 `stdin`（宿主 → 适配器）与 `stdout`（适配器 → 宿主）承载 **JSON-RPC 2.0** 消息。
- **帧定界（NDJSON）**：
  - UTF-8 编码，**每条 JSON-RPC 2.0 消息占一行**，以 `\n`（LF）结尾；接收端容忍 `\r\n`（CRLF）。
  - 帧内禁止出现未转义的换行符；禁止在 `stdout` 输出任何非 JSON-RPC 文本（例如启动横幅或调试打印），否则视为协议违规。
  - **单帧上限**：`8 MiB`（`8 * 1024 * 1024` 字节）。超限帧必须拒绝并断开重连，防止内存放大；大媒体流（如摄像机视频）不走 `stdio` 字节流。
- **日志通道**：`stderr` 专用于适配器非结构化诊断日志，宿主按行采集并统一脱敏，永不作为协议帧解析。
- **消息信封**：严格遵循 JSON-RPC 2.0：
  - 请求：`{"jsonrpc":"2.0","id":<int|string>,"method":"<name>","params":{...}}`
  - 成功响应：`{"jsonrpc":"2.0","id":<int|string>,"result":{...}}`
  - 错误响应：`{"jsonrpc":"2.0","id":<int|string>,"error":{"code":<int>,"message":"<string>","data":{"adapterCode":"...","retryable":<bool>,"retryAfterMs":<int?>}}}`
  - 通知（无 `id`）：`{"jsonrpc":"2.0","method":"<name>","params":{...}}`
- **选型理由**：无监听端口、无跨进程端口嗅探面、随宿主启停、macOS `Process` 与 Windows Rust `Command` 原生零依赖支持，且与仓库已有 `scripts/mijia-mcp` 的 stdio JSON-RPC 模式同构。

---

## 二、生命周期与进程监督（Lifecycle & Supervision）

### 2.1 启动与握手协商

1. **进程隔离启动**：宿主以最小环境白名单（禁止继承宿主完整环境变量，禁止通过命令行参数或环境变量传递任何凭据）启动适配器二进制，工作目录锁定在适配器私有缓存目录（macOS `~/Library/Application Support/MenuBarMijia/adapters/<adapterId>/data`，Windows `%LOCALAPPDATA%\MenuBarMijia\adapters\<adapterId>\data`）。
2. **`initialize` 握手**（超时 `10s`）：
   - 宿主发送 `initialize` 请求，携带 `protocolVersion`（当前 `"0.1"`）、`supportedProtocolVersions`（如 `["0.1"]`）、`hostVersion`、`locale`、`adapterId`、`dataDir`，以及非秘密配置与短期凭据租约（若有）。
   - 适配器返回协商后的 `protocolVersion`、`adapterId`、`adapterVersion`、`manifestDigest`（`sha256:<64位小写hex>`）与运行时 `capabilities` 摘要。
   - **拒绝条件**：`protocolVersion` 不在宿主支持集合内、`adapterId` 与宿主预期不符、`manifestDigest` 与已安装的本地清单摘要不一致、或 10 秒内未响应——宿主立即终止子进程并标记启动失败。
3. **向前兼容原则**：次版本升级仅允许增量添加字段；双方解析器必须忽略未知的附加字段（manifest 本身除外，manifest 校验严格执行 `additionalProperties: false`）。

### 2.2 健康检查

- 宿主按 manifest 声明的 `health.intervalSec`（默认 `60s`，下限 `15s`）发送 `health.ping` 请求，单次超时 `health.timeoutMs`（默认 `5000ms`）。
- 适配器返回 `{ "state": "ok" | "degraded" | "signInRequired" | "offline", "latencyMs": <int>, "detail"?: "<string>" }`。
- 连续 3 次探针超时视为适配器失活，宿主主动触发优雅退出流程并交由监督器按退避策略重启。

### 2.3 优雅退出与孤儿清理

1. 宿主停用适配器或应用退出时，先发送 `shutdown` 请求（等待上限 `2s`），随后关闭子进程 `stdin`。
2. 若子进程在宽限期内未自行退出，交由 `SupervisedProcess.terminate` 执行 `SIGTERM`（等待 `1s`）→ `SIGKILL`（等待 `1s`）升级终止。
3. 每次发送信号与启动前清理孤儿进程，均复用 `SupervisedProcessIdentity` 与 `SupervisedProcessPIDFile`（`0600` 权限、`O_NOFOLLOW`），核对 `pid`、`executablePath`、进程启动时间戳与当前 `euid` 完全匹配后才发信号，防止 PID 复用误杀无关进程。

### 2.4 进程监督复用（复用 #24 / #425）

进程监督直接复用现有通用子进程监督器 `Sources/MijiaCore/ProcessSupervisor.swift` 与 `Sources/MijiaCore/SupervisedProcess.swift`（Windows 侧在 `windows/src-tauri/` 实现同构状态机）：

- **状态机**：`stopped` / `running` / `backingOff(Duration)` / `circuitOpen`。
- **指数退避与抖动**：异常退出后按 `min(jitter(1s * 2^min(consecutiveFailures, 6)), 60s)` 退避重启（抖动系数 `0.8...1.2`）。
- **崩溃熔断**：`120s` 滑动窗口内累计失败达到 `5` 次即进入 `circuitOpen`，停止自动重启并在 UI 提示用户查看脱敏日志；仅显式 `stop()` 可复位熔断器，重复 `start()` 不可绕过。
- **稳定期复位**：子进程持续稳定运行满 `300s`（5 分钟）后清空失败窗口与连续失败计数。
- **单适配器故障隔离**：单个适配器崩溃或熔断仅将其设备标记为离线/陈旧，绝不影响宿主 UI、米家或 Home Assistant 主通道。

---

## 三、v0 只读 RPC 方法表

### 3.1 宿主 → 适配器（请求）

| 方法 | 分类 | 必填 | 参数摘要 | 返回摘要 | 说明 |
| --- | --- | :---: | --- | --- | --- |
| `initialize` | 生命周期 | 是 | `{protocolVersion, supportedProtocolVersions, hostVersion, locale, adapterId, dataDir, config?, leases?}` | `{protocolVersion, adapterId, adapterVersion, manifestDigest, capabilities}` | 握手与版本协商；必须作为首条请求 |
| `capabilities` | 只读查询 | 是 | `{}` | `{readOnly: true, deviceKinds, readings, alerts, pushEvents, history, limits?}` | 返回运行时探测后的能力摘要，必须为 manifest 声明的子集 |
| `snapshot` | 只读查询 | 是 | `{cursor?}` | `{capturedAt, cursor?, rooms, devices: DeviceDescriptor[]}` | 拉取当前全量只读设备快照；单次请求超时 `15s` |
| `events.subscribe` | 事件订阅 | 否 | `{topics: ("stateChanged"\|"deviceAdded"\|"deviceRemoved"\|"safetySignal"\|"healthChanged"\|"authExpired")[]}` | `{subscriptionId, acceptedTopics}` | 仅当 `capabilities.pushEvents == true` 时启用 |
| `events.unsubscribe` | 事件订阅 | 否 | `{subscriptionId}` | `{ok: true}` | 取消既有订阅 |
| `health.ping` | 生命周期 | 是 | `{}` | `{state, latencyMs, detail?}` | 周期健康探针，默认 `60s` 间隔、`5s` 超时 |
| `shutdown` | 生命周期 | 是 | `{reason?: "hostExit"\|"disabled"\|"reconfigure"\|"upgrade"}` | `{ok: true}` | 优雅退出；超时后监督器强杀 |

### 3.2 适配器 → 宿主（通知与受限反向请求）

| 方法 | 形态 | 参数摘要 | 说明 |
| --- | --- | --- | --- |
| `events.stateChanged` | 通知 | `{subscriptionId, nativeId, patch, ts}` | 单设备增量状态更新 |
| `events.deviceAdded` | 通知 | `{subscriptionId, device: DeviceDescriptor, ts}` | 新发现设备 |
| `events.deviceRemoved` | 通知 | `{subscriptionId, nativeId, ts}` | 设备移除 |
| `events.safetySignal` | 通知 | `{subscriptionId, nativeId, kind, active, evidence?, ts}` | **仅上报事实与证据，严禁携带 `severity` 或通知策略** |
| `events.healthChanged` | 通知 | `{state, detail?, ts}` | 适配器健康状态变化 |
| `events.authExpired` | 通知 | `{accountId, reason, ts}` | 租约或上游会话失效，宿主标记账户并触发续期或提示重登 |
| `events.log` | 通知 | `{level, message, fields?}` | 结构化诊断日志，宿主统一脱敏落盘 |
| `host.auth.renew` | 反向请求 | `{accountId, leaseId, reason}` | 请求宿主单飞续期，返回 `{leaseId, kind, value, expiresAt}`；拒绝时适配器必须停止该账户轮询 |

### 3.3 写能力明确排除在 v0 之外（预留至阶段 5 / v1+）

- **v0 禁止写入**：v0 协议**不定义也不允许**任何设备控制写入方法。若适配器在 manifest 中声明非空 `capabilities.commands`，或在运行期试图调用未授权方法，宿主直接拒绝（错误码 `-32004` / `unsupported`）。
- **未来 `control.execute` 预留约束（阶段 5）**：
  1. 只能由宿主在通过完整写入门（`HomeStore+Capabilities` 能力可用性核验 → `ScreenLockPolicy` 锁屏拦截 → `ManualControlPolicy` 高风险二次确认与防漂移校验）之后单向发出；
  2. 请求参数必须携带宿主签发的 **`grantId`**（单次授权标识，用于审计与幂等）与 **`capabilityGeneration`**（宿主能力/适配器单调代次），任何过期代次或缺失 `grantId` 的写指令在宿主侧与适配器侧均必须零副作用拒绝；
  3. 命令动词只能取自宿主封闭词表（映射至 `DeviceCommand`），适配器不得自造动词绕过确认策略。

---

## 四、Manifest 字段表与禁止字段

每个进程外适配器随包提供只读 `adapter-manifest.json`，结构由 [`Shared/adapterManifest.schema.json`](../../Shared/adapterManifest.schema.json) 约束，**独立于内置清单 `Shared/capability-manifest.json`**。

### 4.1 允许字段表

| 字段 | 必填 | 类型 | 语义与约束 | 宿主用途 |
| --- | :---: | --- | --- | --- |
| `manifestVersion` | 是 | integer (`1`) | 清单结构版本 | 未知版本直接拒绝加载 |
| `adapterId` | 是 | string（反向域名） | 全局唯一标识，如 `com.example.lg-webos` | 生成 `sourceScope`、凭据槽、缓存目录与去重命名空间 |
| `name` | 是 | `{zh: string, en: string}` | 双语显示名 | 设置页与诊断摘要展示 |
| `version` | 是 | semver string | 适配器语义化版本 | 诊断记录、版本比对与后续升级回滚 |
| `hostApi` | 是 | semver range | 所需宿主协议版本区间（v0 为 `^0.1.0`） | 不兼容时拒绝启动并提示升级 |
| `runtime` | 是 | object | `{type: "binary"\|"node"\|"python", entry: string, arch: ("arm64"\|"x86_64")[], sha256?: 64-hex}` | 监督器校验入口相对路径（禁止 `..` 与绝对路径）及摘要 |
| `platforms` | 是 | string[] | 非空去重子集：`macos` / `windows` | 平台不匹配时不加载 |
| `capabilities` | 是 | object | `{readOnly: true, deviceKinds, commands?: [], readings?, alerts?, pushEvents?, history?}` | 声明静态能力边界；`deviceKinds` 仅限宿主 15 个 `DeviceKind` 值，未知种类运行期降级为只读 `generic`；**v0 要求 `readOnly == true` 且 `commands` 为空或省略** |
| `permissions` | 是 | object | `{network: {internet: string[], lan: boolean}, files?: {read: string[], write: ("cache")[]}, subprocess?: boolean}` | 最小权限声明；`subprocess` 默认 `false` |
| `vendor` | 否 | object | `{name: string, docs?: https URL, hosts?: string[]}` | 展示与审计元信息；若声明 `vendor.hosts`，**必须为 `permissions.network.internet` 的子集**，否则拒绝 |
| `auth` | 否 | object[] | 登录方式声明：`id`, `type` (`none`\|`apiKey`\|`oauthDevice`\|`qr`), `label`, `scopes?`, `prompts?` | 供宿主渲染原生认证表单与托管凭据槽 |
| `discovery` | 否 | object | `{modes: ("cloudApi"\|"lanMdns"\|"lanSsdp"\|"lanUdp")[], mdns?: string[], ssdp?: string[], udpPorts?: int[]}` | 宿主检查局域网发现权限 |
| `limits` | 否 | object | `{maxDevices?: int, maxConcurrentCalls?: int, requestsPerMinute?: int}` | 宿主限流与诊断告警阈值 |
| `health` | 否 | object | `{intervalSec?: int (>=15), timeoutMs?: int (500..15000)}` | 健康探针调度参数 |
| `ui` | 否 | object | `{configSchema?: object, icon?: string}` | 受限配置表单描述（仅作用于适配器自身配置弹窗，不取代内置后端手写设置页；密码项必须标记 `writeOnly: true`） |

### 4.2 明确禁止字段（FORBIDDEN）

为防止策略偷渡、安全降级或秘密泄漏，以下字段**在 manifest 根节点及任意嵌套层级一律禁止出现**（`Shared/adapterManifest.schema.json` 同时以 `additionalProperties: false` 与校验脚本显式黑名单双层拦截）：

| 禁止字段 | 禁止原因 | 唯一合法归属 |
| --- | --- | --- |
| `riskLevel` / `requiresConfirmation` / `safetyClass` / `bypassConfirmation` | 防止适配器自行声明低风险或绕过高风险二次确认 | 宿主 `ManualControlPolicy`（按 `DeviceKind` 与设备事实属性派生） |
| `canWrite` / `writeAllowed` / `allowControl` / `autoExecute` | 防止适配器声明写权限绕过宿主写入门 | 宿主能力开关 + 写入门（v0 全量只读） |
| `notificationChannel` / `severity` / `interruptionLevel` / `suppressAlerts` / `muteAlerts` | 防止适配器篡改告警分级、绕过或压制安全通知 | 宿主 `AlertSeverity` 表与通知投递管线 |
| `globalDeviceId` / `canonicalId` | 防止适配器伪造全局设备 ID 劫持既有卡片或偏好 | 宿主 `DeviceDeduplicator` 按 `identity` 硬件键计算 |
| `secret` / `secrets` / `token` / `accessToken` / `refreshToken` / `password` / `apiKey` / `cookie` / `session` / `credentials` | 防止明文凭据写死进静态清单并随包分发 | 宿主 `CredentialVault` / Windows `secureStore` + 短期租约注入 |

---

## 五、设备身份、`sourceScope` 与 `DeviceDeduplicator` 交互

1. **作用域标识（`sourceScope`）**：
   - 每个进程外适配器实例拥有独立作用域 `sourceScope = "adapter:<adapterId>"`（与 [ADR-0019](0019-scheduled-command-source-scope.md) 的 `ha:<url>`、米家账号 ID、`demo` 平行）。
   - 多账户场景下，子作用域为 `adapter:<adapterId>:<accountId>`；引用判决与定时任务分区沿用 ADR-0019 / ADR-0023 规则。
2. **不改动 `HomeBackend` 枚举**：
   - 严格遵守 [ADR-0020](0020-backend-descriptor-table.md) 第 1 条，不将 `HomeBackend` 改为开放字符串，也不为第三方适配器追加枚举值。
   - 进程外适配器设备在快照聚合层通过平行的 `ExternalAdapterSlot` 投影并入 `SynthesizedHome`，卡片元数据记录 `sourceScope = "adapter:<adapterId>"`。
3. **命名空间隔离与硬件去重**：
   - 适配器上报的 `nativeId` 仅在 `adapter:<adapterId>` 命名空间内有效，宿主内部限定为 `adapter:<adapterId>:<nativeId>`，绝不直接充当全局 canonical ID。
   - 适配器应在 `DeviceDescriptor.identity` 中尽量提供客观硬件标识：`dids`、`macAddresses`、`uniqueIds`。
   - 宿主将上述字段归一化为 `DeviceSourceIdentity` 后送入 `DeviceDeduplicator`（`Sources/MijiaCore/DeviceDeduplicator.swift` / `windows/src/core/dualSourceProvider.ts`）：
     - **v0 合并优先级**：若通过强硬件键（`did` 或 `macAddress`）与内置源（Home Assistant 或米家云端）匹配为同一物理设备，**内置源始终胜出并保留写路由与 canonical ID**，进程外适配器不可劫持内置卡片控制权，仅可作为补充只读遥测来源（或按策略去重折叠）；
     - **独立设备**：未命中内置源的适配器设备以 `adapter:<adapterId>:<nativeId>` 为规范 ID 渲染为只读卡片；若同一物理设备出现在两个外部适配器中，按 `adapterId` 字典序确定性归并，不依赖启动先后顺序。

---

## 六、凭据边界（仅短期租约）

1. **零长期秘密外泄**：宿主的米家 `CredentialVault`、`passToken`（[ADR-0004](0004-no-pass-token-storage.md)）、Home Assistant 长期令牌、AI API Key、伴生 `bridgeToken`（[ADR-0013](0013-raycast-companion-contract.md)）以及适配器自身的 `refreshToken`，**永远不离开宿主安全存储**（macOS Keychain / Windows `secureStore`）。
2. **短期租约模型**：
   - 宿主按适配器独立槽位（`adapter:<adapterId>:secret`）托管长期凭据，仅在 `initialize` 或响应 `host.auth.renew` 时通过 `stdin` JSON-RPC 下发短期租约：
     ```json
     {
       "accountId": "acct-1",
       "leaseId": "lease-20261124-01",
       "kind": "oauthAccess",
       "value": "<short-lived-token>",
       "expiresAt": "2026-11-24T06:00:00Z"
     }
     ```
   - `kind` 仅允许 `oauthAccess`、`apiKey` 或 `lanToken`；**即使上游是静态 API Key，宿主也必须为其附加有限 `expiresAt`（建议 ≤ 1 小时）以支持随时撤销与轮换**。
   - 适配器仅可在进程内存中持有 `value` 至 `expiresAt`，禁止写入磁盘、缓存或日志。
3. **单飞续期**：租约将过期时，适配器发送 `host.auth.renew` 反向请求；宿主按 `(adapterId, accountId)` 单飞执行上游 refresh 或校验撤销状态，成功则返回新租约，拒绝时适配器必须立即停止该账户请求并发出 `events.authExpired`。

---

## 七、错误码归一化（对齐 `AdapterErrorCode`）

JSON-RPC 2.0 协议层错误保留标准码（`-32700` ~ `-32603`），适配器应用层错误使用 JSON-RPC 保留服务端错误段 `-32000` ~ `-32099`，与 `Sources/MijiaCore/HomeProvider.swift` 中的 `AdapterErrorCode` 一一对应：

| JSON-RPC `error.code` | `data.adapterCode`（对齐 `AdapterErrorCode`） | `data.retryable` 默认 | 语义与宿主处理 |
| :---: | --- | :---: | --- |
| `-32001` | `authExpired` | `false` | 租约过期或上游 401/403；宿主触发单飞续期或标记需重登，不清空已有设备 |
| `-32002` | `unreachable` | `true` | 网络不可达、超时、502/503/504 或局域网权限受阻；指数退避重试 |
| `-32003` | `rateLimited` | `true` | 上游 429 限流；尊重可选 `data.retryAfterMs` |
| `-32004` | `unsupported` | `false` | 不支持的能力、未知方法、或在 v0 调用写入方法；零写入拒绝 |
| `-32005` | `deviceOffline` | `false` | 目标设备离线；卡片置灰并保留陈旧读数标记 |
| `-32099` | `unknown` | `false` | 未分类错误；记录脱敏诊断日志 |
| `-32601`（标准） | `unsupported` | `false` | 方法未找到，归一为 `unsupported` |
| `-32700` / `-32600` / `-32602` / `-32603`（标准） | `unknown` | `false` | 帧/参数/内部错误；连续协议违规由监督器重启 |

---

## 八、安全不变量（Safety Invariants）

1. **统一告警严重度管线**：适配器通过 `snapshot` 中 `DeviceDescriptor.safetySignals` 或 `events.safetySignal` 上报的 `leak`（漏水）、`smoke`（烟雾）、`gas`（燃气）及 `lock`（门锁）信号，必须与内置源一样进入宿主唯一严重度表 `AlertSeverity`（`Sources/MijiaCore/AlertSeverity.swift`、`windows/src/core/alertSeverity.ts`、`Tests/Fixtures/alert_severity_golden.json`）及通知投递管线。
2. **不可压制、不可降级**：
   - 适配器只能上报客观信号种类（`kind`）、激活态（`active`）与事实证据（`evidence`），**严禁携带 `severity`、`interruptionLevel`、`suppress` 或 `mute` 字段**；宿主解析层若收到上述字段必须忽略或判定帧违规。
   - `leak`、`smoke`、`gas` 在宿主侧固定归类为 `AlertSeverity.alert`（生命安全级），在专注模式下仍穿透投递，适配器无权压制、延迟或降级为 `warning`。
3. **关闭展示不关闭安全读取（对齐 ADR-0023 第 4 条）**：即使用户在面板中隐藏了传感器类型展示，只要安全提醒开关处于开启状态，宿主仍可维持该适配器的只读安全读取与 `events.safetySignal` 订阅。

---

## 九、明确不在本 ADR 范围内（Out of Scope）

以下内容显式延后，不在 v0 契约中实现或承诺：

1. **代码签名与扩展市场（插件化路线阶段 6）**：复用 [ADR-0005](0005-update-signing-trust-chain.md) Ed25519 公钥对清单与二进制验签、升级权限扩张再确认弹窗、远端版本 blocklist 与官方/认证/社区三级市场，均留待阶段 6 另行评审落地。
2. **运行时代码（阶段 4）**：本 ADR 不新增任何 Swift / TypeScript / Rust 运行时子进程管理或适配器实现代码；首个只读参考适配器（如 LG webOS）将在独立 PR 中基于本契约实现。
3. **写控制通道（阶段 5）**：`control.execute` 的详细参数 Schema、回读策略与幂等审计存储，待阶段 4 只读参考适配器验证通过后在 v1 协议修订中补齐。
4. **原生 UI 嵌入**：永不支持适配器自带 HTML/JS/WebView 页面。

---

## 十、验证与门禁

- Schema 契约：[`Shared/adapterManifest.schema.json`](../../Shared/adapterManifest.schema.json)
- 黄金语料目录：[`Tests/Fixtures/adapter-protocol/`](../../Tests/Fixtures/adapter-protocol/)（覆盖合法/非法 manifest 及 `initialize`/`snapshot` JSON-RPC 2.0 请求响应对）
- 静态校验脚本：[`scripts/check_adapter_protocol.py`](../../scripts/check_adapter_protocol.py)（纯 Python 标准库，纳入 `scripts/check.sh --script-tests` 与 `--changed` 门禁）

## 参考与依据

- `docs/research/2026-11-23-deep-dive/00-SUMMARY.md` 第四节（插件化路线阶段 3）与 P2 事项
- `docs/research/2026-11-23-deep-dive/02-plugin-architectures-isolated.md` §9
- `docs/research/2026-11-23-deep-dive/05-global-vendors-matter-homekit.md` §7–§8
- `docs/research/2026-11-23-deep-dive/12-magpie-plugin-model.md` §12
- `docs/research/2026-11-23-deep-dive/13-desktop-extension-ecosystems.md` §6
- `Sources/MijiaCore/HomeAdapter.swift`、`Sources/MijiaCore/HomeProvider.swift`、`Sources/MijiaCore/HomeBackendDescriptor.swift`、`Sources/MijiaCore/ProcessSupervisor.swift`、`Sources/MijiaCore/SupervisedProcess.swift`、`Sources/MijiaCore/DeviceDeduplicator.swift`、`Sources/MijiaCore/AlertSeverity.swift`、`windows/src/core/homeProvider.ts`
