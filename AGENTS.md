## Agent skills

### Issue tracker

GitHub (`https://github.com/jryang2026-code/MenuBarHome`, git remote `origin`) via the `gh` CLI, logged in as `jryang2026-code`. The old account `jryang1997` is suspended. GitLab (remote `gitlab`) and the NAS Forgejo (remote `nas`) are backups; file nothing there. Migrated issues cite older GitHub numbers. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (`GLOSSARY.md` + `docs/adr/` at the repo root). See `docs/agents/domain.md`.

### Coding standards

Read `CODING_STANDARDS.md` when reviewing diffs (`/code-review`) or modifying synthesis, optimistic locking, hotkeys, or grid layout.

### Build & verification

Run `bash scripts/check.sh` for secret scan, mechanical lints, and `swift test`, snapshots included. It does not run Rust tests. The pre-commit hook runs the same gate. GitHub Actions runs it on hosted machines without the snapshot comparison. `--skip-snapshots` is only for a Mac other than the maintainer's, whose renderer is not the reference. Run `bash scripts/install_local_app.sh` to build, verify, and install into the bundle the user launches (it keeps the previous version for rollback); `bash scripts/build_app.sh` only packages the bundle inside the worktree. Run `swift scripts/generate_app_icon.swift` when modifying `Resources/AppIcon/AppIcon-*.svg` to regenerate macOS `.icns`, `Assets.car`, README logos, and Windows Tauri icons.

快照基线以维护者这台 Mac 的渲染为准。GitHub 托管机渲染不同，所以 CI 跳过快照比对，只由本机门禁比对。改到 `Sources/MenuBarMijiaApp/` 而界面有变化时，`bash scripts/record_snapshots.sh` 重录。审阅变化的 PNG 后，与改动它们的代码放进同一个提交。`--dry-run` 只列出会变的图，不写基线。脚本用 `git diff` 列出未暂存的变化图和未跟踪的新图，并打印尺寸变化。录制进程没跑完才算失败，日志留在临时文件。快照对不上时，失败信息带第一个不同的像素（`SnapshotAssertion.firstDifferingPixel`）。`SnapshotFixture` 默认把引导标成已完成（`has_completed_onboarding` 为 true）。要录引导界面时再改成 false。改动没碰界面、快照却突然失败时，先在最近一次通过的提交上重跑同一组快照。那边也失败，说明是渲染环境变了。差异时有时无（如系统滚动条样式、并行测试残留的状态）就修测试工具，不要重录基线。系统升级后差异稳定复现，逐张审阅后再重录。

`check.sh` 一步失败也继续跑完其余步，最后用 `scripts/gate_report.sh summary` 打一行。有跳过的步时打印 `⚠️ 部分通过：跳过 <名称>`，退出码是 0。有失败的步时打印 `❌ 门禁未通过`，并带上那一步的退出码。没有 `windows/node_modules` 或 `raycast/node_modules` 就跳过那一步，不会自动 `npm ci`。`go version` 能成功就跑 `scripts/go2rtc-ptz/verify.sh`（在干净的上游检出上重新打补丁并跑测试）。这一步失败则门禁失败。`go version` 失败，或 go 不是可执行文件，才跳过。`--lint-only` 在这些测试步之前返回，但仍跑 `scripts/go2rtc-ptz/check_model_tables.py`（型号表，以及 README 里的补丁 SHA-256）。Rust 测试在 Windows CI 的 `windows-rust-test`。工作目录是 `windows`，命令是 `cargo test --locked --manifest-path src-tauri/Cargo.toml`。

`scripts/check_timer_render.py` 拦住定时器回调里直接 `render()`。`scripts/check_swift_harness_lints.py` 拦住固定次数的 `Task.yield` 循环、`#expect` 里的 `allSatisfy(\.`，以及 `withAnimation` 里裸调返回 `Task` 的函数。判断标准在 `CODING_STANDARDS.md`。重复跑一个 Swift 测试用 `scripts/repeat_test.sh <filter> [count]`。把当前文件盖到旧提交上、确认命令会失败，用 `scripts/red-check.sh`。Windows 只跑一个测试文件时，在 `windows/` 执行 `npm run test:file -- <测试文件>`。

提交钩子的路径用 `git rev-parse --git-path hooks/pre-commit` 查。仓库里的门禁脚本是 `scripts/hooks/pre-commit`。`scripts/check.sh` 把共享 git 目录的 `hooks/pre-commit` 写成包装，转去跑当前工作区的那份脚本。

