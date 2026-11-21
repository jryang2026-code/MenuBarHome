# Optional features and panel redesign plan

Working plan for making connections, features and device types optional while redesigning the panel and settings.

- `rulings.md` takes priority over both design documents.
- `architecture.md` defines the capability model and work packages `P*`.
- `ui.md` defines the interface plan and work packages `WP*`.
- `prototype.html` is a static prototype with sample data only.

Confirmed product decisions: Windows all-off excludes covers, new installs show every supported device type and offer a lights-and-switches preset, and wall switches can be marked as lights without adding a general "don't ask again" option for high-risk devices.

Release checkpoints: after every two or three work packages, stop dispatching, run the manual smoke checklist and cut a release before starting the next batch. Cross-model review is reserved for PRs that touch real device writes, credentials or tokens; other PRs merge once checks are green and the Codex rounds are used up, with leftovers filed as issues.
