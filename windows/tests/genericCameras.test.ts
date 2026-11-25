import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildGenericCameraSourceUrl,
  encodeCameraCredentialComponent,
  genericCameraToSmartDevice,
  isPrivateOrLocalCameraHost,
  redactGenericCameraUrl,
  sanitizeGenericCameraConfig,
  type GenericCameraConfig,
} from "../src/core/genericCameras.js";
import { selectStillWallCameras } from "../src/core/cameraEventStore.js";
import {
  genericCameraCredentialName,
  parseGenericCameraCredential,
  sanitizeSettingsForStorage,
  serializeGenericCameraCredential,
} from "../src/core/secureStore.js";
import { renderGenericCamerasSettingsBlock } from "../src/ui/genericCameraSettingsView.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../..");

interface GoldenCase {
  readonly input: GenericCameraConfig;
  readonly main: string;
  readonly sub: string;
}

test("Shared/genericCameraSources.schema.json defines a credential-free source", () => {
  const schemaPath = path.join(repoRoot, "Shared", "genericCameraSources.schema.json");
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8")) as {
    type: string;
    additionalProperties: boolean;
    required: string[];
    properties: Record<string, unknown>;
  };
  assert.equal(schema.type, "object");
  assert.equal(schema.additionalProperties, false);
  assert.deepEqual(schema.required, ["id", "name", "kind", "host"]);
  assert.equal("username" in schema.properties, false);
  assert.equal("password" in schema.properties, false);
});

test("buildGenericCameraSourceUrl matches Tests/Fixtures/generic_camera_sources_golden.json", () => {
  const fixturePath = path.join(repoRoot, "Tests", "Fixtures", "generic_camera_sources_golden.json");
  const { cases } = JSON.parse(fs.readFileSync(fixturePath, "utf8")) as { cases: readonly GoldenCase[] };
  assert.ok(cases.length > 0);
  for (const { input, main, sub } of cases) {
    assert.equal(buildGenericCameraSourceUrl(input, "main"), main, `${input.name} main`);
    assert.equal(buildGenericCameraSourceUrl(input, "sub"), sub, `${input.name} sub`);
  }
});

test("encodeCameraCredentialComponent encodes RFC 3986 special chars and redactGenericCameraUrl masks secrets", () => {
  assert.equal(encodeCameraCredentialComponent("p@ss:w/ord#1?% &+!'()*"), "p%40ss%3Aw%2Ford%231%3F%25%20%26%2B%21%27%28%29%2A");
  assert.equal(
    redactGenericCameraUrl("rtsp://admin:s3cr3t%401@192.168.1.50:554/stream1#backchannel=0"),
    "rtsp://***@192.168.1.50:554/stream1#backchannel=0",
  );
  assert.equal(
    redactGenericCameraUrl("tapo://my%23pass@192.168.1.90?subtype=1"),
    "tapo://***@192.168.1.90?subtype=1",
  );
});

test("generic camera credentials are never serialized into settings or localStorage", () => {
  const dirtyCamera = {
    id: "11111111-1111-4111-8111-111111111111",
    name: "Front Door",
    kind: "rtsp",
    host: "192.168.1.50",
    port: 554,
    path: "/stream1",
    username: "admin",
    password: "super-secret-password",
    credentials: { username: "admin", password: "super-secret-password" },
  };
  const clean = sanitizeGenericCameraConfig(dirtyCamera);
  assert.ok(clean);
  const cleanRec = clean as unknown as Record<string, unknown>;
  assert.equal("username" in cleanRec, false);
  assert.equal("password" in cleanRec, false);
  assert.equal("credentials" in cleanRec, false);

  const sanitizedSettings = sanitizeSettingsForStorage({
    connectionMode: "xiaomiCloud",
    genericCameras: [dirtyCamera],
  });
  const json = JSON.stringify(sanitizedSettings);
  assert.equal(json.includes("super-secret-password"), false);
  assert.equal(json.includes("username"), false);
  assert.equal(json.includes("password"), false);

  assert.equal(
    genericCameraCredentialName("11111111-1111-4111-8111-111111111111"),
    "generic-camera:11111111-1111-4111-8111-111111111111",
  );
  assert.throws(() => genericCameraCredentialName("../bad"));
  const encoded = serializeGenericCameraCredential({ username: "admin", password: "p@ss#1" });
  assert.deepEqual(parseGenericCameraCredential(encoded), { username: "admin", password: "p@ss#1" });
});

test("host policy allows private LAN and .local hosts and rejects public hosts by default", () => {
  assert.equal(isPrivateOrLocalCameraHost("192.168.1.50"), true);
  assert.equal(isPrivateOrLocalCameraHost([5 * 2, 0, 0, 8].join(".")), true);
  assert.equal(isPrivateOrLocalCameraHost("172.16.4.9"), true);
  assert.equal(isPrivateOrLocalCameraHost("cam-front.local"), true);
  assert.equal(isPrivateOrLocalCameraHost("8.8.8.8"), false);
  assert.equal(isPrivateOrLocalCameraHost("cam.example.com"), false);
  assert.equal(isPrivateOrLocalCameraHost("192.168.1.50/bad"), false);
});

test("genericCameraToSmartDevice creates a strictly read-only camera card included in the still wall", () => {
  const cam = genericCameraToSmartDevice({
    id: "11111111-1111-4111-8111-111111111111",
    name: "Garage RTSP",
    kind: "rtsp",
    host: "192.168.1.50",
  });
  assert.equal(cam.id, "generic-camera:11111111-1111-4111-8111-111111111111");
  assert.equal(cam.kind.kind, "camera");
  if (cam.kind.kind === "camera") {
    assert.equal(cam.kind.powerWritable, false);
    assert.deepEqual(cam.kind.availableNightShots, []);
    assert.equal(cam.kind.motionDetectionEntityId, null);
  }
  const wall = selectStillWallCameras([cam], () => false, 4);
  assert.equal(wall.length, 1);
  assert.equal(wall[0]?.id, cam.id);
});

test("generic cameras live in Advanced Connection settings and never in onboarding", () => {
  const onboardingSource = fs.readFileSync(path.join(repoRoot, "windows", "src", "ui", "onboardingGuide.ts"), "utf8");
  assert.equal(onboardingSource.includes("genericCameras"), false);
  assert.equal(onboardingSource.includes("renderGenericCamerasSettingsBlock"), false);

  const html = renderGenericCamerasSettingsBlock(
    {
      interfaceLanguage: "zh-Hans",
      genericCameras: [
        {
          id: "11111111-1111-4111-8111-111111111111",
          name: "玄关 RTSP",
          kind: "rtsp",
          host: "192.168.1.50",
          port: 554,
        },
      ],
    } as never,
    null,
  );
  assert.ok(html.includes("conn-diag-generic-cameras-section"));
  assert.ok(html.includes("玄关 RTSP"));
  assert.ok(html.includes("192.168.1.50:554"));
});
