# Coding Standards

Reviewed by `/code-review` (Standards axis). Mechanical rules (secret scanning, `kVK_*` key constants, `UNUserNotificationCenter` `.app` bundle guard, and `swift test`) are enforced deterministically by `scripts/check.sh`. The rules below cover architectural and domain judgement calls.

A review citation names the deciding symbol as `path:symbol` and quotes those lines. `HomeStore+ControlWrite.swift:lockOptimistic` is one.

## 1. Entity Registry Exclusions Block State Fallbacks

When synthesizing Home Assistant entities in `Sources/MijiaCore/DeviceSynthesizer.swift` with a primary pass over `snapshot.entityRegistry` followed by a fallback pass over `snapshot.states`:

- Record every matched registry `entity_id` into the seen set (`seen...Ids`) **before** skipping `disabled_by != nil || hidden_by != nil` entries.
- Skipping before recording leaks disabled or hidden entities back into the UI through the `states` fallback loop.

## 2. Bidirectional Optimistic Lock on Snapshot Undo

When restoring a `previousDevices` snapshot in `HomeStore` (`UndoBanner` / `undoTurnAllOff`):

- Call `lockOptimistic(dev.id, duration: .seconds(3.0))` for **every device whose state differs** between current `devices` and `banner.previousDevices`.
- Locking only `where dev.isActiveOn` fails when undoing an action (such as `QuickAction.softNightLight`) that turned a previously-off device on, exposing the restored off-state to stale WebSocket frames.

## 3. System Global Resource Lifecycle

System-wide registrations (such as Carbon `RegisterEventHotKey` in `HotkeyAndNotificationManager`) must bind their active registration lifecycle to their preference toggle:

- Call `UnregisterEventHotKey` immediately when `enableGlobalHotkey` is set to `false`, and re-register when set to `true`.
- Leaving a global hotkey registered while ignoring the callback hijacks the key chord from other macOS applications.

## 4. CompactTile Two-Column Alignment

In `ControlCenterPanel` when `isCompactGridMode` is active:

- Devices with an open detail drawer (`expandedDeviceId == dev.id`) render as full-width `.single(dev)` rows (`isCompactTile: false`).
- Unexpanded devices render in two-column `.pair(left, right)` rows (`isCompactTile: true`). When an unexpanded tile has no partner, pair it with `nil` and render a half-width `Color.clear.frame(maxWidth: .infinity)` placeholder so single tiles never stretch full-width.

## 5. Domain Vocabulary & Single Source of Truth

