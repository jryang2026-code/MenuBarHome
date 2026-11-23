# 12 Magpie 插件机制：两套插件体系、三种执行面与可迁移的能力边界

调研日期：2026-11-23
范围：本机 Magpie 0.1.4696（`/Applications/magpie.app`、`~/.cache/magpie/`、`~/.config/magpie/`）；`yetone/magpie` 源码 `d510779`（2026-11-23 13:40 +0800）；`magpie-community/plugins` 源码 `18fa146`（2026-11-23 10:14 +0800）；npm `@magpie-community/*` 元数据。
方法：按 `00-BRIEF.md` 三层执行——第一层读官方文档与市场清单，第二层读社区插件完整源码，第三层追到宿主 `host.js` / `host.go` / `store.go` / `dist.go` / `page.go` 的具体实现与本地缓存结构。
只读声明：未运行克隆仓库中的任何脚本、构建或安装命令；未打印任何密钥、token、cookie、账号邮箱或 session 内容，涉及 `plugin-auth.json` 等文件时只读取字段名与结构。

> 与 `02-plugin-architectures-isolated.md` 的分工：02 号已横向对比 Homebridge / ioBroker / Matterbridge / Node-RED / HA+HACS / Scrypted / Hubitat，并给出进程外适配器架构总览。本文不重复那张对比矩阵，只做两件增量的事：把 Magpie 这套**真实跑了 127 个插件**的机制拆到实现层；在其证据上补全 02 号只 sketched 的协议细节——凭据租约、健康/额度、推送通道、失败语义与版本/下架治理。

---

## 0. 结论先行

1. **Magpie 有两套互不混用的插件系统**：Go 内置插件 `pluginrt`（编译期、进程内、可开关的官方功能，Manifest 带 `API "^1"` 与 `Requires/Provides` 服务依赖）与 OpenCode v1 插件（npm/git/目录；三种执行面：Bun 子进程 / moejs / iframe）。前者是“官方功能的模块化”，后者才是“第三方扩展”。【源码】`yetone/magpie:docs/subsystems/plugin-runtime.md:1-30`

2. **第三方 provider 代码不进入主进程，但 middleware/agent 是例外**：provider / gateway-hook / tool 插件装进一个独立的 Bun 子进程（plugin host），与 Magpie 用 stdin/stdout 的行分隔 JSON 通信；只做 middleware / routing / agent 的包在 Magpie 网关进程里用 Go 内嵌的 moejs 跑（它坐在每个请求与流事件上，进程外 RPC 太慢）；page 则是沙箱 iframe。三种执行面，权限与 API 各不相同。宿主侧（Bun 面）有 24 个 RPC handler，外加流式 `fetch` 的 `abort`/`credit` 控制与 `log`/`toast`/`auth`/`usage`/`load`/`signIn` 事件。【源码】`yetone/magpie:internal/plugin/host.js:1-27`、`host.js:3676-3778`、`docs/subsystems/gateway-middleware.md:1-10`

3. **插件包形态就是 npm 包，没有另造格式**：入口按 OpenCode 规则解析（`exports["./server"]` → `main` → `exports["."]` → `index.*`），模块导出 `async (input, options) => hooks`；Magpie 只在 `package.json` 增加 `magpie.*` 声明（icon/name/summary/hooks/middleware/agent/page/permissions/options/maxConcurrency），OpenCode 会忽略这些字段，所以同一份包可以双栖。【源码】`yetone/magpie:internal/plugin/host.js:1429-1474`；【文档】<https://usemagpie.ai/docs/plugins#package>

4. **能力面窄且声明式**：插件只能实现 `config` / `auth`（methods、loader、usage、refresh、checkin、calls、options）/ `provider.models` / `chat.headers` / `tool` / `search` / `agent` / `page` / `hooks` / `middleware`；OpenCode 的 `event`、`chat.params` 等钩子 Magpie **不调用**。插件声明“我能做什么”，宿主决定“给不给、什么时候给”。【文档】<https://usemagpie.ai/docs/plugins#input>

5. **`client` 是默认拒绝的能力白名单**：只实现 `auth.set/remove`、`tui.showToast`、`app.log`、`config.get`，其余任何 `client.*` 都通过 Proxy 落到 stub，返回 `{data: undefined}`；每次调用还包在 `AsyncLocalStorage` 的账户作用域里，插件拿不到别的账户的凭据。【源码】`yetone/magpie:internal/plugin/host.js:1347-1417`、`host.js:1218-1268`

6. **隔离是“崩溃隔离 + 超时 + 内存回收”，不是安全沙箱**：所有走 Bun 面的插件共享一个 Bun 进程，拥有当前用户权限（`fs`、`net`、`Bun.$`）；官方文档原话是 “Bun plugins have host privileges; install trusted code.”。单插件加载 20s、模型列表 20s、单 hook 默认 1s（可调 0.1–30s）、hook 链预算 2–10s、tool 55s；宿主 RSS 超 512MB 且启动满 10 分钟后换新进程；崩溃后下一次调用自动重启，若新 Bun 启动即死则回退上一版。【源码】`host.js:354-355, 1613-1618`、`host.go:1208, 1313-1315`；【文档】<https://usemagpie.ai/docs/plugins#run>

7. **供应链是“列表审核 + 传输完整性”，不是代码签名**：安装走 `bun add --ignore-scripts`（不跑 postinstall）；社区包可从 npm 或社区仓 `dist` 分支的 tarball 安装，tarball 只有 sha512 与 `index.json` 一致才装；市场是社区仓 `registry.json` 的人工 PR 审核列表（6 小时拉取 + 内置副本），另有 GitHub `magpie-plugin` topic 的“未审核”区；下架（withdrawn）只拦新用户，老用户保留并提示风险。【源码】`internal/plugin/store.go:876`、`dist.go:22-36, 304-340`、`market.go:34-45, 233`、`withdrawn.go:30-36`；【文档】<https://usemagpie.ai/docs/plugins#publish>

8. **版本策略是“spec 保持 `@latest`、实际安装精确 pin”**：`plugins.json` 里写 `@latest`，`plugins/package.json` 与 `bun.lock` 落到精确版本 + sha512；社区包启动后每小时自动更新，其他包只在 UI 显示更新点；host.js 按内容 sha256 前 6 字节缓存（本机已积累 53 个历史文件），新版本不覆盖旧文件，天然可回退。【源码】`internal/plugin/updates.go:68`、`host.go:981-999`；本地证据：`~/.config/magpie/plugins/{package.json,bun.lock}`、`~/.cache/magpie/plugin-host/`

9. **UX 把“插件”当 provider 管理，而不是当代码管理**：Discover/Installed、按名字/版本/git/目录安装、更新点与 Update all、on/off、options JSON 编辑器、provider 行内的登录方式/多账户/额度卡/签到、同一 provider 冲突时显示“谁在服务”并给 `Use for` 按钮、页面插件用沙箱 iframe 且只给 3 种聚合只读权限；诊断页则是 `page` + loopback service 的组合（AtomCode 的 `diagnosticsPort`）。【文档】<https://usemagpie.ai/docs/plugins#run>；【源码】`internal/plugin/page.go:96-99`、`docs/subsystems/provider-plugins.md:209-236`、`magpie-community/plugins:packages/atomcode/package.json`

10. **对我们最有价值的结论**：Magpie 把“平台适配”拆成 **provider 契约（登录/模型/请求/额度）** 与 **宿主策略（路由、额度聚合、失败回退、UI、告警）**，插件永远不拥有策略。MenuBarHome 的平台适配器应照此切：适配器只产出**事实**（设备、状态、读数、能力标志、健康），宿主保留**判决**（写入门、危险分级、二次确认、锁屏拦截、凭据、告警）。这正好落在 ADR-0020 第 94 行与 ADR-0023 第 38 行允许的“进程外协议重新评估”方向上。

---

## 1. 两套插件系统：先分清“官方功能模块化”与“第三方扩展”

### 1.1 内置插件：`pluginrt`（Go，进程内，编译期）

`pluginrt` 是 Magpie 自己的功能模块系统，不是给第三方用的。每个内置插件在 `init` 里调用 `pluginrt.Register(Manifest)`，Manifest 的字段决定了它的边界：

| 字段 | 含义 | 对我们的映射 |
| --- | --- | --- |
| `ID` | 唯一 id，重复直接 panic | 对应 `FeatureID` / `ConnectionCapabilityID` |
| `API` | 宿主 API 的 caret 区间，如 `"^1"` | 能力清单的 `schemaVersion` 思路 |
| `Requires` / `Provides` | 服务依赖与服务供给 | 对应 ADR-0023 的 `dependsOn` |
| `Essential` | 关掉会破坏核心 | 对应“不可关”的安全保留集 |
| `Parts`（`{Slot, Key}`） | 它占用窗口的哪个插槽 | 对应设置页/面板分区 |
| `SetAt` | 设置页定位（tab + 行） | 对应设置深链 |
| `Defaults` / `Settings` | 配置默认值与 JSON Schema 来源 | 对应 `configSchema` |
| `Client` | 窗口侧脚本/样式/i18n | 对应 UI 资源（我们暂不需要） |

生命周期是 `Reconcile(on, config)`：先按“新到旧”销毁不再需要的插件（以及依赖它们服务的插件），再按依赖顺序反复应用可满足的插件；状态只有 `off` / `pending` / `active` / `failed` / `disposed`，**一个插件失败不影响其他插件**，`Apply` 失败或 panic 会回滚它注册过的东西。【源码】`yetone/magpie:docs/subsystems/plugin-runtime.md:1-30`

这套设计的关键判断是：**官方功能可以模块化，但仍然是编译期代码**。它能 import 核心包、能用 Go 类型、能进签名与公证；代价是加功能仍要发版。ADR-0020 的“封闭枚举 + 描述表”、ADR-0023 的“宿主持有内置能力选择与生命周期”，与它是同构的：我们已经有 `Shared/capability-manifest.json` + `CapabilityManifest.swift` + `capabilityManifest.ts` 这条线，缺的不是理念，而是**运行时的服务注入与失败回滚**（见 §9 差距表）。

### 1.2 OpenCode 插件：三种执行面，不是一种

第三方插件都叫 “OpenCode plugin”，但实际有**三个执行面**，权限与 API 完全不同：

