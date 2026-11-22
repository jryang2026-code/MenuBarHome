#!/usr/bin/env python3
"""Evaluate PR readiness from captured `gh` JSON payloads for scripts/pr-ready.sh."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
import time
from typing import Any

ZERO_CHECK_GRACE_POLLS = 2
CODEX_TRIGGER_RE = re.compile(r"@codex\s+(?:security\s+)?review\b", re.IGNORECASE)
PR_OPEN_COMMIT_SKEW_SECONDS = 15


def flatten_pages(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, list):
        raise SystemExit("GitHub 分页结果不是数组")
    items: list[dict[str, Any]] = []
    for page in payload:
        if isinstance(page, list):
            items.extend(entry for entry in page if isinstance(entry, dict))
        elif isinstance(page, dict):
            items.append(page)
    return items


def parse_ts(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def review_states(comments: list[dict[str, Any]]) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    """Return list of (code_review_obj, source_issue_comment) for codex-review-state:v1 blocks."""
    found: list[tuple[dict[str, Any], dict[str, Any]]] = []
    marker = "codex-review-state:v1"
    for comment in comments:
        user = (comment.get("user") or {}).get("login") or ""
        if user != "chatgpt-codex-connector[bot]":
            continue
        body = comment.get("body") or ""
        idx = body.find(marker)
        if idx < 0:
            continue
        start = body.find("{", idx)
        if start < 0:
            continue
        try:
            obj, _ = json.JSONDecoder().raw_decode(body[start:])
        except json.JSONDecodeError:
            continue
        code = obj.get("code_review")
        if isinstance(code, dict) and code.get("commit_sha"):
            found.append((code, comment))
    return found


def collect_completed_codex_shas(
    states: list[tuple[dict[str, Any], dict[str, Any]]],
    pr_reviews: list[dict[str, Any]],
    inline_comments: list[dict[str, Any]],
) -> set[str]:
    """Count distinct commit SHAs reviewed by Codex across all surfaces (even when summary edits in place)."""
    shas: set[str] = set()
    for code, _ in states:
        sha = code.get("commit_sha")
        if isinstance(sha, str) and sha and code.get("status") == "completed":
            shas.add(sha)
    for review in pr_reviews:
        user = (review.get("user") or {}).get("login") or ""
        if not user.startswith("chatgpt-codex"):
            continue
        state = (review.get("state") or "").upper()
        sha = review.get("commit_id")
        if state and state != "PENDING" and isinstance(sha, str) and sha:
            shas.add(sha)
    for comment in inline_comments:
        user = (comment.get("user") or {}).get("login") or ""
        if not user.startswith("chatgpt-codex"):
            continue
        sha = comment.get("original_commit_id")
        if isinstance(sha, str) and sha:
            shas.add(sha)
    return shas


def codex_unavailable_after_last_state(comments: list[dict[str, Any]]) -> bool:
    last_state_idx = -1
    for idx, comment in enumerate(comments):
        user = (comment.get("user") or {}).get("login") or ""
        body = comment.get("body") or ""
        if user == "chatgpt-codex-connector[bot]" and "codex-review-state:v1" in body:
            last_state_idx = idx
    for comment in comments[last_state_idx + 1:]:
        user = (comment.get("user") or {}).get("login") or ""
        if user != "chatgpt-codex-connector[bot]":
            continue
        lower = (comment.get("body") or "").lower()
        if (
            "usage limits for code reviews" in lower
            or "couldn't complete this review" in lower
            or "couldn\u2019t complete this review" in lower
        ):
            return True
    return False


def clean_body(body: str | None) -> str:
    text = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    return text.strip()


def parse_checks(raw: str) -> dict[str, Any] | None:
    if not raw.strip():
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, list):
        return None

    total = 0
    passed = 0
    skipped = 0
    failed_rows: list[str] = []
    pending_rows: list[str] = []

    for item in data:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or ""
        bucket = item.get("bucket") or ""
        if not name:
            continue
        total += 1
        if bucket == "pass":
            passed += 1
        elif bucket == "skipping":
            skipped += 1
        elif bucket in ("fail", "cancel"):
            failed_rows.append(f"  {name}: {bucket}")
        elif not name.startswith("Cursor "):
            pending_rows.append(f"  {name}: {bucket or 'pending'}")

    return {
        "total": total,
        "passed": passed,
        "skipped": skipped,
        "failed_rows": failed_rows,
        "pending_rows": pending_rows,
    }


def load_json_file(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    raw = path.read_text(encoding="utf-8", errors="replace").strip()
    if not raw:
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return default


def load_wait_state(state_path: Path | None, head: str) -> dict[str, Any]:
    fresh = {"head": head, "zero_check_polls": 0, "ci_settled_at": None}
    if not state_path or not state_path.exists():
        return fresh
    data = load_json_file(state_path, {})
    if not isinstance(data, dict) or data.get("head") != head:
        return fresh
    return {
        "head": head,
        "zero_check_polls": int(data.get("zero_check_polls") or 0),
        "ci_settled_at": data.get("ci_settled_at"),
    }


def save_wait_state(state_path: Path | None, state: dict[str, Any]) -> None:
    if not state_path:
        return
    state_path.write_text(json.dumps(state), encoding="utf-8")


def codex_review_activity(
    *,
    head: str,
    meta: dict[str, Any],
    issue_comments: list[dict[str, Any]],
    states: list[tuple[dict[str, Any], dict[str, Any]]],
    pr_reviews: list[dict[str, Any]],
    latest_for_head: dict[str, Any] | None,
    completed_rounds: int,
) -> tuple[bool, bool, bool]:
    """Return (codex_in_progress, codex_triggered_by_comment, initial_open_auto_trigger)."""
    codex_in_progress = bool(
        latest_for_head is not None
        and latest_for_head.get("status") not in ("completed", "failed")
    )

    trigger_ts: datetime | None = None
    for comment in issue_comments:
        user = (comment.get("user") or {}).get("login") or ""
        if user.endswith("[bot]") or user.startswith("chatgpt-codex"):
            continue
        body = comment.get("body") or ""
        if CODEX_TRIGGER_RE.search(body):
            ts = parse_ts(comment.get("created_at") or comment.get("updated_at"))
            if ts and (trigger_ts is None or ts > trigger_ts):
                trigger_ts = ts

    done_timestamps: list[datetime] = []
    for code, comment in states:
        if code.get("status") == "completed":
            ts = parse_ts(comment.get("updated_at") or comment.get("created_at"))
            if ts:
                done_timestamps.append(ts)
    for review in pr_reviews:
        user = (review.get("user") or {}).get("login") or ""
        if user.startswith("chatgpt-codex") and (review.get("state") or "").upper() != "PENDING":
            ts = parse_ts(review.get("submitted_at"))
            if ts:
                done_timestamps.append(ts)
    latest_codex_done_ts = max(done_timestamps) if done_timestamps else None

    commits = meta.get("commits") or []
    head_committed_at: datetime | None = None
    if isinstance(commits, list) and commits:
        last_commit = commits[-1] if isinstance(commits[-1], dict) else {}
        head_committed_at = parse_ts(last_commit.get("committedDate") or last_commit.get("authoredDate"))
    pr_created_at = parse_ts(meta.get("createdAt"))

    codex_triggered_by_comment = False
    if trigger_ts is not None:
        after_last_review = latest_codex_done_ts is None or trigger_ts > latest_codex_done_ts
        after_head_commit = (
            head_committed_at is None
            or trigger_ts.timestamp() >= head_committed_at.timestamp() - PR_OPEN_COMMIT_SKEW_SECONDS
        )
        codex_triggered_by_comment = after_last_review and after_head_commit

    is_draft = bool(meta.get("isDraft"))
    commits_added_after_open = bool(
        pr_created_at is not None
        and head_committed_at is not None
        and head_committed_at.timestamp() > pr_created_at.timestamp() + PR_OPEN_COMMIT_SKEW_SECONDS
    )
    initial_open_auto_trigger = (
        not is_draft
        and completed_rounds == 0
        and not states
        and not any(((r.get("user") or {}).get("login") or "").startswith("chatgpt-codex") for r in pr_reviews)
        and not commits_added_after_open
    )
    return codex_in_progress, codex_triggered_by_comment, initial_open_auto_trigger


def evaluate_dir(
    tmp: Path,
    *,
    wait_mode: bool,
    max_codex_rounds: int,
    codex_timeout: float,
    no_wait_codex: bool,
    expect_head: str,
    state_file: Path | None,
    now: float,
) -> int:
    meta = load_json_file(tmp / "meta.json", {})
    head = meta["headRefOid"]
    merge = meta.get("mergeStateStatus") or "UNKNOWN"
    checks_status = int((tmp / "checks.status").read_text(encoding="utf-8").strip() or "0")
    checks_raw = (tmp / "checks.json").read_text(encoding="utf-8", errors="replace")
    checks_err = (tmp / "checks.err").read_text(encoding="utf-8", errors="replace").strip()
    issue_pages = load_json_file(tmp / "issues.json", [])
    review_pages = load_json_file(tmp / "reviews.json", [])
    pr_review_pages = load_json_file(tmp / "pr_reviews.json", [])

    print(f"head {head} {merge}")

    if expect_head and not head.lower().startswith(expect_head.strip().lower()):
        print(f"head: waiting for {expect_head} (currently {head[:10]})")
        if wait_mode:
            return 10

    stale = load_json_file(tmp / "stale.json", {})
    behind_by = int((stale.get("ahead_by") if isinstance(stale, dict) else 0) or 0)
    pr_files = {f.get("path") for f in meta.get("files") or [] if isinstance(f, dict)}
    stale_overlap = sorted(pr_files & set((stale.get("files") if isinstance(stale, dict) else None) or []))
    if behind_by:
        line = f"base: behind {meta.get('baseRefName')} by {behind_by} commits"
        if stale_overlap:
            shown = ", ".join(stale_overlap[:5]) + (" ..." if len(stale_overlap) > 5 else "")
            line += (
                f"; {len(stale_overlap)} overlapping files ({shown}) -> "
                f"git merge origin/{meta.get('baseRefName')} and retest"
            )
        print(line)

    wait_state = load_wait_state(state_file, head)
    parsed = parse_checks(checks_raw)
    checks_error = False
    checks_pending = False
    checks_failed = False
    no_checks_reported_err = bool(re.search(r"no checks reported", checks_err, re.I))

    if parsed is None:
        if checks_status == 8:
            print("checks: pending")
            checks_pending = True
        elif checks_status == 0 or no_checks_reported_err:
            wait_state["zero_check_polls"] += 1
            print("checks: none (0 reported)")
            if wait_mode and wait_state["zero_check_polls"] <= ZERO_CHECK_GRACE_POLLS:
                checks_pending = True
        else:
            print("checks: error")
            if checks_err:
                print(checks_err.splitlines()[-1])
            checks_error = True
    else:
        total = parsed["total"]
        failed_rows = parsed["failed_rows"]
        pending_rows = parsed["pending_rows"]
        if failed_rows or pending_rows:
            print("checks:")
            print("\n".join(failed_rows + pending_rows))
            checks_failed = bool(failed_rows)
            checks_pending = bool(pending_rows)
        elif total == 0:
            if checks_status == 8:
                print("checks: pending")
                checks_pending = True
            else:
                wait_state["zero_check_polls"] += 1
                print("checks: none (0 reported)")
                if wait_mode and wait_state["zero_check_polls"] <= ZERO_CHECK_GRACE_POLLS:
                    checks_pending = True
        else:
            wait_state["zero_check_polls"] = 0
            print(f"checks: passed ({parsed['passed']} passed, {parsed['skipped']} skipped)")

    issue_comments = flatten_pages(issue_pages)
    inline_comments = flatten_pages(review_pages)
    pr_reviews = flatten_pages(pr_review_pages)
    states = review_states(issue_comments)

    matched = [code for code, _ in states if code.get("commit_sha") == head]
    latest_for_head = matched[-1] if matched else None
    codex_quota_blocked = False
    if latest_for_head is not None:
        print("codex review: " + json.dumps(latest_for_head, separators=(",", ":"), ensure_ascii=False))
    elif codex_unavailable_after_last_state(issue_comments):
        codex_quota_blocked = True
        print(f"codex review: unavailable (usage limit) for {head}")
    elif states:
        last = states[-1][0]
        print(f"codex review: none for {head} (latest {last.get('commit_sha')} {last.get('status')})")
    else:
        print(f"codex review: none for {head}")

    completed_shas = collect_completed_codex_shas(states, pr_reviews, inline_comments)
    completed_rounds = len(completed_shas)
    codex_cap_reached = max_codex_rounds > 0 and completed_rounds >= max_codex_rounds
    if codex_cap_reached and latest_for_head is None:
        print(f"codex rounds: {completed_rounds}/{max_codex_rounds} (cap reached)")

    inlines: list[tuple[str | None, int | None, str]] = []
    for comment in inline_comments:
        user = (comment.get("user") or {}).get("login") or ""
        if not user.startswith("chatgpt-codex"):
            continue
        if comment.get("original_commit_id") != head:
            continue
        line_no = comment.get("line")
        if line_no is None:
            line_no = comment.get("original_line")
        inlines.append((comment.get("path"), line_no, clean_body(comment.get("body"))))

    if not inlines:
        print("codex inline: none")
    else:
        print("codex inline:")
        for index, (path, line_no, body) in enumerate(inlines):
            if index:
                print()
            print(f"* {path} {line_no}")
            if body:
                print(body[:900])

    if checks_error:
        save_wait_state(state_file, wait_state)
        if wait_mode and re.search(r"HTTP 5\d\d|timeout|EOF|connection reset", checks_err, re.I):
            return 10
        return 1

    if not wait_mode:
        save_wait_state(state_file, wait_state)
        return 0

    latest_failed_empty = bool(
        latest_for_head and latest_for_head.get("status") == "failed" and not inlines
    )
    if latest_for_head and latest_for_head.get("has_unresolved_findings") is False:
        has_findings = False
    elif latest_failed_empty:
        has_findings = False
    else:
        has_findings = bool(inlines) or bool(
            latest_for_head and latest_for_head.get("has_unresolved_findings") is True
        )

    if checks_failed or has_findings or merge in ("DIRTY", "CONFLICTING", "CLOSED"):
        save_wait_state(state_file, wait_state)
        return 1

    codex_done = (
        no_wait_codex
        or bool(
            latest_for_head
            and latest_for_head.get("status") == "completed"
            and latest_for_head.get("has_unresolved_findings") is False
        )
        or latest_failed_empty
        or codex_quota_blocked
        or (codex_cap_reached and not has_findings)
    )

    if merge == "CLEAN" and not checks_pending and codex_done:
        save_wait_state(state_file, wait_state)
        return 0

    if not checks_pending and not codex_done and merge not in ("UNKNOWN", "DIRTY", "CONFLICTING", "CLOSED"):
        codex_in_progress, codex_triggered_by_comment, initial_open_auto_trigger = codex_review_activity(
            head=head,
            meta=meta,
            issue_comments=issue_comments,
            states=states,
            pr_reviews=pr_reviews,
            latest_for_head=latest_for_head,
            completed_rounds=completed_rounds,
        )
        if not (codex_in_progress or codex_triggered_by_comment or initial_open_auto_trigger):
            print(
                f"wake: ci_passed_codex_not_triggered "
                f"(round {completed_rounds}/{max_codex_rounds or '∞'}; "
                f'subsequent pushes need "@codex review" or local codex review)'
            )
            save_wait_state(state_file, wait_state)
            return 3

        if wait_state["ci_settled_at"] is None:
            wait_state["ci_settled_at"] = now
        if codex_timeout > 0 and (now - float(wait_state["ci_settled_at"])) >= codex_timeout:
            print(
                f"wake: codex_timeout_after_ci ({int(codex_timeout)}s after CI passed; "
                f"fallback to local codex review)"
            )
            save_wait_state(state_file, wait_state)
            return 3

    save_wait_state(state_file, wait_state)
    return 10


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Evaluate captured PR state for scripts/pr-ready.sh")
    parser.add_argument("tmp_dir", type=Path)
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--max-codex-rounds", type=int, default=0)
    parser.add_argument("--codex-timeout", type=float, default=480.0)
    parser.add_argument("--no-wait-codex", action="store_true")
    parser.add_argument("--expect-head", default="")
    parser.add_argument("--state-file", type=Path, default=None)
    parser.add_argument("--now", type=float, default=None)
    args = parser.parse_args(argv)

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")

    return evaluate_dir(
        args.tmp_dir,
        wait_mode=args.wait,
        max_codex_rounds=args.max_codex_rounds,
        codex_timeout=args.codex_timeout,
        no_wait_codex=args.no_wait_codex,
        expect_head=args.expect_head,
        state_file=args.state_file,
        now=time.time() if args.now is None else args.now,
    )


if __name__ == "__main__":
    raise SystemExit(main())
