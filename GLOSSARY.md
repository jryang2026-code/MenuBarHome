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
驱动 `HomeStore` 的底层数据源（macOS 与 Windows 均支持 Home Assistant 与米家云端单源、多小米账号聚合、双源自动合并及演示模式：macOS 为使用 `subscribe_entities` 压缩订阅的 `HAWebSocketProvider`、`MiCloudProvider` / `MiAccountsProvider`、`DeviceDeduplicator` 与 `DemoHomeProvider`；Windows 为持久化异步 WebSocket 的 `HomeAssistantClient`、连接池原生 HTTP `windows/src-tauri/src/network.rs`、`MultiAccountMiCloudProvider`、`DualSourceHomeProvider` 与 `demo` 模式；双端均支持局域网 miIO UDP 54321 直连）。
_Avoid_: Server type（服务器类型）、Mode（模式）

**HomeBackendDescriptor（后端描述）**：
`Sources/MijiaCore/HomeBackendDescriptor.swift` 为每个 `HomeBackend` 枚举值建立的集中描述表条目（`HomeBackend.descriptor`，含显示名、是否已配置、主/全量连接源标识、provider 工厂）与唯一生效后端计算（`HomeBackendDescriptor.activeBackends` / `HomeStore.activeBackends`，ADR-0020）；由穷尽 `switch` 承载，不是运行时插件扩展点。
_Avoid_: Plugin（插件）、Registry（注册表）

**CapabilityManifest（内置能力清单）**：
`Shared/capability-manifest.json` 声明连接（`ConnectionCapabilityID`）、功能（`FeatureID`）、设备类型（`DeviceCategoryID`）稳定 ID、种类、硬依赖、新装默认、启动策略、平台可用性与 `docs/capabilities.json` 映射的纯数据契约（ADR-0023），由双端封闭枚举/字面量联合穷尽解析，不含持久状态、凭据秘密或设备危险等级。
_Avoid_: Plugin manifest（插件清单）、Dynamic registry（动态注册表）

**CapabilityDeactivationVerdict（能力停用引用判决）**：
宿主在停用连接、功能或设备类型前由 `CapabilityReferenceEngine`（Windows：`capabilityReferenceVerdict.ts`）输出的纯函数判决契约（`allowed` / `requiresPauseConfirmation` / `blocked`），汇总受影响定时/自动化/快捷动作、软提示、安全保留集（`hiddenSafetyRetainedDeviceIds`）与宿主写入门（`ControlTargetGateVerdict`），由双端共读 `Tests/Fixtures/capability_selection_golden.json` 校验。
_Avoid_: Silent drop（静默丢弃）、Filter-only disable（仅过滤隐藏）

**RaycastSnapshot（伴生快照）**：
写到 `~/Library/Application Support/MenuBarMijia/raycast-snapshot.json`（macOS，`0600`）或 `%LOCALAPPDATA%\MenuBarMijia\raycast-snapshot.json`（Windows）的只读状态、脱敏 `automationStatus`、媒体/开合能力与 `lastCommandFeedback`，供 `raycast/`、随包内置的 `scripts/mijia`（含 `mijia doctor`）与 `scripts/mijia-mcp`（MCP Server 2.0：5 资源 / 17 工具）检索使用，隔离真实凭据，受 `currentSchemaVersion` 契约保护。
_Avoid_: 缓存文件、数据库

**BridgeToken（伴生令牌）**：
随伴生快照生成、用于 `menumijia://` 常量时间免二次确认的本机随机令牌；关闭集成即作废，对 MCP 返回结果一律剥离。
_Avoid_: API Key、密码

**LocalNetworkEndpoint（局域网端点）**：
不离开本机或家庭网络的地址（回环、私有/Tailscale 网段、`.local`/`.lan`/`.home.arpa`/`.internal`、无点单段主机名，ccTLD/`xn--` 除外）；凭据只发给 HTTPS 或局域网端点，其余 HTTP HA 须逐一经用户明文确认；连接前同时在双端校验 DNS 解析结果（`Sources/MijiaCore/HAPlaintextConsent.swift` / `windows/src-tauri/src/network.rs`）防范 DNS 重绑定。
_Avoid_: Intranet（内网）、Trusted host（可信主机）

