import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import type { Window } from "happy-dom";

import {
  CAMERA_EVENT_LIMIT,
  CAMERA_EVENT_RETENTION_MS,
  CAMERA_STILL_REFRESH_COOLDOWN_MS,
  CAMERA_STILL_WALL_LIMIT,
  CameraEventStore,
  StillWallCaptureThrottler,
  isSafeSnapshotFilename,
  sanitizeCameraEventRecord,
  selectStillWallCameras,
  type CameraEventPersistence,
} from "../src/core/cameraEventStore.js";
import type { SmartDevice } from "../src/core/models.js";
import { MenuMijiaWindowsApp } from "../src/ui/app.js";
import {
  ingestHostHASnapshotForDoorbell,
  syncSingleOwnerLifecycle,
} from "../src/ui/activityStackView.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const GOLDEN_PATH = path.resolve(__dirname, "../../Tests/Fixtures/camera_event_golden.json");

function makeCamera(id: string, name = id, isOnline = true): SmartDevice {
  return {
    id,
    name,
    roomId: "door",
    roomName: "门口",
    model: "chuangmi.camera.061a01",
    isOnline,
    kind: {
      kind: "camera",
      entityId: `miot:${id}:2`,
      isOn: true,
      powerWritable: true,
      streamEntityId: null,
      nightShot: null,
      availableNightShots: [],
      motionDetectionEntityId: null,
      isMotionDetectionOn: null,
    },
  };
}

