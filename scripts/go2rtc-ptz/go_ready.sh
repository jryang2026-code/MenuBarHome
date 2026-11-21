#!/usr/bin/env bash
set -euo pipefail

cache_go="${GO2RTC_PTZ_GO_CACHE:-$HOME/.cache/menubarmijia/go1.26.10}/go/bin/go"
candidates=()
if path_go="$(command -v go 2>/dev/null)"; then
    candidates+=("$path_go")
fi
if [ "${path_go:-}" != "$cache_go" ]; then
    candidates+=("$cache_go")
fi

check_candidate() {
    local candidate="$1"
    if [ ! -e "$candidate" ]; then
        last_reason="未找到 go"
        return 1
    fi
    if [ -d "$candidate" ] || [ ! -f "$candidate" ]; then
        last_reason="go 不是普通可执行文件"
        return 1
    fi
    if [ ! -x "$candidate" ]; then
        last_reason="go 不可执行"
        return 1
    fi
    local ver_out="" ver=""
    if ! ver_out="$("$candidate" version 2>/dev/null)"; then
        last_reason="go version 失败"
        return 1
    fi
    ver="$(printf '%s\n' "$ver_out" | awk '{print $3}')"
    case "$ver" in
        go1.2[6-9]*|go1.[3-9][0-9]*|go[2-9].*)
            return 0
            ;;
        *)
            last_reason="Go 版本过低（${ver:-未知}，需要 Go 1.26+）"
            return 1
            ;;
    esac
}

last_reason="未找到 go"
first_reason=""
for candidate in "${candidates[@]}"; do
    if check_candidate "$candidate"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
    if [ -z "$first_reason" ] && [ "$last_reason" != "未找到 go" ]; then
        first_reason="$last_reason"
    fi
done

echo "${first_reason:-$last_reason}" >&2
exit 2
