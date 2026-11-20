#!/usr/bin/env bash
# ci_swift_test.sh 的失败重跑自测：只测纯逻辑，不跑 swift，也不依赖 macOS。
# 夹具在 scripts/testdata/ci-swift-test/，四个必测场景对应：
#   重跑通过  → retry_plan 给出 retry，retry_verdict 判 pass，report_flaky 写出 warning 与 job summary
#   重跑失败  → retry_verdict 判 fail（job 维持失败）
#   崩溃不重跑 → retry_plan 判 crash
#   超过 5 个不重跑 → retry_plan 判 too-many
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

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 ci_swift_test.sh 自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ ci_swift_test.sh 自测通过\n'
