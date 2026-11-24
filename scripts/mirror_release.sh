#!/usr/bin/env bash
# Mirror one published GitHub Release onto a mainland mirror (Gitee / GitCode), best effort.
#
#   bash scripts/mirror_release.sh <gitee|gitcode> <tag> <version> <asset-dir>
#
# Why best effort: the mainland mirror only widens distribution (research #29/R08 showed a
# third-party GitCode rebuild out-downloading the official DMG). It must never be able to fail or
# block the GitHub release it copies, so the workflow step runs after publishing and carries
# `continue-on-error: true`. This script therefore reports problems and exits non-zero at the end
# instead of stopping at the first one, and every asset is uploaded independently.
#
# Token handling: the access token arrives in GITEE_TOKEN / GITCODE_TOKEN and goes into request
# bodies and query strings only. Nothing here prints a URL with the token in it, and no command
# turns on `set -x`.
#
# Environment:
#   GITEE_TOKEN / GITCODE_TOKEN        personal access token with release scope (required to do anything)
#   GITEE_MIRROR_REPO / GITCODE_MIRROR_REPO  owner/repo on the mirror (default jryang2026-code/MenuBarHome)
#   MIRROR_MAX_ASSET_BYTES             per-file ceiling; larger files are reported and skipped (default 100 MiB)
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
failures=0
summary_lines=()

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

# 1. Find the release id for this tag; create the release when the mirror has none yet.
#
# A token in a query string is the API's design. Every request below goes through curl without -v,
# and no response body is printed, so the token never reaches the transcript.
release_id=""
existing="$(curl -sS --max-time 60 -w '\n%{http_code}' \
    "${api_base}/repos/${repo}/releases/tags/${tag}?access_token=${token}" 2>/dev/null || true)"
existing_code="${existing##*$'\n'}"
existing_body="${existing%$'\n'*}"
if [ "$existing_code" = "200" ]; then
    release_id="$(printf '%s' "$existing_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    say "✅ ${target} 已有 ${tag} 的 release（id=${release_id}）"
fi

if [ -z "$release_id" ]; then
    say "ℹ️  ${target} 上没有 ${tag}，创建 release"
    payload=(
        --data-urlencode "access_token=${token}"
        --data-urlencode "tag_name=${tag}"
        --data-urlencode "name=MenuBarHome ${version}"
        --data-urlencode "target_commitish=main"
        --data-urlencode "prerelease=false"
        --data-urlencode "body=大陆镜像：与 GitHub Release ${tag} 同一批安装包（未重新编译）。更新清单签名与 GitHub 版本一致。"
    )
    created="$(curl -sS --max-time 120 -X POST "${api_base}/repos/${repo}/releases" "${payload[@]}" 2>/dev/null || true)"
    release_id="$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    if [ -z "$release_id" ]; then
        warn "${target} 创建 release 失败（响应里没有 id）"
        summary "- ${target}: ❌ 创建 ${tag} release 失败"
        flush_summary
        exit 1
    fi
    say "✅ ${target} release 已创建（id=${release_id}）"
fi

# 2. Upload every asset the mirror does not carry yet, so a rerun is cheap and idempotent.
uploaded_names="$(curl -sS --max-time 60 \
    "${api_base}/repos/${repo}/releases/${release_id}/attach_files?access_token=${token}" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for item in data if isinstance(data, list) else []:
    name = item.get("name") or item.get("file_name") or ""
    if name:
        print(name)' 2>/dev/null || true)"

uploaded=0
skipped=0
for asset in "$asset_dir"/*; do
    [ -f "$asset" ] || continue
    name="$(basename "$asset")"
    if printf '%s\n' "$uploaded_names" | grep -qxF "$name"; then
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
    code="$(curl -sS --max-time 1800 -o /dev/null -w '%{http_code}' -X POST \
        -F "access_token=${token}" \
        -F "file=@${asset}" \
        "${api_base}/repos/${repo}/releases/${release_id}/attach_files" 2>/dev/null || true)"
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

summary "- ${target}（${repo}）：上传 ${uploaded} 个附件，跳过 ${skipped} 个已存在附件"
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
