---
paths:
  - "Sources/MenuBarMijiaApp/**/*.swift"
  - "Tests/MenuBarMijiaAppTests/**/*.swift"
---

# macOS 面板布局、全局热键、玻璃兼容与挂起状态收尾

## 3. System Global Resource Lifecycle

System-wide registrations (such as Carbon `RegisterEventHotKey` in `HotkeyAndNotificationManager`) must bind their active registration lifecycle to their preference toggle:

- Call `UnregisterEventHotKey` immediately when `enableGlobalHotkey` is set to `false`, and re-register when set to `true`.
- Leaving a global hotkey registered while ignoring the callback hijacks the key chord from other macOS applications.

## 4. Control Center 12-Column Flow Layout & Module Spans

In `ControlCenterPanel` (`ControlCenterPanelLayout.swift:spans(for:)` and `DeviceLayout.swift:TileFlowLayout`):

- `TileFlowLayout` packs children into a 12-column grid (`3` = 1×1 round button, `6` = 2×1 capsule or 2×2 hero square, `12` = 4×1 full row or always-expanded panel).
- Devices with an open detail drawer (`expandedDeviceId == dev.id`) transiently take span `12` (`isCompactTile: false`) while unexpanded compact tiles take span `<= 6` (`isCompactTile: true`). When no custom order is saved, sub-row tiles (`span < 12`) are packed before full-row modules (`span == 12`) so an odd full-row strip never strands a lone half-row capsule.

## 8. macOS 14+ Adaptive Glass Boundary

- Isolate macOS 26 `.glassEffect(` and `GlassEffectContainer` calls inside `Sources/MenuBarMijiaApp/ThemeAndMotion.swift` (`View.adaptiveGlass` and `AdaptiveGlassContainer`), guarded by `#available(macOS 26.0, *)` with Material fallback for macOS 14 and 15. Enforced mechanically by `scripts/check.sh`.
- Hide the glass toggle's own label when the row already has a title. macOS 14 has no `labelsVisibility`, so that hide is `glassLabelHidden`. A toggle whose label is its only title stays visible. Owner: `ThemeAndMotion.swift:GlassSwitchToggleStyle.showsLabel`. Pinned by `SettingsPlainLanguageTests.glassSwitchLabelDecision`.

## 10. Overlay Geometry Has One Owner

Placement math that reserves space and the view that draws inside it must read the same dimensions:

- Pill sizes and spacing live once beside the content (`GrokBallSuggestionMetrics`); placement math derives its column, row, and footprint from them instead of repeating literals like 132, 44, 206, and 558.
- A view never hardcodes a size the placement reserves. When the two drift apart the content clips silently: #123's English empty state needed 65 pt inside a 44 pt row.
- Empty and fallback states fill the reserved width (`.frame(maxWidth: .infinity)`) so they reflow instead of assuming a fixed column.

## 12. A Conditional View Ships With Its Snapshot

A view that appears only in some state (a banner, a prompt, an empty or error state) ships with a snapshot case that puts the store into that state. Existing baselines never render it, so the `no-snapshot-change` label is wrong for it even though no current PNG changes.