describe("CameraEventStore & golden contract (#447)", () => {
  it("matches Tests/Fixtures/camera_event_golden.json limits, valid records, malformed records, and wall ordering", () => {
    const golden = JSON.parse(readFileSync(GOLDEN_PATH, "utf8")) as {
      retentionSeconds: number;
      maxEvents: number;
      stillWallLimit: number;
      stillRefreshCooldownSeconds: number;
      validRecords: unknown[];
      malformedRecords: Array<{ reason: string; record: unknown }>;
      unsafeSnapshotFilenames: string[];
      stillWallSelectionCase: {
        visibleCameraIds: string[];
        eventfulCameraIds: string[];
        limit: number;
        expectedOrder: string[];
      };
    };

    assert.equal(CAMERA_EVENT_RETENTION_MS, golden.retentionSeconds * 1000);
    assert.equal(CAMERA_EVENT_LIMIT, golden.maxEvents);
    assert.equal(CAMERA_STILL_WALL_LIMIT, golden.stillWallLimit);
    assert.equal(CAMERA_STILL_REFRESH_COOLDOWN_MS, golden.stillRefreshCooldownSeconds * 1000);

    for (const valid of golden.validRecords) {
      const parsed = sanitizeCameraEventRecord(valid);
      assert.ok(parsed !== null, `Expected valid golden record to parse: ${JSON.stringify(valid)}`);
      if (parsed.snapshotFile !== null) {
        assert.equal(parsed.snapshotFile.includes("://"), false);
        assert.equal(parsed.snapshotFile.includes("/"), false);
      }
    }

    for (const entry of golden.malformedRecords) {
      assert.equal(
        sanitizeCameraEventRecord(entry.record),
        null,
        `Malformed golden record (${entry.reason}) must be rejected`,
      );
    }

    for (const unsafe of golden.unsafeSnapshotFilenames) {
      assert.equal(
        isSafeSnapshotFilename(unsafe),
        false,
        `Unsafe snapshot filename must be rejected: ${JSON.stringify(unsafe)}`,
      );
    }

    const { visibleCameraIds, eventfulCameraIds, limit, expectedOrder } = golden.stillWallSelectionCase;
    const eventful = new Set(eventfulCameraIds);
    const ordered = selectStillWallCameras(
      visibleCameraIds.map((id) => makeCamera(id)),
      (id) => eventful.has(id),
      limit,
    );
    assert.deepEqual(
      ordered.map((d) => d.id),
      expectedOrder,
    );
  });

  it("enforces retention window, max event cap, snapshot eviction, and rejects URLs/credentials", () => {
    let clockMs = 1_700_000_000_000;
    const store = new CameraEventStore({
      retentionMs: 100_000,
      limit: 2,
      now: () => clockMs,
    });

    const first = store.record({
      cameraID: "cam-a",
      kind: "doorbell",
      snapshotBase64: "AQID",
    });
    assert.ok(first);
    assert.equal(store.snapshotBase64(first), "AQID");
    assert.ok(first.snapshotFile && !first.snapshotFile.includes("://") && !first.snapshotFile.includes("/"));

    assert.equal(
      store.record({ cameraID: "rtsp://admin:secret@192.0.2.10/live", kind: "doorbell" }),
      null,
    );

    store.record({ cameraID: "cam-b", kind: "motion" });
    store.record({ cameraID: "cam-c", kind: "person" });
    assert.equal(store.allEvents().length, 2);
    assert.equal(store.snapshotBase64(first), null, "evicted event snapshot must be purged");

    clockMs += 101_000;
    store.record({ cameraID: "cam-d", kind: "package" });
    assert.equal(store.allEvents().length, 1);
    assert.equal(store.latestEvent("cam-d")?.kind, "package");
  });

  it("recovers valid entries when persistence returns malformed records and hydrates snapshots", async () => {
    let clockMs = Date.parse("2026-11-24T12:00:00Z");
    const persistence: CameraEventPersistence = {
      async load() {
        return [
          {
            id: "good-1",
            cameraID: "cam-front",
            kind: "doorbell",
            timestamp: "2026-11-24T11:50:00Z",
            snapshotFile: "snapshot-good-1.jpeg",
          },
          {
            id: "bad-url",
            cameraID: "http://user:pass@192.0.2.1/cam",
            kind: "motion",
            timestamp: "2026-11-24T11:55:00Z",
          },
          "corrupt-row",
          {
            id: "good-2",
            cameraID: "cam-back",
            kind: "motion",
            timestamp: "2026-11-24T11:55:00Z",
            snapshotFile: "../secret.jpeg",
          },
        ];
      },
      async record() {
        return null;
      },
      async attachSnapshot() {
        return null;
      },
      async readSnapshot(file) {
        return file === "snapshot-good-1.jpeg" ? "aGVsbG8=" : null;
      },
      async clear() {},
    };

    const store = new CameraEventStore({ now: () => clockMs, persistence });
    const loaded = await store.load();
    assert.equal(loaded.length, 2);
    assert.equal(loaded[0]?.id, "good-1");
    assert.equal(loaded[1]?.snapshotFile, null, "path traversal snapshotFile must be stripped");

    const hydrated = await store.hydrateSnapshot(loaded[0]!);
    assert.equal(hydrated, true);
    assert.equal(store.snapshotDataUrl(loaded[0]!), "data:image/jpeg;base64,aGVsbG8=");
  });

  it("throttles still captures: serial concurrency, 1-minute per-camera cooldown, and skips while live stream is open", async () => {
    let clockMs = 100_000;
    let liveActive = false;
    const throttler = new StillWallCaptureThrottler({
      perCameraCooldownMs: 60_000,
      globalGapMs: 2_500,
      now: () => clockMs,
      isLiveActive: () => liveActive,
    });

    let activeFetches = 0;
    let maxConcurrent = 0;
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });

    const p1 = throttler.captureOnce("cam-1", async () => {
      activeFetches += 1;
      maxConcurrent = Math.max(maxConcurrent, activeFetches);
      await firstGate;
      activeFetches -= 1;
      return "frame-1";
    });
    // Concurrent capture for another camera is rejected while one is in flight.
    const p2 = throttler.captureOnce("cam-2", async () => "frame-2");
    assert.equal(await p2, null);
    releaseFirst();
    assert.equal(await p1, "frame-1");
    assert.equal(maxConcurrent, 1);

    // Within 60s cooldown, cam-1 is skipped.
    clockMs += 10_000;
    assert.equal(await throttler.captureOnce("cam-1", async () => "frame-1b"), null);
    // Different camera after global gap succeeds.
    assert.equal(await throttler.captureOnce("cam-2", async () => "frame-2"), "frame-2");

    // While live view is open, still captures are skipped.
    clockMs += 70_000;
    liveActive = true;
    assert.equal(await throttler.captureOnce("cam-1", async () => "frame-live"), null);

    // Once live view closes and cooldown has elapsed, capture succeeds again.
    liveActive = false;
    assert.equal(await throttler.captureOnce("cam-1", async () => "frame-1c"), "frame-1c");
  });
});

