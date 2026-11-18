import {
  CAPABILITY_EXPECTED_KIND, CONNECTION_CAPABILITY_IDS, DEVICE_CATEGORY_IDS, FEATURE_IDS,
  type CapabilityID, type CapabilityManifest, type ConnectionCapabilityID, type DeviceCategoryID, type FeatureID,
} from "./capabilityManifest.js";
import type { LanguagePreference } from "./i18n.js";
import { tr3, type SensorAlertKind } from "./safetyAndHealth.js";

export const SAFETY_SIGNAL_KINDS = [
  "leak", "smoke", "gas", "contact", "motion", "vibration", "lock", "doorbell",
  "lowBattery", "longRunningPlug", "longRunningClimate", "highPower", "starredOffline",
] as const;
export type SafetySignalKind = (typeof SAFETY_SIGNAL_KINDS)[number];
export const SENSOR_ALERT_TO_SAFETY_SIGNAL = {
  leak: "leak", smoke: "smoke", gas: "gas", contact: "contact", motion: "motion", vibration: "vibration", lock: "lock",
} as const satisfies Record<SensorAlertKind, SafetySignalKind>;

export type CapabilityInstallResolutionMode = "explicit" | "legacyPreserved" | "freshInstall" | "uncertainFallback";
export interface CapabilitySelection {
  readonly enabledConnections: readonly ConnectionCapabilityID[]; readonly enabledConnectionScopes: readonly string[];
  readonly enabledFeatures: readonly FeatureID[]; readonly enabledCategories: readonly DeviceCategoryID[];
}
export interface CapabilityInstallEvidence {
  readonly explicitSelection?: CapabilitySelection | null; readonly hasLegacySettingsOrOnboarding?: boolean;
  readonly configuredConnectionScopes?: readonly string[]; readonly hasPersistedLocalData?: boolean;
  readonly legacyFeatureFlags?: Partial<Record<FeatureID, boolean>>; readonly identityReadFailure?: string | null;
}
export interface CapabilityInstallResolution {
  readonly mode: CapabilityInstallResolutionMode; readonly selection: CapabilitySelection;
  readonly persistMigrationComplete: boolean; readonly retryDiagnostic: string | null;
}
export interface CapabilityIndexedDevice {
  readonly id: string; readonly name: string; readonly category: DeviceCategoryID;
  readonly connection: ConnectionCapabilityID | null; readonly sourceScope: string;
  readonly isSourceAvailable?: boolean; readonly upstreamHiddenOrDisabled?: boolean;
  readonly participatesInAllOff?: boolean; readonly safetySignals?: readonly SafetySignalKind[];
  readonly readKeys?: readonly string[]; readonly safetyReadKeys?: readonly string[];
}
export interface SafetyRetentionPolicy { readonly enabledSignals: readonly SafetySignalKind[]; readonly starredDeviceIds?: readonly string[]; }
export interface DeviceSetPartition {
  readonly availableDeviceIds: readonly string[]; readonly hiddenSafetyRetainedDeviceIds: readonly string[];
  readonly safetyEvaluationDeviceIds: readonly string[]; readonly readPlanKeys: readonly string[]; readonly showsHiddenSafetyNotice: boolean;
}

export type TimerPartition = "waiting" | "missed" | "foreign";
export type QuickActionReferenceKind = "lightsOff" | "softNightLight" | "climateSleepOff" | "deviceGroup";
export const QUICK_ACTION_TARGET_CATEGORIES = {
  lightsOff: ["light"], softNightLight: ["light"], climateSleepOff: ["climate", "fan"], deviceGroup: [],
} as const satisfies Record<QuickActionReferenceKind, readonly DeviceCategoryID[]>;

export interface TimerReference {
  readonly id: string; readonly name: string; readonly partition: TimerPartition;
  readonly targetIds: readonly string[]; readonly sourceScopes: readonly string[]; readonly allTargetsLGLan?: boolean;
}
export type AutomationReferenceAction =
  | { readonly kind: "devices"; readonly targetIds: readonly string[] }
  | { readonly kind: "quickAction"; readonly quickAction: QuickActionReferenceKind }
  | { readonly kind: "dynamicAllOff" }
  | { readonly kind: "scene"; readonly sceneId: string };
