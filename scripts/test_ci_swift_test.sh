#!/usr/bin/env bash
# 失败重跑自测：只测纯逻辑，不跑 swift，也不依赖 macOS。
# 解析与判定在 scripts/lib/swift_test_retry.sh（macOS 的 ci_swift_test.sh 与 Linux 的
# scripts/linux-check/run.sh 共用），所以这里测的就是两端的行为。夹具在
# scripts/testdata/ci-swift-test/，必测场景对应：
#   重跑通过  → retry_plan 给出 retry，retry_verdict 判 pass，report_flaky 写出 warning 与 job summary
#   重跑失败  → retry_verdict 判 fail（job 维持失败）
#   崩溃不重跑 → retry_plan 判 crash
#   超过 5 个不重跑 → retry_plan 判 too-many
#   Linux 行号偏移 → 日志的行号属于 .work 副本（头部注入 3 行），必须查副本才能定位到正确的函数
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/ci_swift_test.sh
source scripts/ci_swift_test.sh

fixtures="scripts/testdata/ci-swift-test"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/mmb-ci-swift-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '     %s\n' "$2"
    failures=$((failures + 1))
}

expect_eq() { # <message> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "期望 [$2]，实际 [$3]"
    fi
}

# --- 解析：失败用例去重，保留首次失败的文件:行号 -----------------------------------------
rows="$workdir/rows.tsv"
failed_test_cases "$fixtures/first.log" >"$rows"
expect_eq "失败用例去重后两行" "2" "$(wc -l <"$rows" | tr -d ' ')"
expect_eq "同名用例保留首次失败位置" \
    "Flaky cover case	FixtureTests.swift	6" \
    "$(sed -n 1p "$rows")"
expect_eq "第二个用例的文件:行号" \
    "Flaky scene case	FixtureTests.swift	11" \
    "$(sed -n 2p "$rows")"
expect_eq "崩溃日志仍能提取用例" "1" "$(failed_case_count "$fixtures/crash.log")"

# --- filter 推导：从记录位置找回 Suite.func（--filter 匹配 test id，不匹配显示名）---------
filters="$workdir/filters.txt"
retry_filter_args "$rows" "$fixtures/root" >"$filters"
expect_eq "--filter 推导出两个精确的 Suite.func" \
    "FixtureTests.flakyCover
FixtureTests.flakyScene" \
    "$(cat "$filters")"

# --- 嵌套 helper：回扫记录行会落到局部类的 func，必须用 @Test("名字") 抢住 --------------------
# MiSessionExpiryTests 的 #296 就是这种形状（#expect 上方隔着一个 class SelectionBox 的 func set）。
nestedroot="$fixtures/nested"
nrows="$workdir/nested.tsv"
printf '%s\n' "$(printf 'Nested helper case\tNestedFixtureTests.swift\t11')" >"$nrows"
expect_eq "@Test(名字) 抢住时对准测试函数，而不是局部 helper" \
    "NestedFixtureTests.nestedHelperCase" \
    "$(retry_filter_args "$nrows" "$nestedroot")"
expect_eq "只能回扫行号时会落到嵌套 helper（所以需要上面的抢住）" \
    "SelectionBox.set" \
    "$(derive_suite_func "$nestedroot/Tests/NestedFixtureTests.swift" "不存在的用例名" 11)"

# --- 参数化用例：带参数的 issue 行与 `with N test cases passed` 也算通过 -------------------
prows="$workdir/param.tsv"
failed_test_cases "$fixtures/parameterized.log" >"$prows"
expect_eq "参数化用例的 issue 行能解析出文件:行号" \
    "Fold layout picks the first card	ParamFixtureTests.swift	6" \
    "$(sed -n 1p "$prows")"
expect_eq "参数化用例重跑全过判 pass" "pass" "$(retry_verdict "$prows" "$fixtures/parameterized-pass.log")"
expect_eq "参数化用例可重跑" "retry" "$(retry_plan "$fixtures/parameterized.log" 1 0)"

# --- 缺基线不重跑：SnapshotAssertion 会把第一轮的 PNG 写进源码树，重跑必然「通过」----------
expect_eq "缺快照基线不重跑" "no-baseline" "$(retry_plan "$fixtures/missing-baseline.log" 1 0)"
expect_eq "日志里解析不出的失败用例不重跑" "unparsed" "$(retry_plan "$fixtures/unknown-format.log" 1 0)"

# --- 是否需要重跑 -----------------------------------------------------------------------
expect_eq "第一次失败且不崩溃不 stall → 重跑一次" "retry" "$(retry_plan "$fixtures/first.log" 1 0)"
expect_eq "崩溃不重跑" "crash" "$(retry_plan "$fixtures/crash.log" 1 0)"
expect_eq "stall 不重跑" "stall" "$(retry_plan "$fixtures/first.log" 1 1)"
expect_eq "超过 5 个失败用例不重跑" "too-many" "$(retry_plan "$fixtures/many.log" 1 0)"
expect_eq "本地默认不重跑（CI 之外）" "off" "$(retry_plan "$fixtures/first.log" 0 0)"

