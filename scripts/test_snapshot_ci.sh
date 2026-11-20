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

physical_tmp() {
    # mktemp -d on the maintainer's Mac returns a path under /var, itself a
    # symlink to /private/var. The install guards reject symlinked ancestors,
    # so the tests must use the physical path.
    local d
    d="$(mktemp -d)"
    (cd "$d" && pwd -P)
}

test_install_happy_path() {
    local root artifact dest listing
    root="$(physical_tmp)"
    artifact="$root/artifact"
    dest="$root/dest"
    mkdir -p "$artifact" "$dest"
    tiny_png "$artifact/panel.png"
    tiny_png "$artifact/extra.png"
    printf 'old\n' >"$dest/panel.png"
    printf 'stale\n' >"$dest/stale.png"
    if ! bash scripts/ci_snapshot_artifact.sh install "$artifact" "$dest" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL install happy path\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        listing="$(ls "$dest")"
        expect_eq "install keeps only artifact pngs" "$(printf 'extra.png\npanel.png')" "$listing"
        if cmp -s "$artifact/panel.png" "$dest/panel.png"; then
            printf 'PASS install copies artifact pixels\n'
        else
            printf 'FAIL install copies artifact pixels\n' >&2
            failures=$((failures + 1))
        fi
    fi
    rm -rf "$root"
}
test_install_happy_path

test_install_rejects_destination_symlink() {
    local root artifact dest outside
    root="$(physical_tmp)"
    artifact="$root/artifact"
    dest="$root/dest"
    mkdir -p "$artifact" "$dest"
    tiny_png "$artifact/panel.png"
    outside="$root/outside.bin"
    printf 'sentinel\n' >"$outside"
    ln -s "$outside" "$dest/panel.png"
    if bash scripts/ci_snapshot_artifact.sh install "$artifact" "$dest" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL install should reject a destination png symlink\n' >&2
        failures=$((failures + 1))
    elif ! grep -qx 'sentinel' "$outside"; then
        printf 'FAIL install wrote through the destination symlink\n' >&2
        failures=$((failures + 1))
    elif [ ! -L "$dest/panel.png" ]; then
        printf 'FAIL install replaced the destination symlink itself\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS install rejects a destination png symlink\n'
    fi
    rm -rf "$root"
}
test_install_rejects_destination_symlink

test_install_rejects_ancestor_symlink() {
    local root artifact real linkpath
    root="$(physical_tmp)"
    artifact="$root/artifact"
    real="$root/real"
    mkdir -p "$artifact" "$real"
    tiny_png "$artifact/panel.png"
    ln -s real "$root/linkdir"
    linkpath="$root/linkdir/dest"
    if bash scripts/ci_snapshot_artifact.sh install "$artifact" "$linkpath" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL install should reject a symlinked ancestor\n' >&2
        failures=$((failures + 1))
    elif [ -e "$real/dest" ]; then
        printf 'FAIL install wrote through a symlinked ancestor\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS install rejects a symlinked ancestor\n'
    fi
    rm -rf "$root"
}
test_install_rejects_ancestor_symlink

test_branch_advance_rejected() {
    local tmp next bare out rel
    tmp="$(mktemp -d)"
    next="$(mktemp -d)"
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
    git clone -q "$bare" "$next"
    git -C "$next" config user.email test@example.com
    git -C "$next" config user.name test
    git -C "$next" commit -q --allow-empty -m advance
    git -C "$next" push -q origin feature
    recorded="$(git -C "$tmp" rev-parse HEAD)"
    advanced="$(git -C "$bare" rev-parse feature)"
    printf 'after\n' >"$tmp/$rel/panel.png"
    if (
        cd "$tmp"
        SNAPSHOT_BRANCH=feature GITHUB_OUTPUT="$out" \
            bash "$OLDPWD/scripts/ci_commit_snapshot_baselines.sh" commit
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL advanced branch should reject the commit\n' >&2
        failures=$((failures + 1))
    else
        if grep -q '已前进' /tmp/snapshot-ci-test.err; then
            printf 'PASS advanced branch reports the re-record hint\n'
        else
            printf 'FAIL advanced branch message missing\n' >&2
            cat /tmp/snapshot-ci-test.err >&2
            failures=$((failures + 1))
        fi
        if grep -qx 'pushed=false' "$out"; then
            printf 'PASS advanced branch writes pushed=false\n'
        else
            printf 'FAIL advanced branch should write pushed=false\n' >&2
            failures=$((failures + 1))
        fi
        if [ "$(git -C "$tmp" rev-parse HEAD)" != "$recorded" ]; then
            printf 'FAIL advanced branch should not commit on the old tip\n' >&2
            failures=$((failures + 1))
        else
            printf 'PASS recording worktree stays on the recorded commit\n'
        fi
        if [ "$(git -C "$bare" rev-parse feature)" != "$advanced" ]; then
            printf 'FAIL advanced branch should push nothing\n' >&2
            failures=$((failures + 1))
        else
            printf 'PASS remote tip is untouched\n'
        fi
    fi
    rm -rf "$tmp" "$next" "$bare" "$out"
}
test_branch_advance_rejected

test_adopt_snapshot_artifact() {
    local root fake_bin repo rel head_sha other_sha src_good src_bad_nonpng src_bad_link
    root="$(physical_tmp)"
    fake_bin="$root/bin"
    repo="$root/repo"
    rel="Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"
    mkdir -p "$fake_bin" "$repo/$rel"

    cat >"$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"
shift
case "$cmd" in
    repo)
        echo "jryang2026-code/MenuBarHome"
        ;;
    pr)
        printf '%s\n' "${FAKE_ADOPT_PR_JSON:?}"
        ;;
    api)
        printf '%s\n' "${FAKE_ADOPT_ARTIFACTS_JSON:?}"
        ;;
    run)
        sub="$1"
        shift
        case "$sub" in
            list)
                printf '%s\n' "${FAKE_ADOPT_RUNS_JSON:?}"
                ;;
            download)
                dir=""
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = "--dir" ]; then
                        dir="$2"
                        shift 2
                    else
                        shift
                    fi
                done
                cp -R "${FAKE_ADOPT_DOWNLOAD_SRC:?}/." "$dir/"
                ;;
            *)
                exit 3
                ;;
        esac
        ;;
    *)
        exit 3
        ;;
