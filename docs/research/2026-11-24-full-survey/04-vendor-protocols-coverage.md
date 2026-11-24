# 多厂商协议与设备覆盖面深度调研报告（源码三层扒皮）

> **调研定位**：面向 MenuBarHome（macOS Swift + Windows Tauri/TS 双端桌面智能家居控制中心）的多生态协议源码解剖、可行性×覆盖价值矩阵、米家直连升级路线、摄像机实时流技巧与低成本模板驱动适配架构方案。
> **证据边界**：本报告中标记「源码证实」的结论均来自本机实读的 10 个上游开源仓库与 MenuBarHome 本仓基线源码（附精确 `path#symbol`）；标记「资料证实」的结论来自 2025–2026 年官方文档与社区一手公开资料；标记「工程推断」的结论为架构研判。

---

## 核心结论（直报体）

1. **米家直连存在 3 个高杠杆、零法务冲突的立即可做升级**：① 为 Windows 补齐 `LocalMiIOClient`（当前仅 macOS 有，Windows 100% 云轮询）；② 基于本地 `token` 实现 UDP 54321 **`miIO.sub` 局域网主动推送**（源码证实无需小米 HA 专有 OAuth2，可将 Wi-Fi MIoT 设备从轮询切为毫秒级推）；③ `MiotSpecStore` 索引改为 `status=all`（`released` 优先、缺失回退 `debug`）+ 外置声明式 `spec_patches`（add/filter/modify）+ 官方多语言词库，并评估读属性改走 `v2/miotspec/prop/get` 的 `datasource: 1` 云缓存与 200ms 聚合窗。
2. **严守 `XiaoMi/ha_xiaomi_home` 法律边界**：其源码头声明**仅授权非商业用于 Home Assistant，严禁用于开发 APP 或其他软件**，其 `OAUTH2_CLIENT_ID` 与中枢网关 mTLS 证书接口 `/app/v2/ha/oauth/get_central_crt` 亦绑定 HA。MenuBarHome 严禁复用其代码或 `client_id`，中枢网关能力应引导用户经 Home Assistant 侧桥接。
3. **低成本扩充生态的最优解 =「ADR-0024 进程外适配器 + 双模声明式模板引擎 + Matter Multi-Admin」**：
   - **近期直连高性价比 Top 梯队（零云/低摩擦/高桌搭重合度）**：米家直连进阶（内置）→ **Home Assistant 深度协同**（内置）→ **Philips Hue CLIP v2** → **WLED / Shelly Gen2+ / Yeelight / Govee**（极简 LAN 适配器包）→ **Tuya Local**（YAML 模板驱动，覆盖海量白牌）→ **Matter（`matter.js` IP Multi-Admin 二级控制器，一举打通 Aqara M3 / SwitchBot Hub / Tapo / Eve 等跨品牌生态）** → **易微联/Sonoff LAN+WS** → **格力/美的局域网空调**。
   - **明确不建议自研直连的红区**：华为鸿蒙/HiLink（极度封闭、高风控）、海尔智家纯云逆向（封禁频繁、维护重）、HomeKit HAP 独立直连（单控制器互斥，会抢占或无法共用于已入 Apple Home 的设备）。
4. **本次实读源码清单（10 外部仓 + 本仓基线）**：
   - `XiaoMi/ha_xiaomi_home`、`al-one/hass-xiaomi-miot`、`rytilahti/python-miio`
   - `make-all/tuya-local`、`rospogrigio/localtuya`
   - `AlexxIT/SonoffLAN`
   - `home-assistant-libs/aiohue`、`Jc2k/aiohomekit`、`matter-js/python-matter-server`
   - `AlexxIT/go2rtc`
   - 本仓基线：`Sources/MijiaCore/MiCloud/*`、`windows/src/core/miCloud/*`、`docs/adr/0024-out-of-process-adapter-protocol.md`、`docs/agents/windows-camera.md`

---

## 一、厂商 / 协议接入可行性 × 覆盖价值总矩阵

> 维度说明：
> - **本地可行性**：区分「本地推（Push，零轮询）」「本地拉（Poll）」「需云拉密钥+本地控（Hybrid）」「仅云端」。
> - **ADR-0024 归属**：结合本仓 [ADR-0024](../../adr/0024-out-of-process-adapter-protocol.md) 边界判断应「宿主内置」「进程外适配器（`HomeAdapter`）」还是「交由 HA 间接覆盖」。

| 推荐序 | 厂商 / 协议 | 家庭高频度（中 / 国际） | 认证与配网难度 | 本地直连可行性 | 法务 / 封号 / 协议变风险 | Spec / 模板驱动度 | ADR-0024 归属 | 接入结论 |
| :---: | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **P0-1** | **米家直连进阶（MIoT + `miIO.sub`）** | 中国 **★★★★★** / 国际 ★★★☆ | 低（扫码已内置） | **本地推（Wi-Fi `miIO.sub`）+ 本地拉 + 云兜底** | 中（非官方 App 签名；严禁借用 HA OAuth2 client_id） | **极高**（MIoT Spec v2 + 补丁表） | 宿主内置 | **立即升级**（Windows 补 LAN、`miIO.sub` 推、Spec 补丁引擎） |
| **P0-2** | **Home Assistant（既有主通道）** | 中极客 ★★★★ / 国际 **★★★★★** | 低（mDNS + 长期令牌） | **本地推（WebSocket）** | **无**（官方开放 API） | **极高**（HA Domain 统一语义） | 宿主内置 | **继续做深**（借 HA 吃下米家中枢网关、Zigbee2MQTT、大家电长尾） |
| **P1-3** | **WLED + Shelly Gen2/3** | 桌搭极客 ★★★★ / 国际 ★★★★ | **极低**（mDNS 零注册） | **本地推（WebSocket / JSON-RPC）** | **无**（官方开放本地协议） | 高（结构化 JSON Schema） | 进程外适配器（首组样板） | **极低成本验证 ADR-0024**，完美命中桌面灯带/功率插座高频场景 |
| **P1-4** | **Philips Hue CLIP v2** | 中国 ★★★ / 国际 **★★★★★** | 低（mDNS + 按桥物理键） | **本地推（HTTPS SSE 事件流）** | **无**（官方公开 CLIP v2） | **极高**（强类型 Resource Graph） | 进程外适配器 | 国际口碑与灯光精细度标杆；注意并发≤3 与 SSE 僵死探活 |
| **P1-5** | **Yeelight + Govee（LAN）** | 桌搭照明 **★★★★☆** / 国际 ★★★★ | 低（App 开局域网开关） | **本地推/拉**（Yeelight TCP 55443 / Govee UDP 4001-4003） | **无**（官方开发者局域网模式） | 中（灯光模型简单统一） | 进程外适配器 | 桌面屏幕挂灯/氛围灯带爆款，开发工作量极小 |
| **P1-6** | **Matter（IP Multi-Admin 二级控制器）** | 未来增量 **★★★★★**（双市场） | 中（粘贴 11 位多管理配对码） | **本地推（IPv6 + CASE 加密订阅）** | **无**（CSA 开放标准） | **极高**（Cluster / Endpoint 标准模型） | 进程外适配器（`matter.js`） | **杠杆率最高的跨品牌协议**：借 Aqara M3 / SwitchBot Hub / Tapo 网关一次通吃多生态；**不做 PC 直连 BLE/Thread 一级配网** |
| **P2-7** | **涂鸦 Tuya（Local + 可选 Cloud 拉 Key）** | 中国白牌 **★★★★★** / 国际 **★★★★★** | 中高（需取 `local_key`：自有 IoT 项目或授权扫码） | **需云拉 Key + 本地推（TCP 6668 v3.1–3.5）** | 中高（不可复用 HA 的 `TUYA_CLIENT_ID`；免费 IoT 试用期限制） | **高（社区 1,790 份 YAML 模板）** | 进程外适配器 | 覆盖面积仅次于米家；必须采用 YAML DP 模板引擎，禁止按型号硬编码 |
| **P2-8** | **易微联 / Sonoff（LAN + WS 混合）** | 中国 DIY ★★★☆ / 国际 ★★★★ | 中（eWeLink 账号或 DIY 模式） | **本地推（mDNS TXT + HTTP 8081）+ 云 WS 兜底** | 中（非官方 App Secret 存在顶号 406 风险） | 中（按 UIID 映射） | 进程外适配器 | 其双通道仲裁器源码是全行业范本，值得全仓复用设计 |
| **P2-9** | **通用摄像机（RTSP / ONVIF / Tapo / 海康 ISAPI / 大华 / 萤石）** | 中国 **★★★★☆** / 国际 ★★★★ | 中（输入局域网账号密码/ONVIF 探测） | **本地直推/拉（经内置 go2rtc）** | 低（本地标准协议；萤石云端封闭但多数机型支持开局域网 RTSP） | 高（go2rtc 统一 URL 协议抽象） | 宿主 `go2rtc` 扩展 | 复用已有 `go2rtc` 二进制，近乎零体积增量覆盖非米家安防摄像头 |
| **P2-10** | **TP-Link Tapo / Kasa** | 中国 ★★☆ / 国际 **★★★★☆** | 中（需 TP-Link 账号哈希做 KLAP 握手） | **本地拉（KLAP v2 HTTP 加密）** | 中（厂商偶发固件升级改加密握手） | 中高（品类集中在插座/灯/摄像头） | 进程外适配器（或走 Matter） | 优先通过 Matter 覆盖新款，老款用 KLAP 适配器补齐 |
| **P2-11** | **Aqara / 绿米** | 中国全屋 **★★★★★** / 国际 ★★★★ | 中（经 M3/M2 网关 Matter Bridge 或 HA） | **Matter Bridge 本地推**（私有 LAN 协议已收紧） | 低（走 Matter/HomeKit）；云 Open API 偏向 B 端/计费 | 高（走 Matter Cluster） | 经 **Matter 适配器** 或 HA | **勿逆向绿米云/私有网关协议**，引导开网关 Matter Bridge 是唯一长期稳健路 |
| **P3-12** | **SwitchBot** | 日本/欧美 ★★★★ / 中国 ★★☆ | 低（Cloud Token 或 Hub 2 Matter） | **Hub 2 Matter 本地推** / PC BLE 距离受限 | 无（官方开放 Cloud v1.1 + Matter） | 中 | 经 Matter 或轻量云适配器 | 窗帘机器人/手指机器人优先走 Matter，无 Hub 时轻量接 Cloud v1.1 |
| **P3-13** | **格力 Gree（空调）** | 中国大家电 **★★★★☆** | 低（局域网 UDP 7000 扫描） | **本地拉/控（UDP 7000 AES-ECB/GCM）** | 低（纯局域网逆向协议，无云封号） | 高（空调单品类属性规整） | 进程外适配器 | 空调高频刚需，纯局域网稳定；需兼容老 ECB 与新 GCM 密钥 |
| **P3-14** | **美的 Midea（空调/大家电）** | 中国大家电 **★★★★☆** | 中高（需登美居云端换本地 Token/Key） | **云拉 Key + 本地 TCP 实时同步** | 中（美居云登录接口有版本风控） | 中高（已沉淀进 HA Core） | 进程外适配器（或交 HA） | 存量大，但 Token 维护链较长，适合在插件生态开放后做社区/官方适配器 |
| **P3-15** | **博联 BroadLink（红外/射频）** | 老家电改造 ★★★ | 低（局域网 UDP 80） | **本地直控（UDP 80 AES-128-CBC）** | 低 | 低（无状态反馈，依赖码库/学码） | 进程外适配器 | 适合老空调/风扇补盲，但红外无状态反馈体验弱于双向协议 |
| **不建议** | **HomeKit HAP 直连** | 苹果生态 ★★★★ | 高（单控制器绑定冲突） | 本地推（ChaCha20-Poly1305 HTTP + EVENT/1.0） | 低（HAP 非商用规范公开） | 极高（标准 Service/Characteristic） | **不建议直连** | **核心硬伤**：配件不能同时配对 Apple Home 和 MenuBarHome；桌面端应以 Matter Multi-Admin 取代 HAP 控制器 |
| **不建议** | **海尔 Haier（海尔智家）** | 中国大家电 ★★★☆ | 高（云端 OAuth2 + 抓包风控） | 主流国内机型仅云端 WS（仅少部分海外机型本地） | **高**（官方反爬/封禁频发） | 中低 | **交由 HA** | 维护成本远超收益，不进内置/官方优先列表 |
| **不建议** | **华为鸿蒙 / HiLink（智慧生活）** | 中国全屋 ★★★★ | 极高（无公开个人 API） | 高度封闭（非开放本地协议） | **极高**（强加密与合规风险） | 低 | **不直连** | 除非华为开放 Matter Bridge，否则严禁投入逆向直连 |