export interface AutomationReference {
  readonly id: string; readonly name: string; readonly isEnabled: boolean;
  readonly action: AutomationReferenceAction; readonly sourceScopes?: readonly string[];
}
export interface QuickActionReference {
  readonly id: string; readonly name: string; readonly kind: QuickActionReferenceKind;
  readonly targetIds?: readonly string[]; readonly isEnabled?: boolean;
}
export interface SceneReference {
  readonly id: string; readonly name: string; readonly connection: ConnectionCapabilityID | null;
  readonly sourceScope: string; readonly isSourceAvailable?: boolean;
}
export interface DeviceGroupReference { readonly id: string; readonly name: string; readonly memberDeviceIds: readonly string[]; }
export interface PreferenceReferenceSet {
  readonly favoriteDeviceIds?: readonly string[]; readonly aliasDeviceIds?: readonly string[];
  readonly customOrderDeviceIds?: readonly string[]; readonly menuBarTargetDeviceIds?: readonly string[];
  readonly pinnedSourceDeviceIds?: readonly string[]; readonly cameraPreferenceDeviceIds?: readonly string[];
}
export interface CapabilityReferenceGraph {
  readonly timers?: readonly TimerReference[]; readonly automations?: readonly AutomationReference[];
  readonly quickActions?: readonly QuickActionReference[]; readonly scenes?: readonly SceneReference[];
  readonly deviceGroups?: readonly DeviceGroupReference[]; readonly preferences?: PreferenceReferenceSet;
  readonly corruptedStoreReasons?: readonly string[]; readonly expectedGeneration?: number | null; readonly currentGeneration?: number | null;
}

export type DeactivationDisposition = "allowed" | "requiresPauseConfirmation" | "blocked";
export type AffectedReferenceKind = "waitingTimer" | "missedTimer" | "foreignTimer" | "automationRule" | "quickAction";
export type CapabilitySoftNoticeKind =
  | "manualScenesMayControlHiddenDevices" | "preferencesPreserved" | "safetyReadsRetained" | "dependentCapabilitiesCascaded";
export type CapabilityBlockingReasonKind = "unresolvedReferenceOwnership" | "corruptedReferenceStore" | "stalePreviewGeneration";
export interface AffectedReferenceItem {
  readonly kind: AffectedReferenceKind; readonly id: string; readonly name: string;
  readonly connectionScopes: readonly string[]; readonly affectedTargetIds: readonly string[]; readonly affectedCapabilities: readonly CapabilityID[];
}
export interface CapabilitySoftNotice { readonly kind: CapabilitySoftNoticeKind; readonly affectedIds: readonly string[]; }
export interface CapabilityBlockingReason { readonly kind: CapabilityBlockingReasonKind; readonly referenceId: string; readonly detail: string; }
export interface CapabilityDeactivationVerdict {
  readonly disposition: DeactivationDisposition; readonly canDeactivate: boolean; readonly requiresPauseConfirmation: boolean;
  readonly cascadedCapabilities: readonly CapabilityID[]; readonly itemsToPause: readonly AffectedReferenceItem[];
  readonly softNotices: readonly CapabilitySoftNotice[]; readonly blockingReasons: readonly CapabilityBlockingReason[];
  readonly preservedPreferenceDeviceIds: readonly string[]; readonly partition: DeviceSetPartition;
}

export type ControlTargetKind = "device" | "scene";
export type ControlTargetRejectionCode =
  | "categoryDisabled" | "deviceNotFound" | "sceneNotFound"
  | "connectionDisabled" | "connectionUnavailable" | "ambiguousTarget" | "staleGeneration";
export interface ControlTargetRejectionReason {
  readonly code: ControlTargetRejectionCode; readonly disabledCategory?: DeviceCategoryID;
  readonly connection?: ConnectionCapabilityID | null; readonly scope?: string;
}
export interface ControlTargetGateVerdict {
  readonly allowed: boolean; readonly writeCount: number;
  readonly rejectionReason: ControlTargetRejectionReason | null; readonly mayControlHiddenDevices: boolean;
}
export interface PlanTargetGateVerdict {
  readonly allowed: boolean; readonly writeCount: number;
  readonly rejectedTargetId: string | null; readonly rejectionReason: ControlTargetRejectionReason | null;
}
export type PausedTimerResumeDisposition = "armWaiting" | "moveToMissed" | "keepPaused" | "partitionForeign";

