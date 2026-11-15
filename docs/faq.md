# FAQ

[← Back to the README](../README.md)

The numbers below were measured on a past release (see each section), not on the current one. Re-measure with `scripts/measure_footprint.py` before quoting them.

## How much memory and CPU does MenuBarHome use?

The macOS build is one native AppKit/SwiftUI process, with no bundled browser engine. Measured on 2026-11-07 with MenuBarHome 1.1.7 (426) on an Apple-silicon Mac (10 cores, macOS 27.0.1), with about a dozen devices configured, one of them a camera:

| State | RSS | CPU (one core) |
| --- | --- | --- |
| Idle, panel closed | 159 MB | 0.1% |
| Panel open, no interaction | 147 MB | 0.1% |
| Holding Option-M for voice input | 152 MB | 26% |

- **RSS** is the resident set from `ps`. Activity Monitor's Memory column (physical footprint) read about 146 MB for the loaded app.
- **CPU** is a share of one core, computed from CPU-time deltas across three sample windows (five seconds each by default). `ps %cpu` is a lifetime average and keeps reporting a busy period long after it ended, so the script does not use it as the measurement.
- Opening the panel reuses the same process, so RSS stays flat and CPU stays near zero when you do not interact.
- Voice input is the only state with noticeable CPU. `AVAudioEngine` streams the microphone and the speech framework transcribes it. The system's `corespeechd` does the recognition, and its CPU is not part of the app's number.
- Memory depends on what is connected. A camera stream, many MIoT device specs and large scenes all add memory.

## What about Windows 11?

The Windows build is Tauri v2 with WebView2. One host process runs the tray app, either `MenuBarHome.exe` from the installer or `menubarmijia-windows.exe` from a local Tauri build, and one or more `msedgewebview2.exe` processes render the UI. `scripts/measure_footprint.py` sums the host and its own renderer descendants, and ignores WebView2 processes that belong to other applications.

Windows 11 memory and CPU numbers are not in the table yet. They have to be taken on a Windows host. With the tray app running, run the same command there:

```powershell
python scripts\measure_footprint.py --state idle
python scripts\measure_footprint.py --state panel
python scripts\measure_footprint.py --state voice
```

## How do I reproduce these numbers?

`scripts/measure_footprint.py` samples the process that is already running. It never launches the app, and it cannot tell which state the app is in, so put the app in the state first:

```bash
# Idle: panel closed, app left alone for a minute
python3 scripts/measure_footprint.py --state idle

# Panel open: press Option-M, leave the panel open, then
python3 scripts/measure_footprint.py --state panel

# Voice: hold Option-M until the microphone indicator appears, and run this while it listens
python3 scripts/measure_footprint.py --state voice

# Machine-readable copy of the committed baseline
python3 scripts/measure_footprint.py --no-live --json
```

Live rows are marked `live` in the Source column. Without a running app the script prints the committed baseline and marks every row `recorded`. Quit any second copy of the app first. The script measures the first `MenuBarMijiaApp` it finds.
