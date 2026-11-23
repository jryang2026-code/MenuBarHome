# 02 智能家居平台“插件化适配多厂商”架构深度调研：进程与沙箱隔离派

- **调研日期**：2026-11-23
- **调研范围**：智能家居平台插件化与进程/沙箱隔离架构（Homebridge + config-ui-x、ioBroker js-controller、Matterbridge、Node-RED、Home Assistant + HACS、Scrypted、Hubitat / SmartThings Edge），以及符合 MenuBarHome ADR-0020 / ADR-0023 的“进程外适配器”演进设计。
- **实际阅读仓库与 Commit**：
  - `homebridge/homebridge` @ `bd22b19`（2026-11-20）
  - `homebridge/homebridge-config-ui-x` @ `9f166ee`（2026-11-18）
  - `ioBroker/ioBroker.js-controller` @ `007fb9a`（2026-11-22）
  - `Luligu/matterbridge` @ `40b2b9f`（2026-11-20）
  - `node-red/node-red` @ `f613ba1`（2026-11-17）
  - `home-assistant/core` @ `b6d170e`（2026-11-23，稀疏检出核心框架与 `hue` 示例）
  - `hacs/integration` @ `8a54382`（2026-11-10）
  - `koush/scrypted` @ `3507b61`（2026-11-20）
  - Hubitat / SmartThings Edge：官方公开文档检索（未克隆源码）

---

## 0. 结论先行

1. **进程隔离不是“默认开”，而是用崩溃计数器 + 稳定期复位换来的生产兜底。** Homebridge 的 `ChildBridgeService` 在子进程崩溃后按 `restartCount * 10s` 退避重启、累计 `maxRestarts = 4` 次熔断，且稳定在线满 5 分钟即清零计数【源码：`homebridge/homebridge:src/childBridgeService.ts:238-251,582-617`】；ioBroker 则用 `MAX_CRASHES = 3` 与 `CRASH_RESET_TIME = 10min` 防重启风暴【源码：`ioBroker/ioBroker.js-controller:packages/controller/src/lib/controller/instances/instanceExitHandler.ts:35-38,292-356`】。
2. **共享单进程生态的最终宿命，是在核心里硬编码“第三方黑名单”。** Home Assistant 与 Matterbridge（插件层）均在宿主进程内 `import` 第三方代码，HA 不得不在 `loader.py` 中维护 `BLOCKED_CUSTOM_INTEGRATIONS` 硬编码封禁崩溃集成（如 `dreame_vacuum`、`spook`、`entsoe`）【源码：`home-assistant/core:homeassistant/loader.py:138-183`】；这从反面印证了 MenuBarHome ADR-0020/0023 拒绝进程内第三方代码的正确性【源码：`docs/adr/0023-host-owned-builtin-capabilities.md:11,19`】。
3. **跨进程边界有两种主流哲学：“状态数据库总线”与“能力接口代理”。** ioBroker 让所有适配器通过 Redis/JSONL 的 Objects/States DB 异步解耦【源码：`ioBroker/ioBroker.js-controller:packages/controller/src/lib/controller/controller.ts:203-246`】；Scrypted 则用 `RpcPeer` + JS `Proxy` + `FinalizationRegistry` 序列化标准设备接口（`ScryptedInterface`），实现了接口即能力且支持多语言/多机集群【源码：`koush/scrypted:server/src/rpc.ts:84-220`】。
4. **配置 UI 自动生成的天花板在“静态 Schema 表单 + 进程外 Custom UI”，两者必须解耦授权。** Homebridge-config-ui-x 用 `config.schema.json` 驱动表单并支持 `dynamicSchemaVersion`（带严格路径越界校验），遇到复杂登录（如 OAuth/配对）则把自定义 `server.js` fork 到独立子进程并通过严格 CSP 的 iframe 隔离【源码：`homebridge/homebridge-config-ui-x:src/modules/plugins/plugins.service.ts:1620-1639`、`src/modules/custom-plugins/plugins-settings-ui/plugins-settings-ui.service.ts:102-117,316-399`】。
5. **安装与依赖隔离的痛点是“宿主包冲突”与“原生模块 ABI 绑定”。** Homebridge 与 Matterbridge 均显式拦截插件在 `dependencies` 中捆绑宿主库【源码：`homebridge/homebridge:src/plugin.ts:208-213`、`Luligu/matterbridge:packages/core/src/pluginManager.ts:147-161`】；Scrypted 则为每个插件按 `n-${runtime}-v${abi}-${platform}-${arch}` 分目录安装原生可选依赖并自动清理旧版本【源码：`koush/scrypted:server/src/plugin/plugin-npm-dependencies.ts:26-120`】。
6. **凭据隔离的核心原则是“静态加密分库 + 宿主单点解密/脱敏”。** Node-RED 把凭据独立存入 AES-256-CTR 加密文件而非流定义中【源码：`node-red/node-red:packages/node_modules/@node-red/runtime/lib/nodes/credentials.js:31-46`】；ioBroker 用 `encryptedNative` 落盘加密、`protectedNative` 对非自身上下文剥离字段【源码：`ioBroker/ioBroker.js-controller:packages/adapter/src/lib/adapter/adapter.ts:3122-3130,5298-5309`】。
7. **主流开源市场普遍缺少二进制代码签名，靠“清单自动化校验 + 中心维护黑/白名单”治理。** Homebridge 靠人工审核的 `plugins-v2.min.json`（Verified 标志 + `npm --allow-scripts`）【源码：`homebridge/homebridge-config-ui-x:src/modules/plugins/plugins.service.ts:2632-2650,3034-3109`】；HACS 靠 GitHub Action `ValidationManager` 校验结构【源码：`hacs/integration:custom_components/hacs/validate/manager.py:33-81`】；ioBroker 靠 `BlocklistManager` 动态下发禁用版本【源码：`ioBroker/ioBroker.js-controller:packages/controller/src/lib/blocklistManager.ts:97-137`】；仅 SmartThings Edge 原生实现了 CLI 打包签名与 Channel 分发【文档】。
8. **MenuBarHome 的安全闭环不可下放给适配器。** 无论未来是否引入进程外适配器，ADR-0023 确立的“写入门（`capabilityWriteRejection`）+ 高风险二次确认（`ManualControlPolicy`）+ 锁屏拦截（`ScreenLockPolicy`）+ 安全告警保留（`SafetyMonitor`）”与 ADR-0005 的 Ed25519 验签体系都必须留在宿主单点控制【源码：`Sources/MijiaCore/HomeStore+Capabilities.swift:1093-1246`、`Sources/MijiaCore/HomeStore+Security.swift:66-160`、`Sources/MijiaCore/UpdateSignature.swift:6-25`】。

---

## 1. Homebridge + homebridge-config-ui-x：混合隔离与 Schema 驱动 UI 标杆

### 1.1 第一层：定位与架构概览
Homebridge 把第三方智能家居设备桥接为 Apple HomeKit（HAP）及 Matter 配件。早期所有插件运行在主进程内，单个插件未捕获异常会导致整座桥离线；随后演进出 **Child Bridge（子桥）** 模式，允许按平台或配件拆分到独立 `child_process.fork()` 进程运行，并由 `homebridge-config-ui-x` 提供插件市场、表单配置与生命周期管理【源码：`homebridge/homebridge:src/childBridgeService.ts:212-216`】。

### 1.2 第二/三层：核心机制深剖

- **插件发现与加载边界（`PluginManager` & `Plugin`）**
  - **严格命名与关键字门禁**：只扫描匹配 `/^((@[\w-]+(\.[\w-]+)*)\/)?(homebridge-[\w-]+)$/` 且 `package.json` 的 `keywords` 包含 `'homebridge-plugin'` 的包【源码：`homebridge/homebridge:src/pluginManager.ts:74,481-489`】。
  - **初始化期归属锁**：调用 `plugin.initialize(api)` 前设置 `this.currentInitializingPlugin = plugin`，在 `finally` 中清空；若插件异步延迟调用 `registerPlatform`/`registerAccessory`，直接抛出异常拒绝归属，防止跨插件污染【源码：`homebridge/homebridge:src/pluginManager.ts:235-297`】。
  - **禁止重复捆绑宿主**：`Plugin.load()` 检查 `engines.homebridge` 与 `engines.node`（`semver.satisfies`），并对 `dependencies` 中私自包含 `homebridge` / `hap-nodejs` / `@homebridge/hap-nodejs` 的插件打印错误告警（避免多份 singleton 冲突）【源码：`homebridge/homebridge:src/plugin.ts:187-213`】。
