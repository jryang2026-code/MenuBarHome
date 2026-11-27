# Will my devices work?

[← Back to the README](../README.md)

A quick lookup by device type. "Control" means the panel can switch or adjust it; "Read only" means it shows status but cannot be commanded from here. Every row names the capability it comes from in [`capabilities.json`](capabilities.json), and `scripts/check_supported_devices.py` fails the lint if this page and that file disagree.

This page covers devices that reach the app through **Mi Home** (QR sign-in) or **Home Assistant**, plus optional local **read-only generic IP cameras**, **DDC/CI external monitors**, and the **LAN multi-brand TV bridge**. Other ecosystems such as **Google Home, Apple HomeKit (HomeKit Device), Tuya, and Matter/Zigbee** are supported by aggregating them in **Home Assistant** and connecting Home Assistant here.

## By device type

| Device | Status | Notes | Source |
| :--- | :--- | :--- | :--- |
| Lights, light groups | Control | Brightness, colour temperature, presets. Group members fold into the group card by default | — |
| Plugs and switches | Control | Daily energy log; switching one on asks first | `plug-energy` |
| Air conditioners, heaters, electric blankets | Control | Target temperature, modes. Turning a heater on asks first | — |
| Fans, dehumidifiers | Control | Speed (`1–100%`), modes the device reports | `dehumidifiers-blankets-diffusers-speakers` |
| Curtains, window openers, clothes airers | Control | Position (`0–100%`) and travel state. Opening a window or an airer asks first | `covers-curtains` |
| Air purifiers, air fresheners, humidifiers | Control | PM2.5, filter life, fan level | `air-purifiers` |
| Water heaters | Control | Turning on or raising the target asks first | `water-heaters` |
| Bath heaters, range hoods | Control | One merged card: heat, fan, lamp | `bath-heaters-hoods` |
| Washers, dryers, dishwashers | Control | Programme list, remaining time; starting asks first | `laundry-appliances` |
| Fridges, kettles, cookers, ovens | Control | Temperatures and modes; start/pause where the model offers them | `fridges-kitchen` |
| Robot vacuums | Control | Starting asks first | — |
| Speakers | Control | Volume, mute, play state, Now Playing, and XiaoAI TTS / text directives on both platforms | `dehumidifiers-blankets-diffusers-speakers` |
| Cameras and video doorbells | Control | Live view; dual-lens and pan-tilt on verified models; optional read-only generic RTSP/ONVIF/ISAPI/Dahua/Tapo cameras | `camera-live`, `generic-camera` |
| Fish tanks, pet feeders | Control | Through the generic card; feeding asks for the portion | `fish-tanks-pet-feeders` |
| Smart TVs & set-top boxes | Control | HA & Xiaomi TVs with Now Playing, draggable seek (when supported), and D-pad remote; macOS built-in LG webOS; plus optional LAN TV bridge (`mbh-tv-bridge`) focused on LG webOS, Xiaomi / Redmi, and Hisense (overseas VIDAA) | `tv-media-bridge` |
| External monitors (DDC/CI) | Control | Optional on-demand brightness, input source (DP/HDMI/USB-C), and volume/mute on both platforms; power-off (`0xD6`) disabled for firmware safety | `external-display-ddc` |
| Door locks | Read only | Battery and, when the model reports it, locked / unlocked. Xiaomi's spec offers no remote unlock | `locks-sensors` |
| Motion, door/window, water-leak, light and air-quality sensors | Read only | Readings; temperature, humidity, PM2.5 and illuminance also get 24-hour and 7-day charts | `sensor-history` |
| Gateways, routers, repeaters | Read only | On macOS, a generic card when the model exposes something usable; otherwise listed as skipped | `generic-device-cards` |
| Anything else in Mi Home | Generic card | Name, room, up to two readings and one low-risk switch; the rest under More Settings | `generic-device-cards` |

## What is not covered

- **Stateless wireless remotes and buttons** have nothing to read or command.
- **Devices that are not in Mi Home or Home Assistant**, for example an air conditioner that only works in its maker's own app. If Home Assistant can see it, connect Home Assistant instead.
- **Unlocking a door** is not possible through Mi Home's interface, so locks stay read only.

## My device is missing or looks wrong

1. Open **Settings → About & Diagnostics → Devices Not Shown in the Panel** and scan. It lists what was skipped and why (macOS).
2. If it is skipped or wrong, [file a "device not supported" issue](https://github.com/jryang2026-code/MenuBarHome/issues/new?template=unsupported_device.yml). Give the model name; never post your device id or token.
