#!/usr/bin/env bash
# next_version.sh 自测（ADR-0022）：上海日期、同一天序号、以及必须大于已有标签。
set -euo pipefail
cd "$(dirname "$0")/.."

workdir="$(mktemp -d "${TMPDIR:-/tmp}/menubarmijia-next-version.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name t
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" commit -q --allow-empty -m init
}

tag_repo() {
    local dir="$1"
    shift
    local version
    for version in "$@"; do
        git -C "$dir" tag "v$version"
    done
}

expect_out() {
    local expected="$1" message="$2"
    shift 2
    local actual=0
    if "$@" >"$workdir/out.txt" 2>"$workdir/err.txt"; then
        actual=0
    else
        actual=1
    fi
    local got
    got="$(tr -d '\r' < "$workdir/out.txt")"
    if [ "$actual" -eq 0 ] && [ "$got" = "$expected" ]; then
        pass "$message"
    else
        printf 'FAIL %s\n' "$message"
        printf '    stdout: %s\n' "$got"
        sed 's/^/    /' "$workdir/err.txt"
        failures=$((failures + 1))
    fi
}

expect_fail() {
    local pattern="$1" message="$2"
    shift 2
    local actual=0
    if "$@" >"$workdir/out.txt" 2>"$workdir/err.txt"; then
        actual=0
    else
        actual=1
    fi
    if [ "$actual" -eq 1 ] && grep -Fq "$pattern" "$workdir/err.txt"; then
        pass "$message"
    else
        printf 'FAIL %s\n' "$message"
        sed 's/^/    /' "$workdir/err.txt"
        failures=$((failures + 1))
    fi
}

empty="$workdir/empty"
init_repo "$empty"
expect_out "26.11.1701" "first release on 2026-11-17 is 26.11.1701" \
    bash scripts/next_version.sh --repo "$empty" --date 2026-11-17
expect_out "2026.11.17（v1）" "human label uses the calendar date and sequence 1" \
    bash scripts/next_version.sh --repo "$empty" --date 2026-11-17 --label
expect_out "26.12.501" "December 5 does not pad the patch" \
    bash scripts/next_version.sh --repo "$empty" --date 2026-12-05
expect_out "2026.12.05（v1）" "human label pads the calendar day" \
    bash scripts/next_version.sh --repo "$empty" --date 2026-12-05 --label

tagged="$workdir/tagged"
init_repo "$tagged"
tag_repo "$tagged" 1.3.0 26.11.1699 26.11.1701
expect_out "26.11.1702" "same-day tag bumps the sequence and ignores 1.3.0" \
    bash scripts/next_version.sh --repo "$tagged" --date 2026-11-17
expect_out "2026.11.17（v2）" "human label uses the next same-day sequence" \
    bash scripts/next_version.sh --repo "$tagged" --date 2026-11-17 --label

hole="$workdir/hole"
init_repo "$hole"
tag_repo "$hole" 26.11.1702
expect_out "26.11.1703" "a missing lower sequence is not reused" \
    bash scripts/next_version.sh --repo "$hole" --date 2026-11-17

future="$workdir/future"
init_repo "$future"
tag_repo "$future" 26.11.1801
expect_fail "不大于已有标签" "a later tag blocks today's version" \
    bash scripts/next_version.sh --repo "$future" --date 2026-11-17

boundary="$workdir/boundary"
init_repo "$boundary"
tag_repo "$boundary" 26.11.1800
expect_fail "不大于已有标签" "patch 1800 is not a day-17 sequence and still blocks 1701" \
    bash scripts/next_version.sh --repo "$boundary" --date 2026-11-17

full="$workdir/full"
init_repo "$full"
tag_repo "$full" 26.11.1799
expect_fail "当天序号已用尽" "sequence 99 is the last slot in a day" \
    bash scripts/next_version.sh --repo "$full" --date 2026-11-17

old="$workdir/old"
init_repo "$old"
expect_fail "没有大于已发布的 1.3.0" "a 2001-02-01 version is not newer than 1.3.0" \
    bash scripts/next_version.sh --repo "$old" --date 2001-02-01

expect_fail "日期不是合法的公历日" "November 31 is rejected" \
    bash scripts/next_version.sh --repo "$empty" --date 2026-11-31
expect_fail "编不出 MSI 允许的 major" "year 2256 does not fit a major ≤ 255" \
    bash scripts/next_version.sh --repo "$empty" --date 2256-01-01

shim="$workdir/bin"
mkdir -p "$shim"
cat > "$shim/date" <<'EOF'
#!/bin/sh
if [ "${TZ:-}" = "Asia/Shanghai" ]; then
    printf '%s\n' "2026-11-17"
else
    printf '%s\n' "2026-11-16"
fi
EOF
chmod +x "$shim/date"
expect_out "26.11.1701" "the calendar day comes from Asia/Shanghai even when TZ=UTC" \
    env TZ=UTC PATH="$shim:$PATH" bash scripts/next_version.sh --repo "$empty"

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项下一版本号自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ 下一版本号自测通过\n'
