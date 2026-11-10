#!/usr/bin/env bash
# Print a usable go binary, or a one-line skip reason on stderr and exit 2.
# A directory, a non-file, or a stub whose `version` fails is not usable.
set -euo pipefail

if command -v go >/dev/null 2>&1; then
    candidate="$(command -v go)"
else
    candidate="${GO2RTC_PTZ_GO_CACHE:-$HOME/.cache/menubarmijia/go1.26.10}/go/bin/go"
fi

if [ ! -e "$candidate" ]; then
    echo "未找到 go" >&2
    exit 2
fi
if [ -d "$candidate" ] || [ ! -f "$candidate" ]; then
    echo "go 不是普通可执行文件" >&2
    exit 2
fi
if [ ! -x "$candidate" ]; then
    echo "go 不可执行" >&2
    exit 2
fi
if ! "$candidate" version >/dev/null 2>&1; then
    echo "go version 失败" >&2
    exit 2
fi
printf '%s\n' "$candidate"
