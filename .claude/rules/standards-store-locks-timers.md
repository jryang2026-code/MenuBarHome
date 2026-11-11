---
paths:
  - "Sources/MijiaCore/HomeStore*.swift"
  - "Sources/MijiaCore/AssistantSchedule.swift"
  - "Sources/MijiaCore/RaycastSnapshot.swift"
  - "Sources/MijiaCore/LGWebOSClient.swift"
  - "Tests/MijiaCoreTests/*Lock*.swift"
  - "Tests/MijiaCoreTests/*Bulk*.swift"
  - "Tests/MijiaCoreTests/*Scheduled*.swift"
---

# 状态存储、乐观锁、定时指令与批量写入

异步等待后的状态提交遵循 **单主生命周期 (single-owner)**：跨 `await` 后必须按 ID 重新查找条目，并在**同一段无 `await` 的同步区间**内完成存在性核查、移除与持久化，严禁缓存 `await` 前的快照引用直接执行硬件动作。
- **NO**: `let item = scheduledCommands[idx]; await waitForInitialSnapshotIfNeeded(); await execute(item)`
- **OK**: `await waitForInitialSnapshotIfNeeded(); guard let idx = scheduledCommands.firstIndex(where: { $0.id == id }) else { return }; let item = scheduledCommands.remove(at: idx); persistScheduledCommands(); await execute(item)`

## 2. Bidirectional Optimistic Lock on Snapshot Undo

When restoring a `previousDevices` snapshot in `HomeStore` (`UndoBanner` / `undoTurnAllOff`):

- Call `lockOptimistic(dev.id, duration: .seconds(3.0))` for **every device whose state differs** between current `devices` and `banner.previousDevices`.
- Locking only `where dev.isActiveOn` fails when undoing an action (such as `QuickAction.softNightLight`) that turned a previously-off device on, exposing the restored off-state to stale WebSocket frames.

## 7. Scheduled Command Persistence & Missed-Timer Confirmation

When modifying `ScheduledCommand` or `HomeStore+Assistant.swift`:

