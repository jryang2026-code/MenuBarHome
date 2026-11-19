# ADR-0008：Home Assistant 与米家云端双源并行连接与整卡级去重合并

日期：2026-10-31　状态：已接受（更新 [ADR-0002](0002-xiaomi-cloud-direct-backend.md) 的互斥单选约定）

## 背景

ADR-0002 引入了 `HAWebSocketProvider` 与 `MiCloudProvider` 双后端，但当时采用的是互斥二选一模式：用户在设置里选了 Home Assistant 就断开米家云，选了米家云就断开 Home Assistant。

真实用户反馈表明，大量深度用户同时使用两端：
- 一部分设备（如小爱音箱的 TTS 播报与文本指令、Wake on LAN、第三方 Zigbee/HomeKit 设备）在 Home Assistant 上控制能力更完整、局域网 WebSocket 响应更快；
- 另一部分米家新型号或未接入 HA 的设备在米家云端直连中才能识别，且当用户携带 Mac 离开家庭局域网导致 HA 不可达时，米家云端仍可远程控制。

若只是简单把两边设备列表相加，同一台物理设备会出现两张重复卡片；若把两边字段强行拼进同一张卡片混发指令，乐观锁、撤销快照与状态回读会在两个不同步的数据源之间产生竞态撕裂。

## 决定

1. **自动双源并行（macOS 端）**：设置页同时开放 Home Assistant 连接配置与米家账号扫码登录；只配置一端时单源运行，两端均已配置凭证时由组合层并行维护两条数据流并自动合并（无需额外手动切换“合并模式”开关；演示模式仍为独立离线沙盒）。Windows 端支持 Home Assistant、米家云与演示模式三选一单源切换，暂不执行本 ADR 的跨源合并；本地缓存按连接源、规范化地址与凭据指纹隔离。
2. **多级同一性匹配（Join Key）**：
   - **一级（硬件标识精确匹配）**：解析 HA 设备注册表 `HADeviceEntry` 的 `identifiers` 与 `connections`（及实体 `unique_id`），优先匹配官方 `xiaomi_home` 的 `<server>_<did>`、`xiaomi_miot` 的裸 `did`、以及归一化后的设备 `MAC` 地址。
   - **二级（同房同款唯一兜底）**：对未命中硬件标识的设备，若归一化后的同一房间（`RoomArea`）内两边各仅有唯一一台相同 `model`（或相同归一化名称）且相同 `DeviceKind` 类别的设备，自动归并为同一物理设备；同房间存在多台同款同名设备时不猜测合并。
3. **整卡级择优胜出（不跨源拼合单卡控制流）**：
   - 对匹配为同一物理设备的两份候选 `SmartDevice`，按 `Sources/MijiaCore/DeviceDeduplicator.swift:preferredCandidate`（L627-654）的顺序选出唯一胜出卡（或遵从用户在卡片右键菜单设定的单设备固定来源覆盖）：
     1. **在线优先**（`ha.isOnline != mi.isOnline`）：一边在线、一边离线（或整端未连接）时，直接选用在线方，实现在家走 HA、出门 HA 断连自动无缝回落米家云；
     2. **热水器专卡优先**（`.appliance` vs `.climate`，`#300`）：同一台热水器在一端合成出保留模式、故障与剩余时间的 `.appliance` 卡片，而另一端仅为通用 `.climate` 卡片时，优先选用 `.appliance` 卡片；
     3. **可播放实时画面摄像机优先**（`hasLiveView`，`#266`）：摄像机卡片一端具备可打开的实时画面（米家云端固定可通过本地 go2rtc 小米桥接播放，或 Home Assistant 具备非空 `streamEntityId` / `snapshotPath`）而另一端无流可用时，优先选用可播放实时画面的一方；
     4. **可控能力评分优先**（`capabilityScore`）：按合成后 `SmartDevice` 暴露的可控特性与读数项数量（如音箱 TTS/指令能力、灯光色温/灯效、空调风速/摆风、插座功率/电量等）打分，分高者胜出；
     5. **同分 Home Assistant 优先**：能力分相同时优先选用局域网低延迟的 Home Assistant。
   - **房间与名称互补**：默认采用胜出方的名称与房间；若胜出方未分配房间（落入默认/未分配）而另一方有明确房间，自动借用另一方的非空房间归属。
   - **单源指令路由**：每张合成卡片在任意时刻完整绑定当前胜出方的 `HomeProvider` 下发控制指令与生成撤销逆操作，不在单张卡片内混发跨源指令。
