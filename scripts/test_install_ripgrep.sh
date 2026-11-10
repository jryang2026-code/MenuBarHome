#!/usr/bin/env bash
# install_ripgrep.sh 的回退自测。不下载 GitHub Release，也不调用真实的 apt 或 brew。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

bash_bin="$(command -v bash)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rg-install-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
tools="$tmp/tools"
home="$tmp/home"
err="$tmp/err"
mkdir -p "$bin" "$tools" "$home"
link_tool() {
    local cmd="$1" src
    src="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -z "$src" ]]; then
        return 1
    fi
    ln -s "$src" "$tools/$cmd"
}
for cmd in mkdir mktemp tar gzip chmod cp rm id head cat; do
    link_tool "$cmd" || {
        echo "FAIL 缺少 ${cmd}" >&2
        exit 1
    }
done
if ! link_tool sha256sum && ! link_tool shasum; then
    echo "FAIL 需要 sha256sum 或 shasum" >&2
    exit 1
fi

cat >"$bin/uname" <<'EOF'
#!/bin/bash
case "$1" in
    -s) printf '%s\n' "${RG_TEST_KERNEL:?}" ;;
    -m) printf '%s\n' "${RG_TEST_MACHINE:?}" ;;
    *) echo "unexpected uname $*" >&2; exit 9 ;;
esac
EOF
cat >"$bin/curl" <<'EOF'
#!/bin/bash
out=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out="$arg"
    fi
    prev="$arg"
done
printf 'curl\n' >> "${RG_TEST_LOG:?}"
case "${RG_TEST_CURL:?}" in
    fail) exit 1 ;;
    bad)
        printf 'not-a-tarball' >"$out"
        exit 0
        ;;
    ok)
        cp "${RG_TEST_ARCHIVE:?}" "$out"
        exit 0
        ;;
    *) echo "bad RG_TEST_CURL" >&2; exit 9 ;;
esac
EOF
cat >"$bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
cat >"$bin/apt-get" <<'EOF'
#!/bin/bash
printf 'apt-get %s\n' "$*" >> "${RG_TEST_LOG:?}"
if [[ "$1" == "update" ]]; then
    exit 0
fi
if [[ "${RG_TEST_APT:?}" == "fail" ]]; then
    exit 1
fi
if [[ "$RG_TEST_APT" == "retry" ]]; then
    marker="${RG_TEST_LOG}.installs"
    count=0
    if [[ -f "$marker" ]]; then
        count="$(cat "$marker")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$marker"
    if [[ "$count" -eq 1 ]]; then
        exit 1
    fi
fi
printf '%s\n' '#!/bin/sh' 'echo system-rg' > "${RG_TEST_BIN:?}/rg"
chmod +x "${RG_TEST_BIN}/rg"
exit 0
EOF
cat >"$bin/brew" <<'EOF'
#!/bin/bash
printf 'brew %s\n' "$*" >> "${RG_TEST_LOG:?}"
printf '%s\n' '#!/bin/sh' 'echo system-rg' > "${RG_TEST_BIN:?}/rg"
chmod +x "${RG_TEST_BIN}/rg"
exit 0
EOF
chmod +x "$bin/uname" "$bin/curl" "$bin/sudo" "$bin/apt-get" "$bin/brew"

stage="$tmp/stage/ripgrep-14.1.1-x86_64-unknown-linux-musl"
mkdir -p "$stage"
printf '%s\n' '#!/bin/sh' 'echo pinned-rg' >"$stage/rg"
chmod +x "$stage/rg"
tar -czf "$tmp/rg.tgz" -C "$tmp/stage" ripgrep-14.1.1-x86_64-unknown-linux-musl

export RG_TEST_LOG="$tmp/calls.log"
export RG_TEST_BIN="$bin"
export RG_TEST_ARCHIVE="$tmp/rg.tgz"
export HOME="$home"
export TMPDIR="$tmp"
unset GITHUB_PATH

run_install() {
    : >"$RG_TEST_LOG"
    rm -f "$bin/rg" "$home/.local/bin/rg" "$bin/sha256sum" "${RG_TEST_LOG}.installs"
    set +e
    stdout="$(
        PATH="$bin:$tools" \
        RG_TEST_KERNEL="$1" \
        RG_TEST_MACHINE="$2" \
        RG_TEST_CURL="$3" \
        RG_TEST_APT="$4" \
        "$bash_bin" "$root/scripts/install_ripgrep.sh" 2>"$err"
    )"
    status=$?
    set -e
}

