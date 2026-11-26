import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import type { Window } from "happy-dom";

import { HomeAssistantSynthesizer, haServiceCall } from "../src/core/homeAssistant.js";
import { setLanguage } from "../src/core/i18n.js";
import {
  extrapolatedPosition,
  MediaSeekGuard,
  playbackFromHomeAssistant,
  progressStyle,
} from "../src/core/mediaPlayback.js";
import { MiotCommandMapper } from "../src/core/miCloud/command.js";
import type { MiotDeviceSpec } from "../src/core/miCloud/spec.js";
import { MiotSynthesizer } from "../src/core/miCloud/synthesis.js";
import { hasDetailDrawer, type MediaPlaybackState, type SmartDevice, type TvSpec } from "../src/core/models.js";
import type { MenuMijiaWindowsApp } from "../src/ui/app.js";
import {
  bindTvMediaEvents,
  disposeTvMediaEvents,
  renderTvMediaSection,
  tvDrawerHasMedia,
  tvProgressTickerActive,
} from "../src/ui/tvMediaDrawer.js";
import { closeTestWindow, mountTestWindow } from "./uiHarness.js";

let activeDom: Window | null = null;

afterEach(async () => {
  if (activeDom) {
    await closeTestWindow(activeDom);
    activeDom = null;
  }
});

const ANCHOR = Date.UTC(2027, 0, 15, 8, 0, 0);

function playback(overrides: Partial<MediaPlaybackState>): MediaPlaybackState {
  return {
    state: "playing", title: null, subtitle: null, appName: null, artworkURL: null,
    durationSec: null, positionSec: null, positionUpdatedAt: null, playbackRate: 1,
    canPlayPause: false, canSeek: false, canSkipTrack: false, ...overrides,
  };
}

const escapeHtml = (value: string): string =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

