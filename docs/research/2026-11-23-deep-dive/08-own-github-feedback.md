# 08 用户对 MenuBarHome 本身的真实反馈（只读）

**调研日期**：2026-11-23
**范围**：`jryang2026-code/MenuBarHome` 全部 issue（102）、PR（292）、release（3）、traffic、forks（6）、discussions（0）；旧仓库 `jryang1997/MenuBarMijia` 的残留证据（账号已封禁，API 404）；第三方镜像 `azsummer/menubarmijia-cloudbuild`；Trendshift 榜单页。
**实际读了哪些仓库**：本仓库（commit `9fc349d0`，2026-11-23）+ 上述 GitHub 远端数据。**未克隆或运行任何第三方仓库代码**。
**证据标注约定**：`【检索】` = 通过 GitHub REST/GraphQL API 或公开网页实读，附 URL 与读取日期（2026-11-23）；`【源码】` = 本仓库文件+行号；`【文档】` = 仓库内文档；`【推断】` = 我的判断，未经证据直接支持。

---

## 0. 结论先行

1. **GitHub issue 不是这个项目的反馈渠道，样本极小**：102 个 issue 里只有 3 个外部作者，其中 1 个（#44）还是"已撤回"的无效帖；全仓库外部用户评论合计 **1 条**。任何"高频"说法都只能是轶事级证据。【检索】

2. **真正的反馈入口是 X 回复和小红书评论**：维护者用 "MenuBarHome Scout" 把外部评论搬成 issue，共 6 条（`from-x` 2 条：#67、#104；`from-xiaohongshu` 4 条：#14、#15、#16、#30）。这 6 条里有 4 条带用户原话。【检索】

3. **用户最痛的三件事**（按证据强度排序，不是按票数）：**同步成功但拉不到设备**（#76、#67，两个独立来源）、**"很多设备不能用，最后卸载"**（#30）、**面板观感太杂乱**（#27，3 位 X 用户，其中一句"像 2345 网址导航"）。【检索】

4. **唯一的性能硬证据是外部贡献者给的，不是用户报的**：zzzyygh 的 PR #208 实测"面板开一次再关，空闲 CPU 从 ~1% 升到 9–14% 且不回落"，根因是 `BreathingDot` 的 `repeatForever` 动画在面板保活期间永不停。而同期 `docs/faq.zh-CN.md` 写的基线是 **0.1%**——这个数只可能在"面板从未打开过的进程"里测到（该贡献者同状态实测 0.7–1.9%），用户日常的开合状态没被覆盖。【检索】【源码】【推断】

5. **分发是最大漏斗，而且已经在漏**：macOS 未公证（#11）、Windows 未签名（#12）两个 issue 至今 open；README 只有文字指引，没有一张"仍要打开"截图。第三方用 GitCode 镜像自建未签名包，**46 次下载**，高于官方 1.4.0 DMG 的 16 次。【检索】

6. **改名 + 旧账号封禁造成了一次真实事故**：从 MenuBarMijia 升到 MenuBarHome 后"同步完成但 0 设备"，至少 2 个独立来源（X、小红书）复现，用户靠"退出重登"自救；旧 Homebrew tap、旧下载链接、旧 URL scheme 全部失效且无重定向。【检索】

7. **愿意动手的用户把力气花在摄像机上**：SherlockGougou 以 PR #58 提交 8 个 commit（多机位切换、双镜头、电池机走室内机中继拉流、画面旋转），由维护者在 PR #61 合入，现已进主线（`CameraLensCatalog.swift`、`CameraHubCatalog.swift`）。【检索】【源码】

8. **用户明确要过、被正式否决的两件事**：手机端/24h 常驻桥（#15）、米家直转 Matter（#16），都落成了 `.out-of-scope/` 文档。这是产品边界，不是缺陷；但它们反复出现在小红书反馈里，说明"以为它是家庭服务器"的预期落差是系统性的。【源码】

9. **"已关闭"不能当"已解决"读**：29 个 issue 在创建后 2 分钟内被关闭，其中 27 个是从旧仓库/Forgejo 批量迁入的（#13 关闭用时 2 秒，#14 也是 2 秒；其余 2 个是内部工单 #24、#150）。96/102 的关闭率是台账口径，不是修复率。【检索】

10. **流量来源清楚但被高估**：14 天窗口内 referrer 前二为 `github.com`（90 次/58 人）和 `t.co`（35 次/17 人）；Trendshift 记录旧仓库 2026-11-02 拿过 Swift 日榜第 1、39 天 +925 star。新仓库 44 star 不是"没人要"，是账号被封导致的资产归零。【检索】

---

## 1. 样本与方法：为什么这题的样本这么小

### 1.1 台账数据（全部实读，2026-11-23）

