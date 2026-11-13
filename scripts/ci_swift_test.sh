#!/usr/bin/env bash
# `swift test` with a stall watchdog for the macOS CI runner.
#
# A deadlocked test can suspend a checked continuation forever: the suite time limit records an
# issue but cannot resume the continuation, so the job sits silent until its 45-minute timeout.
# After SWIFT_TEST_STALL_SECONDS without new output this script samples every swiftpm-testing
# process (Swift stacks) into the job log. It fails the step only when that log has no passing
# summary. A suite that already printed one and then hung at exit is a pass.
#
# Success is decided by Swift Testing's own summary line, never by the exit code or by the
# watchdog. A passing run can fail to exit on macos-26 (SwiftPM #8394), and `script` does not
# reliably forward the child status. A run with no summary line is a failure.
#
# Usage:
#   bash scripts/ci_swift_test.sh [swift test arguments...]
#   bash scripts/ci_swift_test.sh --self-test
set -uo pipefail

evaluate_swift_test_log() {
    local log_file="$1"
    local run_exit="$2"
    local run_stalled="$3"
    local stall_limit="$4"

    # A crash in a later test binary must fail even if an earlier target printed a passing summary.
    if grep -qE 'unexpected signal code|Fatal error:' "$log_file"; then
        echo "::error::swift test crashed during execution"
        return 1
    fi

    # Every Swift Testing target summary must pass, no test issue may be recorded in any target,
    # and no subsequent target (`Test run started.`) may hang before printing its own summary.
    local summary_verdict
    summary_verdict="$(awk '
        /(^|◇ )Test run started\./ { pending_target = 1; next }
        /Test run with [0-9]+ tests? in [0-9]+ suites?/ {
            summaries++
            pending_target = 0
            if ($0 !~ /Test run with [0-9]+ tests? in [0-9]+ suites? passed/) {
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

run_self_test() {
    local tmp failures=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-swift-test-selftest.XXXXXX")"

    assert_verdict() {
        local label="$1" expected="$2" exit_code="$3" stalled="$4"
        shift 4
        printf '%s\n' "$@" >"$tmp/case.log"
        local actual=0 out
        out="$(evaluate_swift_test_log "$tmp/case.log" "$exit_code" "$stalled" 300 2>&1)" || actual=$?
        if [ "$actual" -eq "$expected" ]; then
            printf 'PASS %s\n' "$label"
        else
            printf 'FAIL %s (expected %s, got %s): %s\n' "$label" "$expected" "$actual" "$out" >&2
            failures=$((failures + 1))
        fi
    }

    assert_verdict "正常全部通过" 0 0 0 \
        "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds."
    assert_verdict "macos-26 汇总通过后退出挂起仍放行" 0 143 1 \
        "✔ Test run with 1 test in 1 suite passed after 0.1 seconds."
    assert_verdict "前一套件通过、后一套件失败必须拒绝" 1 1 0 \
        "✔ Test run with 10 tests in 2 suites passed after 0.2 seconds." \
        "✘ Test run with 4 tests in 1 suite failed after 0.3 seconds."
    assert_verdict "前一套件失败、后一套件通过必须拒绝" 1 1 0 \
        "✘ Test run with 10 tests in 2 suites failed after 0.2 seconds." \
        "✔ Test run with 4 tests in 1 suite passed after 0.3 seconds."
    assert_verdict "前一套件报错无汇总、后一套件通过必须拒绝" 1 1 0 \
        "✘ Test brokenCase() recorded an issue at BarTests.swift:12:5: Expectation failed" \
        "✔ Test run with 4 tests in 1 suite passed after 0.3 seconds."
    assert_verdict "前一套件通过、后一套件启动后静默死锁无汇总必须拒绝" 1 143 1 \
        "◇ Test run started." \
        "✔ Test run with 10 tests in 2 suites passed after 0.2 seconds." \
        "◇ Test run started."
    assert_verdict "前一套件通过、后一进程信号崩溃必须拒绝" 1 1 0 \
        "✔ Test run with 10 tests in 2 suites passed after 0.2 seconds." \
        "error: Exited with unexpected signal code 5"
    assert_verdict "前一套件通过、后一进程 Fatal error 必须拒绝" 1 1 0 \
        "✔ Test run with 10 tests in 2 suites passed after 0.2 seconds." \
        "Swift/ContiguousArrayBuffer.swift:600: Fatal error: Index out of range"
    assert_verdict "前一套件通过、后一套件报错后死锁无汇总必须拒绝" 1 143 1 \
        "✔ Test run with 10 tests in 2 suites passed after 0.2 seconds." \
        "✘ Test deadlockedCase() recorded an issue at FooTests.swift:9:1: Expectation failed"
    assert_verdict "完全无汇总且死锁必须拒绝" 1 143 1 \
        "Building for debugging..."

    rm -rf "$tmp"
    if [ "$failures" -ne 0 ]; then
        echo "❌ ci_swift_test 自测失败 ${failures} 项" >&2
        return 1
    fi
    echo "✅ ci_swift_test 自测通过"
    return 0
}

if [ "${1:-}" = "--self-test" ]; then
    run_self_test
    exit $?
fi

stall_seconds="${SWIFT_TEST_STALL_SECONDS:-300}"
tick=10
log="$(mktemp -t swift-test)"
echo "swift test log: $log"

# A pty keeps stdout line-buffered: without it the final summary can sit in a 4 KiB buffer
# forever when the process hangs at exit, and the watchdog would never see the result.
script -q /dev/null swift test "$@" >"$log" 2>&1 &
test_pid=$!
# Stream the log into the job output so a killed job still leaves the last test visible.
tail -n +1 -f "$log" &
tail_pid=$!

sample_process() {
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
# Read the summary before treating a stall as failure. The macos-26 exit hang writes a passing
# summary and then stays alive, so the watchdog sets stall_detected on a suite that already passed.
evaluate_swift_test_log "$log" "$exit_code" "$stall_detected" "$stall_seconds"
exit $?
