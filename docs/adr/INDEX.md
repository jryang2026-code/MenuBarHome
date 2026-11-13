# Architecture Decision Records (INDEX)

改动架构边界或公共契约前先核对相关 ADR；与「已接受」ADR 冲突时须在 PR/交付中显式说明原因。

| ADR | 日期 | 状态 | 核心结论 |
| --- | --- | --- | --- |
| [0001](0001-ha-as-single-source-of-truth.md) | 2026-10-27 | 已被 ADR-0002 取代 | 早期的单 HA 事实源 + 本地设备合成投影决策。 |
| [0002](0002-xiaomi-cloud-direct-backend.md) | 2026-10-27 | 已接受 | 统一 `HomeProvider` 协议接入 HA WebSocket 与米家云端直连。 |
| [0003](0003-core-builds-on-linux.md) | 2026-10-27 | 已接受（已修订） | `MijiaCore` 保持仅依赖 Foundation，支持脱离 macOS 在 Linux 编译单测。 |
| [0004](0004-no-pass-token-storage.md) | 2026-10-27 | 已接受 | 不持久保存未使用的 `passToken`，会话过期重新扫码登录。 |
| [0005](0005-update-signing-trust-chain.md) | 2026-10-27 | 已接受 | 应用内自更新改用 Ed25519 清单签名 + 固定代码签名证书校验。 |
| [0006](0006-dual-platform-implementation.md) | 2026-10-27 | 已接受 | macOS Swift 与 Windows TypeScript/Rust 各自原生实现，靠共享黄金语料与双端 CI 守住一致。 |
| [0007](0007-lan-direct-deferred.md) | 2026-10-27 | 已接受 | 暂缓推进通用 miIO 局域网控制直连，仅做只读探索验证。 |
| [0008](0008-dual-source-device-deduplication.md) | 2026-10-31 | 已接受 | 支持 HA 与米家云端并行双源连接，并在整卡层级纯函数去重合并。 |
| [0009](0009-habit-ranking-algorithm.md) | 2026-11-01 | 已接受 | 习惯推荐排序按衰减、工作日/周末与动作序列对齐 Siri Suggestions。 |
| [0010](0010-multi-account-xiaomi-sessions.md) | 2026-11-03 | 已接受 | 支持保存多个独立米家账号会话、合并设备并按账号分组展示。 |
| [0011](0011-full-device-coverage.md) | 2026-11-05 | 提议 | 按控制形状建模、`MiotFacet` 通用兜底与双端共享 `deviceProfiles.json` 覆盖层。 |
| [0012](0012-releases-on-gitlab.md) | 2026-11-06 | 已被 ADR-0018 取代 | 过渡期将仓库、CI 与发布迁往 GitLab 的记录。 |
| [0013](0013-raycast-companion-contract.md) | 2026-11-06 | 已接受 | Raycast / CLI / MCP 伴生端统一走只读快照 + `BridgeToken` URL Scheme。 |
| [0014](0014-xiaomi-oauth2-mqtt-evaluation.md) | 2026-11-07 | 已接受 | 保留扫码 HTTP 直连 + HA 双后端，不迁往 `ha_xiaomi_home` 私有 OAuth2/MQTT。 |
| [0015](0015-local-first-privacy-and-diagnostics.md) | 2026-11-07 | 已接受 | 不收集远端遥测，仅提供本机脱敏诊断报告与崩溃摘要。 |
| [0016](0016-central-hub-lan-readonly-verification.md) | 2026-11-07 | 已接受 | 实测确认脱离 HA 无法局域网直连覆盖 BLE/Mesh 网关子设备。 |
| [0017](0017-homekit-third-backend-evaluation.md) | 2026-11-07 | 已接受 | 不引入原生 HomeKit 后端，HomeKit 配件通过 HA HomeKit Device 集成接入。 |
| [0018](0018-back-to-github.md) | 2026-11-08 | 已接受 | 仓库、CI 与发布正式迁回 GitHub（`MenuBarHome`）。 |
| [0019](0019-scheduled-command-source-scope.md) | 2026-11-09 | 已接受 | 定时指令记录创建时的 `sourceScopes`，按当前连接源集合过滤执行与保存。 |
| [0020](0020-backend-descriptor-table.md) | 2026-11-13 | 已接受 | 连接后端保持封闭枚举，散落分支收进穷尽描述表；Windows 补齐 `HomeProvider` 接口层。 |