const sortedUnique = <T extends string>(items: Iterable<T>): T[] => [...new Set(items)].sort() as T[];
export const connectionCapabilityForScope = (scope: string): ConnectionCapabilityID | null =>
  scope.startsWith("mi:") ? "xiaomi-cloud" : scope.startsWith("ha:") ? "home-assistant" : null;

export function capabilitySoftNoticeMessage(kind: CapabilitySoftNoticeKind, preference?: LanguagePreference): string {
  switch (kind) {
    case "manualScenesMayControlHiddenDevices": return tr3("平台场景和脚本仍可手动启动，可能控制已隐藏的设备", "平台場景和腳本仍可手動啟動，可能控制已隱藏的裝置", "Platform scenes and scripts remain manually available and may control hidden devices", undefined, preference);
    case "preferencesPreserved": return tr3("收藏、别名、排序与固定来源已保留，重新开启后按原 ID 恢复", "收藏、別名、排序與固定來源已保留，重新開啟後按原 ID 恢復", "Favorites, aliases, sort order, and pinned sources are preserved and will restore by ID", undefined, preference);
    case "safetyReadsRetained": return tr3("为了继续提供已开启的安全提醒，仍会读取部分隐藏设备", "為了繼續提供已開啟的安全提醒，仍會讀取部分隱藏裝置", "Some hidden devices are still read to keep enabled safety alerts active", undefined, preference);
    case "dependentCapabilitiesCascaded": return tr3("关联子功能将一并关闭", "關聯子功能將一併關閉", "Dependent capabilities will also be turned off", undefined, preference);
  }
}

export function controlTargetRejectionMessage(reason: ControlTargetRejectionReason, preference?: LanguagePreference): string {
  switch (reason.code) {
    case "categoryDisabled": return tr3("该设备类型已关闭", "該裝置類型已關閉", "This device category is turned off", undefined, preference);
    case "deviceNotFound": return tr3("设备不存在", "裝置不存在", "Device not found", undefined, preference);
    case "sceneNotFound": return tr3("场景不存在", "場景不存在", "Scene not found", undefined, preference);
    case "connectionDisabled":
      if (reason.connection === "xiaomi-cloud") return tr3("米家已停用", "米家已停用", "Xiaomi Home is turned off", undefined, preference);
      if (reason.connection === "home-assistant") return tr3("Home Assistant 已停用", "Home Assistant 已停用", "Home Assistant is turned off", undefined, preference);
      return tr3("该连接已停用", "該連線已停用", "This connection is turned off", undefined, preference);
    case "connectionUnavailable":
      if (reason.connection === "xiaomi-cloud") return tr3("米家暂不可用，部分设备暂无数据", "米家暫不可用，部分裝置暫無資料", "Xiaomi Home is temporarily unavailable", undefined, preference);
      if (reason.connection === "home-assistant") return tr3("Home Assistant 暂不可用，部分设备暂无数据", "Home Assistant 暫不可用，部分裝置暫無資料", "Home Assistant is temporarily unavailable", undefined, preference);
      return tr3("该连接暂不可用", "該連線暫不可用", "This connection is temporarily unavailable", undefined, preference);
    case "ambiguousTarget": return tr3("目标存在重名或跨源冲突，请明确指定设备", "目標存在重名或跨源衝突，請明確指定裝置", "Target is ambiguous across devices or sources", undefined, preference);
    case "staleGeneration": return tr3("状态已变化，请刷新后重试", "狀態已變化，請重新整理後重試", "State changed; refresh and try again", undefined, preference);
  }
}

export function normalizeCapabilitySelection(selection: CapabilitySelection, manifest: CapabilityManifest): CapabilitySelection {
  const conns = new Set<ConnectionCapabilityID>(selection.enabledConnections), feats = new Set<FeatureID>(selection.enabledFeatures), cats = new Set<DeviceCategoryID>(selection.enabledCategories);
  const has = (id: CapabilityID): boolean => {
    const k = CAPABILITY_EXPECTED_KIND[id];
    return k === "connection" ? conns.has(id as ConnectionCapabilityID) : k === "feature" ? feats.has(id as FeatureID) : cats.has(id as DeviceCategoryID);
  };
  let changed = true;
  while (changed) {
    changed = false;
    for (const e of manifest.entries) {
      if (has(e.id) && e.dependsOn.some((dep) => !has(dep))) {
        const k = CAPABILITY_EXPECTED_KIND[e.id];
        if (k === "connection") conns.delete(e.id as ConnectionCapabilityID);
        else if (k === "feature") feats.delete(e.id as FeatureID);
        else cats.delete(e.id as DeviceCategoryID);
        changed = true;
      }
    }
  }
  return { enabledConnections: sortedUnique(conns), enabledConnectionScopes: sortedUnique(selection.enabledConnectionScopes), enabledFeatures: sortedUnique(feats), enabledCategories: sortedUnique(cats) };
}

