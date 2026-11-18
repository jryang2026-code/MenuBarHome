#!/usr/bin/env bash
# Squash-merge a pull request at an exact head, then watch the CI run it starts on main.
#
# Usage: bash scripts/merge-pr.sh [--timeout <sec>] [--interval <sec>] <pr> <head-sha>
# Defaults: timeout 3600s, interval 30s. Needs `gh` logged in to the repository.
# Re-runnable: an already-merged PR whose head matches <head-sha> skips the merge
# and only watches main. Refuses to merge unless every statusCheckRollup entry is
# finished and SUCCESS/NEUTRAL/SKIPPED (Codex review state is not a gate here).
# An unfinished `Cursor ...` check is ignored: those reviewers stall when their
# quota runs out, and at least one other check must still be present.
# Exit codes: 0 = main CI passed; 1 = refused or main CI failed; 124 = watch
# timeout (the PR stays merged — keep watching with `gh run view <run-id>`).
set -euo pipefail
export LC_ALL=C

usage() {
    echo "用法：bash scripts/merge-pr.sh [--timeout <sec>] [--interval <sec>] <pr> <head-sha>" >&2
    exit 2
}

timeout_sec=3600
interval_sec=30
pr_number=""
head_sha=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --timeout)
            [ "$#" -ge 2 ] || usage
            timeout_sec="$2"
            shift 2
            ;;
        --interval)
            [ "$#" -ge 2 ] || usage
            interval_sec="$2"
            shift 2
            ;;
        -*)
            usage
            ;;
        *)
            if [ -z "$pr_number" ]; then
                pr_number="$1"
            elif [ -z "$head_sha" ]; then
                head_sha="$1"
            else
                usage
            fi
            shift
            ;;
    esac
done
if [ -z "$pr_number" ] || ! printf '%s\n' "$pr_number" | grep -Eq '^[0-9]+$'; then
    usage
fi
if [ -z "$head_sha" ] || ! printf '%s\n' "$head_sha" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
    usage
fi
if ! printf '%s\n' "$timeout_sec" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
    || ! printf '%s\n' "$interval_sec" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    usage
fi
head_sha="$(printf '%s\n' "$head_sha" | tr '[:upper:]' '[:lower:]')"

python_bin=""
for cand in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python; do
    if command -v "$cand" >/dev/null 2>&1; then
        python_bin="$cand"
        break
    fi
done
if [ -z "$python_bin" ]; then
    echo "缺少 python3" >&2
    exit 1
fi

