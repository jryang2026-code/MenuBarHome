#!/usr/bin/env bash
# Adopt recorded UI snapshot baselines uploaded by CI (`snapshot-baselines-<head-sha>`).
#
# Usage:
#   bash scripts/adopt_snapshot_artifact.sh [--repo <owner/name>] [--run <run-id>] <pr>
#
# Verifies PR provenance (OPEN, same repository, local HEAD == PR head), verifies CI
# workflow identity (ci.yml workflow ID + path), run source repository (non-fork),
# event type (`pull_request` bound to the PR number, or `workflow_dispatch` on the
# PR's branch), and head SHA. When --run is omitted, scans provenance-valid runs for
# this head SHA newest-first and selects the latest one that has a non-expired
# matching `snapshot-baselines-<head-sha>` artifact.
#
# Downloads the artifact strictly by artifact ID after checking the archive size
# limit, safely unpacks and fully decodes every PNG before touching the working tree,
# verifies completeness against existing baselines and SnapshotTests.swift, installs,
# and creates a local commit with `git commit -F`. Does NOT push.
set -euo pipefail
export LC_ALL=C

MAX_ARCHIVE_BYTES=67108864

usage() {
    echo "用法：bash scripts/adopt_snapshot_artifact.sh [--repo <owner/name>] [--run <run-id>] <pr>" >&2
    exit 2
}

repo_opt=""
explicit_run_id=""
pr_number=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo_opt="$2"
            shift 2
            ;;
        --run)
            [ "$#" -ge 2 ] || usage
            explicit_run_id="$2"
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
if [ -n "$explicit_run_id" ] && ! printf '%s\n' "$explicit_run_id" | grep -Eq '^[1-9][0-9]*$'; then
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

if ! gh pr view "$pr_number" --repo "$repo" \
    --json state,headRefOid,headRefName,baseRefName,isCrossRepository,headRepository,headRepositoryOwner \
    >"$tmp/pr.json" 2>"$tmp/gh.err"; then
    gh_fail "pr view"
fi

pr_info="$("$python_bin" -I - "$tmp/pr.json" "$repo" <<'PY'
import json
import sys

def field(val):
    return str(val or "").replace("\x1f", " ").replace("\r", " ").replace("\n", " ")

doc = json.load(open(sys.argv[1], encoding="utf-8"))
expected_repo = sys.argv[2]

state = field(doc.get("state"))
head = field(doc.get("headRefOid")).lower()
branch = field(doc.get("headRefName"))
base_ref = field(doc.get("baseRefName"))

is_cross = doc.get("isCrossRepository")
head_repo_obj = doc.get("headRepository") if isinstance(doc.get("headRepository"), dict) else {}
head_owner_obj = doc.get("headRepositoryOwner") if isinstance(doc.get("headRepositoryOwner"), dict) else {}

head_repo_full = field(head_repo_obj.get("nameWithOwner"))
if not head_repo_full:
    owner = field(head_owner_obj.get("login"))
    name = field(head_repo_obj.get("name"))
    if owner and name:
        head_repo_full = f"{owner}/{name}"

same_repo = "1"
if is_cross is not False:
    same_repo = "0"
elif not head_repo_full or head_repo_full.lower() != expected_repo.lower():
    same_repo = "0"

print("\x1f".join([state, head, branch, base_ref, same_repo, head_repo_full]))
PY
)"
IFS=$'\x1f' read -r pr_state pr_head pr_branch pr_base_ref pr_same_repo pr_head_repo <<EOF
$pr_info
EOF

if [ "$pr_state" != "OPEN" ]; then
    echo "❌ PR #${pr_number} 当前状态为 ${pr_state:-未知}（仅支持 OPEN 状态的 PR）。" >&2
    exit 1
fi
if [ "$pr_same_repo" != "1" ]; then
    echo "❌ PR #${pr_number} 来自 fork 或未知仓库（${pr_head_repo:-未知} != ${repo}），拒绝采纳其快照产物。" >&2
    exit 1
fi
if ! printf '%s\n' "$pr_head" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "❌ PR #${pr_number} 的 head 提交号异常：${pr_head:-<空>}" >&2
    exit 1
