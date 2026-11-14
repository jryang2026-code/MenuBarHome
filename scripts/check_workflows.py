#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

ActionlintMode = Literal["auto", "required", "off"]

CANONICAL_MACOS_RUNNER = "macos-26-intel"
CANONICAL_XCODE_VERSION = "26.6"
CANONICAL_CAMERA_WORKFLOW = "./.github/workflows/camera-bin.yml"
ALLOWED_MACOS_RUNS_ON: frozenset[str] = frozenset(
    {
        CANONICAL_MACOS_RUNNER,
        "${{ fromJSON(vars.MACOS_CI_RUNNER || '\"macos-26-intel\"') }}",
    }
)

_JOB_HEADER_RE = re.compile(r"""^(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_-]+)):\s*(?:#.*)?$""")
_STALE_MACOS_COMMENT_RE = re.compile(r"\bmacos-26(?!-intel)\b")
_PINNED_ACTION_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
_BLOCK_SCALAR_RE = re.compile(r"^[|>](?:[0-9]+[+-]?|[+-]?[0-9]*)$")
_MATRIX_REF_RE = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")
_UNSET = object()


@dataclass(frozen=True)
class ActionRef:
    line: int
    target: str


@dataclass(frozen=True)
class WorkflowJob:
    job_id: str
    line: int
    runs_on: tuple[int, str] | None
    runs_on_list: tuple[str, ...]
    matrix_vars: dict[str, tuple[str, ...]]
    uses_workflow: ActionRef | None
    step_uses: tuple[ActionRef, ...]
    xcode_versions: tuple[tuple[int, str], ...]
    rust_shared_keys: tuple[tuple[int, str], ...]
    tauri_cache_keys: tuple[tuple[int, str], ...]


@dataclass
class _JobBuilder:
    job_id: str
    line: int
    prop_indent: int | None = None
    runs_on: tuple[int, str] | None = None
    runs_on_list: list[str] = field(default_factory=list)
    matrix_vars: dict[str, list[str]] = field(default_factory=dict)
    uses_workflow: ActionRef | None = None
    step_uses: list[ActionRef] = field(default_factory=list)
    xcode_versions: list[tuple[int, str]] = field(default_factory=list)
    rust_shared_keys: list[tuple[int, str]] = field(default_factory=list)
    tauri_cache_keys: list[tuple[int, str]] = field(default_factory=list)

    def freeze(self) -> WorkflowJob:
        return WorkflowJob(
            self.job_id,
            self.line,
            self.runs_on,
            tuple(self.runs_on_list),
            {k: tuple(v) for k, v in self.matrix_vars.items()},
            self.uses_workflow,
            tuple(self.step_uses),
            tuple(self.xcode_versions),
            tuple(self.rust_shared_keys),
            tuple(self.tauri_cache_keys),
        )


@dataclass(frozen=True)
class WorkflowSpec:
    rel_path: str
    jobs: tuple[WorkflowJob, ...]
    stale_macos_comments: tuple[tuple[int, str], ...]


@dataclass(frozen=True)
class WorkflowDiagnostic:
    rel_path: str
    line: int
    message: str

    def format(self) -> str:
        return f"{self.rel_path}:{self.line}: {self.message}"


@dataclass
class _ParseState:
    in_jobs: bool = False
    jobs_indent: int | None = None
    block_capture: tuple[int, str | None, int, list[str]] | None = None
    list_capture: tuple[int, str, str | None] | None = None
    matrix_indent: int | None = None
    cur: _JobBuilder | None = None


def _strip_yaml_comment(raw: str) -> str:
    s = raw.strip()
    in_single = in_double = False
    for idx, ch in enumerate(s):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single and (idx == 0 or s[idx - 1] != "\\"):
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double and (idx == 0 or s[idx - 1].isspace()):
            return s[:idx].rstrip()
    return s


def _clean_yaml_scalar(raw: str) -> str:
    s = _strip_yaml_comment(raw)
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return s


