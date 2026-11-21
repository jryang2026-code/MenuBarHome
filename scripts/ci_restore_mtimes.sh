#!/usr/bin/env bash
set -euo pipefail
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || true)" = "true" ]; then
    echo "❌ ci_restore_mtimes.sh requires a non-shallow git checkout (fetch-depth: 0)" >&2
    exit 1
fi
python3 - << 'PY'
import os
import subprocess

log = subprocess.check_output(
    ["git", "log", "-m", "--pretty=format:COMMIT:%ct", "--name-only"],
    text=True,
)
stamp = None
seen = set()
for line in log.splitlines():
    if not line:
        continue
    if line.startswith("COMMIT:"):
        stamp = int(line.split(":", 1)[1])
        continue
    if stamp is None or line in seen or not os.path.isfile(line):
        continue
    seen.add(line)
    os.utime(line, (stamp, stamp))
print(f"stamped {len(seen)} tracked files")
PY
