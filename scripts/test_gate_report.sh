#!/usr/bin/env bash
# 门禁文案、提交钩子过滤、快照变更列表的自测。不跑 Swift，不连网络。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
# A commit hook exports GIT_INDEX_FILE and GIT_DIR. They point at the committing repository, so
# the temporary repository below would stage and commit into the real index instead of its own.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

expect_summary() {
    local expected_status="$1" expected_line="$2"
    shift 2
    local status=0 output
    output="$(bash scripts/gate_report.sh summary "$@")" || status=$?
    if [ "$status" = "$expected_status" ] && [ "$output" = "$expected_line" ]; then
        pass "summary $(printf '%s ' "$@")"
    else
        fail "summary $(printf '%s ' "$@") 应为退出 ${expected_status} 且「${expected_line}」，实际退出 ${status} 且「${output}」"
    fi
}

expect_summary 0 "✅ 所有门禁检查与单元测试全部通过！" Swift=0 Windows=0 Raycast=0
expect_summary 0 "⚠️ 部分通过：跳过 Windows、Raycast" Swift=0 Windows=skip Raycast=skip
expect_summary 0 "⚠️ 部分通过：跳过 Swift" Swift=skip
expect_summary 1 "❌ 门禁未通过：Swift=1" Swift=1 Windows=0 Raycast=0
expect_summary 1 "❌ 门禁未通过：Swift=1 Windows=4；跳过 Raycast" Swift=1 Windows=4 Raycast=skip

status=0
bash scripts/gate_report.sh summary Swift >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then
    pass "summary 拒绝没有等号的参数"
else
    fail "summary 坏参数应退出 2，实际 ${status}"
fi

hook_log="$(mktemp)"
cat >"$hook_log" <<'EOF'
this should be hidden
⚠️  单文件行数告警（> 1500 行；新代码优先拆分，见 #184）：
  1602  Sources/Foo.swift
  1700  windows/src/Bar.ts
✅ 没有超过 1500 行的源文件。
✔ some passing test
✔ Test run with 3 tests in 1 suite passed after 0.1 seconds.
✘ Test run with 2 tests failed after 0.2 seconds.
PASS 钩子摘要保留 Test run with 3 tests
⚠️ 部分通过：跳过 Windows、Raycast
EOF
hook_out="$(bash scripts/gate_report.sh hook-success "$hook_log")"
for needle in "单文件行数告警" "Sources/Foo.swift" "windows/src/Bar.ts" "没有超过 1500 行" "✔ Test run with 3 tests" "✘ Test run with 2 tests" "部分通过：跳过 Windows、Raycast"; do
    if printf '%s\n' "$hook_out" | grep -qF -- "$needle"; then
        pass "钩子摘要保留 ${needle}"
    else
        fail "钩子摘要丢掉了 ${needle}"
    fi
done
if printf '%s\n' "$hook_out" | grep -qF "this should be hidden" || printf '%s\n' "$hook_out" | grep -qF "some passing test" || printf '%s\n' "$hook_out" | grep -qF "PASS 钩子摘要保留 Test run with 3 tests"; then
    fail "钩子摘要把测试过程也打出来了"
else
    pass "钩子摘要不打印测试过程"
fi
rm -f "$hook_log"

fail_log="$(mktemp)"
cat >"$fail_log" <<'EOF'
✔ passed
✘ panelSnapshot() (0.1 seconds)
✘ Test panelSnapshot() recorded an issue at SnapshotTests.swift:10:1: Expectation failed
✖ tests/ui.test.ts
not ok 3 - opens the door
noise
EOF
fail_out="$(bash scripts/gate_report.sh failing-tests "$fail_log")"
for needle in "panelSnapshot()" "recorded an issue" "tests/ui.test.ts" "opens the door"; do
    if printf '%s\n' "$fail_out" | grep -qF -- "$needle"; then
        pass "失败用例名含 ${needle}"
    else
        fail "失败用例名缺少 ${needle}：${fail_out}"
    fi
