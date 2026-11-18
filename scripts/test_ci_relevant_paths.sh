#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ALL_KEYS=(code macos windows core raycast scripts macos_build appintents windows_native nas go2rtc)
failures=0

expect_true_keys() {
    local label="$1"
    local input="$2"
    shift 2
    local expected_true=" $* "
    local output key want line
    output="$(printf '%b' "$input" | bash scripts/ci_relevant_paths.sh)"
    for key in "${ALL_KEYS[@]}"; do
        want=false
        case "$expected_true" in
            *" $key "*) want=true ;;
        esac
        line="${key}=${want}"
        if ! printf '%s\n' "$output" | grep -Fxq "$line"; then
            printf 'FAIL %s (expected %s)\n' "$label" "$line"
            printf '%s\n' "$output" | sed 's/^/    /'
            failures=$((failures + 1))
            return
        fi
    done
    printf 'PASS %s\n' "$label"
}

expect_true_keys "generic root Markdown sets code=true only so doc-link lint runs" \
    "CODING_STANDARDS.md\n" \
    code

expect_true_keys "docs/* Markdown and asset paths set code=true only" \
    "docs/agents/issue-tracker.md\ndocs/assets/readme-v3/windows-fluent.png\n" \
    code

expect_true_keys "scripts/go2rtc-ptz/README.md preserves scripts and go2rtc flags" \
    "scripts/go2rtc-ptz/README.md\n" \
    code scripts go2rtc

expect_true_keys "non-Markdown repo metadata skips CI jobs" \
    "LICENSE\n.cursor/rules/local.mdc\n"

expect_true_keys "Windows frontend source sets code and windows only" \
    "windows/src/ui/onboardingGuide.ts\n" \
    code windows

expect_true_keys "empty input falls back to full CI" \
    "" \
    "${ALL_KEYS[@]}"

expect_true_keys "record-snapshots workflow runs the macOS snapshot job and script tests" \
    ".github/workflows/record-snapshots.yml\n" \
    code macos scripts

expect_true_keys "unknown path falls back to full CI" \
    "unknown.bin\n" \
    "${ALL_KEYS[@]}"

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项 ci_relevant_paths 自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ ci_relevant_paths 自测通过\n'
