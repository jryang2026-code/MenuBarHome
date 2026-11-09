# ADR-0019：定时任务记录创建时的连接源集合

日期：2026-11-09　状态：已接受

## 背景

`ScheduledCommand` 只保存 `fireDate` 与已解析的 `IntentPlan`，不记这条定时是在哪个家庭 / 账号 / 数据源上创建的。用户在 Home Assistant A 上设了「10 分钟后关灯」，切到家庭 B 或另一个米家账号后，定时仍按时间触发，目标 id 在新家庭里不存在，于是安静失败；恢复旧的列表保存时又会把别的作用域里的条目一起删掉。Windows 端已经用 `ScheduledCommandStore` 按连接身份分队列，macOS 没有对应机制。

早期实现让整条定时只记一个「主作用域」，又试着按每个设备的目标反推来源。前者会让双源 / 多账号里的定时绑死在第一个源上，后者在 `startListening()` 清空 `deviceBackends`、旧设备仍留在列表里的窗口里会猜错来源，LG 电视这类没有 `deviceBackends` 条目的设备也会被永久拒绝。改成记录创建时的全部连接源，匹配时看集合关系，不再逐设备判断归属。

## 决定

1. **持久化记录连接源集合**：`ScheduledCommand` 新增可选字段 `sourceScopes: [String]?`，写入 `schedule(_:after:)` 当时 `HomeStore.activeConnectionScopes` 的排序副本，即 `demo` / `ha:<url>` / 每个已登录米家账号。旧字段 `sourceScope: String?` 继续解码，新条目也写主作用域，便于降级与旧测试；条目的有效作用域是 `sourceScopes ?? sourceScope.map { [$0] } ?? nil`。键名仍是 `assistant_scheduled_commands_v1`，两种旧 JSON（只有 `sourceScope`、两个字段都没有）都能正常解码。
2. **一条请求一条定时**：不在 `schedule` 里按目标拆条，混合来源的计划仍是一次执行、一次撤销记录，目标在触发时缺失由第 8 条兜底。这样撤销横幅和「撤销上一步」覆盖整条请求，不会被后执行的半条覆盖。
3. **唯一的匹配规则**：`HomeStore.sourceScopesMatch` 同时服务触发前检查、`restoreScheduledCommands` 与 `runMissedScheduledCommand`。规则是盖章集合与 `activeConnectionScopes` 必须有交集；并且当前连接里的每一个 `ha:` 都必须出现在盖章里——任何现在连上的 Home Assistant 都必须是创建这条定时时已经见过的。原因是定时目标存的是合并卡片 id，一个创建时不存在的 HA 也可能认领同一个 id，所以不能只否决「不同的 HA」。只移除 HA（没有接入新的）时集合仍然相交，米家定时继续运行。
4. **只武装和展示匹配的条目**：`scheduledCommands` / `missedScheduledCommands` 是匹配条目的视图；其余条目放在 `foreignScheduledCommands`，每次保存写回 `scheduledCommands + missedScheduledCommands + foreignScheduledCommands`，因此当前连接的保存不会删掉别家的定时。
5. **旧条目一次性认领**：`restoreScheduledCommands` 遇到有效作用域为 `nil` 且主作用域 `connectionScopeIdentifier` 已就绪时，把条目归入主作用域并随本次保存写回；主作用域未就绪则原样保留、不认领。Windows 对旧格式的处理是把无法解析的原始串备份到 `.unreadable` 键后丢弃，macOS 的数组格式仍可解析，因此选择认领而不是丢弃。
6. **切换点只有一个**：`startListening()` 在 provider 真正换好之后调用 `syncScheduledCommandScopeIfNeeded()`，`activeConnectionScopes` 集合变化时复用 `restoreScheduledCommands` 重新分区。`invalidateUndoContext()` 运行在 `switchBackend` 开头、`homeBackend` 与会话尚未更新，因此不能在那里判断新作用域。
7. **触发前再核对一次**：定时任务从 sleep 醒来、以及等完首个快照之后各检查一次匹配规则，切换刚好落在 sleep 期间时不会误跑。睡过头的条目仍走既有的 missed 流程；重新匹配上时，已过期的条目同样进入 missed 队列等待确认，不静默执行。
8. **目标不在当前家居就不执行**：选择另一个小米家庭不改变连接源集合（同账号），设备列表却整组替换。定时触发时，只要计划里任一设备 / 场景 id 既不在 `devices` 也不在 `scenes`，就走既有的 missed 流程等待确认，不执行也不消费；手动补执行遇到同样情况则拒绝、保留条目并提示目标设备不在当前家庭。没有设备目标的计划（空意图）不受影响，不会被误判进 missed。快照不完整时同样按缺失处理，保守地进 missed，这是可接受的行为。
9. **人按的手动补执行受锁屏限制**：「立即补执行」发生在当下、由人触发，先过锁屏拦截；被拒绝时不从 `missedScheduledCommands` 移除，解锁后可重试。定时器按时触发的路径保持豁免，这是 #143 的设计。补执行还会调用 `waitForInitialSnapshotIfNeeded()`：它只在 `devices` 与 `scenes` 都为空时等待，最多约 5 秒，并不保证拿到完整快照，因此目标缺失由第 8 条的检查兜底，而不是靠等待。等待结束后要按 id 重新确认条目仍在、重新核对匹配规则，再把“存在性检查、移出队列、持久化”放在一段没有 await 的连续逻辑里，最后才执行计划；两个并发的补执行只会有一个赢下该条目。
10. **先消费再执行**：定时器触发时，匹配、迟到与快照检查通过、且 `missingPlanTargets` 为空之后，先从三个分区移除该条目并持久化，再发设备请求；两步之间没有 `await`。执行途中切换数据源会从磁盘重新分区，条目若还在，切回来时会重新武装或进入 missed，同一计划就可能执行两次；取消任务句柄挡不住已经开始的非结构化设备请求。执行期间崩溃或退出会丢掉这条已消费的定时——对硬件来说漏执行比重复执行安全，这是有意的取舍。`runMissedScheduledCommand` 按同样顺序消费，两条路径一致。
11. **新快照到达前不创建定时**：`startListening()` 记录当时的 `snapshotGeneration`；`schedule(_:after:)` 要求该值已经变化，否则设备列表还是上一次连接的旧内容，盖上新的源集合会把定时引向错误的家。此时沿用「数据源尚未就绪，定时任务未创建」。演示模式与正常首次使用都会先收到首个快照，因此不受影响。例外：计划的所有目标都是 LG 局域网电视卡时跳过该检查——这些行由 LAN 客户端更新，不推进 `snapshotGeneration`；只要混入任一云端目标就仍需新快照。

