import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import { ModelActionPolicy } from "../src/core/assistant.js";
import { loadSharedCapabilityManifest, type CapabilityID } from "../src/core/capabilityManifest.js";
import {
  capabilitySoftNoticeMessage, controlTargetRejectionMessage, evaluateCapabilityDeactivation,
  evaluateControlTargetGate, evaluatePlanTargetsGate, revalidatePausedTimer, resolveCapabilityInstallSelection,
  type AffectedReferenceItem, type CapabilityBlockingReason, type CapabilityIndexedDevice,
  type CapabilityInstallEvidence, type CapabilityInstallResolutionMode, type CapabilityReferenceGraph,
  type CapabilitySelection, type CapabilitySoftNotice, type ControlTargetKind, type ControlTargetRejectionCode,
  type DeactivationDisposition, type DeviceGroupReference, type DeviceSetPartition,
  type PausedTimerResumeDisposition, type SafetyRetentionPolicy, type SceneReference, type TimerReference,
} from "../src/core/capabilityReferenceVerdict.js";
import type { SmartDevice } from "../src/core/models.js";
import { evaluateSensorAlerts } from "../src/core/safetyAndHealth.js";

interface GoldenCorpus {
  readonly version: number;
  readonly catalog: {
    readonly devices: readonly CapabilityIndexedDevice[];
    readonly scenes: readonly SceneReference[];
    readonly deviceGroups: readonly DeviceGroupReference[];
  };
  readonly upgradeCases: readonly {
    readonly id: string; readonly evidence: CapabilityInstallEvidence;
    readonly expectedMode: CapabilityInstallResolutionMode; readonly expectedPersistMigrationComplete: boolean;
    readonly expectedRetryDiagnostic: string | null; readonly expectedSelection: CapabilitySelection;
  }[];
  readonly deactivationCases: readonly {
    readonly id: string; readonly current: CapabilitySelection; readonly proposed: CapabilitySelection;
    readonly safetyPolicy: SafetyRetentionPolicy; readonly references: CapabilityReferenceGraph;
    readonly expectedDisposition: DeactivationDisposition; readonly expectedCascadedCapabilities: readonly CapabilityID[];
    readonly expectedItemsToPause: readonly AffectedReferenceItem[]; readonly expectedSoftNotices: readonly CapabilitySoftNotice[];
    readonly expectedBlockingReasons: readonly CapabilityBlockingReason[];
    readonly expectedPreservedPreferenceDeviceIds: readonly string[];
    readonly expectedPartition: DeviceSetPartition; readonly expectLeakAlertWhenSensorTriggers: boolean | null;
  }[];
  readonly writeGateCases: readonly {
    readonly id: string; readonly targetKind: ControlTargetKind; readonly targetId: string;
    readonly candidateIds: readonly string[]; readonly expectedGeneration: number | null; readonly currentGeneration: number | null;
    readonly selection: CapabilitySelection; readonly expectedAllowed: boolean; readonly expectedWriteCount: number;
    readonly expectedRejectionCode: ControlTargetRejectionCode | null;
    readonly expectedZhMessage: string | null; readonly expectedEnMessage: string | null;
    readonly expectedMayControlHiddenDevices: boolean; readonly expectConfirmationFalseOnCroppedSet: boolean;
  }[];
  readonly planGateCases: readonly {
    readonly id: string; readonly targets: readonly { readonly kind: ControlTargetKind; readonly id: string }[];
    readonly selection: CapabilitySelection; readonly expectedAllowed: boolean; readonly expectedWriteCount: number;
    readonly expectedRejectedTargetId: string | null; readonly expectedRejectionCode: ControlTargetRejectionCode | null;
  }[];
  readonly pausedTimerResumeCases: readonly {
    readonly id: string; readonly timer: TimerReference; readonly fireAtEpochSeconds: number; readonly nowEpochSeconds: number;
    readonly activeConnectionScopes: readonly string[]; readonly selection: CapabilitySelection;
    readonly expectedDisposition: PausedTimerResumeDisposition;
  }[];
}

const loadGolden = (): GoldenCorpus =>
  JSON.parse(readFileSync(resolve(process.cwd(), "..", "Tests/Fixtures/capability_selection_golden.json"), "utf8")) as GoldenCorpus;

