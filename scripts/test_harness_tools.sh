#!/usr/bin/env bash
# Self-test for the test-harness tools wired into run_script_self_tests():
#   - scripts/repeat_test.sh: --stress workers spawn, are always reaped (success,
#     failure, and signal paths), and argument validation exits 2.
#   - windows/scripts/test-file.mjs: usage validation and the real
#     --test-name-pattern filtering effect through a throwaway probe file.
# Bash 3.2 compatible; every background process this script starts is waited
# on before it returns.
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
note_fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

SPIN_PATTERN='while :; do x='
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mmb-harness-tools.XXXXXX")"
cleanup_probe() {
    rm -rf "$PROBE_DIR"
}
trap cleanup_probe EXIT INT TERM HUP

count_spinners() {
    { pgrep -f "$SPIN_PATTERN" || true; } | wc -l | tr -d ' '
}

assert_no_spinners() {
    local label="$1" attempt spinners
    # cleanup() waits on every worker, so the count is normally already zero;
    # the retries only absorb scheduling jitter on loaded machines.
    for attempt in 1 2 3 4 5; do
        spinners="$(count_spinners)"
        if [ "$spinners" -eq 0 ]; then
            return 0
        fi
        sleep 0.1
    done
    note_fail "${label}：仍残留 ${spinners} 个压力自旋进程"
    return 0
}

# --- repeat_test.sh: argument validation -----------------------------------

if bash scripts/repeat_test.sh >/dev/null 2>&1; then
    note_fail "repeat_test.sh 无参数应退出 2"
fi
if bash scripts/repeat_test.sh --stress 2 >/dev/null 2>&1; then
    note_fail "repeat_test.sh --stress 2 缺少 filter 应退出 2"
fi
if bash scripts/repeat_test.sh --stress=abc dummy 3 >/dev/null 2>&1; then
    note_fail "repeat_test.sh --stress=abc 应退出 2"
fi
if bash scripts/repeat_test.sh dummy 0 >/dev/null 2>&1; then
    note_fail "repeat_test.sh count=0 应退出 2"
fi
if bash scripts/repeat_test.sh dummy x >/dev/null 2>&1; then
    note_fail "repeat_test.sh count 非数字应退出 2"
fi
if [ "$(count_spinners)" -ne 0 ]; then
    note_fail "参数校验路径不应启动任何压力子进程"
fi

# --- repeat_test.sh: backward-compatible plain repeats ---------------------

plain_out="$(REPEAT_TEST_RUN='true' bash scripts/repeat_test.sh dummy 3 2>/dev/null)"
if [ "$plain_out" != "passes=3 failures=0" ]; then
    note_fail "repeat_test.sh 普通重复模式输出异常：$plain_out"
fi

# --- repeat_test.sh: --stress success path reaps every worker ---------------

stress_out="$(REPEAT_TEST_RUN='true' bash scripts/repeat_test.sh --stress 2 dummy 3 2>/dev/null)"
if [ "$stress_out" != "passes=3 failures=0" ]; then
    note_fail "repeat_test.sh --stress 2 输出异常：$stress_out"
fi
assert_no_spinners "repeat_test.sh --stress 2 正常结束后"

# --- repeat_test.sh: --stress=<workers> and failing repeats still reap ------

stress_eq_out="$(REPEAT_TEST_RUN='true' bash scripts/repeat_test.sh --stress=2 dummy 2 2>/dev/null)"
if [ "$stress_eq_out" != "passes=2 failures=0" ]; then
    note_fail "repeat_test.sh --stress=2 输出异常：$stress_eq_out"
fi
assert_no_spinners "repeat_test.sh --stress=2 正常结束后"

failing_status=0
REPEAT_TEST_RUN='exit 7' bash scripts/repeat_test.sh --stress 2 dummy 2 >/dev/null 2>&1 || failing_status=$?
if [ "$failing_status" -ne 1 ]; then
    note_fail "repeat_test.sh 重复命令失败应以退出码 1 结束，实际 $failing_status"
