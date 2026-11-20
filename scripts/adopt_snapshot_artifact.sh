#!/usr/bin/env bash
# Adopt recorded UI snapshot baselines uploaded by CI (`snapshot-baselines-<head-sha>`).
#
# Usage:
#   bash scripts/adopt_snapshot_artifact.sh [--repo <owner/name>] <pr>
#
# Finds the latest CI run for the PR's current head commit, verifies that local HEAD,
# PR head, CI run headSha, and the artifact name all match the exact same 40-char SHA,
# downloads `snapshot-baselines-<head-sha>`, validates it with ci_snapshot_artifact.sh,
# installs it into Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests, and creates
# a local commit with `git commit -F`. Does NOT push; run `git push` afterward to
# trigger PR CI.
set -euo pipefail
export LC_ALL=C

usage() {
    echo "用法：bash scripts/adopt_snapshot_artifact.sh [--repo <owner/name>] <pr>" >&2
    exit 2
}

repo_opt=""
pr_number=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo_opt="$2"
            shift 2
            ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        -*)
            usage
            ;;
        *)
            if [ -z "$pr_number" ]; then
                pr_number="$1"
            else
                usage
            fi
            shift
            ;;
    esac
done

if [ -z "$pr_number" ] || ! printf '%s\n' "$pr_number" | grep -Eq '^[1-9][0-9]*$'; then
    usage
fi

python_bin=""
for cand in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python; do
    if command -v "$cand" >/dev/null 2>&1; then
        python_bin="$cand"
        break
    fi
done
if [ -z "$python_bin" ]; then
    echo "❌ 缺少 python3" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
    echo "❌ 当前目录不在 Git 仓库内" >&2
    exit 1
fi
cd "$ROOT"

REL="Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"

local_head="$(git rev-parse HEAD 2>/dev/null | tr '[:upper:]' '[:lower:]')"
if ! printf '%s\n' "$local_head" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "❌ 无法解析本地 HEAD 提交号：${local_head:-<空>}" >&2
    exit 1
fi

if ! git diff --cached --quiet; then
    echo "❌ 工作区存在已暂存的改动，请先提交或取消暂存后再运行 adopt_snapshot_artifact.sh。" >&2
    exit 1
fi

if [ -n "$(git status --porcelain -- "$REL")" ]; then
    echo "❌ 基线目录 ${REL} 存在未提交改动，请先清理后再运行 adopt_snapshot_artifact.sh。" >&2
    exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/adopt-snapshot.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

gh_fail() {
    echo "❌ gh $1 失败：$(tail -n 1 "$tmp/gh.err" 2>/dev/null || echo 未知错误)" >&2
    exit 1
}

repo="${repo_opt:-${GH_REPO:-}}"
if [ -z "$repo" ]; then
    if ! repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$tmp/gh.err")"; then
        gh_fail "repo view"
    fi
fi
if [ -z "$repo" ]; then
    echo "❌ 无法解析 GitHub 仓库名，请通过 --repo 或 GH_REPO 指定。" >&2
    exit 1
fi

if ! gh pr view "$pr_number" --repo "$repo" --json state,headRefOid,headRefName >"$tmp/pr.json" 2>"$tmp/gh.err"; then
    gh_fail "pr view"
fi

pr_info="$("$python_bin" -I - "$tmp/pr.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
state = str(doc.get("state") or "")
head = str(doc.get("headRefOid") or "").lower()
branch = str(doc.get("headRefName") or "")
print(f"{state}\t{head}\t{branch}")
PY
)"
IFS=$'\t' read -r pr_state pr_head pr_branch <<EOF
$pr_info
EOF

if [ "$pr_state" != "OPEN" ]; then
    echo "❌ PR #${pr_number} 当前状态为 ${pr_state:-未知}（仅支持 OPEN 状态的 PR）。" >&2
    exit 1
fi
if ! printf '%s\n' "$pr_head" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "❌ PR #${pr_number} 的 head 提交号异常：${pr_head:-<空>}" >&2
    exit 1
fi

if [ "$local_head" != "$pr_head" ]; then
    echo "❌ 本地 HEAD（${local_head}）与 PR #${pr_number} 的 head（${pr_head}）不一致，拒绝采纳。" >&2
    echo "   请先切换到分支 ${pr_branch:-<PR 分支>} 并同步到最新提交后再重试。" >&2
    exit 1
fi

if ! gh run list --repo "$repo" --workflow ci.yml --commit "$pr_head" --limit 20 \
    --json databaseId,workflowName,headSha,status,conclusion,createdAt,event >"$tmp/runs.json" 2>"$tmp/gh.err"; then
    gh_fail "run list"
fi

run_info="$("$python_bin" -I - "$tmp/runs.json" "$pr_head" <<'PY'
import json
import sys

runs = json.load(open(sys.argv[1], encoding="utf-8"))
target_sha = sys.argv[2].lower()
if not isinstance(runs, list):
    sys.exit(0)