done
rm -f "$fail_log"
empty_log="$(mktemp)"
: >"$empty_log"
empty_out="$(bash scripts/gate_report.sh failing-tests "$empty_log")"
if printf '%s\n' "$empty_out" | grep -qF "未能从日志里提取失败用例名"; then
    pass "没有标记时说明提取不到用例名"
else
    fail "空日志应说明提取不到用例名，实际「${empty_out}」"
fi

finished_log="$(mktemp)"
printf '%s\n' "✘ Test run with 2 tests in 1 suite failed after 0.5 seconds." >"$finished_log"
status=0
verdict="$(bash scripts/gate_report.sh record-verdict 1 "$finished_log")" || status=$?
if [ "$status" = 0 ] && printf '%s\n' "$verdict" | grep -qF "Swift 测试退出码：1" && printf '%s\n' "$verdict" | grep -qF "Test run with 2 tests"; then
    pass "录制跑完时打印 Swift 退出码，不当成崩溃"
else
    fail "录制跑完应退出 0 并打印退出码 1，实际退出 ${status}：${verdict}"
fi
status=0
crash="$(bash scripts/gate_report.sh record-verdict 1 "$empty_log")" || status=$?
if [ "$status" = 1 ] && printf '%s\n' "$crash" | grep -qF "快照录制没有跑完"; then
    pass "没有 Test run with 时判定录制没跑完"
else
    fail "缺少总结应判定崩溃，实际退出 ${status}：${crash}"
fi
printf '%s\n' "✔ Test run with 1 test in 1 suite passed after 0.1 seconds." >"$finished_log"
status=0
bash scripts/gate_report.sh record-verdict 139 "$finished_log" >/dev/null 2>&1 || status=$?
if [ "$status" = 1 ]; then
    pass "信号退出码仍判定录制没跑完"
else
    fail "退出码 139 应判定崩溃，实际 ${status}"
fi
printf '%s\n' "✔ Test run with 7 tests in 1 suite passed after 0.1 seconds." \
    "error: Exited with unexpected signal code 5" >"$finished_log"
status=0
bash scripts/gate_report.sh record-verdict 1 "$finished_log" >/dev/null 2>&1 || status=$?
if [ "$status" = 1 ]; then
    pass "前面的测试汇总不掩盖后面崩溃的快照进程"
else
    fail "汇总之后进程崩溃应判定录制没跑完，实际 ${status}"
fi
rm -f "$finished_log"

repo="$(mktemp -d)"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
git -C "$repo" config core.autocrlf false
mkdir -p "$repo/Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"
printf 'v1\n' >"$repo/Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/a.png"
git -C "$repo" add Tests
git -C "$repo" commit -q -m baseline
printf 'v2\n' >"$repo/Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/a.png"
git -C "$repo" add Tests
staged_list="$(git -C "$repo" status --porcelain -- Tests/MenuBarMijiaAppTests/__Snapshots__)"
diff_list="$(cd "$repo" && bash "$root/scripts/gate_report.sh" list-snapshot-changes Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests)"
if [ -n "$staged_list" ] && [ -z "$diff_list" ]; then
    pass "已暂存且工作区无新改动的图不算录制结果"
else
    fail "暂存图应被 git status 看见、被变更列表忽略。status=「${staged_list}」 list=「${diff_list}」"
fi
printf 'v3\n' >"$repo/Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/a.png"
printf 'new\n' >"$repo/Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/b.png"
diff_list="$(cd "$repo" && bash "$root/scripts/gate_report.sh" list-snapshot-changes Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests)"
if printf '%s\n' "$diff_list" | grep -qF "SnapshotTests/a.png" && printf '%s\n' "$diff_list" | grep -qF "SnapshotTests/b.png"; then
    pass "工作区改动和未跟踪的图都算变更"
else
    fail "变更列表应含 a.png 和 b.png，实际「${diff_list}」"