| 指标 | 数值 | 来源 |
| --- | --- | --- |
| Issues（含已关闭） | 102（open 6） | `gh issue list --state all --limit 500` |
| Pull requests | 292（open 1，即 #396） | `gh pr list --state all` |
| Stars / Forks / Watchers | 44 / 6 / 0 | `GET /repos/jryang2026-code/MenuBarHome` |
| Discussions | 0 | GraphQL `discussions.totalCount` |
| 仓库创建 | 2026-11-08 | 同上 |
| 外部作者 issue | 3（#44、#76、#78） | 按 author 过滤 |
| 外部用户评论 | 1 条（#76 里 MrBuer-Mumu 追加） | 遍历全部 comment |
| 带用户反馈标签的 issue | 6（`from-x` 2 + `from-xiaohongshu` 4） | labels |
| 从旧仓库迁入的 issue | 28（标题 `[GH#NNN]` 或正文含"原 GitHub"；另有 #29 同属旧仓库评论迁移但无这两种标记） | 正文匹配 |
| 标记 `ready-for-agent` 的 issue | 42 | labels |

**结构判断**：42 个 `ready-for-agent` + 292 个 PR 对 102 个 issue，说明这个仓库的主用途是**多智能体任务台账**，不是用户支持台。外部用户在这一堆机器可读的工单里几乎不可见。【推断】

### 1.2 三个必须说明的口径陷阱

**（a）clone 数不是用户数。** 14 天流量：views 770 次 / 180 人，clones 19,517 次 / **1,815 人**。独立 clone 人数是独立浏览人数的 10 倍，不可能是人类行为——多智能体 worktree、CI checkout、fork 的 Actions 都会算进去。【检索】【推断】不要在任何汇报里把 1,815 说成"有 1,800 个用户"。

**（b）旧仓库不可回查。** `gh api repos/jryang1997/MenuBarMijia` 与改名重定向 `repos/jryang2026-code/MenuBarMijia` 均返回 404（账号 suspended）。旧仓库的 issue 数量、star 总数无法独立核实；Trendshift 页面也写着"can no longer sync data for this repository"。【检索】因此本报告只能引用**被搬运进新仓库的原文片段**，不能声称"旧仓库一共 N 条反馈"。

**（c）关闭率是假指标。** 29 个 issue 在创建 120 秒内被关闭，其中 27 个是批量迁移（#1–#30 中绝大部分，另含 #29；只有 #24、#150 是内部工单）。这些关闭表示"已登记"，不表示"已验证修复"——#2（晾衣架方向）在关闭时明确写着"暂无真机，先关闭，等用户反馈再重开"。【检索】

### 1.3 下载量：能反推真实用户规模

| 版本 | 发布日期 | macOS DMG | Windows setup.exe | Windows MSI | 应用内更新清单 `update.json` |
| --- | --- | --- | --- | --- | --- |
| v1.2.0 | 2026-11-08 | 107 | 72 | 9 | 7 |
| v1.3.0 | 2026-11-16 | 84 | 36 | 8 | **35** |
| v1.4.0 | 2026-11-22 | 16 | 6 | 3 | 9 |

`update.json` 只有应用内更新器会拉取，因此它比 DMG 下载量更接近"真实安装并运行的用户"：v1.3.0 的 35 次大致对应从 1.2.0 升级上去的活跃用户。【检索】【推断】结论：**活跃用户量级在几十人，不是几千人**。这也解释了为什么 GitHub 上只有 3 个外部 issue——分母本来就只有几十。

---

## 2. 逐条读外部反馈（原文 + 解读 + 处理结果）

### 2.1 #76「同步米家成功，但是无法拉取设备」——最典型的一次真实故障

- 渠道/平台：GitHub，macOS 27.2.1，App 1.2.0，米家云端 CN。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/76>
- 用户原话（追加评论）：

  > 我刚看有人发的说重新登录后拉取成功，我也尝试了一下。重启 App 后，退出登录后再扫码登录，仍然无法拉取设备

- 诊断信息显示：`设备: 0 (在线 0, 隐藏 0)`、`近期错误 4 次`；而同现象的 #67 截图里底栏状态点仍是绿色。这正是最伤人的失败形态——**看起来成功了**。
- 处理：维护者当天上午定位（issue 00:44 创建，PR #82 于 09:14 合入），一次修了三件事：响应体必须显式 `code == 0`、共享家庭与分页房间/设备发现、空家庭过滤器与诊断不再静默。PR 正文第一句就是 "Eliminates silent 'connected with 0 devices' sync outcomes"。【检索】<https://github.com/jryang2026-code/MenuBarHome/pull/82>
- 解读：这不是"用户不会用"，是**错误被吞掉**。用户能做的只有截图贴 issue，而他连"哪里出错"都看不到。

### 2.2 #67「改名迁移后同步拿不到设备，重新登录才恢复」——一次自己造成的事故

- 渠道：X 回复 + 小红书评论，双来源合并成一条 issue。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/67>
- X 用户 @irvinglove0302 原话：

  > 迁移到新的后，无法同步，重新登录可解决。回头修下或者提醒下哈