- **子进程隔离、IPC 与崩溃熔断（`ChildBridgeService` & `ChildBridgeFork`）**
  - **状态机握手**：父进程 `fork` 出 `childBridgeFork.js`，子进程就绪后发送 `READY` → 父进程下发 `ChildProcessLoadEventData`（`LOAD`）→ 子进程加载插件并初始化 Matter/HAP API，回报 `LOADED` → 父进程发送 `START` → 子进程恢复缓存配件并发布 mDNS 后上报 `ONLINE`【源码：`homebridge/homebridge:src/childBridgeService.ts:450-482`、`src/childBridgeFork.ts:74-288`】。
  - **共享端口分配与父子隔离**：子进程需要发布外部配件或 Matter 节点时，通过 `PORT_REQUEST` / `PORT_ALLOCATED` 向父进程的 `ExternalPortService` 申请端口（5 秒超时后退回随机端口），避免多子进程端口碰撞；并且父进程下发 `homebridgeConfig` 时故意置空 `accessories: []`、`platforms: []` 以防循环序列化或跨插件窥探配置【源码：`homebridge/homebridge:src/childBridgeFork.ts:335-350`、`src/childBridgeService.ts:723-729`】。
  - **崩溃恢复与退避熔断**：子进程意外退出触发 `handleProcessClose(code, signal)`：若本次在线持续超过 `stableRunResetMs = 5 * 60 * 1000`（5 分钟），视为偶发故障并清零 `restartCount`；否则计入崩溃循环。超过 `maxRestarts = 4`（共 5 次失败）即永久置为 `DOWN` + `manuallyStopped = true` 停止自启；`code === 1 && signal === null`（典型未捕获 JS 异常）采用线性退避 `restartCount * 10s` 重启，而信号终止（如 `SIGSEGV`）虽然立即重启但也受 `maxRestarts` 上限约束（修复了早期无上限重启死循环的缺陷）【源码：`homebridge/homebridge:src/childBridgeService.ts:238-251,565-617`】。
- **配置 Schema、动态表单与 Custom UI 沙箱（`homebridge-config-ui-x`）**
  - **静态 + 国际化 + 动态 Schema**：UI 服务端按 `config.schema.<lang>.json` → `config.schema.json` 查找；若声明了 `dynamicSchemaVersion`，则读取用户目录 `.${pluginName}-v${dynamicSchemaVersion}.schema.json`，且显式用 `resolve()` + `startsWith(storageBoundary)` 拦截 `../` 路径穿越【源码：`homebridge/homebridge-config-ui-x:src/modules/plugins/plugins.service.ts:1601-1639`】。注入隐藏的 `_bridge` 子 Schema 并用 `condition: { functionBody: 'return false' }` 隐藏，前端 `SchemaFormComponent` 在 `onChanges` 时特意保留原始 `currentDataObj._bridge` 引用不被 `@ng-formworks/core` 裁掉【源码：`plugins.service.ts:1658-1719`、`ui/src/app/core/components/schema-form/schema-form.component.ts:106-127`】。
  - **Custom UI 进程级 & iframe CSP 双重隔离**：支持插件提供 `homebridge-ui/public/index.html` + `server.js`。前端嵌入 iframe 并施加严格 `Content-Security-Policy`（禁止任意外域脚本，仅允许 `customUiCspDomains` 白名单中 `https://<domain>` 且最多 10 条、单条 ≤256B），并严格校验开发模式 `origin` 防止 XSS 窃取 `localStorage` 令牌（注释记录 2026-08-08 修复的私有安全漏洞）；后端为每个 WebSocket 会话单独 `fork` `server.js`，断开连接时清理监听器并在 5 秒后按单次标记发 `SIGTERM` 防止 PID 复用误杀【源码：`plugins-settings-ui.service.ts:102-117,228-298,316-380`、`plugins.service.ts:3117-3135`】。
- **市场治理与安装安全**
  - **Verified 名单**：定期拉取 GitHub `homebridge/plugins` 的 `assets/plugins-v2.min.json`，解析出 `verifiedPlugins`（`v`）、`verifiedPlusPlugins`（`p`）、`unmaintainedPlugins`（`u`）与 `hiddenPlugins`（`h`）；仅已验证插件允许展示赞助链接【源码：`plugins.service.ts:196-210,2520-2523,3034-3109`】。
  - **包操作串行化与脚本白名单**：通过 `packageOperationQueue` 串行执行 `npm` 命令避免并发损坏 `node_modules`；针对 `npm >= 12` 默认禁用生命周期脚本的机制，从插件 `package.json` 的 `allowScripts` 字段构建 `--allow-scripts` 白名单【源码：`plugins.service.ts:169-187,2632-2650`】。

---

## 2. ioBroker（js-controller）：微内核 + 多进程适配器 + 数据库总线

### 2.1 第一层：定位与架构概览
ioBroker 是典型的**进程隔离微内核（Microkernel）**架构：`js-controller` 本身不承载任何设备驱动，只负责管理主机生命周期、维护 **Objects DB**（设备/通道/状态元数据与配置）和 **States DB**（实时值、ACK 标志、时间戳），以及拉起/监控各个独立运行的 **Adapter（适配器）实例进程**【源码：`ioBroker/ioBroker.js-controller:packages/controller/src/lib/controller/controller.ts:59-67,203-246`】。

### 2.2 第二/三层：核心机制深剖

- **“一实例一进程”与 Compact Mode 折中**
  - **默认强隔离**：`InstanceStarter.#handleAdapterProcessStart` 为每个适配器实例 `cp.fork()` 独立 Node.js 进程（传入 `--instance <no> --loglevel <level>` 与 `--max-old-space-size=${memoryLimitMB}`），或通过 `spawnPythonAdapter` 启动独立 Python 虚拟环境进程；同时调用 `#checkAvailableMemory` 在系统可用内存 <100MB / <50MB 时告警或准备拒启，避免 OOM 拖垮主机【源码：`ioBroker/ioBroker.js-controller:packages/controller/src/lib/controller/instances/instanceStarter.ts:182-196,266-323,415-466,657-673`】。
  - **Compact Mode 合并模式**：为缓解树莓派等低内存设备的多进程开销，允许适配器在 `io-package.json` 中声明 `common.compact = true` 并归入 `compactGroup`。`compactGroup === 0` 运行在主控制器进程内（通过 `decache` + 动态 `import` 加载），其余分组则 fork 独立的 `compactgroupController.js` 按组隔离（组内多个轻量适配器共享进程）【源码：`instanceStarter.ts:512-591`、`compactGroupManager.ts:41-75`】。
- **IPC 边界：状态/对象数据库即总线（无直接跨插件内存引用）**
  - 适配器不直接调用彼此代码，而是通过 `ObjectsClient` 与 `StatesClient`（后端可插拔为 JSONL 文件 DB 或 Redis）读写 `system.adapter.<name>.<n>.*` 对象与状态，并依托 `MessageBus`（`sendTo` / `on('message')`）发送命令【源码：`controller.ts:245`、`adapter.ts:156-250`】。
  - 进程存活与终止控制也走状态总线：控制器向 `${id}.sigKill` 写 PID 或 `-1`，崩溃清理时自动取消该实例的自动订阅（`cleanAutoSubscribes`）并置离线状态【源码：`instanceStarter.ts:602,687-693`、`instanceExitHandler.ts:127-143`】。
- **崩溃隔离、自愈重编译与循环熔断**
  - **Native 模块自愈**：`instanceStarter` 监听子进程 `stderr`，一旦匹配 `NODE_MODULE_VERSION`、`Cannot find module` 等原生依赖错配特征，标记 `proc.needsRebuild = true`；退出后由 `instanceExitHandler` 触发 `rebuildAdapter`（最多尝试 `MAX_REBUILDS = 4` 次）【源码：`instanceStarter.ts:713-729`、`instanceExitHandler.ts:39,245-274`】。
  - **崩溃计数熔断**：退出码为 `UNCAUGHT_EXCEPTION` 时累加 `proc.crashCount`，10 分钟无崩溃（`CRASH_RESET_TIME`）后自动重置；连续崩溃达 `MAX_CRASHES = 3` 次停止重启，并向系统发 `restartLoop` 通知【源码：`instanceExitHandler.ts:35-38,292-356`】。
