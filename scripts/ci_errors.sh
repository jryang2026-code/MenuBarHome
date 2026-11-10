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
gh run view "$run" --json jobs >"$tmp/jobs.json"
gh run view "$run" --log-failed >"$tmp/log.txt" || true

python3 -I - "$run" "$tmp/repo.json" "$tmp/jobs.json" "$tmp/log.txt" <<'PY'
import json
import re
import subprocess
import sys

run, repo_path, jobs_path, log_path = sys.argv[1:5]
repo = json.load(open(repo_path, encoding="utf-8"))["nameWithOwner"]
jobs = json.load(open(jobs_path, encoding="utf-8"))["jobs"]
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
    proc = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", url],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "annotation request failed").strip()
        return [{"annotation_level": "failure", "message": one_line(detail) or "annotation request failed"}]
    if not proc.stdout.strip():
        return []
    return flatten_pages(json.loads(proc.stdout))


infra = []
annotations = []
for job in jobs:
    conclusion = job.get("conclusion")
    if conclusion == "cancelled" and not (job.get("steps") or []):
        infra.append(job.get("name") or str(job.get("databaseId")))
    if conclusion in QUIET:
        continue
    for ann in fetch_annotations(job.get("databaseId")):
        annotations.append(
            (
                job.get("name") or "",
                ann.get("annotation_level") or "",
                one_line(ann.get("message")),
            )
        )

sections = []
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
