# ADR-0018：仓库、CI 与发布迁回 GitHub

日期：2026-11-08　状态：已接受　取代：ADR-0012

## 背景

ADR-0012 把项目搬到 GitLab，因为原账号 `jryang1997` 被停用。GitLab 上没有发过版本，所以没有已安装的客户端依赖它的更新地址。维护者注册了新账号 `jryang2026-code`，决定回到 GitHub，仓库改名 `MenuBarHome`。

## 决定

1. 代码、issue、PR、Release 都放在 `github.com/jryang2026-code/MenuBarHome`。工单操作直接用 `gh`，删除 `scripts/forge.py`。
2. macOS 与 Windows 都从 GitHub Releases 检查和下载更新，恢复 `release.yml` 加 `finalize.yml` 的两阶段发布。ADR-0005 的信任链不变：Ed25519 私钥只留在维护者本机。
3. 每个版本都发三端清单。Windows 解析器只接受三个文件，只发 macOS 的单文件清单会让 Windows 判为无效。
4. CI 全部用 GitHub 托管机。公开仓库不用自托管 runner，因为外部 PR 可能在上面执行代码，而这台 Mac 存着签名私钥。
5. 快照基线仍以维护者的 Mac 为准。托管机渲染不同，CI 跳过快照比对，由本机 `scripts/check.sh` 比对。
6. GitLab 保留为只读备份，不再放工单和发版。

## 代价

- 新账号有被停用的风险：GitHub 条款规定一人只能有一个免费账号。保留 GitLab 备份，账号稳定之前不依赖它发版。
- 1.1.7 及更早版本的更新地址仍是旧账号，只能手动安装一次，除非旧账号恢复。
- CI 不比对快照，界面回归只由提交前的本机门禁拦截。
- 安装包文件名、Bundle ID 和钥匙串条目仍叫 MenuBarMijia，这次只改仓库名。
