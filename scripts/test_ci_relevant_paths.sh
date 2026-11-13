#!/usr/bin/env bash
# ci_relevant_paths.sh 的离线自检（含 PR #103 新增的 3 条路径分流规则）。
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

expect_flags() {
    local label="$1" expected="$2"
    shift 2
    local raw actual
    raw="$(printf '%s\n' "$@" | bash scripts/ci_relevant_paths.sh)"
    actual="$(printf '%s\n' "$raw" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "${label}: 期望 [${expected}]，实际 [${actual}]"
    fi
}

# PR #103 新增规则 1：scripts/go2rtc-ptz/README.md 排在 *.md 之前，必须触发 code（供 check_model_tables.py 校验）
expect_flags "scripts/go2rtc-ptz/README.md 命中 *.md 豁免前的 code 规则" \
    "code=true macos=false windows=false core=false" \
    "scripts/go2rtc-ptz/README.md"

# PR #103 新增规则 2：raycast/* 改动触发 code 与 windows（供 ci.yml raycast 作业运行）
expect_flags "raycast/ 源码改动触发 code 与 windows" \
    "code=true macos=false windows=true core=false" \
    "raycast/src/ask.tsx" "raycast/tests/snapshot-validation.test.ts"

# PR #103 新增规则 3：windows/src/core/miCloud/*.json 双端共享表排在 windows/* 之前，触发全量四项
expect_flags "windows/src/core/miCloud/deviceProfiles.json 触发 macos+windows+core" \
    "code=true macos=true windows=true core=true" \
    "windows/src/core/miCloud/deviceProfiles.json"

# 纯文档改动跳过全部重型任务
expect_flags "纯 Markdown 与 docs/ 改动全为 false" \
    "code=false macos=false windows=false core=false" \
    "README.md" "README.zh-CN.md" "CHANGELOG.md" "docs/adr/0001-ha-as-single-source-of-truth.md"

# 纯 macOS App 层只跑 code + macos
expect_flags "Sources/MenuBarMijiaApp 改动只触发 code + macos" \
    "code=true macos=true windows=false core=false" \
    "Sources/MenuBarMijiaApp/PanelView.swift"

# MijiaCore 改动触发 code + macos + core（Linux 跑 MijiaCore）
expect_flags "Sources/MijiaCore 改动触发 code + macos + core" \
    "code=true macos=true windows=false core=true" \
    "Sources/MijiaCore/AppURLCommand.swift"

# 普通 Windows 前端改动只触发 code + windows
expect_flags "普通 windows/src/ui 改动只触发 code + windows" \
    "code=true macos=false windows=true core=false" \
    "windows/src/ui/panel.ts"

# 共享黄金夹具触发全量
expect_flags "Tests/Fixtures 共享夹具触发全量" \
    "code=true macos=true windows=true core=true" \
    "Tests/Fixtures/intent_golden.json"

# 空输入（diff 取不到文件列表）退回全量安全兜底
raw="$(bash scripts/ci_relevant_paths.sh < /dev/null)"
actual="$(printf '%s\n' "$raw" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [ "$actual" = "code=true macos=true windows=true core=true" ]; then
    pass "空路径列表安全退回全量运行"
else
    fail "空路径列表应全为 true，实际 [${actual}]"
fi

# 未知根路径文件退回全量安全兜底
expect_flags "未知路径安全退回全量运行" \
    "code=true macos=true windows=true core=true" \
    "UnknownTopLevelFile.xyz"

if [ "$failures" -ne 0 ]; then
    echo "❌ ci_relevant_paths 自测失败 ${failures} 项" >&2
    exit 1
fi
echo "✅ ci_relevant_paths 自测通过"
