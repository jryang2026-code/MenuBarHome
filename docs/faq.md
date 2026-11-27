# FAQ

[← Back to the README](../README.md)

Each row in the table notes the app version, measurement date, and method. States not re-measured in the latest pass are marked **To be measured**; you can sample your own machine with `scripts/measure_footprint.py`.

## What if macOS Gatekeeper or Windows SmartScreen blocks the app, and how do I verify the download?

MenuBarHome is not enrolled in the paid Apple Developer Program and does not use a commercial Authenticode certificate, so your OS may warn on first launch.

### macOS (Gatekeeper)

1. Drag `MenuBarHome.app` from the DMG into `/Applications` and double-click it. When macOS warns that it cannot verify the developer, click **Done** (or **OK**) to close the dialog.
2. On **macOS 15 or later**, open **System Settings → Privacy & Security** and scroll down to the Security section.
3. Find the message saying `MenuBarHome` was blocked, click **Open Anyway**, click **Open Anyway** again in the confirmation prompt, and authenticate with Touch ID or your password.
4. **Alternative (Terminal):** if it still won't open or the **Open Anyway** button does not appear, remove the quarantine attribute:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MenuBarHome.app
   ```

### Windows 11 (SmartScreen)

1. When running the downloaded `.exe` or `.msi` installer, if you see the blue **Windows protected your PC** screen, click **More info**.
2. Click **Run anyway** at the bottom of the dialog to continue installation.

### Verifying download integrity (SHA-256)

Every GitHub Release (such as `v1.5.0`) ships a matching `.sha256` file for each installer:

- **macOS (`MenuBarHome-1.5.0.dmg`):**
  ```bash
  # Print the SHA-256 digest and compare with MenuBarHome-1.5.0.dmg.sha256 from the release
  shasum -a 256 MenuBarHome-1.5.0.dmg
  # Or verify automatically if the .sha256 file is in the same folder
  shasum -a 256 -c MenuBarHome-1.5.0.dmg.sha256
  ```
- **Windows (PowerShell):**
  ```powershell
  # Compare with MenuBarHome-1.5.0-windows-x64-setup.exe.sha256
  Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.5.0-windows-x64-setup.exe
  # For the MSI package, compare with MenuBarHome-1.5.0-windows-x64.msi.sha256
  Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.5.0-windows-x64.msi
  ```

For build provenance attestations and SBOM verification, see [SECURITY.md](../SECURITY.md#verifying-release-artifacts).

## How much memory and CPU does MenuBarHome use?

The macOS build is one native AppKit/SwiftUI process, with no bundled browser engine. The **Idle, panel closed** row below was measured on **2026-11-23** on an **Apple M1 Pro (10 cores, macOS 27.2.1)** against a live **MenuBarHome 1.4.0 (807)** process (`MenuBarMijiaApp`, PID `96621`): two read-only `ps -o cputime=,rss= -p <pid>` samples taken `139.3` seconds apart (`211.72s - 210.07s = 1.65s` CPU time over `139.30s` wall time, `1.18%` of one core), with `rss` reading `116032 KB → 114912 KB`.

| State | RSS | CPU (one core) | Measurement details |
| --- | --- | --- | --- |
| Idle, panel closed | 112–113 MB | 1.2% | Measured 2026-11-23 (`1.4.0 (807)`, 139.3s delta) |
| Panel open, no interaction | To be measured | To be measured | Not re-measured in this pass |
| Holding Option-M for voice input | To be measured | To be measured | Not re-measured in this pass (2026-11-07 `1.1.7 (426)` baseline: 152 MB / 26%) |

- **RSS** is the resident set size from `ps -o rss=`.
- **CPU** is a share of one core, computed from the `ps -o cputime=` delta divided by the elapsed wall seconds between samples. `ps %cpu` is a lifetime average and keeps reporting a busy period long after it ended, so it is not used directly.
- Opening the panel reuses the same process; PR #208 (merged 2026-11-17) fixed an issue where a background breathing animation kept running after closing the panel.
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
