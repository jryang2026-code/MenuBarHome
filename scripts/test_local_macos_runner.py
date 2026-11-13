#!/usr/bin/env python3
"""Verify the controller's failure cleanup without starting or registering a runner."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "local_runner", Path(__file__).with_name("local_macos_runner.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CleanupTests(unittest.TestCase):
    def test_stale_runner_is_removed_after_disposable_vm_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            state.write_text(json.dumps({"runner_id": 123}))
            calls = []
            with patch.object(runner, "ROOT", root), \
                 patch.object(runner.subprocess, "run",
                              side_effect=lambda args, **kw: calls.append(args)), \
                 patch.object(runner, "api",
                              side_effect=lambda *a, **kw: calls.append(a)):
                runner.cleanup()
            self.assertFalse(state.exists())
            self.assertEqual(calls, [
                ["tart", "stop", "menubarhome-ci-job"],
                ["tart", "delete", "menubarhome-ci-job"],
                ("actions/runners/123",),
            ])

    def test_failed_deregistration_keeps_state_for_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            state.write_text(json.dumps({"runner_id": 123}))
            failure = subprocess.CalledProcessError(
                1, ["gh", "api"], stderr="HTTP 503")
            with patch.object(runner, "ROOT", root), \
                 patch.object(runner.subprocess, "run"), \
                 patch.object(runner, "api", side_effect=failure):
                with self.assertRaises(subprocess.CalledProcessError):
                    runner.cleanup()
            self.assertTrue(state.exists())

    def test_low_disk_space_never_clones_or_registers(self):
        class FullDisk:
            f_bavail = 1
            f_frsize = 4096
        with patch.object(runner, "cleanup"), \
             patch.object(runner.os, "statvfs", return_value=FullDisk()), \
             patch.object(runner, "command") as command, \
             patch.object(runner, "api") as api:
            with self.assertRaisesRegex(RuntimeError, "25 GiB"):
                runner.once()
            command.assert_not_called()
            api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