fi
if [ -z "$pr_branch" ]; then
    echo "❌ PR #${pr_number} 缺少源分支名（headRefName）。" >&2
    exit 1
fi

if [ "$local_head" != "$pr_head" ]; then
    echo "❌ 本地 HEAD（${local_head}）与 PR #${pr_number} 的 head（${pr_head}）不一致，拒绝采纳。" >&2
    echo "   请先切换到分支 ${pr_branch} 并同步到最新提交后再重试。" >&2
    exit 1
fi

if ! gh api "repos/${repo}/actions/workflows/ci.yml" >"$tmp/workflow.json" 2>"$tmp/gh.err"; then
    gh_fail "api workflows/ci.yml"
fi

ci_workflow_id="$("$python_bin" -I - "$tmp/workflow.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
wf_id = doc.get("id")
wf_path = str(doc.get("path") or "")
if not isinstance(wf_id, int) or wf_id <= 0 or wf_path != ".github/workflows/ci.yml":
    print(f"❌ 无法确认 CI 工作流身份（id={wf_id!r}, path={wf_path!r}）。", file=sys.stderr)
    sys.exit(1)
print(wf_id)
PY
)"

if [ -n "$explicit_run_id" ]; then
    if ! gh api "repos/${repo}/actions/runs/${explicit_run_id}" >"$tmp/runs.json" 2>"$tmp/gh.err"; then
        gh_fail "api runs/${explicit_run_id}"
    fi
    runs_mode="single"
else
    if ! gh api "repos/${repo}/actions/workflows/ci.yml/runs?head_sha=${pr_head}&per_page=30" >"$tmp/runs.json" 2>"$tmp/gh.err"; then
        gh_fail "api workflows/ci.yml/runs"
    fi
    runs_mode="list"
fi

candidates_file="$tmp/candidates.tsv"
"$python_bin" -I - "$tmp/runs.json" "$runs_mode" "$repo" "$ci_workflow_id" "$pr_number" "$pr_head" "$pr_branch" "$pr_base_ref" >"$candidates_file" <<'PY'
import json
import sys

runs_path, mode, repo, wf_id_str, pr_num_str, pr_head, pr_branch, pr_base_ref = sys.argv[1:9]
ci_wf_id = int(wf_id_str)
pr_num = int(pr_num_str)
repo_lower = repo.lower()
pr_head_lower = pr_head.lower()

def field(val):
    return str(val or "").replace("\x1f", " ").replace("\r", " ").replace("\n", " ")

def check_run(run):
    if not isinstance(run, dict):
        return False, "INVALID", "CI 运行记录格式异常"
    run_id = run.get("id")
    if not isinstance(run_id, int) or run_id <= 0:
        return False, "INVALID", "CI 运行缺少有效 id"
    wf_id = run.get("workflow_id")
    wf_path = str(run.get("path") or "")
    if wf_id != ci_wf_id or wf_path != ".github/workflows/ci.yml":
        return (
            False,
            "WORKFLOW_MISMATCH",
            f"CI 运行 {run_id} 的 workflow 不符（workflow_id={wf_id}, path={wf_path or '<空>'}，期望 CI workflow_id={ci_wf_id} / .github/workflows/ci.yml）",
        )
    run_head = str(run.get("head_sha") or "").lower()
    if run_head != pr_head_lower:
        return (
            False,
            "HEAD_SHA_MISMATCH",
            f"CI 运行 {run_id} 的 headSha（{run_head or '<空>'}）与 PR #{pr_num} head（{pr_head_lower}）不一致",
        )
    head_repo_obj = run.get("head_repository")
    head_repo = str(head_repo_obj.get("full_name") or "") if isinstance(head_repo_obj, dict) else ""
    if not head_repo or head_repo.lower() != repo_lower:
        return (
            False,
            "FORK_SOURCE",
            f"CI 运行 {run_id} 的 head_repository（{head_repo or '<空>'}）不是本仓库（{repo}），拒绝 fork 来源",
        )
    event = str(run.get("event") or "")
    if event == "pull_request":
        prs = run.get("pull_requests")
        if not isinstance(prs, list):
            prs = []
        matched = [p for p in prs if isinstance(p, dict) and p.get("number") == pr_num]
        if not matched:
            found_nums = [str(p.get("number")) for p in prs if isinstance(p, dict) and p.get("number") is not None]
            found_str = ",".join(found_nums) if found_nums else "<无>"
            return (
                False,
                "PR_MISMATCH",
                f"CI 运行 {run_id} 关联的 PR 号（{found_str}）与目标 PR #{pr_num} 不符",
            )
        if pr_base_ref:
            base_mismatch = False
            for p in matched:
                base_obj = p.get("base")
                if isinstance(base_obj, dict) and base_obj.get("ref") and base_obj.get("ref") != pr_base_ref:
                    base_mismatch = True
                    break
            if base_mismatch:
                return (
                    False,
                    "PR_BASE_MISMATCH",
                    f"CI 运行 {run_id} 关联的 PR #{pr_num} 目标分支与当前 PR base（{pr_base_ref}）不符",
                )
    elif event == "workflow_dispatch":
        run_branch = str(run.get("head_branch") or "")
        if not run_branch or run_branch == "main" or run_branch != pr_branch:
            return (
                False,
                "BRANCH_MISMATCH",
                f"workflow_dispatch 运行 {run_id} 的分支（{run_branch or '<空>'}）与 PR #{pr_num} 分支（{pr_branch}）不符",
            )
    else:
        return (
            False,
            "EVENT_NOT_ALLOWED",
            f"CI 运行 {run_id} 的事件类型为 {event or '<空>'}（仅允许 pull_request 或 workflow_dispatch）",
        )
    return True, "OK", ""