---

## 二、米家生态三层源码扒皮 & MenuBarHome 升级路线图

### 2.1 小米官方 `XiaoMi/ha_xiaomi_home` 深度解剖（源码证实）

#### (1) 法务与授权红线（极高优先级发现）
实读 `ha_xiaomi_home` 每一个源码文件顶部许可条款（如 `custom_components/xiaomi_home/miot/const.py:5-15`）：
- 小米明确限定：**仅授予非商业目的用于 Home Assistant 的许可，明确不授权用于开发 APP、Web 服务或其他形态的软件**，且禁止未经书面许可使用「Xiaomi / Mijia」商标进行宣传。
- `const.py#OAUTH2_CLIENT_ID`（`'2882303761520251711'`）与 `const.py#OAUTH_REDIRECT_URL`（`'http://homeassistant.local:8123'`）为 HA 专属注册凭证；中枢网关证书签发接口 `/app/v2/ha/oauth/get_central_crt`（`miot_cloud.py#MIoTHttpClient.get_central_cert_async`）同样绑定 `X-Client-BizId: haapi` 与该 OAuth2 令牌。
- **架构判定**：MenuBarHome **严禁**复制 `ha_xiaomi_home` 代码、严禁借用其 `OAUTH2_CLIENT_ID` 或直调 `ha.api.io.mi.com` / `ha.mqtt.io.mi.com`；仅可进行**净室架构借鉴**（Clean-Room Learning），尤其重点吸收其无需 HA OAuth2 的**局域网直连推送协议 `miIO.sub`** 与 **MIoT Spec 补丁思想**。

#### (2) 三级通道路由、防封禁与零轮询推送机制
`miot_client.py#MIoTClient` 构建了完整的 **「中枢网关 > 局域网直连 > 云端」** 三级通道体系：
1. **写控制优先级（`miot_client.py#MIoTClient.set_prop_async`, `action_async`）**：
   - 第一优先：本地中枢网关 `MipsLocalClient`（前提：`online && specv2_access && group_id` 匹配，仅限 `cn` 区 `const.py#SUPPORT_CENTRAL_GATEWAY_CTRL`）。
   - 第二优先：局域网 Wi-Fi 直连 `MIoTLan`（UDP 54321）。
   - 第三兜底：云端 HTTPS `MIoTHttpClient.set_prop_async`（`/app/v2/miotspec/prop/set`）；若返回 `-704010000` 或 `-704042011`（移除/离线），异步触发单设备列表刷新 `__refresh_cloud_device_with_dids_async`。
2. **订阅推送仲裁（`miot_client.py#MIoTClient.__update_device_msg_sub`）**：
   - 每个设备维护唯一主订阅源 `_sub_source_list[did]`，按 `Gateway(push_available)` → `LAN(push_available)` → `Cloud(online)` 自动无缝热切换，避免重复订阅和重复回调。
   - **云端 MQTTv5 推送（`miot_mips.py#MipsCloudClient`）**：连 `{region}-ha.mqtt.io.mi.com:8883`，订阅 `device/{did}/up/properties_changed/#`、`device/{did}/up/event_occured/#`（注意小米官方拼写即 `occured`）、`device/{did}/state/#`。源码显式跳过 `blt.`（蓝牙）与 `proxy.`（代理网关子设备）的在线状态订阅，因云端不推其上下线事件（默认视为在线，`miot_mips.py:1016-1021`）。订阅采用分批节流（`MIPS_SUB_PATCH = 300`，间隔 `1s`），防一次订阅几百台设备打爆连接。
   - **中枢网关本地 MQTT（`miot_mdns.py#MipsService` + `miot_mips.py#MipsLocalClient`）**：
     - 通过 mDNS `_miot-central._tcp.local.` 发现中枢网关，解析 TXT `profile` 的 Base64 二进制负载：`[1:9]` 为大端 `did`、`[9:17][::-1]` 为小端 `group_id`、`[20]>>4 == 1` 为主中枢角色、`([22]>>1)&1 == 1` 确认开启 MQTT 套件（`miot_mdns.py#MipsServiceData.__init__`）。
     - 使用硬编码的 `MIHOME_CA_CERT_STR`（Mijia Root + MIOT CENTRAL GATEWAY CA）与云端签发的客户端证书做 **mTLS** 双向认证；载荷采用自定义二进制 TLV `_MipsMessage`（`<IB` 长度+类型：`ID=0, RET_TOPIC=1, PAYLOAD=2, FROM=3`，`miot_mips.py#_MipsMessage`）。
3. **规避轮询封禁与防刷爆设备的两大精巧设计**：
   - **读属性反直觉策略（`miot_client.py#MIoTClient.get_prop_async`, lines 738-750）**：源码明确注释「直接向网关或设备高频查大量属性会导致设备异常，因此优先查云端缓存」，并在 `miot_cloud.py#MIoTHttpClient.get_props_async` 传入 **`'datasource': 1`**（读云端缓存而非强制穿透设备）。
   - **200ms 批量聚合窗（`miot_cloud.py#MIoTHttpClient.get_prop_async`, `__get_prop_handler`）**：所有并发属性查询合入 `_get_prop_list`，等待 `GET_PROP_AGGREGATE_INTERVAL = 0.2s` 后单次打包最多 `GET_PROP_MAX_REQ_COUNT = 150` 条请求发送；同时对相同 `did.siid.piid` 复用同一个 `Future`（单飞去重），批次失败时统一 drain 置 `None` 避免死锁（lines 781-809）。

#### (3) 重大技术发现：不依赖 HA OAuth2 的局域网本地推送 `miIO.sub`（源码证实）
实读 `miot_lan.py#_MIoTLanDevice` 与 `MIoTLan`，揭示了米家 Wi-Fi MIoT 设备长期鲜为人知的**原生局域网推送机制**：
- **带虚拟身份的扩展探测包（`miot_lan.py#MIoTLan.__init__`, lines 516-521）**：
  - 传统 `python-miio` 发的 32 字节探测包是全 `0xFF`；而新版 MIoT 局域网协议在字节 `[16:20]` 填 `b'MDID'`，`[20:28]` 填 64 位随机 `virtual_did`，`[28:32]` 填 `0x00000000`，向 `255.255.255.255:54321` 广播（扫描间隔指数退避 `5s → 45s`）。
