#!/usr/bin/env bash
# pr-ready.sh 的自测。第二页才有当前 head 的审查；漏了分页就会显示旧结论。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
unset GH_FORCE_TTY

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-ready-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"
head_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
old_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

cat >"$bin/gh" <<'EOF'
#!/bin/bash
joined="$*"
fixture="${PR_READY_FIXTURE:?}"
if [[ "$joined" == *"repo view"* ]]; then
    printf '%s\n' '{"nameWithOwner":"jryang2026-code/MenuBarHome"}'
    exit 0
fi
if [[ "$joined" == *"pr view"* ]]; then
    cat "$fixture/meta.json"
    exit 0
fi
if [[ "$joined" == *"pr checks"* ]]; then
    if [[ "${PR_READY_CHECKS_MODE:-}" == error ]]; then
        echo "HTTP 502" >&2
        exit 1
    fi
    if [[ "${PR_READY_CHECKS_MODE:-}" == pending ]]; then
        exit 8
    fi
    # TTY first: if pr-ready.sh stops clearing GH_FORCE_TTY, its --json call gets table text and fails.
    if [[ "${GH_FORCE_TTY:-}" == 1 ]]; then
        printf '%s\n' 'macos-test fail 2m https://example.test/2'
        exit 1
    fi
    if [[ "$joined" == *"--json"* ]]; then
        cat "$fixture/checks.json"
        exit 1
    fi
    cat "$fixture/checks.txt"
    exit 1
fi
page_ok=0
if [[ "$joined" == *"--paginate"* && "$joined" == *"--slurp"* && "$joined" == *"per_page=100"* ]]; then
    page_ok=1
fi
if [[ "$joined" == *"/issues/"*"/comments"* ]]; then
    if [[ "$page_ok" == 1 ]]; then
        cat "$fixture/issues.json"
    else
        python3 -c 'import json,sys; pages=json.load(sys.stdin); json.dump(pages[0], sys.stdout)' <"$fixture/issues.json"
    fi
    exit 0
fi
if [[ "$joined" == *"/pulls/"*"/comments"* ]]; then
    if [[ "$page_ok" == 1 ]]; then
        cat "$fixture/reviews.json"
    else
        python3 -c 'import json,sys; pages=json.load(sys.stdin); json.dump(pages[0], sys.stdout)' <"$fixture/reviews.json"
    fi
    exit 0
fi
echo "unexpected gh: $joined" >&2
exit 9
EOF
chmod +x "$bin/gh"

mkdir -p "$tmp/fix"
printf '%s\n' "{\"headRefOid\":\"$head_sha\",\"mergeStateStatus\":\"BLOCKED\"}" >"$tmp/fix/meta.json"
cat >"$tmp/fix/checks.txt" <<'EOF'
linux-core	pass	1m	https://example.test/1
macos-test	fail	2m	https://example.test/2
windows-core (ubuntu-latest, 22)	pending	0	https://example.test/3
raycast	skipping	0	https://example.test/4
EOF
cat >"$tmp/fix/checks.json" <<'EOF'
[
  {"name":"linux-core","state":"SUCCESS","bucket":"pass"},
  {"name":"macos-test","state":"FAILURE","bucket":"fail"},
  {"name":"windows-core (ubuntu-latest, 22)","state":"PENDING","bucket":"pending"},
  {"name":"raycast","state":"NEUTRAL","bucket":"skipping"}
]
EOF
python3 -I - "$tmp/fix/issues.json" "$old_sha" "$head_sha" <<'PY'
import json, sys
path, old, head = sys.argv[1:]
def state(sha, findings):
    payload = {
        "code_review": {
            "commit_sha": sha,
            "has_any_findings": findings,
            "has_unresolved_findings": findings,
            "status": "completed",
        },
        "security_review": {
            "commit_sha": None,
            "has_any_findings": None,
            "has_unresolved_findings": None,
            "status": None,
        },
    }
    body = "<!-- codex-review-state:v1 " + json.dumps(payload, separators=(",", ":")) + " -->"
    return {"user": {"login": "chatgpt-codex-connector[bot]"}, "body": body}
pages = [
    [
        {"user": {"login": "someone"}, "body": "hello"},
        state(old, True),
    ],
    [state(head, False)],
]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(pages, fh)
PY
python3 -I - "$tmp/fix/reviews.json" "$old_sha" "$head_sha" <<'PY'
import json, sys
path, old, head = sys.argv[1:]
pages = [
    [
        {
            "user": {"login": "chatgpt-codex-connector[bot]"},
            "original_commit_id": old,
            "path": "old.swift",
            "line": 1,
            "body": "old finding",
        },
        {
            "user": {"login": "human"},
            "original_commit_id": head,
            "path": "human.swift",
            "line": 2,
            "body": "human finding",
        },
    ],
    [
        {
            "user": {"login": "chatgpt-codex-connector[bot]"},
            "original_commit_id": head,
            "path": "Sources/Foo.swift",
            "line": 12,
            "body": "<!-- secret -->\nreal finding\n![x](http://img)",
        }
    ],
]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(pages, fh)
PY

expected="$(cat <<EOF
head $head_sha BLOCKED
checks:
  macos-test: fail
  windows-core (ubuntu-latest, 22): pending
