# 04 国内主流智能家居厂商的接口与开源适配实现

调研日期：2026-11-23　范围：涂鸦 / 绿米 Aqara / 美的 / 海尔 / 格力 / 博联 / 易微联 eWeLink / 萤石 / 华为 HiLink·鸿蒙智联 / 小度 / 天猫精灵，以及中文社区的实际用法。
方法：按 `00-BRIEF.md` 扒三层。实际浅克隆（`--depth 1 --filter=blob:none`，只读源码、不运行任何脚本）并读了核心实现的仓库：

| 仓库 | 读到 commit | commit 日期 | 星数 |
| --- | --- | --- | --- |
| `tuya/tuya-device-sharing-sdk` | `170cfd9` | 2026-08-20 | 48 |
| `tuya/tuya-home-assistant` | `cadfa3a` | 2023-10-20（现为纯文档仓） | 973 |
| `jasonacox/tinytuya` | `b0482da` | 2026-11-12 | 1810 |
| `make-all/tuya-local` | `c7b6158` | 2026-11-23 | 3750 |
| `absent42/Aqara-LANLink` | `7ddd531` | 2026-08-20 | 31 |
| `niceboygithub/AqaraGateway` | `739a128` | 2026-11-23 | 649 |
| `omarshahine/aqara-cli` | `ee764ce` | 2026-08-31 | 4 |
| `georgezhao2010/midea_ac_lan` | `7c5231c` | 2024-01-11（pushed_at 2024-08-20） | 1830 |
| `mill1000/midea-msmart` | `1a92c14` | 2026-11-22 | 150 |
| `banto6/haier` | `6b06bf5` | 2026-11-08 | 1256 |
| `cmroche/greeclimate` | `ec124ec` | 2026-11-16 | 80 |
| `mjg59/python-broadlink` | `730853e` | 2024-04-17 | 1552 |
| `AlexxIT/SonoffLAN` | `5f376c2` | 2026-11-17 | 3355 |
| `home-assistant/core` | `b6d170e` | 2026-11-23 | — |

星数与 `pushed_at` 均取自 `gh api repos/<owner>/<repo>`（2026-11-23 查询）。HACS 默认名单取自 `hacs/default@master` 的 `integration` / `removed` / `blacklist` 三个文件（同一天抓取）。

---

## 0. 结论先行

1. **只有两家值得进「下一个接入平台」的候选名单：涂鸦与绿米。** 其余厂商要么只有单一品类（格力=空调、博联=红外遥控、美的=白电单品），要么根本没有对外通道（小度、天猫精灵、华为 HiLink 是「把 HA 设备挂进语音助手」的反向技能平台）。【源码】【检索】
2. **涂鸦的云+本地是「米家同构」的，但身份被自己人堵住。** 涂鸦「智能生活」扫码 SDK 的请求签名、AES-GCM `encdata`、token 提前 1 分钟刷新、MQTT 2 小时换票重连，几乎是我们 `MiCloudClient` 的翻版【源码 `tuya_sharing/customerapi.py:57-168`】；可它写死了 **Home Assistant 注册的 client id `HA_3y9q4ak7g4ephrvke`**【源码 `homeassistant/components/tuya/const.py:38`】——这正是 ADR-0014 否决小米路线的理由（冒用他方 client id），照抄会自相矛盾。
3. **绿米走出了一条不需要改固件的本地路（LANLink），而且协议模型和我们最像。** `Aqara-LANLink` 用 ECC 握手 + 加密 TCP 隧道拿本地推送，381 个型号的 `data.json` **由 Aqara V3 Open Cloud 规格自动生成**【源码 `docs/catalogue-and-traits.md`】——等于厂商给了我们一份「Aqara 版 MIoT spec」。它借用的是 Aqara 自家 App 的 RPC 接口，与我们现在伪装 Mi Home 的行为同一性质【源码 `MiCloudClient.swift:244-250`】。
4. **改造成本的大头不在认证和传输，在「规格 → 语义设备卡」的合成器。** 我们的 `DeviceCommand` 是语义命令（`setClimateTemperature` 等，按 `entityId`），不是 DP 直写【源码 `Models.swift:1698-1723`】；所以每接一家都要写一层 synthesizer。涂鸦最便宜（139 个标准品类 + 448 个标准 DP code，是**品类驱动**而非型号驱动【源码 `homeassistant/components/tuya/const.py:80,594`】）；Aqara 次之（381 份 `data.json` + `overrides.py` 补丁层）；MIoT 那种逐型号 spec 是最贵的。
5. **`HomeBackendDescriptor` 现在撑不住第三个源。** `HomeBackendDescriptor.activeBackends(homeBackend:hasHASource:hasMiSource:isHAEnabled:isMiEnabled:)` 把「有几个源」硬编成两个具名布尔参数【源码 `Sources/MijiaCore/HomeBackendDescriptor.swift:29-49`】，加一家就多两个参数，`HomeStore.activeBackends` 立刻膨胀——和 ADR-0020 §3 记录的 LG 电视问题同一形状。**改这张表之前，先把它参数化。**
6. **本地可控 ≠ 本地私密。** `tuya-local` README 原话：本地接入「不会阻止设备继续向涂鸦云上报状态」，本地是为了速度与可靠性，不是安全措施【源码 `make-all_tuya-local/README.md:16-21`】；且很多涂鸦设备只允许 1 个本地连接、网关类只允许 1~3 个子设备连接【源码 `README.md:10-15,143-147`】。这会和用户手机上的官方 App 抢连接。
7. **电池类设备是涂鸦本地方案的结构性缺口**：门磁、人体、水浸长期休眠、不维持局域网连接，只往云推【源码 `tinytuya/README.md:780`】。我们是「安全告警优先」的产品（ADR-0023 第 4 条要求告警信号不能被裁剪），这条缺口必须写进产品文案，不能靠本地协议兜。
8. **云侧风控是真实存在且已经咬过人的。** `SonoffLAN` 2026 年起被 eWeLink 云「封了」功率/电流/电压三个传感器通道，作者把原因写进 README 首屏【源码 `AlexxIT/SonoffLAN/README.md:7-9`】；涂鸦 OpenAPI 试用版只给 1 个月、每 6 个月才能续一次，且**跨区调用与跨区订阅被完全禁止**【文档，`tuya/tuya-home-assistant/docs/faq.md:35-55`】。
9. **社区维护度是可以量化的，而且结论打脸「星数即质量」。** 美的的老牌集成 `georgezhao2010/midea_ac_lan`（★1830）已被 HACS 从默认名单移除并**拉进黑名单**，删除理由是多轮「unmaintained」请求（`hacs/default#2504`、`#2951`，2025-01-31）【检索，见来源清单】；取而代之的 `mill1000/midea-ac-py` / `msmart-ng` 反而在默认名单里且在活跃维护。
10. **对中文用户来说，最大的「新接入」其实不是再接一家云，而是把 HA 用满。** 我们仓库里 `tuya.valve`、`aqara.blind.znjlbl01lm` 这些型号串只出现在 HA 测试夹具里【源码 `Tests/Fixtures/ha_cover_snapshot.json:10`】——说明涂鸦/绿米设备本来就已经通过 HA 进到我们的面板了。原生后端的增量价值只对「没装 HA」的那部分用户成立。

---

## 1. 先把尺子立起来：在我们的架构里「接一家」到底要付什么

不先量化这件事，后面所有排序都是空谈。

### 1.1 一个后端要在我们仓库里落地的四个面

| 面 | 具体位置 | 第 2 个源（米家）是怎么做的 |
| --- | --- | --- |
| 后端枚举 + 描述表 | `Sources/MijiaCore/HomeProvider.swift:4-15` 的 `HomeBackend`；`HomeBackendDescriptor.swift` 的 `HomeBackend.descriptor` 穷尽 `switch` | 三档：`homeAssistant` / `xiaomiCloud` / `demo` |
| 协议实现 | `HomeProvider` 12 个方法（`events` / `execute` / `refreshNow` / `retryLAN` / `setPollingContext` / `fetchSensorHistory` / 三个 `resolveCameraStream` / `stopCameraStream` / `readBack` / `shutdown`），多数有默认实现`HomeProvider.swift:109-135` | `MiAccountsProvider` + `MiCloudProvider` + `LocalMiIO` 混合 |
| 规格 → 设备卡合成器 | `Sources/MijiaCore/DeviceSynthesizer.swift`（`MiotSynthesizer` 约 970 行）+ Windows 平行实现 `windows/src/core/synthesis.ts`（约 999 行） | 按 MIoT spec 的服务/属性合成 `DeviceKind`（`Models.swift:1221-1237`，15 种） |
| 门禁与契约 | `Shared/capability-manifest.json` + `docs/capabilities.json` + `scripts/check_capability_manifest.py`（`EXPECTED_DEFAULTS` 硬编码，第 16-21 行）+ Swift/TS 两侧穷尽映射 | 已有 `xiaomi-cloud` 连接能力条目 |

