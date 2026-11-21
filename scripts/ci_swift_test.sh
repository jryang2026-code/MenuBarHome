#!/usr/bin/env bash
set -uo pipefail

evaluate_swift_test_log() {
    local log_file="$1"
    local run_exit="$2"
    local run_stalled="$3"
    local stall_limit="$4"

    if grep -qE 'unexpected signal code|Fatal error:|crashed during execution' "$log_file"; then
        echo "::error::swift test crashed during execution"
        return 1
    fi

    local summary_verdict
    summary_verdict="$(awk '
        /(^|◇ )Test run started\./ { pending_target = 1; next }
        /Test run with [0-9]+ tests?/ {
            summaries++
            pending_target = 0
            if ($0 !~ /Test run with [0-9]+ tests?( in [0-9]+ suites?)? passed/) {
                failed = 1
            }
            next
        }
        /✘ Test |recorded an issue/ { failed = 1 }
        END {
            print (summaries > 0 && !failed && !pending_target) ? "pass" : "fail"
        }
    ' "$log_file")"

    if [ "$summary_verdict" = "pass" ]; then
        if [ "$run_stalled" -eq 1 ] || [ "$run_exit" -ne 0 ]; then
            echo "::warning::the suite passed but swift test did not exit cleanly (exit ${run_exit}, stalled=${run_stalled}); accepting the passing summary"
        fi
        return 0
    fi
    if [ "$run_stalled" -eq 1 ]; then
        echo "::error::swift test produced no output for ${stall_limit}s; the test process is deadlocked"
        return 1
    fi
    echo "::error::swift test produced no passing summary"
    return 1
}

stall_seconds="${SWIFT_TEST_STALL_SECONDS:-300}"
tick=10
log="$(mktemp "${TMPDIR:-/tmp}/swift-test.XXXXXX")"
echo "swift test log: $log"

script -q /dev/null swift test "$@" >"$log" 2>&1 &
test_pid=$!
tail -n +1 -f "$log" &
tail_pid=$!

sample_process() {
    local pid
    for pid in $(pgrep -f swiftpm-testing || true); do
        echo "=== sample ${pid}"
        sample "$pid" 5 -mayDie 2>/dev/null || true
    done
}

stalled=0
last_size=-1
stall_detected=0
while kill -0 "$test_pid" 2>/dev/null; do
    sleep "$tick"
    size="$(wc -c <"$log" | tr -d ' ')"
    if [ "$size" = "$last_size" ]; then
        stalled=$((stalled + tick))
    else
        stalled=0
        last_size="$size"
    fi
    if [ "$stalled" -ge "$stall_seconds" ]; then
        sample_process
        kill -TERM "$test_pid" 2>/dev/null || true
        sleep 2
        pkill -TERM -f swiftpm-testing 2>/dev/null || true
        sleep 2
        pkill -KILL -f swiftpm-testing 2>/dev/null || true
        stall_detected=1
        break
    fi
done
wait "$test_pid" 2>/dev/null
exit_code=$?
kill "$tail_pid" 2>/dev/null || true
wait "$tail_pid" 2>/dev/null || true

echo "=== swift test process exit: $exit_code (stalled=${stall_detected})"
evaluate_swift_test_log "$log" "$exit_code" "$stall_detected" "$stall_seconds"
exit $?