describe("Windows camera still wall UI (#447)", () => {
  let dom: Window;

  beforeEach(() => {
    dom = mountTestWindow();
  });

  afterEach(() => {
    closeTestWindow(dom);
  });

  it("renders a 2x2 still wall excluding hidden cameras, prioritizes eventful cameras, and preserves click-to-live", async () => {
    const root = document.querySelector<HTMLElement>("#app")!;
    const app = new MenuMijiaWindowsApp(root);
    app.devices = [
      makeCamera("cam-a", "玄关摄像机"),
      makeCamera("cam-b", "阳台摄像机"),
      makeCamera("cam-c", "客厅摄像机"),
      makeCamera("cam-d", "门口摄像机"),
      makeCamera("cam-e", "走廊摄像机"),
      makeCamera("cam-f", "车库摄像机", false),
      makeCamera("cam-g", "院子摄像机"),
    ];
    app.settings.layout = { ...app.settings.layout, hiddenDeviceIds: ["cam-a", "cam-b"] };
    app.expandedDeviceId = "cam-d";

    // No events yet -> wall stays hidden.
    app.render();
    assert.equal(root.querySelector(".cc-camera-still-wall"), null);

    // Record events for cam-e and cam-d (with a snapshot for cam-d).
    app.cameraEventStore.record({ cameraID: "cam-e", kind: "motion" });
    app.cameraEventStore.record({ cameraID: "cam-d", kind: "doorbell", snapshotBase64: "aGVsbG8=" });
    app.render();

    const tiles = [...root.querySelectorAll<HTMLButtonElement>(".cc-camera-still-tile")];
    assert.deepEqual(
      tiles.map((t) => t.dataset.stillTile),
      ["cam-d", "cam-e", "cam-c", "cam-f"],
    );
    const img = tiles[0]!.querySelector<HTMLImageElement>(".cc-camera-still-img");
    assert.equal(img?.getAttribute("src"), "data:image/jpeg;base64,aGVsbG8=");
    assert.equal(tiles[3]!.disabled, true, "offline camera tile must be disabled");

    // Clicking an online still tile opens live view for that camera without opening all cameras.
    const opened: string[] = [];
    app.cameraLive.openCameraLiveView = (id: string) => {
      opened.push(id);
    };
    tiles[1]!.click();
    await setImmediate();
    assert.deepEqual(opened, ["cam-e"]);
  });

  it("records doorbell rings into cameraEventStore and clears history on scope switch", async () => {
    const root = document.querySelector<HTMLElement>("#app")!;
    const app = new MenuMijiaWindowsApp(root);
    const doorCam: SmartDevice = {
      ...makeCamera("ha:dev_door", "门口门铃"),
      kind: {
        kind: "camera",
        entityId: "camera.front_door",
        isOn: true,
        powerWritable: true,
        streamEntityId: null,
        nightShot: null,
        availableNightShots: [],
        motionDetectionEntityId: null,
        isMotionDetectionOn: null,
      },
    };
    app.devices = [doorCam];
    const baseSnapshot = {
      devices: [{ id: "dev_door", area_id: "area_entry", disabled_by: null }],
      entities: [
        { entity_id: "camera.front_door", device_id: "dev_door", disabled_by: null, hidden_by: null },
        { entity_id: "event.front_doorbell", device_id: "dev_door", disabled_by: null, hidden_by: null },
      ],
      states: [
        {
          entity_id: "event.front_doorbell",
          state: "2026-11-24T12:00:00Z",
          attributes: { device_class: "doorbell" },
        },
      ],
    };
    // Prime detector baseline, then ring.
    await ingestHostHASnapshotForDoorbell(app, baseSnapshot, { isLocked: false, autoPopup: false, playChime: false });
    await ingestHostHASnapshotForDoorbell(
      app,
      {
        ...baseSnapshot,
        states: [
          {
            entity_id: "event.front_doorbell",
            state: "2026-11-24T12:01:00Z",
            attributes: { device_class: "doorbell" },
          },
        ],
      },
      { isLocked: false, autoPopup: false, playChime: false },
    );
    assert.equal(app.cameraEventStore.latestEvent("ha:dev_door")?.kind, "doorbell");

    // Switching scope / connection mode clears the local camera event history.
    app.settings.connectionMode = "homeAssistant";
    syncSingleOwnerLifecycle(app);
    assert.equal(app.cameraEventStore.allEvents().length, 0);
  });
});
