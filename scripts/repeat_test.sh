#!/usr/bin/env bash
# Repeat one test and count the runs that fail.
# Usage: scripts/repeat_test.sh [--stress[=<workers>]|--stress <workers>] <filter> [count]
#   --stress [workers]  spin busy CPU children (pure arithmetic loops) while
#                       the repeats run, to expose timing races under load.
#                       <workers> defaults to the host's logical core count;
#                       every child is reaped before this script exits.
# REPEAT_TEST_RUN, when set, is the shell command for one run.
# Otherwise the command is: swift test --filter <filter>
# REPEAT_TEST_STRESS_TAG, when set, labels this invocation's spin children:
# each child is started as `sh -c <loop> "stress-tag:<tag>"`, so the tag is
# visible to both `ps` (macOS) and /proc/<pid>/cmdline (Linux) and concurrent
# --stress runs can be told apart by their tag.
# Bash 3.2 compatible.
set -eu

usage() {
    printf '%s\n' "usage: scripts/repeat_test.sh [--stress[=<workers>]] <filter> [count]" >&2
    printf '%s\n' "  --stress [workers]  run <workers> busy CPU spin children (default: host cores) during the repeats" >&2
    printf '%s\n' "  --stress takes <workers> only when <filter> follows it: a lone token after --stress is the filter" >&2
}

is_positive_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ]
}

default_worker_count() {
    if command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu >/dev/null 2>&1; then
        sysctl -n hw.ncpu
    elif command -v nproc >/dev/null 2>&1; then
        nproc
    elif [ -r /proc/cpuinfo ]; then
        grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '8'
    else
        printf '8'
    fi
}

run_once() {
    if [ -n "${REPEAT_TEST_RUN:-}" ]; then
        # The override is a shell command, used by callers that wrap linux-check.
        # It is not the Swift filter.
        sh -c "$REPEAT_TEST_RUN"
    else
        swift test --filter "$1"
    fi
}

STRESS_PIDS=""
cleanup() {
    # Reap every spin child whether the run passed, failed, or got a signal.
    # kill+wait per PID: wait returns after the child is gone, so the caller
    # can rely on zero leftovers once this script has exited. Idempotent:
    # STRESS_PIDS is cleared, so the EXIT trap that follows a signal handler
    # is a no-op instead of killing an already-reaped PID twice.
    local pid
    for pid in $STRESS_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    STRESS_PIDS=""
}

on_signal() {
    # Reap the workers, then exit with 128+<signal> (130=INT, 143=TERM,
    # 129=HUP). Returning into repeat_filter instead would keep burning the
    # remaining repeats after the caller asked us to stop, and would report
    # success for a run that never finished.
    cleanup
    exit "$1"
}

start_stress_workers() {
    local i=1
    # Tag every child with this invocation's token (passed as its $0) so a
    # --stress run in another terminal or worktree is never counted as ours.
    while [ "$i" -le "$stress_workers" ]; do
        sh -c 'x=0; while :; do x=$((x + 1)); done' "stress-tag:$stress_tag" &
        STRESS_PIDS="$STRESS_PIDS $!"
        i=$((i + 1))
    done
    printf '⚙️  已启动 %s 个压力自旋子进程（tag: stress-tag:%s，脚本退出前统一回收）\n' \
        "$stress_workers" "$stress_tag" >&2
}

repeat_filter() {
    filter="$1"
    count="$2"
    passes=0
    failures=0
    i=1
    while [ "$i" -le "$count" ]; do
        if run_once "$filter"; then
            passes=$((passes + 1))
        else
            failures=$((failures + 1))
        fi
        i=$((i + 1))
    done
    printf 'passes=%s failures=%s\n' "$passes" "$failures"
    if [ "$failures" -ne 0 ]; then
        return 1
    fi
    return 0
}

stress_workers=0
if [ "$#" -gt 0 ] && [ "$1" = "--stress" ]; then
    shift
    # Consume a <workers> token only when the filter still follows it, so
    # `repeat_test.sh --stress <numeric-filter>` keeps its filter instead of
    # reading it as a worker count and then failing with "missing filter".
    if [ "$#" -ge 2 ] && is_positive_int "$1"; then
        stress_workers="$1"
        shift
    else
        # --stress with no separate workers token (or a non-numeric next
        # token, which is then the filter): fall back to the host's logical
        # core count.
        stress_workers="$(default_worker_count)"
    fi
elif [ "$#" -gt 0 ]; then
    case "$1" in
        --stress=*)
            stress_workers="${1#--stress=}"
            if ! is_positive_int "$stress_workers"; then
                usage
                printf '%s\n' "--stress=<workers> needs a positive integer, got: $stress_workers" >&2
                exit 2
            fi
            shift
            ;;
    esac
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 2
fi

filter="$1"
count="${2:-20}"
case "$count" in
    ''|*[!0-9]*)
        usage
        printf '%s\n' "count must be a positive integer" >&2
        exit 2
        ;;
esac
if [ "$count" -lt 1 ]; then
    usage
    exit 2
fi

if [ "$stress_workers" -gt 0 ]; then
    stress_tag="${REPEAT_TEST_STRESS_TAG:-repeat-stress-$$}"
    # The tag ends up in a `sh -c` argument and in a `pgrep -f` pattern, so
    # only accept characters that are literal in both.
    case "$stress_tag" in
        ''|*[!A-Za-z0-9._-]*)
            printf '%s\n' "REPEAT_TEST_STRESS_TAG must match [A-Za-z0-9._-], got: $stress_tag" >&2
            exit 2
            ;;
    esac
    # Trap before the first worker exists, so no spawn path can skip cleanup.
    # EXIT covers normal and error exits; INT/TERM/HUP get dedicated handlers
    # that stop the loop instead of resuming it.
    trap cleanup EXIT
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM
    trap 'on_signal 129' HUP
    start_stress_workers
fi

repeat_filter "$filter" "$count"
