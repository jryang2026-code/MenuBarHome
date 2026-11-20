#!/usr/bin/env bash
# 两个测试入口的「失败用例只重跑一次」接线自测：用假 swift 回放日志，不编译、不跑测试。
#   Linux 入口 scripts/linux-check/run.sh      在隔离的假仓库里跑（含 .work 副本与行号偏移）
#   macOS 入口 scripts/ci_swift_test.sh        只在 Darwin 上跑（其余平台显式跳过）
# 规则本身（解析、判定、五种不重跑）由 scripts/test_ci_swift_test.sh 覆盖，这里只验接线：
# 重跑确实发生、带对了 --filter、重跑通过就判通过、没设 CI 就不重跑。
set -uo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/mmb-retry-e2e.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '     %s\n' "$2"
    failures=$((failures + 1))
}
expect_eq() { # <message> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "期望 [$2]，实际 [$3]"
    fi
}

# 假 swift：记录每次调用与被给的参数，第一次回放失败日志，带 --filter 的那次回放重跑日志。
# FAKE_SWIFT_RETRY_LOG 决定重跑那一轮的输出（通过 / 仍失败）。
make_fake_swift() { # dir
    local dir="$1"
    mkdir -p "$dir/bin"
    cat >"$dir/bin/swift" <<'FAKE'
#!/usr/bin/env bash
d="${FAKE_SWIFT_DIR:?}"
printf '%s\n' "$*" >>"$d/args"
has_filter=0
for arg in "$@"; do
    [ "$arg" = "--filter" ] && has_filter=1
done
if [ "$has_filter" = "1" ]; then
    cat "${FAKE_SWIFT_RETRY_LOG:?}"
    exit 0
fi
cat "${FAKE_SWIFT_FIRST_LOG:?}"
exit 1
FAKE
    chmod +x "$dir/bin/swift"
}

# 失败日志：plainCase() 没有显示名（没有 @Test(名字) 可锚），第 13 行只在 .work 副本里对得上。
write_first_log() { # path
    cat >"$1" <<'LOG'
◇ Test run started.
◇ Test "plainCase()" started.
✘ Test "plainCase()" recorded an issue at OffsetFixtureTests.swift:13:9: Expectation failed: 1 == 2
✘ Test run with 1 test in 1 suite failed after 0.4 seconds with 1 issue.
LOG
}

write_retry_pass_log() { # path
    cat >"$1" <<'LOG'
◇ Test run started.
◇ Test "plainCase()" started.
✔ Test "plainCase()" passed after 0.1 seconds.
✔ Test run with 1 test in 1 suite passed after 0.2 seconds.
LOG
}

write_retry_fail_log() { # path
    cat >"$1" <<'LOG'
◇ Test run started.
◇ Test "plainCase()" started.
✘ Test "plainCase()" recorded an issue at OffsetFixtureTests.swift:13:9: Expectation failed: 1 == 2
✘ Test run with 1 test in 1 suite failed after 0.4 seconds with 1 issue.
LOG
}

# 假仓库：run.sh 按自身位置推导仓库根，所以把 run.sh 与共享库放进同样形状的临时仓库。
make_fake_repo() { # dir
    local dir="$1" support
    mkdir -p "$dir/Sources/MijiaCore" "$dir/Tests/MijiaCoreTests" "$dir/Tests/Fixtures" "$dir/scripts/linux-check" "$dir/scripts/lib"
    printf 'public enum Placeholder {}\n' >"$dir/Sources/MijiaCore/Placeholder.swift"
    for support in KeychainTestSupport PreferencesTestSupport StateTestSupport; do
        mkdir -p "$dir/Tests/$support"
        printf 'public enum %s {}\n' "$support" >"$dir/Tests/$support/Support.swift"
    done
    # 仓库里的原作者文件：plainCase 的 #expect 在第 10 行；run.sh 注入 3 行后副本是第 13 行。
    cp scripts/testdata/ci-swift-test/offset/Tests/OffsetFixtureTests.swift "$dir/Tests/MijiaCoreTests/"
    cp scripts/linux-check/run.sh "$dir/scripts/linux-check/run.sh"
    cp scripts/lib/swift_test_retry.sh "$dir/scripts/lib/swift_test_retry.sh"
}

# --- Linux 入口：行号偏移后仍带对 --filter，重跑通过就判通过 ---------------------------------
fake="$workdir/linux"
mkdir -p "$fake"
make_fake_swift "$fake"
make_fake_repo "$fake/repo"
write_first_log "$fake/first.log"
write_retry_pass_log "$fake/retry.log"

out="$(env PATH="$fake/bin:$PATH" CI=true FAKE_SWIFT_DIR="$fake" \
    FAKE_SWIFT_FIRST_LOG="$fake/first.log" FAKE_SWIFT_RETRY_LOG="$fake/retry.log" \
    TZ=Asia/Shanghai bash "$fake/repo/scripts/linux-check/run.sh" 2>&1)"
expect_eq "Linux 入口：重跑通过则整步通过" "0" "$?"
case "$out" in
    *"rerunning 1 failing case(s)"*) pass "Linux 入口：确实发起了重跑" ;;
    *) fail "Linux 入口没有发起重跑" "$out" ;;
