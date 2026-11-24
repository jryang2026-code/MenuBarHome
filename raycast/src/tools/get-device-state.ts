import { matchDevice } from "../match";
import { loadSnapshot } from "../snapshot";

type Input = {
  /** Device name, room-prefixed name, id or pinyin initials, as returned by list-devices. */
  device: string;
};

/**
 * Read-only state for one device: its current state, room, and the supported range of every control,
 * plus the room's environment readings when the app reports them. Nothing is written here.
 */
export default async function tool(input: Input): Promise<{
  updatedAt: string;
  isStale: boolean;
  device: Record<string, unknown>;
  readings: Record<string, unknown>[];
}> {
  const snapshot = await loadSnapshot();
  const match = matchDevice(snapshot, input.device ?? "");
  if (!match.ok) {
    throw new Error(match.error);
  }
  const device = match.device;
  const capabilities = device.capabilities;
  const readings = (snapshot.environmentReadings ?? [])
    .filter((reading) => reading.roomName && reading.roomName === device.roomName)
    .map((reading) => ({
      label: reading.label,
      temperature: reading.temperature,
      humidity: reading.humidity,
      battery: reading.battery,
      updatedAt: reading.updatedAt,
    }));
  return {
    updatedAt: snapshot.updatedAt,
    isStale: snapshot.isStale,
    device: {
      id: device.id,
      name: device.name,
      room: device.roomName,
      category: device.category,
      state: device.isOnline ? device.stateText : "Offline",
      isOnline: device.isOnline,
      isActiveOn: device.isActiveOn,
      isFavorite: device.isFavorite,
      model: device.model,
      capabilities: {
        canTogglePower: device.isPrimaryToggleable,
        brightnessWritable: capabilities.brightnessWritable,
        brightnessPercent: capabilities.brightnessPercent,
        colorWritable: capabilities.colorWritable,
        colorTempKelvin: capabilities.colorTempKelvin,
        minKelvin: capabilities.minKelvin,
        maxKelvin: capabilities.maxKelvin,
        temperatureWritable: capabilities.temperatureWritable,
        targetTemperature: capabilities.targetTemperature,
        minTemp: capabilities.minTemp,
        maxTemp: capabilities.maxTemp,
        temperatureStep: capabilities.step,
        fanSpeedWritable: capabilities.fanSpeedWritable,
        fanPercentage: capabilities.fanPercentage,
        availablePresetModes: capabilities.availablePresetModes,
        positionWritable: capabilities.positionWritable,
        positionPercent: capabilities.positionPercent,
        isHighRisk: capabilities.isHighRisk,
      },
    },
    readings,
  };
}