- 小红书用户 Hodgen 原话：

  > 我说怎么老版的控制不了了
  > 老版升到新版 也是重新授权了下才出现设备

- 处理：与 #76 同一个 PR #82（`Closes #67`）。根因是改名后 bundle id / 钥匙串服务名变化，旧会话没完整带过来，而 UI 没把"需要重新登录"识别成一种状态。
- 解读：**产品改名对用户是一次数据迁移事故**。两位用户都用了"重新授权"这种土办法自救，说明提示缺失比 bug 本身更贵。

### 2.3 #30「多类设备不能用，基本只能调灯，最后卸载」——最贵的一条

- 渠道：小红书笔记「电脑控米家，不用掏手机」评论区，用户 zydmxlm。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/30>
- 原话：

  > 感觉是半成品，今天试了下，空调新风啥的很多设备不能用，基本就调节灯光……最后我还是卸载了

- 处理：维护者把它挂成了"设备覆盖总单"，1.2.0–1.4.0 期间补了窗帘/晾衣架/洗衣烘干/浴霸油烟机/鱼缸喂食器/通用兜底卡等一大批品类。【检索】
- **但**：issue 正文自己写着"原报告没有具体型号、系统、版本和诊断，不能认定这些改动已解决 zydmxlm 的所有设备问题"。也就是说，**这条最贵的反馈至今没有被验证闭环**。【检索】
- 解读：这是"沉默流失"的样本——用户不会回来告诉你修好没有。唯一能补救的是**让下一位用户在流失前留下型号**。

### 2.4 #104「开灯关灯总弹高风险二次确认，找不到关闭选项」

- 渠道：X 回复 @Chjs_css。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/104>
- 原话：

  > 我开灯关灯总是提示高风险设备,得二次确认.好麻烦,没找到相关设置可以关闭这个选项.

- 处理：1.3.0 起，名称/别名含「灯/照明/light/lamp」的墙壁开关免确认；#206 又把繁体「燈」补进分类器，并把 `confirmation_golden.json` 扩到 84 条。【检索】
- 解读：修法的本质是**让用户改设备名字来绕过安全策略**（弹窗里提示"在名称里加个灯字"）。能用，但对普通用户是隐式知识，且没有"这台设备别再问我"的显式开关。

### 2.5 #27「面板太杂乱、像 2345 网址导航」——三位 X 用户的共识

- 渠道：X，@jasmine961203、@TimeStudioApps、@itshanrw 三人。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/27>
- issue 正文记录的转述：

  > 有几位朋友说面板「太杂乱」「像 2345 网址导航」「AI 布局一个样」

- 处理：PR #343（`54c97b0`）把顶部固定区块从 7 个减到 4 个，搜索与 AI 指令合并成一个常驻输入框，快捷场景折叠进抽屉。【检索】
- 解读：这是**唯一一条针对"第一眼观感"的外部负评**，而且是被转述的。1.3.0/1.4.0 的双列磁贴、液态玻璃、折叠长尾都是在回应它。

### 2.6 #15 / #16「电脑得一直开着」「能不能自动转 Matter」——预期落差，不是缺陷

- 渠道：小红书。#15 原话"缺点是电脑得一直开着"；#16 希望米家设备不经过 HA 直接变 Matter。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/15> <https://github.com/jryang2026-code/MenuBarHome/issues/16>
- 处理：都写成 `.out-of-scope` 文档，理由分别是"Matter 网桥要求 24/7 在线，笔记本合盖即全屋离线"和"桌面面板不是家庭自动化服务器"。【源码】`.out-of-scope/direct-matter-bridge.md`、`.out-of-scope/always-on-bridge-and-mobile-app.md`
- 解读：**这两条是最像"产品需求"的反馈**，而且两次都来自小红书。说明相当一部分用户是带着"替代米家 App / 当家庭中枢"的预期来的，产品定位与用户预期之间有稳定落差。

### 2.7 #29「摄像头好像开不了声音？」

- 渠道：旧仓库 GH#97 评论，用户 kkwking123（维护者从 GitHub 通知邮件核对原文）。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/29>
- 原话：

  > @jryang1997 摄像头好像开不了声音？

- 处理：双端摄像头面板加了 HLS 静音/开启声音开关与"仅画面 / Video only"状态说明。【检索】
- 解读：一句话、无版本无型号，是典型的外部反馈形态——**信息量极低，但仍然值得修**，因为"没声音"是摄像机体验的硬伤。

### 2.8 #13「缺少房间和设备（工作室 / 路由器、NAS）」

- 渠道：旧仓库 GH#319，用户环境 macOS 27.2 / 1.1.7 / 米家云端。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/13>
- 现象：自定义房间「工作室」不显示；路由器、NAS 两台设备直接消失。
- 根因（维护者已定位）：这两类没有专用卡片，`MiotSynthesizer.synthesize` 返回 `nil` 跳过；房间列表从"已合成设备"汇总，于是只有这两台设备的房间整个消失。
- 处理：靠 #304（更多设置）+ #305（通用兜底卡）解决。**关闭时并未验证**，属于"根因清楚、方案明确"的预关闭。【检索】
- 解读：**"设备消失"比"设备显示错"更伤**，因为用户会认为应用坏了。兜底卡是正确方向。