function isSourceEnabled(sel: CapabilitySelection, connection: ConnectionCapabilityID | null, scope: string): boolean {
  const resolved = connection ?? connectionCapabilityForScope(scope);
  return resolved ? sel.enabledConnections.includes(resolved) && sel.enabledConnectionScopes.includes(scope) : true;
}
const selectionContains = (sel: CapabilitySelection, id: CapabilityID): boolean =>
  (sel.enabledConnections as readonly string[]).includes(id) || (sel.enabledFeatures as readonly string[]).includes(id) || (sel.enabledCategories as readonly string[]).includes(id);

export function resolveCapabilityInstallSelection(evidence: CapabilityInstallEvidence, manifest: CapabilityManifest): CapabilityInstallResolution {
  const scopes = evidence.configuredConnectionScopes ?? [], flags = evidence.legacyFeatureFlags ?? {}, failure = evidence.identityReadFailure?.trim() ?? "";
  const legacy = normalizeCapabilitySelection({
    enabledConnections: scopes.map(connectionCapabilityForScope).filter((c): c is ConnectionCapabilityID => c !== null),
    enabledConnectionScopes: scopes, enabledFeatures: FEATURE_IDS.filter((f) => flags[f] ?? true), enabledCategories: [...DEVICE_CATEGORY_IDS],
  }, manifest);
  if (failure.length > 0) return { mode: "uncertainFallback", selection: evidence.explicitSelection ? normalizeCapabilitySelection(evidence.explicitSelection, manifest) : legacy, persistMigrationComplete: false, retryDiagnostic: failure };
  if (evidence.explicitSelection) return { mode: "explicit", selection: normalizeCapabilitySelection(evidence.explicitSelection, manifest), persistMigrationComplete: true, retryDiagnostic: null };
  if (Boolean(evidence.hasLegacySettingsOrOnboarding) || scopes.length > 0 || Boolean(evidence.hasPersistedLocalData)) return { mode: "legacyPreserved", selection: legacy, persistMigrationComplete: true, retryDiagnostic: null };
  const conns: ConnectionCapabilityID[] = [], feats: FeatureID[] = [], cats: DeviceCategoryID[] = [];
  for (const e of manifest.entries) {
    if (!e.defaultOnFreshInstall) continue;
    if (e.kind === "connection") conns.push(e.id as ConnectionCapabilityID);
    else if (e.kind === "feature") feats.push(e.id as FeatureID);
    else cats.push(e.id as DeviceCategoryID);
  }
  return { mode: "freshInstall", selection: normalizeCapabilitySelection({ enabledConnections: conns, enabledConnectionScopes: [], enabledFeatures: feats, enabledCategories: cats }, manifest), persistMigrationComplete: true, retryDiagnostic: null };
}

export function partitionCapabilityDevices(devices: readonly CapabilityIndexedDevice[], selection: CapabilitySelection, safetyPolicy: SafetyRetentionPolicy): DeviceSetPartition {
  const sigs = new Set(safetyPolicy.enabledSignals), starred = new Set(safetyPolicy.starredDeviceIds ?? []);
  const cats = new Set(selection.enabledCategories), seen = new Set<string>(), keys = new Set<string>();
  const available: string[] = [], hiddenSafety: string[] = [], safetyEval: string[] = [];
  for (const d of devices) {
    if (d.upstreamHiddenOrDisabled || !isSourceEnabled(selection, d.connection, d.sourceScope) || seen.has(d.id)) continue;
    seen.add(d.id);
    if (cats.has(d.category)) {
      available.push(d.id); safetyEval.push(d.id);
      for (const k of d.readKeys ?? []) keys.add(k);
    } else if ((d.safetySignals ?? []).some((s) => (s === "starredOffline" ? sigs.has("starredOffline") && starred.has(d.id) : sigs.has(s)))) {
      hiddenSafety.push(d.id); safetyEval.push(d.id);
      for (const k of d.safetyReadKeys && d.safetyReadKeys.length > 0 ? d.safetyReadKeys : (d.readKeys ?? [])) keys.add(k);
    }
  }
  return { availableDeviceIds: available, hiddenSafetyRetainedDeviceIds: hiddenSafety, safetyEvaluationDeviceIds: safetyEval, readPlanKeys: sortedUnique(keys), showsHiddenSafetyNotice: hiddenSafety.length > 0 };
}