**DeviceDeduplication（跨源设备去重合并）**：
HA 与米家云端同时生效时，按硬件标识或同房间唯一同款/同名匹配物理设备，按「在线 → 可控分 → 同分 HA 优先」选出主驱动源的纯函数合并，并由 `CanonicalDeviceRegistry`（`Sources/MijiaCore/CanonicalDeviceRegistryFile.swift`、`windows/src/core/canonicalDeviceRegistry.ts`、`windows/src-tauri/src/canonical_registry.rs`）持久化身份分配、显式删除墓碑与轮转备份。
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
`miot-spec.org` 定义的 `siid/piid/aiid` 元数据模型，双端从 `status=all` 索引按 `released > omitted > preview > debug` 择优获取并按型号本地缓存，叠加官方 `instance/v2/multiLanguage` 翻译缓存与声明式补丁 `Shared/specPatches.json`，驱动米家设备合成与指令映射。
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

**HumidifierSpec（加湿器卡片）**：
HA `humidifier` 实体合成的加湿器规格（`Models.swift:HumidifierSpec`，含电源、模式、目标湿度与当前湿度读数；Windows 端映射见 `haDomains.ts`）。
_Avoid_: Humidifier fan（加湿风扇）

**ValveSpec（阀门卡片）**：
HA `valve` 实体合成的开/关规格（`Models.swift:ValveSpec`；Windows 端判别见 `deviceCategory.ts:isValveDevice`），开启水/气阀须确认，不参与默认「全关」。
_Avoid_: Switch card（开关卡）

**CameraLens（摄像机镜头）**：
双摄摄像机在机型能力表或名称明确标识双摄时提供的视频通道切换（默认通道 vs 非零 `channel`）。
_Avoid_: Camera source（视频源）、Stream profile（流配置）

**ApplianceDevice（家电卡片）**：
热水器、洗衣机、烘干机、洗碗机、浴霸与油烟机共用的规格驱动家电卡（`ApplianceSpec`，含状态/剩余时间/模式/目标温度及起停确认规则）；主副服务声明见 `deviceProfiles.json` `appliances` 表。
_Avoid_: Washer card（洗衣机专用卡）、Kitchen appliance（厨房家电专用卡）

**DeviceCardView（通用兜底卡片，`GenericSpec`）**：
无专用合成器但可通过 `MiotSynthesizer.genericCard`（Windows：`synthesis.ts:genericCard`）与 `MiotFacet` 生成 `GenericSpec`、由 `DeviceCardView` 渲染展示至多两项读数 + 低风险开关或只读状态，并按设备家族规则标红告警的卡片；不参与「全关」。
_Avoid_: Unsupported card（不支持卡片）、Fallback tile（兜底磁贴）

**DeviceProfiles.Override（设备家族覆盖）**：
`deviceProfiles.json` `overrides` 中的通配符/类型级补充规则（macOS `MiotFacets.swift:DeviceProfiles.Override` 与 `MiotFacetEngine.profileOverride`；Windows `facets.ts:DeviceOverride` 与 `profileOverride`，含主读数、高亮优先表、`keepInNoisyServices`、投喂动作与告警词表），双端共读。
_Avoid_: Model table（型号表）、Hardcoded card（写死卡片）

**FeedAction（按份投喂）**：
鱼缸与喂食器的 `pet-food-out` 动作：抽取可选份数范围并在二次确认后直接下发，不进撤销横幅。
_Avoid_: Snack button（零食按钮）、Quick feed（快捷投喂）

**HomeOption（米家家庭）**：
小米账号下由 `homeroom/gethome` 返回的独立家庭空间，支持单家庭与全部分合并视图。
_Avoid_: Workspace（工作区）、Account（账号）

**splitParentDid / trackID（多键分键与多轨拆分设备）**：
多键墙壁开关拆分出的独立按键记录（`<parentDid>.s2`，携带 `MiDeviceRecord.splitParentDid` / `splitSiid` 并在 `MiotSynthesizer.specForRecord` 收窄服务）及双轨窗帘按服务拆分的独立轨道卡片（`MiotSynthesizer.plans` / `MiotSynthesizer.trackID`），隐藏父面板并以父 `did` + 子 `siid` 寻址。
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

**allOffTargets（全关目标）**：
当前视图内开启中且允许参与「全关」的 `SmartDevice` 集合（macOS `HomeStore.allOffTargets`；Windows `models.ts:allOffTargets`，插座、扫地机、摄像机等默认不加入，支持单设备覆盖；通用卡不可加入）。
_Avoid_: All devices（全部设备）