ci_runs = [
    r for r in runs
    if isinstance(r, dict)
    and isinstance(r.get("databaseId"), int)
    and (r.get("workflowName") or "") == "CI"
]
matching = [r for r in ci_runs if str(r.get("headSha") or "").lower() == target_sha]
if matching:
    matching.sort(key=lambda r: (str(r.get("createdAt") or ""), r["databaseId"]), reverse=True)
    best = matching[0]
    print(f"MATCH\t{best['databaseId']}\t{best.get('status') or ''}\t{best.get('conclusion') or ''}\t{str(best.get('headSha') or '').lower()}")
elif ci_runs:
    ci_runs.sort(key=lambda r: (str(r.get("createdAt") or ""), r["databaseId"]), reverse=True)
    best = ci_runs[0]
    print(f"MISMATCH\t{best['databaseId']}\t{best.get('status') or ''}\t{best.get('conclusion') or ''}\t{str(best.get('headSha') or '').lower()}")
PY
)"

if [ -z "$run_info" ]; then
    echo "❌ 未找到 PR #${pr_number}（head ${pr_head}）对应的 CI 运行记录。" >&2
    exit 1
fi

IFS=$'\t' read -r run_match run_id run_status run_conclusion run_head <<EOF
$run_info
EOF

if [ "$run_match" != "MATCH" ] || [ "$run_head" != "$pr_head" ]; then
    echo "❌ 最新 CI 运行 ${run_id} 的 headSha（${run_head:-<空>}）与 PR #${pr_number} head（${pr_head}）不一致，拒绝采纳旧快照。" >&2
    exit 1
fi

expected_artifact="snapshot-baselines-${pr_head}"
if ! gh api "repos/${repo}/actions/runs/${run_id}/artifacts?per_page=100" >"$tmp/artifacts.json" 2>"$tmp/gh.err"; then
    gh_fail "api artifacts"
fi

artifact_status="$("$python_bin" -I - "$tmp/artifacts.json" "$expected_artifact" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
artifacts = doc.get("artifacts") if isinstance(doc, dict) else []
if not isinstance(artifacts, list):
    artifacts = []

exact = [a for a in artifacts if isinstance(a, dict) and a.get("name") == expected]
if exact:
    if any(not a.get("expired", False) for a in exact):
        print("OK")
    else:
        print("EXPIRED")
    sys.exit(0)

other = [
    str(a.get("name"))
    for a in artifacts
    if isinstance(a, dict) and str(a.get("name") or "").startswith("snapshot-baselines-")
]
if other:
    print("SHA_MISMATCH\t" + ",".join(other))
else:
    print("MISSING")
PY
)"

IFS=$'\t' read -r artifact_code artifact_detail <<EOF
$artifact_status
EOF

case "$artifact_code" in
    OK)
        ;;
    EXPIRED)
        echo "❌ CI 运行 ${run_id} 的产物 ${expected_artifact} 已过期。" >&2
        exit 1
        ;;
    SHA_MISMATCH)
        echo "❌ CI 运行 ${run_id} 里的快照产物名（${artifact_detail}）与 PR head（${expected_artifact}）不一致，拒绝采纳。" >&2
        exit 1
        ;;
    *)
        echo "❌ CI 运行 ${run_id}（状态：${run_status:-未知}/${run_conclusion:-进行中}）没有产物 ${expected_artifact}。" >&2
        echo "   请确认 macos-test 已完成快照录制，或改用 Actions → Record snapshots。" >&2
        exit 1
        ;;
esac

artifact_dir="$tmp/artifact"
mkdir -p "$artifact_dir"
echo "⬇️  下载 PR #${pr_number} CI 运行 ${run_id} 的快照产物 ${expected_artifact}..."
if ! gh run download "$run_id" --repo "$repo" --name "$expected_artifact" --dir "$artifact_dir" >"$tmp/download.log" 2>"$tmp/gh.err"; then
    gh_fail "run download"
fi

echo "🔍 校验快照产物..."
bash "$SCRIPT_DIR/ci_snapshot_artifact.sh" validate "$artifact_dir"

echo "📦 安装快照基线到 ${REL}..."
bash "$SCRIPT_DIR/ci_snapshot_artifact.sh" install "$artifact_dir" "$REL"

git add -A -- "$REL"
files="$(git diff --cached --name-only -- "$REL")"
if [ -z "$files" ]; then
    echo "ℹ️  快照基线与当前工作区一致，没有需要提交的变化。"
    exit 0
fi

count="$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
msg="$tmp/commit-msg.txt"
printf '%s\n' "$files" | bash "$SCRIPT_DIR/ci_commit_snapshot_baselines.sh" message >"$msg"
printf '\nAdopted from PR #%s CI run %s (%s).\n' "$pr_number" "$run_id" "$expected_artifact" >>"$msg"

git commit -F "$msg"
new_sha="$(git rev-parse --short HEAD)"
echo "✅ 已采纳 ${count} 张快照基线并本地提交（${new_sha}）。"
echo "   确认无误后执行 git push 触发 PR CI。"
