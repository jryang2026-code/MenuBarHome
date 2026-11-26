#!/usr/bin/env python3
"""Validate the shared TV/display protocol catalog and its v1 RPC golden corpus.

Uses Python standard library only.
"""
from __future__ import annotations

import copy
import json
import pathlib
import re
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "Shared" / "tvProtocolCatalog.json"
FIXTURES_DIR = ROOT / "Tests" / "Fixtures" / "tv-plugin"
GOLDEN_PATH = FIXTURES_DIR / "tv_catalog_golden.json"
RPC_PATH = FIXTURES_DIR / "v1_control_rpc_pairs.json"

EXPECTED_CATALOG_ID = "menubarhome.tv-protocol-catalog"
EXPECTED_SCHEMA_VERSION = 1
EXPECTED_ADAPTER_ID = "com.menubarhome.tv-bridge"
EXPECTED_RPC_VERSION = "1.0"

REQUIRED_PROFILE_FIELDS = (
    "id",
    "displayNames",
    "kind",
    "vendors",
    "models",
    "transport",
    "pairing",
    "capabilities",
    "commands",
    "limitations",
)
REQUIRED_TRANSPORT_FIELDS = ("family", "channels", "ports", "discovery")
REQUIRED_PAIRING_FIELDS = ("required", "method", "inputs", "notes")
REQUIRED_CAPABILITY_FIELDS = (
    "power",
    "volume",
    "mute",
    "inputSource",
    "directionalKeys",
    "nowPlaying",
    "supportsNowPlayingSeek",
    "wakeOnLan",
)
ALLOWED_KINDS = frozenset({"display", "tv", "media"})
CLOSED_COMMAND_VERBS = (
    "power.set",
    "display.brightness.set",
    "volume.set",
    "mute.set",
    "input.select",
    "remote.key",
    "media.play",
    "media.pause",
    "media.stop",
    "media.seek",
)
SEEKABLE_IDS = frozenset({"dlna_dmr", "chromecast", "kodi_jsonrpc", "jellyfin_api"})
COLD_BOOT_UNSUPPORTED_IDS = frozenset({"xiaomi_mitv_6095", "redmi_ddc_display"})
DDC_PROFILE_ID = "redmi_ddc_display"
DDC_VCP_CODES = frozenset({"0x10", "0x60", "0x62", "0x8D"})
DDC_INPUT_VALUES = {"DP1": 15, "DP2": 16, "HDMI1": 17, "HDMI2": 18, "USBC": 27}
TCL_PROFILE_ID = "tcl_ffalcon_tnscreen"
TCL_KEY_ACTIONS = {"up": 11, "down": 12, "left": 13, "right": 14, "ok": 15, "back": 16, "home": 19, "power": 20, "source": 29}
ADB_PROFILE_ID = "android_adb_lan"
ADB_HDMI_KEYCODES = [243, 244, 245, 246]
FALSE_FLAGS = {
    "samsung_tizen_ws": ("directHdmiSwitch",),
    "hisense_vidaa_mqtt": ("chinaJuuiSupported",),
}
BEACON_IDS = (
    "redmi_ddc_display",
    "xiaomi_mitv_6095",
    "tcl_ffalcon_tnscreen",
    "android_adb_lan",
    "lg_webos_ssap",
    "android_tv_remote_v2",
    "samsung_tizen_ws",
    "sony_bravia_psk",
    "hisense_vidaa_mqtt",
    "dlna_dmr",
    "chromecast",
    "kodi_jsonrpc",
    "jellyfin_api",
)

FORBIDDEN_KEY_NAMES = frozenset({
    "secret",
    "secrets",
    "token",
    "accessToken",
    "refreshToken",
    "passToken",
    "password",
    "apiKey",
    "apikey",
    "clientSecret",
    "privateKey",
    "cookie",
    "session",
    "credentials",
})
FORBIDDEN_VCP_RE = re.compile(r"0[xX]0*[dD]6\b")
PROFILE_ID_RE = re.compile(r"^[a-z0-9_]+$")
ARTWORK_SEGMENT_RE = re.compile(r"^[A-Za-z0-9._-]+$")

V1_METHODS = frozenset({
    "control.execute",
    "host.contextChanged",
    "media.fetchArtwork",
    "pairing.begin",
    "pairing.submit",
    "pairing.cancel",
    "events.mediaPlaybackChanged",
})
NOTIFICATION_METHODS = frozenset({"host.contextChanged", "events.mediaPlaybackChanged"})
PLAYBACK_STATES = frozenset({"playing", "paused", "stopped", "idle", "buffering"})
EXPECTED_ERRORS = {
    -32004: "unsupported",
    -32602: "unknown",
}


