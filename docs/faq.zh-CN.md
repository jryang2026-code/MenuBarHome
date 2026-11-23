# 常见问题（FAQ）

[← 返回 README](../README.zh-CN.md)

下表标注了每行数据对应的测量版本、日期与方法；未在本轮复测的状态标注为「待测」，可使用 `scripts/measure_footprint.py` 自行采样。

## 首次打开被 macOS Gatekeeper 或 Windows SmartScreen 拦截怎么办？怎么校验安装包？

本项目未加入付费的 Apple 开发者计划，也未使用商业代码签名证书，因此首次运行下载的安装包时系统会弹出安全拦截。

### macOS（Gatekeeper）

1. 将 DMG 中的 `MenuBarHome.app` 拖入 `/Applications` 后首次双击打开，如果弹出未验证开发者提示，先点击 **「完成」**（或 **「好」**）关闭弹窗。
2. 在 **macOS 15 及以上系统**，打开 **「系统设置 → 隐私与安全性」**，向下滚动到「安全性」区域。
3. 找到关于 `MenuBarHome` 被阻止的提示，点击 **「仍要打开」**，在再次弹出的确认框中点 **「仍要打开」**，并用触控 ID 或密码确认。
4. **备选命令**：如果仍被拦截或页面上没有出现「仍要打开」按钮，可在终端移除隔离属性：
   ```bash
   xattr -dr com.apple.quarantine /Applications/MenuBarHome.app
   ```

### Windows 11（SmartScreen）

1. 双击运行从 Releases 下载的 `.exe` 或 `.msi` 安装包时，若出现蓝底 **「Windows 已保护你的电脑」** 提示。
2. 点击提示文字下方的 **「更多信息」**。
3. 在展开界面底部点击 **「仍要运行」** 即可继续安装。

### 校验下载完整性（SHA-256）

每个 GitHub Release（如 `v1.4.0`）都会为三份安装包附带对应的 `.sha256` 校验文件：

- **macOS（`MenuBarHome-1.4.0.dmg`）**：
  ```bash
  # 打印 SHA-256 并与 Release 中的 MenuBarHome-1.4.0.dmg.sha256 对照
  shasum -a 256 MenuBarHome-1.4.0.dmg
  # 若 .sha256 文件在同一目录，可直接校验
  shasum -a 256 -c MenuBarHome-1.4.0.dmg.sha256
  ```
- **Windows（PowerShell）**：
  ```powershell
  # 与 Release 中的 MenuBarHome-1.4.0-windows-x64-setup.exe.sha256 对照
  Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.4.0-windows-x64-setup.exe
  # 若下载 MSI，则与 MenuBarHome-1.4.0-windows-x64.msi.sha256 对照
  Get-FileHash -Algorithm SHA256 .\MenuBarHome-1.4.0-windows-x64.msi
  ```

如需进一步校验 GitHub Actions 构建溯源与 SBOM，见 [SECURITY.md](../SECURITY.md#verifying-release-artifacts)。

## MenuBarHome 占用多少内存和 CPU？

macOS 版是单个原生 AppKit / SwiftUI 进程，没有内嵌浏览器内核。以下「后台静置（面板关闭）」数据于 **2026-11-23** 在 **Apple M1 Pro（10 核，macOS 27.2.1）** 上对正在运行的 **MenuBarHome 1.4.0 (807)**（`MenuBarMijiaApp`，PID `96621`）实测：以只读方式执行 `ps -o cputime=,rss= -p <pid>`，间隔 `139.3` 秒采样两次累计 CPU 时间做差分（`211.72s - 210.07s = 1.65s`，`1.65 / 139.30 ≈ 1.18%`），同时读取 `rss`（`116032 KB → 114912 KB`）。

| 状态 | RSS 常驻内存 | CPU（单核占比） | 测量版本与日期 |
| --- | --- | --- | --- |
| 后台静置（面板关闭） | 112–113 MB | 1.2% | 2026-11-23 实测（`1.4.0 (807)`，139.3s 差分） |
| 面板展开（无操作） | 待测 | 待测 | 未在本轮复测 |
| 按住 Option-M 语音输入 | 待测 | 待测 | 未在本轮复测（2026-11-07 的 `1.1.7 (426)` 基线为 152 MB / 26%） |

- **RSS** 来自 `ps -o rss=` 的常驻集大小。
- **CPU** 为单核占比，由两次 `ps -o cputime=` 采样之间的累计 CPU 时间增量除以采样间隔秒数计算得出。`ps %cpu` 是进程全生命周期平均值，忙碌结束后很长时间仍会偏高，因此不直接采用它。
- 展开面板复用同一进程；2026-11-17 合并的 PR #208 已修复面板关闭后呼吸动画常驻导致 CPU 升高的问题。
- 只有语音输入期间有明显 CPU 占用：`AVAudioEngine` 采集麦克风音频并交由系统语音框架识别；系统进程 `corespeechd` 负责底层识别，其 CPU 不计入应用自身数字。
- 实际内存取决于已接入内容：摄像机实时流、大量 MIoT 设备规格书与复杂场景都会增加占用。

## Windows 11 端占用如何？

Windows 版基于 Tauri v2 与系统 WebView2：一个宿主进程运行托盘程序（安装版为 `MenuBarHome.exe`，本地 Tauri 构建为 `menubarmijia-windows.exe`），并由一个或多个 `msedgewebview2.exe` 子进程渲染界面。`scripts/measure_footprint.py` 会汇总宿主进程及其所属渲染子进程，自动忽略其他应用的 WebView2 进程。

表格暂未收录 Windows 11 实机数据，需在 Windows 机器上托盘程序运行时执行同一脚本采集：

```powershell
python scripts\measure_footprint.py --state idle
python scripts\measure_footprint.py --state panel
python scripts\measure_footprint.py --state voice
```

## 如何复现这些测量数据？

`scripts/measure_footprint.py` 只对已在运行的进程采样，不会自行启动应用，也无法自动判断界面处于哪种状态，因此请先将应用置于对应状态再运行：

```bash
# 静置状态：关闭面板，静置一分钟后采样
python3 scripts/measure_footprint.py --state idle

# 面板展开：按 Option-M 展开面板后采样
python3 scripts/measure_footprint.py --state panel

# 语音输入：按住 Option-M 出现麦克风提示期间采样
python3 scripts/measure_footprint.py --state voice

# 输出仓库已记录基线的机器可读 JSON
python3 scripts/measure_footprint.py --no-live --json
```

实测行在 `Source` 列标记为 `live`；应用未运行时脚本会打印已提交基线并标为 `recorded`。采样前请先退出多开的副本（脚本默认采样找到的第一个 `MenuBarMijiaApp` 进程）。
