#!/usr/bin/env bash
# ci_errors.sh 的自测。用假的 gh 返回分页 annotation 和 job 列表，不连 GitHub。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-errors-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

cat >"$bin/gh" <<'EOF'
#!/bin/bash
joined="$*"
fixture="${CI_ERRORS_FIXTURE:?}"
if [[ "$joined" == *"repo view"* ]]; then
    printf '%s\n' '{"nameWithOwner":"jryang2026-code/MenuBarHome"}'
    exit 0
fi
if [[ "$joined" == *"--log-failed"* ]]; then
    if [[ -f "$fixture/log.txt" ]]; then
        cat "$fixture/log.txt"
    fi
    exit 0
fi
if [[ "$joined" == *"--json jobs"* ]]; then
    cat "$fixture/jobs.json"
    exit 0
fi
if [[ "$joined" == *"check-runs/"*"/annotations"* ]]; then
    id="$(printf '%s\n' "$joined" | sed -n 's/.*check-runs\/\([0-9][0-9]*\)\/annotations.*/\1/p')"
    file="$fixture/ann-$id.json"
    if [[ ! -f "$file" ]]; then
        echo "missing annotations for $id" >&2
        exit 9
    fi
    if [[ "$joined" == *"--paginate"* && "$joined" == *"--slurp"* && "$joined" == *"per_page=100"* ]]; then
        cat "$file"
        exit 0
    fi
    python3 -c 'import json,sys; pages=json.load(sys.stdin); json.dump(pages[0] if pages else [], sys.stdout)' <"$file"
    exit 0
fi
echo "unexpected gh: $joined" >&2
exit 9
EOF
chmod +x "$bin/gh"

run_case() {
    local name="$1" expected_status="$2"
    local status=0 output
    output="$(CI_ERRORS_FIXTURE="$tmp/fix" PATH="$bin:$PATH" bash "$root/scripts/ci_errors.sh" "$name" 2>"$tmp/err")" || status=$?
    if [[ -s "$tmp/err" ]]; then
        fail "$name 不应写 stderr：$(cat "$tmp/err")"
        return
    fi
    if [[ "$status" != "$expected_status" ]]; then
        fail "$name 退出码应为 $expected_status，实际 $status"
        printf '%s\n' "$output" >&2
        return
    fi
    if [[ "$output" == "$3" ]]; then
        pass "$name"
    else
        fail "$name 输出不符"
        printf '期望:\n%s\n实际:\n%s\n' "$3" "$output" >&2
    fi
}

mkdir -p "$tmp/fix"
cat >"$tmp/fix/jobs.json" <<'EOF'
{"jobs":[
  {"name":"macos-test","conclusion":"failure","databaseId":11,"steps":[{},{}]},
  {"name":"ci","conclusion":"cancelled","databaseId":22,"steps":[]},
  {"name":"windows-core","conclusion":"skipped","databaseId":33,"steps":[]},
  {"name":"macos-release","conclusion":"cancelled","databaseId":44,"steps":[{}]}
]}
EOF
cat >"$tmp/fix/ann-11.json" <<'EOF'
[
  [{"annotation_level":"failure","message":"Process completed with exit code 1."}],
  [{"annotation_level":"failure","message":"only on page two"}]
]
EOF
cat >"$tmp/fix/ann-22.json" <<'EOF'
[
  [{"annotation_level":"failure","message":"The job was not acquired by Runner of type hosted"}]
]
EOF
cat >"$tmp/fix/ann-44.json" <<'EOF'
[[]]
EOF
cat >"$tmp/fix/log.txt" <<'EOF'
macos-test	Swift tests	2026-11-10T00:00:00.0000000Z error: boom
macos-test	Swift tests	2026-11-10T00:00:00.0000000Z noise line
macos-test	Swift tests	2026-11-10T00:00:00.0000000Z ✘ Test panelSnapshot() recorded an issue
EOF

expected="$(cat <<'EOF'
=== 取消且 steps=0（runner 未分配，基础设施，不是代码）
ci
=== annotations
macos-test	failure	Process completed with exit code 1.
macos-test	failure	only on page two
ci	failure	The job was not acquired by Runner of type hosted
=== 失败的 job
macos-test
=== 错误与失败用例
error: boom
✘ Test panelSnapshot() recorded an issue
EOF
)"
run_case 42742825141 0 "$expected"

cat >"$tmp/fix/jobs.json" <<'EOF'
{"jobs":[{"name":"ci","conclusion":"cancelled","databaseId":22,"steps":[]}]}
EOF
cat >"$tmp/fix/ann-22.json" <<'EOF'
[[]]
EOF
rm -f "$tmp/fix/log.txt"
run_case 42585955642 0 "$(printf '%s\n' "=== 取消且 steps=0（runner 未分配，基础设施，不是代码）" "ci")"

cat >"$tmp/fix/jobs.json" <<'EOF'
{"jobs":[{"name":"linux-core","conclusion":"success","databaseId":55,"steps":[{}]}]}
EOF
run_case 123 1 "没有失败日志：123（可能仍在运行、已成功，或 run id 不存在）"

status=0
bash "$root/scripts/ci_errors.sh" >/dev/null 2>"$tmp/err" || status=$?
if [[ "$status" == 2 ]]; then
    pass "缺少 run id 时退出 2"
else
    fail "缺少 run id 时应退出 2，实际 $status"
fi

if [[ "$failures" -eq 0 ]]; then
    exit 0
fi
exit 1
