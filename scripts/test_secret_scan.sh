#!/usr/bin/env bash
# check.sh 密钥、私网 10/8 与调试端口扫描范围自测（覆盖 Windows 与 Raycast 源码目录，排除依赖与构建产物）。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

if grep -Eq '^[[:space:]]*check_secret_leaks([[:space:]]|$)' "$root/scripts/check.sh"; then
    pass "check.sh 顶层调用 check_secret_leaks"
else
    fail "check.sh 未调用 check_secret_leaks"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mmb-secret-scan.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

harness="$tmp/harness.sh"
{
    printf '%s\n' 'set -euo pipefail'
    sed -n '/^search_matches()/,/^}/p' "$root/scripts/check.sh"
    sed -n '/^search_quiet()/,/^}/p' "$root/scripts/check.sh"
    sed -n '/^check_secret_leaks()/,/^}/p' "$root/scripts/check.sh"
    printf '%s\n' 'check_secret_leaks'
} >"$harness"

jwt_sample="eyJhbGciOiJIUzI1NiJ9"".""eyJzdWIiOiJ0ZXN0LWxlYWsifQ"
ip_sample="10.42"".88.9"
exempt_ip="10.0"".0.5"
port_sample="localhost:""3425"

reset_fixture() {
    local fx="$1"
    rm -rf "$fx"
    mkdir -p \
        "$fx/Sources/MijiaCore" \
        "$fx/Tests/Fixtures" \
        "$fx/Tests/MijiaCoreTests" \
        "$fx/windows/src" \
        "$fx/windows/src-tauri/src" \
        "$fx/windows/tests" \
        "$fx/raycast/src" \
        "$fx/windows/node_modules/pkg" \
        "$fx/windows/src/node_modules/nested" \
        "$fx/windows/dist" \
        "$fx/windows/src-tauri/target/debug" \
        "$fx/raycast/node_modules/pkg" \
        "$fx/raycast/dist"

    printf '%s\n' 'public enum K { static let defaultSeededToken = "" }' >"$fx/Sources/MijiaCore/KeychainAndPrefs.swift"
    printf '%s\n' 'public enum L { static let defaultHost = "" }' >"$fx/Sources/MijiaCore/LGWebOSClient.swift"
    printf '{"cases":[{"host":"%s","isLocalNetwork":true}]}\n' "$exempt_ip" >"$fx/Tests/Fixtures/local_network_endpoint_golden.json"
    printf 'let custom = "http://%s/v1"\n' "$port_sample" >"$fx/Tests/MijiaCoreTests/AssistantTests.swift"

    printf '%s\n' 'export const ok = "192.0.2.10";' >"$fx/windows/src/ok.ts"
    printf '%s\n' 'pub const OK: &str = "v10.0";' >"$fx/windows/src-tauri/src/ok.rs"
    printf '%s\n' 'export const testOk = true;' >"$fx/windows/tests/ok.test.ts"
    printf '%s\n' 'export const raycastOk = true;' >"$fx/raycast/src/ok.ts"

    # 构建产物与依赖目录即使含疑似 token / 私网地址也不得触发误报。
    local decoy="${jwt_sample} ${ip_sample} http://${port_sample}"
    printf '%s\n' "$decoy" >"$fx/windows/node_modules/pkg/index.js"
    printf '%s\n' "$decoy" >"$fx/windows/src/node_modules/nested/index.js"
    printf '%s\n' "$decoy" >"$fx/windows/dist/bundle.js"
    printf '%s\n' "$decoy" >"$fx/windows/src-tauri/target/debug/generated.rs"
    printf '%s\n' "$decoy" >"$fx/raycast/node_modules/pkg/index.js"
    printf '%s\n' "$decoy" >"$fx/raycast/dist/index.js"
}

bash_bin="$(command -v bash)"

