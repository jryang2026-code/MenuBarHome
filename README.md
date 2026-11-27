English | [简体中文](README.zh-CN.md)

<p align="center">
  <a href="https://trendshift.io/repositories/309141?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-309141" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/309141/daily?language=Swift" alt="jryang2026-code%2FMenuBarHome | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/309141?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-309141" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/309141/weekly?language=Swift" alt="jryang2026-code%2FMenuBarHome | Trendshift" width="250" height="55"/></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/logo-light.svg">
    <img src="docs/assets/logo.svg" width="120" alt="MenuBarHome Logo">
  </picture>
</p>

<h1 align="center">MenuBarHome</h1>

<p align="center">
  <b>Run your whole home from your computer, without reaching for your phone.</b><br>
  A Mi Home control center that lives in the Mac menu bar, with a Windows 11 tray edition too.<br>
  Scan one QR code with the Mi Home app and you're connected. No Home Assistant setup required.<br>
  <sub>Formerly known as <b>MenuBarMijia</b>.</sub>
</p>

<p align="center">
  <a href="https://github.com/jryang2026-code/MenuBarHome/stargazers"><img src="https://img.shields.io/github/stars/jryang2026-code/MenuBarHome?style=social" alt="GitHub Stars"></a>
  <a href="https://github.com/jryang2026-code/MenuBarHome/releases/latest"><img src="https://img.shields.io/github/v/release/jryang2026-code/MenuBarHome?color=0A84FF&label=release" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Windows_11-Tauri_v2-0078D4?logo=windows11&logoColor=white" alt="Windows 11">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
</p>

<p align="center">
  <a href="https://github.com/jryang2026-code/MenuBarHome/releases/latest"><b>Download latest</b></a> ·
  <a href="#quick-start">Install & Connect</a> ·
  <a href="docs/supported-devices.md">Will my devices work?</a> ·
  <a href="docs/platform-matrix.md">Platform Comparison</a> ·
  <a href="#safety-privacy--limitations">Safety & Privacy</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <img src="docs/assets/readme-v3/keyboard-search.gif" alt="macOS demo: press Option-M, type sftd to find the study desk lamp, and press Return to turn it on" width="420">
</p>

<p align="center"><sub>Press <code>⌥M</code>, type <code>sftd</code> (the pinyin initials of 书房台灯, "study desk lamp"), and hit Return. Recorded in macOS demo mode with virtual devices; the interface shown is in Chinese.</sub></p>

