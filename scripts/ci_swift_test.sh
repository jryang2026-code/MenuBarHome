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
# A crash additionally dumps filtered fields from the macOS `ReportCrash` `.ips` report for the
# crashing test process (exception type, faulting thread, and `atos`-symbolized stack frames): the
# runner is destroyed with the job, so this metadata is only readable inside the step that saw it.
#
# A failing run is rerun once, filtered to just the failing cases, to separate a flake from a real
# break inside one job (see `retry_plan`). The rerun needs the case's `Suite.func`, which the log
# does not print: `--filter` matches the test id, never the display name, so the function is read
# from the source file named in the recorded location. A rerun that passes turns the job green with
# `::warning::flaky tests passed on retry` plus a `$GITHUB_STEP_SUMMARY` table; a crash, a stall,
# more than five failing cases, or a rerun that fails again keeps the failure. CI only (`CI=true`);
# `CI_RETRY_FAILED=0/1` overrides either way.
#
# Usage:
#   bash scripts/ci_swift_test.sh [swift test arguments...]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Prints filtered crash metadata from newest macOS `.ips` reports written for this test run's
# process (`swiftpm-testing-helper` / `xctest`) matching the captured PID / parent-PID tree.
#
# Diagnosis is bounded by a single total deadline and must never change the step verdict: every
# command is best-effort and every failure prints a warning instead of a non-zero status.
dump_macos_crash_reports() {
    local min_epoch="${1:-0}"
    local run_pids="${2:-}"
    if [ "$(uname -s)" != "Darwin" ]; then
        return 0
    fi
    echo "=== macOS crash reports (ReportCrash)"
    CRASH_REPORT_MIN_EPOCH="$min_epoch" \
    CRASH_REPORT_RUN_PIDS="${CRASH_REPORT_RUN_PIDS:-$run_pids}" \
    CRASH_REPORT_SEARCH_DIRS="${CRASH_REPORT_SEARCH_DIRS:-$(printf '%s\n%s\n' "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports")}" \
        python3 - <<'PY' || echo "::warning::could not read the macOS crash reports (see the log above)"
import glob
import json
import os
import re
import subprocess
import time

# Single end-to-end budget across report polling and `atos` symbolization.
TOTAL_BUDGET_SECONDS = max(1.0, float(os.environ.get("CRASH_REPORT_BUDGET_SECONDS", "90")))
# ReportCrash flushes the `.ips` asynchronously after the abort and a loaded runner can take a while,
# so poll instead of racing a fixed sleep.
REPORT_WAIT_SECONDS = min(45.0, TOTAL_BUDGET_SECONDS)
POLL_SECONDS = 2.0
ALLOWED_PROC_NAMES = ("swiftpm-testing-helper", "xctest")
NAME_PATTERNS = (
    "swiftpm-testing-helper-*",
    "swiftpm-testing-helper.*",
    "xctest-*",
    "xctest.*",
)
MAX_REPORTS = 2
ATOS_PER_CALL_CAP_SECONDS = 15.0
# Only our own modules are worth an `atos` call: system frames keep the symbols ReportCrash recorded.
SYMBOLIZE_IMAGES = ("MenuBarMijiaPackageTests", "MijiaCore", "MenuBarMijiaApp")
ABS_SOURCE_LOC_RE = re.compile(r"\((?:/[^():]+)+/([^/():]+)(:\d+)?\)")

search_dirs = [line for line in os.environ.get("CRASH_REPORT_SEARCH_DIRS", "").splitlines() if line]
try:
    min_epoch = float(os.environ.get("CRASH_REPORT_MIN_EPOCH", "0"))
except ValueError:
    min_epoch = 0.0

run_pids = set()
for token in re.split(r"[\s,]+", os.environ.get("CRASH_REPORT_RUN_PIDS", "").strip()):
    if not token:
        continue
    try:
        parsed = int(token)
    except ValueError:
        continue
    if parsed > 0:
        run_pids.add(parsed)

total_deadline = time.monotonic() + TOTAL_BUDGET_SECONDS


def remaining_budget():
    return max(0.0, total_deadline - time.monotonic())


def to_int(value):
    try:
        return int(value, 0) if isinstance(value, str) else int(value)
    except (TypeError, ValueError):
        return None


def to_hex(value):
    number = to_int(value)
    return "0x%x" % number if number is not None else str(value)


def parse_ips(path):
    try:
        with open(path, "r", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None
    # An `.ips` is two JSON documents: a one-line header, then the report body.
    try:
        header = json.loads(lines[0]) if lines else {}
        body = json.loads("\n".join(lines[1:])) if len(lines) > 1 else {}
    except ValueError:
        return None
    if not isinstance(header, dict) or not isinstance(body, dict):
        return None
    return header, body


def matches_run_report(header, body):
    proc_name = str(header.get("app_name") or body.get("procName") or "")
    if proc_name not in ALLOWED_PROC_NAMES:
        return False
    if not run_pids:
        return True
    pid = to_int(body.get("pid"))
    if pid is None:
        pid = to_int(header.get("pid"))
    parent_pid = to_int(body.get("parentPid"))
    if parent_pid is None:
        parent_pid = to_int(header.get("parentPid"))
    return (pid in run_pids) or (parent_pid in run_pids)


def recent_reports():
    now = time.time()
    cutoff = min_epoch if min_epoch > 0 else (now - 600.0)
    found = []
    seen = set()
    for directory in search_dirs:
        for pattern in NAME_PATTERNS:
            for path in glob.glob(os.path.join(directory, pattern + ".ips")):
                if path in seen:
                    continue
                seen.add(path)
                try:
                    modified = os.path.getmtime(path)
                except OSError:
                    continue
                if modified < cutoff:
                    continue
                parsed = parse_ips(path)
                if parsed is None:
                    continue
                header, body = parsed
                if matches_run_report(header, body):
                    found.append((modified, path, header, body))
    found.sort(key=lambda item: item[0], reverse=True)
    return found


poll_deadline = min(total_deadline, time.monotonic() + REPORT_WAIT_SECONDS)
candidates = recent_reports()
while not candidates and time.monotonic() < poll_deadline:
    sleep_for = min(POLL_SECONDS, max(0.0, poll_deadline - time.monotonic()))
    if sleep_for <= 0:
        break
    time.sleep(sleep_for)
    candidates = recent_reports()


def filter_fields(mapping, allowed_keys):
    if not isinstance(mapping, dict):
        return None
    filtered = {key: mapping[key] for key in allowed_keys if mapping.get(key) not in (None, "", {}, [])}
    return filtered or None


def show(label, value):
    if value not in (None, "", {}, []):
        print("%s: %s" % (label, json.dumps(value, ensure_ascii=False, sort_keys=True)))


def format_source_location(source_file, source_line):
    name = os.path.basename(str(source_file).strip())
    if not name:
        return ""
    line = source_line if source_line not in (None, "") else "?"
    return "  (%s:%s)" % (name, line)


def sanitize_atos_line(text):
    return ABS_SOURCE_LOC_RE.sub(lambda match: "(%s%s)" % (match.group(1), match.group(2) or ""), text)


def atos_frame(binary, base, address):
    budget = remaining_budget()
    if budget < 1.0:
        return "skipped (diagnosis budget exhausted)"
    if not binary or not os.path.exists(binary):
        return "binary not on disk"
    try:
        result = subprocess.run(
            ["atos", "-o", binary, "-l", to_hex(base), to_hex(address)],
            capture_output=True,
            text=True,
            timeout=min(ATOS_PER_CALL_CAP_SECONDS, budget),
        )
    except Exception as error:  # atos missing or timed out: keep the raw frame
        return "atos failed (%s)" % type(error).__name__
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return sanitize_atos_line(lines[0]) if lines else "atos produced no symbol"


def dump_ips(path, header, body):
    proc_name = str(header.get("app_name") or body.get("procName") or "")
    print("--- %s" % os.path.basename(path))
    print(
        "report: %s pid=%s parentPid=%s bug_type=%s timestamp=%s"
        % (
            proc_name,
            body.get("pid", header.get("pid")),
            body.get("parentPid", header.get("parentPid")),
            header.get("bug_type"),
            header.get("timestamp"),
        )
    )
    show("exception", filter_fields(body.get("exception"), ("type", "signal", "subtype")))
    show("termination", filter_fields(body.get("termination"), ("namespace", "code", "indicator")))

    images = body.get("usedImages") or body.get("images") or []
    threads = body.get("threads") or []
    faulting = body.get("faultingThread")
    if not isinstance(faulting, int) or not 0 <= faulting < len(threads):
        faulting = next((index for index, thread in enumerate(threads) if thread.get("triggered")), None)
    if faulting is None:
        print("no faulting thread recorded")
        return True
    frames = threads[faulting].get("frames") or []
    print("faulting thread %s: %d frames" % (faulting, len(frames)))
    for depth, frame in enumerate(frames):
        index = frame.get("imageIndex")
        image = images[index] if isinstance(index, int) and 0 <= index < len(images) else {}
        module = image.get("name") or "?"
        symbol = frame.get("symbol") or "<no symbol>"
        if isinstance(frame.get("symbolLocation"), int):
            symbol = "%s + %d" % (symbol, frame["symbolLocation"])
        source = ""
        if frame.get("sourceFile"):
            source = format_source_location(frame["sourceFile"], frame.get("sourceLine"))
        print("  #%-2d %-24s %s%s" % (depth, module, symbol, source))
        if source or not any(token in module for token in SYMBOLIZE_IMAGES):
            continue
        base = to_int(image.get("base"))
        offset = to_int(frame.get("imageOffset"))
        if base is None or offset is None:
            continue
        print("      atos: %s" % atos_frame(image.get("path") or "", base, base + offset))
    return True


dumped = 0
for _, path, header, body in candidates:
    if dumped >= MAX_REPORTS:
        break
    if remaining_budget() <= 0:
        print("diagnosis budget (%.0fs) exhausted" % TOTAL_BUDGET_SECONDS)
        break
    try:
        if dump_ips(path, header, body):
            dumped += 1
    except Exception as error:  # never let diagnosis change the step verdict
        print("could not read %s (%s)" % (os.path.basename(path), type(error).__name__))

if dumped == 0:
    print("no matching test-process .ips report created after epoch %.0f" % min_epoch)
PY
    echo "=== end of macOS crash reports"
}

# ---------------------------------------------------------------------------------------------
# Log helpers. scripts/test_ci_swift_test.sh sources this file and drives them with fixture logs.
# ---------------------------------------------------------------------------------------------

# A test process that died takes the summary with it: the crash outranks any passing target.
log_has_crash() {
    grep -qE 'unexpected signal code|Fatal error:|crashed during execution' "$1"
}

# Swift Testing's own verdict: every target summary passed, no issue was recorded in any target,
# and no later target (`Test run started.`) hung before printing its own summary.
swift_test_summary_verdict() {
    awk '
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
    ' "$1"
}

# Failing cases as `name<TAB>File.swift<TAB>line`, deduped on the case name. The location kept is
# the first one recorded: later issues in the same case repeat the same breakage.
failed_test_cases() {
    awk '
        match($0, /✘ Test ".*" recorded an issue at [^ :]+:[0-9]+/) {
            text = substr($0, RSTART, RLENGTH)
            sub(/^✘ Test "/, "", text)
            cut = index(text, "\" recorded an issue at ")
            if (cut == 0) { next }
            name = substr(text, 1, cut - 1)
            rest = substr(text, cut)
            sub(/^" recorded an issue at /, "", rest)
            if (!match(rest, /:[0-9]+$/)) { next }
            file = substr(rest, 1, RSTART - 1)
            if (name in seen) { next }
            seen[name] = 1
            printf "%s\t%s\t%s\n", name, file, substr(rest, RSTART + 1)
        }
    ' "$1"
}

failed_case_count() {
    failed_test_cases "$1" | wc -l | tr -d ' '
}

# `swift test --filter` matches the test id (`Module.Suite/func()`), never the display name, so a
# failing case is traced back to its function through the source file named in its log location.
# Prints one `Suite.func` per failing case (a bare `func` when no enclosing type was found).
retry_filter_args() { # rows_file repo_root
    local rows="$1" root="$2" name file line path candidate first derived seen=""
    while IFS="$(printf '\t')" read -r name file line; do
        [ -n "$file" ] && [ -n "$line" ] || continue
        path=""
        first=""
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            [ -n "$first" ] || first="$candidate"
            # Two test files can share a basename; the one quoting the case name is the right one.
            if grep -Fq -- "$name" "$candidate"; then
                path="$candidate"
                break
            fi
        done <<EOF
$(find "$root/Tests" -name "$file" -type f 2>/dev/null || true)
EOF
        [ -n "$path" ] || path="$first"
        [ -n "$path" ] || continue
        derived="$(awk -v LINE="$line" '
            { src[NR] = $0 }
            END {
                fn_line = 0
                fn_name = ""
                for (i = LINE; i >= 1; i--) {
                    if (match(src[i], /^[[:space:]]*(static[[:space:]]+)?func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
                        text = substr(src[i], RSTART, RLENGTH)
                        sub(/^[[:space:]]*(static[[:space:]]+)?func[[:space:]]+/, "", text)
                        fn_name = text
                        fn_line = i
                        break
                    }
                }
                if (fn_name == "") { exit 0 }
                indent = match(src[fn_line], /[^[:space:]]/) - 1
                suite = ""
                for (i = fn_line - 1; i >= 1; i--) {
                    if (match(src[i], /^[[:space:]]*(@[A-Za-z]+\(.*\)[[:space:]]+)?((final|public|internal)[[:space:]]+)?(struct|class|enum|extension)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
                        candidate_line = substr(src[i], RSTART, RLENGTH)
                        ind = match(src[i], /[^[:space:]]/) - 1
                        if (ind >= indent) { continue }
                        sub(/^.*(struct|class|enum|extension)[[:space:]]+/, "", candidate_line)
                        if (match(candidate_line, /[A-Za-z_][A-Za-z0-9_]*/)) {
                            suite = substr(candidate_line, RSTART, RLENGTH)
                        }
                        break
                    }
                }
                print (suite == "" ? fn_name : suite "." fn_name)
            }
        ' "$path")"
        [ -n "$derived" ] || continue
        case " $seen " in
            *" $derived "*) continue ;;
        esac
        seen="$seen $derived"
        printf '%s\n' "$derived"
    done <"$rows"
}

# Did the rerun actually pass? `pass` also needs every failing case to show up as passed: a filter
# that matched nothing would otherwise look like a green rerun.
retry_verdict() { # rows_file retry_log -> pass | crash | fail | empty | unverified
    local rows="$1" retry_log="$2" name rest
    if log_has_crash "$retry_log"; then
        echo "crash"
        return 0
    fi
    if [ "$(swift_test_summary_verdict "$retry_log")" != "pass" ]; then
        echo "fail"
        return 0
    fi
    if grep -q 'No matching test cases were run' "$retry_log"; then
        echo "empty"
        return 0
    fi
    while IFS="$(printf '\t')" read -r name rest; do
        [ -n "$name" ] || continue
        if ! grep -qF "✔ Test \"$name\" passed" "$retry_log"; then
            echo "unverified"
            return 0
        fi
    done <"$rows"
    echo "pass"
}

# Should the failing run be rerun once? A crash, a stall, or more than five failing cases is a
# real break: rerunning those only burns runner minutes.
retry_plan() { # log retry_enabled stalled -> retry | off | crash | stall | no-cases | too-many
    local log="$1" enabled="$2" stalled="$3" count
    if [ "$enabled" -ne 1 ]; then
        echo "off"
        return 0
    fi
    if log_has_crash "$log"; then
        echo "crash"
        return 0
    fi
    if [ "$stalled" -ne 0 ]; then
        echo "stall"
        return 0
    fi
    count="$(failed_case_count "$log")"
    if [ "$count" -eq 0 ]; then
        echo "no-cases"
        return 0
    fi
    if [ "$count" -gt 5 ]; then
        echo "too-many"
        return 0
    fi
    echo "retry"
}

# The rerun cleared the cases: say so in the log and on the job summary page.
report_flaky() { # rows_file
    local rows="$1" name file line names="" table="" count=0
    while IFS="$(printf '\t')" read -r name file line; do
        [ -n "$name" ] || continue
        count=$((count + 1))
        names="${names:+$names, }$name"
        table="${table}| \`$(printf '%s' "$name" | sed 's/|/\\|/g')\` | \`${file}:${line}\` |
"
    done <"$rows"
    [ "$count" -gt 0 ] || return 0
    echo "::warning::flaky tests passed on retry: ${names}"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            printf '### flaky tests passed on retry（%s）\n\n' "$count"
            printf '首次失败的位置：\n\n'
            printf '| 用例 | 首次失败 |\n| --- | --- |\n%s' "$table"
        } >>"$GITHUB_STEP_SUMMARY"
    fi
}

# One `swift test` run under the stall watchdog, streaming its log into the job output.
# Sets RUN_EXIT, RUN_STALLED, RUN_STARTED (epoch) and RUN_PIDS for the caller.
run_with_watchdog() { # log_file script_arguments...
    local log="$1"
    shift
    local stall_seconds="${SWIFT_TEST_STALL_SECONDS:-300}"
    local tick=10 pid_poll_step=1
    local pids_file test_pid tail_pid stalled=0 last_size=-1 stall_detected=0
    local since_size_check=0 step_elapsed size exit_code
    pids_file="$(mktemp -t swift-test-pids)"
    ALL_PID_FILES="${ALL_PID_FILES:-} ${pids_file}"
    echo "swift test log: $log"
    RUN_STARTED="$(date +%s)"

    # A pty keeps stdout line-buffered: without it the final summary can sit in a 4 KiB buffer
    # forever when the process hangs at exit, and the watchdog would never see the result.
    script -q /dev/null swift test "$@" >"$log" 2>&1 &
    test_pid=$!
    printf '%s\n' "$test_pid" >"$pids_file"
    record_descendant_pids "$test_pid" "$pids_file"
    # Stream the log into the job output so a killed job still leaves the last test visible.
    tail -n +1 -f "$log" &
    tail_pid=$!

    sample_process() {
        for pid in $(pgrep -f swiftpm-testing || true); do
            echo "=== sample ${pid}"
            sample "$pid" 5 -mayDie 2>/dev/null || true
        done
    }

    while kill -0 "$test_pid" 2>/dev/null; do
        sleep "$pid_poll_step"
        record_descendant_pids "$test_pid" "$pids_file"
        since_size_check=$((since_size_check + pid_poll_step))
        if [ "$since_size_check" -lt "$tick" ]; then
            continue
        fi
        step_elapsed="$since_size_check"
        since_size_check=0
        size="$(wc -c <"$log" | tr -d ' ')"
        if [ "$size" = "$last_size" ]; then
            stalled=$((stalled + step_elapsed))
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
    record_descendant_pids "$test_pid" "$pids_file"
    wait "$test_pid" 2>/dev/null
    exit_code=$?
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    RUN_EXIT="$exit_code"
    RUN_STALLED="$stall_detected"
    RUN_PIDS="$(tr '\n' ',' <"$pids_file" | sed 's/,$//')"
}

record_descendant_pids() {
    local root_pid="$1"
    local pids_file="$2"
    ps -eo pid=,ppid= 2>/dev/null | awk -v root="$root_pid" -v file="$pids_file" '
        BEGIN {
            known[root] = 1
            while ((getline line < file) > 0) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line ~ /^[0-9]+$/) known[line] = 1
            }
            close(file)
        }
        {
            p = $1; pp = $2
            if (p ~ /^[0-9]+$/ && pp ~ /^[0-9]+$/) {
                n++
                pids[n] = p
                ppids[n] = pp
            }
        }
        END {
            changed = 1
            while (changed) {
                changed = 0
                for (i = 1; i <= n; i++) {
                    if ((ppids[i] in known) && !(pids[i] in known)) {
                        known[pids[i]] = 1
                        changed = 1
                    }
                }
            }
            for (k in known) print k
        }
    ' > "${pids_file}.tmp" 2>/dev/null && mv "${pids_file}.tmp" "$pids_file" || rm -f "${pids_file}.tmp"
}

# A flake is reported as a passing job with a warning, so the fix stays visible. Everything else
# keeps the original verdict and the original error lines.
main() {
    ALL_PID_FILES=""
    trap 'for f in $ALL_PID_FILES; do rm -f "$f" "$f.tmp"; done' EXIT
    local retry_enabled=0
    case "${CI:-}" in
        true | 1) retry_enabled=1 ;;
    esac
    case "${CI_RETRY_FAILED:-}" in
        0) retry_enabled=0 ;;
        1) retry_enabled=1 ;;
    esac

    local first_log rows_file retry_log plan filter_args filter_count retry_state
    first_log="$(mktemp -t swift-test)"
    run_with_watchdog "$first_log" "$@"
    local first_exit="$RUN_EXIT" first_stalled="$RUN_STALLED" first_pids="$RUN_PIDS" first_started="$RUN_STARTED"
    echo "=== swift test process exit: ${first_exit} (stalled=${first_stalled})"

    # A crash in a later test binary must fail even if an earlier target printed a passing summary.
    if log_has_crash "$first_log"; then
        echo "::error::swift test crashed during execution"
        # The runner goes away with the job: dump filtered crash fields before failing.
        dump_macos_crash_reports "$first_started" "$first_pids" || true
        return 1
    fi

    # Read the summary before treating a stall as failure. The macos-26 exit hang writes a passing
    # summary and then stays alive, so the watchdog sets stalled on a suite that already passed.
    if [ "$(swift_test_summary_verdict "$first_log")" = "pass" ]; then
        if [ "$first_stalled" -eq 1 ] || [ "$first_exit" -ne 0 ]; then
            echo "::warning::the suite passed but swift test did not exit cleanly (exit ${first_exit}, stalled=${first_stalled}); accepting the passing summary"
        fi
        return 0
    fi

    # Swift Testing's own summary failed. Rerunning only the failing cases separates a flake from a
    # real break in one job instead of one manual `gh run rerun --failed` per red push.
    plan="$(retry_plan "$first_log" "$retry_enabled" "$first_stalled")"
    if [ "$plan" = "retry" ]; then
        rows_file="$(mktemp -t swift-test-cases)"
        failed_test_cases "$first_log" >"$rows_file"
        filter_args=()
        filter_count=0
        local filter_value
        while IFS= read -r filter_value; do
            [ -n "$filter_value" ] || continue
            filter_args[${#filter_args[@]}]="--filter"
            filter_args[${#filter_args[@]}]="$filter_value"
            filter_count=$((filter_count + 1))
        done <<EOF
$(retry_filter_args "$rows_file" "$ROOT_DIR")
EOF
        if [ "$filter_count" -eq 0 ]; then
            echo "::warning::could not trace the failing cases back to a test function; not retrying"
        else
            echo "=== flaky check: rerunning ${filter_count} failing case(s) with --filter"
            retry_log="$(mktemp -t swift-test-retry)"
            run_with_watchdog "$retry_log" "$@" "${filter_args[@]}"
            echo "=== retry process exit: ${RUN_EXIT} (stalled=${RUN_STALLED})"
            retry_state="$(retry_verdict "$rows_file" "$retry_log")"
            if [ "$retry_state" = "pass" ]; then
                report_flaky "$rows_file"
                return 0
            fi
            echo "::warning::the retry did not clear the failure (${retry_state}); reporting the first run"
        fi
    elif [ "$retry_enabled" -eq 1 ]; then
        case "$plan" in
            stall) echo "::warning::not retrying: the run stalled" ;;
            too-many) echo "::warning::not retrying: more than five failing cases, which is a real break" ;;
        esac
    fi

    if [ "$first_stalled" -eq 1 ]; then
        echo "::error::swift test produced no output for ${SWIFT_TEST_STALL_SECONDS:-300}s; the test process is deadlocked"
        return 1
    fi
    echo "::error::swift test produced no passing summary"
    return 1
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
    exit $?
fi