增量引用的量级（本文实测）：`.homeAssistant` / `.xiaomiCloud` 字面量在 `Sources/` 出现 **444 次**（`HomeStore+Capabilities.swift` 128、`DualSourceHomeProvider.swift` 80、`HomeStore+Backend.swift` 78），Windows 侧字符串字面量 **343 次**（`connectionsAndDiagView.ts` 51、`onboardingGuide.ts` 32）。

### 1.2 真正的成本排序（按我的实测判断）

```
认证/传输  <  规格解析  <  语义合成器  <  Windows 端重写一遍（ADR-0006）
```

传输层是最便宜的一段：涂鸦 3.1–3.5、美的 8370、格力 UDP、博联 UDP 都已经有干净的参考实现，照抄协议描述即可。贵的是「这台设备该怎么显示成一张我们的卡」。MIoT 之所以贵，是因为它按型号给 spec（16,185 条 released 实例）；涂鸦和 Aqara 都给了**更粗的公共词汇表**，这是它们相对便宜的根本原因。

### 1.3 「借用身份」的三档，以及我们自己的先例

| 档 | 含义 | 我们的态度 |
| --- | --- | --- |
| A. 官方开放平台，用自己的应用身份 | 注册开发者项目拿 `client_id`/`AppKey` | 合法但通常要审核、有配额、部分要企业资质 |
| B. 借用厂商自家 App 的私有接口 | 伪装 App UA 调 `api.io.mi.com` / `aiot-rpc.aqara.cn` | **我们已经在做**：`MiCloudClient.makeUserAgent()` 生成 `APP/com.xiaomi.mihome APPV/10.5.201` 并随机化设备 id（`MiCloudClient.swift:244-250`），`sid=xiaomiio`（`MiAccountLogin.swift:106-109`） |
| C. 借用第三方开源项目注册的身份 | 用 HA 的 `client_id` 并伪装其回调 | **ADR-0014 已否决**（小米 `ha_xiaomi_home` 的 `OAUTH2_CLIENT_ID` + `homeassistant.local:8123` 回调） |

这条尺子直接决定了涂鸦和绿米的排序差异：涂鸦扫码 SDK 落在 C 档（借 HA 的身份），绿米 LANLink 落在 B 档（借 Aqara 自家 App 的身份，与我们米家一致）。

---

## 2. 涂鸦 Tuya

### 2.1 三条互不相同的路

| 路 | 身份 | 需要什么 | 形态 |
| --- | --- | --- | --- |
| 云 OpenAPI（`tuya/tuya-home-assistant` 的老路） | A 档，自建 IoT 项目 | Access ID/Secret、每个用户把自己的账号绑到你的项目下 | 云轮询/云推送 |
| 智能生活扫码（`tuya-device-sharing-sdk`，HA 官方现用） | **C 档**，写死 HA 的 client id | 用户用涂鸦/智能生活 App 扫二维码 | 云 MQTT 推送 |
| 本地（`tinytuya` / `tuya-local`） | 无（只要 `local_key`） | 每台设备的 16 字符 `local_key`（可从云拿，也可手抄） | 局域网 TCP，准实时 |

`tuya/tuya-home-assistant` 现在只剩文档：README 首屏写着「v2 集成不再由涂鸦团队维护，只提供文档」，代码在 `main` 上只剩 18 个文件，实现已并入 `home-assistant/core` 的 `tuya` 组件【源码 `tuya/tuya-home-assistant/README.md:1-30`；`git ls-files | wc -l` = 18】。

### 2.2 扫码 SDK 的实现（第二层，这是最像我们米家后端的一段）

认证链路（`tuya_sharing/user.py`）：

1. `POST https://apigw.iotbing.com/v1.0/m/life/home-assistant/qrcode/tokens?clientid=<client_id>&usercode=<user_code>&schema=<schema>` 拿二维码（`user.py:16-24`）；
2. `GET .../qrcode/tokens/<token>?...` 轮询登录结果，成功后返回 `uid`/`accessToken`/`refreshToken`/`expireTime`（`user.py:27-38`）。

请求签名（`customerapi.py:57-115`）：
- `X-appKey` / `X-requestId`(uuid) / `X-sid` / `X-time` / `X-token`；
- 业务参数与响应体都过 **AES-GCM**，密钥由 `md5(requestId + refreshToken)` 派生，再由 `_secret_generating()` 做一次 HMAC-SHA256 截断到 16 位（`customerapi.py:259-282`）；
- 签名串是「所有 header 拼 `k=v||` + 密文」再走一次 `_restful_sign`（`customerapi.py:284-300`）。

**这和米家的 `MiCloudClient` 是同一套设计语言**（随机 requestId、密钥从会话派生、参数整体加密、签名覆盖 header 与密文）。差别只在米家用 RC4 + `ssecurity`，涂鸦用 AES-GCM + `refreshToken` 派生。对我们来说这不是「学新协议」，是「换一套参数」。

推送（`tuya_sharing/mq.py`）：
- `POST /v1.0/m/life/ha/access/config`，body 是 `{"linkId": "tuya-device-sharing-sdk-python.<uuid1>"}`，返回 broker `url`/`clientId`/`username`/`password`/`expireTime`/两个 topic 模板（`mq.py:35-58`）；
- topic 后缀按设备是否支持本地分成 `/pen` 与 `/sta`（`mq.py:106-113`）——**云端自己告诉客户端「这台设备能不能本地控」**，这个设计值得抄；
- 连接寿命 2 小时，`run()` 在 `expireTime - 60` 秒主动重连换票；`rc=5`（鉴权失败）不原地重试，而是唤醒主循环重新取票；失败退避 1s→60s 指数（`mq.py:130-180`）。

这套「短票 + 主动换票 + 退避 + 不原地重连」比我们米家端的固定间隔轮询在工程上更讲究，值得单独抽成一个可复用的小状态机（见推进清单 P2）。

### 2.3 本地协议 3.1–3.5（第三层）

`tinytuya` 把协议写成了 600 多行 `PROTOCOL.md`，可以当规范读。要点：

| 版本 | 握手 | 帧 | 加密 | 完整性 | 局域网发现 |
| --- | --- | --- | --- | --- | --- |
| 3.1 | 无 | 55AA | 仅 CONTROL 走 AES-ECB | CRC32 | UDP/6666 明文广播 |
| 3.3 | 无 | 55AA | AES-ECB（静态 `local_key`）+ 15 字节版本/序号头 | CRC32 | UDP/6667，密钥是 `MD5("<固定串>")` |
| 3.4 | 3 消息协商会话密钥 | 55AA | AES-ECB（会话密钥） | HMAC-SHA256 | UDP/6667 |
| 3.5 | 3 消息协商 | **6699** | AES-GCM（每包 IV） | GCM Tag | UDP/6667 广播或 **UDP/7000 主动征询**（`{"from":"app","ip":"<my-ip>"}`，`PROTOCOL.md:545-580`） |

三个能直接指导我们实现的细节：

1. **3.5 设备可能完全不广播**，必须主动往子网广播地址的 7000 端口发一个 GCM 包，设备才单播回复（`PROTOCOL.md:574-580`）。只监听 6667 的扫描器会漏掉新固件。
2. **`local_key` 是静态的**，协商出的会话密钥只用于该连接（`PROTOCOL.md:310`）——因此「换 IP 后要重新配对」这种担心是错的，换 IP 只需重新发现。
3. **设备 22（`gwId` 22 字符）要用 `CONTROL_NEW 0x0d` 且显式带 DPS 列表**，否则 `DP_QUERY` 返回 `"data unvalid"`（`PROTOCOL.md:26-30`；`XenonDevice._decode_payload` 靠这个串判定 device22）。这是纯经验知识，文档里没有。

