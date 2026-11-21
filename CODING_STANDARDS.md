# Coding Standards

审阅与编码规范总纲。引用证据时以 `path:symbol` 标注决定性符号并摘出关键行（如 `HomeStore+ControlWrite.swift:lockOptimistic`）。

> **机械检查已由 `scripts/check.sh` 自动拦截（不在此赘述）**：密钥与私网扫描、Git 提交账号与镜像远端推送、`UNUserNotificationCenter` `.app` 守卫、`.glassEffect` 隔离、`L10n.currentLanguage =`、`#require` 嵌套、元组内联 `await`、双端 Ed25519 公钥一致性，以及按需/全量的工作流 `actionlint`、Windows 面板几何、PTZ 型号表与能力矩阵同步。

---

## §1. HA Registry Exclusions Block State Fallbacks

In `DeviceSynthesizer.swift` (`entityRegistry` primary pass -> `states` fallback pass), record every matched `entity_id` into `seen...Ids` **before** skipping `disabled_by != nil || hidden_by != nil` entries so hidden/disabled entities never leak back via `states`.

## §2. Bidirectional Optimistic Lock on Snapshot Undo

When restoring `previousDevices` (`UndoBanner` / `undoTurnAllOff`), call `lockOptimistic(dev.id, duration: .seconds(3.0))` for **every device whose state differs** between current `devices` and `banner.previousDevices`, not only `where dev.isActiveOn` (otherwise undoing a turn-on exposes the off state to stale WebSocket frames).

## §3. System Global Resource Lifecycle

Bind system-wide registrations (`HotkeyAndNotificationManager` Carbon `RegisterEventHotKey`) strictly to their toggle: call `UnregisterEventHotKey` immediately when `enableGlobalHotkey` becomes `false`, and re-register when `true`.

## §4. Control Center 12-Column Flow Layout

In `ControlCenterPanelLayout.swift:spans(for:)` and `DeviceLayout.swift:TileFlowLayout`, `3` = 1×1, `6` = 2×1/2×2, `12` = 4×1/full-row. Expanded drawer (`expandedDeviceId == dev.id`) transiently takes `12` (`isCompactTile: false`). Without custom order, pack sub-row tiles (`span < 12`) before full-row modules (`span == 12`).

## §5. Domain Vocabulary, Core Boundary & Decision Inputs

- Keep `MijiaCore` free of `AppKit` / `SwiftUI` imports (must build on Linux via `scripts/linux-check/run.sh`). Align domain names with [`GLOSSARY.md`](GLOSSARY.md).
- Before deleting a stored `HomeStore` property, search every `extension HomeStore`, including files not named `HomeStore+*`.
- A climate card is heater when model has `heater`/`blanket` or name has `电暖`/`暖气`/`取暖`/`暖风`; 热水器 stays `climate` unless model matches (`deviceCategory.ts:isHeaterDevice`, `CommandIntent.swift:IntentDeviceCategory`).
- Custom AI preset selection must latch disclosure flags (`showsCustomEndpointFields` / `showsAdvanced`) on explicit picker selection rather than deriving from live URL text, so typing `http://localhost:11434` keeps fields mounted and switching to custom never saves the previous provider's host with an empty key.
- Decisions read the exact changing value, not a wrapping container (`ManualControlPolicy.facetRequiresConfirmation`, `StatusItemEventDecision.decide`, `PanelKeyRouter.beforeSearch`, `PanelFoldMeasure.Reading.cardTop`).

## §6. Cross-Platform Golden Corpora & Credential Slot Parity

