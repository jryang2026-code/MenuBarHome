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

    struct RegionDisclosureState: Equatable, Sendable {
        var isExpanded: Bool = false
        private(set) var hasAppliedInitialDefaults = false

        init(isExpanded: Bool = false, hasAppliedInitialDefaults: Bool = false) {
            self.isExpanded = isExpanded
            self.hasAppliedInitialDefaults = hasAppliedInitialDefaults
        }

        mutating func applyInitialNonDefaultIfNeeded(region: MiCloudRegion) {
            guard !hasAppliedInitialDefaults else { return }
            hasAppliedInitialDefaults = true
            if region != .cn {
                isExpanded = true
            }
        }

        mutating func expandIfNeeded(forHighlight anchor: SettingsAnchor?) {
            if anchor == .miAccount {
                isExpanded = true
            }
        }

        mutating func expandIfNeeded(isScanning: Bool) {
            if isScanning {
                isExpanded = true
            }
        }
    }

    @Environment(\.settingsSearchFocus) private var searchFocus
    @State private var phase: ScanPhase
    @State private var loginTask: Task<Void, Never>?
    @State private var pendingLogoutConfirmation: LogoutConfirmation?
    @State private var regionDisclosure: RegionDisclosureState
    private let autoStartsQRLogin: Bool
    private let showsRegionPicker: Bool
    private let showsInlineAddAccountButton: Bool
    private let addAccountTrigger: Int

    public init(
        store: HomeStore,
        previewTicket: QRLoginTicket? = nil,
        autoStartsQRLogin: Bool = false,
        showsRegionPicker: Bool = true,
        showsInlineAddAccountButton: Bool = true,
        addAccountTrigger: Int = 0
    ) {
        self.store = store
        self.autoStartsQRLogin = autoStartsQRLogin
        self.showsRegionPicker = showsRegionPicker
        self.showsInlineAddAccountButton = showsInlineAddAccountButton
        self.addAccountTrigger = addAccountTrigger
        if let previewTicket {
            self._phase = State(initialValue: .waitingForScan(ticket: previewTicket, expiresAt: Date().addingTimeInterval(previewTicket.timeout)))
            self._regionDisclosure = State(initialValue: RegionDisclosureState(isExpanded: true, hasAppliedInitialDefaults: true))
        } else {
            self._phase = State(initialValue: .idle)
            var initialDisclosure = RegionDisclosureState()
            initialDisclosure.applyInitialNonDefaultIfNeeded(region: store.miCloudRegion)
            self._regionDisclosure = State(initialValue: initialDisclosure)
        }
    }

    static func shouldAutoStartQRLogin(
        autoStartsQRLogin: Bool, homeBackend: HomeBackend, miSessionShowsExpired: Bool
    ) -> Bool {
        autoStartsQRLogin && (homeBackend == .xiaomiCloud || miSessionShowsExpired)
    }

    static func shouldExpandRegionPicker(
        region: MiCloudRegion,
        isScanning: Bool,
        forHighlight anchor: SettingsAnchor? = nil
    ) -> Bool {
        isScanning || region != .cn || anchor == .miAccount
    }

    static func regionDisclosureTitle(for region: MiCloudRegion) -> String {
        L10n.format(
            "高级：云端服务器地区（当前：%@）",
            "Advanced: Cloud Region (Current: %@)",
            region.label
        )
    }

    private var isScanningPhase: Bool {
        if case .idle = phase { return false }
        return true
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        VStack(alignment: .leading, spacing: 9) {
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

            // #146 & WP3a: risk notice stays always visible in default view (>= 12pt).
            unofficialRiskNotice

            if showsRegionPicker {
                DisclosureGroup(isExpanded: $regionDisclosure.isExpanded) {
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
                    .padding(.top, 4)
                } label: {
                    Text(Self.regionDisclosureTitle(for: store.miCloudRegion))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(DesignTokens.secondaryText)
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
        .onAppear {
            regionDisclosure.applyInitialNonDefaultIfNeeded(region: store.miCloudRegion)
            regionDisclosure.expandIfNeeded(forHighlight: searchFocus?.highlight)
            regionDisclosure.expandIfNeeded(isScanning: isScanningPhase)
        }
        .onChange(of: searchFocus?.highlight) { _, highlight in
            regionDisclosure.expandIfNeeded(forHighlight: highlight)
        }
        .onChange(of: isScanningPhase) { _, isScanning in
            regionDisclosure.expandIfNeeded(isScanning: isScanning)
        }
        .onChange(of: addAccountTrigger) { oldValue, newValue in
            guard newValue != oldValue else { return }
            regionDisclosure.isExpanded = true
            startQRLogin()
        }
        .onChange(of: store.homeBackend) { _, backend in
            if autoStartsQRLogin, backend != .xiaomiCloud {
                cancelLogin()
            }
        }
        .onDisappear {
            pendingLogoutConfirmation = nil
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
    }

    private func loggedInView(maskedUserId: String) -> some View {
        let account = store.miAccounts.first
        let expiryState = account?.session.expiryState() ?? .valid
        let disconnectReason: String? = {
            if let account,
               case .disconnected(let reason) = store.miAccountStatuses[account.id],
               !reason.isEmpty {
                return reason
            }
            if case .disconnected(let reason) = store.connectionStatus, !reason.isEmpty {
                return reason
            }
            if expiryState == .expired {
                return MiCloudError.sessionExpired.localizedDescription
            }
            return nil
        }()
        let needsRescan = disconnectReason != nil || expiryState != .valid

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: needsRescan
                    ? "exclamationmark.triangle.fill"
                    : "person.crop.circle.badge.checkmark")
                    .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                    .foregroundStyle(needsRescan ? .orange : .green)
                Text(L10n.tr("已登录米家账号：\(maskedUserId)", "Signed in to Xiaomi Home: \(maskedUserId)"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Spacer()
            }

            if let reason = disconnectReason {
                Text(reason)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.orange)
            } else if case .expiringSoon(let date) = expiryState {
                let dateText = date.formatted(date: .abbreviated, time: .omitted)
                Text(L10n.tr("米家登录将在 \(dateText) 到期", "Xiaomi Home sign-in expires \(dateText)"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 6) {
                Button(L10n.tr("同步设备", "Sync Devices")) {
                    store.refreshNow()
                    store.showToast(L10n.tr("正在同步米家云端设备…", "Syncing Xiaomi Cloud devices…"))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                Button(L10n.tr("重新扫码", "Rescan QR")) {
                    if let account {
                        store.miCloudRegion = account.region
                    }
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: needsRescan, tintColor: .accentColor))

                if showsInlineAddAccountButton {
                    Button(L10n.tr("添加更多米家账号", "Add More Xiaomi Accounts")) {
                        startQRLogin()
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: !needsRescan, tintColor: .accentColor))
                }

                Spacer()

                Button(L10n.tr("退出登录", "Sign Out")) {
                    pendingLogoutConfirmation = .all
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
    }

    /// Several accounts merged into one panel: one removable row each, plus the actions that apply to
    /// all of them.
    private var multiAccountView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.miAccounts) { account in
                let expiryState = account.session.expiryState()
                let disconnectReason: String? = {
                    if case .disconnected(let reason) = store.miAccountStatuses[account.id], !reason.isEmpty {
                        return reason
                    }
                    if expiryState == .expired {
                        return MiCloudError.sessionExpired.localizedDescription
                    }
                    return nil
                }()
                let needsRescan = disconnectReason != nil || expiryState != .valid
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: needsRescan
                            ? "exclamationmark.triangle.fill"
                            : "person.crop.circle.badge.checkmark")
                            .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                            .foregroundStyle(needsRescan ? .orange : .green)
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
                        Button(L10n.tr("移除", "Remove")) {
                            pendingLogoutConfirmation = .account(account)
                        }
                        .buttonStyle(PillActionButtonStyle())
                    }
                    if let reason = disconnectReason {
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
            }

            HStack(spacing: 6) {
                Button(L10n.tr("同步设备", "Sync Devices")) {
                    store.refreshNow()
                    store.showToast(L10n.tr("正在同步米家云端设备…", "Syncing Xiaomi Cloud devices…"))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                if showsInlineAddAccountButton {
                    Button(L10n.tr("添加更多米家账号", "Add More Xiaomi Accounts")) {
                        startQRLogin()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }

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

            HStack {
                Spacer()
                Button(L10n.tr("扫码登录米家账号", "Sign In with QR Code")) {
                    startQRLogin()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
        }
    }

    private var unofficialRiskNotice: some View {
        // #146 & WP3a: the risk is always visible (>= 12pt), never buried in fine print or advanced disclosure.
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
