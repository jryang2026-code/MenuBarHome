#!/bin/bash
set -euo pipefail
L="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$L/../.." && pwd)"
W="$L/.work"; S="$(mktemp -d "${TMPDIR:-/tmp}/linux-check-src.XXXXXX")"; trap 'rm -rf "$S"' EXIT
cp -r "$R/Sources/MijiaCore" "$S/MijiaCore"; cp -r "$R/Tests/MijiaCoreTests" "$S/MijiaCoreTests"; cp -r "$R/Tests/KeychainTestSupport" "$S/KeychainTestSupport"
cp -r "$R/Tests/PreferencesTestSupport" "$S/PreferencesTestSupport"
cp -r "$R/Tests/StateTestSupport" "$S/StateTestSupport"
find "$S" -name '*.swift' | while IFS= read -r f; do
  awk 'BEGIN {
         print "#if canImport(FoundationNetworking)"
         print "import FoundationNetworking"
         print "#endif"
       }
       !/waitsForConnectivity = /' "$f" >"$f.linux" && mv "$f.linux" "$f"
done
mkdir -p "$W"; ln -sfn "$R/Tests/Fixtures" "$W/Fixtures"
cd "$S"; find . -type f | while IFS= read -r f; do
  if ! cmp -s "$f" "$W/$f"; then mkdir -p "$(dirname "$W/$f")"; cp "$f" "$W/$f"; fi
done
cd "$W"; find MijiaCore MijiaCoreTests KeychainTestSupport PreferencesTestSupport StateTestSupport -type f | while IFS= read -r f; do
  [ -e "$S/$f" ] || rm "$W/$f"
done
cd "$L"; TZ="${TZ:-Asia/Shanghai}" swift test "$@"