### 2.9 #14「正在握手并连接摄像机实时画面…」

- 渠道：旧仓库 GH#200，Windows 11 / 1.1.6 / `chuangmi.camera.079ac1`。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/14>
- 报错：`读取 go2rtc 组件数据失败：error decoding response body`。根因是首次打开摄像头时在线下载 `go2rtc_win64.zip` 被网络中断，留下空/截断文件。
- 处理：改为内置 `camera-bin/go2rtc.exe` + 启动前完整性校验 + 原子替换自愈。【检索】
- 解读：**Windows 端第一次用摄像机就失败**，是"安装/首次体验"类问题，不是设备兼容问题。它和 2.1 一样属于"静默失败"家族。

### 2.10 #78「设置页面的关闭能不能固定在顶部」

- 渠道：GitHub，Windows 用户 abuq。【检索】<https://github.com/jryang2026-code/MenuBarHome/issues/78>
- 原话（期望）：

  > 偏好设置那里如果滚动到中间，想退出设置还得滚上去

- 处理：PR #84 把 Windows 设置改成三段式（顶部固定关闭+分类页签、中间滚动、底部固定保存），并拆成 4 个分类页签。【检索】
- 解读：一句话、零情绪，但这是**最健康的反馈形态**——用户愿意告诉你怎么改，说明还没放弃。

### 2.11 汇总表

| # | 渠道 | 平台 | 类别 | 用户是否还在 | 处理 | 验证闭环 |
| --- | --- | --- | --- | --- | --- | --- |
| 76 | GitHub | macOS | 登录与连接（0 设备） | 未知 | PR #82 | 代码有测试，用户未回访 |
| 67 | X + 小红书 | macOS | 登录与连接（迁移） | 已自救 | PR #82 | 同上 |
| 30 | 小红书 | 未知 | 设备不支持 | **已卸载** | 覆盖大扩 | **未验证** |
| 104 | X | 未知 | 功能/安全策略 | 已回复"收到" | 1.3.0 + #206 | 未回访 |
| 27 | X ×3 | macOS | UI/UX | 未知 | PR #343 | 快照通过 |
| 15 | 小红书 | — | 功能请求 | 未知 | out-of-scope 文档 | 不适用 |
| 16 | 小红书 | — | 功能请求 | 未知 | out-of-scope 文档 | 不适用 |
| 29 | GitHub（旧） | 未知 | 设备/功能缺陷 | 未知 | 音频开关 | 未回访 |
| 13 | GitHub（旧） | macOS | 设备不支持 | 未知 | #304/#305 | 预关闭，未验证 |
| 14 | GitHub（旧） | Windows | 安装/组件下载 | 未知 | 内置组件 | 有自愈测试 |
| 78 | GitHub | Windows | UI/UX | 未知 | PR #84 | 已合入 |
| — | PR #208 | macOS | **性能/耗电** | 是贡献者 | 已合入 | 实测 11%→1.1% |
| — | PR #209 | — | 功能请求（自动化时段） | 是贡献者 | 已合入 | 单测 10 例 |
| — | PR #58 | macOS/Windows | 摄像机覆盖 | 是贡献者 | 经 #61 合入 | 真机验证 |

---

## 3. 分类频次表（n 很小，看结构不看比例）

| 类别 | 条目数 | 具体条目 | 证据强度 | 现状 |
| --- | --- | --- | --- | --- |
| 设备不支持 / 识别错 | 4 | #30（空调新风不可控）、#13（路由器/NAS/房间消失）、PR #58（电池机/双镜头）、#76（0 设备，边界重叠） | 中（有原话，缺型号） | 覆盖已大扩，#30 未回归 |
| 登录与连接 | 3 | #76、#67、#14（组件下载中断） | 高（有截图/诊断） | 均已修，代码有测试 |
| 功能请求 | 5 | #15 常驻/手机端、#16 Matter、#104 免二次确认、PR #209 时段条件、PR #58 多机位 | 高 | 2 条 out-of-scope，3 条已实现 |
| UI / UX | 2 | #27 太杂乱、#78 关闭按钮不固定 | 中高 | 均已改 |
| 安装 / 签名 / SmartScreen | 2（+2 open） | azsummer 镜像自建未签名包、#146 内部记录的未公证流失；#11/#12 仍 open | 高（有 46 次下载） | **未解决** |
| 性能与耗电 | 1 | PR #208（开合面板后 CPU 11%） | 极高（有复现与前后对比） | 已修，文档未更新 |
| 夸奖 | 3 | @geekbb "这项目真棒啊"、@jaywcjlove 推荐、@YuanZhi88613 演示视频 | 中 | — |

