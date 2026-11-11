---
paths:
  - "Tests/**/*.swift"
  - "scripts/repeat_test.sh"
  - "scripts/red-check.sh"
---

# Swift 测试规范与辅助脚本

重复跑一个 Swift 测试用 `scripts/repeat_test.sh <filter> [count]`。把当前文件盖到旧提交上、确认命令会失败，用 `scripts/red-check.sh`。

## 9. Tests Must Not Race Product Timers (`tight` async & timer seams)

Keep timer, cooldown, polling, and intermediate-state tests **tight** (deterministic, zero wall-clock sleep, millisecond runtime):

- **NO**: `try await Task.sleep(for: .milliseconds(300)); #expect(store.toastNotice != nil)` or fixed `for _ in 0..<20 { await Task.yield() }`
- **OK**: `store.toastAutoDismissInterval = nil; store.trigger(...); #expect(store.toastNotice != nil)` or `setGetPropsHook` + `AsyncStream` gate (`GatedUndoProvider.release()`, `readBackEchoHold`)

When a test asserts on state that a production timer can change (undo banner expiry, scheduled commands, cooldowns, polling):

- Freeze the timer through an existing seam (`HomeStore.pauseUndoBannerCountdown()`, `assistantNow`, `controlDebounceInterval`), or
- Poll a deterministic signal that the path under test actually produces. When the failure path records nothing, the reliable signal is "the timer is frozen and the assertion runs immediately", not a spin on a success-only collection.

A wall-clock sleep before the assertion is the failure mode: on a loaded CI runner the sleep stretches past the timer's expiry, so the assertion fails nondeterministically while passing locally. This shipped once: `failedQuickActionRecordsNothing` spun on `executedCommands` (empty on failures) for 18 s in CI, past the 10 s banner expiry.

The same rule covers a test that needs to observe an intermediate state. Hold the seam open and release it from the test (`setGetPropsHook` fed by an `AsyncStream`, `GatedUndoProvider.release()`, `readBackEchoHold`) instead of sleeping for the state to appear; a sleep long enough to see the state on this machine is a coin flip on a loaded runner. See `initialSnapshotWaitsForEveryAccount` and `wakeFromSleepWaitsForAllAccountsBeforeClosingAwayGap` in `MiAccountsProviderTests` for the gated form.

- A toast assertion that must see the text sets `HomeStore.toastAutoDismissInterval` to nil first. Owner: `HomeStore.toastDismissInterval(for:)`. Pinned by `PanelHealthTests.toastLifetimes`.
- A value read after an `await` has a test for cancel, a second waiter, or a takeover during the wait. Pinned by `ScheduledCommandScopeTests.dismissDuringSnapshotWaitSendsNothing`, `concurrentMissedRunsExecuteOnce`, and `BulkWriteRollbackTests.undoWaitSkipsDeviceANewerBatchTook`.
- "Still in flight" is a counter the path increments (`ScheduledCommandScopeTests.SleepGate.waiting`). A fixed `Task.yield` count is not that counter.
- A repeated `hdiutil` attach takes `UpdateCheckerTests.HdiutilGate` first. Partly pinned by `liveDriverUnpacksAndVerifiesSignedBundles`: it takes the gate. It does not assert that a second attach waits.
- Tests that need a language use `L10n.$overrideLanguage.withValue`. `L10n.currentLanguage` is process-wide. Assigning it from a test races every other suite (`check.sh` rejects `L10n.currentLanguage =` under `Tests/`).
- After `startListening()`, call `waitForTestSnapshot()` before treating `devices` as the new home. An all-LG plan is the exception in §7. Pinned by `ScheduledCommandScopeTests.refusesStaleDeviceListAfterStartListening` and `lgOnlyTimerSkipsSnapshotGuard`.
- A PTZ stop test counts motor calls. Owner: `FakePTZClient.recordedStops`. Pinned by `CameraPTZDriverTests.stopWriteFailureRetriesOnceThenTheButtonSendsStopAgain`.
- Camera diagnostics waits for `streamSource != nil` with a 30-second `ContinuousClock` deadline and requires the readiness result before reading the report. The former 40 × 25 ms loop silently continued with `stream_mode: none` on a loaded runner. Pinned by `MenuBarPanelControllerTests.cameraDiagnosticsReportStreamModeAndAudioSupport`.
