# MenuBarHome

macOS 菜单栏（Swift / AppKit + SwiftUI）与 Windows 托盘（Tauri + TypeScript）双端智能家居控制中心，支持 Home Assistant 与米家云端直连。

## Issue 与仓库边界

- **唯一问题与 PR 源**：GitHub（`https://github.com/jryang2026-code/MenuBarHome`，`origin`），通过 `gh` CLI（账号 `jryang2026-code`）操作；`gitlab` 与 `nas` 为只读镜像，勿向两处提单（已停用账号 `jryang1997` 提交与镜像远端推送已由 `check.sh` 和 `pre-push` 拦截）。

## 交付分流：默认直接 push `main`，仅高风险面走 PR

在用户已授权提交的范围内，按**改动影响面**决定直接推 `main` 还是开 PR：

- **默认直接 push `main`（快车道）**：文案、文档、图标、样式/布局微调、局部 UI/交互修复、测试补充、内部重构或脚手架脚本改进。推送前跑过对应验证，推送后确认云端 CI 全绿，交付时明确区分「已推送」与「CI 已通过」。`git push origin main` 会触发 `pre-push` 钩子自动跑 `check.sh --changed`。
- **必须走 PR（checks 全绿后合入）的 5 类高风险面**：
  1. 登录、凭据、钥匙串与网络传输边界（`MiSession`、`KeychainHelper`、`secureStore`、明文 HTTP 同意与局域网端点校验）
  2. 设备控制写入与安全策略（真实控制指令、二次确认、`allOffTargets`、锁屏拦截、`ScheduledCommand` 作用域/定时）
  3. 数据迁移、跨源设备去重（`DeviceDeduplicator`）与跨端黄金语料语义变更
  4. 自动更新与代码签名/发版（`Update*.swift`、`release.sh`、Ed25519 验签）
  5. 跨平台契约或包构建/发布链路变更（`.github/workflows/` 打包链、Windows MSI/NSIS 安装器）
- **PR 纪律**：单 PR 代码改动控制在约 800 行以内（PNG、夹具、锁文件不计）；Codex 自动评审最多 2 轮（`bash scripts/pr-ready.sh --wait --max-codex-rounds 2 <pr>`），2 轮后仅修可达的安全、数据丢失或崩溃问题，其余转 issue 后合入；已开 PR 跟进 `main` 用 `git merge origin/main`（**严禁 rebase 强推**）；多代理并行时逐个合入，见 `main` 红即停、先修 `main`；多行提交说明用 `git commit -F`。
- **`CHANGELOG.md`**：仅发版整理，不要求每个 PR 手动维护（已在 `git tag` 的版本段严禁追加）。

## 本地门禁与验证环境

- **`git commit`（<0.5s）**：自动跑 `bash scripts/check.sh --lint-only`（密钥扫描、Git 身份、Swift 宏/并发崩溃守卫与 Ed25519 公钥一致性）。全量契约与脚本自检加 `--script-tests`。
- **推 `main` / 开 PR 前**：非 UI 改动跑 `bash scripts/check.sh --changed`；**macOS 界面改动**在本机跑 `bash scripts/check.sh`。像素基准是 GitHub 托管的 `macos-26-intel`（Xcode 26.6，zh_CN），由 CI 的 `macos-test` 比对。本机默认跳过像素比对，汇总里的 `Snapshots` 跳过是预期结果。本机预览或录制用 `bash scripts/check.sh --snapshots` / `bash scripts/record_snapshots.sh`。更换该镜像或 Xcode 后必须重录。确认没有其他非预期的 `⚠️ 部分通过：跳过 ...`。
- **专项检查**：工作流改动跑 `actionlint .github/workflows/*.yml`；维护者 Mac 未装 `cargo`/`rustc`，`windows/src-tauri` 原生层测试由云端 CI `windows-rust-test` 承担（Windows 宿主机跑 `cargo test --locked --manifest-path windows/src-tauri/Cargo.toml`）；Windows 隔离工作树跑前端检查用 `bash scripts/shared_windows_deps.sh run npm --prefix windows test`（勿手工反复 `ln -sfn` / `rm -rf windows/node_modules`）；单测提速用 `node windows/scripts/test-file.mjs tests/<file>.test.ts`（支持 `--test-name-pattern <pattern>` 只跑匹配用例）。
- **检索与跨端**：Windows 无 Swift 工具链时本机跑 `--lint-only`（或 `scripts/remote-swift-test.sh`）；本仓 Swift/Rust 无 LSP，引用检索用 `grep`。

