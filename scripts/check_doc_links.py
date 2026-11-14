#!/usr/bin/env python3

from __future__ import annotations

import fnmatch
import os
import posixpath
import re
import subprocess
import sys
import unicodedata
import urllib.parse
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "tel:", "data:", "menumijia://")
FENCE_OPEN_RE = re.compile(r"^[ ]{0,3}(`{3,}|~{3,})(.*)$")
HEADING_RE = re.compile(r"^[ ]{0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+[ \t]*)?$")
HTML_ID_RE = re.compile(r"""\bid\s*=\s*(['"])([^'"]+)\1""", re.IGNORECASE)
REF_DEF_RE = re.compile(r"^[ ]{0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?")
MD_LINK_RE = re.compile(
    r"""!?\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\(\s*(?:<([^>\n]+)>|((?:[^()\s]+|\([^()\s]*\))+))(?:\s+["'(].*?)?\s*\)"""
)
HTML_LINK_RE = re.compile(r"""<(?:a\b[^>]*?\bhref|img\b[^>]*?\bsrc|source\b[^>]*?\bsrcset)\s*=\s*(['"])(.*?)\1""", re.IGNORECASE)
LINE_FRAGMENT_RE = re.compile(r"^L([1-9][0-9]*)(?:-L?([1-9][0-9]*))?$")
HISTORICAL_ADR_RE = re.compile(r"^docs/adr/[0-9]")
SHELL_TEMPLATE_CHARS = frozenset("<>|$=(){};")
GLOB_CHARS = frozenset("*?[]")
_GIT_OVERRIDE_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_PREFIX",
)


def _clean_git_env() -> dict[str, str]:
    env = dict(os.environ)
    for var in _GIT_OVERRIDE_VARS:
        env.pop(var, None)
    return env


class DocTier(Enum):
    LIVING = "living"
    HISTORICAL_OR_EXTERNAL = "historical"


@dataclass(frozen=True)
class RepoIndex:
    root: Path
    tracked_files: frozenset[str]
    tracked_dirs: frozenset[str]
    tracked_top_dirs: frozenset[str]

    @classmethod
    def from_root(cls, root: Path) -> RepoIndex:
        resolved = root.resolve()
        res = subprocess.run(
            ["git", "ls-files", "-z"], cwd=resolved, env=_clean_git_env(), capture_output=True, text=True, check=False
        )
        raw_files = {e for e in res.stdout.split("\0") if e} if res.returncode == 0 and res.stdout else set()
        if raw_files:
            files = {f for f in raw_files if (resolved / f).exists() and (resolved / f).is_file()}
        else:
            files = {
                p.relative_to(resolved).as_posix()
                for p in resolved.rglob("*")
                if ".git" not in p.relative_to(resolved).parts and p.exists() and p.is_file()
            }
        dirs = {"/".join(f.split("/")[:i]) for f in files for i in range(1, len(f.split("/")))}
        top_dirs = {f.split("/", 1)[0] for f in files if "/" in f}
        return cls(resolved, frozenset(files), frozenset(dirs), frozenset(top_dirs))

    def filter_gitignored(self, rel_paths: set[str]) -> set[str]:
        if not rel_paths:
            return set()
        probes = [item for p in sorted(rel_paths) for item in (p.rstrip("/"), f"{p.rstrip('/')}/")]
        res = subprocess.run(
            ["git", "check-ignore", "--no-index", "--stdin"],
            cwd=self.root,
            env=_clean_git_env(),
            input="\n".join(probes) + "\n",
            text=True,
            capture_output=True,
            check=False,
        )
        if res.returncode in (0, 1):
            ignored = {line.rstrip("/") for line in res.stdout.splitlines() if line.strip()}
            return {
                p for p in rel_paths
                if any("/".join(p.rstrip("/").split("/")[: i + 1]) in ignored for i in range(len(p.rstrip("/").split("/"))))
            }
        gitignore = self.root / ".gitignore"
        if not gitignore.is_file():
            return set()
        pats = [l.strip().rstrip("/") for l in gitignore.read_text(encoding="utf-8").splitlines() if l.strip() and not l.lstrip().startswith("#")]
        return {
            p for p in rel_paths
            if any(fnmatch.fnmatchcase(p.rstrip("/"), pat.lstrip("/")) or any(fnmatch.fnmatchcase(seg, pat) for seg in p.rstrip("/").split("/")) for pat in pats)
        }


