# Gate & Snapshot Internals

Reference for modifying `scripts/check.sh`, `scripts/record_snapshots.sh`, `scripts/gate_report.sh`, `scripts/hooks/pre-commit`, or `.github/workflows/`, and for diagnosing snapshot or gate failures.

## Snapshot Baselines (`scripts/record_snapshots.sh`)

- Baselines are rendered on the maintainer's reference Mac. Hosted GitHub runners render text and materials differently, so CI skips pixel comparison and enforces `snapshot-guard.yml` instead; local `check.sh` runs the pixel comparison.
- When a `Sources/MenuBarMijiaApp/` change intentionally alters visuals, run `bash scripts/record_snapshots.sh`, visually inspect every changed/new PNG, and commit the PNGs in the same commit as the code.
- `--dry-run` lists affected snapshots without overwriting baselines. The script uses `git diff` to list unstaged modified PNGs and untracked new PNGs, and prints dimension changes (`png-size-diff`).
- A recording run fails only if the `swift test` process did not finish; its full log stays in `$TMPDIR`. On a pixel mismatch, the assertion reports `SnapshotAssertion.firstDifferingPixel`.
- `SnapshotFixture` marks onboarding completed (`has_completed_onboarding = true`) by default; set `hasCompletedOnboarding = false` in tests that snapshot onboarding.
- When snapshots fail without a UI change, re-run the same suite on the last passing commit first. Consistent failures across commits indicate an OS/renderer change; intermittent diffs (scroller style, leaked parallel state) belong in the test harness, not a baseline re-record.

## `scripts/check.sh` Step Accounting & Skips

- `check.sh` runs all steps even after an earlier step fails, then prints a one-line verdict via `scripts/gate_report.sh summary`.
- Skipped steps print `⚠️ 部分通过：跳过 <名称>` and exit `0`; any failed step prints `❌ 门禁未通过` and exits with that step's non-zero status.
- When local `windows/node_modules` is absent, `check.sh` reuses a lockfile-matching sibling git worktree's `windows/node_modules` to run the `windows/tests/*.test.ts` suite (`MMB_DISABLE_SHARED_NODE_MODULES=1` forces a skip); full `tsc --noEmit && vite build` runs when local `windows/node_modules` is present, and always runs in CI.
- `scripts/go2rtc-ptz/verify.sh` runs whenever `go version` succeeds within 5 s; a broken or missing `go` skips, while a patch/test failure fails the gate.
- `--lint-only` returns before the test suites while still running secret scans, design-token/harness lints, capability matrix checks, `scripts/go2rtc-ptz/check_model_tables.py`, and script self-tests.
- Pre-commit hook path: `git rev-parse --git-path hooks/pre-commit`. `scripts/check.sh` installs a wrapper in the shared git hooks directory that delegates to the active worktree's `scripts/hooks/pre-commit`.

## Lints, Workflows & Disk Images

- `scripts/check_timer_render.py` blocks unannotated `render()` calls inside timer callbacks (`CODING_STANDARDS.md` §16).
- `scripts/check_swift_harness_lints.py` blocks unannotated fixed-count `Task.yield` loops, `#expect(...allSatisfy(\.)`, and discarded `Task`-returning calls inside `withAnimation` (`CODING_STANDARDS.md` §9).
- Repeat a flaky Swift test with `bash scripts/repeat_test.sh <filter> [count]`; prove a regression test goes red on an older commit with `bash scripts/red-check.sh`.
- Run a single Windows test file from any worktree with `node windows/scripts/test-file.mjs tests/<file>.test.ts` (or `npm run test:file -- tests/<file>.test.ts` inside `windows/`).
- Retry once if `hdiutil attach` reports `Resource temporarily unavailable`; tests that attach disk images serialize on `UpdateCheckerTests.HdiutilGate` (`CODING_STANDARDS.md` §9).
- After editing `.github/workflows/*.yml`, run `actionlint .github/workflows/*.yml` (`check.sh` does not run `actionlint`).
