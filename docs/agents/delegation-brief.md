# Delegation brief template

Paste these lines into every coding task handed to another model, below the task-specific goal. They fix the failures seen when workers ran unattended.

- Start from a fresh `origin/main` in your own worktree; follow main later with `git merge origin/main`, never rebase or force-push.
- Quote specs instead of paraphrasing them. Upgrade behavior comes from the legacy defaults table in `docs/plans/optional-features/architecture.md` (section B, 升级路径); if the brief and the plan disagree, the plan wins and you say so in the PR.
- Run tests in the foreground and wait for them to finish before ending your turn. Do not end a turn while a build or test runs in the background.
- Commit and push after each finished group of fixes, so nothing is left uncommitted if the session stops.
- Before opening or updating a PR, run `bash scripts/check.sh --changed`; for macOS UI changes, run the full `bash scripts/check.sh`.
- Wait for checks with `bash scripts/pr-ready.sh --wait --max-codex-rounds 2 <pr>` (default timeout 1800 s). If it prints `base: behind main ... overlapping files`, run `git merge origin/main`, push, and wait again before calling the PR ready; after two Codex rounds, fix only reachable security, data-loss or crash issues and file the rest as issues.
- Your last line is: PR <full URL>, head <SHA>, checks <state>.