- **版本兼容、凭据加密与市场阻断（Blocklist）**
  - **依赖与版本门禁**：启动前校验 `io-package.json` 是否已上传匹配版本（未上传自动触发 `uploadAdapter`）、校验 `common.dependencies` / `globalDependencies`（`checkVersions`）以及 `package.json` 的 `engines.node`（不满足则直接禁用实例）【源码：`instanceStarter.ts:150-167,210-217,330-357`】。
  - **配置加密与访问脱敏**：适配器在 `io-package.json` 声明 `encryptedNative` 与 `protectedNative`。写入配置时用系统密钥加密 `encryptedNative` 字段（`encryptArray`），启动时只为本适配器解密；对外返回对象时，若请求方非 admin/云端/自身适配器，则自动剔除 `protectedNative` 敏感属性【源码：`ioBroker/ioBroker.js-controller:packages/adapter/src/lib/adapter/adapter.ts:3122-3130,5298-5309,13289-13294`】。
  - **中心化版本封禁**：`BlocklistManager` 读取活跃仓库源中的 `blockedVersions`（semver 规则），在实例启动前实时拦截被开发者撤回的故障版本并批量禁用【源码：`ioBroker/ioBroker.js-controller:packages/controller/src/lib/blocklistManager.ts:48-137`、`instanceStarter.ts:224-240`】。

---

## 3. Matterbridge：单进程动态加载 + Matter 子桥（Childbridge）节点隔离

### 3.1 第一层：定位与架构概览
Matterbridge 将第三方平台/设备封装为标准 **Matter** 设备暴露给 Apple Home / Google Home / Alexa。虽然它广泛使用 Node `worker_threads`（`ThreadsManager` + `BroadcastServer`），但核心源码表明：**Matterbridge 的“Childbridge 模式”隔离的是 Matter 协议层的 `ServerNode` / Fabric 与配对码，而插件 JS 代码本身仍在主进程通过 `import()` 加载**【源码：`Luligu/matterbridge:packages/core/src/pluginManager.ts:1255-1284`、`packages/core/src/matterbridge.ts:623-634`】。

### 3.2 第二/三层：核心机制深剖

- **插件生命周期与依赖冲突守卫**
  - 状态机严格划分为 `add` → `parse` → `load` → `start` → `configure` → `shutdown`：先通过 `resolve()` 查找全局 `node_modules` 或 `matterbridgePluginDirectory` 下的 `package.json`，强制校验 `type === 'module'` 与 `main` 入口，并用 `findInvalidDependencies()` 拦截在 `dependencies`/`peerDependencies` 中私自依赖 `matterbridge`、`@matter*`、`@project-chip*` 的插件（防止 Matter 协议栈单例分裂）【源码：`Luligu/matterbridge:packages/core/src/pluginManager.ts:147-188,750-771,1229-1497`】。
- **Worker 线程的分层使用（平台任务外包，插件内载）**
  - `ThreadsManager` 管理两类线程：`worker`（一次性任务，如 `CheckUpdates`、`SpawnCommand`、`GlobalPrefix`、`ArchiveCommand`）与 `thread`（长驻线程，如 `Backend`、`RootNode`、`Tracker`），全部通过 `BroadcastServer`（基于 `MessageChannel` / `BroadcastChannel` 封装的请求-响应协议）与 `PluginManager` 通信【源码：`Luligu/matterbridge:packages/thread/src/threadsManager.ts:119-130`、`packages/core/src/pluginManager.ts:129-131,197-476`】。
  - 这意味着 Matterbridge 把耗时的 `npm install -g`、`checkUpdates` 等阻塞操作放进 Worker 线程，防止卡死 Matter 主事件循环，但**单个插件的运行时崩溃仍可能波及同一进程**（官方在 `ThreadsManager` 注释中记录了 Node/Bun 线程退出语义，但插件本体未跑在独立 worker 中）【源码：`threadsManager.ts:27-40`、`pluginManager.ts:792-809,1260`】。
- **Schema 驱动表单与扩展点**
  - 每个插件可提供 `<plugin.name>.schema.json`，缺失时 `PluginManager.getDefaultSchema()` 自动兜底生成含 `name`、`type`、`version`（`ui:widget: "hidden"`）与 `debug`、`unregisterOnShutdown` 的标准 JSON Schema【源码：`pluginManager.ts:1643-1714`】。
  - 前端 `ConfigPluginDialog.tsx` 基于 **React JSON Schema Form (`@rjsf`)**：递归扫描属性中以 `ui:` 开头的键（如 `ui:widget`），将其抽离组装成独立的 `uiSchema` 传给表单组件，同时还通过 WebSocket `/api/select-devices` 与 `/api/select-entities` 为黑白名单字段动态注入可选设备列表【源码：`Luligu/matterbridge:apps/frontend/src/components/ConfigPluginDialog.tsx:197-260`】。

---

## 4. Node-RED：事件流级错误捕获 + 独立加密凭据库

### 4.1 第一层：定位与架构概览
Node-RED 是低代码可视化物联网编排引擎，第三方节点通过 npm 包（`package.json` 含 `node-red` 字段）分发。它在同一 Node.js 运行时内加载所有节点包，**不提供进程隔离**，但在**发现管控、运行时异常捕获、以及凭据存储隔离**上有非常成熟的工程设计。

### 4.2 第二/三层：核心机制深剖

- **发现、版本门禁与黑白名单管控（`localfilesystem.js` / `loader.js` / `installer.js`）**
  - **版本与目录边界**：`localfilesystem.js` 扫描 `<userDir>/node_modules` 及上级路径中含 `package.json['node-red']` 的模块，并用 `externalModules.palette.allowList` / `denyList` 在**加载期**和**安装期**双重过滤包名与版本范围【源码：`node-red/node-red:packages/node_modules/@node-red/registry/lib/localfilesystem.js:33-45,187-193,215-247`、`installer.js:177-214`】。
  - **引擎版本匹配**：`loader.js` 加载前检查 `redVersion` 是否满足当前 Node-RED semver（剥离预发布后缀后比对），不匹配即标 `err = "version_mismatch"` 跳过【源码：`loader.js:116-122`】。
  - **同步串行安装与回滚**：`installer.js` 用链式 `activePromise` 串行化 `npm install`，触发 `preInstall` / `postInstall` 钩子，若 `postInstall` 失败自动执行 `npm remove` 回滚【源码：`installer.js:143,233-278`】。
- **配置 UI 与运行时故障边界**
  - **HTML 模板耦合模式**：每个节点由 `<name>.js`（运行时）和 `<name>.html`（前端编辑器配置模板与帮助文档）组成，`loadNodeTemplate` 用正则从 `.html` 提取 `data-template-name` 与多语言 `data-help-name`【源码：`loader.js:175-231`】。该模式灵活性高但安全面较大（编辑器注入任意 JS/HTML），不如纯 JSON Schema 安全。
  - **节点级异常捕获（`Flow.handleError`）**：虽然共享单进程（无法防死循环或未捕获顶层异步异常），但 `Flow.js` 在节点消息处理链上封装了分层错误路由——节点抛出的同步/节点内错误沿当前 Group → 父 Flow 冒泡至最近的 `catch` 节点，不会直接导致整个 Flow 停止调度【源码：`node-red/node-red:packages/node_modules/@node-red/runtime/lib/nodes/flows/Flow.js:596-645`】。
- **凭据隔离（`credentials.js`）**
  - 节点配置（`flows.json`）与节点密钥（`flows_cred.json`）严格分离。`credentials.js` 使用 `aes-256-ctr` + 16 字节随机 IV 整体加密 `credentialCache`，密钥支持四级优先级：Active Project 密钥 > 用户自设 `credentialSecret` > 系统首次随机生成的 `_credentialSecret`（32 字节 hex）> 显式关闭加密；当用户配置自定义密钥后，会自动用旧 `_credentialSecret` 解密并迁移重加密【源码：`node-red/node-red:packages/node_modules/@node-red/runtime/lib/nodes/credentials.js:31-46,85-198`】。

---

## 5. Home Assistant + HACS：单进程 Manifest + ConfigFlow 与无沙箱的代价

### 5.1 第一层：定位与架构概览
Home Assistant（HA）采用“统一 Python 异步事件循环 + 插件式集成（Integration）”架构。所有内置集成（`homeassistant/components/*`）和第三方自定义集成（`custom_components/*`，通常由 HACS 管理）均运行在**同一个 Python 进程**内，换取了极致的零序列化内存共享（状态机 `hass.states` 与事件总线 `hass.bus`），但也承担了最高的隔离代价。

