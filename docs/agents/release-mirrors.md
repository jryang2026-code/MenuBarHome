# 大陆镜像 Release（Gitee / GitCode）

> 研究 #29（`docs/research/2026-11-23-deep-dive/08-own-github-feedback.md`）：macOS 未公证、Windows 未签名，加上 GitHub 在大陆的不稳定，用户已经在**自己**用 GitCode 镜像重建安装包（第三方 `azsummer/menubarmijia-cloudbuild` 46 次下载，超过官方 1.4.0 DMG 的 16 次）。官方镜像的意义是把这 46 次下载收回官方链路，而不是新增一个分发渠道。

## 它做什么

`finalize.yml` 里的 **`mirror-mainland` job** 在 GitRelease 发布成功之后调用 `scripts/mirror_release.sh`，把同一批已校验的附件同步到 Gitee 和/或 GitCode：

- 在镜像仓库里按同一个 tag 建一个 release（已存在就复用，重跑幂等）；
- 逐个上传 `dist/` 里的附件，镜像上已有的跳过；
- 单文件超过 100 MiB（`MIRROR_MAX_ASSET_BYTES`）时跳过并写 `::warning::`，不算失败；
- 上传失败逐个报告，最后以非零退出码结束——外层 `continue-on-error: true` 把它收成一条警告；
- 每次调用有 300 秒总预算（`MIRROR_BUDGET_SECONDS`），超时前主动停下并留下「剩余附件下次补齐」，而不是让一个卡住的连接拖到 job 超时。

两个站点的 API 形状不同，脚本各走各的：

| | Gitee | GitCode |
| --- | --- | --- |
| 建 release | `POST /releases`，表单体，响应带 `id` | `POST /releases`，**JSON** 体，响应**没有** release `id` |
| 寻址 | `releases/{id}/attach_files` | `releases/{tag}/…`，只用 tag |
| 上传 | multipart `POST attach_files` | `GET releases/{tag}/upload_url` 拿预签名地址 → `PUT` 文件（带上签名要求的 header） |

它**不会**：重新编译、改签名、改更新清单、覆盖镜像上已有的同名附件、发布草稿。

## 为什么放在 `finalize.yml` 而不是 `release.yml`

`release.yml` 只产出**草稿**，草稿的两个关键附件（`.update.json` 与应用内更新签名）由维护者在可信机器上离线补。此时同步会把一个可能被撤下、且更新清单还没签名的版本先发到大陆镜像，用户装到的就是官方从未发布过的包。`finalize.yml` 是唯一一处在校验完 10 个附件后才把 release 变公开的地方，镜像紧跟其后，语义才对齐：**GitHub 上没有的版本，镜像上也不会有**。

镜像还是一个**独立 job**（`needs: finalize` + job 级 `continue-on-error: true` + 自己的 20 分钟超时）。即使镜像站点卡死导致这个 job 被取消，`finalize` 仍然是成功状态、release 已经公开；而「草稿已发布后不能再跑 finalize」的门禁也不会被触发。

## 维护者要配的东西（一次性，全部手动）

1. **在两个镜像站点各建一个仓库**（本 PR 不创建任何账号或仓库）：
   - Gitee：<https://gitee.com> → 新建仓库，路径建议与 GitHub 完全一致 `jryang2026-code/MenuBarHome`（或任意仓库，用下面的变量覆盖）。
   - GitCode：<https://gitcode.com> → 同上。
   - 只做 Release 附件分发，**不要**镜像源码推送；镜像仓库可以设为 public。
2. **各生成一个访问令牌**，只要 release 相关权限（Gitee：`projects`；GitCode：祖传 v5 API 同款 `access_token`）：
   - Gitee → 设置 → 私人令牌。
   - GitCode → 设置 → 访问令牌。
3. **写进 GitHub 仓库 Secrets**（Settings → Secrets and variables → Actions）：

   | Secret | 用途 |
   | --- | --- |
   | `GITEE_TOKEN` | Gitee 私人访问令牌 |
   | `GITCODE_TOKEN` | GitCode 访问令牌 |

4. 需要换仓库路径时，用 **Repository variables**（不是 secret）：

   | Variable | 默认值 |
   | --- | --- |
   | `GITEE_MIRROR_REPO` | `jryang2026-code/MenuBarHome` |
   | `GITCODE_MIRROR_REPO` | `jryang2026-code/MenuBarHome` |

   值写成 `owner/repo`（不带 `https://`，不带 `.git`）。

## 行为矩阵

| 配置 | 结果 |
| --- | --- |
| 两个 secret 都没配 | 两个镜像步骤都被 `if: env.*_TOKEN != ''` 跳过，发布流程与今天完全一致 |
| 只配 `GITEE_TOKEN` | 只同步 Gitee；GitCode 步骤跳过 |
| token 失效 / 站点 5xx | 步骤 `continue-on-error: true` → 发布仍然是绿的，运行日志与 job 摘要里各有一条警告 |
| 站点接受连接后卡住 | 脚本在 300 秒预算内停下，job 也有独立超时；最坏情况只是 `mirror-mainland` 这个 job 变红，`finalize` 与 release 不受影响 |
| 重跑同一 tag | 复用已有 release，跳过已上传的附件，不重复占额度 |

发布结束的 job 摘要里会写明每个镜像「已尝试同步」还是「未配置 token，本次跳过」。

## 验证与排障

```bash
# 先用尽量便宜的方式确认脚本本身没问题（离线，不需要任何 token）
bash scripts/test_mirror_release.sh

# 手动补一次镜像（维护者本机，token 只放在环境变量里，不要写进命令历史）
GITEE_TOKEN=*** GITEE_MIRROR_REPO=owner/repo MIRROR_BUDGET_SECONDS=300 \
  bash scripts/mirror_release.sh gitee v1.5.0 1.5.0 /path/to/dist
```

排障要点：

- **HTTP 401**：token 过期或没有 release 权限。
- **HTTP 404 且日志里是创建 release 那一步**：镜像仓库不存在，或 `*_MIRROR_REPO` 写错（必须是 `owner/repo`）。
- **上传被跳过**：单文件超过 `MIRROR_MAX_ASSET_BYTES`（默认 100 MiB），镜像站点的单附件上限通常就在这里。
- **「时间预算用尽」**：300 秒内没传完，重跑一次（release 与已传附件会被复用）或调大 `MIRROR_BUDGET_SECONDS`（同时确认 job 的 `timeout-minutes` 够）。
- **想临时停掉某个镜像**：删掉对应 secret 即可，下一次发布该步骤自动跳过。

## 安全边界

- 令牌只存在于 GitHub Secrets 和 job 环境变量里，脚本只把它放进请求体/查询串，从不 `set -x`，也不打印带 token 的 URL。
- 镜像只承载公开产物（DMG / EXE / MSI / SBOM / `.sha256` / 更新清单与签名）。Ed25519 私钥不进 CI，镜像也无法伪造更新清单——应用内更新仍然只认 `UpdateChecker.swift` 里内置公钥验证过的那份。
- 令牌权限收敛到 release：即使泄漏也改不了仓库代码、发不了能把用户带到别处的更新。