doc = json.load(open(runs_path, encoding="utf-8"))
if mode == "single":
    raw_runs = [doc]
else:
    raw_runs = doc.get("workflow_runs") if isinstance(doc, dict) else []
    if not isinstance(raw_runs, list):
        raw_runs = []

valid = []
rejected = []
for r in raw_runs:
    ok, code, msg = check_run(r)
    sort_key = (str(r.get("created_at") or ""), r.get("id") if isinstance(r.get("id"), int) else 0) if isinstance(r, dict) else ("", 0)
    if ok:
        valid.append((sort_key, r))
    else:
        rejected.append((sort_key, code, msg))

if not valid:
    if not rejected:
        print(f"❌ 未找到 PR #{pr_num}（head {pr_head_lower}）对应的 CI 运行记录。", file=sys.stderr)
    else:
        rejected.sort(key=lambda item: item[0], reverse=True)
        print(f"❌ {rejected[0][2]}，拒绝采纳。", file=sys.stderr)
    sys.exit(1)

valid.sort(key=lambda item: item[0], reverse=True)
for _, r in valid:
    print("\x1f".join([
        field(r["id"]),
        field(r.get("status")),
        field(r.get("conclusion")),
        field(r.get("event")),
    ]))
PY

expected_artifact="snapshot-baselines-${pr_head}"
selected_run_id=""
selected_run_status=""
selected_run_conclusion=""
selected_artifact_id=""
selected_artifact_size=""
diag_code=""
diag_run_id=""
diag_run_status=""
diag_run_conclusion=""
diag_detail=""
checked_runs=0

while IFS=$'\x1f' read -r cand_id cand_status cand_conclusion cand_event; do
    [ -n "$cand_id" ] || continue
    checked_runs=$((checked_runs + 1))
    if ! gh api "repos/${repo}/actions/runs/${cand_id}/artifacts?per_page=100" >"$tmp/artifacts.json" 2>"$tmp/gh.err"; then
        gh_fail "api runs/${cand_id}/artifacts"
    fi

    artifact_res="$("$python_bin" -I - "$tmp/artifacts.json" "$expected_artifact" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
artifacts = doc.get("artifacts") if isinstance(doc, dict) else []
if not isinstance(artifacts, list):
    artifacts = []

exact = [a for a in artifacts if isinstance(a, dict) and a.get("name") == expected]
if exact:
    live = [
        a for a in exact
        if not a.get("expired", False) and isinstance(a.get("id"), int) and a["id"] > 0
    ]
    if live:
        live.sort(key=lambda a: (str(a.get("created_at") or ""), a["id"]), reverse=True)
        best = live[0]
        size = best.get("size_in_bytes")
        size_str = str(size) if isinstance(size, int) else "-1"
        print("\x1f".join(["OK", str(best["id"]), size_str]))
    else:
        print("EXPIRED\x1f\x1f")
    sys.exit(0)

