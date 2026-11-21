#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

CANONICAL_MACOS_RUNNER = "macos-26-intel"
CANONICAL_XCODE_VERSION = "26.6"
_PINNED_ACTION_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
_USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)")
_RUNS_ON_RE = re.compile(r"^\s*runs-on:\s*([^\s#]+)")
_XCODE_VER_RE = re.compile(r"""^\s*xcode-version:\s*["']?([^"'\s#]+)["']?""")


def _clean_scalar(raw: str) -> str:
    val = raw.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
        return val[1:-1]
    return val


def audit_workflows(root: Path, actionlint_mode: str = "auto") -> tuple[bool, list[str]]:
    workflows_dir = root / ".github" / "workflows"
    workflow_files = sorted(p for p in workflows_dir.glob("*.y*ml") if p.is_file()) if workflows_dir.is_dir() else []
    if not workflow_files:
        return False, [".github/workflows:1: no workflow files found"]

    diags: list[str] = []
    for path in workflow_files:
        rel = path.relative_to(root).as_posix()
        for line_no, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = raw_line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if m := _USES_RE.match(raw_line):
                target = _clean_scalar(m.group(1))
                if not target.startswith("./") and not _PINNED_ACTION_RE.match(target):
                    diags.append(f"{rel}:{line_no}: W4: non-local action '{target}' must be pinned to a 40-char commit SHA")
            if m := _RUNS_ON_RE.match(raw_line):
                runner = _clean_scalar(m.group(1))
                if "macos" in runner.lower() and runner != CANONICAL_MACOS_RUNNER:
                    diags.append(f"{rel}:{line_no}: W1: disallowed macOS runner '{runner}' (expected '{CANONICAL_MACOS_RUNNER}')")
            if m := _XCODE_VER_RE.match(raw_line):
                ver = _clean_scalar(m.group(1))
                if ver != CANONICAL_XCODE_VERSION:
                    diags.append(f"{rel}:{line_no}: W2: xcode-version '{ver}', expected '{CANONICAL_XCODE_VERSION}'")

    ran_actionlint = False
    if actionlint_mode != "off":
        resolved = shutil.which("actionlint")
        if not resolved:
            if actionlint_mode == "required":
                diags.append(".github/workflows:1: actionlint is required (--actionlint required) but was not found on PATH")
        else:
            ran_actionlint = True
            proc = subprocess.run(
                [resolved, "-no-color", *[str(p) for p in workflow_files]],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode != 0:
                output = (proc.stdout + "\n" + proc.stderr).strip()
                diags.append(f".github/workflows:1: actionlint failed (exit {proc.returncode}):\n{output}")

    return ran_actionlint, diags


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate GitHub Actions workflow invariants.")
    parser.add_argument("--actionlint", choices=("auto", "required", "off"), default="auto")
    args = parser.parse_args(argv)
    ran_actionlint, diags = audit_workflows(Path(__file__).resolve().parent.parent, actionlint_mode=args.actionlint)
    for diag in diags:
        print(f"❌ {diag}", file=sys.stderr)
    if diags:
        return 1
    suffix = "含 actionlint" if ran_actionlint else "未检测到 actionlint，已跳过 YAML 语法检查"
    print(f"✅ 工作流契约检查通过（{suffix}）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