def _parse_inline_list(val: str) -> list[str]:
    inner = val[1:-1].strip()
    if not inner:
        return []
    return [_clean_yaml_scalar(item) for item in inner.split(",") if _clean_yaml_scalar(item)]


def _flush_block_capture(state: _ParseState) -> None:
    if state.block_capture is None or state.cur is None:
        state.block_capture = None
        return
    _, key, line_no, parts = state.block_capture
    joined = " ".join(p.strip() for p in parts if p.strip())
    if key == "runs-on" and joined:
        state.cur.runs_on = (line_no, joined)
    elif key == "job_uses" and joined:
        state.cur.uses_workflow = ActionRef(line_no, joined)
    elif key == "step_uses" and joined:
        state.cur.step_uses.append(ActionRef(line_no, joined))
    state.block_capture = None


def _record_list_item(state: _ParseState, item: str) -> None:
    if state.cur is None or state.list_capture is None:
        return
    _, kind, var_name = state.list_capture
    val = _clean_yaml_scalar(item)
    if not val:
        return
    if kind == "runs-on":
        state.cur.runs_on_list.append(val)
    elif kind == "matrix" and var_name:
        state.cur.matrix_vars.setdefault(var_name, []).append(val)


def _handle_matrix_entry(state: _ParseState, indent: int, key: str, val: str) -> None:
    cur = state.cur
    assert cur is not None
    if val.startswith("[") and val.endswith("]"):
        cur.matrix_vars.setdefault(key, []).extend(_parse_inline_list(val))
    elif not val:
        state.list_capture = (indent, "matrix", key)


def _handle_job_property(state: _ParseState, indent: int, line_no: int, stripped: str) -> None:
    cur = state.cur
    assert cur is not None
    if cur.prop_indent is None and not stripped.startswith("- "):
        cur.prop_indent = indent
    content = stripped[2:].lstrip() if stripped.startswith("- ") else stripped
    key, sep, raw_val = content.partition(":")
    if not sep:
        return
    key, val = key.strip(), _clean_yaml_scalar(raw_val)
    is_job_prop = cur.prop_indent is not None and indent == cur.prop_indent and not stripped.startswith("- ")
    if state.matrix_indent is not None and indent > state.matrix_indent:
        _handle_matrix_entry(state, indent, key, val)
        return
    if key == "matrix" and (is_job_prop or (indent > (cur.prop_indent or indent) and not val)):
        state.matrix_indent = indent
        return
    if _BLOCK_SCALAR_RE.match(val):
        cap_key = "runs-on" if is_job_prop and key == "runs-on" else ("job_uses" if is_job_prop and key == "uses" else ("step_uses" if key == "uses" else None))
        state.block_capture = (indent, cap_key, line_no, [])
        return
    _record_scalar_prop(state, line_no, key, val, is_job_prop, indent)


def _record_scalar_prop(
    state: _ParseState, line_no: int, key: str, val: str, is_job_prop: bool, indent: int
) -> None:
    cur = state.cur
    assert cur is not None
    if is_job_prop and key == "runs-on":
        if val.startswith("[") and val.endswith("]"):
            cur.runs_on = (line_no, val)
            cur.runs_on_list.extend(_parse_inline_list(val))
        elif not val:
            cur.runs_on = (line_no, "")
            state.list_capture = (indent, "runs-on", None)
        else:
            cur.runs_on = (line_no, val)
    elif key == "uses":
        if is_job_prop:
            cur.uses_workflow = ActionRef(line_no, val)
        else:
            cur.step_uses.append(ActionRef(line_no, val))
    elif key == "xcode-version":
        cur.xcode_versions.append((line_no, val))
    elif key == "shared-key":
        cur.rust_shared_keys.append((line_no, val))
    elif key == "key" and val.startswith("tauri-bundler-tools-"):
        cur.tauri_cache_keys.append((line_no, val))