`tuya-local` 的上层做法（值得抄的结构）：
- **`iot_class: local_push`**，但靠「长连接 + 心跳」而不是 HA 的轮询器（`manifest.json`；`device.py:239-300` 的 `async_receive` 循环把增量 poll 合并进 `_cached_state`，`should_poll` 只在还没拿到过状态、或 `poll_only` 时才为真，`device.py:317-318`）；
- **`persist` 标记**：全量 poll 时，不在本次 poll 里的非持久 DP 会被清空（`device.py:288-296`）——否则关机后残留的「开」状态会一直显示；
- 错误码 914 会附一句人话提示「上次能跑现在不行，大概率要把设备断电重启」（`device.py:40-42`）。

### 2.4 设备模型：品类 + DP code，比 MIoT 便宜得多

- 设备天然带 `category`（139 个标准品类，`homeassistant/components/tuya/const.py:80` 起）+ `product_id` + `status/function/status_range`（`tuya_sharing/device.py:74-95`）；
- DP 是扁平的 `code → value`，标准 DP code 有 448 个（`homeassistant/components/tuya/const.py:594` 起 `class DPCode`）；
- 云端额外给 `dpStatusRelationDTOS`，含 `supportLocal` 与 `dpId ↔ statusCode` 映射（`tuya_sharing/device.py:155-170`）——**DP 号在不同产品上含义不同，必须靠这张表翻译成标准 code**；
- `tuya-local` 用**声明式 YAML** 兜住非标产品：1790 个 YAML、2087 个 product id（实测 `grep -c "^  - id:"`），每份只写 `products[].id` + `entities[].dps[].mapping`（例：`devices/9in1_airquality_monitor.yaml` 把 6 个空气指标 + 电池 + 告警拆成独立实体，用 `mapping: [{scale: 1, step: 1}]` 处理 HCHO 的倍数）。

对我们的含义：**涂鸦可以做成「一张 139 行的品类 → DeviceKind 表 + 一份 DP code 归一化表」**，不需要像 MIoT 那样逐型号合成。这是所有候选里最省合成器成本的一家。

### 2.5 限流与风控（有实证，不是猜）

| 事实 | 证据 |
| --- | --- |
| OpenAPI 试用版 1 个月，每 6 个月可续一次，且对 API 调用配额有限制 | 【文档】`tuya/tuya-home-assistant/docs/faq.md:35-51` |
| **跨区调用与跨区订阅被完全禁止**（用美国 IP 访问中国数据中心即违规） | 【文档】同上 `:55` |
| 本地接入不阻止设备继续上云；很多设备只允许 1 个本地连接 | 【源码】`make-all/tuya-local/README.md:10-21` |
| 网关型设备通常只支持 1 或 3 个子设备连接 | 【源码】`README.md:143-147` |
| 电池类设备休眠，不维持局域网连接，只往云推 | 【源码】`tinytuya/README.md:780` |
| 未查到涂鸦对「智能生活扫码 SDK」明文的 QPS 配额 | 【未查到】：`developer.tuya.com` 文档站为 JS 渲染，静态抓取拿不到正文；SDK 侧也没有任何退避/限流代码（`customerapi.py` 全文无 429 处理） |

### 2.6 身份问题：不能照抄 `HA_3y9q4ak7g4ephrvke`

```
git grep 的结果（HA core 与 tuya-local 完全一致）：
homeassistant/components/tuya/const.py:38  TUYA_CLIENT_ID = "HA_3y9q4ak7g4ephrvke"
homeassistant/components/tuya/const.py:39  TUYA_SCHEMA = "haauthorize"
make-all/tuya-local/custom_components/tuya_local/const.py:22  同一个常量
```

这是 Home Assistant 在涂鸦侧注册的应用身份。我们若直接引用：

- **和 ADR-0014 的否决理由正面冲突**（「多个桌面端共用官方集成的 `client_id` 属于未授权冒用」），
- 且真实存在连带风险：同一 `client_id` 的终端数暴涨时，涂鸦侧限流/封禁会同时打死用户自己的 HA 集成——ADR-0014 已经把这个后果写清楚了。

合法替代只有「A 档自建 IoT 项目」，但那要用户自己去 `iot.tuya.com` 建项目、绑设备、每 6 个月续期，对菜单栏用户是灾难级 UX。

### 2.7 涂鸦小结

- **覆盖**：国内白牌与二线品牌大量用涂鸦模组，是唯一能一次性吃下「一堆杂牌设备」的通道。【推断，依据是涂鸦模组的商业模式与 `tuya-local` 2087 个 product id 的广度】
- **技术可行性**：高。云（同构于米家）+ 本地（3 份成熟实现）都通。
- **致命点**：扫码路线的身份不属于我们；自建项目路线 UX 不可接受。
- **可行的第三条**：只做**本地**（用户自己提供 `local_key`），完全绕开涂鸦云与身份问题。代价是每设备手工输入 16 字符密钥——但可以配「扫码/粘贴云端导出」两条辅助路径，把云端只当「密钥搬运工」，且明确告知用户这是手工配置。（见推进清单 T3）

---

## 3. 绿米 Aqara

### 3.1 三个入口，差别巨大

| 入口 | 认证 | 传输 | 可用性 |
| --- | --- | --- | --- |
| Aqara Open Cloud v3 | 自建项目 `AppId/KeyId/AppKey` → OAuth `authCode` → `AccessToken` + `refreshToken` | HTTPS `intent`-RPC | 需在 `developer.aqara.com` 建项目、选区域、配 Redirect URI，且要「接入云云对接平台」【源码 `aqara-cli/README.md:44-60`；`src/aqara_cli/api.py:110-190`】 |
| LANLink（第三方逆向） | Aqara App 账号密码换 `user_id`+`token`，或直接粘贴 token | 局域网加密 TCP 隧道 | 可用，beta，需在 Aqara App 里打开「局域网控制」【源码 `Aqara-LANLink/docs/architecture.md:13,35,80`】 |
| telnet + 改固件（`AqaraGateway`） | 米家 token + telnet 密码 | 网关上的 `psm` 服务 + 内置 MQTT | **不可用于我们的产品**：README 首屏要求「改机固件或已开 telnet」，厂商还在持续封堵【源码 `niceboygithub/AqaraGateway/README.md:6-20`】 |

### 3.2 LANLink：本报告里质量最高的第三方实现

它解决的问题和我们的米家后端一模一样：**云端登录拿会话 → 局域网长连接拿状态**。关键机制（`docs/architecture.md`）：

1. **配置流**：mDNS 发现中枢 → 账号密码（或粘贴 `user_id`+`token`）→ 云登录换票 → 对中枢做一次 10 秒预算的 LANLink checkin 验证 → 只保存 token，**登录后立刻丢弃密码**（`:23-40`）。
2. **隧道**：`EncryptedTunnel` = ECC 密钥交换 + 对称隧道，随后 checkin 用 `user_id`/`token` 认证（`:49-52`）。
3. **推送订阅是「每次连接一次性」的**：断线重连、拓扑增长后都必须重新订阅，且订阅响应顺带把当前值带回来做**初始填充**（`:64`）——这解决了「连上了但界面空白等下一条推送」的经典问题。
4. **保活与看门狗**：心跳回执约 10 秒一次；中枢已连、拓扑非空、但 300 秒没有任何 trait 上报 → 重新订阅；连续 3 次失败升级为 HA Repair「push_stalled」，并提示用户检查「局域网控制」开关（`:80`）。
5. **拓扑推送**是独立帧，列出所有可达子设备 DID（`:66-70`）——中枢自己告诉我们「现在有哪些子设备在线」，不需要我们轮询设备表。
6. **独立 Wi-Fi 设备（如 FP2）需要「激活」**：向设备 `:443` 发一帧 LANLink 握手，中枢才会把它纳入中继集群；激活不耐重启，所以有 `RearmManager` 做缺席去抖 + 冷却 + 周期扫描（`:72-78`）。这段是纯粹的踩坑积累，也说明这条路并不「干净」。

设备模型（`docs/catalogue-and-traits.md`）：
- 每个型号一个包 `device/models/<model>/`，含 `data.json`（**由 Aqara V3 Open Cloud 规格自动生成**）、`overrides.py`（人工修正层，`OVERRIDES` 键是 wire path，值 `None` 表示删除）、`__init__.py`（三行 shim）；
- 实测 **381 个型号目录**；
- 丢弃策略 `DROPPED_PATHS`：把 `ZigbeeNetworkDiagnostics`、`BasicInformation.Mac` 这类管理噪音静默消费掉、不生成实体（`architecture.md:170-174`）；
- 摄像机：RTSP 经 go2rtc、门铃响铃事件、双向对讲走 go2rtc backchannel（`README.md:20-28`）——**和我们的 go2rtc 摄像头桥、`DoorbellRing.swift` 完全对得上**。

