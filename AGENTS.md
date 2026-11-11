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

Run `bash scripts/check.sh` for secret scan, mechanical lints, and `swift test`, snapshots included (pre-commit runs the same gate; `--lint-only` runs fast lints only; `--skip-snapshots` is only for a non-reference Mac). Rust tests run in CI (`windows-rust-test`: `cargo test --locked --manifest-path src-tauri/Cargo.toml` in `windows/`). On Windows without Swift, run `bash scripts/check.sh --lint-only` or `bash scripts/remote-swift-test.sh --host <user>@<mac>`.

- **Snapshot changes** (`Sources/MenuBarMijiaApp/`): run `bash scripts/record_snapshots.sh` (`--dry-run` previews), visually inspect every changed/new PNG, and commit them with the code.
- **Targeted runs & workflows**: single Windows test `node windows/scripts/test-file.mjs tests/<file>.test.ts`; repeat Swift test `bash scripts/repeat_test.sh <filter> [count]`; red-check `bash scripts/red-check.sh`; app packaging `bash scripts/install_local_app.sh` (or `build_app.sh`); icons `swift scripts/generate_app_icon.swift`; workflow edits `actionlint .github/workflows/*.yml`.
- **Gate & snapshot internals**: read `docs/agents/gates.md` when debugging snapshot diffs, skipped gate steps, pre-commit hooks, `hdiutil attach` contention, or modifying `scripts/`.

### Tooling

本仓库的 Swift 与 Rust 没有语言服务器。引用与定义检索用 `grep`。

CI 失败先看 `bash scripts/ci_errors.sh <run-id>`。它打印失败日志和 check-run annotation，并把 `steps` 为空的取消任务分成「被更新的运行顶掉」和「runner 没分配」。看一个 PR 能不能合，用 `bash scripts/pr-ready.sh <pr>`（加 `--wait` 可静默轮询直到检查与当前 head 的 Codex 审查全部就绪，或遇到失败/审查问题立即提前返回）。盘点未合并分支和工作树用 `bash scripts/pending-work.sh`。挑票用 `bash scripts/issue-frontier.sh`（一次列出所有 `ready-for-agent` 票能不能做：blocker、assignee、`claimed:*` 标签、关联的 open PR 和分支；`--doable` 只输出可做编号）。

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

