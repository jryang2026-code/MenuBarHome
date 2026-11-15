#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class ShadowLayer:
    dx: float
    dy: float
    blur: float
    spread: float = 0.0

    def edge_reaches(self) -> dict[str, float]:
        half = self.blur / 2.0
        return {"left": max(0.0, -self.dx) + self.spread + half, "right": max(0.0, self.dx) + self.spread + half, "top": max(0.0, -self.dy) + self.spread + half, "bottom": max(0.0, self.dy) + self.spread + half}


@dataclass(frozen=True)
class FlyoutGeometryContract:
    tauri_width: float
    tauri_height: float
    tauri_transparent: bool
    tauri_shadow: bool
    rust_main_width: float
    rust_classic_main_width: float
    rust_padding: float
    set_panel_height_uses_helper: bool
    set_panel_height_adds_padding: bool
    set_panel_geometry_uses_helper: bool
    set_panel_geometry_adds_padding: bool
    panel_heights: dict[str, float]
    ts_fluent_main_width: float
    ts_fluent_window_width: float
    ts_classic_main_width: float
    ts_classic_window_width: float
    css_panel_inset: float
    css_popover_width: float
    css_classic_popover_width: float
    css_preview_height: float
    dark_shadows: tuple[ShadowLayer, ...]
    light_shadows: tuple[ShadowLayer, ...]
    classic_dark_shadows: tuple[ShadowLayer, ...]
    classic_light_shadows: tuple[ShadowLayer, ...]


def split_top_level_commas(value: str) -> list[str]:
    parts, current, depth = [], [], 0
    for ch in value:
        depth += (ch == "(") - (ch == ")" and depth > 0)
        if ch == "," and depth == 0:
            if part := "".join(current).strip():
                parts.append(part)
            current = []
        else:
            current.append(ch)
    if tail := "".join(current).strip():
        parts.append(tail)
    return parts


def parse_shadow_layers(raw_shadow: str, label: str) -> tuple[ShadowLayer, ...]:
    layers: list[ShadowLayer] = []
    for raw_layer in split_top_level_commas(raw_shadow):
        cleaned = re.sub(r"(?:rgba?|hsla?|color)\([^)]*\)|#[0-9a-fA-F]{3,8}\b", " ", raw_layer, flags=re.IGNORECASE)
        tokens = cleaned.split()
        if any(tok.lower() == "inset" for tok in tokens):
            continue
        lengths = [float(m.group(1)) for tok in tokens if (m := re.fullmatch(r"(-?\d+(?:\.\d+)?)(?:px)?", tok, re.I))]
        if not (2 <= len(lengths) <= 4):
            raise ValueError(f"{label} 阴影层格式无法解析: {raw_layer!r}")
        layers.append(ShadowLayer(lengths[0], lengths[1], lengths[2] if len(lengths) >= 3 else 0.0, lengths[3] if len(lengths) == 4 else 0.0))
    if not layers:
        raise ValueError(f"{label} 未包含任何外投影层")
    return tuple(layers)


def extract_css_block(css_text: str, selector_pattern: str, label: str) -> str:
    if not (m := re.search(selector_pattern + r"\s*\{([^}]*)\}", css_text, flags=re.DOTALL)):
        raise ValueError(f"styles.css 缺少选择器块: {label}")
    return m.group(1)


def extract_rust_fn_body(rust_text: str, fn_name: str) -> str:
    if not (m := re.search(rf"\bfn\s+{re.escape(fn_name)}\b[^{{]*\{{", rust_text)):
        raise ValueError(f"window.rs 缺少函数 {fn_name}")
    start, depth, idx = m.end(), 1, m.end()
    while idx < len(rust_text) and depth > 0:
        depth += (rust_text[idx] == "{") - (rust_text[idx] == "}")
        idx += 1
    return rust_text[start : idx - 1]


