import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { computeHomeSummary, formatHomeSummaryCapsuleTitle } from "../src/core/homeSummary.js";
import {
  DEFAULT_OVERVIEW_SLOT_BUDGET,
  overviewSlotCost,
  selectOverviewSlotBudget,
  type OverviewSlotSize,
} from "../src/core/overviewSlotBudget.js";
import { setLanguage } from "../src/core/i18n.js";
import type { SmartDevice } from "../src/core/models.js";
import { buildPanelDeviceGridModel, type PanelSplitGridHost } from "../src/ui/panelSplitTiles.js";
import { emptyLayoutPrefs } from "../src/ui/panelPrefs.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = path.resolve(__dirname, "../../Tests/Fixtures");

interface HomeSummaryGolden {
  schemaVersion: number;
  cases: Array<{
    name: string;
    devices: Array<{
      id: string;
      kind: string;
      isOnline: boolean;
      isOn?: boolean;
      positionPercent?: number;
      contactAlarming?: boolean;
      temperature?: number;
      currentTemperature?: number;
    }>;
    alerts: Array<{ id: string; deviceId: string }>;
    lightMarkedSwitchIds: string[];
    expected: Array<{
      kind: string;
      count: number;
      temperatureCelsius?: number;
      alertSeverity: string | null;
      targetDeviceIds: string[];
      filterTag: string | null;
    }>;
  }>;
}

interface SlotBudgetGolden {
  schemaVersion: number;
  defaultBudget: number;
  slotCosts: Record<OverviewSlotSize, number>;
  cases: Array<{
    name: string;
    budget: number;
    items: Array<{ id: string; size: OverviewSlotSize; isPinned: boolean }>;
    keepingVisibleIds: string[];
    expectedVisibleIds: string[];
    expectedHiddenIds: string[];
    expectedUsedSlots: number;
    expectedEffectiveBudget: number;
  }>;
}

function makeDevice(fixture: HomeSummaryGolden["cases"][number]["devices"][number]): SmartDevice {
  const base = {
    id: fixture.id,
    name: fixture.id,
    roomId: "living",
    roomName: "客厅",
    model: "",
    isOnline: fixture.isOnline,
  };
  switch (fixture.kind) {
    case "light":
      return {
        ...base,
        kind: {
          kind: "light",
          entityId: `light.${fixture.id}`,
          isOn: fixture.isOn ?? false,
          brightnessPercent: null,
          colorTempKelvin: null,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
        },
      };
    case "plug":
      return {
        ...base,
        kind: {
          kind: "plug",
          switchEntityId: `switch.${fixture.id}`,
          isOn: fixture.isOn ?? false,
          powerWatts: null,
          childLockEntityId: null,
          isChildLocked: false,
        },
      };
    case "cover":
      return {
        ...base,
        kind: {
          kind: "cover",
          entityId: `cover.${fixture.id}`,
          subtype: "curtain",
          positionPercent: fixture.positionPercent ?? null,
          positionWritable: true,
          openDescription: null,
          closeDescription: null,
          pauseDescription: null,
          batteryPercent: null,
          faultText: null,
          motion: "stopped",
        },
      };
    case "climate":
      return {
        ...base,
        kind: {
          kind: "climate",
          entityId: `climate.${fixture.id}`,
          isOn: fixture.isOn ?? false,
          hvacMode: fixture.isOn ? "cool" : "off",
          availableModes: ["off", "cool"],
          targetTemperature: 24,
          currentTemperature: fixture.currentTemperature ?? null,
          minTemp: 16,
          maxTemp: 30,
          step: 1,
          fanMode: null,
          availableFanModes: [],
        },
      };
    default:
      return {
        ...base,
        kind: {
          kind: "sensor",
          temperature: fixture.temperature ?? null,
          humidity: null,
          battery: null,
          safetyObservations: fixture.contactAlarming
            ? [{ entityId: `contact.${fixture.id}`, kind: "contact", alarming: true }]
            : [],
        },
      };
  }
}

test("computeHomeSummary matches shared home_summary_golden.json fixture", () => {
  const golden = JSON.parse(
    fs.readFileSync(path.join(FIXTURES_DIR, "home_summary_golden.json"), "utf8"),
  ) as HomeSummaryGolden;
  assert.equal(golden.schemaVersion, 1);

  for (const tc of golden.cases) {
    const devices = tc.devices.map(makeDevice);
    const summary = computeHomeSummary({
      devices,
      alerts: tc.alerts,
      lightMarkedSwitchIds: new Set(tc.lightMarkedSwitchIds),
    });
    assert.equal(summary.isEmpty, tc.expected.length === 0, tc.name);
    assert.equal(summary.capsules.length, tc.expected.length, tc.name);
    tc.expected.forEach((exp, idx) => {
      const actual = summary.capsules[idx]!;
      assert.equal(actual.kind, exp.kind, tc.name);
      assert.equal(actual.count, exp.count, tc.name);
      assert.equal(actual.alertSeverity, exp.alertSeverity, tc.name);
      assert.deepEqual(actual.targetDeviceIds, exp.targetDeviceIds, tc.name);
      assert.equal(actual.filterTag, exp.filterTag, tc.name);
      if (exp.temperatureCelsius !== undefined) {
        assert.ok(actual.temperatureCelsius !== null, tc.name);
        assert.ok(Math.abs(actual.temperatureCelsius - exp.temperatureCelsius) < 0.001, tc.name);
      } else {
        assert.equal(actual.temperatureCelsius, null, tc.name);
      }
    });
  }
});

