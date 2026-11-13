#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONIOENCODING=utf-8

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

LINT_ONLY=0
SKIP_SNAPSHOTS=0
for argument in "$@"; do
    case "$argument" in
        --lint-only) LINT_ONLY=1 ;;
        --skip-snapshots) SKIP_SNAPSHOTS=1 ;;
        *)
            echo "❌ 未知参数：${argument}（可用：--lint-only --skip-snapshots）" >&2
            exit 2
            ;;
    esac
done

# The hook lives in the shared git directory, so every worktree gets the same gate.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
case "$GIT_COMMON_DIR" in
    "") ;;
    /*) ;;
    *) GIT_COMMON_DIR="$ROOT_DIR/$GIT_COMMON_DIR" ;;
esac
if [ -n "$GIT_COMMON_DIR" ] && [ -d "$GIT_COMMON_DIR/hooks" ]; then
    # Every worktree shares this hook, so it must not point at one worktree's copy: a symlink to a
    # worktree that was later removed dangles, and git then skips the hook without a word. The
    # wrapper runs the committing worktree's own scripts/hooks/pre-commit.
    HOOK_PATH="$GIT_COMMON_DIR/hooks/pre-commit"
    HOOK_WRAPPER='#!/usr/bin/env bash
# Installed by scripts/check.sh: run the committing worktree'"'"'s own gate.
exec bash "$(git rev-parse --show-toplevel)/scripts/hooks/pre-commit" "$@"'
    if [ -L "$HOOK_PATH" ] || [ "$(cat "$HOOK_PATH" 2>/dev/null || true)" != "$HOOK_WRAPPER" ]; then
        rm -f "$HOOK_PATH"
        printf '%s\n' "$HOOK_WRAPPER" > "$HOOK_PATH" && chmod +x "$HOOK_PATH" 2>/dev/null || true
    fi
fi

search_matches() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -n --glob '!**/node_modules/**' --glob '!**/target/**' --glob '!**/dist/**' "$pattern" "$@"
    else
        grep -rnE --exclude-dir=node_modules --exclude-dir=target --exclude-dir=dist "$pattern" "$@"
    fi
}

search_quiet() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -q "$pattern" "$@"
    else
        grep -qE "$pattern" "$@"
    fi
}

search_files() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -l --glob '!**/node_modules/**' --glob '!**/target/**' --glob '!**/dist/**' "$pattern" "$@"
    else
        grep -rlE --exclude-dir=node_modules --exclude-dir=target --exclude-dir=dist "$pattern" "$@"
    fi
}

check_secret_leaks() {
    local scan_dirs=(
        Sources
        Tests
        windows/src
        windows/src-tauri/src
        windows/tests
        raycast/src
    )
    # 缺失的目录（稀疏检出、只拉一端）让 rg/grep 退出 2，`if search_matches` 会把它当成「没匹配」而放过真泄漏；
    # 只扫存在的目录，并把退出码 1 以外的失败当作扫描本身出错。
    local existing_dirs=() dir
    for dir in "${scan_dirs[@]}"; do
        [ -d "$dir" ] && existing_dirs+=("$dir")
    done
    scan_dirs=("${existing_dirs[@]}")

    local jwt_status=0
    search_matches 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "${scan_dirs[@]}" || jwt_status=$?
    if [ "$jwt_status" -eq 0 ]; then
        echo "❌ 检测到疑似 JWT Token，请移除后再提交！"
        return 1
    elif [ "$jwt_status" -ne 1 ]; then
        echo "❌ JWT 扫描本身失败（退出码 ${jwt_status}），无法确认没有泄漏！"
        return 1
    fi

    if ! search_quiet 'defaultSeededToken = ""' Sources/MijiaCore/KeychainAndPrefs.swift; then
        echo "❌ KeychainAndPrefs.swift 中的 defaultSeededToken 必须为空字符串！"
        return 1
    fi

    if ! search_quiet 'defaultHost = ""' Sources/MijiaCore/LGWebOSClient.swift; then
        echo "❌ LGWebOSClient.swift 中的 defaultHost 必须为空字符串！"
        return 1
    fi

    # 共享 golden 里的 10/8 是测试向量，AssistantTests 里的 localhost:3425 测自定义端口往返；只豁免这两处。
    local lan_ip_hits debug_port_hits
    lan_ip_hits="$(search_matches '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "${scan_dirs[@]}" | grep -Ev '^Tests[/\\]+Fixtures[/\\]+local_network_endpoint_golden\.json:' || true)"
    debug_port_hits="$(search_matches 'localhost:3425' "${scan_dirs[@]}" | grep -Ev '^Tests[/\\]+MijiaCoreTests[/\\]+AssistantTests\.swift:' || true)"
    if [ -n "$lan_ip_hits" ] || [ -n "$debug_port_hits" ]; then
        if [ -n "$lan_ip_hits" ]; then
            echo "$lan_ip_hits"
        fi
        if [ -n "$debug_port_hits" ]; then
            echo "$debug_port_hits"
        fi
        echo "❌ 检测到硬编码的个人局域网 IP 或本机调试端口 (localhost:3425)，请移除！"
        return 1
    fi
    return 0
}

echo "🔍 检查是否存在硬编码 JWT / 密钥 / 个人局域网地址泄露..."
check_secret_leaks

echo "🔍 检查机械性编码规范 (kVK_* 键码常量 & UNUserNotificationCenter Bundle 守卫)..."
if search_matches 'event\.keyCode[[:space:]]*==[[:space:]]*[0-9]+' Sources/; then
    echo "❌ 请使用 Carbon 的 kVK_* 常量，不要直接比较 event.keyCode 数字字面量！"
    exit 1
fi

# Swift Testing macros expand recursively: `#require(try #require(...))` fails compilation on every
# platform, before any test runs. One grep here replaces a CI round trip.
if search_matches '#require\([^)]*#require' Tests/; then
    echo "❌ Swift Testing 的 #require 不能嵌套展开（宏递归会编译失败），请先解包到变量再 require！"
    exit 1
fi

# L10n.currentLanguage is one value for the whole process. A test that assigns it changes
# every other suite's strings. Task-local $overrideLanguage is the only test seam.
if search_matches 'L10n\.currentLanguage[[:space:]]*=([^=]|$)' Tests; then
    echo "❌ 测试给 L10n.currentLanguage 赋值会改到进程里的其他套件。请改用 L10n.\$overrideLanguage.withValue。"
    exit 1
fi

for f in $(search_files 'UNUserNotificationCenter\.current\(\)' Sources || true); do
    if ! search_quiet 'pathExtension == "app"' "$f"; then
        echo "❌ $f 调用了 UNUserNotificationCenter.current()，但缺少 Bundle.main.bundleURL.pathExtension == \"app\" 守卫（会导致 swift test 崩溃）！"
        exit 1
    fi
done

for f in $(search_files '\.glassEffect\(|GlassEffectContainer' Sources || true); do
    # ripgrep prints Windows paths with backslashes; compare in one separator style.
    if [ "${f//\\//}" != "Sources/MenuBarMijiaApp/ThemeAndMotion.swift" ]; then
        echo "❌ $f 直接使用了 macOS 26 专属的 .glassEffect 或 GlassEffectContainer，请改用 ThemeAndMotion.swift 中的 adaptiveGlass / AdaptiveGlassContainer 以保持 macOS 14+ 兼容！"
        exit 1
    fi
done

if command -v rg >/dev/null 2>&1; then
    if rg -nU 'return \([^;{}]*\bawait\b' Sources; then
        echo "❌ 请勿在 return 元组字面量内直接内联 await（Swift 6.4 -O 协程分片优化会消除元组首字段写入导致 EXC_BAD_ACCESS），请先用 let 变量接收 await 结果再构造返回值！"
        exit 1
    fi
elif search_matches 'return \([^)]*\bawait\b' Sources; then
    echo "❌ 请勿在 return 元组字面量内直接内联 await（Swift 6.4 -O 协程分片优化会消除元组首字段写入导致 EXC_BAD_ACCESS），请先用 let 变量接收 await 结果再构造返回值！"
    exit 1
fi

select_python_bin() {
    local cand
    for cand in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python; do
        if command -v "$cand" >/dev/null 2>&1 \
            && "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
}

PYTHON_BIN="$(select_python_bin)"

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout docs/assets/*.svg Resources/AppIcon/*.svg
elif [ -n "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" -c 'import sys, xml.etree.ElementTree as ET; [ET.parse(f) for f in sys.argv[1:]]' docs/assets/*.svg Resources/AppIcon/*.svg
fi

if ! cmp -s Resources/AppIcon/AppIcon-Dark.svg docs/assets/logo-dark.svg || ! cmp -s Resources/AppIcon/AppIcon-Light.svg docs/assets/logo-light.svg; then
    echo "❌ docs/assets/logo-{dark,light}.svg 与 Resources/AppIcon/AppIcon-{Dark,Light}.svg 不一致，请运行 swift scripts/generate_app_icon.swift 同步！"
    exit 1
fi

# Shell-only self-tests do not require Python 3.
bash scripts/repeat_test.sh --self-test
bash scripts/red-check.sh --self-test
bash scripts/ci_swift_test.sh --self-test
bash scripts/test_ci_relevant_paths.sh
bash scripts/test_secret_scan.sh
bash scripts/test_install_ripgrep.sh
bash scripts/test_tauri_cache_key.sh
if command -v node >/dev/null 2>&1; then
    node windows/scripts/test-file.mjs --self-test
fi

# Design-token and Ed25519 checks need Python 3. CI runs them on ubuntu-latest
# (the Swift container image does not ship python3). Missing Python is recorded as a skip
# so neither --lint-only nor the full gate silently claims an all-green pass.
PYTHON_LINT_SKIPPED=0
if [ -n "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" scripts/check_design_tokens.py
    "$PYTHON_BIN" scripts/check_timer_render.py
    "$PYTHON_BIN" scripts/check_swift_harness_lints.py
    "$PYTHON_BIN" scripts/test_check_capability_matrix.py
    "$PYTHON_BIN" scripts/test_mijia_cli.py
    "$PYTHON_BIN" scripts/check_capability_matrix.py
    "$PYTHON_BIN" scripts/go2rtc-ptz/check_model_tables.py
    # Swift 与 Windows 测试都断言合成结果等于这份基线，所以这里直接读基线出报告（#295）。
    "$PYTHON_BIN" scripts/miot_coverage_report.py
    "$PYTHON_BIN" - <<'PY'
import base64
import re
import sys

files = {
    "Sources/MijiaCore/UpdateChecker.swift": r'updateSigningPublicKeyBase64\s*=\s*"([^"]+)"',
    "scripts/sign_update.swift": r'expectedPublicKeyBase64\s*=\s*"([^"]+)"',
    "windows/src/core/updateChecker.ts": r'UPDATE_SIGNING_PUBLIC_KEY_BASE64\s*=\s*"([^"]+)"',
    "windows/src-tauri/src/main.rs": r'UPDATE_SIGNING_PUBLIC_KEY_BASE64:\s*&str\s*=\s*"([^"]+)"',
}
keys = {}
for path, pat in files.items():
    with open(path, encoding="utf-8") as f:
        m = re.search(pat, f.read())
    if not m:
        sys.exit(f"❌ 无法从 {path} 读取 Ed25519 更新公钥常量")
    keys[path] = m.group(1)
if len(set(keys.values())) != 1:
    sys.exit(f"❌ 双端 Ed25519 更新公钥不一致：{keys}")

overlap_files = {
    "Sources/MijiaCore/UpdateChecker.swift": r'updateSigningOverlapPublicKeyBase64\s*=\s*"([^"]*)"',
    "windows/src-tauri/src/main.rs": r'UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64:\s*&str\s*=\s*"([^"]*)"',
}
overlaps = {}
for path, pat in overlap_files.items():
    with open(path, encoding="utf-8") as f:
        m = re.search(pat, f.read())
    if not m:
        sys.exit(f"❌ 无法从 {path} 读取 Ed25519 过渡公开钥常量")
    overlaps[path] = m.group(1)
if len(set(overlaps.values())) != 1:
    sys.exit(f"❌ 双端 Ed25519 过渡公开钥不一致：{overlaps}")
overlap = next(iter(overlaps.values()))
if overlap:
    try:
        decoded = base64.b64decode(overlap, validate=True)
    except Exception as error:
        sys.exit(f"❌ Ed25519 过渡公开钥不是合法 base64：{error}")
    if len(decoded) != 32:
        sys.exit(f"❌ Ed25519 过渡公开钥长度为 {len(decoded)} 字节，预期 32")
    if overlap in keys.values():
        sys.exit("❌ Ed25519 过渡公开钥不能与当前签名公钥相同")
PY
    "$PYTHON_BIN" scripts/update_manifest.py self-test
    # 发布附件集合（含两端 SBOM）是发版硬门槛，用 fixture 验证严格清单不会悄悄放宽。
    bash scripts/test_check_release.sh
    # 多个会话靠 issue-frontier.sh 挑票，判定规则放宽会导致重复认领（#338）。
    bash scripts/test_issue_frontier.sh
    bash scripts/test_gate_report.sh
    bash scripts/test_go2rtc_gate.sh
    bash scripts/test_ci_errors.sh
    bash scripts/test_pr_ready.sh
    if command -v pwsh >/dev/null 2>&1; then
        bash scripts/test_build_installer.sh
    fi
else
    PYTHON_LINT_SKIPPED=1
    echo "⏭️  跳过 Python 门禁检查：未找到 Python 3.10+"
fi

large_files=""
for dir in Sources Tests windows/src windows/src-tauri/src; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
        lines=$(wc -l < "$file" | tr -d '[:space:]')
        if [ "$lines" -gt 1500 ]; then
            large_files="${large_files}  ${lines}  ${file}"$'\n'
        fi
    done < <(find "$dir" -type f \( -name '*.swift' -o -name '*.ts' -o -name '*.rs' \) -print0)
done
if [ -n "$large_files" ]; then
    echo "⚠️  单文件行数告警（> 1500 行；新代码优先拆分，见 #184）："
    printf '%s' "$large_files"
else
    echo "✅ 没有超过 1500 行的源文件。"
fi

if [ "$LINT_ONLY" = "1" ]; then
    if [ "$PYTHON_LINT_SKIPPED" = "1" ]; then
        bash "$ROOT_DIR/scripts/gate_report.sh" summary "PythonLint=skip"
        exit $?
    fi
    echo "✅ 密钥与机械性编码规范检查通过！"
    exit 0
fi

# A new step is one add_gate_step line. The function calls record_gate_result with 名称=0, 名称=skip, or 名称=退出码.
gate_step_names=()
gate_step_fns=()
gate_results=()
add_gate_step() {
    gate_step_names[${#gate_step_names[@]}]="$1"
    gate_step_fns[${#gate_step_fns[@]}]="$2"
}
record_gate_result() {
    gate_results[${#gate_results[@]}]="$1"
}
if [ "$PYTHON_LINT_SKIPPED" = "1" ]; then
    record_gate_result "PythonLint=skip"
fi

run_logged() {
    local title="$1"
    shift
    local log status
    log="$(mktemp "${TMPDIR:-/tmp}/mmb-check.XXXXXX")"
    set +e
    "$@" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e
    if [ "$status" -ne 0 ]; then
        echo "❌ ${title} 失败（退出码 ${status}），完整日志：${log}" >&2
        bash "$ROOT_DIR/scripts/gate_report.sh" failing-tests "$log" >&2 || true
        return "$status"
    fi
    rm -f "$log"
    return 0
}

windows_npm() {
    cd "$ROOT_DIR/windows"
    npm test && npm run typecheck && npm run build
}

raycast_npm() {
    cd "$ROOT_DIR/raycast"
    npm test && npm run typecheck
}

run_swift_gate() {
    local status=0
    if [ "$(uname -s)" = "Linux" ]; then
        # Package.swift requires the macOS SDK. CI's linux-core job runs MijiaCore through this
        # shim; `swift test` at the repo root cannot compile Security/AppKit imports on Linux.
        echo "运行 Linux 上的 MijiaCore 测试（scripts/linux-check）与双端黄金语料校验..."
        run_logged "Linux MijiaCore" bash "$ROOT_DIR/scripts/linux-check/run.sh" || status=$?
        record_gate_result "Swift=${status}"
    elif ! command -v swift >/dev/null 2>&1; then
        # Windows development machines have no Swift toolchain; CI still runs the suite.
        record_gate_result "Swift=skip"
        echo "⏭️  跳过 Swift 门槛：未找到 swift"
        return 0
    elif [ "$SKIP_SNAPSHOTS" = "1" ]; then
        # For a machine whose renderer is not the reference (any Mac other than the one that records the
        # baselines). The default gate compares snapshots.
        echo "运行 Swift 单元测试（跳过快照）与双端黄金语料校验..."
        run_logged "Swift 测试" swift test --skip SnapshotTests || status=$?
        record_gate_result "Swift=${status}"
        # The summary must not call this a full pass: the snapshot comparison did not run.
        record_gate_result "Snapshots=skip"
    else
        echo "运行 Swift 单元测试 (swift test) 与双端黄金语料校验..."
        run_logged "Swift 测试" swift test || status=$?
        record_gate_result "Swift=${status}"
    fi
    [ "$status" -eq 0 ]
}

has_shared_windows_deps() {
    [ "${MMB_DISABLE_SHARED_NODE_MODULES:-0}" = "1" ] && return 1
    [ -f "$ROOT_DIR/windows/package-lock.json" ] || return 1
    local wt
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt="${line#worktree }"
                [ "$wt" = "$ROOT_DIR" ] && continue
                if [ -d "$wt/windows/node_modules/typescript" ] \
                    && [ -f "$wt/windows/package-lock.json" ] \
                    && cmp -s "$ROOT_DIR/windows/package-lock.json" "$wt/windows/package-lock.json"; then
                    return 0
                fi
                ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null || true)
    return 1
}

windows_shared_tests() {
    cd "$ROOT_DIR/windows"
    npm test
}

run_windows_gate() {
    if [ ! -x "windows/node_modules/.bin/tsc" ]; then
        if command -v npm >/dev/null 2>&1 && has_shared_windows_deps; then
            local status=0
            echo "ℹ️  复用同锁文件的兄弟工作树依赖运行 Windows 单元测试（跳过 Vite 打包）..."
            run_logged "Windows 单元测试" windows_shared_tests || status=$?
            record_gate_result "WindowsTests=${status}"
            record_gate_result "WindowsBuild=skip"
            [ "$status" -eq 0 ]
            return $?
        fi
        record_gate_result "Windows=skip"
        echo "⏭️  跳过 Windows 门槛：未找到 windows/node_modules（先 cd windows && npm ci）"
        return 0
    fi
    # `npm run build` = tsc --noEmit + vite build: the bundle that ships in the installer,
    # which typecheck alone does not prove (asset imports, CSS, chunk limits).
    local status=0
    run_logged "Windows 前端" windows_npm || status=$?
    record_gate_result "Windows=${status}"
    [ "$status" -eq 0 ]
}

run_raycast_gate() {
    if [ ! -x "raycast/node_modules/.bin/tsc" ]; then
        record_gate_result "Raycast=skip"
        echo "⏭️  跳过 Raycast 门槛：未找到 raycast/node_modules（先 cd raycast && npm ci）"
        return 0
    fi
    local status=0
    run_logged "Raycast 扩展" raycast_npm || status=$?
    record_gate_result "Raycast=${status}"
    [ "$status" -eq 0 ]
}

# verify.sh clones go2rtc and runs go test -race. --lint-only returns before these
# steps, so a machine that already has Go keeps the fast lint. The patch SHA is
# checked in check_model_tables.py, which that fast path already runs.
# A directory or a stub that fails `go version` is not a toolchain: skip it.
# A working go whose verify.sh fails still fails this gate.
run_go2rtc_gate() {
    local go err status=0
    err="$(mktemp)"
    if ! go="$(bash "$ROOT_DIR/scripts/go2rtc-ptz/go_ready.sh" 2>"$err")"; then
        record_gate_result "go2rtc=skip"
        echo "⏭️  跳过 go2rtc 云台补丁验证：$(cat "$err")"
        rm -f "$err"
        return 0
    fi
    rm -f "$err"
    run_logged "go2rtc 云台补丁" bash "$ROOT_DIR/scripts/go2rtc-ptz/verify.sh" || status=$?
    record_gate_result "go2rtc=${status}"
    [ "$status" -eq 0 ]
}

add_gate_step "Swift 测试" run_swift_gate
add_gate_step "Windows 前端" run_windows_gate
add_gate_step "Raycast 扩展" run_raycast_gate
add_gate_step "go2rtc 云台补丁" run_go2rtc_gate

failed=0
step_total=${#gate_step_fns[@]}
step_index=0
while [ "$step_index" -lt "$step_total" ]; do
    echo "🧪 [$((step_index + 1))/${step_total}] ${gate_step_names[$step_index]}"
    if ! "${gate_step_fns[$step_index]}"; then
        failed=1
    fi
    step_index=$((step_index + 1))
done

set +e
if [ "${#gate_results[@]}" -eq 0 ]; then
    bash "$ROOT_DIR/scripts/gate_report.sh" summary
else
    bash "$ROOT_DIR/scripts/gate_report.sh" summary "${gate_results[@]}"
fi
summary_status=$?
set -e
if [ "$failed" -ne 0 ] && [ "$summary_status" -eq 0 ]; then
    echo "❌ 门禁未通过：某一步失败了，但汇总结果仍是通过" >&2
    exit 1
fi
exit "$summary_status"
