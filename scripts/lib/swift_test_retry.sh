#!/usr/bin/env bash
# `swift test` 失败用例只重跑一次：解析与判定的唯一实现，macOS 的 scripts/ci_swift_test.sh 与
# Linux 的 scripts/linux-check/run.sh 都 source 这一份。只 source，不执行。
#
# 一次失败运行能不能重跑，看这里：不超过五个失败用例、没有崩溃、没有 stall、没有缺基线的快照。
# 重跑按 `Suite.func` 加 `--filter` 只跑失败的那几个用例，全过就判为通过（`::warning::` +
# `$GITHUB_STEP_SUMMARY`），否则维持第一轮的失败。CI 之外默认不重跑。
#
# 调用方约定：
#   swift_test_run_attempt <log> [swift test 参数...]
#       跑一次 `swift test`，把合并输出写进 <log>，并设置 RUN_EXIT / RUN_STALLED。
#       默认实现是下面的 run_with_watchdog（stall 看门狗），两个调用方都用它，平台差异只通过
#       下面三个开关给出。
#   SWIFT_TEST_LAUNCH_CMD   让子进程 stdout 在重定向到文件时仍保持行缓冲的命令前缀：
#                           macOS 用 `script -q /dev/null`（BSD 写法），Linux 用 `stdbuf -oL -eL`。
#                           留空则直接跑（Linux 上没有 util-linux 的 script 时不写 `-c` 的变体）。
#   SWIFT_TEST_SAMPLE_FN    看门狗触发时用来 dump 卡住进程现场的函数名（macOS `sample`，Linux
#                           没有 `sample`，用 ps 快照）。
#   SWIFT_TEST_SOURCE_ROOTS 定位 `Suite.func` 时搜索源码的目录，多个用换行或逗号分隔；默认是
#                           `$repo_root/Tests`。run.sh 指向 `.work` 里的副本，因为日志记录的
#                           `文件:行号` 属于那份副本（副本头部注入了 3 行）。
#
# The macOS `.ips` crash report dump lives in ci_swift_test.sh: Linux has no ReportCrash.

SWIFT_TEST_LAUNCH_CMD="${SWIFT_TEST_LAUNCH_CMD:-}"

# ---------------------------------------------------------------------------------------------
# 日志解析
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
# the first one recorded: later issues in the same case repeat the same breakage. Both issue forms
# count: `recorded an issue at File.swift:1:2` and the parameterized
# `recorded an issue with 1 argument value → 2 at File.swift:1:2`.
failed_test_cases() {
    awk '
        match($0, /✘ Test "[^"]*" recorded an issue/) {
            head = substr($0, RSTART, RLENGTH)
            name = substr(head, length("✘ Test \"") + 1)
            sub(/" recorded an issue$/, "", name)
            rest = substr($0, RSTART + RLENGTH)
            if (!match(rest, /[[:space:]]at[[:space:]][^ :]+:[0-9]+/)) { next }
            place = substr(rest, RSTART, RLENGTH)
            sub(/^.*at[[:space:]]/, "", place)
            if (!match(place, /:[0-9]+$/)) { next }
            if (name in seen) { next }
            seen[name] = 1
            printf "%s\t%s\t%s\n", name, substr(place, 1, RSTART - 1), substr(place, RSTART + 1)
        }
    ' "$1"
}

failed_case_count() {
    failed_test_cases "$1" | wc -l | tr -d ' '
}

