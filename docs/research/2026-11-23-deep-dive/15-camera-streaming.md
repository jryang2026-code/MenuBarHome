# 15 摄像机 / 门铃 / 流媒体：多厂商接入、事件与通知链路的增量调研

调研日期：2026-11-23
范围：摄像机取流与转封装（go2rtc）、事件/快照/录像模型（Frigate）、插件化接入与 HKSV 预缓冲（Scrypted）、小米系开源实现现状（miloco / ha_xiaomi_home / hass-xiaomi-miot / MISS-CS2 逆向项目）、客户端体验（HA camera 卡与 webrtc-camera 卡、HomeKit 门铃与事件快照）。
只做增量：`docs/research/camera-ptz-compatibility.md`（2026-11-07）与 `docs/research/issue-97-camera-support.md`（2026-10-30）已经覆盖 PTZ 协议证据、MISS/CS2 与 miloco 的基本结论、HA 取流路径；本文不重复这些论证，只补新证据、纠错和"我们还没用上的东西"。

本次实际读过的仓库（浅克隆 `~/.cache/mbh-research-clones/<owner>__<repo>`，只读源码，未运行任何脚本）：

| 仓库 | 读到的版本 | 用途 |
| --- | --- | --- |
| `AlexxIT/go2rtc` | master `8eee2d4`（2026-11-23）；另按 tag `v1.9.15` 核对 `pkg/xiaomi/miss/cs2/conn.go` 原文 | source 注册表、MISS/CS2、输出格式选择、低延迟 |
| `blakeblackshear/frigate` | `8c88754`（2026-11-22） | 事件/复核/快照/录像/PTZ 自动跟随 |
| `koush/scrypted` | `3507b61`（2026-11-20） | 插件接口、预缓冲、HomeKit Secure Video |
| `home-assistant/frontend` | `9eb51a8`（2026-11-22） | camera 卡、HLS/WebRTC 选择、静帧刷新 |
| `al-one/hass-xiaomi-miot` | `8ac4df7`（2026-11-18） | 小米云侧 camera 实现现状 |
| `XiaoMi/ha_xiaomi_home` | `75b3acb`（v0.5.0，2026-09-28） | 官方集成是否已有 camera 平台 |
| `homebridge/HAP-NodeJS` | `74b1700`（2026-11-20） | HomeKit 摄像头/门铃/HKSV 的服务与特征 |
| `AlexxIT/WebRTC` | `6471e00`（2026-10-15） | webrtc-camera 卡与数字 PTZ |
| `kaivyy/micam` | `dad0965`（2026-11-19） | 2026 新项目：单会话双镜头 + NVR |
| `willjayyyy/ha-xiaomi-camera` | `73ce5fd`（2026-08-13） | 2026 新项目：miloco SDK + 桥进程 + RTSP |
| `XiaoMi/xiaomi-miloco` | 只取 `main` 的 `knowledge/03-features/live-camera-view.md`（2026-11-23）与 commits API（HEAD `b1887aea`，2026-11-18） | 官方"直播"能力边界是否变化 |
| `home-assistant/core` | `b6d170e`（2026-11-23） | 仅用于核对既有引用的路径未漂移 |

未重新阅读：`lubos-hnanicek/xiaomi-camera-viewer`（沿用 2026-11-07 的结论与行号）、`perseus177/ha-imilab-ec2` 与 `VictorCV-DAM/ha-xiaomi-imilab-camera-liberator-webrtc`（只在 GitHub 搜索摘要层面看到，标注为【检索】）。

---

## 0. 结论先行

1. **go2rtc 的"插件化"不是插件框架，是一张 scheme 注册表。** 每个 source 包在自己的 `init()` 里调 `streams.HandleFunc("xiaomi", …)`，`main.go` 用一张模块表按 `app.modules` 白名单决定谁被初始化。新增一种厂商 = 新增一个 `internal/<vendor>` 包 + 一行注册，不需要接口、动态库或配置 schema。【源码：`go2rtc:internal/streams/handlers.go:12-18`、`go2rtc:main.go:63-119`、`go2rtc:internal/app/app.go:83-89`】

2. **我们 pin 的 `v1.9.15` 就是当前最新 release（2026-10-25），但它断开 CS2 时不发 `msgClose`；master（2026-11-23，未发版）才补上，注释写明"不发 Close，摄像机会占着一个流槽位约 20 秒"。** 这正好解释我们实测的"关窗后立刻重开只出首帧、要 1 分多钟才回收"：不是摄像机顽固，是我们在挂断时没说话。给自建补丁加 5 行比 Windows 端 120 秒保温便宜得多。【源码：`go2rtc:pkg/xiaomi/miss/cs2/conn.go:195-202`（master）对比 `v1.9.15` 同文件无该方法；我们实测见 `docs/research/issue-97-camera-support.md:540`】

3. **PTZ 仍未上游化。** PR #2531 仍是 open（最后一次更新 2026-11-16），issue #2162 open（8 条评论）。我们的"自建补丁二进制 + 能力探针"路线在未来一段时间仍是唯一可交付路径，不存在"等上游合并"这个选项。【检索：GitHub API 2026-11-23；`https://github.com/AlexxIT/go2rtc/pull/2531`、`.../issues/2162`】

4. **MISS 的命令表里还有三块我们完全没用：`0x10D` 回放（SD 卡录像）、`0x106/0x108` 对讲、`0x10B` 音频格式查询。** go2rtc 已实现对讲（把 40ms 的 PCMA/Opus 分片写回摄像机），我们却把 `audio=0` 写死在取流 URL 里——**"没有音频/不能对讲"是产品选择，不是协议限制**。【源码：`go2rtc:pkg/xiaomi/miss/client.go:84-103`、`:205-240`、`go2rtc:pkg/xiaomi/miss/backchannel.go:1-74`；我们的 `Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift:1325-1355`（`audio=0`）】

5. **低延迟的实质是两条：不转码、丢帧不排队。** go2rtc 只做转封装（把摄像机码流拆成 RTP/fMP4 包），没有消费者时自动停源；我们 macOS 播放器在 `AVSampleBufferDisplayLayer` 背压时 `flush()` 并等到下一个关键帧，方向是对的；Windows 端却把每帧丢给 ffmpeg 转 JPEG、再用 45ms 间隔拉取（≈20fps 上限），这是两端画面质感差距的主因。【源码：`go2rtc:internal/streams/stream.go:97-121`、`Sources/MenuBarMijiaApp/CameraLiveVideoPlayer.swift:295-340`、`windows/src-tauri/src/camera.rs:71-78`、`windows/src/ui/cameraLive.ts:189-193`】

6. **"一台摄像机只开一条 P2P 会话，多个观看者/多个档位共享"已有三个成熟实现，我们都还没做：** micam 的 `&shared=1`（双镜头在同一 MISS 会话里按包头 `flags & 0x1400000` 分流，队列满直接丢帧）、ha-xiaomi-camera 的引用计数 `CameraSession` + 20 秒 linger、Scrypted 的 10 秒环形预缓冲。我们目前是"每个镜头一条会话 + macOS 关窗保 15 秒 / Windows 保 120 秒"。【源码：`micam:patches/go2rtc-v1.9.15-shared-session.patch:300-340`、`ha-xiaomi-camera:addon/rootfs/app/bridge/streaming.py:79-84`、`scrypted:plugins/prebuffer-mixin/src/main.ts:30`、`Sources/MenuBarMijiaApp/CameraLivePanelController.swift:70`】

7. **Frigate 的"事件 → 复核项 → 快照/预览片 → MQTT 通知"是通知链路最完整的范本**：0.14 起把 per-object 的 event 聚合成 review item（alert / detection 两级），缩略图是 320×180 的 webp，预览片是低帧率低码率，通知载荷里带 `snapshot.frame_time / box / region / score`。它还证明了一条纪律：**通知用的图必须来自真实管线**（ha-xiaomi-camera 的 `stills.py` 把"绿灯泡接在另一条电路上"这个坑写得很清楚）。【源码：`frigate:frigate/review/types.py:4-6`、`frigate:docs/docs/configuration/review.md:14-30`、`frigate:frigate/api/media.py:961`、`frigate:docs/docs/integrations/mqtt.md:212-250`、`ha-xiaomi-camera:addon/rootfs/app/bridge/stills.py:1-30`】

