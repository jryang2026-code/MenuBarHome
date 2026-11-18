# ADR-0023：宿主拥有内置能力选择、生命周期、引用判决与执行权限

日期：2026-11-18　状态：已接受（关联 ADR-0003、ADR-0005、ADR-0006、ADR-0008、ADR-0013、ADR-0019、ADR-0020）

## 背景

用户需要将未使用的连接、可选功能与设备类型设为关闭，做到不暴露冗余入口、不占用后台轮询或观察资源，同时不削弱漏水/烟雾等安全提醒、锁屏守卫与高风险设备二次确认。为此需要明确内置可选能力的契约边界与所有权归属。

## 备选方案

1. **进程内第三方代码插件或开放注册表**：允许运行时加载外部模块或由字符串自由注册能力。已在 ADR-0020 否决——破坏双端编译期穷尽检查，使外部代码触及凭据与控制链路，并冲击公证签名（ADR-0005）。
2. **各模块自治启停，并将设备类型开关视为安全边界**：关闭类型即彻底断读，控制入口继续依赖各端 `requiresConfirmation`。缺陷在于：关闭传感器会静默吞掉已开启的漏水/烟雾告警；`requiresConfirmation` 对未知目标返回 `false` 会把已关闭目标误放入下游错误分支；模块私自停用会让定时与自动化静默失效。
3. **宿主持有内置能力模型 + 共享纯数据清单与双端穷尽映射**：保留随 App 发布的封闭实现，由宿主集中管理能力选择、生命周期代次、停用前引用判决与统一控制写入门。

## 决定

选择方案 3。

1. **维持封闭内置范围，不做第三方代码插件**：沿用 ADR-0020 的封闭 `HomeBackend` 枚举、本端专用连接表单、规范设备身份以及 ADR-0008 的整卡去重与写路由。插件市场与动态加载不在范围内；LG 电视并入连接组合或调整跨源优先级需另立 ADR。
2. **建立双端共读的纯数据能力清单（`Shared/capability-manifest.json`）**：仅记录连接（`ConnectionCapabilityID`）、功能（`FeatureID`）、设备类型（`DeviceCategoryID`）的稳定 ID、种类、硬依赖、新装默认、启动策略、平台支持度与 `docs/capabilities.json` 映射，**严禁存入持久化状态、凭据秘密或设备危险等级**。Swift 端用封闭枚举与穷尽 `switch`（留在 `MijiaCore` 纯 `Foundation` 边界内，符合 ADR-0003），TypeScript 端用字面量联合与 `satisfies Record<…>`，普通能力 ID 不做品牌类型铺开；门禁在构建前拦截未知 ID、重复 ID、依赖环、缺映射与意外默认值变动。
3. **宿主持有生命周期与引用判决**：能力的启停意愿、作用域代次、任务/连接回收，以及对等待/错过/异源定时（ADR-0019）、启用自动化与快捷动作的停用预检均归宿主持有。带显式目标（含展开后的设备群组成员）的快捷动作与定时、自动化同口径：只要任一目标受本次停用影响就必须列出并经用户确认暂停，禁止静默失效或预览漏列后在运行时整单拒绝；预存缺失的 LG 局域网目标在电视类型未变动时不误报受影响。恢复重验暂停定时时，先执行 ADR-0019 `sourceScopes` 匹配（不匹配归入 `partitionForeign`，纯 LG 局域网定时豁免），再展开设备群组核验目标：所需连接/账号作用域或设备类型仍处于关闭状态（或连接暂不可用）时保持暂停（`keepPaused`）；所需能力已恢复但目标设备/场景已不存在（或群组已空）时禁止永久隐藏，统一转入可见的错过确认流程（`moveToMissed`，与 ADR-0019 第 8 条一致），其余按触发时间恢复武装或转入错过确认。
4. **设备类型开关是显示与资源偏好，不是安全边界**：对应安全提醒开启时，宿主在安全保留集中继续读取传感器、门锁、阀门、插座、空调等告警信号，仅从面板、搜索、AI 目录、伴生快照（ADR-0013）与控制入口撤下。所有控制写入在进入确认判定前先经宿主写入门核验当前可用集合（设备索引记录必填字段双端一致，缺字段按不可用拒绝）——目标不在可用集合时立即零写入拒绝，明确区分「该设备类型已关闭」「设备不存在」以及平台连接停用与单账号/单连接作用域停用（`connectionScopeDisabled`），通过后继续执行锁屏守卫与设备级高风险二次确认。
5. **分阶段落地（ADR-0006）**：P1a 仅交付零运行行为变化的共享能力清单、双端纯解析映射与门禁；引用判决黄金语料（P1b）及各连接、设备类型、功能启停切片按后续工作包渐进接入。

## 与既有 ADR 的关系

- **ADR-0020**：直接承接其封闭 `HomeBackend` 与 `HomeProvider` 接缝，不回退为开放注册表或通用表单描述。
- **ADR-0003 / ADR-0006**：`CapabilityManifest` 纯解析留在 `MijiaCore`（支持 Linux 单测），双端以共享清单和门禁对齐契约。
- **ADR-0008 / ADR-0013 / ADR-0019**：保留现有双源去重、伴生令牌隔离与定时 `sourceScopes` 分区规则，宿主在此之上叠加引用暂停与写入门。

## 后果

- 新增或调整内置连接、可选功能或设备类型时，必须同步更新 `Shared/capability-manifest.json`、`docs/capabilities.json`（如涉及对外能力行）及 Swift/TS 穷尽映射，否则静态门禁直接阻断。
- 安全告警评估与控制写入门留在宿主单点把关，避免裁剪展示层时削弱安全策略。

## 重启条件

1. 未来确实需要评估进程外扩展协议（如独立进程 MCP/HTTP 桥）时，按 ADR-0020 重启条件另立 ADR，不在宿主进程内加载外部代码。
2. 决定将 LG 局域网电视并入统一连接组合或修改跨源优先级时，另立 ADR。

## 相关

- `Shared/capability-manifest.json`、`Sources/MijiaCore/CapabilityManifest.swift`、`windows/src/core/capabilityManifest.ts`、`scripts/check_capability_manifest.py`、`docs/capabilities.json`
- `Sources/MijiaCore/CapabilityReferenceVerdict.swift`、`windows/src/core/capabilityReferenceVerdict.ts`、`Tests/Fixtures/capability_selection_golden.json`
- `Tests/MijiaCoreTests/CapabilityManifestTests.swift`、`Tests/MijiaCoreTests/GoldenCorpusTests.swift`、`windows/tests/capabilityManifest.test.ts`、`windows/tests/capabilityReferenceVerdict.test.ts`