def _check_block_or_comment(
    state: _ParseState, stale_comments: list[tuple[int, str]], line_no: int, indent: int, stripped: str
) -> bool:
    if state.block_capture is not None:
        if not stripped or indent > state.block_capture[0]:
            if stripped:
                state.block_capture[3].append(stripped)
            return True
        _flush_block_capture(state)
    if not stripped:
        return True
    if stripped.startswith("#"):
        if _STALE_MACOS_COMMENT_RE.search(stripped):
            stale_comments.append((line_no, stripped))
        return True
    if state.list_capture is not None:
        if indent > state.list_capture[0] and stripped.startswith("- "):
            _record_list_item(state, stripped[2:])
            return True
        if indent <= state.list_capture[0]:
            state.list_capture = None
    return False


def _process_workflow_line(
    state: _ParseState, jobs: list[_JobBuilder], stale_comments: list[tuple[int, str]], line_no: int, raw_line: str
) -> None:
    stripped = raw_line.strip()
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if _check_block_or_comment(state, stale_comments, line_no, indent, stripped):
        return
    if state.matrix_indent is not None and indent <= state.matrix_indent:
        state.matrix_indent = None
    if indent == 0 or not state.in_jobs:
        if indent == 0:
            state.cur = None
            state.in_jobs = stripped == "jobs:" or stripped.startswith(("jobs: ", "jobs:#"))
        _, sep, raw_val = stripped.partition(":")
        if sep and _BLOCK_SCALAR_RE.match(_clean_yaml_scalar(raw_val)):
            state.block_capture = (indent, None, line_no, [])
        return
    if state.jobs_indent is None and not stripped.startswith("-"):
        state.jobs_indent = indent
    if indent == state.jobs_indent and not stripped.startswith("-"):
        state.cur = None
        if m := _JOB_HEADER_RE.match(stripped):
            state.cur = _JobBuilder(m.group(1) or m.group(2) or m.group(3), line_no)
            jobs.append(state.cur)
        return
    if state.cur is not None:
        _handle_job_property(state, indent, line_no, stripped)


def parse_workflow(rel_path: str, text: str) -> WorkflowSpec:
    jobs: list[_JobBuilder] = []
    stale_comments: list[tuple[int, str]] = []
    state = _ParseState()
    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        _process_workflow_line(state, jobs, stale_comments, line_no, raw_line)
    _flush_block_capture(state)
    return WorkflowSpec(rel_path, tuple(j.freeze() for j in jobs), tuple(stale_comments))


def _resolved_runs_on_candidates(job: WorkflowJob) -> list[str]:
    if job.runs_on_list:
        return list(job.runs_on_list)
    if job.runs_on is None:
        return []
    val = job.runs_on[1]
    mm = _MATRIX_REF_RE.match(val)
    if mm:
        var = mm.group(1)
        if var in job.matrix_vars:
            return list(job.matrix_vars[var])
    return [val] if val else []


def _is_macos_job(job: WorkflowJob) -> bool:
    if job.uses_workflow is not None:
        return False
    if "macos" in job.job_id.lower():
        return True
    return any(
        tok in candidate.lower()
        for candidate in _resolved_runs_on_candidates(job)
        for tok in ("macos", "macos_ci_runner", "self-hosted")
    )


