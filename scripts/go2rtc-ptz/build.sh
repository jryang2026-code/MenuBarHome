#!/usr/bin/env bash
# Build the pinned go2rtc PTZ binary from the upstream v1.9.15 tag plus one patch.
# Never publishes and never touches the user's daily go2rtc binary.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_COMMIT="7c05066c90ab6ad1fccb506d5f0408aa31ebe60f"
PATCH_FILE="$ROOT_DIR/scripts/go2rtc-ptz/patches/0001-xiaomi-ptz.patch"
OUT_DIR="$ROOT_DIR/scripts/go2rtc-ptz/out"
UPSTREAM="https://github.com/AlexxIT/go2rtc"

ensure_go_126() {
    local candidate ver os arch archive sha256 cache_root tmp_archive
    for candidate in "$(command -v go 2>/dev/null || true)" "${GO2RTC_PTZ_GO_CACHE:-$HOME/.cache/menubarmijia/go1.26.10}/go/bin/go"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            ver="$("$candidate" env GOVERSION 2>/dev/null || "$candidate" version 2>/dev/null | awk '{print $3}')"
            case "$ver" in
                go1.2[6-9]*|go1.[3-9][0-9]*|go[2-9].*)
                    export PATH="$(dirname "$candidate"):$PATH"
                    return 0
                    ;;
            esac
        fi
    done

    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)
            os="darwin"; arch="arm64"
            sha256="0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3"
            ;;
        Darwin-x86_64)
            os="darwin"; arch="amd64"
            sha256="e820ab780c273ae4a340b79d0f3c4313b74ee029aa3874792145d44b9f4f91da"
            ;;
        Linux-x86_64)
            os="linux"; arch="amd64"
            sha256="ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5"
            ;;
        Linux-aarch64|Linux-arm64)
            os="linux"; arch="arm64"
            sha256="3f4227ce7b206a513e794f1393adb473a07b46e94d18bd15d1c684bbb7319797"
            ;;
        *)
            echo "❌ 未找到 Go 1.26+，且当前平台 $(uname -s)-$(uname -m) 不支持自动下载固定版本 Go 工具链" >&2
            exit 1
            ;;
    esac

    archive="go1.26.10.${os}-${arch}.tar.gz"
    cache_root="${GO2RTC_PTZ_GO_CACHE:-$HOME/.cache/menubarmijia/go1.26.10}"
    echo "▶ 未检测到 Go 1.26+，正在下载固定版本 Go 工具链 ($archive)..."
    mkdir -p "$cache_root"
    tmp_archive="$(mktemp "${TMPDIR:-/tmp}/go1.26.10.XXXXXX")"
    if ! curl -fsSL --retry 3 --max-time 180 "https://go.dev/dl/$archive" -o "$tmp_archive"; then
        rm -f "$tmp_archive"
        echo "❌ 下载 Go 1.26.10 失败" >&2
        exit 1
    fi
    local actual_sha
    if command -v shasum >/dev/null 2>&1; then
        actual_sha="$(shasum -a 256 "$tmp_archive" | awk '{print $1}')"
    else
        actual_sha="$(sha256sum "$tmp_archive" | awk '{print $1}')"
    fi
    if [ "$actual_sha" != "$sha256" ]; then
        rm -f "$tmp_archive"
        echo "❌ Go 1.26.10 SHA-256 校验失败（期望 ${sha256}，实际 ${actual_sha}）" >&2
        exit 1
    fi
    rm -rf "$cache_root/go" "$cache_root/go.staging.$$"
    mkdir -p "$cache_root/go.staging.$$"
    tar -C "$cache_root/go.staging.$$" -xzf "$tmp_archive"
    rm -f "$tmp_archive"
    mv "$cache_root/go.staging.$$/go" "$cache_root/go"
    rmdir "$cache_root/go.staging.$$" 2>/dev/null || true
    export PATH="$cache_root/go/bin:$PATH"
}
ensure_go_126
if ! command -v lipo >/dev/null 2>&1; then
    echo "❌ 未找到 lipo（Xcode Command Line Tools）" >&2
    exit 1
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "▶ 克隆 go2rtc v1.9.15 ($BASE_COMMIT)"
git clone --quiet --filter=blob:none "$UPSTREAM" "$WORK/go2rtc"
git -C "$WORK/go2rtc" checkout --quiet "$BASE_COMMIT"
git -C "$WORK/go2rtc" apply --index "$PATCH_FILE"

mkdir -p "$OUT_DIR"
build() {
    local goarch="$1" output="$2"
    echo "▶ 构建 darwin/$goarch"
    (cd "$WORK/go2rtc" && CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" \
        go build -trimpath -ldflags "-s -w" -o "$output" .)
}
build arm64 "$OUT_DIR/go2rtc-darwin-arm64"
build amd64 "$OUT_DIR/go2rtc-darwin-amd64"
lipo -create "$OUT_DIR/go2rtc-darwin-arm64" "$OUT_DIR/go2rtc-darwin-amd64" \
    -output "$OUT_DIR/go2rtc-universal"
chmod 755 "$OUT_DIR/go2rtc-universal"

echo "▶ 构建 windows/amd64（不参与 macOS 打包，供后续验证）"
(cd "$WORK/go2rtc" && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
    go build -trimpath -ldflags "-s -w" -o "$OUT_DIR/go2rtc-windows-amd64.exe" .)

PATCH_SHA="$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"
printf 'patch_sha256=%s\nheader_version=v1\n' "$PATCH_SHA" > "$OUT_DIR/go2rtc-ptz.manifest"

echo "✅ 构建完成（未发布、未覆盖日用二进制）"
shasum -a 256 "$OUT_DIR"/go2rtc-* | sed "s|$OUT_DIR/||"
