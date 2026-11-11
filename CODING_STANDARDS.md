# Coding Standards

Reviewed by `/code-review` (Standards axis) and updated by `/retro`. Mechanical rules (secret scanning, `kVK_*` key constants, `UNUserNotificationCenter` `.app` bundle guard, `#require` macro nesting, `L10n.currentLanguage` assignment, `ThemeAndMotion.swift` glass isolation, Swift 6.4 tuple `await`, timer-callback `render()`, and Swift harness lints) are enforced deterministically by `scripts/check.sh`.

A review citation names the deciding symbol as `path:symbol` and quotes those lines (`HomeStore+ControlWrite.swift:lockOptimistic`).

## Domain Rule Slices (Auto-Loaded by Path)

Each slice below lives in `.claude/rules/` with `paths:` globs (loaded natively by Claude Code and injected via `.agents/hooks.json` when reading or editing matching files). During `/code-review`, read only the slices whose `paths:` intersect the diff:

1. [`.claude/rules/standards-synthesis-parity.md`](.claude/rules/standards-synthesis-parity.md) — **§1, §5, §6, §11**: HA registry exclusions before fallback, `MijiaCore` UI-free boundary & domain vocabulary, cross-platform golden corpora & AI provider parity, external payload replay & deterministic fuzzing (`MijiaCore` synthesis/intent/MiCloud, `windows/src/core/**`, `Tests/Fixtures/**`, `docs/capabilities.json`).
2. [`.claude/rules/standards-store-locks-timers.md`](.claude/rules/standards-store-locks-timers.md) — **§2, §7, §14, §15**: bidirectional optimistic lock on snapshot undo, `ScheduledCommand` persistence / `sourceScopes` / missed-timer confirmation, optimistic lock lifecycle, `BulkWriteOutcome` verdicts (`HomeStore*.swift`, `AssistantSchedule.swift`, `RaycastSnapshot.swift`, `LGWebOSClient.swift`).
3. [`.claude/rules/standards-macos-panel.md`](.claude/rules/standards-macos-panel.md) — **§3, §4, §8, §10, §12, §13**: Carbon global hotkey lifecycle, Control Center 12-column flow layout, macOS 14+ adaptive glass boundary, single-owner overlay geometry, conditional view snapshots, pending UI state clearing on every transition (`Sources/MenuBarMijiaApp/**`).
4. [`.claude/rules/standards-swift-tests.md`](.claude/rules/standards-swift-tests.md) — **§9**: tight non-racing timer & async tests, `HdiutilGate`, `L10n.$overrideLanguage`, `waitForTestSnapshot`, `repeat_test.sh` & `red-check.sh` (`Tests/**/*.swift`).
5. [`.claude/rules/standards-windows-ui.md`](.claude/rules/standards-windows-ui.md) — **§16**: Windows panel gesture deferral (`queueBackgroundRender` vs `proactive.ts` drop), unfocused destructive-hold guard, `hasDetailDrawer` parity (`windows/src/ui/**`, `windows/tests/**`).
6. [`.claude/rules/windows-camera.md`](.claude/rules/windows-camera.md) — Windows camera P2P 1-minute cooldown (`cameraKeepAliveMs`), `.255:32108` UDP broadcast relay, MJPEG without `#width=`, bundled LGPL FFmpeg + go2rtc, MSVC `build-win.bat` (`windows/src-tauri/**`, camera TS/workflows; full runbook in [`docs/agents/windows-camera.md`](docs/agents/windows-camera.md)).