def _check_job(spec: WorkflowSpec, job: WorkflowJob, diags: list[WorkflowDiagnostic]) -> None:
    def err(line: int, msg: str) -> None:
        diags.append(WorkflowDiagnostic(spec.rel_path, line, msg))

    if _is_macos_job(job):
        candidates = _resolved_runs_on_candidates(job)
        if job.runs_on is None or (not candidates and not job.runs_on_list):
            err(job.line, f"W1: macOS job '{job.job_id}' is missing runs-on")
        elif job.runs_on_list or any(c not in ALLOWED_MACOS_RUNS_ON for c in candidates):
            bad = job.runs_on_list or [c for c in candidates if c not in ALLOWED_MACOS_RUNS_ON]
            err(
                job.runs_on[0],
                f"W1: job '{job.job_id}' uses disallowed macOS runner {bad!r} "
                f"(expected '{CANONICAL_MACOS_RUNNER}' or MACOS_CI_RUNNER fallback to '{CANONICAL_MACOS_RUNNER}')",
            )
        setup_xcode = [r for r in job.step_uses if r.target.startswith("maxim-lobanov/setup-xcode@")]
        if not setup_xcode:
            err(job.line, f"W2: macOS job '{job.job_id}' must pin Xcode via maxim-lobanov/setup-xcode")
    else:
        setup_xcode = [r for r in job.step_uses if r.target.startswith("maxim-lobanov/setup-xcode@")]
    if len(job.xcode_versions) < len(setup_xcode):
        err(setup_xcode[0].line, f"W2: job '{job.job_id}' uses setup-xcode without explicit xcode-version")
    for x_line, x_ver in job.xcode_versions:
        if x_ver != CANONICAL_XCODE_VERSION:
            err(x_line, f"W2: job '{job.job_id}' selects xcode-version '{x_ver}', expected '{CANONICAL_XCODE_VERSION}'")
    for ref in ([job.uses_workflow] if job.uses_workflow is not None else []) + list(job.step_uses):
        if not ref.target.startswith("./") and not _PINNED_ACTION_RE.match(ref.target):
            err(ref.line, f"W4: non-local action '{ref.target}' in job '{job.job_id}' must be pinned to a 40-char commit SHA")


def _check_ci_release_parity(ci_spec: WorkflowSpec, rel_spec: WorkflowSpec, diags: list[WorkflowDiagnostic]) -> None:
    def err(path: str, line: int, msg: str) -> None:
        diags.append(WorkflowDiagnostic(path, line, msg))

    ci_xcode = {ver for job in ci_spec.jobs for _, ver in job.xcode_versions}
    rel_xcode = {ver for job in rel_spec.jobs for _, ver in job.xcode_versions}
    if not ci_xcode or not rel_xcode or ci_xcode != rel_xcode:
        err(rel_spec.rel_path, 1, f"W2: xcode-version mismatch between ci.yml ({sorted(ci_xcode)}) and release.yml ({sorted(rel_xcode)})")

    ci_tauri = [(l, k) for j in ci_spec.jobs for l, k in j.tauri_cache_keys]
    rel_tauri = [(l, k) for j in rel_spec.jobs for l, k in j.tauri_cache_keys]
    if len(ci_tauri) != 1 or len(rel_tauri) != 1 or ci_tauri[0][1] != rel_tauri[0][1]:
        err(rel_spec.rel_path, rel_tauri[0][0] if rel_tauri else 1, f"W3: tauri-bundler-tools- cache key mismatch: ci.yml has {ci_tauri}, release.yml has {rel_tauri}")

    ci_jobs = {j.job_id: j for j in ci_spec.jobs}
    rel_jobs = {j.job_id: j for j in rel_spec.jobs}
    ci_rust = list(ci_jobs["windows-installer"].rust_shared_keys) if "windows-installer" in ci_jobs else []
    rel_rust = list(rel_jobs["windows-release"].rust_shared_keys) if "windows-release" in rel_jobs else []
    if len(ci_rust) != 1 or len(rel_rust) != 1 or ci_rust[0][1] != rel_rust[0][1]:
        err(rel_spec.rel_path, rel_rust[0][0] if rel_rust else 1, f"W3: Swatinem/rust-cache shared-key mismatch between ci.yml:windows-installer ({ci_rust}) and release.yml:windows-release ({rel_rust})")

    ci_cam = [j.uses_workflow.target for j in ci_spec.jobs if j.uses_workflow is not None and "camera-bin" in j.uses_workflow.target]
    rel_cam = [j.uses_workflow.target for j in rel_spec.jobs if j.uses_workflow is not None and "camera-bin" in j.uses_workflow.target]
    if ci_cam != [CANONICAL_CAMERA_WORKFLOW] or rel_cam != [CANONICAL_CAMERA_WORKFLOW]:
        err(rel_spec.rel_path, 1, f"W3: camera-bin reusable workflow mismatch between ci.yml ({ci_cam}) and release.yml ({rel_cam})")