- **识别设备是否支持通配订阅（`miot_lan.py#MIoTLan.__raw_message_handler`, lines 1245-1261）**：
  - 设备返回的 32 字节响应中，若 `data[16:20] == b'MSUB'` 且 `data[24:27] == b'PUB'` 且 `data[28] == 0xFE`（`OT_SUPPORT_WILDCARD_SUB`）且 `data[27] in [0, 1, 4]`，同时设备带回的 `sub_ts`（`data[20:24]`）与本地记录不一致，客户端即发起订阅。
- **订阅与推送回执闭环（`miot_lan.py#_MIoTLanDevice.subscribe` & `MIoTLan.__message_handler`）**：
  - 发送加密 UDP RPC：`{"method": "miIO.sub", "params": {"version": "2.0", "did": "<virtual_did>", "update_ts": <ts>, "sub_method": "."}}`。
  - 订阅成功后，设备状态变化会主动加密推送 `method == "properties_changed"` 与 `method == "event_occured"` 到客户端监听端口！
  - 客户端维护 **5 秒重复消息去重窗**（`__filter_dup_message`，键 `f'{did}.{msg_id}'`），并必须回复 ACK：`{"id": msg['id'], "result": {"code": 0}}`，否则设备会反复重传。
- **设备筛选与抖动抑制（`miot_lan.py#_MIoTLanDevice.__update_keep_alive`, `__change_online`）**：
  - 仅对 `connect_type in [0, 8, 12, 23]`（Wi-Fi / 混合直连）且不在 `profile_models.yaml` 黑名单中的纯数字 `did` 启用 LAN 直连。
  - 4 态保活机：`FRESH → PING1(5s) → PING2(5s) → PING3(5s) → DEAD`，心跳间隔 `10s → 50s` 加 ±10% 抖动；若设备 `120s` 内上下线翻滚达到 `10` 次（`NETWORK_UNSTABLE_CNT_TH`），强制抑制上线状态 `300s`（`NETWORK_UNSTABLE_RESUME_TH`），根治 Wi-Fi 弱信号设备导致的 UI 闪烁。

#### (4) MIoT Spec v2 声明式补丁管线与实体自动映射
`miot_spec.py#MIoTSpecParser.__parse` 展示了官方如何驯服「数千厂商写烂的 MIoT Spec」：
1. 拉取基础实例：`https://miot-spec.org/miot-spec-v2/instance?type=<urn>`。
2. **四层静态/云端声明式补丁**：
   - **`spec_add.json`（`_SpecAdd`）**：向缺失服务/属性的型号追加标准定义（支持 URN 别名跳转）。
   - **`spec_filter.yaml`（`_SpecFilter`）**：按 `urn_key` 精确屏蔽坏掉的 `services / properties / events / actions`（支持 `9.*` 与 `*` 通配，如直接滤掉 `zhimi-ma4` 的 9/13/15 诊断属性、`narwa-001` 整机屏蔽）。
   - **`spec_modify.yaml`（`_SpecModify`）**：原位覆写错误的 `unit`、`format`、`access`、`value-range`、`value-list`，甚至支持 `expr` 表达式做值归一化（如大金空调把 `"COOL"` 映射为枚举 `0`），并支持多版本 URN 链式别名（`xiaomi-m4:2 -> xiaomi-m4:1`）大幅减少重复维护。
   - **多语言三层融合**：实例级 `miot-spec.org/instance/v2/multiLanguage?urn=...` → 标准模板库 `miot-spec-v2/template/list/{device,service,property,event,action}` + `cdn.cnbj1.fds.api.mi-img.com/res-conf/xiaomi-home/std_ex_*.json` + `bool_trans.yaml`（把枯燥的 True/False 译为「有人/无人」「漏水/正常」）。
3. **三级声明式实体映射（`specs/specv2entity.py`）**：
   - `SPEC_DEVICE_TRANS_MAP`（跨服务组合设备，如空调 = `air-conditioner` 必选 + `fan-control` / `environment` 可选；电视 = `speaker` + `television` + `play-control`）
   - → `SPEC_SERVICE_TRANS_MAP`（单服务映射，如 `light` / `ambient-light` / `indicator-light`（标记 `CONFIG` 隐藏到设置层） / `curtain` / `airer`）
   - → `SPEC_PROP_TRANS_MAP`（按属性短名 + `format` + `access` 自动映射为 Sensor / BinarySensor / Switch / Number / Select，含 `device_class` 与 `state_class`）。

---

### 2.2 `al-one/hass-xiaomi-miot` 与 `rytilahti/python-miio` 对比扒皮（源码证实）

| 机制维度 | `XiaoMi/ha_xiaomi_home`（官方） | `al-one/hass-xiaomi-miot`（社区霸主） | `rytilahti/python-miio`（底层协议库） | 对 MenuBarHome 的启示 |
| :--- | :--- | :--- | :--- | :--- |
| **Spec 索引范围** | 云端列表直接带 `urn`（`spec_type`） | `miot_spec.py#async_get_model_type` 拉 **`instances?status=all`**，`released` 优先、缺失回退 `debug` | 手写 `_mappings` 字典（`miot_device.py#MiotDevice`） | MenuBarHome 当前仅拉 `status=released`，改 `status=all` 可立增覆盖率 |
| **老款非 MIoT 设备** | 直接放弃（`lan/profile_models.yaml` 忽略本地） | **`miio2miot.py#Miio2MiotHelper`** 把传统 miIO `get_prop/set_power` 翻译成标准 MIoT `siid/piid`（支持模板/比例/字典映射） | 每款机型独立 Python 类实现 | 高频老设备（老净化器/插座/台灯）可用纯 JSON 映射表复用同一套 UI |
| **设备怪癖与防卡死** | `spec_filter.yaml` + `spec_modify.yaml` | **`device_customizes.py#DEVICE_CUSTOMIZES`**（3,957 行）：支持 `chunk_properties: 1`（单次只查 1 个属性防单片机死机）、`exclude_miot_properties`、`chunk_coordinators`（高频/低频属性分频轮询）、`auto_cloud`、`cloud_set_single`、`miot_cloud_write` | `get_properties_for_mapping(max_properties=15)`、`handshake_timeout` 定期重握手、失败重试 `id += 100`（`miioprotocol.py#MiIOProtocol.send`） | 必须允许按 model 声明 `chunk_size`、`exclude_props`、`cloud_only_write` 怪癖覆盖，而非全局一刀切 |
| **本地 ↔ 云端降级** | 三级状态机（中枢 > LAN > 云），推送驱动 | `device.py#Device.async_get_properties` 本地连续失败 3 次（`_local_fails >= 3`）切云端；`async_refresh_local_device` 云端重拉新 IP/Token 后复位本地通道 | 仅纯本地 UDP 54321 | MenuBarHome macOS 已有 3 次冷却+广播恢复，需补齐 Windows 端 + `miIO.sub` 推 |
| **登录与多账号** | 官方 HA OAuth2（自动 `refresh_token` 在 70% 生命周期提前续期，`miot_cloud.py:71`） | 账号密码/扫码/双 `sid`（`xiaomiio` + `micoapi` 小爱），支持 `v2/message/v2/check_new_msg` 探活 | 无云端登录 | MenuBarHome 扫码无 `passToken`（ADR-0004）安全性更高，但需做好多家庭/共享家/多账号体验打磨 |

---

### 2.3 MenuBarHome 当前米家直连基线诊断 & 7 大必做升级点

对照实读本仓源码（`Sources/MijiaCore/MiCloud/MiCloudProvider.swift`、`MiCloudClient.swift`、`MiotSpec.swift`、`LocalMiIOClient.swift`、`MiotSynthesizer.swift` 及 `windows/src/core/miCloud/`），MenuBarHome 当前已经做得非常扎实的地方包括：多账号与共享家发现（`v2/home/home_device_list`）、多键面板拆键（`splitParentDid/splitSiid`）、灯组折叠（`v2/groupv2/query_status`）、macOS 本地 UDP 54321 AES-128-CBC 混合读与子网广播 IP 恢复、泛型卡片兜底（`MiotFacetEngine`）、429 退避、空气开关强只读安全门（`isMainsBreaker`）。

但对比 `ha_xiaomi_home` 与 `hass-xiaomi-miot` 后，暴露出 **7 个 ROI 极高的升级缺口**：

1. **【P0 · 双端补差】Windows 端补齐 `LocalMiIOClient`（源码证实缺失）**
   - **现状**：`windows/src/core/miCloud/` 与 `windows/src-tauri/src/` 中**完全没有**本地 UDP 54321 miIO 客户端，Windows 所有米家设备 100% 依赖米家云端轮询，既拖慢响应（300ms–1s vs 本地 15ms），又让 Windows 用户成为米家 429 限流重灾区。
   - **升级方案**：在 `windows/src-tauri/src/` 用 Rust 实现与 macOS `LocalMiIOClient.swift` 同构的异步 UDP 54321 客户端（Tokio UDP + `aes`/`cbc`/`md5` crate + 定向广播恢复），通过 Tauri Command 暴露给 TS 层 `MiCloudProvider`；优先复用双端一致的 `LANEndpointBinding` 与冷却状态机。
2. **【P0 · 质变体验】在双端 `LocalMiIOClient` 中落地 `miIO.sub` 局域网主动推送**
   - **现状**：macOS `LocalMiIOClient.swift` 仅做轮询（面板打开高频拉、关闭低频拉），存在「物理按键关灯后菜单栏延迟数秒才刷新」「门铃/传感器靠云端事件轮询」的短板。
   - **升级方案**：采用净室实现，在本地探测包引入 `MDID + virtual_did` 32 字节握手，识别支持 `MSUB/PUB/0xFE` 的 Wi-Fi MIoT 设备后发送 `miIO.sub (version 2.0, sub_method: ".")`，常驻监听 `properties_changed` / `event_occured` 并回 ACK + 5s 去重窗。支持本地推送的设备立即退出周期属性轮询集合（仅保留 10s–50s 轻量 UDP 保活），大幅降低网络噪音与电量消耗。
