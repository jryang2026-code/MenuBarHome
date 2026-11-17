#!/usr/bin/env bash
# Self-tests for the snapshot reference branch guard, commit message, and suite verdict.
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0

expect_eq() {
    local label="$1" want="$2" got="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$label" "$want" "$got" >&2
        failures=$((failures + 1))
    else
        printf 'PASS %s\n' "$label"
    fi
}

expect_status() {
    local label="$1" want="$2"
    shift 2
    set +e
    "$@" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err
    local got=$?
    set -e
    if [ "$got" != "$want" ]; then
        printf 'FAIL %s (status %s, want %s)\n' "$label" "$got" "$want" >&2
        cat /tmp/snapshot-ci-test.err >&2 || true
        failures=$((failures + 1))
    else
        printf 'PASS %s\n' "$label"
    fi
}

got="$(bash scripts/ci_snapshot_branch.sh normalize 'refs/heads/feature/foo')"
expect_eq "strip refs/heads" "feature/foo" "$got"
got="$(bash scripts/ci_snapshot_branch.sh normalize 'cursor/github-hosted-snapshots-2d14')"
expect_eq "keep a normal branch" "cursor/github-hosted-snapshots-2d14" "$got"

expect_status "reject traversal" 2 bash scripts/ci_snapshot_branch.sh normalize 'feature/../../main'
expect_status "reject blank" 2 bash scripts/ci_snapshot_branch.sh normalize ''
expect_status "reject tag" 2 bash scripts/ci_snapshot_branch.sh normalize 'refs/tags/v1.0.0'
expect_status "reject space" 2 bash scripts/ci_snapshot_branch.sh normalize 'my branch'
expect_status "reject HEAD" 2 bash scripts/ci_snapshot_branch.sh normalize 'HEAD'
expect_status "reject shell metacharacter" 2 bash scripts/ci_snapshot_branch.sh normalize 'branch;rm'
expect_status "locale flag needs a version" 2 bash scripts/ci_snapshot_locale.sh --require-xcode

msg="$(printf '%s\n' 'Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/a.png' | bash scripts/ci_commit_snapshot_baselines.sh message)"
first="$(printf '%s\n' "$msg" | head -n 1)"
expect_eq "commit subject" "test(snapshots): re-record UI baselines on macos-26-intel" "$first"
if printf '%s\n' "$msg" | grep -Fxq -- '- Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/a.png'; then
    printf 'PASS commit message lists the png\n'
else
    printf 'FAIL commit message lists the png\n%s\n' "$msg" >&2
    failures=$((failures + 1))
fi

set +e
printf '%s\n' 'README.md' | bash scripts/ci_commit_snapshot_baselines.sh message >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err
got=$?
set -e
if [ "$got" -eq 0 ]; then
    printf 'FAIL reject non-png (status 0)\n' >&2
    failures=$((failures + 1))
else
    printf 'PASS reject non-png\n'
fi

set +e
out="$(bash scripts/gate_report.sh summary Swift=0 Snapshots=advisory 2>&1)"
got=$?
set -e
if [ "$got" -ne 0 ] || ! printf '%s\n' "$out" | grep -q '本机快照仅供参考'; then
    printf 'FAIL advisory summary\n%s\n' "$out" >&2
    failures=$((failures + 1))
else
    printf 'PASS advisory summary\n'
fi

set +e
bash scripts/gate_report.sh summary Swift=2 Snapshots=advisory >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err
got=$?
set -e
if [ "$got" -eq 0 ]; then
    printf 'FAIL advisory does not hide a failing gate\n' >&2
    failures=$((failures + 1))
else
    printf 'PASS advisory does not hide a failing gate\n'
fi

log="$(mktemp)"
cat >"$log" <<'EOF'
◇ Test run started.
✔ Test run with 2 tests in 1 suite passed after 1.0 seconds.
EOF
expect_eq "suite passed" "passed" "$(bash scripts/gate_report.sh suite-state "$log")"

cat >"$log" <<'EOF'
◇ Test run started.
✘ Test panelSnapshot() recorded an issue at SnapshotTests.swift:1
✘ Test run with 1 test in 1 suite failed after 1.0 seconds.
EOF
expect_eq "suite failed" "failed" "$(bash scripts/gate_report.sh suite-state "$log")"

cat >"$log" <<'EOF'
◇ Test run started.
EOF
expect_eq "suite incomplete" "incomplete" "$(bash scripts/gate_report.sh suite-state "$log")"

cat >"$log" <<'EOF'
Fatal error: boom
◇ Test run started.
✔ Test run with 1 test in 1 suite passed after 1.0 seconds.
EOF
expect_eq "suite crash" "incomplete" "$(bash scripts/gate_report.sh suite-state "$log")"
rm -f "$log"

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 snapshot CI 脚本自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ snapshot CI 脚本自测通过\n'
