# WidgetKit 桌面小组件与 macOS 26 `ControlWidget` 在 ad-hoc 签名下的可行性调研

- **日期**：2026-11-24
- **状态**：已完成（纯可行性调研，无功能代码变更）
- **实测环境**：macOS 27.2.1（Build `26B131`）、Xcode 27.2（Build `27B52`）、`MacOSX27.2.sdk`
- **关联文档**：[ADR-0005（自签名更新链）](../adr/0005-update-signing-trust-chain.md)、[ADR-0013（伴生快照与 URL Scheme）](../adr/0013-raycast-companion-contract.md)、[ADR-0017（HomeKit 签名门槛评估）](../adr/0017-homekit-third-backend-evaluation.md)

## 一句话结论

**在维持无 Apple Developer ID / 无 Team ID（ad-hoc 或自签名）的前提下：不可行（Not feasible without a Developer ID）。**

本机实测确认了三条关键边界：
1. **编译与 `pluginkit` 注册本身可过**：纯 `swiftc` 无需 Xcode 工程即可编出包含 `Widget` 与 macOS 26 `ControlWidget` 的 `.appex` 二进制，ad-hoc 签名后 `codesign --verify --deep --strict` 与 `pluginkit -m` 均通过。
2. **`chronod` 在运行时直接丢弃 ad-hoc 扩展**：即使置于 `~/Applications`、经 `lsregister -f` + `pluginkit -a` + `open -W` 注册，且宿主与扩展均开启 `com.apple.security.app-sandbox`，系统守护进程 `chronod` 仍立即报错 `Requested to add extension, but purging instead because we shouldn't cache it` 并清空描述符缓存，导致小组件与 `ControlWidget` 均无法出现在 Widget Gallery 或控制中心。
3. **App Group 容器读写被 macOS 拦截**：ad-hoc 签名下，无论 `group.*` 还是 `<TeamID>.*` 格式的 `com.apple.security.application-groups` 均在写入时返回 `NSCocoaErrorDomain Code=513`（权限被拒）；虽可用 `com.apple.security.temporary-exception.files.home-relative-path.read-only` 绕过沙盒文件读取，但无法绕过 `chronod` 对 ad-hoc 扩展本身的拒收。

---

## 1. 当前构建、打包与签名链路核查

基于仓库当前源码（未运行 `scripts/build_app.sh`）：

| 环节 | 源码位置 | 现状与关键细节 |
| --- | --- | --- |
| SwiftPM 清单 | [`Package.swift`](../../Package.swift) | SwiftPM 6.0，`.macOS(.v14)`；仅定义 `MijiaCore` 库目标与 `MenuBarMijiaApp` 可执行目标，无 `.appex` 扩展目标，也无 `.xcodeproj`。 |
| 应用组装与签名 | [`scripts/build_app.sh`](../../scripts/build_app.sh) | `swift build -c release --product MenuBarMijiaApp --arch arm64 --arch x86_64` 产出通用二进制 → 手工组装 `MenuBarHome.app/Contents/{MacOS,Resources}`（含 `MenuBarMijia_MijiaCore.bundle`、通用架构带 PTZ 补丁的 `go2rtc`、`Info.plist`：`com.jryang1997.MenuBarMijia`，`LSUIElement=true`）→ 调 `xcodebuild`（必要时回退 `appintentsmetadataprocessor`）提取 `Metadata.appintents/extract.actionsdata` → 代码签名。 |
| 本地与发布签名分流 | [`scripts/build_app.sh`](../../scripts/build_app.sh)（L27-62, L478-505）、[`scripts/release.sh`](../../scripts/release.sh)（L43-121）、[`scripts/MenuBarMijia.entitlements`](../../scripts/MenuBarMijia.entitlements) | 本地未指定身份且本机钥匙串无 `"MenuBarMijia Release Signing"` 时退回 ad-hoc：`codesign --force --sign -`（**不带 entitlements、不带 Hardened Runtime**）。**正式发布（`scripts/release.sh` 与 `.github/workflows/release.yml`）已禁止 ad-hoc**：强制要求固定自签名 RSA-3072 证书 `"MenuBarMijia Release Signing"`（无 Apple Developer Team ID，非 Apple 信任链，见 [ADR-0005](../adr/0005-update-signing-trust-chain.md)），启用 `--options runtime` 与 `scripts/MenuBarMijia.entitlements`（仅含麦克风、日历、定位三项，**未开 App Sandbox**），不加 `--timestamp`，并将证书 SHA-1 写入 `Info.plist` 的 `MijiaCodeSignCertSHA1`；CI 中 `SKIP_NOTARIZE=1`。 |
| 持续集成与发版工作流 | [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)、[`.github/workflows/release.yml`](../../.github/workflows/release.yml) | `ci.yml` 在 `macos-26-intel`（Xcode 26.6）上分别跑 `macos-test`、`macos-appintents`（`APP_INTENTS_ONLY=1`）和 `macos-release`（`ARCHS=native SKIP_APP_INTENTS=1 bash scripts/build_app.sh`，ad-hoc 签名）。`release.yml` 导入 `MACOS_SIGNING_P12` 自签名证书并调用 `scripts/release.sh` 产出未公证 DMG、`sha256` 与 SPDX SBOM。 |

