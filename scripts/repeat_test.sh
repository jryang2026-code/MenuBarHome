#!/usr/bin/env bash
# Repeat one test and count the runs that fail.
# Usage: scripts/repeat_test.sh <filter> [count]
# REPEAT_TEST_RUN, when set, is the shell command for one run.
# Otherwise the command is: swift test --filter <filter>
# Bash 3.2 compatible.
set -eu

usage() {
    printf '%s\n' "usage: scripts/repeat_test.sh <filter> [count]" >&2
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

repeat_filter "$filter" "$count"