4. **跨源统一稳定主键（Canonical ID）**：
   - 配对成功的双源设备固定使用统一稳定主键（优先锚定跨源配对键），使星标常用、自定义排序、每页卡片大小（`TileSize`）、自定义分组与本地重命名别名在 HA 与米家云相互回退切换时完全保留。
5. **界面克制**：卡片正面不增加来源角标；底部状态栏展示双源连接状态，已配对卡片在右键菜单展示当前驱动来源并允许手动固定为 HA 或米家云。

## 后果

- 用户无需在“HA 功能全”和“米家云免折腾/可外网兜底”之间二选一，配置两端即可自动获得去重后的最优设备集。
- 整卡单源路由保证了现有 `HomeStore` 的 3 秒乐观锁、逆向指令撤销和批量操作语义无需重写。
- 需要在 `MijiaCore` 新增纯函数式的双源去重合成器与组合 `HomeProvider` 路由层，并在 `HADeviceEntry` 补齐 `identifiers` 与 `connections` 解码。

## 修订（2026-11）

- `Sources/MijiaCore/DeviceDeduplicator.swift:preferredCandidate`（L627-654）在“在线优先”之后、“`capabilityScore` 评分”之前新增两项专项裁决：热水器 `.appliance` 卡片优先于通用 `.climate` 卡片（`#300`），以及具备可播放实时画面的摄像机（`hasLiveView`）优先于无流摄像机（`#266`）。
- Windows 端已同步落地双源并行连接与整卡去重合并（`windows/src/core/dualSourceProvider.ts`），与 macOS 共享同一套配对与胜出语义。
- **配对卡偏好合并（#24）**：第 4 条的“主键稳定”只覆盖了单侧历史（米家老用户后来接入 HA 时规范 ID 选择会偏向已有偏好的那侧）。当两侧都存过历史（先只用 HA、后只用米家、再双源并行）时，落选一侧的隐藏、收藏、别名、磁贴偏好会指向一个不再出现的 ID。现在合并结果会随快照报告 `preferenceAdoptions`（规范卡 ID → 落选源 ID），macOS `HomeStore` 与 Windows 端 layout 把孤儿侧偏好合并到规范卡上：隐藏优先保持隐藏，收藏取并集（排序槽位跟随孤儿侧），别名与磁贴仅在规范侧没有明确设置时拷贝；孤儿条目保留在磁盘上，回到单源模式仍然生效。每一对（规范 ID、孤儿 ID）只合并一次：macOS 在偏好写完之后才把已完成的对写成扁平字符串数组 `dual_source_adopted_preference_pairs_v1`（`规范 ID + U+001F + 孤儿 ID`，`stringArray(forKey:)` 原样读回，不依赖重启后的桥接转换；上一版写下的字典形态仍会读取并在下次合并时改写为扁平形态），Windows 把 `adoptedPreferencePairs` 与合并结果写进同一份 layout；之后用户在规范卡上的取消隐藏、取消收藏、清空别名、改回磁贴都算数，孤儿条目不会再把它们改回去。即使在写入记录之前崩溃，重启后的重跑也只是并集或“缺失才拷贝”，不会多出任何东西；若记录存在却无法解析，则不合并（把无法读取当成空表会重新覆盖用户已经清除的偏好）。
- **回退磁滞（#25）**：第 3 条的“在线优先”原按任一来源断线的瞬时状态立即翻转胜出者，Wi-Fi 漫游、唤醒重连或 WebSocket 抖动会让配对卡来回切换并杀掉正在观看的直播。现在 `DualSourceHomeProvider` 对持有快照的来源以及 `MiAccountsProvider` 账号级瞬断（恢复前暂保断线前设备鲜活态，设置页与状态栏照常显示真实连接/账号状态）统一引入 `sourceFallbackGrace`（15 秒）磁滞窗口，并采用 `SuspendingClock` 与 `PollingContext.systemActive` 休眠冻结计时，避免跨系统睡眠导致唤醒瞬间误翻转；窗口耗尽仍断线才采用回退并明确停掉失效来源的流，由既有的失败/重试界面提供恢复。凭据失效（`sessionExpired`）、快照清空（`invalidateSnapshot`）与来源替换不受窗口保护，立即生效。纯函数合并器与 Windows 合并契约不变；Windows 协调器在单次拉取失败时仍整体丢弃该侧快照，等价磁滞需另行跟进。
