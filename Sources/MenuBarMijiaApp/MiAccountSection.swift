import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MijiaCore

public struct MiAccountSection: View {
    @Environment(\.isPanelVisible) private var isPanelVisible
    public let store: HomeStore

    private enum ScanPhase: Equatable {
        case idle
        case loadingTicket
        case waitingForScan(ticket: QRLoginTicket, expiresAt: Date)
        case failed(String)
    }

    enum LogoutConfirmation: Equatable {
        case account(MiAccount)
        case all

        func title(accountCount: Int) -> String {
            switch self {
            case .account:
                return L10n.tr("移除米家账号？", "Remove Xiaomi Home account?")
            case .all:
                return accountCount > 1
                    ? L10n.tr("退出全部米家账号？", "Sign out of all Xiaomi Home accounts?")
                    : L10n.tr("退出米家账号？", "Sign out of Xiaomi Home?")
            }
        }

        func confirmButtonTitle(accountCount: Int) -> String {
            switch self {
            case .account:
                return L10n.tr("移除", "Remove")
            case .all:
                return accountCount > 1
                    ? L10n.tr("全部退出", "Sign Out of All")
                    : L10n.tr("退出登录", "Sign Out")
            }
        }

        var messageText: String {
            switch self {
            case .account(let account):
                return L10n.tr(
                    "将从本机移除账号「\(account.displayName)」的米家会话；需要时可重新扫码登录。",
                    "Removes the Xiaomi Home session for \"\(account.displayName)\" from this Mac. You can scan again anytime."
                )
            case .all:
                return L10n.tr(
                    "米家会话将从本机移除；需要时可重新扫码登录。",
                    "Xiaomi Home sessions will be removed from this Mac. You can scan again anytime."
                )
            }
        }
    }

    struct DisableConnectionConfirmation: Equatable {
        let account: MiAccount
        let itemsToPause: [AffectedReferenceItem]
        let generation: Int

        /// The exact list shown in the alert. A confirmation applies only while the live preview still
        /// matches it; otherwise the sheet re-previews (M3).
        var pauseItemKeys: Set<String> { Set(itemsToPause.map(\.pauseKey)) }

        var title: String { L10n.tr("停用米家账号连接？", "Turn off Xiaomi Home connection?") }
        var confirmButtonTitle: String { L10n.tr("暂停并停用连接", "Pause & Turn Off Connection") }
        var messageText: String {
            let names = itemsToPause.prefix(4).map(\.name).joined(separator: "、")
            let suffix = itemsToPause.count > 4 ? "…" : ""
            return L10n.format(
                "停用「%@」的连接后，以下定时、自动化或快捷动作将暂停保留，重新启用连接后自动恢复：%@%@",
                "Turning off the connection for \"%@\" will pause and keep the following timers, automations, or quick actions until you turn it back on: %@%@",
                account.displayName, names, suffix
            )
        }
    }

    @State private var phase: ScanPhase
    @State private var loginTask: Task<Void, Never>?
    @State private var pendingLogoutConfirmation: LogoutConfirmation?
    @State private var pendingDisableConfirmation: DisableConnectionConfirmation?
    private let autoStartsQRLogin: Bool
    private let showsRegionPicker: Bool

    public init(
        store: HomeStore,
        previewTicket: QRLoginTicket? = nil,
        autoStartsQRLogin: Bool = false,
        showsRegionPicker: Bool = true
    ) {
        self.store = store
        self.autoStartsQRLogin = autoStartsQRLogin
        self.showsRegionPicker = showsRegionPicker
        if let previewTicket {
            self._phase = State(initialValue: .waitingForScan(ticket: previewTicket, expiresAt: Date().addingTimeInterval(previewTicket.timeout)))
        } else {
            self._phase = State(initialValue: .idle)
        }
    }

    static func shouldAutoStartQRLogin(
        autoStartsQRLogin: Bool, homeBackend: HomeBackend, miSessionShowsExpired: Bool
    ) -> Bool {
        autoStartsQRLogin && (homeBackend == .xiaomiCloud || miSessionShowsExpired)
    }

    private func requestDisableConnection(for account: MiAccount) {
        let generation = store.capabilityGeneration
        let verdict = store.previewSetMiAccountEnabled(false, id: account.id)
        switch verdict.disposition {
        case .allowed:
            let applied = store.setMiAccountEnabled(false, id: account.id, expectedGeneration: generation)
            if applied.disposition == .blocked {
                reportBlockedDisable(applied)
            } else {
                presentConfirmationIfStillNeeded(applied, account: account)
            }
        case .requiresPauseConfirmation:
            pendingDisableConfirmation = DisableConnectionConfirmation(
                account: account,
                itemsToPause: verdict.itemsToPause,
                generation: generation
            )
        case .blocked:
            reportBlockedDisable(verdict)
        }
    }