8. **HomeKit 的门铃就是一个 `Doorbell` 服务，唯一必需特征是 `ProgrammableSwitchEvent`；事件快照由 `CameraOperatingMode.EventSnapshotsActive` / `PeriodicSnapshotsActive` 门控，HAP 在调用 `handleSnapshotRequest` 前已经按这两个开关筛过 `reason`。** 我们现在的门铃只有"叮一声 + 自动弹窗 + 活动行"，既没有系统通知，也没有任何"事件快照"概念。【源码：`HAP-NodeJS:src/lib/definitions/ServiceDefinitions.ts:457-475`、`:241-258`、`HAP-NodeJS:src/lib/camera/RTPStreamManagement.ts:401-415`；我们的 `Sources/MenuBarMijiaApp/CameraLivePanelController.swift:299-315`】

9. **两端的摄像机链路已经明显分叉，不能再用"同一功能"对外表述：** macOS 有 fMP4 + VideoToolbox + 原生 PTZ + PiP + 双镜头切换 + HLS 音频；Windows 的米家摄像头只有 ffmpeg→JPEG（约 20fps、无音频、无 PTZ），HA 摄像头/HLS 则要先由 Rust 侧 `bridge_hls_camera_stream` 转成 MJPEG，画质与延迟都受二次转码拖累。【源码：`Sources/MenuBarMijiaApp/CameraLiveVideoPlayer.swift:14-16`、`windows/src-tauri/src/camera.rs:71-78,82-95`、`windows/src/ui/cameraLive.ts:1073-1100`、`windows/src/core/homeAssistant.ts:686-698`】

10. **小米官方口径没有变化，但生态里出现了两条新路线：** `ha_xiaomi_home` v0.5.0（最新 release，2026-09-28）仍无 camera 平台；miloco `main` 文档（2026-11-23）仍写明"不支持 PTZ / 双向语音 / 录制回放"。与此同时 2026 下半年出现了 `micam`（纯 go2rtc + 补丁）与 `ha-xiaomi-camera`（直接依赖 `miloco-miot` 闭源 SDK，pinned commit，做成 HA add-on）两条可跑通的第三方路线——后者把"许可证风险"变成了工程事实，而不是理论担忧。【源码/文档：`XiaoMi/xiaomi-miloco:knowledge/03-features/live-camera-view.md:28`、`ha-xiaomi-camera:addon/requirements.txt:1-10`、`ha-xiaomi-camera:README.md:276-292`】

---

## 1. go2rtc：source 注册表、MISS/CS2 现状、三种输出的取舍

### 1.1 插件化的真实形态：注册表 + 模块表，而不是插件框架

三层结构，一层比一层朴素：

1. **协议层**：`internal/streams/handlers.go` 维护 `handlers map[string]Handler`，`HandleFunc(scheme, fn)` 写入，`GetProducer(url)` 按 `url` 冒号前的 scheme 查表并调用，查不到就 `unsupported scheme`。consumer（推流方向）另有一张 `consumerHandlers` 表。【源码：`go2rtc:internal/streams/handlers.go:12-18,52-70,96-110`】
2. **厂商层**：每个 source 包只做一件事——在 `init()` 里注册自己的 scheme。`rtsp/rtsps/rtspx`、`http/https/tcp`、`ffmpeg`、`hass`、`homekit`、`xiaomi`、`onvif`、`tuya`、`roborock` 都是同一形状。【源码：`go2rtc:internal/rtsp/rtsp.go:39-41`、`internal/http/http.go:22-26`、`internal/xiaomi/xiaomi.go:32-50`、`internal/onvif/onvif.go:43`】
3. **装配层**：`main.go` 有一张 `modules := []module{{"xiaomi", xiaomi.Init}, …}` 表，按 `app.modules`（YAML `app: modules:`）白名单选择初始化哪些模块；空表示全开。**这张表就是最便宜的"攻击面开关"**：micam 正是靠它把 `exec / echo / expr / http / debug` 全部关掉。【源码：`go2rtc:main.go:63-119`、`internal/app/app.go:83-89`；`micam:docs/ARCHITECTURE.md:110-120`】

对我们的直接含义：如果要接 ONVIF/RTSP/其它厂商，不需要发明插件协议——**照 go2rtc 的粒度做一个 `CameraSourceKind` 表（scheme → 取流实现 + 能力）就够**；真正的成本在"每种 scheme 的凭证与失败语义"，不在框架。（见 §7 P2-3）

### 1.2 `xiaomi` source：MISS 的真实覆盖面

`internal/xiaomi` 只做三件事：云侧换凭证、按 vendor 选传输、把 URL 交给 `pkg/xiaomi`。

- **凭证**：`getMissURL()` 打 `v2/device/miss_get_vendor`（body 带 `app_pubkey`/`did`/`support_vendors: TUTK_CS2_MTP`），返回 `vendor` + `public_key` + `sign`；老机型走 `getLegacyURL()` 打 `/device/devicepass` 拿 TUTK UID。`getVendorName` 映射 `1=tutk, 3=agora, 4=cs2, 6=mtp`。【源码：`go2rtc:internal/xiaomi/xiaomi.go:110-149,152-196,203-216`】
- **传输**：`pkg/xiaomi/producer.go` 只认两种——URL 里带 `vendor=` 走 `miss.Dial`，否则走 `legacy.Dial`；`miss.NewClient` 内再按 vendor 分 `cs2` / `tutk`，**`agora` 和 `mtp` 直接返回 `unsupported vendor`**。这和我们 2026-11-07 的结论一致，也解释了 `c302n` 这类"云端报 cs2、实际 MTP"的机型为什么永远出不了画面。【源码：`go2rtc:pkg/xiaomi/producer.go:13-28`、`pkg/xiaomi/miss/client.go:47-75`】
- **双镜头**：`channel` 非 0 时，`StartMedia` 发的是 `{"videoquality":-1,"videoquality2":N,…}`——**不是新开会话，而是让同一个会话同时推第二路**。我们的 `CameraLensCatalog` 把 `channel=1` 当成"第二个镜头"用，语义是对的（值本身不是镜头序号）。【源码：`go2rtc:pkg/xiaomi/miss/client.go:172-190`；我们的 `Sources/MijiaCore/MiCloud/CameraLensCatalog.swift:1-10`】
- **画质档位有型号坑**：默认 `hd` 在 `chuangmi.camera.046c04`（C200）与 `chuangmi.camera.72ac1`（C300 双摄）要用 `3`，其余用 `2`；注释写明"部分机型 3 档编码参数是坏的，部分机型 2 档很糊"。这类按型号的分支正是我们 `CameraPTZ` 证据表该有的形状。【源码：`go2rtc:pkg/xiaomi/miss/client.go:150-170`】

### 1.3 CS2 的链路细节：ACK、重排、心跳、告别

`pkg/xiaomi/miss/cs2/conn.go`（533 行）值得单独看，因为它决定了"卡不卡、断不断、多久能重连"：

- **UDP 上每个 DRW 包都要 ACK**，且带 16 位序号；`dataChannel.PushSeq` 维护一个只在"未来序号"上缓存的小窗口，乱序可恢复，缓存满就丢（不重传）。这就是"宁可丢一帧，不要加延迟"的协议级实现。【源码：`go2rtc:pkg/xiaomi/miss/cs2/conn.go:109-175,493-530`】
- **TCP 上每秒发一次 PING**（注释：PCAP 里官方米家 App 就是 ~1s 一次），否则连接被回收。【源码：`:137-141`】
- **UDP 关闭必须显式 `msgClose`**，否则摄像机保留会话与流槽位约 20 秒（master 注释）。v1.9.15 没有这段——见结论 2。【源码：`:195-202`】
- 命令通道 `channels[0]` 由 `ReadCommand` 单读者消费；这正是我们 `CS2CommandChannelGate` 存在的原因（上游只读一次、10 槽缓冲会撑爆），也是 PTZ 位置反馈必须先改 gate 的原因（旧调研 §5）。【源码：`go2rtc:pkg/xiaomi/miss/cs2/conn.go:204-215`；我们的 `Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift:1100-1130`】

### 1.4 输出格式的选择逻辑：谁最不烂就用谁

go2rtc 自己把话说得很直：

> Technology selection based on priorities: 1. Video and Audio better than just Video 2. H265 better than H264 3. **WebRTC better than MSE, than HLS, than MJPEG**（`go2rtc:www/README.md:43-47`）