- Keep `MijiaCore` free of `AppKit` / `SwiftUI` imports so all synthesis, optimistic locking, and store state remain fast-testable via `MockHomeProvider`.
- Align type and property names with [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/0001-ha-as-single-source-of-truth.md`](docs/adr/0001-ha-as-single-source-of-truth.md).
- `actionPolicy.ts:confirmationHazard` calls `deviceCategory` for the heater, plug, camera, and vacuum split, after returning early for a cover, an appliance, and a climate card named 热水器 whose model contains neither `heater` nor `blanket`. The four heater name words live in `deviceCategory.ts:HEATER_NAME_HINTS`. The macOS list is `CommandIntent.swift:IntentDeviceCategory` (`heaterNameHints`). A climate card is a heater when its model contains `heater` or `blanket`, or when its name contains one of those four words. A 热水器 whose name misses the four words stays `climate` only when the model also misses both substrings. `promptContext.ts:assistantDeviceCategory` keeps its own kind switch and calls `isHeaterDevice` and `isAirPurifierDevice`. The hotter-only hazard for the word 热水器 stays in `confirmationHazard`.
- The AI settings draft that chooses which saved key a preset switch keeps is `AssistantCommandBar.swift:AssistantSettingsDraft.selecting` and `AssistantSettingsDraft.configToSave`. The settings view applies the returned fields. `selecting` clears the address and the key when the next preset is 自定义. `configToSave` returns nil while that address is empty, and the save leaves the previous provider's key where it is.
- `HomeStore` is declared in `HomeStore.swift` and extended by the `HomeStore+*.swift` files, by `DeviceReadout.swift`, `UndoBannerPause.swift`, `RaycastControls.swift`, and `RaycastSnapshot.swift`, and by the test extensions in `Tests/MijiaCoreTests/SnapshotWait.swift`, `Tests/MijiaCoreTests/CoverLockWait.swift`, and `Tests/MenuBarMijiaAppTests/SnapshotWait.swift`. Before deleting a stored property, search every extension. A property one extension still reads is live.
- A behavior decision reads the state it acts on. `ManualControlPolicy.swift:facetRequiresConfirmation` compares a new target temperature with `facet.value`. `StatusItemEventDecision.swift:StatusItemEventDecision.decide` reads `State`. `PanelKeyRouter.swift:PanelKeyRouter.beforeSearch` reads `Context`. `PanelFoldLayoutTests.swift:PanelFoldMeasure.Reading.cardTop` is `cardMinY - panelMinY`. `reading` sets `cardMinY` from the first light card's `cardTops` entry.

## 6. Cross-Platform Golden Corpora & AI Provider Parity

When adding or changing spoken command, delay, undo, habit-memory, proactive-suggestion, MIoT synthesis, MIoT command mapping, or AI provider preset rules, or model confirmation rules, in `Sources/MijiaCore/LocalIntentParser.swift`, `Sources/MijiaCore/UserHabitMemory.swift`, `Sources/MijiaCore/AssistantSchedule.swift`, `Sources/MijiaCore/AssistantConfig.swift`, `Sources/MijiaCore/ModelActionPolicy.swift`, `Sources/MijiaCore/MiCloud/MiotSynthesizer.swift`, `Sources/MijiaCore/MiCloud/MiotCommandMapper.swift`, `windows/src/core/assistant.ts`, or `windows/src/core/miCloudClient.ts`:

- Add a representative test case to [`Tests/Fixtures/intent_golden.json`](Tests/Fixtures/intent_golden.json) or [`Tests/Fixtures/miot_golden.json`](Tests/Fixtures/miot_golden.json) so both `Tests/MijiaCoreTests/GoldenCorpusTests.swift` and `windows/tests/core.test.ts` assert the exact same behavior. AI provider preset rules (domain matching, which hosts may receive API keys) live in [`Tests/Fixtures/provider_golden.json`](Tests/Fixtures/provider_golden.json); Mi cloud region codes/order in [`Tests/Fixtures/region_golden.json`](Tests/Fixtures/region_golden.json); the Jev `/v1/systemone` request skeleton in [`Tests/Fixtures/ai_request_golden.json`](Tests/Fixtures/ai_request_golden.json); habit-memory record/unrecord and the Top-4 proactive engine in [`Tests/Fixtures/habit_golden.json`](Tests/Fixtures/habit_golden.json) — all asserted by `Tests/MijiaCoreTests/GoldenCorpusTests.swift` and …
- Keep `AssistantProviderPreset.allCases.map(\.rawValue)` (macOS) and `ASSISTANT_PROVIDER_PRESETS.map(p => p.id)` (Windows) identical in order and membership, and isolate user-saved API keys per provider (`KeychainHelper.assistantProviderAPIKeyAccount(for:)`).
- Never let one platform silently diverge on Chinese or English command parsing, delay limits (`<= 86400s`), unknown-word fallback (`nil` / `null`), MIoT `0`/`1` boolean coercion, multi-service property resolution, or command range/step clamping.
- GrokBall emotion priority and radial slot order live in [`Tests/Fixtures/grok_ball_golden.json`](Tests/Fixtures/grok_ball_golden.json), asserted by both `GoldenCorpusTests` and `windows/tests/core.test.ts`. Preserve the upstream MIT notice when updating the bundled engine or native geometry.
- [`Tests/Fixtures/air_quality_golden.json`](Tests/Fixtures/air_quality_golden.json) pins the purifier air-quality grade (raw grade word or PM2.5) that drives both the label and the card colour, asserted by `AirQualityLevelTests` and `windows/tests/core.test.ts`. Views map `AirQualityLevel.tone` to a colour; they never re-derive the grade.
- [`Tests/Fixtures/confirmation_golden.json`](Tests/Fixtures/confirmation_golden.json) is the shared confirmation table asserted by `GoldenCorpusTests` and `windows/tests/core.test.ts`.
- [`Tests/Fixtures/miot_coverage_golden.json`](Tests/Fixtures/miot_coverage_golden.json) pins how MIoT synthesis classifies one real public spec per device type (`miot_coverage_specs.json`), asserted by `MiotCoverageBaselineTests` and `windows/tests/miotCoverage.test.ts`. A synthesis change that moves a spec between categories must re-record it (`RECORD_MIOT_COVERAGE=1 swift test --filter MiotCoverageBaselineTests`); `windowsDivergences` lists the specs Windows still classifies differently, and must be pruned by hand when a Windows synthesis fix catches up (the recorder keeps the previous list). `miot_golden.json` also pins the generic-card summary (`genericCases`) and the 更多设置 control list (`facetCases`) for both platforms. Rows of [`docs/capabilities.json`](docs/capabilities.json) that carry `miotTypes` take both platforms' README status from this baseline (`scripts/check_capability_matrix.py`), so a re-record that matches or drops a listed type also updates that row in both READMEs.
- [`Tests/Fixtures/miot_facets.json`](Tests/Fixtures/miot_facets.json) is the hand-written rule fixture for generic facets (#303), asserted by `MiotFacetsTests` and `windows/tests/miotFacets.test.ts`; [`miot_facets_coverage_golden.json`](Tests/Fixtures/miot_facets_coverage_golden.json) pins facet membership over the `miot_coverage_specs.json` models. A rule change must update the hand-written case and re-record the golden (`RECORD_MIOT_FACETS=1 swift test --filter MiotFacetsTests`).

## 7. Scheduled Command Persistence & Missed-Timer Confirmation

When modifying `ScheduledCommand` or `HomeStore+Assistant.swift`:

- Persist both `scheduledCommands` and unconfirmed `missedScheduledCommands` to `UserDefaults` (`ScheduledCommand.storageKey`) on every schedule, fire, restore, confirm, dismiss, or cancel transition.
- Never auto-execute an expired timer silently on launch; keep it in `missedScheduledCommands` (and on disk across restarts) until the user explicitly confirms (`runMissedScheduledCommand`) or dismisses (`dismissMissedScheduledCommand`).
- The same applies after the Mac sleeps: `Task.sleep` keeps counting during sleep, so a timer task can wake up long after its `fireDate`. A timer that wakes more than `HomeStore.lateTimerGrace` (60 s) late goes to `missedScheduledCommands` instead of running. Tests simulate this with `assistantNow`.
- A timer records every source connected when it was created (ADR-0019). `schedule(_:after:)` writes `sourceScopes` from `activeConnectionScopes` and also the primary `sourceScope` for old builds; the effective stamp is `sourceScopes ?? sourceScope.map { [$0] } ?? nil`. One request stays one entry, so its undo record covers every target. `HomeStore.sourceScopesMatch` is the only rule, used by the firing guard, `restoreScheduledCommands` and `runMissedScheduledCommand`: the stamp and `activeConnectionScopes` must intersect, and every `ha:` scope connected now must appear in the stamp, because timer targets are merged card ids that an HA the timer never saw can claim. Removing HA still leaves the intersection, so Xiaomi timers survive its removal. Only matching entries are armed or shown; a save writes `foreignScheduledCommands` back so another source's entries survive, and firing re-checks the rule. `schedule` also refuses until `snapshotGeneration` has moved past the value `startListening()` recorded, so a stale device list is never stamped with the new sources, unless every target is a local LG card (LAN rows do not bump the generation; a plan mixing LG and cloud targets still needs the snapshot). Entries written before scopes existed are adopted once at `restoreScheduledCommands` when a primary scope is resolved. `startListening()` is the single re-partition point; `invalidateUndoContext()` runs before the switch and cannot decide it.
- `runMissedScheduledCommand` is a person acting now: the screen-lock guard runs before the entry leaves the list, so a refused run can be retried. A timer firing on schedule stays exempt (#143). The entry is removed and persisted only after `waitForInitialSnapshotIfNeeded()` and a second scope/lock check; a refusal at any point keeps it. That wait only runs while `devices` and `scenes` are both empty (about 5 s), so it is not proof of a complete snapshot; the target check below covers a partial list. After the wait, re-find the entry by id and keep the existence check, the removal and the persist in one stretch without an `await`, so a dismissed, cancelled or already-taken entry makes the waiter exit instead of executing.
- A timer is consumed only after its plan can actually run: `missingPlanTargets(_:)` must be empty, otherwise the firing path sends the entry to `missedScheduledCommands` and the manual path refuses it. Selecting another Mi Home does not change the captured source set (same account), so the device list is the only evidence that the target is here. A plan with no device targets has none missing.
- Once the scope, lateness and snapshot checks pass and `missingPlanTargets(_:)` is empty, the firing task removes the entry id from `scheduledCommands`, `missedScheduledCommands` and `foreignScheduledCommands` and persists in one stretch without an `await`, then executes. A source switch during the in-flight request re-partitions from disk, so an entry still there would be armed or missed again and could run twice; crashing mid-execution loses the timer instead, which is the safer failure for hardware. Completion only clears `scheduledTasks[id]` when `scheduledTaskTokens[id]` still belongs to that run, so it cannot detach a re-armed task.

## 8. macOS 14+ Adaptive Glass Boundary

- Isolate macOS 26 `.glassEffect(` and `GlassEffectContainer` calls inside `Sources/MenuBarMijiaApp/ThemeAndMotion.swift` (`View.adaptiveGlass` and `AdaptiveGlassContainer`), guarded by `#available(macOS 26.0, *)` with Material fallback for macOS 14 and 15. Enforced mechanically by `scripts/check.sh`.
- `ThemeAndMotion.swift:GlassSwitchToggleStyle.showsLabel` hides the toggle's own label when `glassLabelHidden` or `labelsHidden` is true. macOS 14 has no `labelsVisibility`, so `GlassSwitchLabelHost` passes `labelsHidden: false`. A row that already has its own title calls `View.glassLabelHidden()` before `.toggleStyle(.glass)`. `AssistantCommandBar.swift` and the child-lock toggle in `DeviceCardView.swift` use `.toggleStyle(.glass)` without `glassLabelHidden()`, because that label is the only title.

## 9. Tests Must Not Race Product Timers

When a test asserts on state that a production timer can change (undo banner expiry, scheduled commands, cooldowns, polling):

- Freeze the timer through an existing seam (`HomeStore.pauseUndoBannerCountdown()`, `assistantNow`, `controlDebounceInterval`), or
- Poll a deterministic signal that the path under test actually produces. When the failure path records nothing, the reliable signal is "the timer is frozen and the assertion runs immediately", not a spin on a success-only collection.

A wall-clock sleep before the assertion is the failure mode: on a loaded CI runner the sleep stretches past the timer's expiry, so the assertion fails nondeterministically while passing locally. This shipped once: `failedQuickActionRecordsNothing` spun on `executedCommands` (empty on failures) for 18 s in CI, past the 10 s banner expiry.

The same rule covers a test that needs to observe an intermediate state. Hold the seam open and release it from the test (`setGetPropsHook` fed by an `AsyncStream`, `GatedUndoProvider.release()`, `readBackEchoHold`) instead of sleeping for the state to appear; a sleep long enough to see the state on this machine is a coin flip on a loaded runner. See `initialSnapshotWaitsForEveryAccount` and `wakeFromSleepWaitsForAllAccountsBeforeClosingAwayGap` in `MiAccountsProviderTests` for the gated form.

- Assert a toast that must still be on screen after setting `HomeStore.toastAutoDismissInterval` to `nil`. `HomeStore.toastDismissInterval(for:)` then returns nil, including for an error. `PanelHealthTests` does this before expecting the frozen notice. Assert an in-flight row while the gate is still closed (`MockHomeProvider.holdNextExecute`, `HomeStore.pauseUndoBannerCountdown`).
- A value the production path reads after an `await` needs a test that changes it during the wait, including cancel and a second waiter. `HomeStore+Assistant.swift:runMissedScheduledCommand` re-reads `missedScheduledCommands` after `waitForInitialSnapshotIfNeeded`. `ScheduledCommandScopeTests` covers dismiss, cancel, and two waiters. `HomeStore+Undo.swift:undoTurnAllOff` re-reads `optimisticLockRevision` after `batchTask.value`. `BulkWriteRollbackTests.undoWaitSkipsDeviceANewerBatchTook` takes the row while `holdNextExecute` is held.
- "Still in flight" is a counter the path increments. `ScheduledCommandScopeTests.waitUntil` polls `SleepGate.waiting`. A fixed `Task.yield` count is not that counter. `failureAfterUndoStaysSilent` and the missed-run tests still use one.
- `UpdateCheckerTests.HdiutilGate` serializes `hdiutil` attach. Swift Testing runs repetitions in parallel, and two attaches at once are what `hdiutil` answers with "Resource temporarily unavailable".
- `L10n.currentLanguage` is process-wide. `@Suite(.serialized)` serializes that suite only. `PanelFoldMeasure.reading` assigns the language and restores it with `defer` before it returns. Parallel tests use `L10n.$overrideLanguage.withValue`. `CameraPTZDriverTests` is `@Suite(.serialized)` because it uses `CameraLivePanelController.shared`.
- After `HomeStore.startListening()`, call `HomeStore.waitForTestSnapshot()` before treating `devices` as the new home. Assign a row the test invents after that wait. The snapshot replaces an unlocked row. `applyLGDeviceUpdate` sets `latestLGDevice` and updates the row when the TV is enabled and configured and the home is not in demo mode. It removes the row when that guard fails. An all-LG `schedule` is the exception already in §7. `startListening` records `listeningSnapshotGeneration` and returns.
- A PTZ stop test asserts the motor calls. `CameraPTZDriverTests` expects `FakePTZClient.recordedStops` together with `CameraLivePanelController.ptzUnresolvedStops`.

## 10. Overlay Geometry Has One Owner

Placement math that reserves space and the view that draws inside it must read the same dimensions:

- Pill sizes and spacing live once beside the content (`GrokBallSuggestionMetrics`); placement math derives its column, row, and footprint from them instead of repeating literals like 132, 44, 206, and 558.
- A view never hardcodes a size the placement reserves. When the two drift apart the content clips silently: #123's English empty state needed 65 pt inside a 44 pt row.
- Empty and fallback states fill the reserved width (`.frame(maxWidth: .infinity)`) so they reflow instead of assuming a fixed column.

## 11. External Payload Replay & Deterministic Fuzzing

External payloads (Mi cloud responses, MIoT instance JSON, Home Assistant WebSocket frames, go2rtc MP4 bytes) are untrusted and change without notice:

- Sanitised recordings live in `Tests/Fixtures/contracts/`. Each fixture carries a `_fixture` object with its endpoint, capture date and sanitisation note; identifiers, names, MAC addresses and IP addresses are synthetic. Addresses use TEST-NET ranges (`192.0.2.0/24`), never a real LAN.
- `ContractReplayTests` decodes each fixture and asserts the exact stable fields the app consumes. When the upstream shape changes, update the fixture and the assertions together; never weaken an assertion to make a changed payload pass.
- Fuzz tests use `SeededFuzzGenerator` with a fixed base seed and bounded iterations, and print `seed=<n> iteration=<n> input=<hex>` in every failure message. They must finish in milliseconds so the normal `swift test` suite keeps them.
- A fuzzer that finds a trap ships with the fix and a minimal regression case (see the `tfhd` / `trun` short-payload and huge-number cases). Production code must not convert external numbers with trapping initialisers: use `Int(exactly:)` / `DeviceSynthesizer.roundedInt` and degrade to "no reading" when out of range.
- A separate libFuzzer target is intentionally not wired into SwiftPM. The parsers are pure functions with deterministic seeds already reproducible on macOS and Linux; libFuzzer would add an LLVM-only build path without covering more code. Revisit only if a parser starts consuming non-deterministic process state.

## 12. A Conditional View Ships With Its Snapshot

A view that appears only in some state (a banner, a prompt, an empty or error state) ships with a snapshot case that puts the store into that state. Existing baselines never render it, so the `no-snapshot-change` label is wrong for it even though no current PNG changes.

The snapshot is the check that the layout holds: the plaintext-consent banner (#276) truncated its reason on one line until its own snapshot showed it. Reserve `no-snapshot-change` for changes that alter no visible state at all.

## 13. Pending UI State Ends on Every Transition

State that waits on the user or a timer (a consent prompt, an auto-dismiss timer, a window a ring opened) has an owner and an end. For each such field, check every path that can supersede it:

- **Backend switch.** Entering demo mode or rebuilding the provider clears a consent prompt and a persistent toast, and a late callback from the replaced provider is ignored. An ordinary toast already showing keeps its timer. #276 shipped a consent banner whose 仍然连接 rebuilt the live backends while the app said demo.
- **User takeover.** A window or session the user opened, kept or moved into picture-in-picture belongs to the user; automation never moves, switches or closes it. #308 needed this three times: a ring hijacked an open camera view, a later ring re-armed auto-close after picture-in-picture, and a restore was closed by an old timer.
- **Repeat and stale events.** A repeated event renews what it owns or does nothing; an event about an older head, address or timestamp is ignored.

Name the clearing site for each new field in the diff. A field set in one place and cleared nowhere is the defect.

The expired-session prompt is one of these fields. `HomeStore.swift:showToast` lets an ordinary toast replace it, and sets `isSessionToastSuspended`, when the new notice is not persistent, `miSessionBlocksControl` is true, and the current notice is persistent with action `.presentMiReauth`. The ordinary toast stays visible because it can be a real error, such as a keychain write failure. `HomeStore.restoreSuspendedSessionToast` puts the prompt back on `toastNotice` when the ordinary toast ends, while `miSessionBlocksControl` is still true. `ControlCenterPanel.visibleToast` returns nil when `panelNoticeSlot` repeats that toast, so the panel draws the blocked notice once. Settings reads `store.toastNotice`. While a prompt is suspended, `showToast` returns without showing another persistent toast. `HomeStore.invalidateUndoContext` sets `isSessionToastSuspended` to false and dismisses a persistent toast. An ordinary toast already in the slot stays until it ends.

## 14. Optimistic Lock Lifecycle

`HomeStore+ControlWrite.swift:beginOptimisticWrite` assigns the row when `updated` is on screen. It calls `lockOptimistic` only when `lock` is non-nil. The caller sends after that returns. Quick actions, 全关, undo, and a cover tap pass a duration. `commitManualWrite` passes through the duration its caller gives it. `runApplianceAction` passes nil. `HomeStore+Controls.swift:togglePrimary` sends a non-cover with no lock. `confirmToggleReadBack` calls `lockOptimistic` after that send succeeds, for a LAN TV and for an unavailable property read. A published read does not call `lockOptimistic`. A cover is locked before the send, and `confirmToggleReadBack` calls `lockOptimistic` again for 8 seconds, which bumps the revision.

- `optimisticLockRevision` increases in `HomeStore+ControlWrite.swift:lockOptimistic` and in `HomeStore+Backend.swift:handleProviderEvent` when `backendChanged` is true. That same branch removes the id from `optimisticLockUntil`. Adopting a snapshot or an LG report on any other branch removes the id from `optimisticLockUntil` and leaves the revision unchanged. `HomeStore+Undo.swift:runBatchCommands` then still sees `ownsRow` for that write, and the batch still sends the command.
- A locked row that is present in the snapshot keeps the local device while the lock instant is in the future, a local row exists, and read-back does not need the snapshot. A locked id the snapshot omits leaves `devices`, except the `latestLGDevice` insert. The snapshot replaces a locked non-cover when a primary-toggle read-back is in flight (`waitingDeviceIds` or `ReadBackTickets.isInFlight`). `HomeStore+Controls.swift:togglePrimary` is the caller of `readBackTickets.claim`. A cover forces `readBackNeedsSnapshot` false, so a locked cover that is in the snapshot stays until `coverTravelTakesOver` returns true or `optimisticLockUntil` passes.
- Adopting a reported device row removes that id from `optimisticLockUntil`. In `handleProviderEvent` the sites are the `backendChanged` branch, the branch that appends `incoming` when `coverTravelTakesOver` returns true, the other branch that appends `incoming`, and the `latestLGDevice` insert when that lock is missing or expired. `applyLGDeviceUpdate` removes the id when the lock is missing or expired. It leaves the id in place while the instant is still in the future. It drops the row when the TV is disabled, the home is in demo mode, or the host is not configured. The 更多设置 merge copies `snapshot.deviceFacets` for a locked cover while `waitingDeviceIds` or `ReadBackTickets.isInFlight` contains that id. After the toggle task finishes the ticket, a locked cover keeps the local facet rows. The card lock stays.
- `HomeStore+Undo.swift:revertRefusedBatchWrites` restores a refused device when `optimisticLockUntil` still contains the id, then `HomeStore+ControlWrite.swift:revert` requires `ownsRow`. An expired instant still counts. After a report removes the entry, `revertRefusedBatchWrites` skips that device and the reported row stays. `rollbackFailedUndoDevices` and a failed `send` call `revert` directly. `revert` checks `ownsRow` and does not read `optimisticLockUntil` first. The cover failure arm in `togglePrimary` checks both.
- `revert` removes the lock entry. `togglePrimary` stores an unexpired lock it is about to replace in `coverPriorLockUntil`. On a failed cover send that still `ownsRow` and still has a lock entry, it calls `revert`. It writes `coverPriorLockUntil` back only when that stored instant exists. It writes `coverOrigin.prior` back into `coverCommandOrigins` only inside that same write-back.
- `undoTurnAllOff` extends `optimisticLockUntil` to `HomeStore.undoWaitLockCeiling` (120 seconds) while it waits for the in-flight batch, without a new revision. After the wait, a row it still owns returns to a 3 second lock.

## 15. Bulk Write Results

`HomeStore+Undo.swift:BulkWriteOutcome` is the verdict `executeQuickAction` and `turnAllOff` return.

- A device that accepted at least one command and is not in `takenOverDeviceIds` stays on screen and stays in the undo banner. `refusedDeviceIds` is the failed devices with no entry in `acceptedByDevice`. A device skipped because `ownsRow` is false is in `takenOverDeviceIds`, including one that accepted an earlier command in the same batch. `revertRefusedBatchWrites` calls `revert` when the lock entry remains. `revert` then requires `ownsRow`, so a lock that belongs to a newer write does not put the old row back. `trimUndoBanner` drops `refusedDeviceIds` and `takenOverDeviceIds`. A device in `takenOverDeviceIds` leaves the banner with the newer write's row.
- `takenOverDeviceIds`, or any `failedDeviceIds` when `sessionRefusedDeviceIds` is empty, returns `.partial`. A non-empty `sessionRefusedDeviceIds` returns `.refusedByMiSession` even when another device was taken over. `runBatchCommands` returns nil when `controlContextID` has moved or the batch `isStopped`. The task then returns `.partial` before `revertRefusedBatchWrites`, `trimUndoBanner`, and `showBatchWriteFailure`.
- `RaycastSnapshot.swift:executeBuiltInURLScene` reports a quick action and 全关 with `BulkWriteOutcome.externalResult` after `task.value`. The undo case reads `toastNotice` after `undoTurnAllOff`. Undo does not return `BulkWriteOutcome`.
- `HomeStore+ControlWrite.swift:executeDeviceCommand` throws `MiSessionWriteBlocked` immediately before `provider.execute` when the Mi session blocks the write. An LG entity with `lgWebOSClient` goes to `lgClient.execute` and skips that throw. `executeQuickAction` returns `.refusedByMiSession` before it builds rows when `rejectWritesBlockedByMiSession()` is true. Its targets are Mi rows. `turnAllOff` returns `.refusedByMiSession` before it builds rows when `lgClientServes` is false for every target and the session blocks writes. A batch that mixes an LG target with a Mi target sends the LG commands.

## 16. Windows Panel Interaction

- A background timer that refreshes panel chrome calls `windows/src/ui/app.ts:MenuMijiaWindowsApp.queueBackgroundRender`. That method calls `render` when `hasBlockingPanelInteraction` is false, and otherwise sets `pendingCloudRender` for `appLifecycle.ts:startTimerLoop` to apply on a later tick. `setPendingHighRisk` and `syncUndoBannerClock` use it. In `cloudRefresh.ts`, a structural update calls it. A refresh the user is waiting on calls `render` directly. `startTimerLoop` calls `render` directly when `lastUndoAction` has expired, when `processScheduledCommands` reports a storage failure, when the missed-command list length changes, and on every tick while `scheduledCommands` is non-empty. The camera keep-alive timer calls `cameraLive.ts:closeCameraLiveView`, which calls `render`.
- The All Off hold fires from `app.ts:bindAllOffControl` when the button is connected and `document.hasFocus()` is true. A `window` `blur` calls `cancelAllOffHold`. The button's own `blur` clears the timer.
- `deviceViews.ts:renderDeviceTile` and `renderClimateStrip` draw the chevron when `windows/src/core/models.ts:hasDetailDrawer` is true. The body click expands a non-camera card when that function is true. A camera body click opens the live view without it. The chevron click toggles `expandedDeviceId` without calling `hasDetailDrawer` again.


