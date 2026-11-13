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

CI 失败先看 `bash scripts/ci_errors.sh <run-id>`。它打印失败日志和 check-run annotation，并把 `steps` 为空的取消任务分成「被更新的运行顶掉」和「runner 没分配」。看一个 PR 能不能合，用 `bash scripts/pr-ready.sh <pr>`（加 `--wait` 可静默轮询直到检查与当前 head 的 Codex 审查全部就绪，或遇到失败/审查问题立即提前返回）。盘点未合并分支和工作树用 `bash scripts/pending-work.sh`。挑票用 `bash scripts/issue-frontier.sh`（一次列出所有 `ready-for-agent` 票能不能做：blocker、assignee、`claimed:*` 标签、关联的 open PR 和分支；`--doable` 只输出可做编号）。

## Migrated issue numbers

Issues #1 to #31 came from GitLab with the same numbers. Their footers record the original date. Titles that start with `[GH#<old>]` came from the suspended GitHub account, and their bodies still cite **old GitHub numbers** (`#304`, `GH#304`).

Translate an old number through the title prefix: `#5` is `[GH#304]`. An old number with no `[GH#…]` issue was closed before the move. Its record is in the NAS backup at `/volume1/docker/forgejo/backups/issues-backup-20261106.md`.

Merge requests `!1` to `!54` stay on GitLab as history. Commit messages that say `See merge request ...!n` point there.

Some migrated bodies hold a broken `## Blocked by` section with `#$(cat n9)` placeholders. Use the `> 原 GitHub Issue … 前置：Blocked by GH#…` banner on the first line instead; it is the reliable blocker list.

## Pull requests & skill hooks

- **Checks**: `gh pr checks <n>`. `.github/workflows/ci.yml` runs on GitHub-hosted Linux, macOS and Windows machines, without the snapshot comparison. Failed job logs: `bash scripts/ci_errors.sh <run-id>`.
- **Merge**: `gh pr merge <n> --squash --delete-branch`.
- **PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/mp-triage` reads this flag.)_
- **When a skill says "publish to the issue tracker"**: create a GitHub issue with `gh issue create --label ready-for-agent`.
- **When a skill says "fetch the relevant ticket"**: run `gh issue view <n> --comments`.

## Wayfinding operations

`/mp-wayfinder` uses these operations. The **map** is a single issue, and its **child** issues are the tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: write a `Blocked by: #<n>, #<n>` line (or a `## Blocked by` section) in the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: `bash scripts/issue-frontier.sh` checks every open `ready-for-agent` issue in one call. It skips an issue that has open blockers in its body (old numbers are translated for migrated issues), an assignee, a `claimed:*` label, an open PR that mentions it, or an `issue-<n>` branch.
- **Claim**: `gh issue edit <n> --add-assignee @me`, the session's first write.
- **Resolve**: comment with the answer, close the issue, then append a context pointer (gist + link) to the map's Decisions-so-far.
