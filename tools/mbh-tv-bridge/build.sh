#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
GO_BIN="$(bash "$ROOT/../../scripts/go2rtc-ptz/go_ready.sh")"
out="$ROOT/dist"
cd "$ROOT"
rm -rf "$out"; mkdir -p "$out"
for target in "darwin arm64" "darwin amd64" "windows amd64"; do
  set -- $target; os=$1; arch=$2; ext=""; [ "$os" = windows ] && ext=.exe
  name="mbh-tv-bridge-${os}-${arch}${ext}"
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch "$GO_BIN" build -trimpath -ldflags='-s -w' -o "$out/$name" "$ROOT/cmd/mbh-tv-bridge"
  (cd "$out" && shasum -a 256 "$name" > "$name.sha256")
  size=$(wc -c < "$out/$name" | tr -d ' '); echo "$name $size bytes"
done
if [ "${1:-}" = --check ]; then rm -rf "$out"; fi