**Three steps:** [install](#1-install) (Homebrew, DMG, or the Windows installer) → [connect](#2-connect-your-home) (scan one QR code, or try the Demo with no account) → press `⌥M` (`Alt+M` on Windows).

> [!NOTE]
> **New name, new address:** as of 1.2.0, MenuBarMijia is called MenuBarHome and lives at [github.com/jryang2026-code/MenuBarHome](https://github.com/jryang2026-code/MenuBarHome). Version 1.1.7 and earlier can't pick up this update on their own, so install it by hand once. Your sign-in and settings carry over; afterwards, delete the old `MenuBarMijia` app (on Windows, uninstall the old version first).

> [!IMPORTANT]
> **Not affiliated with Xiaomi.** MenuBarHome is an independent open-source project, not an official Xiaomi or Mijia product, and is not affiliated with, endorsed by, or sponsored by Xiaomi Corporation or its affiliates. "Xiaomi", "Mijia", "Mi Home", and "米家" are trademarks of Xiaomi Corporation and its affiliates. The project uses these names only to describe compatibility with Xiaomi / Mijia devices; no endorsement is implied.

---

## Why You'll Want It

You're writing, coding, or on a call, and the light needs to go off. Normally that means unlocking your phone, finding the app, and digging through rooms. MenuBarHome turns it into one shortcut.

- **Scan and go.** Choose "Mi Cloud Connect" in Settings, scan the QR code on screen with the Mi Home app, and every room and device shows up. No Home Assistant, no token hunting. If you already run Home Assistant, you can connect that instead.
- **Keep your hands on the keyboard.** `⌥M` opens the panel. Start typing a device name, a room, or pinyin initials, and press Return to toggle. Arrow keys adjust brightness and temperature.
- **Hold to talk, let go to run it.** No wake word, no waiting for a reply. Everyday commands like switching, dimming, setting the temperature, or timers are understood on your Mac, with no AI key needed.
- **Undo the oops.** All Off leaves plugs, robot vacuums, and cameras alone by default. If you switched off something you needed, tap Undo and everything comes back.
- **Follows your Mac.** Lights off when you lock the screen, desk lamp on when you plug in a display, lighting set before a calendar meeting starts. Every rule starts switched off, so you choose what runs.
- **Native and quiet.** The macOS app is written in Swift with no bundled browser engine, and uses about 1.2% CPU (~113 MB RSS) when idle in the background with the panel closed (see [FAQ](docs/faq.md)).

---

## Quick Start

### 1. Install

- **macOS:** macOS 14 (Sonoma) or later, Universal Binary for Apple Silicon and Intel.
- **Windows:** Windows 11 (64-bit).

**macOS · Homebrew**

```bash
brew tap jryang2026-code/tap
brew trust --cask jryang2026-code/tap/menubarhome
brew install --cask jryang2026-code/tap/menubarhome
```

**macOS · DMG**

Download `MenuBarHome-<version>.dmg` (for example, `MenuBarHome-1.5.0.dmg`) from [GitHub Releases](https://github.com/jryang2026-code/MenuBarHome/releases/latest) and drag `MenuBarHome.app` into Applications.

> The project isn't enrolled in the paid Apple Developer Program, so the app isn't notarized. If macOS Gatekeeper blocks the first launch:
> 1. Double-click `/Applications/MenuBarHome.app` and click **Done** (or **OK**) to dismiss the warning dialog.
> 2. On macOS 15 or later, open **System Settings → Privacy & Security** and scroll down to the Security section.
> 3. Click **Open Anyway** next to the message about `MenuBarHome`, click **Open Anyway** again in the confirmation dialog, and authenticate with Touch ID or your password.
> 4. **Alternative:** if it still won't open or the **Open Anyway** button doesn't appear, clear the quarantine attribute in Terminal:
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/MenuBarHome.app
>    ```

Verify the DMG download against `MenuBarHome-1.5.0.dmg.sha256` from the same release:

```bash
shasum -a 256 MenuBarHome-1.5.0.dmg
# Or verify automatically if the .sha256 file is in the same directory:
shasum -a 256 -c MenuBarHome-1.5.0.dmg.sha256
```

**Windows 11**

Download `MenuBarHome-<version>-windows-x64-setup.exe` (for example, `MenuBarHome-1.5.0-windows-x64-setup.exe`) or `MenuBarHome-<version>-windows-x64.msi` (for example, `MenuBarHome-1.5.0-windows-x64.msi`) from [GitHub Releases](https://github.com/jryang2026-code/MenuBarHome/releases/latest).

> The installer isn't signed with a commercial Authenticode certificate. If Windows SmartScreen blocks it:
> 1. When the blue **Windows protected your PC** prompt appears, click **More info**.
> 2. Click **Run anyway** at the bottom of the dialog to continue installation.

Verify the Windows installer in PowerShell against the corresponding `.sha256` file on the release page:

```powershell
# For the EXE installer (compare with MenuBarHome-1.5.0-windows-x64-setup.exe.sha256)
Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.5.0-windows-x64-setup.exe

# For the MSI installer (compare with MenuBarHome-1.5.0-windows-x64.msi.sha256)
Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.5.0-windows-x64.msi
```

### 2. Connect your home

Click the menu bar (or tray) icon to open the panel, open Settings `⚙️`, and pick one:

- **Mi Cloud Connect (recommended):** choose "Mi Cloud Connect", scan the QR code with the Mi Home app on your phone, and your homes, rooms, and devices sync in. CN, SG, DE, US, and RU servers are supported. On both macOS and Windows you can add more accounts and see all their devices in one panel. If your sign-in is about to expire, the panel warns you 3 days ahead, and a quick re-scan in the panel renews it.
- **Home Assistant (including other ecosystems):** enter your instance address (for example `http://192.168.1.100:8123`; reverse-proxy subpaths work too) and a long-lived access token. Both macOS and Windows can find Home Assistant on your local network. The token is kept in the macOS Keychain or Windows Credential Manager. **Ecosystem boundary:** MenuBarHome connects directly to Mi Home and Home Assistant (plus optional local generic IP cameras, DDC/CI displays, and the LAN TV bridge); devices from **Google Home, Apple HomeKit (HomeKit Device), Tuya, Aqara/Matter/Zigbee**, and other platforms integrate cleanly through Home Assistant aggregation.<br>
  If macOS says "Local network connection blocked by macOS", allow MenuBarHome under **System Settings → Privacy & Security → Local Network**.
- **Demo mode:** try the whole interface with virtual devices, no account needed.

---

## Take the Tour

### A new panel

Search now sits at the top, and the same box takes device names, state questions, and spoken commands. Favorite devices are laid out as tiles, the AC can be nudged up or down right on its card, and room tabs, room auto-group capsules, sorting, and the compact view are a click away. Quick Actions and "For You" suggestions fold behind a single **Shortcuts** toggle (`⌘K` on macOS, `Ctrl+K` on Windows) so the first screen stays uncluttered. Light and dark follow the system, and on macOS 26 or later you can switch to the Liquid Glass theme; opening the macOS panel no longer dims the app you're working in.

<p align="center">
  <img src="docs/assets/readme-v3/panel-themes.gif" alt="The macOS panel in the Classic and Liquid Glass themes, in light and dark appearance" width="900">
</p>

### Settings that feel like System Settings

A sidebar of categories with colored icons and grouped cards, laid out like the Mac's own System Settings. The search field understands Chinese and English keywords plus synonyms, and picking a result jumps straight to that setting and highlights it.

<p align="center">
  <img src="docs/assets/readme-v3/settings.gif" alt="macOS settings: moving between Home Connection, Appearance, and Privacy, then searching &quot;dark&quot; jumps straight to the appearance mode setting" width="900">
</p>

### Hold to talk

Hold `⌥M` or the menu bar icon, say what you want, and let go. What you say appears in the search field as you speak and runs the moment you release. Everyday commands are parsed locally, so there's almost no wait; for trickier requests you can plug in an AI service of your choice.

<p align="center">
  <img src="docs/assets/readme-v3/hold-to-talk.gif" alt="macOS demo: hold Option-M, ask to set the living room light to 40 percent, release, and the ceiling light dims to 40%" width="900">
</p>

### All Off, with Undo

Heading out or going to bed? Hold All Off for 0.6 seconds and everything that's on in the current view switches off. Plugs, robot vacuums, and cameras sit it out by default (you can change that in Settings). An Undo button appears right after; one tap restores the way things were.

<p align="center">
  <img src="docs/assets/readme-v3/all-off-undo.gif" alt="macOS demo: hold All Off to turn off three devices while the plug stays on, then tap Undo to restore them" width="420">
</p>

### Windows 11, redesigned too

The tray app uses the Classic two-column split-tile panel by default and also offers a Windows 11 Fluent 2 two-island flyout (home status, "For You" suggestions, and a camera glance on top; search, quick actions, and device tiles below). Keyboard search, `Alt+M`, native Mica/Acrylic backdrop with system accent colors (Windows 11 22H2+), an independent always-on-top camera PiP window, and light/dark appearance are all there.

<p align="center">
  <img src="docs/assets/readme-v3/windows-fluent.png" alt="The Windows 11 tray panel in light and dark appearance" width="820">
</p>

---

## What Else It Does

- **Works with a lot of devices.** Lights, ACs, fans, plugs, TVs (including MIoT TVs and set-top boxes), curtains, clothes airers, air purifiers, humidifiers, fridges, water heaters, washers and dryers, bath heaters, range hoods, robot vacuums, speakers (with Now Playing and XiaoAI TTS/directive controls on both platforms), cameras, locks, and all sorts of sensors. Mi devices without a dedicated card still get a generic one. [Check your own devices here.](docs/supported-devices.md)
- **TVs, Now Playing, External Monitors (DDC/CI) & Optional Multi-Brand TV Bridge.** Home Assistant TVs/speakers and Xiaomi MIoT TVs get a shared **Now Playing** view (playback status, metadata, authenticated same-origin HA artwork with SHA-256 LRU cache, and a draggable seek bar with a 2 s anti-snap-back guard shown only when `canSeek` + `duration` + `position` are reported) plus a collapsible D-pad remote (ecosystem-adapted HA `remote.send_command` for Apple TV / Android TV / Sony Bravia / Roku / generic + verified MIoT actions). Under Settings → General on both platforms, you can also enable **External Display Control (DDC/CI)** (off by default, zero background traffic when off: brightness, DP/HDMI/USB-C input switching, and volume/mute when read back; power-off `0xD6` is strictly forbidden for firmware safety) and the optional out-of-process **Multi-Brand TV Bridge** (`mbh-tv-bridge`, LAN-only Go binary that shuts down when the panel closes and never hijacks a TV already connected via HA or Mi Home), defaulting to **LG webOS** (SSAP + WoL), **Xiaomi / Redmi** (HTTP 6095), and **Hisense** (overseas VIDAA MQTT 3.1.1) with other brands behind an experimental toggle.
- **On-Device & Ambient-Aware AI.** Everyday commands (including `0–100%` curtains/covers and `1–100%` fan speed) are parsed locally with pinyin/homophone matching and 3-way miss diagnostics; macOS also learns 0 ms phrase shortcuts after 3 consistent hits. On **macOS 26+** with Apple Intelligence enabled, Settings → AI explicitly surfaces an **Apple Foundation Models** status card with one-click default opt-in, API-key-free connection checks, and on-device proactive suggestions. Both macOS and Windows feed only strictly controlled boolean desktop ambient signals (`inMeeting`, `externalDisplayConnected`, `focusActive`, `lateNightWork`, `mediaPlaying` — never window titles, calendar titles, or Wi-Fi SSIDs) into AI prompts and "For You" ranking. Windows voice input adds a panel-focused `Ctrl+M` toggle (`Esc` to abort), home-vocabulary hotword post-correction, and diff-preview confirmation.
- **Camera windows, still wall & PiP.** Click a camera for a pinned live view (independent always-on-top PiP on Windows, 3:4 portrait layout for doorbells, optional auto-open countdown on doorbell/alarm events with up to 2 pinned switches, and listen-only audio where supported by the stream). A 2×2 still wall keeps recent snapshots and a 7-day camera event history; dual-lens models can switch lenses, and pan-tilt cameras turn when you drag the picture. Non-Xiaomi IP cameras (RTSP, ONVIF, Hikvision ISAPI, Dahua, Tapo) can be added under Settings → advanced connections as **read-only generic cameras**: live view and PiP only (no PTZ, talk-back, or camera settings), LAN or `.local` hosts unless you explicitly allow a public address, and passwords kept in the Keychain / Windows Credential Manager, never in config files.
- **Climate trends and energy logs.** Sensors show a 24-hour hover sparkline right on the card plus full 24-hour and 7-day charts; plugs keep a daily energy log, and with your electricity rate entered you get a cost estimate.
- **Moods, room groups & "For You" suggestions.** Save a room's current device states as a local **Mood** (up to 32) and replay it with one click or a global hotkey. Rooms with two or more controllable devices of the same kind show auto-group capsules. Based on what you usually turn on, when, and your current desktop ambient state, "For You" surfaces likely next actions; habits stay on your machine and can be reviewed or cleared anytime.
- **Multiple accounts, two sources & LAN-first speed.** Sign in to several Xiaomi accounts at once, or run Mi Home and Home Assistant side by side; the same physical device is merged automatically. Compatible Wi-Fi Mi devices prefer direct LAN control with explicit write acknowledgements (falling back cleanly to Mi Cloud for legacy non-MIoT LAN devices), and macOS probes cloud-offline Xiaomi devices on the LAN as a read-only reachability hint.
- **Context-aware automations, safety alerts & weekly report.** Rules can run on schedules, lasting conditions, or Mac frontmost apps (with one-click Meeting and Movie templates on macOS), and context restoration automatically restores prior power states when a session ends. Interactive safety notifications let you turn off a device or view a doorbell live feed right from the alert (guarded by screen lock), and a weekly home health report highlights frequent disconnects and standby power draw.
- **Plugs into your tools.** Custom global hotkeys (up to 8 device, scene, quick-action, or mood bindings on both platforms, with a non-focus-stealing HUD on macOS), Apple Shortcuts, `menumijia://` links, a Raycast extension, a bundled local CLI (`mijia doctor`), and **MCP Server 2.0** (bundled with zero-placeholder Settings **Copy Config**), so AI tools like Claude and Cursor can check on and control your home without ever seeing your account credentials.

For what each platform supports, see the [platform comparison](docs/platform-matrix.md).

---

## Keyboard Shortcuts & Natural Commands

### Keyboard Navigation

`⌥M` opens the panel on macOS and `Alt+M` opens it on Windows; you can also bind up to 8 custom global hotkeys to individual devices, scenes, quick actions, or moods on both platforms. Typing to search, `↑`/`↓`, `Return`/`Space`, `→`/`←`, `Tab` (cycle room tabs), `⌘K` / `Ctrl+K` (toggle Shortcuts drawer), and `Esc` work on both platforms; `Ctrl+M` toggles voice listening in the focused Windows panel.

| Shortcut | Action |
| :--- | :--- |
| `⌥M` / `Alt+M` | Toggle the MenuBarHome panel (macOS / Windows) |
| `⌘K` / `Ctrl+K` | Expand or collapse the Shortcuts drawer (Quick Actions, Scenes, and For You) |
| Hold `⌥M` / `Ctrl+M` | Hold to talk on macOS; toggle hands-free voice listening in the focused Windows panel (`Esc` cancels) |
| Custom hotkeys (up to 8) | Trigger a bound device, scene, quick action, or mood globally (with confirmation on high-risk targets) |
| Type letters | Instant search by device name, room, or pinyin initials (e.g. `sftd`) |
| `↑` / `↓` | Navigate through search matches and device cards |
| `Return` / `Space` | Toggle the focused device; expand the detail drawer if not directly switchable |
| `→` / `←` | Press Right to open details; then use Left and Right to adjust light brightness, AC temperature, cover position, or volume (Windows also adjusts fan speed) |
| `Tab` | Switch between room tabs (macOS & Windows) |
| `Esc` | Clear search query, abort voice input, close drawer, or dismiss panel |

### Local Natural Language Commands

These phrases are parsed locally **without any AI API key** or cloud model tokens (with pinyin/initials/homophone fallback matching):

- **Power:** "turn off study light", "turn on living room ac", "turn off all lights"
- **Lighting presets:** "study light moonlight mode", "daylight mode"
- **Adjustments:** "dimmer", "brighter", "set bedroom light to 40%"
- **Climate, Fan & Covers:** "set ac to 24 degrees", "warmer", "fan natural wind", "set living room fan to 60%", "open living room curtain to 50%" (garage doors, window openers, and clothes airers always ask for confirmation)
- **State queries:** "which lights are on?", "is the study lamp on?", "living room temperature" (answered locally from current device state)
- **Timers:** "in 10 minutes turn off study light", "cancel timer"
- **Undo:** "undo", "revert" (active for 10 minutes after any batch execution)

Commands that touch two or more devices or any high-risk device show an inline before → after diff preview for confirmation before executing.

---

## Platform Comparison

macOS is a native Swift 6 app; Windows 11 is a separate Tauri v2 implementation. They share golden test fixtures, but they are not identical:

| Area | macOS 14+ | Windows 11 |
| :--- | :---: | :---: |
| Mi Home QR connect | ✅ | ✅ |
| Home Assistant (aggregates HomeKit / Google Home / Tuya / Matter) | ✅ | ✅ |
| Keyboard search and global hotkey | ✅ `⌥M` | ✅ `Alt+M` |
| Voice | ✅ hold to talk or hands-free | ⚠️ hands-free (`Ctrl+M` + hotword correction) |
| Local commands & AI assistant | ✅ + Apple Foundation Models (macOS 26+) | ✅ local rules + cloud / Ollama |
| All Off and Undo | ✅ | ✅ |
| TV Now Playing, seek, remote & optional TV bridge | ✅ | ✅ |
| External display control (DDC/CI) | ✅ | ✅ |
| Camera live view | ✅ | ✅ |
| Read-only generic IP cameras (RTSP/ONVIF/ISAPI/Dahua/Tapo) | ✅ | ✅ |
| Several Xiaomi accounts at once | ✅ | ✅ |
| Mi Home + Home Assistant dual source | ✅ | ✅ |
| Event automation | ✅ | ⚠️ partial |
| Apple Shortcuts | ✅ | — |
| Signed installer | ⚠️ self-signed | ⚠️ unsigned |

The full device-by-device table, with every capability and its status, is in [docs/platform-matrix.md](docs/platform-matrix.md).

---

## Raycast Extension, Local CLI & MCP Server

MenuBarHome can hand its device list to a companion without sharing any credential. Turn on **Settings → 通用 → 自动化与外部控制 → 高级 → Raycast / CLI / MCP 集成** (**Settings → General → Automation & External Control → Advanced → Raycast / CLI / MCP integration**) on macOS (or **Settings → Safety & Alerts → Raycast / CLI / MCP integration** on Windows): the app writes `~/Library/Application Support/MenuBarMijia/raycast-snapshot.json` on macOS (mode `0600`) or `%LOCALAPPDATA%\MenuBarMijia\raycast-snapshot.json` on Windows with your devices, scenes, quick actions, environment readings, sanitized automation summary, the last command result, and a random local bridge token. Links that carry the token skip the external-link confirmation prompt; high-risk devices still ask, and the lock-screen block still applies on both platforms. Turning the integration off deletes the file and revokes the token. The contract and the trade-offs behind it are in [ADR-0013](docs/adr/0013-raycast-companion-contract.md).

Both the macOS app bundle (`MenuBarHome.app/Contents/Resources/cli/`) and the Windows installer (`cli/` resources) ship `scripts/mijia` and `scripts/mijia-mcp` inside the package. Clicking **Copy Config** in Settings resolves the real installed path automatically with zero placeholder paths to edit.

**Why you still see the old name.** The app is MenuBarHome, but the integration surface kept its original names so existing Raycast commands, Shortcuts, scripts and MCP configs keep working:

| You will see | What it is | Use this |
| :--- | :--- | :--- |
| `menumijia://…` | The URL scheme every companion sends. It is a compatibility contract ([ADR-0013](docs/adr/0013-raycast-companion-contract.md)), so companions keep sending it | Keep `menumijia://`; `menubarhome://` is accepted as an exact alias |
| `scripts/mijia`, `scripts/mijia-mcp` | The bundled CLI and MCP server | `scripts/menubarhome` is the same CLI under the new name; `mijia` keeps working |
| `MenuBarMijia/` data folder, `MenuBarMijiaApp` process | The app's data directory and process name | Nothing to do; your sign-in and settings live there |
| MCP key `menubarmijia` | A label in your MCP client's config, and the server's reported name | Name it anything; the example below uses `menubarhome` |

<details>
<summary><b>How to use the CLI, MCP server, and Raycast extension</b></summary>

### Local CLI

`scripts/mijia` is a dependency-free Python 3 script (bundled inside the app or runnable from a repo checkout). Keep MenuBarHome running while you use it.

| Command | What it does |
| :--- | :--- |
| `scripts/mijia doctor [--json]` | One-line health check: companion integration state, snapshot freshness, and CLI/MCP executable paths (same as `scripts/mijia mcp --doctor`) |
| `scripts/mijia list [--room 书房] [--json]` | Visible devices grouped by room, with online state and readings |
| `scripts/mijia list --format alfred [--room 书房]` | Alfred Script Filter JSON: one item per device, ↵ flips its power, ⌘ shows it in the panel |
| `scripts/mijia list --format swiftbar [--room 书房]` | SwiftBar / xbar plugin text: a menu bar header, one clickable line per device with its state |
| `scripts/mijia status [--json]` | Connection, device counts, environment readings, and the last command's result |
| `scripts/mijia toggle 书房台灯` | Flip the primary switch by name, id, or pinyin initials (`sftd`) |
| `scripts/mijia on 客厅射灯` / `scripts/mijia off 客厅射灯` | Set an exact power state instead of flipping |
| `scripts/mijia brightness 书房台灯 60` | Set light brightness (`0`–`100`%) |
| `scripts/mijia color-temp 书房台灯 4000` | Set light colour temperature (`1000`–`20000` K) |
| `scripts/mijia temperature 书房空调 25` | Set target temperature (`-30`–`100` ℃) |
| `scripts/mijia fan 客厅风扇 --percent 60` / `--preset 自然风` | Set fan speed percentage (`1`–`100`%) or a reported preset mode |
| `scripts/mijia cover-position 客厅窗帘 50` | Set curtain or cover position (`0`–`100`%; garage doors and window openers always require confirmation in-app) |
| `scripts/mijia volume 客厅电视 35` / `mute 客厅电视 on` / `media-play-pause 客厅电视` | Control TV or speaker volume (`0`–`100`%), mute state, and play/pause |
| `scripts/mijia focus 书房台灯` | Reveal the device's room and detail drawer in the panel without actuating hardware |
| `scripts/mijia scene 观影模式` | Run a Home Assistant scene or a built-in quick action (全屋关灯, 一键全关, 撤销…) |
| `scripts/mijia ask "把客厅灯调到 40%"` | One natural-language command, with the app's own parsing and confirmation |
| `scripts/mijia mcp` (or `scripts/mijia-mcp`) | Run local MCP Server 2.0 over stdio |

`scripts/menubarhome` runs the same program: `scripts/menubarhome list` is `scripts/mijia list`.

Exit codes: `0` success, `1` the app reported a failure, `2` local error (snapshot missing, unknown device, integration off), `3` no result in time. `--dry-run` prints the link with the token masked, `--no-wait` sends it without waiting, and `MENUBARMIJIA_SNAPSHOT_PATH` overrides the snapshot path.

### Alfred & SwiftBar

`--format alfred` and `--format swiftbar` render the same read-only snapshot as `list`: nothing is written and no network call is made. Every entry carries a `menumijia://` link, so a click still goes through the app's external-link confirmation, high-risk device confirmation and lock-screen block.

For SwiftBar, save a two-line plugin in the plugin folder, for example
`~/Library/Application Support/SwiftBar/plugins/menubarhome.1m.sh` (the `1m` refreshes it every minute):

```sh
#!/bin/sh
exec /Applications/MenuBarHome.app/Contents/Resources/cli/mijia list --format swiftbar
```

For Alfred, add a **Script Filter** with the keyword `mijia` whose script runs
`/Applications/MenuBarHome.app/Contents/Resources/cli/mijia list --format alfred`, then connect it to an **Open URL**
action so the selected `arg` is opened. Each item's ⌘ variant opens the device in the panel instead of
flipping it. `--icon /Applications/MenuBarHome.app` sets the item icon when the app lives elsewhere;
without it the script uses the installed app's icon, or Alfred's workflow icon.

Both formats put the local bridge token in the links, exactly like every other CLI command: the token
only skips the generic "an external link wants to run this" prompt, and the app still asks before a
high-risk device changes state and refuses controls while the screen is locked.

### Local MCP Server 2.0 (Claude Desktop / Claude Code / Cursor)

`scripts/mijia-mcp` (or `scripts/mijia mcp`) speaks MCP JSON-RPC 2.0 over stdio using only the Python 3 standard library. It exposes **5 read-only resources** (`mijia://status`, `mijia://devices`, `mijia://scenes`, `mijia://sensors`, `mijia://automations`) and **17 tools** — 5 read-only (`list_devices`, `get_home_status`, `get_sensor_summary`, `get_automation_status`, `focus_device`) and 12 control tools (`toggle_device`, `set_device_power`, `set_light_brightness`, `set_light_color_temp`, `set_temperature`, `set_fan`, `set_cover_position`, `set_media_volume`, `set_media_mute`, `media_play_pause`, `run_scene`, `ask_home`). The server uses `bridgeToken` internally to dispatch `menumijia://` links and strips `bridgeToken` and OS free-text strings (calendar/window titles, Wi-Fi SSIDs) from every MCP resource and tool response so secrets never enter the model's context.

Click **Copy Config** inside Settings to copy a ready-to-paste config pointing directly at your installed `mijia-mcp` (zero placeholder paths). On macOS with the app in `/Applications`, it looks like:

```json
{
  "mcpServers": {
    "menubarhome": {
      "command": "/Applications/MenuBarHome.app/Contents/Resources/cli/mijia-mcp"
    }
  }
}
```

Run `mijia doctor` (or `mijia-mcp --doctor`) anytime for a one-line health summary. Every control tool carries `destructiveHint: true` (and `ask_home` also sets `openWorldHint: true`), so MCP clients that honour the annotations ask before running one. To give an AI session read-only access, add `--read-only` to the same entry (`"args": ["--read-only"]`, or run `scripts/mijia mcp --read-only`): `tools/list` then advertises only the 5 read-only tools (`list_devices`, `get_home_status`, `get_sensor_summary`, `get_automation_status`, `focus_device`), and any control call comes back as an error naming the flag instead of touching a device.

### Raycast

`raycast/` is a standard Raycast extension with three view commands (**Search Devices**, **Scenes & Quick Actions**, **Ask MenuBarHome**), three `no-view` commands you can bind to a global hotkey (**Toggle Device**, **Run Scene**, **All off**, which confirms first), and three AI tools (`list-devices`, `get-device-state`, `control-device`) for `@MenuBarHome` in Raycast AI. Import it with Raycast → Extensions → `+` → **Import Extension**, or run `cd raycast && npm ci && npm run dev` while Raycast is open. Power, brightness, colour temperature, thermostat target and fan speed are sent as exact values (`menumijia://power`, `brightness`, `color-temp`, `temperature`, `fan`), so a slider never flips a device by guessing its state; the view commands show an animated toast while the app works, then update it to the result, the `no-view` commands report through a HUD, and `control-device` asks Raycast for confirmation before sending its link.

</details>

---

## Safety, Privacy & Limitations

### Know before you connect

- **Mi Cloud Connect uses an unofficial client API.** It is not an official Xiaomi integration. Xiaomi can rate-limit requests or flag an account (risk control) at any time, and this project cannot promise it won't happen. The app polls less when the panel is closed or the screen is locked, reserves rate-limit capacity for user control writes with exponential backoff, and routes eligible Wi-Fi devices over direct LAN miIO first (falling back to Mi Cloud for legacy non-MIoT LAN devices). If you'd rather not take that risk, connect Home Assistant with Xiaomi's official [xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home) integration instead.
- **You will need to scan again.** The app does not store the long-lived `passToken` and does not renew a sign-in silently ([ADR-0004](docs/adr/0004-no-pass-token-storage.md)). How long a sign-in lasts is decided by Xiaomi's server and is shown in Settings when it is known; the panel warns you 3 days before it ends, and re-scanning takes a few seconds.
- **Ecosystem scope.** Direct built-in connectors are Mi Home and Home Assistant (plus optional local generic IP cameras, DDC/CI displays, and the LAN multi-brand TV bridge). **Google Home, Apple HomeKit (HomeKit Device), Tuya, Aqara/Matter/Zigbee**, and other platforms are brought in via **Home Assistant** aggregation.
- **The apps are not code-signed commercially.** macOS needs **Open Anyway** on first launch and Windows shows a SmartScreen prompt (see [Install](#1-install)).
- **Windows platform differences.** Windows 11 only; voice uses hands-free dictation (`Ctrl+M` toggle + hotword post-correction + diff preview, no hold-to-talk); event automation covers lock/unlock, power/battery, display/suspend, camera/mic, Focus/fullscreen/presentation, Wi-Fi, schedules, and sensor rules with context restore (no Calendar, lid-closed sleep, or frontmost-app triggers); no Apple Foundation Models or Apple Shortcuts. See the [platform comparison](#platform-comparison).

### Safety and privacy

- Account credentials live only in the macOS Keychain or Windows Credential Manager, never in plain config files or logs.
- Turning on a heater, switching a plug, or starting a robot vacuum always asks first; turning them off happens right away.
- While your computer is locked, manual control is refused by default on both macOS and Windows, so nobody can play with your lights while you're away from the desk.
- Everyday commands are parsed on your machine (and on macOS 26+ with Apple Intelligence, complex commands can also run on-device via Apple Foundation Models). Only when you've set up a cloud AI service and a command can't be understood locally does that command, with the relevant device details and boolean-only desktop ambient tags, go to the service you chose.
- In-app updates are verified against an Ed25519 signature whose private key is kept offline.

<details>
<summary><b>Full details: where credentials live, high-risk confirmations, lock screen, and revocation</b></summary>

MenuBarHome is an independent open-source project, not an official Xiaomi app. Mi Home cloud control needs an internet connection. You can connect your own Home Assistant instance on macOS or Windows.

### Where credentials live

| Secret | What is stored | Where |
| :--- | :--- | :--- |
| Xiaomi Home / Mijia | Signed-in account `userId`, `cUserId`, `ssecurity`, `serviceToken`, cloud region, and declared expiry (`passToken` is dropped on login; multi-account on both macOS and Windows) | macOS Keychain (one generic-password item) or Windows Credential Manager (`mi_session` and `mi_session_<slotId>`) |
| Home Assistant | The long-lived access token (the instance URL is not secret) | macOS Keychain or Windows Credential Manager (`ha_token`) |
| AI assistants | Per-provider API keys, plus non-secret imported-key labels, custom-endpoint bindings, and remembered cloud-consent endpoints | Per-provider API keys in macOS Keychain or Windows Credential Manager (`assistant_api_key_<preset>`); non-secret metadata in app preferences |
| Read-only generic cameras | Per-camera RTSP / ONVIF / ISAPI / Dahua / Tapo credentials (handed to go2rtc in memory only, never written to `go2rtc.yaml`) | macOS Keychain or Windows Credential Manager (`generic-camera:<id>`) |
| LG webOS TV (built-in) | The pairing client key issued by the TV | macOS Keychain |
| Multi-brand TV bridge (`mbh-tv-bridge`) | Per-TV pairing client keys / bridge credentials (injected at runtime only) | macOS Keychain (`tvBridge.cred.<nativeId>`) or Windows Credential Manager (`tv-bridge:<id>`) |

macOS encrypts these Keychain items at rest and protects them with the login Keychain; MenuBarHome writes them with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they are available after the first unlock but are never synced to iCloud or another Mac. Neither platform stores secrets in plain `UserDefaults`, WebView `localStorage`, or log files. macOS may ask for Keychain permission after an app update because the build signature changes; answering "Always Allow" covers later reads and writes.

On macOS, versions up to 1.0.6 could mirror credentials into plain `UserDefaults`; on first launch after upgrading, each legacy plaintext value is written into the Keychain and the plaintext key is deleted only after that write succeeds, leaving the old copy in place to retry if Keychain is unavailable. On Windows, upgrading from a legacy `localStorage` build strips secret fields and rewrites `localStorage` before persisting to Windows Credential Manager so a credential-store error never leaves plaintext tokens lingering in WebView storage (the in-memory session stays active for that run), and legacy single-slot `assistant_api_key` entries in Credential Manager migrate into their owning per-provider slot before the legacy entry is deleted.

### High-risk controls, lock screen, and revocation

Manual controls on high-risk devices ask for a second confirmation, not only AI-proposed actions: turning on a heater, switching a plug or camera, starting a vacuum, or turning a water heater on or hotter (on macOS, panel pointer controls also offer a 0.65 s hold or slide-to-confirm gesture, while keyboard and VoiceOver keep explicit confirmation alerts). Turning one of these off stays direct, so making the home safer never requires fighting a dialog. Door/window and gas-alarm sensors are read-only status cards in this app, so they cannot be actuated here at all. The confirmation table is shared across platforms (`Tests/Fixtures/confirmation_golden.json`, `Sources/MijiaCore/ModelActionPolicy.swift`).

On macOS, Settings → 隐私 / Privacy has **锁屏时禁止控制设备 / Block device control while locked**, on by default, as well as **共享屏幕时隐藏面板与摄像机窗口 / Hide from screen sharing** (`NSWindow.sharingType = .none`). While the Mac screen is locked, card/detail controls, custom hotkeys, `menumijia://` links, App Intents/Shortcuts, assistant commands, the safety notification's 立即关闭 / Turn Off Now action and 立即补执行 / Run Now on a missed timer are refused with a toast; timers that fire on schedule and Mac-event automation rules still run. The toggle is persisted locally and the lock state comes from the system's screen-lock notifications.

The same macOS Settings page has **退出并吊销令牌 / Sign Out & Revoke Tokens**, confirmed by a destructive dialog. It signs out every Xiaomi Home account, deletes the Home Assistant token and disconnects, and clears saved AI keys and cloud-consent records while keeping device names, room layout, and local history; you can also revoke one item at a time in its own section. On Windows, credentials and remembered cloud-AI consent endpoints can be cleared per service across the settings sheet (clearing the HA token or a provider's API key deletes its Windows Credential Manager entry, and **AI & Habits** includes a button to revoke remembered cloud-AI consent endpoints).

On macOS, the Home Assistant token goes directly only to an `https` address or a local-network endpoint; for any other plain-`http` address (such as a public DDNS hostname), the panel explains that the token would travel unencrypted and connects only after you choose 仍然连接 / Connect Anyway (remembered per address and cleared by Sign Out & Revoke Tokens). On Windows, every new Home Assistant or custom AI origin requires approval in a native system dialog (`authorized-http-origins.json`), which adds an explicit plaintext-transmission warning whenever a non-local `http` origin would carry tokens or API keys. Both platforms also validate resolved DNS answers before connecting (`HAPlaintextConsent.validateConnectionAddress` on macOS, `PolicyAwareResolver` on Windows) to reject prohibited addresses and protect local plaintext endpoints against DNS rebinding.

Everyday commands are handled by local rules. You can also connect an AI service of your choice for more complex requests. The request includes your command, device and environment information, and any habit summary you have enabled. Manual card actions also train local time-bucket habit memories (used only for the "For You" suggestions); the habit learning toggle turns this off, learned entries can be reviewed and cleared, and undoing a banner rolls the matching records back. Speech recognition uses system services; on macOS, on-device-only recognition is available for supported languages and device, room, and scene names are passed as recognition hints.

To help prevent mistakes, risky actions such as turning on a heater, switching a plug, or starting a vacuum always wait for your confirmation, and low-confidence AI guesses wait as tap-to-run suggestions ("Ask me when unsure" is on by default on macOS). URL controls on macOS also ask first by default, with an option to enable direct control.

The macOS app is not yet notarized by Apple, so you may need to allow it in System Settings the first time; Windows may show a SmartScreen prompt. Both macOS and Windows verify in-app updates against an Ed25519-signed release manifest whose private signing key stays offline. See [ADR-0007](docs/adr/0007-lan-direct-deferred.md) for more on connection options.

Releases built by GitHub Actions carry build provenance attestations and SPDX SBOMs. See [verifying release artifacts](SECURITY.md#verifying-release-artifacts).

To report a vulnerability in private, follow [Security policy](SECURITY.md).

</details>

---

## Development & Architecture

- **Architecture:** The macOS version is written in pure Swift 6 with **no third-party Swift runtime dependencies**, adhering to strict concurrency rules. Core protocol handling and device synthesis live in `MijiaCore` with full headless test coverage. The Windows client is built with Tauri v2 (Rust + TypeScript + Vite).
- **Cross-Platform Consistency:** Both platforms run separate test suites against shared golden test fixtures in `Tests/Fixtures/` (intents, specs, regions, AI payloads) to prevent behavioral drift (see [ADR-0006](docs/adr/0006-dual-platform-implementation.md)).

### Local Build & Verification

```bash
# Run secret checks, linters, and Swift tests on macOS
bash scripts/check.sh

# Build, sign locally, and launch MenuBarHome.app
bash scripts/build_app.sh

# Build and test the Windows tray app
cd windows
npm install
npm test
npm run build
```

Please review [CODING_STANDARDS.md](CODING_STANDARDS.md) before submitting pull requests. Key domain concepts are documented in [GLOSSARY.md](GLOSSARY.md).

---

## Contributors

Thanks to everyone who has contributed features, fixes, and feedback:

- [@jryang2026-code](https://github.com/jryang2026-code) (一群小羊说) — Creator & maintainer
- [@almightyYantao](https://github.com/almightyYantao) (Alimighty.Yantao) — Multi-key Mesh switch split-device synthesis (GitHub #6, GitHub #7), multi-home switcher & light-group scene filtering (GitHub #8), visual skin system, inline climate module, drag-to-reorder layout & custom device groups (GitHub #9), macOS app bundle icon packaging (GitHub #10), panel drop-in animation, local device renaming & room-strip polish (GitHub #11), Windows feature parity and cross-platform UI fixes (GitHub #12), and redundant-write optimization for provider snapshots (GitHub #66)
- [@htx996](https://github.com/htx996) (han) — macOS status-item context menu with live/demo mode switching, dual-source status, and menu-safe click, hold-to-talk, and keyboard handling (GitHub #250)

## License & Acknowledgements

- **License:** Distributed under the [MIT License](LICENSE).
- **Third-Party Integrations:** This repository does not distribute third-party integrations. The optional Home Assistant scripts reference repositories: [xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home) and [midea_ac_lan](https://github.com/wuwentao/midea_ac_lan).
- **Trademarks:** "Xiaomi", "Mijia", and "Midea" are registered trademarks of their respective owners. Used here solely to indicate device compatibility.

Thanks to all contributors who have submitted PRs, reported issues, and helped refine the desktop smart home experience! If MenuBarHome helps you keep your hands on the keyboard, please give it a ⭐ Star on GitHub.

---

## FAQ

- [What if macOS Gatekeeper or Windows SmartScreen blocks the app, and how do I verify the download?](docs/faq.md#what-if-macos-gatekeeper-or-windows-smartscreen-blocks-the-app-and-how-do-i-verify-the-download)
- [How much memory and CPU does it use, and how do I measure it?](docs/faq.md)
- [What about Windows 11?](docs/faq.md#what-about-windows-11)