def load_contract(root: Path = ROOT) -> FlyoutGeometryContract:
    tauri_conf = json.loads((root / "windows/src-tauri/tauri.conf.json").read_text(encoding="utf-8"))
    main_win = next((w for w in tauri_conf.get("app", {}).get("windows", []) if w.get("label") == "main"), None)
    if main_win is None:
        raise ValueError("tauri.conf.json 缺少 label == 'main' 的窗口配置")

    rust_raw = (root / "windows/src-tauri/src/window.rs").read_text(encoding="utf-8")
    rust_text = "\n".join(line for line in rust_raw.splitlines() if not line.lstrip().startswith("//"))
    main_w_m = re.search(r"PANEL_MAIN_WIDTH:\s*f64\s*=\s*(\d+(?:\.\d+)?)\s*;", rust_text)
    classic_w_m = re.search(r"CLASSIC_MAIN_WIDTH:\s*f64\s*=\s*(\d+(?:\.\d+)?)\s*;", rust_text)
    pad_m = re.search(r"PANEL_PADDING:\s*f64\s*=\s*(\d+(?:\.\d+)?)\s*;", rust_text)
    if not main_w_m or not classic_w_m or not pad_m:
        raise ValueError("window.rs 缺少 PANEL_MAIN_WIDTH、CLASSIC_MAIN_WIDTH 或 PANEL_PADDING 常量定义")

    fn_body = extract_rust_fn_body(rust_text, "set_panel_height")
    uses_helper = bool(re.search(r"\bclamp_outer_panel_height\s*\(", fn_body))
    adds_padding = bool(re.search(r"height\s*\+\s*PANEL_PADDING|PANEL_PADDING\s*\*\s*2(?:\.0)?\s*\+\s*height", fn_body))

    geom_fn_body = extract_rust_fn_body(rust_text, "set_panel_geometry")
    geom_uses_helper = bool(re.search(r"\bclamp_outer_panel_height\s*\(", geom_fn_body))
    geom_adds_padding = bool(re.search(r"height\s*\+\s*PANEL_PADDING|PANEL_PADDING\s*\*\s*2(?:\.0)?\s*\+\s*height", geom_fn_body))

    prefs_text = (root / "windows/src/ui/panelPrefs.ts").read_text(encoding="utf-8")
    if not (heights_m := re.search(r"PANEL_HEIGHTS\s*:[^=]*=\s*\[(.*?)\]\s*;", prefs_text, flags=re.DOTALL)):
        raise ValueError("panelPrefs.ts 缺少 PANEL_HEIGHTS 定义")
    panel_heights = {
        m.group(1): float(m.group(2))
        for m in re.finditer(r'\{\s*id:\s*"([^"]+)".*?px:\s*(-?\d+(?:\.\d+)?)\s*\}', heights_m.group(1), flags=re.DOTALL)
    }

    theme_text = (root / "windows/src/ui/panelTheme.ts").read_text(encoding="utf-8")
    fluent_profile_m = re.search(r'fluent:\s*\{[^}]*mainWidthPx:\s*(\d+)[^}]*windowWidthPx:\s*(\d+)', theme_text, flags=re.DOTALL)
    classic_profile_m = re.search(r'classic:\s*\{[^}]*mainWidthPx:\s*(\d+)[^}]*windowWidthPx:\s*(\d+)', theme_text, flags=re.DOTALL)
    if not fluent_profile_m or not classic_profile_m:
        raise ValueError("panelTheme.ts 缺少 fluent 或 classic 的几何定义")

    css_text = re.sub(r"/\*.*?\*/", "", (root / "windows/src/ui/styles.css").read_text(encoding="utf-8"), flags=re.DOTALL)
    app_block = extract_css_block(css_text, r"(?<![\w-])#app", "#app")
    if not (inset_m := re.search(r"--panel-inset\s*:\s*(\d+(?:\.\d+)?)px\s*;", app_block)):
        raise ValueError("styles.css #app 缺少 --panel-inset: <px> 定义")

    popover_block = extract_css_block(css_text, r"(?<![\w>. -])\.cc-popover", ".cc-popover")
    if not (pop_w_m := re.search(r"width\s*:\s*(?:min\(\s*100%\s*,\s*(\d+(?:\.\d+)?)px\s*\)|(\d+(?:\.\d+)?)px)\s*;", popover_block)):
        raise ValueError("styles.css .cc-popover 缺少列宽定义")

    classic_popover_block = extract_css_block(
        css_text,
        r'#app\[data-panel-theme="classic"\]\s*>\s*\.cc-popover(?!\.)',
        '#app[data-panel-theme="classic"] > .cc-popover',
    )
    if not (classic_pop_w_m := re.search(r"width\s*:\s*(?:min\(\s*100%\s*,\s*(\d+(?:\.\d+)?)px\s*\)|(\d+(?:\.\d+)?)px)\s*;", classic_popover_block)):
        raise ValueError('styles.css #app[data-panel-theme="classic"] > .cc-popover 缺少列宽定义')
    if not (classic_dark_m := re.search(r"--classic-popover-shadow\s*:\s*([^;]+);", classic_popover_block, flags=re.DOTALL)):
        raise ValueError('styles.css #app[data-panel-theme="classic"] > .cc-popover 缺少 --classic-popover-shadow 定义')

    classic_light_block = extract_css_block(
        css_text,
        r'#app\[data-panel-theme="classic"\]\s*>\s*\.cc-popover\.scheme-light',
        '#app[data-panel-theme="classic"] > .cc-popover.scheme-light',
    )
    if not (classic_light_m := re.search(r"--classic-popover-shadow\s*:\s*([^;]+);", classic_light_block, flags=re.DOTALL)):
        raise ValueError('styles.css #app[data-panel-theme="classic"] > .cc-popover.scheme-light 缺少 --classic-popover-shadow 定义')

    preview_block = extract_css_block(css_text, r"#app:not\(\.is-native-host\)\s*>\s*\.cc-popover", "#app:not(.is-native-host) > .cc-popover")
    if not (preview_h_m := re.search(r"height\s*:\s*min\(\s*(\d+(?:\.\d+)?)px\s*,", preview_block)):
        raise ValueError("styles.css #app:not(.is-native-host) > .cc-popover 缺少预览高度定义")

    root_block = extract_css_block(css_text, r":root", ":root")
    if not (dark_m := re.search(r"--win-island-shadow\s*:\s*([^;]+);", root_block, flags=re.DOTALL)):
        raise ValueError("styles.css :root 缺少 --win-island-shadow 定义")

    light_block = extract_css_block(css_text, r"(?<![\w>. -])\.cc-popover\.scheme-light", ".cc-popover.scheme-light")
    if not (light_m := re.search(r"--win-island-shadow\s*:\s*([^;]+);", light_block, flags=re.DOTALL)):
        raise ValueError("styles.css .cc-popover.scheme-light 缺少 --win-island-shadow 定义")

    return FlyoutGeometryContract(
        tauri_width=float(main_win.get("width", 0)), tauri_height=float(main_win.get("height", 0)),
        tauri_transparent=bool(main_win.get("transparent") is True), tauri_shadow=bool(main_win.get("shadow") is True),
        rust_main_width=float(main_w_m.group(1)), rust_classic_main_width=float(classic_w_m.group(1)),
        rust_padding=float(pad_m.group(1)),
        set_panel_height_uses_helper=uses_helper, set_panel_height_adds_padding=adds_padding,
        set_panel_geometry_uses_helper=geom_uses_helper, set_panel_geometry_adds_padding=geom_adds_padding,
        panel_heights=panel_heights,
        ts_fluent_main_width=float(fluent_profile_m.group(1)), ts_fluent_window_width=float(fluent_profile_m.group(2)),
        ts_classic_main_width=float(classic_profile_m.group(1)), ts_classic_window_width=float(classic_profile_m.group(2)),
        css_panel_inset=float(inset_m.group(1)),
        css_popover_width=float(pop_w_m.group(1) or pop_w_m.group(2)),
        css_classic_popover_width=float(classic_pop_w_m.group(1) or classic_pop_w_m.group(2)),
        css_preview_height=float(preview_h_m.group(1)),
        dark_shadows=parse_shadow_layers(dark_m.group(1), ":root --win-island-shadow"),
        light_shadows=parse_shadow_layers(light_m.group(1), ".cc-popover.scheme-light --win-island-shadow"),
        classic_dark_shadows=parse_shadow_layers(classic_dark_m.group(1), '#app[data-panel-theme="classic"] > .cc-popover --classic-popover-shadow'),
        classic_light_shadows=parse_shadow_layers(classic_light_m.group(1), '#app[data-panel-theme="classic"] > .cc-popover.scheme-light --classic-popover-shadow'),
    )


