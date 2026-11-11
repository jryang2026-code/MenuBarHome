---
paths:
  - "windows/src/ui/**/*.ts"
  - "windows/tests/**/*.ts"
---

# Windows 面板交互规范

## 16. Windows Panel Interaction

- A background refresh must not rebuild the panel during a gesture. Use `MenuMijiaWindowsApp.queueBackgroundRender`, which defers the rebuild until the gesture ends. A proactive result is the exception: it renders only when `hasBlockingPanelInteraction()` is false, and during a gesture the paint is dropped rather than deferred. Do not send that result through `queueBackgroundRender`. Owner: `windows/src/ui/proactive.ts`. The deferral is pinned by `windows/tests/ui.test.ts` ("queues the expired row removal while a panel gesture is active"). The proactive drop has no pinning test.
- `startTimerLoop` may call `render` while scheduled commands are queued, without that gesture check. Owner: `appLifecycle.ts:startTimerLoop`. No pinning test.
- A destructive hold must not finish while the window is unfocused. Owner: `app.ts:bindAllOffControl`. Pinned by `windows/tests/ui.test.ts` ("does not run All Off when the window is unfocused as the hold completes, and runs it when the window is focused").
- Whether a card offers a drawer is `hasDetailDrawer`, for both the chevron and a non-camera body click. A camera body opens the live view without that check. The chevron's click does not ask again. Owner: `models.ts:hasDetailDrawer`. Pinned by `windows/tests/core.test.ts` ("hasDetailDrawer mirrors the macOS card table and never opens an empty drawer").