### 5.2 第二/三层：核心机制深剖

- **Manifest 声明与依赖隔离尝试（`loader.py` & `requirements.py`）**
  - **纯数据清单驱动发现**：每个集成必须提供 `manifest.json`（见 `hue/manifest.json`），声明 `domain`、`requirements`（PyPI 包）、`dependencies`/`after_dependencies`、`config_flow`、`iot_class`（如 `local_push`）以及**自动发现匹配器**（`zeroconf`、`dhcp`、`ssdp`、`bluetooth`、`homekit`、`mqtt`、`usb`、`lorawan`）【源码：`home-assistant/core:homeassistant/components/hue/manifest.json:1-17`、`homeassistant/loader.py:920-1086`】。
  - **依赖安装与防风暴锁**：`RequirementsManager` 持有一把全局 `pip_lock` 防止并发 `pip install` 损坏环境；安装时强制注入核心 `package_constraints.txt` 约束版本（避免第三方集成强行升降级核心库），失败 3 次记入 `install_failure_history` 后熔断直至重启【源码：`home-assistant/core:homeassistant/requirements.py:24-26,96-137,300-342`】。
  - **Executor 异步导入隔离**：为避免集成 `import` 阶段阻塞主事件循环，`Integration.async_get_component()` 默认在 `import_executor` 线程池执行模块导入，并记录 `IMPORT_EVENT_LOOP_WARNING`【源码：`loader.py:212-217,1139-1187`】。
- **动态向导式配置 UI（`data_entry_flow.py` & `config_entries.py`）**
  - 不使用静态 JSON Schema 一次性渲染所有字段，而是定义了一套**服务器驱动的状态机（`FlowResultType`）**：`FORM`（返回 `probatio` / Voluptuous Schema 供前端渲染当前步表单，支持 `FieldCondition` 条件显隐）、`MENU`、`SHOW_PROGRESS`（异步耗时操作进度条，如 Hue 按下桥接器物理按钮）、`EXTERNAL_STEP`（OAuth2 外部网页跳转回调）、`CREATE_ENTRY`、`ABORT`【源码：`home-assistant/core:homeassistant/data_entry_flow.py:29-40,64-100,169-194`、`homeassistant/components/hue/config_flow.py:107-159`】。
  - 这一设计完美覆盖了“扫码/按键配对 + OAuth + 多步骤发现”等静态 JSON 表单难以表达的交互。
- **自定义集成加载、HACS 市场校验与单进程代价**
  - **强制版本号与核心封禁名单**：`Integration.resolve_from_root()` 对 `custom_components` 强制要求 `manifest.json` 含合法 `version`（用 `AwesomeVersion` 校验多类版本格式），否则直接拒绝加载；同时由于同一 Python 进程内无法隔离第三方崩溃或 Recorder 破坏，HA Core 不得不在源码中硬编码 `BLOCKED_CUSTOM_INTEGRATIONS`（按版本区间阻断 `dreame_vacuum`、`mydolphin_plus`、`icloud3`、`spook`、`entsoe` 等；并在 2026.11.0 标记内置 `marketplace` 取代 `hacs`）【源码：`home-assistant/core:homeassistant/loader.py:138-191,818-885`】。
  - **HACS 分发与自动化校验**：HACS 本质上是面向 GitHub 仓库的去中心化包管理器，**没有二进制签名**。`ValidationManager` 在发布端通过 GitHub Action 并行跑多条静态校验器（检查 `manifest.json` Schema、目录结构、品牌图、描述等）；安装端直接从 GitHub 拉取文件落盘到 `custom_components/<domain>`，若集成支持 `config_flow` 则删除缓存热重载，否则创建 `restart_required` Repair Issue 提示重启 HA【源码：`hacs/integration:custom_components/hacs/repositories/integration.py:40-69,71-118,165-171`、`validate/manager.py:33-81`、`validate/integration_manifest.py:22-43`】。

---

## 6. Scrypted：多运行时独立 Worker + 跨进程能力接口 RPC 典范

### 6.1 第一层：定位与架构概览
Scrypted（以视频 NVR、HomeKit/Matter 桥接和低延迟设备自动化闻名）采取了**最彻底的进程/线程隔离 + 面向对象跨进程 RPC** 架构：每个插件打包为独立 zip，运行在独立的 Node.js 子进程（`NodeForkWorker`）、Worker 线程（`NodeThreadWorker`）、Python Worker 或远程集群节点（`cluster-fork-worker`）中，宿主与插件之间通过双向 `RpcPeer` 透明代理设备能力接口【源码：`koush/scrypted:server/src/plugin/plugin-host.ts:130-232,338-471`】。

### 6.2 第二/三层：核心机制深剖

- **多运行时 Worker 与原生依赖环境隔离**
  - **按插件独立的原生依赖目录**：`plugin-npm-dependencies.ts` 为插件在独立卷目录中按 `n-${runtime}-v${abi}-${platform}-${arch}` 创建隔离前缀路径，仅拷贝 `optionalDependencies`（显式剔除 `scripts` 降低一部分供应链风险？注：此处剥离了插件自身的 `scripts` 字段再执行 `npm install`，并自动清理旧 ABI 目录），启动 `NodeForkWorker` 时通过 `NODE_PATH` 注入该隔离目录，彻底解决不同插件原生 C++ 插件版本冲突问题【源码：`koush/scrypted:server/src/plugin/plugin-npm-dependencies.ts:26-120`、`server/src/plugin/runtime/node-fork-worker.ts:52-74`】。
  - **原子 Zip 解压**：`node-worker-common.ts` 根据 zip MD5 哈希先解压到 `.tmp` 再原子 `renameSync` 替换目标目录，若遇旧僵尸进程锁文件则重命名为 `.tmp2` 延迟清理【源码：`koush/scrypted:server/src/plugin/runtime/node-worker-common.ts:56-101`】。
- **IPC 边界：RpcPeer 透明对象代理与接口即能力**
  - **能力模型**：插件在 `package.json` 的 `scrypted` 块中声明角色与接口（如 `"type": "DeviceProvider"`、`"interfaces": ["DeviceProvider", "DeviceCreator"]`、`pluginDependencies`），运行时设备继承 `ScryptedDeviceBase` 或 `MixinDeviceBase`，能力直接体现为实现的接口列表（`ScryptedInterface`）【源码：`koush/scrypted:plugins/amcrest/package.json:26-39`、`sdk/src/index.ts:10-167`】。
  - **跨进程方法调用与 GC 联动**：`rpc.ts` 在两端各维护一张代理表与 JS `Proxy`。跨进程传递对象时序列化为 `__remote_proxy_id` + `__remote_proxy_props` + `__remote_proxy_oneway_methods`（状态通知 `notify`、`updateDeviceState` 等高频方法标记为 `oneway` 免等待返回），并注册 `FinalizationRegistry` 在本地代理被 GC 回收时向对端发送 `finalize` 释放引用【源码：`koush/scrypted:server/src/rpc.ts:55-192`、`server/src/plugin/plugin-remote.ts:185-194`】。
  - **零拷贝 / 句柄传递**：`NodeThreadWorker` 通过 `MessagePort` `transferList` 转移 `ArrayBuffer`（带 `__rpc_transferable` 保护避免共享缓冲区被二次访问），而 `NodeForkWorker` 甚至支持通过 `sendHandle` 跨进程传递 `net.Socket` 句柄，这对摄像头 RTSP/WebRTC 低延迟流转发至关重要【源码：`node-thread-worker.ts:8-40,119-130`、`node-fork-worker.ts:79-96`】。
- **动态配置接口（非静态 Schema，而是 `Settings` 接口 + Mixin 叠加）**
  - 设备与插件实现 `Settings` 接口（`getSettings(): Promise<Setting[]>` / `putSetting(key, value)`）；更独特的是 `SettingsMixinDeviceBase` 允许像“装饰器”一样把扩展插件（如 Prebuffer、Motion Detection）的设置项以 `${settingsGroupKey}:${key}` 前缀混入原有设备面板，且在 `getSettings` 中分别对基础设备和 Mixin 做 `try/catch` 隔离（单扩展报错只展示只读错误条，不拖垮设备其余设置）【源码：`koush/scrypted:sdk/src/settings-mixin.ts:10-81`】。
