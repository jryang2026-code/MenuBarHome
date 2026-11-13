#!/usr/bin/env bash
# One line per local branch worth looking at: its own change size, its PR state, and its worktree.
#
# Usage: bash scripts/pending-work.sh [base]   # base defaults to origin/main
#
# A squash-merged branch looks "ahead" in `git rev-list`, so the authoritative landed signal is
# the pull request state from GitHub (`gh`). The OWN column is the branch's own diff against its merge base, which
# stays stable while the base branch moves.
set -euo pipefail

base="${1:-origin/main}"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || {
    echo "无法解析基线 ref：$base（先 git fetch）" >&2
    exit 1
}

gh_err_file="$(mktemp "${TMPDIR:-/tmp}/pending-work-gh.XXXXXX")"
trap 'rm -f "$gh_err_file"' EXIT
gh_ok=1
prs="$(gh pr list --state all --limit 200 --json headRefName,state,number \
    --jq '.[] | "\(.headRefName)\t\(.state)\t\(.number)"' 2>"$gh_err_file")" || gh_ok=0
if [ "$gh_ok" -eq 0 ]; then
    gh_reason="$(tail -n 1 "$gh_err_file" 2>/dev/null || true)"
    echo "⚠️ gh pr list 查询失败（${gh_reason:-未知错误}），PR 列将显示为 unknown（请检查网络或 gh auth status）" >&2
fi

pr_state() {
    if [ "$gh_ok" -eq 0 ]; then
        echo "unknown"
        return 0
    fi
    printf '%s\n' "$prs" | awk -F'\t' -v b="$1" '!found && $1 == b { print $2 " #" $3; found = 1 } END { if (!found) print "no PR" }'
}

worktrees="$(git worktree list --porcelain | awk '
    /^worktree / { sub(/^worktree /, ""); path=$0 }
    /^branch / { sub(/^branch refs\/heads\//, ""); print $0 "\t" path }
')"

printf '%-46s %7s %-38s %-12s %s\n' BRANCH AHEAD OWN PR WORKTREE
git for-each-ref --format='%(refname:short)|%(committerdate:short)' refs/heads |
while IFS='|' read -r branch last; do
    [ -n "$branch" ] || continue
    merge_base="$(git merge-base "$base" "$branch" 2>/dev/null || true)"
    own=""
    if [ -n "$merge_base" ]; then
        own="$(git diff --shortstat "$merge_base" "$branch" 2>/dev/null || true)"
    fi
    ahead="$(git rev-list --count "$base..$branch" 2>/dev/null || echo '?')"
    worktree="$(printf '%s\n' "$worktrees" | awk -v b="$branch" -F'\t' '$1 == b {print $2}')"
    # Branches that changed nothing and have no checkout left are noise.
    if [ -z "$own" ] && [ -z "$worktree" ]; then continue; fi
    state=""
    if [ -n "$worktree" ]; then
        if ! git -C "$worktree" status --porcelain >/dev/null 2>&1; then
            state=" (unknown)"
        elif [ -n "$(git -C "$worktree" status --porcelain)" ]; then
            state=" (dirty)"
        else
            state=" (clean)"
        fi
    fi
    printf '%-46s %7s %-38s %-12s %s%s\n' \
        "$branch" "$ahead" "${own:-no file delta}" "$(pr_state "$branch")" \
        "${worktree:-<no worktree>}" "$state"
done
