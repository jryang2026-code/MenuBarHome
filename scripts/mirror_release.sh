#!/usr/bin/env bash
# Mirror one published GitHub Release onto a mainland mirror (Gitee / GitCode), best effort.
#
#   bash scripts/mirror_release.sh <gitee|gitcode> <tag> <version> <asset-dir>
#
# Why best effort: the mainland mirror only widens distribution (research #29/R08 showed a
# third-party GitCode rebuild out-downloading the official DMG). It must never be able to fail or
# block the GitHub release it copies, so it runs in its own job after publishing and carries
# `continue-on-error: true`. This script therefore reports problems per asset and only exits
# non-zero at the end, and it stops itself once its time budget is spent instead of letting a
# stalled upload hit the job timeout.
#
# Two APIs, one shape on paper only: Gitee takes a form-encoded release and a multipart
# `attach_files` upload; GitCode takes a JSON release and uploads through a pre-signed URL
# (`releases/:tag/upload_url` → PUT). Both are addressed by tag here, so no release id is assumed.
#
# Token handling: the token arrives in GITEE_TOKEN / GITCODE_TOKEN and only ever appears in request
# bodies, query strings and a 0600 curl config file. Nothing prints a URL with the token in it, and
# no command turns on `set -x`.
#
# Environment:
#   GITEE_TOKEN / GITCODE_TOKEN        access token with release scope (required to do anything)
#   GITEE_MIRROR_REPO / GITCODE_MIRROR_REPO  owner/repo on the mirror (default jryang2026-code/MenuBarHome)
#   MIRROR_MAX_ASSET_BYTES             per-file ceiling; larger files are reported and skipped (default 100 MiB)
#   MIRROR_BUDGET_SECONDS              total time budget for this run (default 600)
#   MIRROR_API_BASE                    API root override, used only by scripts/test_mirror_release.sh
#   GITHUB_STEP_SUMMARY                written to when the runner sets it
set -uo pipefail

target="${1:-}"
tag="${2:-}"
version="${3:-}"
asset_dir="${4:-}"

if [ -z "$target" ] || [ -z "$tag" ] || [ -z "$version" ] || [ -z "$asset_dir" ]; then
    echo "用法：mirror_release.sh <gitee|gitcode> <tag> <version> <asset-dir>" >&2
    exit 2
fi

case "$target" in
    gitee)
        api_base="${MIRROR_API_BASE:-https://gitee.com/api/v5}"
        token_env="GITEE_TOKEN"
        token="${GITEE_TOKEN:-}"
        repo="${GITEE_MIRROR_REPO:-jryang2026-code/MenuBarHome}"
        ;;
    gitcode)
        api_base="${MIRROR_API_BASE:-https://api.gitcode.com/api/v5}"
        token_env="GITCODE_TOKEN"
        token="${GITCODE_TOKEN:-}"
        repo="${GITCODE_MIRROR_REPO:-jryang2026-code/MenuBarHome}"
        ;;
    *)
        echo "未知镜像目标：${target}（可用：gitee、gitcode）" >&2
        exit 2
        ;;
esac

max_asset_bytes="${MIRROR_MAX_ASSET_BYTES:-104857600}"
budget_seconds="${MIRROR_BUDGET_SECONDS:-600}"
deadline=$((SECONDS + budget_seconds))
failures=0
summary_lines=()
scratch="$(mktemp -d "${TMPDIR:-/tmp}/mirror-release.XXXXXX")"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; failures=$((failures + 1)); }
# A permanent condition the next run cannot fix: report it as an annotation, not as a failure.
note() { printf '::warning::%s\n' "$*"; }
summary() { summary_lines+=("$*"); }

flush_summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    printf '%s\n' "${summary_lines[@]}" >> "$GITHUB_STEP_SUMMARY"
}

if [ -z "$token" ]; then
    say "跳过 ${target} 镜像：未设置 ${token_env}（在仓库 Secrets 里配置后自动生效）"
    flush_summary
    exit 0
fi

if [ ! -d "$asset_dir" ]; then
    warn "${target} 镜像：找不到附件目录 ${asset_dir}"
    summary "- ${target}: ❌ 附件目录不存在（${asset_dir}）"
    flush_summary
    exit 1
fi

# Every request below is bounded by what is left of the budget, so a mirror that accepts a
# connection and then stalls cannot outlive the job.
remaining() { echo $(( deadline - SECONDS )); }
curl_timeout() {
    local left
    left="$(remaining)"
    [ "$left" -gt 0 ] || left=1
    [ "$left" -gt 300 ] && left=300
    echo "$left"
}

# One GET; prints the body. The token rides in the query, which is the API's own design.
api_get() {
    local path="$1" join="?"
    case "$path" in
        *\?*) join="&" ;;
    esac
    curl -sS --max-time "$(curl_timeout)" "${api_base}${path}${join}access_token=${token}"
}

# The asset names the mirror already carries for this tag; empty output when the release is absent.
release_assets_json() {
    local tag_path
    tag_path="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$tag")"
    api_get "/repos/${repo}/releases/tags/${tag_path}"
}

asset_names() {
    python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
for asset in (data.get("assets") or []):
    name = asset.get("name") or ""
    if name:
        print(name)'
}

release_id() {
    python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
print(data.get("id") or "")'
}

create_release() {
    local body="大陆镜像：与 GitHub Release ${tag} 同一批安装包（未重新编译）。更新清单与签名与 GitHub 版本一致。"
    case "$target" in
        gitee)
            curl -sS --max-time "$(curl_timeout)" -X POST \
                --data-urlencode "access_token=${token}" \
                --data-urlencode "tag_name=${tag}" \
                --data-urlencode "name=MenuBarHome ${version}" \
                --data-urlencode "target_commitish=main" \
                --data-urlencode "prerelease=false" \
                --data-urlencode "body=${body}" \
                "${api_base}/repos/${repo}/releases"
            ;;
        gitcode)
            # GitCode documents a JSON body, a query token, and a release keyed by tag — no id.
            python3 - "$tag" "$version" "$body" > "$scratch/release.json" <<'PY'