- `PanelTheme` (`.classic` default, `.liquidGlass` macOS 26+) is macOS-only; share control/search/keyboard/layout prefs while keeping presentation separate.
- Any change to intent parsing, delay (`<= 86400s`), unknown fallback (`nil`/`null`), MIoT `0`/`1` coercion, confirmation rules, habit memory, proactive top-4, AI provider presets/Jev skeleton, region order, or air quality grade must update the shared golden fixtures (`Tests/Fixtures/*_golden.json`, `miot_facets.json`, `docs/capabilities.json`) and keep `GoldenCorpusTests.swift` + `windows/tests/core.test.ts` / `miotCoverage.test.ts` / `miotFacets.test.ts` in lockstep.
- Keep `AssistantProviderPreset.allCases` and `ASSISTANT_PROVIDER_PRESETS` identical in order and membership. Migrate credential slots two-phase per owner (pin legacy owner -> `await` replacement write -> only then delete legacy entry; isolate migration errors; store `custom` host binding separately in `assistantCustomKeyEndpoint`).
- One device type per card: `deviceCategoryForDevice` (Windows) and `DeviceKind.capabilityCategoryID` (macOS) must answer the same `DeviceCategoryID` for the same input (MIoT service or HA entity domain — never a name or a live value; each end keeps its own card shape), and `DEVICE_CATEGORY_PRESETS` / the Swift twin must return the same lists — a wall switch that drives a lamp stays a `plug` card in both. Change them together with `capability_selection_golden.json` `deviceTypeMapping`; Windows asserts it in `windows/tests/deviceTypeMapping.test.ts`, macOS reads the same cases from `GoldenCorpusTests.swift`. The leak and zero-write cases there are fixed assertions: closing the sensor type keeps the flood read and the alert, and a hidden target is rejected with zero writes.
- Re-record MIoT fixtures via `RECORD_MIOT_COVERAGE=1 swift test --filter MiotCoverageBaselineTests` / `RECORD_MIOT_FACETS=1 swift test --filter MiotFacetsTests` and prune caught-up `windowsDivergences` manually.
- Multi-key wall switches inherit parent panel rooms; per-home fallback (`appendMissingDids` / `appendMissingRoomDids`) must skip records whose `splitParentDid` already belongs to a named room.

## §7. Scheduled Command Scope & Single-Owner Async Commit

- **单主生命周期 (single-owner async commit)**：跨 `await` 后必须按 `id` 重新查找条目，并在**同一段无 `await` 的同步区间**内完成存在性核查、移除与 `UserDefaults` 持久化，严禁缓存 `await` 前的索引/引用直接执行硬件动作。
- Persist both `scheduledCommands` and `missedScheduledCommands` (`ScheduledCommand.storageKey`) on every transition. Never auto-execute missed timers silently (including wake-from-sleep > `HomeStore.lateTimerGrace` 60 s); require explicit `runMissedScheduledCommand` or `dismissMissedScheduledCommand`.
- `sourceScopes` (`ADR-0019`): `schedule(_:after:)` stamps active scopes after `snapshotGeneration` advances past `startListening()` (all-LG LAN plans exempt). `HomeStore.sourceScopesMatch` requires non-empty intersection AND every active `ha:` scope present in the stamp. Preserve `foreignScheduledCommands` across saves; re-partition only at `startListening()`.
- Firing/manual paths also check `missingPlanTargets(_:)` is empty; on `runMissedScheduledCommand`, run the screen-lock guard **before** removing the entry so refusals remain retryable. Completion clears `scheduledTasks[id]` only if `scheduledTaskTokens[id]` still matches.

## §8. macOS 14+ Adaptive Glass Boundary

Isolate `.glassEffect(` and `GlassEffectContainer` inside `Sources/MenuBarMijiaApp/ThemeAndMotion.swift` (`#available(macOS 26.0, *)` with Material fallback for 14/15). Hide the glass toggle's own label (`glassLabelHidden`) when the row already has a title (`GlassSwitchToggleStyle.showsLabel`).

## §9. Tight Non-Racing Swift Tests & Snapshots

- Use [`StateTestSupport.awaitState`](Tests/StateTestSupport/AwaitState.swift) for observable state transitions and set a suite time limit.
- Never sleep against product timers (`Task.sleep(for: .milliseconds(...))` or fixed `Task.yield` loops); freeze timers (`pauseUndoBannerCountdown`, `toastAutoDismissInterval = nil`, `assistantNow`, `controlDebounceInterval`) or gate intermediate state deterministically (`AsyncStream` hooks, `SleepGate.waiting`, `FakePTZClient.recordedStops`).
- Snapshots compare with `SnapshotAssertion.Tolerance` (3 of 255 per channel, 96 pixels free), not byte for byte. The budget covers glyph-edge rounding on the reference renderer. Never loosen it to hide a different OS, Xcode, or a real layout change. Re-record instead. Any text or clock that reads the real date (`Text(date, style: .relative)`) must be pinned in the test (`activityTimestampOverride`), because tolerance cannot absorb a changing string.
- Use `L10n.$overrideLanguage.withValue` (never global `L10n.currentLanguage =`). Call `waitForTestSnapshot()` after `startListening()`. Serialize `hdiutil attach` tests on `UpdateCheckerTests.HdiutilGate` (retry once on `Resource temporarily unavailable`). Wait for camera diagnostics `streamSource != nil` with a 30s `ContinuousClock` deadline.
- The reference renderer is GitHub-hosted `macos-26-intel` with Xcode 26.6 and the `zh_CN` metric locale. `macos-test` in `.github/workflows/ci.yml` runs both unit tests (`--skip SnapshotTests`) and pixel comparisons (`--filter SnapshotTests`) in one hosted job and uploads `snapshot-failures` on mismatch.
- `bash scripts/record_snapshots.sh` (`--dry-run` lists changes) records snapshot baselines. `bash scripts/check.sh` skips the pixel compare locally; `bash scripts/check.sh --snapshots` runs it as an advisory check. `SnapshotFixture` defaults `has_completed_onboarding = true`.