云侧身份（`hub/cloud_client.py`）：`aiot-rpc.aqara.cn` / `rpc-ger.aqara.com` / `aiot-rpc-usa.aqara.com` …，并且：

```python
#: Client headers aligned with a captured Android-app request, so our
#: traffic looks like the real app's.
_CLIENT_HEADERS = {"User-Agent": "okhttp/4.12.0", "App-Version": "6.1.6",
                   "Sys-Type": "1", "Phone-Model": "Home Assistant##Server"}
```

也就是说：**它伪装成 Aqara 安卓 App**（`cloud_client.py:319-330`）。这和我们的 `APP/com.xiaomi.mihome` 是同一档风险，不构成新增风险类别；但注意它把 `Phone-Model` 写成了 `Home Assistant##Server`——我们若借鉴，必须换成自己的标识，否则又是一次「借身份」。

### 3.3 Open Cloud v3 的协议形状（如果走 A 档）

- 端点按区域：`open-cn.aqara.com` / `open-usa` / `open-ger` / `open-kr` / `open-ru`（`aqara-cli/src/aqara_cli/api.py:46-52`）；
- 统一 `POST /v3.0/open/api`，body 是 `{"intent": "...", "data": {...}}`；
- 签名：`md5("Accesstoken=..&Appid=..&Keyid=..&Nonce=..&Time=.." + appKey)`（`api.py:118-131`），header 带 `Appid/Keyid/Time/Nonce/Sign/Accesstoken`；
- 刷新：`intent = config.auth.refreshToken`，过期码 `{108,109,110,111}`（`api.py:54-60, 200+`）；
- 不少 `intent` 有坑（`dids` vs `did`、`config.position.delete` 只吃单数 `positionId`、某些字段 403），`aqara-cli` README 专门列了这份「踩坑地图」【源码 `README.md:6-10`】。

要点：**Aqara 官方开放平台是「有正式规格的」，但门槛是项目审核 + OAuth 回调注册**，和涂鸦 A 档同类问题、但至少不需要用户自己续期。

### 3.4 Aqara 小结

- **覆盖**：国内中高端、精装房配套多，传感器/开关/门锁品类齐全；单品类密度不如涂鸦的白牌广度，但客单价与稳定性更好。【推断】
- **技术可行性**：最高的一家——LANLink 把「登录/规格/本地推送/摄像机/门铃」全都验证过了，且规格来源是官方 V3 云。
- **风险**：① 逆向协议，官方随时改（README 明写）；② 需要用户在 App 里打开「局域网控制」，否则只能云；③ beta，单人维护（★31）；④ 我们若直接照搬其云调用，等于二次冒用它的伪装头。
- **相对涂鸦的关键优势**：身份落在 B 档（厂商自家 App），不撞 ADR-0014。

---

## 4. 美的 Midea

### 4.1 协议与认证

- **V3 设备需要一次云换 token/key，之后纯本地**。`msmart-ng` README 讲得最清楚：「对更新的 V3 设备，美的云只用来获取 token & key；拿到并存下后不再需要云；设备不绑定本库内置账号，用户可自带账号」【源码 `mill1000/midea-msmart/README.md`「Note On Cloud Usage」段】。
- 云端有 5 套 App 身份（`美居 900` / `MSmartHome 1010` / `Midea Air 1117` / `NetHome Plus 1017` / `Ariston Clima 1005`），每套 `app_id`/`app_key`/`login_key`/`iot_key`/`hmac_key` 都在源码里（`georgezhao2010/midea_ac_lan/custom_components/midea_ac_lan/midea/core/cloud.py:13-49`）。
- 还有一组**内置 default key**（`app_id: 99`，`cloud.py:51-56`），意味着部分设备连云都不用。
- 本地：UDP 广播 `6445` 与 `20086`，`5a5a` 帧（`core/discover.py:13-60`）；TCP `8370` 长连接、10 秒心跳（`core/device.py:79,123-160`）。
- 设备模型：按 `appliance type`（`AC`/`B0`/`CA`/`C3`…）分插件类，每类一个 `doc/<TYPE>.md` 列出属性表（README 的表格，实测 20+ 类型）。

### 4.2 维护度的现实

| 事实 | 证据 |
| --- | --- |
| `georgezhao2010/midea_ac_lan`（★1830）**在 HACS 黑名单里** | `hacs/default@master:blacklist` 含该仓库名【检索 2026-11-23】 |
| 删除理由：长期无人维护，多次移除请求被搁置 | `hacs/default#2504`、`#2951`（2025-01-31 closed）【检索】 |
| fork `wuwentao/midea_ac_lan` 也被两次请求移除 | `hacs/integration#4646`、`#4702`【检索】 |
| 现役方案是 `mill1000/midea-ac-py` + `msmart-ng`，**在 HACS 默认名单内**、2026-11 仍活跃 | `hacs/default@master:integration` 含 `mill1000/midea-ac-py`；`msmart-ng` commit `1a92c14` 2026-11-22【源码/检索】 |

这条对我们意义很大：**「星数最高」的那家已经死了，且是被社区主动除名**。选型时看 HACS 默认名单比看星数可靠。

### 4.3 美的小结

- 覆盖：仅空调/白电单品（AC 类最成熟），不能承担「整屋」。
- 成本：中低（一次性云换 key + 8370 本地 + 按 appliance type 的属性表）。
- 风险：低（无持续云依赖）；但**品类窄 + 老库已死**，只适合作为「空调专项增强」而不是「下一个平台」。

---

## 5. 海尔 Haier（含一处需要纠正的前提）

### 5.1 先纠错：U+ 没有可用开源，`banto6/haier` 走的不是 U+

任务里写「U+ 平台相关开源（如 banto6/haier 等）」。实测结论相反：

- `banto6/haier` 打的是**海尔智家云**：`zj.haier.net/api-gw/oauthserver/account/v1/login`（账号密码）与 `/refresh`，业务走 `uws.haier.net`（`custom_components/haier/core/client.py` 全文的 URL 集合）；
- 设备属性规格来自 `GET https://uws.haier.net/shadow/v1/devdigitalmodels`（`client.py:39`）——即海尔自己的「数字模型」，是它们的 spec 体系；
- 推送是 **WebSocket**：`client.py:315` 把 `agAddr` 的 `http://` 换成 `wss://`，`core/device_gateway.py:79-92` 起心跳（`_start_heartbeat_sender`）并挂 HA 事件总线，`:271` 的注释写明「通过 websocket 发送控制命令」；
- 集成的 `iot_class` 是 **`cloud_polling`**（`manifest.json`），`integration_type: hub`——注意它其实有 WS 推送，但元数据登记为轮询，说明通道并不稳定到敢自称 push。

**U+ 平台没有可用的第三方开源实现**【检索：以 `hilink`、`harmonyos connect`、`U+` 为关键词的仓库搜索结果里，Home Assistant 相关最高星不足 10，且多为桥接实验】。这条要写进报告，避免后续再按「U+ 有开源」立项。

### 5.2 hOn 是另一条线，而且已经停更

- `Andre0512/pyhOn`（★501，最后 push 2024-08-14）与 `Andre0512/hon`（★1536，2024-08-15）面向 **Haier / Candy / Hoover 欧洲品牌线**的 hOn App，不是国内「海尔智家」；两者都不在 HACS 默认名单【检索 2026-11-23】。
- 因此「海尔」在国内语境下只剩海尔智家云一条路：**账号密码 + 云 WebSocket，无局域网直连**。

### 5.3 海尔小结

覆盖高（白电三巨头之一）、但**只能云**、无本地、无官方开放平台、维护靠单人（★1256 但 issues 仅 9 个，说明使用面或讨论面窄）。适合 P3。

---

## 6. 格力 / 博联 / 易微联

### 6.1 格力 Gree：最干净的局域网，但只有空调

