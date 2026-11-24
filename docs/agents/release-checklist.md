# 发版前检查清单（Release Checklist）

> 发版属于公开交付，**打 `vX.Y.Z` tag 前**必须逐项核对以下刚性门禁；任何未通过项均不得打 tag 或触发发布工作流。
>
> 说明：`scripts/release.sh` 是本地 macOS 打包、签名与 Apple 公证脚本，不包含交互式 preflight 确认钩子，因此本清单中的文档同步与核对步骤作为打 tag 前的人工刚性门禁执行。

## 1. 文档与首屏演示同步核对（打 tag 前必过）

先拉出上一正式版 tag 以来合入的所有改动（`git log <last-tag>..HEAD --oneline`），逐项对照实际代码核实：

- [ ] **对照已合入功能核对双端文档与词表**：
  - [`README.md`](../../README.md) 与 [`README.zh-CN.md`](../../README.zh-CN.md)：快速开始、核心能力描述、安装/签名/公证说明、系统要求与已知限制是否与当前代码一致；不得保留已过期或自相矛盾的旧限制文案（例如已补齐双端对等的能力仍写成单端限制）。
  - [`docs/platform-matrix.md`](../platform-matrix.md) 与 [`docs/platform-matrix.zh-CN.md`](../platform-matrix.zh-CN.md)：逐行核对双端状态标记（`✅` / `⚠️` / `—`）与说明列；**任何平台能力声明必须有真实代码依据**，同步维护 `docs/capabilities.json` 锚点并确认 `python3 scripts/check_capability_matrix.py` 通过。
  - [`GLOSSARY.md`](../../GLOSSARY.md)：核心领域术语、后端实现名、快照与路径约定是否反映最新架构。
- [ ] **核对首屏 GIF 与截图**：
  - 检查 `docs/assets/readme-v3/` 下的动图与截图（如 `docs/assets/readme-v3/keyboard-search.gif`、`docs/assets/readme-v3/windows-fluent.png` 等）以及 [`README.md`](../../README.md) / [`README.zh-CN.md`](../../README.zh-CN.md) 中的引用与图注，确认展示的界面、主题与交互流程与本版发布形态一致；如有重大 UI 或平台特性变化，先补录/替换对应素材再打 tag。
- [ ] **运行文档与契约检查**：
  - 执行 `python3 scripts/check_doc_links.py`、`python3 scripts/check_capability_matrix.py`、`python3 scripts/check_capability_manifest.py`、`python3 scripts/check_supported_devices.py`（或通过 `bash scripts/check.sh --changed` / `bash scripts/check.sh` 统一跑通），确保全部通过且无失效链接或路径引用。

## 2. 版本号、变更日志与本地门禁（打 tag 前）

- [ ] **七处版本元数据一致**：确认 `VERSION` 与 `windows/src-tauri/tauri.conf.json`、`windows/package.json`、`windows/package-lock.json`、`windows/src-tauri/Cargo.toml`、`windows/src-tauri/Cargo.lock`、`scripts/mijia`（`MCP_SERVER_INFO`）版本号完全一致（CI `verify-tag` 会通过 `scripts/check_release.sh` 校验）。
- [ ] **整理 [`CHANGELOG.md`](../../CHANGELOG.md)**：将「未发布」整理到新版本段；已在 `git tag` 的历史版本段严禁追加或改写。
- [ ] **本地门禁全绿**：按 `AGENTS.md` 执行 `bash scripts/check.sh`（非 UI 改动至少 `bash scripts/check.sh --changed`）与 `bash scripts/check.sh --lint-only --script-tests`，确认无非预期跳过项。

## 3. 两阶段发布与签名/镜像顺序（不要跳过或覆盖）

1. **阶段一（Draft）**：确认 `main` 远程 CI 全绿并经维护者确认后，人工创建并推送 `v<VERSION>` tag；`.github/workflows/release.yml` 构建双端安装包与 SPDX SBOM 并写入未发布草稿（8 个待签附件）。若需本地带 Apple 公证 DMG，按 [`scripts/release.sh`](../../scripts/release.sh) 注释说明执行。
2. **阶段二（离线 Ed25519 签名）**：在可信本机下载草稿附件，按 [`docs/agents/in-app-update.md`](in-app-update.md) 与 `.github/workflows/finalize.yml` 提示使用离线私钥运行 `scripts/sign_update.swift`，生成 `.update.json` 与 `.update.json.ed25519.sig` 后上传到该草稿（Ed25519 私钥永不进入 GitHub）。
3. **阶段三（Finalize 与镜像同步）**：手动触发 `.github/workflows/finalize.yml`，通过 `scripts/check_release.sh` 校验全部 10 个附件与 Ed25519 签名后公开 Release，随后 `mirror-mainland` job 按 [`docs/agents/release-mirrors.md`](release-mirrors.md) 同步到 Gitee / GitCode。严禁对已公开发布的 Release 使用 `--clobber` 覆盖附件。
