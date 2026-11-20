#!/usr/bin/env bash
# Self-tests for the snapshot reference branch guard, commit message, artifact validation,
# archive extraction, completeness guards, provenance checks, and suite verdict.
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
    python3 - "$1" "${2:-0}" << 'PY'
import struct, sys, zlib
path = sys.argv[1]
val = int(sys.argv[2]) & 0xFF
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
raw = bytes([0, val, 0, 0])
blob = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(path, "wb").write(blob)
PY
}

make_zip_from_dir() {
    python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
src_dir, zip_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for entry in sorted(os.scandir(src_dir), key=lambda e: e.name):
        if entry.is_symlink():
            zi = zipfile.ZipInfo(entry.name)
            zi.create_system = 3
            zi.external_attr = (0o120777 << 16)
            zf.writestr(zi, os.readlink(entry.path))
        elif entry.is_file():
            zf.write(entry.path, arcname=entry.name)
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

# Fake PNG with valid 8-byte signature but undecodable garbage body
fake_sig_dir="$artifact_root/fake-sig"
mkdir -p "$fake_sig_dir"
python3 - "$fake_sig_dir/panel.png" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + b"A" * 128)
PY
expect_validate_fail "reject valid-signature undecodable PNG" "$fake_sig_dir"

# Fake PNG with valid IHDR & CRCs, but corrupt zlib stream in IDAT
bad_idat_dir="$artifact_root/bad-idat"
mkdir -p "$bad_idat_dir"
python3 - "$bad_idat_dir/panel.png" <<'PY'
import struct, sys, zlib
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
blob = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", b"\x78\x9cINVALID_ZLIB_BYTES_123456") + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(blob)
PY
expect_validate_fail "reject corrupt IDAT zlib stream" "$bad_idat_dir"

# Valid IHDR/IDAT/IEND plus an unknown critical chunk: PNG §13.1 decoders must reject it.
unknown_critical_dir="$artifact_root/unknown-critical"
mkdir -p "$unknown_critical_dir"
python3 - "$unknown_critical_dir/panel.png" <<'PY'
import struct, sys, zlib
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
blob = (sig + chunk(b"IHDR", ihdr) + chunk(b"ZZZZ", b"x")
        + chunk(b"IDAT", zlib.compress(bytes([0, 1, 2, 3]))) + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(blob)
PY
expect_validate_fail "reject unknown critical chunk" "$unknown_critical_dir"

# PNG with dimensions exceeding MAX_DIMENSION (4096)
huge_dim_dir="$artifact_root/huge-dim"
mkdir -p "$huge_dim_dir"
python3 - "$huge_dim_dir/panel.png" <<'PY'
import struct, sys, zlib
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", 5000, 1, 8, 0, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
raw = b"\x00" + b"\x00" * 5000
blob = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(blob)
PY
expect_validate_fail "reject oversized PNG dimensions" "$huge_dim_dir"

# File count exceeding MAX_FILE_COUNT (500)
too_many_dir="$artifact_root/too-many"
mkdir -p "$too_many_dir"
python3 - "$too_many_dir" <<'PY'
import os, struct, sys, zlib
sig = b"\x89PNG\r\n\x1a\n"
ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
blob = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00")) + chunk(b"IEND", b"")
for i in range(501):
    open(os.path.join(sys.argv[1], f"p{i:03d}.png"), "wb").write(blob)
PY
expect_validate_fail "reject >500 PNG files" "$too_many_dir"

# Total uncompressed size exceeding MAX_TOTAL_BYTES (64 MiB), each file < 8 MiB
oversized_total_dir="$artifact_root/oversized-total"
mkdir -p "$oversized_total_dir"
python3 - "$oversized_total_dir" <<'PY'
import os, struct, sys, zlib
sig = b"\x89PNG\r\n\x1a\n"
# 1600x1600 RGB raw = 7,681,600 bytes; level=0 zlib stores uncompressed -> valid ~7.68 MiB PNG (< 8 MiB)
w, h = 1600, 1600
ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
row = b"\x00" + b"\x00" * (w * 3)
raw = row * h
blob = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, level=0)) + chunk(b"IEND", b"")
# 9 * 7.68 MiB ~= 69.1 MiB > 64 MiB total cap
for i in range(9):
    open(os.path.join(sys.argv[1], f"big{i}.png"), "wb").write(blob)