- HA 官方集成 `gree`，`iot_class: local_polling`，依赖 `greeclimate==4.3.1`，**靠 DHCP MAC 前缀自动发现**（`0447CA*`、`502CC6*`、`580D0D*`、`7CB8E6*`、`9424B8*`、`C03937*`、`F4911E*`…，`homeassistant/components/gree/manifest.json`）；
- 本地协议两个密码套件 `CipherV1` / `CipherV2`，`bind()` 先试 V1 再试 V2（`greeclimate/device.py:182-234`）；
- **无账号、无云、无 per-device 密钥**——这是所有候选里唯一「零凭据」的；
- 代价：`PLATFORMS` 只有 `climate`（同一 manifest），只覆盖空调/热泵；
- 隐患：官方在把部分型号改成纯云，社区靠**降级/打补丁固件**夺回本地（`greeclimate/README.md`「Cloud-only Gree Devices」段）。也就是说这条路对新型号会逐步失效。

### 6.2 博联 Broadlink：本地、无云、语义特殊

- HA 官方集成 `broadlink`，`local_polling`，`broadlink-async==1.3.0`，同样靠 MAC 前缀发现（`manifest.json`）；
- 认证是我们最熟悉的那种「设备自己当认证方」：`Device.auth()`（`python-broadlink/broadlink/device.py:173`）用手上的 `devtype` 与本机生成的包计数器做一次挑战应答，`update_aes()`（`:157`）在拿到设备 key 后切换 AES 会话——**没有任何云端参与**；
- 但它的核心价值是 **红外/RF 万能遥控**（码库 + 学习），不是「设备卡」。映射到我们的 `DeviceKind` 里没有对应物（`Models.swift:1221-1237` 15 种里没有 remote），只能落在 `.generic` 或新造一种。这与 ADR-0023 的 `deviceCategory` 清单要一起动。

### 6.3 易微联 eWeLink / Sonoff：唯一有公开文档 API 的一家

- **官方开发者文档**：`https://coolkit-technologies.github.io/eWeLink-API/`（HTTP 200，源码里直接引用该文档链接，`SonoffLAN/custom_components/sonoff/core/ewelink/cloud.py:2,24-36`）；
- 认证：`POST /v2/user/login`，`Authorization: Sign base64(sign(payload))` + `X-CK-Appid`，按 `countryCode` 自动定区域（`cn-apia.coolkit.cn` / `as-apia.coolkit.cc` / `us` / `eu`），区域错了会返回 `10004` 并告知正确区域（`cloud.py:331-376`）；
- 也支持**只给 token** 的登录（`login_token`，`cloud.py:378-390`），即用户可以在别处拿 token 后粘贴进来——对我们是友好路径；
- 运行模式三档 `auto / cloud / local`（`core/const.py:11`），同时支持「本地多播 + 云 WebSocket」两条状态来源；
- **风控实证**：2026 年起 eWeLink 云**封掉了功率/电流/电压三个传感器通道**，作者把原因写在 README 首屏（"These updates placed a heavy load on the eWeLink cloud. As a result, they were blocked by the cloud."，`README.md:7-9`）。

这一条是整个报告里最有价值的「反面教材」：**即使是官方文档化的云 API，厂商也可以在版本升级中单方面阉割数据通道**，而且只影响「云端读」，本地读不受影响。这直接支持我们「本地优先」的既定方向（ADR-0021）。

---

## 7. 萤石 / 华为 / 小度 / 天猫精灵：方向性错误

### 7.1 萤石 Ezviz：云轮询 + 本地 RTSP，登录还要短信码

- HA 集成 `ezviz`，`cloud_polling`，`pyezvizapi==1.0.5.0`，`dependencies: ["ffmpeg"]`（`manifest.json`）；
- 轮询周期 **30 秒**（`coordinator.py` 里 `update_interval = timedelta(seconds=30)`）；
- 视频可以走本地：云返回的 `local_ip` + `local_rtsp_port` 拼成 `rtsp://user:pass@ip:port` 交给 ffmpeg（`camera.py:43-59`）；
- 配置流要 `CONF_CODE`（短信/邮箱验证码）与 `CONF_ENCRYPTION_PASSWORD`（设备验证码）（`config_flow.py:26-48`）。

判断：30 秒轮询对菜单栏控制中心是灾难（我们的米家云轮询已经是 6/60/180 秒自适应，ADR-0014 第 1 条）；且登录带短信码，无法做「扫码即用」。**只有摄像头角度有价值**，而摄像头我们已经通过 go2rtc 覆盖，HA 用户也已覆盖。

### 7.2 华为 HiLink / 鸿蒙智联：没有对外通道

检索结果（2026-11-23，`gh api search/repositories`）：
- `chaosl1996/ha-hwhomebridge-entity-bridge` ★4（2026-10-11）
- `0xlic/ha-huawei-hilink-opple` ★0（2026-10-10），标题即「Local integration for Huawei HiLink Opple ceiling light」——单个灯具

没有可用的整屋通道。鸿蒙智联（HarmonyOS Connect）是**面向设备厂商**的接入认证体系（模组 + 认证），不是给第三方 App 拉取设备的开放平台。【检索 + 推断】

### 7.3 小度 / 天猫精灵：方向是反的

检索到的全部是「把 HA 设备挂进语音助手」，不是「从语音平台拉设备」：

- `plary/hass-dueros-smarthome` ★2（2026-06-26）：描述原文「HA设备暴露给小度语音控制 (OAuth2 + ConnectedHome)」
- `292427558/aligenieHomeAssistant` ★11（2023-06-20）：「天猫精灵 oauth2授权 连接homeassistant」
- `feversky/aligenie` ★47（2020-05-04）

这是结构性的：小度（DuerOS 技能开放平台）与天猫精灵（AliGenie 开放平台）在智能家居语境下是**语音入口 + 云云对接**，要求你作为「技能提供方」暴露设备，而不是作为「客户端」消费设备。国内厂商也不向个人开发者开放「拉取用户设备列表」的能力。【检索 + 推断】

含义：小度/天猫精灵/华为 不该出现在「下一个 HomeBackend」的候选里。若将来要做，正确形态是**反向**：我们把自己的设备暴露成 AliGenie/DuerOS 技能（对外服务，需企业资质），那是另一条产品线。

---

## 8. 中文社区实际在用什么（bbs.hassbian.com 观测）

抓取 `https://bbs.hassbian.com/forum-38-1.html`（综合讨论区首页，2026-11-23，HTTP 200，UTF-8，37 条主题）后人工归类：

| 类别 | 首页出现的热帖（标题摘录） |
| --- | --- |
| 小米/米家生态 | 「抄作业，基于 go2rtc 接入小米摄像头简洁教程」「小米风扇卡片 (Xiaomi Fan Card)」「小米温湿度2长时间不更新」 |
| 厂商自建云（每家自己一套） | 「【集成发布】松下智能家电 Panasonic Smart China 洗衣机/烘护机接入 HA」「【集成发布】鹿客智能锁 HA集成——鹿客管家APP」 |
| 摆脱厂商云 | 「【集成分享】炬为电能表（BLE直连）—摆脱涂鸦云和官方App，蓝牙代理直连HA」「【集成分享】MPPT 太阳能充电控制器 —— 摆脱点灯 App」 |
| 平台风险 | 「ThinkHome倒闭后，产品如何对接HA探讨」 |
| 自制硬件 / 电表 | CH592 燃气表、PZEM-004T、ESP32-S3 风扇控制器、BTHome 温湿度 |
| 非设备 | 国网电费卡片、和风天气、百度地图底图、music assistant |

三条可用的判断：

1. **社区的主战场是「小米 + 厂商自建云 + 自制硬件」，涂鸦只是被当作「要摆脱的云」出现的**（炬为电能表那条）。这与「涂鸦覆盖最大」的直觉有不一致之处：**涂鸦在中文 HA 社区的讨论热度明显低于它在白牌市场的份额**。【检索 + 推断】
2. **「厂商倒闭/停服」是社区公认的现实风险**（ThinkHome 帖）。这支持我们把「本地优先」当作卖点而不是技术洁癖。
3. 摄像头的社区标准答案已经是 **go2rtc**——与我们一致（`XiaomiCameraBridge.swift`）。

> 说明：论坛搜索接口需要登录，无法做关键词命中数统计；上表只基于首页可见标题，**不代表全站热度排序**。

---

## 9. 排序建议：下一个接入平台

### 9.1 打分（主观，权重明示）

权重取「用户覆盖 0.40 / 实现成本 0.25 / 稳定性 0.20 / 法律风险 0.15」（覆盖最重要；成本越高分越低；法律分越高越安全）。

