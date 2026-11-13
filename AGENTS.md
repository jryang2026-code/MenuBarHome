# MenuBarHome

macOS 菜单栏（Swift / AppKit + SwiftUI）与 Windows 托盘（Tauri + TypeScript）双端智能家居控制中心，支持 Home Assistant 与米家云端直连。

## Issue、领域与按需文档

- **唯一问题与 PR 源**：GitHub（`https://github.com/jryang2026-code/MenuBarHome`，`origin`）经 `gh` CLI（登录账号 `jryang2026-code`）操作。旧账号 `jryang1997` 已封禁；`gitlab` 与 `nas`（NAS Forgejo）仅作备份，**严禁在两处提单或写入**（file nothing there）。
- **文档路由（命中对应分支时读取）**：
  - 操作 Issue/PR、查 CI 失败（`ci_errors.sh`）、判 PR 合入（`pr-ready.sh`）、盘点分支/工作树（`pending-work.sh`）、挑票（`issue-frontier.sh`）或遇旧编号（`[GH#304]`、`!54`）：读 `docs/agents/issue-tracker.md`。
  - 命名领域概念对齐 `GLOSSARY.md`；改动架构边界核对 `docs/adr/`（冲突须显式指出，见 `docs/agents/domain.md`）。
  - 审阅 diff（`/code-review`）或回溯规范（`/retro`）：查 `CODING_STANDARDS.md`（日常读写源码由 `.claude/rules/*.md` 与 `.agents/hooks.json` 按路径自动注入）。排查门禁跳步、快照差异、`hdiutil attach` 锁竞争或改 `scripts/` 时读 `docs/agents/gates.md`。
  - Windows 摄像机实时流排障、go2rtc/FFmpeg 内置或 Tauri 安装包构建：读 `docs/agents/windows-camera.md`。
  - 应用内更新链路、Ed25519 清单验签、失败恢复分类或替换脚本（`Update*.swift` / `scripts/release.sh`）：读 `docs/agents/in-app-update.md`。
  - 在 Cursor Cloud 或 Linux 容器工作：读 `docs/agents/cursor-cloud.md`。维护 `.cursor/skills/` 副本时读 `.cursor/skills/README.md`。

## 验证完成判据与环境边界

- **门禁判据**：`bash scripts/check.sh` 覆盖密钥扫描、机械 lint 与 `swift test`（含快照），**不跑 Rust 测试**。有跳过项时打印 `⚠️ 部分通过：跳过 <名称>` 且**退出码仍为 0**（缺本工作树 `windows/node_modules` 时会尝试复用锁文件匹配的兄弟工作树跑 `windows/tests/*.test.ts`，`tsc && vite build` 与 `raycast` 无本地 `node_modules` 仍跳过且不自动 `npm ci`）——确认输出无非预期跳过才算通过。提交钩子只跑 `--lint-only`：开 PR 或向 PR 推送前须跑一次完整的 `bash scripts/check.sh`。PR 上的 CI 不跑 `macos-release`、`macos-appintents`、`windows-installer`（`main` 与手动触发才跑），改打包链路的 PR 合并前用 `gh workflow run CI --ref <分支>` 补跑。
- **渲染与实机边界**：快照基线以维护者这台 Mac 渲染为准，`--skip-snapshots` 仅限非维护者 Mac。面向用户的界面改动单靠单元测试不算完成，须附快照或实机验证证据。
- **Windows 与检索环境**：Windows 本机无 Swift 工具链，本地跑 `bash scripts/check.sh --lint-only`，Swift 测试交 CI 或局域网 Mac（`bash scripts/remote-swift-test.sh --host <user>@<mac>`，配置见脚本头）。本仓 Swift 与 Rust 无语言服务器，引用与定义检索用 `grep`。macOS 本机打包安装、图标重生成、工作流 `actionlint` 均由 `.claude/rules/` 按路径加载。

## 提交、PR 与并发安全

在用户已授权提交的范围内，按改动影响范围（不按代码行数）选择直接 push 或开 PR：

- **可直接 push `main`**：文案、文档、图标、样式微调，及范围明确的局部交互修复（须有针对性验证与用户实机确认）。直接 push 不等于发版；推送后有 runner 时须确认云端检查结果，交付时明确区分「已推送」与「检查已通过」。
- **必须走 PR 且检查全绿后再合并**：登录、凭据与钥匙串、安全权限、设备控制、撤销、定时任务、数据迁移、自动更新、签名、打包发布、跨平台逻辑、多模块改动，以及原因未明的检查失败（已复现确认与本轮无关的既有失败须记录证据与例外原因，禁止默认跳过检查）。
- **PR 与分支纪律**：一题对应一次提交或一个 PR，后续调整继续走原 PR；单个 PR 的改动控制在约 800 行以内（快照 PNG、夹具、锁文件不计），超出先拆题再开工；自动评审（Codex）最多跟两轮，两轮后只有可达的安全、数据丢失或崩溃问题才继续在本 PR 修，其余转 GitHub issue 后合并；多代理并行时一次合一个，PR 自身检查全绿即可合，不必等上一个合入后的 `main` 流水线跑完，但 `main` 流水线变红时停止合并、先修复；已开 PR 跟进 `main` 用 `git merge main`，**严禁 `rebase` 强推**；多行提交说明写文件用 `git commit -F`；提交只含本轮改动；`CHANGELOG.md` 只写未发版段（已在 `git tag` 的版本段严禁追加）。
- **Runner 安全红线**：严禁把维护者这台含签名私钥的 Mac 宿主机注册为自托管 runner。CI 可通过 `MACOS_CI_RUNNER` 使用本机隔离的 macOS 虚拟机：单任务、任务后销毁、不共享宿主目录、钥匙串或剪贴板，并阻断宿主与局域网访问；发布签名仍用原流程。安装、启停与回退见 `docs/agents/local-macos-runner.md`。`gh pr checks <n>` 首次为空时按退避重试。
- **工作树与子代理责任**：`git worktree list` 中登记给其他会话的工作树（如 `wt/dev`）审计只读、严禁改文件；接管前先确认无新提交且 `git status` 干净（对方仍在迭代时在独立分支副本修改）；审计途中若有新提交落地，按最新提交重读后再下结论。主代理对子代理产出负全责，须亲自审 diff、对照 `HEAD` 核实每处引用的 `path:symbol` 存在后再写交接或总结，不透传子代理原话。