codex review: {"commit_sha":"$head_sha","has_any_findings":false,"has_unresolved_findings":false,"status":"completed"}
codex inline:
* Sources/Foo.swift 12
real finding
EOF
)"
status=0
output="$(PR_READY_FIXTURE="$tmp/fix" PATH="$bin:$PATH" bash "$root/scripts/pr-ready.sh" 60 2>"$tmp/err")" || status=$?
if [[ "$status" == 0 && "$output" == "$expected" && ! -s "$tmp/err" ]]; then
    pass "当前 head 的审查在第二页，失败和 pending 检查都列出来"
else
    fail "完整一屏不符，退出 $status"
    printf '期望:\n%s\n实际:\n%s\nstderr:\n%s\n' "$expected" "$output" "$(cat "$tmp/err")" >&2
fi
if printf '%s\n' "$output" | grep -q 'old.swift\|human.swift\|old finding\|secret\|http://img\|has_any_findings":true'; then
    fail "把旧提交、人工评论或 HTML 也打出来了"
else
    pass "不显示旧提交、人工评论和 HTML"
fi

python3 -I - "$tmp/fix/issues.json" "$old_sha" <<'PY'
import json, sys
path, old = sys.argv[1:]
payload = {"code_review": {"commit_sha": old, "has_any_findings": True, "has_unresolved_findings": True, "status": "completed"}, "security_review": {"commit_sha": None, "has_any_findings": None, "has_unresolved_findings": None, "status": None}}
body = "<!-- codex-review-state:v1 " + json.dumps(payload, separators=(",", ":")) + " -->"
pages = [[{"user": {"login": "chatgpt-codex-connector[bot]"}, "body": body}], []]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(pages, fh)
PY
printf '%s\n' 'linux-core	pass	1m	https://example.test/1' >"$tmp/fix/checks.txt"
printf '%s\n' '[{"name":"linux-core","state":"SUCCESS","bucket":"pass"}]' >"$tmp/fix/checks.json"
printf '%s\n' '[[]]' >"$tmp/fix/reviews.json"
stale="$(cat <<EOF
head $head_sha BLOCKED
checks: none
codex review: none for $head_sha (latest $old_sha completed)
codex inline: none
EOF
)"
status=0
output="$(PR_READY_FIXTURE="$tmp/fix" PATH="$bin:$PATH" bash "$root/scripts/pr-ready.sh" 60 2>"$tmp/err")" || status=$?
if [[ "$status" == 0 && "$output" == "$stale" ]]; then
    pass "head 还没有审查时标明最近一条属于哪个提交"
else
    fail "过期审查的输出不符，退出 $status"
    printf '期望:\n%s\n实际:\n%s\n' "$stale" "$output" >&2
fi

status=0
bash "$root/scripts/pr-ready.sh" >/dev/null 2>"$tmp/err" || status=$?
if [[ "$status" == 2 ]]; then
    pass "缺少 PR 号时退出 2"
else
    fail "缺少 PR 号时应退出 2，实际 $status"
fi
status=0
bash "$root/scripts/pr-ready.sh" abc >/dev/null 2>"$tmp/err" || status=$?
if [[ "$status" == 2 ]]; then
    pass "非数字 PR 号退出 2"
else
    fail "非数字 PR 号应退出 2，实际 $status"
fi

status=0
output="$(PR_READY_CHECKS_MODE=error PR_READY_FIXTURE="$tmp/fix" PATH="$bin:$PATH" bash "$root/scripts/pr-ready.sh" 60 2>"$tmp/err")" || status=$?
if [[ "$status" != 0 ]] && printf '%s\n' "$output" | grep -q 'checks: error' && printf '%s\n' "$output" | grep -q 'HTTP 502' && ! printf '%s\n' "$output" | grep -q 'checks: none'; then
    pass "gh pr checks 失败且没有检查行时退出非 0"
else
    fail "空的失败检查被当成全部通过，退出 $status"
    printf 'stdout:\n%s\nstderr:\n%s\n' "$output" "$(cat "$tmp/err")" >&2
fi

status=0
output="$(PR_READY_CHECKS_MODE=pending PR_READY_FIXTURE="$tmp/fix" PATH="$bin:$PATH" bash "$root/scripts/pr-ready.sh" 60 2>"$tmp/err")" || status=$?
if [[ "$status" == 0 ]] && printf '%s\n' "$output" | grep -qx 'checks: pending'; then
    pass "gh 退出 8 表示检查仍在进行"
else
    fail "退出 8 没有标成 pending，退出 $status"
    printf '%s\n' "$output" >&2
fi

printf '%s\n' '[{"name":"macos-test","state":"FAILURE","bucket":"fail"}]' >"$tmp/fix/checks.json"
status=0
output="$(GH_FORCE_TTY=1 PR_READY_FIXTURE="$tmp/fix" PATH="$bin:$PATH" bash "$root/scripts/pr-ready.sh" 60 2>"$tmp/err")" || status=$?
if [[ "$status" == 0 ]] && printf '%s\n' "$output" | grep -q 'macos-test: fail' && ! printf '%s\n' "$output" | grep -q 'checks: none'; then
    pass "GH_FORCE_TTY=1 仍列出失败检查"
else
    fail "GH_FORCE_TTY=1 把失败检查藏起来了，退出 $status"
    printf '%s\n' "$output" >&2
fi

if [[ "$failures" -eq 0 ]]; then
    exit 0
fi
exit 1
