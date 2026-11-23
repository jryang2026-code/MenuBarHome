#!/usr/bin/env python3
"""Validate Shared/deviceLabels.json against both platforms and the migration fixture (#11).

The document only carries choices, never computation: facet and device-type titles in the two
languages the inline catalogs use, plus a neutral icon id per device type. This gate proves:

* the schema is the one the two parsers expect, with no duplicate key and no missing translation;
* every semantic icon id the document uses is mapped by **both** ends, and neither end maps an id
  the document does not declare (`Sources/MijiaCore/DeviceLabels.swift` and
  `windows/src/core/deviceIconSymbols.ts` stay the only platform vocabularies);
* the macOS resource copy is byte-identical to `Shared/deviceLabels.json`, the way the capability
  manifest copy is kept;
* the pre-migration fixture still covers exactly the document's keys and records the same glyph for
  every device type, so the equivalence tests cannot silently lose a case.

Labels are display text, not behaviour: no expression, no regular expression and no code pointer
may enter the document (ADR-0023 §2's closed-data rule).
"""
from __future__ import annotations

import copy
import json
import pathlib
import re
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHARED = ROOT / "Shared/deviceLabels.json"
SWIFT_COPY = ROOT / "Sources/MijiaCore/Resources/deviceLabels.json"
SWIFT_ICONS = ROOT / "Sources/MijiaCore/DeviceLabels.swift"
TS_ICONS = ROOT / "windows/src/core/deviceIconSymbols.ts"
FIXTURE = ROOT / "Tests/Fixtures/device_labels_golden.json"

SCHEMA_VERSION = 1
ROOT_KEYS = frozenset({"schemaVersion", "defaultIcon", "facetTitles", "familyFacetTitles", "deviceTypes"})
TITLE_KEYS = frozenset({"zh-Hans", "en"})
DEVICE_TYPE_KEYS = frozenset({"zh-Hans", "en", "icon"})
ICON_ID = re.compile(r"^[a-z][a-z0-9-]*$")