**读法**：不要看"哪类最多"。要看**哪类会导致用户直接消失**——是 `#30 卸载` 和 `安装失败`，不是 `#78 按钮位置`。

---

## 4. 未解决的高频诉求（按"会不会真的流失用户"排序）

### 4.1 未公证 / 未签名 + 中国大陆下载可达性（最优先）

证据链：
- `#11`（macOS Developer ID + 公证）、`#12`（Windows SignPath）至今 open，且 #11 带 `priority:high`。【检索】
- README.zh-CN.md:90 只有一段文字："第一次打开如果被拦下，到系统设置里点仍要打开"，**没有截图**；Windows 同理（:96）。#146 内部也承认"普通用户最容易在这一步流失"。【源码】
- 第三方 `azsummer/menubarmijia-cloudbuild` 明确写 "Unsigned ad-hoc build compiled from the MIT source"，**构建源是 GitCode 镜像**，发布 46 次下载，比官方 1.4.0 DMG（16 次）还多。【检索】<https://github.com/azsummer/menubarmijia-cloudbuild/releases/tag/cloudbuild-v1.1.7>

**判断**：这已经不是"潜在流失"，是**已经发生的外流**。有人宁可自己跑 CI 也不走官方渠道，原因大概率是"官方包被 Gatekeeper 拦 + GitHub 下载慢/旧链接失效"。【推断】

### 4.2 改名断链与迁移自检

旧 Homebrew tap（`jryang1997/tap`）、旧项目网站、旧 Releases 链接、旧 `menumijia://` scheme 在账号封禁后全部失效：`GET /repos/jryang1997/homebrew-tap` 返回 404，`https://jryang1997.github.io/menubarmijia-web/` 返回 404（2026-11-23 实测），而 GitHub 对已删除仓库**无法做重定向**。#151/#166 只补了 `menubarhome://` 别名和命名对照文档。【检索】用户侧的实际体感是"老版控制不了了"（#67 原话）。**缺**：升级后检测到"有账号但 0 设备"时的主动引导。

### 4.3 设备覆盖的"最后一公里"

#30 的卸载用户没有被回归。当前有 `docs/supported-devices.zh-CN.md`（"我的设备支持吗"），但它是**静态清单**，不能回答"我这台 `xiaomi.aircondition.xxx` 为什么是灰的"。【源码】缺的是"从诊断报告里的 model → 自动判断是映射缺失还是权限问题"的路径。

### 4.4 高风险确认的可解释与可配置

现在的解法是"名字带灯就免确认"（#104 → #206），本质是**用命名约定做策略开关**。对"我这盏灯就叫『书房主灯』所以没事"是有效的；对"我这台是插座但控制的是灯带"就无效。缺 per-device "不再询问"。【源码】【推断】

### 4.5 常驻/手机端（产品边界，但反复出现）

#15、#16 两次都是小红书。`.out-of-scope/` 文档写得很清楚，但**用户在下载前看不到这份文档**。README 首屏强调的是"不用掏手机"，恰好强化了"它能替代米家 App"的误解。【源码】【推断】

### 4.6 反馈闭环缺失（根因）

- 应用内只有一个"问题反馈"链接指向 GitHub issues（`SettingsWindowView.swift:2965`），没有 issue 模板引导、没有预填版本/诊断。
- 空状态文案已经写得不错（`ClassicControlCenterPanelChrome.swift:920-924`："请确认手机米家 App 里这个账号能看到设备……仍然为空，请在偏好设置里「复制诊断信息」反馈"），但**复制完还要用户自己找地方贴**。
- #17（可选、本地优先的匿名统计）被关闭，理由是隐私。结果就是：团队只能靠"有人愿意发帖"来发现问题，而 #30 那种用户直接卸载、什么都不留。【检索】

---

## 5. 从 referrers / 榜单推断用户从哪来

### 5.1 14 天 referrer（2026-11-09 ~ 11-22）

| Referrer | 访问次数 | 独立访客 | 解读 |
| --- | --- | --- | --- |
| github.com | 90 | 58 | GitHub 站内：Trending、搜索、其他仓库/榜单跳转 |
| t.co | 35 | 17 | X（Twitter）链接短链 |
| Baidu | 1 | 1 | 可忽略 |
| bilibili.com | 1 | 1 | 可忽略 |

