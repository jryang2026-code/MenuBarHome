import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import {
  ALERT_SEVERITIES,
  alertSeverityRank,
  sensorAlertSeverity,
} from "../src/core/alertSeverity.js";
import { SENSOR_ALERT_KINDS, sensorAlertIsHazard } from "../src/core/safetyAndHealth.js";

/**
 * R16 §1.5: the two-level alert severity table is one shared contract. macOS reads the same
 * fixture in `Tests/MijiaCoreTests/AlertSeverityTests.swift`.
 */
interface Golden {
  readonly schemaVersion: number;
  readonly severities: Readonly<Record<string, string>>;
}

const golden = JSON.parse(
  readFileSync(new URL("../../Tests/Fixtures/alert_severity_golden.json", import.meta.url), "utf8"),
) as Golden;

describe("alert severity table", () => {
  it("matches the shared golden fixture for every sensor kind", () => {
    assert.equal(golden.schemaVersion, 1);
    assert.deepEqual(Object.keys(golden.severities).sort(), [...SENSOR_ALERT_KINDS].sort());
    for (const kind of SENSOR_ALERT_KINDS) {
      assert.equal(sensorAlertSeverity(kind), golden.severities[kind], kind);
    }
  });

  it("ranks alert before warning", () => {
    assert.deepEqual([...ALERT_SEVERITIES].sort((left, right) => alertSeverityRank(left) - alertSeverityRank(right)), [
      "alert",
      "warning",
    ]);
  });

  it("keeps the 24/7 hazard axis separate: a lock is an alert but still honors away-only", () => {
    for (const kind of SENSOR_ALERT_KINDS) {
      assert.equal(sensorAlertIsHazard(kind), sensorAlertSeverity(kind) === "alert" && kind !== "lock", kind);
    }
  });
});