function reverseDependencyOrder(manifest: CapabilityManifest): CapabilityID[] {
  const visited = new Set<CapabilityID>(), topo: CapabilityID[] = [];
  const visit = (id: CapabilityID): void => {
    if (visited.has(id)) return;
    visited.add(id);
    for (const dep of manifest.entryFor(id).dependsOn) visit(dep);
    topo.push(id);
  };
  for (const e of manifest.entries) visit(e.id);
  return topo.reverse();
}

export function evaluateCapabilityDeactivation(
  current: CapabilitySelection, proposed: CapabilitySelection, manifest: CapabilityManifest,
  devices: readonly CapabilityIndexedDevice[], safetyPolicy: SafetyRetentionPolicy, references: CapabilityReferenceGraph,
): CapabilityDeactivationVerdict {
  const before = normalizeCapabilitySelection(current, manifest), after = normalizeCapabilitySelection(proposed, manifest);
  const beforePart = partitionCapabilityDevices(devices, before, safetyPolicy), afterPart = partitionCapabilityDevices(devices, after, safetyPolicy);
  const beforeAvail = new Set(beforePart.availableDeviceIds), afterAvail = new Set(afterPart.availableDeviceIds);
  const disabledScopes = new Set(before.enabledConnectionScopes.filter((s) => !after.enabledConnectionScopes.includes(s)));
  const disabledCats = new Set(before.enabledCategories.filter((c) => !after.enabledCategories.includes(c)));
  const disabledFeats = new Set(before.enabledFeatures.filter((f) => !after.enabledFeatures.includes(f)));
  const cascaded = reverseDependencyOrder(manifest).filter((id) => selectionContains(before, id) && !selectionContains(after, id));
  const autoChildren = cascaded.filter((id) => selectionContains(proposed, id) && !selectionContains(after, id));

  const devById = new Map<string, CapabilityIndexedDevice>();
  for (const d of devices) if (!d.upstreamHiddenOrDisabled && !devById.has(d.id)) devById.set(d.id, d);
  const sceneById = new Map((references.scenes ?? []).map((s) => [s.id, s] as const));
  const groupById = new Map((references.deviceGroups ?? []).map((g) => [g.id, g] as const));
  const expand = (ids: readonly string[]): string[] => ids.flatMap((id) => groupById.get(id)?.memberDeviceIds ?? [id]);

  const blocking: CapabilityBlockingReason[] = [];
  if (references.expectedGeneration != null && references.currentGeneration != null && references.expectedGeneration !== references.currentGeneration) {
    blocking.push({ kind: "stalePreviewGeneration", referenceId: "generation", detail: `${references.expectedGeneration}!=${references.currentGeneration}` });
  }
  for (const store of references.corruptedStoreReasons ?? []) blocking.push({ kind: "corruptedReferenceStore", referenceId: store, detail: store });

  const items: AffectedReferenceItem[] = [], seenItems = new Set<string>();
  const addItem = (kind: AffectedReferenceKind, id: string, name: string, scopes: readonly string[], targets: readonly string[], caps: readonly CapabilityID[]) => {
    const key = `${kind}:${id}`;
    if (seenItems.has(key)) return;
    seenItems.add(key);
    items.push({ kind, id, name, connectionScopes: sortedUnique(scopes), affectedTargetIds: sortedUnique(targets), affectedCapabilities: sortedUnique(caps) });
  };
  const lostCaps = (ids: readonly string[]): CapabilityID[] => ids.flatMap((id) => {
    const d = devById.get(id); if (!d) return [];
    const c: CapabilityID[] = [], conn = d.connection ?? connectionCapabilityForScope(d.sourceScope);
    if (!isSourceEnabled(after, conn, d.sourceScope) && conn) c.push(conn);
    if (disabledCats.has(d.category)) c.push(d.category);
    return c;
  });
  const inspect = (refId: string, rawIds: readonly string[], scopes: readonly string[]) => {
    const hs: string[] = [], ht: string[] = [], hc: CapabilityID[] = [];
    for (const tid of expand(rawIds)) {
      const d = devById.get(tid), sc = sceneById.get(tid);
      if (d) {
        const sLost = isSourceEnabled(before, d.connection, d.sourceScope) && !isSourceEnabled(after, d.connection, d.sourceScope);
        const cLost = before.enabledCategories.includes(d.category) && !after.enabledCategories.includes(d.category);
        if (sLost || cLost) {
          hs.push(d.sourceScope); ht.push(tid);
          const conn = d.connection ?? connectionCapabilityForScope(d.sourceScope);
          if (sLost && conn) hc.push(conn);
          if (cLost) hc.push(d.category);
        }
      } else if (sc) {
        if (isSourceEnabled(before, sc.connection, sc.sourceScope) && !isSourceEnabled(after, sc.connection, sc.sourceScope)) {
          hs.push(sc.sourceScope); ht.push(tid);
          const conn = sc.connection ?? connectionCapabilityForScope(sc.sourceScope);
          if (conn) hc.push(conn);
        }
      } else if (scopes.some((s) => disabledScopes.has(s))) {
        if (scopes.filter((s) => after.enabledConnectionScopes.includes(s)).length === 0) {
          hs.push(...scopes); ht.push(tid);
          for (const s of scopes) { const c = connectionCapabilityForScope(s); if (c) hc.push(c); }
        } else {
          blocking.push({ kind: "unresolvedReferenceOwnership", referenceId: refId, detail: tid });
          return { scopes: [] as string[], targets: [] as string[], caps: [] as CapabilityID[], blocked: true };
        }
      }
    }
    return { scopes: hs, targets: ht, caps: hc, blocked: false };
  };

  for (const t of references.timers ?? []) {
    const kind: AffectedReferenceKind = t.partition === "waiting" ? "waitingTimer" : t.partition === "missed" ? "missedTimer" : "foreignTimer";
    if (t.allTargetsLGLan) {
      const lostLG = expand(t.targetIds).filter((id) => !afterAvail.has(id));
      if (lostLG.length > 0) addItem(kind, t.id, t.name, t.sourceScopes, lostLG, disabledCats.has("tv") ? ["tv"] : []);
      continue;
    }
    const r = inspect(t.id, t.targetIds, t.sourceScopes);
    if (!r.blocked && r.targets.length > 0) addItem(kind, t.id, t.name, r.scopes.length > 0 ? r.scopes : t.sourceScopes, r.targets, r.caps);
  }
  for (const r of references.automations ?? []) {
    if (!r.isEnabled) continue;
    const rScopes = r.sourceScopes ?? [];
    if (disabledFeats.has("event-automation")) { addItem("automationRule", r.id, r.name, rScopes, [], ["event-automation"]); continue; }
    if (r.action.kind === "devices" || r.action.kind === "scene") {
      const res = inspect(r.id, r.action.kind === "devices" ? r.action.targetIds : [r.action.sceneId], rScopes);
      if (!res.blocked && res.targets.length > 0) addItem("automationRule", r.id, r.name, res.scopes, res.targets, res.caps);
    } else if (r.action.kind === "quickAction") {
      const cats = new Set<DeviceCategoryID>(QUICK_ACTION_TARGET_CATEGORIES[r.action.quickAction]);
      const lost = [...beforeAvail].filter((id) => !afterAvail.has(id) && devById.has(id) && cats.has(devById.get(id)!.category));
      const catOff = [...cats].filter((c) => disabledCats.has(c));
      if (lost.length > 0 || catOff.length > 0) addItem("automationRule", r.id, r.name, lost.map((id) => devById.get(id)!.sourceScope), lost, [...lostCaps(lost), ...catOff]);
    } else {
      const lost = [...beforeAvail].filter((id) => !afterAvail.has(id) && devById.get(id)?.participatesInAllOff === true);
      if (lost.length > 0) addItem("automationRule", r.id, r.name, lost.map((id) => devById.get(id)!.sourceScope), lost, lostCaps(lost));
    }
  }
  for (const qa of references.quickActions ?? []) {
    if (qa.isEnabled === false) continue;
    if (qa.targetIds && qa.targetIds.length > 0) {
      const m = expand(qa.targetIds), prev = m.filter((id) => beforeAvail.has(id)), rem = m.filter((id) => afterAvail.has(id));
      if (prev.length > 0 && rem.length === 0) addItem("quickAction", qa.id, qa.name, prev.map((id) => devById.get(id)!.sourceScope), prev, lostCaps(prev));
    } else {
      const cats = new Set<DeviceCategoryID>(QUICK_ACTION_TARGET_CATEGORIES[qa.kind]);
      const prev = beforePart.availableDeviceIds.filter((id) => devById.has(id) && cats.has(devById.get(id)!.category));
      const rem = afterPart.availableDeviceIds.filter((id) => devById.has(id) && cats.has(devById.get(id)!.category));
      const catOff = [...cats].filter((c) => disabledCats.has(c));
      if ((prev.length > 0 && rem.length === 0) || (cats.size > 0 && catOff.length === cats.size)) {
        addItem("quickAction", qa.id, qa.name, prev.map((id) => devById.get(id)!.sourceScope), prev, [...lostCaps(prev), ...catOff]);
      }
    }
  }

  const p = references.preferences ?? {};
  const allPrefIds = new Set([...(p.favoriteDeviceIds ?? []), ...(p.aliasDeviceIds ?? []), ...(p.customOrderDeviceIds ?? []), ...(p.menuBarTargetDeviceIds ?? []), ...(p.pinnedSourceDeviceIds ?? []), ...(p.cameraPreferenceDeviceIds ?? [])]);
  const preserved = sortedUnique([...allPrefIds].filter((id) => devById.has(id) && !afterAvail.has(id)));
  const notices: CapabilitySoftNotice[] = [];
  const activeScenes = (references.scenes ?? []).filter((s) => isSourceEnabled(after, s.connection, s.sourceScope)).map((s) => s.id);
  if (activeScenes.length > 0 && after.enabledCategories.length < DEVICE_CATEGORY_IDS.length) notices.push({ kind: "manualScenesMayControlHiddenDevices", affectedIds: activeScenes });
  if (preserved.length > 0) notices.push({ kind: "preferencesPreserved", affectedIds: preserved });
  if (afterPart.hiddenSafetyRetainedDeviceIds.length > 0) notices.push({ kind: "safetyReadsRetained", affectedIds: afterPart.hiddenSafetyRetainedDeviceIds });
  if (autoChildren.length > 0) notices.push({ kind: "dependentCapabilitiesCascaded", affectedIds: autoChildren });

  const disposition: DeactivationDisposition = blocking.length > 0 ? "blocked" : items.length > 0 ? "requiresPauseConfirmation" : "allowed";
  return { disposition, canDeactivate: disposition !== "blocked", requiresPauseConfirmation: disposition === "requiresPauseConfirmation", cascadedCapabilities: cascaded, itemsToPause: items, softNotices: notices, blockingReasons: blocking, preservedPreferenceDeviceIds: preserved, partition: afterPart };
}

