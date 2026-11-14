# Windows 摄像机实时画面与 Helper 打包参考

适用：MenuBarHome Windows 客户端（Tauri + WebView2）米家摄像机实时流（`MISS CS2 / TUTK P2P → 本地 UDP 中继 → go2rtc → MJPEG`）、实机验证与安装包 Helper 内置。

## 1. 链路架构与协议要点

1. **云端唤醒与密钥协商**：
   - 取设备 `localip`（`home/device_list` 或 `v2/home/device_list_page`）。
   - 先调 `miotspec/action` `siid=9 aiid=2`（`stop-stream`）再调 `siid=9 aiid=1`（`start-p2p-stream`）。
   - 生成 X25519 密钥对（取 SPKI/PKCS8 DER 末 32 字节 hex），`POST /app/v2/device/miss_get_vendor`（`support_vendors: "TUTK_CS2_MTP"`），返回 `vendor.vendor`（`1=tutk`、`4=cs2`）、`public_key`、`sign`、`vendor_params.p2p_id`；老机型回退 `/device/devicepass`。报 `no p2pid allocated, please reboot device` 表示设备未上电或离线。
2. **本地 UDP 广播打洞中继**：
   - CS2 摄像机不响应单播 `<cam_ip>:32108`，只响应子网广播 `<网段>.255:32108`；go2rtc 绑 `0.0.0.0` 直发单播会超时。
   - 本机起 UDP 中继（`127.0.0.1:0` ↔ 路由到摄像机的本机网卡 IP，`set_broadcast(true)`）：收到 `f1 30` 同时发 `<网段>.255:32108` 与单播 `:32108`；收到 `0x41` 原样回给摄像机动态来源端口，再收 `0x43` 后转发后续报文。`xiaomi://` 必须带端口写 `127.0.0.1:<relay_port>`。
3. **显示格式、鉴权 IPC 拉流与自适应帧率铁律**：
   - 转码源固定用 `ffmpeg:cam_raw_<did>#video=mjpeg`（流名 `cam_mjpeg_<did>`），但前端**严禁**裸连 `<img src="http://127.0.0.1:1984/...">`：`go2rtc` 由 Rust 分配随机回环端口（`FORBIDDEN_GO2RTC_PORTS` 显式拒绝 `1984`/`8554`/`8555`），开启 `local_auth: true` HTTP Basic Auth 并写入 `go2rtc.owner` 校验归属。
   - 前端 `CameraLiveController.pumpAuthenticatedMjpeg` 通过 Tauri IPC `invoke<string>("go2rtc_jpeg_frame", { src })` 经服务端 Basic Auth 拉取 `/api/frame.jpeg?src=cam_mjpeg_<did>` 的 Base64 帧，写入常驻 `<img>`（`img.src = "data:image/jpeg;base64,..."`，`document.createElement("img")` 只创建一次，DOM 重绘时 `replaceChildren(sameImg)` 防闪烁）。
   - **自适应帧间隔调度（`computeNextFrameGapMs`）**：可见且收到动态新帧时按 `cameraActiveFrameGapMs = 45ms`（约 20fps 上限，扣除当次 IPC 耗时后保底 `12ms`）流畅拉流；连续收到相同帧时从 `cameraIdleFrameGapMs = 250ms` 阶梯退避至最高 `500ms` 省电；隐藏保活期间（`liveCameraHidden = true`）降频至 `cameraHiddenFrameGapMs = 400ms` 维持上游转码不断流。
   - 禁用 `stream.mp4`（WebView2 永久缓冲 0:00）与 WebRTC（摄像头 RTP 时间戳虚高导致持续累积 18s+ 延迟）。
   - **严禁加 `#width=`**：会破坏 HEVC 参考帧解码，直接报 `500 Could not find ref with POC`。
   - `go2rtc.yaml` 中 `log.ffmpeg` 用 `error`（`quiet` 非法，退回 `NoLevel` 传 `-v NoLevel` 致转码全败）。

## 2. P2P 会话冷却与单主生命周期