five="$workdir/five.log"
printf '%s\n' '◇ Test run started.' \
    '✘ Test "Case 1" recorded an issue at FixtureTests.swift:6:9: Expectation failed' \
    '✘ Test "Case 2" recorded an issue at FixtureTests.swift:6:9: Expectation failed' \
    '✘ Test "Case 3" recorded an issue at FixtureTests.swift:6:9: Expectation failed' \
    '✘ Test "Case 4" recorded an issue at FixtureTests.swift:6:9: Expectation failed' \
    '✘ Test "Case 5" recorded an issue at FixtureTests.swift:6:9: Expectation failed' >"$five"
expect_eq "正好 5 个失败用例仍重跑" "retry" "$(retry_plan "$five" 1 0)"

# --- 重跑结果 ---------------------------------------------------------------------------
expect_eq "重跑全过 → pass（job 判为通过）" "pass" "$(retry_verdict "$rows" "$fixtures/second-pass.log")"
expect_eq "重跑仍失败 → fail（job 维持失败）" "fail" "$(retry_verdict "$rows" "$fixtures/second-fail.log")"
expect_eq "filter 一个都没匹配上 → empty（不算通过）" "empty" "$(retry_verdict "$rows" "$fixtures/second-empty.log")"
expect_eq "重跑崩溃 → crash（不算通过）" "crash" "$(retry_verdict "$rows" "$fixtures/crash.log")"

partly="$workdir/partly.log"
printf '%s\n' '◇ Test run started.' \
    '✔ Test "Flaky cover case" passed after 0.402 seconds.' \
    '✔ Test run with 1 test in 1 suite passed after 0.5 seconds.' >"$partly"
expect_eq "只跑了一半用例 → unverified（不算通过）" "unverified" "$(retry_verdict "$rows" "$partly")"

expect_eq "汇总行判 pass" "pass" "$(swift_test_summary_verdict "$fixtures/second-pass.log")"
expect_eq "汇总行判 fail" "fail" "$(swift_test_summary_verdict "$fixtures/first.log")"
if log_has_crash "$fixtures/crash.log"; then
    pass "进程崩溃能被识别"
else
    fail "进程崩溃标记没被识别"
fi
if log_has_crash "$fixtures/first.log"; then
    fail "普通失败日志被误判成崩溃"
else
    pass "普通失败日志不判为崩溃"
fi

# --- 重跑通过时的输出：warning + job summary ---------------------------------------------
summary="$workdir/step-summary.md"
: >"$summary"
GITHUB_STEP_SUMMARY="$summary" report_flaky "$rows" >"$workdir/report.log" 2>&1
if grep -Fq '::warning::flaky tests passed on retry: Flaky cover case, Flaky scene case' "$workdir/report.log"; then
    pass "重跑通过后打出 ::warning::flaky tests passed on retry"
else
    fail "缺少 flaky 警告行" "$(cat "$workdir/report.log")"
fi
if grep -Fq '| `Flaky cover case` | `FixtureTests.swift:6` |' "$summary"; then
    pass "job summary 列出用例名与首次失败的 文件:行号"
else
    fail "job summary 缺少用例行" "$(cat "$summary")"
fi

# --- CI 开关：本地默认不重跑，CI_RETRY_FAILED 双向覆盖 --------------------------------------
expect_eq "本地默认不重跑（无 CI）" "0" "$(unset CI CI_RETRY_FAILED; swift_test_retry_enabled)"
expect_eq "CI=true 打开重跑" "1" "$(CI=true CI_RETRY_FAILED=  swift_test_retry_enabled)"
expect_eq "CI_RETRY_FAILED=0 在 CI 里关掉重跑" "0" "$(CI=true CI_RETRY_FAILED=0 swift_test_retry_enabled)"
expect_eq "CI_RETRY_FAILED=1 在本地也能重跑" "1" "$(unset CI; CI_RETRY_FAILED=1 swift_test_retry_enabled)"

# --- Linux 行号偏移：日志里的 文件:行号 属于 .work 里的副本（头部注入了 3 行）----------------
# 夹具的两个用例分别证明两件事：
#   plainCase() 没有显示名（所以没有 @Test(名字) 可抢），第 13 行在副本里是 plainCase 的
#   #expect，在仓库 Tests 里已经是 neighborCase——只有查副本才对。
#   Shifted poll case 有显示名，即使行号偏移也能靠 @Test(名字) 纠正回来。
offsetroot="$fixtures/offset"
orows="$workdir/offset.tsv"
printf '%s\n' "$(printf 'plainCase()\tOffsetFixtureTests.swift\t13')" >"$orows"
SWIFT_TEST_SOURCE_ROOTS="$offsetroot/.work"
expect_eq "查 .work 副本能定位到偏移行号的测试函数" \
    "OffsetFixtureTests.plainCase" \
    "$(retry_filter_args "$orows" "$offsetroot")"
SWIFT_TEST_SOURCE_ROOTS="$offsetroot/Tests"
expect_eq "查仓库 Tests 会差 3 行、落到相邻用例（所以 Linux 必须查副本）" \
    "OffsetFixtureTests.neighborCase" \
    "$(retry_filter_args "$orows" "$offsetroot")"
