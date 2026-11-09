#!/usr/bin/env bash
# Install a pinned ripgrep release binary when `rg` is not already on PATH.
# CI uses this instead of `brew install` / compiling from source.
#
# GitHub release downloads have answered 504 for long stretches, which failed CI with no code at
# fault. The pinned download is retried patiently, then the distro package is used as a fallback so
# an outage does not fail the step. A checksum mismatch is not an outage: it aborts instead of
# falling back, because an unverified binary is worse than no binary.
set -euo pipefail

if command -v rg >/dev/null 2>&1; then
    exit 0
fi

version="14.1.1"
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        asset="ripgrep-${version}-x86_64-unknown-linux-musl.tar.gz"
        sha="4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e"
        ;;
    Darwin-arm64)
        asset="ripgrep-${version}-aarch64-apple-darwin.tar.gz"
        sha="24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be"
        ;;
    *)
        echo "❌ 没有 $(uname -s)-$(uname -m) 的预编译 ripgrep ${version}" >&2
        exit 1
        ;;
esac

install_dir="${HOME}/.local/bin"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Returns 1 on a failed download so the caller can fall back. A checksum mismatch exits the script
# outright: the file came from the network but is not the pinned release.
install_pinned() {
    local url
    url="https://github.com/BurntSushi/ripgrep/releases/download/${version}/${asset}"
    # GitHub answers 502/503/504 on release assets; --retry-all-errors covers those plus resets.
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 15 --max-time 90 \
        "$url" -o "$tmp/rg.tar.gz" || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        echo "${sha}  $tmp/rg.tar.gz" | sha256sum -c - || {
            echo "❌ ripgrep ${version} 的 SHA-256 与固定值不符，终止安装" >&2
            exit 1
        }
    else
        echo "${sha}  $tmp/rg.tar.gz" | shasum -a 256 -c - || {
            echo "❌ ripgrep ${version} 的 SHA-256 与固定值不符，终止安装" >&2
            exit 1
        }
    fi
    tar -xzf "$tmp/rg.tar.gz" -C "$tmp" || return 1
    mkdir -p "$install_dir" || return 1
    cp "$tmp"/ripgrep-*/rg "$install_dir/rg" || return 1
    chmod +x "$install_dir/rg" || return 1
    if [ -n "${GITHUB_PATH:-}" ]; then
        echo "$install_dir" >> "$GITHUB_PATH"
    fi
    export PATH="${install_dir}:${PATH}"
    command -v rg >/dev/null 2>&1
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_from_package_manager() {
    case "$(uname -s)" in
        Linux)
            # The hosted image usually carries an index; only refresh it when the install says the
            # package cannot be found (stale index), which keeps the fallback quick.
            if ! as_root apt-get install -y ripgrep; then
                as_root apt-get update && as_root apt-get install -y ripgrep
            fi
            ;;
        Darwin)
            brew install ripgrep
            ;;
        *)
            return 1
            ;;
    esac
}

if install_pinned; then
    echo "✅ ripgrep ${version} -> $(command -v rg)"
    exit 0
fi

echo "⚠️ 预编译 ripgrep ${version} 下载失败（GitHub Releases 可能返回 5xx），改用系统包管理器" >&2
if install_from_package_manager && command -v rg >/dev/null 2>&1; then
    echo "✅ $(rg --version | head -n 1) -> $(command -v rg)（系统包管理器）"
    exit 0
fi

echo "❌ 无法安装 ripgrep：预编译下载与系统包管理器均失败" >&2
exit 1
