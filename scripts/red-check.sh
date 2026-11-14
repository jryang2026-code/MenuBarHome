#!/usr/bin/env bash
# Run a command on a base revision with current files copied over it.
# Exit 0 when that command fails. Exit 1 when it passes.
# Usage: scripts/red-check.sh --base <rev> --overlay <path> [--overlay <path> ...] -- <command>
# Bash 3.2 compatible.
set -eu

# A commit hook exports GIT_INDEX_FILE and GIT_DIR. Those point at the parent
# repository and make the temporary worktree below fail to open its own index.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

usage() {
    printf '%s\n' "usage: scripts/red-check.sh --base <rev> --overlay <path> [--overlay <path> ...] -- <command>" >&2
}

red_check() {
    base="$1"
    overlay_text="$2"
    shift 2
    root="$(git rev-parse --show-toplevel)"
    work="$(mktemp -d)"
    list="$(mktemp)"
    cleanup() {
        git -C "$root" worktree remove --force "$work" >/dev/null 2>&1 || rm -rf "$work"
        rm -f "$list"
    }
    git -C "$root" worktree add --detach "$work" "$base" >/dev/null
    printf '%s\n' "$overlay_text" > "$list"
    while IFS= read -r path; do
        if [ -z "$path" ]; then
            continue
        fi
        if [ ! -f "$root/$path" ]; then
            printf 'overlay is not a file: %s\n' "$path" >&2
            cleanup
            return 1
        fi
        mkdir -p "$work/$(dirname "$path")"
        cp "$root/$path" "$work/$path"
    done < "$list"
    set +e
    (cd "$work" && "$@")
    status=$?
    set -e
    cleanup
    if [ "$status" -eq 0 ]; then
        printf 'command passed on %s; expected a failure\n' "$base" >&2
        return 1
    fi
    printf 'command failed on %s (exit %s)\n' "$base" "$status"
    return 0
}

base=""
overlays=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base)
            shift
            base="${1:-}"
            if [ -z "$base" ]; then
                usage
                exit 2
            fi
            shift
            ;;
        --overlay)
            shift
            if [ -z "${1:-}" ]; then
                usage
                exit 2
            fi
            overlays="${overlays}$1
"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ -z "$base" ] || [ -z "$overlays" ] || [ "$#" -lt 1 ]; then
    usage
    exit 2
fi

red_check "$base" "$overlays" "$@"