describe("TV Now Playing and remote pad (macOS TVMediaPlaybackTests parity)", () => {
  it("parses HA media_player attributes and supported_features bits", () => {
    const p = playbackFromHomeAssistant("playing", {
      media_title: "沙丘 2",
      media_series_title: "Dune",
      app_name: "Netflix",
      entity_picture: "/api/media_player_proxy/media_player.tv?token=abc&cache=1",
      media_duration: 9960,
      media_position: 120.5,
      media_position_updated_at: "2027-01-15T08:00:00.000000+00:00",
      supported_features: 1 | 2 | 16 | 32 | 16384,
    });
    assert.ok(p);
    assert.equal(p.title, "沙丘 2");
    assert.equal(p.subtitle, "Dune");
    assert.equal(p.appName, "Netflix");
    assert.equal(p.durationSec, 9960);
    assert.equal(p.positionSec, 120.5);
    assert.equal(p.positionUpdatedAt, ANCHOR);
    assert.equal(p.playbackRate, 1);
    assert.ok(p.canPlayPause && p.canSeek && p.canSkipTrack);
    assert.equal(progressStyle(p), "seekable");

    const readOnly = playbackFromHomeAssistant("paused", {
      media_title: "Song", media_artist: "Artist", media_duration: 200, media_position: 10, supported_features: 16384,
    });
    assert.ok(readOnly);
    assert.equal(readOnly.playbackRate, 0);
    assert.ok(readOnly.canPlayPause && !readOnly.canSeek && !readOnly.canSkipTrack);
    assert.equal(progressStyle(readOnly), "readOnly");

    const appOnly = playbackFromHomeAssistant("idle", { app_name: "YouTube" });
    assert.ok(appOnly);
    assert.equal(progressStyle(appOnly), "hidden");

    assert.equal(playbackFromHomeAssistant("on", { supported_features: 0 }), null);
    assert.equal(playbackFromHomeAssistant("off", { media_title: "Stale" }), null);
  });

  it("extrapolates only while playing and clamps to the duration", () => {
    const playing = playback({ durationSec: 100, positionSec: 40, positionUpdatedAt: ANCHOR });
    assert.equal(extrapolatedPosition(playing, ANCHOR + 5000), 45);
    assert.equal(extrapolatedPosition(playing, ANCHOR + 500_000), 100);
    assert.equal(extrapolatedPosition(playing, ANCHOR - 5000), 40);
    const paused = playback({ state: "paused", playbackRate: 0, durationSec: 100, positionSec: 40, positionUpdatedAt: ANCHOR });
    assert.equal(extrapolatedPosition(paused, ANCHOR + 30_000), 40);
    assert.equal(extrapolatedPosition(playback({}), ANCHOR), null);
  });

  it("drag previews locally, releases one seek, and holds 2 s against snap-back", () => {
    const guard = new MediaSeekGuard();
    assert.equal(guard.displayedPosition(10, ANCHOR), 10);
    assert.equal(guard.endDrag(ANCHOR), null);
    guard.beginDrag(30);
    guard.updateDrag(55);
    assert.equal(guard.displayedPosition(12, ANCHOR), 55);
    assert.equal(guard.endDrag(ANCHOR), 55);
    assert.equal(guard.endDrag(ANCHOR), null);
    assert.equal(guard.displayedPosition(12, ANCHOR + 1900), 55);
    assert.equal(guard.displayedPosition(56, ANCHOR + 2000), 56);
  });

  it("HA TV claims its remote.* entity; an idle TV keeps the plain drawer", () => {
    setLanguage("zh-Hans");
    const home = HomeAssistantSynthesizer.synthesize({
      areas: [{ area_id: "living", name: "客厅" }],
      devices: [
        { id: "tv", name: "客厅电视", area_id: "living" },
        { id: "tv-plain", name: "卧室电视", area_id: "living" },
      ],
      entities: [
        { entity_id: "media_player.living_tv", device_id: "tv" },
        { entity_id: "remote.living_tv", device_id: "tv" },
        { entity_id: "media_player.bed_tv", device_id: "tv-plain" },
      ],
      states: [
        { entity_id: "media_player.living_tv", state: "playing", attributes: { device_class: "tv", media_title: "News", supported_features: 1 } },
        { entity_id: "remote.living_tv", state: "on", attributes: {} },
        { entity_id: "media_player.bed_tv", state: "on", attributes: { device_class: "tv", supported_features: 0 } },
      ],
    });
    const tv = home.devices.find((d) => d.id === "tv");
    const plain = home.devices.find((d) => d.id === "tv-plain");
    assert.ok(tv && tv.kind.kind === "tv" && plain && plain.kind.kind === "tv");
    assert.equal(tv.kind.remoteEntityId, "remote.living_tv");
    assert.equal(tv.kind.supportsRemotePad, true);
    assert.equal(tv.kind.playback?.title, "News");
    assert.ok(!home.devices.some((d) => d.id !== "tv" && JSON.stringify(d.kind).includes("remote.living_tv")));
    assert.equal(plain.kind.playback, undefined);
    assert.equal(plain.kind.remoteEntityId, undefined);
    assert.equal(tvDrawerHasMedia(plain.kind), false);
    assert.equal(renderTvMediaSection(plain, plain.kind, escapeHtml), "");
  });

  it("maps transport, seek and remote keys to HA services", () => {
    assert.deepEqual(haServiceCall({ kind: "mediaSeek", entityId: "media_player.tv", positionSec: 61.5 }), {
      domain: "media_player", service: "media_seek", entity_id: "media_player.tv", data: { seek_position: 61.5 },
    });
    assert.equal(haServiceCall({ kind: "mediaPlayPause", entityId: "media_player.tv" }).service, "media_play_pause");
    assert.equal(haServiceCall({ kind: "mediaNextTrack", entityId: "media_player.tv" }).service, "media_next_track");
    assert.equal(haServiceCall({ kind: "mediaPreviousTrack", entityId: "media_player.tv" }).service, "media_previous_track");
    assert.deepEqual(haServiceCall({ kind: "remoteSendKey", entityId: "remote.tv", key: "select" }), {
      domain: "remote", service: "send_command", entity_id: "remote.tv", data: { command: "ENTER" },
    });
    assert.throws(() => haServiceCall({ kind: "remoteSendKey", entityId: "media_player.tv", key: "up" }));
  });

  it("Xiaomi TV remote-control actions become the pad and map only to matching keys", () => {
    const action = (iid: number, name: string, inputs: number[] = []) => ({
      iid, type: `urn:miot-spec-v2:action:${name}:00002800:xiaomi-tv:1`, description: name, in: inputs, out: [],
    });
    const spec = {
      type: "urn:miot-spec-v2:device:television:0000A010:xiaomi-tv:1",
      description: "Television",
      services: [
        {
          iid: 2, type: "urn:miot-spec-v2:service:television:00007817:xiaomi-tv:1", description: "TV",
          properties: [{ iid: 1, type: "urn:miot-spec-v2:property:on:00000006:xiaomi-tv:1", description: "On", format: "bool", access: ["read", "write"] }],
          actions: [],
        },
        {
          iid: 5, type: "urn:miot-spec-v2:service:remote-control:00007880:xiaomi-tv:1", description: "Remote",
          properties: [],
          actions: [action(1, "up"), action(2, "down"), action(3, "ok"), action(4, "back"), action(5, "home"), action(6, "left", [9])],
        },
      ],
    } as unknown as MiotDeviceSpec;
    const home = MiotSynthesizer.synthesize(
      [{ did: "tv9", name: "小米电视", model: "xiaomi.tv.v1", isOnline: true, specType: spec.type }],
      [{ id: "r1", name: "客厅", dids: ["tv9"] }],
      { "xiaomi.tv.v1": spec },
      new Map(),
    );
    const tv = home.devices.find((d) => d.id === "tv9");
    assert.ok(tv && tv.kind.kind === "tv");
    assert.equal(tv.kind.supportsRemotePad, true);
    assert.equal(tv.kind.miotRemoteActions?.up, "miot-action:tv9:5:1");
    assert.equal(tv.kind.miotRemoteActions?.select, "miot-action:tv9:5:3");
    assert.equal(tv.kind.miotRemoteActions?.left, undefined);
    const select = tv.kind.miotRemoteActions?.select ?? "";
    assert.deepEqual(MiotCommandMapper.map({ kind: "remoteSendKey", entityId: select, key: "select" }, spec), {
      kind: "action", call: { did: "tv9", siid: 5, aiid: 3, inputs: [] },
    });
    assert.throws(() => MiotCommandMapper.map({ kind: "remoteSendKey", entityId: select, key: "home" }, spec));
    const mediaEntityId = tv.kind.mediaEntityId;
    assert.throws(() => MiotCommandMapper.map({ kind: "mediaSeek", entityId: mediaEntityId, positionSec: 5 }, spec));
  });

  it("renders Now Playing with an honest progress bar and the pad only when present", () => {
    setLanguage("zh-Hans");
    const kind: TvSpec = {
      kind: "tv", mediaEntityId: "media_player.tv", state: "playing", volumePercent: 20,
      currentSource: null, availableSources: [], volumeWritable: false,
      playback: playback({ title: "News", appName: "YouTube", durationSec: 600, positionSec: 30, canPlayPause: true, canSeek: true }),
      remoteEntityId: "remote.tv", supportsRemotePad: true,
    };
    const dev: SmartDevice = { id: "tv", name: "客厅电视", roomId: "r", roomName: "客厅", model: "tv", isOnline: true, kind } as SmartDevice;
    assert.ok(hasDetailDrawer(dev));
    const html = renderTvMediaSection(dev, kind, escapeHtml);
    assert.match(html, /data-tvseek="tv"/);
    assert.match(html, /data-tvmedia="tv\|playPause"/);
    assert.doesNotMatch(html, /data-tvmedia="tv\|next"/);
    assert.match(html, /data-tvremote-toggle="tv"/);

    const noDuration = renderTvMediaSection(dev, { ...kind, playback: playback({ appName: "YouTube" }), supportsRemotePad: false }, escapeHtml);
    assert.doesNotMatch(noDuration, /cc-tv-progress/);
    const readOnly = renderTvMediaSection(dev, { ...kind, playback: playback({ title: "x", durationSec: 60, positionSec: 1 }) }, escapeHtml);
    assert.match(readOnly, /role="progressbar"/);
    assert.doesNotMatch(readOnly, /data-tvseek/);
  });

  it("progress ticker stops when hidden, restarts on visible, and is cleared by dispose", () => {
    setLanguage("zh-Hans");
    const dom = mountTestWindow({ stubInterval: false });
    activeDom = dom;
    const intervals = new Map<number, () => void>();
    let nextId = 1;
    Object.defineProperty(dom, "setInterval", {
      configurable: true,
      value: (fn: () => void) => { const id = nextId++; intervals.set(id, fn); return id; },
    });
    Object.defineProperty(dom, "clearInterval", { configurable: true, value: (id: number) => intervals.delete(id) });
    let visibility: "visible" | "hidden" = "visible";
    Object.defineProperty(dom.document, "visibilityState", { configurable: true, get: () => visibility });

    const kind: TvSpec = {
      kind: "tv", mediaEntityId: "media_player.tv", state: "playing", volumePercent: 20,
      currentSource: null, availableSources: [], volumeWritable: false,
      playback: playback({ title: "News", durationSec: 600, positionSec: 30, positionUpdatedAt: Date.now(), canSeek: true }),
    };
    const dev = { id: "tv", name: "客厅电视", roomId: "r", roomName: "客厅", model: "tv", isOnline: true, kind } as SmartDevice;
    const root = document.getElementById("app") as HTMLElement;
    root.innerHTML = renderTvMediaSection(dev, kind, escapeHtml);
    const host = { root, devices: [dev], executeSingleCommand: async () => {}, render: () => {} } as unknown as MenuMijiaWindowsApp;

    bindTvMediaEvents(host);
    assert.equal(tvProgressTickerActive(host), true);
    assert.equal(intervals.size, 1);

    visibility = "hidden";
    for (const fn of [...intervals.values()]) fn();
    assert.equal(tvProgressTickerActive(host), false, "a hidden window stops the clock");
    assert.equal(intervals.size, 0);

    visibility = "visible";
    dom.document.dispatchEvent(new dom.Event("visibilitychange"));
    assert.equal(tvProgressTickerActive(host), true, "a playing bar resumes when visible again");
    assert.equal(intervals.size, 1);

    disposeTvMediaEvents(host);
    assert.equal(tvProgressTickerActive(host), false);
    assert.equal(intervals.size, 0);
    dom.document.dispatchEvent(new dom.Event("visibilitychange"));
    assert.equal(intervals.size, 0, "dispose removes the visibility listener");
  });
});