- **健康检查与四维 ACL 权限隔离**
  - **看门狗重启**：`PluginHost.prepareRemote()` 启动每 30 秒一次的 `ping(Date.now())` 心跳与每 60 秒一次的健康巡检：允许最长 10 分钟冷启动（用于安装原生依赖），此后若超过 60 秒未响应或 ping 异常，直接调用 `this.api.requestRestart()` 重启插件进程【源码：`koush/scrypted:server/src/plugin/plugin-host.ts:294-334`】。
  - **细粒度 ACL（`AccessControls`）**：所有状态读取、事件订阅、接口暴露与方法调用均穿过 `AccessControls`（按 `devicesAccessControls` 白名单过滤设备 ID、属性 `properties`、接口 `interfaces` 与方法 `methods`），确保向 Web 客户端或受限插件暴露的 `SystemState` 与 `MediaManager` 权限最小化【源码：`koush/scrypted:server/src/plugin/acl.ts:8-104`、`plugin-remote.ts:12-46,62-76`、`plugin-host.ts:473-521`】。

---

## 7. Hubitat & SmartThings Edge：语言沙箱与驱动通道签名（文档剖析）

> 注：SmartThings Edge 与 Hubitat 平台运行时闭源，本节基于官方开发者文档（【文档】）剖析其沙箱与签名机制。

### 7.1 SmartThings Edge（Lua 沙箱 + 声明式权限 + 通道签名）
- **语言级沙箱**：驱动采用 **Lua** 编写，运行在 Hub 本地受限的 Lua 沙箱容器内，无法自由读写宿主机任意文件或任意执行系统命令【文档：SmartThings Edge Developer Docs】。
- **Manifest 声明式最小权限（`config.yaml`）**：每个驱动包必须通过 `config.yaml` 显式声明所需 `permissions`（如 `lan: {}`、`discovery: {}`、`zigbee: {}`、`zwave: {}`、`matter: {}`）。Sandbox 仅向该驱动注入已声明协议的底层库；若声明 `lan` + `discovery` 则需配合 `search-parameters.yaml`（mDNS/SSDP 预过滤，Hub 在匹配前无需唤醒全部驱动容器），Zigbee/Z-Wave/Matter 则靠 `fingerprints.yaml` 静态指纹匹配设备【文档：SmartThings Edge Driver Configuration & Permissions】。
- **打包签名与 Channel 分发**：开发者通过 `smartthings-cli` 将驱动打包、签名并发布到 **Driver Channel**，终端用户通过订阅受信任通道在 Hub 上本地安装执行，形成了完整的“声明权限 + 离线签名 + 通道分发”闭环【文档：SmartThings CLI & Driver Channels】。

### 7.2 Hubitat Elevation（Groovy 沙箱 + 能力契约 DSL）
- **受限 Groovy 2.4 沙箱**：驱动运行在平台控制的 Groovy 沙箱中，禁止自定义 Java 类、禁止引入外部 JAR、禁止创建原生 `Thread` 或调用阻塞 `println`/`sleep`（必须使用平台提供的 `log.debug()` 与 `runIn()` 异步调度），仅开放白名单内的安全工具类（如 `JsonOutput`、`XmlSlurper`）【文档：Hubitat Driver Overview】。
- **DSL 内聚元数据（`metadata { definition / preferences }`）**：同一份脚本通过 `capability`（如 `"Switch"`、`"TemperatureMeasurement"`）声明标准指令与事件契约，通过 `preferences { input ... }`（`bool`/`text`/`number`/`decimal`/`enum`/`password` + `range`）直接生成设备设置页，支持 `singleThreaded: true` 防止并发重入；通过 `importUrl` 直接从 GitHub raw URL 拉取源码，**无中心签名或权限审批机制**【文档：Hubitat Driver Definition & Preferences】。

---

## 8. 横向机制对比矩阵

| 维度 | Homebridge + config-ui-x | ioBroker (js-controller) | Matterbridge | Node-RED | Home Assistant + HACS | Scrypted | SmartThings Edge |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **隔离模型** | 可选 Child Bridge 子进程（`fork`）+ Custom UI 独立子进程 | **默认一实例一独立进程**（Node/Python）；可选 Compact 组合并 | 插件代码同进程 `import()`；耗时工具用 `worker_threads`；Matter 节点可分 Childbridge | 单进程同 EventLoop；节点级 `try/catch` 路由 | **单 Python 进程**共享事件循环；仅异步导入进线程池 | **每插件独立进程/Worker/远程节点**（`fork`/`worker_threads`/Python） | Hub 本地 **Lua 沙箱容器** |
| **IPC / API 边界** | Node IPC 事件（`READY`/`LOAD`/`ONLINE`/`PORT_REQUEST`） | **Objects + States DB**（Redis/JSONL）+ `MessageBus` | `BroadcastServer`（`MessagePort`/Channel） | 内存事件流 `msg` + `RED` API | 内存直接调用 `hass.states`/`hass.services` | **双向 `RpcPeer` 透明代理** + `FinalizationRegistry` + Socket/Buffer 转移 | Hub 注入受限协议 API（`zigbee`/`lan` 等） |
| **配置 Schema 与 UI** | `config.schema.json`（Angular JSON Schema Form）+ `dynamicSchema` + iframe Custom UI | `jsonConfig.json`（Admin 渲染）+ `io-package.json` | `<name>.schema.json`（`@rjsf` + `ui:*` 提取 + 动态设备选择） | `.html` 自定义模板 + JS 脚本 | **`ConfigFlow` 状态机**（`probatio`/Voluptuous + `Menu`/`Progress`/`OAuth`） | 动态 **`Settings` 接口**（`Setting[]` + `SettingsMixin` 叠加） | Presentation / Profile YAML |
| **崩溃隔离与重启** | 5min 稳定期清零；`maxRestarts=4` 熔断；`10s * n` 退避 | `MAX_CRASHES=3`（10min 窗口）；OOM 前置告警；原生模块自动 `rebuild` | 主进程同命运（仅 Thread 退出有事件矩阵） | 节点级 `Flow.handleError` 冒泡至 `catch` 节点 | 崩溃拖垮或卡死全局；靠 **`BLOCKED_CUSTOM_INTEGRATIONS`** 事后硬编码封禁 | 30s Ping/Pong + 60s 巡检（冷启 10min 宽限），超时自动重启 | 容器崩溃不影响 Hub 核心 |
| **版本兼容机制** | `engines.homebridge` & `node` semver；禁捆绑宿主包 | `engines.node`（不符自动禁用）+ `dependencies` 检查 + `io-package` 同步 | `type: module` 校验 + 禁捆绑 `matterbridge`/`@matter*` | `redVersion` semver 检查 + `--engine-strict` | `AwesomeVersion` 强制版本 + `package_constraints.txt` 锁版本 | 按 `n-node-v${abi}-${platform}-${arch}` 隔离原生依赖目录 | Hub 固件 API 版本 |
| **权限与凭据隔离** | Custom UI 严格 CSP + `origin` 校验 + `storageBoundary` 防穿越 | `encryptedNative` 落盘加密；`protectedNative` 跨上下文剥离 | 无细粒度插件权限沙箱 | **`credentials.js` 独立 AES-256-CTR 文件**；`allowList`/`denyList` | 全进程共享内存与 `.storage`（无边界隔离） | **`AccessControls` 四维 ACL**（设备/属性/接口/方法）；插件私有卷 | `config.yaml` **`permissions` 声明式最小权限** |
| **市场审核与签名** | `plugins-v2.min.json` 人工 Verified 白名单 + `npm --allow-scripts` | Repo `blockedVersions` 黑名单机制；无代码签名 | npm 包分发；无签名 | npm + 官方 Flow Library 索引；`allowList` 管控 | HACS GitHub Action 自动静态校验（`ValidationManager`）；无签名 | npm / zip 哈希校验；无第三方代码签名 | **CLI 打包签名 + Driver Channel 分发** |

---

## 9. 专门设计：遵循 ADR-0020 / ADR-0023 的 MenuBarHome 进程外适配器架构