@dataclass(frozen=True)
class LinkRef:
    doc_path: str
    line: int
    raw_target: str
    kind: str


@dataclass(frozen=True)
class CodePathRef:
    doc_path: str
    line: int
    span: str
    repo_rel_path: str


@dataclass(frozen=True)
class DocDiagnostic:
    doc_path: str
    line: int
    target: str
    reason: str

    def format(self) -> str:
        return f"{self.doc_path}:{self.line}: {self.reason}: `{self.target}`"


def classify_doc(rel_path: str) -> DocTier:
    if (
        rel_path == "CHANGELOG.md"
        or bool(HISTORICAL_ADR_RE.match(rel_path))
        or rel_path.startswith("docs/research/")
        or rel_path.startswith(".out-of-scope/")
    ):
        return DocTier.HISTORICAL_OR_EXTERNAL
    return DocTier.LIVING


def _mask_html_comments(line: str, in_comment: bool) -> tuple[str, bool]:
    out = list(line)
    i, n = 0, len(line)
    while i < n:
        if in_comment:
            end = line.find("-->", i)
            stop = n if end < 0 else end + 3
            out[i:stop] = [" "] * (stop - i)
            in_comment = end < 0
            i = stop
        elif line.startswith("<!--", i):
            in_comment = True
        else:
            i += 1
    return "".join(out), in_comment


def _extract_code_spans(line: str) -> tuple[str, list[tuple[int, int, str]]]:
    out = list(line)
    spans: list[tuple[int, int, str]] = []
    i, n = 0, len(line)
    while i < n:
        if line[i] != "`":
            i += 1
            continue
        j = i
        while j < n and line[j] == "`":
            j += 1
        ticks, search, closed = line[i:j], j, -1
        while search < n:
            pos = line.find(ticks, search)
            if pos < 0:
                break
            end_ticks = pos + len(ticks)
            if (pos == j or line[pos - 1] != "`") and (end_ticks == n or line[end_ticks] != "`"):
                closed = pos
                break
            search = pos + 1
        if closed >= 0:
            end = closed + len(ticks)
            spans.append((i, end, line[j:closed]))
            out[i:end] = ["x"] * (end - i)
            i = end
        else:
            i = j
    return "".join(out), spans


