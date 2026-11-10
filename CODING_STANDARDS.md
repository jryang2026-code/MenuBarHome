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
- A climate card is a heater when its model contains `heater` or `blanket`, or its name contains 电暖, 暖气, 取暖, or 暖风. A 热水器 stays `climate` only when the model misses both substrings. Owners: `deviceCategory.ts:isHeaterDevice`, `CommandIntent.swift:IntentDeviceCategory`. `assistantDeviceCategory` calls `isHeaterDevice` and keeps its own kind switch. `confirmationHazard` applies the hotter-only hazard to that climate 热水器 before `deviceCategory`. Pinned by `windows/tests/facetPolicy.test.ts` ("uses the four macOS heater name hints and the same model checks").
- Switching the AI preset to 自定义 clears the address and the key. A save with an empty custom address writes nothing, so the previous provider's key stays. Owner: `AssistantCommandBar.swift:AssistantSettingsDraft`. Pinned by `SettingsPlainLanguageTests.customPresetSwitchKeepsSavedKey`.
- Before deleting a stored `HomeStore` property, search every extension: the `HomeStore+*.swift` files, `DeviceReadout.swift`, `UndoBannerPause.swift`, `RaycastControls.swift`, `RaycastSnapshot.swift`, both `SnapshotWait.swift` files, and `CoverLockWait.swift`.
- A decision reads the value it changes. A water-heater target compares `facet.value` (`ManualControlPolicy.facetRequiresConfirmation`). A status-item click reads `StatusItemEventDecision.State`. A panel key reads `PanelKeyRouter.Context`. Fold height is the first light's `PanelFoldMeasure.Reading.cardTop` (`cardMinY - panelMinY`). Pinned by `FacetSafetyTests.waterHeaterTemperatureUsesFacetOrigin` and `PanelFoldLayoutTests.firstDeviceCardIsAboveTheFold`.

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
- `GlassSwitchToggleStyle.showsLabel` is false when `glassLabelHidden` or `labelsHidden` is true. macOS 14 passes `labelsHidden: false`, so a row that already has a title calls `View.glassLabelHidden()`. A toggle whose label is the only title does not (`AssistantCommandBar`, the child-lock toggle in `DeviceCardView`). Pinned by `SettingsPlainLanguageTests.glassSwitchLabelDecision`.

## 9. Tests Must Not Race Product Timers

When a test asserts on state that a production timer can change (undo banner expiry, scheduled commands, cooldowns, polling):

- Freeze the timer through an existing seam (`HomeStore.pauseUndoBannerCountdown()`, `assistantNow`, `controlDebounceInterval`), or
- Poll a deterministic signal that the path under test actually produces. When the failure path records nothing, the reliable signal is "the timer is frozen and the assertion runs immediately", not a spin on a success-only collection.

A wall-clock sleep before the assertion is the failure mode: on a loaded CI runner the sleep stretches past the timer's expiry, so the assertion fails nondeterministically while passing locally. This shipped once: `failedQuickActionRecordsNothing` spun on `executedCommands` (empty on failures) for 18 s in CI, past the 10 s banner expiry.

The same rule covers a test that needs to observe an intermediate state. Hold the seam open and release it from the test (`setGetPropsHook` fed by an `AsyncStream`, `GatedUndoProvider.release()`, `readBackEchoHold`) instead of sleeping for the state to appear; a sleep long enough to see the state on this machine is a coin flip on a loaded runner. See `initialSnapshotWaitsForEveryAccount` and `wakeFromSleepWaitsForAllAccountsBeforeClosingAwayGap` in `MiAccountsProviderTests` for the gated form.