fi
warn="$(cd "$repo" && bash "$root/scripts/gate_report.sh" unstaged-snapshots)"
if printf '%s\n' "$warn" | grep -qF "没有暂存" && printf '%s\n' "$warn" | grep -qF "a.png" && printf '%s\n' "$warn" | grep -qF "b.png"; then
    pass "未暂存的截图会警告"
else
    fail "未暂存截图应警告，实际「${warn}」"
fi
git -C "$repo" add Tests
warn="$(cd "$repo" && bash "$root/scripts/gate_report.sh" unstaged-snapshots)"
if [ -z "$warn" ]; then
    pass "截图都暂存后不再警告"
else
    fail "都暂存后不应警告，实际「${warn}」"
fi
rm -rf "$repo"

sizes="$(mktemp -d)"
python3 - "$sizes" <<'PY'
import struct, sys
from pathlib import Path
root = Path(sys.argv[1])
def write(name, w, h):
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr
    (root / name).write_bytes(data)
write("a.png", 8, 8)
write("c.png", 2, 2)
PY
manifest="$(mktemp)"
bash scripts/gate_report.sh png-size-manifest "$sizes" >"$manifest"
python3 - "$sizes/a.png" <<'PY'
import struct, sys
from pathlib import Path
ihdr = struct.pack(">IIBBBBB", 12, 8, 8, 2, 0, 0, 0)
data = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr
Path(sys.argv[1]).write_bytes(data)
PY
python3 - "$sizes/b.png" <<'PY'
import struct, sys
from pathlib import Path
ihdr = struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0)
data = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr
Path(sys.argv[1]).write_bytes(data)
PY
changed="$(mktemp)"
printf '%s\n' a.png b.png c.png >"$changed"
size_out="$(bash scripts/gate_report.sh png-size-diff "$manifest" "$sizes" "$changed")"
if printf '%s\n' "$size_out" | grep -qF "a.png 8x8 -> 12x8" && printf '%s\n' "$size_out" | grep -qF "b.png 新图 4x4" && ! printf '%s\n' "$size_out" | grep -qF "c.png"; then
    pass "尺寸变化只报告新图和边长变了的图"
else
    fail "尺寸变化报告不对：${size_out}"
fi
rm -rf "$sizes" "$manifest" "$changed"

if [ -f windows/package.json ]; then
    if ! command -v node >/dev/null 2>&1; then
        echo "⏭️  跳过 Windows 测试发现自测：未找到 node"
    else
    node --input-type=module <<'JS'
import { globSync, readFileSync, readdirSync } from "node:fs";
const script = JSON.parse(readFileSync("windows/package.json", "utf8")).scripts.test;
if (!script.includes("tests/*.test.ts")) {
    console.error("FAIL test script 没有 tests/*.test.ts");
    process.exit(1);
}
if (script.includes("tests/core.test.ts")) {
    console.error("FAIL test script 仍手工点名 tests/core.test.ts");
    process.exit(1);
}
const found = globSync("tests/*.test.ts", { cwd: "windows" }).map((name) => name.replaceAll("\\", "/")).sort();
const disk = readdirSync("windows/tests").filter((name) => name.endsWith(".test.ts")).map((name) => `tests/${name}`).sort();
const missing = disk.filter((name) => !found.includes(name));
const extra = found.filter((name) => !disk.includes(name));
if (missing.length || extra.length || disk.length === 0) {
    console.error("FAIL glob 与 tests/*.test.ts 不一致", { missing, extra, disk });
    process.exit(1);
}
console.log(`PASS windows test glob ${disk.length}`);
JS
    fi
fi

if grep -qF 'add_gate_step' scripts/check.sh && grep -qF 'record_gate_result' scripts/check.sh && grep -qF 'gate_report.sh" summary' scripts/check.sh; then
    pass "check.sh 用汇总函数，新增步骤只登记一行"
else
    fail "check.sh 没有把步骤结果交给 gate_report.sh summary"
fi
if grep -qF 'Windows 门禁检查与单元测试通过' scripts/check.sh || grep -qF '[4/4] 所有门禁检查与单元测试全部通过' scripts/check.sh; then
    fail "check.sh 仍会在跳过步骤后宣布全部通过"
