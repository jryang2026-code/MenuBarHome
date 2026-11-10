#!/usr/bin/env bash
# go2rtc 门禁只在 go version 成功时跑 verify.sh。目录和失败桩必须跳过。
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

ready="scripts/go2rtc-ptz/go_ready.sh"
bash_bin="$(command -v bash)"
empty="$(mktemp -d)"
cache="$(mktemp -d)"
# PATH must not contain go. perl still has to be visible: the deadline uses it,
# and macOS and Linux both ship perl outside the Go toolchain.
ln -s "$(command -v perl)" "$empty/perl"
trap 'rm -rf "$empty" "$cache"' EXIT

expect_skip() {
    local name="$1" reason="$2"
    shift 2
    local status=0 err out
    err="$(mktemp)"
    out="$(mktemp)"
    set +e
    "$@" >"$out" 2>"$err"
    status=$?
    set -e
    if [ "$status" -eq 2 ] && [ "$(cat "$err")" = "$reason" ] && [ ! -s "$out" ]; then
        pass "$name"
    else
        fail "$name：应为退出 2 且「${reason}」，实际退出 ${status}，stderr「$(cat "$err")」，stdout「$(cat "$out")」"
    fi
    rm -f "$err" "$out"
}

expect_skip "没有 go" "未找到 go" \
    env PATH="$empty" GO2RTC_PTZ_GO_CACHE="$cache/missing" "$bash_bin" "$ready"

mkdir -p "$cache/go/bin/go"
expect_skip "缓存路径是目录" "go 不是普通可执行文件" \
    env PATH="$empty" GO2RTC_PTZ_GO_CACHE="$cache" "$bash_bin" "$ready"

rm -rf "$cache/go/bin/go"
mkdir -p "$cache/go/bin"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$cache/go/bin/go"
chmod +x "$cache/go/bin/go"
expect_skip "go version 失败的桩" "go version 失败" \
    env PATH="$empty" GO2RTC_PTZ_GO_CACHE="$cache" "$bash_bin" "$ready"

printf '%s\n' '#!/bin/sh' 'echo "go version go1.26.10 linux/amd64"' 'exit 0' >"$cache/go/bin/go"
chmod +x "$cache/go/bin/go"
status=0
out="$(mktemp)"
err="$(mktemp)"
set +e
env PATH="$empty" GO2RTC_PTZ_GO_CACHE="$cache" "$bash_bin" "$ready" >"$out" 2>"$err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ "$(cat "$out")" = "$cache/go/bin/go" ] && [ ! -s "$err" ]; then
    pass "能跑 go version 的桩可用"
else
    fail "能跑 go version 的桩应退出 0 并打印路径，实际退出 ${status}，stdout「$(cat "$out")」，stderr「$(cat "$err")」"
fi
rm -f "$out" "$err"

# A stub that sleeps must not stall the gate. The skip itself returns 0.
hang_pid="$cache/hang.pid"
rm -f "$hang_pid"
printf '%s\n' '#!/bin/sh' "echo \$\$ > '$hang_pid'" '/bin/sleep 30' >"$cache/go/bin/go"
chmod +x "$cache/go/bin/go"
start=$(date +%s)
status=0
out="$(mktemp)"
err="$(mktemp)"
set +e
env PATH="$empty" GO2RTC_PTZ_GO_CACHE="$cache" "$bash_bin" "$ready" >"$out" 2>"$err"
status=$?
set -e
end=$(date +%s)
elapsed=$((end - start))
gate_status=1
gate_line=""
if [ "$status" -ne 0 ]; then
    gate_line="⏭️  跳过 go2rtc 云台补丁验证：$(cat "$err")"
    gate_status=0
fi
if [ -f "$hang_pid" ]; then
    hang_id="$(cat "$hang_pid")"
    kill -KILL -- "-$hang_id" 2>/dev/null || true
    kill -KILL "$hang_id" 2>/dev/null || true
fi
if [ "$status" -eq 2 ] \
    && [ "$(cat "$err")" = "go version 超时" ] \
    && [ "$gate_status" -eq 0 ] \
    && [ "$elapsed" -ge 4 ] \
    && [ "$elapsed" -lt 8 ] \
    && [ ! -s "$out" ]; then
    printf 'PASS go version 超时的桩在 %ss 内跳过：%s\n' "$elapsed" "$gate_line"
else
    fail "挂起的桩应在约 5s 内以退出 2 跳过且门禁返回 0，实际探针退出 ${status}，门禁 ${gate_status}，用时 ${elapsed}s，stderr「$(cat "$err")」，stdout「$(cat "$out")」"
fi
rm -f "$out" "$err"

if [ "$failures" -eq 0 ]; then
    exit 0
fi
exit 1
