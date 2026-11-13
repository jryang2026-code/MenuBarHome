#!/usr/bin/env bash
# check_release.sh 附件集合的自测（#170）：两端 SBOM 加入严格清单后，
# draft-assets 必须拒绝缺项、多项、坏 SBOM 与校验和不符的安装包。
#
# 只覆盖 draft-assets；assets 还要求离线 Ed25519 签名，CI 没有私钥，
# 那部分仍由 finalize.yml 在真实草稿上验证。
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(tr -d '[:space:]' < VERSION)"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/menubarmijia-release-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

write_checksum() {
    printf '%s  %s\n' "$(sha256_file "$1")" "$(basename "$1")" > "$1.sha256"
}

spdx_document() {
    # 最小但合法的 SPDX 2.3 JSON：check_release.sh 只要求格式与至少一个组件。
    printf '{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"%s","documentNamespace":"https://example.invalid/%s","packages":[{"SPDXID":"SPDXRef-Package","name":"go2rtc","versionInfo":"1.9.9"}]}\n' "$1" "$1"
}

new_assets() {
    local dir="$1" dmg="$2" exe="$3" msi="$4"
    mkdir -p "$dir"
    printf 'dmg bytes\n' > "$dir/$dmg"
    printf 'exe bytes\n' > "$dir/$exe"
    printf 'msi bytes\n' > "$dir/$msi"
    write_checksum "$dir/$dmg"
    write_checksum "$dir/$exe"
    write_checksum "$dir/$msi"
    spdx_document "MenuBarHome-${version}-macos" > "$dir/MenuBarHome-${version}-macos.spdx.json"
    spdx_document "MenuBarHome-${version}-windows-x64" > "$dir/MenuBarHome-${version}-windows-x64.spdx.json"
}

dmg="MenuBarHome-${version}.dmg"
exe="MenuBarHome-${version}-windows-x64-setup.exe"
msi="MenuBarHome-${version}-windows-x64.msi"
good="$workdir/good"
new_assets "$good" "$dmg" "$exe" "$msi"

run_draft() {
    bash scripts/check_release.sh draft-assets "$version" "$1" >"$workdir/output.log" 2>&1
}

expect_draft() {
    # $1 = 0 表示应通过，非 0 表示应拒绝；失败时打印脚本输出便于定位。
    local expected="$1" message="$2" actual=0
    run_draft "$good" || actual=1
    if [ "$actual" = "$expected" ]; then
        pass "$message"
    else
        printf 'FAIL %s\n' "$message"
        sed 's/^/    /' "$workdir/output.log"
        failures=$((failures + 1))
    fi
}

expect_draft 0 'draft-assets accepts the six build files plus both SPDX SBOMs'

rm "$good/MenuBarHome-${version}-macos.spdx.json"
expect_draft 1 'draft-assets rejects a missing macOS SBOM'
spdx_document "MenuBarHome-${version}-macos" > "$good/MenuBarHome-${version}-macos.spdx.json"

rm "$good/MenuBarHome-${version}-windows-x64.spdx.json"
expect_draft 1 'draft-assets rejects a missing Windows SBOM'
spdx_document "MenuBarHome-${version}-windows-x64" > "$good/MenuBarHome-${version}-windows-x64.spdx.json"

printf 'unexpected\n' > "$good/notes.txt"
expect_draft 1 'draft-assets rejects an unexpected extra file'
rm "$good/notes.txt"

printf 'not json\n' > "$good/MenuBarHome-${version}-macos.spdx.json"
expect_draft 1 'draft-assets rejects an SBOM that is not JSON'
spdx_document "MenuBarHome-${version}-macos" > "$good/MenuBarHome-${version}-macos.spdx.json"

printf '{"spdxVersion":"SPDX-2.3","packages":[]}\n' > "$good/MenuBarHome-${version}-windows-x64.spdx.json"
expect_draft 1 'draft-assets rejects an SBOM with no components'
spdx_document "MenuBarHome-${version}-windows-x64" > "$good/MenuBarHome-${version}-windows-x64.spdx.json"