printf '%s\n' "$(printf 'Shifted poll case\tOffsetFixtureTests.swift\t9')" >"$orows"
expect_eq "有 @Test(名字) 时行号偏移也能纠回正确函数" \
    "OffsetFixtureTests.shiftedPollCase" \
    "$(retry_filter_args "$orows" "$offsetroot")"
unset SWIFT_TEST_SOURCE_ROOTS
expect_eq "不设开关时默认查仓库 Tests" "$offsetroot/Tests" "$(swift_test_source_dirs "$offsetroot")"

# --- 重跑流程（两端共用）：stub 掉一次运行，只验判定与接线 ---------------------------------
attempt_args="$workdir/attempt-args.txt"
stub_log=""
# shellcheck disable=SC2317  # 由 retry_failed_cases 调用
swift_test_run_attempt() { # log_file swift test 参数...
    local log="$1"
    shift
    printf '%s\n' "$*" >"$attempt_args"
    cp "$stub_log" "$log"
    RUN_EXIT=1
    RUN_STALLED=0
}

stub_log="$fixtures/second-pass.log"
driver_out="$(retry_failed_cases "$fixtures/first.log" 1 0 "$fixtures/root" --skip SnapshotTests 2>&1)"
driver_rc=$?
expect_eq "Linux 路径：重跑全过 → 判定通过" "0" "$driver_rc"
expect_eq "重跑沿用原参数并追加 --filter" \
    "--skip SnapshotTests --filter FixtureTests.flakyCover --filter FixtureTests.flakyScene" \
    "$(cat "$attempt_args")"
case "$driver_out" in
    *"::warning::flaky tests passed on retry: Flaky cover case, Flaky scene case"*)
        pass "Linux 路径：重跑通过后打出 flaky 警告" ;;
    *) fail "Linux 路径缺少 flaky 警告" "$driver_out" ;;
esac

stub_log="$fixtures/second-fail.log"
driver_out="$(retry_failed_cases "$fixtures/first.log" 1 0 "$fixtures/root" --skip SnapshotTests 2>&1)"
driver_rc=$?
expect_eq "Linux 路径：重跑仍失败 → 维持失败" "1" "$driver_rc"
case "$driver_out" in
    *"the retry did not clear the failure (fail)"*)
        pass "重跑仍失败时说明原因" ;;
    *) fail "重跑仍失败缺少说明" "$driver_out" ;;
esac

: >"$attempt_args"
stub_log="$fixtures/second-pass.log"
retry_failed_cases "$fixtures/first.log" 0 0 "$fixtures/root" --skip SnapshotTests >/dev/null 2>&1
expect_eq "不重跑时直接判失败（CI 之外）" "1" "$?"
expect_eq "不重跑时不会启动第二次运行" "" "$(cat "$attempt_args")"

expect_eq "崩溃不重跑（共用流程）" "1" "$(retry_failed_cases "$fixtures/crash.log" 1 0 "$fixtures/root" >/dev/null 2>&1; echo $?)"
expect_eq "stall 不重跑（共用流程）" "1" "$(retry_failed_cases "$fixtures/first.log" 1 1 "$fixtures/root" >/dev/null 2>&1; echo $?)"

# --- 两端接线：run.sh 走共享实现，解析/判定只在 lib 里维护一份 ------------------------------
duplicated=""
for fn in log_has_crash swift_test_summary_verdict failed_test_cases retry_filter_args retry_verdict retry_plan retry_failed_cases run_with_watchdog; do
    if grep -qE "^${fn}\\(\\)" scripts/ci_swift_test.sh scripts/linux-check/run.sh; then
        duplicated="$duplicated $fn"
    fi
done
expect_eq "两个调用方都没有各自复制解析/判定函数" "" "$duplicated"
for caller in scripts/ci_swift_test.sh scripts/linux-check/run.sh; do
    if grep -Fq 'scripts/lib/swift_test_retry.sh' "$caller"; then
        pass "$caller 引用共享实现"
    else
        fail "$caller 没有引用共享实现"
    fi
done
if bash -n scripts/linux-check/run.sh; then
    pass "run.sh 语法正确"
else
    fail "run.sh 语法错误"
fi
if grep -qF 'retry_failed_cases' scripts/linux-check/run.sh; then
    pass "run.sh 调用了失败重跑流程"
else
    fail "run.sh 没有调用失败重跑流程"
fi
if grep -qE '^[[:space:]]*swift test "\$@"' scripts/linux-check/run.sh; then
    fail "run.sh 仍在末尾直接跑 swift test（绕过了重跑）"
else
    pass "run.sh 不再绕过重跑直接跑 swift test"
fi
if grep -qF 'stdbuf' scripts/linux-check/run.sh; then
    pass "run.sh 用 stdbuf 而不是 BSD 的 script 写法"
else
    fail "run.sh 没有行缓冲启动前缀"
fi

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 ci_swift_test.sh 自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ ci_swift_test.sh 自测通过\n'
