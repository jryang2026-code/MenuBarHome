# MenuBarHome Glossary

macOS 菜单栏与 Windows 托盘智能家居控制中心领域词表；代码、Issue、PR 与测试统一使用以下正名，避免同义词混用。

## Language

### 核心领域实体

**SmartDevice（逻辑设备）**：
面板中展示与操控的最小设备单元，由同一物理设备下的多个 Home Assistant 原始实体或 MIoT 服务属性聚合而成。
_Avoid_: Entity（原始实体）、Widget（小组件）、Accessory（配件）

**RawEntity（原始实体）**：
底层数据源暴露的单点状态或动作寻址接口（HA `light.*` / `sensor.*` 或 `miot:<did>:<siid>`），仅在同步与控制边界使用，不直接暴露给 UI。
_Avoid_: Device（设备）、Card（卡片）

**DeviceSynthesis（设备合成）**：
将 HA 注册表/状态表或米家云端设备列表/MIoT 属性折叠为 `SmartDevice` 列表与 `EnvironmentReading` 的纯函数转换过程。
_Avoid_: Data mapping（数据映射）、Parsing（解析）

**HomeBackend（连接后端）**：
驱动 `HomeStore` 的底层数据源（macOS 支持 HA `HAWebSocketProvider` 与米家云端 `MiCloudProvider` 单源或双源自动合并及 `DemoHomeProvider`；Windows 为互斥单选）。
_Avoid_: Server type（服务器类型）、Mode（模式）

**HomeBackendDescriptor（后端描述）**：
每个 `HomeBackend` 枚举值对应的集中描述表条目（显示名、是否已配置、连接源标识、provider 工厂），由穷尽 `switch` 保证完备，不是运行时插件扩展点（ADR-0020）。
_Avoid_: Plugin（插件）、Registry（注册表）

**RaycastSnapshot（伴生快照）**：
写到 `~/Library/Application Support/MenuBarMijia/raycast-snapshot.json`（`0600`）的只读状态与 `lastCommandFeedback`，供 `raycast/`、`scripts/mijia` 与 `scripts/mijia-mcp` 检索使用，隔离真实凭据，受 `currentSchemaVersion` 契约保护。
_Avoid_: 缓存文件、数据库

**BridgeToken（伴生令牌）**：
随伴生快照生成、用于 `menumijia://` 常量时间免二次确认的本机随机令牌；关闭集成即作废，对 MCP 返回结果一律剥离。
_Avoid_: API Key、密码

**LocalNetworkEndpoint（局域网端点）**：
不离开本机或家庭网络的地址（回环、私有/Tailscale 网段、`.local`/`.lan`/`.home.arpa`/`.internal`、无点单段主机名，ccTLD/`xn--` 除外）；凭据只发给 HTTPS 或局域网端点，其余 HTTP HA 须逐一经用户明文确认。
_Avoid_: Intranet（内网）、Trusted host（可信主机）

**DeviceDeduplication（跨源设备去重合并）**：
HA 与米家云端同时生效时，按硬件标识或同房间唯一同款/同名匹配物理设备，按「在线 → 可控分 → 同分 HA 优先」选出主驱动源的纯函数合并。
_Avoid_: Cloud sync（云同步）、Entity bridge（实体桥接）

**deviceBackends（卡片数据源表）**：
`DeviceDeduplicator.merge` 为结果中每张卡片记录的当前驱动源（演示模式为空；后插入的 LG 电视回退至 `homeBackend`）。
_Avoid_: activeBackends、pinnedDeviceSources

**MiSession（米家云端会话）**：
通过扫码登录持久化在钥匙串中的 `userId`、`ssecurity`、`serviceToken` 与区域凭证，用于签名与 RC4 传输加密请求 `/app/*`（服务器可读明文，非端到端加密）。
_Avoid_: Token（令牌）、Cookie（网页凭据）、End-to-end encryption（端到端加密）

**MiAccount（米家账号）**：
单区域 + `userId` 标识的一组小米账号凭据，支持多账号并存、合并展示与按账号分组。
_Avoid_: Session（会话）、Profile（账号配置）、Home（家庭）

**MiotSpec（MIoT 设备规格）**：
`miot-spec.org` 定义的 `siid/piid/aiid` 元数据模型，按型号本地缓存，驱动米家设备合成与指令映射。
_Avoid_: Schema（模式）、Profile（配置表）

**MiotFacet（通用控件）**：
按「格式 + 读写」从 `MiotSpec` 自动合成的辅助控件，携带 `siid.piid`/`siid.aiid` 标识、风险等级与高价值标记，规则表存于双端共读的 `deviceProfiles.json`。
_Avoid_: Widget（小组件）、Generic control（泛指控件）

