#!/bin/bash
# 在 Linux（无 Xcode）上编译并测试 MijiaCore。macOS 上请直接用 scripts/check.sh。
# 做法：把 Sources/MijiaCore 和测试复制到 .work/，只注入 FoundationNetworking 导入、去掉 Linux 没有的 waitsForConnectivity。
set -euo pipefail
L="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$L/../.." && pwd)"
W="$L/.work"; S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
cp -r "$R/Sources/MijiaCore" "$S/MijiaCore"; cp -r "$R/Tests/MijiaCoreTests" "$S/MijiaCoreTests"
find "$S" -name '*.swift' -exec sed -i -e '1i #if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif' -e '/waitsForConnectivity = /d' {} \;
mkdir -p "$W"; ln -sfn "$R/Tests/Fixtures" "$W/Fixtures"
# 只写入内容变了的文件。swift build 按 mtime 判断要不要重编，整目录重建会让缓存和第二次运行都全量重编。
cd "$S"; find . -type f | while IFS= read -r f; do
  if ! cmp -s "$f" "$W/$f"; then mkdir -p "$(dirname "$W/$f")"; cp "$f" "$W/$f"; fi
done
cd "$W"; find MijiaCore MijiaCoreTests -type f | while IFS= read -r f; do
  [ -e "$S/$f" ] || rm "$W/$f"
done
cd "$L"; TZ="${TZ:-Asia/Shanghai}" swift test "$@"
