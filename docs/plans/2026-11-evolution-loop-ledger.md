# 2026-11 演进循环状态账本

唯一真相源：跨线程推进 `docs/research/2026-11-24-full-survey/00-MASTER-ROADMAP.md` 的 P0–P3、Track D 与现存 Open Issues。新调研项只记在本账本，不新开 GitHub Issue；PR 解决已有 Issue 时才写 `Closes #<号>`。

## 当前交接快照

- 更新时间：2026-11-24 20:50 CST（Wave 0 收口，Wave 1 启动）
- `main`：`0b9e9498`，CI 绿
- Wave 0：8/8 DONE（#463 #464 #465 #466 #467 #468 #469 + main 1682695f）
- 已完成不再派活：`#453`、`#461`（Windows Rust miIO 原生层）、`#460`（WidgetKit 签名可行性 spike）、`#462`（调研总纲）
- main 红一次（#467 新增 TV 撤销测试抖动）已由 2caf7730 修绿
- 需作者拍板：`v1.5.0` 发版、`#12` SignPath 申请启动

## 模型分派约定

| 代号 | 通道 | 用途 |
| --- | --- | --- |
| Hydrogen High | `antigravity` / `gemini-4-hydrogen` / `thought_level=high` | 文档、样式、测试、常规小单 |
| Neon Mid | `antigravity` / `gemini-4-neon` / `thought_level=medium` | 疑难稳定化、跨端交互、竞态、CI 卡点 |
| Codex sol6.2 | `codex` / `gpt-6.2-sol` / `reasoningEffort=medium` | 后端、协议、传输、同步内核、Rust/Swift 底层 |
| Flash | `pi` 或 `opencode` / `magpie/group/flash-worker` / max | 常规实现切片、单测、提交与开 PR |

## Wave 0：止血与小单清尾（本线程）

| ID | 关联已有Issue | 模型分派 | 前置依赖 | 通道 | 状态 | PR/SHA | 交接备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W0-1 P0-1 文案去自黑 | — | Hydrogen High | 无 | 快车道main | DONE | main 1682695f | README / README.zh-CN / GLOSSARY / platform-matrix；Win11 GIF 需实机录制→HUMAN_GATE |
| W0-2 #305 只读共享账号写入过滤 | #305 | Codex sol6.2 | 无 | PR | DONE | #463 → main dd95812 | 控制写入高风险面；主控审出 P1（共享设备不可控、冷启动硬拦），第 1 轮已修为“确认归属优先 + 权限拒绝转下一账号” |
| W0-3 #314 间歇失败用例收敛 | #314 | Neon Mid | 无 | PR | DONE | #464 → main d94aa56 | 与 W0-2 同触 `DualSourceFallbackGraceTests.swift`，合入时 `git merge origin/main` |
| W0-4 macOS 小收口 | #420 #429 #397 | Flash (pi) | 无 | PR | DONE | #466 → main 46cfc4f | 菜单栏宽度磁滞、AppleMotion 测试覆写、暂停分组收尾；#397 第 3 条只清无可恢复目标的旧标记（全量清扫会复活 HA 移除暂停的分组，违背 #389） |
| W0-5 双端小收口 | #428 #451 | Flash (opencode) | W0-2 合入后（同触 `MiCloudProvider.swift`） | PR | DONE | #468 → main d9e7f8e7 | 助手温度单位、无 uid 自有家庭场景；含语料用例 |
| W0-6 macOS buildTV | #442 | Hydrogen High | 无 | PR | DONE | #467 → main 4ea541e | 黄金语料语义变更；`WINDOWS_DIVERGENCE_BUDGET` 收紧到 0 |
| W0-7 更新调度节拍对齐 | #455 | Codex sol6.2 | W0-2 完成后（同一通道串行） | PR | DONE | #465 → main c895091 | 自动更新高风险面 |
| W0-8 Windows 引导无障碍与水合 | #293 | Flash (opencode) | 无 | PR | DONE | #469 → main 0b9e9498 | Windows 前端 |

## Wave 1：P0 内核止血（传输、焦点、零回弹）

| ID | 关联已有Issue | 模型分派 | 前置依赖 | 通道 | 状态 | PR/SHA | 交接备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1-1 D-1 发版文档同步纪律 | — | Hydrogen High | 无 | 快车道main | DONE | main 187b6743 | 发版 Checklist 加 README/platform-matrix/GLOSSARY 核对门禁 |
| W1-2 P0-7 macOS 面板零抢焦 | — | Neon Mid | 无 | PR | DONE | #474 已合 | `.nonactivatingPanel` + 5 护栏；完整 check.sh ；45s 温热卸载 + 200ms 伸缩动画未做（留 Wave 2A P1-3） |
| W1-3 P0-6 Win 托盘 5 处硬伤 | — | Neon Mid | 无 | PR | DONE | #472 已合 | window.rs / main.rs / companion.rs / desktop_shell.rs；Rust 测试靠云端 |
| W1-4 P0-3a Win Rust 连接池 + 持久 HA WebSocket | — | Codex sol6.2 | 无 | PR | DONE | #471 + #473 已合 | network.rs / home_assistant.rs |
| W1-5 #443 专注模式名过滤 | #443 | Hydrogen High | W1-1 | PR | DONE | #475 已合 | |
| W1-6 P0-3b macOS HA subscribe_entities | — | Codex sol6.2 | W1-4 | PR | DONE | #477 → main d19785d | HomeProvider.swift，与 W1-7 macOS 部分串行 |
| W1-7 P0-4 休眠/网络切换半开 TCP 斩杀 | — | Neon Mid（Win network_monitor.rs）+ Codex sol6.2（macOS） | W1-3、W1-6 | PR | IN_PROGRESS | W1-7a Neon(Win) + W1-7b Codex(mac) | 双端拆两个 PR |
| W1-8 P0-5a Win 米家局域网 Part 2 + 写确认 | #457 | Codex sol6.2 | W1-4 | PR | DONE | #478 → main 27a8dfc | TS 混合路由 |
| W1-9 P0-5b status=all + Shared/specPatches.json | — | Neon Mid | W1-8 | PR | IN_PROGRESS | | 跨端契约 |
| W1-10 P0-8 Per-Field writeEpoch 零回弹 | — | Codex sol6.2 | W1-8 | PR | IN_PROGRESS | | 控制写入 + 黄金语料；datasource:1 真机部分 HUMAN_GATE（#411） |
| W1-11 #424/#446 摄像机桥接监督与 go2rtc 收敛 | #424 #446 | Neon Mid | W1-3 | PR | DONE | #476 已合（#424） | 可延至 Wave 2A 的 P1-2 ；#424 已做（+1736 行，内聚未拆）；#446 go2rtc CS2 补丁 + 打包链路未做，需独立 PR |
| W1-12 #446 go2rtc CS2 补丁与配置收敛 | #446 | Neon Mid | W1-11 | PR | IN_PROGRESS | | 打包链路高风险，配置收敛可拆 |

