#!/usr/bin/env bash
# Self-test for the test-harness tools wired into run_script_self_tests():
#   - scripts/repeat_test.sh: --stress workers are tagged per invocation,
#     always reaped (success, failure, and signal paths), argument validation
#     exits 2, and a termination signal stops the repeat loop instead of
#     running the remaining repeats and reporting success.
#   - windows/scripts/test-file.mjs: usage validation and the real
#     --test-name-pattern filtering effect, proven through side-effect marker
#     files: Node 20's TAP reporter prints skipped test names ("# SKIP test
#     name does not match pattern"), so stdout string-absence checks are not
#     portable across Node versions.
# Bash 3.2 compatible. Every background process this script starts is either
# waited on or reaped by the exit/signal traps before this script returns.
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
note_fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mmb-harness-tools.XXXXXX")"
# Dummy spinner started by this script to prove that workers belonging to a
# different tag are never counted. Reaped by cleanup_probe on every path.
FOREIGN_PID=""
cleanup_probe() {
    if [ -n "$FOREIGN_PID" ]; then
        kill "$FOREIGN_PID" 2>/dev/null || true
        wait "$FOREIGN_PID" 2>/dev/null || true
        FOREIGN_PID=""
    fi
    rm -rf "$PROBE_DIR"
}
trap cleanup_probe EXIT
trap 'cleanup_probe; exit 130' INT
trap 'cleanup_probe; exit 143' TERM
trap 'cleanup_probe; exit 129' HUP

# Per-invocation worker tags. repeat_test.sh starts each spin child as
# `sh -c <loop> "stress-tag:<tag>"`, so the tag shows up in `ps` (macOS) and in
# /proc/<pid>/cmdline (Linux) and the assertions below only ever look at
# workers this run owns -- a `repeat_test.sh --stress` running in another
# terminal or worktree can never turn into a false positive. The counter is
# kept in the current shell (a command-substituted helper would run in a
# subshell and lose every increment) and zero-padded so tag ...-002 cannot
# prefix-match tag ...-020.
SPIN_TAG_PREFIX="mmb-stress-$$"
tag_seq=0
spin_tag=""
next_spin_tag() {
    tag_seq=$((tag_seq + 1))
    spin_tag="$SPIN_TAG_PREFIX-$(printf '%03d' "$tag_seq")"
}

# [s] in the pattern keeps pgrep from matching a shell whose command line
# merely contains the pattern text.
count_tag_spinners() {
    { pgrep -f "[s]tress-tag:$1" || true; } | wc -l | tr -d ' '
}

assert_no_tag_spinners() {
    local tag="$1" label="$2" attempt spinners
    # cleanup() waits on every worker, so the count is normally already zero;
    # the retries only absorb scheduling jitter on loaded machines.
    for attempt in 1 2 3 4 5; do
        spinners="$(count_tag_spinners "$tag")"
        if [ "$spinners" -eq 0 ]; then
            return 0
        fi
        sleep 0.1
    done
    note_fail "${label}：tag ${tag} 下仍残留 ${spinners} 个压力自旋进程"
    return 0
}

