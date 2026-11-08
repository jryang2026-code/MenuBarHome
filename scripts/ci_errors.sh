#!/usr/bin/env bash
# Print only the failure lines of a GitHub Actions run, one screenful instead of the full log.
#
# Usage: bash scripts/ci_errors.sh <run-id>
# Needs `gh` logged in to the repository.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "用法：bash scripts/ci_errors.sh <run-id>" >&2
    exit 2
fi
run="$1"

log="$(mktemp "${TMPDIR:-/tmp}/ci-errors.XXXXXX")"
trap 'rm -f "$log"' EXIT
gh run view "$run" --log-failed >"$log" || true

if [ ! -s "$log" ]; then
    echo "没有失败日志：$run（可能仍在运行、已成功，或 run id 不存在）"
    exit 1
fi

echo "=== 失败的 job"
awk -F'\t' 'NF && !seen[$1]++ {print $1}' "$log"
echo "=== 错误与失败用例"
sed -E 's/^[^\t]*\t[^\t]*\t[0-9T:.Z-]+ ?//' "$log" |
    sed -E 's/\x1b\[[0-9;]*m//g' |
    grep -E 'error:|✘ (Test|Suite)|Test run with .* failed|##\[error\]' |
    awk '!seen[$0]++' |
    head -60
