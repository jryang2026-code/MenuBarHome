#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mmb-git-guard.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

id_harness="$tmp/id_harness.sh"
{
    printf '%s\n' 'set -euo pipefail'
    sed -n '/^check_git_identity()/,/^}/p' "$root/scripts/check.sh"
    printf '%s\n' 'check_git_identity'
} >"$id_harness"

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" config commit.gpgsign false
git -C "$repo" config user.name "jryang2026-code"
git -C "$repo" config user.email "jryang2026-code@users.noreply.github.com"
printf 'ok\n' >"$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -q -m "init"
git -C "$repo" update-ref refs/remotes/origin/main HEAD

if (cd "$repo" && bash "$id_harness") >/dev/null 2>&1; then
    pass "jryang2026-code 干净身份放行"
else
    fail "jryang2026-code 干净身份不应被拦截"
fi

status=0
out="$(cd "$repo" && GIT_AUTHOR_NAME="jryang1997" GIT_AUTHOR_EMAIL="120853343+jryang1997@users.noreply.github.com" bash "$id_harness" 2>&1)" || status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qF "jryang1997"; then
    pass "拦截 GIT_AUTHOR_IDENT 中的已停用账号 jryang1997"
else
    fail "应拦截 GIT_AUTHOR_IDENT 中的 jryang1997，实际 status=${status} out=${out}"
fi

printf 'b\n' >"$repo/a.txt"
git -C "$repo" add a.txt
GIT_AUTHOR_NAME="jryang1997" GIT_AUTHOR_EMAIL="120853343+jryang1997@users.noreply.github.com" \
    git -C "$repo" commit -q --no-verify -m "retired author commit"

status=0
out="$(cd "$repo" && bash "$id_harness" 2>&1)" || status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qF "jryang1997"; then
    pass "拦截 origin/main..HEAD 范围内混入的 jryang1997 提交"
else
    fail "应拦截分支历史中的 jryang1997 提交，实际 status=${status} out=${out}"
fi

head_sha="$(git -C "$repo" rev-parse HEAD)"
base_sha="$(git -C "$repo" rev-parse refs/remotes/origin/main)"
zero_sha="0000000000000000000000000000000000000000"

status=0
out="$(cd "$repo" && MMB_SKIP_PRE_PUSH=1 bash "$root/scripts/hooks/pre-push" gitlab "https://gitlab.com/jryang1997/MenuBarMijia.git" </dev/null 2>&1)" || status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qF "MMB_ALLOW_MIRROR_PUSH=1"; then
    pass "pre-push 即使设置 MMB_SKIP_PRE_PUSH=1 仍拦截 gitlab 镜像推送"
else
    fail "pre-push 应拦截 gitlab 推送，实际 status=${status} out=${out}"
fi

status=0
out="$(cd "$repo" && MMB_SKIP_PRE_PUSH=1 bash "$root/scripts/hooks/pre-push" nas "http://10.10.1.4:3000/jryang/MenuBarMijia.git" </dev/null 2>&1)" || status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qF "MMB_ALLOW_MIRROR_PUSH=1"; then
    pass "pre-push 拦截 nas 镜像推送"
else
    fail "pre-push 应拦截 nas 推送，实际 status=${status} out=${out}"
fi

if (cd "$repo" && MMB_ALLOW_MIRROR_PUSH=1 MMB_SKIP_PRE_PUSH=1 bash "$root/scripts/hooks/pre-push" nas "http://10.10.1.4:3000/jryang/MenuBarMijia.git" </dev/null >/dev/null 2>&1); then
    pass "pre-push 在显式声明 MMB_ALLOW_MIRROR_PUSH=1 时放行镜像同步"
else
    fail "pre-push 在 MMB_ALLOW_MIRROR_PUSH=1 时应放行"
fi

status=0
out="$(printf 'refs/heads/feat %s refs/heads/feat %s\n' "$head_sha" "$zero_sha" | (cd "$repo" && bash "$root/scripts/hooks/pre-push" origin "https://github.com/jryang2026-code/MenuBarHome.git" 2>&1))" || status=$?
if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -qF "jryang1997"; then
    pass "pre-push 拦截向 origin 推送含 jryang1997 作者的特性分支"
else
    fail "pre-push 应拦截含 jryang1997 提交的特性分支推送，实际 status=${status} out=${out}"
fi

git -C "$repo" reset -q --hard "$base_sha"
printf 'clean\n' >"$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -q --no-verify -m "clean commit"
clean_sha="$(git -C "$repo" rev-parse HEAD)"

if printf 'refs/heads/feat %s refs/heads/feat %s\n' "$clean_sha" "$zero_sha" | (cd "$repo" && bash "$root/scripts/hooks/pre-push" origin "https://github.com/jryang2026-code/MenuBarHome.git" >/dev/null 2>&1); then
    pass "pre-push 放行向 origin 推送干净的 jryang2026-code 特性分支"
else
    fail "pre-push 应放行干净特性分支向 origin 推送"
fi

if [ "$failures" -ne 0 ]; then
    echo "❌ Git 身份与远端镜像门禁自测失败 ${failures} 项" >&2
    exit 1
fi
echo "✅ Git 身份与远端镜像门禁自测通过"