3. **【P0 · 降 429 风险】云端属性读取升级 `v2/miotspec/prop/get` + `datasource: 1` 与 200ms 请求聚合**
   - **现状**：`Sources/MijiaCore/MiCloud/MiCloudClient.swift:823` 调用 `miotspec/prop/get` 且**未传 `datasource`**（默认穿透或走老路径），批量上限 100。
   - **升级方案**：后台周期刷新与冷启动快照改走 `v2/miotspec/prop/get` 并传 `datasource: 1`（读小米云缓存，不唤醒/不刷爆低功耗及 Wi-Fi 设备，单批支持至 150），仅在用户刚下发控制指令后的 follow-up 校验或手动强制刷新时走实时源，并引入 200ms 聚合窗口合并多卡片并发读取。
4. **【P1 · 扩设备覆盖】`MiotSpecStore` 切 `status=all` + 外置共享声明式补丁表（Patch + Quirk）**
   - **现状**：`Sources/MijiaCore/MiCloud/MiotSpec.swift:356` 仅拉 `status=released`，导致部分仍在 `debug` 状态的经典老型号（如 `yunmi.kettle.v1`）或刚上市新品只能跌落到只读 `fallbackSpecs.json`；且怪癖修正散落在 Swift/TS 双端代码中。
   - **升级方案**：改拉 `/miot-spec-v2/instances?status=all`（按 `released` 优先于 `debug/preview`、同状态取最高 `version` 归并，与 `hass-xiaomi-miot/core/miot_spec.py:315-324` 同构）；在 `Shared/` 新增双端共享 JSON 补丁包（`specPatches.json`：`filter` 屏蔽坏属性、`modify` 修正单位/量程/枚举、`quirks` 声明 `lanChunkSize` / `cloudOnlyWrite` / `excludeProps`），一次配置双端生效。
5. **【P1 · 降噪音与误伤】按 `pid`（`connect_type`）过滤 LAN 探测 + 抖动抑制器**
   - **现状**：蓝牙 Mesh / Zigbee 子设备并无独立 IPv4 UDP 54321 服务，对其参与广播或端点探测会浪费资源。
   - **升级方案**：参考 `ha_xiaomi_home` 仅对 `pid in [0, 8, 12, 23]` 且 `did` 为纯数字的非 Profile 设备启用 LAN 通道；引入 120s 翻滚计数抖动抑制器，避免边缘 Wi-Fi 设备在 LAN/Cloud 间反复横跳。
6. **【P1 · 中文体验】接入 MIoT 官方多语言翻译接口**
   - **现状**：泛型卡片与「更多设置」依赖本地静态词典 `Shared/deviceLabels.json` / `MiotFacetText`，遇到新厂商私有属性常回退为晦涩英文或原始 `description`。
   - **升级方案**：在 `MiotSpecStore` 缓存 `https://miot-spec.org/instance/v2/multiLanguage?urn=<urn>`（30 天 TTL，镜像失败静默降级），优先渲染官方 `zh_cn` / `en` 服务、属性与枚举文案。
7. **【P2 · 长尾存量】可选轻量 `miio2miot` 本地桥接表**
   - 针对用户反馈高频的老款非 MIoT Wi-Fi 设备（如老款智米净化器、老米家智能插座基础版），以静态 JSON 描述 `get_prop` / `set_power` 到虚拟 MIoT `siid/piid` 的映射，无需单独写设备卡片。

---

## 三、涂鸦（Tuya）生态源码三层扒皮

涂鸦是全球最大的 IoT ODM/白牌方案商（涵盖无数国内中小品牌开关、灯带、取暖器、香薰机、窗帘、宠物喂食器与海外 Meross/Arlec/LSC/SmartLife 生态），设备覆盖价值仅次于米家。但涂鸦没有像 MIoT Spec v2 那样公开透明的统一语义标准——同一类灯泡不同白牌的 DP-ID（数据点编号）可能完全不同（比如有的开关在 DP 1，灯类常在 DP 20，厂商自定义从 DP 101 起）。

### 3.1 局域网加密协议演进 v3.1 → v3.5（`localtuya` + `tuya-local` 源码证实）

实读 `rospogrigio/localtuya/custom_components/localtuya/pytuya/__init__.py` 与 `make-all/tuya-local/custom_components/tuya_local/device.py`，涂鸦本地 TCP（默认端口 `6668`）协议历经五个版本：

| 协议版本 | 帧头 / 帧尾 | 加密算法 | 校验方式 | 握手与载荷关键差异 |
| :--- | :--- | :--- | :--- | :--- |
| **v3.1** | `0x000055AA` / `0x0000AA55` | AES-128-ECB（仅 `CONTROL` 加密 + Base64） | CRC32 + Payload 前缀 `3.1` + 16B MD5 | `DP_QUERY` 明文；最老固件（`pytuya/__init__.py:1051-1070`） |
| **v3.2 (`type_0d`)** | `0x000055AA` / `0x0000AA55` | AES-128-ECB（二进制） | CRC32 | 即所谓 `device22` 变体：查状态必须用 `CONTROL_NEW (0x0D)` 且显式带 `{"1": null, ...}` DP 清单，否则报 `data unvalid`（`pytuya/__init__.py:205-210, 848-873, 938-944`） |
| **v3.3** | `0x000055AA` / `0x0000AA55` | AES-128-ECB（全加密，`3.3\x00*12` 头在密文外） | CRC32 | 存量最多，稳定可靠；部分能耗插座需发 `UPDATEDPS (0x12)` 主动刷新 DP 18/19/20 |
| **v3.4** | `0x000055AA` / `0x0000AA55` | **AES-128-ECB + 动态会话密钥**（`3.4` 头包在密文内） | **HMAC-SHA256 (32B)** | 建连后必须执行 **3-Way 会话密钥协商**（`0x03 SESS_KEY_NEG_START` 发 `local_nonce` → `0x04 RESP` 收 `remote_nonce + HMAC` → `0x05 FINISH` 回 `HMAC(remote_nonce)` → `session_key = AES_ECB(local_key, local_nonce XOR remote_nonce)`，`pytuya/__init__.py#TuyaProtocol._negotiate_session_key`, lines 970-1031）；数据嵌套在 `{"protocol": 5, "data": {"dps": ...}}` |
| **v3.5** | **`0x00006699` / `0x00009966`** | **AES-128-GCM (AEAD)**（动态会话密钥 + 每包 12B IV） | **16B GCM Auth Tag**（头部自偏移 4 起作为 AAD） | 2023+ 新固件主流（资料证实 + `tuya-local/const.py:13` 支持 `3.5`/`3.52`）；沿用 3-Way 会话协商，彻底淘汰 AES-ECB 与 CRC32；实现上需原生 GCM 库（Swift `CryptoKit.AES.GCM` / Rust `aes-gcm` / Node `crypto` 原生支持） |

**实战避坑（`tuya-local/device.py` 源码证实）**：
- **自动协议版本轮转（`_rotate_api_protocol_version`, lines 782-834）**：`API_PROTOCOL_VERSIONS = [3.3, 3.1, 3.2, 3.4, 3.5, 3.22, 3.42, 3.52]`；其中 `3.22/3.42/3.52` 是开启 `device22` 探测的伪版本号——源码特别警告**不可对所有设备盲开 `device22` 探测**，因为部分设备一旦误判切入 `device22` 会永久失联！仅在连续失败达到 `_AUTO_FAILURE_RESET_COUNT = 10` 次后才重启版本轮转。
- **单连接限制与持久推送**：多数涂鸦 Wi-Fi 模组同一时刻只允许 **1–2 个 TCP 6668 连接**（且连上后 `receive()` 即可接收设备主动推送，辅以 `5s` 心跳 + `30s` 周期兜底 `status()` / `updatedps()`）。
- **5 秒乐观写覆盖层（`_FAKE_IT_TIMEOUT = 5`, lines 151-158, 602-668, 754-780）**：写指令发出后设备不会立刻回推，立即读可能拿到旧状态导致 UI 开关回弹。`TuyaLocalDevice` 维护 `_pending_updates`（带 `sent` 与 `updated_at`），读状态时直接将 5 秒内未确认的新值叠加在 `_cached_state` 上，直到设备回推匹配值才清除。

### 3.2 YAML 模板驱动引擎：1,790 份模板如何实现「零代码适配」（源码证实）

实读 `make-all/tuya-local/custom_components/tuya_local/helpers/device_config.py` 与真实设备模板（如 `devices/arlec_fan_light.yaml`，截至 2026-11 该仓已沉淀 **1,790 份 YAML 模板**）：
- **双阶段自动识别算法（`TuyaDeviceConfig.matches` & `match_quality`, lines 138-236）**：
  1. **精确匹配**：若云端或广播拿到 `product_id`，命中模板 `products[].id` 直接得 **101 分**（高于任何模糊匹配）；
  2. **指纹打分**：无 `product_id` 时，校验必填 DP 是否齐全、每个 DP 的运行时类型（注意 Python `bool` 是 `int` 子类的防误判 `_typematch`）是否吻合，按「模板消费掉的 DP 数 / 设备上报总 DP 数 × 100」打分，取最高分模板（`device.py#TuyaLocalDevice.async_inferred_type`）。
