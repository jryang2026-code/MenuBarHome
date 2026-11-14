import { t } from "../core/i18n.js";
import type { FacetControl, HomeScene, SmartDevice } from "../core/models.js";
import {
  extractSensorLiveMetrics,
  sharedSensorHistoryStore,
  startOfLocalDayMs,
  startOfLocalHourMs,
  type SensorHistorySample,
  type SensorHistoryStore,
  type SensorHistoryWindow,
} from "../core/sensorHistory.js";
import { SF_ICONS } from "./appConstants.js";

function demoPhaseSeed(deviceId: string): number {
  let acc = 0;
  for (let i = 0; i < deviceId.length; i += 1) {
    acc = (acc * 31 + deviceId.charCodeAt(i)) % 997;
  }
  return Math.abs(acc % 7);
}

function clampDemo(value: number, lo: number, hi: number): number {
  return Math.round(Math.min(hi, Math.max(lo, value)) * 10) / 10;
}

export function demoSensorHistorySamples(
  deviceId: string,
  base: {
    readonly temperature?: number | null;
    readonly humidity?: number | null;
    readonly pm25?: number | null;
    readonly illuminance?: number | null;
  },
  window: SensorHistoryWindow,
  now: number | Date = Date.now(),
): SensorHistorySample[] {
  const nowMs = now instanceof Date ? now.getTime() : now;
  const phase = demoPhaseSeed(deviceId);
  const baseTemp = typeof base.temperature === "number" && Number.isFinite(base.temperature) ? base.temperature : null;
  const baseHum = typeof base.humidity === "number" && Number.isFinite(base.humidity) ? base.humidity : null;
  const basePm25 = typeof base.pm25 === "number" && Number.isFinite(base.pm25) ? base.pm25 : null;
  const baseLux = typeof base.illuminance === "number" && Number.isFinite(base.illuminance) ? base.illuminance : null;

  if (baseTemp === null && baseHum === null && basePm25 === null && baseLux === null) {
    return [];
  }

  if (window === "24h") {
    const anchorHourMs = startOfLocalHourMs(nowMs);
    const anchorDate = new Date(anchorHourMs);
    const nowHour = anchorDate.getHours();
    const baseDiurnal = Math.sin(((nowHour - 6) / 24) * Math.PI * 2 + phase * 0.35);
    const samples: SensorHistorySample[] = [];

    for (let index = 0; index < 24; index += 1) {
      const hoursBack = 23 - index;
      const slotDate = new Date(
        anchorDate.getFullYear(),
        anchorDate.getMonth(),
        anchorDate.getDate(),
        anchorDate.getHours() - hoursBack,
        0,
        0,
        0,
      );
      const hour = slotDate.getHours();
      const diurnal =
        hoursBack === 0
          ? 0
          : (Math.sin(((hour - 6) / 24) * Math.PI * 2 + phase * 0.35) - baseDiurnal) * 1.85 +
            Math.sin(hoursBack * 0.65 + phase) * 0.25;

      const temp = baseTemp !== null ? clampDemo(baseTemp + diurnal, -40, 80) : null;
      const tempSpread = temp !== null ? (hoursBack === 0 ? 0.2 : 0.3 + ((index + phase) % 3) * 0.1) : 0;
      const hum =
        baseHum !== null
          ? clampDemo(
              baseHum - diurnal * 3.1 + (hoursBack === 0 ? 0 : Math.cos(hoursBack * 0.5 + phase) * 1.2),
              10,
              95,
            )
          : null;
      const humSpread = hum !== null ? (hoursBack === 0 ? 1 : 1.5 + ((index + phase) % 3) * 0.5) : 0;
      const pm25 =
        basePm25 !== null
          ? Math.round(
              clampDemo(
                basePm25 + (hoursBack === 0 ? 0 : Math.sin(((hour - 8) / 24) * Math.PI * 2 + phase) * 9 + ((index + phase) % 4) - 1.5),
                1,
                500,
              ),
            )
          : null;
      const daylightFactor = Math.max(0, Math.sin(((hour - 6) / 12) * Math.PI));
      const nowDaylight = Math.max(0.15, Math.sin(((nowHour - 6) / 12) * Math.PI));
      const lux =
        baseLux !== null
          ? Math.round(
              clampDemo(
                hoursBack === 0 ? baseLux : Math.max(8, (baseLux / nowDaylight) * daylightFactor + ((index * 17 + phase * 11) % 25)),
                0,
                100_000,
              ),
            )
          : null;

      samples.push({
        timestamp: slotDate.getTime(),
        ...(temp !== null
          ? {
              temperature: temp,
              minTemperature: clampDemo(temp - tempSpread, -40, 80),
              maxTemperature: clampDemo(temp + tempSpread, -40, 80),
            }
          : {}),
        ...(hum !== null
          ? {
              humidity: Math.round(hum),
              minHumidity: Math.round(clampDemo(hum - humSpread, 0, 100)),
              maxHumidity: Math.round(clampDemo(hum + humSpread, 0, 100)),
            }
          : {}),
        ...(pm25 !== null
          ? {
              pm25,
              minPm25: Math.max(1, pm25 - 3),
              maxPm25: pm25 + 4,
            }
          : {}),
        ...(lux !== null
          ? {
              illuminance: lux,
              minIlluminance: Math.max(0, Math.round(lux * 0.88)),
              maxIlluminance: Math.round(lux * 1.12),
            }
          : {}),
      });
    }
    return samples;
  }

  const anchorDayMs = startOfLocalDayMs(nowMs);
  const anchorDay = new Date(anchorDayMs);
  const samples: SensorHistorySample[] = [];

  for (let index = 0; index < 7; index += 1) {
    const daysBack = 6 - index;
    const slotDay = new Date(
      anchorDay.getFullYear(),
      anchorDay.getMonth(),
      anchorDay.getDate() - daysBack,
      0,
      0,
      0,
      0,
    );
    const frontWave =
      daysBack === 0
        ? 0
        : Math.sin(((index + phase) / 7) * Math.PI * 2) * 1.55 + Math.cos(daysBack * 0.9 + phase) * 0.35;
    const dailySwing = 1.6 + ((index + phase) % 3) * 0.45;
    const humSwing = 5 + ((index + phase) % 3) * 1.5;

    const avgTemp = baseTemp !== null ? clampDemo(baseTemp + frontWave, -40, 80) : null;
    const avgHum = baseHum !== null ? Math.round(clampDemo(baseHum - frontWave * 2.9, 12, 92)) : null;
    const avgPm25 =
      basePm25 !== null
        ? Math.round(clampDemo(basePm25 + (daysBack === 0 ? 0 : Math.sin(index * 1.1 + phase) * 11), 2, 500))
        : null;
    const avgLux =
      baseLux !== null
        ? Math.round(clampDemo(baseLux * (daysBack === 0 ? 1 : 0.85 + ((index + phase) % 4) * 0.1), 10, 100_000))
        : null;

    samples.push({
      timestamp: slotDay.getTime(),
      ...(avgTemp !== null
        ? {
             temperature: avgTemp,
             minTemperature: clampDemo(avgTemp - dailySwing, -40, 80),
             maxTemperature: clampDemo(avgTemp + dailySwing, -40, 80),
          }
        : {}),
      ...(avgHum !== null
        ? {
            humidity: avgHum,
            minHumidity: Math.round(clampDemo(avgHum - humSwing, 0, 100)),
            maxHumidity: Math.round(clampDemo(avgHum + humSwing, 0, 100)),
          }
        : {}),
      ...(avgPm25 !== null
        ? {
            pm25: avgPm25,
            minPm25: Math.max(1, avgPm25 - 8),
            maxPm25: avgPm25 + 12,
          }
        : {}),
      ...(avgLux !== null
        ? {
            illuminance: avgLux,
            minIlluminance: Math.max(0, Math.round(avgLux * 0.35)),
            maxIlluminance: Math.round(avgLux * 1.65),
          }
        : {}),
    });
  }
  return samples;
}

