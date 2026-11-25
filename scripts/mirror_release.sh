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
#   MIRROR_TARGET_BRANCH               branch the mirror creates a missing tag on (default: the
#                                      mirror repository's own default branch)
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

# Some curl transport errors echo the URL, and every token here rides in that URL. Mask it
# before anything reaches stderr, while keeping the rest of the diagnostic readable.
mask_curl_stderr() {
    local log="$1"
    [ -s "$log" ] || return 0
    python3 - "$log" "$token" <<'PY'
import sys
log_path, secret = sys.argv[1], sys.argv[2]
with open(log_path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        sys.stderr.write(line.replace(secret, "***"))
PY
}

curl_safe() {
    local status=0
    curl "$@" 2>"$scratch/curl.err" || status=$?
    if [ "$status" -ne 0 ]; then
        mask_curl_stderr "$scratch/curl.err"
    fi
    return "$status"
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
    curl_safe -sS --max-time "$(curl_timeout)" "${api_base}${path}${join}access_token=${token}"
}

quote_component() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

asset_names() {
    python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
for asset in ((data or {}).get("assets") or []):
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
print((data or {}).get("id") or "")'
}

# "present" / "missing" / "error" for a lookup body.
#
# Gitee answers a tag without a release with HTTP 200 and a JSON `null`, so the status code alone is
# not enough: a null body, an empty body and an object without a tag_name all mean "create it".
release_state() {
    local code="$1"
    # Only HTTP 200 bodies can describe a release; 404 means missing, everything else is an error.
    case "$code" in
        200) ;;
        404) printf 'missing\n'; return ;;
        *) printf 'error\n'; return ;;
    esac
    python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if raw == "":
    print("missing")
    raise SystemExit
try:
    data = json.loads(raw)
except Exception:
    print("error")
    raise SystemExit
if data is None:
    print("missing")
elif isinstance(data, dict) and data.get("tag_name"):
    print("present")
else:
    print("missing")'
}

# The branch a missing tag is created on: the mirror repository's own default branch, because a
# release-only mirror (no source pushed) may use master, trunk or anything else.
mirror_branch() {
    if [ -n "${MIRROR_TARGET_BRANCH:-}" ]; then
        printf '%s\n' "$MIRROR_TARGET_BRANCH"
        return
    fi
    local branch
    branch="$(api_get "/repos/${repo}" 2>/dev/null | python3 -c 'import json,sys
try:
    print((json.load(sys.stdin) or {}).get("default_branch") or "")
except Exception:
    print("")')"
    printf '%s\n' "${branch:-main}"
}

create_release() {
    local body="大陆镜像：与 GitHub Release ${tag} 同一批安装包（未重新编译）。更新清单与签名与 GitHub 版本一致。"
    local branch
    branch="$(mirror_branch)"
    case "$target" in
        gitee)
            curl_safe -sS --max-time "$(curl_timeout)" -X POST \
                -o "$scratch/create.json" -w '%{http_code}' \
                --data-urlencode "access_token=${token}" \
                --data-urlencode "tag_name=${tag}" \
                --data-urlencode "name=MenuBarHome ${version}" \
                --data-urlencode "target_commitish=${branch}" \
                --data-urlencode "prerelease=false" \
                --data-urlencode "body=${body}" \
                "${api_base}/repos/${repo}/releases" > "$scratch/create.code" || true
            ;;
        gitcode)
            # GitCode documents a JSON body, a query token, and a release keyed by tag — no id.
            python3 - "$tag" "$version" "$body" "$branch" > "$scratch/release.json" <<'PY'
import json, sys
tag, version, body, branch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({
    "tag_name": tag,
    "name": f"MenuBarHome {version}",
    "body": body,
    "target_commitish": branch,
    "prerelease": False,
}, sys.stdout, ensure_ascii=False)
PY
            curl_safe -sS --max-time "$(curl_timeout)" -X POST \
                -o "$scratch/create.json" -w '%{http_code}' \
                -H "Content-Type: application/json" \
                --data-binary "@$scratch/release.json" \
                "${api_base}/repos/${repo}/releases?access_token=${token}" > "$scratch/create.code" || true
            ;;
    esac
    tr -d '[:space:]' < "$scratch/create.code" 2>/dev/null || true
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
            curl_safe -sS --max-time "$(curl_timeout)" -o /dev/null -w '%{http_code}' -X POST \
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
            python3 - "$scratch/upload.json" > "$scratch/upload.curl.tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        info = json.load(handle)
except Exception:
    info = {}
url = info.get("url") or ""
if not url:
    sys.exit(1)
def quote(value, label):
    text = str(value)
    if "\r" in text or "\n" in text:
        sys.exit(f"curl -K 配置字段 {label} 含换行，已拒绝写入")
    return text.replace("\\", "\\\\").replace('"', '\\"')
print(f'url = "{quote(url, "url")}"')
for key, value in (info.get("headers") or {}).items():
    print(f'header = "{quote(key, "header key")}: {quote(value, "header value")}"')
PY
            [ "$?" -eq 0 ] || return 1
            [ -s "$scratch/upload.curl.tmp" ] || return 1
            mv "$scratch/upload.curl.tmp" "$scratch/upload.curl"
            curl_safe -sS --max-time "$(curl_timeout)" -o /dev/null -w '%{http_code}' \
                -K "$scratch/upload.curl" -T "$asset"
            ;;
    esac
}

say "ℹ️  ${target}（${repo}）：同步 ${tag}"

tag_path="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$tag")"
probe_code=000
curl_safe -sS --max-time "$(curl_timeout)" -o "$scratch/probe.json" -w '%{http_code}' \
    "${api_base}/repos/${repo}/releases/tags/${tag_path}?access_token=${token}" \
    > "$scratch/probe.code" || true
probe_code="$(tr -d '[:space:]' < "$scratch/probe.code" 2>/dev/null || true)"
[ -n "$probe_code" ] || probe_code=000
probe_body="$(cat "$scratch/probe.json" 2>/dev/null || true)"
case "$probe_code" in
    200) probe_state="$(printf '%s' "$probe_body" | release_state 200)" ;;
    404) probe_state="missing" ;;
    *)   probe_state="error" ;;
esac
id="$(printf '%s' "$probe_body" | release_id)"
names=""

if [ "$probe_code" = "200" ] && [ "$probe_state" = "present" ]; then
    names="$(printf '%s' "$probe_body" | asset_names)"
    say "✅ ${target} 已有 ${tag} 的 release（${id:-tag 寻址}）"
elif [ "$probe_code" = "404" ] || { [ "$probe_code" = "200" ] && [ "$probe_state" = "missing" ]; }; then
    say "ℹ️  ${target} 上没有 ${tag}，创建 release"
    create_code="$(create_release)"
    created="$(cat "$scratch/create.json" 2>/dev/null || true)"
    id="$(printf '%s' "$created" | release_id)"
    case "$create_code" in
        200|201|202) ;;
        *)
            warn "${target} 创建 release 失败（HTTP ${create_code:-无响应}）"
            summary "- ${target}: ❌ 创建 ${tag} release 失败（HTTP ${create_code:-无响应}）"
            flush_summary
            exit 1
            ;;
    esac
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