- **声明式值变换管线（`TuyaDpsConfig`, lines 396-650）**：一份纯 YAML 即可表达复杂硬件编码，无需写一行设备代码：
  - 数据类型：`boolean / integer / float / string / bitfield / json / base64 / utf16b64 / hex / unixtime`；
  - 数值变换：`range(min/max)`、`scale` 缩放、`step`、`invert: true`（如色温冷暖反转 `arlec_fan_light.yaml:47-50`）、`target_range` 线性重映射；
  - 二进制解包：`format` 多字段大端 struct 解包 + `mask` 位掩码（含 `mask_signed` 补码解析）；
  - 联动逻辑：`conditions` 条件覆盖（如不同模式下有效选项列表动态变化）、`value_mirror` 镜像、`available` 动态隐藏实体。

### 3.3 云端拉取 `local_key` 与合规/产品权衡（源码证实 + 资料证实）

实读 `tuya-local/custom_components/tuya_local/cloud.py` 与 `const.py:22-23`：
- 现代涂鸦集成已用 **`tuya_sharing`（SmartLife / 涂鸦智能 App 用户码 + 扫码）** 取代了繁琐的涂鸦开发者后台建项目流程，且额外可调 `/v1.0/m/life/devices/{device_id}/status` 拿到 `dpStatusRelationDTOS`（云端官方 DP 名称/类型/枚举元数据！`cloud.py#Cloud.async_get_datamodel`, lines 187-217）。
- **但存在与小米官方插件类似的授权风险**：`tuya-local/const.py` 中的 `TUYA_CLIENT_ID = "HA_3y9q4ak7g4ephrvke"`、`TUYA_SCHEMA = "haauthorize"` 是涂鸦官方签给 Home Assistant 的专用凭据，**MenuBarHome 不可直接盗用**！
- **MenuBarHome 接入涂鸦的可行三步走**：
  1. **合规获取 `local_key`**：① 支持用户填入自有 Tuya IoT Platform 凭据一次性拉取 `local_key + product_id + dpStatusRelation` 后本地持久化（设备不重置配网则 `local_key` 永久有效，彻底摆脱 1 年试用期到期陷阱）；② 支持直接导入 JSON/CSV 或 `tinytuya devices.json`；③ 长期可向涂鸦申请商业/独立桌面 App 合作 Client ID 开通扫码。
  2. **本地协议 + 模板引擎**：以 ADR-0024 进程外适配器封装 v3.1–v3.5 TCP 长连接 + 复用或兼容 `tuya-local` 的 MIT 许可（确认 `tuya-local` 许可证后复用/参考其 YAML Schema 思路）设备模板体系，并结合 `dpStatusRelationDTOS` 自动兜底生成泛型卡片。

---

## 四、易微联 / Sonoff & 混合双通道仲裁器源码扒皮（`AlexxIT/SonoffLAN`）

`AlexxIT/SonoffLAN` 是智能家居开源界公认最优雅的 **「LAN + Cloud 混合双通道状态机」** 范本，代码极度精炼（核心 3 文件仅约 1,350 行），其模式可直接作为 MenuBarHome 多通道引擎的参考实现。

### 4.1 局域网零轮询通道（`core/ewelink/local.py#XRegistryLocal`）
- **状态推送直接寄生在 mDNS TXT 记录中（`_handler1` → `_handler3`, lines 64-150）**：监听 `_ewelink._tcp.local.`，设备状态变化时会广播更新的 mDNS TXT（`data1..data4` 拼接 + `iv` + `seq` + `type`）；客户端优先 `load_from_cache`（规避某些机型不发 A 记录导致 `async_request` 失败，lines 100-105），用 `MD5(devicekey)` 做 AES-128-CBC 解密即可拿到实时状态，**全程零轮询**！
- **控制指令与单片机防打死重试（`send`, lines 152-269）**：向 `POST http://<ip>:8081/zeroconf/<cmd>` 发送带 `Connection: close` 的加密 JSON；针对低端 ESP 单片机 HTTP Server 单线程并发时直接发 TCP RST 的通病，源码捕获 `errno.ECONNRESET` 后执行 **10 次 × 100ms 退避重试**（lines 238-260），实战稳定性极高。

### 4.2 云端 WebSocket 推送与防风控通道（`core/ewelink/cloud.py#XRegistryCloud`）
- **动态调度 + 长连接（`connect`, lines 550-602）**：先 GET `https://{region}-dispa.coolkit.{cn|cc}/dispatch/app` 拿最优 WSS 节点，握手 `action: "userOnline"`（`version: 8`）；支持服务端下发心跳周期 `hbInterval`；显式识别 **`error == 406`**（同账号异地顶号）并停止盲目重登。
- **异步指令-回执匹配器（`ResponseWaiter`, lines 256-286）**：每条发出的 WS 指令带全局单调毫秒序列号 `sequence`，在 `_waiters[sequence]` 挂载 `asyncio.Future`，收到无 `action` 的回包时按 `sequence` 唤醒并返回 `"online" / "offline" / "timeout"`。
- **内置防 DDoS 节流阀（`send`, lines 449-460）**：强制全局指令最小间隔 `0.1s`（防止云端断连），对高频耗能传感器激活指令 `uiActive` 额外限制 `1.0s` 节流；断连重连采用 `15s * 2^n`（上限 `64m`）指数退避。

### 4.3 双通道仲裁、指令合并与交叉探活（`core/ewelink/__init__.py#XRegistry`）
MenuBarHome 应重点借鉴的 **5 条黄金仲裁法则**（源码证实）：
1. **LAN 极速优先 + 1 秒断尾切云（`send`, lines 123-140）**：当 `can_local && can_cloud` 时，先发本地请求但**强压超时为 `timeout_lan = 1s`**；只要非 `"online"` 立即无缝回落 `cloud.send`，复用同一 `sequence`（便于设备/云端去重），用户体感无卡顿。
2. **差异化写后回查（lines 102, 137-139, 148-149）**：LAN 写入后设备会主动回推状态（或响应包已带加密 `iv/data`，`local.py:199-209`），**不额外发查询**；而 Cloud 写入后云端不保证回推，仅在 Cloud 写入成功且 `query_cloud=True` 时追加一次 fire-and-forget 的 `cloud.send(device, timeout=0)` 拉最新态。
3. **多通道写入 100ms 合并窗（`send_bulk`, lines 156-176）**：对多键开关/排插的并发写操作，先按 `outlet` 合并覆盖到 `device["params_bulk"]`，`sleep(0.1)` 后由首个弹出者一次性打包下发——彻底解决「一键全关 4 路排插发出 4 个并发 HTTP 请求把设备打重启」的问题！
4. **云/本地交叉探活（lines 136, 236, 308-313, 355）**：收到云端 `online` 状态变化、或本地发送失败后，将 `device["localping"] = 0`，让 5 秒后台巡检立刻执行一次本地探活；本地连续 3 次失败才降级为 `local = False`（`localfail >= 3`），但传感器刷新类命令失败不触发整机离线判定（lines 402-404）。
5. **异常云端噪点过滤（line 239）**：专门拦截云端对离线设备误推的 `{"subDevRssi": 127}` 心跳包，防止离线设备被误标为在线。

---

## 五、国际与局域网开放标准 + 国内大家电全景分析

### 5.1 Philips Hue CLIP v2（`home-assistant-libs/aiohue` 源码证实）
- **配网与安全**：本地 mDNS（`_hue._tcp.local.`）发现网桥，用户按一下桥顶物理 Link 键，客户端 POST `/api` 获取 `hue-application-key`（HTTPS 自签名证书，凭桥 ID/指纹校验），**无需任何云端账号**。
- **资源模型（`aiohue/v2/__init__.py#HueBridgeV2`）**：RESTful 强类型资源图（`device`、`light`、`grouped_light`、`room`、`zone`、`scene`、`smart_scene`、`motion`、`button`、`temperature`、`contact`），初始化单次全量 `fetch_full_state()` 拉齐，之后零轮询。
- **SSE 实时事件流（`aiohue/v2/controllers/events.py#EventStream`）**：
  - 长连 `GET /eventstream/clip/v2`（`Accept: text/event-stream`），逐行解析 `id:`（记录 `_last_event_id`，断线重连通过 `last-event-id` 请求头续传防丢事件）与 `data:`（JSON 事件数组：`add / update / delete`）。
  - **两个必须避开的实战暗坑（源码证实）**：
    1. **桥端并发≤3 硬限制**（`__init__.py:158-182`）：同时发超过 3 个 HTTP 请求即返回 `429/503`，客户端必须限制连接池并发 + 线性退避重试（`0.25s * retries`）。
    2. **官方 SSE 无心跳导致半开连接僵死**（`events.py#__keepalive_workaround`, lines 277-316）：Signify 长期未在 SSE 流加周期心跳，如果路由器重启或 Wi-Fi 切换，TCP 半开不会及时报错。`aiohue` 甚至被迫每 60s 修改一个虚拟 `geofence_client` 名称来人工制造一个事件验证通道存活（配合 `sock_read = 90s` 超时）！MenuBarHome 若接 Hue，可采用更轻量的 60s `GET /clip/v2/resource/bridge` 探活或监听系统网络切换事件主动重连 SSE。

### 5.2 Matter（`python-matter-server` 源码证实 + `matter.js` 桌面端可行性评估）
- **核心架构解剖（`matter-js/python-matter-server/matter_server/server/device_controller.py#MatterDeviceController`）**：
  - **发现与安全**：基于 IPv6 mDNS（已配网节点 `_matter._tcp.local.`，以 `<CompressedFabricID>-<NodeID>` 命名；待配网节点 `_matterc._udp.local.`）；依赖持久化 **Fabric 根证书/NOC（Node Operational Credentials）** 与 **DCL PAA（Product Attestation Authority）设备认证根证书库**。
  - **统一数据模型与零轮询订阅**：`Endpoint / Cluster / Attribute / Command` 四层结构（如 `OnOff`、`LevelControl`、`ColorControl`、`Thermostat`、`WindowCovering`、`DoorLock`、`BridgedDeviceBasicInformation`）；节点入网后执行全量 `_interview_node`（lines 587-664），并通过 `1/29/0`（Descriptor DeviceType == `14`）自动识别 **Matter Bridge（如 Aqara M3 / SwitchBot Hub / Hue Bridge）**；状态更新完全由设备主动推（Wi-Fi/Thread 订阅上限 `60s`，电池设备 `600s`，lines 88-92）。
