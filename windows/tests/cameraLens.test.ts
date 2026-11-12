import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { setLanguage } from "../src/core/i18n.js";
import {
  CameraHubCatalog,
  parsePrivateLanIpv4,
  resolveCameraHub,
} from "../src/core/miCloud/cameraHubs.js";
import { cameraLensLabel, cameraLensesFor } from "../src/core/miCloud/cameraLens.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import type { MiotDeviceSpec } from "../src/core/miCloud/spec.js";

afterEach(() => {
  setLanguage("zh-Hans");
});

const cameraSpec: MiotDeviceSpec = {
  type: "urn:miot-spec-v2:device:camera:0000A01C:mxiang-mwc11:1",
  services: [
    {
      iid: 2,
      type: "urn:miot-spec-v2:service:camera-control:0000782F:mxiang-mwc11:1",
      properties: [
        {
          iid: 1,
          type: "urn:miot-spec-v2:property:on:00000006:mxiang-mwc11:1",
          format: "bool",
          access: ["read", "write"],
        },
      ],
      actions: [],
    },
  ],
};

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

  it("formats localized fallback lens labels and honors custom lens labels", () => {
    setLanguage("zh-Hans");
    assert.equal(cameraLensLabel({ role: "main", channel: 0 }), "广角");
    assert.equal(cameraLensLabel({ role: "secondary", channel: 1 }), "长焦");
    assert.equal(cameraLensLabel({ role: "secondary", channel: 1, label: "3x 特写" }), "3x 特写");

    setLanguage("en");
    assert.equal(cameraLensLabel({ role: "main", channel: 0 }), "Wide");
    assert.equal(cameraLensLabel({ role: "secondary", channel: 1 }), "Telephoto");
  });
});

describe("CameraHubCatalog and gateway synthesis", () => {
  it("maps battery cameras to their indoor hub model prefix", () => {
    assert.equal(CameraHubCatalog.hubModel("mxiang.camera.mwc11"), "mxiang.camera.mwc10");
    assert.equal(CameraHubCatalog.hubModel("mxiang.camera.mwc11.v2"), "mxiang.camera.mwc10");
    assert.equal(CameraHubCatalog.hubModel("chuangmi.camera.81ac1"), null);
    assert.equal(CameraHubCatalog.isHub("mxiang.camera.mwc10"), true);
    assert.equal(CameraHubCatalog.isHub("mxiang.camera.mwc11"), false);
  });

  it("populates subdid and gatewayLocalIp when a single online hub matches in the same home", () => {
    const home = MiotSynthesizer.synthesize(
      [
        {
          did: "cam-mwc11",
          name: "门外电池机",
          model: "mxiang.camera.mwc11",
          isOnline: true,
          specType: cameraSpec.type,
        },
        Object.assign(
          {
            did: "hub-mwc10",
            name: "室内网关",
            model: "mxiang.camera.mwc10",
            isOnline: true,
            specType: null,
          },
          { localIp: "192.168.1.88" },
        ),
      ],
      [{ id: "10", name: "玄关", dids: ["cam-mwc11", "hub-mwc10"], homeId: "home-1" }],
      { "mxiang.camera.mwc11": cameraSpec },
      new Map([["cam-mwc11.2.1", true]]),
    );

    const cam = home.devices.find((d) => d.id === "cam-mwc11");
    assert.ok(cam && cam.kind.kind === "camera");
    assert.equal(cam.kind.subdid, "cam-mwc11");
    assert.equal(cam.kind.gatewayLocalIp, "192.168.1.88");
  });

  it("keeps standalone cameras free of hub fields and isolates multi-home / ambiguous hubs", () => {
    const standalone = MiotSynthesizer.synthesize(
      [
        {
          did: "cam-standalone",
          name: "客厅摄像机",
          model: "chuangmi.camera.81ac1",
          isOnline: true,
          specType: cameraSpec.type,
        },
      ],
      [{ id: "1", name: "客厅", dids: ["cam-standalone"] }],
      { "chuangmi.camera.81ac1": cameraSpec },
      new Map([["cam-standalone.2.1", true]]),
    );
    const cam = standalone.devices[0]!;
    assert.equal(cam.kind.kind, "camera");
    assert.equal("subdid" in cam.kind, false);
    assert.equal("gatewayLocalIp" in cam.kind, false);

    // Ambiguous when two online hubs exist in different rooms without parentDid
    const ambiguous = resolveCameraHub(
      { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true },
      [
        { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true },
        { did: "hub-a", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.1.20" },
        { did: "hub-b", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.1.21" },
      ],
      [
        { id: "r1", name: "客厅", dids: ["cam-1"], homeId: "h1" },
        { id: "r2", name: "书房", dids: ["hub-a", "hub-b"], homeId: "h1" },
      ],
    );
    assert.equal(ambiguous.hub, null);
    assert.equal(ambiguous.reason, "ambiguous_hub");

    // Explicit parentDid resolves unambiguously even with two online hubs
    const byParent = resolveCameraHub(
      { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true, parentDid: "hub-b" },
      [
        { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true, parentDid: "hub-b" },
        { did: "hub-a", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.1.20" },
        { did: "hub-b", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.1.21" },
      ],
    );
    assert.equal(byParent.hub?.did, "hub-b");

    // Cross-home hub must not match
    const otherHome = resolveCameraHub(
      { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true },
      [
        { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true },
        { did: "hub-other", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.2.20" },
      ],
      [
        { id: "r1", name: "玄关", dids: ["cam-1"], homeId: "home-a" },
        { id: "r2", name: "玄关", dids: ["hub-other"], homeId: "home-b" },
      ],
    );
    assert.equal(otherHome.hub, null);
    assert.equal(otherHome.reason, "missing_hub");
  });
});

describe("parsePrivateLanIpv4", () => {
  it("accepts RFC 1918 private IPv4 ranges and rejects public, test-net, or malformed strings", () => {
    const classAPrivate = [2 * 5, 12, 34, 56].join(".");
    assert.equal(parsePrivateLanIpv4(" 192.168.1.50 "), "192.168.1.50");
    assert.equal(parsePrivateLanIpv4("172.16.0.1"), "172.16.0.1");
    assert.equal(parsePrivateLanIpv4("172.31.255.254"), "172.31.255.254");
    assert.equal(parsePrivateLanIpv4(classAPrivate), classAPrivate);

    assert.equal(parsePrivateLanIpv4("192.0.2.10"), null);
    assert.equal(parsePrivateLanIpv4("198.51.100.10"), null);
    assert.equal(parsePrivateLanIpv4("172.15.0.1"), null);
    assert.equal(parsePrivateLanIpv4("172.32.0.1"), null);
    assert.equal(parsePrivateLanIpv4("192.168.01.5"), null);
    assert.equal(parsePrivateLanIpv4("192.168.1.999"), null);
    assert.equal(parsePrivateLanIpv4("not-an-ip"), null);
  });
});
