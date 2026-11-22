# Issue tracker: GitHub

Issues, specs and pull requests live at `https://github.com/jryang2026-code/MenuBarHome`. Every operation goes through the `gh` CLI, logged in as `jryang2026-code`. GitLab (`git remote gitlab`) and the NAS Forgejo (`git remote nas`, LAN only) are backups; file nothing there. The old account `jryang1997` is suspended.

GitHub numbers issues and pull requests from one sequence.

## Triage labels

Canonical GitHub issue triage labels in this repository:
- `needs-triage` — Maintainer needs to evaluate this issue
- `needs-info` — Waiting on reporter for more information
- `ready-for-agent` — Fully specified, ready for an autonomous agent
- `ready-for-human` — Requires human implementation
- `wontfix` — Will not be actioned

## Repo helper scripts

CI 失败先跑 `bash scripts/ci-failures.sh <run-id|pr>` 看摘要：失败 job、Swift Testing / node 失败用例、编译错误首行、进程崩溃、快照不匹配，用例名命中 open 票标 `[已知间歇 #N]`，只有文件名命中标 `[同文件 issue #N，需核对]`。要看完整失败日志用 `bash scripts/ci_errors.sh <run-id>`。它打印失败日志和 check-run annotation，并把 `steps` 为空的取消任务分成「被更新的运行顶掉」和「runner 没分配」。看一个 PR 能不能合，用 `bash scripts/pr-ready.sh <pr>`（加 `--wait` 会在检查与 Codex 就绪时返回 0、发现阻断时返回 1；注意 Codex Bot 只在 PR 打开时自动评审，后续新推送若未触发 `@codex review` 或 CI 绿后超出 `--codex-timeout`（默认 480s）无回应，会立即返回退出码 3 唤醒处理，避免空转）。

## Migrated issue numbers

Issues #1 to #31 came from GitLab with the same numbers. Their footers record the original date. Titles that start with `[GH#<old>]` came from the suspended GitHub account, and their bodies still cite **old GitHub numbers** (`#304`, `GH#304`).

Translate an old number through the title prefix: `#5` is `[GH#304]`. An old number with no `[GH#…]` issue was closed before the move. Its record is in the NAS backup at `/volume1/docker/forgejo/backups/issues-backup-20261106.md`.

Merge requests `!1` to `!54` stay on GitLab as history. Commit messages that say `See merge request ...!n` point there.

Some migrated bodies hold a broken `## Blocked by` section with `#$(cat n9)` placeholders. Use the `> 原 GitHub Issue … 前置：Blocked by GH#…` banner on the first line instead; it is the reliable blocker list.

## Pull requests & skill hooks

- **Checks**: `gh pr checks <n>`. `.github/workflows/ci.yml` runs on GitHub-hosted Linux, macOS and Windows machines. UI snapshot pixels are compared by `macos-test` on `macos-26-intel`. Failed job logs: `bash scripts/ci_errors.sh <run-id>`.
- **Push discipline**: a subagent runs `git merge origin/main` only for a conflict or a check that demands it. Batch one round of fixes into one push — never "merge main, push, fix, push again": every push cancels the running macOS jobs (1213 macOS minutes lost on 2026-11-19). Triage a red run with `bash scripts/ci-failures.sh <run-id|pr>` first, before reading logs.
- **Merge**: `bash scripts/merge-pr.sh <n> <head-sha>` (squash + watch the main CI run; with a plain `gh pr merge <n> --squash --delete-branch` you must watch main yourself).
- **PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `triage` reads this flag.)_
- **When a skill says "publish to the issue tracker"**: create a GitHub issue with `gh issue create --label ready-for-agent`.
- **When a skill says "fetch the relevant ticket"**: run `gh issue view <n> --comments`.

## Wayfinding operations

`wayfinder` uses these operations. The **map** is a single issue, and its **child** issues are the tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: write a `Blocked by: #<n>, #<n>` line (or a `## Blocked by` section) in the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: `gh issue list --label ready-for-agent --state open` lists open `ready-for-agent` issues. Skip an issue that has open blockers in its body, an assignee, a `claimed:*` label, or an open PR that mentions it.
- **Claim**: `gh issue edit <n> --add-assignee @me`, the session's first write.
- **Resolve**: comment with the answer, close the issue, then append a context pointer (gist + link) to the map's Decisions-so-far.