- **桌面端充当 Matter Controller 的真实门槛与解法（资料证实 + 工程推断）**：
  - **为什么桌面端绝不能强推「一级配网器（Primary Commissioner）」**：
    1. **无 Thread 射频**：Mac/PC 均无 IEEE 802.15.4 芯片，无法直连 Thread 设备，必须依赖局域网内已有的 Thread Border Router（Apple TV / HomePod / HA ZBT-1 / Aqara M3），且桌面端**很难获取 Apple/Google 托管的 Thread Operational Dataset**；
    2. **BLE 跨端权限地狱**：首次给 Wi-Fi/Thread 新设备配网需经 BLE，Node `@abandonware/noble` 在 Windows/macOS 打包签名、系统蓝牙权限弹窗、休眠唤醒后易出错；
    3. **C++ `connectedhomeip` SDK 体积与 ABI 灾难**：`python-matter-server` 绑定庞大 C++ 芯片库且以 Linux 容器为一级公民，在 macOS+Windows 桌面客户端打包维护极重。
  - **破局方案：基于 `matter.js` 的「Multi-Admin 二级 IP 控制器」进程外适配器**：
    1. 用户照旧用手机（Apple Home / 米家 / Aqara / Google Home）完成首次硬件配网与 Thread 组网；
    2. 在手机 App 点「开启配对模式」复制 **11 位配对码**，粘贴进 MenuBarHome；
    3. 运行在 ADR-0024 子进程中的纯 TypeScript **`matter.js`** 控制器**纯走局域网 IPv6 UDP（免 BLE、免 Thread Dataset、零 C++ 原生编译依赖、一套代码通吃 macOS + Windows）**通过 PASE/CASE 加入多管理 Fabric，即可原生、低延迟、本地推送地控制所有 Matter 设备及 **Aqara M3 / Hue / SwitchBot / 宜家 Dirigera 等 Matter Bridge 背后的全部 Zigbee/BLE 子设备**！
    4. **注意 IPv6 前置**：需在 UI 诊断页检测本机局域网 IPv6 link-local (`fe80::`) 与 mDNS 可达性，并在未开启 IPv6 的家庭路由器场景给出清晰排查提示。

### 5.3 HomeKit HAP（`Jc2k/aiohomekit` 源码证实）
- **协议机制（`aiohomekit/controller/ip/connection.py#SecureHomeKitProtocol`）**：mDNS `_hap._tcp.local.` 发现 → SRP 6a Pair-Setup（输入 8 位配对码建立长期 Ed25519 信任）→ 每次重连执行 Curve25519 Pair-Verify 派生双向密钥（`a2c_key` / `c2a_key`）→ 将 HTTP/1.1 报文切为 `≤1024B` 分块并用 **ChaCha20-Poly1305** + 单调递增计数器加密（lines 208-259）；配件状态变化直接在同条 TCP 连接上推送 **`EVENT/1.0 200 OK`** 帧（`InsecureHomeKitProtocol.data_received`, lines 168-169），且一旦发生超时必须立即关闭重连以防加解密计数器错位（lines 144-149）。
- **为何不推荐作为 MenuBarHome 的主接入方案（产品与技术双硬伤）**：
  1. **HAP 单控制器排他性**：绝大多数 HomeKit 配件只支持绑定 1 个 Controller。中国/国际苹果用户基本已经把设备绑进了 iPhone「家庭」App，MenuBarHome 无法同时配对——总不能让用户把设备从 Apple Home 解绑！
  2. **macOS `HomeKit.framework` 限制**：原生 AppKit 应用无法直接调 `HMHomeManager`（仅 iOS / Mac Catalyst + App Store Entitlement 可用），且 Windows 完全无此能力。
  3. **替代路线**：通过 **Home Assistant 的 `homekit_controller` 间接接管**，或等待/引导设备经 **Matter Multi-Admin** 共享给桌面端。

### 5.4 高性价比局域网生态 & 桌面高频外设（资料证实）
以下 6 个生态**协议极简、零/低封号风险、与电脑桌搭/极客用户高度重合**，最适合作为 ADR-0024 首批参考与官方适配器：
1. **Shelly（Gen2 / Gen3）**：行业本地开放标杆。mDNS `_shelly._tcp.local.`，本地 HTTP/WebSocket JSON-RPC（`Switch.Set` / `NotifyStatus` 全推送），零云账号，且新款自带 Matter。
2. **WLED**：桌搭灯带/氛围灯统治级开源固件。mDNS `_wled._tcp.local.`，`/json/state` + `/ws` WebSocket 实时推，几十行代码即可完整适配亮度/RGB/预设动效。
3. **Yeelight**：mDNS/SSDP（`239.255.255.250:1982`，`ST: wifi_bulb`）发现 + TCP `55443` 持久连接逐行 JSON-RPC（`set_power` / `set_bright` / `set_ct_abx` + 设备主动推送 `props` 通知）。需用户在 Yeelight App 打开「局域网控制」（注意：2023+ 部分新款蓝牙 Mesh 吸顶灯/灯具不再提供 LAN 模式，改走米家或 Matter）。
4. **Govee**：欧美及国内桌搭爆款灯带/屏幕同步灯。App 开启「LAN Control」后纯 UDP 局域网无加密控制（`239.255.255.250:4001` 发 `scan`，本机听 `4002` 收回包，向设备 `4003` 发 JSON 控开关/亮度/RGB/色温）。实现门槛接近为零。
5. **TP-Link Tapo**：欧美高市占插座/灯泡/摄像头。新版固件启用 **KLAP v2**（本地 HTTP 两次随机种子 SHA-256 握手派生 AES-128-CBC 密钥+签名），需要用户提供 TP-Link 账号邮箱与密码本地算哈希认证；新硬件陆续支持 Matter。
6. **SwitchBot / Aqara / BroadLink**：
   - **SwitchBot**：本体靠 BLE（桌面端蓝牙穿透力与跨房间稳定性差），推荐优先借 **Hub 2 / Hub Mini Matter Bridge** 接入，无 Hub 时轻量调用官方 Cloud API v1.1（HMAC-SHA256 令牌，每日 10,000 次免费配额，够用但仅拉取+Webhook）。
   - **Aqara / 绿米**：国内全屋智能核心玩家，但 Aqara Cloud Open API 偏向企业认证且有配额限制，早期网关局域网开发者模式在新款已取消；社区虽有 `Aqara-LANLink` 逆向网关 TCP 推，但长期最稳妥路径是 **M3 / M2 / E1 网关开启 Matter Bridge**（或经 HA 中转）。
   - **BroadLink（博联 RM 系列）**：局域网 UDP 80 AES-128-CBC 发射学习到的红外/射频码，适合兜底老式非智能空调/风扇，但**无状态回传**，体验上限低于原生智能设备。

### 5.5 国内大家电开源接入现状与风险评估（资料证实）
- **美的 Midea（美居 / Colmo / 小天鹅 / 东芝）**：社区项目 `midea-ac-lan` / `midea-local` 已逐步并入 **Home Assistant Core**。支持空调、热水器、洗衣机等十余品类通过局域网 TCP（v2/v3 协议，v3 需 AES+HMAC 会话认证）实时同步与控制；**唯一摩擦点**在于首次配对需登录美居云端接口拉取设备的 `token` 和 `key`（云端登录接口时常变动或加校验），拉到本地持久化后日常可脱离云端。**评估**：适合作为 P3 进程外适配器或交由 HA 接入。
- **格力 Gree（格力+ 及 OEM 品牌）**：社区 `greeclimate`（HA 内置）支持**纯局域网 UDP 7000 广播发现与绑定**，老机型用公共硬编码 AES-ECB 密钥、新机型走 AES-GCM 密钥协商，日常完全不碰云端、无封号风险，空调单品类覆盖价值极高。**评估**：P3 阶段极具价值的纯本地空调适配器。
- **海尔 Haier（海尔智家 / 卡萨帝 / hOn）**：国内主流机型集成（如 `ha_haier_home`）依赖云端 OAuth2 + WebSocket 同步，海尔官方对第三方抓包与非官方客户端风控较严（历史上 hOn 曾大规模封禁/升级认证拦截开源集成）；仅东南亚 Haismart 局部出现 `haismart-local`。**评估**：维护成本高、稳定性不可控，**不建议自研直连，交由 HA 覆盖**。
- **华为鸿蒙 / HiLink（华为智慧生活）**：生态极度封闭，无公开面向个人第三方桌面应用的本地或云端设备控制 API，私有加密协议迭代快且合规风险极高。**评估**：**明确列入禁区，不投入逆向开发**。

---

## 六、摄像机实时流生态与 `AlexxIT/go2rtc` 源码级优化技巧

MenuBarHome 双端已将 `go2rtc` 与最小化 LGPLv2.1 `ffmpeg` 深度整合为内置 Helper（见 [docs/agents/windows-camera.md](../../agents/windows-camera.md)）。实读 `AlexxIT/go2rtc` 源码，挖掘出 **5 项可直接提升起播速度、省流效率、双向语音与多品牌覆盖的源码级技巧**：

