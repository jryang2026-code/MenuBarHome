import type { HomeScene } from "../models.js";
import { asIdString, MiCloudError } from "./session.js";
import type { MiCloudClient, MiRoom } from "./client.js";

export interface MiCloudScene {
  readonly id: string;
  readonly name: string;
  readonly homeId: string;
  readonly ownerUid: string;
}

export function decodeMiScenes(result: unknown, homeId: string, ownerUid: string): MiCloudScene[] {
  const rows = (result as { manual_scene_info_list?: unknown } | null)?.manual_scene_info_list;
  if (!Array.isArray(rows)) return [];
  const seen = new Set<string>();
  return rows.flatMap((row: Record<string, unknown> | null) => {
    const id = asIdString(row?.["scene_id"]);
    if (!id || /[:/]/.test(id) || seen.has(id)) return [];
    seen.add(id);
    const rawName = row?.["name"];
    const alternateName = row?.["scene_name"];
    const name = typeof rawName === "string" ? rawName : typeof alternateName === "string" ? alternateName : "";
    return [{ id, name: name.trim() || id, homeId, ownerUid }];
  });
}

export function miSceneAccount(entityId: string): string | null {
  const match = /^([^/]+)\/mi-scene:/.exec(entityId);
  return match?.[1] ?? null;
}

export interface MiSceneSnapshot {
  readonly refreshedAt: number;
  readonly scenes: readonly MiCloudScene[];
}

export async function refreshMiScenes(
  client: Pick<MiCloudClient, "manualScenes">,
  rooms: readonly MiRoom[],
  userId: string,
  previous: MiSceneSnapshot | undefined,
  nowMs: number,
): Promise<MiSceneSnapshot> {
  if (previous && nowMs - previous.refreshedAt < 600_000) return previous;
  const scenes: MiCloudScene[] = [];
  const seen = new Set<string>();
  for (const room of rooms) {
    const { homeId } = room;
    const owner = room.ownerUid;
    if (!homeId || !owner || seen.has(homeId)) continue;
    seen.add(homeId);
    try {
      scenes.push(...await client.manualScenes(homeId, owner));
    } catch (error) {
      if (error instanceof MiCloudError && error.kind === "sessionExpired") throw error;
      scenes.push(...(previous?.scenes.filter((s) => s.homeId === homeId && s.ownerUid === owner) ?? []));
    }
  }
  return { refreshedAt: nowMs, scenes };
}

export function miSceneRows(
  snapshot: MiSceneSnapshot | undefined,
  rooms: readonly MiRoom[],
  accountId: string,
): HomeScene[] {
  const homeIds = new Set(rooms.map((room) => room.homeId));
  const visible = snapshot?.scenes.filter((scene) => homeIds.has(scene.homeId)) ?? [];
  const nameCounts = new Map<string, number>();
  for (const scene of visible) nameCounts.set(scene.name, (nameCounts.get(scene.name) ?? 0) + 1);
  return visible.map((scene) => {
    const suffix = `${scene.homeId}-${scene.id}`;
    const id = `${accountId}/mi-scene:${scene.homeId}:${scene.id}`;
    return {
      id, entityId: id, accountId, sourceBackend: "xiaomiCloud", miScene: scene,
      name: (nameCounts.get(scene.name) ?? 0) > 1 ? `${scene.name} (${suffix})` : scene.name,
    };
  });
}

const runningScenes = new Set<string>();

export async function executeMiScene(
  client: Pick<MiCloudClient, "runManualScene">,
  scene: HomeScene | undefined,
  beforeSend?: () => void,
): Promise<null> {
  if (!scene?.miScene || runningScenes.has(scene.id)) throw new Error("Xiaomi scene unavailable");
  runningScenes.add(scene.id);
  try {
    beforeSend?.();
    await client.runManualScene(scene.miScene);
    return null;
  } finally {
    runningScenes.delete(scene.id);
  }
}
