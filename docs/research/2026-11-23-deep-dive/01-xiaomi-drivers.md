# 01 米家 / 小米生态驱动与协议增量深挖

调研日期：2026-11-23
范围：米家凭据与云端 API 控制面、云端 MQTT（MIPS）与局域网 MIPS、局域网 miIO（含推送订阅）、BLE / Mesh / Zigbee 子设备的三条本地通道、米家手动场景云 API、型号覆盖表与节流/离线判定策略。**不重复** `2026-11-05-ecosystem-benchmark.md` 已写透的 `cover.py`、`spec_transform()`、homebridge-miot 解析阶梯、miIO UDP 包头加密。
读过的仓库（浅克隆，默认分支 HEAD）：

| 仓库 | commit | 日期 | 读法 |
| --- | --- | --- | --- |
| [XiaoMi/ha_xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home) | `75b3acb`（v0.5.0） | 2026-09-28 | 全量读 `miot/miot_mips.py`、`miot/miot_client.py`（相关段）、`miot/miot_lan.py`、`miot/miot_cloud.py`、`miot/miot_mdns.py`、`miot/const.py`、`config_flow.py`、`translations/en.json` |
| [al-one/hass-xiaomi-miot](https://github.com/al-one/hass-xiaomi-miot) | `8ac4df7` | 2026-11-18 | `core/device.py`、`core/xiaomi_cloud.py`、`core/mini_miio.py`、`core/miot_local_devices.py`、`core/miot_spec.py`、`device_customizes.py`、`config_flow.py`、`system_health.py` |
| [merdok/homebridge-miot](https://github.com/merdok/homebridge-miot) | `d27d98f`（v2.2.0） | 2026-11-18 | `lib/protocol/MiotDevice.js`、`MiioProtocol.js`、`MiCloud.js`、`lib/constants/Constants.js` |
| [Do1e/mijia-api](https://github.com/Do1e/mijia-api) | `2cc61f2` | 2026-10-10 | `mijiaAPI/apis.py` |
| [rytilahti/python-miio](https://github.com/rytilahti/python-miio) | `9a00e08` | 2026-07-25 | `miio/cloud.py`、`miio/device.py`、`miio/integrations/genericmiot/` |
| [Yonsm/MiService](https://github.com/Yonsm/MiService) | `a1727f7` | 2026-10-15 | `miservice/miiolocal.py`、`miioservice.py`、`miaccount.py` |
| [PiotrMachowski/Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) | `c4db715` | 2025-10-26 | `token_extractor.py` |
| [alsuren/mijia-homie](https://github.com/alsuren/mijia-homie) | `04204e5` | 2026-11-19 | `mijia/src/lib.rs`、`btsensor/`、README |
| [huanyuejue/MiHome-Windows](https://github.com/huanyuejue/MiHome-Windows) | `71e550c` | 2026-11-15 | `app/core/service.py`、`net_guard.py`、`cache.py`、`tools/diag_poll_timing.py` |
| [aholstenson/miio](https://github.com/aholstenson/miio) | `dbd66fd` | 2018-05-17 | 只确认状态（见 §3.9） |

只读 GitHub 文件、未克隆：`ttys026/mit`（`a5d3218`，2026-09-15）、`vanchaklar/xiaomi-lab`（`fd4fb9e`，2026-09-25）、`MiEcosystem/miot-plugin-sdk`（`miot-sdk/service/sceneV2.js`、`scene.js`）。另核对 `al-one/hass-xiaomi-miot` issue **#2904**、**#2043**、**#2512**，`XiaoMi/ha_xiaomi_home` issue **#1586**、**#1862**，官方规格库当日 released 实例数 **16,372**。

---

## 0. 结论先行

1. **官方集成的读路径是「云 → 中枢 → 局域网」，只有写入和推送订阅才把本地放前面。** 源码注释写明了原因：批量直连读会让设备异常，所以读缓存优先走云（`miot_client.py:738-744`）。我们的 `fetchPropsHybrid` 正好相反——LAN 优先读、云兜底（`MiCloudProvider.swift:1082`）。两边都有道理，但官方这条理由我们此前没有记录【源码】。
2. **局域网推送（`miIO.sub`）确实存在，而且不需要任何小米凭据**：探针回复里带 `MSUB`/`PUB` 且 wildcard 字节为 `0xFE` 的机型可以被订阅，之后设备主动推 `properties_changed` / `event_occured`（`miot_lan.py:1240-1262`、`miot_lan.py:262-286`）。官方默认**关闭**（`config_flow.py:1784` 默认 `False`）。我们完全没有这条链路，LAN 只是"更快的轮询"【源码】。
3. **在线判定是三源 OR**：`__check_device_state(cloud, gw, lan)`，任一为真即在线，三源全无才是"设备已移除"（`miot_client.py:1345-1353`）。我们只信云端 `isOnline`，而且离线设备根本不进轮询键集（`MiCloudProvider.swift:1689-1695`）——云端标错一次，卡片就永久离线【源码】。
4. **ADR-0016 需要一处范围修正**：该 ADR 的原文是「在 `ha_xiaomi_home` 与 `python-miio` 里都不存在通过网关 miIO 转发子设备读写的方法」（`docs/adr/0016-...md:37`）——它只审计了那两个实现。第三方实现 al-one 提供了第三种：对 `pid == 18` 的 proxy 子设备复用**父网关的 miIO 连接**，把子设备 did 塞进 `get_properties` 的 params 做本地读写（`core/device.py:216-223`、`1684-1702`），且一位 VRF 空调用户在同网段后实测本地可控（issue #2512，2025-05-19 已解决）。建议把 ADR 的结论改写为「在那两个实现里不存在；al-one 走通了网关 proxy 子设备（仅限固件实现了 proxy 的机型）」【源码+检索】。
5. **米家手动场景可以只用现有 `xiaomiio` 会话读取和执行**：读 `AppSceneService/GetSimpleSceneList`（`get_type:2` → `manual_scene_info_list`），执行 `AppSceneService/NewRunScene`（`scene_type:2`）。al-one 的 PR #2904 明确「不需要新登录、新依赖或网关」。我们现在只有 HA 场景【源码+检索】。
6. **耗材是独立云接口**：`v2/home/standard_consumable_items`（`home_id` + `owner_id` + `filter_ignore:true`）返回跨型号的耗材条目（`mijiaAPI/apis.py:385-397`）。我们目前靠 spec 里的 `filter-life-level` 猜，覆盖率取决于型号【源码】。
7. **`.sN` 虚拟子设备云端只认父 did**：MiHome-Windows 把这条写成实测事实，错误码 `-704083036`，并"学到后用父 did 不再白跑一次失败请求"（`app/core/service.py:532-534`）。这与我们的 `splitParentDid` 结论独立互证（`MiCloudClient.swift:12-16`）【源码】。
8. **局域网批量读的行业共识是 10–15 条/包**：我们 10–14（`LocalMiIOClient.swift:475`）、homebridge-miot 14（`MiotDevice.js:28`）、al-one 15（`mini_miio.py:340`）、官方是"单条 + 0.1 s 聚合队列"（`miot_mips.py:1281-1297`、`1653-1674`）。我们已经达标，不需要改【源码】。
9. **官方把云读的节流写成硬约束**：每 0.2 s 聚合一次、单请求上限 150 条、**同一设备一个刷新周期内只读一次**、连续 3 轮失败就清空待办（`miot_cloud.py:244-245`、`miot_client.py:1707-1709`、`1808-1822`）。我们的云读是 100 条/请求、按需整批，没有"每设备每周期一次"的限制【源码】。
10. **云侧 `miotspec/prop/get` 的 `datasource: 1` 官方和 Do1e 都带，我们两端都没带**（`miot_cloud.py:744`、`apis.py:633`；我们 `MiCloudClient.swift:796-806`、`windows/.../client.ts:677-689`）。语义未确认，属于"低成本可验证"的候选【源码+推断】。

---

## 1. 官方 `XiaoMi/ha_xiaomi_home`（v0.5.0，`75b3acb`）

规模：`custom_components/xiaomi_home/miot/` 下 18,820 行 Python；核心是四个文件：`miot_mips.py`（1,674）、`miot_client.py`（2,064）、`miot_lan.py`（1,374）、`miot_cloud.py`（881）。许可证是"仅限非商用 HA 使用"的私有许可（`miot_mips.py:2-40`），**只可读不可抄代码**。

### 1.1 三层控制路由：云 / 中枢网关 / 局域网

写入（`miot_client.set_prop_async`，`miot_client.py:643-716`）的优先级是**固定顺序**，不是 try/fallback 链：

1. **路由表命中才走中枢**：`_device_list_gateway[did]` 同时满足 `online && specv2_access && 有 group_id`，且对应的 `MipsLocalClient` 存在；
2. 否则 `_device_list_lan[did].online` 为真就走 miIO；
3. 否则走云。

关键细节：命中中枢或局域网后**失败不回退**，直接抛错（`rc not in [0,1]` 就 `raise MIoTClientError`）。回退只发生在"设备不在该路由表里"。

读取（`miot_client.get_prop_async`，`miot_client.py:734-774`）反过来：

```
# NOTICE: Since there are too many request attributes and obtaining
# them directly from the hub or device will cause device abnormalities,
# so obtaining the cache from the cloud is the priority here.
```

云 HTTP 先试，失败才降级到中枢、再降到局域网。**这是官方的核心取舍：批量读走云缓存，写和推送走本地。**

批量刷新（`__refresh_props_handler`，`miot_client.py:1791-1838`）同样是这个顺序，写成 `await 云() or await 中枢() or await LAN()`——短路求值，前者成功就不碰后者。

UX 侧对用户的说法更直白（`translations/en.json` 的 `options.step.update_lan_ctrl_config.description`）：

> When the cloud and the central hub gateway cannot control the devices, the integration will attempt to control the devices through the LAN.

也就是说：**官方把局域网定位为"最后一条腿"，我们把局域网定位为"首选腿"。** 这不是谁对谁错，而是两边对"云端限流 vs 设备被读爆"的权重不同。

### 1.2 MIPS 云端 MQTT（`miot_mips.py`）

不是裸 MQTT，而是 **MQTT v5 + 自有 TLV 信封**：

- 信封 `_MipsMessage` 是 `[len:u32le][type:u8][data]` 的重复序列，type 0=ID、1=ret_topic、2=payload、3=from，字符串以 `\x00` 结尾（`miot_mips.py:90-160`）。
- 云端 client：`client_id=f'ha.{uuid}'`、`host=<region>-ha.mqtt.io.mi.com`、`port=8883`、`username=app_id`、`password=access_token`（`miot_mips.py:855-875`），TLS 带三件证书 + `tls_insecure_set(True)`（`miot_mips.py:621-636`）。
- **QoS 2 全线**（`MIPS_QOS = 2`，`miot_mips.py:221`）——宁愿重也不丢，因为属性推送丢了就没有第二次。
- keepalive 60 s（`const.py:61`），重连指数退避 `10 s → ×2 → 600 s` 封顶（`miot_mips.py:223-224`、`842-849`）。
- **订阅节流**：待订阅 topic 先塞进 `_mips_sub_pending_map`，`call_later(0.01)` 后开始泵，每轮最多 `MIPS_SUB_PATCH = 300` 个，轮间隔 `MIPS_SUB_INTERVAL = 1 s`，单 topic 重试超过 3 次就放弃（`miot_mips.py:225-226`、`514-528`、`723-756`）。这是为了应付"上千设备一次重连"的订阅风暴。
- 主题约定：`device/{did}/up/properties_changed/{siid}/{piid}`、`device/{did}/up/event_occured/...`（`event_occured` 是小米自己的拼写错误，官方在注释里点明：`miot_mips.py:946`）、`device/{did}/state/#`（在线态）。
- **BLE 与 proxy 子设备不订阅在线态**：`if did.startswith('blt.') or did.startswith('proxy.')` 直接 return，注释写「云端可能根本不发这类设备的 online/offline」（`miot_mips.py:1016-1022`）。
- 消息解码容错：非 UTF-8 payload 直接丢弃并记日志，因为抛异常会掀掉 paho 的读循环、连累后续消息（`miot_mips.py:1108-1118`）。这是个很实际的坑。
- 本地 client 的参数不同：重连 `6 s → 60 s`、`SUB_PATCH 1000`、`SUB_INTERVAL 0.1`（`miot_mips.py:1128-1131`）——本地 broker 就在局域网，可以更激进。

### 1.3 令牌与证书生命周期

- `access_token` 的"到期时间"不是服务端给的 `expires_in`，而是 **`expires_in × 0.7`**（`miot_cloud.py:71`、`200`）。也就是还没过期就换票，把时钟偏差和网络抖动折进余量里。
- 刷新触发线是 **提前 60 s**（`miot_client.py:561`），刷新后同时更新 HTTP 头、MIPS MQTT 密码、落盘三处（`miot_client.py:562-579`）。
- 中枢网关客户端证书：余量 **3 天**（`const.py:63`），本机生成 key + CSR，向 `get_central_crt` 换证（`miot_client.py:599-641`）；CA 用写死的 SHA-256 校验（`const.py` 末尾）。
- **只有中国区开中枢**：`SUPPORT_CENTRAL_GATEWAY_CTRL = ['cn']`（`const.py:115`）。六个区域 `cn/de/i2/ru/sg/us`（`const.py:106-112`），OAuth/MQTT host 按区域拼前缀（`miot_cloud.py:102-105`、`miot_mips.py:869`）。

### 1.4 属性订阅与批量 `get_prop` 的节流

三层节流叠在一起，值得逐层记：

**第一层：请求合并（去重 + 延迟 0.2 s）**

`request_refresh_prop(did, siid, piid)` 把键塞进 `_refresh_props_list`（dict，天然去重），首次入队时挂 `call_later(REFRESH_PROPS_DELAY = 0.2)`（`miot_client.py:82`、`718-733`）。UI 上十个实体同时 `async_update` 只会触发一次网络调用。

**第二层：单请求上限 150 + 剩余回填**

`__refresh_props_from_cloud(patch_len=150)`：不足 150 就整批取走并清空；超过 150 就用 `popitem()` 切 150 条出来，剩下的留在 dict 里（`miot_client.py:1656-1686`）。**注意 `popitem()` 是 LIFO**，所以饿死的是最早入队的键——这是个隐性的优先级倒置，官方没处理【源码】。

**第三层：每设备每周期一次 + 3 次重试清零**

- `__refresh_props_from_gw` / `__refresh_props_from_lan` 里都有同一句注释：「A device only requests once a cycle, continuous acquisition of properties can cause device exceptions.」（`miot_client.py:1705-1709`、`1757-1761`）。实现是 `if did in request_list: continue`，然后 `pop` 掉该键——**同设备本轮的其余键直接丢弃，不重排**。
- 整轮三源都失败 → `retry_count += 1`，间隔 `REFRESH_PROPS_RETRY_DELAY = 3 s` 重试；`>= 3` 就清空待办并记 `refresh props failed, retry count exceed`（`miot_client.py:1808-1822`）。

**第四层：HTTP 层再聚合一次（0.2 s / 150 条）**

`MIoTHttpClient.get_prop_async` 是给"单属性按需读"用的：同样的 dict 去重 + `GET_PROP_AGGREGATE_INTERVAL = 0.2` + `GET_PROP_MAX_REQ_COUNT = 150`，键格式是 `did.siid.piid`（`miot_cloud.py:244-245`、`762-841`）。这里有一个被修过的真实 bug：批量请求抛异常时，挂起的 future 永远不会 resolve，且下次同键会复用这个死 future，集成"直到重启都不恢复"；改法是异常时把 `results = []` 兜住，逐个 `set_result(None)`（`miot_cloud.py:778-790` 注释）。**我们的 `getProps` 走的是 `async throws`，不存在这个毒化路径，但值得确认 `MiCloudProvider` 在批量失败后不会复用已完成的 continuation。**

### 1.5 离线判定

`__check_device_state(cloud_state, gw_state, lan_state)`（`miot_client.py:1345-1353`）：

```
cloud None 且 gw False 且 lan False → None（设备被移除）
任一为 True                        → True
否则                               → False
```

三处状态更新（云在线态推送、中枢 devListChange、LAN 保活）都调它，只有合成结果变化才通知订阅者。云侧的错误码 `-704010000` / `-704042011` 被当作"设备可能被移除或离线"，触发按 did 重拉设备列表（`miot_client.py:697-707`）。

### 1.6 局域网 miIO（`miot_lan.py`）

**探针**不是 `python-miio` 的 `21 31 00 20 ff…`，而是 32 字节的 `!1\x00\x20` + 12×`ff` + `MDID` + 8 字节虚拟 did + 4 字节 0（`miot_lan.py:515-521`）。广播地址 `255.255.255.255`，扫描间隔 `5 s → ×2 → 45 s` 封顶（`miot_lan.py:448-449`、`1368-1375`）。

**保活状态机**（每设备一个，`miot_lan.py:357-400`）：

```
FRESH --(KA_INTERVAL, 10s→×2→50s, ±10% 抖动)--> PING1 --(5s)--> PING2 --(5s)--> PING3 --(5s)--> DEAD
任意入站包 → FRESH（DEAD→FRESH 时置 online=True）
PING3→DEAD 时置 online=False
```

**抖动抑制**（`miot_lan.py:402-430`）：保留最近 10 次在线态翻转记录；如果 10 次翻转都发生在 120 s 内，判定为"unstable device"，**上线要延迟 300 s** 才生效，下线立即生效。这条专门救那些 Wi-Fi 信号差、每分钟抖一次的插座——不然卡片会疯闪。

**机型黑名单**：`lan/profile_models.yaml`，823 个老 miIO 机型（每项只有 `ts` 字段，1,646 行 = 2 行/项），命中就跳过本地控制，注释是「Do not support the local control of Profile device for the time being」（`miot_lan.py:1086-1100`）。这是"老协议设备伪装成 MIoT"的排除名单。

**订阅（推送）**：入站探针若 `data[16:20] == b'MSUB'` 且 `data[24:27] == b'PUB'`，读 `data[28]` 判断是否 wildcard（`0xFE`）、`data[27]` 是 sub_type（只接受 0/1/4）、`data[20:24]` 是订阅时间戳；满足条件才发：

```json
{"method":"miIO.sub","params":{"version":"2.0","did":"<虚拟did>","update_ts":<ts>,"sub_method":"."}}
```

（`miot_lan.py:262-286`、`1240-1262`）。退订发 `miIO.unsub`，参数同上。

**上行消息处理**（`miot_lan.py:1271-1330`）：`properties_changed` / `event_occured` 按 `did/p/siid/piid` 匹配广播表；**每条上行都要回 ACK** `{"id":<原id>,"result":{"code":0}}`；5 s 内同 `did.msg_id` 重复的直接重发 ACK 不再分发（`miot_lan.py:1327-1338`）。

**`profile_models` 之外还有一层准入**：`did` 必须是纯数字（`UINT64`），`token` 必须 32 位十六进制（`miot_lan.py:1086-1097`）。`proxy.*` 与 `blt.*` 天然被排除。

### 1.7 中枢网关本地 MIPS

mDNS 服务 `_miot-central._tcp.local.`，`profile` 是 base64 二进制：

- `did = bytes[1:9]` 大端整数
- `group_id = hex(bytes[9:17] 反转)`
- `role = bytes[20] >> 4`，**只有 role == 1 才算有效服务**
- `suite_mqtt = (bytes[22] >> 1) & 1`，必须为真

（`miot_mdns.py:110-127`）。每 600 s 重新查询一次（`MIPS_MDNS_UPDATE_INTERVAL_S`，`miot_mdns.py:73`）。

发现中枢后，`MIoTLan` 会主动 `deinit`（`miot_lan.py:938-949`，日志原文 `find central service, deinit miot lan`）。本地 MIPS 的 API 是 `master/proxy/*` 主题：

| 主题 | 用途 |
| --- | --- |
| `master/proxy/get` | 单属性读（`{did,siid,piid}`） |
| `master/proxy/rpcReq` | `set_properties` / `action`（信封里 `method`+`params`） |
| `master/proxy/getDevList` | 子设备列表（`devList`，带 `online/specV2Access/pushAvailable`） |
| `master/appMsg/devListChange` | 子设备增删推送 |
| `master/proxy/getMijiaActionGroupList` / `execMijiaActionGroup` | **米家场景/动作组**（`miot_mips.py:1415-1445`） |

`get_prop_safe_async` 是"每设备 0.1 s 内只发最后一条请求"的丢弃式合并（`miot_mips.py:1281-1297`、`1653-1674`，`self._get_prop_queue[did].pop()` 取最后一条）——和云侧 0.2 s 全量合并不同，本地是**只保留最新**。

`devListChange` 带来新 did 时，`__on_gw_device_list_changed` 只对这些 did 重新拉 `getDevList`，然后只更新 `group_id` 匹配的记录（`miot_client.py:1259-1284`）。

### 1.8 官方自己仍在踩的坑（对我们有参考价值）

- **#1586（2026-01-02，open）**：装了 `xiaomi.gateway.hub1` 后，两台 Wi-Fi 设备（水壶、风扇）本地推送正常，但**断网不到一分钟就停更**，日志显示中枢把连接状态切成 "Local" 之后就没有数据了。说明中枢通道也有状态机缺陷【检索】。
- **#1862（2026-11-18，open PR）**：标题就是 *retain queued properties for local refresh after cloud misses*——官方正在补"云读失败后本地刷新要接着干"的洞。这恰好是我们"LAN 优先"设计天然避开的坑，但反过来我们缺了"云侧批量缓存"的抗限流能力【检索】。
- **#1791（ADR-0016 引用）**：中枢 `getDevList` 在固件初始化阶段可能超时。

---

## 2. `al-one/hass-xiaomi-miot`（`8ac4df7`）

### 2.1 路由开关：四个布尔量拼出的决策矩阵

不是"云 + 本地谁先谁后"，而是**先算这台设备能不能本地**：

```
use_local = !cloud_only && local && (local_only || miio2miot || custom('miot_local')
            || model in MIOT_LOCAL_MODELS || 是 proxy 子设备 && 父设备可本地)
use_cloud = !local_only && cloud && (cloud_only || !use_local || custom('miot_cloud'))
auto_cloud = !local_only && cloud && custom('auto_cloud')      # 默认关
```

（`core/device.py:874-909`）

（上面是归纳后的伪代码，不是源码原文；`proxy` 子设备那一支实际发生在 `async_init` 里，见 §2.6。）

`MIOT_LOCAL_MODELS` 是一份 1,139 项的**纯型号数组**（`core/miot_local_devices.py`，1,141 行含括号），命中即认为本地可控。这与官方的 `profile_models.yaml`（823 个**不可**本地控制的型号）正好是同一张表的两种写法——一个白名单、一个黑名单。两家都证明了一件事：**"这台型号能不能局域网控制"必须靠数据表，不能靠探测**。

还有两个隐藏开关：`check_lan`（云端拉取后顺手 `miIO.info` 一下，用来区分"设备离线"和"云抖"）和 `chunk_coordinators`（按属性子集分频轮询，见 §2.3）。

### 2.2 失败模型：三振出局 + 重读地址 + 静默回云

本地失败（`core/device.py:1013-1054`）：

1. `_local_fails += 1`；到 3 次且不是纯本地模式 → **重读云端设备列表**，只有 `localip` 或 `token` 变了才重建本地连接（`async_refresh_local_device`，`core/device.py:232-264`），重建成功就**立刻重试一次本地**；
2. 仍然失败且 `auto_cloud` 开 → `use_cloud = self.cloud`，日志降级为 warning，**静默切云**，`available` 保持 True；
3. `auto_cloud` 关 → `available = (_local_fails < 3)`，即 3 次之后卡片才变灰。

云端失败（`core/device.py:1063-1100`）：

- `_cloud_fails <= 3` 只记 info（"will retry"），超过 3 次才 `available = False`，并且**只在状态翻转那一次**记 error；
- 若 `check_lan` 开，同时 `miIO.info` 探测局域网：**局域网通就 `available = True`**——把"云抖"和"设备死"分开（`core/device.py:1068-1076`）。

这套模型比官方更细：官方只有三源 OR 出在线态，al-one 还区分"谁坏了"。

### 2.3 型号覆盖表的数据组织

`device_customizes.py` 3,957 行，键是型号或通配符（`'*.fishbowl.*'`、`'090615.curtain.*'`），值是一份扁平 dict。全仓 `custom_config_*('x')` 扫下来，词表大致分五类：

| 类别 | 键 |
| --- | --- |
| 实体重映射 | `switch_properties`(217)、`sensor_properties`(191)、`select_properties`(183)、`number_properties`(173)、`binary_sensor_properties`(35)、`button_actions`(93)、`select_actions`(16)、`action_params`(9) |
| 轮询节流 | `chunk_coordinators`(82)、`chunk_properties`(32)、`chunk_services`、`interval_seconds`、`notify` |
| 数据清洗 | `value_ratio`(68)、`miot_result_recode`、`cover_position_mapping`(9)、`position_reverse`、`motor_reverse` |
| 排除 | `exclude_miot_services`(62)、`exclude_miot_properties`(61)、`unreadable_properties` |
| 通道 | `miot_local`、`miot_cloud`、`miot_cloud_write`、`miot_cloud_action`、`auto_cloud`、`check_lan`、`miio2miot`、`miio_properties`、`extend_miot_specs` |

（统计口径：全仓 grep `custom_config_(bool|list|integer|json|float)('…')` 去重计数；括号里是 `device_customizes.py` 中出现次数。）

`chunk_coordinators` 是最值得抄的结构：把设备的属性切成若干子集，每组一个独立刷新周期。例：电量/信号 300 s、主状态 60 s、功率 10 s。实现上是给每组建一个 `DataCoordinator`，`all_mapping` 里把已分配的键 `pop` 掉，剩下的进主 coordinator（`core/device.py:617-680`）。**这是"差异化轮询"最省事的数据化写法**：不用改代码，只加一行配置。

`miot_result_recode` 处理一个奇葩现实：某些设备把值放在 `code` 字段里而不是 `value`。`normalize_miot_results` 会在 `value` 缺失且 `code` 是数字时把 `code` 搬进 `value` 并置 `code=0`（`core/device.py:749-766`）。

### 2.4 事件与动作的参数化

- **动作入参**：`action_params`（9 处）声明某 action 的参数名/顺序/取值范围，`button_actions` 把按钮折叠成一个固定入参的动作调用，`select_actions` 把下拉选项映射成不同 aiid。
- **事件记录**：`miio_cloud_records`（+ `miio_cloud_records_interval`，默认 `interval×10`）走 `user/get_user_device_data`，`type` 可以取 `prop` 或 `event`，`limit` 默认 5、时间窗默认 7 天（`core/xiaomi_cloud.py:163-186`）。这是**唯一一条我们也能走的事件路径**：不需要 MQTT，纯 HTTP 历史查询。
- **统计**：`micloud_statistics` / `stat_power_cost_key` / `stat_power_cost_type`（`stat_hour_v3` 等），同样走 `user/get_user_device_data`，但键是设备自定义的（如空调伴侣 `7.1`、老设备 `powerCost`）（`Do1e/mijia-api` 的 `get_statistics` 文档把这条写得很清楚，`apis.py:782-830`）。

### 2.5 日志与诊断

- logger 按型号命名：`logging.getLogger(f'{__name__}.{self.model}')`（`core/device.py:202`），HA 日志里能直接按型号过滤——比按设备名过滤稳定。
- **按状态迁移升降级**：按失败次数分档（`< 3` 记 info、`== 3` 记 warning、再多降为 debug），并且只在状态翻转那一次记 error（`core/device.py:1036-1053`、`1088-1096`、`1476-1480`）。我们目前用 `os.Logger` 的 `notice`/`error` 直出，重复错误会刷屏。
- 没有 `diagnostics.py`（无 HA 诊断导出）。只有 `system_health.py`：组件版本、**云 API 可达性**、**miot-spec 可达性**、登录账号数、设备总数（`system_health.py:14-40`）。"spec 服务不可达"被单列，说明它是个高频故障点。

### 2.6 `pid` 语义与 proxy 子设备（本条影响 ADR-0016）

代码里能直接看到的 `pid` 用法只有四处，但拼起来就是一张表：

| pid | 代码行为 | 出处 |
| --- | --- | --- |
| `0` / `8` / `''` / `None` | 认为有 LAN 地址 | `config_flow.py:261` |
| `6` / `15` / `16` / `17` | **不给本地连接**（`MiotDevice.from_device` 直接返回 None） | `core/device.py:1664` |
| `18` | **proxy 子设备**：复用父设备的 `MiotDevice`（父的 IP + token），`did` 用子自己的 | `core/device.py:216-223` |
| `21` | 隐藏的虚拟设备（mesh 灯组：`parent_id` 出现在 `did` 里） | `core/xiaomi_cloud.py:558-566` |

pid 6/15/16/17 的确切含义**未查到可信一手来源**，本文不猜。

关键在 pid 18 的读路径（`core/device.py:1684-1702`）：

```python
properties = [
    {'did': f'prop.{v["siid"]}.{v["piid"]}' if did is None else str(did), **v}
    for k, v in mapping.items()
]
return await self.async_get_properties(properties, max_properties)
```

`did` 非空时，每个 param 都带子设备 did；而 `self.miio` 是**父网关**的 socket。也就是 `get_properties` 打到网关 IP:54321，参数里点名 `proxy.<网关did>.<序号>`。

一手复现（issue #2512，2025-05-18 开、2025-05-19 用户确认解决）：

> 非常感谢已经解决了，切换到同一网段就可以本地控制了

设备是 `qdhkl.gateway.b19` + 子设备 `qdhkl.aircondition.ac`，日志里 `did: proxy.709155662.0103`。issue #2043 里另一位用户用 `python-miio` 的 `genericmiot` 对 `090615.gateway.ac10` 的 4 台 VRF 内机（`proxy.827601753.00001…00004`）也跑通了同样的路子。

**结论边界**：这只证明"网关自己实现了 miIO proxy 的机型"能本地读写**proxy 子设备**（VRF 内机是确定案例）。它**不**证明 BLE / Mesh 子设备也能走这条路——但那类子设备在云端设备列表里同样有 `parent_id`，是否走 proxy 完全取决于网关固件。因此 ADR-0016 第 37 行的结论不是"错"，而是"范围太窄"：它只审了 `ha_xiaomi_home` 与 `python-miio` 两个实现，而 al-one 是反例。建议改写为「在那两个实现里不存在；al-one 通过 pid==18 的父网关连接读写了 proxy 子设备，BLE/Mesh 子设备待实测」。

### 2.7 BLE 直连的钥匙：`blt_get_beaconkey`

`core/xiaomi_cloud.py:552-555`：`{'did': did, 'pdid': 1}` → `v2/device/blt_get_beaconkey`。同一接口也出现在 token 提取器里（`token_extractor.py:124-129`），并且它只对 `did` 含 `blt` 的设备调用（`token_extractor.py:883-888`）。这是 BLE 设备**绕开网关直连**（CoreBluetooth / bluez）所需的前置密钥，与 miIO token 是两套东西。

---

## 3. 其他语言 / 其他形态的实现

### 3.1 `merdok/homebridge-miot` v2.2.0

- 轮询 15 s（`Constants.js:2`），`MAX_POLL_RETRIES = 4`，重连间隔 `max(interval×4, 30s)`（`MiotDevice.js:29`、`103`）。
- 本地一次读 14 条（`MiotDevice.js:28`），超过就封顶到 14（`setAllPropRequestChunkSize`，`MiotDevice.js:215-222`）。
- **可恢复错误码白名单**：`[-30001, -9999, -30012]`，注释点名 `-30012 "busy."` 是设备瞬时过载，应该重试而不是判定轮询失败（`MiioProtocol.js:9-10`）。默认 4 s 超时、2 次重试、5 s 握手超时（`MiioProtocol.js:4-7`）。
- **云连接复用**：`https.Agent({keepAlive:true, keepAliveMsecs:30000, maxSockets:8})`，注释解释了原因——每次轮询都新建连接会重做 DNS + TLS 握手（`MiCloud.js:14-17`，关联 issue #767）。
- **云可达性缓存 30 s**：`isReachableThroughMiCloud` 有 30 s TTL 和 in-flight 去重，避免每台设备各探一次（`MiotDevice.js:30`、`326-348`）。
- 云/local 切换靠 `requiresMiCloud()` 标记 + 强制开关（`MiotDevice.js:319`）。

### 3.2 `Do1e/mijia-api`

宿主不同：`https://api.mijia.tech/app`，登录 `sid=mijia`（`apis.py:30-31`）——不是我们用的 `api.io.mi.com` + `sid=xiaomiio`。它能做的我们大多也能做，但参数是现成的：

| 能力 | 接口 | 参数要点 |
| --- | --- | --- |
| 场景列表 | `/appgateway/miot/appsceneservice/AppSceneService/GetSimpleSceneList` | `{app_version:12, get_type:2, home_id, owner_uid}` → `manual_scene_info_list` |
| 场景执行 | `.../AppSceneService/NewRunScene` | `{scene_id, scene_type:2, phone_id:"null", home_id, owner_uid}` |
| 耗材 | `/v2/home/standard_consumable_items` | `{home_id:int, owner_id, filter_ignore:true}` → `items[0].consumes_data` |
| 统计 | `/v2/user/statistics` | `{did, key:"siid.piid", data_type:"stat_hour_v3", limit, time_start, time_end}` |
| 消息 | `/v2/message/v2/check_new_msg` | `{begin_at}`，al-one 也拿它当"会话是否还有效"的探针 |
| 批量读 | `/miotspec/prop/get` | `{params:[…], datasource:1}` |

（`apis.py:376-397`、`487-537`、`576-637`、`633`、`782-830`、`399-403`）

### 3.3 `python-miio`

- `cloud.py` 的 `CloudDeviceInfo` 把 `parent_id`、`parent_model` 显式建模，`is_child` = `parent_id != ""`（`cloud.py:44-64`）。这是"云侧识别网关子设备"的最干净写法，比解析 did 前缀可靠。
- `MiCloud` 客户端走 `micloud` 库，`get_devices()` 逐 locale 拉（`cloud.py:88-140`）。
- `device.py:231-252` 的 `get_properties(properties, max_properties)` 是标准的切片循环；`genericmiot` 提供 `metadata`/`status` 子命令，可以直接把设备的 MIoT 元数据导出（`miio/integrations/genericmiot/meta.py`）。我们做 spec 缓存调试时可以做同类工具。

### 3.4 `Yonsm/MiService`

- `MiIOLocalService`：**不登录账号**，只要 IP + token 就能本地读写（`miiolocal.py:1-40`）。握手一次后只保留 `_stamp` 和 `monotonic` 偏移，后续包的时间戳靠 `stamp + elapsed` 推（`miiolocal.py:92-110`）——比每次重握手省一个 RTT。
- 重试策略：同一 UDP 包（同 msg id）最多重发 3 次（`miiolocal.py:76-89`）。
- 云侧 `https://{region}.api.io.mi.com/app`（cn 无前缀，`miioservice.py:66-68`）；规格查询直连 `https://miot-spec.org/miot-spec-v2/instance?type=<urn>`（`miioservice.py:191-195`）——**公开、无需鉴权**，可以作为我们 spec 拉取的备份通道。

### 3.5 `PiotrMachowski/Xiaomi-cloud-tokens-extractor`

- 设备列表用 `/v2/home/home_device_list`（不是 `home/device_list`），参数 `{home_owner, home_id, limit:200, get_split_device:true, support_smart_home:true}`（`token_extractor.py:108-115`）。
- 共享家庭枚举用 `/v2/user/get_device_cnt` 的 `share.share_family`（`token_extractor.py:117-122`、`857-860`）——比 `homeroom/gethome` 的 `share_home_list` 更直接。我们目前走后者（`MiCloudClient.swift` 的 `homeroom/gethome` + `share_home_list`），两条路都在用，不算缺陷。
- 对 `blt.` 设备额外查 `blt_get_beaconkey`（`token_extractor.py:883-888`）。

### 3.6 `ttys026/mit`（Rust，7★，`a5d3218`）

这份代码价值不在星数，而在于它是**官方 `miot_lan.py` 的逐行移植**，把 Python 的 asyncio 语义翻成了单线程 blocking socket + 定时器 tick：

- 文件头注释明说「a pragmatic, synchronous port of the LAN flow used by `XiaoMi/ha_xiaomi_home`」（`src/miot_lan.rs:1-15`）。
- 常量一字不差：`SCAN_INTERVAL 5→45`、`KA 10→50`、`FAST_PING 5`、`NETWORK_UNSTABLE 10/120/300`、`DEDUP_WINDOW 5s`、`OT_SUPPORT_WILDCARD_SUB 0xFE`（`src/miot_lan.rs:36-56`）。
- 保活状态机、抖动抑制、`miIO.sub` 推送全部保留（`src/miot_lan.rs:604-700`）。
- 另有 `src/mips_cloud.rs`（云端 MQTT）与 `src/property_cache.rs`；`src/mico_api.rs:29` 用的是**另一个**官方 OAuth client_id（与 `ha_xiaomi_home` 的不同）。也就是说生态里已经有多份"复用官方应用身份"的实现——这佐证 ADR-0014 的判断（第三方没有自己的注册通道），同时说明这条路在野外并不稀缺【源码】。

### 3.7 `alsuren/mijia-homie`（Rust，70★）

- 走 **BLE GATT 直连**米家温湿度计 2，`bluez-async`（Linux only），读历史特征 + 解密（`mijia/src/lib.rs`、`mijia/src/decode/history.rs`、`Cargo.toml` 依赖 `bluez-async`）。
- 与网关无关，也不需要 beaconkey（它用的是 BLE 连接 + 绑定时写入的 key，流程见 README 的 setup）。
- 对我们的意义：macOS 上对应的是 CoreBluetooth，但每个型号的 GATT 协议都要单独逆向，**不是通用能力**（见 §8 设想）。

### 3.8 `huanyuejue/MiHome-Windows`（833★，Python + 自家 UI）

- 云读批量 20 条/请求（`app/core/service.py:50`），跨设备合并成一次 `get_devices_prop`；`tools/diag_poll_timing.py` 是**专门量"整批/子设备/单次请求"耗时的只读脚本**（统计 `(条数, 耗时)` 对）。
- 实测事实（写进注释）：虚拟子设备 `<父did>.sN` 直接请求**一律返回 `-704083036`**，必须用父 did + 该路 siid；学到之后不再白试（`app/core/service.py:532-534`、`559-561`）。"每次白等约 6 秒"是他们的观测值。
- `net_guard.py` 给上游 `requests` 注入默认超时 `(10, 30)`，因为上游有几处 `requests.get` 没 timeout，表现为"界面无限转圈、日志一片安静"（`app/core/net_guard.py:1-25`）。
- 设备缓存带版本号，语义明确区分"确认无能力 = None"和"读不到 = 不写"，并因为语义变更升过两次版本（`app/core/cache.py:12-30`）。

### 3.9 `aholstenson/miio`（Node，2018 停更）

只作历史对照：`dbd66fd`（2018-05-17）之后无提交，协议实现停在 miIO v1（`get_prop`/`set_power` 字符串属性），没有 MIoT spec。**不作为对标来源**，只说明"老的 miIO 生态已经死透，MIoT spec 是唯一前进方向"。

---

## 4. BLE / 蓝牙 Mesh / Zigbee 子设备：把三条本地通道讲清楚

### 4.1 云端视角：怎么认出"这是个子设备"

三份独立实现给了三个判据，可以叠加用：

| 判据 | 出处 | 可靠性 |
| --- | --- | --- |
| `parent_id` 非空 | python-miio `cloud.py:44-64`；我们 Windows `cameraHubs.ts:282` 已读 | 高（云端显式字段） |
| `did` 前缀 `proxy.` | al-one `core/device.py:216-223`；官方 `miot_mips.py:1016` | 高（VRF 内机、部分网关子设备） |
| `did` 前缀 `blt.` | 官方 `miot_mips.py:1016`；token 提取器 `token_extractor.py:883` | 高（BLE 设备） |
| `did` 正则 `\.s\d+$` | 官方 `miot_cloud.py:718` | 高（多键面板虚拟子键，**不是网关子设备**） |
| `pid` 数值 | al-one `core/device.py:1664`、`216`；`config_flow.py:261` | 中（语义未完全公开） |

我们的问题很具体：**Swift 侧 `MiDeviceRecord` 没有 `parent_id`**（`MiCloudClient.swift:7-38` 只有 `splitParentDid`），所以"这台设备挂在哪个网关下"这件事我们根本没存。Windows 只在摄像机 hub 里读了 `parent_id`。

### 4.2 三条通道的现状与边界

| 通道 | 能覆盖 | 需要什么 | 我们的现状 |
| --- | --- | --- | --- |
| **miIO 直连**（UDP 54321） | 只有带 `localip` + `token` 的 IP 设备 | token（云端给） | 已实现（ADR-0021），**读 + 写，无推送** |
| **网关 proxy**（同一 UDP，params 带子 did） | 网关固件实现了 proxy 的 `proxy.*` 子设备 | 父网关的 IP + token | 未实现；`did` 非数字会被 `MiIOPacket` 直接拒（`MiIOCryptoAndPacket.swift:15`、`42`） |
| **中枢本地 MIPS**（TCP 8883 mTLS） | 中枢管辖的全部子设备（BLE/Mesh/Zigbee） | OAuth2 换的客户端证书 + 内置 CA | 不实现（ADR-0016 决定），`SUPPORT_CENTRAL_GATEWAY_CTRL=['cn']` 限定中国区 |
| 旧网关 LUMI（UDP 9898） | Zigbee 子设备（v2/v3 网关） | 网关局域网 key | 不实现（ADR-0016） |
| 多模网关 + openmiio_agent | BLE/Mesh（部分型号） | Telnet + 往网关装程序 | 不实现（ADR-0016，侵入式） |
| BLE 直连（CoreBluetooth） | 带 `blt.` 的 BLE 设备 | `blt_get_beaconkey` 返回的钥匙 + 每型号 GATT 协议 | 未实现 |

### 4.3 局域网推送能不能救 Wi-Fi 设备？能，但有硬门槛

`vanchaklar/xiaomi-lab` 有一份独立实验记录（`docs/experiments/lan-events.md`，2026-09 前后），用的是 `mijia.vacuum.v2` 固件 2.2.1：

- 探针回复 `advertises_sub=true, sub_type=1, wildcard=false`；
- 强行发 wildcard 订阅 `sub_method="."` → `result.code = -10`（被拒）；
- 该机型的事件型属性（`7/1`、`16/1`）直接 poll 返回 `-4004`，只能靠推送。

这与官方实现的门槛完全对上：**官方只在 `data[28] == 0xFE` 时订阅**（`miot_lan.py:1252-1258`），其它机型连试都不试。所以"局域网推送"不是一个开关，而是**逐机型探测出来的能力**，探测点就在 Hello 回复的 4 个字节里。

对我方含义：这条路的收益是"Wi-Fi 设备从 6 s 轮询变成事件驱动"，成本是"长连接 socket + 订阅状态机 + 去重/ACK + 只对部分机型生效"，风险是"设备固件对订阅的处理质量参差"（`-10` 就是明证）。**建议按 P1 立项，且必须做机型白名单与自动退订**。

### 4.4 Zigbee / Mesh 仍然只能靠网关

除中枢与 proxy 两条外，没有新证据。`Koenkk/zigbee-herdsman-converters`、`AlexxIT/XiaomiGateway3` 的路线（ADR-0016 已记录）依旧是"改网关运行态"，维持不做。

---

## 5. 米家场景 / 自动化的云端 API

### 5.1 读：三个列表接口，选哪个取决于你要什么

| 接口 | 返回 | 适用 |
| --- | --- | --- |
| `AppSceneService/GetSimpleSceneList`（`get_type:2`） | `manual_scene_info_list`，只有**手动场景** | 我们想要的（面板上的"一键执行"） |
| `AppSceneService/GetSceneList` | `scene_info_list`，含手动 + 自动化，带 `scene_trigger.triggers` | 需要区分"手动 / 条件触发"时 |
| `AppSceneService/GetCommonUsedSceneList` | `common_use_scene`（`scene_id / scene_name / scene_type / icon / update_time`） | **米家 App 首页"常用场景"**，最省的一条 |

一手来源：官方 SDK `MiEcosystem/miot-plugin-sdk` 的 `miot-sdk/service/sceneV2.js`（三个接口的完整 jsdoc 与参数）；`Do1e/mijia-api` 的 `apis.py:376-383`；`ALittlePandaMan/mijia-desktop` 的 `docs/HOME_SCENES.md` 记录了 `GetSceneList` 的手动判定规则：`scene_trigger.triggers` 里存在 `src=user` 且 `key=user.click` 且 `enable=true`，**且 `type` 字段不能用来区分条件自动化与手动任务**。

### 5.2 写：`NewRunScene`

```json
{"scene_id": "...", "scene_type": 2, "phone_id": "null",
 "home_id": "<num>", "owner_uid": <owner>}
```

（`Do1e/mijia-api/apis.py:517-537`；`mijia-desktop` 补了固定 `trigger_key=user.click`。）

`scene_type=2` 是手动场景；`phone_id: "null"` 是字符串字面量，不是 null。

### 5.3 语义与安全（来自 al-one PR #2904 的评审结论）

PR #2904（2026-07-29 开，未合并）把场景做成 HA 按钮，正文与评论里有几条**可以直接抄的语义约定**：

- **成功判据必须是 `code == 0`**，不能套用 MIoT 那套"`1` = 已受理未完成"的约定（评论 `2026-09-22`）。
- **同名场景**要有确定性的去重后缀；unique_id 用 `home_id-scene_id`。
- **并发按同一场景拒绝**；**执行结果未知时绝不自动重放**；**云端 ACK ≠ 每个设备都执行完成**。
- 读多家庭时**最多 3 个并发**，单个家庭失败保留其元数据、成功的空列表则移除按钮但不删注册表。
- 刷新节奏：启动读缓存 → 后台 10 分钟刷新 + 云连接恢复时刷新。
- 明确说明**不需要新登录**：用现有米家云会话即可（正文第一段）。
- 本地执行通道的边界：中枢有 `proxy/getMijiaActionGroupList` / `proxy/execMijiaActionGroup`，但**云手动场景 ID 是否等于网关动作组 ID 未验证**，所以 PR 只做云。

### 5.4 对我们

我们现在 `HomeScene` 只来自 HA（`HomeStore+Capabilities.swift:1332`、`1876-1880`），米家直连用户面板里没有场景。接云场景是**纯增量**：多一次列表读、多一个执行写接口，不动现有设备模型。但它同时是**批量写**（一个场景可能开十台设备、包括门锁），必须复用现有的写入门与二次确认。

---

## 6. 对照我们：差距表

现状列的行号均指本仓库 HEAD。

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `MiCloudProvider.swift:1082` `fetchPropsHybrid` | LAN 优先读，失败/缺键回落云 | 官方读云优先、写本地优先，理由：直连批量读会让设备异常（`miot_client.py:738-744`） | 不改主序，但给"本地读连续异常"的设备单独降级为云读（与写路径解耦） | M |
| `MiCloudProvider.swift:1689` `pollKeys` | 只轮询 `isOnline` 的设备 | 官方三源 OR（`miot_client.py:1345`）；al-one 云失败时用 `miIO.info` 探活（`device.py:1068-1076`） | 云端离线但 LAN 准入的 IP 设备，每 N 轮做一次 `miIO.info` 探活；通了就按在线处理 | M |
| `LocalMiIOClient.swift`（全文） | 一问一答式 UDP，握手 TTL 120 s，无入站推送 | 官方 `miIO.sub` + `MSUB/PUB`/wildcard 探测（`miot_lan.py:1240-1262`） | 新增推送通道：常驻 socket + 订阅状态机 + ACK + 5 s 去重；只对 wildcard=0xFE 的机型启用 | L |
| `MiCloudProvider.swift:176-177` | LAN 连续 3 次失败 → 冷却 30 s | 官方 3 次 5 s 快 ping 判死 + 10 次/120 s 抖动则延迟 300 s 上线（`miot_lan.py:357-430`） | 冷却期已够；补"抖动设备"抑制，避免卡片反复上下线 | S |
| `MiCloudProvider.swift:516-521` | 429 退避 60 s→900 s | 官方/其他实现未见更细的分级 | 保持；可把 429 与 -30012 类瞬时错误分开退避 | S |
| `MiCloudClient.swift:222` `propChunkSize = 100` | 云读 100 条/请求 | 官方 150（`miot_cloud.py:245`）、al-one 不分片 | 改动收益小；更值得做的是"每设备每周期一次"的约束 | S |
| `MiCloudClient.swift:796-806`、`windows/.../client.ts:677` | `miotspec/prop/get` 不带 `datasource` | 官方 `datasource:1`（`miot_cloud.py:744`）、Do1e 同（`apis.py:633`） | 真机 A/B 一次，看时延与返回码是否变化 | S |
| `MiotSynthesizer.swift:711-725` | 滤芯寿命从 spec 的 `filter-life-level` 推导 | 独立耗材接口 `v2/home/standard_consumable_items`（`apis.py:385`） | 加一条可选数据源，覆盖 spec 里没写耗材的型号 | S/M |
| `MiCloudClient.swift:7-38` `MiDeviceRecord` | 没有 `parent_id` / `pid` | python-miio 建模 `parent_id`+`parent_model`（`cloud.py:44-64`） | 加两个可选字段（decode 兼容），先用于"经由网关"标注 | S |
| `MiIOCryptoAndPacket.swift:15,42` | 非数字 did 直接拒绝 | al-one 用父网关 socket + 子 did 参数（`device.py:1684-1702`） | 只读 spike：对 `pid==18` 的父网关做 `get_properties(子did)`，验证是否回值 | M |
| `MiCloud`（无场景） | 米家用户没有场景入口 | `GetSimpleSceneList` + `NewRunScene`（§5） | 接云场景列表 + 执行，走写入门与二次确认 | M |
| `MiCloud`（无事件） | 猫眼/门铃事件只能靠 HA | `user/get_user_device_data` 的 `type=event`（`xiaomi_cloud.py:163`） | 真机探测事件键，再决定是否做轮询式事件 | M |
| `windows/src/core/miCloud/client.ts` | 无 LAN miIO（ADR-0021 明确） | 官方/统一实现 | 维持现状；若做推送只做 macOS 先行 | — |
| `DeviceTransportDiagnostics.swift:64-111` | 已有 LAN/云/冷却/权限拒绝的分布与 RTT 分位 | al-one 只有 `system_health` 的四个计数 | 我们已领先；补"每设备的失败原因码"即可 | S |
| 日志（`MiCloudProvider` 各处 `logger.notice/error`） | 重复错误每次轮询都打 | al-one 按状态迁移升降级（`device.py:1036-1053`） | 引入"同一设备同一错误只记首末次"的小工具 | S |

---

## 7. 推进清单

优先级口径：P0 = 低成本高价值或修正明显缺陷；P1 = 值得做的结构改进；P2 = 有价值可等；P3 = 远期/探索。

| # | 标题 | 价值 | 成本 | 优先级 | 高风险面 | 依据 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 离线设备的 LAN 探活（在线判定补第二源） | 云端 `isOnline` 抖动时不再永久灰卡；对断网但仍通电的设备可用 | S/M | **P0** | 是（在线态影响写入门与锁屏拦截） | `miot_client.py:1345`、`device.py:1068-1076` |
| 2 | `datasource:1` 真机 A/B | 可能降低云读时延或改变语义，一次实验就能定论 | S | **P0** | 否（只读） | `miot_cloud.py:744`、`apis.py:633` |
| 3 | `MiDeviceRecord` 补 `parent_id` / `pid` | 为"经由网关"标注、proxy spike、BLE 识别打地基 | S | **P0** | 否 | `cloud.py:44-64`、`client.ts:283-290` |
| 4 | 修正 ADR-0016 的审计范围（不等 spike 结果） | 避免 ADR 与生态事实冲突，后续决策有正确前提 | S | **P0** | 否 | `device.py:1684-1702`、#2512 |
| 5 | 云场景（列表 + 执行） | 米家直连用户第一次拥有"一键场景" | M | **P1** | 是（批量写入，可能含门锁） | §5；PR #2904 的语义约定 |
| 6 | 局域网推送（`miIO.sub`） | Wi-Fi 设备从 6 s 轮询变事件驱动；事件型属性（地图、清洁记录）变得可读 | L | **P1** | 是（网络传输面 + 新增长连接） | `miot_lan.py:262-286`、`1240-1262`；`xiaomi-lab` 的 `-10` 反例 |
| 7 | 网关 proxy 子设备只读 spike | 验证 ADR-0016 的"不存在"是否要改写；VRF 内机类设备可能本地可控 | M | **P1** | 是（同一 UDP 端口的读取能力） | `device.py:216-223`、issue #2512 |
| 8 | 读路径按设备分源（本地读不可靠 → 云读） | 兼顾云限流与本地时延；避免"某型号被读爆" | M | **P2** | 是（影响所有读） | `miot_client.py:738-744`、issue #1862 |
| 9 | 耗材接口 | 滤芯/耗材到期提醒覆盖到 spec 未声明的型号 | S/M | **P2** | 否（只读） | `apis.py:385-397` |
| 10 | 云事件轮询（`type=event`） | 猫眼/门铃在纯云模式可用 | M | **P2** | 否（只读，需真机验证键名） | `xiaomi_cloud.py:163-186` |
| 11 | 日志降噪（同错误首末次） | 诊断包可读性 | S | **P2** | 否 | `device.py:1036-1053` |
| 12 | BLE 直连（beaconkey + CoreBluetooth） | 少数 BLE 传感器脱离网关 | L | **P3** | 是（新传输栈） | `xiaomi_cloud.py:552`、`mijia-homie` |
| 13 | 中枢 mDNS + action group 本地执行 | 场景的毫秒级本地执行 | L | **P3** | 是 | `miot_mdns.py:110-127`、`miot_mips.py:1415-1445` |

**建议的落地顺序**：第一批 #1~#4（全是读侧小改 + 一条 ADR 修正，可在一个 PR 内分层提交）→ #5（独立 PR + ADR 补条）→ #6 单独立项（要 ADR 补充"常驻 UDP 监听"这一新边界）→ #7 只读 spike 单独一票（结论出来再定 ADR-0016 的最终措辞）。

---

## 8. 设想（天马行空，与现有 ADR 的冲突已标注）

1. **把"能不能本地"做成一份共享数据表，双端各写薄解释器。** 官方用 `profile_models.yaml`（823 个不可本地），al-one 用 `MIOT_LOCAL_MODELS`（1,139 个可本地）。我们可以只做"本地推送能力表"（wildcard 0xFE 的机型 + 实测过的 sub_type），字段 `{model, wildcard, sub_type, observed_at}`，由诊断上报回填。**与 ADR-0011 的 `deviceProfiles.json` 方向一致**，不冲突。
2. **"推送优先、轮询兜底"的双层状态机**：有推送的机型只保留 60 s 心跳式 `get_properties`（防丢包），无推送的沿用 6 s。收益是云请求量下降一个数量级；风险是推送丢包后状态陈旧，需要"最后更新时间"透出到卡片。**与 ADR-0021 不冲突，但需要新 ADR 记录长连接边界。**
3. **场景 = 云 ID + 本地 action group ID 的双身份**。若未来验证"云场景 ID == 网关动作组 ID"，可以做到"有中枢时走本地、没有时走云"，同一按钮两条腿。**与 ADR-0016 冲突**（要碰中枢证书），需先满足其重开条件。
4. **把 `miot-spec.org` 的公开 instance 端点做第三路 spec 兜底**（`https://miot-spec.org/miot-spec-v2/instance?type=<urn>`，无需鉴权，`MiService/miioservice.py:191-195`）。我们已有 `fallbackSpecs.json`，但那是"手写兜底"；公开库是"官方兜底"，覆盖 16,372 个 released 实例。**与 ADR-0015 的隐私边界不冲突**（只发 URN，不含设备信息）。
5. **设备健康面板**：把已有的 `DeviceTransportDiagnostics` 从"日志/诊断包"提升为可视面板——每设备的 LAN RTT 分位、失败原因码、父设备、`pid`、`RSSI`（云端列表里有 `rssi`，官方解析进 `device_infos` 但后续未见使用，`miot_cloud.py:617-619`）。用户能自己看出"这个插座为什么老掉线"。**不冲突。**
6. **反向利用 `pid == 21` 的 mesh 灯组**：米家把灯组建成 `parent_id` 出现在 did 里的虚拟设备，我们目前只处理 `group.` 前缀。若能拿到 `pid`，可以把"灯组"与"多键面板子键"分开建模，减少合成器里的特例。**与 ADR-0011 不冲突。**

---

## 9. 来源清单

**读过源码（本地浅克隆，commit 见文首表）**

- [XiaoMi/ha_xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home/blob/75b3acb/custom_components/xiaomi_home/miot/miot_mips.py)：`miot_mips.py:90-160`（TLV 信封）、`221-226`（QoS/重连/订阅批量）、`514-528`、`614-636`、`723-756`、`842-849`、`855-875`、`946`、`1000-1030`、`1108-1118`、`1128-1131`、`1281-1297`、`1415-1445`、`1653-1674`
- 同上：`miot_client.py:82-86`、`541-641`、`643-716`、`718-774`、`825-906`、`960-1034`、`1228-1360`、`1656-1838`
- 同上：`miot_lan.py:131-145`、`262-330`、`357-430`、`438-530`、`930-950`、`1086-1100`、`1213-1375`
- 同上：`miot_cloud.py:71`、`102-105`、`200`、`244-245`、`561-575`、`718-730`、`744`、`762-841`
- 同上：`miot_mdns.py:73`、`110-127`；`const.py:61-115`；`config_flow.py:1776-1840`；`translations/en.json`（LAN 配置说明）
- [al-one/hass-xiaomi-miot](https://github.com/al-one/hass-xiaomi-miot/blob/8ac4df7/custom_components/xiaomi_miot/core/device.py)：`core/device.py:202`、`216-223`、`232-264`、`617-680`、`749-766`、`874-909`、`939-1100`、`1664`、`1684-1702`；`core/xiaomi_cloud.py:163-186`、`325-334`、`552-566`、`1110-1170`；`core/mini_miio.py:20-100`、`179-190`、`300-345`；`core/miot_local_devices.py`；`core/miot_spec.py:185-204`；`device_customizes.py`；`config_flow.py:255-265`；`system_health.py:14-40`
- [merdok/homebridge-miot](https://github.com/merdok/homebridge-miot/blob/d27d98f/lib/protocol/MiotDevice.js)：`lib/protocol/MiotDevice.js:28-30`、`96-103`、`215-222`、`242-250`、`319-348`；`lib/protocol/MiioProtocol.js:4-10`、`332-440`；`lib/protocol/MiCloud.js:14-17`；`lib/constants/Constants.js:2`
- [Do1e/mijia-api](https://github.com/Do1e/mijia-api/blob/2cc61f2/mijiaAPI/apis.py)：`apis.py:30-31`、`376-397`、`399-403`、`487-537`、`576-637`、`633`、`782-830`
- [rytilahti/python-miio](https://github.com/rytilahti/python-miio/blob/9a00e08/miio/cloud.py)：`miio/cloud.py:44-64`、`88-140`；`miio/device.py:231-252`；`miio/integrations/genericmiot/meta.py`
- [Yonsm/MiService](https://github.com/Yonsm/MiService/blob/a1727f7/miservice/miiolocal.py)：`miservice/miiolocal.py:1-110`；`miservice/miioservice.py:66-68`、`191-195`
- [PiotrMachowski/Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor/blob/c4db715/token_extractor.py)：`token_extractor.py:103-129`、`857-888`
- [alsuren/mijia-homie](https://github.com/alsuren/mijia-homie/blob/04204e5/mijia/src/lib.rs)：`mijia/src/lib.rs`、`mijia/src/decode/history.rs`、`mijia/Cargo.toml`、README
- [huanyuejue/MiHome-Windows](https://github.com/huanyuejue/MiHome-Windows/blob/71e550c/app/core/service.py)：`app/core/service.py:50`、`495-585`、`677-690`；`app/core/net_guard.py:1-25`；`app/core/cache.py:12-30`；`tools/diag_poll_timing.py`
- [aholstenson/miio](https://github.com/aholstenson/miio)：`dbd66fd`（2018-05-17）确认停更

**只读 GitHub 文件**

- [ttys026/mit](https://github.com/ttys026/mit) `a5d3218`：`src/miot_lan.rs:1-56`、`604-700`；`src/mico_api.rs:29`；`src/mips_cloud.rs:14-32`
- [vanchaklar/xiaomi-lab](https://github.com/vanchaklar/xiaomi-lab) `fd4fb9e`：`docs/experiments/lan-events.md`、`ANCHOR.md`、`experiments/lan_event_listener.py`
- [MiEcosystem/miot-plugin-sdk](https://github.com/MiEcosystem/miot-plugin-sdk)：`miot-sdk/service/sceneV2.js`（`GetSceneList` / `GetCommonUsedSceneList` / `ChangeCommonUsedSceneOrder`）、`miot-sdk/service/scene.js`（`loadAllScenesV2`）
- [ALittlePandaMan/mijia-desktop](https://github.com/ALittlePandaMan/mijia-desktop)：`docs/HOME_SCENES.md`（手动场景判据、`NewRunScene` 参数、"不自动重试"语义）

**检索（issue / PR，含日期）**

- al-one #2904「Expose Xiaomi Home manual scenes as cloud buttons」，2026-07-29 开，评论至 2026-11-07：<https://github.com/al-one/hass-xiaomi-miot/pull/2904>
- al-one #2512「VRF空调内机子设备无法通过本地控制」，2025-05-18 开、2025-05-19 用户确认同网段后本地可控：<https://github.com/al-one/hass-xiaomi-miot/issues/2512>
- al-one #2043「支持 VRF 空调内机本地控制」，2024-12-08：<https://github.com/al-one/hass-xiaomi-miot/issues/2043>
- XiaoMi/ha_xiaomi_home #1586「有中枢时 Wi-Fi 设备断网后本地不再更新」，2026-01-02 开：<https://github.com/XiaoMi/ha_xiaomi_home/issues/1586>
- XiaoMi/ha_xiaomi_home #1862「retain queued properties for local refresh after cloud misses」，2026-11-18：<https://github.com/XiaoMi/ha_xiaomi_home/pull/1862>
- MIoT 公开规格库当日 released 实例：<https://miot-spec.org/miot-spec-v2/instances?status=released>（2026-11-23 复算 16,372 条）

**未查到 / 未确认**

- `pid` 6 / 15 / 16 / 17 的确切语义（只知道 al-one 把它们排除在本地控制之外）。
- `miotspec/prop/get` 的 `datasource` 字段语义（只知道官方与 Do1e 都传 `1`）。
- 云端手动场景 ID 与中枢 `action group` ID 是否同一套（al-one PR 明确标注"未验证"）。
- `GetSceneList` 到底需要 `home_id` 还是 `home_id + did`（官方 SDK 签名要 `did`，mijia-desktop 的记录只提数字 `home_id`，可能是版本差异）。
- proxy 子设备里除 VRF 内机之外的机型（BLE/Mesh 子设备）是否也走 miIO proxy。
- 我们没有中枢网关、多模网关、VRF 网关实机，第 4 节所有"能/不能"都来自上游源码与用户复现，未经本机验证。

---

**摘要**

1. 修 ADR-0016 的范围并补一条只读 spike：该 ADR 只审过 `ha_xiaomi_home` 与 `python-miio`，而 al-one 用 `pid==18` 的父网关连接读写了 proxy 子设备，VRF 内机已有用户复现（#2512）。
2. 先做三件读侧小改（成本 S）：离线设备的 LAN 探活补"在线"第二源、`MiDeviceRecord` 补 `parent_id/pid`、`datasource:1` 真机 A/B。
3. 米家手动场景是纯增量能力（`GetSimpleSceneList` + `NewRunScene`，用现有会话），但属于批量写入，必须走写入门与二次确认。
4. 局域网推送（`miIO.sub`）是真的但逐机型开放（wildcard `0xFE` 才可用），建议 P1 单独立项并配新 ADR。
5. 报告路径：`docs/research/2026-11-23-deep-dive/01-xiaomi-drivers.md`。
