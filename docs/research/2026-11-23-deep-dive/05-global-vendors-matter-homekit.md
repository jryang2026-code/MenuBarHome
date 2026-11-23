# 05 国际厂商与标准协议的接口差异及优秀客户端实现

调研日期：2026-11-23　范围：Philips Hue / TP-Link Kasa-Tapo / SwitchBot / Govee / Yeelight / LIFX / Nanoleaf / Shelly / Ecobee / Nest SDM / Apple HomeKit / Matter，以及对标库的 transport-protocol-device 分层与能力探测机制；落点是 ADR-0017、ADR-0020、`HomeProvider.swift`、`homeProvider.ts` 的统一 Adapter SPI 草案。

克隆根：`~/.cache/mbh-research-clones/`（只读源码，未运行任何克隆仓库里的脚本）。实读版本：

| 仓库 | commit | 提交日期 | 用途 |
| --- | --- | --- | --- |
| `home-assistant-libs_aiohue` | `31c49063` | 2026-11-16 | Hue v2 客户端、SSE 事件流 |
| `python-kasa__python-kasa` | `7a5b3a26` | 2026-11-21 | transport/protocol/device 三层范本（旧镜像 `rytilahti_python-kasa` 停在 2024-11-13，已弃用其结论） |
| `postlund_pyatv` | `b277a4c8` | 2026-06-19 | 多协议合一、Feature 能力表、Relayer |
| `openhue_openhue-cli` | `46b2c92f` | 2026-11-07 | Hue 声明式场景 / CLI 家庭模型 |
| `home-assistant-libs_aioshelly` | `5b480380` | 2026-11-22 | Shelly Gen2 RPC + WebSocket + mDNS |
| `frawau_aiolifx` | `3102e3e0` | 2026-05-26 | LIFX UDP 的 ACK/response 分级 |
| `Galorhallen_govee-local-api` | `e70c3a4a` | 2026-11-19 | Govee LAN 三端口模型 + SKU 能力表 |
| `stavros_python-yeelight` | `e5c9ce45` | 2026-11-11 | Yeelight SSDP 命令白名单 + 通知 socket |
| `loebi-ch_aionanoleaf2` | `ac91c50f` | 2026-10-19 | Nanoleaf REST + SSE + 抖动退避 |
| `OpenWonderLabs_SwitchBotAPI` | `0db92c78` | 2026-11-20 | v1.1 签名、Webhook |
| `homebridge_HAP-NodeJS` | `74b1700a` | 2026-11-20 | HAP 服务端与 EVENT 推送 |
| `nickustinov_itsyhome-macos` | `5bd8dd8d` | 2026-11-18 | Catalyst + AppKit bundle 的真实工程形态；HAP 虚拟桥 |
| `matter-js_matter.js` | `42aab0c0` | 2026-11-23 | 纯 TS Matter 控制器 |
| `home-assistant-libs_python-matter-server` | `4c820ed1` | 2026-06-23 | native `chip` 包装与多管理员 API |

另：本机 SDK 实测（macOS 27.2 SDK，Xcode 27.2），用于核对 `Matter.framework` 可用性；Home Assistant 集成清单与 Govee/Nanoleaf/Shelly 依赖通过 `raw.githubusercontent.com` 读取 `dev` 分支 `manifest.json`（2026-11-23）。

**相对已有调研的增量**（不是重复）：`similar-projects-analysis.md` 与 `2026-11-05-ecosystem-benchmark.md` 已覆盖 HA/米家/HomeKit 周边与 Matter 1.4 的品类面，但没有拆过 Hue SSE、kasa 的 transport 分层、pyatv 的 Feature 表，也没有实测 `Matter.framework` 的控制器工厂 API。本文的纠错点有两处：**(1)** 「Matter.framework 只能当配件侧」不准确——控制器工厂 API 在 macOS SDK 里是完整的、可编译的，真正卡住的是配网与 entitlement；**(2)** Itsyhome 不只有「Catalyst 主 App + AppKit bundle」这一条路，它还有一条不依赖 HomeKit entitlement 的反向 HAP 桥，ADR-0017 未记录。

---

## 0. 结论先行

