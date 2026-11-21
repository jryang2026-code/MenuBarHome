#!/usr/bin/env bash
# Print what actually failed in one GitHub Actions CI run, as a short summary.
#
# Usage: bash scripts/ci-failures.sh <run-id|pr-number>
#   A number of 8 or more digits is a run id. A shorter number is a PR number: the newest CI
#   run on that PR's head is used.
#
# The whole point is token cost: the job log is 15k-30k lines of build noise, and reading it
# needs `--allow-escape-sequences` plus a `✘` grep. This script keeps the log in a temp file
# and prints at most 60 lines:
#   - the failing jobs,
#   - failing Swift Testing cases (`✘ Test "..." recorded an issue at File.swift:line`),
#   - failing node test cases (TAP `not ok`),
#   - the first line of each distinct compile error,
#   - process crash markers,
#   - snapshot cases whose pixels did not match.
# Every failing case is then matched against the open issues (title or body containing the case
# name or its file name). A case-name hit is tagged `[已知间歇 #N]`; a file-only hit gets the weaker
# `[同文件 issue #N，需核对]`.
#
# A run that failed and was later rerun green (`gh run rerun --failed`) keeps both attempts: the
# newest failing attempt is the one reported here.
#
# The log is read with `gh run view --log-failed`, whose escape sequences arrive as printable
# `^[[0m` text (and as raw ESC bytes with `--allow-escape-sequences`). Both forms are stripped,
# so this works on any gh version.
#
# Needs `gh` logged in to the repository.
set -euo pipefail

usage() {
    echo "用法：bash scripts/ci-failures.sh <run-id|pr-number>" >&2
    echo "  8 位及以上的数字按 run id；更短的数字按 PR 号（取该 PR head 上最新的 CI 运行）。" >&2
    exit 2
}

target="${1:-}"
[ "$#" -le 1 ] || usage
[ -n "$target" ] || usage
case "$target" in
    *[!0-9]*) usage ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-failures.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

run="$target"
pr_note=""
if [ "${#target}" -lt 8 ]; then
    gh pr view "$target" --json headRefOid,number >"$tmp/pr.json" || {
        echo "❌ 读不到 PR ${target}（gh 未登录，或 PR 号不对）" >&2
        exit 1
    }
    head_sha="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("headRefOid") or "")' "$tmp/pr.json")"
    if [ -z "$head_sha" ]; then
        echo "❌ PR ${target} 没有 head SHA" >&2
        exit 1
    fi
    if ! gh run list --commit "$head_sha" --workflow CI --limit 20 \
        --json databaseId,createdAt,conclusion >"$tmp/runs.json" 2>"$tmp/runs.err"; then
        echo "❌ 查不到 PR ${target}（${head_sha}）的 CI 运行" >&2
        sed 's/^/  /' "$tmp/runs.err" >&2
        exit 1
    fi
    run="$(python3 -I -c '
import json, sys
runs = json.load(open(sys.argv[1], encoding="utf-8"))
runs = [r for r in runs if isinstance(r, dict) and r.get("databaseId")]
runs.sort(key=lambda r: r.get("createdAt") or "", reverse=True)
print(runs[0]["databaseId"] if runs else "")
' "$tmp/runs.json")"
    if [ -z "$run" ]; then
        echo "❌ PR ${target}（${head_sha}）还没有 CI 运行" >&2
        exit 1
    fi
    pr_note="PR #${target} → "
fi

run_attempts="$(gh api "repos/{owner}/{repo}/actions/runs/${run}" --jq '.run_attempt' 2>/dev/null || true)"
case "$run_attempts" in
    '' | *[!0-9]*) run_attempts=1 ;;
esac
[ "$run_attempts" -ge 1 ] || run_attempts=1

attempt=""
attempt_json=""
a="$run_attempts"
while [ "$a" -ge 1 ]; do
    if gh run view "$run" --attempt "$a" \
        --json jobs,conclusion,displayTitle,headBranch,workflowName,url >"$tmp/attempt-${a}.json" 2>/dev/null; then
        if python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if any(job.get("conclusion") not in ("success", "skipped", "cancelled", None, "")
                          for job in doc.get("jobs") or []) else 1)
' "$tmp/attempt-${a}.json"; then
            attempt="$a"
            attempt_json="$tmp/attempt-${a}.json"
            break
        fi
    fi
    a=$((a - 1))
done

if [ -z "$attempt" ]; then
    echo "${pr_note}run ${run}：没有失败的 job（成功、仍在运行，或只有取消的任务）。" >&2
    exit 1
fi

gh run view "$run" --attempt "$attempt" --log-failed >"$tmp/log.txt" 2>/dev/null || true
if [ ! -s "$tmp/log.txt" ]; then
    gh run view "$run" --attempt "$attempt" --log >"$tmp/log.txt" 2>/dev/null || true
