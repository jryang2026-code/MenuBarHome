import { MiCloudCrypto } from "../miCloudCrypto.js";
import {
  asIdString,
  MiCloudError,
  miApiBaseURL,
  parseJsonObject,
  type HttpTransport,
  type MiSession,
} from "./session.js";
import type { MiotDeviceSpec } from "./spec.js";

export interface MiDeviceRecord {
  readonly did: string;
  readonly name: string;
  readonly model: string;
  readonly isOnline: boolean;
  readonly specType: string | null;
  /** Split key of a multi-key panel (did like `<parent>.s2`): MIoT calls go to the parent did, switch service `splitSiid`. */
  readonly splitParentDid?: string | null;
  readonly splitSiid?: number | null;
}

/** The did MIoT property and action calls address. */
export function miotDid(record: MiDeviceRecord): string {
  return record.splitParentDid ?? record.did;
}

/** Narrows a panel spec to the switch service a split key controls. */
export function specForRecord(record: MiDeviceRecord, spec: MiotDeviceSpec): MiotDeviceSpec {
  if (!record.splitParentDid || record.splitSiid == null) return spec;
  return { ...spec, services: spec.services.filter((s) => s.iid === record.splitSiid) };
}

export interface MiRoom {
  readonly id: string;
  readonly name: string;
  readonly dids: readonly string[];
  readonly homeId?: string;
  readonly homeName?: string;
  readonly isSharedHome?: boolean;
  /** Xiaomi uid of the home owner; `home_device_list` needs it beside the home id (#76). */
  readonly ownerUid?: string;
}

/**
 * Auth failures the cloud reports inside a 200 body instead of an HTTP status. Kept in one place
 * so the plain-JSON and decrypted paths cannot drift apart (#76).
 */
const SESSION_EXPIRED_MARKERS: readonly string[] = [
  "auth err",
  "servicetoken_expired",
  "token expired",
  "invalid signature",
  "invalid_token",
  "unauthorized",
];

function responseMessage(json: Record<string, unknown>): string {
  for (const key of ["message", "desc", "description", "error", "reason"]) {
    const value = json[key];
    if (typeof value === "string" && value.trim() !== "") return value;
  }
  return "";
}

function looksSessionExpired(text: string): boolean {
  const lower = text.toLowerCase();
  return SESSION_EXPIRED_MARKERS.some((marker) => lower.includes(marker));
}

export interface MiotPropKey {
  readonly did: string;
  readonly siid: number;
  readonly piid: number;
}

export function propKeyString(k: MiotPropKey): string {
  return `${k.did}.${k.siid}.${k.piid}`;
}

export interface MiotPropWrite {
  readonly did: string;
  readonly siid: number;
  readonly piid: number;
  readonly value: unknown;
}

export interface MiotActionCall {
  readonly did: string;
  readonly siid: number;
  readonly aiid: number;
  readonly inputs: readonly unknown[];
}

export class MiCloudClient {
  private readonly session: MiSession;
  private readonly transport: HttpTransport;
  private readonly userAgent: string;

  constructor(session: MiSession, transport: HttpTransport) {
    this.session = session;
    this.transport = transport;
    this.userAgent = "abcdefghijklmnoqrs-ABCDEABCDEABC APP/com.xiaomi.mihome APPV/10.5.201";
  }

