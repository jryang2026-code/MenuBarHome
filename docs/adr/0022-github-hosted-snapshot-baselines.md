# ADR-0022：UI 快照基准改为 GitHub 托管的 macOS

日期：2026-11-17　状态：已接受（取代 [ADR-0018](0018-back-to-github.md) 第 5 条）

## 背景

ADR-0018 把 UI 快照基准放在维护者的 Mac 上，CI 的 `macos-test` 跳过 `SnapshotTests`。托管机和这台 Mac 的渲染不一致，像素比对不能两边同时当基准。刷新基线也不该依赖这一台私人机器。

## 决定

1. 唯一基准渲染机是 GitHub 托管的 `macos-26-intel`，Xcode 钉在 26.6，区域与 `macos-test` 相同（`zh_CN`、公制、摄氏），由 `scripts/ci_snapshot_locale.sh` 写入。`macos-snapshots` 固定跑在这台机器上，不读 `MACOS_CI_RUNNER`。
2. `macos-test` 仍可排到本地隔离 VM，并继续跳过像素比对。VM 不是基准。
3. 重录用手动工作流 Record snapshots。它只接受本仓库已有的功能分支，拒绝默认分支。渲染在一台只有只读权限的 macOS 上跑目标分支的测试，并把 PNG 做成产物。另一台新的机器只使用默认分支上的脚本：检查产物里每一项都是该目录下的普通 PNG，再提交并推送。只有这次推送产生了新提交，才 `workflow_dispatch` 启动 `ci.yml`。不新增 PAT。
4. 本机 `scripts/check.sh` 默认不把像素差异当失败。`--snapshots` 只额外跑一次本机比对，失败不阻断。
5. 更换 `macos-26-intel` 镜像或 Xcode 钉扎后必须重录。不放宽 `SnapshotAssertion.Tolerance`。

## 代价

- 改界面的 PR 多一个 macOS job。
- 录制工作流的手动按钮要等该文件进入默认分支后才出现。
- 本机看到的像素和 CI 不同是预期结果。