- Persist both `scheduledCommands` and unconfirmed `missedScheduledCommands` to `UserDefaults` (`ScheduledCommand.storageKey`) on every schedule, fire, restore, confirm, dismiss, or cancel transition.
- Never auto-execute an expired timer silently on launch; keep it in `missedScheduledCommands` (and on disk across restarts) until the user explicitly confirms (`runMissedScheduledCommand`) or dismisses (`dismissMissedScheduledCommand`).
- The same applies after the Mac sleeps: `Task.sleep` keeps counting during sleep, so a timer task can wake up long after its `fireDate`. A timer that wakes more than `HomeStore.lateTimerGrace` (60 s) late goes to `missedScheduledCommands` instead of running. Tests simulate this with `assistantNow`.
- A timer records every source connected when it was created (ADR-0019). `schedule(_:after:)` writes `sourceScopes` from `activeConnectionScopes` and also the primary `sourceScope` for old builds; the effective stamp is `sourceScopes ?? sourceScope.map { [$0] } ?? nil`. One request stays one entry, so its undo record covers every target. `HomeStore.sourceScopesMatch` is the only rule, used by the firing guard, `restoreScheduledCommands` and `runMissedScheduledCommand`: the stamp and `activeConnectionScopes` must intersect, and every `ha:` scope connected now must appear in the stamp, because timer targets are merged card ids that an HA the timer never saw can claim. Removing HA still leaves the intersection, so Xiaomi timers survive its removal. Only matching entries are armed or shown; a save writes `foreignScheduledCommands` back so another source's entries survive, and firing re-checks the rule. `schedule` also refuses until `snapshotGeneration` has moved past the value `startListening()` recorded, so a stale device list is never stamped with the new sources, unless every target is a local LG card (LAN rows do not bump the generation; a plan mixing LG and cloud targets still needs the snapshot). Entries written before scopes existed are adopted once at `restoreScheduledCommands` when a primary scope is resolved. `startListening()` is the single re-partition point; `invalidateUndoContext()` runs before the switch and cannot decide it.
- `runMissedScheduledCommand` is a person acting now: the screen-lock guard runs before the entry leaves the list, so a refused run can be retried. A timer firing on schedule stays exempt (#143). The entry is removed and persisted only after `waitForInitialSnapshotIfNeeded()` and a second scope/lock check; a refusal at any point keeps it. That wait only runs while `devices` and `scenes` are both empty (about 5 s), so it is not proof of a complete snapshot; the target check below covers a partial list. After the wait, re-find the entry by id and keep the existence check, the removal and the persist in one stretch without an `await`, so a dismissed, cancelled or already-taken entry makes the waiter exit instead of executing.
- A timer is consumed only after its plan can actually run: `missingPlanTargets(_:)` must be empty, otherwise the firing path sends the entry to `missedScheduledCommands` and the manual path refuses it. Selecting another Mi Home does not change the captured source set (same account), so the device list is the only evidence that the target is here. A plan with no device targets has none missing.
- Once the scope, lateness and snapshot checks pass and `missingPlanTargets(_:)` is empty, the firing task removes the entry id from `scheduledCommands`, `missedScheduledCommands` and `foreignScheduledCommands` and persists in one stretch without an `await`, then executes. A source switch during the in-flight request re-partitions from disk, so an entry still there would be armed or missed again and could run twice; crashing mid-execution loses the timer instead, which is the safer failure for hardware. Completion only clears `scheduledTasks[id]` when `scheduledTaskTokens[id]` still belongs to that run, so it cannot detach a re-armed task.

## 14. Optimistic Lock Lifecycle

- `beginOptimisticWrite` locks only when `lock` is non-nil. A nil lock may change the row and leaves the existing lock in charge. Owner: `HomeStore+ControlWrite.swift:beginOptimisticWrite`.
- A primary toggle's lock is taken by `confirmToggleReadBack` after the send. A cover is locked before the send and locked again after success, which bumps the revision. Owner: `HomeStore+Controls.swift:togglePrimary`. Partly pinned by `CoverCommandOriginTests.inFlightSnapshotCannotDropCommandedTravel` for the cover. The non-cover lock has no test there.
- `optimisticLockRevision` increases only in `lockOptimistic` and on `backendChanged`. Any other adoption of a reported row clears the lock and leaves the revision, so the batch still owns the send. Owner: `lockOptimistic`, `handleProviderEvent`. No dedicated revision test.
- A locked row stays on screen only while the snapshot still contains it, a local row exists, the lock is unexpired, and read-back does not need that snapshot. An omitted id leaves `devices`, unless it is the current `latestLGDevice`. An in-flight read-back may replace a locked non-cover. A cover in the snapshot stays until its travel is confirmed or the lock expires. Owner: `HomeStore+Backend.swift:handleProviderEvent`. Partly pinned by `CoverCommandOriginTests.inFlightSnapshotCannotDropCommandedTravel` for the cover. The non-cover lock has no test there.
- Adopting a reported row clears the lock. An unexpired lock keeps the on-screen LG row, while `applyLGDeviceUpdate` has already recorded `latestLGDevice`. A disabled, demo, or unconfigured TV removes the row. Owner: `applyLGDeviceUpdate`. Pinned by `BulkWriteRollbackTests.equalLGReportTakesTheRow` for the replace after the lock expires.
- A batch undo of a refusal needs both the lock entry and `ownsRow`. An undo failure needs `ownsRow` only. A failed cover restores a prior lock only when it saved one, and restores the travel origin only with that lock. Owner: `revertRefusedBatchWrites`, `revert`, `togglePrimary`. Pinned by `BulkWriteRollbackTests.expiredLockSkipsTheRevert` and `expiredLockWithoutSnapshotStillReverts`.
- While undo waits for the in-flight batch, the lock extends to `HomeStore.undoWaitLockCeiling` (120 seconds) without a new revision, then returns to 3 seconds for rows the undo still owns. Owner: `undoTurnAllOff`. Partly pinned by `BulkWriteRollbackTests.undoWaitLockIsBoundedAndRelaxed` for the 120 second ceiling and the return to 3 seconds. It does not assert the revision.

## 15. Bulk Write Results

`BulkWriteOutcome` is the verdict `executeQuickAction` and `turnAllOff` return.

- A device the batch still owns, and that accepted a command, stays on screen and in the undo banner. A device a newer write took leaves the banner on that newer row, even after an earlier accept. A refusal rolls back only while the batch still owns the row and the lock entry remains. Owner: `HomeStore+Undo.swift:executeQuickAction`, `revert`. Pinned by `BulkWriteRollbackTests.partlyAppliedDeviceKeepsItsRowAndBanner` and `olderBatchSkipsTakenDevice`.
- A Mi-session refusal is `.refusedByMiSession`. Any other incomplete batch, including a takeover or a batch that was stopped, is `.partial`. A stopped batch does not roll back over the undo. Owner: `executeQuickAction`, `turnAllOff`. Pinned by `PanelHealthTests.takenOverBatchReportsPartial` and `BulkWriteRollbackTests.failureAfterUndoStaysSilent`.
- An external quick action or 全关 reports `BulkWriteOutcome`, not whatever toast is on screen. Undo reports the toast. Owner: `RaycastSnapshot.swift:executeBuiltInURLScene`. Partly pinned by `PanelHealthTests.staleExpiryToastDoesNotFailLGOnlyAllOff` for 全关. Undo reading `toastNotice` has no test there.
- An expired Mi session must not block a command a live LG client serves. A batch that cannot send refuses before showing rows. Owner: `HomeStore+ControlWrite.swift:executeDeviceCommand`. Pinned by `PanelHealthTests.mixedLGAAndMiAllOffSendsLG`.
