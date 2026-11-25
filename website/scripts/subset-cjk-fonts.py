#!/usr/bin/env python3
"""
Subset official OFL-1.1 LXGW WenKai (v1.530) and LXGW Neo XiHei (v1.309)
into lean, CJK-only self-hosted WOFF2 files under public/fonts/.

Usage:
  python scripts/subset-cjk-fonts.py --src-dir <folder-with-ttf-files>

Scans all source files under src/ and index.html for CJK ideographs and CJK
punctuation (strictly excluding Basic Latin, Latin-1, and Private Use Areas),
merges a curated smart-home / search safety set, and outputs:
  - public/fonts/lxgw-wenkai-medium-zh.woff2   (Display headlines)
  - public/fonts/lxgw-neo-xihei-zh.woff2       (Body, UI, popover & mono CJK)
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from fontTools.subset import Subsetter, Options, load_font, save_font

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "public" / "fonts"

# Curated safety set (~185 common smart-home, UI, search & desktop Chinese chars + punctuation)
# Ensures interactive typing in the search bar or minor copy edits never fall back to system fonts.
SAFETY_CHARS = (
    "开关灯空调窗帘卧室书房客厅玄关厨房阳台卫生间浴室餐厅走廊车库前门后门"
    "台灯吸顶灯挂灯氛围灯夜灯筒灯射灯灯带吊灯壁灯落地灯"
    "亮度色温温度湿度风速制冷制热除湿送风静音自动节能睡眠专注观影日落傍晚清晨"
    "摄像头摄像机门铃插座排插传感器净水器加湿器净化器风扇扫地机水阀阀门"
    "模式场景氛围搜索打开关闭重置取消确认下载安装免费开源更新版本设置偏好"
    "隐私安全权限允许拒绝提示成功失败连接断开在线离线局域网云端本地直连融合"
    "设备房间全屋分组定时延时撤销恢复语音识别指令控制面板悬浮置顶画中画"
    "广角长焦云台缩放拍照录像历史事件通知电量功率瓦特百分比"
    "星标赞赏收藏复制粘贴返回退出菜单栏系统托盘快捷键工具链"
    "一二三四五六七八九十百千万零两第次条个台组项秒分时天年月日"
    "，。、：；？！「」『』（）《》【】"
)


def is_cjk_codepoint(cp: int) -> bool:
    """Strictly match CJK / CJK-punctuation blocks — never Basic Latin or Private Use Area."""
    return (
        (0x2E80 <= cp <= 0x2EFF)  # CJK Radicals Supplement
        or (0x3000 <= cp <= 0x303F)  # CJK Symbols and Punctuation
        or (0x3400 <= cp <= 0x4DBF)  # CJK Unified Ideographs Extension A
        or (0x4E00 <= cp <= 0x9FFF)  # CJK Unified Ideographs
        or (0xF900 <= cp <= 0xFAFF)  # CJK Compatibility Ideographs
        or (0xFE30 <= cp <= 0xFE4F)  # CJK Compatibility Forms
        or (0xFF00 <= cp <= 0xFFEF)  # Halfwidth and Fullwidth Forms
    )


def collect_cjk_codepoints() -> set[int]:
    cps: set[int] = set()

    scan_paths: list[Path] = []
    index_html = ROOT / "index.html"
    if index_html.exists():
        scan_paths.append(index_html)

    for dirpath, _, filenames in os.walk(ROOT / "src"):
        for name in filenames:
            if name.endswith((".ts", ".tsx", ".css", ".html")):
                scan_paths.append(Path(dirpath) / name)

    for path in scan_paths:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for ch in text:
            cp = ord(ch)
            if is_cjk_codepoint(cp):
                cps.add(cp)

    for ch in SAFETY_CHARS:
        cp = ord(ch)
        if is_cjk_codepoint(cp):
            cps.add(cp)

    return cps


def subset_font(src_ttf: Path, dst_woff2: Path, unicodes: set[int], keep_hinting: bool) -> tuple[int, int]:
    options = Options()
    options.flavor = "woff2"
    options.hinting = keep_hinting
    options.layout_features = ["kern", "liga", "ccmp", "locl"]
    options.name_IDs = [0, 1, 2, 4, 5, 6, 13, 14]
    options.drop_tables += ["DSIG"]

    font = load_font(str(src_ttf), options)
    cmap = font.getBestCmap() or {}
    present = {cp for cp in unicodes if cp in cmap}
    missing = sorted(unicodes - present)
    if missing:
        print(f"  WARN {src_ttf.name}: {len(missing)} missing codepoints: {[hex(c) for c in missing[:10]]}")

    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes=present)
    subsetter.subset(font)

    dst_woff2.parent.mkdir(parents=True, exist_ok=True)
    save_font(font, str(dst_woff2), options)
    font.close()

    return len(present), dst_woff2.stat().st_size


def main() -> None:
    parser = argparse.ArgumentParser(description="Subset LXGW WenKai & Neo XiHei into lean WOFF2 files.")
    parser.add_argument(
        "--src-dir",
        required=True,
        type=Path,
        help="Directory containing LXGWWenKai-Medium.ttf and LXGWNeoXiHei.ttf",
    )
    args = parser.parse_args()

    cps = collect_cjk_codepoints()
    print(f"Collected {len(cps)} unique CJK/punctuation codepoints (strictly CJK blocks)")

    jobs = [
        ("LXGWWenKai-Medium.ttf", "lxgw-wenkai-medium-zh.woff2", False),
        ("LXGWNeoXiHei.ttf", "lxgw-neo-xihei-zh.woff2", True),
    ]

    total_bytes = 0
    for src_name, dst_name, hinting in jobs:
        src_path = args.src_dir / src_name
        if not src_path.exists():
            raise FileNotFoundError(f"Missing source font: {src_path}")
        dst_path = OUT_DIR / dst_name
        glyphs, size = subset_font(src_path, dst_path, cps, keep_hinting=hinting)
        total_bytes += size
        print(f"  {dst_name:30}  {glyphs:4} glyphs   {size / 1024:6.1f} KiB")

    print(f"Total CJK subset transfer (ZH only): {total_bytes / 1024:.1f} KiB")


if __name__ == "__main__":
    main()
