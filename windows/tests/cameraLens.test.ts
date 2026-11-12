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
    assert.equal(cam.kind.gatewayDid, "hub-mwc10");
    assert.equal(cam.kind.gatewayModel, "mxiang.camera.mwc10");
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
    assert.equal("gatewayDid" in cam.kind, false);
    assert.equal("gatewayModel" in cam.kind, false);
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

    // Cross-home parentDid must be rejected
    const crossHomeParent = resolveCameraHub(
      { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true, parentDid: "hub-other" },
      [
        { did: "cam-1", model: "mxiang.camera.mwc11", isOnline: true, parentDid: "hub-other" },
        { did: "hub-other", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.2.20" },
      ],
      [
        { id: "r1", name: "玄关", dids: ["cam-1"], homeId: "home-a" },
        { id: "r2", name: "玄关", dids: ["hub-other"], homeId: "home-b" },
      ],
    );
    assert.equal(crossHomeParent.hub, null);
    assert.equal(crossHomeParent.reason, "missing_hub");

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

  it("matches macOS hubRecord parity on offline own hub, earlier hubless room, and unlisted cross-home hubs", () => {
    // 1. Offline own hub in camera's room must NOT hijack another room's online hub
    const offlineOwn = resolveCameraHub(
      { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
      [
        { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
        { did: "hub-own", model: "mxiang.camera.mwc10", isOnline: false, localIp: "192.168.1.30" },
        { did: "hub-other", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.1.31" },
      ],
      [
        { id: "yard", name: "院子", dids: ["cam-a", "hub-own"], homeId: "home-a" },
        { id: "hall", name: "客厅", dids: ["hub-other"], homeId: "home-a" },
      ],
    );
    assert.equal(offlineOwn.hub, null);
    assert.equal(offlineOwn.reason, "offline_hub");

    // Two hubs in home outside camera's room where one is offline and one is online -> still ambiguous across rooms
    const mixedOtherRooms = resolveCameraHub(
      { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
      [
        { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
        { did: "hub-1", model: "mxiang.camera.mwc10", isOnline: false },
        { did: "hub-2", model: "mxiang.camera.mwc10", isOnline: true },
      ],
      [
        { id: "yard", name: "院子", dids: ["cam-a"], homeId: "home-a" },
        { id: "hall", name: "客厅", dids: ["hub-1", "hub-2"], homeId: "home-a" },
      ],
    );
    assert.equal(mixedOtherRooms.hub, null);
    assert.equal(mixedOtherRooms.reason, "ambiguous_hub");

    // Two online hubs in the same room -> ambiguous_hub
    const twoInSameRoom = resolveCameraHub(
      { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
      [
        { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
        { did: "hub-a", model: "mxiang.camera.mwc10", isOnline: true },
        { did: "hub-b", model: "mxiang.camera.mwc10", isOnline: true },
      ],
      [{ id: "kids", name: "儿童房", dids: ["cam-a", "hub-a", "hub-b"], homeId: "home-a" }],
    );
    assert.equal(twoInSameRoom.hub, null);
    assert.equal(twoInSameRoom.reason, "ambiguous_hub");

    // 2. Earlier room without hub must not hide later room containing camera + hub (both resolveCameraHub and MiotSynthesizer)
    const laterRoom = MiotSynthesizer.synthesize(
      [
        { did: "hub-living", name: "客厅室内机", model: "mxiang.camera.mwc10", isOnline: true, specType: null },
        Object.assign(
          { did: "hub-kids", name: "儿童房室内机", model: "mxiang.camera.mwc10", isOnline: true, specType: null },
          { localIp: "192.168.1.42" },
        ),
        { did: "cam", name: "儿童房摄像机", model: "mxiang.camera.mwc11", isOnline: true, specType: cameraSpec.type },
      ],
      [
        { id: "living", name: "客厅", dids: ["cam"], homeId: "home" },
        { id: "kids", name: "儿童房", dids: ["cam", "hub-kids"], homeId: "home" },
        { id: "hall", name: "大厅", dids: ["hub-living"], homeId: "home" },
      ],
      { "mxiang.camera.mwc11": cameraSpec },
      new Map([["cam.2.1", true]]),
    );
    const synthesizedCam = laterRoom.devices.find((d) => d.id === "cam");
    assert.ok(synthesizedCam && synthesizedCam.kind.kind === "camera");
    assert.equal(synthesizedCam.kind.gatewayDid, "hub-kids");
    assert.equal(synthesizedCam.kind.gatewayLocalIp, "192.168.1.42");

    // 3. Unlisted hub from another home (absent from home-a's rooms when distinctHomeIds.size === 1) must NOT leak in
    const unlistedOtherHome = resolveCameraHub(
      { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
      [
        { did: "cam-a", model: "mxiang.camera.mwc11", isOnline: true },
        { did: "hub-unlisted", model: "mxiang.camera.mwc10", isOnline: true, localIp: "192.168.9.10" },
      ],
      [{ id: "yard", name: "院子", dids: ["cam-a"], homeId: "home-a" }],
    );
    assert.equal(unlistedOtherHome.hub, null);
    assert.equal(unlistedOtherHome.reason, "missing_hub");
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