def check_parity_and_runners(specs: list[WorkflowSpec]) -> list[WorkflowDiagnostic]:
    diags: list[WorkflowDiagnostic] = []
    by_name = {Path(spec.rel_path).name: spec for spec in specs}
    for spec in specs:
        for line_no, comment in spec.stale_macos_comments:
            diags.append(WorkflowDiagnostic(spec.rel_path, line_no, f"W2: stale bare 'macos-26' comment (use '{CANONICAL_MACOS_RUNNER}'): {comment}"))
        for job in spec.jobs:
            _check_job(spec, job, diags)
    if "ci.yml" in by_name and "release.yml" in by_name:
        _check_ci_release_parity(by_name["ci.yml"], by_name["release.yml"], diags)
    return diags


def _run_actionlint(
    root: Path,
    workflow_files: list[Path],
    mode: ActionlintMode,
    actionlint_bin: str | None | object,
) -> tuple[bool, list[WorkflowDiagnostic]]:
    if mode == "off":
        return False, []
    resolved = shutil.which("actionlint") if actionlint_bin is _UNSET else actionlint_bin
    if not isinstance(resolved, str) or not resolved:
        if mode == "required":
            return False, [WorkflowDiagnostic(".github/workflows", 1, "actionlint is required (--actionlint required) but was not found on PATH")]
        return False, []
    proc = subprocess.run([resolved, "-no-color", *[str(p) for p in workflow_files]], cwd=root, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        output = (proc.stdout + "\n" + proc.stderr).strip()
        return True, [WorkflowDiagnostic(".github/workflows", 1, f"actionlint failed (exit {proc.returncode}):\n{output}")]
    return True, []


def audit_workflows(
    root: Path,
    *,
    actionlint_mode: ActionlintMode = "auto",
    actionlint_bin: str | None | object = _UNSET,
) -> list[WorkflowDiagnostic]:
    return audit_workflows_with_status(root, actionlint_mode=actionlint_mode, actionlint_bin=actionlint_bin)[1]


def audit_workflows_with_status(
    root: Path,
    *,
    actionlint_mode: ActionlintMode = "auto",
    actionlint_bin: str | None | object = _UNSET,
) -> tuple[bool, list[WorkflowDiagnostic]]:
    workflows_dir = root / ".github" / "workflows"
    workflow_files = sorted(p for p in workflows_dir.glob("*.y*ml") if p.is_file()) if workflows_dir.is_dir() else []
    if not workflow_files:
        return False, [WorkflowDiagnostic(".github/workflows", 1, "no workflow files found")]
    specs = [parse_workflow(p.relative_to(root).as_posix(), p.read_text(encoding="utf-8")) for p in workflow_files]
    diags = check_parity_and_runners(specs)
    ran_actionlint, al_diags = _run_actionlint(root, workflow_files, actionlint_mode, actionlint_bin)
    diags.extend(al_diags)
    return ran_actionlint, diags


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate GitHub Actions workflow invariants.")
    parser.add_argument("--actionlint", choices=("auto", "required", "off"), default="auto")
    args = parser.parse_args(argv)
    ran_actionlint, diags = audit_workflows_with_status(Path(__file__).resolve().parent.parent, actionlint_mode=args.actionlint)
    for diag in diags:
        print(f"❌ {diag.format()}", file=sys.stderr)
    if diags:
        return 1
    suffix = "含 actionlint" if ran_actionlint else "未检测到 actionlint，已跳过 YAML 语法检查"
    print(f"✅ 工作流契约检查通过（{suffix}）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