printf 'tampered\n' > "$good/$dmg"
expect_draft 1 'draft-assets rejects an installer whose SHA-256 does not match'

# check_release.sh tag 版本一致性自测（含 scripts/mijia、package-lock.json 与 Cargo.lock）
tag_repo="$workdir/tag-repo"
mkdir -p "$tag_repo/windows/src-tauri" "$tag_repo/scripts"
git -C "$tag_repo" init -q
git -C "$tag_repo" config user.email t@example.com
git -C "$tag_repo" config user.name t
git -C "$tag_repo" config commit.gpgsign false

write_tag_repo_files() {
    local ver="$1" mijia_ver="$2" lock_ver="$3" cargo_lock_ver="$4"
    printf '%s\n' "$ver" > "$tag_repo/VERSION"
    printf '{"version":"%s","bundle":{"active":true,"targets":["nsis","msi"]}}\n' "$ver" \
        > "$tag_repo/windows/src-tauri/tauri.conf.json"
    printf '{"name":"menubarmijia-windows","version":"%s"}\n' "$ver" \
        > "$tag_repo/windows/package.json"
    printf '{"name":"menubarmijia-windows","version":"%s","packages":{"":{"version":"%s"}}}\n' \
        "$lock_ver" "$lock_ver" > "$tag_repo/windows/package-lock.json"
    cat > "$tag_repo/windows/src-tauri/Cargo.toml" <<EOF
[package]
name = "menubarmijia-windows"
version = "$ver"
EOF
    cat > "$tag_repo/windows/src-tauri/Cargo.lock" <<EOF
[[package]]
name = "menubarmijia-windows"
version = "$cargo_lock_ver"
EOF
    cat > "$tag_repo/scripts/mijia" <<EOF
MCP_SERVER_INFO = {"name": "menubarmijia", "version": "$mijia_ver"}
EOF
    git -C "$tag_repo" add -A
    git -C "$tag_repo" commit -q -m "release $ver" --allow-empty
    git -C "$tag_repo" tag -f "v$ver"
}

expect_tag() {
    local expected="$1" req_tag="$2" message="$3" expected_pattern="${4:-}"
    local event_name="${5:-}" ref="${6:-}" ref_type="${7:-}" actual=0
    local -a env_args=(env -u GITHUB_EVENT_NAME -u GITHUB_REF -u GITHUB_REF_TYPE -u GITHUB_OUTPUT)
    [ -n "$event_name" ] && env_args+=("GITHUB_EVENT_NAME=$event_name")
    [ -n "$ref" ] && env_args+=("GITHUB_REF=$ref")
    [ -n "$ref_type" ] && env_args+=("GITHUB_REF_TYPE=$ref_type")
    "${env_args[@]}" CHECK_RELEASE_ROOT="$tag_repo" \
        bash scripts/check_release.sh tag "$req_tag" >"$workdir/tag.log" 2>&1 || actual=1
    if [ "$actual" = "$expected" ] && { [ -z "$expected_pattern" ] || grep -Fq "$expected_pattern" "$workdir/tag.log"; }; then
        pass "$message"
    else
        printf 'FAIL %s\n' "$message"
        sed 's/^/    /' "$workdir/tag.log"
        failures=$((failures + 1))
    fi
}

write_tag_repo_files "1.2.5" "1.2.5" "1.2.5" "1.2.5"
expect_tag 0 "v1.2.5" "tag accepts matching VERSION, package/lock, Cargo.toml/lock, and scripts/mijia"
expect_tag 0 "v1.2.5" "tag accepts push ref refs/tags/v1.2.5" "" "push" "refs/tags/v1.2.5" "tag"
expect_tag 1 "v1.2.5" "tag rejects push ref refs/heads/main" "推送触发的 ref refs/heads/main 不是 refs/tags/v1.2.5" "push" "refs/heads/main" "branch"

