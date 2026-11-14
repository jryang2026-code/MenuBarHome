#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parent / "check_windows_geometry.py"
SPEC = importlib.util.spec_from_file_location("check_windows_geometry", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
geom = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = geom
SPEC.loader.exec_module(geom)

REPO_FILES = (
    "windows/src-tauri/tauri.conf.json",
    "windows/src-tauri/src/window.rs",
    "windows/src/ui/panelPrefs.ts",
    "windows/src/ui/styles.css",
)


def copy_repo_fixture(tmp_dir: str) -> Path:
    root = Path(tmp_dir)
    for rel in REPO_FILES:
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(geom.ROOT / rel, dst)
    return root


class WindowsGeometryContractTests(unittest.TestCase):
    def test_real_repository_passes_geometry_and_shadow_contract(self) -> None:
        c = geom.load_contract(geom.ROOT)
        self.assertEqual((c.tauri_width, c.tauri_height, c.tauri_transparent, c.tauri_shadow), (412.0, 680.0, True, False))
        self.assertEqual((c.rust_main_width, c.rust_padding, c.css_panel_inset, c.css_popover_width, c.css_preview_height), (380.0, 16.0, 16.0, 380.0, 648.0))
        self.assertEqual(c.panel_heights, {"compact": 580.0, "standard": 680.0, "tall": 780.0, "max": 0.0})
        self.assertEqual(geom.validate_contract(c), [])

    def test_rejects_double_padding_in_set_panel_height(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = copy_repo_fixture(tmp)
            win_rs = root / "windows/src-tauri/src/window.rs"
            win_rs.write_text(
                win_rs.read_text(encoding="utf-8").replace(
                    "let target_h = clamp_outer_panel_height(height, work.height as f64 / scale);",
                    "let target_h = if height <= 0.0 { 680.0 } else { (height + PANEL_PADDING * 2.0).min(680.0) };",
                ),
                encoding="utf-8",
            )
            errors = geom.check_repo(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("clamp_outer_panel_height", errors[0])

    def test_rejects_shadow_layer_exceeding_panel_inset(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = copy_repo_fixture(tmp)
            styles = root / "windows/src/ui/styles.css"
            styles.write_text(styles.read_text(encoding="utf-8").replace("0 6px 14px rgba(0, 0, 0, 0.34)", "0 14px 32px rgba(0, 0, 0, 0.42)"), encoding="utf-8")
            errors = geom.check_repo(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("bottom=30px", errors[0])

    def test_rejects_width_drift_between_tauri_rust_and_css(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = copy_repo_fixture(tmp)
            styles = root / "windows/src/ui/styles.css"
            styles.write_text(styles.read_text(encoding="utf-8").replace("width: min(100%, 380px);", "width: min(100%, 360px);"), encoding="utf-8")
            errors = geom.check_repo(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("412", errors[0])
            self.assertIn("392", errors[0])

    def test_rejects_standard_height_drift_from_tauri_conf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = copy_repo_fixture(tmp)
            prefs = root / "windows/src/ui/panelPrefs.ts"
            prefs.write_text(prefs.read_text(encoding="utf-8").replace("px: 680", "px: 660"), encoding="utf-8")
            errors = geom.check_repo(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("PANEL_HEIGHTS.standard", errors[0])

    def test_rejects_native_window_shadow_enabled_in_tauri_conf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = copy_repo_fixture(tmp)
            tauri_conf = root / "windows/src-tauri/tauri.conf.json"
            tauri_conf.write_text(tauri_conf.read_text(encoding="utf-8").replace('"shadow": false', '"shadow": true'), encoding="utf-8")
            errors = geom.check_repo(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("shadow=false", errors[0])


if __name__ == "__main__":
    unittest.main()