| 厂商 | 覆盖 | 成本(高=便宜) | 稳定性 | 法律 | 加权 | 排序 |
| --- | --- | --- | --- | --- | --- | --- |
| 涂鸦 Tuya（本地为主 + 密钥搬运） | 5 | 4 | 4 | 3 | 4.25 | 1 |
| 绿米 Aqara（LANLink） | 4 | 3 | 3 | 4 | 3.55 | 2 |
| 格力 Gree（纯局域网） | 2 | 5 | 3 | 5 | 3.40 | 3 |
| 博联 Broadlink | 2 | 3 | 4 | 5 | 3.10 | 4※ |
| 易微联 eWeLink / Sonoff | 1 | 4 | 4 | 5 | 2.95 | 5 |
| 海尔 Haier（智家云） | 3 | 2 | 3 | 3 | 2.75 | 6 |
| 美的 Midea | 2 | 3 | 3 | 4 | 2.75 | 7 |
| 萤石 Ezviz | 2 | 2 | 3 | 3 | 2.35 | 8 |
| 华为 / 小度 / 天猫精灵 | 0 | — | — | — | — | **不做** |

※博联分数够用，但没有 `DeviceKind` 落点（红外遥控不在 15 种卡里），实际不可直接开工，见 6.2。

**分数不是结论，下面是结论。** 格力 3.40 高于博联与易微联、接近绿米，但它只覆盖空调，对我们这类「整屋控制中心」是「加一个空调卡片」而不是「多一批用户」——**加权分只能用来排除，不能用来定序**。

### 9.2 我的建议：先涂鸦（本地优先），再绿米；两者都不做云轮询

**第一顺位：涂鸦，但只做「本地 + 密钥搬运」，不做扫码云。**

理由：
1. 唯一能一次性覆盖大量白牌/二线品牌设备的通道，`tuya-local` 2087 个 product id 是这条广度的实证；
2. 合成器最便宜：139 品类 + 448 DP code，是**品类驱动**而非型号驱动；
3. 协议最全：3.1–3.5 有 600 行规范级文档（`tinytuya/PROTOCOL.md`），3.5 的 `/7000` 征询这种坑都写明了；
4. 法律风险最低的形态恰好是「不用云」：用户自己提供 `local_key`（可从涂鸦云导出、或从我们的引导页粘贴），我们完全不接触涂鸦的服务端与身份。这既避开了 `HA_3y9q4ak7g4ephrvke` 的身份问题，也避开了 1 个月试用与跨区禁令。

**第二顺位：绿米 Aqara（LANLink）。**

理由：
1. 唯一有「本地推送 + 官方规格目录 + 摄像头/门铃」的完整样本，381 型号；
2. 身份风险与我们米家后端同级（借厂商自家 App），不撞 ADR-0014；
3. 与我们的门铃、摄像头、传感器告警三条主线都能对上；
4. 但它是 beta、单人、逆向，且要求用户开「局域网控制」——所以放第二，且**必须先跟维护者建立联系或至少锁定协议版本**，不能盲抄。

**明确不做：**
- 小度 / 天猫精灵 / 华为 HiLink：方向相反，无对外通道；
- 萤石：30 秒云轮询，与我们的交互标准冲突；
- 涂鸦/绿米的**云轮询**形态：我们已经有更好的 HA 通道。

### 9.3 更省的一条路（应当先做，优先级高于任何新厂商）

**把 HA 用满**：我们仓库里的涂鸦/绿米设备已经通过 HA 进来了（`Tests/Fixtures/ha_cover_snapshot.json:10` 的 `aqara.blind.znjlbl01lm`、`ha_domain_cards.json:13` 的 `tuya.valve`）。对已装 HA 的用户，新增原生后端价值为零；对没装 HA 的用户，价值才是全部。所以正确顺序是：

1. 先量化「有多少目标用户没有 HA」（我们没有这个数据，**这是立项前必须回答的第一个问题**）；
2. 若比例低 → 不做新厂商，把预算投到 HA 侧的体验（实体覆盖、`UnsupportedDeviceScanner` 的提示质量）；
3. 若比例高 → 按上面的 涂鸦→绿米 顺序做，且一次只做一家。

---

## 10. 对照我们：差距表

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `Sources/MijiaCore/HomeBackendDescriptor.swift:29-49` | `activeBackends(homeBackend:hasHASource:hasMiSource:isHAEnabled:isMiEnabled:)`：源数量硬编码成两个具名布尔 | Aqara-LANLink 用「中枢 + 拓扑推送」表达多源；我们无对应物 | **改成由 `Set<ConnectionCapabilityID>` 驱动**，`primaryScopeIdentifier` 保留；否则第 3 家要加 2 个参数 | S |
| `Sources/MijiaCore/HomeProvider.swift:82-107` | 12 个方法，含摄像头/历史/回读；默认实现已给 | 各家都只需要子集，我们已有 protocol extension | 新后端先只实现 `events`/`execute`/`refreshNow`/`shutdown`，其余走默认 | S |
| `Sources/MijiaCore/DeviceSynthesizer.swift`（MIoT 约 970 行）+ `windows/src/core/synthesis.ts`（约 999 行） | 逐型号 spec 合成；无品类兜底层 | 涂鸦：139 品类 + 448 DP code；Aqara：381 份 `data.json` + `overrides.py`；HA 官方：`tuya-device-handlers` 包 | 引入**「品类表 + 覆盖层」**两级结构（我们已有 `Resources/fallbackSpecs.json` 这种数据表先例）；Windows 侧共用同一份数据 | L |
| `Shared/capability-manifest.json` + `docs/capabilities.json` + `scripts/check_capability_manifest.py:14-21` | 三方 + 硬编码 `EXPECTED_DEFAULTS` 必须同步 | — | 加连接能力时把这四处写进一个 checklist 脚本（现在漏一处就阻断，容易被当成噪音绕过） | S |
| `Sources/MijiaCore/MiCloud/MiCloudClient.swift:244-250` | 伪装 `APP/com.xiaomi.mihome` + 随机设备 id | Aqara-LANLink 伪装 `okhttp/4.12.0` + `Phone-Model: Home Assistant##Server` | **抽公共 UA/签名层**，且新后端不得写他家产品名（避免二次冒用） | M |
| `Sources/MijiaCore/CredentialVault.swift` | 钥匙串槽位抽象（`SlotMutation`/`Lookup`） | 各家都是「一账号一 token」 | 新后端只加一个槽 + 一个 `sourceScope` 前缀（`tuya:<uid>` / `aqara:<did>`） | S |
| ADR-0019 的 `sourceScopes` | 现有 `demo` / `ha:<url>` / 米家账号 三种 | — | 新增 `tuya:...` 前缀时同步定时/自动化的分区规则，否则定时会跨源误判 | S |
| `windows/src/core/homeProvider.ts` | 已有与 Swift 同形接口（ADR-0020 落地记录） | — | 新后端必须双端同 PR（ADR-0006），**这是成本翻倍的来源** | L |
| 状态推送 | HA=WebSocket，米家=自适应轮询（6/60/180s） | 涂鸦=云 MQTT（2h 票 + 主动换票 + 退避）；Aqara=局域网隧道 + 10s 心跳 + 300s 看门狗；美的=TCP 8370 + 10s 心跳；海尔=WSS + 心跳 | 把「短票主动换票 + 指数退避 + 不原地重连」抽成可复用小状态机（涂鸦 `mq.py:130-180` 是范本） | M |
| 设备状态「残留」处理 | 未见统一策略 | `tuya-local`：全量 poll 清掉不在本次 poll 里的非持久 DP（`device.py:288-296`） | 检查我们离线/关机后是否残留「开」状态 | S |
| 错误码人话 | `ControlFailure` 已有 | `tuya-local`：914 → 「大概率要断电重启」（`device.py:40-42`） | 给高频失败码补「下一步该干什么」 | S |

---

## 11. 推进清单

