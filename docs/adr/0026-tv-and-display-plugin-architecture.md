# ADR-0026：跨品牌电视与外接显示器插件架构

日期：2026-11-26　状态：Proposed（关联 [ADR-0006](0006-dual-platform-implementation.md)、[ADR-0020](0020-backend-descriptor-table.md)、[ADR-0023](0023-host-owned-builtin-capabilities.md)、[ADR-0024](0024-out-of-process-adapter-protocol.md)）

## 背景

用户希望在一个菜单栏面板里控制智能电视、电视盒、Apple TV 和纯外接显示器。现有能力覆盖 Home Assistant `media_player.*` 与米家云端电视动作，但跨品牌局域网协议、DDC/CI 显示器和无 HA 的 Apple TV 仍缺统一入口。

[ADR-0023](0023-host-owned-builtin-capabilities.md) 禁止宿主进程加载第三方代码。[ADR-0024](0024-out-of-process-adapter-protocol.md) 定义了 v0 只读进程外协议，并把受控写入留到 v1。本 ADR 只定义电视与显示器的能力边界、进程外插件拆分方式和 v1 最小增量契约。本 ADR 不新增 Swift、TypeScript 或 Rust 运行时代码。

## 决定总览

采用双轨架构。轨道 A 由宿主自带，零额外安装成本。轨道 B 由独立进程承担，按用户需要安装。

1. 轨道 A 是宿主内置零成本能力。宿主增强 HA `media_player.*` 与 `remote.*` 实体支持，复用米家 MIoT 方向键动作，并加入可选原生 DDC/CI 外接显示器模块。该模块覆盖 Redmi G27U、A27U、G27 等纯显示器，禁用高危 `0xD6` 电源码。
2. 轨道 B1 是 Go 单二进制进程外主插件 `com.menubarhome.tv-bridge`。Go 构建固定 `CGO_ENABLED=0`。插件遵循 ADR-0024 v1 受控写入，声明 `permissions.network.internet: []`，只访问局域网。二进制下载复用 `go2rtc` 的按需下载与 SHA-256 校验模式。面板收起时宿主停止插件进程，常驻内存可回收至 0 MB。
3. 轨道 B2 是独立可选插件 `com.menubarhome.appletv-bridge`。没有 HA 且需要 Apple TV 控制的用户按需安装该插件，由插件在运行时准备 `pyatv`。宿主不捆绑 `pyatv`，也不替该插件预置任何凭据。

`HomeBackend` 保持 ADR-0020 的三值封闭枚举。电视和显示器设备通过 `sourceScope` 与设备合成层进入面板，不新增后端枚举值。

## 一、轨道 A：宿主内置零成本能力

宿主内置轨道只复用已有连接和随 App 分发的原生模块，不要求用户下载额外进程。

### 1.1 HA 与米家

- HA 侧增强 `media_player.*` 的播放状态、音量、静音、信源和媒体元数据读取，并在实体声明支持时映射 `remote.*` 方向键与确认键。
- 米家侧复用 MIoT `television` 的方向键动作。冷开机不列入保证范围，电视必须处于可响应状态。
- 所有写入仍经过 ADR-0023 的宿主写入门、锁屏守卫和高风险二次确认。

### 1.2 原生 DDC/CI 外接显示器

DDC/CI 模块只处理显示器能可靠回读的 VCP 能力。

| VCP 码 | 用途 | 约束 |
| --- | --- | --- |
| `0x10` | 亮度 | 仅当显示器报告该码可写时开放 |
| `0x60` | 输入源 | `DP1=15`、`DP2=16`、`HDMI1=17`、`HDMI2=18`、`USBC=27` |
| `0x62` | 音量 | 仅当显示器报告该码可写时开放 |
| `0x8D` | 静音 | 仅当显示器报告该码可写时开放 |
| `0xD6` | 电源 | 禁用，不接受读取、写入或批量透传 |

宿主必须把 `0xD6` 列入 `forbiddenVcpCodes`。任何命令、自动发现规则和 UI 菜单都不得写入该码。

macOS 上部分 Redmi 显示器通过 `AppleDCPMCDP29XX -> 0xB7` 桥片暴露 DDC/CI。插件和宿主按 IOKit 服务路径识别桥片，不按显示器营销名称猜测能力。

## 二、轨道 B：进程外插件

### 2.1 轨道 B1，`com.menubarhome.tv-bridge`

B1 处理跨品牌局域网电视，作为主插件覆盖 Xiaomi、Redmi、TCL、雷鸟、通用 AOSP、LG、Android TV、Samsung、Sony 和 Hisense 的已知协议。插件遵守以下边界。

