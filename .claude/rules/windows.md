---
paths:
  - "windows/**/*"
---

# Windows 客户端测试命令

Rust 测试在 Windows CI 的 `windows-rust-test`。工作目录是 `windows`，命令是 `cargo test --locked --manifest-path src-tauri/Cargo.toml`。

Windows 只跑一个测试文件时，可在任意工作树执行 `node windows/scripts/test-file.mjs tests/<file>.test.ts`（或在 `windows/` 执行 `npm run test:file -- tests/<file>.test.ts`）。