assert_case() {
    local name="$1"
    if [[ "$status" == "$2" ]]; then
        pass "$name 退出 $2"
    else
        fail "$name 应退出 $2，实际 $status"
        printf 'stdout:\n%s\nstderr:\n%s\nlog:\n%s\n' "$stdout" "$(cat "$err")" "$(cat "$RG_TEST_LOG")" >&2
    fi
}

printf '%s\n' '#!/bin/sh' 'echo have-rg' >"$bin/rg"
chmod +x "$bin/rg"
: >"$RG_TEST_LOG"
set +e
stdout="$(PATH="$bin:$tools" RG_TEST_KERNEL=Linux RG_TEST_MACHINE=x86_64 RG_TEST_CURL=fail RG_TEST_APT=ok "$bash_bin" "$root/scripts/install_ripgrep.sh" 2>"$err")"
status=$?
set -e
assert_case "已有 rg" 0
if [[ ! -s "$RG_TEST_LOG" ]]; then
    pass "已有 rg 时不下载"
else
    fail "已有 rg 时仍调用了网络工具：$(cat "$RG_TEST_LOG")"
fi
rm -f "$bin/rg"

run_install Linux x86_64 bad ok
assert_case "校验和不符" 1
if grep -q 'SHA-256' "$err" && ! grep -q 'apt-get' "$RG_TEST_LOG"; then
    pass "校验和不符时终止，不改用系统包"
else
    fail "校验和失败应终止且不调用 apt-get"
    printf 'stderr:\n%s\nlog:\n%s\n' "$(cat "$err")" "$(cat "$RG_TEST_LOG")" >&2
fi

run_install Linux x86_64 fail ok
assert_case "下载失败后 apt 成功" 0
if grep -q 'apt-get install -y ripgrep' "$RG_TEST_LOG" && printf '%s\n' "$stdout" | grep -q 'system-rg' && printf '%s\n' "$stdout" | grep -q '系统包管理器'; then
    pass "下载失败时改用系统包并报告路径"
else
    fail "apt 回退没有装上 rg"
    printf 'stdout:\n%s\nlog:\n%s\n' "$stdout" "$(cat "$RG_TEST_LOG")" >&2
fi

run_install Linux x86_64 fail retry
assert_case "apt 第一次失败后重试成功" 0
installs="$(grep -c 'apt-get install -y ripgrep' "$RG_TEST_LOG" || true)"
updates="$(grep -c 'apt-get update' "$RG_TEST_LOG" || true)"
if [[ "$installs" == 2 && "$updates" == 1 ]]; then
    pass "apt 安装失败后 update 再装一次"
else
    fail "apt 重试次数不对：install=$installs update=$updates"
fi

run_install Linux x86_64 fail fail
assert_case "下载和 apt 都失败" 1
if grep -q '均失败' "$err"; then
    pass "两种方式都失败时说明原因"
else
    fail "失败文案不符：$(cat "$err")"
fi

run_install Haiku x86_64 fail ok
assert_case "没有预编译包的平台" 1
if grep -q 'Haiku-x86_64' "$err" && ! grep -q 'curl' "$RG_TEST_LOG"; then
    pass "不支持的平台在下载前结束"
else
    fail "不支持的平台仍去下载或文案不对"
fi

run_install Darwin arm64 fail ok
assert_case "macOS 下载失败后 brew 成功" 0
if grep -q 'brew install ripgrep' "$RG_TEST_LOG" && ! grep -q 'apt-get' "$RG_TEST_LOG"; then
    pass "Darwin 回退走 brew"
else
    fail "Darwin 回退没有只调用 brew：$(cat "$RG_TEST_LOG")"
fi

printf '%s\n' '#!/bin/bash' 'cat >/dev/null' 'exit 0' >"$bin/sha256sum"
chmod +x "$bin/sha256sum"
: >"$RG_TEST_LOG"
rm -f "$bin/rg"
rm -rf "$home/.local"
set +e
stdout="$(PATH="$bin:$tools" RG_TEST_KERNEL=Linux RG_TEST_MACHINE=x86_64 RG_TEST_CURL=ok RG_TEST_APT=ok "$bash_bin" "$root/scripts/install_ripgrep.sh" 2>"$err")"
status=$?
set -e
assert_case "预编译包校验通过" 0
if printf '%s\n' "$stdout" | grep -q "ripgrep 14.1.1 -> $home/.local/bin/rg" \
    && [[ "$(cat "$home/.local/bin/rg")" == *"pinned-rg"* ]] \
    && ! grep -q 'apt-get' "$RG_TEST_LOG"; then
    pass "预编译安装不走系统包"
