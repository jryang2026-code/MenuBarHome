#!/usr/bin/env bash
: "${ROOT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

cleanup_shared_windows_deps() {
    if [ ! -L "$ROOT_DIR/windows/node_modules" ] && [ -f "$ROOT_DIR/windows/node_modules/.mmb-shared-link" ]; then
        rm -rf "$ROOT_DIR/windows/node_modules"
    fi
}

find_shared_windows_node_modules() {
    [ "${MMB_DISABLE_SHARED_NODE_MODULES:-0}" = "1" ] && return 1
    [ -f "$ROOT_DIR/windows/package-lock.json" ] || return 1
    local line wt
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt="${line#worktree }"
                [ "$wt" = "$ROOT_DIR" ] && continue
                if [ -d "$wt/windows/node_modules" ] \
                    && [ ! -L "$wt/windows/node_modules" ] \
                    && [ ! -e "$wt/windows/node_modules/.mmb-shared-link" ] \
                    && [ -x "$wt/windows/node_modules/.bin/tsc" ] \
                    && [ -x "$wt/windows/node_modules/.bin/vite" ] \
                    && [ -f "$wt/windows/package-lock.json" ] \
                    && cmp -s "$ROOT_DIR/windows/package-lock.json" "$wt/windows/package-lock.json"; then
                    printf '%s\n' "$wt/windows/node_modules"
                    return 0
                fi
                ;;
        esac
    done < <(git -C "$ROOT_DIR" worktree list --porcelain 2>/dev/null || true)
    return 1
}

with_shared_windows_deps() {
    local shared_nm="$1"
    shift
    cleanup_shared_windows_deps
    if [ -e "$ROOT_DIR/windows/node_modules" ]; then
        "$@"
        return $?
    fi
    mkdir -p "$ROOT_DIR/windows/node_modules"
    printf '%s\n' "$shared_nm" > "$ROOT_DIR/windows/node_modules/.mmb-shared-link"
    trap 'cleanup_shared_windows_deps' EXIT INT TERM HUP
    if [ -d "$shared_nm/.bin" ]; then
        ln -s "$shared_nm/.bin" "$ROOT_DIR/windows/node_modules/.bin"
    fi
    local entry base
    for entry in "$shared_nm"/*; do
        [ -e "$entry" ] || continue
        base="$(basename "$entry")"
        case "$base" in
            .vite*|.cache|.mmb-shared-link) continue ;;
        esac
        ln -s "$entry" "$ROOT_DIR/windows/node_modules/$base"
    done
    local status=0
    "$@" || status=$?
    cleanup_shared_windows_deps
    trap - EXIT INT TERM HUP
    return "$status"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    if [ "${1:-}" != "run" ] || [ "$#" -lt 2 ]; then
        echo "usage: bash scripts/shared_windows_deps.sh run <command> [args...]" >&2
        exit 2
    fi
    shift
    cleanup_shared_windows_deps
    if [ -x "$ROOT_DIR/windows/node_modules/.bin/tsc" ] && [ -x "$ROOT_DIR/windows/node_modules/.bin/vite" ]; then
        exec "$@"
    fi
    shared_nm="$(find_shared_windows_node_modules || true)"
    if [ -z "$shared_nm" ]; then
        echo "❌ 未找到可用的 windows/node_modules（本地与同锁文件工作树均缺失）" >&2
        exit 2
    fi
    with_shared_windows_deps "$shared_nm" "$@"
fi