def load_strict_json(text: str) -> Any:
    def no_dups(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key, value in pairs:
            if key in out:
                raise ValueError(f"重复 JSON 键: {key}")
            out[key] = value
        return out

    return json.loads(text, object_pairs_hook=no_dups)


def extract_swift_icons(source: str) -> dict[str, str]:
    icons: dict[str, str] = {}
    for raw_id, symbol in re.findall(r'^\s*case "([a-z][a-z0-9-]*)": return "([^"]+)";?$', source, re.M):
        if raw_id in icons:
            raise ValueError(f"Swift 重复图标 id: {raw_id}")
        icons[raw_id] = symbol
    return icons


def extract_ts_icons(source: str) -> dict[str, str]:
    icons: dict[str, str] = {}
    for raw_id, symbol in re.findall(r'^\s*"?([a-z][a-z0-9-]*)"?: "([^"]+)",$', source, re.M):
        if raw_id in icons:
            raise ValueError(f"TS 重复图标 id: {raw_id}")
        icons[raw_id] = symbol
    return icons


def validate_titles(entries: Any, scope: str, errs: list[str]) -> None:
    if not isinstance(entries, dict) or not entries:
        errs.append(f"{scope} 必须是非空对象")
        return
    for key, entry in entries.items():
        if not isinstance(key, str) or not key:
            errs.append(f"{scope} 含空 key")
            continue
        if not isinstance(entry, dict):
            errs.append(f"{scope}.{key} 必须是对象")
            continue
        extra = set(entry) - TITLE_KEYS
        if extra:
            errs.append(f"{scope}.{key} 含未授权字段: {', '.join(sorted(extra))}")
        for language in sorted(TITLE_KEYS):
            value = entry.get(language)
            if not isinstance(value, str) or not value.strip():
                errs.append(f"缺失翻译: {scope}.{key} 缺少 {language}")
            elif value != value.strip():
                errs.append(f"{scope}.{key}.{language} 首尾不能有空白")


def validate_device_types(entries: Any, errs: list[str]) -> set[str]:
    used: set[str] = set()
    if not isinstance(entries, dict) or not entries:
        errs.append("deviceTypes 必须是非空对象")
        return used
    for key, entry in entries.items():
        if not isinstance(key, str) or not key:
            errs.append("deviceTypes 含空 key")
            continue
        if not isinstance(entry, dict):
            errs.append(f"deviceTypes.{key} 必须是对象")
            continue
        extra = set(entry) - DEVICE_TYPE_KEYS
        if extra:
            errs.append(f"deviceTypes.{key} 含未授权字段: {', '.join(sorted(extra))}")
        has_zh = "zh-Hans" in entry
        has_en = "en" in entry
        if has_zh != has_en:
            errs.append(f"缺失翻译: deviceTypes.{key} 必须同时带 zh-Hans 和 en，或都不带")
        for language in ("zh-Hans", "en"):
            if language in entry:
                value = entry[language]
                if not isinstance(value, str) or not value.strip():
                    errs.append(f"缺失翻译: deviceTypes.{key} 的 {language} 为空")
                elif value != value.strip():
                    errs.append(f"deviceTypes.{key}.{language} 首尾不能有空白")
        icon = entry.get("icon")
        if icon is not None:
            if not isinstance(icon, str) or not ICON_ID.match(icon):
                errs.append(f"图标 id 非法: deviceTypes.{key}.icon={icon!r}")
            else:
                used.add(icon)
        if not has_zh and icon is None:
            errs.append(f"deviceTypes.{key} 既没有标题也没有图标")
    return used


def validate_document(
    document: Any,
    swift_icons: dict[str, str],
    ts_icons: dict[str, str],
    fixture: Any,
) -> list[str]:
    errs: list[str] = []
    if not isinstance(document, dict):
        return ["清单根节点必须是 JSON 对象"]
    extra = set(document) - ROOT_KEYS
    if extra:
        errs.append(f"根节点含未授权字段: {', '.join(sorted(extra))}")
    version = document.get("schemaVersion")
    if not isinstance(version, int) or isinstance(version, bool) or version != SCHEMA_VERSION:
        errs.append(f"不支持的 schemaVersion: {version!r}")
    default_icon = document.get("defaultIcon")
    if not isinstance(default_icon, str) or not ICON_ID.match(default_icon):
        errs.append(f"默认图标 id 非法: {default_icon!r}")

    validate_titles(document.get("facetTitles"), "facetTitles", errs)
    validate_titles(document.get("familyFacetTitles"), "familyFacetTitles", errs)
    facet_keys = document.get("facetTitles") if isinstance(document.get("facetTitles"), dict) else {}
    family_keys = document.get("familyFacetTitles") if isinstance(document.get("familyFacetTitles"), dict) else {}
    duplicate_facets = set(facet_keys) & set(family_keys)
    if duplicate_facets:
        errs.append(f"重复 key: facet 同时出现在两个分组: {', '.join(sorted(duplicate_facets))}")

    used_icons = validate_device_types(document.get("deviceTypes"), errs)
    if isinstance(default_icon, str) and ICON_ID.match(default_icon):
        used_icons.add(default_icon)

    declared = set(swift_icons)
    for label, platform in (("Swift", declared), ("TS", set(ts_icons))):
        if platform - used_icons:
            errs.append(f"图标映射多余: {label} 映射了清单未使用的 id: {', '.join(sorted(platform - used_icons))}")
        if used_icons - platform:
            errs.append(f"图标映射缺失: {label} 未映射清单声明的 id: {', '.join(sorted(used_icons - platform))}")
    for icon in sorted(declared & set(ts_icons)):
        if swift_icons[icon] != ts_icons[icon]:
            errs.append(f"符号不一致: {icon} 在 Swift 是 {swift_icons[icon]!r}，在 TS 是 {ts_icons[icon]!r}")

    errs.extend(validate_fixture(document, fixture, swift_icons, ts_icons, default_icon))
    return errs


def validate_fixture(
    document: dict[str, Any],
    fixture: Any,
    swift_icons: dict[str, str],
    ts_icons: dict[str, str],
    default_icon: Any,
) -> list[str]:
    errs: list[str] = []
    if not isinstance(fixture, dict):
        return ["迁移夹具必须是 JSON 对象"]
    if fixture.get("version") != 1:
        errs.append(f"迁移夹具 version 非法: {fixture.get('version')!r}")
    symbols = fixture.get("symbols")
    if not isinstance(symbols, dict):
        return [*errs, "迁移夹具缺少 symbols"]
    device_types = document.get("deviceTypes") if isinstance(document.get("deviceTypes"), dict) else {}
    if set(symbols) != set(device_types):
        errs.append(
            "夹具与清单不一致: deviceTypes 键集不同 "
            f"(夹具多 {sorted(set(symbols) - set(device_types))}，清单多 {sorted(set(device_types) - set(symbols))})"
        )
    for device_type, entry in device_types.items():
        if not isinstance(entry, dict) or not isinstance(symbols.get(device_type), str):
            continue
        icon = entry.get("icon", default_icon)
        mapped = swift_icons.get(icon)
        if mapped != symbols[device_type]:
            errs.append(f"符号变化: {device_type} 迁移前是 {symbols[device_type]!r}，Swift 现在映射为 {mapped!r}")
        mapped_ts = ts_icons.get(icon)
        if mapped_ts != symbols[device_type]:
            errs.append(f"符号变化: {device_type} 迁移前是 {symbols[device_type]!r}，TS 现在映射为 {mapped_ts!r}")

    for platform in ("macos", "windows"):
        section = fixture.get(platform)
        if not isinstance(section, dict):
            errs.append(f"迁移夹具缺少 {platform} 段")
            continue
        facet_titles = section.get("facetTitles")
        if isinstance(facet_titles, dict):
            expected = set(facet_titles)
            actual = set(facet_keys_of(document))
            if expected != actual:
                errs.append(
                    f"夹具与清单不一致: {platform}.facetTitles 键集不同 "
                    f"(夹具多 {sorted(expected - actual)}，清单多 {sorted(actual - expected)})"
                )
        else:
            errs.append(f"迁移夹具缺少 {platform}.facetTitles")
        types = section.get("deviceTypes")
        if isinstance(types, dict) and set(types) != set(device_types):
            errs.append(
                f"夹具与清单不一致: {platform}.deviceTypes 键集不同 "
                f"(夹具多 {sorted(set(types) - set(device_types))}，清单多 {sorted(set(device_types) - set(types))})"
            )
    return errs


def facet_keys_of(document: dict[str, Any]) -> list[str]:
    keys: list[str] = []
    for group in ("facetTitles", "familyFacetTitles"):
        entries = document.get(group)
        if isinstance(entries, dict):
            keys.extend(entries)
    return keys


def load_inputs() -> tuple[Any, dict[str, str], dict[str, str], Any]:
    document = load_strict_json(SHARED.read_text("utf-8"))
    swift_icons = extract_swift_icons(SWIFT_ICONS.read_text("utf-8"))
    ts_icons = extract_ts_icons(TS_ICONS.read_text("utf-8"))
    fixture = load_strict_json(FIXTURE.read_text("utf-8"))
    return document, swift_icons, ts_icons, fixture


def run_self_test() -> int:
    document, swift_icons, ts_icons, fixture = load_inputs()
    assert not validate_document(document, swift_icons, ts_icons, fixture), "基线清单应通过"

    def expect_err(mutator: Any, keyword: str) -> None:
        doc, swift, ts, gold = copy.deepcopy(document), dict(swift_icons), dict(ts_icons), copy.deepcopy(fixture)
        mutator(doc, swift, ts, gold)
        errs = validate_document(doc, swift, ts, gold)
        assert any(keyword in err for err in errs), f"预期命中 {keyword!r}，实际: {errs}"

    expect_err(lambda d, _s, _t, _g: d.__setitem__("hazardLevel", "critical"), "未授权字段")
    expect_err(lambda d, _s, _t, _g: d.__setitem__("schemaVersion", 2), "schemaVersion")
    expect_err(lambda d, _s, _t, _g: d["facetTitles"]["on"].pop("en"), "缺失翻译")
    expect_err(lambda d, _s, _t, _g: d["familyFacetTitles"].__setitem__("on", dict(d["facetTitles"]["on"])), "重复 key")
    expect_err(lambda d, _s, _t, _g: d["deviceTypes"]["router"].pop("zh-Hans"), "缺失翻译")
    expect_err(lambda d, _s, _t, _g: d["deviceTypes"].__setitem__("toaster", {"icon": "toaster"}), "图标映射缺失")
    expect_err(lambda d, _s, _t, _g: d["deviceTypes"].__setitem__("toaster", {}), "既没有标题也没有图标")
    expect_err(lambda _d, s, _t, _g: s.pop("wifi"), "图标映射缺失")
    expect_err(lambda _d, s, _t, _g: s.__setitem__("ghost", "ghost.fill"), "图标映射多余")
    expect_err(lambda _d, _s, t, _g: t.__setitem__("water", "drop.fill"), "符号不一致")
    expect_err(lambda _d, _s, _t, g: g["symbols"].__setitem__("router", "router.fill"), "符号变化")
    expect_err(lambda _d, _s, _t, g: g["windows"]["facetTitles"].pop("on"), "夹具与清单不一致")
    print("✅ check_device_rules.py --self-test 通过")
    return 0


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    if "--self-test" in sys.argv[1:]:
        return run_self_test()
    try:
        document, swift_icons, ts_icons, fixture = load_inputs()
        errors = validate_document(document, swift_icons, ts_icons, fixture)
        if SHARED.read_bytes() != SWIFT_COPY.read_bytes():
            errors.append("副本不一致: Sources/MijiaCore/Resources/deviceLabels.json 必须与 Shared/deviceLabels.json 逐字节相同")
    except Exception as exc:  # noqa: BLE001 - the message is the gate output
        print(f"❌ 设备标签门禁解析失败：{exc}", file=sys.stderr)
        return 1
    if errors:
        print("❌ Shared/deviceLabels.json 门禁检查未通过：", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    facets = len(facet_keys_of(document))
    icons = len(set(swift_icons))
    print(f"✅ 共享设备标签校验通过：{facets} 条 facet 标题、{len(document['deviceTypes'])} 个设备类型、{icons} 个语义图标 id 与两端映射一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