else
    pass "check.sh 不再宣布跳过也全部通过"
fi
if grep -qF 'hook-success' scripts/hooks/pre-commit && grep -qF 'unstaged-snapshots' scripts/hooks/pre-commit; then
    pass "pre-commit 保留长文件列表，并警告未暂存的截图"
else
    fail "pre-commit 没有接上摘要过滤或未暂存截图警告"
fi
if grep -qF '>/dev/null 2>&1 || true' scripts/record_snapshots.sh || grep -qF 'git status' scripts/record_snapshots.sh; then
    fail "record_snapshots.sh 仍吞掉 Swift 输出，或用 git status 列变更"
else
    pass "record_snapshots.sh 不再吞掉 Swift 输出，也不用 git status"
fi
if grep -qF 'record-verdict' scripts/record_snapshots.sh && grep -qF 'list-snapshot-changes' scripts/record_snapshots.sh && grep -qF 'png-size-diff' scripts/record_snapshots.sh; then
    pass "record_snapshots.sh 打印 Swift 退出码、变更和尺寸"
else
    fail "record_snapshots.sh 没有接上退出码、变更列表或尺寸"
fi

py_stub="$(mktemp -d)"
cat >"$py_stub/python3" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$py_stub/python3.15" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$py_stub/python3" "$py_stub/python3.15"
bash_bin="$(command -v bash)"
chosen="$(PATH="$py_stub" "$bash_bin" -c "$(sed -n '/^select_python_bin()/,/^}/p' scripts/check.sh); select_python_bin")"
rm -f "$py_stub/python3.15"
none_chosen="$(PATH="$py_stub" "$bash_bin" -c "$(sed -n '/^select_python_bin()/,/^}/p' scripts/check.sh); select_python_bin || true")"
rm -rf "$py_stub"
if [ "$chosen" = "python3.15" ]; then
    pass "select_python_bin 跳过低于 3.10 的 python3 并优先选高版本"
else
    fail "select_python_bin 未选 python3.15，实际：$chosen"
fi
if [ -z "$none_chosen" ]; then
    pass "select_python_bin 在仅有不可用 python3 桩时返回空串"
else
    fail "select_python_bin 不应退回不可用的 python3，实际：$none_chosen"
fi
if grep -qF 'record_gate_result "PythonLint=skip"' scripts/check.sh \
    && grep -qF 'summary "PythonLint=skip"' scripts/check.sh; then
    pass "check.sh 缺少 Python 3.10+ 时显式登记 PythonLint=skip"
else
    fail "check.sh 缺少 Python 3.10+ 时未显式登记 PythonLint=skip"
fi

if grep -qF 'WindowsBuild=skip' scripts/check.sh; then
    fail "check.sh 仍在共享工作树依赖路径下登记 WindowsBuild=skip"
else
    pass "check.sh 共享工作树依赖不再跳过 WindowsBuild"
fi

source "$root/scripts/shared_windows_deps.sh"

wt_sandbox="$(mktemp -d)"
donor_wt="$wt_sandbox/donor"
ephem_wt="$wt_sandbox/ephem"
consumer_wt="$wt_sandbox/consumer"
git -C "$wt_sandbox" init -q "$donor_wt"
git -C "$donor_wt" config user.email t@example.com
git -C "$donor_wt" config user.name t
git -C "$donor_wt" config commit.gpgsign false
mkdir -p "$donor_wt/windows"
printf '{"lockfileVersion":3}\n' >"$donor_wt/windows/package-lock.json"
git -C "$donor_wt" add windows/package-lock.json
git -C "$donor_wt" commit -q -m init
git -C "$donor_wt" worktree add -q -b ephem "$ephem_wt"
git -C "$donor_wt" worktree add -q -b consumer "$consumer_wt"