> **关键现状**：本仓库对外分发并不使用裸 ad-hoc，而是使用**无 Apple 信任链、无 Team ID（`TeamIdentifier=not set`）、无 Provisioning Profile** 的自签名证书；本地开发与 CI 冒烟构建则使用 ad-hoc（`-`）。二者在 `chronod` 与 macOS App Group 校验上缺少的正是同一套 Apple Developer 身份（Team ID + Apple 信任链 / 描述文件）。

---

## 2. SwiftPM 能否产出 `.appex` 扩展？最小构建链改动是什么？

### 2.1 实测结论：纯 `swiftc` / SwiftPM 可以编出 `.appex` 二进制，不强制依赖 `.xcodeproj`

在仓库外的临时目录中，用一份单文件 Swift 源码同时声明 `Widget`（`StaticConfiguration`）与 `@available(macOS 26.0, *) ControlWidget`（`StaticControlConfiguration` + `ControlWidgetToggle` + `SetValueIntent`），通过 `@main struct SpikeWidgetBundle: WidgetBundle` 入口编译：

```bash
xcrun swiftc -O -parse-as-library -application-extension \
  -target arm64-apple-macos14.0 WidgetMain.swift -o SpikeWidgetBin
```

实测结果：
- 编译退出码 `0`，链接 `WidgetKit` / `SwiftUI` / `AppIntents`，输出含 `_main` 符号的 Mach-O 可执行文件。
- 手工将其按 macOS App Extension 目录规范装入 `SpikeHost.app/Contents/PlugIns/SpikeWidget.appex/Contents/MacOS/SpikeWidget`，配 `Info.plist`（`CFBundlePackageType = XPC!`、`CFBundleIdentifier = <host>.widget`、`NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`），由内向外签名后，`codesign --verify --deep --strict --verbose=2` 通过。

### 2.2 若未来具备 Developer ID，最小构建链改动

| 方式 | 做法 | 适用边界 |
| --- | --- | --- |
| **方案 A（最小改动，延续脚本组装）** | 1. `Package.swift` 新增 `MenuBarMijiaWidget` 可执行目标（或由 `scripts/build_app.sh` 调 `swiftc -parse-as-library -application-extension` 编译通用架构）；<br>2. `scripts/build_app.sh` 组装 `Contents/PlugIns/MenuBarHomeWidget.appex`，并复用现有 `appintentsmetadataprocessor` 流程为 `.appex` 生成 `Contents/Resources/Metadata.appintents/extract.actionsdata`（`ControlWidget` 与 `AppIntentConfiguration` 必需）；<br>3. 按「`go2rtc` → `.appex`（带沙盒与 App Group entitlements）→ `.app`」顺序由内向外 `codesign`。 | 适合仅使用 `<TeamID>.<group>`（无需嵌入 `.provisionprofile`）的 Developer ID 直接分发场景；注意 SwiftPM 中若使用 `.unsafeFlags(["-application-extension"])` 会阻止该包被其他 SwiftPM 包引用（对本应用仓无影响）。 |
| **方案 B（轻量 `.xcodeproj` / `xcodegen` 包装层）** | `MijiaCore` 保持纯 SwiftPM（守住 [ADR-0003](../adr/0003-core-builds-on-linux.md) Linux 编译约束）；仅用轻量 Xcode 工程承载 App + Widget Extension 两个 target，统一处理 `ExtractAppIntentsMetadata`、Asset Catalog、`.provisionprofile` 嵌入与签名。 | 若使用 iOS 风格 `group.*` App Group、需要嵌描述文件、或后续要上 Mac App Store / TestFlight，方案 B 维护成本显著低于手工脚本。 |

---

## 3. ad-hoc 签名（`codesign -s -`、无 Team ID）本机实测证据

