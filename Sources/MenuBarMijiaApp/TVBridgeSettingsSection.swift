import SwiftUI
import MijiaCore

/// Settings → 常规 → 多品牌电视桥接插件（可选）. Off by default; turning it off stops `mbh-tv-bridge`
/// and removes its TVs from the panel.
struct TVBridgeSettingsSection: View {
    @Bindable var bridge: TVBridgeStore
    @State private var binaryPath = ""
    @State private var expectedSHA = ""
    @State private var isAdding = false
    @State private var removing: TVBridgeDeviceConfig?

    var body: some View {
        SettingsSection(title: L10n.tr("多品牌电视桥接插件（可选）", "Multi-brand TV Bridge (Optional)")) {
            SettingsToggleRow(
                title: L10n.tr("通过 mbh-tv-bridge 控制更多电视", "Control more TVs through mbh-tv-bridge"),
                isOn: Binding(get: { bridge.isEnabled }, set: { bridge.setEnabled($0) })
            )
            .accessibilityIdentifier("settings-tv-bridge")

            caption(L10n.tr(
                "支持小米 / Redmi、雷鸟 / TCL、海信 / 创维等安卓电视（ADB）、LG webOS、索尼 Bravia、三星 Tizen、DLNA 与 Kodi。插件在独立进程中运行，未开启时零后台开销；已由 Home Assistant 或米家接入的同一台电视始终由内置来源控制。",
                "Supports Xiaomi / Redmi, FFalcon / TCL, Hisense / Skyworth Android TVs (ADB), LG webOS, Sony Bravia, Samsung Tizen, DLNA and Kodi. The plugin runs in its own process and nothing runs while this is off; a TV already connected through Home Assistant or Xiaomi Home stays on the built-in source."
            ))

            if bridge.isEnabled {
                Divider().overlay(Color.primary.opacity(0.06))
                binarySettings
                Divider().overlay(Color.primary.opacity(0.06))
                deviceList
            }
        }
        .onAppear {
            binaryPath = bridge.config.binaryPath ?? ""
            expectedSHA = bridge.config.expectedBinarySHA256 ?? ""
        }
        .sheet(isPresented: $isAdding) { TVBridgeDeviceEditor(bridge: bridge) }
        .alert(L10n.tr("移除电视？", "Remove TV?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { device in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("移除", "Remove"), role: .destructive) { bridge.removeDevice(nativeId: device.nativeId) }
        } message: { device in
            Text(device.name)
        }
    }

    private var binarySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    L10n.tr("mbh-tv-bridge 路径", "mbh-tv-bridge path"), text: $binaryPath,
                    prompt: Text(bridge.detectedBinaryPath ?? "/usr/local/bin/mbh-tv-bridge")
                )
                .onSubmit { bridge.setBinaryPath(binaryPath) }
                statusBadge
            }
            TextField(L10n.tr("SHA-256 校验值（可选）", "SHA-256 digest (optional)"), text: $expectedSHA)
                .onSubmit { bridge.setExpectedSHA256(expectedSHA) }
            HStack {
                caption(statusDetail)
                Spacer()
                Button(bridge.isRefreshing ? L10n.tr("正在刷新…", "Refreshing…") : L10n.tr("立即刷新", "Refresh Now")) {
                    bridge.setBinaryPath(binaryPath)
                    bridge.setExpectedSHA256(expectedSHA)
                    bridge.refresh()
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(bridge.isRefreshing)
            }
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bridge.config.devices.isEmpty {
                caption(L10n.tr("尚未添加电视", "No TVs added yet"))
            }
            ForEach(bridge.config.devices, id: \.nativeId) { device in
                HStack(spacing: 6) {
                    Image(systemName: "tv").foregroundStyle(.secondary)
                    Text(device.name).lineLimit(1)
                    Text(device.driver.displayTitle)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(device.host)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                    Button(L10n.tr("移除", "Remove"), role: .destructive) { removing = device }
                }
            }
            HStack {
                Spacer()
                Button(L10n.tr("添加电视", "Add TV"), systemImage: "plus") { isAdding = true }
                    .buttonStyle(PillActionButtonStyle())
            }
        }
    }

    private var statusBadge: some View {
        let (title, color): (String, Color) = switch bridge.status {
        case .disabled: (L10n.tr("未启用", "Off"), .secondary)
        case .missingBinary: (L10n.tr("未配置", "Not set"), .orange)
        case .idle: (L10n.tr("待命", "Idle"), .secondary)
        case .running: (L10n.tr("运行中", "Running"), .green)
        case .failed: (L10n.tr("报错", "Error"), .red)
        }
        return Text(title)
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var statusDetail: String {
        switch bridge.status {
        case .disabled: L10n.tr("插件未启用", "The plugin is off")
        case .missingBinary: L10n.tr("未找到 mbh-tv-bridge，请填写二进制路径后回车", "mbh-tv-bridge wasn't found. Enter its path and press Return")
        case .idle: L10n.tr("打开面板时自动连接电视", "Connects to your TVs when the panel opens")
        case .running: L10n.format("已连接 %@ 台电视", "%@ TVs connected", "\(bridge.devices.count)")
        case .failed(let message): message
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TVBridgeDeviceEditor: View {
    let bridge: TVBridgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var roomName = ""
    @State private var driver: TVBridgeDeviceConfig.Driver = .xiaomi_6095
    @State private var host = ""
    @State private var port = ""
    @State private var macAddress = ""
    @State private var secret = ""
    @State private var failed = false

    private var parsedPort: Int?? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return .some(value)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty && parsedPort != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField(L10n.tr("名称", "Name"), text: $name, prompt: Text(L10n.tr("客厅电视", "Living Room TV")))
                TextField(L10n.tr("房间", "Room"), text: $roomName)
                Picker(L10n.tr("协议驱动", "Driver"), selection: $driver) {
                    ForEach(TVBridgeDeviceConfig.Driver.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                }
                TextField(L10n.tr("IP 地址", "IP address"), text: $host, prompt: Text("192.168.1.20"))
                TextField(L10n.tr("端口", "Port"), text: $port, prompt: Text(L10n.format("默认 %@", "Default %@", "\(driver.defaultPort)")))
                TextField(L10n.tr("MAC 地址（可选，用于网络唤醒）", "MAC address (optional, for Wake-on-LAN)"), text: $macAddress)
                if let title = driver.credentialTitle {
                    SecureField(title, text: $secret)
                }
            }
            if failed {
                Text(L10n.tr("无法保存：密钥未能写入钥匙串", "Couldn't save: the key could not be stored in Keychain"))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L10n.tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("添加", "Add")) {
                    guard let port = parsedPort else { return }
                    if bridge.addDevice(
                        name: name, roomName: roomName, driver: driver, host: host,
                        port: port, macAddress: macAddress, secret: secret
                    ) {
                        dismiss()
                    } else {
                        failed = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
