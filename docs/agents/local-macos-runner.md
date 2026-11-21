# 本机隔离的 macOS CI（已停用，保留文档备查）

> **状态：已停用，保留文档备查。** macOS CI 已全部留在 GitHub 托管的 `macos-26-intel` 上，不再读取 `MACOS_CI_RUNNER`，原本拆分的 `macos-test` 与 `macos-snapshots` 已合并为单个 `macos-test` job，仓库内的 Tart 控制与回环 DNS 辅助脚本也已移除。

## 隔离与安全边界

- 严禁把维护者这台含签名私钥的 Mac 宿主机直接注册为自托管 runner。
- 所有 macOS CI（`macos-test`、`macos-appintents`、`macos-release`）与 `release.yml` 固定运行在 GitHub 托管的 `macos-26-intel`（Xcode 26.6，区域 `zh_CN`）。
- 如果未来重新启用本机隔离 Tart VM（4 核、12GB 内存、Softnet 隔离、单次 JIT 配置即用即毁），须先把 Swift 单元测试（`--skip SnapshotTests`）拆回独立 job，将 UI 快照像素比对与发布构建继续固定在 GitHub 托管的 `macos-26-intel` 上。