所有实验均在仓库外临时目录（`/tmp/widgetkit-spike-*` 与临时 `~/Applications/SpikeHost*.app`）执行，未触碰 `/Applications` 或用户已安装的 `MenuBarHome.app`，实验结束后已通过 `pluginkit -r`、`lsregister -u` 与 `rm -rf` 清理。

### 3.1 `pluginkit` 注册与 `chronod` / Widget Gallery / `ControlWidget` 行为

构建包含 `Widget` + macOS 26 `ControlWidget` 的 `SpikeHost.app/Contents/PlugIns/SpikeWidget.appex`，分别测试了：
- **实验 2**：`/tmp/widgetkit-spike-exp2/SpikeHost.app` 与 `$HOME/.tmp-widgetkit-spike/SpikeHost.app`（扩展开沙盒、宿主不开沙盒，ad-hoc 签名）
- **实验 2c / 3**：`$HOME/Applications/SpikeHost3.app`（补充 `CFBundleSupportedPlatforms = ["MacOSX"]`，**宿主与扩展同时开启 `com.apple.security.app-sandbox = true`**，ad-hoc 由内向外签名，执行 `lsregister -f`、`pluginkit -a`、`open -W`）

实测结果一致：

1. **`pluginkit` 列表可见**：
   ```text
   $ pluginkit -m -v -i com.example.widgetspike3.host.widget
        com.example.widgetspike3.host.widget(1.0)	A91BD276-84F0-4ECD-9934-AFCF3F1A255C	2026-11-24 07:22:28 +0000	/Users/yangzhiyuan/Applications/SpikeHost3.app/Contents/PlugIns/SpikeWidget3.appex
    (1 plug-in)
   ```
   `pluginkit -m -D -v -p com.apple.widgetkit-extension` 同样列出该扩展。
2. **但 `chronod` 立即拒收并清除描述符缓存**（`/usr/bin/log show --predicate 'process == "chronod"'` 原始日志）：
   ```text
   chronod[723]: [com.apple.chrono:extensions-verbose] Added extensions: [<WidgetExtension - identifier: com.example.widgetspike3.host::com.example.widgetspike3.host.widget, version: 1, containerVersion: 1, lastModifiedDate: 1970-01-01T08:00:00+08:00 isApple: false>]
   chronod[723]: [com.apple.chrono:descriptor] Queuing extension added events: com.example.widgetspike3.host::com.example.widgetspike3.host.widget
   chronod[723]: [com.apple.chrono:descriptor] Requested to add extension, but purging instead because we shouldn't cache it: <WidgetExtension - identifier: com.example.widgetspike3.host::com.example.widgetspike3.host.widget, version: 1, containerVersion: 1, lastModifiedDate: 1970-01-01T08:00:00+08:00 isApple: false> - isApple? false
   chronod[723]: [com.apple.chrono:descriptor] Purging descriptors for extensions: [com.example.widgetspike3.host::com.example.widgetspike3.host.widget]
   chronod[723]: [com.apple.chrono:database] Clearing descriptor cache for com.example.widgetspike3.host.widget
   chronod[723]: [com.apple.chrono:reloadService] Error setting last requested reload date for key: <_ReloadStateKey: extensionBundleIdentifier=com.example.widgetspike3.host.widget, kind=all>: Error Domain=com.apple.baseboard.bssqlite Code=19 "constraint failed" UserInfo={NSLocalizedDescription=constraint failed, NSLocalizedFailureReason=FOREIGN KEY constraint failed}
   ```
3. **Widget Gallery 与 `ControlWidget` 结果**：
   - 由于 `chronod` 在发现扩展的同一毫秒即将其描述符从 SQLite 缓存清除，小组件**不会出现在 macOS Widget Gallery**，后续 `WidgetCenter.shared.reloadAllTimelines()` 与 `ControlCenter.shared.reloadAllControls()` 也因数据库外键缺失（扩展记录已被 purge）无法刷新。
   - **关于 `ControlWidget`**：macOS 26 的 `ControlWidget` 与桌面 `Widget` 共用同一个 `com.apple.widgetkit-extension` 扩展点，且同样由 `chronod`（日志子系统 `com.apple.chrono:controlCenterServer`）托管发现与刷新；此外 `AppIntentControlConfiguration` / `SetValueIntent` 还要求 `.appex` 内携带 `Metadata.appintents`。因此在 ad-hoc 签名下，`ControlWidget` 与桌面 `Widget` 被同一道 `chronod` 门槛拦住，无法工作。

