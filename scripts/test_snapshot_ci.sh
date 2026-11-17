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
expect_status "reject newline injection" 2 bash scripts/ci_snapshot_branch.sh normalize $'$(id)\nmain'
expect_status "reject embedded newline" 2 bash scripts/ci_snapshot_branch.sh normalize $'feature\nmain'
expect_status "reject main" 2 bash scripts/ci_snapshot_branch.sh normalize main
expect_status "reject refs/heads/main" 2 bash scripts/ci_snapshot_branch.sh normalize refs/heads/main
expect_status "reject configured default branch" 2 env DEFAULT_BRANCH=develop bash scripts/ci_snapshot_branch.sh normalize develop
expect_status "locale flag needs a version" 2 bash scripts/ci_snapshot_locale.sh --require-xcode

test_unpushed_snapshot_commit() {
    local tmp bare out
    tmp="$(mktemp -d)"
    bare="$(mktemp -d)"
    out="$(mktemp)"
    git init -q -b feature "$tmp"
    git init -q --bare -b feature "$bare"
    git -C "$tmp" config user.email test@example.com
    git -C "$tmp" config user.name test
    git -C "$tmp" commit -q --allow-empty -m init
    git -C "$tmp" remote add origin "$bare"
    git -C "$tmp" push -q origin feature
    if ! (
        cd "$tmp"
        SNAPSHOT_BRANCH=feature GITHUB_OUTPUT="$out" \
            bash "$OLDPWD/scripts/ci_commit_snapshot_baselines.sh" commit
    ); then
        printf 'FAIL in-sync empty record should succeed\n' >&2
        failures=$((failures + 1))
    elif ! grep -qx 'pushed=false' "$out"; then
        printf 'FAIL in-sync empty record should set pushed=false\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS in-sync empty record\n'
    fi
    git -C "$tmp" commit -q --allow-empty -m 'local only'
    : >"$out"
    if (
        cd "$tmp"
        SNAPSHOT_BRANCH=feature GITHUB_OUTPUT="$out" \
            bash "$OLDPWD/scripts/ci_commit_snapshot_baselines.sh" commit
    ); then
        printf 'FAIL unpushed HEAD should not succeed\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS unpushed HEAD is rejected\n'
    fi
    rm -rf "$tmp" "$bare" "$out"
}
test_unpushed_snapshot_commit

test_commit_ignores_target_hook() {
    local tmp bare out rel
    tmp="$(mktemp -d)"
    bare="$(mktemp -d)"
    out="$(mktemp)"
    rel="Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"
    git init -q -b feature "$tmp"
    git init -q --bare -b feature "$bare"
    git -C "$tmp" config user.email test@example.com
    git -C "$tmp" config user.name test
    mkdir -p "$tmp/$rel"
    printf 'before\n' >"$tmp/$rel/panel.png"
    git -C "$tmp" add "$rel/panel.png"
    git -C "$tmp" commit -q -m init
    git -C "$tmp" remote add origin "$bare"
    git -C "$tmp" push -q origin feature
    printf 'after\n' >"$tmp/$rel/panel.png"
    mkdir -p "$tmp/.git/hooks"
    cat >"$tmp/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo pwned >> README.md
git add README.md
EOF
    chmod +x "$tmp/.git/hooks/pre-commit"
    if ! (
        cd "$tmp"
        SNAPSHOT_BRANCH=feature GITHUB_OUTPUT="$out" \
            bash "$OLDPWD/scripts/ci_commit_snapshot_baselines.sh" commit
    ); then
        printf 'FAIL commit should ignore a target pre-commit hook\n' >&2
        failures=$((failures + 1))
    elif git -C "$tmp" show --name-only --format= HEAD | grep -qx 'README.md'; then
        printf 'FAIL target pre-commit hook added README.md\n' >&2
        failures=$((failures + 1))
    elif [ -f "$tmp/README.md" ]; then
        printf 'FAIL target pre-commit hook wrote README.md\n' >&2
        failures=$((failures + 1))
    elif ! grep -qx 'pushed=true' "$out"; then
        printf 'FAIL hook-ignored commit should set pushed=true\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS commit ignores a target pre-commit hook\n'
    fi
    rm -rf "$tmp" "$bare" "$out"
}
test_commit_ignores_target_hook

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

tiny_png() {
    python3 - "$1" << 'PY'
import struct, sys, zlib
path = sys.argv[1]
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
raw = b"\x00\x00\x00\x00"
blob = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(path, "wb").write(blob)
PY
}

expect_validate_fail() {
    local label="$1"
    shift
    if bash scripts/ci_snapshot_artifact.sh validate "$@" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL %s (validate succeeded)\n' "$label" >&2
        failures=$((failures + 1))
    else
        printf 'PASS %s\n' "$label"
    fi
}

artifact_root="$(mktemp -d)"
good="$artifact_root/good"
mkdir -p "$good"
tiny_png "$good/panel.png"
if bash scripts/ci_snapshot_artifact.sh validate "$good" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
    printf 'PASS plain png artifact\n'
else
    printf 'FAIL plain png artifact\n' >&2
    cat /tmp/snapshot-ci-test.err >&2
    failures=$((failures + 1))
fi

link_dir="$artifact_root/link"
mkdir -p "$link_dir"
tiny_png "$artifact_root/outside.png"
ln -s "$artifact_root/outside.png" "$link_dir/panel.png"
expect_validate_fail "reject symlink" "$link_dir"

other_dir="$artifact_root/other"
mkdir -p "$other_dir"
printf 'not a png\n' >"$other_dir/readme.txt"
tiny_png "$other_dir/panel.png"
expect_validate_fail "reject non-png" "$other_dir"

nested_dir="$artifact_root/nested"
mkdir -p "$nested_dir/sub"
tiny_png "$nested_dir/sub/panel.png"
expect_validate_fail "reject nested path" "$nested_dir"
rm -rf "$artifact_root"

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 snapshot CI 脚本自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ snapshot CI 脚本自测通过\n'