**DeviceTypeSelection（设备类型选择）**：
用户持久化的设备类型选择（全部已支持类型 / 只用灯和开关 / 自己选），存于连接选择的同一记录（`extraFields.enabledCategories`），决定面板、搜索、AI 目录与直接控制入口纳入哪些 `DeviceCategoryID`。它只裁剪可用集合，安全保留集由 `partitionCapabilityDevices` 决定；缺失即「未选择」= 显示全部。Windows 见 `deviceTypeSelection.ts` 与 `deviceTypeSelectionView.ts`（P4b-W）。
_Avoid_: DeviceListCut（一次性房间/类型筛选）、Device visibility（单台设备手动隐藏）

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

**SourceEpoch（连接源代际）**：
`windows/src/ui/sourceEpoch.ts` 中三级嵌套（`source` ⊃ `home` ⊃ `localWrite`）的连接源失效代际：`advance` 按层级向下级联（换源三级全动、换家庭动 home+localWrite、本地写只动 localWrite），异步工作用 `capture()` 取 `EpochToken` 后以 `isCurrent` / `guard`（返回 `STALE`）判弃；`ui/sourceSwitch.ts` 的 `switchSource` / `switchHome` 是仅有的换源/换家庭入口，云端同步接力用 `claimSyncRun` 领取独立于三级的 `SyncRunToken`——新一轮领取、换源或换家庭都会使其失效，本地写不会；领取本身不触碰 home 级（后台刷新不等于换了家庭）。配合双端写入保护（macOS `Sources/MijiaCore/HomeStore+ControlWrite.swift` `writeEpoch` / Windows `windows/src/core/optimisticLock.ts`），防止写入前的旧快照回弹覆盖本地新状态。
_Avoid_: 裸 revision 计数（手写自增 `sourceRevision` / `syncGeneration` / `localControlRevision`）、`invalidateSourceControl`

**ActiveDevice（活跃开启设备）**：
在线且正处于运行/开启状态的受控设备（不含冰箱、待机电视、纯传感器与打开状态的开合设备）。
_Avoid_: Online device（在线设备）

**CompactTile（双列紧凑磁贴）**：
双列紧凑网格卡片；展开详情抽屉时瞬时扩为整行（12 列）宽度。
_Avoid_: Mini card（迷你卡片）、Widget（小组件）

**ActivityStackView（通知中心）**：
面板头部折叠展示（最多露 3 层）的系统提醒、主动守护与门铃记录（macOS `ActivityStackView`；Windows `activityStackView.ts:renderActivityStack`）；切换后端即清空本机告警记录。
_Avoid_: Reminder cycle（提醒轮播）、Toast（瞬时提示）

**TransientStackView（瞬时横幅栈）**：
面板底部共用的撤销与 Toast 浮层（macOS `TransientStackView` 与 `TransientStackExpansion`），与通知中心共享 `StackedCardGeometry`，悬停展开并暂停撤销倒计时。
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

**MoodSnapshot（本地氛围快照）**：
跨数据源按房间采集的本机设备状态快照（最多 32 个，`Sources/MijiaCore/MoodSnapshot.swift`、`windows/src/core/moodSnapshot.ts`，契约见 `Tests/Fixtures/mood_snapshot.schema.json`），可通过快捷区或自定义快捷键一键还原，受锁屏、能力门与整批确认保护。
_Avoid_: Cloud scene（米家云端场景）、Preset（单设备预设）

**RoomAutoGroup（房间同品类自动分组）**：
同房间同品类（`light` / `cover` / `plug` / `fan` / `climate`）在线可控设备达到 2 台及以上时自动生成的房间控制胶囊（`Sources/MijiaCore/RoomAutoGroup.swift`、`windows/src/core/roomAutoGroup.ts`）。
_Avoid_: Custom device group（手动自定义分组）

**AssistantDiffPreview（指令变更预览）**：
语音或文本指令涉及 2 台及以上目标或任意高风险设备时，在命令栏内联展示的「当前状态 → 目标状态」预览确认卡（`Sources/MijiaCore/AssistantDiffPreview.swift`、`windows/src/core/assistantDiffPreview.ts`）。
_Avoid_: Toast（瞬时提示）

**AutomationContextStack（自动化上下文栈）**：
持久化 LIFO 状态栈（`automation_context_stack_v1`，上限 32 帧、12 小时有效期；`Sources/MijiaCore/AutomationContextStack.swift`、`windows/src/core/automationContextStack.ts`），仅记录触发自动化进入时改动的电源状态，在上下文退出且未被人工接管时恢复原状。
_Avoid_: Undo banner（手动撤销横幅）