## §10. Overlay Geometry Has One Owner

Share pill sizes and spacing from content metrics; views never hardcode dimensions reserved by placement math, and fallback/empty states use `.frame(maxWidth: .infinity)` to reflow cleanly.

## §11. External Payload Replay & Deterministic Fuzzing

Sanitized contract recordings in `Tests/Fixtures/contracts/` use synthetic IDs and TEST-NET `192.0.2.0/24` IPs (update fixture + assertions together when upstream changes; never weaken assertions). Fuzz tests use `SeededFuzzGenerator` (millisecond budget, print `seed=`, `iteration=`, `input=`). Production parsers never trap on external numbers (`Int(exactly:)` / `roundedInt` / `.magnitude`).

## §12. Core Main-Screen Snapshots Policy

Keep `SnapshotTests` focused on ~20 core main-screen layouts (control center panel, primary device drawers, onboarding, and settings tabs). Do not add dedicated PNG snapshot baselines for every transient toast, conditional banner, or edge-case prompt; test transient state transitions via deterministic unit assertions.

## §13. Pending UI State Ends on Every Transition

Pair every pending UI field, toast, consent banner, activity row, hover/expansion flag, or automation-opened window with explicit clearing across backend switch (`invalidateUndoContext()`), panel hide, user PiP/window takeover, and stale events; name the clearing site in diffs. Note `rebuildLiveProvider` (e.g. `allowHAPlaintext`) intentionally skips `invalidateUndoContext` unless resetting home context; `recentSafetyAlerts` caps at 10 newest records/id and drops orphaned devices on accepted snapshots; transient hover re-evaluates on every collection change (`TransientStackExpansion.isExpanded`).

## §14. Optimistic Lock Lifecycle

- Per-field/per-facet ownership (`Sources/MijiaCore/HomeStore+ControlWrite.swift:ownsRow` L743-752, `revert` L774-823, `revertManualSessionPatch` L624-633): `beginOptimisticWrite` (L651-721) and `commitManualWrite` (L868-1024) create timed `optimisticFieldLocks` leases only when `lock != nil` (covers lock before & after send), whereas any shown write mutating fields (`!fields.isEmpty`) still advances `optimisticFieldRevisions` and `optimisticLockRevision` even when `lock == nil` (L701-708, L954-958) so an older failed write cannot roll back over a newer write on the same field while disjoint fields/facets roll back independently.
- Six sites advance `optimisticLockRevision`: `lockOptimistic` (L313-314), `lockOptimisticFacet` (L342-346, when `bumpDeviceRevision` is `true`; also updates `optimisticFacetRevisions`), `clearManualWriteSession` (L425-427, when `bumpRevision` is `true`), `beginOptimisticWrite` (L693-703), `commitManualWrite` (L954-955), and `backendChanged` during snapshot adoption (`Sources/MijiaCore/HomeStore+Backend.swift:handleProviderEvent` L317-324, after `clearOptimisticRevisions`).
- Ordinary snapshot adoption (`!backendChanged`), lease expiry (`pruneExpiredOptimisticLocks` L250-267), non-cover read-back (`readBackNeedsSnapshot` L336-347), `coverTravelTakesOver` (L200-223, L349-359), and `HomeStore.undoWaitLockCeiling` (`Sources/MijiaCore/HomeStore+Undo.swift` L537, L780-796, 120s lock extension then 3s relaxation) never advance revisions. Locked fields/facets remain visible only while present in snapshots (or `latestLGDevice` / local row), unexpired, and not superseded by non-cover read-back or confirmed cover travel.

## §15. Bulk Write Results