write_tag_repo_files "1.2.5" "1.2.0" "1.2.5" "1.2.5"
expect_tag 1 "v1.2.5" "tag rejects stale scripts/mijia MCP_SERVER_INFO version" "scripts/mijia MCP_SERVER_INFO"

write_tag_repo_files "1.2.5" "1.2.5" "1.2.0" "1.2.5"
expect_tag 1 "v1.2.5" "tag rejects stale windows/package-lock.json version" "windows/package-lock.json"

write_tag_repo_files "1.2.5" "1.2.5" "1.2.5" "1.2.0"
expect_tag 1 "v1.2.5" "tag rejects stale windows/src-tauri/Cargo.lock version" "windows/src-tauri/Cargo.lock"

# 若当前环境 openssl 支持 Ed25519，额外实测 assets 模式拒绝仅含 DMG 的单平台签名清单
openssl_bin=""
for cand in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" genpkey -algorithm ed25519 -out "$workdir/test-ed25519.pem" >/dev/null 2>&1; then
        openssl_bin="$cand"
        break
    fi
done
if [ -n "$openssl_bin" ]; then
    assets_repo="$workdir/assets-repo"
    mkdir -p "$assets_repo/Sources/MijiaCore"
    printf '%s\n' "$version" > "$assets_repo/VERSION"
    pub_b64="$(python3 - "$openssl_bin" "$workdir/test-ed25519.pem" <<'PY'
import base64, subprocess, sys
der = subprocess.check_output([sys.argv[1], "pkey", "-in", sys.argv[2], "-pubout", "-outform", "DER"])
assert len(der) == 44 and der[:12] == bytes.fromhex("302a300506032b6570032100")
print(base64.b64encode(der[12:]).decode("ascii"))
PY
)"
    printf 'let updateSigningPublicKeyBase64 = "%s"\n' "$pub_b64" > "$assets_repo/Sources/MijiaCore/UpdateChecker.swift"
    assets_dir="$workdir/signed-assets"
    new_assets "$assets_dir" "$dmg" "$exe" "$msi"

    # 1) 仅签 DMG（1 个 files 条目）的清单在完整双端 assets 模式下必须被拒绝
    python3 - "$version" "$pub_b64" "$assets_dir" "$openssl_bin" "$workdir/test-ed25519.pem" <<'PY'
import base64, subprocess, sys
from pathlib import Path
sys.path.insert(0, "scripts")
import update_manifest

version, pub_b64, directory, openssl_bin, key_pem = sys.argv[1:]
d = Path(directory)
dmg_sha = update_manifest.read_sidecar(d / f"MenuBarHome-{version}.dmg")
body = update_manifest.canonical_bytes(version, "1.0.0", pub_b64, (dmg_sha,))
manifest = d / f"MenuBarHome-{version}.update.json"
manifest.write_bytes(body)
sig = subprocess.check_output([openssl_bin, "pkeyutl", "-sign", "-inkey", key_pem, "-rawin", "-in", str(manifest)])
Path(str(manifest) + ".ed25519.sig").write_text(base64.b64encode(sig).decode("ascii") + "\n", encoding="utf-8")
PY
    actual=0
    PATH="$(dirname "$openssl_bin"):$PATH" CHECK_RELEASE_ROOT="$assets_repo" \
        bash scripts/check_release.sh assets "$version" "$assets_dir" >"$workdir/assets.log" 2>&1 || actual=1
    if [ "$actual" = 1 ] && grep -q "全部 3 个安装包" "$workdir/assets.log"; then
        pass "assets rejects a macOS-only (1-file) update manifest on a full release"
    else
        printf 'FAIL assets should reject 1-file manifest\n'
        sed 's/^/    /' "$workdir/assets.log"
        failures=$((failures + 1))
    fi
fi

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项发布附件校验自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ 发布附件校验自测通过\n'