run_suite() {
    local mode_label="$1" run_path="$2"
    local fx="$tmp/fx" out="$tmp/out" status

    expect_pass() {
        local label="$1"
        set +e
        (cd "$fx" && PATH="$run_path" "$bash_bin" "$harness") >"$out" 2>&1
        status=$?
        set -e
        if [ "$status" -eq 0 ]; then
            pass "${mode_label}: ${label}"
        else
            fail "${mode_label}: ${label} 应通过，实际退出 ${status}：$(cat "$out")"
        fi
    }

    expect_caught() {
        local label="$1" rel_file="$2" payload="$3" expected_needle="$4"
        reset_fixture "$fx"
        printf '%s\n' "$payload" >"$fx/$rel_file"
        set +e
        (cd "$fx" && PATH="$run_path" "$bash_bin" "$harness") >"$out" 2>&1
        status=$?
        set -e
        if [ "$status" -eq 1 ] && grep -qF -- "$expected_needle" "$out"; then
            pass "${mode_label}: ${label}"
        else
            fail "${mode_label}: ${label} 应退出 1 且包含「${expected_needle}」，实际退出 ${status}：$(cat "$out")"
        fi
    }

    reset_fixture "$fx"
    expect_pass "干净基线放行黄金豁免并忽略 node_modules/target/dist"

    expect_caught "拦截 windows/src JWT" "windows/src/leak.ts" "const t = '${jwt_sample}';" "JWT Token"
    expect_caught "拦截 windows/src-tauri/src JWT" "windows/src-tauri/src/leak.rs" "const T: &str = \"${jwt_sample}\";" "JWT Token"
    expect_caught "拦截 windows/tests JWT" "windows/tests/leak.test.ts" "const t = '${jwt_sample}';" "JWT Token"
    expect_caught "拦截 raycast/src JWT" "raycast/src/leak.ts" "const t = '${jwt_sample}';" "JWT Token"

    expect_caught "拦截 windows/src 10/8 私网地址" "windows/src/leak.ts" "const host = 'http://${ip_sample}:8123';" "个人局域网 IP"
    expect_caught "拦截 windows/src-tauri/src 10/8 私网地址" "windows/src-tauri/src/leak.rs" "const H: &str = \"${ip_sample}\";" "个人局域网 IP"
    expect_caught "拦截 windows/tests 10/8 私网地址" "windows/tests/leak.test.ts" "const h = '${ip_sample}';" "个人局域网 IP"
    expect_caught "拦截 raycast/src 10/8 私网地址" "raycast/src/leak.ts" "const h = '${ip_sample}';" "个人局域网 IP"
    expect_caught "拦截非豁免 Tests 10/8 私网地址" "Tests/OtherTests.swift" "let h = \"${ip_sample}\"" "个人局域网 IP"

    expect_caught "拦截 windows/src 调试端口" "windows/src/leak.ts" "const u = 'http://${port_sample}';" "localhost:3425"
    expect_caught "拦截 windows/src-tauri/src 调试端口" "windows/src-tauri/src/leak.rs" "const U: &str = \"http://${port_sample}\";" "localhost:3425"
    expect_caught "拦截 windows/tests 调试端口" "windows/tests/leak.test.ts" "const u = 'http://${port_sample}';" "localhost:3425"
    expect_caught "拦截 raycast/src 调试端口" "raycast/src/leak.ts" "const u = 'http://${port_sample}';" "localhost:3425"
    expect_caught "拦截非豁免 Tests 调试端口" "Tests/OtherTests.swift" "let u = \"http://${port_sample}\"" "localhost:3425"

    # 稀疏检出：缺一个扫描目录时，其余目录里的 JWT 仍须拦截，干净树仍须放行。
    reset_fixture "$fx"
    rm -rf "$fx/raycast"
    expect_pass "缺少 raycast/src 时干净基线仍放行"
    rm -rf "$fx/raycast"
    printf '%s\n' "const t = '${jwt_sample}';" >"$fx/windows/src/leak.ts"
    set +e
    (cd "$fx" && PATH="$run_path" "$bash_bin" "$harness") >"$out" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 1 ] && grep -qF -- "JWT Token" "$out"; then
        pass "${mode_label}: 缺少 raycast/src 时仍拦截 windows/src JWT"
    else
        fail "${mode_label}: 缺少 raycast/src 时仍拦截 windows/src JWT 应退出 1，实际退出 ${status}：$(cat "$out")"
    fi
}

run_suite "default-path" "$PATH"

no_rg_bin="$tmp/no-rg-bin"
mkdir -p "$no_rg_bin"
for cmd in grep cat printf echo; do
    src="$(command -v "$cmd" 2>/dev/null || true)"
    if [ -n "$src" ]; then
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$src" >"$no_rg_bin/$cmd"
        chmod +x "$no_rg_bin/$cmd"
    fi
done
run_suite "grep-fallback" "$no_rg_bin"

if [ "$failures" -ne 0 ]; then
    echo "❌ 密钥与私网扫描自测失败 ${failures} 项" >&2
    exit 1
fi
echo "✅ 密钥与私网扫描自测通过"
