#!/usr/bin/env bash
# Normalize a branch name for Record snapshots, then prove it exists in this repository.
#
#   ci_snapshot_branch.sh normalize <name>
#   ci_snapshot_branch.sh resolve
#
# resolve reads BRANCH_INPUT, checks the GitHub branches API, and appends name=<branch>
# to GITHUB_OUTPUT when that variable is set. Tags, commit SHAs, and forks are rejected
# because the branches API only returns branches of GITHUB_REPOSITORY.
set -euo pipefail

normalize_branch() {
    local raw="$1"
    raw="${raw//$'\r'/}"
    case "$raw" in
        refs/heads/*) raw="${raw#refs/heads/}" ;;
    esac
    if [ -z "$raw" ]; then
        echo "❌ 分支名为空" >&2
        return 2
    fi
    case "$raw" in
        HEAD|refs|refs/*)
            echo "❌ 只接受本仓库的分支名，收到：${raw}" >&2
            return 2
            ;;
        -*|/*|*/|*//*)
            echo "❌ 分支名不合法：${raw}" >&2
            return 2
            ;;
        *..*)
            echo "❌ 分支名不合法：${raw}" >&2
            return 2
            ;;
    esac
    if ! printf '%s' "$raw" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
        echo "❌ 分支名含有不允许的字符：${raw}" >&2
        return 2
    fi
    case "/$raw/" in
        */./*|*/../*)
            echo "❌ 分支名不合法：${raw}" >&2
            return 2
            ;;
    esac
    printf '%s\n' "$raw"
}

cmd_resolve() {
    local branch encoded api_name
    branch="$(normalize_branch "${BRANCH_INPUT:-}")"
    if [ -z "${GITHUB_REPOSITORY:-}" ]; then
        echo "❌ 缺少 GITHUB_REPOSITORY" >&2
        return 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "❌ 缺少 gh，无法确认分支属于本仓库" >&2
        return 1
    fi
    encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$branch")"
    if ! api_name="$(gh api "repos/${GITHUB_REPOSITORY}/branches/${encoded}" --jq .name)"; then
        echo "❌ 本仓库没有分支 ${branch}。不接受 tag、提交号，或其他仓库的分支。" >&2
        return 1
    fi
    if [ "$api_name" != "$branch" ]; then
        echo "❌ 分支 API 返回 ${api_name}，与 ${branch} 不一致" >&2
        return 1
    fi
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf 'name=%s\n' "$branch" >> "$GITHUB_OUTPUT"
    fi
    printf '%s\n' "$branch"
}

case "${1:-}" in
    normalize)
        normalize_branch "${2-}"
        ;;
    resolve)
        cmd_resolve
        ;;
    -h|--help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        ;;
    *)
        echo "❌ 用法：ci_snapshot_branch.sh normalize <name> | resolve" >&2
        exit 2
        ;;
esac
