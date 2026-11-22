#!/usr/bin/env bash
# One screen for a pull request: head and merge state, failing or pending checks,
# the latest Codex review state for this head, Codex inline comments on this head, and
# whether the base branch moved on files this PR also touches (green CI on a stale base).
#
# Exit codes in --wait mode:
#   0   PR is CLEAN, CI checks settled with no failures, and Codex gate is satisfied
#   1   Blocker found (failed check, unresolved Codex finding, or conflict/closed PR)
#   3   CI passed, action needed on Codex (not triggered on subsequent push, or timed out after CI)
#   124 Overall wait timeout exceeded
#
# Usage: bash scripts/pr-ready.sh [--wait] [--timeout <sec>] [--interval <sec>]
#          [--max-codex-rounds <n>] [--codex-timeout <sec>] [--no-wait-codex] [--expect-head <sha>] <pr>
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "用法：bash scripts/pr-ready.sh [--wait] [--timeout <sec>] [--interval <sec>] [--max-codex-rounds <n>] [--codex-timeout <sec>] [--no-wait-codex] [--expect-head <sha>] <pr>" >&2
    exit 2
}

wait_mode=0
timeout_sec=1800
interval_sec=20
max_codex_rounds=0
codex_timeout_sec=480
no_wait_codex=0
expect_head=""
pr_number=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --wait)
            wait_mode=1
            shift
            ;;
        --timeout)
            [ "$#" -ge 2 ] || usage
            timeout_sec="$2"
            shift 2
            ;;
        --interval)
            [ "$#" -ge 2 ] || usage
            interval_sec="$2"
            shift 2
            ;;
        --max-codex-rounds)
            [ "$#" -ge 2 ] || usage
            max_codex_rounds="$2"
            shift 2
            ;;
        --codex-timeout)
            [ "$#" -ge 2 ] || usage
            codex_timeout_sec="$2"
            shift 2
            ;;
        --no-wait-codex)
            no_wait_codex=1
            shift
            ;;
        --expect-head)
            [ "$#" -ge 2 ] || usage
            expect_head="$2"
            shift 2
            ;;
        -*)
            usage
            ;;
        *)
            if [ -n "$pr_number" ]; then
                usage
            fi
            pr_number="$1"
            shift
            ;;
    esac
done

if [ -z "$pr_number" ] || ! printf '%s\n' "$pr_number" | grep -Eq '^[0-9]+$'; then
    usage
fi
if ! printf '%s\n' "$timeout_sec" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
    || ! printf '%s\n' "$interval_sec" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
    || ! printf '%s\n' "$codex_timeout_sec" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
    || ! printf '%s\n' "$max_codex_rounds" | grep -Eq '^[0-9]+$'; then
    usage
fi
if [ -n "$expect_head" ] && ! printf '%s\n' "$expect_head" | grep -Eq '^[0-9a-fA-F]{4,40}$'; then
    usage
fi

python_bin=""
for cand in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python; do
    if command -v "$cand" >/dev/null 2>&1; then
        python_bin="$cand"
        break
    fi
done
if [ -z "$python_bin" ]; then
    echo "缺少 python3" >&2
    exit 1
fi

state_file="$(mktemp "${TMPDIR:-/tmp}/pr-ready-state.XXXXXX")"
trap 'rm -f "$state_file"' EXIT