other = [
    str(a.get("name"))
    for a in artifacts
    if isinstance(a, dict) and str(a.get("name") or "").startswith("snapshot-baselines-")
]
if other:
    print("SHA_MISMATCH\x1f" + ",".join(other) + "\x1f")
else:
    print("MISSING\x1f\x1f")
PY
)"

    IFS=$'\x1f' read -r art_code art_f1 art_f2 <<EOF
$artifact_res
EOF

    if [ "$art_code" = "OK" ]; then
        selected_run_id="$cand_id"
        selected_run_status="$cand_status"
        selected_run_conclusion="$cand_conclusion"
        selected_artifact_id="$art_f1"
        selected_artifact_size="$art_f2"
        break
    fi

    if [ -z "$diag_code" ] || { [ "$diag_code" = "MISSING" ] && [ "$art_code" != "MISSING" ]; }; then
        diag_code="$art_code"
        diag_run_id="$cand_id"
        diag_run_status="$cand_status"
        diag_run_conclusion="$cand_conclusion"
        diag_detail="$art_f1"
    fi
done <"$candidates_file"

if [ -z "$selected_run_id" ]; then
    case "$diag_code" in
        EXPIRED)
            echo "❌ CI 运行 ${diag_run_id} 的产物 ${expected_artifact} 已过期。" >&2
            exit 1
            ;;
        SHA_MISMATCH)
            echo "❌ CI 运行 ${diag_run_id} 里的快照产物名（${diag_detail}）与 PR head（${expected_artifact}）不一致，拒绝采纳。" >&2
            exit 1
            ;;
        *)
            echo "❌ 检查了 ${checked_runs} 条来源合法的 CI 运行（最新：${diag_run_id}，状态：${diag_run_status:-未知}/${diag_run_conclusion:-进行中}），均未找到产物 ${expected_artifact}。" >&2
            echo "   请确认 macos-test 已完成快照录制，或使用 --run <id> 指定运行，或改用 Actions → Record snapshots。" >&2
            exit 1
            ;;
    esac
fi

if ! printf '%s\n' "$selected_artifact_size" | grep -Eq '^[1-9][0-9]*$' || [ "$selected_artifact_size" -gt "$MAX_ARCHIVE_BYTES" ]; then
    echo "❌ 产物 ${expected_artifact}（artifact ID ${selected_artifact_id}）归档大小异常或超限（${selected_artifact_size} 字节，上限 ${MAX_ARCHIVE_BYTES} 字节），拒绝下载。" >&2
    exit 1
fi

archive_zip="$tmp/artifact.zip"
echo "⬇️  按 artifact ID ${selected_artifact_id} 下载 PR #${pr_number} CI 运行 ${selected_run_id}（${selected_run_status:-未知}/${selected_run_conclusion:-进行中}）的快照产物 ${expected_artifact}..."
if ! gh api "repos/${repo}/actions/artifacts/${selected_artifact_id}/zip" >"$archive_zip" 2>"$tmp/gh.err"; then
    gh_fail "api artifacts/${selected_artifact_id}/zip"
fi

artifact_dir="$tmp/artifact"
mkdir -p "$artifact_dir"
echo "📦 安全解包快照归档..."
bash "$SCRIPT_DIR/ci_snapshot_artifact.sh" extract-zip "$archive_zip" "$artifact_dir"

echo "🔍 校验快照产物..."
bash "$SCRIPT_DIR/ci_snapshot_artifact.sh" validate "$artifact_dir"

echo "🧩 安装快照基线到 ${REL}..."
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
printf '\nAdopted from PR #%s CI run %s (artifact %s, %s).\n' \
    "$pr_number" "$selected_run_id" "$selected_artifact_id" "$expected_artifact" >>"$msg"

git commit -F "$msg"
new_sha="$(git rev-parse --short HEAD)"
echo "✅ 已采纳 ${count} 张快照基线并本地提交（${new_sha}）。"
echo "   确认无误后执行 git push 触发 PR CI。"