> **事实与推断区分**：本机无付费 Apple Developer ID 证书（与 [ADR-0017](../adr/0017-homekit-third-backend-evaluation.md) 一致），因此未能做「同一 `.appex` 换 Developer ID 签名后被 `chronod` 接受」的阳性对照。但结合本机实测（ad-hoc 在 `~/Applications` + 双端沙盒 + `lsregister` + `open -W` 下仍被 `chronod` 立即 purge）与社区/Apple 报告（`chronod` 与 ExtensionKit 对第三方 WidgetKit 扩展要求有效 Apple 签名身份与 Team ID 绑定），可以确认 **ad-hoc 签名无法交付可用的 Widget Gallery / Control Center 体验**。

### 3.2 App Group 容器（`com.apple.security.application-groups`）与替代数据通道实测

实验 1 / 1b 编译探针进程（测试 `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` 写入与宿主目录文件读取），在 ad-hoc 签名（`codesign --force --sign -`）下逐项运行：

| 实验组 | 形态与 Entitlements | 退出码 | App Group 容器读写 | 读取宿主 `Application Support` 文件 |
| --- | --- | --- | --- | --- |
| 1a 裸二进制对照组 | 无 bundle、无 entitlements | `0` | 路径返回，无容器目录 | `OK` |
| 1b 裸二进制 + 沙盒 | 无 bundle、`app-sandbox = true` | `133`（`SIGTRAP`） | `libsecinit` 因缺 `CFBundleIdentifier` 直接陷阱退出 | — |
| 1c `.app` + 仅沙盒 | `app-sandbox = true` | `0` | `NSCocoaErrorDomain Code=513`（权限被拒） | `Code=257`（沙盒拦截） |
| 1d `.app` + iOS 风格 App Group | `app-sandbox = true` + `application-groups = ["group.com.example.widgetspike"]` | `0`（**未被 `amfid` SIGKILL**） | `containermanagerd` 创建目录，但写入报 **`NSCocoaErrorDomain Code=513`** | `Code=257` |
| 1e `.app` + macOS TeamID 风格 App Group | `app-sandbox = true` + `application-groups = ["ABCDEFGHIJ.com.example.widgetspike"]` | `0` | 写入同样报 **`NSCocoaErrorDomain Code=513`**（ad-hoc 无匹配 Team ID） | `Code=257` |
| 1f `.app` + 只读临时例外 | `app-sandbox = true` + `com.apple.security.temporary-exception.files.home-relative-path.read-only = ["/Library/Application Support/WidgetSpikeTest/"]` | `0` | `Code=513` | **`OK:{"ok":true,"from":"host"}`** |

结论与 Apple 规则对齐：
- 与 `com.apple.developer.homekit`（[ADR-0017](../adr/0017-homekit-third-backend-evaluation.md) 中 `amfid` 直接 `SIGKILL 137`）不同，macOS 上的 `com.apple.security.application-groups` 不会阻止进程启动；但在 macOS 15 Sequoia 及以上系统，Apple 收紧了 App Group 容器的跨应用数据保护（见 Apple Developer Forums / Quinn *"App Groups: macOS vs iOS: Working Towards Harmony"*）：无缝访问 App Group 容器要求满足四者之一——Mac App Store 分发、TestFlight 分发、组 ID 以进程实际签名证书的 **Apple Team ID** 开头、或由嵌入的 **Provisioning Profile** 授权。ad-hoc（及无 Team ID 的自签名证书）四项皆不满足，因而被系统拒绝读写（GUI 场景会弹「想要访问其他 App 的数据」或后台扩展直接静默 `EPERM/513`）。
- **替代方案评估**：
  1. **只读临时例外直读宿主快照（实验 1f 已验证可用）**：非 Mac App Store 分发时，`com.apple.security.temporary-exception.files.home-relative-path.read-only` 是 macOS 非受限权限，沙盒扩展可直接读取非沙盒主程序写入的 `~/Library/Application Support/MenuBarMijia/raycast-snapshot.json`（或专用 `widget-snapshot.json`），零凭据暴露、零 App Group 依赖。
  2. **纯静态跳转小组件（零数据读取）**：不读任何状态，仅作为快捷按钮通过 `widgetURL` / `Link` 唤起 `menumijia://` URL Scheme。
  - **局限**：上述替代方案只解决了「数据怎么给扩展」，**解决不了 3.1 节中 `chronod` 拒收 ad-hoc `.appex` 的根本障碍**。

---

## 4. Gatekeeper 与 Quarantine（隔离属性）影响

当用户从 GitHub Releases 下载未公证（ad-hoc 或自签名）的 DMG 并拖入 `/Applications` 时：

