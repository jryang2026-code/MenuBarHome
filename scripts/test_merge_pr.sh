#!/usr/bin/env bash
# merge-pr.sh 自测：注入假 gh（无网络）。覆盖：pending/失败检查拒绝、head 不一致、
# CLOSED 拒绝、happy path --match-head-commit、已合并跳过、main CI 失败转 ci_errors、超时 124。
set -euo pipefail
cd "$(dirname "$0")/.."

workdir="$(mktemp -d "${TMPDIR:-/tmp}/mmb-merge-pr-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
fake_bin="$workdir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
# 假 gh：只实现 merge-pr.sh / ci_errors.sh 用到的子命令，全部无网络。
set -u
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
cmd="$1"
shift
case "$cmd" in
    repo) echo '{"nameWithOwner":"jryang2026-code/MenuBarHome"}' ;;
    api) echo '[]' ;;
    pr)
        sub="$1"
        shift
        case "$sub" in
            view)
                fields=""
                while [ "$#" -gt 0 ]; do
                    [ "$1" = --json ] && fields="$2"
                    shift
                done
                if [ "$fields" = mergeCommit ]; then
                    printf '{"mergeCommit":{"oid":"%s"}}\n' "${FAKE_GH_MERGE_OID:?}"
                else
                    printf '%s\n' "${FAKE_GH_PR_JSON:?}"
                fi
                ;;
            merge) printf 'pr merge %s\n' "$*" >>"${FAKE_GH_MERGE_LOG:?}" ;;
            *) exit 3 ;;
        esac
        ;;
    run)
        sub="$1"
        shift
        log_failed=0 fields="" commit=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --json) fields="$2" ;;
                --log-failed) log_failed=1 ;;
                --commit) commit=1 ;;
            esac
            shift
        done
        case "$sub" in
            list)
                if [ "$commit" = 1 ]; then
                    printf '%s\n' "${FAKE_GH_RUN_LIST_JSON:?}"
                else
                    echo '[]'
                fi
                ;;
            view)
                if [ "$log_failed" = 1 ]; then
                    cat "${FAKE_GH_LOG_FAILED_FILE:?}"
                elif [ "$fields" = status,conclusion ]; then
                    printf '%s\n' "${FAKE_GH_RUN_STATUS_JSON:?}"
                else
                    printf '%s\n' "${FAKE_GH_RUN_JOBS_JSON:?}"
                fi
                ;;
            *) exit 3 ;;
        esac
        ;;
    *) exit 3 ;;
esac
GH
chmod +x "$fake_bin/gh"

HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba98fedcba98fedcba98fedcba98fedcba98"
MERGE_OID="aaaabbbbccccdddd000011112222333344445555"
RUN_ID="44228348849"
PR="235"
GREEN='[{"__typename":"CheckRun","name":"changes","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"linux-core","status":"COMPLETED","conclusion":"SKIPPED"}]'
OFFEND='[{"__typename":"CheckRun","name":"changes","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"macos-test","status":"IN_PROGRESS","conclusion":null},{"__typename":"CheckRun","name":"windows-rust-test","status":"COMPLETED","conclusion":"FAILURE"}]'
pr_json() { # <state> <head> <rollup> <merge-oid>
    printf '{"state":"%s","headRefOid":"%s","mergeCommit":{"oid":"%s"},"statusCheckRollup":%s}\n' "$1" "$2" "$4" "$3"
}
RUN_LIST="$(printf '[{"databaseId":%s,"workflowName":"CI","headSha":"%s","headBranch":"main"}]' "$RUN_ID" "$MERGE_OID")"
RUN_JOBS_JSON="$(printf '{"jobs":[{"name":"windows-rust-test","conclusion":"failure","databaseId":4242,"steps":[{"name":"npm test"}]}],"event":"push","headBranch":"main","headSha":"%s","createdAt":"2026-11-18T03:00:00Z","databaseId":%s,"workflowName":"CI"}' "$MERGE_OID" "$RUN_ID")"
FAILED_LOG="$workdir/failed.log"
{
    printf 'windows-rust-test\tstep\t2026-11-18T03:14:37Z\t    not ok 17 - stops a Xiaomi cloud live view after repeated frame failures instead of renegotiating\n'
    printf 'windows-rust-test\tstep\t2026-11-18T03:14:37Z\t      error: '\''Timed out waiting for UI state'\''\n'
    printf 'windows-rust-test\tstep\t2026-11-18T03:11:01Z\t    ok 1 - renders built-in QuickActions in xiaomiCloud and homeAssistant modes\n'
} >"$FAILED_LOG"