- **WebRTC**：延迟最好（表里 `latency: best`），但要 Pion + ICE；`webrtc: listen: ""` 可以整个关掉，我们就是这么做的。【源码/文档：`go2rtc:README.md:360-370`、我们的 `XiaomiCameraBridge.swift:555-582`】
- **MSE / fMP4 over WebSocket**：`latency: medium`，按帧推进 fMP4 分片（不做 HLS 式切片），不需要 jitter buffer；`/api/stream.mp4` 在 Safari 下会自动 302 到 HLS/fMP4；`duration=` 参数还能"录一段"。【源码：`go2rtc:internal/mp4/mp4.go:25,83,132`】
- **HLS**：`latency: bad`，`internal/hls/README.md` 第一句就是 "HLS is the worst technology for real-time streaming"；它的分片是 **0.5 秒**、播放列表目标时长 1 秒，按模板计算理论下限就是 0.5–1 秒（推断）。【源码：`go2rtc:internal/hls/README.md:5-6`、`internal/hls/session.go:26-32`】
- **MJPEG / 单帧**：`/api/frame.jpeg` 取一张关键帧，适合通知缩略图；`/api/stream.mjpeg` 适合兜底。【源码：`go2rtc:internal/mjpeg/mjpeg.go:27`】

### 1.5 低延迟不是调参，是三条结构性选择

1. **不转码**：`xiaomi://` 直接把摄像机码流（H.264/H.265）转成 RTP 包，`ffmpeg:` 只在消费者真的连上时才被拉起；没有消费者时 `stopProducers` 直接停源。【源码：`go2rtc:pkg/xiaomi/miss/producer.go:145-190`、`internal/streams/stream.go:97-121`】
2. **两阶段启动**：producer 的 `stateMedias → stateTracks → stateStart`，只有 consumer 选出轨道后才真正 `Start()`——避免"为了拿 SDP 先把摄像机拉起来"。【源码：`go2rtc:internal/streams/producer.go:112-160`】
3. **预加载是显式动作**：`AddPreload(name, "video&audio")` 用 probe consumer 常驻，等价于"保活但不解码"。【源码：`go2rtc:internal/streams/preload.go:1-60`】

我们 macOS 的 15 秒 warm playback 本质上是第 3 条的另一种实现，只是它保的是**整条解码链**而不只是会话（见 §6）。

---

## 2. Frigate：事件、快照、录像、检测与自动跟随

### 2.1 输入模型：一个摄像机 = 多条流 + 角色

Frigate 不直接读摄像机，而是先让 go2rtc restream，再让每个角色（`detect` / `record` / `audio`）从本地 RTSP 取流；官方文档明确把"减少对摄像机的连接数"当作一等目标：**一条 restream 连接，detect 与 record 都连本地**。【文档：`frigate:docs/docs/configuration/restream.md:20-70`】

这对我们有直接参考价值：我们的 `cam_raw` + `cam_mjpeg` 已经是"一个源、两个派生"，但派生是**在 startBridge 时就 `PUT` 两条**（mjpeg 那条是 `ffmpeg:raw#video=mjpeg`，靠 go2rtc 懒启动才没有立刻编码）。如果以后要加"低码率预览/录像"，正确做法是继续加派生名，而不是再开一条 P2P。

### 2.2 事件模型：从 "event = 一个物体" 到 "review item = 一段时间"

- 0.13 及以前：一个被跟踪物体 = 一个 event，同一时刻四个人走过就有四条视频。
- 0.14 起：**review item = 一段时间**，可包含多个 tracked object；同一摄像机的 review 不能重叠；分 `alert`（默认 person/car）与 `detection`（其余）两级，级别可因 zone/子标签升级。【文档：`frigate:docs/docs/configuration/review.md:14-32`；源码：`frigate:frigate/review/types.py:4-6`】

这个模型对我们很重要：我们现在只有 `PanelActivity`（通知行）和 `DoorbellRing`（单次按压），**没有"一件事"的对象**。门铃按一次、随后 30 秒有人影移动，在 Frigate 里是一条 alert review；在我们这里会是三条互不相关的记录。

### 2.3 快照：四层可调 + 一个 API 形状

`SnapshotsConfig` 的字段就是"通知图"的完整旋钮：`enabled`、`timestamp`（叠加时间）、`bounding_box`（默认 **true**）、`crop`（默认 false）、`required_zones`（进入指定区域才存）。【源码：`frigate:frigate/config/camera/snapshots.py:21-45`】

对外只有几个稳定端点：`/api/events/{event_id}/snapshot.jpg`、`/{camera}/{label}/snapshot.jpg`、`/preview/{file}/thumbnail.jpg`、`/{camera}/{label}/thumbnail.jpg`。【源码：`frigate:frigate/api/media.py:961,1904,1963,2009`】

缩略图本身是 **webp**、固定 **320×180**（`THUMB_WIDTH = 320`、`THUMB_HEIGHT = 180`，`PREVIEW_FRAME_TYPE = "webp"`），由 review maintainer 在事件进行中不断用最新帧覆盖写同一个文件——所以通知里拿到的永远是"目前最好的一张"，而不是事件开始那一张。【源码：`frigate:frigate/review/maintainer.py:41-42,80-100`、`frigate/const.py:147`】

### 2.4 通知载荷：给客户端的字段就是"可操作的最小集"

`frigate/reviews` 的 MQTT 消息带 `id / camera / start_time / end_time / severity / thumb_path / data.detections[] / data.objects[] / data.zones[]`；`frigate/events` 另带 `snapshot.frame_time / box / area / region / score`。客户端据此能画时间线、点开片段、显示"person, car"。【文档：`frigate:docs/docs/integrations/mqtt.md:212-260`、`:40-90`】

**我们的 `DoorbellRing` 只有 `deviceId / entityId / firedAt`**。要支持"通知里显示谁、在哪、什么"，这个结构必须扩。

### 2.5 PTZ 自动跟随：唯一成熟的闭环参考，但我们缺反馈

`frigate/ptz/autotrack.py`（1430 行）的做法：

1. **标定**：`num_steps = 30`，`np.linspace(0, 1, 30)` 逐档移动并记录耗时；zoom 也标。
2. **线性回归**：用 `(abs(pan)+abs(tilt), 耗时)` 拟合 `耗时 = intercept + slope × 位移`，并要求 `0.1 ≤ intercept ≤ 10`、`0 < slope ≤ 2`，否则判标定失败；参数写回 YAML 的 `movement_weights`。
3. **预测**：`_predict_movement_time` 用回归系数算"这次要转多久"，据此预测目标框在画面里的位置，再决定是否继续追、是否 zoom。【源码：`frigate:frigate/ptz/autotrack.py:355-420,520-600,592-626`】

我们只有开环步进（PR #2531 的 `Motor()` 只发命令不读 `0x113`），**没有位置、没有耗时实测，做不了这个闭环**。能借的只有"标定 + 回归"的方法论：即使开环，也可以在真机上测"一步 ≈ 多少像素"（PR #2531 作者测到 640 宽画面约 70px/步），把"按住多久 ≈ 转多少度"做成一张按型号的表（成本 S），而不是像现在这样只按时间发步。

---

## 3. Scrypted：接口 + Mixin + 预缓冲 + HKSV

### 3.1 插件模型：能力是接口，组合靠 Mixin

- 最小摄像头接口只有两个方法：`takePicture()` 与 `getPictureOptions()`；视频在 `VideoCamera.getVideoStream(options)`。【源码：`scrypted:sdk/types/src/types.input.ts:474-478,712`】
- 请求是**带约束的协商**：客户端说"我要 h264/h265 备选、aac 音频、mp4 容器、预缓冲 N 毫秒"，插件要么原生满足，要么用 ffmpeg 包一层；`MediaStreamOptions.prebuffer` 就是这个契约的一部分。【源码：`scrypted:sdk/types/src/types.input.ts:520-560`】
- 跨设备能力注入靠 `MixinProvider`：一个插件可以给别的设备"加接口/拦调用"，预缓冲、Rebroadcast、HomeKit 都是这么挂上去的。【源码：`scrypted:sdk/types/src/types.input.ts:2208-2212`】

对照我们：`CameraStreamSource` 是**闭集枚举**（`hls` / `liveMP4` / `mjpeg` / `snapshot` / `demo`），能力靠 `CameraSpec` 的布尔与字符串拼。要接第三个厂商时，枚举会继续膨胀；Scrypted 的"请求约束 + 协商结果"更耐扩。