def _iter_outside_fences(text: str) -> list[tuple[int, str]]:
    in_fence: tuple[str, int] | None = None
    active: list[tuple[int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        m = FENCE_OPEN_RE.match(line)
        if m:
            marker, rest = m.group(1), m.group(2)
            if in_fence is None and not (marker[0] == "`" and "`" in rest):
                in_fence = (marker[0], len(marker))
                continue
            if in_fence and marker[0] == in_fence[0] and len(marker) >= in_fence[1] and not rest.strip():
                in_fence = None
                continue
        if in_fence is None:
            active.append((lineno, line))
    return active


def _collect_md_links(
    text: str, rel_path: str, lineno: int, links: list[LinkRef], ext_label_ranges: list[tuple[int, int]]
) -> None:
    for m in MD_LINK_RE.finditer(text):
        target = (m.group(2) or m.group(3) or "").strip()
        links.append(LinkRef(rel_path, lineno, target, "markdown"))
        if target.lower().startswith(EXTERNAL_SCHEMES):
            ext_label_ranges.append((m.start(1), m.end(1)))
        inner = m.group(1)
        if "](" in inner:
            _collect_md_links(inner, rel_path, lineno, links, ext_label_ranges)


def _extract_code_paths(
    rel_path: str,
    lineno: int,
    spans: list[tuple[int, int, str]],
    ext_ranges: list[tuple[int, int]],
    top_dirs: frozenset[str],
    code_paths: list[CodePathRef],
) -> None:
    for start, end, span in spans:
        if any(s <= start and end <= e for s, e in ext_ranges):
            continue
        for raw_tok in span.split():
            if raw_tok.startswith("-"):
                continue
            tok = raw_tok.lstrip("\"'`,;:").rstrip("\"'`,.;:")
            if not tok:
                continue
            path_part = tok.split("#", 1)[0].split(":", 1)[0].rstrip("/")
            if not path_part or any(ch in SHELL_TEMPLATE_CHARS for ch in path_part):
                continue
            norm = posixpath.normpath(path_part)
            if "/" in norm and norm.split("/", 1)[0] in top_dirs:
                code_paths.append(CodePathRef(rel_path, lineno, tok, norm))


def parse_markdown_refs(
    rel_path: str, text: str, tier: DocTier, top_dirs: frozenset[str]
) -> tuple[list[LinkRef], list[CodePathRef]]:
    links: list[LinkRef] = []
    code_paths: list[CodePathRef] = []
    in_comment = False
    for lineno, raw_line in _iter_outside_fences(text):
        comment_free, in_comment = _mask_html_comments(raw_line, in_comment)
        masked_line, spans = _extract_code_spans(comment_free)
        ext_ranges: list[tuple[int, int]] = []
        _collect_md_links(masked_line, rel_path, lineno, links, ext_ranges)
        if ref_m := REF_DEF_RE.match(masked_line):
            links.append(LinkRef(rel_path, lineno, ref_m.group(1).strip(), "ref_def"))
        for html_m in HTML_LINK_RE.finditer(masked_line):
            for part in html_m.group(2).strip().split(","):
                if tokens := part.strip().split():
                    links.append(LinkRef(rel_path, lineno, tokens[0], "html"))
        if tier == DocTier.LIVING:
            _extract_code_paths(rel_path, lineno, spans, ext_ranges, top_dirs, code_paths)
    return links, code_paths


def _heading_base(raw_heading: str) -> str:
    s = re.sub(r"`+([^`]+)`+", r"\1", raw_heading)
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"<[^>]+>", "", s).strip().lower()
    return "".join(
        "-" if ch in (" ", "\t") else ch
        for ch in s
        if ch in (" ", "\t", "-", "_") or unicodedata.category(ch)[0] in ("L", "N")
    )


def heading_slugs(md_text: str) -> frozenset[str]:
    slugs: set[str] = set()
    counts: dict[str, int] = {}
    in_comment = False
    for _lineno, raw_line in _iter_outside_fences(md_text):
        for id_m in HTML_ID_RE.finditer(raw_line):
            slugs.add(id_m.group(2).strip().lower())
        comment_free, in_comment = _mask_html_comments(raw_line, in_comment)
        if not comment_free.strip():
            continue
        if m := HEADING_RE.match(comment_free):
            if base := _heading_base(m.group(1)):
                slug = base
                if slug in slugs:
                    idx = counts.get(base, 1)
                    while f"{base}-{idx}" in slugs:
                        idx += 1
                    counts[base] = idx + 1
                    slug = f"{base}-{idx}"
                else:
                    counts.setdefault(base, 1)
                slugs.add(slug)
    return frozenset(slugs)


def _resolve_target(ref: LinkRef) -> tuple[str | None, str | None, str]:
    raw = ref.raw_target.strip()
    path_part, sep, fragment = raw.partition("#")
    path_part = urllib.parse.unquote(path_part.split("?", 1)[0]).strip()
    if not path_part:
        return ref.doc_path, fragment if sep == "#" else None, ""
    doc_dir = posixpath.dirname(ref.doc_path)
    joined = path_part.lstrip("/") if path_part.startswith("/") else (f"{doc_dir}/{path_part}" if doc_dir else path_part)
    norm = posixpath.normpath(joined)
    if (norm in ("", ".") and path_part.startswith("/")) or norm == ".." or norm.startswith("../"):
        return None, None, "链接越出仓库根目录"
    return ("" if norm == "." else norm), (fragment if sep == "#" else None), ""


def _validate_fragment(
    ref: LinkRef, target_rel: str, fragment: str, index: RepoIndex, slug_cache: dict[str, frozenset[str]], line_cache: dict[str, int]
) -> DocDiagnostic | None:
    frag = urllib.parse.unquote(fragment).strip()
    if not frag:
        return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, "空锚点片段")
    if target_rel == "" or target_rel in index.tracked_dirs:
        return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, f"目录目标不支持锚点 #{frag}")
    if line_m := LINE_FRAGMENT_RE.match(frag):
        start_l = int(line_m.group(1))
        end_l = int(line_m.group(2)) if line_m.group(2) else start_l
        if target_rel not in line_cache:
            line_cache[target_rel] = len((index.root / target_rel).read_text(encoding="utf-8", errors="replace").splitlines())
        total = line_cache[target_rel]
        if start_l > total or end_l < start_l or end_l > total:
            return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, f"行号锚点 #{frag} 超出文件范围 (1..{total})")
        return None
    if target_rel.endswith(".md"):
        if target_rel not in slug_cache:
            slug_cache[target_rel] = heading_slugs((index.root / target_rel).read_text(encoding="utf-8"))
        if frag.lower() not in slug_cache[target_rel]:
            return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, f"标题锚点 #{frag} 在 {target_rel} 中不存在")
        return None
    return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, f"非 Markdown 文件不支持锚点 #{frag}（仅支持 #L 行号范围）")


