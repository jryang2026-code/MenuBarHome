---
paths:
  - "Sources/MenuBarMijiaApp/**/*.swift"
  - "Tests/MenuBarMijiaAppTests/**/*.swift"
  - "scripts/*snapshot*.sh"
---

# macOS 界面快照基线

快照基线以维护者这台 Mac 的渲染为准。GitHub 托管机渲染不同，所以 CI 跳过快照比对，只由本机门禁比对。改到 `Sources/MenuBarMijiaApp/` 而界面有变化时，`bash scripts/record_snapshots.sh` 重录。审阅变化的 PNG 后，与改动它们的代码放进同一个提交。`--dry-run` 只列出会变的图，不写基线。脚本用 `git diff` 列出未暂存的变化图和未跟踪的新图，并打印尺寸变化。录制进程没跑完才算失败，日志留在临时文件。快照对不上时，失败信息带第一个不同的像素（`SnapshotAssertion.firstDifferingPixel`）。`SnapshotFixture` 默认把引导标成已完成（`has_completed_onboarding` 为 true）。要录引导界面时再改成 false。改动没碰界面、快照却突然失败时，先在最近一次通过的提交上重跑同一组快照。那边也失败，说明是渲染环境变了。差异时有时无（如系统滚动条样式、并行测试残留的状态）就修测试工具，不要重录基线。系统升级后差异稳定复现，逐张审阅后再重录。