### 3.2 预缓冲：10 秒环形缓冲 + 10 秒空闲回收 + 电池降级

- `prebufferDurationMs = 10000`：常驻一个 RTSP 会话，把最近 10 秒的 chunk 存在内存环形数组里，新客户端连上时先灌这段历史，所以"打开就有画面"。【源码：`scrypted:plugins/prebuffer-mixin/src/main.ts:30,719-740`】
- 空闲 10 秒且没有活跃客户端就杀掉会话；被动客户端不重置计时器（避免"后台标签页把摄像头一直拉着"）。【源码：`:750-770`】
- **电量感知**：有 `Battery`/`Charger` 接口时，低电量或未充电就关掉预缓冲，改成按需——这条我们没有，但我们的电池摄像机（`CameraHubCatalog` 的 `mxiang.camera.mwc11`）正是最需要它的。【源码：`:776-800`】

### 3.3 HKSV：参数是被 Apple 的容器要求倒推出来的

- 分片 = **4 秒**（`iframeIntervalSeconds = 4`，同时用作 `-g fps*4` 的 GOP），分片长度也是 4 秒；预缓冲 = `1 × 4s × 1000 = 4000ms`，实际向设备要 **2.5 倍**（10 秒）的片段，多出来的用于对齐关键帧。【源码：`scrypted:plugins/homekit/src/types/camera/camera-recording.ts:24,130,163`、`plugins/homekit/src/types/camera.ts:175-180`】
- **优先直连**：如果预缓冲流本身就是 `tcp://` + `mp4` + h264 + aac，就直接读 socket，不启 ffmpeg；否则转码（音频强制 AAC-LC；注释说 HomeKit 见到 AAC-ELD 会优先选它，所以故意不提供 ELD）。【源码：`camera-recording.ts:163-200`、`camera.ts:150-170`】
- **触发**：HKSV 的录制由 Home 中心在收到 `MotionSensor` 事件后主动拉流；`CameraRecordingManagement` + `CameraOperatingMode` 决定事件快照/周期快照是否允许。【源码：`scrypted:plugins/homekit/src/types/camera/camera-secure-video.ts:75-76,149`；`HAP-NodeJS:src/lib/definitions/ServiceDefinitions.ts:241-258`】
- README 里的运维事实同样有价值：服务器必须和 Home 中心同子网，否则"直播能看、录像不触发"；iPad/HomePod 作家庭中枢不可靠。（`scrypted:plugins/homekit/README.md:5-40`）

对我们的含义：如果要做"事件片段"，**4 秒 GOP + 4 秒分片 + 10 秒环形缓冲**是一组已经在 Apple 生态里跑通的参数（Scrypted 的实现，被 HKSV 用户长期使用）；我们的 fMP4 demuxer 已经有按 sample 重组的能力，做"最近 N 秒导出 mp4"不需要新依赖（见 §7 P2）。

---

## 4. 小米系开源：官方没变，第三方在分叉

### 4.1 miloco（官方）：能力边界一年未变，工程细节更清楚

本次只取 `main` 的直播文档（2026-11-23）与 commits（HEAD `b1887aea`，2026-11-18），增量点：

- 能力边界仍是三句：**不支持 PTZ、不支持双向语音、不支持录制/历史回放**；PPCS 需要 UDP 入站、必须同局域网。【文档：`miloco:knowledge/03-features/live-camera-view.md:26-31`】
- 架构上是"**一次解码、一次 H.264 编码、多订阅者共享**"：第一个订阅者创建 `H264LiveEncoder`，后续订阅者复用编码输出；直播与感知流水线通过 `start_camera_decode_video_stream(multi_reg=True)` 共用同一次解码；浏览器侧优先 WebCodecs `VideoDecoder`，LAN HTTP 下回退 MSE + jmuxer。【文档：同上，`研发面/架构概览` 段】
- 仍然要求 `libmiot_camera_lite`（闭源、非商业许可）——旧调研的"排除"结论不变。【文档：`docs/research/issue-97-camera-support.md:114-131`】

### 4.2 `ha_xiaomi_home`：v0.5.0（最新 release）仍无 camera 平台

我们手上的克隆就是 v0.5.0（`75b3acb`，2026-09-28，`docs: update changelog and version to v0.5.0`），平台文件里没有 `camera.py`；GitHub 最新 release 也正是 v0.5.0（API 查询 2026-11-23）。**"官方集成不给画面"这条结论在 2026-11 仍然成立，不需要新的论证。**（旧调研的 issue #40 / #160 引用继续有效）

### 4.3 `hass-xiaomi-miot`：所有"直播"都建在厂商云接口上，没有 P2P

`camera.py`（`8ac4df7`）的三条路：

1. `async_get_stream_address` → 优先 `camera_stream_for_google_home.start_hls_stream`，失败再 `camera_stream_for_amazon_alexa.start_rtsp_stream`，带 4.5 分钟兜底刷新（旧调研已述）。
2. 告警片段：`alarm/playlist` + `common/app/m3u8` + `img`（AES-CBC）。
3. `handle_async_mjpeg_stream` 兜底。

**增量结论**：这个仓库里没有任何 MISS/CS2/TUTK 代码（`grep -i "miss|cs2|tutk|go2rtc"` 只命中无关字符串）。所以它对我们最有价值的部分不是"取流"，而是**事件 API**：`alarm/playlist` 与 `img` 就是"云端最近一次告警的封面 + 片段"，可以独立于直播使用。【源码：`hass-xiaomi-miot:custom_components/xiaomi_miot/camera.py:180-275,453-510`】

### 4.4 2026 年新出现的两个第三方实现（真正的增量）

**（a）`kaivyy/micam`（MIT，`dad0965`，2026-11-19）：单会话双镜头 + 本地 NVR**

- 给 go2rtc v1.9.15 打补丁，URL 加 `&shared=1` 后走 `dialShared`：**一个 hub 持有一条 MISS 会话**，用 `StartMedia("both", …)` 让摄像机同时推两路，再按包头 `flags & 0x1400000` 判断是第二镜头，分发给各自的 sub（队列 512，满了丢帧，不阻塞读循环）；最后一个 sub 关闭时才 `StopMedia` + 关闭会话。【源码：`micam:patches/go2rtc-v1.9.15-shared-session.patch:300-495`】
- 输出：WebRTC（`video-rtc.js`）+ **RTSP 给 NVR** + 录像用 `ffmpeg -c copy` 从本地 RTSP 拉、15 分钟一段、按保留天数/磁盘水位清理（CPU ~0–1%）。【源码：`micam:recorder.py:1-60`、`docs/ARCHITECTURE.md:60-90`】
- 安全姿态值得抄：`app.modules` 白名单 + `api.allow_paths` 只放 `/api/ws`、`/api/webrtc`、`/api/frame.jpeg`、`/api/restart`，其余 403；`/api/config`、`/api/exit`、`/api/xiaomi` 只允许 loopback；`exec/echo/expr` 的 `allow_paths` 指向不存在的路径。【源码：`micam:docs/ARCHITECTURE.md:110-130` + patch 的 `internal/api/*.go` 段】

**（b）`willjayyyy/ha-xiaomi-camera`（Apache-2.0，`73ce5fd`）：把 miloco SDK 做成桥**

