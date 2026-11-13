# ADR-0020：连接后端保持封闭集合，把散落的后端分支收进一张描述表；Windows 补上 `HomeProvider` 接缝

日期：2026-11-13　状态：已接受（关联 ADR-0002、ADR-0003、ADR-0006、ADR-0008、ADR-0017、ADR-0019）

## 背景

维护者提出两个设想：把 `windows/` 拆成独立仓库；以及「一切皆插件」，让 Home Assistant、米家、AI、语音识别都能像添加 provider 一样接入。本 ADR 只回答其中与**连接后端**有关的部分，并顺带记录拆仓的结论。AI 提供方清单与语音识别各自另开 ADR。

## 事实核对（2026-11-13，`main` 于 `9a4a0afa`）

每条都给出可重跑的命令。

### 1. 两端提交耦合度

近三个月共 596 次提交，其中约 175 次改了 `windows/`；这 175 次里 97 次同时改了 `Sources/`，49 次同时改了 `Tests/Fixtures/`。

```bash
git log --since="3 months ago" --name-only --format='format:@@@' | awk '/^@@@$/{if(w&&m)b++; if(w&&!m)o++; if(w&&f)x++; w=0;m=0;f=0;n++;next} /^windows\//{w=1} /^Sources\//{m=1} /^Tests\/Fixtures\//{f=1} END{print b,o,x,n}'
```

Windows 测试直接读取 `Tests/Fixtures/` 下 16 个共享语料文件；`scripts/` 与 `.github/workflows/` 里有 18 个文件引用 `windows/`。

### 2. Swift 端已有接缝，但只有两个槽位

- `HomeProvider` 协议（`Sources/MijiaCore/HomeProvider.swift`）已有 6 个实现：`HAWebSocketProvider`、`MiCloudProvider`、`MiAccountsProvider`、`DualSourceHomeProvider`、`DemoHomeProvider`、`MockHomeProvider`。
- 组合点写死为两个具名参数：`HomeStore.makeComposite(homeAssistant:xiaomiCloud:...)` 构造 `DualSourceHomeProvider(homeAssistant:xiaomiCloud:...)`。
- `.homeAssistant` / `.xiaomiCloud` 字面量在 `Sources/` 出现 127 处、分布于 21 个文件。其中 50 处在 `DualSourceHomeProvider.swift`（30）与 `DeviceDeduplicator.swift`（20），属于 ADR-0008 的成对合并规则，本来就该按源区分；其余约 77 处散在 `HomeStore` 与界面层。
- 「哪些源当前生效」这条判断被原样抄了三遍：`HomeStore+Backend.swift` 的 `makeLiveProvider()`、`MenuBarPanelController.swift`、`UnsupportedDeviceScanner.swift` 都写着 `hasHASource || (!hasMiSource && homeBackend == .homeAssistant)` 及其对称式。

```bash
grep -rcE "\.(homeAssistant|xiaomiCloud)\b" Sources | grep -v ":0" | sort -t: -k2 -nr
grep -rnE "has(HA|Mi)Source \|\| \(!(store\.)?has(HA|Mi)Source" Sources
```

### 3. 第三个源已经存在，而且绕开了接缝

LG webOS 电视（`Sources/MijiaCore/LGWebOSClient.swift`）不实现 `HomeProvider`：`HomeStore+Backend.swift` 直接持有客户端，经 `applyLGDeviceUpdate(_:)` 在快照之后把卡片插进面板。后果已经记在别处——`GLOSSARY.md` 的 `deviceBackends` 条目注明 LG 电视在表里没有条目、回退到 `homeBackend`；ADR-0019 第 11 条为它单开了「不推进 `snapshotGeneration`」的例外。这是「加一个源要付出什么」的现成样本。

### 4. Windows 端没有接缝

`windows/src/core/` 里 `HomeAssistantClient` 与米家客户端是两个互不相干的类，没有共同接口。界面层直接按 `settings.connectionMode === "homeAssistant"` / `"xiaomiCloud"` 分支，共 81 处、16 个文件，集中在 `windows/src/ui/app.ts`（23）、`cameraLive.ts`（10）、`appLifecycle.ts`（9）、`cloudRefresh.ts`（8）。Windows 也没有双源合并（ADR-0008 标注为先落地 macOS）。

```bash
grep -rcE "\"(homeAssistant|xiaomiCloud)\"" windows/src | grep -v ":0" | sort -t: -k2 -nr
```

## 备选方案

1. **运行时插件**：后端编成可动态加载的包，第三方可分发。插件接口要在 Swift 与 TypeScript 各维护一份（ADR-0006 的一致性成本翻倍）；插件代码会接触令牌、钥匙串与设备控制；macOS 公证后的进程加载外部代码还要动签名体系（ADR-0005）。目前没有第三方后端作者。
2. **开放注册表**：`HomeBackend` 改成字符串标识，后端在启动时自行注册。失去 `switch` 的穷尽检查——现在加一个枚举值，编译器会指出所有没处理的地方，这正是封闭集合的好处。持久化键 `home_backend` 与 `deviceBackends`、源固定表里已存的原始值也要迁移。
3. **封闭集合 + 描述表**：`HomeBackend` 仍是枚举，每个值对应一条描述，散落的分支改成查表；Windows 补上与 Swift 同形的 `HomeProvider` 接口。加后端仍要改代码、发版，但改动集中。
4. **维持现状**。Windows 的 81 处分支继续增长；Swift 的三份重复判断继续各自演化。

## 决定

选择方案 3。