1. **递归隔离属性**：浏览器下载的 DMG 带有 `com.apple.quarantine`，拖出的 `MenuBarHome.app` 及其内部的 `Contents/PlugIns/*.appex` 会递归继承该属性。
2. **macOS 15 Sequoia / 26+ Tahoe 拦截升级**：系统已移除右键「打开」快捷绕过；用户首次双击会直接被 Gatekeeper 拦截，必须进入「系统设置 → 隐私与安全性 → 仍要打开」，或手工执行 `xattr -dr com.apple.quarantine /Applications/MenuBarHome.app`。
3. **嵌套 `.appex` 的额外断层**：仅通过「隐私与安全性」放行宿主 `.app`，并不能可靠清除或豁免 `Contents/PlugIns/*.appex` 的隔离属性与签名校验；如果 `.appex` 仍带隔离属性或未按由内向外顺序严格签名，ExtensionKit / `chronod` 会静默忽略扩展（用户无任何错误提示，只在 Widget Gallery 里「搜不到」）。
4. **与本仓库现有自更新链的关系**：[ADR-0005](../adr/0005-update-signing-trust-chain.md) 中 `AppUpdater.shouldStripQuarantine(currentAppIsAdHoc:)` 仅在**应用内自更新**时替非 Apple 锚定构建清除隔离属性；用户首次下载 DMG 安装依然完全暴露在 Gatekeeper 拦截下。

---

## 5. 结论、真实实现规模估算与重启条件

### 5.1 最终判定

**`Not feasible without a Developer ID`（无 Apple Developer ID 不可行）。**

这与 [ADR-0017](../adr/0017-homekit-third-backend-evaluation.md) 对 `#11`（付费账号 + Developer ID 签名/公证）与 `#58`（WidgetKit / `ControlWidget`）同属一道门槛的判断完全一致，并由本机 `chronod` 与 `containermanagerd` 实测数据补齐了直接证据。

### 5.2 在无 Developer ID 期间的现成替代路径

以下能力均已在仓库落地且不受 `chronod` 签名门槛限制：
- 菜单栏状态图标与常驻读数（Pinned Readouts）；
- `AppIntents`（快捷指令 / Siri / Spotlight，已由 `scripts/build_app.sh` 提取 `Metadata.appintents`）；
- `menumijia://` / `menubarhome://` URL Scheme 与只读快照（[ADR-0013](../adr/0013-raycast-companion-contract.md)），可供 Raycast、CLI、MCP 或第三方桌面组件工具（如 Übersicht）直接消费。

### 5.3 若未来具备 Apple Developer ID + Team ID（#11 落地）后的真实实现估算

- **体量估算**：**L（约 1,200–1,800 行 Swift + 打包/CI/权限配置改动）**，建议拆为 **2–3 个 PR**（1. 构建链 + 最小空壳 `.appex` + 共享快照契约；2. 桌面只读/交互式 `Widget`；3. macOS 26 `ControlWidget` + 延迟回读）。
- **高风险面命中**：命中 `AGENTS.md` 第 **1** 类（跨进程数据边界 / App Group）、第 **2** 类（设备控制写入与高风险二次确认/锁屏拦截）、第 **5** 类（打包与签名发布链），必须走 PR 且每项单独验收。
- **预计改动文件清单**：
  - 构建与打包：`Package.swift`（或新增轻量 `Xcode/` 包装工程）、`scripts/build_app.sh`、`scripts/release.sh`、`scripts/install_local_app.sh`、`scripts/ci_relevant_paths.sh`
  - 权限与签名：`scripts/MenuBarMijia.entitlements`、新增 `scripts/MenuBarMijiaWidget.entitlements`
  - CI 与发布：`.github/workflows/ci.yml`、`.github/workflows/release.yml`
  - 核心与共享快照：`Sources/MijiaCore/`（新增 `WidgetSnapshot.swift` 或复用 `RaycastSnapshot` 精简模型，保持 Linux 可编译）
  - 主 App 桥接：`Sources/MenuBarMijiaApp/AppIntents.swift`、`Sources/MenuBarMijiaApp/HomeStore.swift`（写入快照并触发 `WidgetCenter.shared.reloadAllTimelines()` / `ControlCenter.shared.reloadAllControls()`）
  - 扩展本体：新增 `Sources/MenuBarMijiaWidget/`（`WidgetBundle`、TimelineProvider、桌面卡片视图、`@available(macOS 26.0, *) ControlWidget` 与 `SetValueIntent`）
  - 文档与决策：`docs/adr/`（记录 App Group 边界与打包链变更）