def _validate_link(
    ref: LinkRef, index: RepoIndex, slug_cache: dict[str, frozenset[str]], line_cache: dict[str, int]
) -> DocDiagnostic | None:
    raw = ref.raw_target.strip()
    if not raw or raw == "#":
        return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, "空链接目标")
    if raw.lower().startswith(EXTERNAL_SCHEMES):
        return None
    target_rel, fragment, err = _resolve_target(ref)
    if target_rel is None:
        return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, err)
    if target_rel and target_rel not in index.tracked_files and target_rel not in index.tracked_dirs:
        return DocDiagnostic(ref.doc_path, ref.line, ref.raw_target, f"链接目标不存在或未纳入版本控制 ({target_rel})")
    if fragment is not None:
        return _validate_fragment(ref, target_rel, fragment, index, slug_cache, line_cache)
    return None


def scan_repo_docs(root: Path = ROOT) -> tuple[int, int, int, list[DocDiagnostic]]:
    index = RepoIndex.from_root(root)
    md_files = sorted(f for f in index.tracked_files if f.endswith(".md"))
    slug_cache: dict[str, frozenset[str]] = {}
    line_cache: dict[str, int] = {}
    diags: list[DocDiagnostic] = []
    pending_code: list[CodePathRef] = []
    total_links = total_code_paths = 0
    for rel_path in md_files:
        text = (index.root / rel_path).read_text(encoding="utf-8")
        links, code_refs = parse_markdown_refs(rel_path, text, classify_doc(rel_path), index.tracked_top_dirs)
        total_links += len(links)
        total_code_paths += len(code_refs)
        for link_ref in links:
            if d := _validate_link(link_ref, index, slug_cache, line_cache):
                diags.append(d)
        for ref in code_refs:
            cand = ref.repo_rel_path
            if cand == ".." or cand.startswith("../"):
                diags.append(DocDiagnostic(ref.doc_path, ref.line, ref.span, "行内路径越出仓库根目录"))
            elif any(ch in GLOB_CHARS for ch in cand):
                if not any(fnmatch.fnmatchcase(f, cand) for f in index.tracked_files):
                    diags.append(DocDiagnostic(ref.doc_path, ref.line, ref.span, f"通配路径未匹配任何文件 ({cand})"))
            elif cand not in index.tracked_files and cand not in index.tracked_dirs:
                pending_code.append(ref)
    if pending_code:
        ignored = index.filter_gitignored({r.repo_rel_path for r in pending_code})
        for ref in pending_code:
            if ref.repo_rel_path not in ignored:
                diags.append(DocDiagnostic(ref.doc_path, ref.line, ref.span, f"行内仓库路径不存在 ({ref.repo_rel_path})"))
    diags.sort(key=lambda d: (d.doc_path, d.line, d.target))
    return len(md_files), total_links, total_code_paths, diags


def audit_doc_links(root: Path = ROOT) -> list[DocDiagnostic]:
    return scan_repo_docs(root)[3]


def main() -> None:
    doc_count, link_count, path_count, diags = scan_repo_docs(ROOT)
    if diags:
        print("❌ Markdown 文档链接与仓库路径引用检查未通过：", file=sys.stderr)
        for diag in diags:
            print(f"  {diag.format()}", file=sys.stderr)
        raise SystemExit(1)
    print(f"✅ Markdown 文档链接与仓库路径引用检查通过（{doc_count} 篇文档，{link_count} 处链接，{path_count} 处路径）。")


if __name__ == "__main__":
    main()
