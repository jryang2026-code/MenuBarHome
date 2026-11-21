#!/usr/bin/env python3
"""Validate Shared/capability-manifest.json against docs/capabilities.json, Swift, and TypeScript."""
from __future__ import annotations
import copy, json, pathlib, re, sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
VALID_KINDS = ("connection", "feature", "deviceCategory")
VALID_POLICIES = ("whenConfigured", "onDemand", "backgroundWhenEnabled", "readPlanWhenEnabled")
STATUS_RANK = {"unsupported": 0, "partial": 1, "supported": 2}
BASELINE_UNLISTED = frozenset({"light", "vacuum", "tv"})
ROOT_KEYS = frozenset({"schemaVersion", "hostCoreCapabilityMatrixIds", "capabilities"})
ENTRY_KEYS = frozenset({"id", "kind", "dependsOn", "defaultOnFreshInstall", "startupPolicy", "platforms", "capabilityMatrix"})
EXPECTED_DEFAULTS: dict[str, bool] = {
    "xiaomi-cloud": False, "home-assistant": False,
    "voice-input": False, "ai-assistant": False, "proactive-suggestions": True, "companion-integration": False,
    "event-automation": True, "sensor-history": True, "plug-energy": True, "camera-live": True,
    "light": True, "plug": True, "climate": True, "fan": True, "cover": True, "appliance": True, "fridge": True,
    "vacuum": True, "speaker": True, "tv": True, "camera": True, "sensor": True, "valve": True, "generic": True,
}


