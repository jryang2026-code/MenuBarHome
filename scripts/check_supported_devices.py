#!/usr/bin/env python3
"""Check docs/supported-devices*.md against docs/capabilities.json (#154).

Every row that cites a capability in the Source column (a backticked id such as `plug-energy`)
must name an id that exists in the manifest, and that capability must not be unsupported on macOS
while the page calls the device "Control" / "可控". A row can therefore not claim control that the
manifest says is missing, and a renamed or removed capability breaks the lint instead of rotting.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/capabilities.json"
PAGES = (
    ("docs/supported-devices.md", "Control"),
    ("docs/supported-devices.zh-CN.md", "可控"),
)


def main() -> int:
    rows = {row["id"]: row for row in json.loads(MANIFEST.read_text(encoding="utf-8"))["rows"]}
    errors: list[str] = []
    checked = 0
    for page, control_word in PAGES:
        path = ROOT / page
        if not path.exists():
            errors.append(f"{page}: 文件不存在")
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if not line.startswith("|") or line.startswith("| :--") or line.startswith("| Device") or line.startswith("| 设备"):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) != 4:
                errors.append(f"{page}:{number}: 表格行应有 4 列，实际 {len(cells)}")
                continue
            device, status, _notes, source = cells
            ids = re.findall(r"`([a-z0-9-]+)`", source)
            for capability in ids:
                checked += 1
                row = rows.get(capability)
                if row is None:
                    errors.append(f"{page}:{number}: 「{device}」引用了不存在的能力 `{capability}`")
                elif status == control_word and row["macos"] == "unsupported":
                    errors.append(f"{page}:{number}: 「{device}」写成可控，但 `{capability}` 在 macOS 上是 unsupported")
    if errors:
        print("❌ 设备支持速查页与 docs/capabilities.json 不一致：")
        for error in errors:
            print(f"  {error}")
        return 1
    print(f"✅ 设备支持速查页的 {checked} 处能力引用都存在于 docs/capabilities.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
