#!/usr/bin/env bash
# ci-failures.sh 自测：注入假 gh（无网络），用 testdata/ci-failures/ 的夹具日志验证解析。
# 覆盖：ANSI（原始 ESC 与 printable `^[[` 两种）被剥掉、失败用例去重且保留首次的文件:行号、
# node/编译/崩溃/快照信号各有小节、open issue 命中标 [已知间歇 #N]、通过的用例不出现、
# 总输出 ≤ 60 行、PR 号取 head 上最新的 CI 运行。
set -euo pipefail
cd "$(dirname "$0")/.."

workdir="$(mktemp -d "${TMPDIR:-/tmp}/mmb-ci-failures-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
fixtures="scripts/testdata/ci-failures"
fake_bin="$workdir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
# 假 gh：记录全部参数，按子命令返回夹具。
set -u
printf '%s\n' "$*" >>"${FAKE_GH_CALLS:?}"
cmd="$1"
shift
case "$cmd" in
    api)
        printf '%s\n' "${FAKE_GH_RUN_ATTEMPT:-1}"
        ;;
    pr)
        cat "${FAKE_GH_FIXTURES:?}/pr.json"
        ;;
    issue)
        cat "${FAKE_GH_FIXTURES:?}/issues.json"
        ;;
    run)
        sub="$1"
        shift
        log_failed=0
        while [ "$#" -gt 0 ]; do
            [ "$1" = --log-failed ] && log_failed=1
            shift
        done
        if [ "$sub" = list ]; then
            cat "${FAKE_GH_FIXTURES:?}/runs.json"
        elif [ "$log_failed" = 1 ]; then
            cat "${FAKE_GH_FIXTURES:?}/failed.log"
        else
            cat "${FAKE_GH_FIXTURES:?}/jobs.json"
        fi
        ;;
    *) exit 3 ;;
esac
GH
chmod +x "$fake_bin/gh"

export PATH="$fake_bin:$PATH"
export FAKE_GH_CALLS="$workdir/gh.log"
export FAKE_GH_FIXTURES="$PWD/$fixtures"

failures=0
status=0
out="$workdir/out.log"

run_ci_failures() { # <args...>
    : >"$FAKE_GH_CALLS"
    status=0
    bash scripts/ci-failures.sh "$@" >"$out" 2>&1 || status=$?
}

expect() { # <message> <needle>
    if grep -Fq -- "$2" "$out"; then
        printf 'PASS %s\n' "$1"
    else
        printf 'FAIL %s（缺少：%s）\n' "$1" "$2"
        sed 's/^/    /' "$out"
        failures=$((failures + 1))
    fi
}

reject() { # <message> <needle>
    if grep -Fq -- "$2" "$out"; then
        printf 'FAIL %s（不应出现：%s）\n' "$1" "$2"
        grep -nF -- "$2" "$out" | sed 's/^/    /'
        failures=$((failures + 1))
    else
        printf 'PASS %s\n' "$1"
    fi
}

run_ci_failures 44000000001

if [ "$status" -eq 0 ]; then
    printf 'PASS 失败运行退出码 0（摘要已输出）\n'
else
    printf 'FAIL 失败运行退出码应为 0，实际 %s\n' "$status"
    sed 's/^/    /' "$out"
    failures=$((failures + 1))
fi

expect "任务名与失败 job 列表" "失败 job：macos-test, macos-snapshots, windows-core, linux-core, ci"
expect "Swift 失败用例带文件名与首次失败行号" '"HA disable previews device timers and revalidates on fresh snapshot" HAConnectionDisableTests.swift:522'
expect "open issue 命中后标已知间歇（用例名与文件名都命中）" '[已知间歇 #308]'
expect "票里只写用例名（没写文件名）也能命中" '"HA disable previews device timers and revalidates on fresh snapshot" HAConnectionDisableTests.swift:522 [已知间歇 #281]'
expect "node TAP 失败用例被点名" "not ok - stops a Xiaomi cloud live view after repeated frame failures instead of renegotiating"
expect "编译错误首行被点名" "error: fatalError"
expect "崩溃标记被点名" "exited with unexpected signal code 6"
expect "崩溃标记含 crashed during execution" "swift test crashed during execution"
expect "快照不匹配的用例名被点名" '"onboarding-custom-ai-zh-light"'
expect "缺基线的快照被点名" "adaptive-pilot-capped-zh-light（缺基线）"
expect "汇总门禁 job 说明没有独立信号" "没有可提取的失败信号"
reject "通过的用例不出现在摘要里" "A passing case stays out of the summary"

case_dupes="$(grep -Fc 'Duplicated case across two log lines stays one row' "$out" || true)"
if [ "$case_dupes" = "1" ]; then
    printf 'PASS 同名用例去重后只出现一次\n'
else
    printf 'FAIL 同名用例应只出现一次，实际 %s 次\n' "$case_dupes"
    failures=$((failures + 1))
fi

cross_job="$(grep -Fc 'HAConnectionDisableTests.swift:522' "$out" || true)"
if [ "$cross_job" = "2" ]; then
    printf 'PASS 同一用例在两个 job 里各出现一次（去重按 job 分桶）\n'
else
    printf 'FAIL 同一用例应在两个 job 下各出现一次，实际 %s 次\n' "$cross_job"
    failures=$((failures + 1))
fi

error_dupes="$(grep -Fc 'error: fatalError' "$out" || true)"
if [ "$error_dupes" = "1" ]; then
    printf 'PASS 重复的编译错误去重\n'
else
    printf 'FAIL 重复的编译错误应只出现一次，实际 %s 次\n' "$error_dupes"
    failures=$((failures + 1))
fi

if grep -q $'^\x1b\|^\[\[[0-9;]*m\|\^\[\[\|\x1b\[' "$out"; then
    printf 'FAIL 输出里仍有 ANSI 转义序列\n'
    grep -n $'\x1b\|^\[\[[0-9;]*m' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
else
    printf 'PASS 输出里没有 ANSI 转义序列\n'
fi

line_count="$(wc -l <"$out" | tr -d ' ')"
if [ "$line_count" -le 60 ]; then
    printf 'PASS 摘要行数 %s ≤ 60\n' "$line_count"
else
    printf 'FAIL 摘要 %s 行，超过 60 行上限\n' "$line_count"
    failures=$((failures + 1))
fi

run_ci_failures 311
expect "PR 号取 head 上最新的 CI 运行" "run 44000000001 attempt 1/1"
expect "PR 号写进标题" "PR #311 → "
reject "PR 号模式不会误用更旧的那次运行" "run 44000000000"

printf '%s\n' "--- 夹具摘要（供人工对照）"
sed 's/^/    /' "$out"

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 ci-failures.sh 自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ ci-failures.sh 自测通过\n'