- A toast assertion that must see the text sets `HomeStore.toastAutoDismissInterval` to nil first. An in-flight row is asserted while its gate is still held (`holdNextExecute`, `pauseUndoBannerCountdown`). Owner: `HomeStore.toastDismissInterval(for:)`. Pinned by `PanelHealthTests.toastLifetimes`.
- A value read after an `await` has a test that cancels it, races a second waiter, or takes the row during the wait. Owners: `runMissedScheduledCommand`, `undoTurnAllOff`. Pinned by `ScheduledCommandScopeTests.dismissDuringSnapshotWaitSendsNothing`, `concurrentMissedRunsExecuteOnce`, and `BulkWriteRollbackTests.undoWaitSkipsDeviceANewerBatchTook`.
- "Still in flight" is a counter the path increments. Owner: `ScheduledCommandScopeTests.SleepGate.waiting`, polled by `waitUntil`. A fixed `Task.yield` count is not that counter. `failureAfterUndoStaysSilent` still uses one.
- A repeated `hdiutil` attach takes `UpdateCheckerTests.HdiutilGate` first. Pinned by `liveDriverUnpacksAndVerifiesSignedBundles`.
- `L10n.currentLanguage` is process-wide. One `@Suite(.serialized)` does not hide it from other suites. `PanelFoldMeasure.reading` sets it and restores it before returning. Parallel tests use `L10n.$overrideLanguage`. `CameraPTZDriverTests` is serialized because it uses `CameraLivePanelController.shared`.
- After `startListening()`, call `waitForTestSnapshot()` before treating `devices` as the new home. An all-LG `schedule` is the exception in §7. The LG row rule is §14. Pinned by `ScheduledCommandScopeTests.refusesStaleDeviceListAfterStartListening` and `lgOnlyTimerSkipsSnapshotGuard`.
- A PTZ stop test counts motor calls, not only the notice. Owner: `FakePTZClient.recordedStops`, `CameraLivePanelController.ptzUnresolvedStops`. Pinned by `CameraPTZDriverTests.stopWriteFailureRetriesOnceThenTheButtonSendsStopAgain`.

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

- **Backend switch.** Entering demo mode or rebuilding the provider clears a consent prompt and a persistent toast. An ordinary toast keeps its timer. A late callback from the replaced provider is ignored. Owner: `invalidateUndoContext`. Pinned by `PanelHealthTests.switchingBackendClearsExpiredToast`. #276 shipped a consent banner whose 仍然连接 rebuilt the live backends while the app said demo.
- **User takeover.** A window or session the user opened, kept or moved into picture-in-picture belongs to the user; automation never moves, switches or closes it. #308 needed this three times: a ring hijacked an open camera view, a later ring re-armed auto-close after picture-in-picture, and a restore was closed by an old timer.
- **Repeat and stale events.** A repeated event renews what it owns or does nothing; an event about an older head, address or timestamp is ignored.

Name the clearing site for each new field in the diff. A field set in one place and cleared nowhere is the defect.

An ordinary toast may cover the expired-session prompt. The prompt returns when that toast ends only while the session still blocks. A second persistent toast is ignored only while the suspension is active and the session still blocks. When the session no longer blocks, `showToast` clears the suspension and shows the new persistent toast. A context change drops the suspension and the persistent toast. The panel hides the scan toast when the blocked notice already repeats it. Owners: `HomeStore.showToast`, `restoreSuspendedSessionToast`, `invalidateUndoContext`, `ControlCenterPanel.visibleToast`. Pinned by `PanelHealthTests.ordinaryErrorSuspendsSessionToast`, `secondBlockedWriteDoesNotStack`, `recoveryWhileSuspendedRestoresNothing`, and `contextChangeWhileSuspendedRestoresNothing`. The clear-and-show path after recovery has no separate test.

## 14. Optimistic Lock Lifecycle

- A shown row is locked only when the write passes a duration. A nil lock changes the row and leaves any existing lock in charge. Owner: `HomeStore+ControlWrite.swift:beginOptimisticWrite`. `commitManualWrite` forwards the caller's duration. `runApplianceAction` passes nil. Quick actions, 全关, undo, and a cover tap pass a duration.
- A non-cover primary toggle locks after a successful send for a LAN TV or an unavailable read. A published read does not lock. A cover locks before the send and again for 8 seconds after success. Owner: `HomeStore+Controls.swift:togglePrimary`, `confirmToggleReadBack`. Pinned by `CoverCommandOriginTests.inFlightSnapshotCannotDropCommandedTravel`.
- `optimisticLockRevision` increases only in `lockOptimistic` and when `handleProviderEvent` sees `backendChanged`. That backend change also clears the lock, so the old write no longer owns the row. Any other snapshot or LG adoption clears the lock and leaves the revision, so `runBatchCommands` still sends. No dedicated revision test.
- A locked row stays local only when its id is in the snapshot, a local row exists, the lock is unexpired, and read-back does not need the snapshot. An id the snapshot omits leaves `devices`, except the `latestLGDevice` insert. An in-flight primary-toggle read-back takes a locked non-cover. A cover in the snapshot stays until `coverTravelTakesOver` is true or the lock expires. Owner: `HomeStore+Backend.swift:handleProviderEvent`. `togglePrimary` is the only `readBackTickets.claim` caller. Pinned by `CoverCommandOriginTests.inFlightSnapshotCannotDropCommandedTravel`.
- Adopting a reported row clears `optimisticLockUntil`. Keeping the local row does not. `applyLGDeviceUpdate` removes the row when the TV is disabled, the home is demo, or the host is not configured. Otherwise it records `latestLGDevice` immediately, and an unexpired lock returns before the on-screen row is replaced. A locked cover keeps local 更多设置 rows once its read-back ticket has finished. Owners: `handleProviderEvent`, `applyLGDeviceUpdate`. Pinned by `BulkWriteRollbackTests.equalLGReportTakesTheRow` for the replace after expiry.
- A batch restores a refused device only when the lock entry still exists and `ownsRow` is true. An expired entry still counts. Undo failure rollback checks `ownsRow` only. A failed cover send restores the unexpired lock it replaced, and restores `coverOrigin.prior` only with that lock. Owners: `revertRefusedBatchWrites`, `revert`, `rollbackFailedUndoDevices`, `togglePrimary`. Pinned by `BulkWriteRollbackTests.expiredLockSkipsTheRevert` and `expiredLockWithoutSnapshotStillReverts`.
- While undo waits for the in-flight batch, the lock extends to `HomeStore.undoWaitLockCeiling` (120 seconds) without a new revision, then returns to 3 seconds for rows the undo still owns. Owner: `undoTurnAllOff`. Pinned by `BulkWriteRollbackTests.undoWaitLockIsBoundedAndRelaxed`.