json_field() { # <file> <python-expr over doc>
    "$python_bin" -I -c 'import json,sys; doc = json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$1" "$2"
}
monotonic_now() { "$python_bin" -I -c 'import time; print(f"{time.monotonic():.3f}")'; }
reached_deadline() { # <start-epoch> <seconds>
    "$python_bin" -I -c 'import sys,time; print("1" if time.monotonic() - float(sys.argv[1]) >= float(sys.argv[2]) else "0")' "$1" "$2"
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-pr.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
gh_fail() {
    echo "❌ gh $1 失败：$(tail -n 1 "$tmp/gh.err" 2>/dev/null || echo 未知错误)" >&2
    exit 1
}

if ! gh pr view "$pr_number" --json state,headRefOid,mergeCommit,statusCheckRollup >"$tmp/pr.json" 2>"$tmp/gh.err"; then
    gh_fail "pr view"
fi
pr_state="$(json_field "$tmp/pr.json" 'doc.get("state") or ""')"
pr_head="$(json_field "$tmp/pr.json" 'doc.get("headRefOid") or ""')"
if [ "$pr_head" != "$head_sha" ]; then
    echo "❌ PR #${pr_number} 的 head 是 ${pr_head:-未知}，与指定的 ${head_sha} 不一致；请核对 head 后重试。" >&2
    exit 1
fi

merge_commit=""
if [ "$pr_state" = "MERGED" ]; then
    merge_commit="$(json_field "$tmp/pr.json" '(doc.get("mergeCommit") or {}).get("oid") or ""')"
    echo "ℹ️  PR #${pr_number} 已合并（head ${head_sha}），跳过合并，直接盯 main CI。"
else
    if [ "$pr_state" != "OPEN" ]; then
        echo "❌ PR #${pr_number} 的状态是 ${pr_state:-未知}，不是 OPEN，不能合并。" >&2
        exit 1
    fi
    check_gate=0
    "$python_bin" -I - "$tmp/pr.json" <<'PY' || check_gate=$?
import json
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")

checks = json.load(open(sys.argv[1], encoding="utf-8")).get("statusCheckRollup") or []
checks = [check for check in checks if isinstance(check, dict)]


def check_name(check):
    return check.get("name") or check.get("context") or "(未命名检查)"


def check_identity(check):
    return (check.get("workflowName") or "", check_name(check))


# A newer run of the same check supersedes older attempts, such as a Snapshot Guard run
# cancelled when a label lands right after the PR opens.
latest = {}
for index, check in enumerate(checks):
    key = check_identity(check)
    rank = (check.get("startedAt") or "", index)
    if key not in latest or rank >= latest[key][0]:
        latest[key] = (rank, check)
checks = [entry[1] for entry in latest.values()]

has_ci_check = any(not check_name(check).startswith("Cursor ") for check in checks)
bad = [] if has_ci_check else ["  （还没有任何检查登记）"]
for check in checks:
    name = check_name(check)
    if check.get("status") is None and "state" in check:
        if check.get("state") != "SUCCESS":
            bad.append(f"  {name}: {check.get('state') or '未知状态'}")
        continue
    status = check.get("status") or "未开始"
    if status != "COMPLETED":
        if not name.startswith("Cursor "):
            bad.append(f"  {name}: {status}")
    elif check.get("conclusion") not in ("SUCCESS", "NEUTRAL", "SKIPPED"):
        bad.append(f"  {name}: {check.get('conclusion') or '无结论'}")
if bad:
    print("❌ PR 的检查未全部完成且成功，拒绝合并：", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    print("先等检查结束，或修复失败项后再合并（Codex 审查状态不在此门禁内）。", file=sys.stderr)
    sys.exit(1)
PY
    if [ "$check_gate" -ne 0 ]; then
        exit 1
    fi
    if ! gh pr merge "$pr_number" --squash --match-head-commit "$head_sha" >"$tmp/merge.log" 2>&1 </dev/null; then
        echo "❌ gh pr merge 失败：" >&2
        sed 's/^/    /' "$tmp/merge.log" >&2 || true
        exit 1
    fi
    if ! gh pr view "$pr_number" --json mergeCommit >"$tmp/merged.json" 2>"$tmp/gh.err"; then
        gh_fail "pr view (mergeCommit)"
    fi
    merge_commit="$(json_field "$tmp/merged.json" '(doc.get("mergeCommit") or {}).get("oid") or ""')"
fi

if [ -z "$merge_commit" ]; then
    echo "❌ 读不到合并提交（mergeCommit.oid 为空），无法盯 main CI。" >&2
    exit 1
fi
echo "🔀 合并提交：${merge_commit}"

run_id=""
appear_start="$(monotonic_now)"
while true; do
    if gh run list --branch main --workflow CI --commit "$merge_commit" --limit 5 \
        --json databaseId,workflowName,headSha,headBranch >"$tmp/runs.json" 2>/dev/null; then
        run_id="$("$python_bin" -I - "$tmp/runs.json" "$merge_commit" <<'PY'
import json
import sys

try:
    runs = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    sys.exit(0)
for run in runs if isinstance(runs, list) else []:
    if (
        isinstance(run, dict)
        and run.get("headSha") == sys.argv[2]
        and run.get("workflowName") == "CI"
        and (run.get("headBranch") or "") == "main"
        and isinstance(run.get("databaseId"), int)
    ):
        print(run["databaseId"])
        break
PY
)"
    fi
    if [ -n "$run_id" ]; then
        break
    fi
    if [ "$(reached_deadline "$appear_start" 120)" = "1" ]; then
        echo "❌ 2 分钟内没等到 main 上 ${merge_commit} 的 CI run；请手动确认：gh run list --branch main --commit ${merge_commit}" >&2
        exit 1
    fi
    sleep 10
done

echo "👀 盯 main CI run ${run_id}（每 ${interval_sec}s 查一次，最多 ${timeout_sec}s）..."
start_epoch="$(monotonic_now)"
while true; do
    if gh run view "$run_id" --json status,conclusion >"$tmp/run.json" 2>/dev/null; then
        # `gh run` reports lowercase values, unlike the uppercase statusCheckRollup.
        if [ "$(json_field "$tmp/run.json" 'doc.get("status") or ""')" = "completed" ]; then
            run_conclusion="$(json_field "$tmp/run.json" 'doc.get("conclusion") or ""')"
            if [ "$run_conclusion" = "success" ]; then
                echo "✅ 合并提交 ${merge_commit} 的 main CI 已通过（run ${run_id}）。"
                exit 0
            fi
            echo "❌ main CI 结论是 ${run_conclusion}（合并提交 ${merge_commit}，run ${run_id}）：停止合并下一个 PR，先修 main。" >&2
            echo "    bash scripts/ci_errors.sh ${run_id}" >&2
            bash "$(dirname "$0")/ci_errors.sh" "$run_id" || true
            exit 1
        fi
    fi
    if [ "$(reached_deadline "$start_epoch" "$timeout_sec")" = "1" ]; then
        echo "⏳ 等待超时（${timeout_sec}s）：main CI run ${run_id} 还没结束。PR 已合并，这不是合并失败；继续盯：gh run view ${run_id}" >&2
        exit 124
    fi
    sleep "$interval_sec"
done