    /// Re-present the alert only when the disable did not apply. A successful apply returns the pause
    /// verdict it just used, so presenting that again would offer Cancel for an account that is
    /// already off (review #275). A real change of the list leaves the account enabled.
    private func presentConfirmationIfStillNeeded(_ verdict: CapabilityDeactivationVerdict, account: MiAccount) {
        guard verdict.disposition == .requiresPauseConfirmation,
              store.isMiAccountEnabled(account.id) else { return }
        let fresh = DisableConnectionConfirmation(
            account: account, itemsToPause: verdict.itemsToPause, generation: store.capabilityGeneration
        )
        // Present on the next tick so SwiftUI does not drop an alert raised while the old one is
        // still dismissing.
        Task { @MainActor in pendingDisableConfirmation = fresh }
    }

    /// A blocked preview is never silent: name the reason and what to do about it (L2).
    private func reportBlockedDisable(_ verdict: CapabilityDeactivationVerdict) {
        let kinds = Set(verdict.blockingReasons.map(\.kind))
        let message: String
        if kinds.contains(.corruptedReferenceStore) {
            message = L10n.tr(
                "无法停用该连接：本地保存的定时、自动化或布局数据已损坏。请先在对应页面修复或删除这些数据后重试",
                "Could not turn off this connection: saved timers, automations or layout data are damaged. Fix or delete them in their pages and try again"
            )
        } else if kinds.contains(.unresolvedReferenceOwnership) {
            message = L10n.tr(
                "无法停用该连接：有定时或自动化无法确认目标属于哪个连接。请先在这些项目里重新选择目标",
                "Could not turn off this connection: a timer or automation has targets that cannot be attributed to a connection. Reselect their targets first"
            )
        } else if kinds.contains(.stalePreviewGeneration) {
            message = L10n.tr(
                "连接状态刚刚发生变化，请再试一次",
                "The connection state just changed; try again"
            )
        } else {
            message = L10n.tr("无法停用该连接", "Could not turn off this connection")
        }
        store.showToast(message, isError: true)
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        let _ = store.capabilityGeneration
        VStack(alignment: .leading, spacing: 9) {
            if showsRegionPicker {
                HStack {
                    Text(L10n.tr("云端服务器地区", "Cloud Region"))
                        .font(.system(size: DesignTokens.TypeSize.body))
                    Spacer()
                    Picker(
                        L10n.tr("云端服务器地区", "Cloud Region"),
                        selection: Binding(
                            get: { store.miCloudRegion },
                            set: { store.miCloudRegion = $0 }
                        )
                    ) {
                        ForEach(MiCloudRegion.allCases) { region in
                            Text(region.label).tag(region)
                        }
                    }
                    .labelsHidden()
                    .frame(width: DesignTokens.Settings.fieldWidth)
                    .controlSize(.regular)
                }
            }

            switch phase {
            case .idle:
                if store.miAccounts.count > 1 {
                    multiAccountView
                } else if let masked = store.miSessionMaskedUserId {
                    loggedInView(maskedUserId: masked)
                } else {
                    loggedOutView
                }

            case .loadingTicket:
                HStack(spacing: 8) {
                    if isPanelVisible {
                        ProgressView()
                            .controlSize(.regular)
                    }
                    Text(L10n.tr("正在获取小米登录二维码…", "Fetching Xiaomi QR code…"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                    Spacer()
                    Button(L10n.tr("取消", "Cancel")) {
                        cancelLogin()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
                .padding(.vertical, 6)

            case .waitingForScan(let ticket, let expiresAt):
                qrCodeScanningView(ticket: ticket, expiresAt: expiresAt)

            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                    }

                    HStack {
                        Button(L10n.tr("取消", "Cancel")) {
                            cancelLogin()
                        }
                        .buttonStyle(PillActionButtonStyle())

                        Spacer()

                        Button(L10n.tr("重试获取二维码", "Retry QR Code")) {
                            startQRLogin()
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                    }
                }
            }
        }
        .task {
            guard Self.shouldAutoStartQRLogin(
                autoStartsQRLogin: autoStartsQRLogin,
                homeBackend: store.homeBackend,
                miSessionShowsExpired: store.miSessionShowsExpired
            ), case .idle = phase else { return }
            startQRLogin()
        }
        .onChange(of: store.homeBackend) { _, backend in
            if autoStartsQRLogin, backend != .xiaomiCloud {
                cancelLogin()
            }
        }
        .onDisappear {
            pendingLogoutConfirmation = nil
            pendingDisableConfirmation = nil
            cancelLogin()
        }
        .alert(
            pendingLogoutConfirmation?.title(accountCount: store.miAccounts.count) ?? "",
            isPresented: Binding(
                get: { pendingLogoutConfirmation != nil },
                set: { if !$0 { pendingLogoutConfirmation = nil } }
            ),
            presenting: pendingLogoutConfirmation
        ) { confirmation in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {
                pendingLogoutConfirmation = nil
            }
            Button(
                confirmation.confirmButtonTitle(accountCount: store.miAccounts.count),
                role: .destructive
            ) {
                pendingLogoutConfirmation = nil
                UnsupportedDeviceScanner.shared.reset()
                switch confirmation {
                case .account(let account):
                    store.logoutMiAccount(id: account.id)
                case .all:
                    store.logoutMiAccount()
                }
            }
        } message: { confirmation in
            Text(confirmation.messageText)
        }
        .alert(
            pendingDisableConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingDisableConfirmation != nil },
                set: { if !$0 { pendingDisableConfirmation = nil } }
            ),
            presenting: pendingDisableConfirmation
        ) { confirmation in
            Button(L10n.tr("取消", "Cancel"), role: .cancel) { pendingDisableConfirmation = nil }
            Button(confirmation.confirmButtonTitle) {
                pendingDisableConfirmation = nil
                let verdict = store.setMiAccountEnabled(
                    false, id: confirmation.account.id, pauseConfirmed: true,
                    expectedGeneration: confirmation.generation,
                    expectedPauseItemKeys: confirmation.pauseItemKeys
                )
                if verdict.disposition == .blocked { reportBlockedDisable(verdict) }
                presentConfirmationIfStillNeeded(verdict, account: confirmation.account)
            }
        } message: { confirmation in
            Text(confirmation.messageText)
        }
    }

    private func connectionToggleButton(for account: MiAccount, isEnabled: Bool) -> some View {
        Button(isEnabled ? L10n.tr("停用连接", "Turn Off Connection") : L10n.tr("启用连接", "Turn On Connection")) {
            if isEnabled { requestDisableConnection(for: account) } else { store.setMiAccountEnabled(true, id: account.id) }
        }
        .buttonStyle(PillActionButtonStyle(isSelected: !isEnabled, tintColor: .accentColor))
    }

    @ViewBuilder
    private func accountStatusLine(isEnabled: Bool, disconnectReason: String?, expiryState: MiSessionExpiryState) -> some View {
        if !isEnabled {
            Text(L10n.tr("连接已停用", "Connection turned off"))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)
        } else if let reason = disconnectReason {
            Text(reason)
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.orange)
        } else if case .expiringSoon(let date) = expiryState {
            let dateText = date.formatted(date: .abbreviated, time: .omitted)
            Text(L10n.tr("米家登录将在 \(dateText) 到期", "Xiaomi Home sign-in expires \(dateText)"))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.orange)
        }
    }

    private func loggedInView(maskedUserId: String) -> some View {
        let account = store.miAccounts.first
        let isEnabled = account.map { store.isMiAccountEnabled($0.id) } ?? store.hasEnabledMiSource
        let expiryState = isEnabled ? (account?.session.expiryState() ?? .valid) : .valid
        let disconnectReason: String? = {
            guard isEnabled else { return nil }
            if let account, case .disconnected(let reason) = store.miAccountStatuses[account.id], !reason.isEmpty { return reason }
            if case .disconnected(let reason) = store.connectionStatus, !reason.isEmpty { return reason }
            return expiryState == .expired ? MiCloudError.sessionExpired.localizedDescription : nil
        }()
        let needsRescan = isEnabled && (disconnectReason != nil || expiryState != .valid)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: !isEnabled ? "pause.circle.fill" : (needsRescan ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"))
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(!isEnabled ? DesignTokens.secondaryText : (needsRescan ? .orange : .green))
                Text(L10n.tr("已登录米家账号：\(maskedUserId)", "Signed in to Xiaomi Home: \(maskedUserId)"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Spacer()
                if let account { connectionToggleButton(for: account, isEnabled: isEnabled) }
            }

            accountStatusLine(isEnabled: isEnabled, disconnectReason: disconnectReason, expiryState: expiryState)

            HStack(spacing: 6) {
                if isEnabled {
                    Button(L10n.tr("同步设备", "Sync Devices")) {
                        store.refreshNow()
                        store.showToast(L10n.tr("正在同步米家云端设备…", "Syncing Xiaomi Cloud devices…"))
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                }

                Button(L10n.tr("重新扫码", "Rescan QR")) {
                    if let account { store.miCloudRegion = account.region }
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: needsRescan, tintColor: .accentColor))

                Button(L10n.tr("添加账号", "Add Account")) { startQRLogin() }
                    .buttonStyle(PillActionButtonStyle(isSelected: isEnabled && !needsRescan, tintColor: .accentColor))

                Spacer()

                Button(L10n.tr("退出登录", "Sign Out")) { pendingLogoutConfirmation = .all }
                    .buttonStyle(PillActionButtonStyle())
            }
        }
    }

    /// Several accounts merged into one panel: one removable row each, plus the actions that apply to
    /// all of them.
    private var multiAccountView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.miAccounts) { account in
                let isEnabled = store.isMiAccountEnabled(account.id)
                let expiryState = isEnabled ? account.session.expiryState() : .valid
                let disconnectReason: String? = {
                    guard isEnabled else { return nil }
                    if case .disconnected(let reason) = store.miAccountStatuses[account.id], !reason.isEmpty { return reason }
                    return expiryState == .expired ? MiCloudError.sessionExpired.localizedDescription : nil
                }()
                let needsRescan = isEnabled && (disconnectReason != nil || expiryState != .valid)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: !isEnabled ? "pause.circle.fill" : (needsRescan ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"))
                            .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                            .foregroundStyle(!isEnabled ? DesignTokens.secondaryText : (needsRescan ? .orange : .green))
                        Text(account.displayName)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        Spacer()
                        if needsRescan {
                            Button(L10n.tr("重新扫码", "Rescan QR")) {
                                store.miCloudRegion = account.region
                                startQRLogin()
                            }
                            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                        }
                        connectionToggleButton(for: account, isEnabled: isEnabled)
                        Button(L10n.tr("移除", "Remove")) { pendingLogoutConfirmation = .account(account) }
                            .buttonStyle(PillActionButtonStyle())
                    }
                    accountStatusLine(isEnabled: isEnabled, disconnectReason: disconnectReason, expiryState: expiryState)
                }
            }

            HStack(spacing: 6) {
                if store.hasEnabledMiSource {
                    Button(L10n.tr("同步设备", "Sync Devices")) {
                        store.refreshNow()
                        store.showToast(L10n.tr("正在同步米家云端设备…", "Syncing Xiaomi Cloud devices…"))
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                }

                Button(L10n.tr("添加账号", "Add Account")) {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle())

                Spacer()

                Button(L10n.tr("全部退出", "Sign Out of All")) {
                    pendingLogoutConfirmation = .all
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
    }

    private var loggedOutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr(
                "无需额外部署 Home Assistant，扫码即可通过米家云端直连同步设备与房间。",
                "No Home Assistant needed. Scan with the Mi Home app to sync devices and rooms directly from Xiaomi Cloud."
            ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(DesignTokens.secondaryText)

            // #146: the risk is visible, not buried in secondary-colour fine print.
            Label {
                Text(L10n.tr(
                    "直连使用非官方接口，小米可能限制请求或风控账号；介意的话请改用官方的 Home Assistant (xiaomi_home)。登录会过期，到期需重新扫码。",
                    "Direct mode uses an unofficial API, so Xiaomi may rate-limit or flag accounts. If that worries you, use Home Assistant (xiaomi_home) instead. Sign-in expires; you will need to scan again."
                ))
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.primary.opacity(0.85))

            HStack {
                Spacer()
                Button(L10n.tr("扫码登录米家账号", "Sign In with QR Code")) {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
        }
    }

    private func qrCodeScanningView(ticket: QRLoginTicket, expiresAt: Date) -> some View {
        VStack(spacing: 8) {
            if let qrImage = Self.makeQRImage(from: ticket.loginURL.absoluteString) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 144, height: 144)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous))
            }

            Text(L10n.tr("使用手机「米家」App 或小米账号扫码确认登录", "Scan with the Mi Home app on your phone to confirm sign-in"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                .multilineTextAlignment(.center)

            if isPanelVisible {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded()))
                    Text(L10n.tr("二维码有效剩余 \(remaining)s", "QR code expires in \(remaining)s"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                Button(L10n.tr("取消", "Cancel")) {
                    cancelLogin()
                }
                .buttonStyle(PillActionButtonStyle())

                Button(L10n.tr("刷新二维码", "Refresh QR")) {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func startQRLogin() {
        loginTask?.cancel()
        store.beginMiLogin()
        phase = .loadingTicket
        let selectedRegion = store.miCloudRegion.rawValue
        loginTask = Task {
            let login = MiAccountLogin(region: selectedRegion)
            do {
                let ticket = try await login.start()
                guard !Task.isCancelled else { return }
                let expiresAt = Date().addingTimeInterval(ticket.timeout)
                phase = .waitingForScan(ticket: ticket, expiresAt: expiresAt)
                let session = try await login.waitForScan(ticket)
                guard !Task.isCancelled else { return }
                phase = .idle
                store.completeMiLogin(session)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(msg)
            }
        }
    }

    private func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        phase = .idle
    }

    private static func makeQRImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