1. **`HomeBackend` 维持封闭枚举**，取值不变（`homeAssistant` / `xiaomiCloud` / `demo`），持久化原始值不变。本 ADR 不新增任何后端。
2. **Swift 端新增 `HomeBackendDescriptor`**（放在 `MijiaCore`，只含数据与闭包，不引入 AppKit / SwiftUI，符合 ADR-0003）。每个 `HomeBackend` 值一条，由一个穷尽 `switch` 返回，因此漏写会编译失败。初始字段只收已经重复出现的东西：
   - 显示名（现 `HomeBackend.title`）；
   - 是否已配置（现 `hasHASource` / `hasMiSource`）；
   - 连接源标识（ADR-0019 的 `demo` / `ha:<url>` / 米家账号）；
   - provider 工厂（现 `makeHAProvider` / `makeMiAccountsProvider`）。
   
   字段清单在落地 PR 里按实际收敛结果定稿，原则是「至少两处在用才进表」。
3. **「当前生效的源」只算一次**：`HomeStore` 提供唯一的计算属性，`makeLiveProvider()`、`MenuBarPanelController`、`UnsupportedDeviceScanner` 三处改为读取它。
4. **Windows 端新增 `HomeProvider` 接口**（`windows/src/core/`），方法与 Swift 协议对齐到 Windows 实际用到的子集：快照、执行指令、刷新、摄像头流、关闭。现有两个客户端各包一层实现；界面层的 `connectionMode ===` 分支改为调用 `host.provider`。无法归入接口的分支（如仅米家有的登录过期处理）保留，并在 PR 里列出。
5. **设置界面不做表单描述驱动**。Home Assistant 是地址 + 令牌 + 明文同意 + 局域网发现，米家是扫码登录 + 多账号 + 地区，差异太大，通用表单描述盖不住。两端界面层各保留按后端分开的设置区块，只在一处按后端选择。
6. **不改合并规则**。`DualSourceHomeProvider` 与 `DeviceDeduplicator` 里的 50 处成对逻辑不在本 ADR 范围内，ADR-0008 的优先级规则原样保留。
7. **不拆仓**。`windows/` 留在本仓库。第 1 节的耦合度说明拆仓会让一半以上的 Windows 改动变成跨仓协调，并且使 ADR-0006 的「共享语料 + 双端同 PR」无法执行。发版节奏的问题用独立 tag 与独立发布工作流解决，不在本 ADR 展开。

## 落地顺序

纯重构，行为不变；每个 PR 控制在约 800 行内。

1. **Windows 接口**（1–3 个 PR，按文件分）：先 `core` 里的接口与两个实现，再逐个迁移 `ui/` 文件。验收：`windows/tests/*.test.ts` 与共享语料断言全部不变地通过；`grep` 到的 `connectionMode ===` 处数下降并在 PR 里报数。
2. **Swift 描述表**（1 个 PR）：第 2、3 条。验收：`bash scripts/check.sh` 全绿且快照基线零差异；三份重复判断只剩一份。
3. **LG 电视并入接缝**：不在本 ADR 决定。它要把组合点从两个具名槽位改成多源，并触及 ADR-0008 的合并与 ADR-0019 第 11 条的例外，需要单独的 ADR。前两步完成后再评估，届时它就是描述表是否够用的检验。

步骤 1 与 2 互不依赖，可并行；按 ADR-0006 属于分阶段落地，以本节为标注。

## 与既有 ADR 的关系

- **ADR-0017**（不引入 HomeKit 后端）：不冲突。其决定第 1 条「`HomeBackend` 维持三档」原样保留；本 ADR 不构成重启条件，降低加后端的改动量也不改变 HomeKit 的 SDK 与签名门槛。
- **ADR-0006**（双端各自实现）：不冲突，且是不拆仓的直接依据。本 ADR 让两端的后端边界同形，缩小结构性漂移。
- **ADR-0008 / ADR-0019**：不改规则，只把 ADR-0019 的连接源标识的来源集中到描述表。
- **ADR-0003**：描述表留在 `MijiaCore`，不带界面类型。

## 后果

- 加一个后端的改动变成：加枚举值、加一条描述、加一个 provider 实现，再处理编译器指出的剩余 `switch`。仍然要发版，不是用户可自行安装的插件。
- Windows 界面层不再知道后端细节，为将来落地双源合并留出位置；本 ADR 不承诺落地。
- 代价：两端各多一层间接；Windows 迁移期间 `ui/` 文件改动面大，容易与并行分支冲突，需要按文件排队合并。
- 「一切皆插件」在后端这一块收敛为「封闭集合、集中描述」。如果将来出现第三方后端作者，走进程外协议（本地 HTTP 或 MCP，`scripts/mijia-mcp` 是现成起点）另行评估，而不是在进程内加载代码。

## 重启条件

1. 出现愿意维护第三方后端的外部作者，且封闭集合成为实际阻碍；或
2. 步骤 3 评估时发现描述表盖不住 LG 电视这类局域网单设备源；或
3. Windows 有了独立维护者或两端有意不再追求一致——此时重新评估第 7 条的不拆仓。

## 相关

- `Sources/MijiaCore/HomeProvider.swift`（`HomeBackend`、`HomeProvider`）、`Sources/MijiaCore/HomeStore+Backend.swift`（`makeLiveProvider`、`makeComposite`、`applyLGDeviceUpdate`）、`Sources/MijiaCore/DualSourceHomeProvider.swift`、`Sources/MijiaCore/LGWebOSClient.swift`
- `windows/src/core/homeAssistant.ts`（`HomeAssistantClient`）、`windows/src/core/miCloudClient.ts`、`windows/src/core/models.ts`（`HomeBackend`）、`windows/src/ui/app.ts`
- `GLOSSARY.md`：`HomeBackend（连接后端）`、`deviceBackends（卡片数据源表）`。`HomeBackendDescriptor（后端描述）`。