| # | 标题 | 价值 | 成本 | 优先级 | 高风险面？ | 依据 |
| --- | --- | --- | --- | --- | --- | --- |
| T1 | **先回答「目标用户里没装 HA 的比例」**：用现有遥测/issue/社区提问估一个数，再决定是否投新厂商 | 避免为一个未知比例的少数派付出双端成本 | S | **P0** | 否 | §9.3；ADR-0006 双端成本；我们仓库里涂鸦/绿米只以 HA 夹具形态出现 |
| T2 | **`activeBackends` 参数化**：把 2 个具名布尔换成源集合，保持行为不变 | 解开「加第 3 个源要加 2 个参数」的死结 | S | **P0** | 是（连接源判定影响写路由/定时作用域） | `HomeBackendDescriptor.swift:29-49`；ADR-0020 §3 的 LG 电视同类问题；ADR-0023 第 3 条 |
| T3 | **涂鸦本地后端（不含云）**：局域网 3.3–3.5 + 用户提供 `local_key` + 品类/DP 归一化表 | 一次覆盖大量白牌设备；零云依赖；不碰身份问题 | L | P1（T1 结论支持时才启动） | **是**（新凭据 + 设备控制写入）→ 走 PR | §2.3/2.4/2.6；`tinytuya/PROTOCOL.md`；`tuya-local` 2087 product id |
| T4 | **补 3.5 的主动征询发现**（若做 T3）：必须往子网广播 `7000` 发 GCM 包，只监听 6667 会漏新型号 | 直接决定「能不能发现设备」 | S | P1（随 T3） | 是（局域网探测） | `PROTOCOL.md:545-580` |
| T5 | **绿米 LANLink 后端**：先做只读（状态 + 门铃事件），确认稳定后再开写入 | 本地推送 + 381 型号 + 与我们门铃/摄像头主线吻合 | L | P2 | 是（凭据 + 隧道 + 控制） | §3.2；`Aqara-LANLink/docs/architecture.md` |
| T6 | **抽「短票换票 + 退避重连」状态机**：涂鸦 MQTT 的 `expire-60s` 主动换票 + `rc=5` 不原地重连为准 | 降低所有云后端的抖动；可复用到米家 token 续期 | M | P2 | 是（认证链路）→ 走 PR | `tuya_sharing/mq.py:130-180`；`customerapi.py:131-168` |
| T7 | **品类/DP 覆盖层数据化**：把「品类 → DeviceKind」和「DP code → 语义属性」做成共享 JSON（双端共读） | 缓解 ADR-0006「每个 bug 修两遍」；为 T3 铺路 | M | P2 | 否 | `Shared/capability-manifest.json` 与 `fallbackSpecs.json` 已是先例；`homeassistant/components/tuya/const.py:80,594` |
| T8 | **给「离线/关机残留状态」加统一清理** | 菜单栏显示错状态比不显示更糟 | S | P2 | 是（显示与控制一致性） | `tuya-local/device.py:288-296` |
| T9 | **错误码 → 下一步动作** 的文案补齐（含 `914` 类「断电重启」） | 减少「点了没反应」的支持成本 | S | P3 | 否 | `tuya-local/device.py:40-42`；我们的 `ControlFailure` |
| T10 | 美的小范围空调支持（仅当有明确用户需求） | 品类窄，增益有限 | M | P3 | 是（新凭据） | §4；HACS 黑名单事实说明选型要看维护度 |
| T11 | 博联红外（需先扩 `DeviceKind` / `capability-manifest` 的 deviceCategory） | 生态价值大但与「设备卡」模型冲突 | L | P3 | 是（跨端契约） | §6.2；`Models.swift:1221-1237` |
| — | **不做**：小度、天猫精灵、华为 HiLink、萤石，以及任何厂商的「云轮询」形态 | 方向性错误 / 体验倒退 | — | — | — | §7 |

**风险面口径**：T2/T3/T4/T5/T6/T8/T10/T11 都触碰 AGENTS.md 的五类高风险面（凭据与网络边界、设备控制写入、跨平台契约），按仓库规定必须走 PR + checks 全绿，不能直推 `main`。

---

## 12. 设想（天马行空，与现有 ADR 的关系已注明）

1. **「密钥搬运工」而不是「云后端」**：涂鸦/绿米都不做常驻云连接，只做一次性引导——用户在手机上打开官方 App，我们用剪贴板/二维码把 `local_key`、`did`、隧道 token 接过来，之后全部本地。这会让「云后端」这个概念在我们的架构里消失一半。（与 ADR-0007「局域网直连暂缓」不一致：那条是为 miIO 写的，若本方案落地需重开评估。）
2. **把 ADR-0020 的「封闭集合」推到「封闭集合 + 能力矩阵」**：不新增 `HomeBackend` 枚举值，而是让**一个通用 `VendorLANProvider`** 按「发现器 + 密钥 + 品类表」三件套参数化，涂鸦/格力/美的 共用一套 provider。代价：失去编译期穷尽检查的一部分；收益：第 4、5 家几乎零边际成本。（**与 ADR-0020 第 1 条冲突**，需新 ADR。）
3. **反向技能**：把小度/天猫精灵做成「我们暴露设备给语音助手」而不是「我们拉设备」。这需要公网回调与企业资质，几乎肯定超出本项目边界，但它是唯一让这三家产生价值的方向。（与 ADR-0023 不冲突，属新领域。）
4. **社区驱动的型号覆盖**：学 `tuya-local` 的 YAML、Aqara-LANLink 的 `overrides.py`，做一个**只读的数据覆盖包**（用户可贡献「型号 → 属性映射」，不含代码）。这在 ADR-0020/0023 的允许范围内——「进程外扩展协议 / 纯数据清单」都在允许侧，只有「进程内加载第三方代码」被否。
5. **「厂商停服」作为一个产品特性**：本地协议本身就意味着厂商倒闭后还能用（社区 ThinkHome 帖的现实痛点）。可以把「不依赖厂商云」写进产品页，并把本地覆盖率做成一个可见指标（比如卡片上标「本地」/「云端」徽标）。
6. **涂鸦的 `supportLocal` 字段可以反哺米家**：涂鸦云端明说「这台设备能不能本地控」，我们的米家后端目前靠试错判断 miIO 可用性（ADR-0021 的 LAN-first 混合）。可以在设备卡上显式区分「本地可用/仅云」，减少用户的「为什么时快时慢」困惑。

---

## 13. 来源清单

### 源码（本地浅克隆，行号以本文写作时的 commit 为准）

- `~/.cache/mbh-research-clones/tuya_tuya-device-sharing-sdk@170cfd9`
  - `tuya_sharing/user.py:16-38`（二维码申请/轮询）
  - `tuya_sharing/customerapi.py:57-115`（签名 + AES-GCM）、`:131-168`（token 刷新）、`:225-300`（nonce / 派生密钥 / 签名串）
  - `tuya_sharing/mq.py:35-58`（MQTT 配置接口）、`:106-113`（`/pen` 与 `/sta`）、`:130-180`（换票与退避）
  - `tuya_sharing/device.py:74-95`（`CustomerDevice` 字段）、`:155-170`（`dpStatusRelationDTOS`）
- `~/.cache/mbh-research-clones/tuya_tuya-home-assistant@cadfa3a`
  - `README.md:1-30`（v2 集成停止维护、Smart Life 迁移说明）
  - `docs/faq.md:35-55`（试用 1 个月 / 6 个月续期 / 跨区禁止）
- `~/.cache/mbh-research-clones/jasonacox_tinytuya@b0482da`
  - `PROTOCOL.md`（版本对照表、发现端口、3.5 征询、device22）
  - `README.md:780`（电池设备休眠）
  - `DP_Mapping.md`（DP 指令模式与 DPS 映射）
- `~/.cache/mbh-research-clones/make-all_tuya-local@c7b6158`
  - `README.md:10-21`（单连接限制、不阻止上云）、`:52-65`（云端辅助与试用期）、`:143-147`（网关子设备连接上限）
  - `custom_components/tuya_local/const.py:22-23`（复用 HA 的 client id）
  - `custom_components/tuya_local/manifest.json`（`local_push`、`tinytuya==1.21.1`）
  - `custom_components/tuya_local/device.py:40-42`（914 提示）、`:239-300`（增量合并）、`:288-296`（非持久 DP 清理）、`:317-318`（`should_poll`）
  - `custom_components/tuya_local/devices/*.yaml`（1790 份 / 2087 product id）