import json, sys
tag, version, body = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
    "tag_name": tag,
    "name": f"MenuBarHome {version}",
    "body": body,
    "target_commitish": "main",
    "prerelease": False,
}, sys.stdout, ensure_ascii=False)
PY
            curl -sS --max-time "$(curl_timeout)" -X POST \
                -H "Content-Type: application/json" \
                --data-binary "@$scratch/release.json" \
                "${api_base}/repos/${repo}/releases?access_token=${token}"
            ;;
    esac
}

# Gitee: multipart POST to the release. GitCode: ask for a pre-signed URL, then PUT the file with
# exactly the headers that URL was signed for.
upload_asset() {
    local asset="$1" name="$2" id="$3"
    case "$target" in
        gitee)
            if [ -z "$id" ]; then
                warn "${target} 上传 ${name} 失败（拿不到 release id）"
                return 1
            fi
            curl -sS --max-time "$(curl_timeout)" -o /dev/null -w '%{http_code}' -X POST \
                -F "access_token=${token}" \
                -F "file=@${asset}" \
                "${api_base}/repos/${repo}/releases/${id}/attach_files"
            ;;
        gitcode)
            local encoded_name
            encoded_name="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$name")"
            local tag_path
            tag_path="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$tag")"
            api_get "/repos/${repo}/releases/${tag_path}/upload_url?file_name=${encoded_name}" \
                > "$scratch/upload.json" || return 1
            python3 - "$scratch/upload.json" > "$scratch/upload.curl" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        info = json.load(handle)
except Exception:
    info = {}
url = info.get("url") or ""
if not url:
    sys.exit(1)
def quote(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"')
print(f'url = "{quote(url)}"')
for key, value in (info.get("headers") or {}).items():
    print(f'header = "{quote(key)}: {quote(value)}"')
PY
            [ -s "$scratch/upload.curl" ] || return 1
            curl -sS --max-time "$(curl_timeout)" -o /dev/null -w '%{http_code}' \
                -K "$scratch/upload.curl" -T "$asset"
            ;;
    esac
}

say "ℹ️  ${target}（${repo}）：同步 ${tag}"

tag_path="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$tag")"
probe="$(curl -sS --max-time "$(curl_timeout)" -w '\n%{http_code}' \
    "${api_base}/repos/${repo}/releases/tags/${tag_path}?access_token=${token}" 2>/dev/null || true)"
probe_code="${probe##*$'\n'}"
probe_body="${probe%$'\n'*}"
id="$(printf '%s' "$probe_body" | release_id)"
names=""

if [ "$probe_code" = "200" ]; then
    names="$(printf '%s' "$probe_body" | asset_names)"
    say "✅ ${target} 已有 ${tag} 的 release（${id:-tag 寻址}）"
elif [ "$probe_code" = "404" ]; then
    say "ℹ️  ${target} 上没有 ${tag}，创建 release"
    created="$(create_release)"
    id="$(printf '%s' "$created" | release_id)"
    if [ "$target" = "gitee" ] && [ -z "$id" ]; then
        warn "${target} 创建 release 失败（响应里没有 id）"
        summary "- ${target}: ❌ 创建 ${tag} release 失败"
        flush_summary
        exit 1
    fi
    say "✅ ${target} release 已创建"
else
    warn "${target} 查询 release 失败（HTTP ${probe_code:-无响应}）"
    summary "- ${target}: ❌ 查询 ${tag} release 失败（HTTP ${probe_code:-无响应}）"
    flush_summary
    exit 1
fi

uploaded=0
skipped=0
for asset in "$asset_dir"/*; do
    [ -f "$asset" ] || continue
    name="$(basename "$asset")"
    if [ "$(remaining)" -le 0 ]; then
        note "${target} 时间预算（${budget_seconds}s）用尽，剩余附件未同步；下次发布或手动重跑会补齐"
        break
    fi
    if printf '%s\n' "$names" | grep -qxF "$name"; then
        say "⏭️  ${target} 已有 ${name}"
        skipped=$((skipped + 1))
        continue
    fi
    size="$(wc -c < "$asset" | tr -d '[:space:]')"
    if [ "$size" -gt "$max_asset_bytes" ]; then
        note "${target} 跳过 ${name}：${size} 字节超过单文件上限 ${max_asset_bytes}"
        skipped=$((skipped + 1))
        continue
    fi
    code="$(upload_asset "$asset" "$name" "$id" 2>/dev/null | tail -n 1)"
    case "$code" in
        200|201|202)
            say "✅ ${target} 已上传 ${name}（${size} 字节）"
            uploaded=$((uploaded + 1))
            ;;
        *)
            warn "${target} 上传 ${name} 失败（HTTP ${code:-无响应}）"
            ;;
    esac
done

summary "- ${target}（${repo}）：上传 ${uploaded} 个附件，跳过 ${skipped} 个"
if [ "$failures" -gt 0 ]; then
    summary "- ${target}: ⚠️ ${failures} 个问题，详见运行日志（不影响 GitHub 发布）"
    flush_summary
    printf '⚠️  %s 镜像完成，但有 %s 个问题（GitHub 发布不受影响）\n' "$target" "$failures" >&2
    exit 1
fi

summary "- ${target}: ✅ 镜像完成"
flush_summary
say "✅ ${target} 镜像完成"
exit 0
