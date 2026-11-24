#!/usr/bin/env python3
"""Validate Shared/adapterManifest.schema.json and Tests/Fixtures/adapter-protocol/ fixtures (ADR-0024).

Uses Python stdlib only.
"""
from __future__ import annotations

import copy
import json
import pathlib
import re
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "Shared" / "adapterManifest.schema.json"
FIXTURES_DIR = ROOT / "Tests" / "Fixtures" / "adapter-protocol"

V0_ALLOWED_METHODS = frozenset({
    "initialize",
    "capabilities",
    "snapshot",
    "events.subscribe",
    "events.unsubscribe",
    "health.ping",
    "shutdown",
})

ADAPTER_ERROR_CODES = {
    -32001: "authExpired",
    -32002: "unreachable",
    -32003: "rateLimited",
    -32004: "unsupported",
    -32005: "deviceOffline",
    -32099: "unknown",
    -32601: "unsupported",
}

ALLOWED_LEASE_KINDS = frozenset({"oauthAccess", "lanToken"})
FORBIDDEN_SIGNAL_KEYS = frozenset({"severity", "interruptionLevel", "suppress", "suppressAlerts", "mute", "muteAlerts"})
FORBIDDEN_LEASE_KEYS = frozenset({"refreshToken", "passToken", "password", "cookie", "session"})


