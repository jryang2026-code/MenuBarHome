#!/usr/bin/env bash
# 下一发布版本（ADR-0022）。
#
# 机器版本：上海时区当天的 YY.M.DDNN。
# YY = 年 − 2000，M = 月（不补零），DDNN = 日×100 + 当天序号（从 1 到 99）。
# 同一天已有 v* 标签时取最大序号 + 1。结果必须大于 1.3.0，也必须大于已有发布标签。
#
# 用法：
#   scripts/next_version.sh                 # 打印 26.11.1701
#   scripts/next_version.sh --label         # 打印 2026.11.17（v1）
#   scripts/next_version.sh --date 2026-11-17 --repo /path/to/repo
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX

fail() {
    echo "❌ $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
用法：scripts/next_version.sh [--label] [--date YYYY-MM-DD] [--repo <git 仓库>]

默认按 Asia/Shanghai 的今天、当前仓库的 v* 标签，打印下一次发布的机器版本。
--label 改为打印给人看的标签，例如 2026.11.17（v1）。
EOF
    exit 2
}

print_label=0
date_override=""
repo=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            print_label=1
            shift
            ;;
        --date)
            [ "$#" -ge 2 ] || usage
            date_override="$2"
            shift 2
            ;;
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "❌ 未知参数：$1" >&2
            usage
            ;;
    esac
done

if [ -z "$repo" ]; then
    repo="$(cd "$(dirname "$0")/.." && pwd)"
fi
command -v python3 >/dev/null 2>&1 || fail "需要 python3"
command -v git >/dev/null 2>&1 || fail "需要 git"

if [ -n "$date_override" ]; then
    stamp="$date_override"
else
    command -v date >/dev/null 2>&1 || fail "需要 date"
    stamp="$(TZ=Asia/Shanghai date +%Y-%m-%d)"
fi

python3 - "$stamp" "$repo" "$print_label" <<'PY'
import datetime
import subprocess
import sys

stamp, repo, print_label = sys.argv[1], sys.argv[2], sys.argv[3]
MINIMUM = (1, 3, 0)


def die(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)
    raise SystemExit(1)


try:
    day = datetime.date.fromisoformat(stamp)
except ValueError:
    die(f"日期不是合法的公历日：{stamp}")

year_offset = day.year - 2000
if year_offset < 0 or year_offset > 255:
    die(f"年份 {day.year} 编不出 MSI 允许的 major（0–255）")


def parse_release(tag: str):
    if not tag.startswith("v"):
        return None
    parts = tag[1:].split(".")
    if len(parts) != 3:
        return None
    numbers = []
    for part in parts:
        if not part.isdigit() or (len(part) > 1 and part.startswith("0")):
            return None
        numbers.append(int(part))
    return tuple(numbers)


try:
    raw = subprocess.check_output(
        ["git", "-C", repo, "tag", "-l", "v*"],
        stderr=subprocess.PIPE,
        text=True,
    )
except subprocess.CalledProcessError as error:
    detail = (error.stderr or "").strip() or str(error)
    die(f"无法读取标签：{detail}")

parsed = []
for line in raw.splitlines():
    tag = line.strip()
    version = parse_release(tag)
    if version is not None:
        parsed.append((version, tag))

floor = day.day * 100
sequences = [
    version[2] - floor
    for version, _tag in parsed
    if version[0] == year_offset and version[1] == day.month and floor < version[2] <= floor + 99
]
sequence = max(sequences, default=0) + 1
if sequence > 99:
    die("当天序号已用尽（最大 99）")

candidate = (year_offset, day.month, floor + sequence)
machine = f"{candidate[0]}.{candidate[1]}.{candidate[2]}"
if candidate <= MINIMUM:
    die(f"{machine} 没有大于已发布的 1.3.0")

blockers = [(version, tag) for version, tag in parsed if version >= candidate]
if blockers:
    die(f"{machine} 不大于已有标签 {max(blockers)[1]}")

if print_label == "1":
    print(f"{day.year}.{day.month:02d}.{day.day:02d}（v{sequence}）")
else:
    print(machine)
PY
