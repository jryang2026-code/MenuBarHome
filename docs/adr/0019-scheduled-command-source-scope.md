# ADR-0019：定时任务绑定连接作用域

日期：2026-11-09　状态：已接受

## 背景

`ScheduledCommand` 只保存 `fireDate` 与已解析的 `IntentPlan`，不记这条定时是在哪个家庭 / 账号 / 数据源上创建的。用户在 Home Assistant A 上设了「10 分钟后关灯」，切到家庭 B 或另一个米家账号后，定时仍按时间触发，目标 id 在新家庭里不存在，于是安静失败；恢复旧的列表保存时又会把别的作用域里的条目一起删掉。Windows 端已经用 `ScheduledCommandStore` 按连接身份分队列，macOS 没有对应机制。

## 决定

1. **作用域标识沿用连接作用域**：把 `syncSensorHistoryScope()` 里已算出的 `demo` / `ha:<url>` / `mi:<scope>` 提取为 `HomeStore.connectionScopeIdentifier`，传感器历史与定时任务共用同一个值，不新建身份体系。小米账号未登录时该值为 `nil`，视作「数据源未就绪」：此时不武装、不认领任何定时。
2. **持久化字段可选**：`ScheduledCommand` 新增 `sourceScope: String?`，键名沿用 `assistant_scheduled_commands_v1`。旧 JSON 没有该键时解码为 `nil`（Swift 可选字段的 `decodeIfPresent`），用户升级后不会丢掉已有定时。
3. **旧条目一次性认领**：`restoreScheduledCommands` 遇到 `sourceScope == nil` 且当前作用域已就绪时，把条目归入当前作用域并随本次保存写回；作用域未就绪则原样保留、不认领。Windows 对旧格式的处理是把无法解析的原始串备份到 `.unreadable` 键后丢弃，macOS 的数组格式仍可解析，因此选择认领而不是丢弃。
4. **只武装和展示当前作用域**：`scheduledCommands` / `missedScheduledCommands` 仍是当前作用域的视图；其他作用域的条目放在 `foreignScheduledCommands`，每次保存写回 `scheduledCommands + missedScheduledCommands + foreignScheduledCommands`，因此当前作用域的保存不会删掉别家的定时。
5. **切换点只有一个**：`startListening()` 在 provider 真正换好之后调用 `syncScheduledCommandScopeIfNeeded()`，作用域变化时复用 `restoreScheduledCommands` 重新分区。`invalidateUndoContext()` 运行在 `switchBackend` 开头、`homeBackend` 与会话尚未更新，因此不能在那里判断新作用域。
6. **触发前再核对一次**：定时任务从 sleep 醒来、以及等完首个快照之后各检查一次作用域，切换刚好落在 sleep 期间时不会误跑。睡过头的条目仍走既有的 missed 流程；作用域重新连上时，已过期的条目同样进入 missed 队列等待确认，不静默执行。
7. **人按的手动补执行受锁屏限制**：「立即补执行」发生在当下、由人触发，先过锁屏拦截；被拒绝时不从 `missedScheduledCommands` 移除，解锁后可重试。定时器按时触发的路径保持豁免，这是 #143 的设计。补执行还要等首个快照，切换数据源或重新锁屏可能落在这段时间里，所以移出队列、持久化、真正执行三步都放在等待之后，并在等待后重新校验作用域与锁屏状态。
8. **目标不在当前家居就不执行**：选择另一个小米家庭不改变连接作用域（同账号），设备列表却整组替换。定时触发时，只要计划里任一设备 / 场景 id 既不在 `devices` 也不在 `scenes`，就走既有的 missed 流程等待确认，不执行也不消费；手动补执行遇到同样情况则拒绝、保留条目并提示目标设备不在当前家庭。没有设备目标的计划（空意图）不受影响，不会被误判进 missed。

## 后果

- 切换数据源后再切回来，原来的定时还在；在其他数据源等待期间到期的定时会进入 missed 队列，不会被静默执行。
- 未登录米家且没有 HA 连接时不能新建定时（按钮/语音会提示数据源未就绪），与 Windows 的「请等待设备同步完成」一致。
- 其他作用域的定时不显示、也不能通过「取消定时」取消；要取消需先切回那个数据源。
- `foreignScheduledCommands` 与当前作用域条目共用同一个存储键，条目总数没有上限，但定时本来就是少量短期数据。