def load_strict_json(text: str) -> Any:
    def no_dups(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for k, v in pairs:
            if k in out:
                raise ValueError(f"重复 JSON 键: {k}")
            out[k] = v
        return out

    return json.loads(text, object_pairs_hook=no_dups)


def _matches_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "null":
        return value is None
    return False


def validate_against_schema(value: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    """Minimal JSON Schema Draft 2020-12 subset validator using Python stdlib only."""
    errs: list[str] = []

    expected_type = schema.get("type")
    if isinstance(expected_type, str) and not _matches_type(value, expected_type):
        errs.append(f"{path}: 类型应为 {expected_type}，实际为 {type(value).__name__}")
        return errs

    if "const" in schema:
        expected_const = schema["const"]
        if type(value) is not type(expected_const) or value != expected_const:
            errs.append(f"{path}: 值必须为 {expected_const!r}，实际为 {value!r}")

    if "enum" in schema:
        if not any(type(value) is type(opt) and value == opt for opt in schema["enum"]):
            errs.append(f"{path}: 值 {value!r} 不在允许集合 {schema['enum']!r} 内")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errs.append(f"{path}: 长度不能小于 {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errs.append(f"{path}: 长度不能大于 {schema['maxLength']}")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errs.append(f"{path}: 值 {value!r} 不匹配正则 {schema['pattern']!r}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errs.append(f"{path}: 值 {value} 小于最小值 {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errs.append(f"{path}: 值 {value} 大于最大值 {schema['maximum']}")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errs.append(f"{path}: 数组元素数 {len(value)} 小于 minItems={schema['minItems']}")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errs.append(f"{path}: 数组元素数 {len(value)} 大于 maxItems={schema['maxItems']}")
        if schema.get("uniqueItems"):
            seen: list[str] = []
            for item in value:
                key = json.dumps(item, sort_keys=True, ensure_ascii=False)
                if key in seen:
                    errs.append(f"{path}: 数组存在重复元素 {item!r}")
                    break
                seen.append(key)
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for idx, item in enumerate(value):
                errs.extend(validate_against_schema(item, item_schema, f"{path}[{idx}]"))

    if isinstance(value, dict):
        required = schema.get("required", [])
        for req_key in required:
            if req_key not in value:
                errs.append(f"{path}: 缺少必填字段 {req_key!r}")

        props = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for k, v in value.items():
            child_path = f"{path}.{k}"
            if k in props:
                errs.extend(validate_against_schema(v, props[k], child_path))
            elif additional is False:
                errs.append(f"{path}: 不允许未声明字段 {k!r}")
            elif isinstance(additional, dict):
                errs.extend(validate_against_schema(v, additional, child_path))

    return errs


def find_forbidden_keys(value: Any, forbidden: frozenset[str], path: str = "$") -> list[str]:
    errs: list[str] = []
    if isinstance(value, dict):
        for k, v in value.items():
            child_path = f"{path}.{k}"
            if k in forbidden:
                errs.append(f"{child_path}: 命中禁止字段 {k!r}")
            errs.extend(find_forbidden_keys(v, forbidden, child_path))
    elif isinstance(value, list):
        for idx, item in enumerate(value):
            errs.extend(find_forbidden_keys(item, forbidden, f"{path}[{idx}]"))
    return errs


def validate_manifest(manifest: Any, schema: dict[str, Any]) -> list[str]:
    errs = validate_against_schema(manifest, schema)
    forbidden = frozenset(schema.get("x-forbiddenKeys", []))
    errs.extend(find_forbidden_keys(manifest, forbidden))

    if isinstance(manifest, dict):
        vendor = manifest.get("vendor")
        perms = manifest.get("permissions")
        if isinstance(vendor, dict) and isinstance(perms, dict):
            vendor_hosts = vendor.get("hosts")
            net = perms.get("network")
            if isinstance(vendor_hosts, list) and isinstance(net, dict) and isinstance(net.get("internet"), list):
                extra_hosts = sorted(set(vendor_hosts) - set(net["internet"]))
                if extra_hosts:
                    errs.append(f"$.vendor.hosts 含未在 permissions.network.internet 声明的主机: {', '.join(extra_hosts)}")
    return errs


def validate_rpc_pair(fixture: Any, schema: dict[str, Any], name: str) -> list[str]:
    errs: list[str] = []
    if not isinstance(fixture, dict):
        return [f"{name}: 根节点必须是对象"]

    req = fixture.get("request")
    resp = fixture.get("response")
    if not isinstance(req, dict) or not isinstance(resp, dict):
        return [f"{name}: 必须包含 request 与 response 对象"]

    if req.get("jsonrpc") != "2.0" or resp.get("jsonrpc") != "2.0":
        errs.append(f"{name}: request 与 response 的 jsonrpc 必须为 '2.0'")
    if "id" not in req or req.get("id") != resp.get("id"):
        errs.append(f"{name}: request 与 response 的 id 必须存在且一致")

    method = req.get("method")
    if method not in V0_ALLOWED_METHODS:
        errs.append(f"{name}: 非法 v0 方法 {method!r}")

    if "result" not in resp and "error" not in resp:
        errs.append(f"{name}: response 必须包含 result 或 error")
    if "result" in resp and "error" in resp:
        errs.append(f"{name}: response 不能同时包含 result 与 error")

    allowed_kinds = set(schema["properties"]["capabilities"]["properties"]["deviceKinds"]["items"]["enum"])
    allowed_alerts = set(schema["properties"]["capabilities"]["properties"]["alerts"]["items"]["enum"])

    if method == "initialize":
        params = req.get("params")
        result = resp.get("result")
        if not isinstance(params, dict) or not isinstance(result, dict):
            errs.append(f"{name}: initialize 需要对象 params 与 result")
        else:
            for req_field in ("protocolVersion", "supportedProtocolVersions", "hostVersion", "adapterId", "dataDir"):
                if req_field not in params:
                    errs.append(f"{name}: initialize.params 缺少 {req_field!r}")
            for res_field in ("protocolVersion", "adapterId", "adapterVersion", "manifestDigest", "capabilities"):
                if res_field not in result:
                    errs.append(f"{name}: initialize.result 缺少 {res_field!r}")
            if params.get("adapterId") != result.get("adapterId"):
                errs.append(f"{name}: initialize 响应 adapterId 与请求不一致")
            digest = result.get("manifestDigest")
            if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
                errs.append(f"{name}: manifestDigest 格式非法")
            leases = params.get("leases", [])
            if not isinstance(leases, list):
                errs.append(f"{name}: leases 必须是数组")
            else:
                for idx, lease in enumerate(leases):
                    if not isinstance(lease, dict):
                        errs.append(f"{name}: leases[{idx}] 必须是对象")
                        continue
                    for fk in FORBIDDEN_LEASE_KEYS:
                        if fk in lease:
                            errs.append(f"{name}: leases[{idx}] 禁止携带长期秘密字段 {fk!r}")
                    if lease.get("kind") not in ALLOWED_LEASE_KINDS:
                        errs.append(f"{name}: leases[{idx}].kind 非法: {lease.get('kind')!r}")
                    for lf in ("accountId", "leaseId", "value", "expiresAt"):
                        if not isinstance(lease.get(lf), str) or not lease[lf]:
                            errs.append(f"{name}: leases[{idx}] 缺少非空字段 {lf!r}")
            caps = result.get("capabilities")
            caps_schema = schema["properties"]["capabilities"]
            forbidden = frozenset(schema.get("x-forbiddenKeys", []))
            errs.extend(validate_against_schema(caps, caps_schema, f"{name}.response.result.capabilities"))
            errs.extend(find_forbidden_keys(caps, forbidden, f"{name}.response.result.capabilities"))

    if method == "snapshot":
        scope = fixture.get("sourceScope")
        if not isinstance(scope, str) or not scope.startswith("adapter:"):
            errs.append(f"{name}: snapshot 夹具必须声明 adapter:<id> 格式的 sourceScope")
        result = resp.get("result")
        if not isinstance(result, dict):
            errs.append(f"{name}: snapshot.result 必须是对象")
        else:
            if not isinstance(result.get("capturedAt"), str) or not result["capturedAt"]:
                errs.append(f"{name}: snapshot.result.capturedAt 必须是非空字符串")
            devices = result.get("devices")
            if not isinstance(devices, list) or not devices:
                errs.append(f"{name}: snapshot.result.devices 必须是非空数组")
            else:
                for idx, dev in enumerate(devices):
                    if not isinstance(dev, dict):
                        errs.append(f"{name}: devices[{idx}] 必须是对象")
                        continue
                    for df in ("nativeId", "name", "kind", "online", "identity"):
                        if df not in dev:
                            errs.append(f"{name}: devices[{idx}] 缺少 {df!r}")
                    if dev.get("kind") not in allowed_kinds:
                        errs.append(f"{name}: devices[{idx}].kind 非法: {dev.get('kind')!r}")
                    signals = dev.get("safetySignals", [])
                    if not isinstance(signals, list):
                        errs.append(f"{name}: devices[{idx}].safetySignals 必须是数组")
                    else:
                        for sidx, sig in enumerate(signals):
                            if not isinstance(sig, dict):
                                errs.append(f"{name}: devices[{idx}].safetySignals[{sidx}] 必须是对象")
                                continue
                            if sig.get("kind") not in allowed_alerts:
                                errs.append(f"{name}: devices[{idx}].safetySignals[{sidx}].kind 非法")
                            bad_sig_keys = sorted(set(sig) & FORBIDDEN_SIGNAL_KEYS)
                            if bad_sig_keys:
                                errs.append(f"{name}: safetySignals[{sidx}] 禁止携带策略字段: {', '.join(bad_sig_keys)}")

    err_sample = fixture.get("errorResponseExample")
    if err_sample is not None:
        if not isinstance(err_sample, dict) or err_sample.get("jsonrpc") != "2.0":
            errs.append(f"{name}: errorResponseExample 必须是合法 JSON-RPC 2.0 对象")
        else:
            err_obj = err_sample.get("error")
            if not isinstance(err_obj, dict):
                errs.append(f"{name}: errorResponseExample.error 必须是对象")
            else:
                code = err_obj.get("code")
                data = err_obj.get("data")
                expected_adapter_code = ADAPTER_ERROR_CODES.get(code)
                if expected_adapter_code is None:
                    errs.append(f"{name}: errorResponseExample.error.code {code!r} 未对齐 AdapterErrorCode")
                elif not isinstance(data, dict) or data.get("adapterCode") != expected_adapter_code:
                    errs.append(f"{name}: errorResponseExample.error.data.adapterCode 应为 {expected_adapter_code!r}")
                elif not isinstance(data.get("retryable"), bool):
                    errs.append(f"{name}: errorResponseExample.error.data.retryable 必须是布尔值")

    return errs


def run_check() -> list[str]:
    errs: list[str] = []
    if not SCHEMA_PATH.is_file():
        return [f"缺少 Schema 文件: {SCHEMA_PATH}"]
    if not FIXTURES_DIR.is_dir():
        return [f"缺少黄金语料目录: {FIXTURES_DIR}"]

    try:
        schema = load_strict_json(SCHEMA_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"解析 {SCHEMA_PATH} 失败: {exc}"]

    if not isinstance(schema, dict) or schema.get("additionalProperties") is not False:
        errs.append("Schema 根节点必须设置 additionalProperties: false")
    if not schema.get("x-forbiddenKeys"):
        errs.append("Schema 必须声明 x-forbiddenKeys 禁止字段表")

    valid_manifests = sorted(FIXTURES_DIR.glob("manifest-valid-*.json"))
    invalid_manifests = sorted(FIXTURES_DIR.glob("manifest-invalid-*.json"))
    rpc_pairs = sorted(
        p for p in FIXTURES_DIR.glob("rpc-*-pair.json")
        if not p.name.startswith("rpc-invalid-")
    )
    invalid_rpc_fixtures = sorted(FIXTURES_DIR.glob("rpc-invalid-*.json"))

    if not valid_manifests:
        errs.append("缺少合法 manifest 夹具 (manifest-valid-*.json)")
    if not invalid_manifests:
        errs.append("缺少非法 manifest 夹具 (manifest-invalid-*.json)")
    if len(rpc_pairs) < 2:
        errs.append("至少需要 initialize 与 snapshot 两组 RPC 夹具 (rpc-*-pair.json)")
    if not invalid_rpc_fixtures:
        errs.append("缺少非法 RPC 夹具 (rpc-invalid-*.json)")

    for path in valid_manifests:
        try:
            data = load_strict_json(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errs.append(f"{path.name}: JSON 解析失败: {exc}")
            continue
        m_errs = validate_manifest(data, schema)
        for e in m_errs:
            errs.append(f"{path.name} 应合法但校验失败: {e}")

    for path in invalid_manifests:
        try:
            data = load_strict_json(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errs.append(f"{path.name}: JSON 解析失败: {exc}")
            continue
        m_errs = validate_manifest(data, schema)
        if not m_errs:
            errs.append(f"{path.name} 应被拒绝但却通过了校验")

    for path in rpc_pairs:
        try:
            data = load_strict_json(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errs.append(f"{path.name}: JSON 解析失败: {exc}")
            continue
        errs.extend(validate_rpc_pair(data, schema, path.name))

    for path in invalid_rpc_fixtures:
        try:
            data = load_strict_json(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errs.append(f"{path.name}: JSON 解析失败: {exc}")
            continue
        r_errs = validate_rpc_pair(data, schema, path.name)
        if not r_errs:
            errs.append(f"{path.name} 应被拒绝但却通过了校验")

    return errs


def run_self_test() -> None:
    schema = load_strict_json(SCHEMA_PATH.read_text(encoding="utf-8"))
    valid = load_strict_json((FIXTURES_DIR / "manifest-valid-readonly.json").read_text(encoding="utf-8"))
    assert validate_manifest(valid, schema) == [], "baseline valid manifest should pass"

    # 1. Forbidden key nested inside capabilities must fail
    nested_bad = copy.deepcopy(valid)
    nested_bad["capabilities"]["severity"] = "warning"
    assert validate_manifest(nested_bad, schema), "nested forbidden key must fail"

    # 2. Write commands in v0 must fail
    write_bad = copy.deepcopy(valid)
    write_bad["capabilities"]["commands"] = ["power"]
    assert validate_manifest(write_bad, schema), "non-empty commands in v0 must fail"

    # 3. Undeclared vendor.hosts must fail
    host_bad = copy.deepcopy(valid)
    host_bad["vendor"]["hosts"] = ["evil.example.com"]
    assert any("vendor.hosts" in e for e in validate_manifest(host_bad, schema)), "undeclared vendor host must fail"

    # 4. Path traversal in runtime.entry must fail
    entry_bad = copy.deepcopy(valid)
    entry_bad["runtime"]["entry"] = "../../bin/sh"
    assert validate_manifest(entry_bad, schema), "path traversal entry must fail"

    # 5. RPC safetySignal carrying severity must fail
    snap = load_strict_json((FIXTURES_DIR / "rpc-snapshot-pair.json").read_text(encoding="utf-8"))
    assert validate_rpc_pair(snap, schema, "self-test-snap") == []
    bad_snap = copy.deepcopy(snap)
    bad_snap["response"]["result"]["devices"][0]["safetySignals"][0]["severity"] = "warning"
    assert validate_rpc_pair(bad_snap, schema, "self-test-snap"), "severity in safetySignals must fail"

    # 6. RPC initialize lease carrying refreshToken or static apiKey must fail
    init = load_strict_json((FIXTURES_DIR / "rpc-initialize-pair.json").read_text(encoding="utf-8"))
    assert validate_rpc_pair(init, schema, "self-test-init") == []
    bad_init = copy.deepcopy(init)
    bad_init["request"]["params"]["leases"][0]["refreshToken"] = "nope"
    assert validate_rpc_pair(bad_init, schema, "self-test-init"), "refreshToken in lease must fail"
    bad_init_static_key = copy.deepcopy(init)
    bad_init_static_key["request"]["params"]["leases"][0]["kind"] = "apiKey"
    assert validate_rpc_pair(bad_init_static_key, schema, "self-test-init"), "static apiKey lease must fail"

    # 7. RPC initialize response capabilities must validate full schema (including empty commands)
    bad_init_caps = copy.deepcopy(init)
    bad_init_caps["response"]["result"]["capabilities"]["commands"] = ["power"]
    caps_errs = validate_rpc_pair(bad_init_caps, schema, "self-test-init-caps")
    assert any("commands" in e for e in caps_errs), "non-empty commands in initialize response must fail"

    bad_init_extra_cap = copy.deepcopy(init)
    bad_init_extra_cap["response"]["result"]["capabilities"]["extraFlag"] = True
    assert validate_rpc_pair(bad_init_extra_cap, schema, "self-test-init-extra"), "undeclared capability key must fail"

    invalid_rpc = load_strict_json((FIXTURES_DIR / "rpc-invalid-initialize-write-caps.json").read_text(encoding="utf-8"))
    assert any("commands" in e for e in validate_rpc_pair(invalid_rpc, schema, "rpc-invalid-initialize-write-caps.json")), (
        "invalid initialize write-commands fixture must fail"
    )
    assert run_check() == [], "fixture suite check should pass"

    # 8. Duplicate JSON keys must fail strict loader
    try:
        load_strict_json('{"a": 1, "a": 2}')
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate JSON keys must raise ValueError")

    print("✅ check_adapter_protocol.py 自检通过！")


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        run_self_test()
        return 0
    errs = run_check()
    if errs:
        for err in errs:
            print(f"❌ {err}", file=sys.stderr)
        return 1
    print("✅ 进程外适配器协议 Schema 与黄金语料校验通过！")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
