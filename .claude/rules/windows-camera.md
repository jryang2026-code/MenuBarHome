---
paths:
  - "windows/src-tauri/**/*"
  - "windows/build-win.bat"
  - "windows/scripts/*.sh"
  - "windows/scripts/*.ps1"
  - "windows/src/**/camera*.ts"
  - "windows/tests/camera*.test.ts"
  - ".github/workflows/camera-bin.yml"
---

# Windows 摄像机实时流与 Tauri 打包约束

完整协议、排障回路与 FFmpeg 裁剪参数见 `docs/agents/windows-camera.md`。

- **P2P 会话 1 分钟冷却（禁关窗即停流）**：承载过视频的单 P2P 会话需 1 分钟以上自我回收；关后 0.3–2.5s 内重连会退化至 0–14 fps（卡首帧）。关闭小窗必须只做隐藏保温（`display:none` + 常驻同一 `<img>` 持续消费），仅在 `cameraKeepAliveMs`（默认 120s）到期、面板关闭、切设备或重连时才拆桥并发 `stop-stream`（`siid=9 aiid=2`）。
- **后端串行锁 + 前端代次检查**：`CAMERA_BRIDGE_LOCK` 全程串行 `start_xiaomi_camera_bridge` / `stop_xiaomi_camera_bridge`，前端每次 `await` 后核对 `liveCameraToken`，防止交错拆掉新桥。
- **UDP 广播打洞与显示格式**：CS2 握手只响应子网广播 `<网段>.255:32108`，必须经 `127.0.0.1:<随机>` 本地 UDP 中继转发；WebView2 必须用 `ffmpeg:<raw>#video=mjpeg` + `<img>`（MP4 渐进流永久缓冲、WebRTC 虚高时间戳累积延迟），**严禁加 `#width=`**（破坏 HEVC 解码报 `Could not find ref with POC`），`go2rtc.yaml` 日志级别用 `error`（`quiet` 非法，退回 `-v NoLevel` 致 ffmpeg 全败）。
- **Helper 内置与无弹窗**：安装包在 `src-tauri/camera-bin/` 内置 `go2rtc.exe`（1.9.15）与裁剪版 LGPL `ffmpeg`（7.1.2，PE Subsystem 改为 `2` GUI + `CREATE_NO_WINDOW` 防黑框闪屏），首次运行拷入 `%LOCALAPPDATA%\MenuBarMijia\bin`（MSI 安装目录可能只读）；`camera-bin/README.md` 必须保留以防 `bundle.resources: ["camera-bin/*"]` 空匹配。
- **Tauri 本机与 CI 构建静默坑**：本机默认 GNU 工具链会让 `tauri build` 构建脚本崩 `0xc0000005` 且 CLI **仍报 `exit 0`**——看构建日志并用 `windows/build-win.bat`（切 `vcvars64` + 清 `CC`/`CXX` + `stable-x86_64-pc-windows-msvc` + `npm run tauri -- build --target x86_64-pc-windows-msvc`）；MSYS2 下 `RUNNER_TEMP` 含 `D:`，GNU `tar` 会把盘符当远程主机，须 `cygpath -u` + `tar --force-local`。