**MoreSettings（更多设置）**：
详情抽屉内由 `FacetControl` 渲染的辅助控件区（高价值在前，其余默认折叠，高风险写须设置授权；HA 实体的辅助控件走各自域 service）。
_Avoid_: Advanced panel（高级面板）、Extra controls（额外控件）

**RoomArea（房间区域）**：
物理空间划分（如客厅、书房、卧室），以 HA 区域注册表或米家家庭房间为准并归一化。
_Avoid_: Zone（防区）、Group（分组）

**CoverDevice（开合类设备）**：
按风险分窗帘类、开窗器（开需确认）、车库/大门（开关均确认）、晾衣架四类；多轨电机按服务拆分为独立卡片。
_Avoid_: Window（作总称时）、Curtain（作总称时）

**HumidifierDevice（加湿器卡片）**：
HA `humidifier` 实体合成的卡片（电源、模式、目标湿度与当前湿度读数）。
_Avoid_: Humidifier fan（加湿风扇）

**ValveDevice（阀门卡片）**：
HA `valve` 实体合成的开/关卡片（开启水/气阀须确认，不参与默认「全关」）。
_Avoid_: Switch card（开关卡）

**CameraLens（摄像机镜头）**：
双摄摄像机在机型能力表或名称明确标识双摄时提供的视频通道切换（默认通道 vs 非零 `channel`）。
_Avoid_: Camera source（视频源）、Stream profile（流配置）

**ApplianceDevice（家电卡片）**：
热水器、洗衣机、烘干机、洗碗机、浴霸与油烟机共用的规格驱动家电卡（状态/剩余时间/模式/目标温度及起停确认规则）；主副服务声明见 `deviceProfiles.json` `appliances` 表。
_Avoid_: Washer card（洗衣机专用卡）、Kitchen appliance（厨房家电专用卡）

**GenericDeviceCard（通用兜底卡片）**：
无专用合成器但可通过 `MiotFacet` 展示至多两项读数 + 低风险开关或只读状态，并按设备家族规则标红告警的卡片；不参与「全关」。
_Avoid_: Unsupported card（不支持卡片）、Fallback tile（兜底磁贴）

**FamilyOverride（设备家族覆盖）**：
`deviceProfiles.json` `overrides` 中的通配符/类型级补充规则（主读数、高亮优先表、`keepInNoisyServices`、投喂动作与告警词表），双端共读。
_Avoid_: Model table（型号表）、Hardcoded card（写死卡片）

**FeedAction（按份投喂）**：
鱼缸与喂食器的 `pet-food-out` 动作：抽取可选份数范围并在二次确认后直接下发，不进撤销横幅。
_Avoid_: Snack button（零食按钮）、Quick feed（快捷投喂）

**HomeOption（米家家庭）**：
小米账号下由 `homeroom/gethome` 返回的独立家庭空间，支持单家庭与全部分合并视图。
_Avoid_: Workspace（工作区）、Account（账号）

**SplitDevice（多键分键设备）**：
多键墙壁开关拆分出的独立按键记录（`<parentDid>.s2`，携带 `splitParentDid` / `splitSiid`），隐藏父面板并以父 `did` + 子 `siid` 寻址。
_Avoid_: Sub-entity（子实体）、Virtual plug（虚拟插座）

**EnvironmentReading（环境读数）**：
按「独立传感器 → 空气净化器 → 空调室温」优先级提取并展示的实时温湿度指标。
_Avoid_: Weather（天气）、Telemetry（遥测）

**WeeklyHealthReport（家庭健康周报）**：
纯本机历史数据汇总的用电、温湿度区间、低电量/耗材及离线设备摘要（`OfflineHistory` 保留 14 天）。
_Avoid_: Analytics（统计）、Telemetry（遥测）

### 控制与偏好

**Scene（场景）**：
HA 中预定义的 `scene.*`/`script.*` 一键联动动作，面板仅触发不编排。
_Avoid_: Automation（后台自动化规则）、Macro（宏）

**QuickAction（内置快捷动作）**：
按设备类别实时聚合的一键批量领域指令，提供按设备数计时的撤销横幅（1–2 台 10s，3+ 台 15s）与 10 分钟助手回滚。
_Avoid_: Local scene（本地场景）、Custom script（自定义脚本）

**AllOffTarget（全关目标）**：
当前视图内开启中且允许参与「全关」的 `SmartDevice` 集合（插座、扫地机、摄像机等默认不加入，支持单设备覆盖；通用卡不可加入）。
_Avoid_: All devices（全部设备）

**DeviceListCut（房间或类型筛选）**：
内存态一次性筛选（全部 / 单房间 / 单设备类型），不写入磁盘且不改写房间计数/磁贴尺寸基准。
_Avoid_: IntentDeviceCategory（意图设备大类）、Persistent filter（持久筛选）

