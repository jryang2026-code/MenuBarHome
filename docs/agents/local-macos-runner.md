# 本机隔离的 macOS CI（已停用，保留文档备查）

> **状态：已停用，保留文档备查。** macOS CI 已全部留在 GitHub 托管的 `macos-26-intel` 上，不再读取 `MACOS_CI_RUNNER`，原本拆分的 `macos-test` 与 `macos-snapshots` 已合并为单个 `macos-test` job。**如果未来重新启用本地 VM，必须先把 Swift 单元测试（`--skip SnapshotTests`）拆回独立 job**，因为本地 ARM64 VM 不是 UI 快照像素基准（基准固定为 GitHub 托管 `macos-26-intel` + Xcode 26.6 + `zh_CN`），不能承载像素比对与基线录制。

宿主机只运行 Tart 和控制脚本，不运行仓库里的构建代码。每个 GitHub job 使用独立的虚拟机副本，完成、失败或超时后销毁。签名发布流程不接入此 runner。

## 隔离边界

- 单台虚拟机，4 核、12GB 内存，不共享宿主目录、钥匙串、剪贴板、USB 或 SSH agent。
- Softnet 阻断虚拟机主动访问宿主、其他虚拟机和私有网络；DNS 由 VM 内的回环服务转发到公共 HTTPS 解析器，不开放宿主 DNS 端口。
- GitHub 管理凭据留在宿主，只有用于单个 job 的 JIT 配置传入虚拟机。
- 控制脚本固定运行宿主安装目录中的副本，不从 PR 或 job 的 checkout 加载代码。
- macOS 虚拟机不是 UI 快照基准。重新启用时须把像素比对留在固定 GitHub 托管 `macos-26-intel` 的独立 job，排到本机 VM 的单测 job 必须继续跳过 `SnapshotTests`。

这些措施用于限制公开仓库 PR 中的任意代码。工作流中的条件和 runner 标签不是安全隔离措施。

## 本机文件

本地 VM 使用安装时复制的 Xcode，托管机仍固定 Xcode 26.6；两边的工具链版本均输出到 CI 日志。

安装目录：`~/.local/share/menubarhome-ci/`。

`runner.py` 来自 `scripts/local_macos_runner.py`，更新前先停止服务，再审核并复制新版本。`manifest.json` 记录安装范围，`vm.log` 和 `job.log` 记录当前一次运行。`state.json` 只记录 runner ID、名称和时间，不保存 JIT 配置。

Tart 基础镜像名为 `menubarhome-ci-base`，每次任务的副本名为 `menubarhome-ci-job`。只可销毁任务副本，保留基础镜像。基础镜像包含独立的 macOS、Xcode 和 GitHub Actions runner，不能导入 Apple ID 或签名证书。

本机网络的普通公网 DNS 查询超时，因此基础 VM 还安装了 `scripts/local_ci_dns.py` 到 `/usr/local/libexec/menubarhome-ci-dns.py`，由 `com.menubarhome.ci-dns` 系统 LaunchDaemon 启动，并将 Ethernet DNS 设为 `127.0.0.1`。服务只监听 VM 回环地址的 UDP 53，按 `DO_H_UPSTREAMS` 顺序轮询裸 IP DoH 上游（`223.5.5.5`、`1.12.12.12`、`1.1.1.1`、`1.0.0.1`），不依赖宿主代理或目录。单次查询共用 4.5 秒总预算（`QUERY_DEADLINE`，低于 macOS stub resolver 约 5 秒的单次时限）：每个上游的连接与分块读取都只用剩余时间，预算用完立即回 SERVFAIL，不再逐个等满 3.5 秒，也不会把迟到（stub resolver 已放弃）的应答当结果。

## 启停和检查

登录后由 `~/Library/LaunchAgents/com.menubarhome.ci.plist` 启动。Mac 需要开机且用户已登录，睡眠期间不能接活。

```bash
launchctl print "gui/$(id -u)/com.menubarhome.ci"
gh api repos/jryang2026-code/MenuBarHome/actions/runners --jq '.runners[] | {name,status,busy}'
tail -n 30 ~/.local/share/menubarhome-ci/controller.log
tail -n 30 ~/.local/share/menubarhome-ci/job.log
```

停止服务会终止当前本地任务并销毁其虚拟机，所以先确认 runner 没有忙碌任务。

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.menubarhome.ci.plist
```

启动服务：

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.menubarhome.ci.plist
```

## 切换 CI 执行位置（已停用）

当前 `.github/workflows/ci.yml` 已移除对 `MACOS_CI_RUNNER` 的读取，全部 macOS job 固定在 GitHub 托管的 `macos-26-intel` 上运行。以下记录仅保留供未来重新启用本机 VM 时参考：

- 重新启用前，须先把 `ci.yml` 中合并后的 `macos-test` 拆回「只跑 `--skip SnapshotTests` 的单测 job（可按 `MACOS_CI_RUNNER` 路由到非 fork 的本机 VM）」和「固定 `macos-26-intel` 跑 `--filter SnapshotTests` 的快照基准 job」，避免非基准 VM 参与像素比对或基线录制。
- `macos-release`、`macos-appintents` 与快照基准 job 须继续留在 GitHub 托管机，避免与单测一起排到单台串行 VM。

历史上通过仓库 Actions 变量切换路由的命令：

```bash
gh variable set MACOS_CI_RUNNER --repo jryang2026-code/MenuBarHome --body '["self-hosted","macOS","ARM64","menubarhome-vm"]'
```

删除变量恢复托管机：

```bash
gh variable delete MACOS_CI_RUNNER --repo jryang2026-code/MenuBarHome
```

这不是自动故障转移。已经排队的 job 不会因变量变动而换机器，需要取消并重新运行。长时间离线前应先恢复托管机；停止正在运行的任务须取得用户授权。

## 更新和验证

基础镜像必须在接收任何仓库 job 之前准备好。停止服务后才能更新基础镜像。更新 Xcode 或 Actions runner 后，检查虚拟机内 `xcodebuild -version`、`swift --version` 和 `security find-identity -v -p codesigning`；最后一项应为零项有效身份。

启用前还应从虚拟机验证：可以访问 GitHub，不能连接宿主和局域网；执行一次 CI 后 runner ID 与任务虚拟机副本都被替换。磁盘可用空间低于 25GiB 时控制脚本拒绝启动新任务。

安装 Tart 的官方说明：https://tart.run/quick-start/ 。GitHub JIT runner 接口：https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-a-repository 。