export FAKE_GH_LOG="$workdir/gh.log" FAKE_GH_MERGE_LOG="$workdir/merge.log"
export FAKE_GH_MERGE_OID="$MERGE_OID" FAKE_GH_RUN_LIST_JSON="$RUN_LIST" FAKE_GH_RUN_JOBS_JSON="$RUN_JOBS_JSON"
export FAKE_GH_LOG_FAILED_FILE="$FAILED_LOG" FAKE_GH_RUN_STATUS_JSON='{"status":"completed","conclusion":"success"}'
export FAKE_GH_PR_JSON="$(pr_json OPEN "$HEAD_SHA" "$GREEN" "")"

failures=0
status=0

run_pr() { # <期望退出码> <message> <args...>
    local expected="$1" message="$2"
    shift 2
    : >"$FAKE_GH_LOG"
    rm -f "$FAKE_GH_MERGE_LOG"
    status=0
    PATH="$fake_bin:$PATH" bash scripts/merge-pr.sh "$@" >"$workdir/out.log" 2>&1 || status=$?
    if [ "$status" -eq "$expected" ]; then
        printf 'PASS %s\n' "$message"
        return 0
    fi
    printf 'FAIL %s（期望退出码 %s，实际 %s）\n' "$message" "$expected" "$status"
    sed 's/^/    /' "$workdir/out.log"
    failures=$((failures + 1))
    return 1
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

expect_absent() { # <message> <needle>
    if grep -Fq -- "$2" "$workdir/out.log"; then
        printf 'FAIL %s\n' "$1"
        sed 's/^/    /' "$workdir/out.log"
        failures=$((failures + 1))
    else
        printf 'PASS %s\n' "$1"
    fi
}

merged_never() { # <message>
    if [ ! -f "$FAKE_GH_MERGE_LOG" ]; then
        printf 'PASS %s\n' "$1"
    else
        printf 'FAIL %s\n' "$1"
        sed 's/^/    /' "$FAKE_GH_MERGE_LOG"
        failures=$((failures + 1))
    fi
}

# 1) 未完成/失败的检查拒绝合并
export FAKE_GH_PR_JSON="$(pr_json OPEN "$HEAD_SHA" "$OFFEND" "")"
if run_pr 1 "pending 或失败检查拒绝合并" "$PR" "$HEAD_SHA"; then
    expect_in "拒绝时点名 macos-test" "macos-test: IN_PROGRESS"
    expect_in "拒绝时点名 windows-rust-test" "windows-rust-test: FAILURE"
    merged_never "拒绝时未调用 gh pr merge"
fi

# 2) head 不一致拒绝合并
export FAKE_GH_PR_JSON="$(pr_json OPEN "$OTHER_SHA" "$GREEN" "")"
if run_pr 1 "head 不一致拒绝合并" "$PR" "$HEAD_SHA"; then
    expect_in "head 不一致时说明实际与期望" "与指定的 ${HEAD_SHA} 不一致"
    merged_never "head 不一致时未调用 gh pr merge"
fi

# 3) 已关闭的 PR 拒绝合并
export FAKE_GH_PR_JSON="$(pr_json CLOSED "$HEAD_SHA" "$GREEN" "")"
if run_pr 1 "CLOSED 状态拒绝合并" "$PR" "$HEAD_SHA"; then
    expect_in "CLOSED 状态说明不能合并" "不是 OPEN"
    merged_never "CLOSED 状态时未调用 gh pr merge"
fi

# 3b) 还没有任何检查登记时拒绝合并
export FAKE_GH_PR_JSON="$(pr_json OPEN "$HEAD_SHA" "[]" "")"
if run_pr 1 "没有检查时拒绝合并" "$PR" "$HEAD_SHA"; then
    expect_in "没有检查时说明原因" "还没有任何检查登记"
    merged_never "没有检查时未调用 gh pr merge"
fi

# 3c) 只有 Cursor 检查时仍算没有 CI 检查
CURSOR_PENDING='{"__typename":"CheckRun","name":"Cursor Security Agent: Security Reviewer","status":"IN_PROGRESS","conclusion":null}'
export FAKE_GH_PR_JSON="$(pr_json OPEN "$HEAD_SHA" "[$CURSOR_PENDING]" "")"
if run_pr 1 "只有 Cursor 检查时拒绝合并" "$PR" "$HEAD_SHA"; then
    expect_in "只有 Cursor 检查时说明原因" "还没有任何检查登记"
    merged_never "只有 Cursor 检查时未调用 gh pr merge"
fi

# 3c-1) 同名检查以最新一次为准：被取消的旧运行不挡合并，新失败仍要拦住
GUARD_OLD='{"__typename":"CheckRun","name":"snapshot-baselines","workflowName":"Snapshot Guard","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-11-18T12:50:00Z"}'
GUARD_NEW='{"__typename":"CheckRun","name":"snapshot-baselines","workflowName":"Snapshot Guard","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-11-18T12:51:00Z"}'
GUARD_FAIL='{"__typename":"CheckRun","name":"snapshot-baselines","workflowName":"Snapshot Guard","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-18T12:52:00Z"}'
FAKE_GH_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${HEAD_SHA}\",\"mergeCommit\":null,\"statusCheckRollup\":[${GUARD_OLD},${GUARD_NEW}]}"
export FAKE_GH_PR_JSON
if run_pr 0 "被新运行取代的取消检查不挡合并" "$PR" "$HEAD_SHA"; then
    expect_in "取代后按 head 合并" "--match-head-commit ${HEAD_SHA}" "$FAKE_GH_MERGE_LOG"
fi
FAKE_GH_PR_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"${HEAD_SHA}\",\"mergeCommit\":null,\"statusCheckRollup\":[${GUARD_NEW},${GUARD_FAIL}]}"
export FAKE_GH_PR_JSON
if run_pr 1 "最新一次失败仍拒绝合并" "$PR" "$HEAD_SHA"; then
    expect_in "拒绝时点名最新失败" "snapshot-baselines: FAILURE"
    merged_never "最新失败时未调用 gh pr merge"
fi

# 3d) 卡住的 Cursor 检查不挡合并
export FAKE_GH_PR_JSON="$(pr_json OPEN "$HEAD_SHA" "[$CURSOR_PENDING,${GREEN#[}" "")"
if run_pr 0 "卡住的 Cursor 检查不挡合并" "$PR" "$HEAD_SHA"; then
    expect_in "Cursor 卡住时仍按 head 合并" "--match-head-commit ${HEAD_SHA}" "$FAKE_GH_MERGE_LOG"
fi

# 4) happy path：squash 合并带 --match-head-commit，盯到 main CI 成功
export FAKE_GH_PR_JSON="$(pr_json OPEN "$HEAD_SHA" "$GREEN" "")"
export FAKE_GH_RUN_STATUS_JSON='{"status":"completed","conclusion":"success"}'
if run_pr 0 "happy path 合并并盯到 CI 成功" "$PR" "$HEAD_SHA"; then
    expect_in "happy path 用 --squash --match-head-commit 合并" "--squash --match-head-commit $HEAD_SHA" "$FAKE_GH_MERGE_LOG"
    expect_in "happy path 成功行带合并提交与 run id" "${MERGE_OID} 的 main CI 已通过（run ${RUN_ID}）"
fi

# 5) 已合并的同 head PR 跳过合并，直接盯 main
export FAKE_GH_PR_JSON="$(pr_json MERGED "$HEAD_SHA" "$GREEN" "$MERGE_OID")"
if run_pr 0 "已合并 PR 跳过合并直接盯 main" "$PR" "$HEAD_SHA"; then
    merged_never "已合并 PR 不再调用 gh pr merge"
    expect_in "已合并 PR 仍输出成功行" "${MERGE_OID} 的 main CI 已通过（run ${RUN_ID}）"
fi

# 6) main CI 失败：退出 1，提示停止合并，并调用 ci_errors.sh
export FAKE_GH_PR_JSON="$(pr_json OPEN "$HEAD_SHA" "$GREEN" "")"
export FAKE_GH_RUN_STATUS_JSON='{"status":"completed","conclusion":"failure"}'
if run_pr 1 "main CI 失败退出 1" "$PR" "$HEAD_SHA"; then
    expect_in "失败行要求停止合并先修 main" "先修 main"
    expect_in "失败行提示 ci_errors.sh" "bash scripts/ci_errors.sh ${RUN_ID}"
    expect_in "ci_errors.sh 输出失败用例名" "not ok 17 - stops a Xiaomi cloud live view after repeated frame failures instead of renegotiating"
    expect_in "main CI 失败时真的调用了 ci_errors.sh" "run view ${RUN_ID} --log-failed" "$FAKE_GH_LOG"
fi

# 7) 等待超时：退出 124，说明 PR 已合并而非合并失败
export FAKE_GH_RUN_STATUS_JSON='{"status":"in_progress","conclusion":null}'
if run_pr 124 "盯 main CI 超时退出 124" --timeout 2 --interval 1 "$PR" "$HEAD_SHA"; then
    expect_in "超时行带 run id" "run ${RUN_ID} 还没结束"
    expect_in "超时说明 PR 已合并" "PR 已合并"
    expect_in "超时前已完成合并" "--squash --match-head-commit $HEAD_SHA" "$FAKE_GH_MERGE_LOG"
fi

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 merge-pr.sh 自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ merge-pr.sh 自测通过\n'
