# MenuBarHome 模块与路径速查（Feature Map）

> 本文件作为跨端、多工作树开发的权威路径索引，由 `scripts/check_doc_links.py` 校验路径真实性。进入新 worktree 后，先对照此表定位，避免猜测路径。

## 核心逻辑与数据层（`Sources/MijiaCore/`）

- **状态主存与控制入口**：`Sources/MijiaCore/HomeStore.swift`、`Sources/MijiaCore/HomeStore+Backend.swift`、`Sources/MijiaCore/HomeStore+Controls.swift`、`Sources/MijiaCore/HomeStore+ControlWrite.swift`、`Sources/MijiaCore/HomeStore+Undo.swift`、`Sources/MijiaCore/HomeStore+Security.swift`
- **双源架构与设备合成**：`Shared/capability-manifest.json`、`Sources/MijiaCore/CapabilityManifest.swift`、`Sources/MijiaCore/CapabilityReferenceVerdict.swift`、`Sources/MijiaCore/HomeBackendDescriptor.swift`、`Sources/MijiaCore/HomeProvider.swift`、`Sources/MijiaCore/DualSourceHomeProvider.swift`、`Sources/MijiaCore/DeviceDeduplicator.swift`、`Sources/MijiaCore/DeviceSynthesizer.swift`、`Sources/MijiaCore/DeviceSourceIdentity.swift`、`Sources/MijiaCore/DeviceSourcePins.swift`
- **小米云端与 MIoT 协议**：`Sources/MijiaCore/MiCloud/MiAccountsProvider.swift`、`Sources/MijiaCore/MiCloud/MiAccountLogin.swift`、`Sources/MijiaCore/MiCloud/MiCloudClient.swift`、`Sources/MijiaCore/MiCloud/MiCloudProvider.swift`、`Sources/MijiaCore/MiCloud/MiotSpec.swift`、`Sources/MijiaCore/MiCloud/MiotCommandMapper.swift`
- **Home Assistant 与局域网**：`Sources/MijiaCore/HADiscovery.swift`、`Sources/MijiaCore/HAHomeSnapshot.swift`、`Sources/MijiaCore/HAPlaintextConsent.swift`、`Sources/MijiaCore/MiCloud/LocalMiIOClient.swift`
- **安全边界与凭据**：`Sources/MijiaCore/KeychainAndPrefs.swift`、`Sources/MijiaCore/CredentialVault.swift`、`Sources/MijiaCore/SafetyMonitor.swift`、`Sources/MijiaCore/ScreenLockPolicy.swift`、`Sources/MijiaCore/ManualControlPolicy.swift`
- **语音/自然语言/自动化**：`Sources/MijiaCore/CommandIntent.swift`、`Sources/MijiaCore/LocalIntentParser.swift`、`Sources/MijiaCore/AssistantConfig.swift`、`Sources/MijiaCore/AssistantSchedule.swift`、`Sources/MijiaCore/AutomationRule.swift`、`Sources/MijiaCore/AppURLCommand.swift`、`Sources/MijiaCore/UserHabitMemory.swift`
- **摄像机与云台**：`Sources/MijiaCore/CameraPTZ.swift`、`Sources/MijiaCore/CameraPTZClient.swift`、`Sources/MijiaCore/CameraLiveHandoff.swift`、`Sources/MijiaCore/MiCloud/XiaomiCameraBridge.swift`、`Sources/MijiaCore/MiCloud/CameraHubCatalog.swift`、`Sources/MijiaCore/MiCloud/CameraLensCatalog.swift`
- **应用内更新与验签**：`Sources/MijiaCore/UpdateChecker.swift`、`Sources/MijiaCore/UpdateManifest.swift`、`Sources/MijiaCore/UpdateSignature.swift`

## macOS 桌面端界面（`Sources/MenuBarMijiaApp/`）

