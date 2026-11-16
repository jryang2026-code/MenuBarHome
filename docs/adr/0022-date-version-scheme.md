# ADR-0022：1.3.0 之后的发布版本改为上海日期 `YY.M.DDNN`

日期：2026-11-16　状态：已接受

## 背景

`v1.3.0` 已经发布。下一版仍要让已经装上的客户端认成“更新的三段数字”，同时让 Windows MSI 和 Cargo 能打包。把公历年直接写成 major（`2026.11.17`）做不到这两件事。本决定从下一版开始生效，不改当前 `VERSION` 与各端已经写成 `1.3.0` 的版本文件。

## 约束

这些限制是现有代码的行为，方案必须同时满足。

1. **已安装的客户端只接受恰好三段数字，并按整数比较。** Windows `is_release_version`（`windows/src-tauri/src/update_manifest.rs`）要求恰好 3 段、每段非空且全是 ASCII 数字。签名脚本 `isReleaseVersion`（`scripts/sign_update.swift`）和 macOS 清单解析 `UpdateManifest.isReleaseVersionText`（`Sources/MijiaCore/UpdateManifest.swift`）是同一条规则。macOS `AppVersion`（`Sources/MijiaCore/UpdateChecker.swift`）把每一段解析成整数再逐段比较；它会删掉末尾值为 0 的段（所以 `1.3.0` 与 `1.3` 相等），不会改写段内的数字。因此 `26.11.1710` 的第三段仍是 1710。Windows `compare_versions` 同样按整数比较，缺段当作 0。这三处都不拒绝前导零：`"01".parse` 在 Rust、Swift、JavaScript 里都是 1。

2. **Windows MSI 的 ProductVersion 装不下四位年份。** 发布包同时打 NSIS 与 MSI（`windows/src-tauri/tauri.conf.json` 的 `bundle.targets`，`scripts/check_release.sh` 强制两者都在）。打包用的 `@tauri-apps/cli` 2.12.3（`windows/package-lock.json`）在 `tauri-bundler` 的 `validate_wix_version` 里拒绝 major 或 minor 大于 255、patch 大于 65535（`crates/tauri-bundler/src/bundle/windows/msi/mod.rs`，tag `tauri-cli-v2.12.3`）。`2026` 作为 major 会在 MSI 步骤失败。`convert_version` 还先调用 `semver::Version::parse`。

3. **Cargo 与 semver 禁止前导零。** `windows/src-tauri/Cargo.lock` 锁定 `semver` 1.0.28。它的 `numeric_identifier` 在数值仍为 0 又读到下一位数字时返回 `LeadingZero`。单独的 `0` 合法，所以 `1.3.0` 仍然是合法版本。`01.3.0` 写不进 `Cargo.toml`。

4. **顺序必须单调，并且大于 `1.3.0`。** 比较是整数而不是字符串。年减 2000 放在 major，月放在 minor（不补零，所以 9 月是 9，排在 10 月前面），日用 `日 × 100 + 当天序号` 放在 patch。同一天序号从 1 计到 99：11 月 17 日第一版是 `26.11.1701`，第二版是 `26.11.1702`；12 月 5 日第一版是 `26.12.501`，而不是 `26.12.0501`。序号停在 99，是为了不占用下一天的号码（17 日的 99 是 1799，18 日从 1801 起）。`26.*` 的 major 大于 1，所以新版本大于 `1.3.0`。

Homebrew cask 更新脚本另外要求每一段是 1 到 4 位数字（`packaging/homebrew/update_cask.sh`）。本方案最大的 patch 是 31 日序号 99，即 3199，仍在这 4 位以内。cask 脚本不负责拒绝 MSI 越界或前导零。

## 决定

1. 机器版本是 `YY.M.DDNN`。`YY = 公历年 − 2000`，`M` 是月且不补零，`DDNN = 日 × 100 + 当天序号`，序号从 1 开始，最大 99。没有前导零。
2. 给人看的标签是 `YYYY.MM.DD（vN）`。月和日补成两位，括号是全角，`N` 是当天序号。2026-11-17 的第一版显示为 `2026.11.17（v1）`，2026-12-05 的第一版显示为 `2026.12.05（v1）`。这只是展示，不写入 `VERSION`。
3. `scripts/next_version.sh` 用 Asia/Shanghai 的当天日期，再看仓库里已有的 `v*` 发布标签，算出下一个机器版本。同一天已有标签时取最大序号加 1，不回填空号（空号可能已经小于当天更大的标签）。结果必须严格大于 `1.3.0`，也必须严格大于每一个已有的三段发布标签；否则脚本失败，而不是发出一个客户端会当成“更旧”的号。`--label` 只打印给人看的标签。
4. `scripts/check_release.sh` 的 `tag`（以及附件版本）在原有的“三段数字”之外，拒绝前导零和 MSI 上限之外的值。`1.3.0`、`26.11.1701`、`26.12.501` 和上限 `255.255.65535` 仍然通过。

| 上海日期 | 当天序号 | 机器版本 | 给人看的标签 |
| --- | --- | --- | --- |
| 2026-11-17 | 1 | `26.11.1701` | `2026.11.17（v1）` |
| 2026-11-17 | 2 | `26.11.1702` | `2026.11.17（v2）` |
| 2026-12-05 | 1 | `26.12.501` | `2026.12.05（v1）` |

## 后果

- 下一版发布时把 `next_version.sh` 的机器版本写入 `VERSION`，以及 `check_release.sh tag` 与之对照的 Windows 与 `scripts/mijia` 版本字段。本 ADR 不改这些文件，已安装的 `1.3.0` 不受影响。
- 应用内更新界面直接拼接版本字符串，没有按“版本号很小”来截断或改比较方式。macOS 设置页（`UpdateSection`）和经典面板页脚（`ClassicControlCenterPanelChrome.updateBadgeTitle`，文案是 `更新 v<version>`）会多出几个字符；页脚状态文字有 `lineLimit(1)`，徽章本身没有截断。Windows 设置里的 `发现新版本 v{version}` / `当前版本 v{version}`（`.cc-update-row`）和托盘菜单 `有新版本 v{version}，点击查看` 同样是整段字符串；托盘 tooltip 不含版本号。`ReleaseNotesDigest` 与 Windows `renderReleaseNotesMarkdown` 把 Markdown 标题当分段，不解析版本号。macOS 只把 1 到 3 位数字加 `. ` 认成有序列表，这不影响 `## 26.11.1701` 这种标题，也不影响以 `-` 开头的条目。`CHANGELOG.md` 的 `## <version>` 标题没有位数假设。本决定不改这些界面。
- 同一天的第 100 个发布（序号超过 99），或算出的号码不大于已有标签时，脚本失败，需要换一天或先处理那枚标签。2256 年及以后 major 会超过 255，那是另一代版本方案的事。

## 相关

- [ADR-0005](0005-update-signing-trust-chain.md)（更新清单信任链；`--min-from` 仍是三段数字）
- [docs/agents/in-app-update.md](../agents/in-app-update.md)
- `scripts/next_version.sh`、`scripts/check_release.sh`
