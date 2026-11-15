# 常见问题（FAQ）

[← 返回 README](../README.zh-CN.md)

下面的数据测自过去的某个版本（见各节说明），不是当前版本。引用前请先用 `scripts/measure_footprint.py` 重新测量。

## MenuBarHome 占用多少内存和 CPU？

macOS 版是单个原生 AppKit / SwiftUI 进程，没有内嵌浏览器内核。以下为 2026-11-07 在 Apple 芯片 Mac（10 核，macOS 27.0.1）上使用 MenuBarHome 1.1.7 (426) 的实测值（已接入十余台设备，含 1 台摄像机）：

| 状态 | RSS 常驻内存 | CPU（单核占比） |
| --- | --- | --- |
| 后台静置（面板关闭） | 159 MB | 0.1% |
| 面板展开（无操作） | 147 MB | 0.1% |
| 按住 Option-M 语音输入 | 152 MB | 26% |

- **RSS** 来自 `ps` 的常驻集大小；活动监视器「内存」列（物理内存占用）同一状态下约为 146 MB。
- **CPU** 为单核占比，由连续三个采样窗口（默认每段 5 秒）的 CPU 时间增量计算得出。`ps %cpu` 是进程全生命周期平均值，忙碌结束后很长时间仍会偏高，因此测量脚本不采用它。
- 展开面板复用同一进程，无交互时 RSS 基本不变，CPU 接近于零。
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