def load_strict_json(text: str) -> Any:
    def no_dups(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key, value in pairs:
            if key in out:
                raise ValueError(f"重复 JSON 键: {key}")
            out[key] = value
        return out

    return json.loads(text, object_pairs_hook=no_dups)


def is_nonempty_str(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def normalize_vcp(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"0[xX]([0-9a-fA-F]{2})", value.strip())
    if match is None:
        return None
    return "0x" + match.group(1).upper()


def is_forbidden_key_name(key: str) -> bool:
    lowered = key.lower()
    if lowered in {item.lower() for item in FORBIDDEN_KEY_NAMES}:
        return True
    return lowered.endswith(("token", "secret", "password", "apikey", "credentials"))


def find_forbidden_keys(value: Any, path: str = "$") -> list[str]:
    errs: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if is_forbidden_key_name(key):
                errs.append(f"{child_path}: 命中禁止的密钥键名 {key!r}")
            errs.extend(find_forbidden_keys(child, child_path))
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            errs.extend(find_forbidden_keys(child, f"{path}[{idx}]"))
    return errs


def find_forbidden_vcp(value: Any, path: str = "$", in_forbidden_list: bool = False) -> list[str]:
    errs: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            child_forbidden = in_forbidden_list or key == "forbiddenVcpCodes"
            if key in {"code", "vcpCode"} and normalize_vcp(child) == "0xD6" and not child_forbidden:
                errs.append(f"{child_path}: 禁止使用 VCP 0xD6")
            errs.extend(find_forbidden_vcp(child, child_path, child_forbidden))
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            errs.extend(find_forbidden_vcp(child, f"{path}[{idx}]", in_forbidden_list))
    elif isinstance(value, str) and not in_forbidden_list and FORBIDDEN_VCP_RE.search(value):
        errs.append(f"{path}: 禁止出现 VCP 0xD6 文字: {value!r}")
    return errs


def validate_golden(golden: Any) -> list[str]:
    errs: list[str] = []
    if not isinstance(golden, dict):
        return ["黄金语料根节点必须是对象"]

    expected_lists = {
        "requiredProfileFields": REQUIRED_PROFILE_FIELDS,
        "requiredTransportFields": REQUIRED_TRANSPORT_FIELDS,
        "requiredPairingFields": REQUIRED_PAIRING_FIELDS,
        "requiredCapabilityFields": REQUIRED_CAPABILITY_FIELDS,
        "expectedClosedCommandVerbs": CLOSED_COMMAND_VERBS,
    }
    for name, expected in expected_lists.items():
        if golden.get(name) != list(expected):
            errs.append(f"黄金语料 {name} 与校验脚本常量不一致")

    if set(golden.get("allowedKinds", [])) != set(ALLOWED_KINDS):
        errs.append("黄金语料 allowedKinds 与校验脚本常量不一致")
    if golden.get("catalogId") != EXPECTED_CATALOG_ID:
        errs.append("黄金语料 catalogId 不匹配")
    if golden.get("schemaVersion") != EXPECTED_SCHEMA_VERSION:
        errs.append("黄金语料 schemaVersion 不匹配")

    ids = golden.get("expectedProfileIds")
    if not isinstance(ids, list) or len(ids) != len(set(ids)):
        errs.append("黄金语料 expectedProfileIds 必须是唯一数组")
    elif tuple(ids) != BEACON_IDS:
        errs.append("黄金语料 expectedProfileIds 与校验脚本常量不一致")

    if set(golden.get("expectedKinds", {})) != set(BEACON_IDS):
        errs.append("黄金语料 expectedKinds 必须覆盖全部协议 ID")
    if set(golden.get("protocolBeacons", {})) != set(BEACON_IDS):
        errs.append("黄金语料 protocolBeacons 必须覆盖全部协议 ID")
    if set(golden.get("expectedSeekableIds", [])) != SEEKABLE_IDS:
        errs.append("黄金语料 expectedSeekableIds 与校验脚本常量不一致")
    if set(golden.get("expectedColdBootUnsupportedIds", [])) != COLD_BOOT_UNSUPPORTED_IDS:
        errs.append("黄金语料 expectedColdBootUnsupportedIds 与校验脚本常量不一致")
    if golden.get("expectedDdcVcpCodes") != sorted(DDC_VCP_CODES):
        errs.append("黄金语料 expectedDdcVcpCodes 与校验脚本常量不一致")
    if golden.get("expectedDdcInputValues") != DDC_INPUT_VALUES:
        errs.append("黄金语料 expectedDdcInputValues 与校验脚本常量不一致")
    if golden.get("expectedTclKeyActions") != TCL_KEY_ACTIONS:
        errs.append("黄金语料 expectedTclKeyActions 与校验脚本常量不一致")
    if golden.get("expectedAdbHdmiKeycodes") != ADB_HDMI_KEYCODES:
        errs.append("黄金语料 expectedAdbHdmiKeycodes 与校验脚本常量不一致")
    if golden.get("forbiddenVcpCodes") != ["0xD6"]:
        errs.append("黄金语料 forbiddenVcpCodes 必须为 ['0xD6']")
    if set(golden.get("expectedFalseFlags", {})) != set(FALSE_FLAGS):
        errs.append("黄金语料 expectedFalseFlags 必须覆盖全部受约束协议 ID")
    for profile_id, field_names in FALSE_FLAGS.items():
        if golden.get("expectedFalseFlags", {}).get(profile_id) != list(field_names):
            errs.append(f"黄金语料 expectedFalseFlags.{profile_id} 与校验脚本常量不一致")
    return errs


def validate_profile(profile: Any, path: str, golden: dict[str, Any], closed_verbs: list[str]) -> list[str]:
    errs: list[str] = []
    if not isinstance(profile, dict):
        return [f"{path}: 协议画像必须是对象"]

    for field in REQUIRED_PROFILE_FIELDS:
        if field not in profile:
            errs.append(f"{path}: 缺少必填字段 {field!r}")

    profile_id = profile.get("id")
    if not is_nonempty_str(profile_id) or PROFILE_ID_RE.fullmatch(profile_id) is None:
        errs.append(f"{path}.id: 必须是小写 snake_case 字符串")

    names = profile.get("displayNames")
    if not isinstance(names, dict):
        errs.append(f"{path}.displayNames: 必须是对象")
    else:
        for lang in ("zh", "en"):
            if not is_nonempty_str(names.get(lang)):
                errs.append(f"{path}.displayNames.{lang}: 必须是非空字符串")

    if profile.get("kind") not in ALLOWED_KINDS:
        errs.append(f"{path}.kind: 非法值 {profile.get('kind')!r}")

    for field in ("vendors", "models"):
        value = profile.get(field)
        if not isinstance(value, list) or not value or not all(is_nonempty_str(item) for item in value):
            errs.append(f"{path}.{field}: 必须是非空字符串数组")

    transport = profile.get("transport")
    if not isinstance(transport, dict):
        errs.append(f"{path}.transport: 必须是对象")
    else:
        for field in REQUIRED_TRANSPORT_FIELDS:
            if field not in transport:
                errs.append(f"{path}.transport: 缺少 {field!r}")
        if not is_nonempty_str(transport.get("family")):
            errs.append(f"{path}.transport.family: 必须是非空字符串")
        channels = transport.get("channels")
        if not isinstance(channels, list) or not channels or not all(is_nonempty_str(item) for item in channels):
            errs.append(f"{path}.transport.channels: 必须是非空字符串数组")
        discovery = transport.get("discovery")
        if not isinstance(discovery, list) or not all(is_nonempty_str(item) for item in discovery):
            errs.append(f"{path}.transport.discovery: 必须是字符串数组")
        ports = transport.get("ports")
        if not isinstance(ports, list):
            errs.append(f"{path}.transport.ports: 必须是数组")
        else:
            for idx, port in enumerate(ports):
                port_path = f"{path}.transport.ports[{idx}]"
                if not isinstance(port, dict):
                    errs.append(f"{port_path}: 必须是对象")
                    continue
                if not is_int(port.get("number")) or not 1 <= port["number"] <= 65535:
                    errs.append(f"{port_path}.number: 必须是 1 到 65535 的整数")
                if not is_nonempty_str(port.get("protocol")):
                    errs.append(f"{port_path}.protocol: 必须是非空字符串")

    pairing = profile.get("pairing")
    if not isinstance(pairing, dict):
        errs.append(f"{path}.pairing: 必须是对象")
    else:
        for field in REQUIRED_PAIRING_FIELDS:
            if field not in pairing:
                errs.append(f"{path}.pairing: 缺少 {field!r}")
        if not isinstance(pairing.get("required"), bool):
            errs.append(f"{path}.pairing.required: 必须是布尔值")
        if not is_nonempty_str(pairing.get("method")):
            errs.append(f"{path}.pairing.method: 必须是非空字符串")
        for field in ("inputs", "notes"):
            value = pairing.get(field)
            if not isinstance(value, list) or not all(is_nonempty_str(item) for item in value):
                errs.append(f"{path}.pairing.{field}: 必须是字符串数组")

    capabilities = profile.get("capabilities")
    if not isinstance(capabilities, dict):
        errs.append(f"{path}.capabilities: 必须是对象")
    else:
        for field in REQUIRED_CAPABILITY_FIELDS:
            if not isinstance(capabilities.get(field), bool):
                errs.append(f"{path}.capabilities.{field}: 必须是布尔值")
        if capabilities.get("supportsNowPlayingSeek") is True and capabilities.get("nowPlaying") is not True:
            errs.append(f"{path}.capabilities: supportsNowPlayingSeek 为真时 nowPlaying 必须为真")

    commands = profile.get("commands")
    if not isinstance(commands, list) or not commands:
        errs.append(f"{path}.commands: 必须是非空数组")
    else:
        unknown = [verb for verb in commands if verb not in closed_verbs]
        if unknown:
            errs.append(f"{path}.commands: 含封闭动词表之外的命令 {unknown!r}")
        if len(commands) != len(set(commands)):
            errs.append(f"{path}.commands: 存在重复命令")

    limitations = profile.get("limitations")
    if not isinstance(limitations, list) or not limitations or not all(is_nonempty_str(item) for item in limitations):
        errs.append(f"{path}.limitations: 必须是非空字符串数组")

    if "metadata" in profile and not isinstance(profile["metadata"], dict):
        errs.append(f"{path}.metadata: 必须是对象")
    return errs


def validate_catalog(catalog: Any, golden: dict[str, Any]) -> list[str]:
    errs: list[str] = []
    if not isinstance(catalog, dict):
        return ["协议目录根节点必须是对象"]

    if catalog.get("schemaVersion") != EXPECTED_SCHEMA_VERSION:
        errs.append("协议目录 schemaVersion 不匹配")
    if catalog.get("catalogId") != EXPECTED_CATALOG_ID:
        errs.append("协议目录 catalogId 不匹配")
    if not is_nonempty_str(catalog.get("description")):
        errs.append("协议目录 description 必须是非空字符串")

    closed_verbs = catalog.get("closedCommandVerbs")
    if closed_verbs != list(CLOSED_COMMAND_VERBS):
        errs.append("协议目录 closedCommandVerbs 与校验脚本常量不一致")
    if isinstance(closed_verbs, list) and len(closed_verbs) != len(set(closed_verbs)):
        errs.append("协议目录 closedCommandVerbs 存在重复值")

    errs.extend(find_forbidden_keys(catalog))
    errs.extend(find_forbidden_vcp(catalog))

    profiles = catalog.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        errs.append("协议目录 profiles 必须是非空数组")
        return errs

    by_id: dict[str, dict[str, Any]] = {}
    for idx, profile in enumerate(profiles):
        path = f"$.profiles[{idx}]"
        if isinstance(profile, dict) and is_nonempty_str(profile.get("id")):
            profile_id = profile["id"]
            if profile_id in by_id:
                errs.append(f"{path}.id: 重复协议 ID {profile_id!r}")
            else:
                by_id[profile_id] = profile
        errs.extend(validate_profile(profile, path, golden, CLOSED_COMMAND_VERBS))

    expected_ids = golden.get("expectedProfileIds", [])
    if sorted(by_id) != sorted(expected_ids):
        missing = sorted(set(expected_ids) - set(by_id))
        extra = sorted(set(by_id) - set(expected_ids))
        errs.append(f"协议 ID 与黄金语料不一致，缺少 {missing!r}，多出 {extra!r}")

    actual_kinds = {profile_id: profile.get("kind") for profile_id, profile in by_id.items()}
    if actual_kinds != golden.get("expectedKinds"):
        errs.append("协议 kind 与黄金语料不一致")

    actual_seekable = {
        profile_id for profile_id, profile in by_id.items()
        if isinstance(profile.get("capabilities"), dict)
        and profile["capabilities"].get("supportsNowPlayingSeek") is True
    }
    if actual_seekable != SEEKABLE_IDS:
        errs.append(f"可跳转媒体协议集合不一致，实际为 {sorted(actual_seekable)!r}")

    for profile_id in COLD_BOOT_UNSUPPORTED_IDS:
        profile = by_id.get(profile_id)
        if isinstance(profile, dict) and profile.get("metadata", {}).get("coldBootSupported") is not False:
            errs.append(f"{profile_id}: metadata.coldBootSupported 必须为 false")

    tcl = by_id.get(TCL_PROFILE_ID)
    if isinstance(tcl, dict) and tcl.get("metadata", {}).get("keyActions") != TCL_KEY_ACTIONS:
        errs.append("tcl_ffalcon_tnscreen 按键码表不匹配")
    if isinstance(tcl, dict) and tcl.get("metadata", {}).get("adbRequired") is not False:
        errs.append("tcl_ffalcon_tnscreen 必须标注 adbRequired: false")

    adb = by_id.get(ADB_PROFILE_ID)
    if isinstance(adb, dict) and adb.get("metadata", {}).get("hdmiKeycodes") != ADB_HDMI_KEYCODES:
        errs.append("android_adb_lan HDMI keycode 映射不匹配")

    ddc = by_id.get(DDC_PROFILE_ID)
    if isinstance(ddc, dict):
        metadata = ddc.get("metadata", {})
        vcp_codes = {
            normalize_vcp(item.get("code"))
            for item in metadata.get("vcpCodes", [])
            if isinstance(item, dict)
        }
        if vcp_codes != DDC_VCP_CODES:
            errs.append("redmi_ddc_display VCP 白名单必须恰好包含 0x10、0x60、0x62、0x8D")
        source_values = {}
        for item in metadata.get("vcpCodes", []):
            if isinstance(item, dict) and normalize_vcp(item.get("code")) == "0x60":
                source_values = item.get("values")
        if source_values != DDC_INPUT_VALUES:
            errs.append("redmi_ddc_display 输入源 VCP 0x60 取值表不匹配")
        forbidden = [normalize_vcp(value) for value in metadata.get("forbiddenVcpCodes", [])]
        if "0xD6" not in forbidden:
            errs.append("redmi_ddc_display 必须在 forbiddenVcpCodes 中禁用 0xD6")
        note = metadata.get("macOsBridgeNote", "")
        if not isinstance(note, str) or not all(token in note for token in golden.get("macOsBridgeNoteContains", [])):
            errs.append("redmi_ddc_display 缺少 AppleDCPMCDP29XX -> 0xB7 桥片说明")

    for profile_id, field_names in FALSE_FLAGS.items():
        profile = by_id.get(profile_id)
        if not isinstance(profile, dict):
            continue
        metadata = profile.get("metadata", {})
        for field in field_names:
            if metadata.get(field) is not False:
                errs.append(f"{profile_id}: metadata.{field} 必须为 false")

    for profile_id, beacons in golden.get("protocolBeacons", {}).items():
        profile = by_id.get(profile_id)
        if not isinstance(profile, dict) or not isinstance(beacons, list):
            continue
        serialized = json.dumps(profile, ensure_ascii=False).lower()
        for beacon in beacons:
            if not isinstance(beacon, str) or beacon.lower() not in serialized:
                errs.append(f"{profile_id}: 缺少协议事实 {beacon!r}")
    return errs


def artwork_path_allowed(value: Any) -> bool:
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value or ":" in value:
        return False
    segments = value.split("/")
    if len(segments) != 4 or segments[0] != "artwork":
        return False
    return all(ARTWORK_SEGMENT_RE.fullmatch(segment) is not None and segment not in {".", ".."} for segment in segments)


def validate_error(error: Any, name: str, allowed_codes: set[int] | None = None) -> list[str]:
    errs: list[str] = []
    if not isinstance(error, dict):
        return [f"{name}: response.error 必须是对象"]
    code = error.get("code")
    if not is_int(code):
        errs.append(f"{name}: response.error.code 必须是整数")
        return errs
    if allowed_codes is not None and code not in allowed_codes:
        errs.append(f"{name}: response.error.code {code!r} 不在允许集合 {sorted(allowed_codes)!r}")
    expected_adapter_code = EXPECTED_ERRORS.get(code)
    data = error.get("data")
    if expected_adapter_code is None:
        errs.append(f"{name}: response.error.code {code!r} 未定义 adapterCode 映射")
    elif not isinstance(data, dict) or data.get("adapterCode") != expected_adapter_code:
        errs.append(f"{name}: response.error.data.adapterCode 应为 {expected_adapter_code!r}")
    elif not isinstance(data.get("retryable"), bool):
        errs.append(f"{name}: response.error.data.retryable 必须是布尔值")
    return errs


def validate_case(case: Any, expected_name: str, closed_verbs: list[str]) -> list[str]:
    errs: list[str] = []
    if not isinstance(case, dict):
        return [f"{expected_name}: 夹具必须是对象"]
    if case.get("name") != expected_name:
        errs.append(f"{expected_name}: name 字段与键名不一致")

    expect = case.get("expect")
    if expect not in {"accept", "reject"}:
        errs.append(f"{expected_name}: expect 必须为 accept 或 reject")

    request = case.get("request")
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
        errs.append(f"{expected_name}: request 必须是 JSON-RPC 2.0 对象")
        return errs
    method = request.get("method")
    if method not in V1_METHODS:
        errs.append(f"{expected_name}: 非法 v1 方法 {method!r}")
        return errs

    has_id = "id" in request
    if method in NOTIFICATION_METHODS and has_id:
        errs.append(f"{expected_name}: 通知方法不能携带 id")
    if method not in NOTIFICATION_METHODS and not has_id:
        errs.append(f"{expected_name}: 请求方法必须携带 id")

    response = case.get("response")
    if method in NOTIFICATION_METHODS:
        if response is not None:
            errs.append(f"{expected_name}: 通知夹具的 response 必须为 null")
        if expect != "accept":
            errs.append(f"{expected_name}: 通知夹具必须为 accept")
    else:
        if not isinstance(response, dict) or response.get("jsonrpc") != "2.0":
            errs.append(f"{expected_name}: response 必须是 JSON-RPC 2.0 对象")
            return errs
        if response.get("id") != request.get("id"):
            errs.append(f"{expected_name}: request 与 response 的 id 必须一致")
        has_result = "result" in response
        has_error = "error" in response
        if has_result == has_error:
            errs.append(f"{expected_name}: response 必须恰好包含 result 或 error")
        elif expect == "accept" and not has_result:
            errs.append(f"{expected_name}: accept 夹具必须返回 result")
        elif expect == "reject" and not has_error:
            errs.append(f"{expected_name}: reject 夹具必须返回 error")

        if has_error:
            allowed_codes = {-32004} if method == "control.execute" else {-32602}
            errs.extend(validate_error(response["error"], expected_name, allowed_codes))
            if method not in {"control.execute", "media.fetchArtwork"}:
                errs.append(f"{expected_name}: 只有 control.execute 与 media.fetchArtwork 允许 reject 夹具")

        if expect == "accept" and has_result and not isinstance(response["result"], dict):
            errs.append(f"{expected_name}: response.result 必须是对象")

    params = request.get("params")
    if not isinstance(params, dict):
        errs.append(f"{expected_name}: request.params 必须是对象")
        return errs

    if method == "control.execute":
        if expect == "accept":
            for field in ("grantId", "capabilityGeneration", "nativeId", "verb"):
                if field not in params:
                    errs.append(f"{expected_name}: control.execute.params 缺少 {field!r}")
            if not is_nonempty_str(params.get("grantId")):
                errs.append(f"{expected_name}: grantId 必须是非空字符串")
            if not is_int(params.get("capabilityGeneration")) or params["capabilityGeneration"] < 1:
                errs.append(f"{expected_name}: capabilityGeneration 必须是正整数")
            if params.get("verb") not in closed_verbs:
                errs.append(f"{expected_name}: verb 不在封闭命令动词表内")
            if not is_nonempty_str(params.get("nativeId")):
                errs.append(f"{expected_name}: nativeId 必须是非空字符串")
            if "args" in params and not isinstance(params["args"], dict):
                errs.append(f"{expected_name}: args 必须是对象")
        else:
            data = response.get("error", {}).get("data", {}) if isinstance(response, dict) else {}
            if not isinstance(data, dict) or data.get("adapterCode") != "unsupported":
                errs.append(f"{expected_name}: 写拒绝必须归一为 unsupported")

    elif method == "host.contextChanged":
        if not is_nonempty_str(params.get("scope")):
            errs.append(f"{expected_name}: scope 必须是非空字符串")
        if not isinstance(params.get("active"), bool):
            errs.append(f"{expected_name}: active 必须是布尔值")
        if not is_nonempty_str(params.get("reason")):
            errs.append(f"{expected_name}: reason 必须是非空字符串")

    elif method == "events.mediaPlaybackChanged":
        if not is_nonempty_str(params.get("nativeId")):
            errs.append(f"{expected_name}: nativeId 必须是非空字符串")
        if params.get("playbackState") not in PLAYBACK_STATES:
            errs.append(f"{expected_name}: playbackState 非法")
        if not isinstance(params.get("canSeek"), bool):
            errs.append(f"{expected_name}: canSeek 必须是布尔值")
        if not is_nonempty_str(params.get("ts")):
            errs.append(f"{expected_name}: ts 必须是非空字符串")
        if params.get("canSeek") is True:
            duration = params.get("durationSec")
            position = params.get("positionSec")
            if not isinstance(duration, (int, float)) or isinstance(duration, bool) or duration <= 0:
                errs.append(f"{expected_name}: canSeek 为真时 durationSec 必须是正数")
            elif not isinstance(position, (int, float)) or isinstance(position, bool) or position < 0 or position > duration:
                errs.append(f"{expected_name}: canSeek 为真时 positionSec 必须在 0 与 durationSec 之间")
        else:
            if "durationSec" in params or "positionSec" in params:
                errs.append(f"{expected_name}: canSeek 为假时禁止携带伪进度字段")
        artwork_path = params.get("artworkPath")
        if artwork_path is not None and not artwork_path_allowed(artwork_path):
            errs.append(f"{expected_name}: artworkPath 必须是受限相对路径")

    elif method == "media.fetchArtwork":
        if not is_nonempty_str(params.get("nativeId")):
            errs.append(f"{expected_name}: nativeId 必须是非空字符串")
        path = params.get("path")
        if expect == "accept":
            if not artwork_path_allowed(path):
                errs.append(f"{expected_name}: path 必须是 artwork/<year>/<month>/<name> 相对路径")
            max_bytes = params.get("maxBytes")
            if not is_int(max_bytes) or not 1 <= max_bytes <= 1024 * 1024:
                errs.append(f"{expected_name}: maxBytes 必须是 1 到 1048576 的整数")
            result = response.get("result", {}) if isinstance(response, dict) else {}
            if not isinstance(result, dict) or not is_nonempty_str(result.get("mimeType")) or not is_nonempty_str(result.get("bytesBase64")):
                errs.append(f"{expected_name}: result 必须包含 mimeType 与 bytesBase64")
        else:
            if artwork_path_allowed(path):
                errs.append(f"{expected_name}: reject 夹具必须使用非法路径")
            data = response.get("error", {}).get("data", {}) if isinstance(response, dict) else {}
            if not isinstance(data, dict) or data.get("adapterCode") != "unknown":
                errs.append(f"{expected_name}: 路径穿越必须归一为 unknown")

    elif method == "pairing.begin":
        if not is_nonempty_str(params.get("nativeId")) or not is_nonempty_str(params.get("method")):
            errs.append(f"{expected_name}: pairing.begin 需要 nativeId 与 method")
        result = response.get("result", {}) if isinstance(response, dict) else {}
        if not isinstance(result, dict) or not is_nonempty_str(result.get("pairingId")):
            errs.append(f"{expected_name}: pairing.begin.result 必须包含 pairingId")
        instructions = result.get("instructions") if isinstance(result, dict) else None
        if not isinstance(instructions, list) or not instructions or not all(is_nonempty_str(item) for item in instructions):
            errs.append(f"{expected_name}: pairing.begin.result.instructions 必须是非空字符串数组")

    elif method == "pairing.submit":
        if not is_nonempty_str(params.get("pairingId")):
            errs.append(f"{expected_name}: pairingId 必须是非空字符串")
        if not isinstance(params.get("inputs"), dict) or not params["inputs"]:
            errs.append(f"{expected_name}: inputs 必须是非空对象")
        result = response.get("result", {}) if isinstance(response, dict) else {}
        if not isinstance(result, dict) or result.get("paired") is not True:
            errs.append(f"{expected_name}: pairing.submit.result.paired 必须为 true")

    elif method == "pairing.cancel":
        if not is_nonempty_str(params.get("pairingId")):
            errs.append(f"{expected_name}: pairingId 必须是非空字符串")
        result = response.get("result", {}) if isinstance(response, dict) else {}
        if not isinstance(result, dict) or result.get("cancelled") is not True:
            errs.append(f"{expected_name}: pairing.cancel.result.cancelled 必须为 true")

    return errs


def validate_rpc_fixtures(data: Any) -> list[str]:
    errs: list[str] = []
    if not isinstance(data, dict):
        return ["v1 RPC 夹具根节点必须是对象"]
    if not is_nonempty_str(data.get("description")):
        errs.append("v1 RPC 夹具 description 必须是非空字符串")
    if data.get("protocolVersion") != EXPECTED_RPC_VERSION:
        errs.append("v1 RPC 夹具 protocolVersion 必须为 1.0")
    if data.get("adapterId") != EXPECTED_ADAPTER_ID:
        errs.append("v1 RPC 夹具 adapterId 不匹配")

    errs.extend(find_forbidden_keys(data))

    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        errs.append("v1 RPC 夹具 cases 必须是非空数组")
        return errs

    seen: set[str] = set()
    required_methods = set(V1_METHODS)
    for case in cases:
        if not isinstance(case, dict) or not is_nonempty_str(case.get("name")):
            errs.append("v1 RPC 夹具存在无名 case")
            continue
        name = case["name"]
        if name in seen:
            errs.append(f"{name}: case 名称重复")
        seen.add(name)
        method = case.get("request", {}).get("method") if isinstance(case.get("request"), dict) else None
        if method in required_methods:
            required_methods.remove(method)
        errs.extend(validate_case(case, name, CLOSED_COMMAND_VERBS))

    if required_methods:
        errs.append(f"v1 RPC 夹具缺少方法覆盖: {sorted(required_methods)!r}")
    return errs


def run_check() -> list[str]:
    errs: list[str] = []
    for path in (CATALOG_PATH, GOLDEN_PATH, RPC_PATH):
        if not path.is_file():
            errs.append(f"缺少文件: {path.relative_to(ROOT)}")
    if errs:
        return errs

    try:
        catalog = load_strict_json(CATALOG_PATH.read_text(encoding="utf-8"))
        golden = load_strict_json(GOLDEN_PATH.read_text(encoding="utf-8"))
        rpc = load_strict_json(RPC_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"JSON 解析失败: {exc}"]

    errs.extend(validate_golden(golden))
    errs.extend(validate_catalog(catalog, golden))
    errs.extend(validate_rpc_fixtures(rpc))
    return errs


def run_self_test() -> None:
    assert run_check() == [], "golden corpus should pass before mutation tests"

    catalog = load_strict_json(CATALOG_PATH.read_text(encoding="utf-8"))
    rpc = load_strict_json(RPC_PATH.read_text(encoding="utf-8"))
    golden = load_strict_json(GOLDEN_PATH.read_text(encoding="utf-8"))

    duplicate = copy.deepcopy(catalog)
    duplicate["profiles"].append(copy.deepcopy(duplicate["profiles"][0]))
    assert any("重复协议 ID" in err for err in validate_catalog(duplicate, golden)), "duplicate profile id must fail"

    missing_field = copy.deepcopy(catalog)
    del missing_field["profiles"][0]["limitations"]
    assert any("缺少必填字段" in err for err in validate_catalog(missing_field, golden)), "missing required field must fail"

    bad_vcp = copy.deepcopy(catalog)
    bad_vcp["profiles"][0]["metadata"]["vcpCodes"].append({"code": "0xD6", "name": "power"})
    assert any("0xD6" in err for err in validate_catalog(bad_vcp, golden)), "forbidden VCP code must fail"

    secret_key = copy.deepcopy(catalog)
    secret_key["generatedToken"] = "placeholder"
    assert any("禁止的密钥键名" in err for err in validate_catalog(secret_key, golden)), "hardcoded secret key name must fail"

    fake_seek = copy.deepcopy(catalog)
    fake_seek["profiles"][0]["capabilities"]["supportsNowPlayingSeek"] = True
    assert any("nowPlaying" in err for err in validate_catalog(fake_seek, golden)), "fake seek capability must fail"

    missing_grant = copy.deepcopy(rpc)
    del missing_grant["cases"][0]["request"]["params"]["grantId"]
    assert any("grantId" in err for err in validate_rpc_fixtures(missing_grant)), "accept case without grantId must fail"

    traversal = copy.deepcopy(rpc)
    traversal["cases"][6]["request"]["params"]["path"] = "../../etc/passwd"
    assert any("artwork" in err or "path" in err for err in validate_rpc_fixtures(traversal)), "accepted traversal path must fail"

    try:
        load_strict_json('{"a": 1, "a": 2}')
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate JSON keys must raise ValueError")

    print("✅ check_tv_catalog.py 自检通过！")


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        run_self_test()
        return 0
    errs = run_check()
    if errs:
        for err in errs:
            print(f"❌ {err}", file=sys.stderr)
        return 1
    print("✅ 电视与显示器协议目录及黄金语料校验通过！")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