- 依赖 `miloco-miot @ git+https://github.com/XiaoMi/xiaomi-miloco.git@eb264e8b#subdirectory=backend/miot`，**pinned commit**，明确说明"闭源 native 库不随仓库分发，构建时从上游下载"。【源码：`ha-xiaomi-camera:addon/requirements.txt:1-12`、`README.md:276-292`】
- 为什么要拆成 add-on：闭源库链接 glibc（到 `GLIBC_2.25`），HA 官方容器是 Alpine/musl，加载不了；所以桥跑 Debian + `host_network: true`，视频从不进 HA 进程，只给 HA 一个 URL。【源码：`addon/Dockerfile:1-15`、`docs/ARCHITECTURE.md:7-30`】
- 会话模型是我们最该学的：**每台摄像机一条 P2P 会话，引用计数（`CameraSession._hold`），最后一个用户离开后 linger 20 秒**；消费者队列上限 70 个单元（20 视频帧/秒 + 50 Opus 包/秒），满了丢帧；所有派生流（h264/360p/…共 8 条）都从 root 流按名字派生，**共享同一条会话**，`ffmpeg:` 变体按消费者懒启动。【源码：`addon/rootfs/app/bridge/streaming.py:79-90,100-130`、`docs/ARCHITECTURE.md:285-300,370-382`】
- 实测数据（他们的机型/固件）：同 LAN 会话 `CONNECTED` 约 2 秒、首帧约 0.13 秒；跨 VPN `PPCS_Connect errorcode: -3` 永不连上；码流是 H.265 848×480 ~21fps、关键帧约 2.8 秒、每个关键帧前重发 VPS/SPS/PPS；access token 约 3 天有效。【源码：`docs/ARCHITECTURE.md:40-60,108-118`】
- 快照纪律：**不用 SDK 的解码回调做快照**，而是从已发布的 RTSP 里用 ffmpeg 解一张——理由是"解码回调会在主链路已经坏掉时继续返回图片，等于把绿灯接在另一条电路上"，而且回调会为每帧解码、4K 机型单核 55%。【源码：`addon/rootfs/app/bridge/stills.py:1-40`】

这两条路线说明：**MISS/CS2 的协议层已经没有秘密，差异化全在"会话复用、输出封装、快照来源"三个工程决策上。**

### 4.5 其它（仅检索层面，未见源码）

- `perseus177/ha-imilab-ec2`：IMILAB/Mijia EC2 电池机，捆绑"打过补丁的 go2rtc"。【检索：GitHub 仓库页 2026-11-23】
- `VictorCV-DAM/ha-xiaomi-imilab-camera-liberator-webrtc`：宣称 <200ms WebRTC、本地 UDP PTZ、Lovelace 卡；创建于 2026-11-18，3 星，未验证。【检索：同上】
- `eugeneRover/micam`：Xiaomi 摄像头的 headless 流媒体服务，未见细节。【检索：同上】

---

## 5. 客户端体验：三种"看摄像头"的产品形态

### 5.1 HA frontend：网格看静帧，点开才起流

- 卡片默认 `camera_view: "auto"`；当卡片把摄像机当作静态图时（`camera_image` 配置 / `auto`），静帧每 **10 秒**刷新一次，`IntersectionObserver` 让卡片离开视口就停止刷新（省流量/省电）。`live` 才建流。【源码：`home-assistant/frontend:src/panels/lovelace/cards/hui-picture-entity-card.ts:60,212-218`、`components/hui-image.ts:29,55,107-109,370-475`】
- 点开/`live` 时 `ha-camera-stream` 会**同时挂 HLS 与 WebRTC 两个播放器**（HLS 先出画占位，WebRTC 一旦出画立刻切过去；两者都失败回落 MJPEG），判断依据是 `camera/capabilities` 的 `frontend_stream_types` 与各自 `hasVideo` 回调。【源码：`components/ha-camera-stream.ts:199-235`、`src/data/camera-streams.ts:28-100`】
- HLS 播放器参数直接说明了"为什么 HLS 只能当兜底"：`backBufferLength: 60`、`maxLiveSyncPlaybackRate: 2`、`lowLatencyMode` 仅在 LL-HLS 支持时开。【源码：`components/ha-hls-player.ts:364-376`】

**这是"多路网格"最省资源的实现**：N 路 × 每 10 秒一张 JPEG，点击某一路才建立会话。我们目前是每开一台就建 P2P 会话，没有网格。

### 5.2 `AlexxIT/WebRTC` 卡：模式串 + 自动停 + 数字 PTZ

- `mode` 默认 `'webrtc,mse,hls,mjpeg'`，按能力逐级尝试（MSE 要 `MediaSource`/`ManagedMediaSource`，HLS 要 `canPlayType('application/vnd.apple.mpegurl')`）。【源码：`AlexxIT/WebRTC:custom_components/webrtc/www/video-rtc.js:39,331-381`】
- `background` + `intersection`（默认 0.75）：卡片看不见就停流；进系统画中画时把 `background` 置 true（PiP 期间继续播）。【源码：`www/webrtc-camera.js:13-16,536-545`】
- **数字 PTZ**：不转摄像机，只对 `<video>` 做 transform：鼠标拖动平移、滚轮缩放、双击缩放（`transition: transform 200ms`）、单指拖动缩放速度 1/200、最大 10×、位置持久化（`persist_key`）。【源码：`www/digital-ptz.js:1-40`】

数字 PTZ 对我们很有用：**在物理 PTZ 不可用/未验证的机型上，"看起来能推拉摇移"是零成本、零风险的体验兜底**（我们已经有双击缩放，但没有拖动平移与惯性）。

### 5.3 Apple Home：门铃 = 一个服务和两个开关

- 门铃配件在 HAP 里是 `Doorbell` 服务，**必需特征只有 `ProgrammableSwitchEvent`**（单按/双按/长按），可选 `Volume`、`Mute`、`Brightness`。【源码：`HAP-NodeJS:src/lib/definitions/ServiceDefinitions.ts:457-475`】
- 事件快照是独立能力：`CameraOperatingMode` 服务里有 `EventSnapshotsActive`（事件快照）与 `PeriodicSnapshotsActive`（周期快照）；`handleSnapshotRequest` 被调用时，HAP 已按这两个开关筛过 `reason`（`event` / `periodic`），所以实现方只需要"给一张图"。【源码：`ServiceDefinitions.ts:241-258`、`src/lib/camera/RTPStreamManagement.ts:401-415`】
- 录制侧是 `CameraRecordingManagement` + `CameraRecordingDelegate`，容器固定 fMP4，H.264 + AAC。【源码：`ServiceDefinitions.ts:265`、`Scrypted:plugins/homekit/src/types/camera/camera-recording.ts:150-200`】
- Home App 的"摄像头网格/通知缩略图"两件事没有公开源码可读，机制只能从上面两条服务推断：**Home 中心收到 `ProgrammableSwitchEvent` → 按 `EventSnapshotsActive` 向摄像头请求一张 event 快照 → 富通知带图；点开后再走 `CameraRTPStreamManagement` 拉实时流**。【推断，依据同上；本机无 Apple Home 环境，未实测】

### 5.4 门铃 → 桌面通知：我们要补的不是"弹窗"，是"图 + 动作 + 去重"

现状（我们）：`DoorbellRing` → `HomeStore.handleDoorbellRing` → 播放 `NSSound("Glass")` + 打开右上角小窗（可关）+ 活动行。**没有 `UNNotification`，没有附件，没有动作按钮。**【源码：`Sources/MenuBarMijiaApp/CameraLivePanelController.swift:299-315`、`Sources/MijiaCore/HomeStore+Doorbell.swift:1-30`】

已有的可复用件：
- 去重：同一次按压 `key = entityId@firedAt`，跨源（米家/HA）2 秒窗口合并（#23）。【源码：`Sources/MijiaCore/DoorbellRing.swift:20-30`、`DualSourceHomeProvider.swift:377-400`】
- 通知基建：`HotkeyAndNotificationManager` 已有 Category / Action（关灯、补执行定时）与 `UNUserNotificationCenter` 封装，但从未用过 `UNNotificationAttachment`。【源码：`Sources/MenuBarMijiaApp/HotkeyAndNotificationManager.swift:623-700,780-805`】
- 取图：go2rtc `/api/frame.jpeg?src=cam_raw_<did>`（Basic auth，本地回环）或 HA `/api/camera_proxy/<entity>?token=`（token 免费随状态下发）。【源码：`go2rtc:internal/mjpeg/mjpeg.go:27`、`HomeProvider.swift:984-995`】

因此"门铃通知带缩略图"是**成本 S 的确定性改进**，不需要新协议、不需要新进程（见 §7 P0-3）。

---

## 6. 对照我们：差距表

