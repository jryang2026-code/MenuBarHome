## Linux Cloud Agents (Antigravity Cloud & Cursor Cloud)

Cloud agents run on Linux. `scripts/build_app.sh`, `scripts/install_local_app.sh`, and a repo-root `swift test` need the macOS SDK (CI uses `macos-26-intel`). The Windows Tauri installer (`cargo test` with Win32 WebView2, `npx tauri build`) runs on Windows CI.

### Automatic session bootstrap

`.agents/environment.json` runs `bash .agents/cloud-setup.sh` automatically on every new Cloud VM (and `/home/antigravity/env-setup.sh` mirrors it at the Antigravity project level). It idempotently configures:

- `~/.bashrc` `PATH` exports (`~/.local/swift/usr/bin`, `~/.local/bin`, `/usr/local/go/bin`, `/usr/local/cargo/bin`) for non-interactive command subshells.
- **Swift 6.1.3** user-space toolchain in `~/.local/swift` (no `sudo` required on Debian 12) plus pinned timestamps on `scripts/linux-check/Shims` so incremental builds reuse cache.
- **`actionlint`** in `~/.local/bin/actionlint`.
- **`windows/node_modules`** and **`raycast/node_modules`** via `npm ci` (guarded by `package-lock.json` SHA-256 stamps so waking an existing VM skips redundant installs).
- **Persistent Cloud skills (`~/.gemini/skills/` & `~/.gemini/pstack/pstack-models.md`)**: On Antigravity Cloud, `/shared/user/.gemini` persists all 94 `pstack` and `mp-*` skills across sessions; `.agents/cloud-setup.sh` ensures the default `pstack-models.md` (`inherit`) is present. To rebuild skills from upstream sources, use `~/.gemini/pstack/build-cloud-skills.py`.

### Linux gates

- `bash scripts/check.sh --skip-snapshots` — full Linux gate: secret scan, mechanical lints, `scripts/linux-check/run.sh` (`MijiaCoreTests`, matching CI's `linux-core` job), Windows frontend unit tests + `tsc && vite build`, and Raycast extension tests + typecheck.
- `bash scripts/check.sh --lint-only` (add `--script-tests` when touching `scripts/`) — secret scan and mechanical lints (~4s).
- `actionlint .github/workflows/ci.yml .github/workflows/snapshot-guard.yml` — GitHub Actions workflow validation.
- `bash scripts/test_nas_setup.sh` — NAS packaging safety (stubs network commands; no NAS host required).

`npm run dev --prefix windows` serves the tray UI at port 1420 (`strictPort`). First launch shows onboarding; “Preview the demo” / “先看演示预览” opens the offline demo home, and clicking a device card toggles it. Mi Cloud QR login and Home Assistant need a real account and are not part of cloud setup.

Note for Ubuntu/GCC-14 images (Cursor Cloud): if the base image ships GCC 14 without headers, install `libstdc++-14-dev` so `swift-crypto` finds `cstdio`; Antigravity Cloud's Debian 12 image ships GCC 12 with `libstdc++-12-dev` preinstalled.