# Every case name the log mentions, from the `✘ Test "..."` lines alone. A name that never yields a
# parsable issue line means the log format changed under us: see `retry_plan`.
mentioned_case_count() {
    awk '
        match($0, /✘ Test "/) {
            rest = substr($0, RSTART + RLENGTH)
            if (!match(rest, /^[^"]*"/)) { next }
            name = substr(rest, 1, RSTART - 1)
            if (name in seen) { next }
            seen[name] = 1
            total++
        }
        END { print total + 0 }
    ' "$1"
}

# Directories searched for the file named in a failure location, one per line, in priority order.
swift_test_source_dirs() { # repo_root
    local root="$1" dir
    if [ -n "${SWIFT_TEST_SOURCE_ROOTS:-}" ]; then
        printf '%s\n' "$SWIFT_TEST_SOURCE_ROOTS" | tr ',' '\n' | while IFS= read -r dir; do
            if [ -n "$dir" ]; then
                printf '%s\n' "$dir"
            fi
        done
        return 0
    fi
    printf '%s\n' "$root/Tests"
}

# The `Suite.func` for one failing case, read out of the source file named in its location.
#
# The `@Test("display name")` attribute is the anchor when the file has one: a plain backward scan
# from the recorded line lands on a nested helper instead of the test function, which is exactly
# what happens in MiSessionExpiryTests (a local `func set` inside `class SelectionBox`). The
# recorded line is only the fallback, for a test whose display name is just its signature.
derive_suite_func() { # source_file case_name line -> `Suite.func` (a bare `func` without a suite)
    awk -v NAME="$2" -v LINE="$3" '
        { src[NR] = $0 }
        END {
            quoted = "\"" NAME "\""
            fn_line = 0
            fn_name = ""
            for (i = 1; i <= NR; i++) {
                if (!index(src[i], "@Test") || !index(src[i], quoted)) { continue }
                for (j = i; j <= NR && j <= i + 8; j++) {
                    if (match(src[j], /^[[:space:]]*(static[[:space:]]+)?func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
                        fn_line = j
                        break
                    }
                }
                break
            }
            if (fn_line == 0) {
                for (i = LINE; i >= 1; i--) {
                    if (match(src[i], /^[[:space:]]*(static[[:space:]]+)?func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
                        fn_line = i
                        break
                    }
                }
            }
            if (fn_line == 0) { exit 0 }
            text = substr(src[fn_line], RSTART, RLENGTH)
            sub(/^[[:space:]]*(static[[:space:]]+)?func[[:space:]]+/, "", text)
            fn_name = text
            indent = match(src[fn_line], /[^[:space:]]/) - 1
            suite = ""
            for (i = fn_line - 1; i >= 1; i--) {
                if (match(src[i], /^[[:space:]]*(@[A-Za-z]+(\(.*\))?[[:space:]]+)?((final|public|internal)[[:space:]]+)?(struct|class|enum|extension)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
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
    ' "$1"
}

# `swift test --filter` matches the test id (`Module.Suite/func()`), never the display name, so a
# failing case is traced back to its function through the source file named in its log location.
# Prints one `Suite.func` per failing case (a bare `func` when no enclosing type was found).
retry_filter_args() { # rows_file repo_root
    local rows="$1" root="$2" name file line path candidate first dir seen="" derived
    while IFS="$(printf '\t')" read -r name file line; do
        [ -n "$file" ] && [ -n "$line" ] || continue
        path=""
        first=""
        while IFS= read -r dir; do
            if [ -z "$dir" ] || [ ! -d "$dir" ]; then
                continue
            fi
            while IFS= read -r candidate; do
                [ -n "$candidate" ] || continue
                [ -n "$first" ] || first="$candidate"
                # Two test files can share a basename; the one quoting the case name is the right one.
                if grep -Fq -- "$name" "$candidate"; then
                    path="$candidate"
                    break
                fi
            done < <(find "$dir" -name "$file" -type f 2>/dev/null || true)
            if [ -n "$path" ]; then
                break
            fi
        done < <(swift_test_source_dirs "$root")
        [ -n "$path" ] || path="$first"
        [ -n "$path" ] || continue
        derived="$(derive_suite_func "$path" "$name" "$line")"
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
        # A parameterized case reports `✔ Test "..." with 2 test cases passed`, so the name alone
        # is the anchor. The summary above already rejected any `✘` line.
        if ! grep -qF "✔ Test \"$name\"" "$retry_log"; then
            echo "unverified"
            return 0
        fi
    done <"$rows"
    echo "pass"
}

# Should the failing run be rerun once? A crash, a stall, or more than five failing cases is a
# real break: rerunning those only burns runner minutes.
retry_plan() { # log retry_enabled stalled
#   -> retry | off | crash | stall | no-cases | too-many | unparsed | no-baseline
    local log="$1" enabled="$2" stalled="$3" count mentioned
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
    # A missing baseline is written into the source tree by SnapshotAssertion and reported as an
    # issue, so the rerun would compare against the PNG the first run just recorded and pass. That
    # would let a render change through without a committed baseline: never retry those.
    if grep -q 'No reference was found on disk' "$log"; then
        echo "no-baseline"
        return 0
    fi
    count="$(failed_case_count "$log")"
    # Rerunning only what we could parse would hide a case the parser missed.
    mentioned="$(mentioned_case_count "$log")"
    if [ "$mentioned" -gt "$count" ]; then
        echo "unparsed"
        return 0
    fi
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

# ---------------------------------------------------------------------------------------------
# 重跑流程：两个平台共用，平台差异只在 swift_test_run_attempt 这一层
# ---------------------------------------------------------------------------------------------

# Rerun the failing cases once. Returns 0 when the rerun cleared every failure, so the caller can
# turn a red run green; returns 1 when the failure stands and the caller keeps its own verdict.
retry_failed_cases() { # first_log retry_enabled stalled repo_root [swift test args...]
    local first_log="$1" retry_enabled="$2" stalled="$3" repo_root="$4"
    shift 4
    local plan rows_file retry_log retry_state filter_value filter_count=0
    local filter_args=()
    plan="$(retry_plan "$first_log" "$retry_enabled" "$stalled")"
    if [ "$plan" != "retry" ]; then
        if [ "$retry_enabled" -eq 1 ]; then
            case "$plan" in
                stall) echo "::warning::not retrying: the run stalled" ;;
                too-many) echo "::warning::not retrying: more than five failing cases, which is a real break" ;;
                unparsed) echo "::warning::not retrying: some failing cases were not parsable from the log" ;;
                no-baseline) echo "::warning::not retrying: a snapshot baseline is missing, so a rerun would compare against the PNG this run just recorded" ;;
            esac
        fi
        return 1
    fi
    rows_file="$(mktemp -t swift-test-cases)"
    failed_test_cases "$first_log" >"$rows_file"
    while IFS= read -r filter_value; do
        [ -n "$filter_value" ] || continue
        filter_args[${#filter_args[@]}]="--filter"
        filter_args[${#filter_args[@]}]="$filter_value"
        filter_count=$((filter_count + 1))
    done <<EOF
$(retry_filter_args "$rows_file" "$repo_root")
EOF
    if [ "$filter_count" -eq 0 ]; then
        echo "::warning::could not trace the failing cases back to a test function; not retrying"
        rm -f "$rows_file"
        return 1
    fi
    echo "=== flaky check: rerunning ${filter_count} failing case(s) with --filter"
    retry_log="$(mktemp -t swift-test-retry)"
    swift_test_run_attempt "$retry_log" "$@" "${filter_args[@]}"
    echo "=== retry process exit: ${RUN_EXIT} (stalled=${RUN_STALLED})"
    retry_state="$(retry_verdict "$rows_file" "$retry_log")"
    if [ "$retry_state" = "pass" ]; then
        report_flaky "$rows_file"
        rm -f "$rows_file"
        return 0
    fi
    echo "::warning::the retry did not clear the failure (${retry_state}); reporting the first run"
    rm -f "$rows_file"
    return 1
}

# ---------------------------------------------------------------------------------------------
# 一次运行：stall 看门狗 + 行缓冲
# ---------------------------------------------------------------------------------------------

# The default `swift_test_run_attempt`: one `swift test` run under the stall watchdog, streaming
# its log into the job output. Sets RUN_EXIT, RUN_STALLED, RUN_STARTED (epoch) and RUN_PIDS.
run_with_watchdog() { # log_file swift_test_arguments...
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
    if [ -n "$SWIFT_TEST_LAUNCH_CMD" ]; then
        # shellcheck disable=SC2086  # fixed internal prefix; see SWIFT_TEST_LAUNCH_CMD above
        $SWIFT_TEST_LAUNCH_CMD swift test "$@" >"$log" 2>&1 &
    else
        # No pty and no stdbuf: accept a block-buffered log, the verdict only needs the final bytes.
        swift test "$@" >"$log" 2>&1 &
    fi
    test_pid=$!
    printf '%s\n' "$test_pid" >"$pids_file"
    record_descendant_pids "$test_pid" "$pids_file"
    # Stream the log into the job output so a killed job still leaves the last test visible.
    tail -n +1 -f "$log" &
    tail_pid=$!

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
            if [ -n "${SWIFT_TEST_SAMPLE_FN:-}" ]; then
                "$SWIFT_TEST_SAMPLE_FN" || true
            fi
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
    exit_code=0
    wait "$test_pid" 2>/dev/null || exit_code=$?
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    RUN_EXIT="$exit_code"
    RUN_STALLED="$stall_detected"
    RUN_PIDS="$(tr '\n' ',' <"$pids_file" | sed 's/,$//')"
    rm -f "$pids_file"
}

swift_test_run_attempt() { # log_file swift_test_arguments...
    run_with_watchdog "$@"
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

# CI only, with `CI_RETRY_FAILED=0/1` overriding either way. Every caller resolves this the same
# way so a local run never reruns a failure behind the developer's back.
swift_test_retry_enabled() {
    local enabled=0
    case "${CI:-}" in
        true | 1) enabled=1 ;;
    esac
    case "${CI_RETRY_FAILED:-}" in
        0) enabled=0 ;;
        1) enabled=1 ;;
    esac
    printf '%s\n' "$enabled"
}