fi
assert_no_spinners "repeat_test.sh 失败退出后"

# --- repeat_test.sh: SIGTERM mid-run still reaps every worker ---------------

term_status=0
REPEAT_TEST_RUN='sleep 1' bash scripts/repeat_test.sh --stress 2 dummy 2 >/dev/null 2>&1 &
victim="$!"
spin_seen=0
spin_attempt=1
while [ "$spin_attempt" -le 20 ]; do
    if [ "$(count_spinners)" -ge 2 ]; then
        spin_seen=1
        break
    fi
    sleep 0.1
    spin_attempt=$((spin_attempt + 1))
done
if [ "$spin_seen" -ne 1 ]; then
    kill -TERM "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    note_fail "repeat_test.sh --stress 2 未观察到压力子进程启动"
else
    kill -TERM "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    assert_no_spinners "repeat_test.sh 收到 SIGTERM 后"
fi

# --- test-file.mjs: usage validation and real filtering --------------------

if command -v node >/dev/null 2>&1; then
    usage_status=0
    node windows/scripts/test-file.mjs >/dev/null 2>&1 || usage_status=$?
    if [ "$usage_status" -ne 2 ]; then
        note_fail "test-file.mjs 无参数应以退出码 2 结束，实际 $usage_status"
    fi
    options_only_status=0
    node windows/scripts/test-file.mjs --test-name-pattern foo >/dev/null 2>&1 || options_only_status=$?
    if [ "$options_only_status" -ne 2 ]; then
        note_fail "test-file.mjs 只有过滤参数没有文件应以退出码 2 结束，实际 $options_only_status"
    fi

    probe_file="$PROBE_DIR/probe.test.mjs"
    {
        printf '%s\n' 'import assert from "node:assert/strict";'
        printf '%s\n' 'import { test } from "node:test";'
        printf '%s\n' ''
        printf '%s\n' 'test("harness match target", () => {'
        printf '%s\n' '  assert.ok(true);'
        printf '%s\n' '});'
        printf '%s\n' ''
        printf '%s\n' 'test("harness other target", () => {'
        printf '%s\n' '  assert.fail("this test must be filtered out");'
        printf '%s\n' '});'
    } >"$probe_file"

    filter_status=0
    node windows/scripts/test-file.mjs "$probe_file" --test-name-pattern "harness match" >/dev/null 2>&1 || filter_status=$?
    if [ "$filter_status" -ne 0 ]; then
        note_fail "test-file.mjs 带过滤参数运行探针应以退出码 0 结束，实际 $filter_status"
    fi
    filter_run="$(node windows/scripts/test-file.mjs "$probe_file" --test-name-pattern "harness match" 2>/dev/null)"
    if ! printf '%s\n' "$filter_run" | grep -q "harness match target"; then
        note_fail "test-file.mjs --test-name-pattern 未执行匹配用例"
    fi
    if printf '%s\n' "$filter_run" | grep -q "harness other target"; then
        note_fail "test-file.mjs --test-name-pattern 不应执行不匹配用例"
    fi
    if ! printf '%s\n' "$filter_run" | grep -Eq '(#|ℹ) (tests|pass) 1$'; then
        note_fail "test-file.mjs --test-name-pattern 应只执行 1 条用例"
    fi
    unfiltered_status=0
    node windows/scripts/test-file.mjs "$probe_file" >/dev/null 2>&1 || unfiltered_status=$?
    if [ "$unfiltered_status" -ne 1 ]; then
        note_fail "test-file.mjs 无过滤对照应因探针失败用例以退出码 1 结束，实际 $unfiltered_status"
    fi
else
    printf '%s\n' "⏭️  跳过 test-file.mjs 自测：未找到 node" >&2
fi

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项测试脚手架自测失败\n' "$failures" >&2
    exit 1
fi
printf '%s\n' "✅ repeat_test.sh / test-file.mjs 脚手架自测通过"
