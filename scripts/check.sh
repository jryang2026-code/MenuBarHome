#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONIOENCODING=utf-8

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

LINT_ONLY=0
SKIP_SNAPSHOTS=0
RUN_SCRIPT_TESTS=0
CHANGED_ONLY=0
BASE_REF=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --lint-only)
            LINT_ONLY=1
            shift
            ;;
        --skip-snapshots)
            SKIP_SNAPSHOTS=1
            shift
            ;;
        --script-tests)
            RUN_SCRIPT_TESTS=1
            shift
            ;;
        --changed)
            CHANGED_ONLY=1
            shift
            ;;
        --base)
            [ "$#" -ge 2 ] || {
                echo "❌ --base 需要指定比较基准引用" >&2
                exit 2
            }
            BASE_REF="$2"
            shift 2
            ;;
        *)
            echo "❌ 未知参数：$1（可用：--lint-only --script-tests --changed [--base <ref>] --skip-snapshots）" >&2
            exit 2
            ;;
    esac
done

# The hooks live in the shared git directory, so every worktree gets the same gates.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
case "$GIT_COMMON_DIR" in
    "") ;;
    /*) ;;
    *) GIT_COMMON_DIR="$ROOT_DIR/$GIT_COMMON_DIR" ;;
esac
if [ -n "$GIT_COMMON_DIR" ] && [ -d "$GIT_COMMON_DIR/hooks" ]; then
    # Every worktree shares these hooks, so wrappers invoke the active worktree's own copy.
    install_hook_wrapper() {
        local hook_name="$1"
        local hook_path="$GIT_COMMON_DIR/hooks/$hook_name"
        local wrapper="#!/usr/bin/env bash
# Installed by scripts/check.sh: run the active worktree's own ${hook_name} gate.
exec bash \"\$(git rev-parse --show-toplevel)/scripts/hooks/${hook_name}\" \"\$@\""
        if [ -L "$hook_path" ] || [ "$(cat "$hook_path" 2>/dev/null || true)" != "$wrapper" ]; then
            rm -f "$hook_path"
            printf '%s\n' "$wrapper" > "$hook_path" && chmod +x "$hook_path" 2>/dev/null || true
        fi
    }
    install_hook_wrapper "pre-commit"
    install_hook_wrapper "pre-push"
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

# Fast static checks run locally on every commit and on ubuntu-latest in CI
# (the Swift container image does not ship python3). Missing Python is recorded as a skip.
PYTHON_LINT_SKIPPED=0
if [ -n "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" scripts/check_design_tokens.py
    "$PYTHON_BIN" scripts/check_timer_render.py
    "$PYTHON_BIN" scripts/check_swift_harness_lints.py
    "$PYTHON_BIN" scripts/check_workflows.py
    "$PYTHON_BIN" scripts/check_doc_links.py
    "$PYTHON_BIN" scripts/check_capability_matrix.py
    "$PYTHON_BIN" scripts/go2rtc-ptz/check_model_tables.py
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
else
    PYTHON_LINT_SKIPPED=1
    echo "⏭️  跳过 Python 门禁检查：未找到 Python 3.10+"
fi

large_files=""
for dir in Sources Tests windows/src windows/src-tauri/src windows/tests; do
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

run_clean_env() {
    env -u GITHUB_EVENT_NAME -u GITHUB_REF -u GITHUB_REF_TYPE -u GITHUB_OUTPUT -u GITHUB_SHA -u GITHUB_ACTIONS \
        -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_PREFIX \
        "$@"
}

run_script_self_tests() {
    echo "🧪 运行脚本与工具自检 (--script-tests)..."
    run_clean_env bash scripts/repeat_test.sh --self-test
    run_clean_env bash scripts/red-check.sh --self-test
    run_clean_env bash scripts/ci_swift_test.sh --self-test
    run_clean_env bash scripts/test_ci_relevant_paths.sh
    run_clean_env bash scripts/test_secret_scan.sh
    run_clean_env bash scripts/test_install_ripgrep.sh
    if command -v node >/dev/null 2>&1; then
        run_clean_env node windows/scripts/test-file.mjs --self-test
    fi
    if [ -n "$PYTHON_BIN" ]; then
        run_clean_env "$PYTHON_BIN" scripts/check_workflows.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/check_doc_links.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/test_check_capability_matrix.py
        run_clean_env "$PYTHON_BIN" scripts/test_mijia_cli.py
        run_clean_env "$PYTHON_BIN" scripts/test_local_macos_runner.py
        run_clean_env "$PYTHON_BIN" scripts/update_manifest.py self-test
        run_clean_env bash scripts/test_check_release.sh
        run_clean_env bash scripts/test_issue_frontier.sh
        run_clean_env bash scripts/test_gate_report.sh
        run_clean_env bash scripts/test_go2rtc_gate.sh
        run_clean_env bash scripts/test_ci_errors.sh
        run_clean_env bash scripts/test_pr_ready.sh
        if command -v pwsh >/dev/null 2>&1; then
            run_clean_env bash scripts/test_build_installer.sh
        fi
    fi
}

if [ "$RUN_SCRIPT_TESTS" = "1" ]; then
    run_script_self_tests
fi

if [ "$LINT_ONLY" = "1" ]; then
    if [ "$PYTHON_LINT_SKIPPED" = "1" ]; then
        bash "$ROOT_DIR/scripts/gate_report.sh" summary "PythonLint=skip"
        exit $?
    fi
    echo "✅ 密钥与机械性编码规范检查通过！"
    exit 0
fi

# Resolve changed scope for `--changed` mode, or detect whether `scripts/go2rtc-ptz/` changed on full runs.
SCOPE_MACOS=true
SCOPE_WINDOWS=true
SCOPE_CORE=true
SCOPE_RAYCAST=true
SCOPE_SCRIPTS=false
SCOPE_GO2RTC=false
MACOS_APP_CHANGED=1

resolve_base_ref() {
    if [ -n "$BASE_REF" ]; then
        printf '%s\n' "$BASE_REF"
        return 0
    fi
    local branch head_sha upstream_sha
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "$branch" = "main" ] && git rev-parse --verify origin/main >/dev/null 2>&1; then
        head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
        upstream_sha="$(git rev-parse origin/main 2>/dev/null || true)"
        if [ -n "$head_sha" ] && [ -n "$upstream_sha" ] && [ "$head_sha" != "$upstream_sha" ]; then
            printf '%s\n' "origin/main"
            return 0
        fi
    fi
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        git merge-base HEAD origin/main 2>/dev/null || printf '%s\n' "origin/main"
        return 0
    fi
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        printf '%s\n' "HEAD~1"
        return 0
    fi
    return 1
}

collect_changed_files() {
    local base="$1"
    {
        if [ -n "$base" ] && git cat-file -e "${base}^{commit}" 2>/dev/null; then
            git diff --name-only --no-renames "$base" HEAD 2>/dev/null || true
        fi
        git diff --name-only --no-renames 2>/dev/null || true
        git diff --cached --name-only --no-renames 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
    } | sort -u | sed '/^$/d'
}

if [ "$CHANGED_ONLY" = "1" ]; then
    resolved_base="$(resolve_base_ref || true)"
    changed_list="$(collect_changed_files "$resolved_base")"
    if [ -z "$changed_list" ]; then
        echo "✅ 未检测到相对基线（${resolved_base:-工作区}）的改动，快速静态检查已通过。"
        if [ "$PYTHON_LINT_SKIPPED" = "1" ]; then
            bash "$ROOT_DIR/scripts/gate_report.sh" summary "PythonLint=skip"
            exit $?
        fi
        exit 0
    fi

    scope_output="$(printf '%s\n' "$changed_list" | bash "$ROOT_DIR/scripts/ci_relevant_paths.sh")"
    eval "$scope_output"
    SCOPE_MACOS="$macos"
    SCOPE_WINDOWS="$windows"
    SCOPE_CORE="$core"
    SCOPE_RAYCAST="$raycast"
    SCOPE_SCRIPTS="$scripts"
    SCOPE_GO2RTC="$go2rtc"

    MACOS_APP_CHANGED=0
    if printf '%s\n' "$changed_list" | grep -Eq '^(Sources/MenuBarMijiaApp/|Resources/|Tests/MenuBarMijiaAppTests/|Package\.(swift|resolved)$)'; then
        MACOS_APP_CHANGED=1
    fi

    echo "🎯 增量门禁命中范围：macos=${SCOPE_MACOS} core=${SCOPE_CORE} windows=${SCOPE_WINDOWS} raycast=${SCOPE_RAYCAST} scripts=${SCOPE_SCRIPTS} go2rtc=${SCOPE_GO2RTC}"
    if [ "$SCOPE_SCRIPTS" = "true" ] && [ "$RUN_SCRIPT_TESTS" != "1" ]; then
        run_script_self_tests
    fi
else
    if [ "${MMB_FORCE_GO2RTC:-0}" = "1" ]; then
        SCOPE_GO2RTC=true
    else
        resolved_base="$(resolve_base_ref || true)"
        changed_list="$(collect_changed_files "$resolved_base")"
        if printf '%s\n' "$changed_list" | grep -q '^scripts/go2rtc-ptz/'; then
            SCOPE_GO2RTC=true
        fi
    fi
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
    elif [ "$CHANGED_ONLY" = "1" ] && [ "$MACOS_APP_CHANGED" = "0" ]; then
        echo "ℹ️  仅核心层改动，跳过 UI 快照渲染比对，运行 MijiaCore 单元测试..."
        run_logged "Swift 核心测试" swift test --skip SnapshotTests || status=$?
        record_gate_result "Swift=${status}"
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
# steps, and unchanged runs rely on check_model_tables.py verifying the patch SHA-256.
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

if [ "$SCOPE_MACOS" = "true" ] || [ "$SCOPE_CORE" = "true" ]; then
    add_gate_step "Swift 测试" run_swift_gate
fi
if [ "$SCOPE_WINDOWS" = "true" ]; then
    add_gate_step "Windows 前端" run_windows_gate
fi
if [ "$SCOPE_RAYCAST" = "true" ]; then
    add_gate_step "Raycast 扩展" run_raycast_gate
fi
if [ "$SCOPE_GO2RTC" = "true" ] || [ "${MMB_FORCE_GO2RTC:-0}" = "1" ]; then
    add_gate_step "go2rtc 云台补丁" run_go2rtc_gate
fi

step_total=${#gate_step_fns[@]}
if [ "$step_total" -eq 0 ]; then
    echo "✅ 受影响检查已完成（无需运行编译或单元测试套件）。"
    if [ "${#gate_results[@]}" -eq 0 ]; then
        exit 0
    fi
    bash "$ROOT_DIR/scripts/gate_report.sh" summary "${gate_results[@]}"
    exit $?
fi

failed=0
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
