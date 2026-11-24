#!/usr/bin/env bash
# Offline self-test for scripts/mirror_release.sh.
#
#   bash scripts/test_mirror_release.sh
#
# The mirror must be able to do one thing above all: never become the reason a GitHub release fails.
# This test runs the script against a local stand-in for the Gitee and GitCode v5 APIs, and the
# stand-in enforces each provider's real contract — Gitee: form-encoded release + multipart
# `attach_files`; GitCode: JSON release with a query token and no release id, then a pre-signed
# `upload_url` followed by a PUT. A request in the wrong shape gets a 400, so the test fails instead
# of quietly proving nothing.
set -uo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
SCRIPT="$ROOT_DIR/scripts/mirror_release.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/mirror-release-test.XXXXXX")"
server_pid=""
failures=0

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null
        wait "$server_pid" 2>/dev/null
    fi
    rm -rf "$work"
}
trap cleanup EXIT

check() {
    local what="$1"
    shift
    if "$@"; then
        echo "✅ $what"
    else
        echo "❌ $what" >&2
        failures=$((failures + 1))
    fi
}

count_in() { grep -c "$2" "$1" 2>/dev/null || true; }

mkdir -p "$work/assets"
printf 'dmg-bytes' > "$work/assets/MenuBarHome-1.0.0.dmg"
printf 'exe-bytes' > "$work/assets/MenuBarHome-1.0.0-windows-x64-setup.exe"

cat > "$work/server.py" <<'PY'
import http.server
import json
import os
import socketserver
import sys
import urllib.parse

here = os.path.dirname(os.path.abspath(__file__))
log_path = os.path.join(here, "requests.log")
# tag -> {"id": int, "assets": [names]}
state = {"releases": {}, "fail_uploads": False, "next_id": 4242}