| # | 我们的文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | --- | --- |
| 1 | `Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift`、`windows/src-tauri/src/camera.rs` | 固定 go2rtc v1.9.15；关闭流时 UDP 直接关 socket，摄像机会占槽位 ~20s（我们实测 1 分钟+） | master 的 `Conn.Close()` 先发 `msgClose` 再关；ha-xiaomi-camera linger 20s | 自建补丁加 `msgClose`（5 行），真机验证后把 Windows 120s 保温降到 ~20–30s | S |
| 2 | `Sources/MijiaCore/MiCloud/CameraLensCatalog.swift`、`XiaomiCameraBridge.swift:298-310` | 双镜头是"切换"：换镜头就停掉旧流，同一时刻只开一路；每路各自一条 P2P 会话 | micam `&shared=1`：一条会话推两路，按 `flags & 0x1400000` 分流 | 先做"同会话双路"实验分支（自建补丁），验证 061a01/72ac1 是否支持 `StartMedia("both")`；不支持则保留切换 | M |
| 3 | `XiaomiCameraBridge.swift:1325-1355` | 取流 URL 写死 `audio=0`；`FragmentedMP4Demuxer` 只解析视频轨；`CameraLiveAudioStatus` 把非 HLS 全部标成 video only | go2rtc 默认 `audio=1`，PCMA/Opus 直接进 RTP；`backchannel.go` 做 40ms 分片回写 | 第一步只做"听"：开 `audio=1`，fMP4 解音频轨 → `AVSampleBufferAudioRenderer`；对讲另立 | M |
| 4 | 同上 | 无对讲 | `StartSpeaker()` + `WriteAudio(codecID, payload)`；PCM/PCMA/Opus 按机型分（dafang/isc5c1/hlc6 要 PCM，72ac1 要 Opus） | 对讲放到 P2（需要麦克风权限 + 回声处理 + 机型表） | L |
| 5 | 无 | 无 SD 卡回放 | MISS `cmdPlaybackReq 0x10D` 已在命令表里（上游未实现） | 先做证据收集（抓包/真机），再决定 | L |
| 6 | `Sources/MijiaCore/CameraPTZ.swift` | 开环步进；型号表硬编码在 Swift 里；无位置、无单步像素标定 | Frigate 的 30 档标定 + 线性回归（需要反馈）；PR #2531 作者实测 70px/步 | 先做"单步像素/耗时"实测表（按型号），把按住时长映射成步数；位置反馈要等 gate 改造 | S（标定）/ M（反馈） |
| 7 | `Sources/MijiaCore/CameraPTZ.swift:54-101` | 能力证据表写死在代码里，新增型号要改 Swift、跑测试 | 我们自己的 `deviceProfiles.json` 先例；micam/ha-xiaomi-camera 都是配置文件/常量表 + 注释证据 | 把 PTZ/镜头/画质档位合成一个 `cameraProfiles.json`（model → vendor/mode/stepPixels/quality），Swift 与 TS 各读一份 | M |
| 8 | `Sources/MijiaCore/DoorbellRing.swift`、`HomeStore+Doorbell.swift` | 门铃 = 时间戳 + 去重 + 鸣笛 + 弹窗 + 活动行 | HomeKit：`Doorbell` 服务 + `EventSnapshotsActive`；Frigate：alert/detection + 快照 + 动作 | 扩 `DoorbellRing` 带 `snapshotURL`/`label`；发 `UNNotification` + attachment + "查看/静音"动作 | S |
| 9 | `HotkeyAndNotificationManager.swift` | 有 Category/Action 基建，无 attachment | Frigate MQTT 载荷、HA 富通知 `image` | 加 `UNNotificationAttachment`（JPEG 写 caches），复用现有去重键 | S |
| 10 | `Sources/MijiaCore/MiCloud/MiCloudProvider.swift:1560-1620` | 只轮询门铃事件（`doorbell-ring`/`doorbell-press`），没有移动/人形事件 | Frigate review（人/车/包裹 + zone）、HA `event`/`binary_sensor` | 建 `CameraEvent`（kind/time/device/zones/score/snapshot），门铃与移动共用一条管线 | M |
| 11 | `Sources/MijiaCore/PanelActivity.swift` | 活动行只保留最近 20 条，无按摄像机/类型筛选，无"已读" | Frigate review 时间线 + 已读状态 | 事件库落 SQLite（或 JSON），活动面板加筛选；先不做视频 | M |
| 12 | 全部 | 无录像/导出 | go2rtc `stream.mp4?duration=`；micam `ffmpeg -c copy` 15 分钟分段；Scrypted 4s 分片 | 先做"导出最近 N 秒"（从 fMP4 环形缓冲，macOS 独有）；再做持续录像 | M |
| 13 | `Sources/MenuBarMijiaApp/CameraLivePanelController.swift` | 单窗口；双镜头切换；无网格 | HA 网格：静帧 10s + 点击起流；webrtc-camera 的 visibility 停流 | 菜单栏加"摄像头墙"（2×2 静帧，10s 刷新；点击开窗），复用 `snapshotPath`/`frame.jpeg` | M |
| 14 | `CameraLiveVideoPlayer.swift` | 背压时 flush + 等关键帧（正确）；但只处理视频 | Scrypted 4s GOP、HKSV 2.5× 预缓冲 | 把"最近 10s 环形缓冲"做成可导出 mp4 的能力（事件片段） | M |
| 15 | `Sources/MijiaCore/HomeProvider.swift:928-995` | HA：`camera/stream` → HLS；失败转 MJPEG；有音频 | HA frontend：HLS 占位 + WebRTC 优先 + MJPEG 兜底 | 保持现状（HLS 对我们够用），但把"启动失败原因"区分证书/编码/超时，别一律黑屏 | S |
| 16 | `windows/src/core/homeAssistant.ts:686-698`、`windows/src/ui/cameraLive.ts:1073-1100`、`windows/src-tauri/src/camera.rs:82-95` | Windows HA 摄像头：`camera_proxy` 改写成 `camera_proxy_stream` 直接播 MJPEG；HLS 则走 Rust `bridge_hls_camera_stream` 二次转 MJPEG（有 origin allowlist） | macOS 同源已原生播 HLS | 中期给 WebView2 加 hls.js（保留现有桥作兜底）；短期把"这是转码后的画面"在 UI 上说清楚，别让用户以为是摄像头糊 | S/M |
| 17 | `windows/src-tauri/src/camera.rs:71-78` | 米家摄像头：ffmpeg 转 H.264 + MJPEG 两条；前端拉 JPEG（45–500ms 自适应） | macOS fMP4 + VideoToolbox；go2rtc MSE | 中期把 Windows 切到 fMP4（WebView2 MSE 或 Rust 解复用 → Media Foundation）；短期至少把 MJPEG 质量/帧率做成可调 | M/L |
| 18 | `windows/`（无 PTZ） | Windows 无 PTZ | 我们的 macOS 补丁桥已有 HTTP 端点（loopback + Basic auth） | Windows 直接复用同一补丁二进制 + 同一 `/api/xiaomi/ptz` 契约；Tauri 侧只做手势与状态机 | S/M |
| 19 | `XiaomiCameraBridge.swift:555-582` | go2rtc 配置有 `local_auth`、随机端口、禁 1984/8554/8555、owner 校验；但**没有** `app.modules` 白名单、没有 `api.allow_paths`，且 `rtsp: listen` 开着却从未使用 | micam：模块白名单 + `allow_paths` + loopback-only | 加 `app.modules: [api, ws, mp4, mjpeg, webrtc, xiaomi, ffmpeg]`；`rtsp.listen: ""`；`api.allow_paths` 只留用到的 | S |
| 20 | `Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift:250-256` | 每次取流都新生成 X25519 密钥对（无缓存），且 `stop-stream → start-p2p-stream → miss_get_vendor` 串行执行 | ha-xiaomi-camera 把 access token 持久化并按约 3 天周期刷新；go2rtc 每次连接仍要联网取密钥（协议决定） | 两条 MIoT action 必须串行；`miss_get_vendor` 可尝试与唤醒并行预取（需真机确认不抢会话），单次开流可省一次 RTT | S |

---

## 7. 推进清单

### P0（低成本、修明显缺陷）

**P0-1 给自建 go2rtc 补丁加 `msgClose`，并重测会话回收时间**
- 价值：关窗/切镜头/切设备后的重连速度直接受益；可能把 Windows 的 120 秒保温砍到 20–30 秒，省一条常驻转码。
- 成本：S（5 行 Go + 一次真机计时）。
- 高风险面：否（不改控制写入，只改断开握手）。但改的是"下载/校验的二进制"，属于发版链路 → 走 PR。
- 依据：`go2rtc:pkg/xiaomi/miss/cs2/conn.go:195-202`（master）vs `v1.9.15` 无此方法；我们的实测 `docs/research/issue-97-camera-support.md:540`。

