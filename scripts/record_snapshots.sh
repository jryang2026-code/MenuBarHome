#!/usr/bin/env bash
# Record UI snapshot baselines and list the PNGs that changed.
#
#   bash scripts/record_snapshots.sh [--dry-run]
#
# The reference renderer is GitHub-hosted macos-26-intel with Xcode 26.6 and the zh_CN
# metric locale. This Mac is not that renderer. A local diff is a preview.
# Bump the runner image or the Xcode pin only together with a new recording.
# Do not widen SnapshotAssertion tolerances to hide a renderer change.
#   --dry-run  record into a scratch copy and list what would change, leaving the baselines alone
#
# The script prints the Swift Testing summary and the process exit code, and keeps the log.
# Record mode reports an issue for each baseline whose pixels changed, so a finished run can
# exit non-zero. The script itself fails only when that run does not finish.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
SNAPSHOT_REL="Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"
SNAPSHOT_DIR="$ROOT_DIR/$SNAPSHOT_REL"
DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        exit 0
        ;;
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

# macos-26 can hang after Swift Testing prints its summary (SwiftPM #8394).
# On GitHub Actions, stop a quiet process and keep going when the log already settled.
run_snapshot_tests() {
    local log="$1"
    if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
        local status=0
        SNAPSHOT_RECORD=1 swift test --filter SnapshotTests >"$log" 2>&1 || status=$?
        return "$status"
    fi
    local stall_seconds="${SWIFT_TEST_STALL_SECONDS:-300}"
    local tick=10
    local test_pid stalled=0 last_size=-1 stall_detected=0 size exit_code=0 state
    SNAPSHOT_RECORD=1 script -q /dev/null swift test --filter SnapshotTests >"$log" 2>&1 &
    test_pid=$!
    while kill -0 "$test_pid" 2>/dev/null; do
        sleep "$tick"
        size="$(wc -c <"$log" | tr -d '[:space:]')"
        if [ "$size" = "$last_size" ]; then
            stalled=$((stalled + tick))
        else
            stalled=0
            last_size="$size"
        fi
        if [ "$stalled" -ge "$stall_seconds" ]; then
            echo "swift test produced no output for ${stall_seconds}s; stopping it" >&2
            kill -TERM "$test_pid" 2>/dev/null || true
            sleep 2
            pkill -TERM -f swiftpm-testing 2>/dev/null || true
            sleep 2
            pkill -KILL -f swiftpm-testing 2>/dev/null || true
            stall_detected=1
            break
        fi
    done
    # script(1) on macOS can return 0 after a failed swift test, and a finished
    # suite can hang (SwiftPM #8394). Judge the log, not the process status.
    wait "$test_pid" 2>/dev/null || exit_code=$?
    state="$(bash "$ROOT_DIR/scripts/gate_report.sh" suite-state "$log")"
    echo "snapshot suite state: ${state} (exit ${exit_code}, stalled=${stall_detected})" >&2
    case "$state" in
        passed) return 0 ;;
        failed) return 1 ;;
        *) return 143 ;;
    esac
}

set +e
run_snapshot_tests "$LOG"
swift_status=$?
set -e
if ! bash "$ROOT_DIR/scripts/gate_report.sh" record-verdict "$swift_status" "$LOG"; then
    exit 1
fi

changed="$(bash "$ROOT_DIR/scripts/gate_report.sh" list-snapshot-changes "$SNAPSHOT_REL")"
if [ -z "$changed" ]; then
    # Record mode only fails a test for a baseline it rewrites. With nothing rewritten, a non-zero
    # exit is a real failure, not "no change".
    if [ "$swift_status" -ne 0 ]; then
        echo "❌ 没有基线变化，但快照测试失败（退出码 ${swift_status}）。完整日志：${LOG}"
        bash "$ROOT_DIR/scripts/gate_report.sh" failing-tests "$LOG" | head -20
        exit 1
    fi
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
elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "✅ 已更新 ${count} 张基线"
else
    echo "✅ 已更新 ${count} 张基线。"
fi
