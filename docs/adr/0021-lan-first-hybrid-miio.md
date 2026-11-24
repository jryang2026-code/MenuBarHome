# ADR-0021：macOS 落地 miIO 局域网优先混合读写与云端自动回退

日期：2026-11-15　状态：已接受（取代 [0007-lan-direct-deferred.md](0007-lan-direct-deferred.md)）

## 背景

[ADR-0007](0007-lan-direct-deferred.md) 在早期修复阶段暂缓了通用 miIO 局域网直连。此后 macOS 端已完成 `LocalMiIOClient`（UDP `54321`，AES-128-CBC 加解密与设备时间戳偏移维护）及 `MiCloudProvider` 的局域网优先（LAN-first）混合读写架构落地，ADR-0007 中“不做实现”的结论已与现行代码不符，需正式记录现行边界与回退契约。

## 决定

### 1. 局域网优先混合架构（macOS）

- **协议与传输层（`LocalMiIOClient`、`MiIOPacket`、`NWConnectionMiIOUDPTransport`）**：在 `Sources/MijiaCore/MiCloud/LocalMiIOClient.swift` 中通过 UDP `54321` 端口与设备完成 hello 握手（缓存 `deviceId32`、`baseStamp` 与握手时间，TTL 120 秒），按设备 `did` 串行排队并按 MTU 安全批量（`maxBatchSize`）分片发送 `get_properties`、`set_properties` 与 `action`。
- **混合读取（`MiCloudProvider.fetchPropsHybrid`）**：轮询与单设备回读优先将符合局域网直连条件的属性键交由 `LocalMiIOClient.getProps` 并发拉取；局域网未返回的属性键（`missingKeys`）或局域网请求失败的设备自动合入 `cloudKeys`，由 `MiCloudAPI.getProps` 云端兜底补齐。
- **混合写入（`MiCloudProvider.execute`）**：控制指令经 `MiotCommandMapper.map` 映射后，优先调用 `LocalMiIOClient.setProps` 或 `callAction`；若局域网因超时或握手失败抛出可回退错误，则记录一次局域网失败并立即无缝回退至 `MiCloudAPI` 云端下发。对于非幂等的 `action` 调用，一旦 UDP 包已发出但响应丢失或请求 ID 不匹配，抛出 `MiIOError.ambiguousActionOutcome` 并触发后续状态回读，不自动重放动作，防止硬件重复执行。

### 2. 局域网直连准入边界（`MiCloudProvider.lanEndpoint`）

设备必须同时满足以下条件才启用局域网 UDP 直连，否则直接走云端：

1. 设备当前在线（`record.isOnline`），且非共享设备（`!record.isShared`，且 `did` / `miotDid` 不在 `sharedHomeDids` 中）。
2. 非多键拆分虚拟子记录（`record.splitParentDid == nil`）且非虚拟灯组（`!record.did.hasPrefix("group.")`）；多键子开关在属性读写时统一归一到父设备 `miotDid`。
3. 持有合法的 32 位十六进制设备 `token`（`MiIOPacket.validateToken(token) != nil`）。
4. `localip` 为合法的 RFC1918 私有局域网 IPv4 地址（`HADiscovery.isPrivateLANIPv4(ip)`），拒绝公网 IP、回环地址、链路本地地址与主机名。
5. 未处于连续失败冷却期：单设备连续局域网失败达到 `lanFailureThreshold` 次后进入 `lanCooldownDuration` 冷却窗口（`lanHealthByDid`），冷却期内直接走云端，当云端设备列表中的 `localip` 或 `token` 变化时立即重置健康状态。

### 3. 空响应、门锁状态清理与乐观锁安全

- **空响应与门锁状态清理（`completedKeys` / `applyPropRead`）**：miIO 与云端 `get_properties` 对返回非零 `code` 的属性会省略条目。即使局域网返回全空字典，只要请求已完成，其属性键仍计入 `completedKeys`（`lanAnsweredKeys`）并继续尝试云端补齐；若最终门锁状态属性（`door-state`）仍缺失，`applyPropRead` 会清除本地缓存的旧门锁状态，避免设备在线但保留过期的已锁/未锁断言。
- **乐观锁与回读保护（`OptimisticField` / `HomeStore` / `readBack`）**：控制写入期间由 `HomeStore` 乐观锁保护本地期望值；`readBack(deviceId:)` 仅当目标设备主服务开关或状态属性（`on` / `status`）出现在本次新鲜返回的 `freshKeys` 中时才返回 `.published`，空响应或缺失关键属性的局域网/云端回包不会提前解除乐观锁。

### 4. 双端范围划分（macOS 与 Windows）

- **macOS**：支持米家云端 + 局域网 miIO UDP（`54321`）混合直连、Home Assistant 局域网 WebSocket、LG webOS 局域网直连（`LGWebOSClient`）及摄像机局域网 P2P 中继（`XiaomiCameraBridge`）。
- **Windows**：米家正常轮询、单设备回读和控制通过 TypeScript 混合路由与 Rust miIO UDP `54321` 直连，云端补齐局域网缺失的属性。写请求发出后须收到显式回执（#457），仅在原生层能确认写请求还未发出时才回退，出现不完整回执或部分成功时安排设备状态回读。Home Assistant 局域网 WebSocket 和摄像机局域网 P2P 流媒体桥接使用各自的传输。BLE / Mesh 网关子设备在两端均受限于网关协议，维持云端或 Home Assistant 接入（见 [ADR-0016](0016-central-hub-lan-readonly-verification.md)）。

## 相关

- `Sources/MijiaCore/MiCloud/LocalMiIOClient.swift`、`Sources/MijiaCore/MiCloud/MiIOPacket.swift`、`Sources/MijiaCore/MiCloud/MiCloudProvider.swift`
- `Tests/MijiaCoreTests/LocalMiIOAndHybridTests.swift`、`Tests/MijiaCoreTests/ContractReplayTests.swift`
- [ADR-0007](0007-lan-direct-deferred.md)、[ADR-0016](0016-central-hub-lan-readonly-verification.md)
