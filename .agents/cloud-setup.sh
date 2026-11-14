#!/usr/bin/env bash
# Idempotent Linux cloud environment setup for MenuBarHome (Antigravity Cloud & Cursor Cloud).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_VERSION="6.1.3"
ACTIONLINT_VERSION="1.7.12"

mkdir -p "$HOME/.local/bin"

# 1. Ensure bash subshells (including BASH_ENV=~/.bashrc) inherit user toolchains
#    without polluting synthetic test PATHs (e.g. PATH="$empty") or shadowing prepended test stubs.
touch "$HOME/.bashrc"
sed -i '/case \$- in/,/esac/d' "$HOME/.bashrc" 2>/dev/null || true
sed -i '/^export PATH="\$HOME\/\.local\/swift\/usr\/bin:/d' "$HOME/.bashrc" 2>/dev/null || true
sed -i '/# >>> menubarhome-cloud-path >>>/,/# <<< menubarhome-cloud-path <<</d' "$HOME/.bashrc" 2>/dev/null || true
cat <<'EOF' >> "$HOME/.bashrc"
# >>> menubarhome-cloud-path >>>
case ":$PATH:" in
  *":/usr/bin:"*)
    _mbh_p=":$PATH:"
    _mbh_add=""
    for _mbh_d in "$HOME/.local/swift/usr/bin" "$HOME/.local/bin" "/usr/local/go/bin" "/usr/local/cargo/bin"; do
      case "$_mbh_p:$_mbh_add:" in
        *":$_mbh_d:"*) ;;
        *) [ -d "$_mbh_d" ] && _mbh_add="${_mbh_add:+$_mbh_add:}$_mbh_d" ;;
      esac
    done
    if [ -n "$_mbh_add" ]; then
      case "$_mbh_p" in
        *":/usr/local/bin:"*) _mbh_p="${_mbh_p%%:/usr/local/bin:*}:$_mbh_add:/usr/local/bin:${_mbh_p#*:/usr/local/bin:}" ;;
        *) _mbh_p="${_mbh_p%%:/usr/bin:*}:$_mbh_add:/usr/bin:${_mbh_p#*:/usr/bin:}" ;;
      esac
      PATH="${_mbh_p#:}"
      PATH="${PATH%:}"
      export PATH
    fi
    unset _mbh_p _mbh_add _mbh_d
    ;;
esac
# <<< menubarhome-cloud-path <<<
EOF
export PATH="$HOME/.local/swift/usr/bin:$HOME/.local/bin:/usr/local/go/bin:/usr/local/cargo/bin:$PATH"

# 2. Install actionlint in user space if absent
if ! command -v actionlint >/dev/null 2>&1; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) al_arch="amd64" ;;
    aarch64|arm64) al_arch="arm64" ;;
    *) al_arch="" ;;
  esac
  if [ -n "$al_arch" ]; then
    tmp_al="$(mktemp -d)"
    tarball="actionlint_${ACTIONLINT_VERSION}_linux_${al_arch}.tar.gz"
    if command -v gh >/dev/null 2>&1 && gh release download "v${ACTIONLINT_VERSION}" -R rhysd/actionlint -p "$tarball" -D "$tmp_al" 2>/dev/null; then
      tar -xzf "$tmp_al/$tarball" -C "$tmp_al" actionlint
      mv "$tmp_al/actionlint" "$HOME/.local/bin/actionlint"
      chmod +x "$HOME/.local/bin/actionlint"
    elif curl -fsSL --http1.1 --retry 3 "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${tarball}" -o "$tmp_al/$tarball" 2>/dev/null; then
      tar -xzf "$tmp_al/$tarball" -C "$tmp_al" actionlint
      mv "$tmp_al/actionlint" "$HOME/.local/bin/actionlint"
      chmod +x "$HOME/.local/bin/actionlint"
    fi
    rm -rf "$tmp_al"
  fi
fi

# 3. Install Swift 6.1.3 Linux toolchain in user space (~/.local/swift) if absent
if ! command -v swift >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      swift_plat="debian12"
      swift_tar="swift-${SWIFT_VERSION}-RELEASE-debian12.tar.gz"
      ;;
    aarch64|arm64)
      swift_plat="debian12-aarch64"
      swift_tar="swift-${SWIFT_VERSION}-RELEASE-debian12-aarch64.tar.gz"
      ;;
    *)
      swift_plat=""
      swift_tar=""
      ;;
  esac
  if [ -n "$swift_plat" ]; then
    tmp_sw="$(mktemp -d)"
    swift_url="https://download.swift.org/swift-${SWIFT_VERSION}-release/${swift_plat}/swift-${SWIFT_VERSION}-RELEASE/${swift_tar}"
    curl -fL --http1.1 --retry 3 "$swift_url" -o "$tmp_sw/swift.tar.gz"
    rm -rf "$HOME/.local/swift"
    mkdir -p "$HOME/.local/swift"
    tar -xzf "$tmp_sw/swift.tar.gz" --strip-components=1 -C "$HOME/.local/swift"
    rm -rf "$tmp_sw"
  fi
fi

# 4. Install npm dependencies for windows/ and raycast/ when lockfile changes
install_npm_if_needed() {
  local sub="$1"
  local dir="$REPO_ROOT/$sub"
  [ -f "$dir/package-lock.json" ] || return 0
  local want_sha
  want_sha="$(sha256sum "$dir/package-lock.json" | awk '{print $1}')"
  local stamp="$dir/node_modules/.cloud-lock-sha256"
  if [ -x "$dir/node_modules/.bin/tsc" ] && [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$want_sha" ]; then
    return 0
  fi
  npm ci --prefix "$dir" --no-audit --no-fund
  printf '%s\n' "$want_sha" > "$stamp"
}

install_npm_if_needed "windows"
install_npm_if_needed "raycast"

# 5. Pin Linux Swift shim timestamps so incremental MijiaCore builds stay cached
if [ -d "$REPO_ROOT/scripts/linux-check/Shims" ]; then
  find "$REPO_ROOT/scripts/linux-check/Shims" \
       "$REPO_ROOT/scripts/linux-check/Package.swift" \
       "$REPO_ROOT/scripts/linux-check/Package.resolved" \
       -type f -exec touch -d @1577836800 {} + 2>/dev/null || true
fi

# 6. Ensure default Antigravity Cloud pstack model sheet exists on persistent ~/.gemini
if [ -d "$HOME/.gemini" ] && [ ! -f "$HOME/.gemini/pstack/pstack-models.md" ]; then
  mkdir -p "$HOME/.gemini/pstack"
  cat <<'EOF' > "$HOME/.gemini/pstack/pstack-models.md"
# pstack model configuration (Antigravity Cloud)

feature, refactoring: inherit
bug-fix: inherit
perf-issue: inherit
hillclimb: inherit
judgment and prose: inherit
strongest judgment: inherit
how explorer: inherit
how explainer: inherit
why investigators: inherit
why synthesizer: inherit
reflect tooling: inherit
reflect judgment, divergent, synthesizer: inherit
arena runners: inherit, inherit, inherit
arena cross-judge pool: inherit
swarm workers: inherit
architect runners: inherit, inherit, inherit
interrogate reviewers: inherit, inherit, inherit
thermos reviewers: inherit
no-comments reviewer: inherit

default effort: session
session hook: on
EOF
fi