### 9.1 设计边界与前提约束
根据 MenuBarHome 的现行架构决策，任何扩展机制必须同时守住四条红线：
1. **宿主进程内零第三方代码（ADR-0020 / ADR-0023）**：不开放动态库（`.dylib`/`.dll`）加载、不引入嵌入式 JS/Python 引擎到主 App 进程，不把 `HomeBackend` 改为开放注册表，也不把 `Shared/capability-manifest.json` 变成第三方可写清单【源码：`docs/adr/0020-backend-descriptor-table.md:58-95`、`docs/adr/0023-host-owned-builtin-capabilities.md:19-20,38`】。
2. **双端同形与纯粹核心（ADR-0003 / ADR-0006）**：协议解析与状态模型留在 `Sources/MijiaCore/`（纯 `Foundation`，可 Linux 单测）与 `windows/src/core/`，由 `Tests/Fixtures/` 共享黄金语料守住一致【源码：`docs/adr/0003-core-builds-on-linux.md`、`docs/adr/0006-dual-platform-implementation.md`】。
3. **控制与安全权永不外放（ADR-0013 / ADR-0023）**：所有写入门、锁屏守卫、高风险二次确认与安全告警保留必须由宿主单点执行。
4. **复用已有进程外基建**：本仓库已有两条经过验证的进程外桥接模式——`scripts/mijia-mcp`（stdio JSON-RPC 2.0 + 只读快照）与 `XiaomiCameraBridge.swift` / `companion.rs`（受管子进程生命周期校验 + loopback HTTP + 本地 Secret 鉴权）【源码：`scripts/mijia-mcp:1-28`、`Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift:56-79`、`windows/src-tauri/src/companion.rs:16-26,54-59`】。

---

### 9.2 架构总览与通信载体选择

| 候选方案 | 隔离性 | 双端通用性 | 凭据/端口暴露面 | 实时推送能力 | 结论 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **A. 受管子进程 stdio JSON-RPC 2.0**（推荐主通道） | 独立 OS 进程，随宿主启停 | Swift `Process` + Rust `Command` 原生零依赖 | 无监听端口、无跨进程嗅探面 | 全双工行分隔 JSON 推送（`notifications`） | **首选控制与状态通道** |
| **B. 独立守护进程 + 本地 Loopback HTTP/WS** | 独立 OS 进程 | HTTP/WS 通用 | 需随机端口 + 每次启动轮换 Secret Header | WS/SSE 推送 | 仅作视频流（已有 `go2rtc`）或长驻重服务备选 |
| **C. 复用 MCP (`scripts/mijia-mcp`)** | 独立 OS 进程 | MCP 协议偏 AI 工具调用（Tool/Resource） | 无端口 | MCP 不适合高频设备增量状态推送与配置表单状态机 | 保持作为**上行 AI 出口**，不反向作设备驱动总线 |

**推荐形态**：**宿主作为 Supervisor（监督者），以受管子进程 `stdio`（换行分隔 JSON-RPC 2.0，参考 LSP / MCP 帧规范）拉起“进程外适配器（External Adapter）”**。macOS 由 `Sources/MijiaCore` 管理子进程句柄，Windows 由 Tauri Rust 层（`windows/src-tauri/src/`）管理子进程句柄并转发给 TS 核心，两端解析完全相同的 JSON 协议帧。

---

### 9.3 五大核心契约设计

#### （1）能力描述契约（Manifest + 配置 Schema + 设备形状投影）
借鉴 **SmartThings Edge `config.yaml` + Homebridge `config.schema.json` + MenuBarHome 形状模型**：
- 每个进程外适配器随包携带只读 `adapter-manifest.json`（**独立于内置的 `Shared/capability-manifest.json`**，不污染内置枚举）：
  ```jsonc
  {
    "manifestVersion": 1,
    "adapterId": "com.example.tplink-lan",
    "name": "TP-Link Kasa/Tapo LAN",
    "version": "1.2.0",
    "minHostProtocolVersion": 1,
    "runtime": { "type": "binary", "entrypoint": "bin/adapter" },
    "permissions": {
      "network": ["lan"],           // 声明式权限：lan / internet / none（不声明即拒绝或弹窗提示）
      "credentials": ["password"]   // 仅声明需要哪些配置项由宿主加密托管
    },
    "configSchema": { /* JSON Schema 子集：string/number/boolean/enum + format:"password" */ },
    "declaredCategories": ["light", "plug"],
    "declaredRiskHint": "standard"  // 仅作补充提示，宿主保留覆盖权（见 §9.3(3)）
  }
  ```
- **状态与控制形状映射（借鉴 Scrypted 接口即能力 + MenuBarHome `FacetControl`）**：
  - 适配器不传输 UI HTML/JS，只通过 JSON-RPC `adapter/snapshot` 与 `adapter/stateDelta` 上报标准化设备对象：必须携带规范身份（`adapterId` + `nativeDeviceId`）、`category`（映射自 `DeviceCategoryID` 的已知值，未知一律落入 `generic`）、在线状态、读数及标准控制面（`power` / `brightness` / `colorTemp` / `temperature` / `cover` / `facets[]`）。
  - 双端 `HomeStore` 将其封装为独立的 `ExternalAdapterSlot`（不修改 `HomeBackend` 三值封闭枚举，避免破坏 ADR-0020 的编译期穷尽检查，而是在快照聚合层做显式隔离，并附带 `sourceEpoch` / `adapterGeneration` 代次防串台）【源码：`Sources/MijiaCore/HomeBackendDescriptor.swift:52-95`】。

#### （2）写入门仍归宿主（Host-Owned Write Gate）
借鉴 **ADR-0023 写入门 + Scrypted `AccessControls`**：
- **单向控制流**：所有来自面板卡片、键盘搜索、本地口令/AI 助手、`menumijia://` URL Scheme（ADR-0013）、MCP 的控制指令，**严禁直接发往适配器**；必须先经过宿主 `HomeStore` 的 `rejectDeviceWriteIfCapabilityDisabled` / `capabilityWriteRejection`（以及 Windows 对等逻辑）校验：
  1. 适配器全局开关 & 该设备所属 `DeviceCategoryID` 是否启用（关闭某类设备时，面板撤下入口且写入门零写入拒绝）；
  2. 目标 `adapterId + nativeDeviceId` 是否存在于当前 `capabilityGeneration` / `adapterEpoch` 活跃快照中（防止适配器重启或切换配置期间的过期指令误触设备）；
  3. 适配器不得自发订阅操作系统 URL Scheme 或篡改 `raycast-snapshot.json`（快照唯一写入权归宿主 `companion.rs` / `RaycastSnapshot.swift`）。

#### （3）安全确认与告警仍归宿主（Host-Owned Safety & Confirmation Policy）
借鉴 **MenuBarHome `ManualControlPolicy` / `ScreenLockPolicy` + ioBroker 进程外不可信原则**：
- **危险等级不由适配器豁免**：适配器声明的 `declaredRiskHint` **只能上调不可下调**。当设备映射到 `plug`、`valve`、`cover`（车库门/开窗器/晾衣架）、加热类 `appliance` 或 `generic` 只读/受限设备时，宿主 `ManualControlPolicy` 与 `ModelActionPolicy` 强制按宿主统一规则触发二次确认弹窗（含 `ManualControlHazardProfile` 模态期间防漂移核验），适配器无权通过返回字段关闭确认【源码：`Sources/MijiaCore/ManualControlPolicy.swift:80-151`、`Sources/MijiaCore/HomeStore+Security.swift:8-160`】。
- **锁屏守卫与安全告警保留**：任何外部适配器指令在宿主 `ScreenLockPolicy.isLocked` 为真时直接拦截；若用户开启安全提醒而关闭某类设备展示，宿主仍可向适配器发送只读 `adapter/pollSafetySignals` 请求以保留漏水/烟雾等告警信号（对齐 ADR-0023 第 4 条）【源码：`docs/adr/0023-host-owned-builtin-capabilities.md:22`】。

#### （4）凭据与权限隔离（Host-Owned Credential Vault）
借鉴 **Node-RED `credentials.js` + ioBroker `encryptedNative` + SmartThings `permissions`**：
- **主凭据零共享**：米家账号 `CredentialVault`（`Sources/MijiaCore/CredentialVault.swift`）、HA 长期令牌、AI API Key 与伴生 `bridgeToken` **永远不暴露给适配器进程**。
- **按适配器分槽托管**：适配器自身所需的厂商账号/局域网密钥（在 `configSchema` 中标记 `writeOnly: true` / `format: "password"`）由宿主代收并加密存入宿主 `CredentialVault` / Windows `secureStore` 独立槽位（如 `adapter:<adapterId>:secret`）；仅在启动该适配器子进程时，通过 stdin JSON-RPC `host/initialize` 消息单次注入内存（**不通过命令行参数，不落明文 env，不写磁盘明文 JSON**）。
- **最小进程边界**：子进程禁用继承宿主环境变量（仅传白名单最小 `PATH`/`LANG`），工作目录锁定在独立的 `~/Library/Application Support/MenuBarMijia/adapters/<adapterId>/data`（macOS）或 `%LOCALAPPDATA%\MenuBarMijia\adapters\<adapterId>\data`（Windows）；macOS 下可选附加轻量 `sandbox-exec` 规则或无权限子进程约束，禁止访问宿主钥匙串与主应用目录。