### 6.1 `go2rtc` 核心机制源码剖析（源码证实）
1. **按需惰性拉流与并发防抖（`internal/streams/stream.go`, `add_consumer.go`）**：
   - `Stream` 维持 `producers` 与 `consumers` 列表，只有当第一个消费者接入 `AddConsumer` 时才执行 `prod.Dial()` → `GetMedias()` → 编解码精确匹配 `MatchMedia` → `prod.start()`；最后一个消费者退出 `RemoveConsumer` 且无 `pending` 并发连接时立即 `stopProducers()` 释放摄像头连接槽位与带宽。
2. **复用流秒出首帧的关键帧注入（`add_consumer.go:86-88` + `pkg/rtsp/keyframe.go`）**：
   - 当新消费者接入一个已在播放（或预热中）的 Producer 时，go2rtc 自动调用 `track.RequestKeyframe()` 强制请求 IDR 关键帧，消除等待 2–4 秒 GOP 间隔的黑屏延迟！
   - 针对不同相机固件的怪癖，`pkg/rtsp/keyframe.go` 实现了 5 种策略（`#keyframe=pli` RTCP PLI、`fir` RTCP FIR、`play`、`resetup`/`replay` 旁路短建连触发关键帧），对国产监控摄像头尤为有效。
3. **预热探针 `preload`（`internal/streams/preload.go#AddPreload`）**：
   - 通过挂载一个轻量虚拟 `probe` 消费者保持上游流不断开（仅用于高频监控场景如门铃/婴儿房，且建议搭配子码流以控带宽）。
4. **小米 MISS 协议探测提速暗门（`pkg/xiaomi/miss/producer.go#probe`, lines 55-99）**：
   - 实读源码发现：`xiaomi://` 建连后默认会循环读包直到**同时拿到视频 SPS/VPS 帧 AND 音频帧**才结束 `probe()`（超时 15s）！如果桌面端静音预览小窗在 URL 参数加上 **`audio=0`**（`query.Get("audio") != "0"`），`probe` 拿到首个视频关键帧即刻返回，**跳过等待音频包，可直接缩短首帧起播延迟**；且 `Start()` 在读错时立刻 `client.Close()` 主动释放摄像头 P2P 会话槽位（lines 136-140）。
5. **跨品牌原生双向语音（Backchannel）引擎（源码证实）**：
   - `add_consumer.go:90-104` 原生支持 `DirectionSendonly` 反向音频轨自动路由，并在 `AddConsumerMedias`（line 17）支持 WebRTC 播放中途动态重协商开启对讲（**不断开正在看的高清画面**）：
     - **小米 MISS（`pkg/xiaomi/miss/backchannel.go`）**：调 `StartSpeaker()`，支持 PCMA / PCM 8kHz 40ms 切片与 Opus 双 20ms 合并为 40ms 包发给摄像头喇叭；
     - **TP-Link Tapo（`pkg/tapo/backchannel.go`）**：自动新开 `conn2` 独立会话发 `{"talk":{"mode":"aec"}}`，MPEG-TS 封装 PCMA 推流；
     - **海康/萤石 ISAPI（`pkg/isapi/backchannel.go`）**：通过 `isapi://` 辅助源走 HTTP 持久写回传音频；
     - **通用 RTSP/ONVIF（`pkg/rtsp/backchannel.go#Conn.addBackchannel`）**：**新开独立 RTSP Backchannel 会话**发送 G.711（含 Reolink 门铃帧重打包修复 `pcm.RepackG711`），完全不打断主视频流！

### 6.2 主流家庭摄像头在桌面端的低延迟与省流最佳实践

| 摄像头品牌 / 协议 | 推荐 go2rtc 输入源配置 | 本地直连门槛 | 双向语音支持 | 桌面端低延迟 & 省流关键技巧 |
| :--- | :--- | :--- | :--- | :--- |
| **米家 / 小米（CS2 / TUTK MISS）** | `xiaomi://...`（本仓已配 UDP 广播中继） | 中（需云端换 X25519 密钥 + P2P 冷却） | **支持**（`miss/backchannel.go`） | 静音小窗预览加 `&audio=0` 加速 `probe()`；保持本仓已验证的 **120s 隐藏保温 + 静态帧退避（45ms→500ms）+ 2.5s 同会话冷却**；HEVC 下严禁 `#width=` 缩放 |
| **海康威视 / 萤石（Hikvision / EZVIZ）** | `rtsp://user:pass@ip:554/Streaming/Channels/102`（预览）+ `101`（高清）+ `isapi://...`（对讲） | 萤石国内版需在 App 查机身 6 位验证码并开启「局域网实时预览/RTSP」 | **支持**（RTSP 或 `isapi://` 双源并列） | **主/子码流分轨**：卡片小窗默认拉 `102`（子码流 640p H.264，几乎零 CPU 软解负担），弹窗放大再切 `101`；H.264 源优先直通 WebRTC/MSE（<0.5s 延迟），规避 FFmpeg MJPEG 转码 |
| **大华 / 乐橙（Dahua / Imou）** | `rtsp://user:pass@ip:554/cam/realmonitor?channel=1&subtype=1&unicast=true&proto=Onvif` | 低（局域网默认开 RTSP/ONVIF） | **支持**（加 `proto=Onvif`，子流加 `#backchannel=0` 防双占） | 子码流 `subtype=1` 预览，主码流 `subtype=0` 放大；配 `#keyframe=pli` 加快秒开 |
| **TP-Link Tapo** | `tapo://cloud_pass@ip` 或 `rtsp://cam_user:cam_pass@ip:554/stream2` | 低（App 高级设置建本地摄像头账号） | **支持**（`tapo://` 原生 `aec` 双向语音） | `stream2`（360p/720p）做托盘小窗省流，`stream1` 做全屏；若需对讲用 `tapo://` 协议源 |
| **通用 ONVIF / RTSP / HomeKit 摄像头** | `onvif://user:pass@ip`（自动发现多码流 + PTZ）或 `rtsp://...` | 极低（标准协议 + WS-Discovery 自动扫局域网） | 视设备支持 ONVIF Profile T | 利用 `go2rtc` 内置 ONVIF 自动探测并拉取低清子码流 + 复用 MenuBarHome 已有 PTZ 控件；对 H.264 源优先走本地 WebRTC（音频 8kHz G.711 自动与浏览器 Opus 互转），仅在 H.265 或异常时间戳设备（如部分米家 CS2 固件）自动降级到本仓现有的鉴权 IPC MJPEG 链路 |

---

## 七、源码级「规格驱动 / 模板驱动」跨厂商适配核心设计（对接 ADR-0024）

综合 10 个上游仓库的源码经验与本仓 [ADR-0024](../../adr/0024-out-of-process-adapter-protocol.md)（进程外适配器协议 v0），要让 MenuBarHome 以**最小研发与维护成本**从「2 生态（米家+HA）」扩展到「10+ 生态、数千设备型号」，核心不在多写几个硬编码 Provider，而在于把**协议差异下沉为标准四层管线**：

```
┌────────────────────────────────────────────────────────────────────────┐
│ L4 宿主统一展示与安全层（Swift / TS 共享语义，宿主唯一持有）              │
│   15 类 DeviceKind + 泛型 Facet 卡片 + DeviceDeduplicator + 写入安全门  │
└───────────────────────────────▲────────────────────────────────────────┘
                                │ ADR-0024 stdio NDJSON JSON-RPC 2.0
                                │ (snapshot / events.stateChanged / v1 control.execute)
┌───────────────────────────────▼────────────────────────────────────────┐
│ L3 进程外适配器边界（HomeAdapter + ProcessSupervisor 故障隔离）          │
│   轻量二进制 / Node 适配器：Hue / WLED / Shelly / Yeelight / Govee /    │
│   Tuya Local / Matter.js / Sonoff / Gree / Midea                       │
├────────────────────────────────────────────────────────────────────────┤
│ L2 双模「规格 / 模板」驱动映射层（零代码覆盖 90% 长尾型号）               │
│   模式 A（强 Spec 生态：MIoT / Matter / Hue / Shelly）                   │
│     原始 Spec ──► Patch(add/filter/modify) ──► 多语言 ──► 能力规则映射   │
│   模式 B（无 Spec 生态：Tuya DP / Sonoff UIID / 私有 JSON）              │
│     产品指纹/DP 打分 ──► YAML/JSON 声明式模板 ──► 值变换管线(scale/mask) │
├────────────────────────────────────────────────────────────────────────┤
│ L1 混合双通道仲裁引擎（借鉴 SonoffLAN + ha_xiaomi_home + tuya-local）   │
│   路由：LAN 推 > LAN 拉(≤1s 短超时) > Cloud 推/拉(缓存优先+200ms 聚合)   │
│   韧性：100ms 写入合并窗 + 5s 乐观写防回弹 + 交叉探活 + 120s 抖动抑制     │
└────────────────────────────────────────────────────────────────────────┘
```