## Wave 2A：P1 桌面护城河与手感

| ID | 关联已有Issue | 模型分派 | 前置依赖 | 通道 | 状态 | PR/SHA | 交接备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1-1 桌面即传感器 2.0 | #430 #431 #432 | Codex sol6.2 + Neon Mid | Wave 1 | PR | TODO | | |
| P1-2 摄像机桌面盯屏 | #445 #447 | Neon Mid | P0-6 | PR | TODO | | |
| P1-3 首屏美学减法 + 零弹窗确认 | — | Hydrogen High / Neon Mid | Wave 1 | 样式快车道 / L2-L3 PR | TODO | | |
| P1-4 Win 原生材质 + WebView2 瘦身 | — | Neon Mid | P0-6 | PR | TODO | | |

## Wave 2B：P1 写入管线、热键与安全底座

| ID | 关联已有Issue | 模型分派 | 前置依赖 | 通道 | 状态 | PR/SHA | 交接备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1-5 滑块邮箱 + 429 令牌桶 + 合并写 | — | Codex sol6.2 | P0-8 | PR | TODO | | |
| P1-6 全局热键 + 盲操 HUD + 投屏防窥 | — | Neon Mid | Wave 1 | PR | TODO | | |
| P1-7 Capture Mood + 房间群控 | #294 | Codex sol6.2 | P1-5 | PR | TODO | | |
| P1-8 DNS Rebinding + Job Object + 防误删 | #412 | Codex sol6.2 | Wave 1 | PR | TODO | | #412 只读 LAN 探测并入评估 |

## Wave 3A：P2 插件化与多厂商

| ID | 关联已有Issue | 模型分派 | 前置依赖 | 通道 | 状态 | PR/SHA | 交接备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P2-1 ADR-0024 v0 收口 + webOS Sidecar | #456 #438 | Codex sol6.2 | Wave 2 | PR | TODO | | |
| P2-2 L0 JSON 驱动 + Credential Broker | — | Codex sol6.2 | P2-1 | PR | TODO | | |
| P2-3 ADR-0024 v1 受控写入 + SDUI | — | Codex sol6.2 + Neon Mid | P2-2 | PR | TODO | | |
| P2-4 通用摄像机接入 | — | Codex sol6.2 | P1-2 | PR | TODO | | |

## Wave 3B：P2 内核统一与 P3 条件触发

| ID | 关联已有Issue | 模型分派 | 前置依赖 | 通道 | 状态 | PR/SHA | 交接备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P2-5 Win 后台状态与凭据下沉 Rust | — | Codex sol6.2 | Wave 3A | PR | TODO | | |
| P2-6 N 源去重图谱 + Happy Eyeballs | — | Codex sol6.2 | P2-5 | PR | TODO | | |
| P2-7 伴生生态 MCP 权限 + Raycast Store | #437 | Hydrogen High | 无 | PR | TODO | | Store 上架提交本身为 HUMAN_GATE |
| P3-1 ~ P3-6 | — | — | 生态起量后条件触发 | — | TODO | | 未达触发条件不派活 |

## HUMAN_GATE（自动跳过，绝不擅自触发）

| ID | 关联已有Issue | 状态 | 说明 |
| --- | --- | --- | --- |
| P0-2 / #12 SignPath 申请 | #12 | HUMAN_GATE | 人工提交 |
| #11 Apple Developer ID | #11 | HUMAN_GATE | 人工提交；P3-2 WidgetKit 被其阻塞 |
| #411 datasource:1 真机实测 | #411 | HUMAN_GATE | 真机 |
| #449 miIO.sub 推送 | #449 | HUMAN_GATE | 延后（与 P3-5 合并） |
| v1.5.0 正式发版 Tag/Release | — | HUMAN_GATE | 作者拍板 |
| P0-1 Win11 实机 GIF | — | HUMAN_GATE | 需实机录制 |
| D-2 ~ D-6 对外发帖、外部仓库 PR、WinGet | — | HUMAN_GATE | 对外发布 |

## 明确否决（永不派活）

NO-1 ~ NO-11，见总纲 §5.7。