`hdiutil attach` 报 `Resource temporarily unavailable` 时先重试这一次。应用内挂载已经按退避重试（`UpdateSystemDriver.retryingAttach`）。测试里重复 attach 的串行要求见 `CODING_STANDARDS.md`。

改 `.github/workflows/` 下的工作流后，跑 `actionlint .github/workflows/*.yml`。`check.sh` 不跑这条。

Windows 上没有 Swift 工具链：本机跑 `bash scripts/check.sh --lint-only`，Swift 测试交给 CI 或局域网 Mac（`bash scripts/remote-swift-test.sh --host <user>@<mac>`，一次配置见脚本头）。

### Tooling

本仓库的 Swift 与 Rust 没有语言服务器。引用与定义检索用 `grep`。

CI 失败先看 `bash scripts/ci_errors.sh <run-id>`。它打印失败日志和 check-run annotation，并把 `steps` 为空的取消任务分成「被更新的运行顶掉」和「runner 没分配」。看一个 PR 能不能合，用 `bash scripts/pr-ready.sh <pr>`。它一屏给出 head、合并状态、未通过或未完成的检查，以及当前 head 的 Codex 审查。盘点未合并分支和工作树用 `bash scripts/pending-work.sh`。挑票用 `bash scripts/issue-frontier.sh`（一次列出所有 `ready-for-agent` 票能不能做：blocker、assignee、`claimed:*` 标签、关联的 open PR 和分支；`--doable` 只输出可做编号）。

### Commit & PR policy

本约定仅适用于此项目。在用户已授权提交的范围内，按改动风险选择直接 push 或 PR，不要求每次代码修改都开 PR。

- 文案、文档、图标、样式微调，以及范围明确的局部交互修复，完成相应检查后可直接 push 到 `main`。交互修复应有针对性验证和用户实机确认；按影响范围判断风险，不按代码行数判断。
- 登录、凭据与钥匙串、安全权限、设备控制、撤销、定时任务、数据迁移、自动更新、签名、打包发布、跨平台逻辑，以及牵涉多个模块的改动，走 PR，检查通过后再合并。
- 检查失败原因尚未确认时，走 PR 排查，解决后再合并。已复现并确认与本轮无关的既有失败，需记录证据及例外原因；跳过检查不是默认流程。
- 一个完整问题对应一次提交或一个 PR；同一问题的后续调整继续使用原 PR。
- 多个代理并行时按顺序合并：上一个合并进 `main` 的流水线变绿后，再合下一个。`main` 的每个提交都有自己的流水线，但同时合并的提交结果交错，`main` 变红后难以判断是哪次合并引入的。
- 直接 push 后，有 runner 时确认云端检查的最终结果；交付时区分“已推送”与“检查已通过”。直接 push 不等于发布新版本。
- PR 用 `gh pr create` 开，`gh pr checks <n>` 看检查。`.github/workflows/ci.yml` 全部跑在 GitHub 托管机上：`ubuntu-latest`、`macos-26`、`windows-latest`。不要把这台 Mac 注册成自托管 runner，公开仓库的外部 PR 可能在上面执行代码，而签名私钥在这台机器上。首次查询为空时按退避重试。
- 多行提交说明写进文件，用 `git commit -F` 提交。
- 已经开了 PR 的分支要跟上 `main` 时，把 `main` merge 进来。不要 rebase，以免强推。
- 提交前看 `git status`。工作区里只能有这次要提交的改动。
- 更新日志的新条目写进尚未发布的版本段。`git tag` 里已经有的版本，对应的 `CHANGELOG.md` 段落不再追加。

### Worktrees

- `git worktree list` 里登记给其他会话的分支（如 Codex 的 `wt/dev` 工作树）归该代理所有：审计只读，不改它的文件。
- 接管前先确认对方已安静：无新提交且 `git status` 干净。对方仍在迭代时，在自己的分支副本上完成改动再推回。
- 对方提交在你审计途中落地，就按最新提交重读后再下结论，不基于旧快照。

## Cursor Cloud specific instructions

Linux 云代理的构建、检查与端口约定见 `docs/agents/cursor-cloud.md`（在 Cursor Cloud 或 Linux 容器里工作时读）。

## Cursor skills

Before coding, read `.cursor/skills/poteto-mode/SKILL.md` and follow its rules. Then use any fitting `mp-` or `principle-` skill. Sources and refresh steps are in `.cursor/skills/README.md`.