describe("Shared capability selection and reference verdicts (P1b)", () => {
  it("matches Tests/Fixtures/capability_selection_golden.json across upgrade, deactivation, safety retention, write gate, and timer resume", () => {
    const manifest = loadSharedCapabilityManifest();
    const corpus = loadGolden();
    assert.equal(corpus.version, 1);

    for (const c of corpus.upgradeCases) {
      const actual = resolveCapabilityInstallSelection(c.evidence, manifest);
      assert.equal(actual.mode, c.expectedMode, c.id);
      assert.equal(actual.persistMigrationComplete, c.expectedPersistMigrationComplete, c.id);
      assert.equal(actual.retryDiagnostic, c.expectedRetryDiagnostic, c.id);
      assert.deepEqual(actual.selection, c.expectedSelection, c.id);
    }

    const leakDevice: SmartDevice = {
      id: "sensor.kitchen_leak", name: "厨房水浸传感器", roomId: "kitchen", roomName: "厨房",
      model: "lumi.sensor_wleak.aq1", isOnline: true,
      kind: {
        kind: "sensor", temperature: null, humidity: null, battery: 90,
        statusText: "浸水告警", alertKind: "leak",
        safetyObservations: [{ entityId: "105.2.1", kind: "leak", alarming: true }],
      },
    };
    for (const c of corpus.deactivationCases) {
      const actual = evaluateCapabilityDeactivation(c.current, c.proposed, manifest, corpus.catalog.devices, c.safetyPolicy, c.references);
      assert.equal(actual.disposition, c.expectedDisposition, c.id);
      assert.deepEqual(actual.cascadedCapabilities, c.expectedCascadedCapabilities, c.id);
      assert.deepEqual(actual.itemsToPause, c.expectedItemsToPause, c.id);
      assert.deepEqual(actual.softNotices, c.expectedSoftNotices, c.id);
      assert.deepEqual(actual.blockingReasons, c.expectedBlockingReasons, c.id);
      assert.deepEqual(actual.preservedPreferenceDeviceIds, c.expectedPreservedPreferenceDeviceIds, c.id);
      assert.deepEqual(actual.partition, c.expectedPartition, c.id);
      if (c.expectLeakAlertWhenSensorTriggers !== null) {
        const evalDevices = actual.partition.safetyEvaluationDeviceIds.includes(leakDevice.id) ? [leakDevice] : [];
        const res = evaluateSensorAlerts(evalDevices, {}, 1_700_000_000_000, {
          enabled: { leak: c.safetyPolicy.enabledSignals.includes("leak") }, onlyWhenAway: false, includesAway: true,
        });
        assert.equal(res.alerts.length > 0, c.expectLeakAlertWhenSensorTriggers, c.id);
      }
    }

    for (const c of corpus.writeGateCases) {
      const v = evaluateControlTargetGate({
        targetKind: c.targetKind, targetId: c.targetId, candidateIds: c.candidateIds,
        expectedGeneration: c.expectedGeneration, currentGeneration: c.currentGeneration,
        selection: c.selection, devices: corpus.catalog.devices, scenes: corpus.catalog.scenes,
      });
      assert.equal(v.allowed, c.expectedAllowed, c.id);
      assert.equal(v.writeCount, c.expectedWriteCount, c.id);
      assert.equal(v.rejectionReason?.code ?? null, c.expectedRejectionCode, c.id);
      assert.equal(v.mayControlHiddenDevices, c.expectedMayControlHiddenDevices, c.id);
      assert.equal(v.rejectionReason ? controlTargetRejectionMessage(v.rejectionReason, "zh-Hans") : null, c.expectedZhMessage, c.id);
      assert.equal(v.rejectionReason ? controlTargetRejectionMessage(v.rejectionReason, "en") : null, c.expectedEnMessage, c.id);
      if (v.mayControlHiddenDevices) {
        assert.match(capabilitySoftNoticeMessage("manualScenesMayControlHiddenDevices", "zh-Hans"), /可能控制已隐藏的设备/);
      }
      if (c.expectConfirmationFalseOnCroppedSet) {
        assert.equal(ModelActionPolicy.needsConfirmation({ targetId: c.targetId, operation: { kind: "power", isOn: true } }, []), false, c.id);
      }
    }

    for (const c of corpus.planGateCases) {
      const v = evaluatePlanTargetsGate({ targets: c.targets, selection: c.selection, devices: corpus.catalog.devices, scenes: corpus.catalog.scenes });
      assert.equal(v.allowed, c.expectedAllowed, c.id);
      assert.equal(v.writeCount, c.expectedWriteCount, c.id);
      assert.equal(v.rejectedTargetId, c.expectedRejectedTargetId, c.id);
      assert.equal(v.rejectionReason?.code ?? null, c.expectedRejectionCode, c.id);
    }

    for (const c of corpus.pausedTimerResumeCases) {
      const d = revalidatePausedTimer({
        timer: c.timer, fireAtEpochSeconds: c.fireAtEpochSeconds, nowEpochSeconds: c.nowEpochSeconds,
        activeConnectionScopes: c.activeConnectionScopes, selection: c.selection,
        devices: corpus.catalog.devices, scenes: corpus.catalog.scenes,
      });
      assert.equal(d, c.expectedDisposition, c.id);
    }
  });
});