- 单二进制形态，构建参数固定为 `CGO_ENABLED=0`。
- 清单声明 `permissions.network.internet: []`。插件只访问用户局域网地址和已发现的本地设备。
- 协议画像来自 `Shared/tvProtocolCatalog.json`。插件不得自带另一份互斥协议表。
- 二进制按需下载，下载流程复用 `go2rtc` 的 URL 固定、SHA-256 校验和失败重试策略。校验失败时不解压、不执行。
- 面板收起时宿主发送 `shutdown`，进程退出后常驻内存回收至 0 MB。再次展开时按清单重新启动。
- 凭据只在宿主安全存储中保存。插件通过 ADR-0024 的运行时注入获得短期租约或用户输入项，清单和目录都不保存密钥值。

### 2.2 轨道 B2，`com.menubarhome.appletv-bridge`

B2 只服务没有 HA 的 Apple TV 用户。插件独立安装、独立启停，不进入默认连接组合。它保持与 B1 相同的传输、清单和监督规则，仅在清单设备种类、配对方式和运行时依赖上不同。

选择拆分的原因是 Apple TV 的能力探测依赖 `pyatv` 的协议栈，而绝大多数电视用户不需要这份依赖。把 B2 从 B1 拆开后，B1 继续保持单二进制和小内存占用。

## 三、类 Apple TV Now Playing 四维能力边界

电视与媒体卡片只展示协议能证明的能力。Now Playing 分为四维。

| 维度 | 允许展示 | 拒绝条件 |
| --- | --- | --- |
| 播放状态 | `playing`、`paused`、`stopped`、`idle` 等协议明确状态 | 协议只回报在线状态时伪装播放中 |
| 元数据 | 标题、作者、专辑、来源应用 | 协议没有字段时用占位文本冒充真实内容 |
| 封面 | 通过 `media.fetchArtwork` 获取的本机受限路径 | 路径含 `..`、绝对路径或外部 URL |
| 进度与跳转 | 协议同时报告 `duration + position + canSeek` 时渲染可拖动进度条 | 任一字段缺失或为未知时不画假进度条 |

国产电视原生流媒体 App，爱奇艺、优酷、腾讯视频、芒果 TV 和哔哩哔哩，受 `MediaSession` 与沙盒限制。宿主和插件不承诺这些 App 的播放进度、封面或精确播放态。插件可以把未知字段上报为不可用，不得用计时器推算进度。

`canSeek: true` 是渲染进度条的唯一开关。宿主收到 `canSeek: false` 时隐藏拖动条，只保留状态文本。

## 四、ADR-0024 v1 面向 TV/Media 的最小增量方法表

v1 只增加下表方法。v0 的只读方法保持原样，ADR-0024 的 `grantId` 与 `capabilityGeneration` 预留约束在这里细化。

| 方法 | 方向 | 参数摘要 | 返回或形态 | 不变量 |
| --- | --- | --- | --- | --- |
| `control.execute` | 宿主 → 插件 | `{grantId, capabilityGeneration, nativeId, verb, args?}` | `{accepted, applied?, rejectedReason?}` | 缺 `grantId` 或代次过期时零副作用拒绝；`verb` 必须来自封闭表 |
| `host.contextChanged` | 宿主 → 插件 | `{scope, active, reason}` | 通知 | 面板收起后插件必须停止非必要轮询 |
| `media.fetchArtwork` | 宿主 → 插件 | `{nativeId, path, maxBytes?}` | `{mimeType, bytesBase64}` | `path` 只允许受限相对路径；路径穿越返回错误 |
| `pairing.begin` | 宿主 → 插件 | `{nativeId, method}` | `{pairingId, instructions}` | 只返回用户下一步，不返回任何密钥值 |
| `pairing.submit` | 宿主 → 插件 | `{pairingId, inputs}` | `{paired, nativeId?}` | 用户确认后才提交；插件不得缓存输入值 |
| `pairing.cancel` | 宿主 → 插件 | `{pairingId, reason?}` | `{cancelled}` | 取消后 `pairingId` 立即失效 |
| `events.mediaPlaybackChanged` | 插件 → 宿主 | `{nativeId, playbackState, title?, artist?, durationSec?, positionSec?, canSeek, artworkPath?, ts}` | 通知 | `canSeek` 为真时三个进度字段必须齐备且自洽 |

`control.execute` 的 `capabilityGeneration` 来自宿主能力代次。插件比对本地握手记录的代次，不一致即拒绝。`grantId` 是一次写入授权，不复用、不落盘、不进入日志。

`media.fetchArtwork` 的路径白名单只允许形如 `artwork/<year>/<month>/<name>` 的相对路径。插件拒绝 `..`、绝对路径、反斜杠和 URL scheme。

## 五、封闭命令动词表