export function evaluateControlTargetGate(options: {
  readonly targetKind: ControlTargetKind; readonly targetId: string; readonly candidateIds?: readonly string[];
  readonly expectedGeneration?: number | null; readonly currentGeneration?: number | null;
  readonly selection: CapabilitySelection; readonly devices: readonly CapabilityIndexedDevice[]; readonly scenes?: readonly SceneReference[];
}): ControlTargetGateVerdict {
  if (options.expectedGeneration != null && options.currentGeneration != null && options.expectedGeneration !== options.currentGeneration) {
    return { allowed: false, writeCount: 0, rejectionReason: { code: "staleGeneration" }, mayControlHiddenDevices: false };
  }
  if (new Set(options.candidateIds ?? []).size > 1) return { allowed: false, writeCount: 0, rejectionReason: { code: "ambiguousTarget" }, mayControlHiddenDevices: false };
  if (options.targetKind === "device") {
    const dev = options.devices.find((d) => d.id === options.targetId && !d.upstreamHiddenOrDisabled);
    if (!dev) return { allowed: false, writeCount: 0, rejectionReason: { code: "deviceNotFound" }, mayControlHiddenDevices: false };
    const conn = dev.connection ?? connectionCapabilityForScope(dev.sourceScope);
    if (!isSourceEnabled(options.selection, conn, dev.sourceScope)) return { allowed: false, writeCount: 0, rejectionReason: { code: "connectionDisabled", connection: conn, scope: dev.sourceScope }, mayControlHiddenDevices: false };
    if (!options.selection.enabledCategories.includes(dev.category)) return { allowed: false, writeCount: 0, rejectionReason: { code: "categoryDisabled", disabledCategory: dev.category }, mayControlHiddenDevices: false };
    if (dev.isSourceAvailable === false) return { allowed: false, writeCount: 0, rejectionReason: { code: "connectionUnavailable", connection: conn, scope: dev.sourceScope }, mayControlHiddenDevices: false };
    return { allowed: true, writeCount: 1, rejectionReason: null, mayControlHiddenDevices: false };
  }
  const sc = (options.scenes ?? []).find((s) => s.id === options.targetId);
  if (!sc) return { allowed: false, writeCount: 0, rejectionReason: { code: "sceneNotFound" }, mayControlHiddenDevices: false };
  const conn = sc.connection ?? connectionCapabilityForScope(sc.sourceScope);
  if (!isSourceEnabled(options.selection, conn, sc.sourceScope)) return { allowed: false, writeCount: 0, rejectionReason: { code: "connectionDisabled", connection: conn, scope: sc.sourceScope }, mayControlHiddenDevices: false };
  if (sc.isSourceAvailable === false) return { allowed: false, writeCount: 0, rejectionReason: { code: "connectionUnavailable", connection: conn, scope: sc.sourceScope }, mayControlHiddenDevices: false };
  return { allowed: true, writeCount: 1, rejectionReason: null, mayControlHiddenDevices: options.selection.enabledCategories.length < DEVICE_CATEGORY_IDS.length };
}