def validate_contract(c: FlyoutGeometryContract) -> list[str]:
    errors: list[str] = []
    if not c.tauri_transparent or c.tauri_shadow:
        errors.append(f"tauri.conf.json main 窗口必须保持 transparent=true 且 shadow=false（实际 transparent={c.tauri_transparent}, shadow={c.tauri_shadow}）")

    rust_outer_w = c.rust_main_width + 2.0 * c.rust_padding
    css_outer_w = c.css_popover_width + 2.0 * c.css_panel_inset
    if c.rust_padding != c.css_panel_inset:
        errors.append(f"window.rs PANEL_PADDING ({c.rust_padding:g}px) 与 styles.css #app --panel-inset ({c.css_panel_inset:g}px) 不一致")
    if not (c.tauri_width == rust_outer_w == css_outer_w == c.ts_fluent_window_width) or c.rust_main_width != c.ts_fluent_main_width:
        errors.append(
            f"Fluent 飞出面板外框宽度失配: tauri.conf.json width={c.tauri_width:g}, "
            f"window.rs PANEL_MAIN_WIDTH+2*PANEL_PADDING={rust_outer_w:g}, "
            f"styles.css .cc-popover+2*--panel-inset={css_outer_w:g}, "
            f"panelTheme.ts fluent={c.ts_fluent_main_width:g}/{c.ts_fluent_window_width:g}"
        )

    rust_classic_outer_w = c.rust_classic_main_width + 2.0 * c.rust_padding
    css_classic_outer_w = c.css_classic_popover_width + 2.0 * c.css_panel_inset
    if not (
        c.rust_classic_main_width == c.css_classic_popover_width == c.ts_classic_main_width == 440.0
        and rust_classic_outer_w == css_classic_outer_w == c.ts_classic_window_width == 472.0
    ):
        errors.append(
            f"Classic 飞出面板外框宽度失配: window.rs CLASSIC_MAIN_WIDTH+2*PANEL_PADDING={rust_classic_outer_w:g}, "
            f'styles.css #app[data-panel-theme="classic"] > .cc-popover+2*--panel-inset={css_classic_outer_w:g}, '
            f"panelTheme.ts classic={c.ts_classic_main_width:g}/{c.ts_classic_window_width:g}"
        )

    missing = [k for k in ("compact", "standard", "tall", "max") if k not in c.panel_heights]
    if missing:
        errors.append(f"panelPrefs.ts PANEL_HEIGHTS 缺少档位: {', '.join(missing)}")
    else:
        compact_h, standard_h, tall_h, max_h = (c.panel_heights[k] for k in ("compact", "standard", "tall", "max"))
        if not (compact_h < standard_h < tall_h):
            errors.append(f"panelPrefs.ts PANEL_HEIGHTS 必须满足 compact < standard < tall（实际 {compact_h:g}, {standard_h:g}, {tall_h:g}）")
        if max_h != 0.0:
            errors.append(f"panelPrefs.ts PANEL_HEIGHTS.max 必须为 0（实际 {max_h:g}）")
        if standard_h != c.tauri_height:
            errors.append(f"panelPrefs.ts PANEL_HEIGHTS.standard ({standard_h:g}) 与 tauri.conf.json height ({c.tauri_height:g}) 不一致")

    expected_preview_h = c.tauri_height - 2.0 * c.css_panel_inset
    if c.css_preview_height != expected_preview_h:
        errors.append(f"styles.css 浏览器预览高度 ({c.css_preview_height:g}px) 必须等于 tauri height - 2*--panel-inset ({expected_preview_h:g}px)")

    if not c.set_panel_height_uses_helper or c.set_panel_height_adds_padding:
        errors.append("window.rs set_panel_height 必须通过 clamp_outer_panel_height 计算外框高度，严禁对 PANEL_HEIGHTS 再次累加 PANEL_PADDING")
    if not c.set_panel_geometry_uses_helper or c.set_panel_geometry_adds_padding:
        errors.append("window.rs set_panel_geometry 必须通过 clamp_outer_panel_height 计算外框高度，严禁对 PANEL_HEIGHTS 再次累加 PANEL_PADDING")

    shadow_blocks = (
        ("Fluent Dark (:root)", c.dark_shadows),
        ("Fluent Light (.scheme-light)", c.light_shadows),
        ('Classic Dark (#app[data-panel-theme="classic"] > .cc-popover)', c.classic_dark_shadows),
        ('Classic Light (#app[data-panel-theme="classic"] > .cc-popover.scheme-light)', c.classic_light_shadows),
    )
    for theme_name, layers in shadow_blocks:
        for index, layer in enumerate(layers, start=1):
            if layer.blur < 0.0:
                errors.append(f"styles.css {theme_name} 第 {index} 层阴影 blur 不能为负数 ({layer.blur:g}px)")
            if clipped := [f"{edge}={reach:g}px" for edge, reach in layer.edge_reaches().items() if reach > c.css_panel_inset]:
                errors.append(f"styles.css {theme_name} 第 {index} 层阴影超出 --panel-inset ({c.css_panel_inset:g}px) 会被 HWND 裁切: {', '.join(clipped)}")
    return errors


def check_repo(root: Path = ROOT) -> list[str]:
    try:
        return validate_contract(load_contract(root))
    except ValueError as error:
        return [str(error)]


def main() -> int:
    if errors := check_repo(ROOT):
        for err in errors:
            print(f"❌ {err}", file=sys.stderr)
        return 1
    print("✅ Windows 飞出面板几何与阴影留白预算检查通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