  async request(api: string, data: unknown): Promise<unknown> {
    const cleanPath = "/" + api.replace(/^\/+|\/+$/g, "");
    const url = `${miApiBaseURL(this.session.region)}${cleanPath}`;
    const nonce = MiCloudCrypto.makeNonce();
    const signed = MiCloudCrypto.signedNonce(this.session.ssecurity, nonce);
    const dataStr = MiCloudCrypto.compactJSONString(data);
    const fields = MiCloudCrypto.encryptParams(cleanPath, dataStr, this.session.ssecurity, nonce);

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "User-Agent": this.userAgent,
        "x-xiaomi-protocal-flag-cli": "PROTOCAL-HTTP2",
        "MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4",
        "Accept-Encoding": "identity",
        "Content-Type": "application/x-www-form-urlencoded",
        Cookie: [
          `userId=${this.session.userId}`,
          `serviceToken=${this.session.serviceToken}`,
          `yetAnotherServiceToken=${this.session.serviceToken}`,
          "locale=zh_CN",
          "timezone=GMT+08:00",
          "is_daylight=0",
          "dst_offset=0",
          "channel=MI_APP_STORE",
        ].join("; "),
      },
      body: MiCloudCrypto.formURLEncode(fields),
    });

    return MiCloudClient.decodeResponse(resp.body, resp.status, signed);
  }

  static decodeResponse(body: string, statusCode: number, signedNonce: string): unknown {
    if (statusCode === 401 || statusCode === 403) {
      throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码");
    }
    const plain = parseJsonObject(body);
    if (plain) {
      if (typeof plain["code"] === "number") {
        // `code` 0 means the cloud answered, so a non-200 status is an HTTP failure worth retrying.
        if (Math.trunc(plain["code"]) === 0) {
          if (statusCode !== 200) {
            throw new MiCloudError("http", `米家云服务 HTTP ${statusCode}`, statusCode);
          }
          return plain["result"] ?? null;
        }
        return MiCloudClient.unwrapResult(plain);
      }
      const message = responseMessage(plain);
      if (looksSessionExpired(message)) {
        throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码");
      }
      if (statusCode !== 200) {
        throw new MiCloudError("http", `米家云服务 HTTP ${statusCode}`, statusCode);
      }
      throw new MiCloudError("badResponse", "米家云响应缺少状态码");
    }
    if (statusCode !== 200) {
      throw new MiCloudError("http", `米家云服务 HTTP ${statusCode}`, statusCode);
    }
    let decryptedText: string;
    try {
      decryptedText = MiCloudCrypto.decryptResponse(body, signedNonce);
    } catch {
      throw new MiCloudError("badResponse", "米家云响应无法解密");
    }
    const json = parseJsonObject(decryptedText);
    if (!json) {
      throw new MiCloudError("badResponse", "米家云解密后非 JSON");
    }
    return MiCloudClient.unwrapResult(json);
  }

  static unwrapResult(json: Record<string, unknown>): unknown {
    if (typeof json["code"] !== "number") {
      // A body without `code` is not a successful answer. An auth word is still a dead session, so
      // the user gets the QR hint instead of a generic parse error (#76).
      const message = responseMessage(json);
      if (looksSessionExpired(message)) {
        throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码");
      }
      throw new MiCloudError("badResponse", `米家云响应缺少状态码${message ? `：${message}` : ""}`);
    }
    const code = Math.trunc(json["code"]);
    const message = responseMessage(json);
    if (code === 0) return json["result"] ?? null;
    if (code === 2 || code === 3 || looksSessionExpired(message)) {
      throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码", code);
    }
    throw new MiCloudError("api", `米家云指令失败 (${code})：${message}`, code);
  }

  static parseDeviceList(result: unknown): MiDeviceRecord[] {
    if (!result || typeof result !== "object") return [];
    const list = (result as Record<string, unknown>)["list"];
    return Array.isArray(list) ? MiCloudClient.parseDeviceRecordArray(list) : [];
  }

  /** One device entry of `home/device_list` / `home_device_list`, or `null` when unusable. */
  static parseDeviceRecord(item: unknown): MiDeviceRecord | null {
    if (!item || typeof item !== "object") return null;
    const rec = item as Record<string, unknown>;
    const did = asIdString(rec["did"]);
    const model = typeof rec["model"] === "string" ? rec["model"] : null;
    if (!did || !model) return null;
    const extra = rec["extra"] && typeof rec["extra"] === "object" ? (rec["extra"] as Record<string, unknown>) : {};
    const split = extra["split"] && typeof extra["split"] === "object" ? (extra["split"] as Record<string, unknown>) : null;
    const splitParentDid = split ? asIdString(split["parentId"]) : null;
    const splitSiid = split && typeof split["moduleId"] === "number" ? Math.trunc(split["moduleId"]) : null;
    return {
      did,
      name: typeof rec["name"] === "string" ? rec["name"] : model,
      model,
      isOnline: typeof rec["isOnline"] === "boolean" ? rec["isOnline"] : true,
      specType: typeof rec["spec_type"] === "string" ? rec["spec_type"] : null,
      ...(splitParentDid && splitSiid !== null ? { splitParentDid, splitSiid } : {}),
    };
  }

  /** `home_device_list` returns its rows directly, so `device_info` is already the record array. */
  static parseDeviceRecordArray(items: readonly unknown[]): MiDeviceRecord[] {
    const out: MiDeviceRecord[] = [];
    for (const item of items) {
      const record = MiCloudClient.parseDeviceRecord(item);
      if (record) out.push(record);
    }
    return out;
  }

  /** Homes another account shared with this one arrive under `share_home_list`, not `homelist` (#134). */
  static parseRooms(result: unknown): MiRoom[] {
    if (!result || typeof result !== "object") return [];
    const obj = result as Record<string, unknown>;
    const rooms: MiRoom[] = [];
    const seenHomes = new Set<string>();
    const appendHomes = (homes: readonly unknown[], shared: boolean) => {
      for (const home of homes) {
        if (!home || typeof home !== "object") continue;
        const h = home as Record<string, unknown>;
        const homeId = asIdString(h["id"]) ?? "";
        if (homeId) {
          if (seenHomes.has(homeId)) continue;
          seenHomes.add(homeId);
        }
        const homeName = typeof h["name"] === "string" ? h["name"] : "";
        const ownerUid = asIdString(h["uid"]) ?? undefined;
        const sharedFlag = shared ? { isSharedHome: true as const } : {};
        const ownerFlag = ownerUid ? { ownerUid } : {};
        const roomlist = h["roomlist"];
        let roomCount = 0;
        if (Array.isArray(roomlist)) {
          for (const rm of roomlist) {
            if (!rm || typeof rm !== "object") continue;
            const r = rm as Record<string, unknown>;
            const id = asIdString(r["id"]);
            if (!id) continue;
            roomCount += 1;
            const rawDids = Array.isArray(r["dids"]) ? r["dids"] : [];
            const dids = rawDids.map(asIdString).filter((d): d is string => d !== null);
            rooms.push({
              id,
              name: typeof r["name"] === "string" ? r["name"] : "",
              dids,
              homeId,
              homeName,
              ...sharedFlag,
              ...ownerFlag,
            });
          }
        }
        const homeDids = Array.isArray(h["dids"])
          ? h["dids"].map(asIdString).filter((d): d is string => d !== null)
          : [];
        if (homeId && homeDids.length > 0) {
          rooms.push({ id: `home_${homeId}`, name: "", dids: homeDids, homeId, homeName, ...sharedFlag, ...ownerFlag });
          continue;
        }
        // A home with no rooms and no dids still matters when the cloud names its owner: only
        // `withHomeDeviceLists` can list its devices, and it needs a room to learn the pair
        // (home id, owner uid) from. Without this entry such a shared home is invisible (#76, #67).
        if (homeId && roomCount === 0 && ownerUid) {
          rooms.push({ id: `home_${homeId}`, name: "", dids: [], homeId, homeName, ...sharedFlag, ...ownerFlag });
        }
      }
    };
    appendHomes(Array.isArray(obj["homelist"]) ? obj["homelist"] : [], false);
    appendHomes(Array.isArray(obj["share_home_list"]) ? obj["share_home_list"] : [], true);
    return rooms;
  }

  static parseLightGroupMembers(result: unknown): Map<string, string[]> {
    const groups = new Map<string, string[]>();
    if (!Array.isArray(result)) return groups;
    for (const item of result) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const groupDid = asIdString(record["group_did"]);
      if (!groupDid) continue;
      const raw = [record["member_ship"], record["membership"]].find(
        (value): value is Record<string, unknown> =>
          value !== null && typeof value === "object" && !Array.isArray(value),
      );
      if (!raw) continue;
      const members = groups.get(groupDid) ?? [];
      for (const memberDid of Object.keys(raw)) {
        if (memberDid.length > 0 && !members.includes(memberDid)) members.push(memberDid);
      }
      groups.set(groupDid, members);
    }
    return groups;
  }

  /**
   * `v2/home/device_list_page` also returns the split keys of multi-key Mesh panels, which
   * `home/device_list` omits even with `get_split_device`; fall back to the latter on failure.
   */
  async deviceList(): Promise<MiDeviceRecord[]> {
    try {
      return await this.deviceListPaged();
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      return this.legacyDeviceList();
    }
  }

  /**
   * Devices of homes shared with this account are missing from the unfiltered list; the cloud
   * returns them only when asked for by did, as Xiaomi's own `xiaomi_home` integration does (#134).
   */
  async devicesByDids(dids: string[]): Promise<MiDeviceRecord[]> {
    const records: MiDeviceRecord[] = [];
    for (let start = 0; start < dids.length; start += 150) {
      records.push(...(await this.deviceListPaged(dids.slice(start, start + 150))));
    }
    const seen = new Set<string>();
    return records.filter((r) => !seen.has(r.did) && (seen.add(r.did), true));
  }

  private async deviceListPaged(dids?: string[]): Promise<MiDeviceRecord[]> {
    const records: MiDeviceRecord[] = [];
    let startDid = "";
    for (let page = 0; page < 20; page++) {
      const data: Record<string, unknown> = {
        get_split_device: true,
        support_smart_home: true,
        get_third_device: true,
        limit: 200,
      };
      if (dids) data["dids"] = dids;
      if (startDid) data["start_did"] = startDid;
      const res = await this.request("v2/home/device_list_page", data);
      records.push(...MiCloudClient.parseDeviceList(res));
      const obj = res && typeof res === "object" ? (res as Record<string, unknown>) : {};
      const next = asIdString(obj["next_start_did"]) ?? "";
      if (obj["has_more"] !== true || !next || next === startDid) break;
      startDid = next;
    }
    const seen = new Set<string>();
    return records.filter((r) => !seen.has(r.did) && (seen.add(r.did), true));
  }

  private async legacyDeviceList(): Promise<MiDeviceRecord[]> {
    const res = await this.request("home/device_list", {
      getVirtualModel: true,
      getHuamiDevices: 1,
      get_split_device: false,
      support_smart_home: true,
    });
    return MiCloudClient.parseDeviceList(res);
  }

  /**
   * Homes and their rooms. An account with many homes answers the first page with `has_more` and a
   * `max_id`, so the rest arrive from `get_dev_room_page` (#76). A failed page stops the walk
   * instead of failing the whole listing: the homes already parsed stay usable.
   */
  async homeRooms(): Promise<MiRoom[]> {
    let result: unknown;
    try {
      result = await this.request("v2/homeroom/gethome_merged", {
        fg: true,
        fetch_share: true,
        fetch_share_dev: true,
        limit: 300,
        app_ver: 9,
        plat_form: 0,
      });
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      result = await this.request("v2/homeroom/gethome", {
        fg: true,
        fetch_share: true,
        fetch_share_dev: true,
        limit: 300,
        app_ver: 9,
        plat_form: 0,
      });
    }
    let rooms = MiCloudClient.parseRooms(result);
    const visited = new Set<string>();
    let maxId = MiCloudClient.homePageCursor(result);
    for (let page = 0; page < 20; page++) {
      if (MiCloudClient.hasMoreHomes(result) !== true || !maxId || visited.has(maxId)) break;
      visited.add(maxId);
      let next: unknown;
      try {
        next = await this.request("v2/homeroom/get_dev_room_page", { start_id: maxId, limit: 150 });
      } catch (err) {
        if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
        break;
      }
      rooms = MiCloudClient.mergeRoomPage(next, rooms);
      result = next;
      maxId = MiCloudClient.homePageCursor(next);
    }
    return rooms;
  }

  /**
   * Merges one `v2/homeroom/get_dev_room_page` continuation (`result.info`) into the rooms parsed
   * from `gethome_merged`, keeping every room of an existing home and deduplicating dids.
   */
  static mergeRoomPage(page: unknown, rooms: readonly MiRoom[]): MiRoom[] {
    if (!page || typeof page !== "object") return [...rooms];
    const obj = page as Record<string, unknown>;
    const result = [...rooms];
    const appendDids = (dids: readonly string[], roomId: string, homeId: string, roomName = ""): void => {
      if (dids.length === 0 || !roomId) return;
      const idx = result.findIndex((r) => r.id === roomId);
      if (idx >= 0) {
        const current = result[idx]!;
        const seen = new Set(current.dids);
        const merged = [...current.dids];
        for (const did of dids) {
          if (!seen.has(did)) {
            seen.add(did);
            merged.push(did);
          }
        }
        result[idx] = { ...current, dids: merged };
        return;
      }
      const sibling = result.find((r) => r.homeId === homeId);
      result.push({
        id: roomId,
        name: roomName,
        dids: [...new Set(dids)],
        homeId,
        homeName: sibling?.homeName ?? "",
        ...(sibling?.isSharedHome === true ? { isSharedHome: true as const } : {}),
        ...(sibling?.ownerUid ? { ownerUid: sibling.ownerUid } : {}),
      });
    };

    const infoList = Array.isArray(obj["info"]) ? obj["info"] : [];
    for (const entry of infoList) {
      if (!entry || typeof entry !== "object") continue;
      const info = entry as Record<string, unknown>;
      const homeId = asIdString(info["id"]) ?? "";
      if (!homeId) continue;
      const homeDids = Array.isArray(info["dids"])
        ? info["dids"].map(asIdString).filter((d): d is string => d !== null)
        : [];
      appendDids(homeDids, `home_${homeId}`, homeId);
      const roomlist = Array.isArray(info["roomlist"]) ? info["roomlist"] : [];
      for (const rm of roomlist) {
        if (!rm || typeof rm !== "object") continue;
        const r = rm as Record<string, unknown>;
        const roomId = asIdString(r["id"]);
        if (!roomId) continue;
        const roomDids = Array.isArray(r["dids"])
          ? r["dids"].map(asIdString).filter((d): d is string => d !== null)
          : [];
        appendDids(roomDids, roomId, homeId, typeof r["name"] === "string" ? r["name"] : "");
      }
    }
    return result;
  }

  /** `has_more` comes back as a real boolean or as 1/0 depending on the endpoint. */
  private static hasMoreHomes(result: unknown): boolean {
    if (!result || typeof result !== "object") return false;
    const value = (result as Record<string, unknown>)["has_more"];
    return value === true || value === 1;
  }

  private static homePageCursor(result: unknown): string {
    if (!result || typeof result !== "object") return "";
    return asIdString((result as Record<string, unknown>)["max_id"]) ?? "";
  }

  /**
   * Devices of one home, including the shared and third-party keys the unfiltered list omits
   * (#76). Home and owner ids are sent as numbers when they fit, because the endpoint rejects
   * oversized ids in JSON number form.
   */
  async homeDevices(homeId: string, ownerUid: string): Promise<MiDeviceRecord[]> {
    const records: MiDeviceRecord[] = [];
    const asNumericId = (raw: string): number | string => {
      if (!/^\d+$/.test(raw)) return raw;
      const parsed = Number(raw);
      return Number.isSafeInteger(parsed) ? parsed : raw;
    };
    let startDid = "";
    for (let page = 0; page < 20; page++) {
      const data: Record<string, unknown> = {
        home_owner: asNumericId(ownerUid),
        home_id: asNumericId(homeId),
        limit: 300,
        get_split_device: true,
        support_smart_home: true,
        get_cariot_device: true,
        get_third_device: true,
      };
      if (startDid) data["start_did"] = startDid;
      const res = await this.request("v2/home/home_device_list", data);
      const obj = res && typeof res === "object" ? (res as Record<string, unknown>) : {};
      // `device_info` holds the rows; some regions answer with the older `list` field instead.
      const rows = Array.isArray(obj["device_info"])
        ? obj["device_info"]
        : Array.isArray(obj["list"])
          ? obj["list"]
          : [];
      records.push(...MiCloudClient.parseDeviceRecordArray(rows));
      const next = asIdString(obj["max_did"]) ?? asIdString(obj["next_start_did"]) ?? "";
      if (obj["has_more"] !== true || !next || next === startDid) break;
      startDid = next;
    }
    const seen = new Set<string>();
    return records.filter((r) => !seen.has(r.did) && (seen.add(r.did), true));
  }

  /** Maps each Xiaomi light group among `groupDids` to its member device dids, in first-seen order. */
  async lightGroupMembers(groupDids: readonly string[]): Promise<Map<string, string[]>> {
    const unique = [...new Set(groupDids)].filter((did) => did.startsWith("group."));
    const members = new Map<string, string[]>();
    for (let start = 0; start < unique.length; start += 100) {
      const result = await this.request("v2/groupv2/query_status", {
        group_did: unique.slice(start, start + 100),
      });
      for (const [groupDid, memberDids] of MiCloudClient.parseLightGroupMembers(result)) {
        const merged = members.get(groupDid) ?? [];
        for (const memberDid of memberDids) {
          if (!merged.includes(memberDid)) merged.push(memberDid);
        }
        members.set(groupDid, merged);
      }
    }
    return members;
  }

  async getProps(keys: readonly MiotPropKey[]): Promise<Map<string, unknown>> {
    const values = new Map<string, unknown>();
    const chunkSize = 100;
    for (let start = 0; start < keys.length; start += chunkSize) {
      const chunk = keys.slice(start, start + chunkSize);
      const params = chunk.map((k) => ({ did: k.did, siid: k.siid, piid: k.piid }));
      const result = await this.request("miotspec/prop/get", { params });
      if (Array.isArray(result)) {
        for (const item of result) {
          if (!item || typeof item !== "object") continue;
          const obj = item as Record<string, unknown>;
          const did = asIdString(obj["did"]);
          const siid = typeof obj["siid"] === "number" ? Math.trunc(obj["siid"]) : null;
          const piid = typeof obj["piid"] === "number" ? Math.trunc(obj["piid"]) : null;
          const code = typeof obj["code"] === "number" ? Math.trunc(obj["code"]) : 0;
          if (did && siid !== null && piid !== null && code === 0 && "value" in obj) {
            values.set(propKeyString({ did, siid, piid }), obj["value"]);
          }
        }
      }
    }
    return values;
  }

  async setProps(writes: readonly MiotPropWrite[]): Promise<void> {
    const params = writes.map((w) => ({
      did: w.did,
      siid: w.siid,
      piid: w.piid,
      value: w.value,
    }));
    const result = await this.request("miotspec/prop/set", { params });
    if (Array.isArray(result)) {
      for (const item of result) {
        if (item && typeof item === "object") {
          const code = typeof (item as Record<string, unknown>)["code"] === "number"
            ? Math.trunc((item as Record<string, unknown>)["code"] as number)
            : 0;
          if (code < 0) {
            throw new MiCloudError("api", "设备未响应或离线", code);
          }
        }
      }
    }
  }

  async action(call: MiotActionCall): Promise<void> {
    await this.callAction(call);
  }

  async callAction(call: MiotActionCall): Promise<unknown> {
    const result = await this.request("miotspec/action", {
      params: {
        did: call.did,
        siid: call.siid,
        aiid: call.aiid,
        in: call.inputs,
      },
    });
    if (result && typeof result === "object") {
      const code = typeof (result as Record<string, unknown>)["code"] === "number"
        ? Math.trunc((result as Record<string, unknown>)["code"] as number)
        : 0;
      if (code < 0) {
        throw new MiCloudError("api", "设备未响应或离线", code);
      }
    }
    return result;
  }
}

// MARK: - MIoT Spec & Synthesis