**P0-2 go2rtc 配置收敛**
- 价值：减少攻击面（exec/http/rtsp 全部关掉），也少开一个 TCP 端口。
- 成本：S（改 `desiredGo2RTCConfig` + 一条快照测试）。
- 高风险面：是（网络传输边界），走 PR。
- 依据：`micam:docs/ARCHITECTURE.md:110-130`；我们 `XiaomiCameraBridge.swift:555-582` 且 `rtsp` 从未被使用。

**P0-3 门铃系统通知（带缩略图 + 动作）**
- 价值：现在门铃只在 App 内可见，用户不看菜单栏就错过；这是 #308 的自然收尾。
- 成本：S（`UNNotificationAttachment` + `frame.jpeg` 取图 + 复用现有去重键）。
- 高风险面：否（本地通知，不外发）。
- 依据：`HotkeyAndNotificationManager.swift:623-700`；`go2rtc:internal/mjpeg/mjpeg.go:27`；`HAP-NodeJS:...RTPStreamManagement.ts:401-415` 的 event/periodic 区分。

**P0-4 能力表数据化**
- 价值：新增机型不再改 Swift；PTZ/镜头/画质三张表目前分散在三处，容易漂移。
- 成本：S/M（一次搬迁 + 一致性测试；已有 `Tests/Fixtures/camera_ptz_models.json` 先例）。
- 高风险面：否。
- 依据：`CameraPTZ.swift:54-101`、`CameraLensCatalog.swift:8-15`、`go2rtc:pkg/xiaomi/miss/client.go:150-170` 的型号分支。

### P1（结构改进）

**P1-1 `CameraEvent` 模型 + 本地事件库**
- 价值：门铃、移动、人形、包裹共用一条管线；通知、活动面板、Raycast/MCP 都能查。
- 成本：M（模型 + 存储 + 保留策略 + 测试）。
- 高风险面：否（只读事件，不下发控制）。
- 依据：Frigate review/alert 模型（`frigate/review/types.py`、`docs/.../review.md:14-32`）；我们的 `PanelActivity` 太薄。

**P1-2 摄像头墙（2×2 静帧 + 点击起流）**
- 价值：菜单栏形态天然适合"瞥一眼"；避免为看一眼建 4 条 P2P。
- 成本：M（新面板 + 10s 刷新 + 可见性停更）。
- 高风险面：否。
- 依据：HA `hui-image` 10s + IntersectionObserver；webrtc-camera `intersection: 0.75`。

**P1-3 双镜头同会话（实验分支）**
- 价值：真正"同时看两路"，且只占一条会话；对电池机与单会话机型是刚需。
- 成本：M（补丁 190 行 + 真机验证 + 回退开关）。
- 高风险面：是（设备控制边界/会话数），走 PR + 真机清单。
- 依据：`micam:patches/...shared-session.patch:300-495`；`go2rtc:pkg/xiaomi/miss/client.go:172-190`。

**P1-4 音频（先听不说）**
- 价值：摄像机没有声音是明显的体验缺口；go2rtc 侧零成本（改 `audio=1`）。
- 成本：M（fMP4 音频轨 + 播放器 + 音量/静音 UI）。
- 高风险面：否。
- 依据：`go2rtc:pkg/xiaomi/miss/producer.go:55-105`（PCMA/Opus 探测）、`client.go:200-240`。

### P2（有价值但可等）

- **P2-1 事件片段导出**（最近 10s 环形缓冲 → mp4；参数参考 HKSV 4s GOP / 2.5× 预缓冲）——成本 M。
- **P2-2 移动/人形事件订阅**（MIoT `event` + HA `event`/`binary_sensor`；带 60s 冷却与"仅离家/锁屏时通知"）——成本 M，复用 `AwayArbitrator`。
- **P2-3 ONVIF/RTSP 源**（走 go2rtc `onvif://`/`rtsp://`，统一进 `CameraStreamSource`）——成本 M，是"多厂商"的最小落地。
- **P2-4 Windows 对齐**：HA 摄像头 HLS（hls.js）+ 复用 PTZ 端点——成本 S/M。
- **P2-5 云端告警封面**（`alarm/playlist` + `img` AES-CBC，给"最近一次告警"用，不做直播）——成本 M，仅在用户机型不支持 HLS/P2P 时才有意义。
- **P2-6 对讲**（`0x106/0x108` + 40ms 分片 + 机型 codec 表）——成本 L。

### P3（远期/探索）

- 端侧视觉事件（Vision/CoreML 做人形/包裹，替代云 AI 订阅）。
- 本地 NVR（持续录像 + 保留策略 + NAS 归档）。
- Apple Home 桥（HAP-NodeJS 证明可行，但工程与合规成本高）。
- PTZ 自动跟随（需要位置反馈或视觉闭环；frigate autotrack 是方法论参考）。

---

## 8. 设想（天马行空，标注与现有 ADR 的关系）

1. **把摄像机桥做成独立进程 + 本地协议（HTTP/WS），两端共享一套实现。**
   现状是 macOS 用 Swift actor + go2rtc，Windows 用 Rust + go2rtc，PTZ 只在 macOS。ADR-0023 否决的是"进程内第三方代码插件"，进程外扩展是允许重启评估的方向——一个 `menubar-camera-bridge`（签名、可执行、只监听 loopback、带 token）可以让两端与 Raycast/MCP 都复用，也能承载"录像/事件片段"这类重活。**与 ADR-0023 不冲突**（进程外），但需要新的 ADR 说明协议与信任边界。

2. **"事件中枢"：把门铃/移动/人形/包裹统一成 `CameraEvent`，对外暴露为活动时间线 + 系统通知 + MCP 查询。**
   Frigate 的 review item 是现成模板；我们的差异化在"菜单栏常驻 + 本地口令助手"，比如"刚才门口有人吗"直接查事件库。**不与任何 ADR 冲突**。

3. **摄像头墙 + 数字 PTZ：不转摄像机的"假云台"。**
   webrtc-camera 的 digital-ptz 只有 348 行；我们有双击缩放但没有拖动平移/惯性。对 PTZ 未验证的机型（061a01），数字 PTZ 是唯一"能推拉"的体验，且零风险。**不冲突**。

4. **用 go2rtc 的 `hass` / `onvif` source 做"零配置导入"。**
   `hass` source 能直接吃 HA 的 WebSocket 凭证；`onvif://` 能自动发现 RTSP。这样"多厂商"不是我们写 N 个适配器，而是把 go2rtc 当统一后端。**不冲突**（仍是外部二进制，不是进程内插件）。

5. **端侧"谁来了"：Vision 做人形/包裹检测，事件截图入 SQLite，通知里带"人/车/包裹"标签。**
   不需要云 AI 订阅，也不碰摄像机固件。代价是 CPU/电量，需要"仅在家/仅特定摄像机"开关。**不冲突**。

6. **门铃对讲 + 快捷回复（TTS）。**
   协议已具备（`0x106/0x108` + Opus/PCM），难点是回声消除与权限。做完之后，"快递放门口"可以一键播报。**不冲突**（但属于"向设备写入音频"，是新的高风险面，需要明确授权与失败兜底）。

7. **HomeKit 桥（把我们的摄像头发成 HAP 配件）。**
   HAP-NodeJS 证明门铃 + HKSV 可以纯软件实现；但需要常驻进程、mDNS、配对存储，且与"菜单栏 App"生命周期冲突。**与 ADR-0006（两端各自实现）有张力**，建议单列 ADR 再评估。

8. **NAS 归档：事件片段写 NAS（SMB/WebDAV），Jellyfin 里能回看。**
   我们已经有 NAS 只读镜像与运维文档；把"事件片段"当媒体库是最自然的融合。**不冲突**。

---

## 9. 本次未验证 / 不确定

| 项 | 状态 |
| --- | --- |
| `msgClose` 能把会话回收从"1 分钟+"降到 ~20 秒 | 未实测（需要真机 + 自建二进制）；上游注释如此，我们的旧实测是反例 |
| `StartMedia("both")` 与 `flags & 0x1400000` 在 061a01 / 72ac1 上是否成立 | 未实测；micam 只在 CW100 双镜头验证 |
| `audio=1` 后 061a01 的音频编码（PCMA/Opus）与 fMP4 封装兼容性 | 未实测 |
| HKSV 参数（4s GOP / 4s 分片）在 HomeKit 真机的表现 | 未验证（无 Apple Home 环境） |
| Home App 通知缩略图的确切行为 | 【推断】，依据 HAP 服务与 Scrypted 实现，未实测 |
| `ha_xiaomi_home` 是否会在未来版本加 camera 平台 | 未查到路线图；截至 v0.5.0 无 |
| `VictorCV-DAM/...` 宣称的 <200ms 与本地 PTZ | 仅搜索摘要，未读源码 |