## 领域约定与按需文档

- 领域术语对齐 [`GLOSSARY.md`](GLOSSARY.md)；模块与文件路径速查先看 [`docs/feature-map.md`](docs/feature-map.md)（避免跨工作树盲猜路径）；改动架构边界先查 [`docs/adr/INDEX.md`](docs/adr/INDEX.md)，与已接受 ADR 冲突时须显式声明。
- 非机械编码/并发/UI/测试规范见 [`CODING_STANDARDS.md`](CODING_STANDARDS.md)。
- 专项 Runbook（仅命中对应任务时读取）：
  - Issue/PR 编号、老号映射与协同脚本：[`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md)
  - 派活给其他模型时的固定说明行：[`docs/agents/delegation-brief.md`](docs/agents/delegation-brief.md)
  - Windows 摄像机实时流、go2rtc/FFmpeg 与 Tauri 打包：[`docs/agents/windows-camera.md`](docs/agents/windows-camera.md)
  - 应用内自更新链路与 Ed25519 验签：[`docs/agents/in-app-update.md`](docs/agents/in-app-update.md)
  - Linux 容器与云端环境（Antigravity Cloud / Cursor Cloud）：[`docs/agents/cursor-cloud.md`](docs/agents/cursor-cloud.md)
  - 本地隔离 macOS CI VM 运维：[`docs/agents/local-macos-runner.md`](docs/agents/local-macos-runner.md)

## 技能路由（`pstack` & Matt Pocock 工程套件）

- **工程执行默认路由 `poteto-mode`**：涉及多文件修改、跨函数/模块签名调整、架构设计、根因未明的 Bug 或性能问题时，按当前宿主读取并执行 `poteto-mode`（本机 Antigravity / Codex 直接 `read_file` 读取 `~/.agents/skills/poteto-mode/SKILL.md` 与 `~/.agents/skill-catalog/pstack/docs/harness/antigravity.md`）；单文件明确小改或纯问答直接执行并在真实产物上验证。意图已明确时直入对应专项技能（`~/.agents/skill-catalog/pstack/skills/` 下的 `how`、`why`、`architect`、`arena`、`pstack-swarm`、`interrogate`、`pstack-tdd`、`no-comments`、`unslop`、`technical-writing`、`reflect`）。
- **本机 Swarm 与 PR 盯梢路由**：多代理并行协作遵循 `~/.agents/skills/poteto-swarm/SKILL.md`（并发写者用 `workspace: "share"` + Carbon/Argon/Hydrogen 三层模型路由，`Monitor` 固定 `gemini-4-hydrogen-xhigh` 且仅多波次并发时启用）；PR/CI 等待优先跑后台阻塞脚本 `bash scripts/pr-ready.sh --wait --max-codex-rounds 2 <pr>`，不用 LLM `schedule` 短周期轮询。Antigravity Cloud Linux 容器仍使用 `Workspace: "inherit"`、`Model: "inherit"`（见 [`docs/agents/cursor-cloud.md`](docs/agents/cursor-cloud.md)）。
- **议题分拣、规划拆票与双轴审查**：使用已安装的 Matt Pocock 工程技能（`triage`、`wayfinder`、`grill-with-docs`、`to-spec`、`to-tickets`、`implement`、`diagnosing-bugs`、`code-review`、`retro`；Antigravity Cloud 镜像别名带 `mp-` 前缀），与 [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) 联动。

## 并发与 Runner 安全红线

- **严禁**把维护者这台含签名私钥的 Mac 宿主机注册为自托管 runner（CI `MACOS_CI_RUNNER` 仅允许指向隔离 VM）。
- `git worktree list` 中其他会话的工作树仅审计只读、严禁改文件；主代理核对 diff 与实际 `path:symbol` 后再交付。