mkdir -p "$ephem_wt/windows/node_modules/.bin"
printf '#!/bin/sh\nexit 0\n' >"$ephem_wt/windows/node_modules/.bin/tsc"
printf '#!/bin/sh\nexit 0\n' >"$ephem_wt/windows/node_modules/.bin/vite"
chmod +x "$ephem_wt/windows/node_modules/.bin/tsc" "$ephem_wt/windows/node_modules/.bin/vite"
printf 'ephemeral\n' >"$ephem_wt/windows/node_modules/.mmb-shared-link"

mkdir -p "$donor_wt/windows/node_modules/.bin" "$donor_wt/windows/node_modules/typescript" "$donor_wt/windows/node_modules/.vite"
printf '#!/bin/sh\nexit 0\n' >"$donor_wt/windows/node_modules/.bin/tsc"
printf '#!/bin/sh\nexit 0\n' >"$donor_wt/windows/node_modules/.bin/vite"
chmod +x "$donor_wt/windows/node_modules/.bin/tsc" "$donor_wt/windows/node_modules/.bin/vite"
chmod -R a-w "$donor_wt/windows/node_modules"

found_nm="$(ROOT_DIR="$consumer_wt" find_shared_windows_node_modules)"
expected_nm="$(cd "$donor_wt/windows/node_modules" && pwd -P)"
actual_nm="$(cd "$found_nm" && pwd -P)"
if [ "$actual_nm" = "$expected_nm" ]; then
    pass "find_shared_windows_node_modules 跳过 .mmb-shared-link 工作树并命中只读真实依赖"
else
    fail "find_shared_windows_node_modules 应命中 ${expected_nm}，实际 ${actual_nm}"
fi

mkdir -p "$consumer_wt/windows/dist"
printf 'keep-dist' >"$consumer_wt/windows/dist/index.html"
farm_out="$(ROOT_DIR="$consumer_wt" with_shared_windows_deps "$found_nm" "$bash_bin" -c 'mkdir -p "$0/windows/node_modules/.vite-temp" && printf ok > "$0/windows/node_modules/.vite-temp/stamp" && [ -x "$0/windows/node_modules/.bin/tsc" ] && [ ! -e "$0/windows/node_modules/.vite" ] && cat "$0/windows/node_modules/.vite-temp/stamp"' "$consumer_wt")"
if [ "$farm_out" = "ok" ] && [ ! -e "$consumer_wt/windows/node_modules" ] && [ -f "$consumer_wt/windows/dist/index.html" ] && [ ! -e "$donor_wt/windows/node_modules/.vite-temp" ]; then
    pass "with_shared_windows_deps 支持本地写入 .vite-temp、保留 windows/dist、不污染只读 donor 并在退出后清理"
else
    fail "with_shared_windows_deps 行为异常: out=${farm_out} consumer=$(ls -la "$consumer_wt/windows" 2>&1)"
fi

run_out="$(ROOT_DIR="$consumer_wt" "$bash_bin" "$root/scripts/shared_windows_deps.sh" run "$bash_bin" -c '[ -x "$0/windows/node_modules/.bin/vite" ] && printf run-ok' "$consumer_wt")"
if [ "$run_out" = "run-ok" ] && [ ! -e "$consumer_wt/windows/node_modules" ]; then
    pass "shared_windows_deps.sh run 自动挂载并清理共享依赖"
else
    fail "shared_windows_deps.sh run 行为异常: out=${run_out}"
fi

mkdir -p "$consumer_wt/windows/node_modules/real-pkg"
ROOT_DIR="$consumer_wt" cleanup_shared_windows_deps
if [ -d "$consumer_wt/windows/node_modules/real-pkg" ]; then
    pass "cleanup_shared_windows_deps 绝不删除无 .mmb-shared-link 标记的真实 node_modules"
else
    fail "cleanup_shared_windows_deps 误删了真实 node_modules"
fi

chmod -R u+w "$donor_wt/windows/node_modules"
rm -rf "$wt_sandbox"

if [ "$failures" -ne 0 ]; then
    echo "❌ 门禁文案自测失败 ${failures} 项" >&2
    exit 1
fi
echo "✅ 门禁文案自测通过"