### 7.1 双模声明式适配引擎关键设计要点
1. **统一「设备模板 / 规格补丁」Schema（跨端共享纯数据文件）**：
   - **Patch 补丁模式（升级现有米家 + 赋能 Matter/Hue）**：采用 `ha_xiaomi_home` 的三段式外置补丁（`add` / `filter` / `modify`）+ `hass-xiaomi-miot` 的 `quirks`（`lanChunkSize`、`cloudOnlyWrite`、`pollIntervalGroup`、`excludeProps`），所有补丁支持**别名引用**（同一厂商系列多版本共享 1 份规则），放在 `Shared/spec-patches/` 下由双端与适配器共用。
   - **Template 模板模式（赋能涂鸦、格力、私有协议）**：采用 `tuya-local` 经过 1,790 款真实设备验证的 YAML/JSON 模板语法：
     - 匹配规则：`products[].id` 精确命中（101 分） > 必填键齐全 + 类型一致覆盖率打分（0–100 分）；
     - 值变换原语：`range`、`scale`、`step`、`invert`、`target_range`、`bitmask`、`hex/base64`、`enumMap`、`conditions`（条件覆盖）；
     - **兜底泛型卡片**：未命中任何专用模板时，若上游提供自描述元数据（如涂鸦云端 `dpStatusRelationDTOS`、MIoT 未分类属性、Matter 未知 Cluster），自动投影到 MenuBarHome 现有的 `DeviceKind.generic` + `FacetControl` 抽屉，做到**「接入即看见、绝不静默丢设备」**。
2. **与 ADR-0024 契约的 3 个关键对齐提醒（工程实证）**：
   - **凭据边界对齐（ADR-0024 §六）**：ADR-0024 明确规定 `leases[].kind` **仅接受上游强制过期的短期令牌**（如 OAuth2 `access_token`），禁止把静态密钥伪装成租约。而局域网协议中大量存在**静态长期密钥**（Hue `app_key`、Tuya `local_key`、Sonoff `devicekey`、Midea `token/key`、Matter NOC 证书）。这些凭据应通过 ADR-0024 允许的 `ui.configSchema` 标记 `writeOnly: true` 或存储在适配器私有加密数据区（或由宿主按 `adapterId` 隔离托管并在 `initialize.config` 下发），同时在 Manifest 中强校验 `permissions.network.lan: true` 与 `internet: []`（纯局域网适配器**断外网权限**，从根源杜绝静态 `local_key` 外泄风险！）。
   - **硬件指纹去重对齐（ADR-0024 §五）**：当同一设备同时经「米家直连 + Matter 适配器」或「HA + Hue 适配器」接入时，所有适配器必须在 `DeviceDescriptor.identity` 中如实上报 `macAddresses`、`dids` 或 `uniqueIds`（如 Hue Zigbee IEEE 地址 / Matter SerialNumber），交由宿主 `DeviceDeduplicator` 确定性归并，避免菜单栏出现双份重复卡片。
   - **写能力演进对齐（ADR-0024 §3.3 阶段 5）**：虽然 v0 严格只读，但第一批试点适配器（WLED / Shelly / Hue / Govee）在设计内部通道仲裁器时就应预留 `grantId` 幂等去重与 `100ms` 批量合并窗，进入阶段 5 开放 `control.execute` 后即可直接具备防回弹与防打死设备能力。
3. **社区长尾覆盖率飞轮（低维护成本秘诀）**：
   - 在 MenuBarHome 现有的「复制诊断」基础上增加**「导出脱敏设备指纹（Raw Spec / DP Dump）」**按钮（自动剥离 Token/IP/UID/名称）；
   - 遇到未完美适配的新型号，用户只需贴出脱敏 JSON 提 Issue，维护者或 AI 辅助生成一份 30 行的声明式 Patch/Template JSON，经 CI Schema 校验合并进模板仓库，客户端即可热更新/随小版本生效——实现**设备覆盖面与核心代码量解耦**。

---

## 附：本次实读源码核验索引（精选核心 `path#symbol`）

| 仓库 | 文件路径与符号（`path#symbol`） | 核心证实内容 |
| :--- | :--- | :--- |
| `XiaoMi/ha_xiaomi_home` | `custom_components/xiaomi_home/miot/const.py#OAUTH2_CLIENT_ID`, 文件头 License | HA 专用 OAuth2 凭证与禁止用于非 HA 软件的许可红线 |
| `XiaoMi/ha_xiaomi_home` | `custom_components/xiaomi_home/miot/miot_lan.py#_MIoTLanDevice.subscribe`, `MIoTLan.__raw_message_handler`, `__message_handler` | UDP 54321 `MDID` 探测、`MSUB/PUB/0xFE` 识别、`miIO.sub` 局域网主动推送、5s 去重与 120s 抖动抑制 |
| `XiaoMi/ha_xiaomi_home` | `custom_components/xiaomi_home/miot/miot_mips.py#MipsCloudClient`, `MipsLocalClient`, `_MipsMessage` | 云端 MQTTv5 推送、中枢网关 mTLS + TLV 帧、300 批量订阅节流、跳过 `blt.`/`proxy.` 上下线 |
| `XiaoMi/ha_xiaomi_home` | `custom_components/xiaomi_home/miot/miot_mdns.py#MipsServiceData.__init__` | `_miot-central._tcp.local.` TXT `profile` Base64 解码（`did`/`group_id`/`role`/`suite_mqtt`） |
| `XiaoMi/ha_xiaomi_home` | `custom_components/xiaomi_home/miot/miot_client.py#MIoTClient.set_prop_async`, `get_prop_async`, `__update_device_msg_sub` | 中枢>LAN>云写路由、读优先云缓存防刷爆、单主订阅源热切换 |
| `XiaoMi/ha_xiaomi_home` | `custom_components/xiaomi_home/miot/miot_cloud.py#MIoTHttpClient.get_props_async`, `__get_prop_handler` | `datasource: 1`、200ms / 150 属性批量聚合窗与失败 drain 防死锁 |
| `XiaoMi/ha_xiaomi_home` | `custom_components/xiaomi_home/miot/miot_spec.py#MIoTSpecParser.__parse`, `specs/specv2entity.py#SPEC_DEVICE_TRANS_MAP` | `spec_add/filter/modify` 四层补丁、官方多语言与三级实体映射表 |
| `al-one/hass-xiaomi-miot` | `custom_components/xiaomi_miot/core/miot_spec.py#MiotSpec.async_get_model_type` | `instances?status=all` 拉全量、`released` 优先于 `debug` |
| `al-one/hass-xiaomi-miot` | `custom_components/xiaomi_miot/core/miio2miot.py#Miio2MiotHelper`, `core/device_customizes.py#DEVICE_CUSTOMIZES`, `core/device.py#Device.async_get_properties` | 老 Profile 设备到 MIoT 桥接、3,957 行设备怪癖表、3 次失败切云与 IP/Token 热刷 |
| `rytilahti/python-miio` | `miio/miioprotocol.py#MiIOProtocol.send`, `miio/miot_device.py#MiotDevice.get_properties_for_mapping` | `handshake_timeout`、重试 `id+=100`、15 属性分片与 Token 错误精准区分 |
| `make-all/tuya-local` | `custom_components/tuya_local/device.py#TuyaLocalDevice`, `helpers/device_config.py#TuyaDeviceConfig.match_quality`, `TuyaDpsConfig`, `cloud.py#Cloud.async_get_datamodel` | 持久连接推+5s 心跳、5s 乐观写 `_FAKE_IT_TIMEOUT`、协议自动轮转（3.1–3.52）、1,790 份 YAML 模板打分引擎与云端 DP 数据模型拉取 |
| `rospogrigio/localtuya` | `custom_components/localtuya/pytuya/__init__.py#TuyaProtocol._negotiate_session_key`, `_encode_message`, `detect_available_dps` | Tuya v3.1–v3.4 帧编码、`device22 (type_0d)` 探测与 v3.4 3-Way 会话密钥协商 |
| `AlexxIT/SonoffLAN` | `custom_components/sonoff/core/ewelink/__init__.py#XRegistry.send`, `send_bulk`, `local.py#XRegistryLocal`, `cloud.py#XRegistryCloud` | mDNS TXT 加密推送、HTTP 8081 `ECONNRESET` 10 次重试、1s LAN 短超时切 WS、100ms 合并写与交叉探活 |
| `home-assistant-libs/aiohue` | `aiohue/v2/__init__.py#HueBridgeV2.request`, `aiohue/v2/controllers/events.py#EventStream` | CLIP v2 资源图、并发≤3 限流重试、SSE `last-event-id` 续传与僵死保活坑 |
| `Jc2k/aiohomekit` | `aiohomekit/controller/ip/connection.py#SecureHomeKitProtocol`, `InsecureHomeKitProtocol.data_received` | HAP 1024B ChaCha20-Poly1305 分块加密、`EVENT/1.0` 推送与超时错位强断重连 |
| `matter-js/python-matter-server` | `matter_server/server/device_controller.py#MatterDeviceController._interview_node`, `start` | IPv6 mDNS (`_matter._tcp`)、Bridge 识别（DeviceType 14）、Wi-Fi/Thread/电池分层订阅 |
| `AlexxIT/go2rtc` | `internal/streams/add_consumer.go#Stream.addConsumer`, `preload.go#AddPreload`, `pkg/xiaomi/miss/producer.go#probe`, `pkg/xiaomi/miss/backchannel.go`, `pkg/rtsp/keyframe.go`, `pkg/rtsp/backchannel.go`, `pkg/tapo/backchannel.go`, `pkg/isapi/backchannel.go` | 惰性起播、关键帧按需触发（PLI/FIR/ReSETUP）、小米 `audio=0` 探测提速与 4 大协议双向语音实现 |
| `MenuBarHome`（本仓基线） | `Sources/MijiaCore/MiCloud/MiCloudClient.swift#getProps`, `MiotSpec.swift#loadTypeIndex`, `LocalMiIOClient.swift`, `windows/src/core/miCloud/`, `docs/adr/0024-out-of-process-adapter-protocol.md` | 证实 Windows 缺失 `LocalMiIOClient`、Mac 未启用 `miIO.sub`、云端未传 `datasource: 1`、Spec 仅拉 `released` 及 ADR-0024 契约边界 |