The snapshot is the check that the layout holds: the plaintext-consent banner (#276) truncated its reason on one line until its own snapshot showed it. Reserve `no-snapshot-change` for changes that alter no visible state at all.

## 13. Pending UI State Ends on Every Transition (`单主生命周期` / single-owner)

Every pending UI field or timer follows **单主生命周期 (single-owner)**: name its single clearing site in the diff across backend switches, panel hide, user takeover, and cancellation.

- **NO**: Set `pendingBanner = ...` on trigger while leaving `invalidateUndoContext()` / panel-hide / user-PiP takeover untouched.
- **OK**: Pair every new pending state field with explicit clearing in `invalidateUndoContext()`, panel hide, and user takeover, plus a transition test.

State that waits on the user or a timer (a consent prompt, an auto-dismiss timer, a window a ring opened) has an owner and an end. For each such field, check every path that can supersede it:

- **Backend switch.** A persistent toast ends when `invalidateUndoContext` runs. `switchBackend` calls it. `rebuildLiveProvider` does not, so `allowHAPlaintext` leaves the toast up. `updateConnection` calls `invalidateUndoContext` even when the Home Assistant URL is unchanged. Owner: `invalidateUndoContext`. Pinned by `PanelHealthTests.switchingBackendClearsExpiredToast` for the switch to demo. The same-home rebuild has no pinning test. #276 shipped a consent banner whose 仍然连接 rebuilt the live backends while the app said demo.
- **User takeover.** A window or session the user opened, kept or moved into picture-in-picture belongs to the user; automation never moves, switches or closes it. #308 needed this three times: a ring hijacked an open camera view, a later ring re-armed auto-close after picture-in-picture, and a restore was closed by an old timer.
- **Repeat and stale events.** A repeated event renews what it owns or does nothing; an event about an older head, address or timestamp is ignored.
- **Activity center.** `recentSafetyAlerts` (at most 10, newest record per id) and `dismissedActivityIds` end in `invalidateUndoContext`, before another backend can own the panel. `panelActivities` excludes records whose device has disappeared; safety actions retain the scope captured at delivery. A dismissed expiring-session notice returns for a different expiry. Owners: `HomeStore+Activities.swift`, `invalidateUndoContext`, `PanelActivityFeed`. Pinned by `PanelActivityStoreTests.switchingBackendClearsActivities`, `stackLeavesOutForeignAndOrphanedRows`, `recordingDedupesAndCapsAtTen`, and `PanelActivityFeedTests.dismissedExpiringWarningReturnsWithANewExpiry`.
- **Stack interaction.** Activity expansion ends on panel hide, backend switch, or an empty feed. Transient hover and expansion end on leave, panel hide, an empty feed, or view disappearance; hiding a panel resumes the undo countdown even when AppKit never sends hover-leave. The transient view reports its measured height (including its bottom inset), and the device grid derives its bottom padding from that reading. Owners: `ActivityStackView`, `TransientStackView`, `ControlCenterPanel`.
- A new safety occurrence clears the previous dismissal for its id. Finishing a swipe can dismiss only the captured record's date. Accepted device snapshots delete orphaned safety records and their dismissal ids, so returning devices cannot revive old alerts. Pinned by `PanelActivityStoreTests.recurringAlertReappearsAfterDismissal`, `staleAlertDismissalKeepsNewOccurrence`, and `removedDeviceDoesNotReviveOldAlert`.
- Hover expansion is derived again on every transient-card collection change, including 1→2 and 2→1→2 while the pointer stays still. Owner: `TransientStackExpansion.isExpanded`. Pinned by `TransientStackExpansionTests.hoveredSingleExpandsWhenSecondCardArrives` and `hoveredStackReexpandsAfterCardReplacement`.

Name the clearing site for each new field in the diff. A field set in one place and cleared nowhere is the defect.

An ordinary toast may cover the expired-session prompt. The prompt returns when that toast ends only while the session still blocks. A second persistent toast is ignored only while the suspension is active and the session still blocks. When the session no longer blocks, `showToast` clears the suspension and shows the new persistent toast. `invalidateUndoContext` drops the suspension and the persistent toast. `rebuildLiveProvider` does not call it. The panel hides the scan toast when the blocked notice already repeats it. Owners: `HomeStore.showToast`, `restoreSuspendedSessionToast`, `invalidateUndoContext`, `ControlCenterPanel.visibleToast`. Pinned by `PanelHealthTests.ordinaryErrorSuspendsSessionToast`, `secondBlockedWriteDoesNotStack`, `recoveryWhileSuspendedRestoresNothing`, and `contextChangeWhileSuspendedRestoresNothing`. The clear-and-show path after recovery has no separate test.
