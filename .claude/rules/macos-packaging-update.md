---
paths:
  - "scripts/build_app.sh"
  - "scripts/install_local_app.sh"
  - "scripts/release.sh"
  - "scripts/sign_update.swift"
  - "Sources/MijiaCore/Update*.swift"
  - "Tests/MijiaCoreTests/Update*.swift"
---

# macOS 打包、本机安装与自动更新挂载

Run `bash scripts/install_local_app.sh` to build, verify, and install into the bundle the user launches (it keeps the previous version for rollback); `bash scripts/build_app.sh` only packages the bundle inside the worktree.

`hdiutil attach` 报 `Resource temporarily unavailable` 时先重试这一次。应用内挂载已经按退避重试（`UpdateSystemDriver.retryingAttach`）。测试里重复 attach 的串行要求见 `.claude/rules/standards-swift-tests.md`。