export function evaluatePlanTargetsGate(options: {
  readonly targets: readonly { readonly kind: ControlTargetKind; readonly id: string }[];
  readonly expectedGeneration?: number | null; readonly currentGeneration?: number | null;
  readonly selection: CapabilitySelection; readonly devices: readonly CapabilityIndexedDevice[]; readonly scenes?: readonly SceneReference[];
}): PlanTargetGateVerdict {
  for (const t of options.targets) {
    const v = evaluateControlTargetGate({ targetKind: t.kind, targetId: t.id, expectedGeneration: options.expectedGeneration ?? null, currentGeneration: options.currentGeneration ?? null, selection: options.selection, devices: options.devices, scenes: options.scenes ?? [] });
    if (!v.allowed) return { allowed: false, writeCount: 0, rejectedTargetId: t.id, rejectionReason: v.rejectionReason };
  }
  return { allowed: true, writeCount: options.targets.length, rejectedTargetId: null, rejectionReason: null };
}

export function revalidatePausedTimer(options: {
  readonly timer: TimerReference; readonly fireAtEpochSeconds: number; readonly nowEpochSeconds: number;
  readonly activeConnectionScopes: readonly string[]; readonly selection: CapabilitySelection;
  readonly devices: readonly CapabilityIndexedDevice[]; readonly scenes?: readonly SceneReference[];
}): PausedTimerResumeDisposition {
  const stamped = new Set(options.timer.sourceScopes), active = new Set(options.activeConnectionScopes);
  if (!options.timer.allTargetsLGLan && [...active].some((s) => s.startsWith("ha:") && !stamped.has(s))) return "partitionForeign";
  const scenes = options.scenes ?? [], sceneIds = new Set(scenes.map((s) => s.id));
  const targets = options.timer.targetIds.map((id) => ({ kind: (sceneIds.has(id) ? "scene" : "device") as ControlTargetKind, id }));
  if (!evaluatePlanTargetsGate({ targets, selection: options.selection, devices: options.devices, scenes }).allowed) return "keepPaused";
  if (!options.timer.allTargetsLGLan && ![...stamped].some((s) => active.has(s))) return "partitionForeign";
  return options.fireAtEpochSeconds <= options.nowEpochSeconds ? "moveToMissed" : "armWaiting";
}

export const CONNECTION_CAPABILITIES_USED = CONNECTION_CAPABILITY_IDS;