def load_strict_json(text: str) -> Any:
    def no_dups(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for k, v in pairs:
            if k in out:
                raise ValueError(f"重复 JSON 键: {k}")
            out[k] = v
        return out
    return json.loads(text, object_pairs_hook=no_dups)


def extract_ids(src: str, specs: tuple[tuple[str, str], ...], block_pat: str, item_pat: str, lang: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for name, kind in specs:
        m = re.search(block_pat.format(name=name), src, re.S)
        if not m:
            raise ValueError(f"{lang} 缺少 {name}")
        for raw_id in re.findall(item_pat, m.group(1)):
            if raw_id in out:
                raise ValueError(f"{lang} 重复能力 ID: {raw_id}")
            out[raw_id] = kind
    return out


def validate_manifest(
    manifest: Any, docs_rows: dict[str, dict[str, Any]], swift_ids: dict[str, str], ts_ids: dict[str, str],
    expected_defaults: dict[str, bool] = EXPECTED_DEFAULTS,
) -> list[str]:
    errs: list[str] = []
    if not isinstance(manifest, dict):
        return ["清单根节点必须是 JSON 对象"]
    if set(manifest) - ROOT_KEYS:
        errs.append(f"根节点含未授权字段: {', '.join(sorted(set(manifest) - ROOT_KEYS))}")
    if manifest.get("schemaVersion") != 1 or isinstance(manifest.get("schemaVersion"), bool):
        errs.append(f"不支持的 schemaVersion: {manifest.get('schemaVersion')!r}")
    if swift_ids != ts_ids:
        errs.append(f"缺映射: Swift 与 TS 能力集合不一致 ({set(swift_ids) ^ set(ts_ids)})")

    raw_host = manifest.get("hostCoreCapabilityMatrixIds")
    host_ids = raw_host if isinstance(raw_host, list) and all(isinstance(x, str) and x for x in raw_host) else []
    if host_ids is not raw_host:
        errs.append("hostCoreCapabilityMatrixIds 必须是非空字符串数组")
    elif len(set(host_ids)) != len(host_ids):
        errs.append("重复 ID: hostCoreCapabilityMatrixIds 存在重复项")
    for r in host_ids:
        if r not in docs_rows:
            errs.append(f"未知 ID: hostCoreCapabilityMatrixIds 引用了不存在的矩阵行 {r!r}")

    raw_entries = manifest.get("capabilities")
    if not isinstance(raw_entries, list) or not raw_entries:
        return [*errs, "capabilities 必须是非空数组"]

    by_id: dict[str, dict[str, Any]] = {}
    opt_matrix: set[str] = set()
    known_ids = set(swift_ids) | set(ts_ids)
    for idx, entry in enumerate(raw_entries):
        if not isinstance(entry, dict):
            errs.append(f"capabilities[{idx}] 必须是对象"); continue
        if set(entry) - ENTRY_KEYS:
            errs.append(f"capabilities[{idx}] 含禁止或未知字段: {', '.join(sorted(set(entry) - ENTRY_KEYS))}")
        cid = entry.get("id")
        if not isinstance(cid, str) or not cid:
            errs.append(f"capabilities[{idx}].id 非法"); continue
        if cid in by_id:
            errs.append(f"重复 ID: 能力 {cid!r} 重复声明"); continue
        by_id[cid] = entry
        if cid not in known_ids:
            errs.append(f"未知 ID: 能力 {cid!r} 未在 Swift/TS 声明")
        kind = entry.get("kind")
        if kind not in VALID_KINDS:
            errs.append(f"{cid}: 非法 kind {kind!r}")
        elif (cid in swift_ids and swift_ids[cid] != kind) or (cid in ts_ids and ts_ids[cid] != kind):
            errs.append(f"缺映射: {cid} 的 kind 与 Swift/TS 不一致")
        deps = entry.get("dependsOn")
        if not isinstance(deps, list) or not all(isinstance(d, str) and d for d in deps):
            errs.append(f"{cid}.dependsOn 必须是字符串数组")
        elif len(set(deps)) != len(deps):
            errs.append(f"重复 ID: {cid}.dependsOn 含重复依赖")
        d_on = entry.get("defaultOnFreshInstall")
        if not isinstance(d_on, bool):
            errs.append(f"{cid}.defaultOnFreshInstall 必须是布尔值")
        elif expected_defaults.get(cid) != d_on:
            errs.append(f"默认值变化: {cid} 新装默认与基线不一致 ({d_on})")
        if entry.get("startupPolicy") not in VALID_POLICIES:
            errs.append(f"{cid}: 非法 startupPolicy")
        plat = entry.get("platforms")
        if not isinstance(plat, dict) or set(plat) != {"macos", "windows"} or any(plat[p] not in STATUS_RANK for p in ("macos", "windows")):
            errs.append(f"{cid}.platforms 非法")
        mat = entry.get("capabilityMatrix")
        if not isinstance(mat, dict) or set(mat) != {"coverage", "rowIds"} or not isinstance(mat.get("rowIds"), list):
            errs.append(f"缺映射: {cid} 缺少合法 capabilityMatrix"); continue
        cov, rids = mat["coverage"], mat["rowIds"]
        if not all(isinstance(r, str) and r for r in rids) or len(set(rids)) != len(rids):
            errs.append(f"重复 ID 或非法值: {cid}.capabilityMatrix.rowIds"); continue
        if cov == "mapped":
            if not rids:
                errs.append(f"缺映射: {cid} mapped 但 rowIds 为空")
            rows = [docs_rows[r] for r in rids if r in docs_rows]
            for r in rids:
                if r not in docs_rows:
                    errs.append(f"未知 ID: {cid} 引用了 docs/capabilities.json 不存在的 {r!r}")
                else:
                    opt_matrix.add(r)
            if rows and isinstance(plat, dict) and set(plat) == {"macos", "windows"}:
                for p in ("macos", "windows"):
                    if plat[p] in STATUS_RANK and STATUS_RANK[plat[p]] != max(STATUS_RANK[r[p]] for r in rows):
                        errs.append(f"缺映射: {cid}.{p} 与 docs/capabilities.json 状态不一致")
        elif cov != "baselineUnlisted" or kind != "deviceCategory" or cid not in BASELINE_UNLISTED or rids:
            errs.append(f"缺映射: {cid} 非法 capabilityMatrix 覆盖策略")

    for label, cmap in (("Swift", swift_ids), ("TS", ts_ids)):
        if set(cmap) - set(by_id):
            errs.append(f"缺映射: {label} 声明但清单缺失: {', '.join(sorted(set(cmap) - set(by_id)))}")
    if set(expected_defaults) - set(by_id):
        errs.append(f"默认值变化: 清单缺少受默认基线保护的能力: {', '.join(sorted(set(expected_defaults) - set(by_id)))}")
    if set(host_ids) & opt_matrix:
        errs.append(f"缺映射: hostCoreCapabilityMatrixIds 与可选能力重复映射: {sorted(set(host_ids) & opt_matrix)}")
    if set(docs_rows) - (set(host_ids) | opt_matrix):
        errs.append(f"缺映射: docs/capabilities.json 未归属行: {sorted(set(docs_rows) - (set(host_ids) | opt_matrix))}")

    states: dict[str, str] = {}
    stack: list[str] = []
    def dfs(cid: str) -> None:
        states[cid] = "visiting"; stack.append(cid); e = by_id[cid]
        for dep in e.get("dependsOn") if isinstance(e.get("dependsOn"), list) else []:
            if not isinstance(dep, str):
                continue
            if dep not in by_id:
                errs.append(f"未知 ID: {cid}.dependsOn 引用不存在的能力 {dep!r}"); continue
            if states.get(dep) == "visiting":
                errs.append(f"依赖环: {' -> '.join([*stack[stack.index(dep):], dep])}"); continue
            if dep not in states:
                dfs(dep)
            de = by_id[dep]; ps, pd = e.get("platforms"), de.get("platforms")
            if isinstance(ps, dict) and isinstance(pd, dict):
                for p in ("macos", "windows"):
                    if ps.get(p) in ("supported", "partial") and pd.get(p) == "unsupported":
                        errs.append(f"依赖不兼容: {cid} 在 {p} 可用但依赖 {dep} unsupported")
            if e.get("defaultOnFreshInstall") is True and de.get("defaultOnFreshInstall") is False:
                errs.append(f"默认值变化: {cid} 默认开启但依赖 {dep} 默认关闭")
        stack.pop(); states[cid] = "visited"

    for cid in by_id:
        if cid not in states:
            dfs(cid)
    return errs


def load_inputs() -> tuple[Any, dict[str, dict[str, Any]], dict[str, str], dict[str, str]]:
    manifest = load_strict_json((ROOT / "Shared/capability-manifest.json").read_text("utf-8"))
    docs_rows = {r["id"]: r for r in load_strict_json((ROOT / "docs/capabilities.json").read_text("utf-8"))["rows"]}
    swift_ids = extract_ids(
        (ROOT / "Sources/MijiaCore/CapabilityManifest.swift").read_text("utf-8"),
        (("ConnectionCapabilityID", "connection"), ("FeatureID", "feature"), ("DeviceCategoryID", "deviceCategory")),
        r"public enum {name}\b[^{{]*\{{(.*?)\n\}}", r'\b\w+\s*=\s*"([^"]+)"', "Swift",
    )
    ts_ids = extract_ids(
        (ROOT / "windows/src/core/capabilityManifest.ts").read_text("utf-8"),
        (("CONNECTION_CAPABILITY_IDS", "connection"), ("FEATURE_IDS", "feature"), ("DEVICE_CATEGORY_IDS", "deviceCategory")),
        r"export const {name}\s*=\s*\[(.*?)\]\s*as const", r'"([^"]+)"', "TypeScript",
    )
    return manifest, docs_rows, swift_ids, ts_ids


def run_self_test() -> int:
    base, docs_rows, swift_ids, ts_ids = load_inputs()
    assert not validate_manifest(base, docs_rows, swift_ids, ts_ids), "基线清单应通过"
    def expect_err(mutator: Any, kw: str) -> None:
        m, s, t = copy.deepcopy(base), dict(swift_ids), dict(ts_ids)
        mutator(m, s, t)
        errs = validate_manifest(m, docs_rows, s, t)
        assert any(kw in e for e in errs), f"预期命中 {kw!r}，实际: {errs}"
    expect_err(lambda m, _s, _t: m["capabilities"][0]["dependsOn"].append("ghost-id"), "未知 ID")
    expect_err(lambda m, _s, _t: m["capabilities"][0]["capabilityMatrix"]["rowIds"].append("ghost-doc"), "未知 ID")
    expect_err(lambda m, _s, _t: m["capabilities"].append(copy.deepcopy(m["capabilities"][0])), "重复 ID")
    expect_err(lambda m, _s, _t: (m["capabilities"][2]["dependsOn"].append("ai-assistant"), m["capabilities"][3]["dependsOn"].append("voice-input")), "依赖环")
    expect_err(lambda _m, s, _t: s.pop("camera-live"), "缺映射")
    expect_err(lambda m, _s, _t: m["capabilities"][0]["capabilityMatrix"]["rowIds"].clear(), "缺映射")
    expect_err(lambda m, _s, _t: m["hostCoreCapabilityMatrixIds"].pop(), "缺映射")
    expect_err(lambda m, _s, _t: m["capabilities"][11].__setitem__("defaultOnFreshInstall", False), "默认值变化")
    expect_err(lambda m, _s, _t: m["capabilities"][0].__setitem__("riskLevel", "high"), "禁止或未知字段")
    print("✅ check_capability_manifest.py --self-test 通过")
    return 0


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8"); sys.stderr.reconfigure(encoding="utf-8")
    if "--self-test" in sys.argv[1:]:
        return run_self_test()
    try:
        manifest, docs_rows, swift_ids, ts_ids = load_inputs()
        errors = validate_manifest(manifest, docs_rows, swift_ids, ts_ids)
    except Exception as exc:
        print(f"❌ 能力清单门禁解析失败：{exc}", file=sys.stderr); return 1
    if errors:
        print("❌ Shared/capability-manifest.json 门禁检查未通过：", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    print(f"✅ 共享能力清单校验通过：{len(manifest['capabilities'])} 项能力与 Swift/TS 及 docs/capabilities.json 一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
