import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { cameraLensesFor } from "../src/core/miCloud/cameraLens.js";

describe("camera lens names", () => {
  it("keeps a catalog model and an affirmed dual name", () => {
    assert.deepEqual(
      cameraLensesFor("isa.camera.500dh").map((lens) => lens.channel),
      [0, 1],
    );
    assert.equal(cameraLensesFor("vendor.camera.unknown", "客厅双摄").length, 2);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "Front dual-lens").length, 2);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "双镜头摄像机").length, 2);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "客廳雙攝").length, 2);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "雙鏡頭攝像機").length, 2);
  });

  it("does not treat a substring or a negation as a second lens", () => {
    assert.equal(cameraLensesFor("chuangmi.camera.81ac1", "客厅摄像机").length, 0);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "Individual").length, 0);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "不是双摄").length, 0);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "不是双镜头").length, 0);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "不是雙攝").length, 0);
    assert.equal(cameraLensesFor("vendor.camera.unknown", "not dual").length, 0);
  });
});