- **应用入口与面板宿主**：`Sources/MenuBarMijiaApp/MenuBarMijiaApp.swift`、`Sources/MenuBarMijiaApp/MenuBarPanelController.swift`、`Sources/MenuBarMijiaApp/MenuBarPanelController+Presentation.swift`、`Sources/MenuBarMijiaApp/URLCommandHandler.swift`、`Sources/MenuBarMijiaApp/HotkeyAndNotificationManager.swift`
- **现代控制中心主题（Liquid Glass）**：`Sources/MenuBarMijiaApp/ControlCenterPanel.swift`、`Sources/MenuBarMijiaApp/ControlCenterPanelChrome.swift`、`Sources/MenuBarMijiaApp/ControlCenterPanelLayout.swift`、`Sources/MenuBarMijiaApp/ControlCenterPanelStacks.swift`、`Sources/MenuBarMijiaApp/ControlCenterPanelActivities.swift`、`Sources/MenuBarMijiaApp/PanelSplitTileShared.swift`、`Sources/MenuBarMijiaApp/ThemeAndMotion.swift`、`Sources/MenuBarMijiaApp/DesignTokens.swift`
- **经典控制中心主题（Classic）**：`Sources/MenuBarMijiaApp/Classic/ClassicControlCenterPanel.swift`、`Sources/MenuBarMijiaApp/Classic/ClassicControlCenterPanelChrome.swift`、`Sources/MenuBarMijiaApp/Classic/ClassicControlCenterPanelLayout.swift`、`Sources/MenuBarMijiaApp/Classic/ClassicThemeAndMotion.swift`
- **卡片、抽屉、设置与实况视频**：`Sources/MenuBarMijiaApp/DeviceCardView.swift`、`Sources/MenuBarMijiaApp/ApplianceDetailDrawer.swift`、`Sources/MenuBarMijiaApp/CoverDetailDrawer.swift`、`Sources/MenuBarMijiaApp/SettingsWindowView.swift`、`Sources/MenuBarMijiaApp/CameraLivePanelController.swift`、`Sources/MenuBarMijiaApp/CameraLivePanelPTZ.swift`、`Sources/MenuBarMijiaApp/GrokBallView.swift`

## Windows 端前端与 Tauri 原生层（`windows/`）

- **核心业务与协议**：`windows/src/core/capabilityManifest.ts`、`windows/src/core/capabilityReferenceVerdict.ts`、`windows/src/core/models.ts`、`windows/src/core/homeProvider.ts`、`windows/src/core/dualSourceProvider.ts`、`windows/src/core/homeAssistant.ts`、`windows/src/core/miAccountsStore.ts`、`windows/src/core/miCloudClient.ts`、`windows/src/core/miCloud/command.ts`、`windows/src/core/assistant.ts`、`windows/src/core/appUrlCommand.ts`、`windows/src/core/i18n.ts`、`windows/src/core/connectionRemoval.ts`、`windows/src/core/secureStore.ts`
- **面板 UI 与双主题动效**：`windows/src/ui/app.ts`、`windows/src/ui/appLifecycle.ts`、`windows/src/ui/sourceEpoch.ts`、`windows/src/ui/sourceSwitch.ts`、`windows/src/ui/activityStackView.ts`、`windows/src/ui/systemContextPoll.ts`、`windows/src/ui/panelView.ts`、`windows/src/ui/panelTheme.ts`、`windows/src/ui/reconciler.ts`、`windows/src/ui/motionSpring.ts`、`windows/src/ui/liquidGlassSlider.ts`、`windows/src/ui/detailDrawers.ts`、`windows/src/ui/connectionsAndDiagView.ts`、`windows/src/ui/settings.ts`、`windows/src/ui/cameraLive.ts`、`windows/src/ui/styles.css`
- **Tauri Rust 宿主层**：`windows/src-tauri/src/main.rs`、`windows/src-tauri/src/desktop_shell.rs`、`windows/src-tauri/src/system_events.rs`、`windows/src-tauri/src/wifi.rs`、`windows/src-tauri/src/credentials.rs`、`windows/src-tauri/src/home_assistant.rs`、`windows/src-tauri/src/camera_stream.rs`、`windows/src-tauri/src/update.rs`、`windows/src-tauri/src/window.rs`
- **Windows 本地校验工具**：`windows/scripts/test-file.mjs`、`windows/scripts/verify-flyout-layout.mjs`

## Raycast 扩展与测试根目录

- **Raycast 伴侣**：`raycast/src/ask.tsx`、`raycast/src/search-devices.tsx`、`raycast/src/search-scenes.tsx`、`raycast/src/snapshot.ts`、`raycast/src/url.ts`
- **测试目录**：`Tests/MijiaCoreTests/`、`Tests/MenuBarMijiaAppTests/`、`Tests/Fixtures/`、`windows/tests/`、`raycast/tests/`

## 门禁、发版与协同脚本（`scripts/`）

- **主门禁与依赖复用**：`scripts/check.sh`、`scripts/shared_windows_deps.sh`、`scripts/ci_relevant_paths.sh`、`scripts/check_doc_links.py`、`scripts/check_capability_manifest.py`、`scripts/check_swift_harness_lints.py`、`scripts/check_windows_test_lints.py`、`scripts/check_workflows.py`
- **PR 与 Issue 协同**：`scripts/pr-ready.sh`、`scripts/ci_errors.sh`、`scripts/pending-work.sh`、`scripts/issue-frontier.sh`
- **打包、更新与测试**：`scripts/build_app.sh`、`scripts/release.sh`、`scripts/check_release.sh`、`scripts/mijia`、`scripts/linux-check/run.sh`、`scripts/repeat_test.sh`、`scripts/test_harness_tools.sh`
