#!/usr/bin/env bash
# Repeat one test and count the runs that fail.
# Usage: scripts/repeat_test.sh <filter> [count]
#        scripts/repeat_test.sh --self-test
# REPEAT_TEST_RUN, when set, is the shell command for one run.
# Otherwise the command is: swift test --filter <filter>
# Bash 3.2 compatible.
set -eu

usage() {
    printf '%s\n' "usage: scripts/repeat_test.sh <filter> [count]" >&2
    printf '%s\n' "       scripts/repeat_test.sh --self-test" >&2
}

run_once() {
    if [ -n "${REPEAT_TEST_RUN:-}" ]; then
        # The override is a shell command, used by the self-test and by callers
        # that wrap linux-check. It is not the Swift filter.
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

self_test() {
    script="$0"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/flaky.sh" <<'EOF'
#!/bin/sh
file="$1"
n=0
if [ -f "$file" ]; then
    n=$(cat "$file")
fi
n=$((n + 1))
printf '%s\n' "$n" > "$file"
# Even runs fail. Four runs then produce two failures.
test $((n % 2)) -eq 1
EOF
    chmod +x "$tmp/flaky.sh"

    if "$script" >/dev/null 2>"$tmp/noargs.err"; then
        printf '%s\n' "self-test: missing filter should fail" >&2
        return 1
    fi
    if ! grep -q "usage: scripts/repeat_test.sh" "$tmp/noargs.err"; then
        printf '%s\n' "self-test: missing filter should print usage" >&2
        return 1
    fi

    set +e
    REPEAT_TEST_RUN="$tmp/flaky.sh $tmp/count" "$script" filter 4 >"$tmp/flaky.out"
    flaky_status=$?
    set -e
    if [ "$flaky_status" -eq 0 ]; then
        printf '%s\n' "self-test: flaky command should exit non-zero" >&2
        return 1
    fi
    if ! grep -q "passes=2 failures=2" "$tmp/flaky.out"; then
        printf '%s\n' "self-test: expected passes=2 failures=2" >&2
        cat "$tmp/flaky.out" >&2
        return 1
    fi

    set +e
    REPEAT_TEST_RUN="exit 0" "$script" filter 3 >"$tmp/ok.out"
    ok_status=$?
    set -e
    if [ "$ok_status" -ne 0 ]; then
        printf '%s\n' "self-test: a passing command should exit 0" >&2
        return 1
    fi
    if ! grep -q "passes=3 failures=0" "$tmp/ok.out"; then
        printf '%s\n' "self-test: expected passes=3 failures=0" >&2
        return 1
    fi
    printf '%s\n' "repeat_test.sh self-test passed"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
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

repeat_filter "$filter" "$count"