#### （5）签名、审核、生命周期与双端共用
- **签名与完整性校验（复用 ADR-0005 `UpdateSignature` + `Go2RTCOwnerRecord`）**：
  - 官方/认证适配器清单采用与自更新相同的 **Ed25519 离线公钥** 验签（复用 `UpdateSignature.verify` 与 Windows `update.rs` 同构逻辑）：清单元数据锁定 `adapterId`、`version`、`sha256`（二进制/归档包摘要）与 `permissions`。
  - 运行时启动子进程前，像 `XiaomiCameraBridge.swift` 的 `Go2RTCOwnerRecord` 一样核对磁盘二进制路径、大小与 `sha256`，防止被本地恶意替换【源码：`Sources/MijiaCore/UpdateSignature.swift:10-25`、`Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift:56-79`】。
  - 用户手动安装未签名本地开发适配器时，必须经过高危显式警告开关启用，UI 持久标注「未签名外部适配器」。
  - 远端清单支持类似 ioBroker `BlocklistManager` 的 `blockedVersions` 字段，一旦发现崩溃或安全漏洞版本可在不发版宿主的情况下阻断启动。
- **崩溃隔离与退避重启（借鉴 Homebridge + ioBroker + Scrypted）**：
  - 子进程崩溃只标记该适配器离线并在面板提示重试，宿主 UI 与米家/HA 主通道零受影响。
  - 采用混合退避熔断：**30 秒 JSON-RPC `ping` 心跳** + 异常退出计数（10 分钟稳定运行重置），**连续 3 次启动/运行崩溃**后熔断暂停并提示用户查看脱敏日志，禁止无限死循环重启。
- **双端（Swift + Tauri）共用方式（ADR-0006）**：
  - 在仓库新增纯数据协议规范与黄金语料 `Tests/Fixtures/external_adapter_golden.json`：覆盖握手、Schema 解析、设备状态投影、权限越界拒绝、崩溃熔断状态机、写入门拒绝与 Ed25519 清单验签。
  - macOS（`MijiaCore` 纯 Foundation 编解码 + `MenuBarMijiaApp` 设置页通用 JSON Schema 渲染）与 Windows（`windows/src/core/` TypeScript 编解码 + `windows/src-tauri` Rust 子进程监管 + Fluent 设置页表单渲染）共享同一份黄金测试语料与 CI 门禁。

---

## 10. 对照我们：差距表

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| :--- | :--- | :--- | :--- | :---: |
| [HomeBackendDescriptor.swift](../../../Sources/MijiaCore/HomeBackendDescriptor.swift) / [homeProvider.ts](../../../windows/src/core/homeProvider.ts) | `HomeBackend` 为三值封闭枚举，第三个源 LG 电视绕开接缝直接插卡（ADR-0020 已记录） | Scrypted 接口即能力（`ScryptedDeviceBase` + `RpcPeer`）；Homebridge `ChildBridgeService` 统一桥接模型 | 保持 `HomeBackend` 封闭不动；若评估进程外适配器，单独设计平行的 `ExternalAdapterSlot` 投影层，不把 `HomeBackend` 改开放字符串 | **M** |
| [Shared/capability-manifest.json](../../../Shared/capability-manifest.json) | 静态记录内置连接/功能/设备类型及依赖，受静态门禁校验 | SmartThings `config.yaml`（权限声明）+ Homebridge `config.schema.json`（UI 表单） | 保持内置清单纯洁；若引入外部适配器，使用独立 `adapter-manifest.json`（含 `permissions` 与 `configSchema`），与内置清单隔离 | **S** |
| [HomeStore+Capabilities.swift](../../../Sources/MijiaCore/HomeStore+Capabilities.swift) / [HomeStore+Security.swift](../../../Sources/MijiaCore/HomeStore+Security.swift) | 已有完备的单点写入门（`capabilityWriteRejection`）与高风险二次确认防漂移核验（`ModalDeviceContext`） | Scrypted `AccessControls` 四维过滤；ioBroker `States` ACK 隔离 | **直接复用并作为强约束**：所有进程外适配器写请求必须经过此写入门与 `ManualControlPolicy`，严禁适配器旁路直控 | **S** |
| [CredentialVault.swift](../../../Sources/MijiaCore/CredentialVault.swift) / [secureStore.ts](../../../windows/src/core/secureStore.ts) | 全应用凭据收敛于单一 Keychain Vault / Windows 凭据槽 | Node-RED `credentials.js` 分库加密；ioBroker `encryptedNative` 按实例隔离密钥 | 为外部适配器分配独立隔离槽位（`adapter:<id>:secret`），仅通过 stdin RPC 按需单次下发给对应子进程，严禁读取主 Vault | **M** |
| [XiaomiCameraBridge.swift](../../../Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift) / [companion.rs](../../../windows/src-tauri/src/companion.rs) | 已有子进程二进制路径/mtime 校验（`Go2RTCOwnerRecord`）与 Rust Loopback Secret HTTP IPC | Homebridge `ChildBridgeService`（`maxRestarts=4` + `stableRunResetMs=5min`）+ ioBroker `MAX_CRASHES=3` + Scrypted `ping` 心跳 | 把 `XiaomiCameraBridge` 的“进程身份校验”与 Homebridge/ioBroker 的“崩溃退避熔断 + 稳定期复位”抽象为通用子进程监督基元 | **M** |
| [UpdateSignature.swift](../../../Sources/MijiaCore/UpdateSignature.swift) | 已具备 Ed25519 离线公钥验签基础设施 | SmartThings Edge 通道签名 + ioBroker `BlocklistManager` 阻断失效版本 | 复用 `UpdateSignature` 校验适配器清单与 SHA-256，补充本地/远端版本黑名单机制 | **S** |
| [scripts/mijia-mcp](../../../scripts/mijia-mcp) / [SettingsWindowView.swift](../../../Sources/MenuBarMijiaApp/SettingsWindowView.swift) | `mijia-mcp` 只作上行只读快照+URL 桥；设置页为原生手写表单（ADR-0020 第 5 条刻意不做通用表单） | Homebridge `SchemaFormComponent`（JSON Schema 渲染动态配置） | 内置后端保留手写设置页；若未来上线进程外适配器，仅在“适配器配置弹窗”局部引入轻量 JSON Schema 子集渲染器，不渲染第三方 HTML/JS | **L** |

---

## 11. 推进清单

| # | 标题 | 价值 | 成本 | 优先级 | 涉及高风险面？ | 依据 |
| :- | :--- | :--- | :- | :---: | :---: | :--- |
| 1 | **抽象通用“受管子进程监督器”用于现有 `go2rtc` 桥**（崩溃计数 + 退避重启 + 5 分钟稳定期复位 + 孤儿进程清理） | 消除摄像头桥偶发崩溃后的无响应或无限重启循环风险，同时为未来进程外适配器打底 | M | **P1** | **否**（重构本地摄像机桥管理，不改登录/设备控制/更新签名链路） | Homebridge `ChildBridgeService`（`stableRunResetMs`）与 ioBroker `instanceExitHandler`（`MAX_CRASHES`）已被长期验证有效 |
| 2 | **起草《进程外适配器协议规范（stdio JSON-RPC 2.0）》与黄金语料草案**（按 ADR-0020/0023 重启条件立新 ADR） | 在不引入任何运行时插件负担的前提下，锁定能力契约、写入门、安全确认与凭据边界，把现有 LG webOS 电视作为首个“拟外置”验证样本 | S | **P2** | **是**（若后续落地将涉及凭据传递、设备控制写入与跨端契约，须严格走 PR 评审） | ADR-0020 第 94 行与 ADR-0023 第 38 行已明确将进程外 MCP/HTTP 桥列为未来评估方向 |
| 3 | **适配现有 `UpdateSignature` 增加“扩展清单验签 + 本地黑名单阻断”能力** | 若未来开放进程外适配器或第三方伴生工具，从 Day 1 具备防篡改签名与紧急撤回能力，避免陷入 HA 硬编码补丁泥潭 | S | **P2** | **是**（涉及 Ed25519 验签体系，属 AGENTS.md 高风险面第 4 类） | ADR-0005 已有现成 Ed25519 验签基建；ioBroker `BlocklistManager` 证明版本阻断比发版修复更快 |
| 4 | **在适配器配置场景评估“受限 JSON Schema 子集表单渲染器”**（SwiftUI + Fluent TS，禁用任意脚本/iframe） | 让未来进程外适配器无需撰写双端原生设置页即可获得基本配置 UI，同时避免 Homebridge Custom UI 曾踩过的 XSS/CSP 漏洞 | L | **P3** | **否**（纯 UI 表单渲染，需配套 `password` 字段直入宿主加密槽） | `homebridge-config-ui-x` `plugins-settings-ui.service.ts` 展示了引入第三方 HTML/JS 带来极大 CSP 与 XSS 防护成本 |