**GenericCameraSource（只读通用摄像机）**：
用户在设置中添加的非米家网络摄像机（`rtsp` / `onvif` / `isapi` / `dahua` / `tapo`），只读实时画面（`Sources/MijiaCore/GenericCameraSource.swift`、`windows/src/core/genericCameras.ts`，共享契约 `Shared/genericCameraSources.schema.json`）。凭据存于 `generic-camera:<id>`，仅在内存中交给 go2rtc。
_Avoid_: IP camera integration（IP 摄像机集成）、ONVIF device（ONVIF 设备）

**CameraEventStore / StillWall（摄像机事件库与 2×2 静态墙）**：
7 天 / 500 条本机摄像机事件与抓拍缩略图存储（`Sources/MijiaCore/CameraEvent.swift`、`windows/src/core/cameraEventStore.ts`、`windows/src-tauri/src/camera_events.rs`），驱动最多 4 路摄像机的 2×2 静态墙，并配合 `CameraPipWatchPolicy`（`Sources/MijiaCore/CameraPipWatchPolicy.swift`、`windows/src/core/cameraPip.ts`）控制门铃/告警自动弹出画中画倒计时与固定开关。
_Avoid_: Cloud recording（云录像）

**HotkeyBinding（自定义全局热键绑定）**：
绑定到单个设备电源、场景、快捷动作或本地氛围的自定义全局快捷键（双端上限 8 组，`Sources/MijiaCore/HotkeyShortcut.swift`、`windows/src/ui/hotkeyBindings.ts`），执行路径复用面板锁屏拦截与高风险确认，macOS 附带非激活态提示浮层（`Sources/MenuBarMijiaApp/MacOSPrivacyAndHUD.swift` `HotkeyHUDController`）。
_Avoid_: Panel hotkey（主面板呼出热键）

**MediaPlaybackState（正在播放与防回跳进度态）**：
HA `media_player.*`、小米 MIoT 电视与音箱共享的四维播放态模型（`Sources/MijiaCore/MediaPlayback.swift`、`windows/src/core/mediaPlayback.ts`，配合 `MediaArtworkLoader.swift` / `ha_media_artwork` 同源鉴权封面代理与 2 秒防回跳 `MediaSeekGuard`）；仅当协议同时上报 `canSeek`、`duration` 与 `position` 时渲染可拖拽进度条，遥控键通过 `Tests/Fixtures/ha_remote_commands_golden.json` 按生态自适应映射。
_Avoid_: Fake progress bar（伪进度条）、Player widget（播放器组件）

**DDCCIDisplayController（外接显示器 DDC/CI 控制）**：
默认关闭、按需探测的原生外接显示器控制模块（macOS `Sources/MijiaCore/DDC/DDCCIDisplayController.swift` / `Sources/MenuBarMijiaApp/ExternalDisplayStore.swift`；Windows `windows/src-tauri/src/ddc_ci.rs` / `windows/src/ui/ddcDisplaySection.ts`），仅开放可回读的亮度（`0x10`）、输入源（`0x60`）、音量（`0x62`）与静音（`0x8D`），严格禁用电源关屏码 `0xD6`（见 `Shared/tvProtocolCatalog.json` 与 ADR-0026）。
_Avoid_: Monitor power switch（显示器电源开关）

**TVBridge（进程外多品牌电视桥接插件，`mbh-tv-bridge`）**：
遵循 ADR-0024 v1 与 ADR-0026 封闭命令动词表的可选独立 Go 单二进制进程（`adapters/mbh-tv-bridge/`，macOS `Sources/MijiaCore/TVBridge/TVBridgeClient.swift` / `Sources/MenuBarMijiaApp/TVBridgeStore.swift`，Windows `windows/src-tauri/src/tv_bridge.rs` / `windows/src/ui/tvBridgeSection.ts`），纯局域网运行且面板收起即停机；按 ID / MAC / 规范名执行非劫持去重，默认聚焦 `lg_webos_ssap`、`xiaomi_mitv_6095` 与 `hisense_vidaa_mqtt` 三大首发品牌。
_Avoid_: Built-in TV backend（内置电视后端）、Third-party plugin loader（动态插件加载器）

**DesktopAmbientContext（受控枚举桌面情境）**：
遵循 ADR-0015 隐私边界的纯布尔/枚举桌面状态投影（`Sources/MijiaCore/DesktopAmbientContext.swift`、`windows/src/core/assistant/desktopContext.ts`），仅允许 `inMeeting`、`externalDisplayConnected`、`focusActive`、`lateNightWork`、`mediaPlaying` 5 个受控标签进入 AI 提示词与主动推荐排序，类型层面排除窗口标题、日历标题与 Wi-Fi SSID 等自由文本。
_Avoid_: Raw OS telemetry（原始系统文本遥测）
