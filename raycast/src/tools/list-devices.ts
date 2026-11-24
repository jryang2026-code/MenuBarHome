import { loadSnapshot, type RaycastDevice } from "../snapshot";

type Input = {
  /** Only list devices in this room. Accepts the room's display name or id; leave empty for every room. */
  room?: string;
};

interface ToolDevice {
  id: string;
  name: string;
  room: string;
  category: string;
  state: string;
  isOnline: boolean;
  isActiveOn: boolean;
  isFavorite: boolean;
  /** The controls this device accepts, so the answer never promises a control the app would refuse. */
  controls: string[];
}

function controlsOf(device: RaycastDevice): string[] {
  const capabilities = device.capabilities;
  const controls: string[] = [];
  if (device.isPrimaryToggleable) {
    controls.push("power");
  }
  if (capabilities.brightnessWritable) {
    controls.push("brightness");
  }
  if (capabilities.colorWritable) {
    controls.push("colorTemperature");
  }
  if (capabilities.temperatureWritable) {
    controls.push("targetTemperature");
  }
  if (capabilities.fanSpeedWritable) {
    controls.push("fanSpeed");
  }
  if (capabilities.positionWritable) {
    controls.push("position");
  }
  return controls;
}

function toToolDevice(device: RaycastDevice): ToolDevice {
  return {
    id: device.id,
    name: device.name,
    room: device.roomName,
    category: device.category,
    state: device.isOnline ? device.stateText : "Offline",
    isOnline: device.isOnline,
    isActiveOn: device.isActiveOn,
    isFavorite: device.isFavorite,
    controls: controlsOf(device),
  };
}

function fold(value: unknown): string {
  return String(value ?? "").trim().toLowerCase();
}

/**
 * Read-only device list for Raycast AI. It reads the same `raycast-snapshot.json` the app writes, so
 * no credentials and no network calls are involved. Call it once per conversation and reuse the ids.
 */
export default async function tool(input: Input = {}): Promise<{
  updatedAt: string;
  isStale: boolean;
  connection: string;
  devices: ToolDevice[];
}> {
  const snapshot = await loadSnapshot();
  const query = fold(input.room);
  let devices = snapshot.devices ?? [];
  if (query) {
    const roomNames = new Set(
      devices
        .filter((device) => fold(device.roomId) === query || fold(device.roomName) === query)
        .map((device) => fold(device.roomName)),
    );
    if (roomNames.size === 0) {
      const known = [...new Set(devices.map((device) => device.roomName))].filter(Boolean).join(", ");
      throw new Error(`No room matches "${input.room}". Known rooms: ${known || "none"}.`);
    }
    devices = devices.filter((device) => roomNames.has(fold(device.roomName)));
  }
  return {
    updatedAt: snapshot.updatedAt,
    isStale: snapshot.isStale,
    connection: snapshot.connectionSummary,
    devices: devices.map(toToolDevice),
  };
}