| 执行面 | 承载的插件类型 | 运行时 | 能拿到什么 | 隔离程度 |
| --- | --- | --- | --- | --- |
| **Bun 子进程（plugin host）** | provider、gateway hook、tool、search | Magpie 下载并管理的 Bun（最低 1.4.2，新版本自动跟进，保留上一版回退） | Node/Bun API（`fs`/`net`/`Bun.$`）、`client` 白名单、当前账户作用域 | 进程边界（崩溃隔离），**不是**安全沙箱 |
| **moejs（Magpie 网关进程内）** | middleware、routing strategy、agent bridge | Go 内嵌的 JS 引擎 [moejs](https://github.com/MoeForge/moejs)，经 `jsmod` 编译加载 | 网关请求/回复、路由与 usage 行；没有 Node/Bun 的通用 `fs`/`net`/`Bun.$`（绑定由 `jsmod` 决定） | 进程内，靠引擎能力面与 opt-in 控制 |
| **沙箱 iframe** | page（侧边栏页面、panel） | 宿主 WebView 的 sandboxed frame | 只能通过 `_magpie/bridge.js` 读 3 种聚合数据 | `connect-src 'none'` + 权限白名单 |

**为什么 middleware 反而在进程内**：它坐在**每个** agent 请求与每个流式事件上，进程外一次 RPC 的延迟会摊到所有请求；而它又不需要 Node/Bun 的文件/网络能力，所以用 Go 内嵌的 moejs 跑，既能直接操作请求体，又拿不到 Bun 的完整系统权限。provider 插件则相反：要发网络请求、要跑厂商 SDK、要处理流式响应，必须在 Bun 里，于是被推到进程外。【源码】`yetone/magpie:docs/subsystems/gateway-middleware.md:1-10`、`docs/subsystems/plugin-runtime.md:1-30`；本机 App 的 `THIRD_PARTY_NOTICES:4-7` 也写明 “magpie is built with moejs … a JavaScript engine that runs gateway plugins”。

- 包形态：npm 包、git 仓库或本地目录；Bun 面还兼容 [pi](https://github.com/earendil-works/pi) 的 provider 包（`pi.js` / `pi-<hash>.js`）；
- 通信（Bun 面）：stdin/stdout 一行一个 JSON，`{id, method, params}` → `{id, result}` / `{id, error}`；流式 `fetch` 额外有 `head` / `chunk` / `credit` / `abort`；
- 信任：Bun 面与 Magpie 同用户、同文件系统权限，没有 per-plugin 沙箱；moejs 面没有 Node 系统 API，但仍与网关同进程；page 面有真正的 iframe 沙箱。安全整体靠审核、签名（仅分发 tarball 的 sha512）与用户“安装即信任”。

市场里 127 个条目按 kind 分布为：provider 51、agent 29、middleware 24、page 15、tools 8（`registry.json` 统计，2026-11-23）。【源码】`magpie-community/plugins:registry.json`；本地 `~/.cache/magpie/plugin-market.json` 同为 127 条。

**为什么两套并存**：内置插件解决“官方功能太多、用户只想开一部分”的问题，可以放心 import 核心；OpenCode 插件解决“长尾 provider 太多、官方写不过来”的问题，必须隔离。Magpie 的具体取舍是：**provider 面推到 Bun 子进程；middleware 面用受限的 moejs 留在网关进程；page 面关进 iframe**。这比“所有第三方代码都进子进程”更务实，但也意味着它接受“第三方 middleware 与网关同进程”的风险——因为它给 middleware 的 API 里没有 `fs`/`net`/`Bun.$`。我们的 ADR-0023 更严格（进程内零第三方代码），所以不该照搬 moejs 这一层，只应照搬“按能力面选择执行面”的判断方法：需要系统权限的走子进程，只需要数据的走受限通道，需要 UI 的走 iframe。

---

## 2. 包形态与发现：一个 npm 包，三种来源，两层审核

### 2.1 入口解析：完全沿用 OpenCode 规则

`entries(target)` 的查找顺序是：`package.json` 的 `exports["./server"]` → `main` → `exports["."]` → `exports` 字符串 → `index.ts` / `index.tsx` / `index.js` / `index.mjs` / `index.cjs`；如果目标本身是文件，就直接加载该文件。模块导出可以是 `export default {id, server}`（OpenCode v1），也可以是任意多个函数 / `{server}` 对象；**每个导出函数都会被当成一个插件调用**，所以社区约定把测试用的内部函数挂到 `_internal` 对象上，不直接导出。【源码】`yetone/magpie:internal/plugin/host.js:1429-1474`；`magpie-community/plugins:packages/river/index.mjs:238`（`export const _internal = {...}` 的用法）

一个最小 provider 插件的骨架（来自社区 `river` 包，已删减）：

```js
function createPlugin({ fetchImpl = globalThis.fetch } = {}) {
  return {
    config: async (cfg) => {
      cfg.provider ??= {}
      cfg.provider["river"] ??= {
        name: "River",
        npm: "@ai-sdk/openai-compatible",
        api: "https://api.river.ai/v1",
        models: { /* 首次启动的引导模型 */ },
      }
    },
    auth: {
      provider: "river",
      methods: [{ type: "api", label: "River API key", placeholder: "rv_…" }],
      async loader(getAuth) {
        const auth = await getAuth()
        if (auth?.type !== "api" || !auth.key) return {}
        return { baseURL: "https://api.river.ai/v1", apiKey: auth.key }
      },
      async usage(getAuth) { /* 返回 plan / windows / error / signIn */ },
    },
    provider: {
      id: "river",
      async models(provider, { auth } = {}) { /* 账户级模型发现 */ },
    },
  }
}
export const RiverPlugin = async () => createPlugin()
```

【源码】`magpie-community/plugins:packages/river/index.mjs:155-238`

这段代码把契约讲得很清楚：`config` 声明 provider 与引导模型；`auth.methods` 声明登录方式；`loader` 返回 AI SDK 所需的 `baseURL/apiKey/headers/fetch`；`usage` 返回额度窗口；`provider.models` 做账户级模型发现。**插件不拥有路由、重试、额度聚合、UI**，这些都在 Magpie 侧。

### 2.2 `package.json` 里的 `magpie.*`：增量声明

| 字段 | 作用 | 备注 |
| --- | --- | --- |
| `magpie.icon` | Discover 卡片、Installed 行、provider 图标 | https URL 或 `data:image/...`，≤1MB |
| `magpie.name` | 社区列表没起名时的显示名 | 一行 ≤80 字节，不参与按名解析、不带“已审核” |
| `magpie.summary` | 未审核区的卡片摘要 | `{en, zh}`，每语言 ≤300 字节 |
| `magpie.maxConcurrency` | 每个账户的并发上限 | 1–1000，用户设置可覆盖 |
| `magpie.hooks` | 异步 gateway hook 入口 | 只有 `onRequest/onResponse/onSignIn`，可在 Bun 里等 I/O |
| `magpie.middleware` / `magpie.gateway` | 同步 gateway middleware | 运行在 Magpie 网关进程，可 `ctx.reject` |
| `magpie.agent` | 把某个 agent 的配置桥接进 Magpie | 可无 `main`/`exports` |
| `magpie.page` | 在侧边栏加一个页面 | 沙箱 iframe + 声明式 permissions |
| `magpie.permissions` | 页面/面板可申请的读 | 只有 `usage:summary`、`usage:day`、`providers:list`，均不含秘密 |
| `magpie.options` | 包级 options 的示例 JSON | Installed 行的 Options 编辑器起点 |

【源码】`yetone/magpie:internal/plugin/page.go:96-99`、`internal/plugin/market.go:428-446`；【文档】<https://usemagpie.ai/docs/plugins#package>

这张表的取舍很值得学：**能声明 UI 元数据、能声明读权限、能声明并发上限，但不能声明“我安全”“我可以写”**。页面的读权限是白名单枚举，且明确“None of them carries a secret”。

### 2.3 市场：`registry.json` 是产品，不是代码

- 官方列表在 `magpie-community/plugins` 仓库的 `registry.json`，条目字段：`package`、`name`、`icon`、`providers`、`community`、`replaces`、`kind`、`summary{en,zh}`；`kind` 为 `middleware` / `agent` / `tools` / `page`，没有 `kind` 就是 provider。
- Magpie 每 6 小时拉一次，失败就用内置副本（`//go:embed market.json`），所以断网也能看到列表。
- 新条目要开 PR 人工审核；同一个“channel”（厂商服务）已有条目时，新包必须说明差异，否则不合并。
- 发布有两条通道：npm，以及社区仓 `dist` 分支的 tarball（`index.json` 给每个版本的文件名与 sha512）。Magpie 先问 npm，npm 没有该版本时才走 dist；**tarball 只有 sha512 匹配才安装**。
- 另有 GitHub `magpie-plugin` topic 的“未审核”区：仓库根目录有 `package.json`、入口文件已提交即可被索引，卡片明说 “reviewed by no one”，名字/摘要若来自包自身会标 “Its own words”。
- 下架（withdrawn）只挡新用户：`Add` 时拒绝，老用户保留并收到风险提示与替代品（目前只有 Antigravity 一条，替代为本地 `agy` CLI 插件）。

【源码】`internal/plugin/market.go:34-45, 233`、`dist.go:22-36, 304-340`、`withdrawn.go:30-36`；`magpie-community/plugins:README.md`“The market”“Publishing”；【文档】<https://usemagpie.ai/docs/plugins#publish>

### 2.4 本地证据：一个真实安装态长什么样

- `~/.config/magpie/plugins.json`：8 条 `spec`，全部是 `@latest` 或裸包名；这就是“用户意图”。
- `~/.config/magpie/plugins/package.json`：8 个依赖全部 pin 到精确版本（例如 `0.2.48`、`0.1.24`）。
- `~/.config/magpie/plugins/bun.lock`：每个包带 `sha512-...` integrity；这是“实际安装态”。
- `~/.config/magpie/plugin-updates.json`：按时间记录 `from → to`，能看到 11-15 到 11-23 之间的连续小版本升级。
- `~/.cache/magpie/plugin-host/`：53 个 `host-<12hex>.js`，是历次 App 版本内嵌 host 脚本的内容寻址缓存；不是用户插件。
- `~/.cache/magpie/bun/{1.4.4,1.4.5}` + `state.json`：Bun 运行时也保留上一版，供崩溃回退。
- `~/.cache/magpie/{plugin-market.json,plugin-npm.json,plugin-github.json}`：市场列表 127 条、npm 元数据、GitHub 检索 547 条。
- `~/.config/magpie/plugin-providers.json`：14 个 provider 的“上次列出的模型/账户/登录方式”缓存，让 Magpie 不必每次启动都问插件。
- `~/.config/magpie/plugin-checkin.json`、`plugin-calls.json`、`plugin-tools.json`、`plugin-searches.json`：按能力分文件的状态，互不污染。

这组文件的划分值得直接抄：**意图（plugins.json）/ 安装态（package.json + lock）/ 运行时缓存（plugin-providers.json）/ 能力状态（checkin/calls/tools/searches）** 四层分离。我们现在的 `providers.json`、`providers-state.json`、`models.json` 也有类似分层，但没有“安装态”这一层，因为还没有可安装的适配器。

---

## 3. 宿主如何加载：一个 Bun 子进程、24 个 RPC、四道时间闸

### 3.1 启动链

1. `hostFile()` 把内嵌的 `host.js` 按 `sha256` 前 6 字节写到 `~/.cache/magpie/plugin-host/host-<hash>.js`，内容相同则复用；新 App 版本自然产生新文件，旧文件不删，便于回退/排查。【源码】`internal/plugin/host.go:981-999`
2. `Bun(ctx)` 找可用的 Bun：最低 1.4.2，按平台选 build（musl / baseline / arm64），下载后校验 `bunSums`；新版本自动跟进，`state.json` 保留 `current`/`previous`。
3. `bunCommand(ctx, bun, settings.Dir(), "run", js)` 拉起子进程；`StartTree` 让它在自己的进程树里，插件再 `Bun.spawn` 的东西会随宿主一起结束；stdout/stderr 分开读，避免插件留住的 fd 把宿主卡死。【源码】`host.go:1089-1180, 505-540`
4. `init` 调用带 2 分钟总超时，参数包括 `authPath`、`modelsDevPath`、`piPath`、`directory`、`config`、`prefer`、`options`、`plugins[{spec,target,options,gateway}]`、`loadMillis`、`listMillis`、`heavy{mb,afterMillis,everyMillis}`。【源码】`host.go:1188-1235`

### 3.2 加载：并行、各自超时、失败隔离

`loadPlugins(list)` 对每个插件并行执行 `one(p, isPi)`，每个都有 `inTime(..., loadWait=20s)`；超时/抛错只把该插件标成 `{spec, error}`，其他插件照常加载。加载顺序仍按 `plugins.json` 的顺序保留，因为“后面的插件覆盖前面的 hook”是 OpenCode 的语义。【源码】`host.js:1476-1560`

`config` hook 是例外：它们**串行**执行，因为后一个可能在前一个的 `config.provider[id]` 上继续搭；每个也有 20s 上限，失败只记日志。对于“一个 provider 被两个插件同时登录”的情况，`auths()` 取 `plugins.json` 的 `prefer`，否则取列表里最后一个（与 OpenCode 一致）；只有“服务方”的 `provider.models` 会跑，但所有插件的 `config` 都会跑。【源码】`host.js:1553-1575`；`docs/subsystems/provider-plugins.md:209-236`

### 3.3 RPC 面：24 个 handler + 流式 fetch

宿主 → 插件的 handler（`const handlers`）：

| 组 | 方法 |
| --- | --- |
| 初始化/状态 | `init`、`gatewayStates`、`reload`、`setProviderOptions` |
| 登录 | `providers`、`prompt`、`validate`、`authorize`、`callback`、`importFiles`、`cliInstalled`、`installCli`、`import`、`take`、`signOut`、`keepSignedIn` |
| 模型/请求 | `load`、`usage`、`check`、`calls`、`apiKey` |
| 工具/搜索 | `tool`、`search` |

另有 `fetch` 的流式协议：`{id, event:"head", status, headers}` → `{id, event:"chunk", data(base64)}` → `{id, result:null}`；`abort` 取消一个 fetch，`credit` 把读者已经消费的字节还给窗口。窗口初始 512KB，单帧 64KB，单行上限 32MB，帧开销 2048B；这样慢读者会反压上游，而不是让宿主无界缓冲。【源码】`host.js:1-27`、`host.go:160-185`

插件 → 宿主的非请求事件：`log`、`toast`、`auth`、`usage`、`load`、`signIn`。这些事件让插件可以“报告事实”，但不能改宿主策略：`usage` 只进账本，`load` 只进路由参考，`signIn` 只标记账户。

### 3.4 时间闸与内存闸

| 闸门 | 值 | 超时后的行为 |
| --- | --- | --- |
| `init` 总时限 | 2 分钟 | 整个 host 启动失败，`get()` 返回错误；下一次调用会重启 |
| 单插件 load / 单个 config hook | 20s | 该插件 `{spec,error}`，其他插件继续 |
| 单次 `providers` 列表（每个 models hook） | 20s | 该 provider 标记 `fellBack` + `listError`，沿用上一次列表 |
| 单 hook（gateway） | 默认 1000ms，`gatewayTimeoutMs` 夹到 100–30000ms | 该 hook 失败，请求继续（不会被拒） |
| hook 链总预算 | 2–10s，或最长单 hook 的 timeout（更长时） | 同上 |
| tool 执行 | 55s | 返回超时错误，host 继续服务 |
| host RSS | >512MB 且启动满 10 分钟，每分钟检查 | 通知宿主；宿主为后续调用起新 host，旧 host 答完在途请求后退役 |
| Bun 启动失败 | 连续崩溃 | 回退到 `previous` Bun，并把新版本“set aside” |

【源码】`host.go:1208, 1313-1315`、`host.js:354-355, 362-378, 1613-1618`；`docs/subsystems/plugin-tools.md:1-30`

### 3.5 账户作用域：插件只能看见“当前这一单”

`host.js` 用 `AsyncLocalStorage` 维护 `scope`（账户）、`via`（代理）、`reach`（可达性）、`listing`（列表）、`signInSignal`（登录取消）等上下文。`inScope(provider, key, fn)` 在调用插件前把 `{provider, key, had}` 放进 store；`client.auth.set` 只写这个账户；`getAuth()` 只返回这个账户的副本。`plugin-auth.json` 的写入是 0600 权限、临时文件 + fsync + rename，且“运行中被登出的账户不会被 hook 重新写回”。【源码】`host.js:999-1080, 1218-1268, 1347-1417`

这一点是整个模型里最值得抄的：**不是“给插件一个 auth 对象”，而是“给插件一个只能碰当前账户的运行时”**。多账户、token 轮换、登出竞态，都因此收敛到宿主一处。

### 3.6 它不是什么：不是沙箱

- Bun 面上的所有插件共享一个进程与全局对象，能读彼此的临时文件、`process.env`，也能改 `globalThis`；
- 插件拥有当前用户权限，可以 `fs.readFile` 任何用户可读文件、`Bun.spawn` 任意进程、`net.connect` 任意地址；
- 官方文档明确写 “Bun plugins have host privileges; install trusted code.”；
- 唯一的“隔离”是：插件代码不在 Magpie 主进程内，崩溃不会带崩 UI；以及页面插件另有一套 iframe 沙箱（见 §4.10）。

【文档】<https://usemagpie.ai/docs/plugins#gateway-request>；【源码】`host.js:29-40`（直接 `import fs/net/http2/tls`）

所以 Magpie 的信任模型是“**审核 + 用户知情 + 进程边界**”，不是“能力沙箱”。这对我们的直接含义是：如果 MenuBarHome 要跑第三方适配器，**不能假设适配器是善意的**，必须把写入门、危险分级、凭据、网络出口留在宿主；Magpie 靠“插件只做 provider、不做策略”把风险压到可接受，我们要靠“适配器只做驱动、不做判决”达到同样的效果。

---

## 4. 插件可声明的能力：逐项拆

### 4.1 Provider 与模型发现

- provider id 来自 `auth.provider`；如果 models.dev 有同 id，就以 models.dev 为起点，否则用 `config` hook 声明 `{name, npm, api, models}`。
- `npm` 决定 AI SDK 协议：`@ai-sdk/anthropic` → Messages，`@ai-sdk/openai` → Responses，`@ai-sdk/google` → Gemini，其他 → Chat Completions。
- `provider.models(provider, {auth})` 按账户列模型；每个账户只服务自己列出的模型；失败的语义有三种：返回 `provider.models` 原样（沿用旧列表）、抛错（`fellBack`）、或返回带 `Symbol.for("magpie.fellBack")` 的列表。
- 模型字段除 OpenCode 的 `id/name/limit/capabilities/cost/variants` 外，Magpie 还读 `free`、`rate`、`rateWas`、`serviceTiers`、`also`（同一模型还支持哪些 API）、`capabilities.output`（text/image/video/audio）。

【源码】`yetone/magpie:internal/plugin/providers.go:72-231`；【文档】<https://usemagpie.ai/docs/plugins#provider>

**设计要点**：插件只声明“模型是什么、多少钱、支持什么”，**不声明“该路由给谁”**。路由、额度聚合、失败回退、账户选择都在宿主。

### 4.2 登录方式

`auth.methods` 支持：

- `{type:"api", label, placeholder?}`：API key；可带 `authorize(inputs)` 做校验/交换；
- `{type:"oauth", label, prompts?, authorize}`：浏览器/设备码；`authorize` 返回 `{url, instructions, method:"auto"|"code", callback}`；
- `prompts`：`text` / `select` / `password`（Magpie 自有类型），支持 `when` 条件与 `validate`；
- 登录成功统一存成 `{type:"oauth", refresh, access, expires, ...}` 或 `{type:"api", key, ...}`；
- 多账户：第一个账户用 provider id，后续用 `id#xxxxxx`；
- `auth.refresh` / `refreshLead` / `rotating`：宿主单飞续期，轮换型 refresh token 永不并发；
- `auth.import` / `importFrom`：从别的 CLI/桌面应用导入登录；
- `auth.checkin` / `auth.calls` / `auth.usage` / `auth.options`：见下。

【文档】<https://usemagpie.ai/docs/plugins#signin>；【源码】`host.js:2732-2900`、`host.js:1232-1268`

### 4.3 额度 / 用量

`auth.usage(getAuth, provider)` 返回：

```jsonc
{
  "plan": "Pro",
  "user": "…",
  "until": "…",
  "renew": "auto",
  "balance": "$12.40",
  "error": "",
  "windows": [{
    "name": "5 hours",
    "used": 37,                  // 百分比；不知道就省略，绝不写 0
    "resetsAt": "…", "resetSecs": 3600,
    "span": 18000,
    "display": "370 / 1000 credits",
    "amount": 370, "limit": 1000, "unit": "credits",
    "model": "opus", "models": [], "notModels": [],
    "family": "Gemini", "pool": "Gemini",
    "aside": false,               // 用光也不停账户
    "credits": true,              // 用光后还能花额度
    "balance": 6291,              // 预付钱包
    "runsOutAt": "…", "runsOut": 120
  }],
  "resets": { "count": 2, "until": "…", "byWindow": false },
  "signIn": "kept"
}
```

【文档】<https://usemagpie.ai/docs/plugins#usage>；【源码】`internal/plugin/providers.go:1333-1365`

关键语义：`used` 缺失 ≠ 0；有 `amount/limit` 时宿主自己算份额；`aside` 只展示不参与路由；`credits` 表示“窗口用光但还有额度”；`balance` 是钱包，单位不同不互相比较。**这些都宿主解释，插件只报事实。**

### 4.4 签到（checkin）

`auth.checkin(getAuth, provider)` 返回 `{outcome, credit?, streak?, message?, until?}`；`outcome` 是 `claimed/done/ineligible/inactive/captcha/failed`。宿主按北京日调度、失败 30 分钟重试、`until` 到点再问、验证码永不代解。【文档】<https://usemagpie.ai/docs/plugins#checkin>；`docs/subsystems/provider-plugins.md:59-76`

对 MenuBarHome 的映射：这不是“签到”，而是**平台侧的每日任务/额度领取**（例如某些摄像头云存储的每日赠送）。宿主应提供同样的“声明式任务 + 宿主调度 + 结果卡片”，而不是让适配器自己起 timer。

### 4.5 插件自己的开关（options）

两种，别混：

- `auth.options: [{key, label, description?, default?, confirm?, filtersModels?, placement?}]`：provider 行内的开关；宿主校验 key（`[a-z0-9_-]{1,40}`）、label ≤60、description/confirm ≤300、最多 16 个、default 只收 `true`；支持多语言 `labels/descriptions/confirms`；`filtersModels:true` 表示开关会影响模型列表；`placement:"top"` 放在账户区上方。
- `package.json` 的 `magpie.options`：包级 JSON options，给 Installed 行的 Options 编辑器做示例；改它会重启 host。

【源码】`docs/subsystems/provider-plugins.md:83-92`；【文档】<https://usemagpie.ai/docs/plugins#package>

这给我们的启示：**“用户可配置的东西”要分两层**——影响 provider 行为的布尔开关（宿主原生 UI，可本地化、可确认）与自由 JSON（高级用户/调试）。我们的连接配置目前是手写表单，未来适配器配置也应分成这两层，而不是把一整块 JSON 丢给用户。

### 4.6 工具（tools）

插件的 OpenCode `tool` hook 会被 Magpie 收集成 MCP server：

- 工具名 `^[A-Za-z0-9_-]{1,48}$`，同名后者胜；
- `args` 支持 zod v3/v4、`.describe/.optional/.default/enum/array/nested object`，也接受裸 JSON Schema；
- 调用时宿主先按工具自己的 schema 校验参数（默认值填充、错误指出路径），再 `execute(args, ctx)`，55s 超时；
- MCP 名是 `<plugin-short-name>_<tool>`，每个插件还可以单独成为一个 Library MCP server；
- 关掉的插件不列工具、不启动 host；
- 官方明确“工具在 plugin host 里以用户权限运行，安装插件就是信任它”。

【源码】`docs/subsystems/plugin-tools.md:1-55`

对我们的映射：如果适配器要暴露“查询设备/执行场景”给 AI，正确做法不是让适配器自己开 MCP server，而是**宿主把适配器的能力投影成 MCP 工具**，并复用现有 `menumijia://` 的桥令牌与只读快照。这样工具调用仍然经过宿主的写入门。

### 4.7 搜索（search）

插件可以声明 `search` 入口，复用自己某个 provider 的登录（`auth: "<provider>"`），宿主负责选账户、续期、限流与失败回退。这是“能力复用”的好例子：搜索不是新登录，而是已有 provider 的另一种用法。【源码】`docs/subsystems/provider-plugins.md:113-116`

### 4.8 异步 gateway hook（`magpie.hooks`）

`onRequest(body, ctx)` 在路由前跑，可以等 I/O（如记忆召回），返回一个对象来增补请求；`onResponse(reply, ctx)` 是完成后的有界通知；`onSignIn(event, ctx)` 听账户登出/即将过期。

边界非常硬：

- 不能拒绝请求（拒绝是 middleware 的 `ctx.reject` 的权限）；
- 改 `model`、`stream`、客户端工具声明、tool choice 会被回滚；
- 每个 hook 拿到的是克隆，失败/返回 undefined 的修改被丢弃；
- `ctx` 只有 `protocol/model/stream/path/origin/agent/caller/session/cwd/query/kind/state/signal/report`，**没有 headers、没有凭据**；
- `origin` 由宿主派生（local / magpie-key / gateway-key / remote），不是客户端自称；
- 超时默认 1s，链预算 2–10s；启动 host 最多 11s；
- `ctx.report(code, bytes)` 只接受固定的 7 种 code 与字节数，不保留私有文本。

【源码】`yetone/magpie:docs/subsystems/gateway-request-hooks.md:1-120`；【文档】<https://usemagpie.ai/docs/plugins#gateway-request>

这是“**观察者可以丰富上下文，但不能改变安全边界**”的范本。映射到我们：适配器可以上报“门铃响了/漏水了/设备离线了”，但**不能直接发通知、不能决定严重级别、不能触发自动化**；宿主决定是否提醒、是否弹窗、是否执行联动。

### 4.9 同步 middleware（`magpie.middleware`）

与 hook 不同，middleware 跑在 Magpie 网关进程（moejs），可以 `ctx.reject(403, "...")`、改请求/回复、按事件流改 chunk。它适合“协议级改写”（模型重定向、参数覆盖、敏感词），不适合“需要等外部服务”的场景。两者分开命名（`magpie.hooks` vs `magpie.middleware`），避免一个 import `node:fs` 的 hook 被误当 middleware 加载。【源码】`docs/subsystems/gateway-request-hooks.md:14-20`；【文档】<https://usemagpie.ai/docs/plugins#middleware>

以 `think-tags` 这个完整 middleware 为例：它导出 `onEvent(ev, ctx)` 与 `onResponse(body, ctx)`，在 `ctx.state` 里按流 index 保存“可能是半个 `<think>` 标签”的 carry，只改 `delta.content` / `choices[].message.content` 等文本字段；没有改动时返回 `undefined`，网关就知道这条事件不用重写。它不碰 headers、status 或工具声明，所以能安全地挂在每个流式事件上。【源码】`magpie-community/plugins:packages/think-tags/think-tags.middleware.js:1-276`

对我们的映射：我们目前不需要“协议改写”层；但如果未来要支持“不同厂商的同一设备语义归一”，应放在宿主，而不是 middleware。

### 4.10 页面（pages）

页面是唯一有真正沙箱的扩展点：

- 页面是 HTML/CSS/JS 文件，跑在**沙箱 iframe** 里，`connect-src 'none'`、无 inline script；
- 只能通过 `_magpie/bridge.js` 与宿主说话：`magpie.ready`、`magpie.read(name, params)`、`magpie.options.get/set`（最多 1 次/秒）、`magpie.theme`；
- `magpie.permissions` 只允许三种读：`usage:summary`、`usage:day`、`providers:list`，且都不含秘密；
- 可选 host part：`main` 用 OpenCode v1 `export default {id, server}` 起一个 127.0.0.1 服务，页面 frame 导航过去；服务必须用“只有这个页面拿到的 token”守每条路由，并校验 `Host`；
- 页面可以替代内置页（Sessions/Library/Routing/Usage），也可以作为 panel 插进内置页。

【源码】`internal/plugin/page.go:1-120`；`magpie-community/plugins:README.md`“Pages”；【文档】<https://usemagpie.ai/docs/plugins#pages>

结论：**Magpie 把“能画 UI 的第三方代码”单独关进 iframe，而不是让它进 provider host**。如果 MenuBarHome 未来要开放 UI 扩展，这是唯一可接受的形态；但按 ADR-0020 第 5 条（不做表单描述驱动）与 ADR-0023（不做第三方代码插件），我建议**先不做 UI 插件**。

### 4.11 诊断页：page + host service 的组合

“诊断页”不是一个单独的能力位，而是 `magpie.page.service` + 页面沙箱的组合：

- `package.json` 的 `magpie.page.service` 声明一个 `127.0.0.1` 端口（或由插件 option 指定端口）；
- 插件的 host part 起这个只读服务，页面 frame 导航过去；
- 服务必须给每条路由加“只有这个页面拿到的 token”校验，并校验 `Host`；
- 典型做法是 AtomCode 插件：`diagnosticsPort`（默认 3478）、页面标题 “AtomCode diagnostics”、只读排障工作区、状态摘要区分“本地可读性”与“上游可用性”、脱敏后的 last error、离线自检、可展开的运行时元数据；README 明确要求报告里绝不含 token、refresh token、OAuth state、`plugin-auth.json`、邮箱、账号 id 或未脱敏的 home 路径。

【源码】`magpie-community/plugins:packages/atomcode/package.json`（`magpie.page.service`）、`packages/atomcode/README.md:45, 153, 183-185`；【源码】`internal/plugin/page.go:33-64`

对我们的映射：适配器诊断页不需要第三方 HTML；宿主可以用原生面板展示同样的信息（健康、最后错误、计数、版本、账户状态），导出时按 ADR-0015 脱敏。关键是**“诊断数据由适配器上报事实，宿主决定展示与脱敏”**，而不是让适配器自己写一个网页。

---

## 5. API 边界：插件拿到什么、拿不到什么

### 5.1 `client` 白名单

| 能力 | 行为 | 备注 |
| --- | --- | --- |
| `client.auth.set({path:{id}, body})` | 写当前作用域账户的登录 | 不合并，整体替换；登出竞态下不复活 |
| `client.auth.remove` | 删除当前账户 | |
| `client.tui.showToast` | 转成 `{event:"toast"}`，宿主决定怎么显示 | 插件不能直接弹原生窗 |
| `client.app.log` | 转成 `{event:"log"}`，进宿主日志 | |
| `client.config.get` | 返回所有 `config` hook 之后的配置 | 只读 |
| 其他任何 `client.*` | Proxy stub，返回 `{data: undefined}` | 默认拒绝 |

【源码】`host.js:1347-1417`

### 5.2 拿不到的东西

- 拿不到宿主钥匙串、`plugin-auth.json` 里别的账户、别的插件的文件；
- 拿不到请求的 `Authorization` 头（gateway hook 的 `ctx` 明确不含 headers/credentials）；
- 拿不到“用户是谁”的可靠身份（`origin` 是宿主派生的来源分类，不是用户身份；文档明确 “This classification is not a user identity”）；
- 拿不到路由/额度/失败回退的控制权；
- 拿不到“拒绝请求”的权力（hook 不能 reject，middleware 才能）。

### 5.3 插件仍然能做的“越界”事

因为共享进程 + 用户权限，恶意插件可以：

- 读 `~/.ssh`、浏览器 cookie、其他 App 的数据；
- 起子进程、装 launch agent；
- 直接访问网络，绕过宿主代理；
- 读 `plugin-auth.json`（如果它知道路径）。

Magpie 的应对不是技术隔离，而是：**审核列表 + 不签名的第三方默认标“未审核” + 安装即信任的明确文案 + 下架机制**。这也是为什么它的 provider 插件生态能跑起来：插件只做“厂商 API 适配”，不做“系统能力”，所以作恶面相对可控。【推断】

---

## 6. 版本、缓存与更新：一套为“高频小版本”设计的分发

### 6.1 版本

- `plugins.json` 存用户意图（`@latest` / 精确版本 / git ref / 本地路径）；
- `plugins/package.json` + `bun.lock` 存实际安装态（精确版本 + sha512）；
- 社区 `@magpie-community/*` 启动后一小时自动更新；其他包只在 UI 显示更新点，用户点 Update 才装；
- 固定在某个版本的 spec 不会自动跳，除非用户点 Update（会 pin 到新版本并解除 pin）；
- git 插件按 commit 比较（`git ls-remote`，最多 10 分钟一次；GitHub 走 API）；
- `dist` 分支的 tarball 只用于 npm 没有的版本/包，sha512 必须匹配。

【文档】<https://usemagpie.ai/docs/plugins#run>；【源码】`updates.go:60-100`、`dist.go:22-36`

### 6.2 缓存

- `host-<sha256[0:6]>.js`：内容寻址，App 升级不覆盖旧文件；
- `bun/install-cache`：Bun 的包缓存，Magpie 会 prune 掉不再安装的版本（否则每个插件每个版本都留一份）；
- `plugin-providers.json`：上次列出的 provider/models/accounts，启动时先读它，避免每次问插件；
- `models.json`：models.dev 的目录缓存（本机 6.9MB），给没有 `config` 声明的 provider 做兜底。

### 6.3 为什么值得学

社区插件的发布节奏极快：`opencode-qoder-auth` 从 `0.1.0` 到 `0.2.71` 共 74 个版本；`opencode-workbuddy-auth` 在 2026-09-30 到 2026-11-19 之间发了 85 个版本。【检索】`npm view` 元数据，2026-11-23。这种节奏下，“精确 pin + 一键更新 + 自动更新社区包 + 可回退”不是锦上添花，而是必需品。

---

## 7. 失败隔离与可观测性：把“插件会坏”当前提

Magpie 在这方面的细节密度最高，值得逐条对照：

| 失败 | 处理 | 证据 |
| --- | --- | --- |
| 单个插件 import/初始化超时 | 20s 后标 `{spec,error}`，其他插件继续 | `host.js:354-355, 1476-1560` |
| 单个 `config` hook 抛错 | 记日志，继续下一个；只有它改的 provider 条目回滚 | `host.js:1553-1575` |
| 单个 provider 的 models hook 卡住 | 20s 后该 provider `fellBack` + `listError`，沿用旧列表 | `docs/subsystems/provider-plugins.md:236-238` |
| 插件 401 但其实是“模型不服务” | 读 body 前 64KB，若只说模型不可用且不含 token/session 词，按 `kept`，不标记登录失效 | `provider-plugins.md:240-242` |
| access token 提前失效但 refresh 还有效 | `staleAccess` 把 `expires` 置 1，下一次请求续期；不误标“重新登录” | `provider-plugins.md:244-246` |
| 空闲账户 token 过期 | 宿主 `KeepPluginsSignedIn` 在到期前按 `refreshLead` 续期，单飞 + 退避（30s 起，翻倍到 30min） | `provider-plugins.md:248-254` |
| host 内存膨胀 | RSS >512MB 且启动满 10min → 起新 host，旧 host 答完在途请求后退役 | `host.go:1301-1315`、`host.js:362-378` |
| host 崩溃 | 下一次调用自动重启；若新 Bun 启动即死，回退 `previous` 并 set aside | `host.go:1030-1075` |
| 插件报“登录过期” | `X-Magpie-Sign-In: expired` 或 `throw {signIn:"expired"}`；宿主标记账户、停止路由、UI 提示 | `provider-plugins.md:240-246` |
| 同名 provider 冲突 | 两个插件都保留，显示“谁在服务”，给 `Use for` 按钮 / `magpie plugin use` | `provider-plugins.md:209-236` |
| 包被下架 | 新用户 `Add` 拒绝；老用户保留 + 风险提示 + 替代品 | `withdrawn.go:1-60` |

可观测性方面，host 提供 `gatewayStates()`：每个 gateway hook 的 `calls/failures/avgMillis/lastOutcome/lastBytes`；Settings → Plugins 有 JSON options 与调用/延迟/失败/结果诊断；`ctx.report(code, bytes)` 只允许固定 code，不保留私有文本。【源码】`host.js:3676-3682`、`docs/subsystems/gateway-request-hooks.md:100-120`

这套东西的共同点是：**失败被局部化、被计数、被展示，而不是被吞掉或放大**。我们的适配器一旦接第三方云，失败只会更多；这套“局部失败 + 状态可见”的骨架应该直接复用。

---

## 8. 用户侧 UX：把复杂度收进“provider 行”

Magpie 的 Plugins 页做了这些事（从文档、CLI 与本地状态归纳）：

1. **Discover**：官方社区列表 + 未审核 GitHub 区 + npm 搜索（`<query> opencode`，匹配 name/keywords 里的 `opencode` + `auth|plugin|provider`）；卡片显示来源、许可证、星数、是否社区审核、是否“Its own words”。
2. **Installed**：每行是插件，带 on/off、版本、更新点、Options（包级 JSON）、Tools/Page 列表、冲突提示。
3. **安装**：按名字、版本、git、目录；本地目录是“就地加载”，改完要重启 host（App 里关开一次插件）。
4. **登录**：provider 行内出现 methods 按钮；有 prompts 的先问；二维码/浏览器/设备码由宿主开；多账户并列；每个账户有额度卡、签到行、登出。
5. **冲突**：同一 provider 两个插件都登录时，行内明确“X 也在登录 Y；当前由 Z 服务”，另一个有 `Use for Y`。
6. **更新**：社区包自动；其他包在 sidebar 显示 “1 update”，Installed 顶部列出并给 Update all。
7. **下架**：保留但提示风险与替代。
8. **CLI 对齐**：`magpie plugin add/login/list/update/rm/off/options/use/registry`，`magpie provider test`，`magpie quota`，`magpie accounts checkin`。
9. **沙箱测试**：`HOME=$(mktemp -d) magpie plugin add ./pkg`，不碰真实配置。

【文档】<https://usemagpie.ai/docs/plugins#run>、<https://usemagpie.ai/docs/plugins#test>；【源码】`docs/subsystems/provider-plugins.md:83-92`

对我们的映射：MenuBarHome 的设置页是原生手写表单（ADR-0020 第 5 条刻意不做通用表单），所以我们不应该复制“JSON Schema 渲染整页”。但可以复制**“连接行”这个信息架构**：一行一个平台，行内放状态、账户、设备数、健康、更新、禁用/卸载；配置仍用原生表单；只有高级 options 用 JSON 编辑器。

---

## 9. 对照我们：差距表

成本口径：S ≤ 2 人日，M ≤ 1 周，L > 1 周（含双端与测试）。

| 我们文件 | 现状 | 对标做法 | 建议 | 成本 |
| --- | --- | --- | --- | :---: |
| [docs/adr/0020-backend-descriptor-table.md](../../../docs/adr/0020-backend-descriptor-table.md) / [0023](../../../docs/adr/0023-host-owned-builtin-capabilities.md) | 已否决进程内第三方插件；进程外 MCP/HTTP 桥列为“另立 ADR 再评估” | Magpie 两套插件体系：内置 `pluginrt` + 第三方三执行面（Bun/moejs/iframe） | 不改 ADR 结论；新增一份“进程外适配器协议 v0” ADR，明确它是 ADR-0020/0023 重启条件的落地，不开放 `HomeBackend` 字符串注册 | S |
| [Sources/MijiaCore/HomeProvider.swift](../../../Sources/MijiaCore/HomeProvider.swift) | 进程内 Swift 协议：`events/execute/refreshNow/setPollingContext/fetchSensorHistory/resolveCameraStream/stopCameraStream/readBack/shutdown` | Magpie provider 契约：`config/auth.loader/provider.models/usage/refresh`，全部走 JSON | 把现有协议方法逐条映射成 wire 方法（见 §12），用同一套语义（事件流、读回、关流），不另造概念 | M |
| [windows/src/core/homeProvider.ts](../../../windows/src/core/homeProvider.ts) | 与 Swift 同形的 `HomeProvider` 接口，但方法子集不同 | Magpie 双端共用同一份 host.js / 同一份插件 | 适配器协议只定义一次，Swift 与 TS 各自实现编解码；用 `Tests/Fixtures/` 黄金语料锁死帧格式与错误码 | M |
| [Sources/MijiaCore/KeychainAndPrefs.swift](../../../Sources/MijiaCore/KeychainAndPrefs.swift) / `CredentialVault` | 宿主钥匙串集中存米家/HA/AI 凭据 | Magpie `plugin-auth.json` 0600 + 每账户作用域 + 宿主单飞续期 | 适配器凭据分槽 `adapter:<id>:account:<id>`；**refresh token 永不离开宿主**；适配器只拿短期 access lease，到期用 `host.auth.renew` 换 | M |
| [Sources/MijiaCore/HomeStore+ControlWrite.swift](../../../Sources/MijiaCore/HomeStore+ControlWrite.swift) | 所有写入走乐观写 + 失败回滚 + 新写优先 | Magpie 插件 `fetch` 完全自由，没有写入门 | 适配器只暴露 `control.execute`，且只接受宿主调用；宿主写入门、幂等键、回滚、审计都在原处；适配器不得自发起控制 | S |
| [Sources/MijiaCore/ManualControlPolicy.swift](../../../Sources/MijiaCore/ManualControlPolicy.swift) / [HomeStore+Security.swift](../../../Sources/MijiaCore/HomeStore+Security.swift) | 危险分级、二次确认、锁屏拦截、未知目标先拒绝（写入门在策略之前） | Magpie 插件不声明危险等级，只声明模型/额度等事实 | adapter manifest **不设 risk 字段**；只允许事实性 `safetySignals`（漏水/烟雾/门磁读数）；危险等级由宿主按 `DeviceKind` + `ManualControlPolicy` 派生，未知一律从高 | S |
| [Sources/MijiaCore/DeviceDeduplicator.swift](../../../Sources/MijiaCore/DeviceDeduplicator.swift) / [DeviceSourceIdentity.swift](../../../Sources/MijiaCore/DeviceSourceIdentity.swift) | canonical id 由 `dids/macAddresses/uniqueIds` 强键合并 | Magpie 用 provider id + 账户后缀区分同名/同服务 | adapter 必须上报 `identity{dids,macAddresses,uniqueIds}`；宿主负责 canonical id 与跨源合并；适配器不得自造“全局唯一 id”参与去重 | S |
| [Shared/capability-manifest.json](../../../Shared/capability-manifest.json) | 静态记录内置连接/功能/设备类型、依赖、启动策略、平台支持 | Magpie `registry.json` + 每包 `magpie.*` + `plugin-providers.json` 缓存 | 内置清单保持不动；新增独立的 `adapter-manifest.json` 与 adapter registry；不要把第三方字段塞进内置清单 | S |
| [Sources/MijiaCore/HomeStore+Capabilities.swift](../../../Sources/MijiaCore/HomeStore+Capabilities.swift) | `capabilityGeneration` + 停用预检 + 引用判决 | Magpie `pluginrt.Reconcile` 的服务依赖与失败回滚；`loaded/error` 状态 | adapter 生命周期纳入 generation：启动/崩溃/升级都 bump，旧代次的写请求一律拒绝 | M |
| [scripts/mijia-mcp](../../../scripts/mijia-mcp) / [RaycastSnapshot.swift](../../../Sources/MijiaCore/RaycastSnapshot.swift) | 已有只读快照 + `bridgeToken` + `menumijia://` 控制；MCP 自动剥离 token | Magpie tools/pages 的“读权限白名单 + 宿主投影” | 适配器不写 `raycast-snapshot.json`、不自己开 MCP；宿主把适配器能力投影成 MCP 工具时复用现有 bridge token 与写入门 | S |
| [docs/adr/0015-local-first-privacy-and-diagnostics.md](../../../docs/adr/0015-local-first-privacy-and-diagnostics.md) | 本机脱敏诊断、无远端遥测 | Magpie `gatewayStates()` + `ctx.report` + 每插件计数 | 每个适配器加 `calls/failures/p50/p95/lastError/lastSyncAt/bytes`，只存数值与错误码，不存请求体；导出时脱敏 | M |
| [Sources/MijiaCore/UpdateSignature.swift](../../../Sources/MijiaCore/UpdateSignature.swift) / [scripts/release.sh](../../../scripts/release.sh) | 已有 Ed25519 清单签名 + 固定证书校验 | Magpie：npm/dist sha512 + registry PR 审核 + withdrawn；不签代码 | 适配器比 Magpie 更需要签名：Ed25519 签 `manifest + binary sha256 + permissions`；权限扩张必须重新确认；保留 blocklist | M |
| [Sources/MenuBarMijiaApp/SettingsWindowView.swift](../../../Sources/MenuBarMijiaApp/SettingsWindowView.swift) | 原生手写设置页，按后端分区；ADR-0020 第 5 条拒绝通用表单 | Magpie pages iframe + permissions；options JSON 编辑器 | 不开放第三方 UI；适配器配置用原生表单；仅高级字段用 JSON 编辑器；若未来要动态表单，只做受限 schema 子集并单独立 ADR | L |
| [Tests/Fixtures/](../../../Tests/Fixtures) | 双端共享黄金语料（设备、能力、去重） | Magpie `scripts/check.mjs` + `try.sh` 沙箱 + 插件自带测试 | 新增 `external_adapter_golden.json`：握手/版本协商/设备投影/写拒绝/崩溃退避/租约续期；Swift 与 TS 各跑一遍 | M |

---

## 10. 推进清单

| # | 标题 | 价值 | 成本 | 优先级 | 涉及高风险面？ | 依据 |
| :- | :--- | :--- | :- | :---: | :---: | :--- |
| 1 | **《进程外适配器协议 v0》ADR + manifest JSON Schema + 黄金语料** | 把 ADR-0020/0023 的“将来再评估”变成可评审的契约；不写运行时代码也能先锁边界 | S | **P0** | 是（架构契约；需 ADR 评审） | ADR-0020:94、ADR-0023:38；Magpie 的 `host.js` 契约证明“窄 RPC + 声明式能力”可支撑 127 个插件 |
| 2 | **身份与作用域语义定稿**：`adapterId + nativeId + identity{dids,mac,uniqueId}`、`sourceScope = adapter:<id>`、去重优先级、pin 规则 | 不做这一步，适配器一接入就会和米家/HA 设备重复、定时作用域错乱 | S | **P0** | 是（跨源去重/ADR-0019 作用域） | 我们的 `DeviceSourceIdentity` + `DeviceDeduplicator` 已有强键；Magpie 的 provider id + 账户后缀只解决“登录账户区分”，不解决“设备身份”，不能照抄 |
| 3 | **通用子进程监督器**：拉起、握手、心跳、退避重启、稳定期复位、孤儿清理、stdout/stderr 分流 | 复用现有 `XiaomiCameraBridge`/`companion.rs` 的经验，为所有适配器打底；崩溃不再带崩面板 | M | **P1** | 否（本地进程管理，不碰凭据/控制） | Magpie `reap/retire/heavy` 与 Homebridge/ioBroker 的熔断参数（02 号报告已对比） |
| 4 | **凭据租约 + 单飞续期**：宿主 Vault 分槽、短期 access lease、`host.auth.renew`、轮换 token 不外流 | 这是适配器安全的核心；没有它，第三方适配器迟早会持有长期 refresh token | M | **P1** | 是（登录/凭据/钥匙串） | Magpie `inScope` + `keepSignedIn` + `rotating` 的账户作用域与单飞续期 |
| 5 | **只读参考适配器**（建议先用 LG webOS 或一个局域网 HTTP 设备）+ 设备投影 + 去重预览 | 用真实设备验证协议，不碰写入；同时清理 LG 绕开 `HomeProvider` 的历史特例 | M | **P1** | 是（若含控制则升级为高风险；首版只读） | ADR-0020 落地顺序第 3 条；Magpie 的 `provider.models` 只读发现模式 |
| 6 | **写能力 + 授权/确认/审计**：`control.execute` 只在宿主写入门之后发出；每次写带 `grantId` 与 capabilityGeneration | 让适配器从“看”走到“控”，但仍不拥有判决权 | L | **P2** | 是（设备控制写入/二次确认/锁屏） | ADR-0023 第 4 条；`HomeStore+ControlWrite` 的乐观写与回滚 |
| 7 | **适配器签名 + 权限扩张再确认 + blocklist** | 比 Magpie 的“审核列表 + sha512”更强；家庭设备是物理执行器，值得更严 | M | **P2** | 是（Ed25519/发版/安装器） | ADR-0005；Magpie `dist.go` 的 sha512 与 `withdrawn.go` 的下架 |
| 8 | **适配器健康/额度面板 + 脱敏诊断导出** | 用户能看懂“为什么这个平台不更新了”；支持远程排障但不泄隐私 | S–M | **P2** | 否（只读展示） | Magpie `gatewayStates` + `ctx.report`；ADR-0015 |
| 9 | **适配器市场/审核流程**（官方/认证/社区三级） | 长尾平台覆盖的唯一可扩展方式；但必须建立在 1–7 之上 | L | **P3** | 是（分发/供应链） | Magpie registry PR + GitHub topic 的“未审核”分层；我们可加签名层 |
| 10 | **UI 插件/页面扩展**（不建议近期做） | 收益低、攻击面大；与 ADR-0020 第 5 条冲突 | L | **P3** | 是（第三方 UI/凭据） | Magpie pages 的 iframe + 3 种只读权限是唯一可接受形态；我们暂不需要 |

---

## 11. 设想（天马行空，标注 ADR 冲突）

1. **“适配器即事实账本”**：适配器每次状态变化都产出一条带 `adapterId + deviceId + 前后值 + 证据` 的不可变记录，宿主用它做安全审计、异常检测与回放。Magpie 的 `usage` 账本 + `plugin-calls.json` 是雏形，但只记 token 不记设备。**冲突**：无直接冲突，但会增加存储与隐私面，需要 ADR-0015 的脱敏约束。
2. **“局域网发现即插即用”**：宿主内置只读 mDNS/SSDP 嗅探器（零第三方代码），发现某厂商网关后提示“一键安装已签名适配器”。**冲突**：ADR-0023 第 1 条明确“插件市场与动态加载不在当前范围内”，需要新 ADR。
3. **“WASM/WASI 适配器”**：用 Wasmtime 跑纯协议翻译器，一份 `.wasm` 双端通用，天然无文件/网络权限，只通过宿主注入的 socket capability 访问局域网。**冲突**：引入第三方字节码引擎，直接冲突 ADR-0020/0023 的“不在宿主进程内加载外部代码”精神（虽然不在主进程），且增加包体与公证复杂度。
4. **“把 Bun 嵌进 macOS 端，复用 Magpie 的 host.js 模式”**：Magpie 证明了 Bun 子进程 + JSONL 在 macOS 上可行，且能跑 TypeScript 插件。**冲突**：ADR-0006 要求双端各自原生实现；引入 Bun 运行时会让 macOS 包体增加数十 MB，并改变签名/公证链路（ADR-0005）。可作为“Windows 优先”的跨端适配器方案，但不建议 macOS 首版。
5. **“适配器录制/回放”**：把真实厂商响应脱敏后录成 fixtures，CI 里回放；适配器作者不接触真实账号也能开发。Magpie 社区仓已有 `fixtures/` 与 `scripts/check.mjs` 的先例。**冲突**：无；但要注意 fixtures 里不能含真实 token/设备 id。
6. **“健康/额度联邦”**：多个适配器把自己的云额度/速率限制上报，宿主像 Magpie 的 quota 聚合那样统一展示、按剩余额度选择“用哪个平台执行同一场景”。**冲突**：无；但家庭场景里“同一场景多平台”很少见，优先级低。
7. **“适配器能力市场 + 自动生成平台矩阵文档”**：manifest 是唯一事实源，CI 自动生成 `docs/platform-matrix` 的新平台行与支持设备表。**冲突**：与 ADR-0023 的静态能力清单门禁需要协调；可以让 adapter manifest 只生成“外部平台”一节，不碰内置清单。
8. **“把写入门做成可证明的 capability token”**：宿主在确认/解锁后签发一个短时效、绑定 `adapterId + deviceId + command hash + capabilityGeneration` 的 token，适配器必须带着它执行；token 由宿主 HMAC，适配器只透传。**冲突**：无；但它不是安全边界（适配器仍可伪造自己的行为），主要是审计与防重放，别把它当沙箱。

---

## 12. 进程外适配器协议草案（v0）

> 定位：这是 §10 第 1 条要落成 ADR 的草案。它遵守 ADR-0020/0023：`HomeBackend` 枚举不变、宿主保留写入门/确认/锁屏/凭据/告警；适配器只是“平台驱动”，不是“策略引擎”。与 02 号报告 §9 的协议总览相比，本节补的是 Magpie 验证过的**账户作用域、租约续期、健康/额度、推送通道、失败语义与版本治理**。

### 12.1 设计原则

1. **宿主是唯一的判决者**：设备是否存在、能力是否启用、是否锁屏、是否需要二次确认、是否允许写入，全部由宿主判定；适配器只回答“我能看到什么/我执行结果如何”。
2. **事实与判决分离**：manifest 只允许声明事实（支持的设备种类、命令、读数、网络主机、限额），不允许声明危险等级、确认策略、写入许可。
3. **默认拒绝**：未声明的能力、未声明的网络主机、未声明的 RPC 方法，一律拒绝；未知设备/未知命令返回错误，不执行。
4. **最小凭据**：refresh token 永不离开宿主；适配器只拿短期 access lease；轮换型 token 由宿主单飞续期。
5. **进程边界 = 崩溃边界，不是安全边界**：真正的安全靠签名、审核、网络出口限制与宿主写入门；不要假设适配器善意。
6. **版本可协商、能力可增量**：`hostApi` 用 semver 区间；新增能力是加法；删除能力要经过 deprecation；权限扩张必须重新征得用户同意。

### 12.2 传输与帧

- **主通道**：宿主作为 supervisor 拉起适配器子进程，`stdin/stdout` 换行分隔 JSON（UTF-8），`stderr` 只用于日志。理由：无监听端口、无跨进程鉴权、随宿主启停、天然适配 macOS `Process` 与 Windows `Command`；与我们已有的 `scripts/mijia-mcp`（stdio JSON-RPC）同构。
- **备选**：长驻重服务（摄像头转码、局域网网关）可用 loopback HTTP/WS + 每次启动轮换的 secret header，但必须绑定 `127.0.0.1` 且校验 `Host`；这与现有 `XiaomiCameraBridge`/`companion.rs` 的模式一致。
- **帧**：`{v:1, id, method, params}` → `{v:1, id, result}` 或 `{v:1, id, error:{code, message, retryable}}`；事件 `{v:1, event, data}`；一行一个 JSON，单行上限 8MB（摄像头不走字节流，走 URL）；`abort` 取消在途请求；若未来要传 MJPEG 快照，再加 `credit` 窗口（照抄 Magpie 的 512KB 窗口 + 2048B 帧开销）。
- **握手**：宿主先发 `host.hello` 请求，适配器在 result 里回 `{adapterId, protocolVersion, manifestDigest}`；双方交换协议版本与能力摘要，版本不兼容直接拒绝启动。

一次实际交换长这样（每行一个 JSON）：

```jsonl
{"v":1,"id":1,"method":"host.hello","params":{"protocolVersion":1,"hostVersion":"1.0.0","locale":"zh-Hans","dataDir":"…","logLevel":"info"}}
{"v":1,"id":1,"result":{"adapterId":"com.example.aqara-lan","protocolVersion":1,"manifestDigest":"sha256:…"}}
{"v":1,"event":"state.changed","data":{"deviceId":"lumi.158d0001a2b3c4","patch":{"online":false},"ts":1763900000000}}
{"v":1,"id":9,"method":"control.execute","params":{"grantId":"g-7f3a","deviceId":"lumi.158d0001a2b3c4","command":{"verb":"power","on":true},"timeoutMs":20000}}
{"v":1,"id":9,"result":{"status":"ok","readBack":{"online":true,"power":true}}}
```


### 12.3 Manifest 字段表

```jsonc
{
  "manifestVersion": 1,
  "adapterId": "com.example.aqara-lan",
  "name": { "zh": "Aqara 局域网", "en": "Aqara LAN" },
  "version": "1.0.0",
  "hostApi": "^1",                    // 宿主协议 semver 区间
  "runtime": { "type": "binary", "entry": "bin/adapter", "arch": ["arm64", "x86_64"] },
  "platforms": ["macos", "windows"],
  "vendor": { "name": "Aqara", "docs": "https://…", "hosts": ["api.aqara.com"] },
  "auth": [
    { "id": "cloud", "type": "oauthDevice", "label": { "zh": "Aqara 账号" },
      "scopes": ["device.read", "device.control"] },
    { "id": "lan", "type": "apiKey", "label": { "zh": "局域网令牌" },
      "prompts": [{ "key": "token", "type": "password" }] }
  ],
  "discovery": {
    "modes": ["cloudApi", "lanMdns", "lanSsdp", "lanUdp"],
    "mdns": ["_aqara._tcp"],
    "udp": [{ "port": 54321 }]
  },
  "capabilities": {
    "deviceKinds": ["light", "plug", "sensor", "cover", "climate", "camera"],
    "commands": ["power", "brightness", "colorTemp", "temperature", "coverPosition", "scene"],
    "readings": ["temperature", "humidity", "battery", "illuminance"],
    "history": true,
    "camera": { "protocols": ["hls"], "maxConcurrent": 2 },
    "alerts": ["leak", "smoke", "gas", "contact", "motion", "vibration", "lock", "doorbell"],
    "scenes": true
  },
  "limits": { "maxDevices": 200, "maxConcurrentCalls": 4, "requestsPerMinute": 60 },
  "permissions": {
    "network": { "internet": ["api.aqara.com"], "lan": true },
    "files": { "read": [], "write": ["cache"] },
    "subprocess": false,
    "clipboard": false
  },
  "health": { "probe": "health.check", "intervalSec": 60, "timeoutMs": 5000 },
  "ui": { "configSchema": { /* 受限 JSON Schema 子集，password 字段直入宿主 Vault */ }, "icon": "icon.png" }
}
```

| 字段 | 必填 | 类型 | 语义 | 宿主怎么用 |
| --- | :---: | --- | --- | --- |
| `manifestVersion` | 是 | int | manifest 自身版本 | 未知版本拒绝 |
| `adapterId` | 是 | string | 反向域名，全局唯一 | 作用域、凭据槽、去重命名空间 |
| `name` | 是 | `{lang:string}` | 显示名 | 设置页/市场 |
| `version` | 是 | semver | 适配器版本 | 更新/回滚/审计 |
| `hostApi` | 是 | semver range | 需要的宿主协议版本 | 不满足则拒绝启动，UI 提示升级宿主 |
| `runtime` | 是 | object | 入口与架构 | supervisor 校验路径与 sha256 |
| `platforms` | 是 | string[] | 支持平台 | 不匹配则不显示 |
| `vendor.hosts` | 否 | string[] | 厂商文档/审核展示的主机 | 仅供展示与审核对照；真正的白名单是 `permissions.network.internet`，两者必须一致，否则拒绝安装 |
| `auth[]` | 否 | object[] | 登录方式 | 宿主渲染登录 UI；`type` 枚举 `apiKey`/`oauthDevice`/`qr`/`reuseLocalCli`/`importFile` |
| `discovery.modes` | 否 | string[] | 发现方式 | 宿主决定是否允许 LAN/mDNS/UDP 权限 |
| `capabilities.deviceKinds` | 是 | string[] | 映射到我们的 `DeviceKind` | 未知 kind → 只读 `generic`；不新增枚举 |
| `capabilities.commands` | 是 | string[] | 支持的命令动词（宿主发布的封闭词表） | 宿主按内部命令模型（`DeviceCommand` 及对应控制路径）校验；未声明 → 拒绝；适配器不得自造动词 |
| `capabilities.readings` | 否 | string[] | 支持的读数 | UI/历史/自动化 |
| `capabilities.camera` | 否 | object | 协议与并发 | 宿主分配流槽位 |
| `capabilities.alerts` | 否 | string[] | 能上报的告警种类 | 只作为**证据**，严重级别由宿主定 |
| `limits` | 否 | object | 设备/并发/速率上限 | 宿主限流与 UI 提示 |
| `permissions.network` | 是 | object | 互联网主机 + 是否允许 LAN | 沙箱/代理白名单 |
| `permissions.files` | 否 | object | 只读/只写 cache | 沙箱 profile |
| `permissions.subprocess` | 否 | bool | 是否允许起子进程 | 默认 false；true 需要高亮警告 |
| `health` | 否 | object | 探针与间隔 | 宿主健康面板 |
| `ui.configSchema` | 否 | object | 受限字段描述 | 原生表单渲染；`password` 直入 Vault |

> `ui.configSchema` 只作用于**适配器自己的配置弹窗**；内置的米家 / HA 设置页仍按 ADR-0020 第 5 条手写，不由此渲染。首版也可以先不实现动态渲染，让适配器作者提供一份宿主模板。

**明确禁止的字段**（防止把策略偷渡进 manifest）：

- `riskLevel` / `requiresConfirmation` / `safetyClass`：危险等级只能由宿主按 `DeviceKind` + `ManualControlPolicy` 派生；未知一律从高。
- `canWrite` / `writeAllowed`：写入许可由宿主按连接能力 + 用户授权决定。
- `notificationChannel` / `severity`：推送由宿主统一出口；适配器只能发 `alert` 事件与事实证据。
- `globalDeviceId`：去重只能用 `identity{dids,macAddresses,uniqueIds}`，由宿主算 canonical id。
- 任何秘密：token、密码、cookie、session 一律不进 manifest；`configSchema` 里只能是 `writeOnly` 字段声明。

**映射到我们现有的四种连接**（证明 manifest 词汇够用）：

| 现有连接 | `auth[].type` | `discovery.modes` | 说明 |
| --- | --- | --- | --- |
| 米家云端 | `qr` | `cloudApi` | 二维码由适配器返回 payload，宿主渲染；多账户/区域用 prompts |
| Home Assistant | `apiKey` + `prompts[{key:"baseUrl"}]` | `lanMdns` | 长期令牌 + 地址；mDNS 发现只读 |
| LG webOS 电视 | `apiKey`（TV key）+ `prompts[{key:"host"}]` | `lanSsdp`/`lanUdp` | 单设备源；可先用只读参考适配器验证 |
| go2rtc / 摄像头桥 | `apiKey`（URL + 可选 secret） | 无 | 走 `camera.open` 返回 URL，不传裸流 |

### 12.4 RPC 方法表

#### 宿主 → 适配器（请求）

| 方法 | 参数 | 返回 | 说明 |
| --- | --- | --- | --- |
| `host.hello` | `{protocolVersion, hostVersion, locale, dataDir, logLevel}` | `{adapterId, protocolVersion, manifestDigest}` | 启动握手；版本不兼容即停 |
| `adapter.init` | `{config, accounts:[{accountId, authType}], credentials:[{accountId, kind:"oauthAccess"\|"apiKey"\|"lanToken", value, expiresAt}]}` | `{ok, capabilitiesDigest}` | 非秘密配置 + 每个账户的短期凭据租约；**refresh token 永不出现** |
| `auth.begin` | `{methodId, inputs}` | `{flowId, url?, qrPayload?, instructions?, mode:"auto"\|"code", expiresAt}` | 二维码/设备码/浏览器由宿主渲染 |
| `auth.poll` | `{flowId}` | `{state:"pending"\|"success"\|"failed", account?, error?}` | `success` 时宿主负责落 Vault |
| `auth.complete` | `{flowId, code?}` | 同上 | `mode:"code"` 时用户粘贴 |
| `auth.cancel` | `{flowId}` | `{ok}` | 用户取消/超时 |
| `discover.scan` | `{timeoutMs}` | `{devices:[DeviceDescriptor], rooms:[], scenes:[]}` | 首次/手动刷新 |
| `state.snapshot` | `{}` | `{devices:[DeviceDescriptor], capturedAt}` | 宿主启动时拉一次 |
| `state.subscribe` | `{deviceIds?}` | `{subscriptionId}` | 之后用 `state.changed` 事件推送 |
| `state.unsubscribe` | `{subscriptionId}` | `{ok}` | |
| `control.execute` | `{grantId, deviceId, command, timeoutMs}` | `{status:"ok"\|"rejected"\|"unsupported"\|"timeout", readBack?}` | **只在宿主写入门之后调用**；`grantId` 用于审计/幂等 |
| `history.read` | `{deviceId, metric, from, to, bucketSec}` | `{samples:[{t,v}]}` | 传感器历史 |
| `camera.open` | `{deviceId, quality}` | `{streamId, url, expiresAt, audio:false}` | 返回可播放 URL；不传裸流 |
| `camera.close` | `{streamId}` | `{ok}` | 释放单会话设备 |
| `health.check` | `{}` | `{state:"ok"\|"degraded"\|"signInRequired"\|"offline", latencyMs, detail?}` | 60s 一次，也可手动 |
| `quota.read` | `{}` | `{plan?, windows:[{name,used?,limit?,unit?,resetsAt?}], balance?}` | 可选；云平台额度 |
| `shutdown` | `{}` | `{ok}` | 宿主退出/禁用时 |

凭据租约的细则：

- `kind` 只允许 `oauthAccess` / `apiKey` / `lanToken`；`expiresAt` 对 API key 也必填（宿主可随时轮换/撤销）。
- 适配器不得把 `value` 写入磁盘、日志或缓存；只能在内存里用到过期。
- 到期前适配器调 `host.auth.renew`；宿主单飞续期，返回新的 lease；轮换型 refresh token 只在宿主侧。
- L2（门锁/阀门）可进一步改成“宿主前置签名代理”：适配器拿到的不是厂商 key，而是只能调用宿主代理的 scoped token，代理再注入真 key。

#### 适配器 → 宿主（事件/反向请求）

| 方法/事件 | 数据 | 说明 |
| --- | --- | --- |
| `log` | `{level, message, fields?}` | 只写日志；宿主统一脱敏 |
| `state.changed` | `{deviceId, patch, ts}` | 增量状态；`patch` 只含变化字段 |
| `device.added` / `device.removed` | `{device}` / `{deviceId}` | 发现/移除 |
| `alert` | `{deviceId, kind:"leak"\|"smoke"\|"gas"\|"contact"\|"motion"\|"vibration"\|"lock"\|"doorbell", evidence:{...}, ts}` | **不携带 severity/是否通知**；宿主决定 |
| `auth.expired` | `{accountId, reason}` | 宿主标记账户、停路由、提示重新登录 |
| `health.changed` | `{state, detail?}` | 宿主健康面板 |
| `usage.report` | `{calls, errors, bytes, p50Ms}` | 可选，进诊断计数 |
| `host.auth.renew`（反向请求） | `{accountId, reason}` | 宿主单飞续期，返回新的 `{access, expiresAt}`；拒绝时适配器必须停用该账户 |

#### 控制

| 方法 | 方向 | 说明 |
| --- | --- | --- |
| `abort` | 宿主 → 适配器 | 取消在途请求（用户关面板/超时） |
| `credit` | 宿主 → 适配器 | 仅当未来传字节流时使用；照抄 Magpie 的窗口模型 |
| `shutdown` | 宿主 → 适配器 | 优雅退出；超时后 supervisor 强杀进程树 |

### 12.5 DeviceDescriptor

```jsonc
{
  "nativeId": "lumi.158d0001a2b3c4",
  "identity": {
    "dids": ["lumi.158d0001a2b3c4"],
    "macAddresses": ["AA:BB:CC:DD:EE:FF"],
    "uniqueIds": ["aqara:switch:h1"]
  },
  "name": "客厅落地灯",
  "room": "客厅",
  "kind": "light",                     // 必须是宿主 DeviceKind 的已知值；未知 → generic
  "model": "lumi.light.aqcn02",
  "online": true,
  "capabilities": {
    "power": { "writable": true },
    "brightness": { "writable": true, "min": 1, "max": 100, "step": 1 },
    "colorTemp": { "writable": true, "min": 2700, "max": 6500, "step": 100 },
    "modes": []
  },
  "readings": [
    { "key": "illuminance", "value": 120, "unit": "lx" }
  ],
  "safetySignals": []                  // 只放事实读数，取值同 SafetySignalKind（leak/smoke/gas/contact/motion/vibration/lock/doorbell）
}
```

约束：

- `kind` 只能取 `DeviceKind` 的 15 个值（light/climate/fan/plug/fridge/vacuum/speaker/tv/camera/sensor/cover/appliance/generic/humidifier/valve）；未知值不得超过 `generic`，且 `generic` 默认只读。
- `capabilities` 只描述“能不能写、范围、步长”，不描述“是否危险”；危险由宿主按 `kind` + 设备字段（如 `cover.subtype`、`appliance.heats`、`valve`）派生。
- `capabilities.commands` 的动词来自宿主发布的封闭词表，映射到 `DeviceCommand` 或对应的控制路径（如窗帘的 `setCoverPosition`）；适配器不能新增动词，也不能用未知动词绕过确认。
- `identity` 必须尽量给全 `dids/macAddresses/uniqueIds`；宿主用现有 `DeviceSourceIdentity` 归一化后去重。适配器自造的 `nativeId` 只在 `adapterId` 命名空间内唯一，不能当全局 id。
- `safetySignals` 是“读数”，不是“告警级别”；宿主的安全告警评估仍是唯一出口。

### 12.6 安全边界

| 层 | 适配器可以做 | 适配器不可以做 | 谁强制 |
| --- | --- | --- | --- |
| 凭据 | 拿短期 access lease；用 `host.auth.renew` 换新 | 读 Keychain、拿 refresh token、写 `plugin-auth` 类文件 | 宿主 Vault + RPC 白名单 |
| 网络 | 访问 manifest 声明的互联网主机；按 `permissions.network.lan` 访问局域网 | 访问未声明主机、开监听端口、扫全网 | 沙箱 profile / 本地出口代理 |
| 文件 | 读写自己的 `dataDir/cache` | 读用户目录、读其他适配器、读宿主配置 | 沙箱 profile + 工作目录 |
| 进程 | 无（`subprocess:false`） | 起子进程、装 launch agent、改系统设置 | 沙箱 profile + 代码审计 |
| 控制 | 只在 `control.execute` 里执行一个已由宿主批准的 `DeviceCommand` | 自发起控制、接受局域网/云端 webhook 直接控制、绕过宿主 | 宿主写入门 + 适配器契约（无入站控制通道） |
| 策略 | 上报事实、状态、告警证据 | 声明危险等级、决定是否确认、决定是否通知、决定路由 | 宿主 `ManualControlPolicy` / `HomeStore+Security` / 通知层 |
| 身份 | 上报 `identity` 强键 | 自造全局 id 参与去重、冒充其他适配器 | 宿主 `DeviceDeduplicator` + `adapterId` 命名空间 |

**分层建议（按风险递增）**：

- **L0（只读适配器）**：子进程 + stdio + 无秘密 + 超时/崩溃隔离。成本最低，先跑通“发现/状态/历史”。
- **L1（可写适配器）**：L0 + 网络出口白名单（本地代理或 `sandbox-exec` profile）+ 只写 cache 目录 + 写入门/审计。上写能力前必须到 L1。
- **L2（门锁/阀门/车库门类）**：L1 + 签名 manifest + 二进制 sha256 校验 + 权限扩张再确认 + 独立用户/XPC（可选）。这类设备一旦误开就是物理伤害，不能只靠 L0。

> 说明：`sandbox-exec` 在 macOS 上已被标记 deprecated，但仍可用；更稳的长期方案是 XPC service + App Sandbox + 出口代理。不要把 `sandbox-exec` 当唯一防线。

### 12.7 版本、升级与回滚

- `hostApi: "^1"`：主版本不匹配拒绝启动；次版本新增能力是加法；适配器必须忽略未知字段。
- manifest 在安装时 pin 摘要（`manifestDigest = sha256(manifest)`）；升级时若 `permissions` 扩大（新增 host、LAN、文件读、subprocess），必须重新弹权限确认。
- 适配器二进制/包必须有 `sha256`，与签名清单一起验；保留上一版目录，失败回滚。
- blocklist：`{adapterId, versions:[...], reason}`，宿主启动前检查；与 Magpie 的 `withdrawn` 同类，但我们可以在不发版的情况下阻断。
- 审计：每次 `control.execute` 记录 `grantId/adapterId/deviceId/commandHash/result/ts`，不记录明文参数中的敏感值。

### 12.8 失败语义

| 场景 | 适配器行为 | 宿主行为 |
| --- | --- | --- |
| 启动 10s 未握手 | 退出 | 标记 `failed`，退避重启 |
| `init` 10s 未回 | 退出 | 同上 |
| 单 RPC 15s 未回（`control` 20s） | 收到 `abort` 后停止 | 返回超时；控制类不重试（避免重复执行），查询类可重试一次 |
| 适配器崩溃 | — | 1s/2s/4s/…/60s 退避；10 分钟内 3 次崩溃 → 熔断，UI 提示；稳定 10 分钟复位 |
| 厂商 401/403 | 发 `auth.expired` | 标记账户、停止路由、提示重新登录；不自动清空设备 |
| 厂商 429/5xx | 返回 `retryable:true` | 指数退避；不影响其他适配器 |
| 设备离线 | `state.changed {online:false}` | 卡片置灰；安全告警仍按最后已知值 + stale 标记 |
| 未知设备/未知命令 | 返回 `unsupported` | 零写入拒绝；记录审计 |
| 适配器被禁用 | 收 `shutdown` | 停进程、撤下设备入口；**若安全告警开启，保留只读 lease 继续读漏水/烟雾**（ADR-0023 第 4 条） |
| 适配器升级失败 | 回滚上一版 | 标记 `updateFailed`，保留旧进程运行 |

其中“适配器被禁用”这一条是关键：**“关闭设备类型展示”不等于“关闭安全读取”**。Magpie 用 `Essential`/`InUse` 让关键插件在功能关闭时仍运行；我们的适配器协议必须允许宿主在“UI 关闭”时仍保持一个只读、低权限的 safety lease。这也是 §12.3 里 `capabilities.alerts` 与 `state.subscribe` 要分开的原因。

### 12.9 用户侧 UX（设置页）

1. **添加平台**：设置 → 连接 → “添加平台”，列出官方/认证/社区三级；卡片显示适配器名、厂商、支持设备种类、权限摘要、是否签名。
2. **安装**：下载 → 校验签名/sha256 → 权限确认页（互联网主机、局域网、只读/可写、是否允许子进程）→ 安装。
3. **登录**：按 manifest 的 `auth[]` 渲染原生表单/二维码/设备码；成功后显示账户行。
4. **发现**：扫描 → 设备列表（带“已由米家提供，是否合并？”预览）→ 选择导入。
5. **状态行**：健康点（ok/degraded/signInRequired/offline/failed）、最后同步、设备数、额度（若有）、更新点、查看日志、禁用/卸载。
6. **权限变更**：适配器升级若扩大权限，行内出现“需要重新授权”，不授权则保持旧版运行。
7. **诊断**：导出脱敏报告（适配器 id/版本/健康/计数/错误码，不含设备名、不含请求体）。

### 12.10 与 ADR-0020 / ADR-0023 的关系

- **`HomeBackend` 不动**：不把三值枚举改成开放字符串，也不为每个适配器加一个枚举值。适配器设备走一条平行的 `ExternalAdapterSlot` 投影层（02 号报告 §9.3 已提出），在快照聚合时并入 `SynthesizedHome`；`deviceBackends` 需要增加 adapter 维度（例如 `deviceAdapterIDs: [deviceId: adapterId]`），而不是复用三值枚举。
- **能力清单不动**：`Shared/capability-manifest.json` 只增加**一个**宿主能力 `external-adapters`（`kind:"connection"`，`defaultOnFreshInstall:false`，`startupPolicy:"whenConfigured"`），不把每个第三方适配器写进内置清单；每个适配器的 manifest 是独立文件，由 adapter registry 管理。
- **写入门/确认/锁屏不动**：§12.6 的所有“谁强制”都指向现有 `HomeStore+Capabilities` / `ManualControlPolicy` / `HomeStore+Security`，适配器协议不新增任何绕过路径。
- **定时/自动化作用域**：ADR-0019 的 `sourceScopes` 增加 `adapter:<adapterId>` 前缀；停用适配器时按现有引用判决暂停相关定时/自动化，不静默失效。
- **重启条件**：本草案正是 ADR-0023 第 38 行第 1 条“评估进程外扩展协议”的落地；落地前需要单独 ADR，不能以本报告替代评审。

### 12.11 最小可落地切片（只写契约，不跑代码）

如果只做一件事，按这个顺序落。前 3 步是 S（纯文档/纯数据），后 2 步是 M（双端类型与语料），都不触碰运行时的凭据、控制与锁屏面（ADR 评审本身仍属架构级变更）：

1. `docs/adr/0024-external-adapter-protocol.md`：把 §12.1–12.8 收敛成决策，明确 `HomeBackend` 不动、`ExternalAdapterSlot` 投影、写入门/确认/锁屏/凭据仍归宿主。
2. `Shared/adapter-manifest.schema.json`：§12.3 的 JSON Schema（含禁止字段的 `additionalProperties:false` 与 `permissions` 必填）。
3. `Tests/Fixtures/external_adapter_golden.json`：握手、版本不匹配、设备投影、未知 kind→generic、未知命令→拒绝、租约续期、崩溃退避状态机。
4. `Sources/MijiaCore/ExternalAdapterProtocol.swift` + `windows/src/core/externalAdapterProtocol.ts`：只做 Codable/类型与纯函数编解码，不拉进程、不连网；双端用同一份黄金语料跑通。
5. 通过 `scripts/check.sh --changed` 与现有 `Tests/Fixtures` 门禁后，再评估是否进入 P1（子进程监督器）。

这样即使最终决定“不做适配器”，也只是多了一份 schema 与语料，不会留下运行时代码或安全面。

---

## 13. 来源清单

### 本机（只读，未打印秘密）

- `/Applications/magpie.app/Contents/Info.plist`：版本 0.1.4696，`LSUIElement`，URL scheme `magpie`。
- `/Applications/magpie.app/Contents/Resources/THIRD_PARTY_NOTICES`：第 4-7 行确认 moejs 是运行 gateway plugins 的内嵌 JS 引擎。
- `~/.cache/magpie/plugin-host/`：53 个 `host-<hash>.js` + 3 个 `pi-<hash>.js`，内容寻址缓存。
- `~/.cache/magpie/{plugin-market.json,plugin-npm.json,plugin-github.json}`：127 / npm 元数据 / 547 条 GitHub 检索。
- `~/.cache/magpie/{providers-state.json,models.json}`：provider 运行态与 models.dev 目录（仅看结构）。
- `~/.cache/magpie/bun/{1.4.4,1.4.5,state.json,install-cache}`：Bun 运行时与包缓存。
- `~/.config/magpie/{plugins.json,plugins.yml,plugins/package.json,plugins/bun.lock}`：意图/安装态。
- `~/.config/magpie/{plugin-updates.json,plugin-providers.json,plugin-checkin.json,plugin-calls.json,plugin-tools.json,plugin-searches.json}`：更新历史与能力状态（仅字段名/结构）。
- `~/.config/magpie/plugin-auth.json`：仅读取顶层键与条目字段名（`access/accountId/expires/refresh/type`），未读取值。
- `~/.config/magpie/plugins/node_modules/`：7 个 `@magpie-community/*` 包 + 1 个 `magpie-gemini-web` 的 `package.json` 与文件布局。

### 源码仓库

- `yetone/magpie` @ `d51077941dfc46bd91c2bd7f5ef6a49b54809f9b`（2026-11-23）：
  - `internal/plugin/host.js`（3965 行）：协议头注释、`makeClient`、`loadPlugins`、`watchHeavy`、`handlers`、账户作用域。
  - `internal/plugin/host.go`（2373 行）：Bun 启动、`init`、`reap/retire/stop`、512MB 回收、line/frame 限制。
  - `internal/plugin/{store.go,dist.go,market.go,updates.go,withdrawn.go,page.go,installcache.go}`：安装、dist 校验、市场、更新、下架、页面权限、缓存清理。
  - `docs/subsystems/{plugin-runtime.md,provider-plugins.md,plugin-tools.md,gateway-request-hooks.md}`：契约与失败语义。
- `magpie-community/plugins` @ `18fa1467fe50d760133bc0955f3ff3dbec735688`（2026-11-23）：
  - `README.md`：Use / Writing a package / Write your own / The market / Publishing / Pages / Gateway hooks / Agents。
  - `registry.json`：127 条，kind 统计 51/29/24/15/8。
  - `packages/river/{package.json,index.mjs}`：最小 provider 插件完整契约（config/auth/usage/models）。
  - `packages/notify/{package.json,notify.hooks.mjs,README.md}`：推送通道的 `magpie.hooks` + page + options 组合。
  - `packages/think-tags/{package.json,think-tags.middleware.js}`：同步 middleware 的 `magpie.middleware` 声明。
  - `packages/zen-free/package.json`：`magpie.icon/maxConcurrency` 与多文件 provider 布局。

### 官方文档

- <https://usemagpie.ai/docs/plugins>（2026-11-23 读取）：Overview / How magpie runs plugins / The package / Provider and models / Signing in / Usage / Check-in / What a plugin is given / Testing / Publishing and listing / Async gateway request hooks / Gateway middleware / Pages。
- <https://usemagpie.ai/docs/plugins#gateway-request>： “Bun plugins have host privileges; install trusted code.” 与 hook 预算/回滚语义。

### npm 元数据（2026-11-23）

- `npm view @magpie-community/opencode-qoder-auth version versions`：74 个版本，`0.1.0` → `0.2.71`。
- `npm view @magpie-community/opencode-workbuddy-auth time`：85 个版本，`0.1.1`（2026-09-30）→ `0.2.37`（2026-11-19）。

### 我们的仓库

- `docs/adr/0020-backend-descriptor-table.md`（第 49–51、58–95 行）：封闭 `HomeBackend`；进程外协议另行评估。
- `docs/adr/0023-host-owned-builtin-capabilities.md`（第 19–23、36–39 行）：宿主持有内置能力、写入门、引用判决；重启条件。
- `docs/adr/0015-local-first-privacy-and-diagnostics.md`：本机脱敏诊断。
- `docs/adr/0005-update-signing-trust-chain.md`：Ed25519 验签。
- `Sources/MijiaCore/HomeProvider.swift:82-106`：`HomeProvider` 协议。
- `Sources/MijiaCore/Models.swift:1221-1275, 1698-1745`：`DeviceKind` 15 种、`DeviceCommand`。
- `Sources/MijiaCore/DeviceSynthesizer.swift:219-247`：`SynthesizedHome`。
- `Sources/MijiaCore/DeviceSourceIdentity.swift:5-25`：`dids/macAddresses/uniqueIds`。
- `Sources/MijiaCore/DeviceDeduplicator.swift:44-52`：canonical 合并。
- `Sources/MijiaCore/HomeStore+ControlWrite.swift:1-22`：乐观写/回滚。
- `Sources/MijiaCore/ManualControlPolicy.swift:85-110`：确认策略；未知目标返回 false（因此写入门必须先拒绝）。
- `Sources/MijiaCore/HomeStore+Security.swift:249-261`：锁屏拦截。
- `Sources/MijiaCore/KeychainAndPrefs.swift:45, 93`：Keychain 读写。
- `Sources/MijiaCore/AppURLCommand.swift:269-320`：bridge token 常量时间比较与直控确认。
- `Sources/MijiaCore/RaycastSnapshot.swift:386-400`：bridge token 生成/读取。
- `scripts/mijia-mcp:1-12`：只读 MCP 桥，不接触凭据。
- `windows/src/core/homeProvider.ts:24-36`：Windows `HomeProvider` 接口。
- `Shared/capability-manifest.json`：内置能力清单（静态）。

---

### 摘要（5 行内）

1. Magpie 用**两套插件系统**把“官方功能模块化”和“第三方扩展”分开：内置 `pluginrt` 留在 Go 主进程，第三方 OpenCode 插件全部进一个 Bun 子进程，主进程只暴露 24 个窄 RPC 与默认拒绝的 `client`。
2. 它最值得抄的不是市场，而是**事实/判决分离**：插件只声明 provider、登录、模型、额度、设备事实；路由、额度聚合、失败回退、告警、UI 全部宿主所有。
3. 它的隔离是**崩溃隔离 + 超时 + 512MB 回收 + 版本回退**，不是安全沙箱（官方明说 “install trusted code”）；我们做家庭设备适配器必须比它更严，凭据只给短期 lease，写入门永远在宿主。
4. 建议先落 P0：一份《进程外适配器协议 v0》ADR + manifest schema + 身份/作用域/去重语义 + 黄金语料；再落 P1：通用子进程监督器、凭据租约、只读参考适配器。
5. 报告路径：`docs/research/2026-11-23-deep-dive/12-magpie-plugin-model.md`。