inspect_once() {
    local n="$1"
    local wait_flag="$2"
    local tmp gh_err
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-ready.XXXXXX")"

    handle_gh_failure() {
        local step="$1"
        gh_err="$(tail -n 1 "$tmp/gh.err" 2>/dev/null || true)"
        echo "gh error (${step}): ${gh_err:-unknown failure}"
        rm -rf "$tmp"
        if [ "$wait_flag" = "1" ]; then
            case "$gh_err" in
                *"Could not resolve"*|*"not found"*|*"Not Found"*|*"HTTP 401"*|*"HTTP 403"*|*"HTTP 404"*|*"authentication"*|*"auth login"*)
                    return 1
                    ;;
                *)
                    return 10
                    ;;
            esac
        fi
        return 1
    }

    if ! gh repo view --json nameWithOwner >"$tmp/repo.json" 2>"$tmp/gh.err"; then
        handle_gh_failure "repo view"
        return $?
    fi
    if ! gh pr view "$n" --json headRefOid,mergeStateStatus,baseRefName,files,commits,createdAt,isDraft >"$tmp/meta.json" 2>"$tmp/gh.err"; then
        handle_gh_failure "pr view"
        return $?
    fi
    local checks_status=0
    env -u GH_FORCE_TTY gh pr checks "$n" --json name,state,bucket >"$tmp/checks.json" 2>"$tmp/checks.err" || checks_status=$?
    printf '%s\n' "$checks_status" >"$tmp/checks.status"
    local repo
    if ! repo="$("$python_bin" -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["nameWithOwner"])' "$tmp/repo.json" 2>"$tmp/gh.err")"; then
        handle_gh_failure "parse repo"
        return $?
    fi
    if ! gh api --paginate --slurp "repos/${repo}/issues/${n}/comments?per_page=100" >"$tmp/issues.json" 2>"$tmp/gh.err"; then
        handle_gh_failure "issues comments"
        return $?
    fi
    if ! gh api --paginate --slurp "repos/${repo}/pulls/${n}/comments?per_page=100" >"$tmp/reviews.json" 2>"$tmp/gh.err"; then
        handle_gh_failure "review comments"
        return $?
    fi
    if ! gh api --paginate --slurp "repos/${repo}/pulls/${n}/reviews?per_page=100" >"$tmp/pr_reviews.json" 2>"$tmp/gh.err"; then
        handle_gh_failure "pull reviews"
        return $?
    fi

    local base_ref head_oid
    base_ref="$("$python_bin" -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["baseRefName"])' "$tmp/meta.json")"
    head_oid="$("$python_bin" -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["headRefOid"])' "$tmp/meta.json")"
    # Commits on the base since the merge base, and the files they changed. Best effort: an error only skips the stale-base check.
    gh api "repos/${repo}/compare/${head_oid}...${base_ref}" --jq '{ahead_by: .ahead_by, files: [.files[]?.filename]}' >"$tmp/stale.json" 2>/dev/null || echo '{}' >"$tmp/stale.json"

    local eval_args=(
        "$tmp"
        --max-codex-rounds "$max_codex_rounds"
        --codex-timeout "$codex_timeout_sec"
        --state-file "$state_file"
    )
    if [ "$wait_flag" = "1" ]; then
        eval_args+=(--wait)
    fi
    if [ "$no_wait_codex" = "1" ]; then
        eval_args+=(--no-wait-codex)
    fi
    if [ -n "$expect_head" ]; then
        eval_args+=(--expect-head "$expect_head")
    fi

    local verdict_status=0
    "$python_bin" -I "${SCRIPT_DIR}/pr_ready_eval.py" "${eval_args[@]}" || verdict_status=$?
    rm -rf "$tmp"
    return "$verdict_status"
}

if [ "$wait_mode" -eq 0 ]; then
    inspect_once "$pr_number" 0
    exit $?
fi

start_epoch="$("$python_bin" -I -c 'import time; print(f"{time.monotonic():.3f}")')"
last_screen=""
while true; do
    status=0
    last_screen="$(inspect_once "$pr_number" 1)" || status=$?
    if [ "$status" -ne 10 ]; then
        printf '%s\n' "$last_screen"
        exit "$status"
    fi
    timed_out="$("$python_bin" -I -c 'import sys, time; elapsed = time.monotonic() - float(sys.argv[1]); print("1" if elapsed >= float(sys.argv[2]) else "0")' "$start_epoch" "$timeout_sec")"
    if [ "$timed_out" = "1" ]; then
        printf '%s\n' "$last_screen"
        echo "等待 PR #${pr_number} 超时（${timeout_sec}s）" >&2
        exit 124
    fi
    sleep "$interval_sec"
done