---

## 12. 设想（天马行空，标明 ADR 冲突）

1. **用 MCP双向化 + WebAssembly（WASI）轻量沙箱替代子进程**：目前进程外适配器若需要跨 macOS/Windows 分发，原生二进制需编两套（arm64/x64 + win64）。若引入 WASI 组件模型（如 Wasmtime）跑纯协议翻译器（如将某小众厂商局域网 HTTP/UDP 转为标准设备形状），一份 `.wasm` 可跨双端运行且天然无文件系统/环境变量权限，仅通过宿主注入的受限 Socket Capability 访问局域网。
   - **冲突**：虽不加载原生动态库，但引入第三方字节码引擎及 Wasmtime 依赖直接冲突 **ADR-0020/0023**（不做运行时插件与分发）及 **MenuBarMijia 零外部重型三方依赖原则**，且增加了包体积与公证审查复杂度。
2. **把现有 `LGWebOSClient` 拆成第一个标准进程外适配器（“吃自己的狗粮”）**：目前 LG 电视在 Swift 端绕开了 `HomeProvider`、在 Windows 端未对齐。若直接按第 9 节协议将其拆出为可选内置/随包进程外适配器，既能验证双端共用一份协议实现的威力，也能顺手清理 `HomeStore+Backend.swift` 里的特例分支。
   - **冲突**：直接涉及 **ADR-0020 落地顺序第 3 条**（需另立 ADR 决定 LG 电视归属）以及 **ADR-0006**（需改变双端原生代码分工）。
3. **“零配置局域网发现触发按需拉起”**：借鉴 Home Assistant `manifest.json` 的 `zeroconf`/`ssdp` 声明与 SmartThings Edge 的 `search-parameters.yaml` 预筛选——主程序内置只读 mDNS 嗅探器（零第三方代码执行），发现局域网存在某厂商网关（如 Aqara/Hue/米家中枢）时才提示用户一键下载并拉起对应已签名的进程外适配器，彻底做到平日起动零内存占用。
   - **冲突**：涉及 **ADR-0023 第 1 条**（插件市场与动态下载安装不在当前范围内）。

---

## 13. 来源清单

### 源码仓库（本地只读浅克隆 `~/.cache/mbh-research-clones/`）
- `homebridge/homebridge` (`bd22b19`): `src/pluginManager.ts`, `src/plugin.ts`, `src/childBridgeService.ts`, `src/childBridgeFork.ts`, `src/ipcService.ts`, `src/server.ts`
- `homebridge/homebridge-config-ui-x` (`9f166ee`): `src/modules/plugins/plugins.service.ts`, `src/modules/custom-plugins/plugins-settings-ui/plugins-settings-ui.gateway.ts`, `src/modules/custom-plugins/plugins-settings-ui/plugins-settings-ui.service.ts`, `ui/src/app/core/components/schema-form/schema-form.component.ts`
- `ioBroker/ioBroker.js-controller` (`007fb9a`): `packages/controller/src/lib/controller/controller.ts`, `packages/controller/src/lib/controller/instances/instanceStarter.ts`, `packages/controller/src/lib/controller/instances/instanceExitHandler.ts`, `packages/controller/src/lib/controller/instances/compactGroupManager.ts`, `packages/controller/src/lib/blocklistManager.ts`, `packages/adapter/src/lib/adapter/adapter.ts`
- `Luligu/matterbridge` (`40b2b9f`): `packages/core/src/pluginManager.ts`, `packages/core/src/matterbridge.ts`, `packages/thread/src/threadsManager.ts`, `packages/types/src/matterbridgePlatformTypes.ts`, `apps/frontend/src/components/ConfigPluginDialog.tsx`
- `node-red/node-red` (`f613ba1`): `packages/node_modules/@node-red/registry/lib/loader.js`, `packages/node_modules/@node-red/registry/lib/installer.js`, `packages/node_modules/@node-red/registry/lib/localfilesystem.js`, `packages/node_modules/@node-red/runtime/lib/nodes/credentials.js`, `packages/node_modules/@node-red/runtime/lib/nodes/flows/Flow.js`
- `home-assistant/core` (`b6d170e`): `homeassistant/loader.py`, `homeassistant/requirements.py`, `homeassistant/data_entry_flow.py`, `homeassistant/config_entries.py`, `homeassistant/components/hue/manifest.json`, `homeassistant/components/hue/config_flow.py`
- `hacs/integration` (`8a54382`): `custom_components/hacs/repositories/integration.py`, `custom_components/hacs/validate/manager.py`, `custom_components/hacs/validate/integration_manifest.py`
- `koush/scrypted` (`3507b61`): `server/src/plugin/plugin-host.ts`, `server/src/plugin/plugin-remote.ts`, `server/src/plugin/acl.ts`, `server/src/rpc.ts`, `server/src/plugin/plugin-npm-dependencies.ts`, `server/src/plugin/runtime/node-fork-worker.ts`, `server/src/plugin/runtime/node-thread-worker.ts`, `server/src/plugin/runtime/node-worker-common.ts`, `sdk/src/index.ts`, `sdk/src/settings-mixin.ts`, `plugins/amcrest/package.json`

### 本仓库参照文件
- [docs/adr/0013-raycast-companion-contract.md](../../../docs/adr/0013-raycast-companion-contract.md)
- [docs/adr/0020-backend-descriptor-table.md](../../../docs/adr/0020-backend-descriptor-table.md)
- [docs/adr/0023-host-owned-builtin-capabilities.md](../../../docs/adr/0023-host-owned-builtin-capabilities.md)
- [Shared/capability-manifest.json](../../../Shared/capability-manifest.json)
- [Sources/MijiaCore/HomeBackendDescriptor.swift](../../../Sources/MijiaCore/HomeBackendDescriptor.swift)
- [Sources/MijiaCore/HomeStore+Capabilities.swift](../../../Sources/MijiaCore/HomeStore+Capabilities.swift)
- [Sources/MijiaCore/HomeStore+Security.swift](../../../Sources/MijiaCore/HomeStore+Security.swift)
- [Sources/MijiaCore/ManualControlPolicy.swift](../../../Sources/MijiaCore/ManualControlPolicy.swift)
- [Sources/MijiaCore/CredentialVault.swift](../../../Sources/MijiaCore/CredentialVault.swift)
- [Sources/MijiaCore/UpdateSignature.swift](../../../Sources/MijiaCore/UpdateSignature.swift)
- [Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift](../../../Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift)
- [scripts/mijia-mcp](../../../scripts/mijia-mcp)
- [windows/src/core/homeProvider.ts](../../../windows/src/core/homeProvider.ts)
- [windows/src-tauri/src/companion.rs](../../../windows/src-tauri/src/companion.rs)

### 官方文档检索（2026-11-23）
- SmartThings Edge Driver 官方文档检索（`smartthings.com` / `github.com/SmartThingsCommunity/smartthings-cli`）：Lua Sandbox、`config.yaml` permissions、`search-parameters.yaml`、`fingerprints.yaml`、Driver Channels & CLI 签名（经搜索摘要核对，原始跳转链接未单独展开）
- Hubitat Elevation 开发者文档检索（`hubitat.com`）：Groovy 2.4 Sandbox、`metadata`/`definition`/`preferences`、Capabilities（经搜索摘要核对，原始跳转链接未单独展开）
