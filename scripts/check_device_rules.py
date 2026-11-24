#!/usr/bin/env python3
"""Validate Shared/deviceLabels.json and Shared/deviceClaims.json against both platforms.

Two shared documents, one gate:

* `deviceLabels.json` only carries display text and neutral icon ids. The gate proves the schema is
  the one the two parsers expect, that every semantic icon id is mapped by **both** ends and none
  their vocabularies declare goes unused, that the macOS resource copy is byte-identical, and that
  the pre-migration fixture still records the same glyph for every device type.
* `deviceClaims.json` (#26) carries the MIoT claim ladder, the device-type service aliases, two
  closed claim conditions, the appliance service list and the light-like fallback tokens. The gate
  proves the ladder is unique and ordered, that a rung's `renderers` names a proper subset of the
  platforms (a platform gap must be explicit, never silent), that each end's code really implements
  the rungs it claims (macOS's builder table exactly, Windows's synthesizer at least by name), and
  that the alias/condition/appliance references all point into the document.

The coverage baseline's `windowsDivergences` is a debt table: the gate fails when it grows past
`WINDOWS_DIVERGENCE_BUDGET`, and also when an entry grew stale (a divergence identical to the macOS
entry, or naming a service the ladder does not claim). Shrinking it is always fine; lower the budget
in the same change.

Both documents carry choices, never computation: no expression, no regular expression and no code
pointer may enter them (ADR-0023 §2's closed-data rule).
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

SHARED_CLAIMS = ROOT / "Shared/deviceClaims.json"
SWIFT_CLAIMS_COPY = ROOT / "Sources/MijiaCore/Resources/deviceClaims.json"
SWIFT_SYNTH = ROOT / "Sources/MijiaCore/MiCloud/MiotSynthesizer.swift"
TS_SYNTH = ROOT / "windows/src/core/miCloud/synthesis.ts"
COVERAGE_GOLDEN = ROOT / "Tests/Fixtures/miot_coverage_golden.json"

SCHEMA_VERSION = 1
ROOT_KEYS = frozenset({"schemaVersion", "defaultIcon", "facetTitles", "familyFacetTitles", "deviceTypes"})
TITLE_KEYS = frozenset({"zh-Hans", "en"})
DEVICE_TYPE_KEYS = frozenset({"zh-Hans", "en", "icon"})
ICON_ID = re.compile(r"^[a-z][a-z0-9-]*$")

CLAIMS_SCHEMA_VERSION = 1
CLAIMS_ROOT_KEYS = frozenset({"schemaVersion", "preferredServices", "ladder", "applianceServices", "fallbackTypeTokens"})
LADDER_KEYS = frozenset({"service", "claimableWhen", "renderers"})
CONDITION_KEYS = frozenset({"serviceHasProperty", "deviceTypeIsService"})
SERVICE_PROPERTY_KEYS = frozenset({"service", "property"})
FALLBACK_TOKEN_KEYS = frozenset({"service", "tokens"})
PLATFORMS = ("macos", "windows")
SERVICE_NAME = re.compile(r"^[a-z][a-z0-9-]*$")

# Ratchets. `windowsDivergences` is a debt table and may only shrink: lower the budget in the same
# change that removes an entry. A claim rung only one end renders is the same kind of debt, so a new
# macOS-only rung is refused outright and a new Windows-only rung needs this number raised on
# purpose (the current two are the MIoT television/stb cards macOS has no builder for).
WINDOWS_DIVERGENCE_BUDGET = 1
WINDOWS_ONLY_CLAIM_BUDGET = 2
MACOS_ONLY_CLAIM_BUDGET = 0


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


def extract_swift_builders(source: str) -> set[str]:
    """Service → builder table in `MiotSynthesizer`, the macOS renderer vocabulary."""
    block = re.search(r"static let builders: \[String: KindBuilder\] = \[\n(.*?)\n    \]", source, re.S)
    if not block:
        raise ValueError("Swift 缺少 MiotSynthesizer.builders 表")
    services = re.findall(r'^\s*"([a-z][a-z0-9-]*)": build[A-Z][A-Za-z]*,$', block.group(1), re.M)
    if not services:
        raise ValueError("Swift builders 表为空")
    if len(set(services)) != len(services):
        raise ValueError("Swift builders 表存在重复服务")
    return set(services)


def validate_claims_document(
    document: Any,
    swift_builders: set[str],
    ts_source: str,
    golden: Any,
) -> list[str]:
    errs: list[str] = []
    if not isinstance(document, dict):
        return ["共享认领清单根节点必须是 JSON 对象"]
    extra = set(document) - CLAIMS_ROOT_KEYS
    if extra:
        errs.append(f"认领清单根节点含未授权字段: {', '.join(sorted(extra))}")
    version = document.get("schemaVersion")
    if not isinstance(version, int) or isinstance(version, bool) or version != CLAIMS_SCHEMA_VERSION:
        errs.append(f"不支持的 schemaVersion: {version!r}")

    ladder = document.get("ladder")
    if not isinstance(ladder, list) or not ladder:
        return [*errs, "ladder 必须是非空数组"]

    ladder_services: list[str] = []
    macos_services: set[str] = set()
    windows_services: set[str] = set()
    windows_only: list[str] = []
    macos_only: list[str] = []
    for idx, entry in enumerate(ladder):
        scope = f"ladder[{idx}]"
        if not isinstance(entry, dict):
            errs.append(f"{scope} 必须是对象")
            continue
        unknown = set(entry) - LADDER_KEYS
        if unknown:
            errs.append(f"{scope} 含未授权字段: {', '.join(sorted(unknown))}")
        service = entry.get("service")
        if not isinstance(service, str) or not SERVICE_NAME.match(service):
            errs.append(f"{scope}.service 非法: {service!r}")
            continue
        if service in ladder_services:
            errs.append(f"重复服务: ladder 中 {service} 出现两次")
            continue
        ladder_services.append(service)

        renderers = entry.get("renderers")
        if renderers is None:
            macos_services.add(service)
            windows_services.add(service)
        elif (
            not isinstance(renderers, list)
            or not renderers
            or not all(isinstance(p, str) for p in renderers)
            or len(set(renderers)) != len(renderers)
            or set(renderers) - set(PLATFORMS)
            or set(renderers) == set(PLATFORMS)
        ):
            errs.append(f"{scope}.renderers 必须是非空且不含两个平台的平台子集: {renderers!r}")
        else:
            if "macos" in renderers:
                macos_services.add(service)
            else:
                windows_only.append(service)
            if "windows" in renderers:
                windows_services.add(service)
            else:
                macos_only.append(service)

        condition = entry.get("claimableWhen")
        if condition is None:
            continue
        if not isinstance(condition, dict) or not condition:
            errs.append(f"{scope}.claimableWhen 必须是非空对象")
            continue
        unknown = set(condition) - CONDITION_KEYS
        if unknown:
            errs.append(f"{scope}.claimableWhen 含未授权条件: {', '.join(sorted(unknown))}")
        rule = condition.get("serviceHasProperty")
        if rule is not None:
            if (
                not isinstance(rule, dict)
                or set(rule) != SERVICE_PROPERTY_KEYS
                or not all(isinstance(rule[k], str) and SERVICE_NAME.match(rule[k]) for k in SERVICE_PROPERTY_KEYS)
            ):
                errs.append(f"{scope}.claimableWhen.serviceHasProperty 必须带合法的 service 与 property")
        device_type_rule = condition.get("deviceTypeIsService")
        if device_type_rule is not None and device_type_rule is not True:
            errs.append(f"{scope}.claimableWhen.deviceTypeIsService 只接受 true")

    # A rung nobody renders would silently drop the device: the document and the code must agree.
    if macos_services != swift_builders:
        errs.append(
            "缺映射: 认领阶梯与 Swift builders 不一致 "
            f"(阶梯多 {sorted(macos_services - swift_builders)}，Swift 多 {sorted(swift_builders - macos_services)})"
        )
    missing_in_ts = sorted(s for s in windows_services if f'"{s}"' not in ts_source)
    if missing_in_ts:
        errs.append(f"缺映射: Windows 合成器未提及认领阶梯服务 {', '.join(missing_in_ts)}")
    if len(windows_only) > WINDOWS_ONLY_CLAIM_BUDGET:
        errs.append(
            f"平台独占认领增加: Windows 独占 {len(windows_only)} 条 > 预算 {WINDOWS_ONLY_CLAIM_BUDGET}"
            f" ({', '.join(windows_only)})；补上另一端或显式提高预算"
        )
    if len(macos_only) > MACOS_ONLY_CLAIM_BUDGET:
        errs.append(
            f"平台独占认领增加: macOS 独占 {len(macos_only)} 条 > 预算 {MACOS_ONLY_CLAIM_BUDGET}"
            f" ({', '.join(macos_only)})"
        )

    preferred = document.get("preferredServices")
    if not isinstance(preferred, dict) or not preferred:
        errs.append("preferredServices 必须是非空对象")
    else:
        for device_type, services in preferred.items():
            if not isinstance(device_type, str) or not SERVICE_NAME.match(device_type):
                errs.append(f"preferredServices 含非法设备类型: {device_type!r}")
                continue
            if not isinstance(services, list) or not services or not all(isinstance(s, str) for s in services):
                errs.append(f"preferredServices.{device_type} 必须是非空字符串数组")
                continue
            if len(set(services)) != len(services):
                errs.append(f"preferredServices.{device_type} 含重复服务")
            for service in services:
                if service not in ladder_services:
                    errs.append(f"preferredServices.{device_type} 引用了阶梯外的服务 {service!r}")

    appliances = document.get("applianceServices")
    if (
        not isinstance(appliances, list)
        or not appliances
        or not all(isinstance(s, str) and SERVICE_NAME.match(s) for s in appliances)
    ):
        errs.append("applianceServices 必须是非空且合法的服务名数组")
    elif len(set(appliances)) != len(appliances):
        errs.append("applianceServices 含重复服务")

    tokens = document.get("fallbackTypeTokens")
    if not isinstance(tokens, list) or not tokens:
        errs.append("fallbackTypeTokens 必须是非空数组")
    else:
        seen: set[str] = set()
        for idx, entry in enumerate(tokens):
            scope = f"fallbackTypeTokens[{idx}]"
            if not isinstance(entry, dict) or set(entry) != FALLBACK_TOKEN_KEYS:
                errs.append(f"{scope} 必须只带 service 与 tokens")
                continue
            service = entry["service"]
            if not isinstance(service, str) or service not in ladder_services:
                errs.append(f"{scope}.service 必须是认领阶梯内的服务: {service!r}")
            elif service in seen:
                errs.append(f"重复服务: fallbackTypeTokens 中 {service} 出现两次")
            seen.add(service)
            entry_tokens = entry["tokens"]
            if (
                not isinstance(entry_tokens, list)
                or not entry_tokens
                or not all(isinstance(t, str) and t for t in entry_tokens)
                or len(set(entry_tokens)) != len(entry_tokens)
            ):
                errs.append(f"{scope}.tokens 必须是非空且不重复的字符串数组")

    errs.extend(validate_divergence_ratchet(golden, set(ladder_services)))
    return errs


def validate_resource_copies() -> list[str]:
    """Both Swift packages must copy every shared document the runtime decodes.

    `Package.swift` alone is not enough: `scripts/linux-check/Package.swift` lists its resources
    again, and forgetting a document there traps on `DeviceClaims.shared` under `linux-core` (#440).
    """
    errs: list[str] = []
    for label, path in (
        ("Package.swift", ROOT / "Package.swift"),
        ("scripts/linux-check/Package.swift", ROOT / "scripts/linux-check/Package.swift"),
    ):
        try:
            text = path.read_text("utf-8")
        except OSError as exc:
            errs.append(f"{label} 不可读: {exc}")
            continue
        for name in ("deviceLabels.json", "deviceClaims.json"):
            if f'Resources/{name}' not in text:
                errs.append(f"资源缺失: {label} 没有复制 Resources/{name}")
    return errs


def validate_divergence_ratchet(golden: Any, ladder_services: set[str]) -> list[str]:
    errs: list[str] = []
    if not isinstance(golden, dict):
        return ["覆盖语料必须是 JSON 对象"]
    models = golden.get("models")
    divergences = golden.get("windowsDivergences")
    if not isinstance(models, dict) or not isinstance(divergences, dict):
        return ["覆盖语料缺少 models 或 windowsDivergences"]
    if len(divergences) > WINDOWS_DIVERGENCE_BUDGET:
        errs.append(
            f"双端差异增加: {len(divergences)} 条 > 预算 {WINDOWS_DIVERGENCE_BUDGET}（只减不增）"
        )
    for model, entry in sorted(divergences.items()):
        if model not in models:
            errs.append(f"双端差异引用了语料不存在的型号: {model}")
        elif entry == models[model]:
            errs.append(f"双端差异与 macOS 分类相同，应删除: {model}")
        if not isinstance(entry, dict):
            errs.append(f"双端差异条目必须是对象: {model}")
            continue
        service = entry.get("service")
        if isinstance(service, str) and service not in ladder_services:
            errs.append(f"双端差异的服务不在认领阶梯中: {model} → {service}")
    return errs


def load_inputs() -> tuple[Any, dict[str, str], dict[str, str], Any]:
    document = load_strict_json(SHARED.read_text("utf-8"))
    swift_icons = extract_swift_icons(SWIFT_ICONS.read_text("utf-8"))
    ts_icons = extract_ts_icons(TS_ICONS.read_text("utf-8"))
    fixture = load_strict_json(FIXTURE.read_text("utf-8"))
    return document, swift_icons, ts_icons, fixture


def load_claim_inputs() -> tuple[Any, set[str], str, Any]:
    claims = load_strict_json(SHARED_CLAIMS.read_text("utf-8"))
    swift_builders = extract_swift_builders(SWIFT_SYNTH.read_text("utf-8"))
    ts_source = TS_SYNTH.read_text("utf-8")
    golden = load_strict_json(COVERAGE_GOLDEN.read_text("utf-8"))
    return claims, swift_builders, ts_source, golden


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

    claims, swift_builders, ts_source, golden = load_claim_inputs()
    assert not validate_claims_document(claims, swift_builders, ts_source, golden), "基线认领清单应通过"
    assert not validate_resource_copies(), "两个 Swift 包都应复制共享文档"

    def expect_claim_err(mutator: Any, keyword: str) -> None:
        doc = copy.deepcopy(claims)
        swift = set(swift_builders)
        gold = copy.deepcopy(golden)
        source = ts_source
        result = mutator(doc, swift, gold)
        if isinstance(result, str):
            source = result
        errs = validate_claims_document(doc, swift, source, gold)
        assert any(keyword in err for err in errs), f"预期命中 {keyword!r}，实际: {errs}"

    expect_claim_err(lambda d, _s, _g: d.__setitem__("shape", "cover"), "未授权字段")
    expect_claim_err(lambda d, _s, _g: d.__setitem__("schemaVersion", 2), "schemaVersion")
    expect_claim_err(lambda d, _s, _g: d["ladder"].append(dict(d["ladder"][0])), "重复服务")
    expect_claim_err(lambda d, _s, _g: d["ladder"][0].__setitem__("requiresAnyOf", []), "未授权字段")
    expect_claim_err(lambda d, _s, _g: d["ladder"][0].__setitem__("renderers", ["macos", "windows"]), "renderers")
    expect_claim_err(lambda d, _s, _g: d["ladder"][23]["claimableWhen"].__setitem__("expression", "x"), "未授权条件")
    expect_claim_err(
        lambda d, _s, _g: d["ladder"][23]["claimableWhen"].__setitem__("deviceTypeIsService", False),
        "只接受 true",
    )
    expect_claim_err(lambda d, _s, _g: d["preferredServices"]["outlet"].append("kettle-ghost"), "阶梯外的服务")
    expect_claim_err(lambda d, _s, _g: d["applianceServices"].clear(), "applianceServices")
    expect_claim_err(lambda d, _s, _g: d["fallbackTypeTokens"][0]["tokens"].append("lamp"), "不重复")
    expect_claim_err(lambda d, s, _g: s.discard("curtain"), "Swift builders")
    expect_claim_err(lambda _d, _s, _g: ts_source.replace('"television"', '"tv-vendor"'), "Windows 合成器")
    expect_claim_err(lambda _d, _s, g: g["windowsDivergences"].__setitem__("extra.model", {"category": "matched"}), "双端差异")
    expect_claim_err(
        lambda _d, _s, g: g["windowsDivergences"].__setitem__(
            m := next(iter(g["windowsDivergences"])), dict(g["models"][m])
        ),
        "应删除",
    )
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
        claims, swift_builders, ts_source, golden = load_claim_inputs()
        errors.extend(validate_claims_document(claims, swift_builders, ts_source, golden))
        errors.extend(validate_resource_copies())
        if SHARED_CLAIMS.read_bytes() != SWIFT_CLAIMS_COPY.read_bytes():
            errors.append("副本不一致: Sources/MijiaCore/Resources/deviceClaims.json 必须与 Shared/deviceClaims.json 逐字节相同")
    except Exception as exc:  # noqa: BLE001 - the message is the gate output
        print(f"❌ 设备规则门禁解析失败：{exc}", file=sys.stderr)
        return 1
    if errors:
        print("❌ 共享设备规则门禁检查未通过：", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    facets = len(facet_keys_of(document))
    icons = len(set(swift_icons))
    print(
        f"✅ 共享设备规则校验通过：{facets} 条 facet 标题、{len(document['deviceTypes'])} 个设备类型、"
        f"{icons} 个语义图标 id、{len(claims['ladder'])} 条认领阶梯、"
        f"{len(golden['windowsDivergences'])} 条双端差异"
        f"（预算 {WINDOWS_DIVERGENCE_BUDGET}）。"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