esac
GH
    chmod +x "$fake_bin/gh"

    git init -q -b feat/ui "$repo"
    git -C "$repo" config user.email "jryang2026-code@users.noreply.github.com"
    git -C "$repo" config user.name "jryang2026-code"
    tiny_png "$repo/$rel/panel.png"
    tiny_png "$repo/$rel/stale.png"
    git -C "$repo" add "$rel/panel.png" "$rel/stale.png"
    git -C "$repo" commit -q -m "feat: initial ui"
    head_sha="$(git -C "$repo" rev-parse HEAD)"
    other_sha="1111111111111111111111111111111111111111"
    [ "$head_sha" = "$other_sha" ] && other_sha="2222222222222222222222222222222222222222"

    src_good="$root/src-good"
    mkdir -p "$src_good"
    # Produce a distinct valid PNG by appending an innocuous tEXt chunk before IEND.
    python3 - "$src_good/panel.png" <<'PY'
import struct, sys, zlib
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
raw = b"\x00\xff\x00\x00\x00\xff\x00\x00\x00\x00\xff\x00\x00\xff"
blob = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(blob)
PY
    tiny_png "$src_good/added.png"

    src_bad_nonpng="$root/src-bad-nonpng"
    mkdir -p "$src_bad_nonpng"
    tiny_png "$src_bad_nonpng/panel.png"
    printf 'not a png\n' >"$src_bad_nonpng/evil.txt"

    src_bad_link="$root/src-bad-link"
    mkdir -p "$src_bad_link"
    ln -s "$src_good/panel.png" "$src_bad_link/panel.png"

    local script_path="$PWD/scripts/adopt_snapshot_artifact.sh"

    # 1. Usage validation
    expect_status "adopt rejects missing PR arg" 2 bash "$script_path"
    expect_status "adopt rejects non-numeric PR arg" 2 bash "$script_path" abc

    # 2. Reject local HEAD != PR head
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${other_sha}\",\"headRefName\":\"feat/ui\"}" \
        FAKE_ADOPT_RUNS_JSON="[]" \
        FAKE_ADOPT_ARTIFACTS_JSON='{"artifacts":[]}' \
        FAKE_ADOPT_DOWNLOAD_SRC="$src_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject mismatched local HEAD\n' >&2
        failures=$((failures + 1))
    elif ! grep -q '不一致' /tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt mismatched local HEAD missing hint\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects mismatched local HEAD\n'
    fi

    # 3. Reject CI run with mismatched headSha
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${head_sha}\",\"headRefName\":\"feat/ui\"}" \
        FAKE_ADOPT_RUNS_JSON="[{\"databaseId\":9000,\"workflowName\":\"CI\",\"headSha\":\"${other_sha}\",\"status\":\"completed\",\"conclusion\":\"failure\",\"createdAt\":\"2026-11-20T01:00:00Z\",\"event\":\"pull_request\"}]" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"name\":\"snapshot-baselines-${other_sha}\",\"expired\":false}]}" \
        FAKE_ADOPT_DOWNLOAD_SRC="$src_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject mismatched CI run headSha\n' >&2
        failures=$((failures + 1))
    elif ! grep -q 'headSha' /tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt mismatched run headSha missing hint\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects mismatched CI run headSha\n'
    fi

    # 4. Reject artifact whose name has a different SHA
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${head_sha}\",\"headRefName\":\"feat/ui\"}" \
        FAKE_ADOPT_RUNS_JSON="[{\"databaseId\":9001,\"workflowName\":\"CI\",\"headSha\":\"${head_sha}\",\"status\":\"completed\",\"conclusion\":\"failure\",\"createdAt\":\"2026-11-20T01:00:00Z\",\"event\":\"pull_request\"}]" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"name\":\"snapshot-baselines-${other_sha}\",\"expired\":false}]}" \
        FAKE_ADOPT_DOWNLOAD_SRC="$src_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject artifact name SHA mismatch\n' >&2
        failures=$((failures + 1))
    elif ! grep -q '快照产物名' /tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt artifact name mismatch missing hint\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects artifact name SHA mismatch\n'
    fi

    # 5. Reject invalid artifact (non-PNG) without touching repo
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${head_sha}\",\"headRefName\":\"feat/ui\"}" \
        FAKE_ADOPT_RUNS_JSON="[{\"databaseId\":9001,\"workflowName\":\"CI\",\"headSha\":\"${head_sha}\",\"status\":\"completed\",\"conclusion\":\"failure\",\"createdAt\":\"2026-11-20T01:00:00Z\",\"event\":\"pull_request\"}]" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"name\":\"snapshot-baselines-${head_sha}\",\"expired\":false}]}" \
        FAKE_ADOPT_DOWNLOAD_SRC="$src_bad_nonpng" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject non-png artifact\n' >&2
        failures=$((failures + 1))
    elif [ "$(git -C "$repo" rev-parse HEAD)" != "$head_sha" ] || [ -n "$(git -C "$repo" status --porcelain)" ]; then
        printf 'FAIL adopt left repo dirty after rejecting non-png artifact\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects invalid non-png artifact cleanly\n'
    fi

    # 6. Reject invalid artifact (symlink) without touching repo
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${head_sha}\",\"headRefName\":\"feat/ui\"}" \
        FAKE_ADOPT_RUNS_JSON="[{\"databaseId\":9001,\"workflowName\":\"CI\",\"headSha\":\"${head_sha}\",\"status\":\"completed\",\"conclusion\":\"failure\",\"createdAt\":\"2026-11-20T01:00:00Z\",\"event\":\"pull_request\"}]" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"name\":\"snapshot-baselines-${head_sha}\",\"expired\":false}]}" \
        FAKE_ADOPT_DOWNLOAD_SRC="$src_bad_link" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject symlink artifact\n' >&2
        failures=$((failures + 1))
    elif [ "$(git -C "$repo" rev-parse HEAD)" != "$head_sha" ] || [ -n "$(git -C "$repo" status --porcelain)" ]; then
        printf 'FAIL adopt left repo dirty after rejecting symlink artifact\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects symlink artifact cleanly\n'
    fi

    # 7. Happy path (including in-progress CI run with null conclusion): validates, installs, commits locally without pushing
    if ! (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${head_sha}\",\"headRefName\":\"feat/ui\"}" \
        FAKE_ADOPT_RUNS_JSON="[{\"databaseId\":9001,\"workflowName\":\"CI\",\"headSha\":\"${head_sha}\",\"status\":\"in_progress\",\"conclusion\":null,\"createdAt\":\"2026-11-20T01:00:00Z\",\"event\":\"pull_request\"}]" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"name\":\"snapshot-baselines-${head_sha}\",\"expired\":false}]}" \
        FAKE_ADOPT_DOWNLOAD_SRC="$src_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt happy path failed\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        local new_head subject committed_files
        new_head="$(git -C "$repo" rev-parse HEAD)"
        subject="$(git -C "$repo" log -1 --format=%s)"
        committed_files="$(git -C "$repo" show --name-only --format= HEAD | sed '/^$/d' | sort)"
        if [ "$new_head" = "$head_sha" ]; then
            printf 'FAIL adopt happy path did not create a commit\n' >&2
            failures=$((failures + 1))
        elif [ "$subject" != "test(snapshots): re-record UI baselines on macos-26-intel" ]; then
            printf 'FAIL adopt commit subject unexpected: %s\n' "$subject" >&2
            failures=$((failures + 1))
        elif [ ! -f "$repo/$rel/added.png" ] || [ -f "$repo/$rel/stale.png" ] || ! cmp -s "$src_good/panel.png" "$repo/$rel/panel.png"; then
            printf 'FAIL adopt did not install/prune baseline PNGs properly\n' >&2
            failures=$((failures + 1))
        elif [ -n "$(git -C "$repo" status --porcelain)" ]; then
            printf 'FAIL adopt left working tree dirty after commit\n' >&2
            failures=$((failures + 1))
        elif ! printf '%s\n' "$committed_files" | grep -Fxq "$rel/panel.png"; then
            printf 'FAIL adopt commit missing panel.png\n' >&2
            failures=$((failures + 1))
        else
            printf 'PASS adopt happy path validates, installs, and commits locally (including null conclusion)\n'
        fi
    fi

    rm -rf "$root"
}
test_adopt_snapshot_artifact

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 snapshot CI 脚本自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ snapshot CI 脚本自测通过\n'