**IntentPlan（意图执行计划）**：
自然语言经 `LocalIntentParser` 或 `ModelIntentResolver` 解析生成的 `[DeviceIntent]` 与反馈文案。
_Avoid_: Prompt output（模型输出）、Action script（动作脚本）

**BareCategoryCommand（裸类别指令）**：
仅含类别与动作、未指定房间/设备的指令（按开/关状态、当前显示房间与习惯候选收敛；无界面入口遇歧义不执行）。
_Avoid_: Ambiguous command（模糊指令）、Whole-home command（全屋指令）

**ScheduledCommand（定时指令）**：
带绝对 `fireDate`、`IntentPlan` 与创建时 `sourceScopes` 的本地延时任务（`assistant_scheduled_commands_v1`）；跨启动/睡眠超时转入 `missedScheduledCommands` 等待人工确认，绝不后台静默触发过期动作。
_Avoid_: Background job（后台任务）、Cron（计划任务）

**ActiveDevice（活跃开启设备）**：
在线且正处于运行/开启状态的受控设备（不含冰箱、待机电视、纯传感器与打开状态的开合设备）。
_Avoid_: Online device（在线设备）

**CompactTile（双列紧凑磁贴）**：
双列紧凑网格卡片；展开详情抽屉时瞬时扩为整行（12 列）宽度。
_Avoid_: Mini card（迷你卡片）、Widget（小组件）

**ActivityStack（通知中心）**：
面板头部折叠展示（最多露 3 层）的系统提醒、主动守护与门铃记录；切换后端即清空本机告警记录。
_Avoid_: Reminder cycle（提醒轮播）、Toast（瞬时提示）

**TransientStack（瞬时横幅栈）**：
面板底部共用的撤销与 Toast 浮层，与通知中心共享 `StackedCardGeometry`，悬停展开并暂停撤销倒计时。
_Avoid_: Activity feed（持久提醒集合）、Single banner（互斥横幅）

**SafetyAlert（主动守护提醒）**：
macOS 原生风险通知（插座高功率长开、空调长开、低电量、星标离线及可单独开关的传感器边沿告警；危险传感器报警期间图标变红）。
_Avoid_: Alarm（警报）、Push notification（远程推送）

**ProactiveSuggestion（猜你想控推荐）**：
基于习惯记忆（ADR-0009）、环境与在线设备生成的可执行 Top-4 候选推荐。
_Avoid_: Static shortcut（静态快捷方式）、Random tip（随机提示）

**pendingSuggestions（待点建议）**：
Windows 命令栏内等待用户点击执行的计划/确认芯片（`bare:on`/`off`、`confirm:*`），与 `aiProactiveSuggestions` 分离。
_Avoid_: ProactiveSuggestion（猜你想控）、assistantSuggestions（macOS 命令栏）

**GrokBall（AI 情绪表情球）**：
随连接、语音与执行状态切换表情的自由拖动球面组件（macOS 支持按方位外扩胶囊；Windows 侧挂纵向推荐）。
_Avoid_: Static icon（静态图标）、Chatbot avatar（聊天头像）

**LightGroupFold（米家灯组折叠）**：
启用 `hideGroupedLights` 时在展示层隐藏已归属 `group.*` 灯组的单灯，搜索、场景与全关仍计入成员灯。
_Avoid_: DeviceGroup（本地自定义分组）、Room grouping（房间分组）

**RoomOrderDraft（房间排序草稿）**：
房间与类型胶囊排序会话的内存草稿，隐式退出即合并落盘（`room_custom_order` / `kind_custom_order`），`Esc`/取消回滚。
_Avoid_: Room order、Layout edit

**PanelEditMode（面板编辑模式）**：
面板唯一的三态编辑状态（`none` / `deviceLayout` / `roomOrder`），统一键盘与视图状态。
_Avoid_: isEditingLayout / isEditingRooms

**内容井（well）**：
减弱透明度或 macOS 14/15 Material 下的半透明卡片基底（`PanelDesign.swift:TileSurface.fill`），与 macOS 26 原生 `.glassEffect` 互斥。
_Avoid_: Platter（白色底板）、Card background（卡片底色）

**高光边（Specular Rim）**：
玻璃内缘立体折射描边（macOS `ThemeAndMotion.swift:specularRim`；Windows `.cc-rim`）。
_Avoid_: Border、Hairline

**ViewPreference（本地视图偏好）**：
仅作用于本机的置顶、分组、排序、磁贴尺寸、隐藏、面板高度/主题/位置及菜单栏常驻指标，不回写远端数据源。
_Avoid_: Device config（设备配置）、Profile（档案）

**NativeBackdrop（原生背景）**：
Windows DWM 绘制的 Mica/Acrylic 背景（`data-backdrop="acrylic"` / `none`），区别于 WebView 内模糊与透明度调节。
_Avoid_: 玻璃皮、壁纸透出