wait_for_tag_spinners() {
    local tag="$1" wanted="$2" attempt=1
    while [ "$attempt" -le 30 ]; do
        if [ "$(count_tag_spinners "$tag")" -ge "$wanted" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    return 1
}

# --- repeat_test.sh: argument validation -----------------------------------

next_spin_tag
validation_tag="$spin_tag"
if REPEAT_TEST_STRESS_TAG="$validation_tag" bash scripts/repeat_test.sh >/dev/null 2>&1; then
    note_fail "repeat_test.sh 无参数应退出 2"
fi
# A bare --stress has no filter to run: it must fail validation instead of
# treating the next token as a worker count.
if REPEAT_TEST_STRESS_TAG="$validation_tag" bash scripts/repeat_test.sh --stress >/dev/null 2>&1; then
    note_fail "repeat_test.sh --stress 缺少 filter 应退出 2"
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
bad_tag_status=0
REPEAT_TEST_STRESS_TAG='not_a!tag' bash scripts/repeat_test.sh --stress 1 dummy 1 >/dev/null 2>&1 \
    || bad_tag_status=$?
if [ "$bad_tag_status" -ne 2 ]; then
    note_fail "repeat_test.sh 的 REPEAT_TEST_STRESS_TAG 含非法字符应退出 2，实际 $bad_tag_status"
fi
assert_no_tag_spinners "$validation_tag" "参数校验路径不应启动任何压力子进程"

# A lone numeric token after --stress is the filter, not a worker count: the
# run must complete all default 20 repeats instead of failing on a missing
# filter.
next_spin_tag
numeric_filter_tag="$spin_tag"
numeric_filter_status=0
numeric_filter_out="$(REPEAT_TEST_STRESS_TAG="$numeric_filter_tag" REPEAT_TEST_RUN='true' \
    bash scripts/repeat_test.sh --stress 42 2>/dev/null)" || numeric_filter_status=$?
if [ "$numeric_filter_status" -ne 0 ] || [ "$numeric_filter_out" != "passes=20 failures=0" ]; then
    note_fail "repeat_test.sh --stress 42 应把 42 当作 filter 跑满默认 20 次，实际(${numeric_filter_status})：$numeric_filter_out"
fi
assert_no_tag_spinners "$numeric_filter_tag" "repeat_test.sh --stress 42 数字 filter 运行后"

# --- repeat_test.sh: backward-compatible plain repeats ---------------------

plain_status=0
plain_out="$(REPEAT_TEST_RUN='true' bash scripts/repeat_test.sh dummy 3 2>/dev/null)" || plain_status=$?
if [ "$plain_status" -ne 0 ] || [ "$plain_out" != "passes=3 failures=0" ]; then
    note_fail "repeat_test.sh 普通重复模式输出异常(${plain_status})：$plain_out"
fi

# --- repeat_test.sh: --stress success path reaps every worker ---------------

next_spin_tag
stress_tag="$spin_tag"
stress_status=0
stress_out="$(REPEAT_TEST_STRESS_TAG="$stress_tag" REPEAT_TEST_RUN='true' \
    bash scripts/repeat_test.sh --stress 2 dummy 3 2>/dev/null)" || stress_status=$?
if [ "$stress_status" -ne 0 ] || [ "$stress_out" != "passes=3 failures=0" ]; then
    note_fail "repeat_test.sh --stress 2 输出异常(${stress_status})：$stress_out"
fi
assert_no_tag_spinners "$stress_tag" "repeat_test.sh --stress 2 正常结束后"

# --- repeat_test.sh: --stress=<workers> and failing repeats still reap ------

next_spin_tag
stress_eq_tag="$spin_tag"
stress_eq_status=0
stress_eq_out="$(REPEAT_TEST_STRESS_TAG="$stress_eq_tag" REPEAT_TEST_RUN='true' \
    bash scripts/repeat_test.sh --stress=2 dummy 2 2>/dev/null)" || stress_eq_status=$?
if [ "$stress_eq_status" -ne 0 ] || [ "$stress_eq_out" != "passes=2 failures=0" ]; then
    note_fail "repeat_test.sh --stress=2 输出异常(${stress_eq_status})：$stress_eq_out"
fi
assert_no_tag_spinners "$stress_eq_tag" "repeat_test.sh --stress=2 正常结束后"

next_spin_tag
failing_tag="$spin_tag"
failing_status=0
REPEAT_TEST_STRESS_TAG="$failing_tag" REPEAT_TEST_RUN='exit 7' \
    bash scripts/repeat_test.sh --stress 2 dummy 2 >/dev/null 2>&1 || failing_status=$?
if [ "$failing_status" -ne 1 ]; then
    note_fail "repeat_test.sh 重复命令失败应以退出码 1 结束，实际 $failing_status"
fi
assert_no_tag_spinners "$failing_tag" "repeat_test.sh 失败退出后"

# --- repeat_test.sh: workers from another invocation are never counted -----

foreign_tag="$SPIN_TAG_PREFIX-foreign-000"
sh -c 'x=0; while :; do x=$((x + 1)); done' "stress-tag:$foreign_tag" &
FOREIGN_PID="$!"
if ! wait_for_tag_spinners "$foreign_tag" 1; then
    note_fail "并发对照自旋子进程未按预期启动"
fi
next_spin_tag
concurrent_check_tag="$spin_tag"
if [ "$(count_tag_spinners "$concurrent_check_tag")" -ne 0 ]; then
    note_fail "其他 tag 的并发自旋进程不应计入本用例（tag ${concurrent_check_tag}）"
fi
if [ "$(count_tag_spinners "$foreign_tag")" -lt 1 ]; then
    note_fail "并发对照自旋子进程应只被自己的 tag 计数（tag ${foreign_tag}）"
fi
kill "$FOREIGN_PID" 2>/dev/null || true
wait "$FOREIGN_PID" 2>/dev/null || true
FOREIGN_PID=""

# --- repeat_test.sh: SIGTERM mid-run stops the loop and reaps every worker --

next_spin_tag
term_tag="$spin_tag"
term_counter="$PROBE_DIR/term_runs"
REPEAT_TEST_STRESS_TAG="$term_tag" \
REPEAT_TEST_RUN="printf x >>'$term_counter'; sleep 1" \
    bash scripts/repeat_test.sh --stress 2 dummy 5 >/dev/null 2>&1 &
victim="$!"
if ! wait_for_tag_spinners "$term_tag" 2; then
    kill -TERM "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    note_fail "repeat_test.sh --stress 2 未观察到压力子进程启动"
else
    kill -TERM "$victim" 2>/dev/null || true
    term_status=0
    wait "$victim" 2>/dev/null || term_status=$?
    if [ "$term_status" -eq 0 ]; then
        note_fail "repeat_test.sh 收到 SIGTERM 后不应以退出码 0 结束"
    elif [ "$term_status" -ne 143 ]; then
        note_fail "repeat_test.sh 收到 SIGTERM 应以退出码 143 结束，实际 $term_status"
    fi
    term_runs=0
    if [ -f "$term_counter" ]; then
        term_runs="$(wc -c <"$term_counter" | tr -d ' ')"
    fi
    if [ "$term_runs" -ge 5 ]; then
        note_fail "repeat_test.sh 收到 SIGTERM 后不应跑满 5 次，实际已运行 ${term_runs} 次"
    fi
    assert_no_tag_spinners "$term_tag" "repeat_test.sh 收到 SIGTERM 后"
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

    # Both callbacks drop a marker next to the probe file; which markers exist
    # proves which callbacks ran, independently of how the reporter prints
    # skipped tests.
    probe_file="$PROBE_DIR/probe.test.mjs"
    {
        printf '%s\n' 'import { test } from "node:test";'
        printf '%s\n' 'import { writeFileSync } from "node:fs";'
        printf '%s\n' 'import { dirname, join } from "node:path";'
        printf '%s\n' 'import { fileURLToPath } from "node:url";'
        printf '%s\n' ''
        printf '%s\n' 'const probeDir = dirname(fileURLToPath(import.meta.url));'
        printf '%s\n' 'const markRan = (name) => writeFileSync(join(probeDir, name), "");'
        printf '%s\n' ''
        printf '%s\n' 'test("harness match target", () => {'
        printf '%s\n' '  markRan("ran-target");'
        printf '%s\n' '});'
        printf '%s\n' ''
        printf '%s\n' 'test("harness other target", () => {'
        printf '%s\n' '  markRan("ran-other");'
        printf '%s\n' '});'
    } >"$probe_file"

    check_pattern_run() {
        local placement="$1" status="$2"
        if [ "$status" -ne 0 ]; then
            note_fail "test-file.mjs ${placement}运行探针应以退出码 0 结束，实际 $status"
        fi
        if [ ! -f "$PROBE_DIR/ran-target" ]; then
            note_fail "test-file.mjs ${placement}过滤参数未执行匹配用例（缺少 ran-target 标记）"
        fi
        if [ -f "$PROBE_DIR/ran-other" ]; then
            note_fail "test-file.mjs ${placement}过滤参数不应执行不匹配用例（存在 ran-other 标记）"
        fi
    }

    rm -f "$PROBE_DIR/ran-target" "$PROBE_DIR/ran-other"
    after_status=0
    node windows/scripts/test-file.mjs "$probe_file" --test-name-pattern "harness match" \
        >/dev/null 2>&1 || after_status=$?
    check_pattern_run "文件后置 " "$after_status"

    rm -f "$PROBE_DIR/ran-target" "$PROBE_DIR/ran-other"
    before_status=0
    node windows/scripts/test-file.mjs --test-name-pattern "harness match" "$probe_file" \
        >/dev/null 2>&1 || before_status=$?
    check_pattern_run "文件前置 " "$before_status"

    rm -f "$PROBE_DIR/ran-target" "$PROBE_DIR/ran-other"
    unfiltered_status=0
    node windows/scripts/test-file.mjs "$probe_file" >/dev/null 2>&1 || unfiltered_status=$?
    if [ "$unfiltered_status" -ne 0 ]; then
        note_fail "test-file.mjs 无过滤对照应以退出码 0 结束，实际 $unfiltered_status"
    fi
    if [ ! -f "$PROBE_DIR/ran-target" ] || [ ! -f "$PROBE_DIR/ran-other" ]; then
        note_fail "test-file.mjs 无过滤对照应执行两条用例（标记文件不齐）"
    fi
else
    printf '%s\n' "⏭️  跳过 test-file.mjs 自测：未找到 node" >&2
fi

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项测试脚手架自测失败\n' "$failures" >&2
    exit 1
fi
printf '%s\n' "✅ repeat_test.sh / test-file.mjs 脚手架自测通过"