`executeQuickAction` / `turnAllOff` return `BulkWriteOutcome`: owned accepted devices stay in the undo banner; devices taken over by newer writes leave the older batch's banner; Mi-session refusal returns `.refusedByMiSession`; partial/taken-over/stopped batches return `.partial` (stopped batches never overwrite undo); expired Mi sessions never block live LG targets (`executeDeviceCommand`).

## §16. Windows Panel Interaction & Camera Packaging Guardrails

- Background refreshes defer via `MenuMijiaWindowsApp.queueBackgroundRender` during gestures (`hasBlockingPanelInteraction()`); proactive results render only when idle and **drop** (never defer) during gestures (`proactive.ts`).
- Destructive holds (`bindAllOffControl`) must abort if unfocused; restoring unsaved Settings drafts reconciles `#settings-api-key` via `syncKeyFieldWithEndpoint`; `mountTestWindow()` fails unstubbed `fetch` in 1 ms.
- **Subpage & Keyboard Routing (`deviceViews.ts`, `panelKeyboard.ts`, `app.ts`)**: split-pill left half (`[data-toggle-device]`) toggles power directly while the right chevron (`[data-expand-device]`) opens the in-place subpage. Keyboard shortcuts (`Escape` stack pop before search clear, `1`–`9` room jumps, arrow navigation, `Ctrl+F`/`/` search focus) must check `expandedDeviceId` / subpage state and active room/kind/search filters. `PANEL_HEIGHTS` (`580`, `680`, `780`) defines outer Tauri HWND logical heights including `2 * PANEL_PADDING` (`16px` `#app` shadow inset).
- **Keyed DOM Reconciler (`reconciler.ts`, `bindEvents.ts`)**: `PanelRenderPipeline.commitRender` reconciles keyed controls in place; bind panel events once on the root via delegation or `RenderEventScope` (`scope.on`), never raw `addEventListener` on reconciled child nodes.
- **Windows Camera (`docs/agents/windows-camera.md`)**: enforce 1-minute P2P cooldown (`cameraKeepAliveMs` 120s — hide modal/`<img>` rather than tearing down bridge immediately), serialize `start/stop_xiaomi_camera_bridge` via `CAMERA_BRIDGE_LOCK` + `liveCameraToken`, keep `.255:32108` UDP relay, MJPEG `<img>` without `#width=` (`error` log level), bundled `camera-bin/README.md`, and MSVC `windows/build-win.bat` (GNU `tar` on MSYS2 uses `cygpath -u` + `--force-local`).

---

## §17. Settings Save Model

Switches, pickers and sliders in Settings apply at once. A text form that carries a credential or triggers a reconnect (the Home Assistant address and token, the AI service) is saved explicitly, and it registers with `SettingsUnsavedChanges` so an unsaved edit is flagged with "有未保存的更改" and is never dropped silently: switching pages offers Save / Discard / Cancel, and closing the window (`windowShouldClose`) offers the same three. A form's `save` returns `false` when nothing was stored (a refused Keychain write, a missing address) so the edits stay flagged; an automatic suggestion (a LAN-discovered address) moves the baseline instead of counting as an edit.

## §18. Text Size And Labels

Secondary text is at least 11 pt (the first-run guide uses 11 / 11.5, not 10 / 10.5). Text that states a limit, a risk or a consequence (an unofficial API, a plaintext token, an expiring sign-in) is at least 12 pt (`DesignTokens.TypeSize.caption`) and uses the primary colour or a warning tint, not secondary grey. Every icon-only button needs both `accessibilityLabel` and a hover help (`help` / `panelHelp`). Explanatory text in Settings and onboarding uses `DesignTokens.secondaryText`, not the system `.secondary`: rendered snapshots show `.secondary` at about 3.4:1 on white in light mode (WCAG AA body text needs 4.5:1), while `secondaryText` measures about 4.9:1 light and 6.4:1 dark. Measure rendered pixels in the snapshot baselines before claiming a contrast result.

## Tooling Quick Reference

- **App icons**: editing `Resources/AppIcon/AppIcon-*.svg` -> `swift scripts/generate_app_icon.swift`
- **Local macOS install**: `bash scripts/install_local_app.sh` (installs rollback-safe `.app`; `build_app.sh` builds in-tree only)
- **Single Windows test**: `node windows/scripts/test-file.mjs tests/<file>.test.ts`
- **Windows flyout layout & screenshot check**: `npm --prefix windows run verify:ui` (`-- --out-dir <dir>`)
