#!/usr/bin/env bash
# Repeat one test and count the runs that fail.
# Usage: scripts/repeat_test.sh [--stress[=<workers>]|--stress <workers>] <filter> [count]
#   --stress [workers]  spin busy CPU children (pure arithmetic loops) while
#                       the repeats run, to expose timing races under load.
#                       <workers> defaults to the host's logical core count;
#                       every child is reaped before this script exits.
# REPEAT_TEST_RUN, when set, is the shell command for one run.
# Otherwise the command is: swift test --filter <filter>
# Bash 3.2 compatible.
set -eu

usage() {
    printf '%s\n' "usage: scripts/repeat_test.sh [--stress[=<workers>]] <filter> [count]" >&2
    printf '%s\n' "  --stress [workers]  run <workers> busy CPU spin children (default: host cores) during the repeats" >&2
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
    # can rely on zero leftovers once this script has exited.
    local pid
    for pid in $STRESS_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    STRESS_PIDS=""
}

start_stress_workers() {
    local i=1
    while [ "$i" -le "$stress_workers" ]; do
        sh -c 'x=0; while :; do x=$((x + 1)); done' &
        STRESS_PIDS="$STRESS_PIDS $!"
        i=$((i + 1))
    done
    printf '⚙️  已启动 %s 个压力自旋子进程（脚本退出前统一回收）\n' "$stress_workers" >&2
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
    if [ "$#" -gt 0 ] && is_positive_int "$1"; then
        stress_workers="$1"
        shift
    else
        # --stress with no count (or a non-numeric next token, which is then
        # the filter): fall back to the host's logical core count.
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
    # Trap before the first worker exists, so no spawn path can skip cleanup.
    trap cleanup EXIT INT TERM HUP
    start_stress_workers
fi

repeat_filter "$filter" "$count"