PY
expect_validate_fail "reject total size >64 MiB" "$oversized_total_dir"

# Archive extraction guards (pre-unpack archive size & zip entry limits)
zip_bomb_path="$artifact_root/too-many.zip"
make_zip_from_dir "$too_many_dir" "$zip_bomb_path"
if bash scripts/ci_snapshot_artifact.sh extract-zip "$zip_bomb_path" "$artifact_root/out-many" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
    printf 'FAIL extract-zip should reject >500 entries\n' >&2
    failures=$((failures + 1))
else
    printf 'PASS extract-zip rejects >500 entries\n'
fi

oversized_zip="$artifact_root/oversized.zip"
python3 - "$oversized_zip" <<'PY'
import sys
# Sparse-like raw file > 64 MiB to test pre-unpack size guard before opening ZIP
with open(sys.argv[1], "wb") as fh:
    fh.seek(67108865)
    fh.write(b"\x00")
PY
if bash scripts/ci_snapshot_artifact.sh extract-zip "$oversized_zip" "$artifact_root/out-oversized" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
    printf 'FAIL extract-zip should reject >64 MiB archive before unpacking\n' >&2
    failures=$((failures + 1))
else
    printf 'PASS extract-zip rejects >64 MiB archive before unpacking\n'
fi

lzma_dir="$artifact_root/lzma-src"
mkdir -p "$lzma_dir"
tiny_png "$lzma_dir/panel.png" 7
lzma_zip="$artifact_root/lzma.zip"
python3 - "$lzma_dir/panel.png" "$lzma_zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_LZMA) as zf:
    zf.write(sys.argv[1], arcname="panel.png")
PY
if bash scripts/ci_snapshot_artifact.sh extract-zip "$lzma_zip" "$artifact_root/out-lzma" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
    printf 'FAIL extract-zip should reject non-STORED/DEFLATED entries\n' >&2
    failures=$((failures + 1))
else
    printf 'PASS extract-zip rejects LZMA entries\n'
fi

good_zip="$artifact_root/good.zip"
make_zip_from_dir "$lzma_dir" "$good_zip"
if bash scripts/ci_snapshot_artifact.sh extract-zip "$good_zip" "$artifact_root/out-good" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
    printf 'PASS extract-zip accepts DEFLATED entries\n'
else
    printf 'FAIL extract-zip should accept DEFLATED entries\n' >&2
    failures=$((failures + 1))
fi

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
    tiny_png "$artifact/panel.png" 42
    tiny_png "$artifact/extra.png" 7
    tiny_png "$dest/panel.png" 1
    if ! bash scripts/ci_snapshot_artifact.sh install "$artifact" "$dest" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL install happy path\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        listing="$(ls "$dest")"
        expect_eq "install keeps and adds artifact pngs" "$(printf 'extra.png\npanel.png')" "$listing"
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