1. 厂商 API 的差异可以切干净：transport（发现/帧/加密/会话）、protocol（对象模型与写语义）、device（能力与卡片）三层；python-kasa 用一张 6 条的「protocol × transport」映射表加两处动态覆盖就覆盖了全部 SKU。**【源码】** `python-kasa__python-kasa:kasa/device_factory.py:190-256`
2. 推送的难点不是「有没有 SSE/WebSocket」，而是**保活、重连、续传**三件事：aiohue 因为 Hue 的 EventStream 没有 keepalive，只能每 60 秒改名一个 geofence 客户端来「制造事件」探活。**【源码】** `home-assistant-libs_aiohue:aiohue/v2/controllers/events.py:25-26, 180-230, 290-320`
3. 局域网的「写确认」粒度差三个数量级：LIFX 有「ACK」与「ACK+response」两级 + 序号重传，Govee/Yeelight 基本是 fire-and-forget；Hue 的写方法不返回新状态，权威状态只从事件流回来（`LightsController.turn_on` 只发 PUT，缓存由 `EventStream` 更新）。→ 我们的乐观写 + 回读不能全局一套参数，必须由适配器声明。**【源码】** `frawau_aiolifx:aiolifx/aiolifx.py:53-54, 331-405`；`Galorhallen_govee-local-api:src/govee_local_api/controller.py:704-800`；`home-assistant-libs_aiohue:aiohue/v2/controllers/lights.py:32-56`
4. 能力探测有四条成熟路子：设备自报命令白名单（Yeelight SSDP 的 `support` 字段）、组件协商（kasa 的 `component_nego`）、特性注册表（pyatv 的 `FeatureName` + `FeatureInfo(state/options)`）、SKU 静态表（Govee）。四条可以组合：先协商，拿不到再查表。**【源码】** `stavros_python-yeelight:yeelight/main.py:517-553`；`python-kasa__python-kasa:kasa/smart/smartdevice.py:221-245`；`postlund_pyatv:pyatv/interface.py:86-90`
5. pyatv 的 `FeatureState` 是「三值」而不是布尔：`Available / Unavailable / Unsupported`，把「协议不支持」和「设备此刻不可用」分开。我们的 `CapabilityManifest` 目前只有产品级 `supported/partial/unsupported`，缺设备级的「暂时不可用」。**【源码】** `postlund_pyatv:pyatv/protocols/mrp/__init__.py:960-1022`；对照 `Sources/MijiaCore/CapabilityManifest.swift:3`
6. HomeKit 在 macOS 上不是「没适配好」，而是三道硬边界叠在一起：SDK 只有 macabi 切片、`com.apple.developer.homekit` 是受限 entitlement、首次使用还要 TCC 的 `NSHomeKitUsageDescription`。Itsyhome 的绕法是**把主 App 做成 Catalyst**，原生 AppKit 反过来只是它加载的 bundle；它还有第二条路——用 `hap-swift` 起虚拟 HAP 桥，把 HA 设备反向暴露给 Apple 家庭，不需要 HomeKit entitlement。**【源码】** ADR-0017 第 19-66 行（本机实测）+ `nickustinov_itsyhome-macos:Itsyhome/iOS/AppDelegate.swift:22-66`、`project.yml:29-71`、`macOSBridge/HAPBridge/VirtualBridgeService.swift:1-70`
7. `Matter.framework` 在原生 macOS 上**能编译**完整的控制器工厂 API：本次用 `MTRStorage` + `MTRDeviceControllerFactory.sharedInstance().start(_:)` 对 `arm64-apple-macos14.0` 做 typecheck，退出码 0。但「能编译」不等于「能配网」：Apple 的合规路径是 `MatterSupport` 扩展（`com.apple.matter.support.extension.device-setup`），BLE/Thread 配网的第三方 entitlement 公开资料里没有明确答案。**【源码】本机实测；【文档】** [Apple Matter](https://developer.apple.com/apple-home/matter/)、[MatterSupport](https://developer.apple.com/documentation/mattersupport/adding-matter-support-to-your-ecosystem)
8. python-matter-server 本质是 native CHIP 的 Python 包装（`from chip.clusters import Attribute`），而 matter.js 是纯 TS/Node。对我们的意义：Windows（Tauri）可以走 Node sidecar 顺理成章，macOS 则多一个进程与打包面；ADR-0023 允许的正是「进程外」。**【源码】** `home-assistant-libs_python-matter-server:matter_server/server/sdk.py:1-20`；`matter-js_matter.js:packages/matter.js/src/CommissioningController.ts:315-360`
9. 多管理员不是 API 问题而是产品问题：设备第一个 fabric 的控制器必须「开放配对窗口」并给出临时码，第二个生态才能加入；Apple 叫 Turn On Pairing Mode，Aqara 官方把 M3/M100 定义为 Matter 控制器 + 桥接器，米家一侧没有公开的「开放配对窗口」文档（未查到）。**【文档】** [Apple 支持](https://support.apple.com/en-us/102135)、[Aqara 开放平台](https://opendoc.aqara.com/docs/AqaraDevice/Hub-M3.html)
10. 我们已有的 `OptimisticField` + `ReadBackTickets` + `ControlReadBack` 已经把「乐观写—确认回读—失败回滚」做完了约七成；真正缺的是**让适配器声明自己的推送/确认/错误语义**，以及 Windows 的 `HomeProvider` 只有一个 `execute`。**【源码】** `Sources/MijiaCore/OptimisticField.swift:5-30`、`ReadBackTickets.swift:1-56`、`HomeProvider.swift:28-37`、`windows/src/core/homeProvider.ts:24-30`

---

## 1. Philips Hue API v2 与 aiohue

### 1.1 资源模型：一个「设备」被拆成多个可独立更新的资源

Hue v2（CLIP v2）不再有 v1 的「light 对象塞满所有字段」，而是：

- `device`：物理设备（型号、固件、zigbee 连接）
- `light` / `grouped_light`：可控制的光，能力用**可选子对象**表达（`dimming`、`color`、`color_temperature`、`gradient`、`effects`、`dynamics`、`alert`、`signaling`）
- `room` / `zone` / `bridge_home`：空间层级，`grouped_light` 挂在 room/zone 上
- `scene`：`actions[]`，每条 `target` + `action{on, dimming, color, color_temperature, gradient, effects, dynamics}`
- `entertainment_configuration`：娱乐区，`channels[]` 里每个 channel 是若干 `segment` 的引用，带 xyz 位置

关键点：**能力是「字段存在与否」而不是类型列表**。`GroupedLight` 的注释直接写明 `on` 是「任一盏亮即 true」、`dimming.brightness` 是「只对亮着的灯取平均」——这类聚合语义必须由协议层定义，不能指望 UI 猜。**【源码】** `home-assistant-libs_aiohue:aiohue/v2/models/grouped_light.py:26-52`、`scene.py:13-52`、`entertainment_configuration.py:14-80`

aiohue 的分层很干净：`HueBridgeV2`（传输 + 认证 + 限流）→ 各 `*Controller`（一个资源类型一个，内部 `dict[id, dataclass]` 缓存 + 订阅）→ `models/*`（wire dataclass，带 `*Put` 写对象）。写路径用**最小 delta 对象**：`LightPut` 只填本次改的 feature，未填的不动。`set_state` 里连「effect 必须走 `effects_v2` 才能同时改颜色」这种厂商怪癖都被吸收在协议层。**【源码】** `home-assistant-libs_aiohue:aiohue/v2/controllers/lights.py:78-171`

### 1.2 SSE 事件流：spec 的一半 + 厂商补丁

`EventStream` 的读取循环（`__event_reader`）做了四件事：

1. **续传**：把上一条事件的 `id:` 存进 `_last_event_id`，重连时作为 `last-event-id` 请求头发回。这是标准 SSE 语义，Hue 支持。**【源码】** `aiohue/v2/controllers/events.py:180-190`
2. **读超时**：`sock_read=90s`，90 秒没有一行数据就判定连接死掉（`CONNECTION_TIMEOUT = 90`）。**【源码】** `events.py:25, 196-200`
3. **重连节奏**：`reconnect_wait = min(2 * connect_attempts, 600)`——等待是线性的 `2s, 4s, 6s…`（上限 600s），成功一次把 `connect_attempts` 重置为 1；不是指数退避，也不加抖动。**【源码】** `events.py:224-236`
4. **保活补丁**：Hue 的 EventStream 不发 keepalive，也没有 ping。aiohue 的做法是每 60 秒创建/改名一个 geofence 客户端（`aiohue_xxx`），改名必然产生一条 `update` 事件，于是「有没有收到事件」成了探活信号。注释里写得很直白：*"Oh yeah, this is a major hack and hopefully it will only be temporary"*。**【源码】** `events.py:290-320`

事件分发是「按资源类型过滤」的：`BaseResourcesController.initialize()` 先全量拉一次 `clip/v2/resource/<type>`，把每条当作 `RESOURCE_ADDED` 走同一套 `_handle_event`，然后订阅后续事件；重连时再次全量拉，走 `__handle_reconnect` 做 diff。**「全量 + 增量走同一条状态机」** 是他们避免两份代码的关键。**【源码】** `aiohue/v2/controllers/base.py:57-85`、`aiohue/v2/controllers/events.py:240-256`

### 1.3 限流与错误：503/429 是常态

`HueBridgeV2.request` 对 503（桥忙）与 429（限流）最多重试 25 次，第 n 次前睡 `0.25 * n` 秒；403 直接抛 `Unauthorized`；400 会先尝试解析 CLIP 的 `errors[0]` 再抛，避免只剩一句 `400, message='Bad Request'`。**【源码】** `aiohue/v2/__init__.py:27, 165-205`

这条对我们是直接可抄的：**「桥忙」不是网络错误**，要单独归一化成可重试错误，并带 `retryAfter`。

### 1.4 Entertainment：一条与 REST 完全不同的数据面

娱乐区不是 REST 轮询能做的：`PUT /clip/v2/resource/entertainment_configuration/{id}` body `{"action":"start"}` 激活后，客户端要开一条 **DTLS 1.2 PSK** 的 UDP 会话到桥的 **2100** 端口，密码套件固定 `TLS_PSK_WITH_AES_128_GCM_SHA256`，PSK identity 是配对时拿到的 `username`（也就是 application key），PSK secret 是 `clientkey`；之后按 `HueStream` v2 帧持续推流（约 50 Hz 发送，桥再抽取到 Zigbee 的 25 Hz；常见娱乐区上限 10 盏灯，单包最多 20 通道——两份二手资料口径不完全一致）。**【检索】** [Hypercolor 硬件说明](https://hyperb1iss.github.io/hypercolor/hardware/hue/)、[IoTech 分析](https://iotech.blog/posts/philips-hue-entertainment-api/)（2026-11-23 读取；未查 Philips 官方 PDF）

对我们的含义：**同一个厂商可以有两套完全不同的 transport**（HTTPS+SSE 与 UDP+DTLS），适配器 SPI 不能假设「一个适配器 = 一种传输」。真要做娱乐区，它应该是一个独立的 capability（`streaming`），而不是灯光写入的一个字段。

---

## 2. TP-Link Kasa / Tapo：python-kasa 的三层范本

### 2.1 transport 层：只负责「把一段文本发出去并拿回文本」

`BaseTransport` 只有五个抽象成员：`default_port`、`credentials_hash`、`send(request: str) -> dict`、`close()`、`reset()`，超时默认 5 秒。**【源码】** `python-kasa__python-kasa:kasa/transports/basetransport.py:1-60`

具体实现按「加密/握手方式」分：

- `XorTransport`：老 Kasa 的固定 key 异或
- `KlapTransport`：两次握手（handshake1 拿 `local_seed/remote_seed/auth_hash`，handshake2 用 `sha256(remote_seed + auth_hash)` 确认），之后 AES-CBC + 递增序列号
- `KlapTransportV2`：同一套 KLAP 外层，换一套 hash 推导（`kasa/transports/klaptransport.py:418`）
- `AesTransport` / `SslAesTransport` / `SslTransport`：Tapo 新固件与摄像头

`KlapTransport` 里还有两个工程细节值得抄：`_handshake_lock = asyncio.Lock()`（并发调用不会同时握手）、`_handshake_session_expired()`（会话过期自动重握）。**【源码】** `klaptransport.py:1-45, 121-146, 287-330`

### 2.2 protocol 层：只负责「请求/响应语义」

`BaseProtocol.query(request: str | dict, retry_count=3)`。`SmartProtocol` 是 JSON-RPC 风格的多请求批处理（`_execute_multiple_query`），会把多个 `method` 合成一帧，回来再按 `id` 拆；错误码映射成 `AuthenticationError` / `DeviceError`。**【源码】** `kasa/protocols/protocol.py:82-107`、`kasa/protocols/smartprotocol.py:90-160, 254-360`

### 2.3 device 层：先连上、再决定「这是个什么东西」

`device_factory.connect` 的顺序是：

1. 用 `get_protocol(config)` 从 `deviceconfig` 里的 `device_family + encryption_type + https` 查出（protocol, transport）组合；
2. 连接后先取设备信息与 `component_nego`（能力协商）；
3. 用 `get_device_class_from_sys_info` / `get_device_class_from_family` 选 `IotDevice` / `SmartDevice` / `IotPlug` / `IotBulb` … 子类；
4. 设备类在做 `_negotiate()` 时拿到 `component_nego.component_list`（`{id: version}`），`_initialize_modules()` 按 `Module.requires` 建模块表。

那张 6 条的映射表在 `get_protocol`（`IOT.XOR / IOT.KLAP / SMART.AES / SMART.KLAP / SMART.KLAP.HTTPS / SMART.AES.HTTPS`），表外还有 3 处特例（摄像头、门铃、老固件扫地机），以及一处「查表之后再按 `login_version >= 2` 换成 KLAPv2」的动态覆盖。**【源码】** `kasa/device_factory.py:190-256`

这就是我们要的形状：**表 + 覆盖，而不是 if/else 树**。

### 2.4 能力探测与降级

`component_nego` 是设备自报的「组件 + 版本」，python-kasa 把它变成模块表；模块声明 `requires`，缺依赖就不建。UI 层拿到的不是「这个型号支持什么」，而是「这台设备此刻报告了什么」。**没有任何 SKU 白名单**。**【源码】** `kasa/smart/smartdevice.py:221-245, 418-460`

代价是：协议版本升级（组件增删）会直接改变能力面，必须有 fixture 测试兜底。仓库里 `SUPPORTED.md` 是「人工验证过的型号清单」，只用于文档，不参与运行时判断。**【源码】** `python-kasa__python-kasa:SUPPORTED.md:1-10`

---

## 3. pyatv：一个设备、多条协议、一张特性表

pyatv 面对的是 Apple TV 同时开 MRP / DMAP / AirPlay / RAOP / Companion 五条通道的现实。它的解法是三层：

### 3.1 接口层（`pyatv/interface.py`）

定义 `RemoteControl`、`Metadata`、`Power`、`Audio`、`Playing` 等抽象接口，外加一个**全局特性注册表**：`@feature(index, name, doc)` 把方法/属性登记成 `FeatureName`，`FeatureInfo(state, options)` 返回三值状态：

- `Available`：此刻可用（可以带 `options`，比如音量范围）
- `Unavailable`：协议支持、设备此刻不给（例如 metadata 里没有 artwork）
- `Unsupported`：这条协议根本不支持

**【源码】** `postlund_pyatv:pyatv/interface.py:86-109`；`pyatv/protocols/mrp/__init__.py:960-1022`（同一特性在不同播放状态下可用性会变：正在播放时 `Pause` 可用、`Play` 不可用）

### 3.2 转发层（`pyatv/core/relayer.py` + `facade.py`）

`Relayer(interface, priority)` 按 `DEFAULT_PRIORITIES = [MRP, DMAP, Companion, AirPlay, RAOP]` 把调用转给第一个实现了该方法的协议；都没实现就抛 `NotSupportedError`。`FacadeRemoteControl` 这类类只是「把接口方法转发给 relayer」，没有业务逻辑。**【源码】** `pyatv/core/relayer.py:1-90`、`pyatv/core/facade.py:38-80`

### 3.3 状态层（`StateProducer` + `push_updater`）

每个协议把自己的推送（MRP 的 protobuf、DMAP 的 HTTP 长轮询…）归一成 `StateMessage` / `UpdatedState`，再由 `StateProducer` 广播；`heartbeater(name, sender, failure, interval=30, retries=1)` 提供统一的保活循环，失败两次就判定协议掉线。**【源码】** `pyatv/core/protocol.py:41-80`

### 3.4 对我们的直接启发

- 「一个设备多条通道」不是靠 `switch backend`，而是靠**接口 + 优先级 + 每特性可用性**；
- 能力不是静态 bool，而是**带原因的枚举**；UI 可以据此决定「置灰 + 提示」还是「隐藏」；
- `options` 可以承载范围（音量 0-100、色温 2000-6500K），正好对应我们 `DeviceFacets` 里的控件范围。

---

## 4. 其余厂商：六种「局域网」与两种「云」

### 4.1 SwitchBot API v1.1：签名与 Webhook

- 鉴权：`sign = base64(HMAC-SHA256(secret, token + t + nonce))`，头里带 `Authorization: token`、`sign`、`t`、`nonce`。
- **官方文档自相矛盾**：正文写 `HMAC-SHA256(token + t, secret).toUpperCase()`（无 nonce、转大写），同一页所有语言的示例代码都是 `token + t + nonce` 且 base64、不转大写。实现必须以示例代码为准，并把这条写进适配器注释，否则接一次错一次。**【源码】** `OpenWonderLabs_SwitchBotAPI:README.md:159-260`
- Webhook：`POST /v1.1/webhook/setupWebhook` 注册一个 HTTPS URL，所有设备与场景事件推到这里；这是云到端的单向推送，没有本地通道，且需要公网可达。**【源码】** `README.md:1358-1430`

### 4.2 Govee LAN：三个 UDP 端口 + 一张 SKU 能力表

- 发现：向 `239.255.255.250:4001` 发扫描包
- 状态：设备把状态推到客户端的 `4002`
- 命令：客户端发到设备的 `4003`
- 无鉴权、无加密；`GoveeController` 默认 `update_enabled=True`（定时主动查询）、`evict_enabled=False`（可选 30 秒没消息就踢掉）

**【源码】** `Galorhallen_govee-local-api:src/govee_local_api/controller.py:44-46, 71-140, 704-800`

能力靠 `light_capabilities.py` + `SUPPORTED_DEVICES.md` 的 SKU 表（不同型号支持 segment / scene / 色温的范围不同）。**这是「无法协商时只能查表」的现实样本**，也解释了为什么 Govee 的 HA 集成是 `local_push` 但仍然有 `update_interval`。

### 4.3 Yeelight LAN：设备自报命令白名单

- 发现：SSDP `M-SEARCH` 到 `239.255.255.250:1982`，响应里有 `Location: yeelight://ip:55443` 和 **`support:` 一串命令名**（`get_prop set_default set_power toggle set_bright set_scene ... start_cf stop_cf set_ct_abx set_adjust adjust_bright adjust_ct`）。
- 控制：TCP 55443，一行一个 JSON（`{"id":n,"method":"set_power","params":["on",...]}`）。
- 推送：另开一条 TCP 连接，设备在属性变化时发 `{"method":"props","params":{...}}`。
- 低延迟：music mode 改成 UDP 直发（牺牲可靠性换实时）。

**【源码】** `stavros_python-yeelight:yeelight/ssdp_discover.py:24-60`、`yeelight/main.py:517-553, 677-720`

`get_capabilities()` 直接把 SSDP 响应里的 `support` 当作「这台设备会哪些命令」——**白名单即能力表**，比任何型号表都准。

### 4.4 LIFX LAN：把「确认」做成 API 参数

LIFX 的 UDP 报文头允许同时置 `ack_required` 与 `res_required`，于是客户端有三档：

- `fire_and_forget`：只发，不等
- `req_with_ack`：等 ACK，超时重传
- `req_with_resp`：等 ACK + 状态响应（可用来做写后确认）

`try_sending` 默认 `timeout=0.5s`、`max_attempts=3`，全失败就 `unregister()` 把设备标记为不可达。**【源码】** `frawau_aiolifx:aiolifx/aiolifx.py:53-54, 331-405, 376-450`

这是「写确认等级」最干净的实现：**等级不是适配器的全局属性，而是每次写可以选的参数**（默认值来自适配器）。

### 4.5 Nanoleaf：REST + SSE + 抖动退避 + 用 payload 形状探测能力

- REST：`http://host:port/api/v1/{token}/...`
- 事件：SSE `http://host:port/api/v1/{token}/events?`，事件类型 `StateEvent` / `LayoutEvent` / `EffectsEvent` / `TouchEvent`；触摸高频流另开 UDP。
- 重连：指数退避 1s → 30s（×2，attempt 上限 16），并且**加抖动**：结果落在 `[ceiling/2, ceiling]`，避免所有客户端同时重连。
- 能力探测：`_supports_events = "panelLayout" in data and data["panelLayout"] is not None`——Essentials 系列没有 `panelLayout`，也就不支持事件流。

**【源码】** `loebi-ch_aionanoleaf2:aionanoleaf2/nanoleaf.py:102-128, 245-247, 510-518, 683-730, 895-920`；`aionanoleaf2/events.py:43-160`

「用响应里有没有某个字段来判断能力」看起来脆弱，但在厂商没有 capability 字段时，这是唯一不需要维护型号表的办法。

### 4.6 Shelly Gen2：JSON-RPC over WebSocket，帧类型三分

- 发现：mDNS，先查 `_shelly._tcp.local.` 再退到 `_http._tcp.local.`（`aioshelly/zeroconf.py:17-40`）。
- 传输：`ws://host/rpc`（或 HTTP POST `/rpc`）。
- 帧：统一 `{id, src, dst, method, params}`；`handle_frame` 分三种——有 `method` 且有 `id` 是「对方向我调用，要回」；有 `method` 无 `id` 是通知（`NotifyStatus` / `NotifyEvent`）；有 `id` 无 `method` 是响应。未知/迟到的 `id` 只记日志，不炸。
- 鉴权：SHA-256 的 digest 挑战（`realm/nonce/nc/cnonce/response`），`nonce` 会轮换，`nc` 递增。

**【源码】** `home-assistant-libs_aioshelly:aioshelly/rpc_device/wsrpc.py:105-155, 365-425`；`aioshelly/zeroconf.py:1-70`

### 4.7 Ecobee 与 Nest SDM：两种云的极端

| | Ecobee | Nest SDM |
| --- | --- | --- |
| 鉴权 | OAuth2，第三方设备用 PIN 授权；access token 短期，refresh token 约 1 年 | Google OAuth2 + Device Access 项目 |
| 读 | REST 轮询（`GET Thermostat Summary` 就是为轮询设计的） | REST `GET /enterprises/{project}/devices/{id}` |
| 推 | 文档导航里的 Push API 条目被注释掉，页面主推 `GET Thermostat Summary` 轮询 | Cloud Pub/Sub，事件**不保证有序**，要用 `timestamp` 校正；不活跃 6 个月 refresh token 会失效 |
| 备注 | scope `smartRead/smartWrite/ems` | 2026-11-30 前必须迁到自建 Pub/Sub topic，否则事件停发 |

**【文档】** [Ecobee 授权](https://www.ecobee.com/home/developer/api/documentation/v1/auth/auth-intro.shtml)、[Nest 事件](https://developers.google.com/nest/device-access/subscribe-to-events)、[Nest API](https://developers.google.com/nest/device-access/api)（2026-11-23 读取）

这两个是「云适配器」的模板：**OAuth 生命周期管理 + 轮询/订阅二选一 + 事件乱序**。我们接 Nest 这类云时，错误码归一里必须有 `authExpired(reauth: .oauth)`，且 UI 要能区分「令牌过期」与「用户在 Google 侧撤销授权」。

---

## 5. Apple HomeKit

### 5.1 ADR-0017 的结论仍然成立（本次复核）

ADR-0017 已在本机实测：macOS SDK 的原生 `HomeKit.framework` 只有 `maccatalyst` 切片，`HMHomeManager.h` 明写 `API_UNAVAILABLE(macos)`；把 macabi 产物 `dlopen` 进原生进程会被 dyld 以 `incompatible platform` 拒绝。本次没有重复跑，只做了两件增量核对：

1. **Itsyhome 的工程形态**与 ADR 描述一致：主 target `platform: iOS` + `supportedDestinations: [iOS, maccatalyst]`，entitlements 里 `com.apple.developer.homekit: true`；`macOSBridge` 是 `type: bundle`、`platform: macOS`，`NSPrincipalClass` 为 `MacOSController`，由 Catalyst 侧 `Bundle.macOSBridgePlugin` → `loadAndReturnError()` → `principalClass as iOS2Mac.Type` 加载。**【源码】** `nickustinov_itsyhome-macos:project.yml:29-100`、`Itsyhome/iOS/AppDelegate.swift:22-66`、`macOSBridge/Info.plist:21-22`、`Itsyhome/Shared/BridgeProtocols.swift:576-592`
2. **权限链**：`HomeKitManager` 里 `HMHomeManager()` 的创建发生在 Catalyst target 内（`Itsyhome/iOS/HomeKitManager.swift:77`），所以受限 entitlement 与 TCC 都落在 Catalyst 进程上，AppKit bundle 完全不碰 HomeKit。**【源码】** 同上

### 5.2 HAP 协议本身：为什么「手写控制器」不划算

HAP 的难点不在 REST 风格的读写，而在四件事同时成立：

- **配对**：SRP 6a 的 pair-setup（PIN/QR），再 pair-verify 建立会话密钥；
- **加密**：会话建立后所有 HTTP 帧用 ChaCha20-Poly1305 加密，不是 TLS；
- **推送**：不是 WebSocket，而是「长连接上随时插入 `EVENT/1.0 200 OK` 响应」，靠 `ev` 订阅特征；HAP-NodeJS 的实现注释写得很清楚；
- **模型**：Service / Characteristic / 权限（read/write/notify）、TLV8 编码、mDNS `_hap._tcp`。

**【源码】** `homebridge_HAP-NodeJS:src/lib/HAPServer.ts:327-340`、`src/lib/util/tlv.ts`、`src/lib/Characteristic.ts`

ADR-0017 方案 2 已否决手写 HAP 控制器；本次没有新证据推翻它。补充一条**成本量级**：HAP-NodeJS 仅 `src/lib` 就有 `HAPServer`、`EventedHTTPServer`、`hapCrypto`、`tlv`、`controller/`（客户端侧）等多套实现，且要持续跟 Apple 的配对流程变更——这是一个独立产品的工作量，不是「加一个 backend」。

### 5.3 Itsyhome 的第二条路：虚拟 HAP 桥（反方向）

`macOSBridge/HAPBridge/` 用 `hap-swift` 起了一个 HAP **服务端**：`VirtualBridgeService` 把 `VirtualDeviceStore` 里的虚拟设备以 bridged accessory 形式发布，`setupID = "ACMN"`，配对身份存 Keychain（`HAPIdentityKeychain`），pairings 存 JSON 文件（`FilePairingStore`，注释解释为什么要自己实现：内存版每次启动都忘，设备 ID 一变 Apple 家庭里就留 stale 记录）。**【源码】** `nickustinov_itsyhome-macos:macOSBridge/HAPBridge/VirtualBridgeService.swift:1-90`、`FilePairingStore.swift:1-40`、`HAPIdentityKeychain.swift:1-40`

**这条路不需要 `com.apple.developer.homekit`**：HAP 服务端只要局域网、mDNS 与本地网络权限。它的产品含义是「让 Apple 家庭看见我们的设备」，而不是「让我们看见 Apple 家庭的设备」。对 MenuBarHome 的启发见「设想」第 1 条。

---

## 6. Matter

### 6.1 `Matter.framework`：能编译，不等于能配网

本机实测（macOS 27.2 SDK）：

```
$ grep '^targets:' .../Matter.framework/Matter.tbd
targets: [ x86_64-macos, x86_64-maccatalyst, arm64e-macos, arm64e-maccatalyst,
           arm64e.x1-macos, arm64e.x1-maccatalyst ]
```

头文件里有完整的控制器 API：`MTRDeviceControllerFactory`（`MTR_AVAILABLE(ios(16.4), macos(13.3), ...)`）、`MTRDeviceController`、`MTRDevice`、`MTRDeviceControllerStartupParams`、`MTRCommissioningParameters`、`MTRDeviceController+XPC`。我写了一个最小文件（`MTRStorage` 实现 + `MTRDeviceControllerFactoryParams(storage:)` + `factory.start(params)`）做 typecheck：

```
$ xcrun swiftc -typecheck -target arm64-apple-macos14.0 -sdk "$SDK" mattercheck.swift
exit=0
```

**这是本次相对 ADR-0017 的增量事实**：不只是 `import Matter` 能过，控制器工厂的初始化链路在原生 macOS target 上也能过编译。

但三道未知仍然存在：

1. **配网入口**：Apple 的合规路径是 `MatterSupport` 框架 + 一个 `com.apple.matter.support.extension.device-setup` 扩展，由系统 UI 负责扫码/蓝牙/Thread 凭证，然后把 pairing code 交回 App；Apple 文档明确「Apps that don't implement their own Matter ecosystem can use the HomeKit API」——反过来，要实现自己的 ecosystem，就得走 MatterSupport。**【文档】** [MatterSupport](https://developer.apple.com/documentation/mattersupport/adding-matter-support-to-your-ecosystem)、[Apple Home Matter](https://developer.apple.com/apple-home/matter/)
2. **entitlement**：macOS 的 capability 列表里有 `Matter Allow Setup Payload`（用于解析二维码/配对码），但没有「第三方 Matter 控制器」这一项；社区在 2026 年的帖子里仍在问「standalone Matter controller 发布版需要什么 entitlement」，没有官方答案。**【文档】** [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)；**【检索】** Apple Developer Forums `Matter` 标签（2026-01 与 2026-04 两帖，均未闭环）
3. **运行时**：`MTRDeviceController+XPC` 说明框架可能把控制器放到系统服务里；是否需要额外授权、`Matter.framework` 在无付费账号的自签名产物里能否启动，未实测（需要真实设备与配对码，超出本次范围）。

结论：**原生 Matter 控制器在我们的签名体系（ADR-0005）下仍是「#11 之后才谈得上」的事**，且即便 #11 完成，也要先验证 IP-only 自有 fabric 能否不依赖系统 MatterSupport 跑通。

### 6.2 matter.js：可随 App 打包的纯 TS 控制器

`CommissioningController` 是纯 TS：`commissionNode(...)` 走完整配网（可选 `subscribeMinIntervalFloorSeconds` / `subscribeMaxIntervalCeilingSeconds`），`PairedNode.events.attributeChanged` 是 Observable，`close()` 释放；`ControllerStore` 负责 fabric/节点持久化。**【源码】** `matter-js_matter.js:packages/matter.js/src/CommissioningController.ts:315-360, 465-510, 815-830`、`packages/matter.js/src/device/PairedNode.ts:180-200, 280-290`

工程含义：

- 需要 Node 运行时（或 React Native / 其他 JS 引擎）；Windows Tauri 天然有 WebView，但仍要一个 Node/JS 侧进程或 Rust 侧绑定；
- 包体不小（`packages/*` 十几个 workspace），但可以只带 `@matter/main` + 控制器相关包；
- 与 ADR-0023 完全兼容：它是**进程外 sidecar**，不是「往宿主进程里塞第三方代码」。

### 6.3 python-matter-server：native CHIP 的包装，暴露了多管理员的真实 API

它不是纯 Python：`sdk.py` 第一行就是 `from chip.clusters import Attribute`、`from chip.ChipDeviceCtrl import ChipDeviceController`，底下是 connectedhomeip 的原生库。**【源码】** `home-assistant-libs_python-matter-server:matter_server/server/sdk.py:1-60`

它的 WebSocket API 是一份很好的「控制器能力清单」：`commission_with_code`、`commission_on_network`、`set_wifi_credentials`、`set_thread_dataset`、`open_commissioning_window`、`discover`、`interview_node`、`device_command`、`read_attribute`、`write_attribute`、`remove_node`、`set_acl_entry`、`set_node_binding`。**【源码】** `matter_server/common/models.py:28-56`

`open_commissioning_window` 的实现把多管理员的坑写全了：先读 `AdministratorCommissioning.WindowStatus`；如果窗口已开但没有缓存的参数（进程重启/别人开过），先 `RevokeCommissioning` 再重开；默认 300 秒、1000 次迭代、随机 discriminator；返回 `setup_pin_code` / `setup_manual_code` / `setup_qr_code`，并起一个 timer 到期清缓存。**【源码】** `matter_server/server/device_controller.py:477-560`

### 6.4 多管理员在真实生态里怎么用

- **规范层**：一个设备可同时加入多个 fabric，每个生态一个 administrator；Matter 规范要求设备至少支持 5 个 fabric（二手转述，未查规范原文）。**【检索】** [Sensereo 多管理员说明](https://sensereo.com/community/share-matter-devices-across-ecosystems/)（2026-11-13）
- **Apple 侧**：配件设置 → Turn On Pairing Mode → Copy Code，得到一个临时码（第三方文档说约 5 分钟有效），在第二个 App 里手动输入；反向（设备已在别家）则在「家庭」App 添加时选 More options。**【文档】** [Apple 支持](https://support.apple.com/en-us/102135)；**【检索】** [Nanoleaf 教程](https://support.nanoleaf.me/hc/en-us/articles/34124213402644-Apple-Home-How-To-Using-the-Multi-Admin-Feature-for-Matter-Devices)
- **Aqara**：官方文档把 M3 定义为 Matter 控制器 + Matter 桥接器（可把 Zigbee 子设备桥到 Apple Home / Alexa / Google / SmartThings / Home Assistant / Homey），M100 同定位。**【文档】** [Aqara 开放平台 M3](https://opendoc.aqara.com/docs/AqaraDevice/Hub-M3.html)
- **米家**：中枢网关可把部分设备以 Matter 桥接出去（品牌资料与社区文章一致），但米家 App 没有公开的「为本设备开放配对窗口」入口，无法像 Apple 那样给出第二生态的临时码。**【检索】**（2026 品牌资料与社区帖，未见小米官方文档；结论标为「未查到」）

**桥接设备的特殊性**：一个 Matter 桥在控制器眼里是**一个节点 + 多个 endpoint**，不是 N 个节点。所以「多管理员」对桥接设备意味着「配对那个桥」，子设备不单独占 fabric；这也意味着桥的厂商决定了哪些子设备能被看见（Aqara 的「高阶桥接」就是把场景/信号映射成虚拟插座/ occupancy 传感器）。

### 6.5 三种控制器方案对比（落到我们）

| 方案 | 运行形态 | 能力 | 成本 | 主要风险 |
| --- | --- | --- | --- | --- |
| `Matter.framework` 原生 | 进程内（macOS） | IP 设备读写/订阅，理论完整 | M（Swift 封装 + 存储 + 线程模型） | 配网需 MatterSupport 扩展；entitlement 不明确；BLE/Thread 未验证 |
| matter.js sidecar | 进程外 Node | 完整控制器 + 配网 + 多管理员 | L（打包 Node、IPC、跨端两份启动逻辑） | 包体、Node 安全更新、Windows/macOS 两套打包 |
| python-matter-server sidecar | 进程外 Python + native chip | 与 HA 完全一致 | L（Python 运行时 + native 库 + 交叉编译） | macOS 通用二进制、公证、体积 |

三条都绕不开「先有 fabric 与配对码」。以我们当前的签名与发版体系（ADR-0005、#11），**没有一条能在短期变成可交付功能**；能现在做的是把 SPI 留出 `matter` 这个 capability 位，不写死后端数量。

---

## 7. 共同抽象：三层怎么切、能力怎么探、降级怎么做

### 7.1 三层对照

| 库 | transport | protocol | device / 能力 |
| --- | --- | --- | --- |
| python-kasa | `transports/*`：Xor/KLAP/KLAPv2/AES/SSL，`send(str)->dict` | `protocols/*`：Iot/Smart/SmartCam，`query()` 批处理 + 重试 | `IotDevice`/`SmartDevice` 子类 + `component_nego` → modules |
| aiohue | `HueBridgeV2.create_request`（HTTPS、自签、`hue-application-key`、503/429 重试） | `EventStream`（SSE 续传/重连/保活）+ `*Controller`（资源缓存） | `models/*` 可选 feature 子对象 = 能力 |
| pyatv | 各协议自己的 socket/HTTP（`support/http.py`、`rtsp`、`opack`） | `protocols/{mrp,dmap,airplay,raop,companion}` | `FeatureName` + `FeatureInfo(state, options)` + Relayer 优先级 |
| aioshelly | WebSocket `/rpc` 或 HTTP，digest 挑战 | `handle_frame` 三分类（call/notification/response） | 设备型号 → `RpcDevice` + 组件 id（`switch:0` 等） |
| python-matter-server | native `chip` + WebSocket 服务端 | `APICommand` 命令集 | node/endpoint/cluster/attribute（Matter 数据模型） |

### 7.2 能力探测的五个模式

1. **自报白名单**（Yeelight `support`）：最准、最便宜，但只有老式厂商给。
2. **组件协商**（kasa `component_nego`）：带版本，能表达「有但版本低」。
3. **特性注册表**（pyatv `FeatureName`）：适合「多协议覆盖同一功能」的场景，可在运行时按状态翻转。
4. **结构探测**（Nanoleaf `panelLayout` 是否存在）：无 capability 字段时的兜底，脆弱但有效。
5. **静态 SKU 表**（Govee）：最差但要能用；必须配 fixture 测试与「未知型号降级为只读/仅开关」。

### 7.3 降级策略

- **能力缺失**：隐藏控件（不是置灰），例如没有 `color_temperature` 就不画色温滑杆；
- **能力暂时不可用**：置灰 + 原因（pyatv 的 `Unavailable`）；
- **协议不支持**：完全不出现（pyatv 的 `Unsupported`）；
- **写失败**：区分「可重试」（503/429/超时）与「需用户动作」（配对按钮、重新登录、局域网权限）。

这三档正好对应我们 `CapabilitySupportStatus` 的 `supported/partial/unsupported`，但后者是**产品级**（哪个平台支持哪个设备类型），不是**设备级**。两者要分开命名，否则 UI 会把「这台灯没有色温」误判成「macOS 不支持灯」。

---

## 8. 落到我们：统一 Adapter SPI 草案

### 8.1 现状盘点

| 文件 | 现在有什么 | 缺什么 |
| --- | --- | --- |
| `Sources/MijiaCore/HomeProvider.swift:82-107` | `events() / execute / refreshNow / retryLAN / setPollingContext / fetchSensorHistory / resolveCameraStream / readBack / shutdown` | 没有能力声明；没有「这个源是推还是拉」；`retryLAN` 是米家专属泄漏到通用协议 |
| 同文件 `:28-37` | `ControlReadBack { published, unavailable, failed }` | 只有三值，没有「等待推送多久」「重试几次」 |
| 同文件 `:58-80` | `HomeProviderError` 五个 case | 没有 `retryable` / `retryAfter` / `needsUserAction` |
| `HomeBackendDescriptor.swift:3-27` | 标题、是否配置、scope、provider 工厂 | 没有 capabilities、没有 discovery、没有配对/鉴权形态 |
| `HomeStore+Controls.swift:480-545` | 乐观写 → `readBack` → 回读不符则等 `readBackEchoDelay` 再读一次 → 2 秒锁 | 这套流程对所有后端一致，HA（推送）也被迫走「读回」 |
| `ReadBackTickets.swift:1-56` | 单设备单飞、in-flight/latest、上下文切换重置 | 已经是很好的并发原语，可保留 |
| `PollingPolicy.swift:24-48` | 全局 6s / 60s / 180s | 不能按源覆盖（Shelly 本地推送不需要 6s 轮询） |
| `windows/src/core/homeProvider.ts:24-30` | 只有 `execute` | ADR-0020 计划的快照/刷新/摄像头/关闭都没进接口 |
| `CapabilityManifest.swift:1-30` | 产品级能力矩阵（连接/功能/设备类别 × macOS/Windows） | 不是设备级能力 |

### 8.2 SPI 草案（Swift 侧）

目标：**`HomeProvider` 继续当「聚合层」，新增 `HomeAdapter` 当「单一源」**；一个适配器只描述自己的语义，聚合层不再猜。

```swift
// 1) 适配器标识与发现
public struct AdapterID: Hashable, Sendable, Codable {
    public let kind: String      // "hue" / "shelly" / "ha" / "mi" / "matter"
    public let scope: String     // "hue:001788FFFE123456" / "ha:http://nas:8123"
}

public protocol HomeAdapterDiscovering: Sendable {
    func discover(timeout: Duration) async -> [AdapterCandidate]
}

public struct AdapterCandidate: Sendable {
    public let id: AdapterID
    public let displayName: String
    public let transport: AdapterTransport   // .lan / .cloud / .ble / .matter
    public let needsPairing: AdapterPairing  // .none / .button / .code / .oauth / .setupCode
}

// 2) 能力：由适配器声明，聚合层只读
public struct AdapterCapabilities: Sendable, Equatable {
    public var push: PushCapability
    public var writeConfirmation: WriteConfirmation
    public var groups: Bool
    public var scenes: Bool
    public var history: Bool
    public var effects: Bool
    public var camera: CameraCapability
    public var maxWritesPerSecond: Double?
    public var rawNamespace: String?          // "miot" / nil；决定 setMiotProperty 是否可用
}

public enum PushCapability: Sendable, Equatable {
    case stream(keepAlive: Duration?, resumable: Bool)  // Hue SSE / Shelly WS / Matter subscription
    case notify                                          // Yeelight props / Govee UDP 4002
    case poll(fast: Duration, slow: Duration)            // SwitchBot / Ecobee / Nest
    case none
}

public enum WriteConfirmation: Sendable, Equatable {
    case push(within: Duration)                 // 等设备自己推回来
    case readBack(attempts: Int, delay: Duration) // 写后主动读
    case ack                                    // 只有传输层确认（LIFX ACK / Shelly RPC result）
    case none                                   // 发出去就算（Govee/Yeelight 基础命令）
}

// 3) 读模型：允许「补丁」而不是每次整屋快照
public enum AdapterEvent: Sendable {
    case snapshot(AdapterSnapshot)              // 首次 / 重连后的全量
    case patch(AdapterPatch)                    // 单设备/单字段增量
    case status(ConnectionStatus)
    case sourceEvent(AdapterSourceEvent)        // 门铃、按钮、场景触发
}

// 4) 写模型：回执说明「这次写到什么程度」
public struct AdapterWriteReceipt: Sendable {
    public enum Acceptance: Sendable { case queued, acknowledged, applied }
    public var acceptance: Acceptance
    public var expected: [OptimisticField: JSONValue]      // 用于乐观锁范围
    public var dedupeKey: String?                          // 幂等键
    public var retryAfter: Duration?
}

// 5) 错误归一
public enum AdapterError: Error, Sendable, Equatable {
    case authExpired(reauth: ReauthKind)          // .token / .pairButton / .oauth / .setupCode
    case unreachable(isLocalNetworkDenied: Bool)
    case rateLimited(retryAfter: Duration?)
    case unsupported(capability: String)
    case rejected(code: String, message: String)  // 设备明确拒绝
    case conflict(currentValue: String?)          // 乐观值被设备真值推翻
    case transient(message: String)

    public var isRetryable: Bool { ... }
    public var needsUserAction: ReauthKind? { ... }
}

// 6) 协议本体
public protocol HomeAdapter: Sendable {
    var id: AdapterID { get }
    var capabilities: AdapterCapabilities { get }
    func start() async throws -> AdapterSnapshot
    func events() -> AsyncStream<AdapterEvent>
    func execute(_ command: DeviceCommand) async throws -> AdapterWriteReceipt
    func readBack(_ target: AdapterReadTarget) async -> AdapterReadResult
    func stop() async
}
```

> 草案里未展开的类型（`AdapterSnapshot` / `AdapterPatch` / `AdapterReadTarget` / `AdapterReadResult` / `AdapterTransport` / `AdapterPairing` / `CameraCapability` / `ReauthKind`）都按现有 `SynthesizedHome`、`ControlReadBack`、`PollingContext` 的语义定义，不引入新的数据模型；这份草案只新增「声明」，不新增状态机。

### 8.3 关键设计说明

**(a) 命令币种沿用 `DeviceCommand`。** 它已经是语义化的（`setLightBrightness`、`setClimateTemperature`…），`entityId` 事实上就是「适配器本地句柄」（HA 是 `light.x`，米家是 `did.siid` 复合），不需要再抽一层。真正要收口的是两个逃生舱 `setMiotProperty` / `callMiotAction`：它们应由 `capabilities.rawNamespace == "miot"` 门控，HA/Hue/Matter 适配器直接拒绝。**【源码】** `Sources/MijiaCore/Models.swift:1698-1745`

**(b) 确认策略由适配器给，流程由 `HomeStore` 执行。** 现在 `confirmToggleReadBack` 无条件 `readBack` + echo 重试 + 2 秒锁；改成：

- `.push(within: 1.5s)`：只等 `snapshotGeneration` 变化，超时才退回一次 `readBack`；
- `.readBack(attempts: 1, delay: 350ms)`：保持现状（米家）；
- `.ack`：写成功即确认，锁 2 秒防抖；
- `.none`：写即认为成功（不等任何确认），同样锁 2 秒；写没落地只会体现在随后的快照里。

这样 HA（推送）不再做无意义的读回，米家（轮询）保持现有行为，行为变化可逐适配器开关。**【源码】** `Sources/MijiaCore/HomeStore+Controls.swift:480-545`

**(c) 推送上下文语义化。** 把 `setPollingContext` 从 `HomeProvider` 移到 `HomeAdapter`，并且只对 `.poll` 能力生效；`.stream` 适配器只把 `panelVisible` 用于「合并窗口」（HA 现在就是这么做的：面板可见 100ms、不可见 500ms）。**【源码】** `HomeProvider.swift:740-776`

**(d) 轮询参数本地化。** `PollingPolicy` 保留为默认值，但 `AdapterCapabilities.push = .poll(fast:slow:)` 可以覆盖；Shelly 这类本地推送 + 低频兜底的设备可以 `poll(fast: 30s, slow: 300s)`，不该跟米家云一样 6 秒。**【源码】** `PollingPolicy.swift:24-48`

**(e) 错误归一后，UI 只认三件事**：能不能重试、要不要用户动手、要不要降级显示。`HomeProviderError` 可以保留为兼容层，内部映射到 `AdapterError`。

### 8.4 Windows 侧对齐（TypeScript）

```ts
export interface AdapterCapabilities {
  readonly push: { kind: "stream"; keepAliveMs?: number; resumable: boolean }
             | { kind: "notify" } | { kind: "poll"; fastMs: number; slowMs: number } | { kind: "none" };
  readonly writeConfirmation: { kind: "push"; withinMs: number }
             | { kind: "readBack"; attempts: number; delayMs: number }
             | { kind: "ack" } | { kind: "none" };
  readonly groups: boolean; readonly scenes: boolean; readonly history: boolean;
  readonly rawNamespace?: "miot";
}

export interface HomeAdapter {
  readonly id: { kind: string; scope: string };
  readonly capabilities: AdapterCapabilities;
  start(): Promise<AdapterSnapshot>;
  events(): AsyncIterable<AdapterEvent>;
  execute(command: DeviceCommand): Promise<AdapterWriteReceipt>;
}
```

`windows/src/core/homeProvider.ts` 现在只有 `execute`，`HomeAssistantProvider` 还要经 `haTransportGate` 做 scope 生命周期检查；这两件事在 SPI 里分别落到 `capabilities` 与 `execute` 的前置钩子（`beforeSend` 已有），不需要重写。**【源码】** `windows/src/core/homeProvider.ts:8-70`

### 8.5 接线点与迁移顺序（不破坏 ADR-0020 / ADR-0023）

1. **给现有两个 provider 加 capability 声明**（纯增量，行为不变）：HA `.stream(keepAlive: 25s, resumable: false) + .push(1.5s)`，米家 `.poll(6s, 60s) + .readBack(1, 350ms)`。
2. **`HomeStore` 改为查 capability 执行确认流程**（一处 switch，加测试）。
3. **`HomeBackendDescriptor` 增加 `capabilities` 与 `adapterKind`**；`HomeBackend` 仍是封闭枚举（ADR-0020 决定 1 不变）。
4. **引入 `HomeAdapter` 协议，先用现有 HA provider 做第一个实现**（包装而非重写），验证 SPI 能否表达 SSE 的 patch 语义。
5. **第二个适配器选 Hue LAN**：本地、SSE、无云账号、读模型清晰，是检验 SPI 的最佳样本；但它是新的高风险面（凭据/钥匙串 + 设备写入），按 AGENTS.md 必须走 PR。
6. **Matter 只留位**：`AdapterTransport.matter` + `AdapterPairing.setupCode` 先定义，不实现。

---

## 9. 对照我们：差距表

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `Sources/MijiaCore/HomeProvider.swift:82-107` | 能力、推送、历史、摄像头全揉在一个协议 | pyatv 接口 + Feature 表；kasa transport/protocol 分离 | 拆出 `HomeAdapter`，`HomeProvider` 只做聚合 | M |
| `HomeProvider.swift:58-80` | 5 个错误 case，无重试语义 | aiohue 503/429 独立重试；Nanoleaf 401/404 不重试 | `AdapterError` 归一 + `isRetryable` / `needsUserAction` | S |
| `HomeProvider.swift:28-37`、`HomeStore+Controls.swift:480-545` | 所有后端都走 readBack + echo + 2s 锁 | LIFX 三档确认；Hue 靠 SSE | 确认策略由 `capabilities.writeConfirmation` 决定 | M |
| `HomeBackendDescriptor.swift:3-27` | 只有标题/配置/scope/工厂 | kasa `device_family` 表 + 覆盖 | 加 `capabilities`、`adapterKind`、`pairing` | S |
| `PollingPolicy.swift:24-48` | 全局 6s/60s/180s | Govee `update_interval` 可配；Shelly 本地推送 | 允许适配器覆盖 fast/slow | S |
| `windows/src/core/homeProvider.ts:24-30` | 只有 `execute` | ADR-0020 计划的方法集 | 补 `events()` / `snapshot` / `capabilities` | M |
| `CapabilityManifest.swift:1-30` | 产品级能力矩阵 | pyatv 设备级三值 | 新增设备级 capability，勿与产品矩阵混用 | S |
| `HADiscovery.swift`（只找 HA） | 单一发现器 | Shelly mDNS、Govee UDP、Hue mDNS、Matter mDNS | 抽 `AdapterDiscovering` + 统一候选列表 | M |
| `Models.swift:1698-1745` | `setMiotProperty` / `callMiotAction` 对所有后端可见 | 厂商逃生舱应门控 | 由 `rawNamespace` 门控 | S |
| `DualSourceHomeProvider.swift`（固定两槽位） | 两个具名参数 | pyatv Relayer 的 N 协议 | 先不改；等第三个源落地前再评估 | L |
| `HomeProviderEvent`（只有整屋快照） | `snapshotUpdated(SynthesizedHome)` | Hue SSE patch / Shelly 通知 | 不在本轮改；由适配器内部合并（HA 已有 100/500ms 窗口） | L |

---

## 10. 推进清单

| # | 标题 | 价值 | 成本 | 优先级 | 高风险面 | 依据 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `AdapterError` 错误码归一 + `HomeProviderError` 映射 | 用户看到「重试 / 重新登录 / 按配对键」而不是原始 JSON；减少重复诊断日志 | S | **P0** | 否 | aiohue 503/429、Nanoleaf 401/404、Ecobee OAuth |
| 2 | 给 HA 与米家 provider 加 `capabilities` 声明（行为不变） | 为后续所有确认/轮询策略提供单一事实源 | S | **P0** | 否 | pyatv FeatureInfo、kasa component_nego |
| 3 | 确认流程改由 capability 驱动 | 推送后端不再做无意义回读；去掉统一 2s 锁的体感延迟 | M | **P1** | 是（设备控制写入路径） | LIFX 三档确认、Hue SSE |
| 4 | `HomeAdapter` SPI 落地（先包装 HA provider） | 第三个源的接入成本从「改 HomeProvider + 三处判断」降到「实现一个协议」 | M | **P1** | 否（纯重构） | ADR-0020 方案 3、pyatv Relayer |
| 5 | Windows `HomeProvider` 补齐 `events/snapshot/capabilities` | 与 Swift 同形，避免 ADR-0006 的结构漂移 | M | **P1** | 否 | ADR-0020 落地记录、`homeProvider.ts` |
| 6 | Hue LAN 适配器（作为 SPI 验证样本） | 第一个「国际厂商 + 本地推送」源；SSE + 分组/场景模型可直接映射 | L | **P2** | 是（新凭据 + 设备写入） | aiohue 全文、Hue v2 模型 |
| 7 | `AdapterDiscovering` + mDNS/SSDP 候选列表 | 设置页从「手填地址」变成「发现设备」 | M | **P2** | 否 | aioshelly zeroconf、Yeelight SSDP、Govee UDP |
| 8 | Matter via matter.js sidecar（进程外） | 覆盖 Matter 设备与多管理员；Windows 端尤其自然 | L | **P3** | 是（发版链路 / 新进程 / fabric 密钥） | ADR-0023、matter.js、python-matter-server |
| 9 | `Matter.framework` IP-only spike | 若可行，可省掉 sidecar | M | **P3** | 是（签名 / entitlement） | 本次 typecheck 通过；配网路径未知 |
| 10 | HAP 虚拟桥（把我们的设备暴露给 Apple 家庭） | 不用 HomeKit entitlement 就能进 Apple 家庭 | L | **P3** | 是（配对身份 / 本地网络 / 长期维护） | Itsyhome `HAPBridge`、hap-swift |

高风险面判定按仓库 AGENTS.md：1/2/4/5/7 不触及登录凭据、控制写入、数据迁移、更新签名或跨端共享语料（#5 只改 Windows 内部接口，不动 `Tests/Fixtures`）；3 触及设备控制写入；6/8/9/10 触及凭据与发版。

---

## 11. 设想（可不受现有 ADR 约束）

1. **反向 HAP 桥：让 MenuBarHome 变成 Apple 家庭的「虚拟桥」**。Itsyhome 已经证明用 `hap-swift` 在 macOS 进程内起 HAP 服务端不需要 `com.apple.developer.homekit`，只需要局域网 + Keychain。我们可以把米家/HA 设备以虚拟配件发布到 Apple 家庭，用 Siri 控制。**与 ADR-0017 不冲突**（那是「读 HomeKit」，这是「写 HAP」），但与「控制中心」定位有张力：我们变成被 HomeKit 控制的一端，需要长期维护配对身份与 mDNS。成本 L，风险是「Apple 改 HAP 配对流程」。
2. **统一能力探针（Capability Probe）**：对每个新设备跑一次「读全部属性 + 尝试无害写 + 观察事件」的探测，产出 per-device JSON 缓存，UI 根据它生成控件。kasa 的 `component_nego`、Yeelight 的 `support`、Nanoleaf 的 `panelLayout` 都是这个思路的局部实现；我们可以把它做成适配器契约的一部分（`probe()` 可选方法）。成本 M。
3. **断线续传的通用 `ResumeToken`**：Hue 有 `last-event-id`，HA 没有，Shelly 没有。适配器可以声明 `resumable: Bool`；不可续传的源在重连后必须做一次全量 + diff（aiohue 的 `__handle_reconnect` 就是范本）。成本 S。
4. **适配器契约测试 + 故障注入**：用本地假设备（延迟 0/300ms/3s、丢包 5%、401、503、半开连接）跑同一套契约测试，确保「慢设备不会把 UI 卡住」「重连不会重复执行命令」。我们可以复用 `MockHomeProvider` 的位置，但需要把它升级成「可编排的假适配器」。成本 M。
5. **声明式场景（openhue 风格）**：openhue 用 YAML 定义场景（`ParseSceneDefinition` + `KnownFields(true)` + 行号错误），可以导出/导入。我们的场景目前是 HA 的 `scene.turn_on`，如果未来支持多源场景，YAML/JSON 的「声明式场景」比在 UI 里点选更可版本化。成本 M。**与 ADR-0020 的封闭后端集合不冲突**，但会新增一个文件格式契约。
6. **Matter 只做「被桥接」而不是「做控制器」**：与其自己当 Matter controller（entitlement + 配网 + 多管理员全是坑），不如让 Aqara/米家中枢把设备桥出来，我们通过 HA 或未来的 matter.js 读。这是成本最低的「支持 Matter」姿势。成本 S（若已有 HA）。

---

## 12. 来源清单

**本机实测**

- macOS 27.2 SDK：`Matter.framework/Matter.tbd` targets、`MTRDeviceControllerFactory.h`、`MTRDeviceController+XPC.h`；`xcrun swiftc -typecheck -target arm64-apple-macos14.0` 对 `MTRStorage` + `factory.start(_:)` 的最小文件退出码 0。
- ADR-0017 的 HomeKit SDK/dyld/entitlement/TCC 实测（本仓库 `docs/adr/0017-homekit-third-backend-evaluation.md:19-105`）。

**源码（克隆根 `~/.cache/mbh-research-clones/`）**

- `home-assistant-libs_aiohue:aiohue/v2/controllers/events.py`、`aiohue/v2/controllers/base.py`、`aiohue/v2/controllers/lights.py`、`aiohue/v2/__init__.py`、`aiohue/v2/models/{grouped_light,scene,entertainment_configuration}.py`
- `python-kasa__python-kasa:kasa/device_factory.py`、`kasa/transports/{basetransport,klaptransport}.py`、`kasa/protocols/{protocol,smartprotocol}.py`、`kasa/smart/smartdevice.py`、`SUPPORTED.md`
- `postlund_pyatv:pyatv/interface.py`、`pyatv/core/{relayer,facade,protocol,scan}.py`、`pyatv/protocols/mrp/__init__.py`、`pyatv/const.py`
- `openhue_openhue-cli:openhue/{home_model,scene_yaml}.go`
- `home-assistant-libs_aioshelly:aioshelly/rpc_device/wsrpc.py`、`aioshelly/zeroconf.py`
- `frawau_aiolifx:aiolifx/aiolifx.py`
- `Galorhallen_govee-local-api:src/govee_local_api/controller.py`
- `stavros_python-yeelight:yeelight/main.py`、`yeelight/ssdp_discover.py`
- `loebi-ch_aionanoleaf2:aionanoleaf2/nanoleaf.py`、`aionanoleaf2/events.py`
- `OpenWonderLabs_SwitchBotAPI:README.md`
- `homebridge_HAP-NodeJS:src/lib/HAPServer.ts`
- `nickustinov_itsyhome-macos:Itsyhome/iOS/AppDelegate.swift`、`Itsyhome/iOS/HomeKitManager.swift`、`Itsyhome/Shared/BridgeProtocols.swift`、`project.yml`、`macOSBridge/Info.plist`、`macOSBridge/HAPBridge/*`
- `matter-js_matter.js:packages/matter.js/src/CommissioningController.ts`、`packages/matter.js/src/device/PairedNode.ts`
- `home-assistant-libs_python-matter-server:matter_server/server/{sdk,device_controller}.py`、`matter_server/common/models.py`

**文档 / 检索**

- Apple：[Matter support in iOS](https://developer.apple.com/apple-home/matter/)、[Adding Matter support to your ecosystem](https://developer.apple.com/documentation/mattersupport/adding-matter-support-to-your-ecosystem)、[Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)、[Pair and manage your Matter accessories](https://support.apple.com/en-us/102135)、Developer Forums `Matter` 标签（2026-01 / 2026-04 帖，检索）
- Google：[Cloud-to-cloud 入门](https://developers.home.google.com/cloud-to-cloud/get-started)、[Nest SDM 事件](https://developers.google.com/nest/device-access/subscribe-to-events)、[Nest SDM API](https://developers.google.com/nest/device-access/api)
- Ecobee：[Authorization Core Concepts](https://www.ecobee.com/home/developer/api/documentation/v1/auth/auth-intro.shtml)
- Aqara：[中枢 M3](https://opendoc.aqara.com/docs/AqaraDevice/Hub-M3.html)、[2025-04 新闻稿](https://www.aqara.com/en/news/aqara-enhances-user-experience-with-expanded-matter-device-integration-and-advanced-bridging-capabilities/)
- Matter 中文网：[使用与多生态配网](https://matter.cn/use)
- Nanoleaf：[Apple Home 多管理员教程](https://support.nanoleaf.me/hc/en-us/articles/34124213402644-Apple-Home-How-To-Using-the-Multi-Admin-Feature-for-Matter-Devices)
- Hue Entertainment（二手，互相印证）：[Hypercolor](https://hyperb1iss.github.io/hypercolor/hardware/hue/)、[IoTech](https://iotech.blog/posts/philips-hue-entertainment-api/)
- Matter 多 fabric 数量：[Sensereo](https://sensereo.com/community/share-matter-devices-across-ecosystems/)（二手，未查规范原文）
- Home Assistant 集成依赖清单：`homeassistant/components/{govee_light_local,shelly,nanoleaf,yeelight,lifx}/manifest.json`（`dev` 分支，2026-11-23 读取）

---

## 摘要（5 行内）

1. **最值得先做**：把 `AdapterError` 归一 + 让 HA/米家 provider 声明 `capabilities`（推送/确认/轮询语义），成本 S，能立刻消除「推送后端也做回读 + 统一 2 秒锁」的浪费。
2. **第二个**：按 pyatv 的「接口 + 优先级 + 每特性三值」落地 `HomeAdapter` SPI，先包装现有 HA provider 验证，再拿 Hue LAN 当第三个源；ADR-0020 的封闭枚举不必动。
3. **第三**：Matter 只留 capability 位、不写实现；真要做得走进程外（matter.js / python-matter-server），原生 `Matter.framework` 虽然 typecheck 通过，但配网 entitlement 仍不明确，HomeKit 那条路则继续按 ADR-0017 否掉。
4. 报告路径：`docs/research/2026-11-23-deep-dive/05-global-vendors-matter-homekit.md`。
5. 未确认项已按【检索】/【未查到】标注：Matter 多 fabric 数量原文、米家「开放配对窗口」入口、`Matter.framework` 在无付费账号下的运行时行为。