else
    fail "预编译安装结果不对"
    printf 'stdout:\n%s\nfile:\n%s\nlog:\n%s\n' "$stdout" "$(cat "$home/.local/bin/rg" 2>/dev/null || true)" "$(cat "$RG_TEST_LOG")" >&2
fi

if command -v shasum >/dev/null 2>&1; then
sha_tools="$tmp/sha-tools"
mkdir -p "$sha_tools"
for cmd in mkdir mktemp tar gzip chmod cp rm id head cat; do
    ln -s "$tools/$cmd" "$sha_tools/$cmd"
done
ln -s "$(command -v shasum)" "$sha_tools/shasum"
rm -f "$bin/sha256sum" "$bin/shasum" "$bin/rg"
rm -rf "$home/.local"
: >"$RG_TEST_LOG"
set +e
stdout="$(PATH="$bin:$sha_tools" RG_TEST_KERNEL=Linux RG_TEST_MACHINE=x86_64 RG_TEST_CURL=bad RG_TEST_APT=ok "$bash_bin" "$root/scripts/install_ripgrep.sh" 2>"$err")"
status=$?
set -e
assert_case "没有 sha256sum 时坏包被 shasum 拒绝" 1
if grep -q 'SHA-256' "$err" && ! grep -q 'apt-get' "$RG_TEST_LOG"; then
    pass "shasum 校验失败时终止，不改用系统包"
else
    fail "shasum 校验失败仍继续安装"
    printf 'stderr:\n%s\nlog:\n%s\n' "$(cat "$err")" "$(cat "$RG_TEST_LOG")" >&2
fi

printf '%s\n' '#!/bin/bash' 'printf '\''shasum\n'\'' >> "${RG_TEST_LOG:?}"' 'cat >/dev/null' 'exit 0' >"$bin/shasum"
chmod +x "$bin/shasum"
rm -f "$bin/rg"
rm -rf "$home/.local"
: >"$RG_TEST_LOG"
set +e
stdout="$(PATH="$bin:$sha_tools" RG_TEST_KERNEL=Linux RG_TEST_MACHINE=x86_64 RG_TEST_CURL=ok RG_TEST_APT=ok "$bash_bin" "$root/scripts/install_ripgrep.sh" 2>"$err")"
status=$?
set -e
assert_case "没有 sha256sum 时 shasum 放行预编译包" 0
if grep -qx 'shasum' "$RG_TEST_LOG" && ! grep -q 'apt-get' "$RG_TEST_LOG" && printf '%s\n' "$stdout" | grep -q 'ripgrep 14.1.1'; then
    pass "没有 sha256sum 时改走 shasum"
else
    fail "没有调用 shasum，或改用了系统包"
    printf 'stdout:\n%s\nlog:\n%s\n' "$stdout" "$(cat "$RG_TEST_LOG")" >&2
fi
rm -f "$bin/shasum"

# Mac pre-commit has shasum and no sha256sum. The harness must finish on that PATH.
if [[ "${RG_TEST_SHASUM_ONLY:-0}" != 1 ]]; then
    shim="$(mktemp -d)"
    for cmd in bash dirname mkdir mktemp tar gzip chmod cp rm id head cat python3 ln grep sed; do
        ln -s "$(command -v "$cmd")" "$shim/$cmd"
    done
    ln -s "$(command -v shasum)" "$shim/shasum"
    set +e
    shim_out="$(RG_TEST_SHASUM_ONLY=1 PATH="$shim" "$bash_bin" "$root/scripts/test_install_ripgrep.sh" 2>&1)"
    shim_status=$?
    set -e
    if [[ "$shim_status" == 0 ]]; then
        pass "PATH 只有 shasum、没有 sha256sum 时自测通过"
    else
        fail "PATH 只有 shasum、没有 sha256sum 时自测失败，退出 ${shim_status}"
        printf '%s\n' "$shim_out" | tail -n 40 >&2
    fi
    rm -rf "$shim"
fi
else
    pass "本机没有 shasum，校验走 sha256sum"
fi

if [[ "$failures" -eq 0 ]]; then
    exit 0
fi
exit 1