- **1 分钟会话冷却与同会话退避**：单 P2P 会话承载视频后需 1 分钟以上由固件侧自我回收。新会话 326–412 帧/12s（首帧 1–3s）；关闭后立即重开会退化至 0–14 fps（卡首帧、HTTP 0 字节），因此前端对同一台摄像机重协商前执行 `cameraSameSessionCooldownMs = 2500ms` 退避（跨摄像机切换则跳过）；高频连测打入深度拒绝后须静置 5 分钟以上。
- **隐藏保温（120s）**：关闭小窗只设 `liveCameraHidden = true`（`display:none` + `400ms` 低频保活拉帧），常驻 `<img>`、UDP 中继与 ffmpeg 保持热态，120 秒内重开秒出画；仅在 `cameraKeepAliveMs`（默认 `120_000ms`）到期、主面板收起、切设备、退出米家账号或异常重连时才调 `stop_xiaomi_camera_bridge` + `stop-stream`。
- **串行与代次守卫**：Rust 端 `CAMERA_BRIDGE_LOCK`（async Mutex）全程串行 `start_xiaomi_camera_bridge` / `stop_xiaomi_camera_bridge`；前端用 `liveCameraToken` 在每个 `await` 后核对代次，过期桥启动后立即补发回收。

## 3. Helper 内置与 Windows 构建坑

- **内置二进制**：`src-tauri/camera-bin/` 打包 `go2rtc.exe`（v1.9.15，SHA-256 `5b448fc90f15c925406d8da0984301985e385050222c1c2bbdf0a76fe4b1e9cb`）与最小化 LGPLv2.1 `ffmpeg`（v7.1.2，开启 `httpproxy`/`hls`/`https`/`schannel` 与 h264/hevc→mjpeg，无 libx264，PE 头 `pe_offset + 24 + 68` 的 `Subsystem` 置 `2` GUI + `CREATE_NO_WINDOW` 防黑框闪屏，附 `GO2RTC-LICENSE.txt` 与 `FFMPEG-LICENSE.txt`）。保留已提交的 `camera-bin/README.md` 防 `bundle.resources: ["camera-bin/*"]` 空匹配。
- **运行时落地**：MSI 安装目录可能只读，首次使用从 `resource_dir().join("camera-bin")` 以临时文件原子重命名拷入 `%LOCALAPPDATA%\MenuBarMijia\bin`（不覆盖已有文件）；缺失时回退 3 次退避下载或提示手动放置路径。
- **本机与 CI 构建**：
  - 本机默认 GNU 工具链会让 `tauri build` 构建脚本崩 `0xc0000005` 且 CLI **仍报 `exit 0`**——必须看日志，构建走 `windows/build-win.bat`（`vcvars64.bat` + 清 `CC`/`CXX` + `RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-msvc` + `npm run tauri -- build --target x86_64-pc-windows-msvc`）。改了前端 TS 必须重跑 `tauri build` 才会打进内嵌 exe。
  - MSYS2 下 `RUNNER_TEMP` 为 `D:\a\_temp`，GNU `tar` 会把 `D:` 当远程主机，须 `cygpath -u` + `tar --force-local`。
  - Git Bash 调 `taskkill`/`tasklist` 加 `MSYS_NO_PATHCONV=1`；单文件测试走 `node windows/scripts/test-file.mjs <file>`（Node 22 原生剥离 TS 类型，无需额外转译器）。

## 4. 诊断与实机验证回路

1. **应用内「复制诊断」**：先看 `online`、`connectionMode`、`hasCustomURL` 与原始错误区分云端掉线、密钥协商、组件下载（`download_go2rtc_win64` 45s/120s 网络截断）与桥接转码；对外答复修复状态前用 `git tag --contains <commit>` 核实是否已进发版 tag。
2. **绕过 App 独立基线**（`.scratch/camera-diag/diag.ts`）：读凭据管理器 `mi_session.com.jryang.menubarmijia` 直跑协商 + UDP 中继 + go2rtc，数 `/api/stream.mjpeg` 12 秒内 `0xFFD9` 帧数（读取循环只丢弃计数，不做正则拼接）。健康值：326–412 帧/12s，首帧 <3s。
3. **App 内 WebView2 验证**（`cdp-drive.mjs`）：以 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=19222`（先 `netstat` 避开被 `svchost` 占用的 9223）启动安装版 exe，每 400ms 比对 `Page.captureScreenshot` PNG 哈希并核对连续 `open → close → open` 三次均出画。