- `~/.cache/mbh-research-clones/Aqara-LANLink@7ddd531`
  - `README.md`（379 型号、云只在启动/重连、只存 token、非官方声明）
  - `docs/architecture.md:13`（云的三处使用）、`:23-40`（配置流）、`:49-56`（ECC 隧道与 checkin）、`:62-64`（订阅重装 + 初始填充）、`:66-76`（拓扑推送与独立 Wi-Fi 激活）、`:78-82`（心跳 10s / 看门狗 300s）、`:170-174`（`DROPPED_PATHS`）
  - `docs/catalogue-and-traits.md`（`data.json` 由 V3 Open Cloud 规格生成、`overrides.py` 语义）
  - `custom_components/aqara_lanlink/device/models/`（381 个型号目录）
  - `custom_components/aqara_lanlink/hub/cloud_client.py:106-156`（区域 RPC 端点）、`:319-330`（伪装 App 头）
- `~/.cache/mbh-research-clones/niceboygithub_AqaraGateway@739a128`
  - `README.md:6-20`（必须改固件或已开 telnet；厂商持续封堵）
- `~/.cache/mbh-research-clones/aqara-cli@ee764ce`
  - `src/aqara_cli/api.py:46-52`（区域域名）、`:110-190`（intent RPC + MD5 签名 + 刷新）
  - `README.md:6-10`（intent 踩坑地图）、`:44-60`（建项目流程）
- `~/.cache/mbh-research-clones/georgezhao2010_midea_ac_lan@7c5231c`
  - `custom_components/midea_ac_lan/midea/core/cloud.py:13-49`（五套云端身份）、`:51-56`（内置 default key）
  - `.../core/discover.py:13-60`（6445/20086 广播）
  - `.../core/device.py:79,123-160`（8370 TCP + 10s 心跳）
- `~/.cache/mbh-research-clones/mill1000_midea-msmart@1a92c14`
  - `README.md`「Note On Cloud Usage」（V3 一次性云换 token/key，之后纯本地；设备不绑定库内置账号）
- `~/.cache/mbh-research-clones/banto6_haier@6b06bf5`
  - `custom_components/haier/manifest.json`（`cloud_polling`、`hub`）
  - `.../core/client.py:39`（`devdigitalmodels`）、`:315`（`agAddr` → `wss://`）
  - `.../core/device_gateway.py:79-92,122-136,271`（心跳 / 事件 / WS 控制）
- `~/.cache/mbh-research-clones/cmroche_greeclimate@ec124ec`
  - `greeclimate/device.py:182-234`（V1→V2 尝试绑定）、`greeclimate/discovery.py`（广播发现）
  - `README.md`「Cloud-only Gree Devices」（降级/打补丁固件）
- `~/.cache/mbh-research-clones/mjg59_python-broadlink@730853e`
  - `broadlink/device.py:157`（`update_aes`）、`:173`（`auth`）、`:65-74`（广播发现）
- `~/.cache/mbh-research-clones/AlexxIT_SonoffLAN@5f376c2`
  - `README.md:7-9`（2026 起云侧封掉功率/电流/电压）、`:20-30`（本地+云同时可管）
  - `custom_components/sonoff/core/ewelink/cloud.py:24-36`（区域 + dispatch）、`:331-376`（签名登录 + 10004 换区）、`:378-390`（token 登录）
  - `custom_components/sonoff/core/const.py:11`（`auto/cloud/local`）
- `~/.cache/mbh-research-clones/home-assistant_core@b6d170e`
  - `homeassistant/components/tuya/const.py:38-39`（`TUYA_CLIENT_ID`/`TUYA_SCHEMA`）、`:80`（`DeviceCategory` 139 项）、`:594`（`DPCode` 448 项）
  - `homeassistant/components/tuya/manifest.json`（`cloud_push`、`tuya-device-sharing-sdk==0.2.15`、`tuya-device-handlers==0.0.34`）
  - `homeassistant/components/gree/manifest.json`（`local_polling`、`greeclimate==4.3.1`、DHCP MAC 前缀）
  - `homeassistant/components/broadlink/manifest.json`（`local_polling`、`broadlink-async==1.3.0`）
  - `homeassistant/components/ezviz/manifest.json`（`cloud_polling`、`pyezvizapi==1.0.5.0`）、`coordinator.py`（30 秒）、`camera.py:43-59`（本地 RTSP）、`config_flow.py:26-48`（短信码 + 加密密码）

### 我们仓库

- `Sources/MijiaCore/HomeProvider.swift:4-15`（`HomeBackend`）、`:82-135`（`HomeProvider` 与默认实现）
- `Sources/MijiaCore/HomeBackendDescriptor.swift:29-49`（`activeBackends` 两个具名布尔）、`:52-95`（三条描述 + `activeBackends` 计算属性）
- `Sources/MijiaCore/Models.swift:1221-1237`（`DeviceKind` 15 种）、`:1316-1360`（`SmartDevice`）、`:1698-1723`（`DeviceCommand` 语义命令）
- `Sources/MijiaCore/MiCloud/MiCloudClient.swift:244-250`（伪装 Mi Home UA）、`MiAccountLogin.swift:106-109`（`sid=xiaomiio`）
- `Sources/MijiaCore/CredentialVault.swift:54-79`（钥匙串槽位抽象）
- `Shared/capability-manifest.json`、`docs/capabilities.json`、`scripts/check_capability_manifest.py:14-21`
- `Tests/Fixtures/ha_cover_snapshot.json:10`（`aqara.blind.znjlbl01lm`）、`Tests/Fixtures/ha_domain_cards.json:13`（`tuya.valve`）
- ADR-0007、ADR-0014、ADR-0017、ADR-0019、ADR-0020、ADR-0021、ADR-0023

### 文档与检索（2026-11-23 全部返回 HTTP 200 后引用）

- Home Assistant 集成文档：`https://www.home-assistant.io/integrations/tuya/`、`/gree/`、`/broadlink/`、`/ezviz/`（各集成 `manifest.json` 的 `documentation` 字段声明的地址）
- eWeLink 开放 API：`https://coolkit-technologies.github.io/eWeLink-API/`（`SonoffLAN` 源码直接引用）
- Aqara 开发者平台：`https://developer.aqara.com/`（首页可访问；文档正文为 JS 渲染，未能静态抓取）
- HACS 名单：`https://raw.githubusercontent.com/hacs/default/master/{integration,removed,blacklist}`（2026-11-23 抓取；`integration` 5576 条）
- 社区观测：`https://bbs.hassbian.com/forum-38-1.html`（2026-11-23 抓取，UTF-8，37 条主题；搜索接口需登录，未做命中数统计）
- HACS 除名请求：`hacs/default#2504`、`#2951`（2025-01-31）、`hacs/integration#4646`、`#4702`（均为 closed）
- GitHub 仓库检索（★/`pushed_at` 见 §0 表格与各节）：`chaosl1996/ha-hwhomebridge-entity-bridge` ★4、`0xlic/ha-huawei-hilink-opple` ★0、`plary/hass-dueros-smarthome` ★2、`292427558/aligenieHomeAssistant` ★11、`feversky/aligenie` ★47、`Andre0512/pyhOn` ★501（2024-08-14）、`Andre0512/hon` ★1536（2024-08-15）

### 未查到 / 未能确认

- 涂鸦「智能生活扫码 SDK」的明文 QPS 配额与封禁规则（文档站 JS 渲染，SDK 无 429 处理）；
- Aqara Open Cloud 的 QPS 配额与项目审核周期（同因）；
- 中国各品牌家庭渗透率的公开可信数据——§9 的「覆盖」分是【推断】，依据是品类广度、白牌份额常识与社区观测，**不是统计数字**。

---

### 摘要

1. **只有涂鸦和绿米值得做**：涂鸦**本地优先 + 用户自带 `local_key`**（绕开 `HA_3y9q4ak7g4ephrvke` 的身份冒用与 1 个月试用/跨区禁令）收益最大、合成器最便宜（139 品类 + 448 DP code）；绿米 LANLink（381 型号、本地推送、门铃/RTSP 齐备）第二，但 beta 需谨慎。
2. **先改 `HomeBackendDescriptor.activeBackends`**：它把源数量硬编成两个布尔参数，第 3 个源会让它和 ADR-0020 §3 的 LG 电视问题一样崩；改成源集合驱动是任何新厂商的前置条件。
3. **别急着写代码**：涂鸦/绿米设备本来就已经通过 HA 进了我们的面板（测试夹具里就有 `aqara.blind.znjlbl01lm`、`tuya.valve`），先量化「没装 HA 的用户占多少」再决定投入。

报告路径：`docs/research/2026-11-23-deep-dive/04-china-vendors.md`
