#!/usr/bin/env bash
# Record the UI snapshot baselines on this Mac and list the PNGs that changed.
#
#   bash scripts/record_snapshots.sh [--dry-run]
#
# This Mac is the reference renderer. GitHub-hosted Macs render differently, so CI skips the
# snapshot comparison and scripts/check.sh checks these baselines. Review the changed PNGs
# before committing.
#   --dry-run  record into a scratch copy and list what would change, leaving the baselines alone
#
# The script prints the Swift Testing summary and the process exit code, and keeps the log.
# Record mode reports an issue for each baseline whose pixels changed, so a finished run can
# exit non-zero. The script itself fails only when that run does not finish.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(git rev-parse --show-toplevel)"
SNAPSHOT_REL="Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"
SNAPSHOT_DIR="$ROOT_DIR/$SNAPSHOT_REL"
DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    "") ;;
    *) echo "❌ 未知参数：$1（可用：--dry-run）" >&2; exit 2 ;;
esac

backup=""
cleanup() {
    if [ "$DRY_RUN" = "1" ] && [ -n "$backup" ] && [ -d "$backup" ]; then
        rm -rf "$SNAPSHOT_DIR"
        mkdir -p "$SNAPSHOT_DIR"
        cp -R "$backup/." "$SNAPSHOT_DIR/"
        rm -rf "$backup"
        backup=""
    fi
}
trap cleanup EXIT

if [ "$DRY_RUN" = "1" ]; then
    backup="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-baselines.XXXXXX")"
    cp -R "$SNAPSHOT_DIR/." "$backup/"
fi

cd "$ROOT_DIR"
LOG="$(mktemp "${TMPDIR:-/tmp}/mmb-snapshot-record.XXXXXX")"
echo "录制日志：${LOG}"
size_before="$(mktemp)"
if command -v python3 >/dev/null 2>&1; then
    bash "$ROOT_DIR/scripts/gate_report.sh" png-size-manifest "$SNAPSHOT_DIR" >"$size_before"
else
    : >"$size_before"
fi

set +e
SNAPSHOT_RECORD=1 swift test --filter SnapshotTests >"$LOG" 2>&1
swift_status=$?
set -e
if ! bash "$ROOT_DIR/scripts/gate_report.sh" record-verdict "$swift_status" "$LOG"; then
    exit 1
fi

changed="$(bash "$ROOT_DIR/scripts/gate_report.sh" list-snapshot-changes "$SNAPSHOT_REL")"
if [ -z "$changed" ]; then
    echo "✅ 基线无变化"
    exit 0
fi

printf '%s\n' "$changed" | sed 's#^#  #'
rel_file="$(mktemp)"
printf '%s\n' "$changed" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
        "$SNAPSHOT_REL"/*) printf '%s\n' "${path#"$SNAPSHOT_REL"/}" ;;
        *) printf '%s\n' "$path" ;;
    esac
done >"$rel_file"
if command -v python3 >/dev/null 2>&1; then
    bash "$ROOT_DIR/scripts/gate_report.sh" png-size-diff "$size_before" "$SNAPSHOT_DIR" "$rel_file"
else
    echo "⏭️  未报告尺寸：未找到 python3"
fi
rm -f "$rel_file" "$size_before"
count="$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
if [ "$DRY_RUN" = "1" ]; then
    echo "ℹ️ 共 ${count} 张会变化（dry run，未写入）"
else
    echo "✅ 已更新 ${count} 张基线，审阅后提交"
fi