`control.execute.verb` 只能取表中的值。插件不得接受 `rawCommand`、`shell`、`http.request` 或任意 VCP 写入。

| 动词 | 参数 | 宿主映射 | 适用轨道 |
| --- | --- | --- | --- |
| `power.set` | `{isOn}` | HA `media_player.turn_on/off`，MIoT 电视电源，Tizen/WoL 唤醒 | A、B1 |
| `display.brightness.set` | `{percent}` | DDC/CI `0x10` | A |
| `volume.set` | `{level}` | `mediaSetVolume` 或 DDC/CI `0x62` | A、B1、B2 |
| `mute.set` | `{isMuted}` | 媒体静音或 DDC/CI `0x8D` | A、B1、B2 |
| `input.select` | `{source}` | `mediaSelectSource` 或 DDC/CI `0x60` | A、B1 |
| `remote.key` | `{key}` | `pressButton`，按键名来自协议目录 | A、B1、B2 |
| `media.play` | `{}` | HA `media_player.media_play`，`pyatv` play | B1、B2 |
| `media.pause` | `{}` | HA `media_player.media_pause`，`pyatv` pause | B1、B2 |
| `media.stop` | `{}` | HA `media_player.media_stop`，`pyatv` stop | B1、B2 |
| `media.seek` | `{positionSec}` | 仅在 `canSeek == true` 时允许 | B1、B2 |

verbs 表同时写入 `Shared/tvProtocolCatalog.json` 的 `closedCommandVerbs`，由 `scripts/check_tv_catalog.py` 校验三处一致。

## 六、共享数据目录与校验

`Shared/tvProtocolCatalog.json` 是 macOS、Windows、Go 插件共读的纯数据目录。它声明协议画像、传输端口、发现方式、按键码表、VCP 白名单、能力边界和限制说明。目录不含任何密钥、令牌、配对码值或硬编码凭据键名。

`Tests/Fixtures/tv-plugin/tv_catalog_golden.json` 固定协议 ID、必填字段、封闭动词表和关键协议事实。`Tests/Fixtures/tv-plugin/v1_control_rpc_pairs.json` 给出合法与非法 RPC 对，覆盖缺 `grantId`、`host.contextChanged`、`events.mediaPlaybackChanged`、`media.fetchArtwork` 路径穿越和配对流程。

`scripts/check_tv_catalog.py` 使用 Python 标准库做静态校验，纳入 `scripts/check.sh` 的契约检查与脚本自检。校验项包括唯一 ID、必填字段、`0xD6` 禁用、秘密键名禁用、黄金语料一致性和 RPC 夹具预期结果。

## 与既有 ADR 的关系

- **ADR-0006**：两端不共享运行时代码，改为共读同一份协议目录和黄金语料，符合该 ADR 的一致性约束。
- **ADR-0020**：不新增 `HomeBackend` 枚举，不把电视协议变成开放后端。
- **ADR-0023**：宿主继续持有写入门、能力代次、锁屏守卫和引用判决。进程外插件只执行宿主授权后的动作。
- **ADR-0024**：本 ADR 是 v1 增量提案，不改 v0 只读契约，也不修改 v0 Schema 与校验脚本。受控写入沿用 `grantId` 与 `capabilityGeneration` 预留约束。

本 ADR 与已接受的 ADR-0006、ADR-0020、ADR-0023 不冲突。ADR-0024 仍为 Proposed，本 ADR 只在其预留边界上补充 TV/Media 最小方法集。

## 后果

- 新增电视协议时先更新目录和黄金夹具，再实现插件映射。两端 UI 与 Go 插件共享同一份事实源。
- DDC/CI 电源写入没有合法路径。任何未来新增 VCP 写码都必须经过目录白名单和门禁。
- 纯显示器无需 HA 或云端账号即可接入。Apple TV 用户按需承担 `pyatv` 依赖。
- 后续宿主实现必须按 v1 方法表拒绝未知动词。插件实现不得自行扩展命令词表。

## 验证

- 目录与夹具：`python3 scripts/check_tv_catalog.py`
- 脚本自检：`python3 scripts/check_tv_catalog.py --self-test`
- 项目门禁：`bash scripts/check.sh` 或 `bash scripts/check.sh --changed`

## 参考

- `Shared/tvProtocolCatalog.json`
- `Tests/Fixtures/tv-plugin/tv_catalog_golden.json`
- `Tests/Fixtures/tv-plugin/v1_control_rpc_pairs.json`
- `scripts/check_tv_catalog.py`
- `docs/research/2026-11-23-deep-dive/04-china-vendors.md`
- `docs/research/2026-11-23-deep-dive/05-global-vendors-matter-homekit.md`
- `docs/research/2026-11-24-full-survey/04-vendor-protocols-coverage.md`
