#!/usr/bin/env bash
# Print the failure lines of a GitHub Actions run, plus check-run annotations.
#
# Usage: bash scripts/ci_errors.sh <run-id>
# Needs `gh` logged in to the repository.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "用法：bash scripts/ci_errors.sh <run-id>" >&2
    exit 2
fi
run="$1"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-errors.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
gh repo view --json nameWithOwner >"$tmp/repo.json"
gh run view "$run" --json jobs,event,headBranch,headSha,createdAt,databaseId,workflowName >"$tmp/run.json" || {
    echo "❌ 读不到 run ${run}（id 不对，或 gh 未登录/网络失败）" >&2
    exit 1
}
gh run view "$run" --log-failed >"$tmp/log.txt" || true
branch="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("headBranch") or "")' "$tmp/run.json")"
workflow="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("workflowName") or "")' "$tmp/run.json")"
if [ -n "$branch" ]; then
    if [ -n "$workflow" ]; then
        gh run list --branch "$branch" --workflow "$workflow" --limit 30 --json databaseId,createdAt,headSha,event,headBranch >"$tmp/runs.json" || printf '[]\n' >"$tmp/runs.json"
    else
        gh run list --branch "$branch" --limit 30 --json databaseId,createdAt,headSha,event,headBranch >"$tmp/runs.json" || printf '[]\n' >"$tmp/runs.json"
    fi
else
    printf '[]\n' >"$tmp/runs.json"
fi

gh_bin="$(command -v gh)"
python3 -I - "$run" "$tmp/repo.json" "$tmp/run.json" "$tmp/log.txt" "$tmp/runs.json" "$gh_bin" <<'PY'
import json
import os
import re
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")

run, repo_path, run_path, log_path, runs_path, gh_bin = sys.argv[1:7]
repo = json.load(open(repo_path, encoding="utf-8"))["nameWithOwner"]
run_doc = json.load(open(run_path, encoding="utf-8"))
jobs = run_doc["jobs"]
runs = json.load(open(runs_path, encoding="utf-8"))
log = open(log_path, encoding="utf-8", errors="replace").read()

QUIET = {"success", "skipped", "", None}
prefix = re.compile(r"^[^\t]*\t[^\t]*\t[0-9T:.Z-]+ ?")
error_line = re.compile(r"error:|✘ (Test|Suite)|Test run with .* failed|##\[error\]")
ansi = re.compile(r"\x1b\[[0-9;]*m")


def one_line(text):
    return " ".join((text or "").split())


def flatten_pages(payload):
    if not isinstance(payload, list):
        return []
    items = []
    for page in payload:
        if isinstance(page, list):
            items.extend(entry for entry in page if isinstance(entry, dict))
        elif isinstance(page, dict):
            items.append(page)
    return items


def fetch_annotations(job_id):
    url = f"repos/{repo}/check-runs/{job_id}/annotations?per_page=100"
    cmd = (
        ["bash", gh_bin, "api", "--paginate", "--slurp", url]
        if os.name == "nt" and not gh_bin.lower().endswith((".exe", ".cmd", ".bat"))
        else [gh_bin, "api", "--paginate", "--slurp", url]
    )
    proc = subprocess.run(
        cmd,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "annotation request failed").strip()
        return [{"annotation_level": "failure", "message": one_line(detail) or "annotation request failed"}]
    if not proc.stdout.strip():
        return []
    return flatten_pages(json.loads(proc.stdout))


def has_newer_run(meta, candidates):
    created = meta.get("createdAt") or ""
    if not created or not isinstance(candidates, list):
        return False
    branch = meta.get("headBranch") or ""
    sha = meta.get("headSha") or ""
    me = meta.get("databaseId")
    for other in candidates:
        if not isinstance(other, dict) or other.get("databaseId") == me:
            continue
        if (other.get("createdAt") or "") <= created:
            continue
        # main groups concurrency by commit, so the next commit does not cancel this run.
        if branch == "main" and other.get("headSha") != sha:
            continue
        return True
    return False


newer = has_newer_run(run_doc, runs)
superseded = []
infra = []
annotations = []
for job in jobs:
    conclusion = job.get("conclusion")
    job_anns = []
    if conclusion not in QUIET:
        job_anns = fetch_annotations(job.get("databaseId"))
        for ann in job_anns:
            annotations.append(
                (
                    job.get("name") or "",
                    ann.get("annotation_level") or "",
                    one_line(ann.get("message")),
                )
            )
    if conclusion == "cancelled" and not (job.get("steps") or []):
        text = " ".join((ann.get("message") or "") for ann in job_anns).lower()
        name = job.get("name") or str(job.get("databaseId"))
        if newer or "higher priority waiting request" in text:
            superseded.append(name)
        else:
            infra.append(name)

sections = []
if superseded:
    sections.append("=== cancelled (superseded)")
    sections.extend(superseded)
if infra:
    sections.append("=== 取消且 steps=0（runner 未分配，基础设施，不是代码）")
    sections.extend(infra)
if annotations:
    sections.append("=== annotations")
    sections.extend(f"{name}\t{level}\t{message}" for name, level, message in annotations)

if log.strip():
    seen_jobs = []
    known = set()
    errors = []
    known_errors = set()
    for line in log.splitlines():
        if not line:
            continue
        job_name = line.split("\t", 1)[0]
        if job_name not in known:
            known.add(job_name)
            seen_jobs.append(job_name)
        body = ansi.sub("", prefix.sub("", line, count=1))
        if error_line.search(body) and body not in known_errors:
            known_errors.add(body)
            errors.append(body)
    sections.append("=== 失败的 job")
    sections.extend(seen_jobs)
    sections.append("=== 错误与失败用例")
    sections.extend(errors[:60])

if sections:
    print("\n".join(sections))
    sys.exit(0)

print(f"没有失败日志：{run}（可能仍在运行、已成功，或 run id 不存在）")
sys.exit(1)
PY
