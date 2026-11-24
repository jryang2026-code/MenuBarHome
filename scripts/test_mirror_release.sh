#!/usr/bin/env bash
# Offline self-test for scripts/mirror_release.sh.
#
#   bash scripts/test_mirror_release.sh
#
# The mirror must be able to do one thing above all: never become the reason a GitHub release fails.
# This test runs the script against a local stand-in for the Gitee/GitCode v5 API and pins five
# behaviours — a missing token is a clean skip with no request at all, the first run creates the
# release and uploads every asset, a rerun uploads only what is missing, an upload the mirror rejects
# is reported per file instead of stopping the run, and an asset over the size ceiling is skipped with
# a warning.
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

here = os.path.dirname(os.path.abspath(__file__))
log_path = os.path.join(here, "requests.log")
state = {"releases": {}, "uploads": {}, "fail_uploads": False, "next_id": 4242}


def log(line):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def release_id_from(path):
    parts = path.strip("/").split("/")
    return parts[4] if len(parts) > 4 else ""


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        log(f"GET {path}")
        if "/releases/tags/" in path:
            tag = path.rsplit("/", 1)[-1]
            if tag in state["releases"]:
                self._reply(200, {"id": state["releases"][tag]})
            else:
                self._reply(404, {"message": "not found"})
            return
        if path.endswith("/attach_files"):
            release_id = release_id_from(path)
            self._reply(200, [{"name": name} for name in state["uploads"].get(release_id, [])])
            return
        self._reply(404, {"message": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        log(f"POST {path}")
        if path.endswith("/__fail_uploads"):
            state["fail_uploads"] = True
            self._reply(204)
            return
        if path.endswith("/releases"):
            tag = ""
            for part in raw.decode("utf-8", "replace").replace("&", "\n").split("\n"):
                if part.startswith("tag_name="):
                    tag = part.split("=", 1)[1]
            release_id = state["next_id"]
            state["next_id"] += 1
            state["releases"][tag] = release_id
            state["uploads"][str(release_id)] = []
            self._reply(201, {"id": release_id, "tag_name": tag})
            return
        if path.endswith("/attach_files"):
            if state["fail_uploads"]:
                self._reply(500, {"message": "boom"})
                return
            name = ""
            for line in raw.decode("utf-8", "replace").splitlines():
                if 'filename="' in line:
                    name = line.split('filename="', 1)[1].split('"', 1)[0]
            release_id = release_id_from(path)
            if name:
                state["uploads"].setdefault(release_id, []).append(name)
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
status=$?
check "缺少 token 时退出码 0" test "$status" = "0"
check "缺少 token 时说明跳过原因" grep -q '跳过 gitee 镜像' "$work/skip.log"
check "缺少 token 时没有任何请求" test ! -f "$work/requests.log"

# 2. First run: create the release and upload both assets.
rm -f "$work/requests.log"
GITEE_TOKEN="t" GITEE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitee v1.0.0 1.0.0 "$work/assets" \
    > "$work/first.log" 2>&1
status=$?
check "首跑退出码 0" test "$status" = "0"
check "首跑创建 release" grep -q 'POST /repos/owner/repo/releases$' "$work/requests.log"
check "首跑上传两个附件" test "$(count_in "$work/requests.log" '^POST .*attach_files')" = "2"

# 3. Rerun: the mirror already has both files, so nothing is uploaded again.
: > "$work/requests.log"
GITEE_TOKEN="t" GITEE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitee v1.0.0 1.0.0 "$work/assets" \
    > "$work/second.log" 2>&1
status=$?
check "重跑退出码 0" test "$status" = "0"
check "重跑不重复上传" test "$(count_in "$work/requests.log" '^POST .*attach_files')" = "0"

# 4. A rejecting mirror: every asset is attempted, each failure is named, exit is non-zero.
curl -sS -o /dev/null -X POST "${MIRROR_API_BASE}/__fail_uploads" 2>/dev/null || true
rm -f "$work/requests.log"
GITCODE_TOKEN="t" GITCODE_MIRROR_REPO="owner/repo" bash "$SCRIPT" gitcode v2.0.0 2.0.0 "$work/assets" \
    > "$work/fail.log" 2>&1
status=$?
check "上传被拒时退出码非零（交给 continue-on-error 收成警告）" test "$status" != "0"
check "上传被拒时逐个附件报告失败" test "$(count_in "$work/fail.log" '失败（HTTP')" = "2"
check "上传被拒时点名 HTTP 状态" grep -q 'HTTP 500' "$work/fail.log"

# 5. An asset over the ceiling is skipped with a warning, and that alone is not a failure.
rm -f "$work/requests.log"
GITCODE_TOKEN="t" GITCODE_MIRROR_REPO="owner/repo" MIRROR_MAX_ASSET_BYTES=1 \
    bash "$SCRIPT" gitcode v3.0.0 3.0.0 "$work/assets" > "$work/oversize.log" 2>&1
status=$?
check "超上限附件被跳过并写明原因" grep -q '超过单文件上限' "$work/oversize.log"
check "仅超上限时退出码 0" test "$status" = "0"

if [ "$failures" -gt 0 ]; then
    echo "❌ 镜像自检未通过：${failures} 项" >&2
    exit 1
fi
echo "✅ 镜像自检通过"
