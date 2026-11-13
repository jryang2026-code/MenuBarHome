---
paths:
  - "scripts/check.sh"
  - "scripts/hooks/**"
  - "scripts/gate_report.sh"
  - "scripts/check_*.py"
  - "scripts/go2rtc-ptz/**"
---

# 提交钩子与门禁脚本

提交钩子只跑 `check.sh --lint-only`（`MMB_HOOK_FULL=1` 时跑全量）；测试与快照比对靠开 PR 或更新 PR 前跑一次完整的 `bash scripts/check.sh`。提交钩子的路径用 `git rev-parse --git-path hooks/pre-commit` 查。仓库里的门禁脚本是 `scripts/hooks/pre-commit`。`scripts/check.sh` 把共享 git 目录的 `hooks/pre-commit` 写成包装，转去跑当前工作区的那份脚本。

`check.sh` 一步失败也继续跑完其余步，最后用 `scripts/gate_report.sh summary` 打一行。有跳过的步时打印 `⚠️ 部分通过：跳过 <名称>`，退出码是 0。有失败的步时打印 `❌ 门禁未通过`，并带上那一步的退出码。本工作树没有 `windows/node_modules` 时，`check.sh` 会尝试复用锁文件一致的兄弟工作树 `windows/node_modules` 跑 `windows/tests/*.test.ts`（设 `MMB_DISABLE_SHARED_NODE_MODULES=1` 强制跳过），完整 `tsc --noEmit && vite build` 及 `raycast/node_modules` 缺失时仍跳过且不会自动 `npm ci`。`go version` 能成功就跑 `scripts/go2rtc-ptz/verify.sh`（在干净的上游检出上重新打补丁并跑测试）。这一步失败则门禁失败。`go version` 失败，或 go 不是可执行文件，才跳过。`--lint-only` 在这些测试步之前返回，但仍跑 `scripts/go2rtc-ptz/check_model_tables.py`（型号表，以及 README 里的补丁 SHA-256）。Rust 测试在 Windows CI 的 `windows-rust-test`。工作目录是 `windows`，命令是 `cargo test --locked --manifest-path src-tauri/Cargo.toml`。

`scripts/check_timer_render.py` 拦住定时器回调里直接 `render()`。`scripts/check_swift_harness_lints.py` 拦住固定次数的 `Task.yield` 循环、`#expect` 里的 `allSatisfy(\.`，以及 `withAnimation` 里裸调返回 `Task` 的函数。判断标准在 `CODING_STANDARDS.md`。
