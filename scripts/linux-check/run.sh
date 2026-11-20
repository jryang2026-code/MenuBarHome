#!/bin/bash
# 在 Linux（无 Xcode）上编译并测试 MijiaCore。macOS 上请直接用 scripts/check.sh。
# 做法：把 Sources/MijiaCore 和测试复制到 .work/，只注入 FoundationNetworking 导入、去掉 Linux 没有的 waitsForConnectivity。
set -euo pipefail
L="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$L/../.." && pwd)"
W="$L/.work"; S="$(mktemp -d "${TMPDIR:-/tmp}/linux-check-src.XXXXXX")"; trap 'rm -rf "$S"' EXIT
cp -r "$R/Sources/MijiaCore" "$S/MijiaCore"; cp -r "$R/Tests/MijiaCoreTests" "$S/MijiaCoreTests"; cp -r "$R/Tests/KeychainTestSupport" "$S/KeychainTestSupport"
cp -r "$R/Tests/PreferencesTestSupport" "$S/PreferencesTestSupport"
cp -r "$R/Tests/StateTestSupport" "$S/StateTestSupport"
# 注入 Linux 需要的 FoundationNetworking 导入（3 行），并删掉 Linux 没有的 waitsForConnectivity 行。
# 用 awk 而不是 sed：GNU 的 `sed -i -e '1i text'` 在 BSD sed 上直接报错，而 find -exec 的失败
# 不会让脚本失败，副本就会默默少掉这 3 行（自测 scripts/test_swift_test_retry.sh 会真的跑这一段）。
find "$S" -name '*.swift' | while IFS= read -r f; do
  awk 'BEGIN {
         print "#if canImport(FoundationNetworking)"
         print "import FoundationNetworking"
         print "#endif"
       }
       !/waitsForConnectivity = /' "$f" >"$f.linux" && mv "$f.linux" "$f"
done
mkdir -p "$W"; ln -sfn "$R/Tests/Fixtures" "$W/Fixtures"
# 只写入内容变了的文件。swift build 按 mtime 判断要不要重编，整目录重建会让缓存和第二次运行都全量重编。
cd "$S"; find . -type f | while IFS= read -r f; do
  if ! cmp -s "$f" "$W/$f"; then mkdir -p "$(dirname "$W/$f")"; cp "$f" "$W/$f"; fi
done
cd "$W"; find MijiaCore MijiaCoreTests KeychainTestSupport PreferencesTestSupport StateTestSupport -type f | while IFS= read -r f; do
  [ -e "$S/$f" ] || rm "$W/$f"
done

# 失败用例自动重跑一次：解析与判定与 macOS 的 scripts/ci_swift_test.sh 共用
# scripts/lib/swift_test_retry.sh，不各维护一份。CI 之外默认不重跑，CI_RETRY_FAILED=0/1 覆盖。
# shellcheck source=scripts/lib/swift_test_retry.sh
. "$R/scripts/lib/swift_test_retry.sh"
# util-linux 的 script 要写成 `script -q -c "cmd" /dev/null`（BSD 是 `script -q /dev/null cmd`），
# 这里干脆不用 pty：stdbuf 就能让 stdout 保持行缓冲，看门狗与流式日志都够用。
# 顺带跑一次 stdbuf，确认 libstdbuf 真的能用：装了但跑不起来时直接回退到块缓冲，不卡死整步。
if command -v stdbuf >/dev/null 2>&1 && stdbuf -oL true 2>/dev/null; then
  SWIFT_TEST_LAUNCH_CMD="stdbuf -oL -eL"
else
  SWIFT_TEST_LAUNCH_CMD=""
fi
# 日志里的 `文件:行号` 属于 .work 里的副本（头部注入了 3 行），定位 Suite.func 只能查副本；
# 查仓库里的 Tests/ 会偏移 3 行，可能落到相邻的用例上。
SWIFT_TEST_SOURCE_ROOTS="$W"
# Linux 没有 macOS 的 `sample`，也没有 ReportCrash 的 .ips：看门狗触发时给 ps 现场即可。
SWIFT_TEST_SAMPLE_FN="sample_stalled_linux_processes"

sample_stalled_linux_processes() {
  ps -eo pid,ppid,stat,etime,wchan:24,args 2>/dev/null | grep -E "swift|xctest|stdbuf" | grep -v grep || true
}

retry_enabled="$(swift_test_retry_enabled)"
first_log="$(mktemp "${TMPDIR:-/tmp}/linux-check-test.XXXXXX")"
cd "$L"
TZ="${TZ:-Asia/Shanghai}"; export TZ
# RUN_EXIT / RUN_STALLED 才是这次运行的结论；函数本身的退出码没有意义（set -e 下要挡住）。
swift_test_run_attempt "$first_log" "$@" || true
first_stalled="$RUN_STALLED"
echo "=== swift test process exit: ${RUN_EXIT} (stalled=${first_stalled})"

# 与 macOS 一致：崩溃压过任何一个先前的 passing 汇总。Linux 没有 ReportCrash 的 .ips 与 atos，
# 现场只能看 job 日志，所以这里不 dump 报告。
if log_has_crash "$first_log"; then
  echo "::error::swift test crashed during execution"
  exit 1
fi

# Swift Testing 自己的汇总行说了算，退出码与看门狗只作诊断。
if [ "$(swift_test_summary_verdict "$first_log")" = "pass" ]; then
  if [ "$first_stalled" -eq 1 ] || [ "$RUN_EXIT" -ne 0 ]; then
    echo "::warning::the suite passed but swift test did not exit cleanly (exit ${RUN_EXIT}, stalled=${first_stalled}); accepting the passing summary"
  fi
  exit 0
fi

if retry_failed_cases "$first_log" "$retry_enabled" "$first_stalled" "$R" "$@"; then
  exit 0
fi

if [ "$first_stalled" -eq 1 ]; then
  echo "::error::swift test produced no output for ${SWIFT_TEST_STALL_SECONDS:-300}s; the test process is deadlocked"
  exit 1
fi
echo "::error::swift test produced no passing summary (exit ${RUN_EXIT})"
exit 1