export function seedDemoSensorHistory(
  devices: readonly SmartDevice[],
  options?: {
    readonly store?: SensorHistoryStore;
    readonly facetsByDevice?: Readonly<Record<string, readonly FacetControl[]>>;
    readonly now?: number | Date;
    readonly force?: boolean;
  },
): void {
  const store = options?.store ?? sharedSensorHistoryStore();
  const nowMs = options?.now instanceof Date ? options.now.getTime() : (options?.now ?? Date.now());
  const facetsByDevice = options?.facetsByDevice ?? {};
  const previousScope = store.connectionScope;
  store.setConnectionScope("demo");
  try {
    for (const dev of devices) {
      if (dev.kind.kind !== "sensor" || !dev.isOnline) continue;
      const live = extractSensorLiveMetrics(dev, facetsByDevice[dev.id] ?? []);
      if (
        live.temperature === null &&
        live.humidity === null &&
        live.pm25 === null &&
        live.illuminance === null
      ) {
        continue;
      }
      if (!options?.force) {
        const pts24 = store.points(dev.id, "24h", nowMs);
        const pts7d = store.points(dev.id, "7d", nowMs);
        const full24 = pts24.every((pt) => pt.isObserved);
        const full7d = pts7d.every((pt) => pt.isObserved);
        if (full24 && full7d) continue;
      }
      store.mergeCloudSamples(dev.id, "24h", demoSensorHistorySamples(dev.id, live, "24h", nowMs), nowMs);
      store.mergeCloudSamples(dev.id, "7d", demoSensorHistorySamples(dev.id, live, "7d", nowMs), nowMs);
    }
  } finally {
    if (previousScope !== "demo" && previousScope !== "default") {
      store.setConnectionScope(previousScope);
    }
  }
}

