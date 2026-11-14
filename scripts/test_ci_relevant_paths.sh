#!/usr/bin/env bash
# ci_relevant_paths.sh 的离线自检（覆盖 11 维精准路径分流规则与安全兜底）。
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

ALL_FALSE="code=false macos=false windows=false core=false raycast=false scripts=false macos_build=false appintents=false windows_native=false nas=false go2rtc=false"
ALL_TRUE="code=true macos=true windows=true core=true raycast=true scripts=true macos_build=true appintents=true windows_native=true nas=true go2rtc=true"

build_expected() {
    local -a true_keys=("$@")
    local out="" key val k
    for key in code macos windows core raycast scripts macos_build appintents windows_native nas go2rtc; do
        val=false
        for k in "${true_keys[@]}"; do
            if [ "$k" = "$key" ]; then
                val=true
                break
            fi
        done
        out="${out:+${out} }${key}=${val}"
    done
    printf '%s' "$out"
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

# 1. go2rtc README 排在 *.md 之前，触发 code + scripts + go2rtc
expect_flags "scripts/go2rtc-ptz/README.md 命中 *.md 豁免前的 code+scripts+go2rtc 规则" \
    "$(build_expected code scripts go2rtc)" \
    "scripts/go2rtc-ptz/README.md"

# 2. README / capabilities.json 触发 code（由 nas-safety 检查 capability matrix）
expect_flags "README.md 触发 code=true" \
    "$(build_expected code)" \
    "README.md" "README.zh-CN.md" "docs/capabilities.json"

# 3. raycast/ 解耦（仅 snapshot-validation.ts 联动 windows）
expect_flags "raycast/ 源码改动只触发 code + raycast" \
    "$(build_expected code raycast)" \
    "raycast/src/ask.tsx" "raycast/tests/snapshot-validation.test.ts"

expect_flags "raycast/src/snapshot-validation.ts 同时触发 code + raycast + windows" \
    "$(build_expected code raycast windows)" \
    "raycast/src/snapshot-validation.ts"

# 4. windows/src/core/miCloud/*.json 双端共享表触发四项主测试
expect_flags "windows/src/core/miCloud/deviceProfiles.json 触发 macos+windows+core" \
    "$(build_expected code macos windows core)" \
    "windows/src/core/miCloud/deviceProfiles.json"

# 5. 纯文档与 Agent 规则跳过全部重型任务
expect_flags "纯 Markdown、docs/ 与 .claude/.agents 改动全为 false" \
    "$ALL_FALSE" \
    "CHANGELOG.md" "docs/adr/0001-ha-as-single-source-of-truth.md" ".claude/rules/macos.md" ".cursor/skills/tdd/SKILL.md"

# 6. macOS App 层 vs AppIntents vs MijiaCore
expect_flags "Sources/MenuBarMijiaApp 普通改动只触发 code + macos" \
    "$(build_expected code macos)" \
    "Sources/MenuBarMijiaApp/PanelView.swift"

expect_flags "Sources/MenuBarMijiaApp/AppIntents.swift 额外触发 appintents" \
    "$(build_expected code macos appintents)" \
    "Sources/MenuBarMijiaApp/AppIntents.swift"

expect_flags "Sources/MijiaCore 改动触发 code + macos + core" \
    "$(build_expected code macos core)" \
    "Sources/MijiaCore/AppURLCommand.swift"

expect_flags "scripts/build_app.sh 触发打包与 AppIntents 构建检查" \
    "$(build_expected code macos scripts macos_build appintents)" \
    "scripts/build_app.sh"

# 7. Windows 前端 vs 原生层
expect_flags "普通 windows/src/ui 改动只触发 code + windows（不触发 windows_native）" \
    "$(build_expected code windows)" \
    "windows/src/ui/panel.ts"

expect_flags "windows/src-tauri 原生改动触发 code + windows + windows_native" \
    "$(build_expected code windows windows_native)" \
    "windows/src-tauri/src/lib.rs"

expect_flags "camera-bin 构建脚本改动触发 windows_native" \
    "$(build_expected code windows windows_native)" \
    "windows/scripts/build-ffmpeg-min.sh" \
    "windows/scripts/prepare-camera-bin.sh" \
    "windows/scripts/patch_pe_subsystem.py"

# 8. 脚本与 NAS 精准路由
expect_flags "scripts/pr-ready.sh 只触发 code + scripts" \
    "$(build_expected code scripts)" \
    "scripts/pr-ready.sh"

expect_flags "nas/ 目录只触发 code + nas" \
    "$(build_expected code nas)" \
    "nas/setup.sh"

# 9. 共享黄金夹具
expect_flags "Tests/Fixtures 共享夹具触发 code + macos + windows + core" \
    "$(build_expected code macos windows core)" \
    "Tests/Fixtures/intent_golden.json"

# 10. 空输入与未知路径安全兜底全量
raw="$(bash scripts/ci_relevant_paths.sh < /dev/null)"
actual="$(printf '%s\n' "$raw" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [ "$actual" = "$ALL_TRUE" ]; then
    pass "空路径列表安全退回全量运行"
else
    fail "空路径列表应全为 true，实际 [${actual}]"
fi

expect_flags "未知路径安全退回全量运行" \
    "$ALL_TRUE" \
    "UnknownTopLevelFile.xyz"

if [ "$failures" -ne 0 ]; then
    echo "❌ ci_relevant_paths 自测失败 ${failures} 项" >&2
    exit 1
fi
echo "✅ ci_relevant_paths 自测通过"