test_install_completeness_guards() {
    local root artifact tests_root dest orig_panel
    root="$(physical_tmp)"
    artifact="$root/artifact"
    tests_root="$root/Tests/MenuBarMijiaAppTests"
    dest="$tests_root/__Snapshots__/SnapshotTests"
    mkdir -p "$artifact" "$dest"

    tiny_png "$dest/panelSnapshot.light.png" 1
    tiny_png "$dest/keepSnapshot.light.png" 2
    tiny_png "$artifact/panelSnapshot.light.png" 99
    orig_panel="$root/orig_panel.png"
    cp "$dest/panelSnapshot.light.png" "$orig_panel"

    # 1. Missing file without SnapshotTests.swift must be rejected before writing anything
    if bash scripts/ci_snapshot_artifact.sh install "$artifact" "$dest" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL install should reject incomplete artifact without tests source\n' >&2
        failures=$((failures + 1))
    elif [ ! -f "$dest/keepSnapshot.light.png" ] || ! cmp -s "$orig_panel" "$dest/panelSnapshot.light.png"; then
        printf 'FAIL install mutated dest on incomplete artifact\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS install rejects incomplete artifact without modifying dest\n'
    fi

    # 2. Missing file whose test function STILL exists in SnapshotTests.swift must be rejected
    cat >"$tests_root/SnapshotTests.swift" <<'SWIFT'
struct SnapshotTests {
    func panelSnapshot() {}
    func keepSnapshot() {}
}
SWIFT
    if bash scripts/ci_snapshot_artifact.sh install "$artifact" "$dest" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL install should reject missing baseline for active test\n' >&2
        failures=$((failures + 1))
    elif [ ! -f "$dest/keepSnapshot.light.png" ] || ! cmp -s "$orig_panel" "$dest/panelSnapshot.light.png"; then
        printf 'FAIL install mutated dest when active test baseline was missing\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS install rejects missing baseline when test still exists\n'
    fi

    # 3. Removing the test function from SnapshotTests.swift allows pruning its stale baseline
    cat >"$tests_root/SnapshotTests.swift" <<'SWIFT'
struct SnapshotTests {
    func panelSnapshot() {}
}
SWIFT
    if ! bash scripts/ci_snapshot_artifact.sh install "$artifact" "$dest" >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL install should allow pruning baseline after test deletion\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    elif [ -f "$dest/keepSnapshot.light.png" ] || ! cmp -s "$artifact/panelSnapshot.light.png" "$dest/panelSnapshot.light.png"; then
        printf 'FAIL install did not prune deleted-test baseline or update active baseline\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS install prunes baseline only when test function was deleted\n'
    fi

    rm -rf "$root"
}
test_install_completeness_guards

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
    local root fake_bin repo rel tests_file head_sha other_sha
    local src_good src_good_alt src_incomplete src_bad_nonpng src_bad_link src_bad_fakepng
    local zip_good zip_good_alt zip_incomplete zip_bad_nonpng zip_bad_link zip_bad_fakepng
    local run_dir art_dir zip_dir dl_log
    root="$(physical_tmp)"
    fake_bin="$root/bin"
    repo="$root/repo"
    rel="Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"
    tests_file="Tests/MenuBarMijiaAppTests/SnapshotTests.swift"
    run_dir="$root/runs"
    art_dir="$root/artifacts"
    zip_dir="$root/zips"
    dl_log="$root/download.log"
    mkdir -p "$fake_bin" "$repo/$rel" "$run_dir" "$art_dir" "$zip_dir"

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
        endpoint="$1"
        case "$endpoint" in
            */actions/workflows/ci.yml)
                printf '%s\n' "${FAKE_ADOPT_WORKFLOW_JSON:-{\"id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\"}}"
                ;;
            */actions/workflows/ci.yml/runs*)
                printf '%s\n' "${FAKE_ADOPT_RUNS_JSON:?}"
                ;;
            */actions/runs/*/artifacts*)
                rid="$(printf '%s\n' "$endpoint" | sed -E 's#.*/actions/runs/([0-9]+)/artifacts.*#\1#')"
                if [ -n "${FAKE_ADOPT_ARTIFACTS_DIR:-}" ] && [ -f "${FAKE_ADOPT_ARTIFACTS_DIR}/${rid}.json" ]; then
                    cat "${FAKE_ADOPT_ARTIFACTS_DIR}/${rid}.json"
                else
                    printf '%s\n' "${FAKE_ADOPT_ARTIFACTS_JSON:?}"
                fi
                ;;
            */actions/runs/*)
                rid="$(printf '%s\n' "$endpoint" | sed -E 's#.*/actions/runs/([0-9]+)$#\1#')"
                if [ -n "${FAKE_ADOPT_RUNS_DIR:-}" ] && [ -f "${FAKE_ADOPT_RUNS_DIR}/${rid}.json" ]; then
                    cat "${FAKE_ADOPT_RUNS_DIR}/${rid}.json"
                else
                    printf '%s\n' "${FAKE_ADOPT_SINGLE_RUN_JSON:?}"
                fi
                ;;
            */actions/artifacts/*/zip)
                aid="$(printf '%s\n' "$endpoint" | sed -E 's#.*/actions/artifacts/([0-9]+)/zip$#\1#')"
                if [ -n "${FAKE_ADOPT_DOWNLOAD_LOG:-}" ]; then
                    printf '%s\n' "$aid" >> "${FAKE_ADOPT_DOWNLOAD_LOG}"
                fi
                if [ -n "${FAKE_ADOPT_ZIP_DIR:-}" ] && [ -f "${FAKE_ADOPT_ZIP_DIR}/${aid}.zip" ]; then
                    cat "${FAKE_ADOPT_ZIP_DIR}/${aid}.zip"
                else
                    cat "${FAKE_ADOPT_ZIP_FILE:?}"
                fi
                ;;
            *)
                echo "unexpected gh api endpoint: $endpoint" >&2
                exit 3
                ;;
        esac
        ;;
    run)
        echo "gh run should not be called (must use REST API + artifact ID download)" >&2
        exit 99
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
    cat >"$repo/$tests_file" <<'SWIFT'
