#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage:
  gate_report.sh summary Swift=0 Windows=skip Raycast=0
  gate_report.sh hook-success LOG
  gate_report.sh failing-tests LOG
  gate_report.sh record-verdict STATUS LOG
  gate_report.sh list-snapshot-changes DIR
  gate_report.sh png-size-manifest DIR
  gate_report.sh png-size-diff BEFORE_MANIFEST SNAPSHOT_DIR CHANGED_LIST
  gate_report.sh unstaged-snapshots
EOF
}

join_by() {
    local separator="$1"
    shift
    local out="" part
    for part in "$@"; do
        if [ -z "$out" ]; then
            out="$part"
        else
            out="${out}${separator}${part}"
        fi
    done
    printf '%s' "$out"
}

cmd_summary() {
    local failed=0
    local -a skips=()
    local -a fail_parts=()
    local arg key val line
    for arg in "$@"; do
        key="${arg%%=*}"
        val="${arg#*=}"
        if [ "$key" = "$arg" ] || [ -z "$key" ]; then
            echo "❌ summary 参数必须是 名称=0、名称=skip 或 名称=退出码：${arg}" >&2
            exit 2
        fi
        if [ "$val" = "skip" ]; then
            skips+=("$key")
        elif [ "$val" != "0" ]; then
            failed=1
            fail_parts+=("${key}=${val}")
        fi
    done
    if [ "$failed" -eq 1 ]; then
        line="❌ 门禁未通过：$(join_by ' ' "${fail_parts[@]}")"
        if [ "${#skips[@]}" -gt 0 ]; then
            line="${line}；跳过 $(join_by '、' "${skips[@]}")"
        fi
        printf '%s\n' "$line"
        exit 1
    fi
    if [ "${#skips[@]}" -gt 0 ]; then
        printf '⚠️ 部分通过：跳过 %s\n' "$(join_by '、' "${skips[@]}")"
        exit 0
    fi
    printf '%s\n' "✅ 所有门禁检查与单元测试全部通过！"
}

cmd_hook_success() {
    awk '
        /^(✅|⚠️)|Test run with|^部分通过/ {
            print
            keep_body = ($0 ~ /单文件行数告警/) ? 1 : 0
            next
        }
        keep_body && /^[[:space:]]+[0-9]+[[:space:]]+/ {
            print
            next
        }
        { keep_body = 0 }
    ' "$1"
}

cmd_failing_tests() {
    local log="$1" line found=0
    while IFS= read -r line; do
        found=1
        case "$line" in
            ❌*) printf '%s\n' "$line" ;;
            *) printf '❌ %s\n' "$line" ;;
        esac
    done < <(grep -E '✘|✖|recorded an issue|^not ok ' "$log" || true)
    if [ "$found" -eq 0 ]; then
        echo "❌ 未能从日志里提取失败用例名，请看完整日志"
    fi
}

cmd_record_verdict() {
    local status="$1" log="$2" summary
    summary="$(grep -E 'Test run with' "$log" | tail -n 1 || true)"
    # Record mode reports an issue for each baseline it rewrites, so a finished
    # suite can exit non-zero. A signal, or no Swift Testing summary, means it
    # did not finish.
    if [ "$status" -ge 128 ] || [ -z "$summary" ]; then
        echo "❌ 快照录制没有跑完。Swift 测试退出码：${status}"
        echo "完整日志：${log}"
        tail -n 20 "$log" || true
        exit 1
    fi
    echo "Swift 测试退出码：${status}"
    printf '%s\n' "$summary"
}

cmd_list_snapshot_changes() {
    local dir="$1"
    {
        git diff --name-only -- "$dir"
        git ls-files --others --exclude-standard -- "$dir"
    } | sed '/^$/d' | sort -u
}

cmd_png_size_manifest() {
    python3 - "$1" <<'PY'
import os
import struct
import sys

root = sys.argv[1]
rows = []
for dirpath, _, names in os.walk(root):
    for name in names:
        if not name.endswith(".png"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, "rb") as handle:
            header = handle.read(24)
        if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
            continue
        width, height = struct.unpack(">II", header[16:24])
        rel = os.path.relpath(path, root)
        rows.append(f"{rel}\t{width}\t{height}")
for row in sorted(rows):
    print(row)
PY
}

cmd_png_size_diff() {
    python3 - "$1" "$2" "$3" <<'PY'
import os
import struct
import sys

before_path, root, changed_path = sys.argv[1:]
before = {}
with open(before_path, encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 3:
            before[parts[0]] = (parts[1], parts[2])

def size_of(path):
    with open(path, "rb") as handle:
        header = handle.read(24)
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", header[16:24])
    return str(width), str(height)

lines = []
with open(changed_path, encoding="utf-8") as handle:
    for line in handle:
        rel = line.strip()
        if not rel:
            continue
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            continue
        now = size_of(path)
        if now is None:
            continue
        old = before.get(rel)
        if old is None:
            lines.append(f"{rel} 新图 {now[0]}x{now[1]}")
        elif old != now:
            lines.append(f"{rel} {old[0]}x{old[1]} -> {now[0]}x{now[1]}")
if lines:
    print("尺寸变化：")
    for line in lines:
        print(f"  {line}")
PY
}

cmd_unstaged_snapshots() {
    local lines
    lines="$(
        {
            git diff --name-only -- Tests/MenuBarMijiaAppTests/__Snapshots__
            git ls-files --others --exclude-standard -- Tests/MenuBarMijiaAppTests/__Snapshots__
        } | sed '/^$/d' | sort -u
    )"
    if [ -n "$lines" ]; then
        echo "⚠️  工作区有截图改动，但没有暂存。这次提交不会带上这些图："
        printf '%s\n' "$lines" | sed 's/^/⚠️  /'
    fi
}

case "${1:-}" in
    summary) shift; cmd_summary "$@" ;;
    hook-success) cmd_hook_success "${2:?}" ;;
    failing-tests) cmd_failing_tests "${2:?}" ;;
    record-verdict) cmd_record_verdict "${2:?}" "${3:?}" ;;
    list-snapshot-changes) cmd_list_snapshot_changes "${2:?}" ;;
    png-size-manifest) cmd_png_size_manifest "${2:?}" ;;
    png-size-diff) cmd_png_size_diff "${2:?}" "${3:?}" "${4:?}" ;;
    unstaged-snapshots) cmd_unstaged_snapshots ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
