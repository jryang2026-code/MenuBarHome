#!/usr/bin/env bash
# Run a command on a base revision with current files copied over it.
# Exit 0 when that command fails. Exit 1 when it passes.
# Usage: scripts/red-check.sh --base <rev> --overlay <path> [--overlay <path> ...] -- <command>
#        scripts/red-check.sh --self-test
# Bash 3.2 compatible.
set -eu

# A commit hook exports GIT_INDEX_FILE and GIT_DIR. Those point at the parent
# repository and make the temporary worktree below fail to open its own index.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

usage() {
    printf '%s\n' "usage: scripts/red-check.sh --base <rev> --overlay <path> [--overlay <path> ...] -- <command>" >&2
    printf '%s\n' "       scripts/red-check.sh --self-test" >&2
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

self_test() {
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git init -q "$tmp/repo"
    git -C "$tmp/repo" config user.email "red-check@example.com"
    git -C "$tmp/repo" config user.name "red-check"
    printf '%s\n' old > "$tmp/repo/app.txt"
    git -C "$tmp/repo" add app.txt
    git -C "$tmp/repo" commit -q -m base
    base="$(git -C "$tmp/repo" rev-parse HEAD)"
    cat > "$tmp/repo/fails-on-old.sh" <<'EOF'
#!/bin/sh
grep -q new app.txt
EOF
    chmod +x "$tmp/repo/fails-on-old.sh"
    cat > "$tmp/repo/always-passes.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$tmp/repo/always-passes.sh"

    set +e
    (cd "$tmp/repo" && "$script" --base "$base" --overlay fails-on-old.sh -- ./fails-on-old.sh >"$tmp/red.out" 2>"$tmp/red.err")
    red_status=$?
    set -e
    if [ "$red_status" -ne 0 ]; then
        printf '%s\n' "self-test: a command that fails on the base should pass the check" >&2
        cat "$tmp/red.err" >&2
        return 1
    fi
    if ! grep -q "command failed on" "$tmp/red.out"; then
        printf '%s\n' "self-test: missing failure report" >&2
        return 1
    fi

    set +e
    (cd "$tmp/repo" && "$script" --base "$base" --overlay always-passes.sh -- ./always-passes.sh >"$tmp/green.out" 2>"$tmp/green.err")
    green_status=$?
    set -e
    if [ "$green_status" -eq 0 ]; then
        printf '%s\n' "self-test: a command that passes on the base should fail the check" >&2
        return 1
    fi
    if ! grep -q "expected a failure" "$tmp/green.err"; then
        printf '%s\n' "self-test: missing expected-failure report" >&2
        cat "$tmp/green.err" >&2
        return 1
    fi
    printf '%s\n' "red-check.sh self-test passed"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

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
