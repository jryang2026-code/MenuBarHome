#!/usr/bin/env python3
"""`scripts/check_windows_test_timeouts.py` 的回归测试：只用合成 TS 源码，不打开真实应用。

运行：python3 scripts/test_check_windows_test_timeouts.py
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import sys
import unittest

# Loading the checker here would otherwise drop a __pycache__ entry next to it.
sys.dont_write_bytecode = True

_loader = importlib.machinery.SourceFileLoader("check_windows_test_timeouts", "scripts/check_windows_test_timeouts.py")
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
assert _spec is not None and _spec.loader is not None
checker = importlib.util.module_from_spec(_spec)
sys.modules[_loader.name] = checker
_spec.loader.exec_module(checker)

LABEL = "windows/tests/synthetic.test.ts"


def errors_of(src: str) -> list[str]:
    return checker.scan_source(src, LABEL)


class WaitForTimeoutScanTest(unittest.TestCase):
    def test_single_line_low_timeout_fails_with_fix_hint(self) -> None:
        errors = errors_of("await waitFor(() => expiredCount === 1, 500);\n")
        self.assertEqual(len(errors), 1)
        self.assertIn("windows/tests/synthetic.test.ts:1", errors[0])
        self.assertIn("500ms", errors[0])
        self.assertIn("延迟 promise 或信号", errors[0])
        self.assertIn("2000ms", errors[0])

    def test_multiline_call_reports_value_line(self) -> None:
        src = (
            "await waitFor(\n"
            "  () =>\n"
            "    app?.cameraLive.activeLiveCameraId === 'cam-b' &&\n"
            "    app.cameraLive.liveCameraStreamURL === 'cam_mjpeg_cam-b',\n"
            "  1_000,\n"
            ");\n"
        )
        errors = errors_of(src)
        self.assertEqual(len(errors), 1)
        self.assertIn("windows/tests/synthetic.test.ts:5", errors[0])
        self.assertIn("1_000ms", errors[0])

    def test_underscore_separator_is_handled(self) -> None:
        errors = errors_of("await waitFor(() => app?.ready, 1_000);\n")
        self.assertEqual(len(errors), 1)
        self.assertIn("1_000ms", errors[0])

    def test_exactly_2000_passes(self) -> None:
        self.assertEqual(errors_of("await waitFor(() => app?.ready, 2_000);\n"), [])
        self.assertEqual(errors_of("await waitFor(() => app?.ready, 2000);\n"), [])

    def test_string_message_second_argument_passes(self) -> None:
        src = (
            "async function waitFor(ready: () => boolean, message: string): Promise<void> {}\n"
            "await waitFor(() => !app.isSyncingCloud && app.replyBanner !== null, 'the refresh never settled');\n"
        )
        self.assertEqual(errors_of(src), [])

    def test_low_helper_default_fails(self) -> None:
        errors = errors_of("async function waitFor(predicate: () => boolean, timeoutMs = 500): Promise<void> {}\n")
        self.assertEqual(len(errors), 1)
        self.assertIn("windows/tests/synthetic.test.ts:1", errors[0])
        self.assertIn("timeoutMs", errors[0])
        self.assertIn("500ms", errors[0])

    def test_default_2000_helper_passes(self) -> None:
        src = "async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {}\n"
        self.assertEqual(errors_of(src), [])

    def test_commas_inside_nested_calls_do_not_split_args(self) -> None:
        errors = errors_of("await waitFor(() => byId('a,b').count(1, 2) === 3, 500);\n")
        self.assertEqual(len(errors), 1)
        self.assertIn("500ms", errors[0])

    def test_string_and_comment_content_is_ignored(self) -> None:
        src = (
            "// waitFor(() => ready, 100) in a comment\n"
            "const note = 'waitFor(() => ready, 100)';\n"
            "/* waitFor(() => ready, 100) */\n"
            "await waitFor(() => ready, 2_000);\n"
        )
        self.assertEqual(errors_of(src), [])

    def test_waitfor_suffix_names_do_not_match(self) -> None:
        self.assertEqual(errors_of("await waitForSignal(() => ready, 100);\n"), [])

    def test_real_repo_tree_passes(self) -> None:
        # 当前仓库必须全绿（violation 已在 w2UndoGrokCam.test.ts 修掉）。
        self.assertEqual(checker.check_tree(), [])


if __name__ == "__main__":
    unittest.main()