热门路径：仓库首页 247/124、`releases/tag/v1.2.0` 75/56、`pulls` 71/**5**、`README.zh-CN.md` 69/51、`issues` 68/22、`pull/58` 40/**1**。【检索】

两个细节值得注意：
- **`pulls` 71 次访问只有 5 个人**，`pull/58` 40 次只有 1 个人——这是我们自己的多智能体在刷 PR 页面，不是用户。【推断】
- **v1.2.0 的 release 页比 v1.3.0/v1.4.0 热**（75/56 vs 34/30），说明大量流量来自外部文章/帖子里的**旧固定链接**，而不是"来看最新版"。【推断】

### 5.2 Trendshift：旧仓库的真实量级

- 2026-10-24 首次进 Swift 日榜 #21；**2026-11-02 日榜 #1**（当天 +273 star、+20 fork）；11-03 #9；11-01 #3。【检索】<https://trendshift.io/repositories/309141>
- 39 天累计 **+925 star、+58 fork**（页面口径）。【检索】
- 页面记录的社交提及：@YuanZhi88613（10-17 演示视频、10-21 HA 合并卡）、@jaywcjlove（10-24）、@geekbb（11-11 "这项目真棒啊"）、作者本人多条。【检索】

### 5.3 结论：三层漏斗

1. **X（中文技术圈）是点火器**：@jaywcjlove、@geekbb、@YuanZhi88613 这类账号转发 → t.co 进 GitHub。
2. **GitHub Trending / Trendshift 是放大器**：11-02 冲到 Swift 日榜 #1，带来一次性 star 峰值。
3. **小红书是转化落点，但 referrer 被剥离**：4 条 `from-xiaohongshu` issue 证明有真实流量，但 traffic 面板里几乎看不到（外链常被平台抹掉来源）。

**推论**：新仓库 44 star ≠ 需求消失。旧账号封禁把 900+ star、58 fork 的资产归零了，现在看到的是一台刚重启的机器。【推断】

---

## 6. 用户到底改了什么（fork / PR / 镜像）

| 对象 | 动作 | 说明了什么 |
| --- | --- | --- |
| SherlockGougou | PR #58，8 个 commit、约 1,600 行，改摄像机 | 家里有多台/电池摄像头，官方拉不出流；自己动手做了多机位、双镜头、室内机中继 |
| zzzyygh | PR #208（CPU 泄漏）、PR #209（自动化时段） | 真正的 power user：会自己采样 CPU、会把"21:00 预热被 21:15 回家规则关掉"抽象成功能需求 |
| azsummer | 建 `menubarmijia-cloudbuild`，GitCode 镜像 + Actions 构建 | 要一个能装上的包；官方渠道对他不可用 |
| MemeLin1213 / yutaocn / jesson904 / MrBuer-Mumu | fork 但 0 commit ahead | 纯跟随/备份，没有改造意图 |
| abuq / MrBuer-Mumu | 各开 1 个 issue | 普通用户，愿意反馈 |

**解读**：6 个 fork 里只有 2 个产生过真实改动（SherlockGougou 的摄像机、zzzyygh 的两个 PR），其余 4 个是纯跟随/备份。而这两份改动都进了主线。**这个项目的功能演进有相当一部分是"用户自己写 + 维护者合并"驱动的**，不是需求投票驱动的。【推断】

---

## 对照我们：差距表

| 我们文件 / 模块 | 现状 | 对标（用户反馈） | 建议 | 成本 |
| --- | --- | --- | --- | --- |
| `README.zh-CN.md:84-96` 安装段 | 未公证/未签名只有两段文字，无截图、无"仍要打开"图示 | #146 内部承认这是最大流失点；azsummer 自建包 46 次下载 | 补 2 张截图（macOS 隐私与安全性、Windows SmartScreen）+ 一段 15 秒 GIF；同时给 SHA-256 校验命令 | S |
| 分发渠道 | 只有 GitHub Releases + 自有 brew tap | 大陆用户走 GitCode 镜像自建 | 增加一个官方大陆镜像（GitCode/Gitee 同步 release 二进制），tap 保留两个 | M |
| `docs/faq.zh-CN.md:11-14` | 基线写 0.1%，未标注"面板开合后"状态 | PR #208 实测 9–14% 且不回落；1.4.0 又改成卸载视图树 | 增测三种状态（从未打开 / 开合一次后 / 长时间保活），标注测量版本与日期 | S |
| `README.zh-CN.md:67` | "面板开着不操作时 CPU 占用约 0.1%" | 同上，这句对"开合过"的用户不成立 | 改成"面板关闭时"或补一句"1.4.0 起关闭面板会卸载视图树" | S |
| 空状态 `ClassicControlCenterPanelChrome.swift:920-924` | 已有"同步完成但没设备"+ 引导复制诊断 | #76 用户只能贴长截图 | 加"一键复制并打开 issue 模板"，自动带上版本/地区/设备数 | M |
| `Sources/MenuBarMijiaApp/SettingsWindowView.swift:2965` | "问题反馈"直接跳 issues 列表 | 外部用户不会写结构化 issue | 跳转 `issues/new?template=bug.yml`，或用 URL 参数预填诊断 | S |
| 高风险确认（#104/#206） | 靠名称关键词豁免，弹窗提示"加个灯字" | 用户找不到关闭入口，觉得"好麻烦" | 设备详情里加"此设备不再询问"（写入 `ManualControlPolicy`，仍保留插座/总闸硬保护） | M |
| `docs/supported-devices.zh-CN.md` | 静态支持清单 | #30 卸载用户、#13 消失的路由器/NAS | 加"按 model 搜索"+ "没找到？贴诊断"入口，把用户 model 直接进 `miot_golden.json` | M |
| 迁移路径（改名后） | 有 `menubarhome://` 别名 + 文档 | #67 两来源"重新登录才好" | 升级后若"已登录但 0 设备"，直接弹"检测到旧版数据，请重新扫码" | S |
| 遥测 / 反馈闭环 | 无（#17 因隐私关闭） | 只能等用户主动发帖，#30 直接卸载 | 先做**本地**"功能使用摘要"导出（不上传），用户愿意才贴到 issue | M |
| 摄像机型号覆盖 | 已有 `CameraLensCatalog` / `CameraHubCatalog` | PR #58 来自真实电池机用户 | 把"电池机必须选室内机"写进 supported-devices 与错误文案（`MiCloudProvider.swift:2097` 已有雏形） | S |

---

## 推进清单

| # | 标题 | 价值 | 成本 | 优先级 | 高风险面？ | 依据 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 安装页补"仍要打开 / SmartScreen"截图 + 校验命令 | 直接减少首次启动流失 | S | **P0** | 否（纯文档） | #146、镜像 46 次下载 |
| 2 | 更正 README/FAQ 的 CPU 基线口径 | 避免"文档说谎"，也是性能回归的锚点 | S | **P0** | 否 | PR #208、`faq.zh-CN.md:13`、`README.zh-CN.md:67` |
| 3 | 升级迁移自检：已登录但 0 设备 → 引导重扫 | 修掉一次真实事故的复发路径 | S | **P0** | 是（登录/凭据边界） | #67、#76、PR #82 |
| 4 | 应用内"一键反馈"：预填诊断 + issue 模板 | 把"复制诊断"变成"发出诊断" | S–M | P1 | 否 | #76 的交互形态、`SettingsWindowView.swift:2965` |
| 5 | 高风险确认加 per-device "不再询问" | 去掉"改名字绕策略"的隐式知识 | M | P1 | **是**（设备控制安全策略） | #104、#206 |
| 6 | 大陆镜像分发（GitCode/Gitee 同步 release） | 接住已经在自建包的用户 | M | P1 | 是（发布链路） | azsummer 镜像 |
| 7 | 设备覆盖回归清单：把用户诊断里的 model 进 golden corpus | 让 #30 这类"不能用"可验证 | M | P2 | 否 | #30、#13、`supported-devices.zh-CN.md` |
| 8 | 本地功能使用摘要导出（不上传） | 在不碰隐私的前提下拿到使用结构 | M | P2 | 是（隐私） | #17 |
| 9 | 把 `ready-for-agent` 等内部标签从公开 issue 收起来 | 外部用户看 issues 列表会以为这是机器人仓库 | S | P2 | 否 | 42 个 `ready-for-agent` |
| 10 | 常驻桥 / 手机端重新评估 | 反复出现的最大预期落差 | L | P3 | 是（架构） | #15、`.out-of-scope/always-on-bridge-and-mobile-app.md` |

---

## 设想（天马行空，与现有 ADR 的关系已注明）

1. **"反馈即 issue"的诊断包**：诊断报告生成时顺带建一个匿名 gist（不含 DID/令牌），用户点"提交"就把链接贴进 issue。与 ADR-0004（不存 passToken）不冲突，但要新增一份"哪些字段可以出网"的白名单。
2. **兼容性投票页**：`docs/supported-devices.zh-CN.md` 每行加"我用过 ✓ / 用不了 ✗"，数据来自 issue 里的 model + 用户自报。等于把 #30 那种"说不清型号"的反馈结构化。
3. **发布节奏实验**：Trendshift 显示 11-02 单日 +273 star 是 KOL 转发触发的。可以故意把"大版本 + 演示 GIF"对齐到一次 X 转发，而不是每周发小版本。
4. **把 `.out-of-scope` 前置到下载页**：在 Releases 正文第一段写"这是桌面面板，不是 24/7 家庭服务器；手机端与 Matter 桥不在范围内"。冲突：与现有 README 营销口径（"不用掏手机"）有张力，需要产品拍板。
5. **进程外常驻桥**（远期）：ADR-0020 否决的是"进程内第三方代码插件"，进程外的独立 MCP/HTTP 桥是允许重启评估的方向。如果 #15 反复出现，可以做一个"用户自己的树莓派跑 bridge"的官方 recipe，而不是内置。**与 `.out-of-scope/always-on-bridge-and-mobile-app.md` 冲突**，需重开讨论。
6. **Fork 回流机制**：PR #58 证明"用户自己改摄像机"是可行的。可以维护一份 `docs/agents/contributor-wishlist.md`，把"我们没设备、欢迎你带真机来改"的型号列出来（晾衣架方向、猫眼门铃事件都是这类）。

---

## 来源清单

GitHub 仓库与 issue/PR（读取日期 2026-11-23）：
- 仓库首页与统计：<https://github.com/jryang2026-code/MenuBarHome>（44 star / 6 fork / 102 issue / 292 PR）
- 外部用户 issue：#76 <https://github.com/jryang2026-code/MenuBarHome/issues/76>、#78 <https://github.com/jryang2026-code/MenuBarHome/issues/78>、#44（已撤回）
- 外部反馈搬运：#67 <https://github.com/jryang2026-code/MenuBarHome/issues/67>、#104 <https://github.com/jryang2026-code/MenuBarHome/issues/104>、#30 <https://github.com/jryang2026-code/MenuBarHome/issues/30>、#15、#16、#27、#29、#13、#14（同仓库 `/issues/<n>`）
- 处理 PR：#82 <https://github.com/jryang2026-code/MenuBarHome/pull/82>、#84 <https://github.com/jryang2026-code/MenuBarHome/pull/84>、#61 <https://github.com/jryang2026-code/MenuBarHome/pull/61>、#208 <https://github.com/jryang2026-code/MenuBarHome/pull/208>、#209 <https://github.com/jryang2026-code/MenuBarHome/pull/209>、#58 <https://github.com/jryang2026-code/MenuBarHome/pull/58>
- 未解决分发项：#11、#12（同仓库 `/issues/11`、`/issues/12`）
- Releases 与下载量：<https://github.com/jryang2026-code/MenuBarHome/releases>（v1.2.0 / v1.3.0 / v1.4.0）
- Traffic（14 天，2026-11-09 ~ 11-22）：`/traffic/views`（770/180）、`/traffic/clones`（19,517/1,815）、`/traffic/popular/referrers`、`/traffic/popular/paths`

旧仓库与第三方：
- 旧仓库 API：`repos/jryang1997/MenuBarMijia` → 404（账号 suspended）；旧 tap `repos/jryang1997/homebrew-tap` → 404；旧项目站 `https://jryang1997.github.io/menubarmijia-web/` → HTTP 404（均 2026-11-23 实测）
- Trendshift：<https://trendshift.io/repositories/309141>（11-02 Swift 日榜 #1，39 天 +925 star / +58 fork）
- 第三方镜像：<https://github.com/azsummer/menubarmijia-cloudbuild>，release <https://github.com/azsummer/menubarmijia-cloudbuild/releases/tag/cloudbuild-v1.1.7>（unsigned，46 次下载，源为 GitCode 镜像）
- 旧 GitHub issue 原文（已不可访问，仅经新仓库转述）：`jryang1997/MenuBarMijia/issues/97`、`/188`、`/190`、`/191`、`/200`、`/136`、`/160`、`/319`、`/296–310`
- 小红书：`xiaohongshu.com/explore/6ae854d9000000000f025241`（zydmxlm）、`/explore/6af14279000000003401caf3`（Hodgen）
- X：`x.com/irvinglove0302/status/2119967775053709545`、`x.com/Chjs_css/status/2120929520979165252`、`x.com/jasmine961203/status/2117071061070332160`、`x.com/TimeStudioApps/status/2117077386986652085`、`x.com/itshanrw/status/2116831767126761804`

本仓库源码/文档：
- `README.zh-CN.md:67`（CPU 0.1% 表述）、`:84-96`（安装段）
- `docs/faq.zh-CN.md:11-14`（性能基线）
- `Sources/MenuBarMijiaApp/Classic/ClassicControlCenterPanelChrome.swift:920-924`（空状态）
- `Sources/MenuBarMijiaApp/SettingsWindowView.swift:2965`（问题反馈链接）
- `Sources/MijiaCore/MiCloud/CameraLensCatalog.swift`、`CameraHubCatalog.swift`、`MiCloudProvider.swift:2097`
- `.out-of-scope/always-on-bridge-and-mobile-app.md`、`.out-of-scope/direct-matter-bridge.md`
- `docs/supported-devices.zh-CN.md`

**未查到**：旧仓库的完整 issue 列表与总 star 数（账号封禁，API 404）；任何 GitHub Discussions 数据（仓库 Discussions 为 0）；Homebrew cask 安装量（GitHub 不公开）；用户留存/卸载率（无遥测）。

---

**摘要（5 行）**
1. 样本极小但方向清楚：GitHub 只有 3 个外部 issue，真正的反馈在 X 与小红书，最贵的一条（#30）用户已卸载且至今未回归验证。
2. 建议 P0：安装页补"仍要打开 / SmartScreen"截图 + 大陆镜像分发——第三方自建未签名包 46 次下载已经超过官方 1.4.0 DMG。
3. 建议 P0：更正 README/FAQ 的 0.1% CPU 口径，并把"升级后已登录但 0 设备"做成主动引导（PR #208 与 #67 都证明现状文档/提示在误导用户）。
4. 结构性建议：把"复制诊断"升级成"一键开 issue（预填诊断）"，否则永远只有愿意手写长截图的用户才会被听见。
5. 报告路径：`docs/research/2026-11-23-deep-dive/08-own-github-feedback.md`。
