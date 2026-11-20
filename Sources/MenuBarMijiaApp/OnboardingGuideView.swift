import SwiftUI
import AppKit
import MijiaCore

/// Route inside `OnboardingGuideView`: three-card platform chooser, platform setup, or dual-source summary.
public enum OnboardingRoute: Equatable, Sendable {
    case choosePlatform
    case connectMi
    case connectHA
    case connectedSummary
}

/// First-run three-card platform onboarding (WP4a): Xiaomi Home, Home Assistant (manual entry),
/// or offline Demo, with zero background/LAN probes before the user connects. Advanced features
/// remain collapsed behind the "Advanced" disclosure until asked for.
public struct OnboardingGuideView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let store: HomeStore

    @State private var route: OnboardingRoute
    @State private var haURLDraft: String = ""
    @State private var haTokenDraft: String = ""
    @State private var haConnectError: (reason: String, impact: String, action: String)?
    @State private var selectedPreset: AssistantProviderPreset = .openRouterJev
    @State private var baseURLDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var showsCustomEndpointFields: Bool = false
    @State private var voiceAuthorized: Bool = false
    @State private var isRequestingVoice: Bool = false
    /// Advanced stays shut on first launch; the user opens it only when they need it.
    @State private var isAdvancedExpanded: Bool
    private let initialPresetOverride: AssistantProviderPreset?

    public init(
        store: HomeStore,
        initialAdvancedExpanded: Bool = false,
        initialPresetOverride: AssistantProviderPreset? = nil,
        initialRoute: OnboardingRoute? = nil
    ) {
        self.store = store
        self._route = State(initialValue: initialRoute ?? .choosePlatform)
        self._isAdvancedExpanded = State(initialValue: initialAdvancedExpanded)
        self.initialPresetOverride = initialPresetOverride
        if let initialPresetOverride {
            self._selectedPreset = State(initialValue: initialPresetOverride)
            self._showsCustomEndpointFields = State(initialValue: initialPresetOverride == .custom)
        }
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    switch route {
                    case .choosePlatform:
                        platformChooserSection
                        launchAtLoginCard
                        advancedDisclosure
                    case .connectMi:
                        miConnectSection
                    case .connectHA:
                        haConnectSection
                    case .connectedSummary:
                        connectedSummarySection
                        deviceTypeCard
                        launchAtLoginCard
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            bottomActionRow
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .onAppear {
            launchAtLogin.refresh()
            haURLDraft = HAConnectionSaveGuard.initialURLDraft(storedURL: store.serverURLString, hasHASource: store.hasHASource)
            let initialHAToken = HAConnectionSaveGuard.loadInitialToken(from: store)
            haTokenDraft = initialHAToken.token
            let config = store.assistantConfig
            let initialPreset = AssistantProviderPreset.infer(baseURL: config.baseURL)
            if let initialPresetOverride {
                let fields = AssistantSettingsDraft.selecting(
                    initialPresetOverride,
                    from: initialPreset,
                    fields: .init(
                        baseURL: config.baseURL,
                        model: config.model,
                        apiKey: store.storedAssistantAPIKey(forBaseURL: config.baseURL)
                    ),
                    storedKey: { store.storedAssistantAPIKey(forBaseURL: $0) }
                )
                selectedPreset = initialPresetOverride
                showsCustomEndpointFields = initialPresetOverride == .custom
                baseURLDraft = fields.baseURL
                modelDraft = fields.model
                apiKeyDraft = fields.apiKey
            } else {
                selectedPreset = initialPreset
                showsCustomEndpointFields = initialPreset == .custom
                baseURLDraft = config.baseURL
                modelDraft = config.model
                apiKeyDraft = store.storedAssistantAPIKey(forBaseURL: config.baseURL)
            }
            voiceAuthorized = SpeechInputController.shared.hasVoicePermissions
        }
        .onDisappear {
            store.cancelPendingHAOnboardingVerification()
            store.isKeepingOnboardingGuideOpenForDualSource = false
        }
        .onChange(of: store.miAccounts.count) { oldCount, newCount in
            if route == .connectMi, newCount > oldCount {
                withAnimation(AppleMotion.snappySpring) {
                    route = .connectedSummary
                }
                announceLiveRegion(L10n.tr("已连接米家账号，可继续添加 Home Assistant 启用双源或开始使用。", "Xiaomi Home connected. You can add Home Assistant for dual-source or start using the app."))
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color(red: 0.92, green: 0.38, blue: 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "house.fill")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                Text(L10n.tr("选择你的智能家居", "Choose Your Smart Home"))
                    .font(.system(size: 14, weight: .bold))
                    .tracking(-0.2)

                Text(L10n.tr(
                    "按需连接平台，未连接前不会发起任何后台或局域网请求",
                    "Connect on demand; zero background or LAN requests until you connect"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(DesignTokens.secondaryText)
            }

            Spacer()

            Button(store.effectiveLanguage == .en ? "中文" : "EN") {
                withAnimation(AppleMotion.snappySpring) {
                    store.appLanguagePreference = (store.effectiveLanguage == .en) ? .zhHans : .en
                }
            }
            .buttonStyle(PillActionButtonStyle())
            .help(L10n.tr("切换为英文界面 / Switch to English", "Switch to Chinese / 切换为中文界面"))

            Button(L10n.tr("跳过", "Skip")) {
                withAnimation(AppleMotion.snappySpring) {
                    store.finishOnboardingGuide()
                }
            }
            .buttonStyle(PillActionButtonStyle())
            .help(L10n.tr("跳过引导，直接开始", "Skip the guide and start now"))
        }
    }

    private var supportedDevicesURL: URL? {
        let page = store.effectiveLanguage == .en ? "supported-devices.md" : "supported-devices.zh-CN.md"
        return URL(string: "https://github.com/jryang2026-code/MenuBarHome/blob/main/docs/\(page)")
    }

    // MARK: - 3-Card Platform Chooser (WP4a)

    private var platformChooserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            platformCard(
                icon: "qrcode",
                tint: .orange,
                title: L10n.tr("米家", "Xiaomi Home"),
                badge: L10n.tr("推荐手机扫码", "QR Login Recommended"),
                detail: L10n.tr(
                    "手机「米家」扫码即可同步设备，支持多账号，稍后也可再添加 Home Assistant 组成双源。",
                    "Scan with the Mi Home app to sync devices. Multi-account supported; add Home Assistant later for dual-source."
                ),
                accessibilityHint: L10n.tr("打开米家扫码登录步骤", "Opens Xiaomi Home QR sign-in")
            ) {
                store.isKeepingOnboardingGuideOpenForDualSource = true
                withAnimation(AppleMotion.snappySpring) { route = .connectMi }
            }

            platformCard(
                icon: "server.rack",
                tint: .accentColor,
                title: "Home Assistant",
                badge: L10n.tr("手动填写地址", "Manual Address"),
                detail: L10n.tr(
                    "填写你的服务器地址与长期访问令牌，验证快照后再保存，不主动扫描局域网。",
                    "Enter your server URL and Long-Lived Access Token. Verified before saving with no automatic LAN scan."
                ),
                accessibilityHint: L10n.tr("打开 Home Assistant 地址与令牌填写表单", "Opens Home Assistant URL and token form")
            ) {
                haConnectError = nil
                store.isKeepingOnboardingGuideOpenForDualSource = true
                withAnimation(AppleMotion.snappySpring) { route = .connectHA }
            }

            platformCard(
                icon: "play.rectangle.fill",
                tint: .secondary,
                title: L10n.tr("先逛逛（不连接设备）", "Explore First (No Devices Connected)"),
                badge: L10n.tr("完全离线", "Offline"),
                detail: L10n.tr(
                    "示例家庭，不会控制真实设备。零网络请求，随时可返回连接真实家庭。",
                    "Demo home; won't control real devices. Zero network requests; connect a real home anytime."
                ),
                accessibilityHint: L10n.tr("进入离线示例家庭预览界面", "Enters the offline demo home preview")
            ) {
                store.cancelPendingHAOnboardingVerification()
                store.isKeepingOnboardingGuideOpenForDualSource = false
                withAnimation(AppleMotion.snappySpring) {
                    store.switchBackend(.demo)
                    store.showToast(L10n.tr("已进入演示模式，随时可以连接真实家庭", "Demo mode on; connect a real home any time"))
                }
            }

            if !store.hasConnectedHomeSource, let supportedDevicesURL {
                Link(destination: supportedDevicesURL) {
                    Label(L10n.tr("我的设备支持吗？", "Will my devices work?"), systemImage: "questionmark.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("选择要连接的智能家居平台", "Choose a smart home platform")))
    }

    private func platformCard(
        icon: String,
        tint: Color,
        title: String,
        badge: String,
        detail: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tint == .secondary ? DesignTokens.secondaryText : tint)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title)，\(badge)。\(detail)"))
        .accessibilityHint(Text(accessibilityHint))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Connect Mi Home

    private var miConnectSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            stepBackHeader(
                title: L10n.tr("连接米家", "Connect Xiaomi Home"),
                backTitle: store.hasHASource
                    ? L10n.tr("返回", "Back")
                    : L10n.tr("返回选择平台", "Choose Platform")
            ) {
                withAnimation(AppleMotion.snappySpring) {
                    if store.hasHASource {
                        route = .connectedSummary
                    } else {
                        store.isKeepingOnboardingGuideOpenForDualSource = false
                        route = .choosePlatform
                    }
                }
            }

            Label(
                L10n.tr(
                    "非米家官方客户端；扫码登录凭证仅保存在本机钥匙串，随时可在设置中退出并吊销。",
                    "Unofficial client; sign-in credentials stay in your local Keychain and can be revoked anytime in Settings."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(L10n.tr("风险提示：非米家官方客户端；扫码登录凭证仅保存在本机钥匙串。", "Notice: unofficial client; sign-in credentials stay in your local Keychain.")))

            MiAccountSection(store: store)
        }
        .padding(11)
        .glassTile(isActive: store.hasEnabledMiSource, cornerRadius: DesignTokens.Radius.card)
    }

    // MARK: - Connect Home Assistant (Manual Entry + Verified Save)

    private var haConnectSection: some View {
        let normalizedDraft = HAWebSocketProvider.normalizeBaseURL(HAConnectionSaveGuard.effectiveURL(haURLDraft))
        let securityPageURL = URL(string: "\(normalizedDraft)/profile/security")
        let canOpenSecurityPage = securityPageURL?.scheme.map { $0 == "http" || $0 == "https" } == true
            && !(securityPageURL?.host?.isEmpty ?? true)

        return VStack(alignment: .leading, spacing: 8) {
            stepBackHeader(
                title: store.hasEnabledMiSource
                    ? L10n.tr("添加 Home Assistant（双源）", "Add Home Assistant (Dual-Source)")
                    : L10n.tr("连接 Home Assistant", "Connect Home Assistant"),
                backTitle: store.hasEnabledMiSource
                    ? L10n.tr("返回", "Back")
                    : L10n.tr("返回选择平台", "Choose Platform")
            ) {
                store.cancelPendingHAOnboardingVerification()
                haConnectError = nil
                withAnimation(AppleMotion.snappySpring) {
                    if store.hasEnabledMiSource {
                        route = .connectedSummary
                    } else {
                        store.isKeepingOnboardingGuideOpenForDualSource = false
                        route = .choosePlatform
                    }
                }
            }

            Text(L10n.tr(
                "手动输入服务器地址并粘贴长期访问令牌；只有在收到 Home Assistant 状态快照后才会保存配置。",
                "Enter your server URL and Long-Lived Access Token. Settings are saved only after Home Assistant returns a snapshot."
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            TextField("https://your-home.ui.nabu.casa", text: $haURLDraft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11.5, design: .monospaced))
                .accessibilityLabel(Text(L10n.tr("Home Assistant 服务器地址", "Home Assistant server URL")))

            if HAConnectionSaveGuard.showsPlaintextWarning(forDraft: haURLDraft) {
                Label(
                    L10n.tr("令牌将以明文在网络上传输，建议使用 HTTPS 或 Nabu Casa 地址。", "Your token will travel unencrypted. Use HTTPS or a Nabu Casa address."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                SecureField(L10n.tr("粘贴 HA 长期访问令牌", "Paste HA Long-Lived Access Token"), text: $haTokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11.5, design: .monospaced))
                    .accessibilityLabel(Text(L10n.tr("Home Assistant 长期访问令牌", "Home Assistant Long-Lived Access Token")))

                Button {
                    submitHAOnboarding()
                } label: {
                    Text(store.isVerifyingHAOnboarding
                        ? L10n.tr("正在验证…", "Verifying…")
                        : L10n.tr("验证并连接", "Verify & Connect"))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                .disabled(store.isVerifyingHAOnboarding)
            }

            if canOpenSecurityPage, let securityPageURL {
                Button(L10n.tr("打开网页取令牌", "Open Security Page")) {
                    NSWorkspace.shared.open(securityPageURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }

            if let error = haConnectError {
                VStack(alignment: .leading, spacing: 3) {
                    Label(error.reason, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(error.impact)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.primary.opacity(0.85))
                    Text(error.action)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(error.reason)。\(error.impact) \(error.action)"))
            }
        }
        .padding(11)
        .glassTile(isActive: store.hasEnabledHASource, cornerRadius: DesignTokens.Radius.card)
    }

    private func submitHAOnboarding() {
        haConnectError = nil
        let url = haURLDraft
        let token = haTokenDraft
        Task { @MainActor in
            let outcome = await store.connectHomeAssistantForOnboarding(serverURL: url, token: token)
            switch outcome {
            case .connected:
                haConnectError = nil
                withAnimation(AppleMotion.snappySpring) {
                    route = .connectedSummary
                }
                announceLiveRegion(L10n.tr("Home Assistant 验证并连接成功。", "Home Assistant verified and connected."))
            case .cancelled:
                break
            case .failed(let reason, let impact, let action):
                haConnectError = (reason, impact, action)
                announceLiveRegion("\(reason)。\(impact) \(action)")
            }
        }
    }

    // MARK: - Connected Summary & Dual-Source Step

    private var connectedSummarySection: some View {
        let hasMi = store.hasEnabledMiSource
        let hasHA = store.hasEnabledHASource
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                Text(hasMi && hasHA
                    ? L10n.tr("双源已连接（米家 + Home Assistant）", "Dual-Source Connected (Xiaomi Home + Home Assistant)")
                    : L10n.tr("平台已连接", "Platform Connected"))
                    .font(.system(size: 12.5, weight: .semibold))
            }

            Text(hasMi && hasHA
                ? L10n.tr("两套平台的设备会自动合并去重，随时可在设置里调整优先级或单端停用。", "Devices from both platforms merge automatically. Adjust priority or pause either source anytime in Settings.")
                : L10n.tr("现在就能开始控制设备，或者顺手再添加另一个平台启用双源。", "You can start controlling devices now, or add the other platform for dual-source."))
                .font(.system(size: 11.5))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if hasMi && !hasHA {
                Button {
                    haConnectError = nil
                    withAnimation(AppleMotion.snappySpring) { route = .connectHA }
                } label: {
                    Label(L10n.tr("再添加 Home Assistant（启用双源）", "Add Home Assistant (Dual-Source)"), systemImage: "plus.circle")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(PillActionButtonStyle())
            } else if hasHA && !hasMi {
                Button {
                    withAnimation(AppleMotion.snappySpring) { route = .connectMi }
                } label: {
                    Label(L10n.tr("再添加米家（启用双源）", "Add Xiaomi Home (Dual-Source)"), systemImage: "plus.circle")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassTile(isActive: true, cornerRadius: DesignTokens.Radius.card)
    }

    // MARK: - Device Types (P4b-M)

    /// Every supported type stays on until the user applies a preset or their own list (architecture.md §I).
    private var deviceTypeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("选择要显示的设备类型", "Choose Device Types to Show"))
                .font(.system(size: 11.5, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(L10n.tr(
                "默认显示全部已支持类型；之后也可在设置「常规 › 设备类型」里调整。",
                "Every supported type shows by default; change it later in Settings › General › Device Types."
            ))
            .font(.system(size: 11))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            DeviceTypeSelectionView(store: store)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.card)
    }

    // MARK: - Launch at Login Card

    private var launchAtLoginCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("登录 Mac 时自动启动", "Launch at Login"))
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(L10n.tr(
                        "菜单栏工具常驻：重启 Mac 后自动出现，不用再去应用程序里找。",
                        "Keep the menu-bar tool around after a restart without opening Applications again."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: Binding(
                    get: { store.launchAtLoginOnboardingChoice },
                    set: { store.launchAtLoginOnboardingChoice = $0 }
                ))
                .labelsHidden()
                .glassLabelHidden()
                .toggleStyle(.glass)
            }

            if store.launchAtLoginPolicy.needsManualApproval {
                HStack(alignment: .top, spacing: 8) {
                    Label(
                        L10n.tr(
                            "系统没有自动设置成功，请到系统设置里手动开启。",
                            "macOS could not enable it automatically. Turn it on in System Settings."
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button(L10n.tr("去系统设置开启", "Open System Settings")) {
                        launchAtLogin.openSystemSettings()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
        }
        .padding(11)
        .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.card)
    }

    private func stepBackHeader(title: String, backTitle: String, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(backTitle)
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .buttonStyle(PillActionButtonStyle())

            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    private func announceLiveRegion(_ message: String) {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    // MARK: - Advanced (collapsed by default)

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.tr(
                    "这些功能第一次用到时再打开也不迟；下面每一行都标了在哪里配置。",
                    "You will not need these on day one. Each row says where it lives."
                ))
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                advancedAIModelCard

                advancedPointerRow(
                    icon: "sparkles",
                    title: L10n.tr("GrokBall 情绪球", "GrokBall Sidecar"),
                    detail: L10n.tr(
                        "设置 → 通用 → 启用侧边情绪智能球，点一下看推荐、拖到顺手的位置。",
                        "Settings → General → Enable Sidecar Grok Ball. Click for suggestions, drag it where it fits."
                    ),
                    actionTitle: L10n.tr("打开设置", "Open Settings")
                ) {
                    SettingsWindowOpener.shared.show(tab: .general)
                }

                advancedPointerRow(
                    icon: "video",
                    title: L10n.tr("摄像机直播", "Camera Live View"),
                    detail: L10n.tr(
                        "连上摄像头后，点设备卡片上的摄像机图标就能看直播，无需在此配置。",
                        "Once a camera is connected, click the camera icon on its card for live view. Nothing to set up here."
                    )
                )

                advancedPointerRow(
                    icon: "gearshape.2",
                    title: L10n.tr("自动化与 URL 直控", "Automation & URL Control"),
                    detail: L10n.tr(
                        "设置 → 通用 → 自动化与外部控制；URL 直控默认每次先确认。",
                        "Settings → General → Automation & External Control. URL control asks first by default."
                    ),
                    actionTitle: L10n.tr("打开设置", "Open Settings")
                ) {
                    SettingsWindowOpener.shared.show(tab: .general)
                }

                advancedVoiceAndShortcutsCard
            }
            .padding(.top, 9)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("进阶功能（用到再看）", "Advanced (Only When Needed)"))
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(L10n.tr(
                        "AI 指令、GrokBall、摄像机、自动化与 URL 直控",
                        "AI commands, GrokBall, cameras, automation and URL control"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.secondaryText)
                }
                Spacer(minLength: 0)
                Text(L10n.tr("默认收起", "Collapsed"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.secondaryText)
            }
        }
        .tint(Color.accentColor)
        .padding(11)
        .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.card)
    }

    // MARK: - Advanced: AI Decision Model

    private var advancedAIModelCard: some View {
        let effectiveBase = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCustomKey = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let importedSource = hasCustomKey && !effectiveBase.isEmpty
            ? AssistantConfig.importedKeySource(forBaseURL: effectiveBase, defaults: store.userDefaults, vault: store.credentialVault)
            : nil
        let isLoopback = !effectiveBase.isEmpty
            && AssistantConfig(baseURL: effectiveBase, model: modelDraft, apiKey: "").isLoopbackEndpoint

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, alignment: .center)
                Text(L10n.tr("AI 决策模型（可选）", "AI Decision Model (Optional)"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let importedSource {
                    Label(L10n.tr("已从 \(importedSource) 导入", "Imported from \(importedSource)"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if hasCustomKey {
                    Label(L10n.tr("已配置密钥", "Key Configured"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if isLoopback {
                    Label(L10n.tr("本机免密接口", "Local Endpoint"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(L10n.tr("不填也能用本机规则", "Local Rules Work Without It"))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
            }

            Text(L10n.tr(
                "常规指令本机直接执行，不需要 AI。想要一次统筹多台设备或更口语的说法，再接 Jev、DeepSeek 等服务。",
                "Simple commands run on this Mac without AI. Connect Jev, DeepSeek or another service only for multi-device phrasing."
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Picker(
                    "",
                    selection: Binding(
                        get: { selectedPreset },
                        set: { newPreset in
                            let fields = AssistantSettingsDraft.selecting(
                                newPreset,
                                from: selectedPreset,
                                fields: draftFields,
                                storedKey: { store.storedAssistantAPIKey(forBaseURL: $0) }
                            )
                            selectedPreset = newPreset
                            showsCustomEndpointFields = newPreset == .custom
                            applyDraft(fields)
                        }
                    )
                ) {
                    ForEach(AssistantProviderPreset.allCases) { preset in
                        Text(preset.shortTitle).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .controlSize(.small)

                SecureField(selectedPreset.keyPlaceholder, text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))

                Button(L10n.tr("保存", "Save")) {
                    if saveOnboardingAssistantDraft(showErrorToast: true, enablesAssistant: true) != nil {
                        store.showToast(L10n.tr("已保存 \(selectedPreset.shortTitle) 配置", "Saved \(selectedPreset.shortTitle) config"))
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: !apiKeyDraft.isEmpty || (showsCustomEndpointFields && !effectiveBase.isEmpty), tintColor: .accentColor))
            }

            if showsCustomEndpointFields {
                HStack(spacing: 6) {
                    TextField(
                        AssistantConfig.defaultBaseURL,
                        text: Binding(
                            get: { baseURLDraft },
                            set: { newValue in
                                let updated = AssistantSettingsDraft.updatingBaseURL(
                                    newValue,
                                    currentPreset: selectedPreset,
                                    fields: draftFields,
                                    storedKey: { store.storedAssistantAPIKey(forBaseURL: $0) }
                                )
                                selectedPreset = updated.preset
                                applyDraft(updated.fields)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityLabel(Text(AssistantSettingsCopy.serviceAddressLabel))

                    TextField("gpt-4o-mini", text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 112)
                        .accessibilityLabel(Text(AssistantSettingsCopy.modelLabel))
                }
            }

            if selectedPreset.supportsKeyImport && !hasCustomKey {
                Button(L10n.tr("已在 CodexBar 或环境变量里配过？点此导入 Key", "Already set up in CodexBar or env vars? Import the key")) {
                    if let label = AssistantConfig.importAmbientAPIKey(forBaseURL: effectiveBase, defaults: store.userDefaults, vault: store.credentialVault) {
                        apiKeyDraft = store.storedAssistantAPIKey(forBaseURL: effectiveBase)
                        store.showToast(L10n.tr("已从 \(label) 导入 \(selectedPreset.shortTitle) 的 Key", "Imported the \(selectedPreset.shortTitle) key from \(label)"))
                    } else {
                        store.showToast(
                            L10n.tr(
                                "CodexBar 和环境变量里都没有 \(selectedPreset.shortTitle) 的 Key，或无法写入钥匙串",
                                "No \(selectedPreset.shortTitle) key in CodexBar or environment variables, or the Keychain refused the write"
                            ),
                            isError: true
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var draftFields: AssistantSettingsDraft.Fields {
        AssistantSettingsDraft.Fields(baseURL: baseURLDraft, model: modelDraft, apiKey: apiKeyDraft)
    }

    private func applyDraft(_ fields: AssistantSettingsDraft.Fields) {
        baseURLDraft = fields.baseURL
        modelDraft = fields.model
        apiKeyDraft = fields.apiKey
    }

    @discardableResult
    private func saveOnboardingAssistantDraft(showErrorToast: Bool, enablesAssistant: Bool) -> AssistantConfig? {
        guard let cfg = AssistantSettingsDraft.configToSave(preset: selectedPreset, fields: draftFields) else {
            if showErrorToast {
                store.showToast(AssistantSettingsCopy.customAddressRequired, isError: true)
            }
            return nil
        }
        guard store.saveAssistantConfig(cfg) else {
            if showErrorToast {
                store.showToast(
                    L10n.tr("无法写入钥匙串，请授权钥匙串访问后重试", "Could not save to Keychain; allow Keychain access and try again"),
                    isError: true
                )
            }
            return nil
        }
        // Only the AI card's own Save button is an explicit opt-in that turns the feature on
        // (P5a-M Codex review). The guide's Done button also saves a non-empty draft, and the draft
        // is prefilled with the stored key when the guide is reopened from Settings, so Done must
        // never re-enable an assistant the user turned off (#318 review).
        // A refused write already shows its own toast (identity uncertain / store refused).
        if enablesAssistant, !store.aiAssistantEnabled {
            _ = store.setAIAssistantEnabled(true)
        }
        let resolved = store.assistantConfig
        baseURLDraft = resolved.baseURL
        modelDraft = resolved.model
        selectedPreset = resolved.preset
        return cfg
    }

    // MARK: - Advanced: Voice & Shortcuts

    private var advancedVoiceAndShortcutsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, alignment: .center)
                Text(L10n.tr("语音与快捷键（可选）", "Voice & Shortcuts (Optional)"))
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if voiceAuthorized {
                    Label(L10n.tr("语音已授权", "Voice Authorized"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            Text(L10n.tr(
                "长按菜单栏图标或 \(hotkeyLabel) 直接说话，例如「书房灯月光模式」「10 分钟后关灯」。",
                "Hold the menu bar icon or \(hotkeyLabel) and speak, e.g. \"study light moonlight mode\" or \"turn off the lights in 10 minutes\"."
            ))
            .font(.system(size: 11))
            .foregroundStyle(DesignTokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            // #176: when a command takes effect is a consequence, not a how-to (CODING_STANDARDS §18).
            Text(L10n.tr(
                "松手就执行；电暖器、插座、扫地机这类设备仍会先问你。",
                "Release and it runs. Heaters, plugs and vacuums still ask first."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)

            if !voiceAuthorized {
                HStack {
                    Spacer()
                    Button {
                        isRequestingVoice = true
                        Task { @MainActor in
                            let granted = await SpeechInputController.shared.requestPermissions()
                            voiceAuthorized = granted
                            isRequestingVoice = false
                            if granted {
                                store.showToast(L10n.tr("已开启麦克风与语音识别权限", "Microphone & Speech Recognition enabled"))
                            } else {
                                store.showToast(
                                    L10n.tr("可在「系统设置 → 隐私与安全性」中开启权限", "Enable permissions in System Settings → Privacy & Security"),
                                    isError: true
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                            Text(isRequestingVoice
                                 ? L10n.tr("正在请求系统授权…", "Requesting Authorization…")
                                 : L10n.tr("授权麦克风与语音", "Authorize Microphone & Speech"))
                        }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                    .disabled(isRequestingVoice)
                }
                .padding(.top, 2)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Footer

    private var bottomActionRow: some View {
        HStack {
            Text(L10n.tr("随时可在「设置 → 通用 → 首次设置」重新打开", "Reopen anytime in Settings → General → Setup"))
                .font(.system(size: 11.5))
                .foregroundStyle(DesignTokens.secondaryText)

            Spacer()

            Button {
                let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedBase = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedModel = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentPreset = AssistantProviderPreset.infer(baseURL: store.assistantConfig.baseURL)
                let storedKey = store.storedAssistantAPIKey(forBaseURL: store.assistantConfig.baseURL)
                // A draft that only echoes the stored config (the reopened-guide prefill) is not a
                // new choice, so it must not turn a deliberately disabled assistant back on.
                let draftChangesConfig = trimmedKey != storedKey
                    || selectedPreset != currentPreset
                    || trimmedBase != store.assistantConfig.baseURL
                    || (!trimmedModel.isEmpty && trimmedModel != store.assistantConfig.model)
                if !trimmedKey.isEmpty || draftChangesConfig {
                    _ = saveOnboardingAssistantDraft(showErrorToast: false, enablesAssistant: draftChangesConfig)
                }
                withAnimation(AppleMotion.snappySpring) {
                    store.finishOnboardingGuide()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.tr("开始使用", "Get Started"))
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
        }
    }

    // MARK: - Subviews

    private var hotkeyLabel: String {
        HotkeySettingsState.shared.shortcut.displayString
    }

    @MainActor private var launchAtLogin: LaunchAtLoginCoordinator { .live(store: store) }

    private func advancedPointerRow(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PillActionButtonStyle())
            }
        }
    }
}