def log(line):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def tag_from_releases_path(path):
    """/repos/o/r/releases/tags/<tag> or /repos/o/r/releases/<tag>/upload_url."""
    parts = [urllib.parse.unquote(part) for part in path.strip("/").split("/")]
    if "tags" in parts:
        index = parts.index("tags") + 1
        return parts[index] if len(parts) > index else ""
    if "releases" in parts:
        index = parts.index("releases") + 1
        if len(parts) > index and not parts[index].isdigit():
            return parts[index]
    return ""


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, payload=None, raw=None):
        body = raw if raw is not None else (b"" if payload is None else json.dumps(payload).encode())
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _release_payload(self, tag):
        return {
            "tag_name": tag,
            "name": f"MenuBarHome {tag}",
            "body": "mirror",
            "prerelease": False,
            "assets": [{"name": name, "size": 9, "digest": "sha256:x"} for name in state["releases"][tag]["assets"]],
        }

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        log(f"GET {path}")
        if "access_token" not in query:
            self._reply(401, {"message": "missing access_token"})
            return
        if path.endswith("/upload_url"):
            tag = tag_from_releases_path(path)
            name = (query.get("file_name") or [""])[0]
            port = self.server.server_address[1]
            self._reply(200, {
                "url": f"http://127.0.0.1:{port}/upload/{urllib.parse.quote(tag)}/{urllib.parse.quote(name)}",
                "headers": {
                    "x-obs-meta-project-id": "p",
                    "x-obs-acl": "public-read",
                    "x-obs-callback": "c",
                    "Content-Type": "application/octet-stream",
                },
            })
            return
        if "/releases/tags/" in path:
            tag = tag_from_releases_path(path)
            if tag in state["releases"]:
                self._reply(200, self._release_payload(tag))
            elif tag == "v6.0.0":
                # Gitee answers a tag without a release with HTTP 200 and a JSON null.
                self._reply(200, raw=b"null")
            else:
                self._reply(404, {"message": "not found"})
            return
        if path.strip("/") == "repos/owner/repo":
            self._reply(200, {"full_name": "owner/repo", "default_branch": "trunk"})
            return
        self._reply(404, {"message": "not found"})

    def do_PUT(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        log(f"PUT {path}")
        parts = path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != "upload":
            self._reply(404, {"message": "not found"})
            return
        if not self.headers.get("x-obs-meta-project-id"):
            self._reply(400, {"message": "missing signed header"})
            return
        tag = urllib.parse.unquote(parts[1])
        name = urllib.parse.unquote(parts[2])
        if state["fail_uploads"]:
            self._reply(500, {"message": "boom"})
            return
        if len(raw) != 9:
            self._reply(400, {"message": "unexpected body"})
            return
        state["releases"].setdefault(tag, {"id": state["next_id"], "assets": []})
        state["next_id"] += 1
        state["releases"][tag]["assets"].append(name)
        self._reply(201, {"name": name})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        log(f"POST {path} {content_type}")
        if path.endswith("/__fail_uploads"):
            state["fail_uploads"] = True
            self._reply(204)
            return
        # Gitee takes the token in a form field (or a multipart part), GitCode in the query.
        token_given = "access_token" in query or b"access_token" in raw
        if not token_given:
            self._reply(401, {"message": "missing access_token"})
            return
        if path.endswith("/releases"):
            if content_type == "application/json":
                # GitCode: JSON body, and the documented response carries no release id.
                try:
                    payload = json.loads(raw.decode("utf-8"))
                except Exception:
                    self._reply(400, {"message": "body is not JSON"})
                    return
                tag = payload.get("tag_name") or ""
                if tag in state["releases"]:
                    self._reply(400, {"message": "release exists"})
                    return
                state["releases"][tag] = {"id": state["next_id"], "assets": []}
                state["next_id"] += 1
                log(f"CREATE-BRANCH {payload.get('target_commitish') or ''}")
                self._reply(200, self._release_payload(tag))
                return
            if content_type == "application/x-www-form-urlencoded":
                # Gitee: form-encoded release, and the response carries the id.
                fields = urllib.parse.parse_qs(raw.decode("utf-8"))
                tag = (fields.get("tag_name") or [""])[0]
                state["releases"][tag] = {"id": state["next_id"], "assets": []}
                state["next_id"] += 1
                log(f"CREATE-BRANCH {(fields.get('target_commitish') or [''])[0]}")
                payload = self._release_payload(tag)
                payload["id"] = state["releases"][tag]["id"]
                self._reply(201, payload)
                return
            self._reply(400, {"message": "unexpected content type"})
            return
        if path.endswith("/attach_files"):
            if content_type != "multipart/form-data":
                self._reply(400, {"message": "upload must be multipart"})
                return
            name = ""
            for line in raw.decode("utf-8", "replace").splitlines():
                if 'filename="' in line:
                    name = line.split('filename="', 1)[1].split('"', 1)[0]
            if state["fail_uploads"]:
                self._reply(500, {"message": "boom"})
                return
            target_tag = next((t for t, entry in state["releases"].items()
                               if str(entry["id"]) in path), "")
            if not target_tag or not name:
                self._reply(400, {"message": "unknown release or file"})
                return
            state["releases"][target_tag]["assets"].append(name)
            self._reply(201, {"name": name})
            return
        self._reply(404, {"message": "not found"})

    def log_message(self, *_args):
        pass


with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    port = server.server_address[1]
    with open(os.path.join(here, "port"), "w", encoding="utf-8") as handle:
        handle.write(str(port))
    sys.stderr.write(f"listening on {port}\n")
    server.serve_forever()
PY

python3 "$work/server.py" 2>"$work/server.err" &
server_pid=$!
for _ in $(seq 1 100); do
    [ -f "$work/port" ] && break
    sleep 0.05
done
if [ ! -f "$work/port" ]; then
    echo "❌ 本地镜像 API 桩没有启动：$(cat "$work/server.err" 2>/dev/null)" >&2
    exit 1
fi
export MIRROR_API_BASE="http://127.0.0.1:$(cat "$work/port")"

# 1. No token: a skip, exit 0, and not one request.
rm -f "$work/requests.log"
GITEE_TOKEN="" bash "$SCRIPT" gitee v1.0.0 1.0.0 "$work/assets" > "$work/skip.log" 2>&1
check "缺少 token 时退出码 0" test "$?" = "0"
check "缺少 token 时说明跳过原因" grep -q '跳过 gitee 镜像' "$work/skip.log"
check "缺少 token 时没有任何请求" test ! -f "$work/requests.log"

# 2. Gitee first run: form-encoded create, then a multipart upload per asset.
rm -f "$work/requests.log"
GITEE_TOKEN="t" GITEE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitee v1.0.0 1.0.0 "$work/assets" \
    > "$work/gitee.log" 2>&1
check "Gitee 首跑退出码 0" test "$?" = "0"
check "Gitee 首跑按表单创建 release" grep -q 'POST /repos/owner/repo/releases application/x-www-form-urlencoded' "$work/requests.log"
check "Gitee 首跑上传两个附件" test "$(count_in "$work/requests.log" 'POST /repos/owner/repo/releases/4242/attach_files multipart/form-data')" = "2"

# 3. Gitee rerun: the mirror already carries both files, so nothing is uploaded again.
rm -f "$work/requests.log"
GITEE_TOKEN="t" GITEE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitee v1.0.0 1.0.0 "$work/assets" \
    > "$work/gitee2.log" 2>&1
check "Gitee 重跑退出码 0" test "$?" = "0"
check "Gitee 重跑不重复上传" test "$(count_in "$work/requests.log" 'POST ')" = "0"

# 4. GitCode first run: JSON create without an id, then upload_url + PUT for each asset.
rm -f "$work/requests.log"
GITCODE_TOKEN="t" GITCODE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitcode v2.0.0 2.0.0 "$work/assets" \
    > "$work/gitcode.log" 2>&1
check "GitCode 首跑退出码 0" test "$?" = "0"
check "GitCode 首跑按 JSON 创建 release" grep -q 'POST /repos/owner/repo/releases application/json' "$work/requests.log"
check "GitCode 首跑按 tag 申请上传地址" test "$(count_in "$work/requests.log" 'GET /repos/owner/repo/releases/v2.0.0/upload_url')" = "2"
check "GitCode 首跑 PUT 两个附件" test "$(count_in "$work/requests.log" 'PUT /upload/v2.0.0/')" = "2"
check "GitCode 首跑不伪装成 Gitee 附件上传" test "$(count_in "$work/requests.log" 'attach_files')" = "0"

# 5. Gitee answers a missing tag with HTTP 200 + JSON null: that still means "create it".
rm -f "$work/requests.log"
GITEE_TOKEN="t" GITEE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitee v6.0.0 6.0.0 "$work/assets" \
    > "$work/nullbody.log" 2>&1
check "Gitee 的 null 响应按缺 release 处理并建出来" grep -q 'gitee release 已创建' "$work/nullbody.log"
check "Gitee 的 null 响应之后照常上传两个附件" test "$(count_in "$work/requests.log" 'POST /repos/owner/repo/releases/[0-9]*/attach_files')" = "2"

# 6. A release-only mirror may not have `main`; the tag is created on its own default branch.
check "创建 release 用镜像仓库的默认分支（trunk）" grep -q 'CREATE-BRANCH trunk' "$work/requests.log"

# 7. A rejecting mirror: every asset is attempted, each failure is named, exit is non-zero.
curl -sS -o /dev/null -X POST "${MIRROR_API_BASE}/__fail_uploads" 2>/dev/null || true
rm -f "$work/requests.log"
GITCODE_TOKEN="t" GITCODE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitcode v3.0.0 3.0.0 "$work/assets" \
    > "$work/fail.log" 2>&1
check "上传被拒时退出码非零（交给 continue-on-error 收成警告）" test "$?" != "0"
check "上传被拒时逐个附件报告失败" test "$(count_in "$work/fail.log" '失败（HTTP')" = "2"
check "上传被拒时点名 HTTP 状态" grep -q 'HTTP 500' "$work/fail.log"

# 8. An asset over the ceiling is skipped with a warning, and that alone is not a failure.
rm -f "$work/requests.log"
GITCODE_TOKEN="t" GITCODE_MIRROR_REPO="owner/repo" MIRROR_MAX_ASSET_BYTES=1 \
    bash "$SCRIPT" gitcode v4.0.0 4.0.0 "$work/assets" > "$work/oversize.log" 2>&1
check "超上限附件被跳过并写明原因" grep -q '超过单文件上限' "$work/oversize.log"
check "仅超上限时退出码 0" test "$?" = "0"

# 9. The time budget stops the run instead of letting a stall hit the job timeout.
rm -f "$work/requests.log"
GITCODE_TOKEN="t" GITCODE_MIRROR_REPO="owner/repo" MIRROR_BUDGET_SECONDS=0 \
    bash "$SCRIPT" gitcode v5.0.0 5.0.0 "$work/assets" > "$work/budget.log" 2>&1
check "时间预算用尽时说明并停下" grep -q '时间预算' "$work/budget.log"
check "时间预算用尽时不吞掉失败（退出码 0，附件留给下次补齐）" test "$?" = "0"

if [ "$failures" -gt 0 ]; then
    echo "❌ 镜像自检未通过：${failures} 项" >&2
    exit 1
fi
echo "✅ 镜像自检通过"
