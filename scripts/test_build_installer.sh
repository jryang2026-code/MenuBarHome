#!/usr/bin/env bash
# build-installer.ps1 的自测。假的 npx 代替 tauri，并按 GitHub Actions 的 pwsh 包装方式再跑一遍。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
script="$root/windows/scripts/build-installer.ps1"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "FAIL 没有 pwsh，无法验证安装包重试" >&2
    exit 1
fi

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-installer-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/npx" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BUILD_TEST_LOG:?}"
mode="${BUILD_TEST_MODE:?}"
count="$(grep -c . "$BUILD_TEST_LOG")"
case "$mode" in
    ok) exit 0 ;;
    compile)
        echo "error: cannot find type Foo" >&2
        exit 17
        ;;
    http200)
        echo "failed to bundle project: http status: 200" >&2
        exit 23
        ;;
    once)
        if [[ "$count" -eq 1 ]]; then
            echo "failed to bundle project: http status: 504" >&2
            exit 17
        fi
        echo built
        exit 0
        ;;
    twice)
        echo "failed to bundle project: http status: 503" >&2
        exit 19
        ;;
    *) echo "bad mode $mode" >&2; exit 9 ;;
esac
EOF
chmod +x "$bin/npx"
if command -v cygpath >/dev/null 2>&1; then
    bash_win="$(cygpath -m "$(command -v bash)")"
    npx_win="$(cygpath -m "$bin/npx")"
    cat >"$bin/npx.cmd" <<EOF
@echo off
"$bash_win" "$npx_win" %*
EOF
fi

host_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

pwsh_bin="$(command -v pwsh)"
export PATH="$bin:$PATH"
export RUNNER_TEMP="$(host_path "$tmp/runner")"
export BUILD_TEST_LOG="$(host_path "$tmp/calls.log")"
mkdir -p "$tmp/runner"

invoke_installer() {
    : >"$tmp/calls.log"
    rm -f "$tmp/runner/tauri-build.log"
    set +e
    invoke_out="$("$@")"
    invoke_status=$?
    set -e
    invoke_calls="$(grep -c . "$tmp/calls.log" || true)"
}

run_mode() {
    local host_script host_step
    host_script="$(host_path "$script")"
    host_step="$(host_path "$tmp/step.ps1")"
    invoke_installer "$pwsh_bin" -NoProfile -ExecutionPolicy Bypass -File "$host_script"
    file_out="$invoke_out"
    file_status="$invoke_status"
    file_calls="$invoke_calls"
    cat >"$tmp/step.ps1" <<EOF
\$ErrorActionPreference = 'stop'
& '$host_script'
if ((Test-Path -LiteralPath variable:\\LASTEXITCODE)) { exit \$LASTEXITCODE }
EOF
    invoke_installer "$pwsh_bin" -NoProfile -ExecutionPolicy Bypass -Command ". '$host_step'"
    wrap_out="$invoke_out"
    wrap_status="$invoke_status"
    wrap_calls="$invoke_calls"
}

expect_mode() {
    local mode="$1" file_code="$2" wrap_code="$3" call_count="$4" warning="$5"
    BUILD_TEST_MODE="$mode" run_mode "$mode"
    if [[ "$file_status" == "$file_code" && "$wrap_status" == "$wrap_code" && "$file_calls" == "$call_count" && "$wrap_calls" == "$call_count" ]]; then
        pass "$mode 退出码与调用次数"
    else
        fail "$mode 期望 file=$file_code wrap=$wrap_code calls=$call_count，实际 file=$file_status/$file_calls wrap=$wrap_status/$wrap_calls"
        printf '%s\n' "$file_out" >&2
    fi
    if [[ "$warning" == yes ]]; then
        if printf '%s\n' "$file_out" | grep -q '::warning::Tauri bundler download returned an HTTP 5xx; retrying once'; then
            pass "$mode 打印一次重试警告"
        else
            fail "$mode 没有重试警告"
        fi
    else
        if printf '%s\n' "$file_out" | grep -q '::warning::'; then
            fail "$mode 不该重试"
        else
            pass "$mode 不重试"
        fi
    fi
}

# GitHub's pwsh wrapper dot-sources the step and turns any non-zero LASTEXITCODE into process exit 1.
expect_mode ok 0 0 1 no
expect_mode compile 17 1 1 no
expect_mode http200 23 1 1 no
expect_mode once 0 0 2 yes
expect_mode twice 19 1 2 yes

if [[ "$failures" -eq 0 ]]; then
    exit 0
fi
exit 1