## 后果

- 一条定时可以同时属于 Home Assistant 和米家：移除其中一个源，只要盖章里还有当前连接的源就会继续运行；两个源都换掉才转 foreign。
- 在 Home Assistant A 上创建、盖章包含 `ha:A` 的定时，切到 Home Assistant B 后一律不武装，即使 B 的实体 id 与 A 完全相同；切回 A 后恢复。这是无条件的保证，因为匹配规则要求当前连接的每个 `ha:` 都在盖章里，B 不在其中。
- 已知限制：接入一台创建时不存在的 Home Assistant 也会扣住这条定时，即使它的目标其实是米家设备——合并卡片 id 可能被新 HA 认领，规则无法区分；移除这台 HA 后恢复。A 换成 B 的情形同理，B 期间条目留在磁盘的 foreign 分区，不会丢。
- 只移除 Home Assistant（没有接入新的）时，盖章里的米家账号仍与当前集合相交，且当前没有 `ha:`，指向米家设备的定时继续运行。
- 新建定时必须等到 `startListening()` 之后的首个快照；切换数据源后的短暂窗口内创建会被拒绝并提示，不再把旧设备列表盖上新的源集合。计划的所有目标都是 LG 局域网电视卡时例外，因为 LG 更新不推进 `snapshotGeneration`；混入云端目标仍需新快照。
- 定时器一旦开始执行就从磁盘消失；执行期间退出或崩溃不会留下可再次执行的条目，正在进行的设备请求也可能照样完成，但不会出现第二次。
- 未登录米家且没有 HA 连接时不能新建定时（按钮/语音会提示数据源未就绪），与 Windows 的「请等待设备同步完成」一致。
- 当前不匹配的定时不显示、也不能通过「取消定时」取消；重新接上它盖章里的源后会自动武装（已过期则进入 missed），源集合匹配时该分区内的条目共享同一个存储键，条目总数没有上限，但定时本来就是少量短期数据。
