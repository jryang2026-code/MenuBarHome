#!/usr/bin/env bash
# One screen for a pull request: head and merge state, failing or pending checks,
# the latest Codex review state for this head, and Codex inline comments on this head.
#
# Usage: bash scripts/pr-ready.sh <pr>
# Needs `gh` logged in to the repository. Review comments are read past the first 100.
set -euo pipefail
export LC_ALL=C

if [ "$#" -ne 1 ] || ! printf '%s\n' "$1" | grep -Eq '^[0-9]+$'; then
    echo "用法：bash scripts/pr-ready.sh <pr>" >&2
    exit 2
fi
n="$1"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-ready.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
gh repo view --json nameWithOwner >"$tmp/repo.json"
gh pr view "$n" --json headRefOid,mergeStateStatus >"$tmp/meta.json"
gh pr checks "$n" >"$tmp/checks.txt" || true
repo="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["nameWithOwner"])' "$tmp/repo.json")"
gh api --paginate --slurp "repos/${repo}/issues/${n}/comments?per_page=100" >"$tmp/issues.json"
gh api --paginate --slurp "repos/${repo}/pulls/${n}/comments?per_page=100" >"$tmp/reviews.json"

python3 -I - "$tmp" <<'PY'
import json
import re
import sys
from pathlib import Path

tmp = Path(sys.argv[1])
meta = json.loads((tmp / "meta.json").read_text(encoding="utf-8"))
head = meta["headRefOid"]
merge = meta["mergeStateStatus"]
checks = (tmp / "checks.txt").read_text(encoding="utf-8", errors="replace")
issue_pages = json.loads((tmp / "issues.json").read_text(encoding="utf-8"))
review_pages = json.loads((tmp / "reviews.json").read_text(encoding="utf-8"))


def flatten_pages(payload):
    if not isinstance(payload, list):
        raise SystemExit("GitHub 分页结果不是数组")
    items = []
    for page in payload:
        if isinstance(page, list):
            items.extend(entry for entry in page if isinstance(entry, dict))
        elif isinstance(page, dict):
            items.append(page)
    return items


def review_states(comments):
    found = []
    marker = "codex-review-state:v1"
    for comment in comments:
        user = (comment.get("user") or {}).get("login") or ""
        if user != "chatgpt-codex-connector[bot]":
            continue
        body = comment.get("body") or ""
        idx = body.find(marker)
        if idx < 0:
            continue
        start = body.find("{", idx)
        if start < 0:
            continue
        try:
            obj, _ = json.JSONDecoder().raw_decode(body[start:])
        except json.JSONDecodeError:
            continue
        code = obj.get("code_review")
        if isinstance(code, dict) and code.get("commit_sha"):
            found.append(code)
    return found


def clean_body(body):
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    body = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", body)
    return body.strip()


print(f"head {head} {merge}")

rows = []
for line in checks.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    name, state = parts[0], parts[1]
    if state in ("pass", "skipping"):
        continue
    rows.append(f"  {name}: {state}")
if rows:
    print("checks:")
    print("\n".join(rows))
else:
    print("checks: none")

states = review_states(flatten_pages(issue_pages))
matched = [state for state in states if state.get("commit_sha") == head]
if matched:
    print("codex review: " + json.dumps(matched[-1], separators=(",", ":"), ensure_ascii=False))
elif states:
    last = states[-1]
    print(f"codex review: none for {head} (latest {last.get('commit_sha')} {last.get('status')})")
else:
    print(f"codex review: none for {head}")

inlines = []
for comment in flatten_pages(review_pages):
    user = (comment.get("user") or {}).get("login") or ""
    if not user.startswith("chatgpt-codex"):
        continue
    if comment.get("original_commit_id") != head:
        continue
    line_no = comment.get("line")
    if line_no is None:
        line_no = comment.get("original_line")
    inlines.append((comment.get("path"), line_no, clean_body(comment.get("body"))))

if not inlines:
    print("codex inline: none")
else:
    print("codex inline:")
    for index, (path, line_no, body) in enumerate(inlines):
        if index:
            print()
        print(f"* {path} {line_no}")
        if body:
            print(body[:900])
PY
