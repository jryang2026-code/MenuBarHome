#!/usr/bin/env bash
# Commit changed snapshot PNGs and push them to SNAPSHOT_BRANCH.
#
#   ci_commit_snapshot_baselines.sh message   # read a path list on stdin, print the commit message
#   ci_commit_snapshot_baselines.sh commit    # stage, commit, push
#
# A second run with the same pixels finds nothing to commit and exits 0.
# The push is not a force push. The run must sit on the current branch tip: if
# the branch advanced past the recorded commit, the run fails and asks for a
# re-record instead of rebasing old pixels onto the new tip.
set -euo pipefail

# Ignore repo hooks and any git shim on PATH. The push job must not run a
# hook planted in the target checkout.
git() {
    /usr/bin/git -c core.hooksPath=/dev/null "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd))"
REL="Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"

assert_snapshot_paths() {
    local line
    if [ -z "$1" ]; then
        echo "❌ 没有快照路径" >&2
        return 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            "$REL"/*.png) ;;
            *)
                echo "❌ 快照提交只能包含 ${REL} 下的 PNG：${line}" >&2
                return 1
                ;;
        esac
    done <<EOF
$1
EOF
}

build_message() {
    local count="$1"
    local files="$2"
    printf '%s\n' "test(snapshots): re-record UI baselines on macos-26-intel"
    printf '\n'
    printf '%s\n' "Reference renderer: GitHub-hosted macos-26-intel, Xcode 26.6, zh_CN metric locale."
    printf '%s\n' "Changed files (${count}):"
    printf '%s\n' "$files" | sed '/^$/d' | sed 's/^/- /'
}

cmd_message() {
    local files count
    files="$(sed '/^$/d')"
    assert_snapshot_paths "$files"
    count="$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    build_message "$count" "$files"
}

write_pushed() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf 'pushed=%s\n' "$1" >> "$GITHUB_OUTPUT"
    fi
}

require_pushed_head() {
    local branch="$1"
    local head remote
    git fetch origin "$branch"
    head="$(git rev-parse HEAD)"
    remote="$(git rev-parse "origin/${branch}")"
    if [ "$head" != "$remote" ]; then
        echo "❌ HEAD ${head} 不是 origin/${branch}（${remote}）。快照提交没有推上去。" >&2
        write_pushed false
        return 1
    fi
}

require_recorded_tip() {
    # The record job rendered baselines from one exact commit; that commit must
    # still be the branch tip. Rebasing old pixels onto a newer tip would push
    # baselines that do not match the new source.
    local branch="$1" base="$2"
    local remote
    git fetch origin "$branch"
    remote="$(git rev-parse "origin/${branch}")"
    if [ "$base" != "$remote" ]; then
        echo "❌ 分支 ${branch} 已前进：origin=${remote}，本次录制基于 ${base}。" >&2
        echo "   旧录制不能覆盖新提交。请在新分支顶上重新运行 Record snapshots。" >&2
        write_pushed false
        return 1
    fi
}

cmd_commit() {
    local branch files count msg base
    branch="$(bash "$SCRIPT_DIR/ci_snapshot_branch.sh" normalize "${SNAPSHOT_BRANCH:?}")"
    cd "$ROOT"
    base="$(git rev-parse HEAD)"
    require_recorded_tip "$branch" "$base"
    if [ -e "$REL" ]; then
        git add -A -- "$REL"
    fi
    files="$(git diff --cached --name-only -- "$REL")"
    if [ -z "$files" ]; then
        echo "没有需要提交的快照基线"
        write_pushed false
        return 0
    fi
    assert_snapshot_paths "$files"
    export GIT_AUTHOR_NAME='github-actions[bot]'
    export GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
    export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
    export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
    count="$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    msg="$(mktemp)"
    build_message "$count" "$files" >"$msg"
    echo "提交说明："
    cat "$msg"
    /usr/bin/git -c core.hooksPath=/dev/null \
        -c user.name="$GIT_AUTHOR_NAME" \
        -c user.email="$GIT_AUTHOR_EMAIL" \
        commit -F "$msg"
    rm -f "$msg"
    git push origin "HEAD:refs/heads/${branch}"
    require_pushed_head "$branch"
    echo "已推送 ${count} 张快照基线到 ${branch}"
    write_pushed true
}

case "${1:-}" in
    message) cmd_message ;;
    commit) cmd_commit ;;
    -h|--help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        ;;
    *)
        echo "❌ 用法：ci_commit_snapshot_baselines.sh message | commit" >&2
        exit 2
        ;;
esac
