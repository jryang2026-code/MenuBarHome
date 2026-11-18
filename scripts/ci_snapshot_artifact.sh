#!/usr/bin/env bash
# Check a downloaded snapshot artifact, then copy it into the baseline directory.
#
#   ci_snapshot_artifact.sh validate DIR
#   ci_snapshot_artifact.sh install ARTIFACT_DIR DEST_DIR
#
# Every entry must be a regular PNG file directly in DIR. Symlinks, nested paths,
# traversal, non-PNGs, and unreasonable sizes are rejected. install copies only
# after that check, and removes destination PNGs the artifact no longer has.
#
# install additionally refuses to touch a destination whose path or directory
# already contains a symlink: cp would follow the link and let the target branch
# overwrite files outside the baseline directory (for example the trusted push
# helper this workflow runs right after). Reject up front, never write through.
set -euo pipefail

# Largest committed UI snapshot is about 240 KB. 8 MiB is still one picture, not a dump.
MIN_BYTES=64
MAX_BYTES=8388608
PNG_SIG="89504e470d0a1a0a"

validate_dir() {
    local dir="$1"
    local entry rel base size magic count
    if [ ! -d "$dir" ]; then
        echo "❌ 快照产物目录不存在：$dir" >&2
        return 1
    fi
    count=0
    while IFS= read -r -d '' entry; do
        rel="${entry#"$dir"/}"
        base="$(basename "$rel")"
        if [ "$rel" != "$base" ] || [[ "$rel" == *"/"* ]]; then
            echo "❌ 快照产物不能有子目录：$rel" >&2
            return 1
        fi
        if [[ "$base" == *".."* ]] || [[ "$base" == /* ]]; then
            echo "❌ 快照产物路径不合法：$base" >&2
            return 1
        fi
        if [ -L "$entry" ]; then
            echo "❌ 快照产物不能是符号链接：$base" >&2
            return 1
        fi
        if [ -d "$entry" ]; then
            echo "❌ 快照产物不能有子目录：$base" >&2
            return 1
        fi
        if [ ! -f "$entry" ]; then
            echo "❌ 快照产物必须是普通文件：$base" >&2
            return 1
        fi
        if [[ ! "$base" =~ ^[A-Za-z0-9._-]+\.png$ ]]; then
            echo "❌ 快照产物必须是该目录下的 .png：$base" >&2
            return 1
        fi
        size="$(wc -c <"$entry" | tr -d '[:space:]')"
        if [ "$size" -lt "$MIN_BYTES" ] || [ "$size" -gt "$MAX_BYTES" ]; then
            echo "❌ 快照产物大小不合理（${size} 字节）：$base" >&2
            return 1
        fi
        sig="$(od -An -tx1 -N8 "$entry" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
        if [ "$sig" != "$PNG_SIG" ]; then
            echo "❌ 快照产物不是 PNG：$base" >&2
            return 1
        fi
        count=$((count + 1))
    done < <(find "$dir" -mindepth 1 -print0)
    if [ "$count" -eq 0 ]; then
        echo "❌ 快照产物是空的" >&2
        return 1
    fi
    echo "已检查 ${count} 张 PNG"
}

reject_destination_symlinks() {
    local dest="$1"
    local cur next rel part entry
    # Check each ancestor of the destination path (including itself), and then
    # the entries inside it. $dest points into a checkout of the target branch,
    # so any of these can be a symlink planted by that branch.
    if [[ "$dest" == /* ]]; then
        cur="/"
    else
        cur="."
    fi
    rel="${dest#/}"
    rel="${rel%/}"
    while IFS= read -r part; do
        [ -n "$part" ] || continue
        if [ "$cur" = "/" ]; then
            next="/$part"
        elif [ "$cur" = "." ]; then
            next="$part"
        else
            next="$cur/$part"
        fi
        if [ -L "$next" ]; then
            echo "❌ 目标路径上有符号链接，拒绝安装：$next" >&2
            return 1
        fi
        cur="$next"
    done < <(printf '%s\n' "$rel" | tr '/' '\n')
    if [ -d "$dest" ]; then
        while IFS= read -r -d '' entry; do
            if [ -L "$entry" ]; then
                echo "❌ 目标目录里已有符号链接，拒绝安装：$(basename "$entry")" >&2
                return 1
            fi
        done < <(find "$dest" -mindepth 1 -maxdepth 1 -print0)
    fi
}

install_dir() {
    local artifact="$1"
    local dest="$2"
    local name src
    validate_dir "$artifact"
    reject_destination_symlinks "$dest"
    mkdir -p "$dest"
    if [ -d "$dest" ]; then
        while IFS= read -r -d '' src; do
            name="$(basename "$src")"
            if [ ! -f "$artifact/$name" ]; then
                rm -f -- "$src"
            fi
        done < <(find "$dest" -mindepth 1 -maxdepth 1 -name '*.png' -print0)
    fi
    while IFS= read -r -d '' src; do
        name="$(basename "$src")"
        cp -- "$src" "$dest/$name"
    done < <(find "$artifact" -mindepth 1 -maxdepth 1 -type f -name '*.png' -print0)
}

case "${1:-}" in
    validate)
        validate_dir "${2:?}"
        ;;
    install)
        install_dir "${2:?}" "${3:?}"
        ;;
    -h|--help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        ;;
    *)
        echo "❌ 用法：ci_snapshot_artifact.sh validate DIR | install ARTIFACT_DIR DEST_DIR" >&2
        exit 2
        ;;
esac