export function demoDevices(): SmartDevice[] {
  const devices: SmartDevice[] = [
    {
      id: "light.living_ceiling",
      name: t("客厅吸顶灯"),
      roomId: "room_living",
      roomName: t("客厅"),
      model: "yeelink.light.ceiling22",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: "miot:light.living_ceiling:2",
        isOn: true,
        brightnessPercent: 78,
        colorTempKelvin: 4100,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: "Day",
        availableEffects: ["Day", "Night"],
      },
    },
    {
      id: "climate.living_ac",
      name: t("客厅立式空调"),
      roomId: "room_living",
      roomName: t("客厅"),
      model: "xiaomi.aircondition.mc5",
      isOnline: true,
      kind: {
        kind: "climate",
        entityId: "miot:climate.living_ac:2",
        isOn: true,
        hvacMode: "cool",
        availableModes: ["cool", "heat", "dry", "fan_only", "auto", "off"],
        targetTemperature: 25,
        currentTemperature: 26,
        minTemp: 16,
        maxTemp: 30,
        step: 0.5,
        fanMode: "auto",
        availableFanModes: ["auto", "low", "medium", "high"],
      },
    },
    {
      id: "light.study_desk",
      name: t("书房台灯"),
      roomId: "room_study",
      roomName: t("书房"),
      model: "yeelink.light.lamp15",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: "miot:light.study_desk:2",
        isOn: true,
        brightnessPercent: 64,
        colorTempKelvin: 4600,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: ["Day", "Night"],
      },
    },
    {
      id: "fan.bedroom_standing",
      name: t("主卧直流风扇"),
      roomId: "room_bedroom",
      roomName: t("主卧"),
      model: "zhimi.fan.za5",
      isOnline: true,
      kind: {
        kind: "fan",
        entityId: "miot:fan.bedroom_standing:2",
        isOn: false,
        percentage: 50,
        presetMode: "Level 2",
        availablePresetModes: ["Level 1", "Level 2", "Level 3", "Level 4"],
        isOscillating: false,
      },
    },
    {
      id: "plug.entry_socket",
      name: t("玄关智能插座"),
      roomId: "room_entry",
      roomName: t("玄关"),
      model: "cuco.plug.cp1",
      isOnline: true,
      kind: {
        kind: "plug",
        switchEntityId: "miot:plug.entry_socket:2",
        isOn: true,
        powerWatts: 18.4,
        childLockEntityId: null,
        isChildLocked: false,
      },
    },
    {
      id: "vacuum.roborock",
      name: t("全屋扫拖机器人"),
      roomId: "room_living",
      roomName: t("客厅"),
      model: "roborock.vacuum.a15",
      isOnline: true,
      kind: {
        kind: "vacuum",
        entityId: "miot:vacuum.roborock:2",
        status: "docked",
        battery: 100,
        modeEntityId: null,
        currentMode: null,
        availableModes: [],
      },
    },
    {
      id: "sensor.living_env",
      name: t("客厅温湿度计"),
      roomId: "room_living",
      roomName: t("客厅"),
      model: "miaomiaoce.sensor_ht.t2",
      isOnline: true,
      kind: {
        kind: "sensor",
        temperature: 25.5,
        humidity: 52,
        battery: 94,
      },
    },
    {
      id: "camera.living_cam",
      name: t("客厅摄像机"),
      roomId: "room_living",
      roomName: t("客厅"),
      model: "chuangmi.camera.81ac1",
      isOnline: true,
      kind: {
        kind: "camera",
        entityId: "miot:camera.living_cam:2",
        isOn: true,
        nightShot: "Auto",
        availableNightShots: ["Off", "On", "Auto"],
        motionDetectionEntityId: "miot:camera.living_cam:5",
        isMotionDetectionOn: true,
        streamEntityId: "miot:camera.living_cam:20",
      },
    },
  ];
  seedDemoSensorHistory(devices);
  return devices;
}

export function demoScenes(): HomeScene[] {
  return [
    { id: "scene.home", name: t("回家模式"), entityId: "scene.home" },
    { id: "scene.focus", name: t("专注模式"), entityId: "scene.focus" },
    { id: "scene.sleep", name: t("睡眠模式"), entityId: "scene.sleep" },
    { id: "scene.leave", name: t("离家模式"), entityId: "scene.leave" },
  ];
}

export function quickActions(): ReadonlyArray<{
  readonly id: string;
  readonly title: string;
  readonly icon: string;
  readonly tint: string;
  readonly command: string;
}> {
  return [
    { id: "lights_on", title: t("全开主灯"), icon: SF_ICONS.sunMaxFill, tint: "amber", command: t("打开所有灯") },
    { id: "lights_off", title: t("睡眠关灯"), icon: SF_ICONS.moonStarsFill, tint: "indigo", command: t("关闭所有灯") },
    { id: "cool_25", title: t("25°制冷"), icon: SF_ICONS.snowflake, tint: "cyan", command: t("空调调到25度") },
    { id: "focus", title: t("调亮灯光"), icon: SF_ICONS.lightbulbFill, tint: "amber", command: t("再亮一点") },
  ];
}