---

## 10. 来源清单

**go2rtc（master `8eee2d4`，2026-11-23；tag `v1.9.15` 对照）**
- source 注册表：`internal/streams/handlers.go:12-18,52-70,96-110`
- 模块表与白名单：`main.go:63-119`、`internal/app/app.go:83-89`
- producer 状态机与按需启动：`internal/streams/producer.go:112-160`、`internal/streams/preload.go:1-60`
- 无消费者停源：`internal/streams/stream.go:97-121`
- 小米凭证与 vendor：`internal/xiaomi/xiaomi.go:110-216`、`internal/xiaomi/README.md`
- MISS 命令表/画质/对讲：`pkg/xiaomi/miss/client.go:84-103,150-190,205-240`、`pkg/xiaomi/miss/backchannel.go:1-74`、`pkg/xiaomi/miss/producer.go:55-105,145-190`
- CS2 传输：`pkg/xiaomi/miss/cs2/conn.go:109-175,195-202,204-215,493-530`
- 输出格式：`www/README.md:43-47`、`README.md:360-370`、`internal/hls/README.md:5-6`、`internal/hls/session.go:26-32`、`internal/mp4/mp4.go:25,83,132`、`internal/mjpeg/mjpeg.go:27`
- 上游状态：`https://github.com/AlexxIT/go2rtc/pull/2531`（open，updated 2026-11-16）、`https://github.com/AlexxIT/go2rtc/issues/2162`（open）、releases API：latest = `v1.9.15`（2026-10-25）

**Frigate（`8c88754`，2026-11-22）**
- review/alert 模型：`frigate/review/types.py:4-6`、`docs/docs/configuration/review.md:14-32`
- 快照配置与 API：`frigate/config/camera/snapshots.py:21-45`、`frigate/api/media.py:961,1904,1963,2009`、`frigate/review/maintainer.py:41-42,80-100`、`frigate/const.py:147`
- 通知载荷：`docs/docs/integrations/mqtt.md:33-90,212-260`
- restream 与角色：`docs/docs/configuration/restream.md:20-70`
- PTZ 自动跟随：`frigate/ptz/autotrack.py:355-420,520-600,592-626`

**Scrypted（`3507b61`，2026-11-20）**
- 接口与 Mixin：`sdk/types/src/types.input.ts:474-478,545-560,712,2208-2212`
- 预缓冲：`plugins/prebuffer-mixin/src/main.ts:30,719-740,750-770,776-800`
- HKSV：`plugins/homekit/src/types/camera/camera-recording.ts:24,130,163-200`、`plugins/homekit/src/types/camera.ts:150-180`、`plugins/homekit/src/types/camera/camera-secure-video.ts:75-76,149`、`plugins/homekit/README.md:5-40`

**HomeKit（HAP-NodeJS `74b1700`，2026-11-20）**
- 门铃服务：`src/lib/definitions/ServiceDefinitions.ts:457-475`
- 摄像头操作模式：`:241-258`；事件快照特征：`src/lib/definitions/CharacteristicDefinitions.ts:1235-1252`
- 快照请求与 reason：`src/lib/camera/RTPStreamManagement.ts:401-415`

**Home Assistant frontend（`9eb51a8`，2026-11-22）**
- 静帧刷新与可见性：`src/panels/lovelace/components/hui-image.ts:29,55,107-109,370-475`
- 卡片：`src/panels/lovelace/cards/hui-picture-entity-card.ts:60,212-218`
- 播放器选择：`src/data/camera-streams.ts:28-100`、`src/components/ha-camera-stream.ts:199-235`、`src/components/ha-hls-player.ts:364-376`

**AlexxIT/WebRTC（`6471e00`，2026-10-15）**
- 模式选择：`custom_components/webrtc/www/video-rtc.js:39,331-381`
- 可见性/画中画：`custom_components/webrtc/www/webrtc-camera.js:13-16,536-545`
- 数字 PTZ：`custom_components/webrtc/www/digital-ptz.js:1-40`

**小米**
- miloco：`https://github.com/XiaoMi/xiaomi-miloco`（HEAD `b1887aea`，2026-11-18）、`knowledge/03-features/live-camera-view.md`（2026-11-23 读取，`:26-31` 能力边界）
- `ha_xiaomi_home`：`75b3acb`（v0.5.0，2026-09-28），releases API 确认最新
- `hass-xiaomi-miot`：`8ac4df7`，`custom_components/xiaomi_miot/camera.py:180-275,453-510`

**2026 新项目**
- `https://github.com/kaivyy/micam`（`dad0965`，2026-11-19）：`patches/go2rtc-v1.9.15-shared-session.patch:300-495`、`recorder.py:1-60`、`docs/ARCHITECTURE.md:60-130`
- `https://github.com/willjayyyy/ha-xiaomi-camera`（`73ce5fd`，2026-08-13）：`addon/requirements.txt:1-12`、`addon/Dockerfile:1-15`、`addon/rootfs/app/bridge/streaming.py:79-130`、`addon/rootfs/app/bridge/stills.py:1-40`、`docs/ARCHITECTURE.md:7-60,285-300,370-382`、`README.md:276-292`
- 【检索】`https://github.com/perseus177/ha-imilab-ec2`、`https://github.com/VictorCV-DAM/ha-xiaomi-imilab-camera-liberator-webrtc`、`https://github.com/eugeneRover/micam`（GitHub 搜索 2026-11-23）

**仓库内（MenuBarHome）**
- 桥与转封装：`Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift:257-347,555-582,1325-1355,1100-1130`
- 取流链：`Sources/MijiaCore/MiCloud/MiCloudProvider.swift:2070-2270,2286-2300`
- 播放器：`Sources/MenuBarMijiaApp/CameraLiveVideoPlayer.swift:186-380`、`CameraLivePlayback.swift:1-160`
- 面板/保活/门铃：`Sources/MenuBarMijiaApp/CameraLivePanelController.swift:69-70,148-160,299-330,745-800`
- 交接规则：`Sources/MijiaCore/CameraLiveHandoff.swift:1-103`
- 门铃模型：`Sources/MijiaCore/DoorbellRing.swift`、`HomeStore+Doorbell.swift`
- 通知：`Sources/MenuBarMijiaApp/HotkeyAndNotificationManager.swift:623-700,780-805`
- 能力表/镜头：`Sources/MijiaCore/CameraPTZ.swift`、`Sources/MijiaCore/MiCloud/CameraLensCatalog.swift`、`CameraHubCatalog.swift`
- HA 取流：`Sources/MijiaCore/HomeProvider.swift:928-995`
- Windows：`windows/src-tauri/src/camera.rs:71-78,82-95,404-412`、`windows/src/ui/cameraLive.ts:185-199,487-497,1073-1100`、`windows/src/core/homeAssistant.ts:686-698`、`docs/agents/windows-camera.md:1-41`
- 既有调研：`docs/research/camera-ptz-compatibility.md`、`docs/research/issue-97-camera-support.md`

---

**摘要（5 行）**

1. 最有价值的三条建议：给自建 go2rtc 补 `msgClose`（断流即释放会话，重连从"一分钟"回到"秒级"）；门铃/事件走"系统通知 + 事件快照"而不是只弹窗；把 PTZ/镜头/画质三张能力表合并成数据文件，两端共用。
2. 双镜头同会话（micam 的 `&shared=1`）与音频/对讲（`0x10B/0x10D`、`0x106/0x108`）是协议层已经具备、我们尚未使用的两块能力；前者需要真机验证，后者是产品选择而非技术限制。
3. 多厂商接入不需要插件框架：照 go2rtc 的注册表 + `app.modules` 白名单做，先把"厂商"收敛成 scheme 表，再谈 ONVIF/RTSP。
4. 报告路径：`docs/research/2026-11-23-deep-dive/15-camera-streaming.md`。
5. 未验证项已单列在 §9（`msgClose` 提速、双镜头共享、音频封装、HKSV 真机表现）。