fi
gh issue list --state open --limit 300 --json number,title,body >"$tmp/issues.json" 2>/dev/null \
    || printf '[]\n' >"$tmp/issues.json"

python3 -I - "$run" "$attempt" "$run_attempts" "$pr_note" "$attempt_json" "$tmp/log.txt" "$tmp/issues.json" <<'PY'
import json
import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")

run, attempt, attempts, pr_note, jobs_path, log_path, issues_path = sys.argv[1:8]
doc = json.load(open(jobs_path, encoding="utf-8"))
raw = open(log_path, encoding="utf-8", errors="replace").read()
try:
    issues = json.load(open(issues_path, encoding="utf-8"))
except (ValueError, OSError):
    issues = []

MAX_LINES = 60
QUIET = {"success", "skipped", "cancelled", "", None}
TEXT_LIMIT = 110
NAME_LIMIT = 70

# gh prints ESC sequences either raw or escaped as `^[[0m`; both are noise here.
ANSI = re.compile(r"(?:\x1b\[[0-9;?]*[A-Za-z]|\^\[\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b[=>])")
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

SWIFT_CASE = re.compile(r'✘ Test "(?P<name>.+?)" recorded an issue at (?P<file>[^:\s]+):(?P<line>[0-9]+)')
NODE_PLAN = re.compile(r"(?:^|\s)not ok [0-9]+ - (?P<name>.+)$")
NODE_SPEC = re.compile(r"^\s*✖ (?P<name>.+?)(?:\s+\([0-9.]+m?s\))?$")
COMPILE = re.compile(r"(?:^|\s)error: (?P<text>.+)$")
CRASH = re.compile(r"crashed during execution|Process '(?P<proc>[^']*)' exited|unexpected signal code [0-9]+|Fatal error:")
SNAPSHOT = re.compile(r'Snapshot "(?P<name>[^"]+)" does not match reference')
NO_BASELINE = re.compile(r"No reference was found on disk")
EXITED = re.compile(r"Process '(?P<proc>[^']*)' exited(?P<rest>.*)$")
SIGNAL = re.compile(r"unexpected signal code [0-9]+")
TAB_PREFIX = re.compile(r"^[^\t]*\t[^\t]*\t[^\t]*\t")


def clean(text):
    return CONTROL.sub("", ANSI.sub("", text or "")).replace("\ufeff", "")


