import type { RaycastDevice, RaycastSnapshot } from "./snapshot";

/**
 * Local device and scene resolution for the no-view commands and AI tools. It mirrors the rules in
 * `scripts/mijia` (name, room-prefixed name, id, pinyin initials/full spelling) so a phrase that works
 * in the CLI or MCP server also works here. Resolution happens against the read-only snapshot; the app
 * still re-resolves the id from the `menumijia://` link before touching a device.
 */
export type DeviceMatch = { ok: true; device: RaycastDevice } | { ok: false; error: string };
export type SceneKind = "scene" | "quick";
export type SceneMatch =
  | { ok: true; kind: SceneKind; id: string; name: string }
  | { ok: false; error: string };

function fold(value: unknown): string {
  return String(value ?? "").trim().toLowerCase();
}

function normalize(value: unknown): string {
  return fold(value).replace(/\s+/g, " ");
}

function deviceExactKeys(device: RaycastDevice): Set<string> {
  const name = fold(device.name);
  const room = fold(device.roomName);
  const short = room && name.startsWith(room) ? name.slice(room.length).trim() : name;
  const initials = fold(device.pinyinInitials);
  const roomInitials = fold(device.roomPinyinInitials);
  const fullPinyin = fold(device.pinyinFull);
  const keys = [
    name,
    `${room}${name}`,
    `${room} ${name}`,
    `${room}${short}`,
    `${room} ${short}`,
    initials,
    `${roomInitials}${initials}`,
    fullPinyin,
  ];
  return new Set(keys.filter((key) => key.trim() !== ""));
}

function deviceHaystacks(device: RaycastDevice): string[] {
  const name = fold(device.name);
  const room = fold(device.roomName);
  const short = room && name.startsWith(room) ? name.slice(room.length).trim() : name;
  const fullPinyin = fold(device.pinyinFull);
  return [name, `${room}${name}`, `${room} ${name}`, `${room} ${short}`, fullPinyin].filter(
    (haystack) => haystack.trim() !== "",
  );
}

function deviceLabel(device: RaycastDevice): string {
  const room = device.roomName ? ` (${device.roomName})` : "";
  return `${device.name}${room} · ${device.id}`;
}

function ambiguous<T>(candidates: T[], query: string, what: string, label: (item: T) => string): string {
  const shown = candidates.slice(0, 5).map(label).join("; ");
  const more = candidates.length > 5 ? `; and ${candidates.length - 5} more` : "";
  return `"${query}" matches ${candidates.length} ${what}s: ${shown}${more}. Be more specific or use the id.`;
}

export function matchDevice(snapshot: RaycastSnapshot, query: string): DeviceMatch {
  const trimmed = query.trim();
  if (!trimmed) {
    return { ok: false, error: "Type a device name, id or pinyin initials." };
  }
  const devices = snapshot.devices ?? [];
  const byId = devices.find((device) => device.id === trimmed);
  if (byId) {
    return { ok: true, device: byId };
  }
  const needle = normalize(trimmed);
  const exact = devices.filter((device) => deviceExactKeys(device).has(needle));
  if (exact.length === 1) {
    return { ok: true, device: exact[0] };
  }
  if (exact.length > 1) {
    return { ok: false, error: ambiguous(exact, trimmed, "device", deviceLabel) };
  }
  const loose = devices.filter((device) =>
    deviceHaystacks(device).some((haystack) => haystack.includes(needle)),
  );
  if (loose.length === 1) {
    return { ok: true, device: loose[0] };
  }
  if (loose.length > 1) {
    return { ok: false, error: ambiguous(loose, trimmed, "device", deviceLabel) };
  }
  return {
    ok: false,
    error: `No device matches "${trimmed}". Run Search Devices to see the visible devices and their ids.`,
  };
}

interface SceneCandidate {
  kind: SceneKind;
  id: string;
  name: string;
  entity?: string;
  pinyinInitials: string;
  pinyinFull: string;
}

function sceneCandidates(snapshot: RaycastSnapshot): SceneCandidate[] {
  const quickActions = (snapshot.quickActions ?? []).map((action) => ({
    kind: "quick" as const,
    id: action.id,
    name: action.name,
    pinyinInitials: action.pinyinInitials,
    pinyinFull: "",
  }));
  const scenes = (snapshot.scenes ?? []).map((scene) => ({
    kind: "scene" as const,
    id: scene.id,
    name: scene.name,
    entity: scene.entityId,
    pinyinInitials: scene.pinyinInitials,
    pinyinFull: scene.pinyinFull,
  }));
  return [...quickActions, ...scenes];
}

function sceneLabel(candidate: SceneCandidate): string {
  return `${candidate.name} (${candidate.kind === "quick" ? "quick action" : "scene"}) · ${candidate.id}`;
}

function sceneResult(candidate: SceneCandidate): SceneMatch {
  return { ok: true, kind: candidate.kind, id: candidate.id, name: candidate.name };
}

export function matchScene(snapshot: RaycastSnapshot, query: string): SceneMatch {
  const trimmed = query.trim();
  if (!trimmed) {
    return { ok: false, error: "Type a scene or quick action name." };
  }
  const candidates = sceneCandidates(snapshot);
  const needle = normalize(trimmed);
  const unprefixed = needle.startsWith("quick:") ? needle.slice("quick:".length).trim() : needle;
  const pool =
    needle.startsWith("quick:") ? candidates.filter((candidate) => candidate.kind === "quick") : candidates;

  const byId = pool.filter(
    (candidate) => fold(candidate.id) === unprefixed || fold(candidate.entity) === unprefixed,
  );
  if (byId.length === 1) {
    return sceneResult(byId[0]);
  }
  if (byId.length > 1) {
    return { ok: false, error: ambiguous(byId, trimmed, "scene", sceneLabel) };
  }
  const exact = pool.filter(
    (candidate) =>
      fold(candidate.name) === unprefixed ||
      fold(candidate.pinyinInitials) === unprefixed ||
      fold(candidate.pinyinFull) === unprefixed,
  );
  if (exact.length === 1) {
    return sceneResult(exact[0]);
  }
  if (exact.length > 1) {
    return { ok: false, error: ambiguous(exact, trimmed, "scene", sceneLabel) };
  }
  const loose = pool.filter(
    (candidate) =>
      fold(candidate.name).includes(unprefixed) ||
      fold(candidate.pinyinInitials).includes(unprefixed) ||
      fold(candidate.pinyinFull).includes(unprefixed),
  );
  if (loose.length === 1) {
    return sceneResult(loose[0]);
  }
  if (loose.length > 1) {
    return { ok: false, error: ambiguous(loose, trimmed, "scene", sceneLabel) };
  }
  return {
    ok: false,
    error: `No scene or quick action matches "${trimmed}". Run Scenes & Quick Actions to browse them.`,
  };
}

/** One human-readable line for HUDs and confirmation dialogs. */
export function describeDevice(device: RaycastDevice): string {
  const state = device.isOnline
    ? device.stateText || (device.isActiveOn ? "On" : "Off")
    : "Offline";
  const room = device.roomName ? ` · ${device.roomName}` : "";
  return `${device.name}${room} · ${state}`;
}