test("formatHomeSummaryCapsuleTitle localizes in zh-Hans, zh-Hant, en and converts °F", () => {
  const capsules = [
    { kind: "alerts" as const, count: 1, temperatureCelsius: null, alertSeverity: "alert" as const, targetDeviceIds: [], filterTag: null },
    { kind: "lightsOn" as const, count: 3, temperatureCelsius: null, alertSeverity: null, targetDeviceIds: [], filterTag: "light" as const },
    { kind: "doorsOpen" as const, count: 2, temperatureCelsius: null, alertSeverity: null, targetDeviceIds: [], filterTag: "cover" as const },
    { kind: "indoorTemp" as const, count: 1, temperatureCelsius: 24, alertSeverity: null, targetDeviceIds: [], filterTag: "sensor" as const },
  ];

  try {
    setLanguage("zh-Hans");
    assert.deepEqual(
      capsules.map((c) => formatHomeSummaryCapsuleTitle(c, "celsius")),
      ["1 条告警", "3 盏灯开着", "2 处门窗开着", "室内 24°"],
    );
    setLanguage("zh-Hant");
    assert.deepEqual(
      capsules.map((c) => formatHomeSummaryCapsuleTitle(c, "celsius")),
      ["1 條告警", "3 盞燈開著", "2 處門窗開著", "室內 24°"],
    );
    setLanguage("en");
    assert.deepEqual(
      capsules.map((c) => formatHomeSummaryCapsuleTitle(c, "fahrenheit")),
      ["1 alert", "3 lights on", "2 doors/windows open", "Indoor 75°"],
    );
  } finally {
    setLanguage("zh-Hans");
  }
});

test("selectOverviewSlotBudget matches shared slot_budget_golden.json fixture", () => {
  const golden = JSON.parse(
    fs.readFileSync(path.join(FIXTURES_DIR, "slot_budget_golden.json"), "utf8"),
  ) as SlotBudgetGolden;
  assert.equal(golden.schemaVersion, 1);
  assert.equal(DEFAULT_OVERVIEW_SLOT_BUDGET, golden.defaultBudget);

  for (const [size, cost] of Object.entries(golden.slotCosts)) {
    assert.equal(overviewSlotCost(size as OverviewSlotSize), cost, size);
  }

  for (const tc of golden.cases) {
    const result = selectOverviewSlotBudget({
      items: tc.items,
      budget: tc.budget,
      keepingVisibleIds: new Set(tc.keepingVisibleIds),
    });
    assert.deepEqual(result.visibleIds, tc.expectedVisibleIds, tc.name);
    assert.deepEqual(result.hiddenIds, tc.expectedHiddenIds, tc.name);
    assert.equal(result.usedSlots, tc.expectedUsedSlots, tc.name);
    assert.equal(result.effectiveBudget, tc.expectedEffectiveBudget, tc.name);
    assert.equal(result.hiddenCount, tc.expectedHiddenIds.length, tc.name);
    assert.equal(result.hasOverflow, tc.expectedHiddenIds.length > 0, tc.name);
  }
});

test("buildPanelDeviceGridModel applies size-weighted slot budget with pinned items preserved", () => {
  const devices: SmartDevice[] = [
    makeDevice({ id: "ac1", kind: "climate", isOnline: true, isOn: true }),
    ...Array.from({ length: 8 }, (_, idx) =>
      makeDevice({ id: `light_${idx + 1}`, kind: "light", isOnline: true, isOn: false }),
    ),
  ];
  const layout = emptyLayoutPrefs();
  const host: PanelSplitGridHost = {
    isEditingLayout: false,
    listCut: { kind: "all" },
    selectedRoom: "全部",
    layout,
    devices,
    presentationDevices: devices,
    roomOptions: [{ id: "living", name: "客厅" }],
    expandedDeviceId: null,
    pendingHighRisk: null,
    waitingDeviceIds: new Set(),
    valuesAreStale: false,
    settings: {
      hideOfflineDevices: false,
      isCompactGridMode: true,
      climatePanel: true,
    },
    isLongTailExpanded: false,
    isOfflineDrawerExpanded: false,
    isRoomBrowseMenuOpen: false,
    hasInteractedInPanelSession: false,
    prioritySnapshot: null,
  };

  // 1 full climate (4 slots) + 6 half lights (12 slots) = 16 slots -> 7 visible, 2 hidden.
  const model = buildPanelDeviceGridModel(host);
  assert.equal(model.visibleOnlineCount, 7);
  assert.equal(model.hiddenOnlineCount, 2);
  assert.equal(model.showsLongTailBar, true);
});
