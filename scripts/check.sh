#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONIOENCODING=utf-8

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

LINT_ONLY=0
SKIP_SNAPSHOTS=0
RUN_SNAPSHOTS=0
RUN_SCRIPT_TESTS=0
CHANGED_ONLY=0
INSTALL_HOOKS=0
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
        --snapshots)
            RUN_SNAPSHOTS=1
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
        --install-hooks)
            INSTALL_HOOKS=1
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
            echo "❌ 未知参数：$1（可用：--lint-only --script-tests --changed [--base <ref>] --skip-snapshots --snapshots --install-hooks）" >&2
            exit 2
            ;;
    esac
done

if [ "$SKIP_SNAPSHOTS" = "1" ] && [ "$RUN_SNAPSHOTS" = "1" ]; then
    echo "❌ --snapshots 与 --skip-snapshots 不能同时使用" >&2
    exit 2
fi

install_git_hooks() {
    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    case "$git_common_dir" in
        "") return 0 ;;
        /*) ;;
        *) git_common_dir="$ROOT_DIR/$git_common_dir" ;;
    esac
    [ -d "$git_common_dir/hooks" ] || return 0
    local hook_name hook_path wrapper
    for hook_name in pre-commit pre-push; do
        hook_path="$git_common_dir/hooks/$hook_name"
        if [ "$INSTALL_HOOKS" != "1" ] && [ -x "$hook_path" ] && [ ! -L "$hook_path" ]; then
            continue
        fi
        wrapper="#!/usr/bin/env bash
exec bash \"\$(git rev-parse --show-toplevel)/scripts/hooks/${hook_name}\" \"\$@\""
        rm -f "$hook_path"
        printf '%s\n' "$wrapper" > "$hook_path" && chmod +x "$hook_path" 2>/dev/null || true
    done
}

install_git_hooks

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
        raycast/tests
        packaging
        scripts
        .github/workflows
        docs
    )
    local existing_dirs=() dir
    for dir in "${scan_dirs[@]}"; do
        [ -d "$dir" ] && existing_dirs+=("$dir")
    done
    scan_dirs=("${existing_dirs[@]}")

    local combined_hits=""
    local scan_status=0
    combined_hits="$(search_matches '(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|localhost:3425)' "${scan_dirs[@]}")" || scan_status=$?
    if [ "$scan_status" -ne 0 ] && [ "$scan_status" -ne 1 ]; then
        echo "❌ 密钥与私网地址扫描本身失败（退出码 ${scan_status}），无法确认没有泄漏！"
        return 1
    fi
    if [ -n "$combined_hits" ]; then
        local jwt_hits lan_ip_hits debug_port_hits
        jwt_hits="$(printf '%s\n' "$combined_hits" | grep -E 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' || true)"
        if [ -n "$jwt_hits" ]; then
            printf '%s\n' "$jwt_hits"
            echo "❌ 检测到疑似 JWT Token，请移除后再提交！"
            return 1
        fi
        lan_ip_hits="$(printf '%s\n' "$combined_hits" | grep -E '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -Ev '^Tests[/\\]+Fixtures[/\\]+(local_network_endpoint|miio_protocol)_golden\.json:|^scripts[/\\]+hooks[/\\]+pre-push:' || true)"
        debug_port_hits="$(printf '%s\n' "$combined_hits" | grep -F 'localhost:3425' | grep -Ev '^Tests[/\\]+MijiaCoreTests[/\\]+AssistantTests\.swift:|^scripts[/\\]+check\.sh:' || true)"
        if [ -n "$lan_ip_hits" ] || [ -n "$debug_port_hits" ]; then
            [ -n "$lan_ip_hits" ] && printf '%s\n' "$lan_ip_hits"
            [ -n "$debug_port_hits" ] && printf '%s\n' "$debug_port_hits"
            echo "❌ 检测到硬编码的个人局域网 IP 或本机调试端口 (localhost:3425)，请移除！"
            return 1
        fi
    fi

    if ! search_quiet 'defaultSeededToken = ""' Sources/MijiaCore/KeychainAndPrefs.swift; then
        echo "❌ KeychainAndPrefs.swift 中的 defaultSeededToken 必须为空字符串！"
        return 1
    fi

    if ! search_quiet 'defaultHost = ""' Sources/MijiaCore/LGWebOSClient.swift; then
        echo "❌ LGWebOSClient.swift 中的 defaultHost 必须为空字符串！"
        return 1
    fi
    return 0
}

check_git_identity() {
    git rev-parse --git-dir >/dev/null 2>&1 || return 0

    local author_ident committer_ident
    author_ident="$(git var GIT_AUTHOR_IDENT 2>/dev/null || true)"
    committer_ident="$(git var GIT_COMMITTER_IDENT 2>/dev/null || true)"
    if printf '%s\n%s\n' "$author_ident" "$committer_ident" | grep -qF "jryang1997"; then
        echo "❌ 当前 Git 提交身份仍为已停用账号 jryang1997，请先在当前工作树设置："
        echo '   git config user.name "jryang2026-code" && git config user.email "jryang2026-code@users.noreply.github.com"'
        return 1
    fi

    local retired_commits=""
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        retired_commits="$(git log --format='%h %an <%ae> | %cn <%ce>' origin/main..HEAD 2>/dev/null | grep -F 'jryang1997' || true)"
    elif [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
        retired_commits="$(git log -1 --format='%h %an <%ae> | %cn <%ce>' HEAD 2>/dev/null | grep -F 'jryang1997' || true)"
    fi
    if [ -n "$retired_commits" ]; then
        printf '%s\n' "$retired_commits"
        echo "❌ 当前分支包含已停用账号 jryang1997 的提交，请改写作者为 jryang2026-code 后再继续！"
        return 1
    fi
    return 0
}

echo "🔍 检查是否存在硬编码 JWT / 密钥 / 个人局域网地址泄露..."
check_secret_leaks
check_git_identity

echo "🔍 检查机械性编码规范 (Swift 宏/并发隔离/UNUserNotificationCenter Bundle 守卫)..."

if search_matches '#require\([^)]*#require' Tests/; then
    echo "❌ Swift Testing 的 #require 不能嵌套展开（宏递归会编译失败），请先解包到变量再 require！"
    exit 1
fi

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
        if command -v "$cand" >/dev/null 2>&1; then
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

PYTHON_LINT_SKIPPED=0
if [ -n "$PYTHON_BIN" ]; then
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
    if [ "$RUN_SCRIPT_TESTS" != "1" ] && ! git diff --quiet HEAD -- .github/workflows 2>/dev/null; then
        "$PYTHON_BIN" scripts/check_workflows.py
    fi
else
    PYTHON_LINT_SKIPPED=1
    echo "⏭️  跳过 Python 门禁检查：未找到 Python 3.10+"
fi

run_clean_env() {
    env -u GITHUB_EVENT_NAME -u GITHUB_REF -u GITHUB_REF_TYPE -u GITHUB_OUTPUT -u GITHUB_SHA -u GITHUB_ACTIONS \
        -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_PREFIX \
        "$@"
}

run_contract_checks() {
    if [ -n "$PYTHON_BIN" ]; then
        "$PYTHON_BIN" scripts/check_workflows.py
        "$PYTHON_BIN" scripts/check_doc_links.py
        "$PYTHON_BIN" scripts/check_capability_matrix.py
        "$PYTHON_BIN" scripts/check_capability_manifest.py
        "$PYTHON_BIN" scripts/check_adapter_protocol.py
        "$PYTHON_BIN" scripts/check_tv_catalog.py
        "$PYTHON_BIN" scripts/check_device_rules.py
        "$PYTHON_BIN" scripts/check_supported_devices.py
        "$PYTHON_BIN" scripts/check_windows_geometry.py
        "$PYTHON_BIN" scripts/go2rtc-ptz/check_model_tables.py
    fi
}

run_script_self_tests() {
    echo "🧪 运行契约与脚本工具自检 (--script-tests)..."
    run_contract_checks
    if [ -n "$PYTHON_BIN" ]; then
        run_clean_env "$PYTHON_BIN" scripts/check_doc_links.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/test_mijia_cli.py
        run_clean_env "$PYTHON_BIN" scripts/update_manifest.py self-test
        run_clean_env "$PYTHON_BIN" scripts/probe_lan_gateway.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/measure_footprint.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/check_capability_manifest.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/check_adapter_protocol.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/check_tv_catalog.py --self-test
        run_clean_env "$PYTHON_BIN" scripts/check_device_rules.py --self-test
        run_clean_env bash scripts/test_ci_relevant_paths.sh
        run_clean_env bash scripts/test_check_release.sh
        run_clean_env bash scripts/test_mirror_release.sh
        run_clean_env bash scripts/test_nas_setup.sh
        run_clean_env "$PYTHON_BIN" scripts/test_pr_ready.py
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

SCOPE_MACOS=true
SCOPE_WINDOWS=true
SCOPE_CORE=true
SCOPE_RAYCAST=true
SCOPE_SCRIPTS=false
SCOPE_WEBSITE=true
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
    SCOPE_WEBSITE="$website"
    SCOPE_GO2RTC="$go2rtc"

    MACOS_APP_CHANGED=0
    if printf '%s\n' "$changed_list" | grep -Eq '^(Sources/MenuBarMijiaApp/|Resources/|Tests/MenuBarMijiaAppTests/|Package\.(swift|resolved)$)'; then
        MACOS_APP_CHANGED=1
    fi

    echo "🎯 增量门禁命中范围：macos=${SCOPE_MACOS} core=${SCOPE_CORE} windows=${SCOPE_WINDOWS} raycast=${SCOPE_RAYCAST} website=${SCOPE_WEBSITE} scripts=${SCOPE_SCRIPTS} go2rtc=${SCOPE_GO2RTC}"
    if [ "$RUN_SCRIPT_TESTS" != "1" ]; then
        if [ "$SCOPE_SCRIPTS" = "true" ] || printf '%s\n' "$changed_list" | grep -q '^nas/'; then
            run_script_self_tests
        elif [ -n "$PYTHON_BIN" ]; then
            if printf '%s\n' "$changed_list" | grep -q '^\.github/workflows/'; then
                "$PYTHON_BIN" scripts/check_workflows.py
            fi
            if printf '%s\n' "$changed_list" | grep -Eq '(\.md$|^docs/|^Shared/|^Tests/Fixtures/(adapter-protocol|tv-plugin)/)'; then
                "$PYTHON_BIN" scripts/check_doc_links.py
                "$PYTHON_BIN" scripts/check_capability_matrix.py
                "$PYTHON_BIN" scripts/check_capability_manifest.py
                "$PYTHON_BIN" scripts/check_adapter_protocol.py
                "$PYTHON_BIN" scripts/check_tv_catalog.py
                "$PYTHON_BIN" scripts/check_device_rules.py
                "$PYTHON_BIN" scripts/check_supported_devices.py
            elif printf '%s\n' "$changed_list" | grep -Eq '(^adapters/mbh-tv-bridge/|TVBridge|tvBridge)'; then
                "$PYTHON_BIN" scripts/check_tv_catalog.py
            fi
            if [ "$SCOPE_WINDOWS" = "true" ]; then
                "$PYTHON_BIN" scripts/check_windows_geometry.py
            fi
            if [ "$SCOPE_GO2RTC" = "true" ] || printf '%s\n' "$changed_list" | grep -Eq '(CameraPTZ\.swift|camera_ptz_models\.json)'; then
                "$PYTHON_BIN" scripts/go2rtc-ptz/check_model_tables.py
            fi
        fi
    fi
else
    if [ "$RUN_SCRIPT_TESTS" != "1" ]; then
        run_script_self_tests
    fi
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
    npm run build && npm test
}

raycast_npm() {
    cd "$ROOT_DIR/raycast"
    npm test && npm run typecheck
}

website_npm() {
    npm --prefix "$ROOT_DIR/website" run typecheck
}

run_swift_gate() {
    local status=0
    if [ "$(uname -s)" = "Linux" ]; then
        echo "运行 Linux 上的 MijiaCore 测试（scripts/linux-check）与双端黄金语料校验..."
        run_logged "Linux MijiaCore" bash "$ROOT_DIR/scripts/linux-check/run.sh" || status=$?
        record_gate_result "Swift=${status}"
    elif ! command -v swift >/dev/null 2>&1; then
        record_gate_result "Swift=skip"
        echo "⏭️  跳过 Swift 门槛：未找到 swift"
        return 0
    elif [ "$SKIP_SNAPSHOTS" = "1" ]; then
        echo "运行 Swift 单元测试（跳过快照）与双端黄金语料校验..."
        run_logged "Swift 测试" swift test --skip SnapshotTests || status=$?
        record_gate_result "Swift=${status}"
        record_gate_result "Snapshots=skip"
    elif [ "$CHANGED_ONLY" = "1" ] && [ "$MACOS_APP_CHANGED" = "0" ]; then
        echo "ℹ️  仅核心层改动，跳过 UI 快照渲染比对，运行 MijiaCore 单元测试..."
        run_logged "Swift 核心测试" swift test --skip SnapshotTests || status=$?
        record_gate_result "Swift=${status}"
    elif [ "$RUN_SNAPSHOTS" = "1" ]; then
        echo "运行 Swift 单元测试，并额外做一次本机快照比对（失败不阻断）..."
        echo "像素基准是 GitHub 托管机 macos-26-intel（Xcode 26.6，zh_CN）。本机结果只供参考。"
        run_logged "Swift 测试" swift test --skip SnapshotTests || status=$?
        record_gate_result "Swift=${status}"
        if [ "$status" -eq 0 ]; then
            local snap=0
            set +e
            swift test --filter SnapshotTests
            snap=$?
            set -e
            if [ "$snap" -ne 0 ]; then
                echo "⚠️ 本机快照与基准不一致。这不阻断本机门禁。更新基线可运行 bash scripts/record_snapshots.sh。"
                record_gate_result "Snapshots=advisory"
            fi
        fi
    else
        echo "运行 Swift 单元测试（跳过快照像素比对）与双端黄金语料校验..."
        echo "像素基准是 GitHub 托管机 macos-26-intel（Xcode 26.6，zh_CN）。本机预览用 bash scripts/check.sh --snapshots。"
        run_logged "Swift 测试" swift test --skip SnapshotTests || status=$?
        record_gate_result "Swift=${status}"
        record_gate_result "Snapshots=skip"
    fi
    [ "$status" -eq 0 ]
}

source "$ROOT_DIR/scripts/shared_windows_deps.sh"

run_windows_gate() {
    cleanup_shared_windows_deps
    if [ ! -x "$ROOT_DIR/windows/node_modules/.bin/tsc" ]; then
        local shared_nm=""
        if command -v npm >/dev/null 2>&1 && shared_nm="$(find_shared_windows_node_modules)"; then
            local status=0
            trap 'cleanup_shared_windows_deps' EXIT INT TERM HUP
            echo "ℹ️  复用同锁文件的兄弟工作树依赖运行完整 Windows 前端门禁（单测 + 类型检查 + Vite 打包）..."
            run_logged "Windows 前端" with_shared_windows_deps "$shared_nm" windows_npm || status=$?
            cleanup_shared_windows_deps
            trap - EXIT INT TERM HUP
            record_gate_result "Windows=${status}"
            [ "$status" -eq 0 ]
            return $?
        fi
        record_gate_result "Windows=skip"
        echo "⏭️  跳过 Windows 门槛：未找到 windows/node_modules（先 cd windows && npm ci）"
        return 0
    fi
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

run_website_gate() {
    if [ ! -d "website/node_modules" ]; then
        record_gate_result "Website=skip"
        echo "⏭️  跳过 Website 门槛：未找到 website/node_modules（先 npm ci --prefix website）"
        return 0
    fi
    local status=0
    run_logged "Website 类型检查" website_npm || status=$?
    record_gate_result "Website=${status}"
    [ "$status" -eq 0 ]
}

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
if [ "$SCOPE_WEBSITE" = "true" ]; then
    add_gate_step "Website 类型检查" run_website_gate
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