def one_line(text, limit=TEXT_LIMIT):
    text = " ".join(clean(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def clip(text, limit=NAME_LIMIT):
    return text if len(text) <= limit else text[: limit - 1] + "…"


def strip_prefix(line):
    return TAB_PREFIX.sub("", line, count=1)


# --- failing jobs ------------------------------------------------------------------------
job_steps = {}
failed_jobs = []
for job in doc.get("jobs") or []:
    if job.get("conclusion") in QUIET:
        continue
    name = job.get("name") or str(job.get("databaseId"))
    failed_jobs.append(name)
    job_steps[name] = [s.get("name") or "" for s in job.get("steps") or [] if s.get("conclusion") == "failure"]

# --- log signals, per job ----------------------------------------------------------------
swift_cases = []      # (job, name, file, line)
node_cases = []       # (job, name)
compile_errors = []   # (job, text)
crashes = []          # (job, text)
snapshots = []        # (job, snapshot name)
seen = set()


def push(bucket, key, item):
    # Deduplicated per job: the same core test can fail in both `macos-test` and `linux-core`, and
    # each job has to keep its own row.
    if key in seen:
        return
    seen.add(key)
    bucket.append(item)


for line in raw.splitlines():
    if not line.strip():
        continue
    body = clean(strip_prefix(line)).strip()
    if not body:
        continue
    job = clean(line.split("\t", 1)[0]).strip() or "?"
    match = SWIFT_CASE.search(body)
    if match:
        push(swift_cases, (job, "swift", match.group("name")), (job, match.group("name"), match.group("file"), match.group("line")))
        continue
    match = SNAPSHOT.search(body)
    if match:
        push(snapshots, (job, "snapshot", match.group("name")), (job, match.group("name")))
        continue
    if NO_BASELINE.search(body) and "__Snapshots__" in body:
        # A newly added case has no PNG on disk; the path is `<Suite>.<snapshot>.png`.
        stem = os.path.splitext(os.path.basename(body.split("snapshot: ")[-1].strip()))[0]
        name = stem.split(".", 1)[-1]
        push(snapshots, (job, "snapshot", name), (job, f"{name}（缺基线）"))
        continue
    match = NODE_PLAN.search(body) or NODE_SPEC.match(body)
    if match:
        push(node_cases, (job, "node", match.group("name")), (job, match.group("name")))
        continue
    if CRASH.search(body):
        text = "swift test crashed during execution" if "crashed during execution" in body else ""
        if not text:
            exited = EXITED.search(body)
            signal = SIGNAL.search(body)
            if exited:
                proc = os.path.basename(exited.group("proc").split()[0]) if exited.group("proc").strip() else "process"
                rest = exited.group("rest").strip()
                text = f"{proc} exited {rest}".strip()
            elif signal:
                text = signal.group(0)
            else:
                text = "Fatal error: " + body.split("Fatal error:", 1)[-1].strip()
        push(crashes, (job, "crash", text), (job, one_line(text)))
        continue
    match = COMPILE.search(body)
    if match and "Process '" not in match.group("text"):
        text = "error: " + match.group("text")
        push(compile_errors, (job, "compile", text), (job, one_line(text)))

# --- open issues: a case name or its file name in the title or body ----------------------
haystacks = []
for issue in issues:
    if not isinstance(issue, dict) or not issue.get("number"):
        continue
    haystack = f"{issue.get('title') or ''}\n{issue.get('body') or ''}".lower()
    haystacks.append((issue["number"], haystack))


def issue_for(name, file_name=""):
    """(number, by_name) of the open issue naming this case, or failing that its file."""
    lowered = (name or "").strip().lower()
    if lowered:
        for number, haystack in haystacks:
            if lowered in haystack:
                return number, True
    if file_name:
        lowered_file = os.path.basename(file_name).lower()
        for number, haystack in haystacks:
            if lowered_file in haystack:
                return number, False
    return None, False


def tagged(text, name, file_name=""):
    """Match on the raw case name, then annotate the formatted row.

    Only a case-name hit is a known flaky case. A file-name hit only says some open issue mentions
    the file (a refactor ticket, say), so it gets a weaker tag the reader has to check.
    """
    number, by_name = issue_for(name, file_name)
    if not number:
        return text
    return f"{text} [已知间歇 #{number}]" if by_name else f"{text} [同文件 issue #{number}，需核对]"


# --- summary -----------------------------------------------------------------------------
limit = min(MAX_LINES, max(20, int(os.environ.get("CI_FAILURES_MAX_LINES", MAX_LINES))))
out = []
out.append(f"{pr_note}run {run} attempt {attempt}/{attempts}"
           f"（{doc.get('workflowName') or 'CI'} · {doc.get('headBranch') or '?'} · {one_line(doc.get('displayTitle') or '', 60)}）")
out.append(f"失败 job：{', '.join(failed_jobs)}")

CAPS = {"swift": 12, "node": 6, "compile": 4, "crash": 4, "snapshot": 6}
SECTION = {
    "swift": "Swift Testing 失败用例",
    "node": "node test 失败用例",
    "compile": "编译错误",
    "crash": "进程崩溃",
    "snapshot": "快照不匹配",
}


def emit(kind, items):
    rows = items[: CAPS[kind]]
    out.append(f"{SECTION[kind]}（{len(items)}）：")
    for row in rows:
        out.append(f"  · {row}")
    if len(items) > len(rows):
        out.append(f"  · …另有 {len(items) - len(rows)} 条")


for job in failed_jobs:
    steps = [s for s in job_steps.get(job, []) if s]
    header = f"--- {job}" + (f"（{', '.join(steps)} 失败）" if steps else "")
    out.append(header)
    job_swift = [tagged(f'"{clip(name)}" {os.path.basename(file)}:{line}', name, file)
                 for j, name, file, line in swift_cases if j == job]
    job_node = [tagged(f"not ok - {clip(name, 90)}", name) for j, name in node_cases if j == job]
    job_compile = [text for j, text in compile_errors if j == job]
    job_crash = [text for j, text in crashes if j == job]
    job_snapshot = [tagged(f'"{clip(name)}"', name) for j, name in snapshots if j == job]
    if job_swift:
        emit("swift", job_swift)
    if job_node:
        emit("node", job_node)
    if job_compile:
        emit("compile", job_compile)
    if job_crash:
        emit("crash", job_crash)
    if job_snapshot:
        emit("snapshot", job_snapshot)
    if not (job_swift or job_node or job_compile or job_crash or job_snapshot):
        out.append("  · 没有可提取的失败信号（汇总其它 job 的门禁）")

if len(out) > limit:
    out = out[: limit - 1]
    out.append(f"…输出已截到 {limit} 行，完整日志：bash scripts/ci_errors.sh --attempt {attempt} {run}")

matched = sum(1 for row in out if "[已知间歇 #" in row)
print("\n".join(out))
if matched == 0 and haystacks:
    print(f"（{len(haystacks)} 个 open issue 里没有匹配的已知间歇票）")
PY