esac
expect_eq "Linux 入口：重跑按 .work 副本的行号带对 --filter" \
    "test --filter OffsetFixtureTests.plainCase" \
    "$(sed -n 2p "$fake/args" 2>/dev/null)"
case "$out" in
    *"::warning::flaky tests passed on retry: plainCase()"*) pass "Linux 入口：重跑通过后打出 flaky 警告" ;;
    *) fail "Linux 入口缺少 flaky 警告" "$out" ;;
esac
expect_eq "Linux 入口：总共跑了两次" "2" "$(wc -l <"$fake/args" | tr -d ' ')"

# --- Linux 入口：重跑仍失败则维持失败 --------------------------------------------------------
fake="$workdir/linux-fail"
mkdir -p "$fake"
make_fake_swift "$fake"
make_fake_repo "$fake/repo"
write_first_log "$fake/first.log"
write_retry_fail_log "$fake/retry.log"
out="$(env PATH="$fake/bin:$PATH" CI=true FAKE_SWIFT_DIR="$fake" \
    FAKE_SWIFT_FIRST_LOG="$fake/first.log" FAKE_SWIFT_RETRY_LOG="$fake/retry.log" \
    bash "$fake/repo/scripts/linux-check/run.sh" 2>&1)"
expect_eq "Linux 入口：重跑仍失败则整步失败" "1" "$?"
expect_eq "Linux 入口：重跑仍失败时跑了两次" "2" "$(wc -l <"$fake/args" | tr -d ' ')"
case "$out" in
    *"the retry did not clear the failure"*) pass "Linux 入口：说明重跑没有清掉失败" ;;
    *) fail "Linux 入口没有说明重跑结果" "$out" ;;
esac

# --- Linux 入口：没设 CI 就不重跑（本地默认行为不变）-----------------------------------------
fake="$workdir/linux-local"
mkdir -p "$fake"
make_fake_swift "$fake"
make_fake_repo "$fake/repo"
write_first_log "$fake/first.log"
write_retry_pass_log "$fake/retry.log"
out="$(env -u CI -u CI_RETRY_FAILED PATH="$fake/bin:$PATH" FAKE_SWIFT_DIR="$fake" \
    FAKE_SWIFT_FIRST_LOG="$fake/first.log" FAKE_SWIFT_RETRY_LOG="$fake/retry.log" \
    bash "$fake/repo/scripts/linux-check/run.sh" 2>&1)"
expect_eq "Linux 入口：本地默认不重跑" "1" "$?"
expect_eq "Linux 入口：本地只跑一次" "1" "$(wc -l <"$fake/args" | tr -d ' ')"

# --- macOS 入口：同样的接线（pty 前缀与看门狗只在 Darwin 上有意义）-----------------------------
if [ "$(uname -s)" = "Darwin" ]; then
    fake="$workdir/macos"
    mkdir -p "$fake/repo/scripts/lib" "$fake/repo/Tests/MijiaCoreTests"
    make_fake_swift "$fake"
    cp scripts/ci_swift_test.sh "$fake/repo/scripts/ci_swift_test.sh"
    cp scripts/lib/swift_test_retry.sh "$fake/repo/scripts/lib/swift_test_retry.sh"
    cp scripts/testdata/ci-swift-test/offset/Tests/OffsetFixtureTests.swift "$fake/repo/Tests/MijiaCoreTests/"
    # macOS 入口直接查仓库 Tests，日志行号就是原作者文件的行号（第 10 行）。
    sed 's/OffsetFixtureTests.swift:13:9/OffsetFixtureTests.swift:10:9/' "$workdir/linux/first.log" >"$fake/first.log"
    sed 's/OffsetFixtureTests.swift:13:9/OffsetFixtureTests.swift:10:9/' "$workdir/linux/retry.log" >"$fake/retry.log"
    out="$(env PATH="$fake/bin:$PATH" CI=true FAKE_SWIFT_DIR="$fake" \
        FAKE_SWIFT_FIRST_LOG="$fake/first.log" FAKE_SWIFT_RETRY_LOG="$fake/retry.log" \
        GITHUB_STEP_SUMMARY="$fake/summary.md" bash "$fake/repo/scripts/ci_swift_test.sh" --skip SnapshotTests 2>&1)"
    expect_eq "macOS 入口：重跑通过则整步通过" "0" "$?"
    expect_eq "macOS 入口：重跑沿用原参数并带对 --filter" \
        "test --skip SnapshotTests --filter OffsetFixtureTests.plainCase" \
        "$(sed -n 2p "$fake/args" 2>/dev/null)"
    case "$out" in
        *"::warning::flaky tests passed on retry"*) pass "macOS 入口：重跑通过后打出 flaky 警告" ;;
        *) fail "macOS 入口缺少 flaky 警告" "$out" ;;
    esac
    if grep -Fq '| `plainCase()` | `OffsetFixtureTests.swift:10` |' "$fake/summary.md" 2>/dev/null; then
        pass "macOS 入口：job summary 记下用例与首次失败位置"
    else
        fail "macOS 入口 job summary 缺少用例行" "$(cat "$fake/summary.md" 2>/dev/null)"
    fi
else
    printf 'SKIP macOS 入口接线自测（只在 Darwin 上跑：pty 前缀与看门狗是 macOS 专属）\n'
fi

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项测试入口接线自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ 测试入口接线自测通过\n'
