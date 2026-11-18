#!/usr/bin/env bash
# ci_errors.sh 自测：注入假 gh（无网络）。验证 --attempt 透传、
# `not ok` 失败用例被点名、通过的 `ok` 行不被打印。
set -euo pipefail
cd "$(dirname "$0")/.."

workdir="$(mktemp -d "${TMPDIR:-/tmp}/mmb-ci-errors-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
fake_bin="$workdir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
# 假 gh：记录全部参数，返回固定 JSON 与失败日志。
set -u
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
cmd="$1"
shift
case "$cmd" in
    repo) echo '{"nameWithOwner":"jryang2026-code/MenuBarHome"}' ;;
    api) echo '[]' ;;
    run)
        sub="$1"
        shift
        log_failed=0
        while [ "$#" -gt 0 ]; do
            [ "$1" = --log-failed ] && log_failed=1
            shift
        done
        if [ "$sub" = list ]; then
            echo '[]'
        elif [ "$log_failed" = 1 ]; then
            cat "${FAKE_GH_LOG_FAILED_FILE:?}"
        else
            printf '%s\n' "${FAKE_GH_RUN_JOBS_JSON:?}"
        fi
        ;;
    *) exit 3 ;;
esac
GH
chmod +x "$fake_bin/gh"

RUN_ID="44228348849"
MERGE_OID="aaaabbbbccccdddd000011112222333344445555"
RUN_JOBS_JSON="$(printf '{"jobs":[{"name":"windows-rust-test","conclusion":"failure","databaseId":4242,"steps":[{"name":"npm test"}]}],"event":"push","headBranch":"main","headSha":"%s","createdAt":"2026-11-18T03:00:00Z","databaseId":%s,"workflowName":"CI"}' "$MERGE_OID" "$RUN_ID")"
FAILED_LOG="$workdir/failed.log"
{
    printf 'windows-rust-test\tstep\t2026-11-18T03:14:37Z\t    not ok 17 - stops a Xiaomi cloud live view after repeated frame failures instead of renegotiating\n'
    printf 'windows-rust-test\tstep\t2026-11-18T03:14:38Z\tnot ok 144 - Smart camera support and live view (\\#97)\n'
    printf 'windows-rust-test\tstep\t2026-11-18T03:14:37Z\t      error: '\''Timed out waiting for UI state'\''\n'
    printf 'windows-rust-test\tstep\t2026-11-18T03:11:01Z\t    ok 1 - renders built-in QuickActions in xiaomiCloud and homeAssistant modes\n'
} >"$FAILED_LOG"

export FAKE_GH_LOG="$workdir/gh.log" FAKE_GH_RUN_JOBS_JSON="$RUN_JOBS_JSON" FAKE_GH_LOG_FAILED_FILE="$FAILED_LOG"

failures=0
status=0

run_ci_errors() { # <args...>
    : >"$FAKE_GH_LOG"
    status=0
    PATH="$fake_bin:$PATH" bash scripts/ci_errors.sh "$@" >"$workdir/out.log" 2>&1 || status=$?
}

expect_in() { # <message> <needle> [file]
    if grep -Fq -- "$2" "${3:-$workdir/out.log}"; then
        printf 'PASS %s\n' "$1"
    else
        printf 'FAIL %s\n' "$1"
        sed 's/^/    /' "${3:-$workdir/out.log}"
        failures=$((failures + 1))
    fi
}

expect_status() { # <期望退出码> <message>
    if [ "$status" -eq "$1" ]; then
        printf 'PASS %s\n' "$2"
    else
        printf 'FAIL %s（期望退出码 %s，实际 %s）\n' "$2" "$1" "$status"
        sed 's/^/    /' "$workdir/out.log"
        failures=$((failures + 1))
    fi
}

expect_absent() { # <message> <needle> [file]
    if grep -Fq -- "$2" "${3:-$workdir/out.log}"; then
        printf 'FAIL %s\n' "$1"
        sed 's/^/    /' "${3:-$workdir/out.log}"
        failures=$((failures + 1))
    else
        printf 'PASS %s\n' "$1"
    fi
}

run_ci_errors --attempt 1 "$RUN_ID"
expect_status 0 "--attempt 1 仍打印失败摘要（退出码 0）"
expect_in "--attempt 1 透传给 run view 元数据" "run view ${RUN_ID} --attempt 1 --json jobs,event,headBranch,headSha,createdAt,databaseId,workflowName" "$FAKE_GH_LOG"
expect_in "--attempt 1 透传给 --log-failed" "run view ${RUN_ID} --attempt 1 --log-failed" "$FAKE_GH_LOG"
expect_in "缩进的 not ok 失败用例被点名" "not ok 17 - stops a Xiaomi cloud live view after repeated frame failures instead of renegotiating"
expect_in "非缩进的 not ok 失败用例被点名" "not ok 144 - Smart camera support and live view (\\#97)"
expect_in "error 行仍被打印" "Timed out waiting for UI state"
expect_absent "通过的 ok 用例不被打印" "ok 1 - renders built-in QuickActions in xiaomiCloud and homeAssistant modes"

run_ci_errors "$RUN_ID"
expect_status 0 "不带 --attempt 时行为不变（退出码 0）"
expect_in "不带 --attempt 也打印失败用例" "not ok 17 - stops a Xiaomi cloud live view"
expect_absent "不带 --attempt 时不向 gh 传 --attempt" "--attempt" "$FAKE_GH_LOG"

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 ci_errors.sh 自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ ci_errors.sh 自测通过\n'