## 15. Bulk Write Results

`BulkWriteOutcome` is the verdict `executeQuickAction` and `turnAllOff` return.

- A device that accepted at least one command and was not taken over stays on screen and in the undo banner. `refusedDeviceIds` is the failures with no `acceptedByDevice` entry. Losing `ownsRow`, including after an earlier accept in the same batch, puts the device in `takenOverDeviceIds` and leaves the banner on the newer row. `revert` runs for a refusal only when the lock entry remains and `ownsRow` is still true. Owners: `executeQuickAction`, `turnAllOff`, `revertRefusedBatchWrites`, `trimUndoBanner`, `revert`. Pinned by `BulkWriteRollbackTests.partlyAppliedDeviceKeepsItsRowAndBanner` and `olderBatchSkipsTakenDevice`.
- `.refusedByMiSession` wins when any device was session-refused. Otherwise a takeover or any other failure is `.partial`. A stopped batch or a moved `controlContextID` is `.partial` and does not revert, trim, or show the failure toast. Owners: `executeQuickAction`, `turnAllOff`. Pinned by `PanelHealthTests.takenOverBatchReportsPartial` and `BulkWriteRollbackTests.failureAfterUndoStaysSilent`.
- Quick actions and 全关 report `BulkWriteOutcome.externalResult`. Undo reads `toastNotice`. Owner: `RaycastSnapshot.swift:executeBuiltInURLScene`. Pinned by `PanelHealthTests.staleExpiryToastDoesNotFailLGOnlyAllOff`.
- `executeDeviceCommand` throws `MiSessionWriteBlocked` immediately before `provider.execute`. A live LG client skips that throw. `executeQuickAction` returns `.refusedByMiSession` before building rows when the session blocks. `turnAllOff` does that only when every target fails `lgClientServes`. A mixed batch still sends the LG commands. Pinned by `PanelHealthTests.mixedLGAAndMiAllOffSendsLG`.

## 16. Windows Panel Interaction

- A background chrome refresh calls `MenuMijiaWindowsApp.queueBackgroundRender`, which renders now unless `hasBlockingPanelInteraction()` is true. `setPendingHighRisk`, `syncUndoBannerClock`, and a structural cloud update use it. A refresh the user is waiting on calls `render`. Pinned by `windows/tests/ui.test.ts` ("queues the expired row removal while a panel gesture is active").
- `startTimerLoop` calls `render` when `lastUndoAction` expires, when `processScheduledCommands` reports a storage failure, when the missed-command count changes, and on every tick while `scheduledCommands` is non-empty. The camera keep-alive calls `closeCameraLiveView`, which calls `render`. No pinning test for the every-tick render.
- All Off fires only while the button is connected and `document.hasFocus()` is true. Window blur cancels the hold. Owner: `app.ts:bindAllOffControl`. Pinned by `windows/tests/ui.test.ts` ("does not run All Off when the window is unfocused as the hold completes").
- The chevron is drawn only when `hasDetailDrawer` is true. A non-camera body click expands only then. A camera body click opens the live view without that check. The chevron click toggles `expandedDeviceId` without calling `hasDetailDrawer` again. Owners: `models.ts:hasDetailDrawer`, `bindEvents.ts`. Pinned by `windows/tests/core.test.ts` ("hasDetailDrawer mirrors the macOS card table and never opens an empty drawer") and `windows/tests/ui.test.ts` ("never opens an empty drawer, and opens one for a card whose only control is 更多设置").


