#!/usr/bin/env python3
"""Unit tests for scripts/pr_ready_eval.py and scripts/pr-ready.sh monitor behavior."""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_ready_eval  # noqa: E402


def _make_codex_state_comment(
    commit_sha: str,
    *,
    status: str = "completed",
    has_findings: bool = False,
    created_at: str = "2026-11-22T02:03:04Z",
    updated_at: str = "2026-11-22T02:06:51Z",
) -> dict:
    payload = {
        "code_review": {
            "commit_sha": commit_sha,
            "has_any_findings": has_findings,
            "has_unresolved_findings": has_findings,
            "status": status,
        }
    }
    return {
        "user": {"login": "chatgpt-codex-connector[bot]"},
        "created_at": created_at,
        "updated_at": updated_at,
        "body": f"<!-- codex-review-state:v1 {json.dumps(payload)} -->\nSummary",
    }


def _populate_tmp(
    root: Path,
    *,
    head: str = "bd1026d1a3de21988efdf75f3ef9fd4d97cd7f24",
    merge: str = "CLEAN",
    created_at: str = "2026-11-22T02:02:52Z",
    is_draft: bool = False,
    commits: list[dict] | None = None,
    checks: list[dict] | None = None,
    checks_status: int = 0,
    checks_err: str = "",
    issues: list[dict] | None = None,
    inline_comments: list[dict] | None = None,
    pr_reviews: list[dict] | None = None,
) -> Path:
    meta = {
        "headRefOid": head,
        "mergeStateStatus": merge,
        "baseRefName": "main",
        "createdAt": created_at,
        "isDraft": is_draft,
        "files": [{"path": "windows/src/ui/app.ts"}],
        "commits": commits
        if commits is not None
        else [{"oid": head, "committedDate": "2026-11-22T02:02:15Z"}],
    }
    (root / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    (root / "checks.json").write_text(
        "" if checks is None else json.dumps(checks), encoding="utf-8"
    )
    (root / "checks.status").write_text(f"{checks_status}\n", encoding="utf-8")
    (root / "checks.err").write_text(checks_err, encoding="utf-8")
    (root / "issues.json").write_text(json.dumps([issues or []]), encoding="utf-8")
    (root / "reviews.json").write_text(
        json.dumps([inline_comments or []]), encoding="utf-8"
    )
    (root / "pr_reviews.json").write_text(
        json.dumps([pr_reviews or []]), encoding="utf-8"
    )
    (root / "stale.json").write_text("{}", encoding="utf-8")
    return root


def _eval(
    tmp: Path,
    *,
    wait_mode: bool = True,
    max_codex_rounds: int = 2,
    codex_timeout: float = 480.0,
    no_wait_codex: bool = False,
    expect_head: str = "",
    state_file: Path | None = None,
    now: float = 1000.0,
) -> tuple[int, str]:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = pr_ready_eval.evaluate_dir(
            tmp,
            wait_mode=wait_mode,
            max_codex_rounds=max_codex_rounds,
            codex_timeout=codex_timeout,
            no_wait_codex=no_wait_codex,
            expect_head=expect_head,
            state_file=state_file,
            now=now,
        )
    return code, buf.getvalue()


class PrReadyEvalTests(unittest.TestCase):
    def test_in_place_edited_codex_summary_plus_reviews_reaches_cap_and_exits_0(self) -> None:
        """Reproduces PR #359 bd1026d1 hang: bot overwrote its single issue comment in place."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            head = "bd1026d1a3de21988efdf75f3ef9fd4d97cd7f24"
            _populate_tmp(
                root,
                head=head,
                commits=[
                    {"oid": "0d17d676", "committedDate": "2026-11-22T02:02:15Z"},
                    {"oid": "7513d18d", "committedDate": "2026-11-22T02:17:01Z"},
                    {"oid": head, "committedDate": "2026-11-22T03:04:34Z"},
                ],
                checks=[
                    {"name": "windows-core", "state": "SUCCESS", "bucket": "pass"},
                    {"name": "macos-test", "state": "SKIPPED", "bucket": "skipping"},
                ],
                # Single summary comment edited in place now references only round 2 SHA.
                issues=[_make_codex_state_comment("7513d18d3931a65679dfd206632ec5eba1774f3a", has_findings=True)],
                pr_reviews=[
                    {
                        "user": {"login": "chatgpt-codex-connector[bot]"},
                        "state": "COMMENTED",
                        "commit_id": "0d17d67623954ae80b2f0a864f36cfb62bf42c1e",
                        "submitted_at": "2026-11-22T02:06:48Z",
                    },
                    {
                        "user": {"login": "chatgpt-codex-connector[bot]"},
                        "state": "COMMENTED",
                        "commit_id": "7513d18d3931a65679dfd206632ec5eba1774f3a",
                        "submitted_at": "2026-11-22T02:55:24Z",
                    },
                ],
            )
            code, out = _eval(root, max_codex_rounds=2, state_file=root / "state.json")
            self.assertEqual(code, 0)
            self.assertIn("checks: passed (1 passed, 1 skipped)", out)
            self.assertIn("codex rounds: 2/2 (cap reached)", out)

    def test_push_2_without_codex_trigger_wakes_immediately_when_ci_passes(self) -> None:
        """Reproduces PR #359 7513d18d 30-min timeout: push #2 CI green, no @codex review comment."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            head = "7513d18d3931a65679dfd206632ec5eba1774f3a"
            _populate_tmp(
                root,
                head=head,
                created_at="2026-11-22T02:02:52Z",
                commits=[
                    {"oid": "0d17d67623954ae80b2f0a864f36cfb62bf42c1e", "committedDate": "2026-11-22T02:02:15Z"},
                    {"oid": head, "committedDate": "2026-11-22T02:17:01Z"},
                ],
                checks=[{"name": "ci", "state": "SUCCESS", "bucket": "pass"}],
                issues=[_make_codex_state_comment("0d17d67623954ae80b2f0a864f36cfb62bf42c1e", has_findings=True)],
            )
            code, out = _eval(root, max_codex_rounds=2, state_file=root / "state.json")
            self.assertEqual(code, 3)
            self.assertIn("wake: ci_passed_codex_not_triggered", out)
            self.assertIn("@codex review", out)

    def test_push_2_with_codex_trigger_waits_then_times_out_after_ci(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            state_file = root / "state.json"
            head = "7513d18d3931a65679dfd206632ec5eba1774f3a"
            _populate_tmp(
                root,
                head=head,
                created_at="2026-11-22T02:02:52Z",
                commits=[
                    {"oid": "0d17d676", "committedDate": "2026-11-22T02:02:15Z"},
                    {"oid": head, "committedDate": "2026-11-22T02:17:01Z"},
                ],
                checks=[{"name": "ci", "state": "SUCCESS", "bucket": "pass"}],
                issues=[
                    _make_codex_state_comment("0d17d676", has_findings=True, updated_at="2026-11-22T02:06:51Z"),
                    {
                        "user": {"login": "jryang2026-code"},
                        "created_at": "2026-11-22T02:48:51Z",
                        "body": "@codex review",
                    },
                ],
            )
            code1, _ = _eval(root, max_codex_rounds=2, codex_timeout=480, state_file=state_file, now=1000.0)
            self.assertEqual(code1, 10)

            code2, _ = _eval(root, max_codex_rounds=2, codex_timeout=480, state_file=state_file, now=1200.0)
            self.assertEqual(code2, 10)

            code3, out3 = _eval(root, max_codex_rounds=2, codex_timeout=480, state_file=state_file, now=1480.0)
            self.assertEqual(code3, 3)
            self.assertIn("wake: codex_timeout_after_ci", out3)

    def test_initial_pr_open_waits_for_auto_codex_up_to_codex_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            state_file = root / "state.json"
            head = "0d17d67623954ae80b2f0a864f36cfb62bf42c1e"
            _populate_tmp(
                root,
                head=head,
                created_at="2026-11-22T02:02:52Z",
                commits=[
                    {"oid": "pre1", "committedDate": "2026-11-22T02:01:00Z"},
                    {"oid": head, "committedDate": "2026-11-22T02:02:15Z"},
                ],
                checks=[{"name": "ci", "state": "SUCCESS", "bucket": "pass"}],
                issues=[],
            )
            code1, _ = _eval(root, max_codex_rounds=2, codex_timeout=300, state_file=state_file, now=100.0)
            self.assertEqual(code1, 10)
            code2, out2 = _eval(root, max_codex_rounds=2, codex_timeout=300, state_file=state_file, now=400.0)
            self.assertEqual(code2, 3)
            self.assertIn("wake: codex_timeout_after_ci", out2)

    def test_checks_reporting_cursor_ignore_and_zero_check_grace(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            state_file = root / "state.json"
            head = "abc1234567"
            # First 2 polls with 0 reported checks wait cleanly.
            _populate_tmp(
                root,
                head=head,
                checks=None,
                checks_status=1,
                checks_err="no checks reported on the 'feat' branch",
            )
            code1, out1 = _eval(root, no_wait_codex=True, state_file=state_file)
            self.assertEqual(code1, 10)
            self.assertIn("checks: none (0 reported)", out1)
            code2, _ = _eval(root, no_wait_codex=True, state_file=state_file)
            self.assertEqual(code2, 10)
            code3, _ = _eval(root, no_wait_codex=True, state_file=state_file)
            self.assertEqual(code3, 0)

            # Pending Cursor check does not block passing CI checks.
            _populate_tmp(
                root,
                head=head,
                checks=[
                    {"name": "Cursor Bugbot", "state": "PENDING", "bucket": "pending"},
                    {"name": "ci", "state": "SUCCESS", "bucket": "pass"},
                    {"name": "macos-test", "state": "SKIPPED", "bucket": "skipping"},
                ],
                checks_status=8,
            )
            code4, out4 = _eval(root, no_wait_codex=True, state_file=state_file)
            self.assertEqual(code4, 0)
            self.assertIn("checks: passed (1 passed, 1 skipped)", out4)

    def test_expect_head_waits_for_push_to_register(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _populate_tmp(
                root,
                head="oldsha1111",
                checks=[{"name": "ci", "state": "SUCCESS", "bucket": "pass"}],
            )
            code1, out1 = _eval(root, no_wait_codex=True, expect_head="newsha2222")
            self.assertEqual(code1, 10)
            self.assertIn("head: waiting for newsha2222", out1)

            _populate_tmp(
                root,
                head="newsha22223333",
                checks=[{"name": "ci", "state": "SUCCESS", "bucket": "pass"}],
            )
            code2, _ = _eval(root, no_wait_codex=True, expect_head="newsha2222")
            self.assertEqual(code2, 0)


if __name__ == "__main__":
    unittest.main()
