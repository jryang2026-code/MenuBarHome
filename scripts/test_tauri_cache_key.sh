#!/usr/bin/env bash
# The Windows release restores the bundler-tools cache CI saves. The key strings have to match.
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

keys_of() {
    grep -E '^[[:space:]]*key:[[:space:]]*tauri-bundler-tools-' "$1" || true
}

value_of() {
    printf '%s\n' "$1" | sed -E 's/^[[:space:]]*key:[[:space:]]*//'
}

ci_keys="$(keys_of .github/workflows/ci.yml)"
release_keys="$(keys_of .github/workflows/release.yml)"
ci_count="$(printf '%s\n' "$ci_keys" | grep -c . || true)"
release_count="$(printf '%s\n' "$release_keys" | grep -c . || true)"

if [ "$ci_count" = 1 ]; then
    pass "ci.yml 有一条 tauri-bundler-tools key"
else
    fail "ci.yml 应有一条 tauri-bundler-tools key，实际 ${ci_count}"
fi
if [ "$release_count" = 1 ]; then
    pass "release.yml 有一条 tauri-bundler-tools key"
else
    fail "release.yml 应有一条 tauri-bundler-tools key，实际 ${release_count}"
fi

ci_value="$(value_of "$ci_keys")"
release_value="$(value_of "$release_keys")"
if [ -n "$ci_value" ] && [ "$ci_value" = "$release_value" ]; then
    pass "两处 tauri bundler tools 缓存 key 相同"
else
    fail "缓存 key 不一致：ci『${ci_value}』 release『${release_value}』"
fi

if [ "$failures" -eq 0 ]; then
    exit 0
fi
exit 1