struct SnapshotTests {
    func panelSnapshot() {}
    func keepSnapshot() {}
}
SWIFT
    tiny_png "$repo/$rel/panelSnapshot.light.png" 1
    tiny_png "$repo/$rel/keepSnapshot.light.png" 2
    tiny_png "$repo/$rel/removedSnapshot.light.png" 3
    git -C "$repo" add "$tests_file" "$rel/panelSnapshot.light.png" "$rel/keepSnapshot.light.png" "$rel/removedSnapshot.light.png"
    git -C "$repo" commit -q -m "feat: initial ui"
    head_sha="$(git -C "$repo" rev-parse HEAD)"
    other_sha="1111111111111111111111111111111111111111"
    [ "$head_sha" = "$other_sha" ] && other_sha="2222222222222222222222222222222222222222"

    # Good artifact #1 (updates panelSnapshot, keeps keepSnapshot, adds addedSnapshot, omits deleted removedSnapshot)
    src_good="$root/src-good"
    mkdir -p "$src_good"
    tiny_png "$src_good/panelSnapshot.light.png" 111
    tiny_png "$src_good/keepSnapshot.light.png" 2
    tiny_png "$src_good/addedSnapshot.light.png" 55
    zip_good="$root/good.zip"
    make_zip_from_dir "$src_good" "$zip_good"

    # Good artifact #2 (distinct pixel payload to verify which run/artifact was chosen)
    src_good_alt="$root/src-good-alt"
    mkdir -p "$src_good_alt"
    tiny_png "$src_good_alt/panelSnapshot.light.png" 222
    tiny_png "$src_good_alt/keepSnapshot.light.png" 2
    zip_good_alt="$root/good-alt.zip"
    make_zip_from_dir "$src_good_alt" "$zip_good_alt"

    # Incomplete artifact (omits active keepSnapshot.light.png)
    src_incomplete="$root/src-incomplete"
    mkdir -p "$src_incomplete"
    tiny_png "$src_incomplete/panelSnapshot.light.png" 111
    zip_incomplete="$root/incomplete.zip"
    make_zip_from_dir "$src_incomplete" "$zip_incomplete"

    # Invalid non-PNG artifact
    src_bad_nonpng="$root/src-bad-nonpng"
    mkdir -p "$src_bad_nonpng"
    tiny_png "$src_bad_nonpng/panelSnapshot.light.png" 111
    tiny_png "$src_bad_nonpng/keepSnapshot.light.png" 2
    printf 'not a png\n' >"$src_bad_nonpng/evil.txt"
    zip_bad_nonpng="$root/bad-nonpng.zip"
    make_zip_from_dir "$src_bad_nonpng" "$zip_bad_nonpng"

    # Invalid symlink artifact
    src_bad_link="$root/src-bad-link"
    mkdir -p "$src_bad_link"
    ln -s "$src_good/panelSnapshot.light.png" "$src_bad_link/panelSnapshot.light.png"
    zip_bad_link="$root/bad-link.zip"
    make_zip_from_dir "$src_bad_link" "$zip_bad_link"

    # Fake PNG (valid 8-byte signature + undecodable body)
    src_bad_fakepng="$root/src-bad-fakepng"
    mkdir -p "$src_bad_fakepng"
    python3 - "$src_bad_fakepng/panelSnapshot.light.png" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + b"X" * 128)
