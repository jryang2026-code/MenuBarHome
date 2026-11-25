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
  type GenericCameraCredentials,
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
  readonly name: string;
  readonly config: GenericCameraConfig;
  readonly mode: "placeholder" | "credentials";
  readonly credentials?: GenericCameraCredentials;
  readonly expectedMain: string;
  readonly expectedSub: string;
}

interface GoldenFixture {
  readonly schemaVersion: number;
  readonly cases: readonly GoldenCase[];
}

test("Shared/genericCameraSources.schema.json is valid JSON schema with additionalProperties: false", () => {
  const schemaPath = path.join(repoRoot, "Shared", "genericCameraSources.schema.json");
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8")) as {
    type: string;
    items: { additionalProperties: boolean; required: string[]; properties: Record<string, unknown> };
  };
  assert.equal(schema.type, "array");
  assert.equal(schema.items.additionalProperties, false);
  assert.deepEqual(schema.items.required, ["id", "name", "kind", "host"]);
  assert.equal("username" in schema.items.properties, false);
  assert.equal("password" in schema.items.properties, false);
});

test("buildGenericCameraSourceUrl matches Tests/Fixtures/generic_camera_sources_golden.json", () => {
  const fixturePath = path.join(repoRoot, "Tests", "Fixtures", "generic_camera_sources_golden.json");
  const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8")) as GoldenFixture;
  assert.equal(fixture.schemaVersion, 1);
  assert.ok(fixture.cases.length >= 10);

  for (const c of fixture.cases) {
    const creds = c.mode === "placeholder" ? "placeholder" : (c.credentials ?? {});
    const main = buildGenericCameraSourceUrl(c.config, "main", creds);
    const sub = buildGenericCameraSourceUrl(c.config, "sub", creds);
    assert.equal(main, c.expectedMain, `${c.name} main`);
    assert.equal(sub, c.expectedSub, `${c.name} sub`);
  }
});

test("encodeCameraCredentialComponent encodes RFC 3986 special chars and redactGenericCameraUrl masks secrets", () => {
  assert.equal(encodeCameraCredentialComponent("p@ss:w/ord#1?% &+!'()*"), "p%40ss%3Aw%2Ford%231%3F%25%20%26%2B%21%27%28%29%2A");
  assert.equal(
    redactGenericCameraUrl("rtsp://admin:s3cr3t%401@192.168.1.50:554/stream1#backchannel=0"),
    "rtsp://***@192.168.1.50:554/stream1#backchannel=0",
  );
  assert.equal(
    redactGenericCameraUrl("tapo://my%23pass@192.168.1.90?subtype=sd"),
    "tapo://***@192.168.1.90?subtype=sd",
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