PY
    tiny_png "$src_bad_fakepng/keepSnapshot.light.png" 2
    zip_bad_fakepng="$root/bad-fakepng.zip"
    make_zip_from_dir "$src_bad_fakepng" "$zip_bad_fakepng"

    local script_path="$PWD/scripts/adopt_snapshot_artifact.sh"
    local pr_ok="{\"state\":\"OPEN\",\"headRefOid\":\"${head_sha}\",\"headRefName\":\"feat/ui\",\"baseRefName\":\"main\",\"isCrossRepository\":false,\"headRepository\":{\"name\":\"MenuBarHome\",\"nameWithOwner\":\"jryang2026-code/MenuBarHome\"},\"headRepositoryOwner\":{\"login\":\"jryang2026-code\"}}"
    local run_ok="{\"id\":9001,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-11-20T01:00:00Z\",\"pull_requests\":[{\"number\":42,\"base\":{\"ref\":\"main\"}}]}"
    local art_ok="{\"artifacts\":[{\"id\":5001,\"name\":\"snapshot-baselines-${head_sha}\",\"size_in_bytes\":2048,\"expired\":false,\"created_at\":\"2026-11-20T01:05:00Z\"}]}"

    # 1. Usage validation
    expect_status "adopt rejects missing PR arg" 2 bash "$script_path"
    expect_status "adopt rejects non-numeric PR arg" 2 bash "$script_path" abc
    expect_status "adopt rejects non-numeric --run arg" 2 bash "$script_path" --run xyz 42

    # 2. Reject local HEAD != PR head
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${other_sha}\",\"headRefName\":\"feat/ui\",\"baseRefName\":\"main\",\"isCrossRepository\":false,\"headRepository\":{\"nameWithOwner\":\"jryang2026-code/MenuBarHome\"}}" \
        FAKE_ADOPT_RUNS_JSON='{"workflow_runs":[]}' \
        FAKE_ADOPT_ARTIFACTS_JSON='{"artifacts":[]}' \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
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

    # 3. P1-1: Reject fork PR
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${head_sha}\",\"headRefName\":\"feat/ui\",\"baseRefName\":\"main\",\"isCrossRepository\":true,\"headRepository\":{\"name\":\"MenuBarHome\",\"nameWithOwner\":\"attacker/MenuBarHome\"},\"headRepositoryOwner\":{\"login\":\"attacker\"}}" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject fork PR\n' >&2
        failures=$((failures + 1))
    elif ! grep -q 'fork' /tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt fork PR missing hint\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects fork PR\n'
    fi

    # 4. P1-1: Reject CI run from fork head_repository (both auto and --run)
    local run_fork="{\"id\":9010,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"attacker/MenuBarHome\"},\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-11-20T01:00:00Z\",\"pull_requests\":[{\"number\":42}]}"
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_fork}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject fork head_repository run\n' >&2
        failures=$((failures + 1))
    elif ! grep -q 'fork' /tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt fork run missing hint\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects fork head_repository run\n'
    fi

    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_SINGLE_RUN_JSON="$run_fork" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" --run 9010 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt --run should reject fork head_repository run\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt --run rejects fork head_repository run\n'
    fi

    # 5. P1-1: Reject run from wrong workflow (even if named CI)
    local run_wrong_wf="{\"id\":9011,\"workflow_id\":999999,\"path\":\".github/workflows/evil.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-11-20T01:00:00Z\",\"pull_requests\":[{\"number\":42}]}"
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_wrong_wf}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject wrong workflow\n' >&2
        failures=$((failures + 1))
    elif ! grep -q 'workflow' /tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt wrong workflow missing hint\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects wrong workflow\n'
    fi

    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_SINGLE_RUN_JSON="$run_wrong_wf" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" --run 9011 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt --run should reject wrong workflow\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt --run rejects wrong workflow\n'
    fi

    # 6. P1-1: Reject pull_request run associated with a different PR number
    local run_wrong_pr="{\"id\":9012,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-11-20T01:00:00Z\",\"pull_requests\":[{\"number\":99}]}"
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_wrong_pr}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject mismatched PR number on run\n' >&2
        failures=$((failures + 1))
    elif ! grep -q 'PR 号' /tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt mismatched PR number missing hint\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects mismatched PR number on run\n'
    fi

    # 7. P1-1: Reject disallowed event type (e.g. push) and wrong workflow_dispatch branch
    local run_push="{\"id\":9013,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-11-20T01:00:00Z\",\"pull_requests\":[]}"
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_push}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject push event run\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects disallowed event type\n'
    fi

    local run_dispatch_wrong_branch="{\"id\":9014,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"other-branch\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"workflow_dispatch\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-11-20T01:00:00Z\",\"pull_requests\":[]}"
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_dispatch_wrong_branch}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject workflow_dispatch on wrong branch\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects workflow_dispatch on wrong branch\n'
    fi

    # 8. Reject CI run with mismatched head_sha
    local run_wrong_sha="{\"id\":9000,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${other_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-11-20T01:00:00Z\",\"pull_requests\":[{\"number\":42}]}"
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_wrong_sha}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"id\":5000,\"name\":\"snapshot-baselines-${other_sha}\",\"size_in_bytes\":2048,\"expired\":false}]}" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
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

    # 9. Reject artifact whose name has a different SHA
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"id\":5009,\"name\":\"snapshot-baselines-${other_sha}\",\"size_in_bytes\":2048,\"expired\":false}]}" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
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

    # 10. P1-2: Reject oversized archive reported by API before downloading
    : >"$dl_log"
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="{\"artifacts\":[{\"id\":5010,\"name\":\"snapshot-baselines-${head_sha}\",\"size_in_bytes\":99999999,\"expired\":false}]}" \
        FAKE_ADOPT_DOWNLOAD_LOG="$dl_log" \
        FAKE_ADOPT_ZIP_FILE="$zip_good" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject oversized archive before download\n' >&2
        failures=$((failures + 1))
    elif [ -s "$dl_log" ]; then
        printf 'FAIL adopt downloaded oversized archive instead of rejecting upfront\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects oversized archive before downloading\n'
    fi

    # 11. P1-2: Reject fake PNG (valid signature, undecodable body) without touching repo
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_bad_fakepng" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject undecodable fake PNG\n' >&2
        failures=$((failures + 1))
    elif [ "$(git -C "$repo" rev-parse HEAD)" != "$head_sha" ] || [ -n "$(git -C "$repo" status --porcelain)" ]; then
        printf 'FAIL adopt left repo dirty after rejecting fake PNG\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects undecodable fake PNG cleanly\n'
    fi

    # 12. Reject invalid non-PNG & symlink artifacts without touching repo
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_bad_nonpng" \
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

    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_bad_link" \
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

    # 13. P1-2: Reject incomplete artifact (missing active baseline) without touching repo
    if (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_JSON="$art_ok" \
        FAKE_ADOPT_ZIP_FILE="$zip_incomplete" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should reject incomplete artifact\n' >&2
        failures=$((failures + 1))
    elif [ "$(git -C "$repo" rev-parse HEAD)" != "$head_sha" ] || [ -n "$(git -C "$repo" status --porcelain)" ] || [ ! -f "$repo/$rel/keepSnapshot.light.png" ]; then
        printf 'FAIL adopt mutated repo on incomplete artifact\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt rejects incomplete artifact without touching repo\n'
    fi

    # 14. P2: Two runs for the SAME SHA — newer run 9002 has NO matching artifact, older run 9001 HAS artifact 5001
    local run_newer="{\"id\":9002,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"pull_request\",\"status\":\"in_progress\",\"conclusion\":null,\"created_at\":\"2026-11-20T02:00:00Z\",\"pull_requests\":[{\"number\":42}]}"
    printf '%s\n' "$run_ok" >"$run_dir/9001.json"
    printf '%s\n' "$run_newer" >"$run_dir/9002.json"
    printf '%s\n' "$art_ok" >"$art_dir/9001.json"
    printf '%s\n' '{"artifacts":[]}' >"$art_dir/9002.json"
    cp "$zip_good" "$zip_dir/5001.zip"
    cp "$zip_good_alt" "$zip_dir/5002.zip"

    : >"$dl_log"
    if ! (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_newer},${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_DIR="$art_dir" \
        FAKE_ADOPT_ZIP_DIR="$zip_dir" \
        FAKE_ADOPT_DOWNLOAD_LOG="$dl_log" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt P2 fallback to older run with artifact failed\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    else
        local new_head subject committed_files body
        new_head="$(git -C "$repo" rev-parse HEAD)"
        subject="$(git -C "$repo" log -1 --format=%s)"
        body="$(git -C "$repo" log -1 --format=%b)"
        committed_files="$(git -C "$repo" show --name-only --format= HEAD | sed '/^$/d' | sort)"
        if [ "$new_head" = "$head_sha" ]; then
            printf 'FAIL adopt P2 fallback did not create commit\n' >&2
            failures=$((failures + 1))
        elif [ "$(cat "$dl_log")" != "5001" ]; then
            printf 'FAIL adopt P2 fallback did not download artifact ID 5001 (got %s)\n' "$(cat "$dl_log")" >&2
            failures=$((failures + 1))
        elif [ "$subject" != "test(snapshots): re-record UI baselines on macos-26-intel" ]; then
            printf 'FAIL adopt commit subject unexpected: %s\n' "$subject" >&2
            failures=$((failures + 1))
        elif [ ! -f "$repo/$rel/addedSnapshot.light.png" ] || [ -f "$repo/$rel/removedSnapshot.light.png" ] || ! cmp -s "$src_good/panelSnapshot.light.png" "$repo/$rel/panelSnapshot.light.png"; then
            printf 'FAIL adopt did not install/prune baseline PNGs properly\n' >&2
            failures=$((failures + 1))
        elif [ -n "$(git -C "$repo" status --porcelain)" ]; then
            printf 'FAIL adopt left working tree dirty after commit\n' >&2
            failures=$((failures + 1))
        elif ! printf '%s\n' "$committed_files" | grep -Fxq "$rel/panelSnapshot.light.png"; then
            printf 'FAIL adopt commit missing panelSnapshot.light.png\n' >&2
            failures=$((failures + 1))
        elif ! printf '%s\n' "$body" | grep -q 'CI run 9001 (artifact 5001,'; then
            printf 'FAIL adopt commit body missing run/artifact provenance: %s\n' "$body" >&2
            failures=$((failures + 1))
        else
            printf 'PASS adopt skips newer run without artifact, downloads by artifact ID, and commits cleanly\n'
        fi
    fi

    # Reset repo back to initial head_sha for --run and workflow_dispatch tests
    git -C "$repo" reset -q --hard "$head_sha"

    # 15. P2: Both runs 9002 (newer, artifact 5002) and 9001 (older, artifact 5001) have matching artifacts
    printf '%s\n' "{\"artifacts\":[{\"id\":5002,\"name\":\"snapshot-baselines-${head_sha}\",\"size_in_bytes\":2048,\"expired\":false,\"created_at\":\"2026-11-20T02:05:00Z\"}]}" >"$art_dir/9002.json"

    # 15a. Without --run: selects newer run 9002 (artifact 5002)
    : >"$dl_log"
    if ! (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_newer},${run_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_DIR="$art_dir" \
        FAKE_ADOPT_ZIP_DIR="$zip_dir" \
        FAKE_ADOPT_DOWNLOAD_LOG="$dl_log" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt newest-with-artifact selection failed\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    elif [ "$(cat "$dl_log")" != "5002" ] || ! cmp -s "$src_good_alt/panelSnapshot.light.png" "$repo/$rel/panelSnapshot.light.png"; then
        printf 'FAIL adopt should prefer newest run 9002 (artifact 5002)\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt prefers newest run when multiple runs have matching artifacts\n'
    fi

    git -C "$repo" reset -q --hard "$head_sha"

    # 15b. With --run 9001: selects explicit older run 9001 (artifact 5001)
    : >"$dl_log"
    if ! (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_DIR="$run_dir" \
        FAKE_ADOPT_ARTIFACTS_DIR="$art_dir" \
        FAKE_ADOPT_ZIP_DIR="$zip_dir" \
        FAKE_ADOPT_DOWNLOAD_LOG="$dl_log" \
            bash "$script_path" --run 9001 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt --run 9001 failed\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    elif [ "$(cat "$dl_log")" != "5001" ] || ! cmp -s "$src_good/panelSnapshot.light.png" "$repo/$rel/panelSnapshot.light.png"; then
        printf 'FAIL adopt --run 9001 did not install artifact 5001\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt --run 9001 selects explicit provenance-verified run\n'
    fi

    git -C "$repo" reset -q --hard "$head_sha"

    # 16. P1-1: workflow_dispatch on the PR's same-repo branch is accepted (including null conclusion)
    local run_dispatch_ok="{\"id\":9003,\"workflow_id\":411138546,\"path\":\".github/workflows/ci.yml\",\"name\":\"CI\",\"head_sha\":\"${head_sha}\",\"head_branch\":\"feat/ui\",\"head_repository\":{\"full_name\":\"jryang2026-code/MenuBarHome\"},\"event\":\"workflow_dispatch\",\"status\":\"in_progress\",\"conclusion\":null,\"created_at\":\"2026-11-20T03:00:00Z\",\"pull_requests\":[]}"
    printf '%s\n' "$art_ok" >"$art_dir/9003.json"
    : >"$dl_log"
    if ! (
        cd "$repo"
        PATH="$fake_bin:$PATH" \
        FAKE_ADOPT_PR_JSON="$pr_ok" \
        FAKE_ADOPT_RUNS_JSON="{\"workflow_runs\":[${run_dispatch_ok}]}" \
        FAKE_ADOPT_ARTIFACTS_DIR="$art_dir" \
        FAKE_ADOPT_ZIP_DIR="$zip_dir" \
        FAKE_ADOPT_DOWNLOAD_LOG="$dl_log" \
            bash "$script_path" 42
    ) >/tmp/snapshot-ci-test.out 2>/tmp/snapshot-ci-test.err; then
        printf 'FAIL adopt should accept same-repo PR branch workflow_dispatch run\n' >&2
        cat /tmp/snapshot-ci-test.err >&2
        failures=$((failures + 1))
    elif [ "$(cat "$dl_log")" != "5001" ]; then
        printf 'FAIL adopt workflow_dispatch did not download artifact 5001\n' >&2
        failures=$((failures + 1))
    else
        printf 'PASS adopt accepts same-repo PR branch workflow_dispatch run (including null conclusion)\n'
    fi

    rm -rf "$root"
}
test_adopt_snapshot_artifact

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 snapshot CI 脚本自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ snapshot CI 脚本自测通过\n'
