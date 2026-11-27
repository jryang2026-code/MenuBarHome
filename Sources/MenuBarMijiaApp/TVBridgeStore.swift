import Foundation
import Observation
import MijiaCore

extension TVBridgeDeviceConfig.Driver {
    var displayTitle: String {
        switch self {
        case .xiaomi_mitv_6095: L10n.tr("小米 / Redmi 电视", "Xiaomi / Redmi TV")
        case .tcl_ffalcon_tnscreen: L10n.tr("雷鸟 / TCL（实验）", "FFalcon / TCL (Experimental)")
        case .android_adb_lan: L10n.tr("通用安卓电视 ADB（实验）", "Generic Android TV ADB (Experimental)")
        case .lg_webos_ssap: "LG webOS"
        case .hisense_vidaa_mqtt: L10n.tr("海信电视（海外 VIDAA）", "Hisense TV (Overseas VIDAA)")
        case .sony_bravia_psk: L10n.tr("索尼 Bravia（实验）", "Sony Bravia (Experimental)")
        case .samsung_tizen_ws: L10n.tr("三星 Tizen（实验）", "Samsung Tizen (Experimental)")
        case .dlna_dmr: L10n.tr("DLNA（实验）", "DLNA (Experimental)")
        case .kodi_jsonrpc: L10n.tr("Kodi（实验）", "Kodi (Experimental)")
        }
    }

    /// From `Shared/tvProtocolCatalog.json`.
    var defaultPort: Int {
        switch self {
        case .xiaomi_mitv_6095: 6095
        case .tcl_ffalcon_tnscreen: 6553
        case .android_adb_lan: 5555
        case .lg_webos_ssap: 3001
        case .hisense_vidaa_mqtt: 36669
        case .sony_bravia_psk: 80
        case .samsung_tizen_ws: 8002
        case .dlna_dmr: 1900
        case .kodi_jsonrpc: 8080
        }
    }

    /// Drivers that need a pairing secret, and what the TV calls it.
    var credentialTitle: String? {
        switch self {
        case .sony_bravia_psk: L10n.tr("预共享密钥（PSK）", "Pre-shared key (PSK)")
        case .lg_webos_ssap: L10n.tr("配对密钥（Client Key）", "Client key")
        case .hisense_vidaa_mqtt: L10n.tr("配对码（PIN，可选）", "Pairing PIN (optional)")
        case .samsung_tizen_ws: L10n.tr("访问令牌（Token）", "Access token")
        default: nil
        }
    }
}

/// Optional multi-brand TV bridge (ADR-0026): an out-of-process `mbh-tv-bridge` that drives TVs the
/// built-in sources cannot.
///
/// Off by default. While off it starts no process, sends no RPC and runs no timer, and the panel is
/// unchanged. Pairing secrets live only in the Keychain (`tvBridge.cred.<nativeId>`); the saved
/// config holds the slot name. Rows join the panel through `HomeStore.setAdapterDevices`, where a
/// built-in TV always wins a duplicate, and writes come back through `HomeStore`'s guards.
@MainActor
@Observable
final class TVBridgeStore {
    static let shared = TVBridgeStore()
    nonisolated static let binaryName = "mbh-tv-bridge"

    nonisolated static func visibleDrivers(includeExperimental: Bool) -> [TVBridgeDeviceConfig.Driver] {
        includeExperimental ? TVBridgeDeviceConfig.Driver.allCases : TVBridgeDeviceConfig.Driver.primaryCases
    }

    enum Status: Equatable {
        case disabled
        case missingBinary
        case idle
        case running
        case failed(String)
    }

    /// Where pairing secrets go. The live store is the Keychain; tests pass a dictionary.
    struct Secrets {
        var load: (String) -> String?
        var save: (_ value: String, _ slot: String) -> Bool

        @MainActor static let keychain = Secrets(
            load: { slot in
                let value = KeychainHelper.loadSecret(account: slot)
                return value.isEmpty ? nil : value
            },
            save: { value, slot in KeychainHelper.saveSecret(value, account: slot) }
        )
    }

    typealias ManagerFactory = (TVBridgeConfig, _ credentials: [String: String]) -> TVBridgePluginManager

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: Secrets
    @ObservationIgnored private let makeManager: ManagerFactory
    @ObservationIgnored private let binaryCandidates: () -> [String]
    @ObservationIgnored private var manager: TVBridgePluginManager?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var panelVisible = false
    /// One-shot stop after the panel closes; cancelled when it reopens. Never set while off or stopped.
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    /// `nil` waits `config.idleShutdownSeconds`; tests pass a short delay.
    @ObservationIgnored private let idleDelay: Duration?
    @ObservationIgnored private weak var home: HomeStore?
    /// Bumped on every disable or config change so an in-flight snapshot cannot repopulate the panel.
    @ObservationIgnored private var generation = 0

    private(set) var config: TVBridgeConfig
    private(set) var devices: [SmartDevice] = []
    private(set) var status: Status = .disabled
    private(set) var isRefreshing = false
    private(set) var detectedBinaryPath: String?

    var isEnabled: Bool { config.isEnabled }
    var effectiveBinaryPath: String? { config.binaryPath ?? detectedBinaryPath }

    init(
        defaults: UserDefaults = .standard,
        secrets: Secrets = .keychain,
        binaryCandidates: @escaping () -> [String] = TVBridgeStore.defaultBinaryCandidates,
        idleDelay: Duration? = nil,
        makeManager: @escaping ManagerFactory = TVBridgeStore.liveManager
    ) {
        self.idleDelay = idleDelay
        self.defaults = defaults
        self.secrets = secrets
        self.binaryCandidates = binaryCandidates
        self.makeManager = makeManager
        config = TVBridgeConfig.load(from: defaults)
        if config.isEnabled { detectBinary() }
        status = idleStatus
    }

    nonisolated static func liveManager(_ config: TVBridgeConfig, credentials: [String: String]) -> TVBridgePluginManager {
        TVBridgePluginManager(config: config, credentialResolver: { credentials[$0] })
    }

    nonisolated static func defaultBinaryCandidates() -> [String] {
        var paths: [String] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("MenuBarMijia/TVBridge", isDirectory: true)
            paths.append(dir.appendingPathComponent("bin/\(binaryName)").path)
            paths.append(dir.appendingPathComponent(binaryName).path)
        }
        paths.append("/opt/homebrew/bin/\(binaryName)")
        paths.append("/usr/local/bin/\(binaryName)")
        return paths
    }

    /// Routes `adapter:` writes and panel/system changes here. Both are no-ops while the bridge is off.
    func attach(to home: HomeStore) {
        self.home = home
        home.adapterCommandHandler = { [weak self] command in
            guard let self else { throw TVBridgeError.disabled }
            try await self.execute(command)
        }
        home.adapterPollingContextHandler = { [weak self] context in
            self?.pollingContextChanged(context)
        }
        home.setAdapterDevices(devices)
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        guard enabled != config.isEnabled else { return }
        config.isEnabled = enabled
        if enabled { detectBinary() }
        apply(config)
        if enabled, panelVisible { refresh() }
    }

    func setBinaryPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != config.binaryPath else { return }
        config.binaryPath = next
        if next == nil { detectBinary() }
        apply(config)
    }

    func setExpectedSHA256(_ digest: String) {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != config.expectedBinarySHA256 else { return }
        config.expectedBinarySHA256 = next
        apply(config)
    }

    /// Adds a TV. A secret goes to the Keychain first; a refused write adds nothing.
    @discardableResult
    func addDevice(
        name: String, roomName: String, driver: TVBridgeDeviceConfig.Driver,
        host: String, port: Int?, macAddress: String?, secret: String?
    ) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty, port.map({ (1...65_535).contains($0) }) ?? true else { return false }
        let nativeId = "tv-" + UUID().uuidString.prefix(8).lowercased()
        var slot: String?
        if driver.credentialTitle != nil, let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            let account = "tvBridge.cred.\(nativeId)"
            guard secrets.save(secret, account) else { return false }
            slot = account
        }
        let mac = macAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        config.devices.append(TVBridgeDeviceConfig(
            nativeId: nativeId, driver: driver, host: host, port: port, name: name,
            roomName: roomName.trimmingCharacters(in: .whitespacesAndNewlines),
            macAddress: mac?.isEmpty == false ? mac : nil, credentialSlot: slot
        ))
        apply(config)
        if panelVisible { refresh() }
        return true
    }

    func removeDevice(nativeId: String) {
        guard let removed = config.devices.first(where: { $0.nativeId == nativeId }) else { return }
        if let slot = removed.credentialSlot { _ = secrets.save("", slot) }
        config.devices.removeAll { $0.nativeId == nativeId }
        apply(config)
        if panelVisible { refresh() }
    }

    // MARK: - Panel

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard config.isEnabled else { return nil }
        if let refreshTask { return refreshTask }
        guard effectiveBinaryPath != nil else {
            status = .missingBinary
            return nil
        }
        guard !config.devices.isEmpty else {
            publish([])
            return nil
        }
        let manager = resolvedManager()
        let token = generation
        isRefreshing = true
        let task = Task { [weak self] in
            guard let self, token == self.generation, self.config.isEnabled else { return }
            let result: Result<[SmartDevice], Error>
            do { result = .success(try await manager.snapshot()) } catch { result = .failure(error) }
            // Switched off or reconfigured while starting: the retired manager must not keep a process.
            guard token == self.generation, self.config.isEnabled else {
                await manager.shutdown()
                return
            }
            let running = await manager.isRunning
            let hardwareIds = await manager.hardwareIdentifiers
            self.finishRefresh(result, running: running, hardwareIds: hardwareIds, token: token)
        }
        refreshTask = task
        return task
    }

    private func finishRefresh(
        _ result: Result<[SmartDevice], Error>, running: Bool, hardwareIds: [String: [String]], token: Int
    ) {
        guard token == generation, config.isEnabled else { return }
        refreshTask = nil
        isRefreshing = false
        switch result {
        case .success(let rows):
            publish(rows.map(Self.routable), hardwareIds: hardwareIds)
            status = running ? .running : idleStatus
            // The panel may have closed while the bridge was starting: the close found nothing to stop.
            if running, !panelVisible, idleTask == nil, let manager {
                let hidden = TVBridgePollingContext(panelVisible: false, systemActive: true, lowPower: false)
                track { [weak self] in
                    await manager.updatePollingContext(hidden)
                    guard let self, self.manager === manager, !self.panelVisible, self.config.isEnabled else { return }
                    self.scheduleIdleShutdown(manager)
                }
            }
        case .failure(let error):
            publish([])
            status = .failed(Self.friendlyMessage(for: error))
        }
    }

    func pollingContextChanged(_ context: PollingContext) {
        let opened = context.panelVisible && !panelVisible
        let closed = !context.panelVisible && panelVisible
        panelVisible = context.panelVisible
        if context.panelVisible { cancelIdleShutdown() }
        guard config.isEnabled else { return }
        if let manager {
            let bridgeContext = TVBridgePollingContext(
                panelVisible: context.panelVisible, systemActive: context.systemActive, lowPower: context.lowPower
            )
            track { [weak self] in
                await manager.updatePollingContext(bridgeContext)
                let running = await manager.isRunning
                guard let self, self.manager === manager else { return }
                if !running, self.status == .running { self.status = self.idleStatus }
                // `host.contextChanged` alone never fires again once the panel stays shut, so the
                // idle stop is a timer of its own.
                if closed, running, !self.panelVisible, self.config.isEnabled { self.scheduleIdleShutdown(manager) }
            }
        }
        if opened { refresh() }
    }

    // MARK: - Writes

    func execute(_ command: DeviceCommand) async throws {
        guard config.isEnabled else { throw TVBridgeError.disabled }
        guard let (deviceId, bridgeCommand) = Self.bridgeCommand(for: command) else {
            throw TVBridgeError.unsupportedCommand
        }
        let manager = resolvedManager()
        do {
            try await manager.execute(deviceId: deviceId, command: bridgeCommand, capabilityGeneration: 1)
        } catch {
            if self.manager === manager { status = .failed(Self.friendlyMessage(for: error)) }
            throw error
        }
        guard self.manager === manager else { return }
        status = .running
        if panelVisible { refresh() }
    }

    /// Ties the drawer's controls to commands this store can route: every target is the row id,
    /// with `#mute` / `#power.on` / `#power.off` for the controls `HomeStore` addresses separately.
    static func routable(_ device: SmartDevice) -> SmartDevice {
        guard case .tv(var spec) = device.kind else { return device }
        spec.mediaEntityId = device.id
        spec.remoteEntityId = device.id
        spec.muteSwitchEntityId = device.id + "#mute"
        spec.powerOnActionId = device.id + "#power.on"
        spec.powerOffActionId = device.id + "#power.off"
        var routed = device
        routed.kind = .tv(spec)
        return routed
    }

    static func bridgeCommand(for command: DeviceCommand) -> (String, TVBridgeCommand)? {
        let target: String
        let mapped: (String?) -> TVBridgeCommand?
        switch command {
        case .pressButton(let id):
            target = id
            mapped = { $0 == "power.on" ? .power(true) : $0 == "power.off" ? .power(false) : nil }
        case .setSwitch(let id, let isOn):
            target = id
            mapped = { $0 == "mute" ? .setMute(isOn) : $0 == nil ? .power(isOn) : nil }
        case .mediaSetVolume(let id, let level): target = id; mapped = { _ in .setVolume(level) }
        case .mediaSelectSource(let id, let source): target = id; mapped = { _ in .selectSource(source) }
        case .mediaPlayPause(let id): target = id; mapped = { _ in .playPause }
        case .mediaNextTrack(let id): target = id; mapped = { _ in .next }
        case .mediaPreviousTrack(let id): target = id; mapped = { _ in .previous }
        case .mediaSeek(let id, let position): target = id; mapped = { _ in .seek(position) }
        case .remoteSendKey(let id, let key): target = id; mapped = { _ in .remoteKey(key.rawValue) }
        default: return nil
        }
        let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
        guard let deviceId = parts.first, HomeStore.isAdapterDeviceId(deviceId),
              let bridgeCommand = mapped(parts.count > 1 ? parts[1] : nil) else { return nil }
        return (deviceId, bridgeCommand)
    }

    /// Lets tests (and teardown) wait for queued bridge work.
    func waitForPendingWork() async {
        await refreshTask?.value
        while let task = backgroundTasks.values.first ?? idleTask { await task.value }
    }

    /// App quit: asks the bridge to shut down for at most `timeout`, then sends `SIGTERM` → short wait
    /// → `SIGKILL` to any process still alive without waiting on the request lock.
    func shutdownNow(timeout: TimeInterval = 0.2) {
        generation += 1
        cancelIdleShutdown()
        refreshTask?.cancel()
        refreshTask = nil
        if let manager {
            self.manager = nil
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await manager.shutdown()
                done.signal()
            }
            _ = done.wait(timeout: .now() + timeout)
        }
        StdioTVBridgeTransport.terminateAllImmediately(gracePeriod: timeout)
    }

    private func scheduleIdleShutdown(_ manager: TVBridgePluginManager) {
        cancelIdleShutdown()
        let delay = idleDelay ?? .seconds(config.idleShutdownSeconds)
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.manager === manager, !self.panelVisible else { return }
            self.idleTask = nil
            await manager.shutdown()
            if self.manager === manager, self.status == .running { self.status = self.idleStatus }
        }
    }

    private func cancelIdleShutdown() {
        idleTask?.cancel()
        idleTask = nil
    }

    // MARK: - Internals

    private var idleStatus: Status {
        guard config.isEnabled else { return .disabled }
        return effectiveBinaryPath == nil ? .missingBinary : .idle
    }

    private func detectBinary() {
        guard config.binaryPath == nil else { return }
        detectedBinaryPath = binaryCandidates().first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Saves `next` and drops the running bridge so the next refresh starts on the new config.
    private func apply(_ next: TVBridgeConfig) {
        try? next.save(to: defaults)
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        cancelIdleShutdown()
        if let old = manager {
            manager = nil
            // Disable the retired manager first, so a start already in flight cannot bring it back.
            var retired = next
            retired.isEnabled = false
            track { await old.updateConfig(retired) }
        }
        if !next.isEnabled { publish([]) }
        status = idleStatus
    }

    private func resolvedManager() -> TVBridgePluginManager {
        if let manager { return manager }
        var effective = config
        effective.binaryPath = effectiveBinaryPath
        var credentials: [String: String] = [:]
        for slot in config.devices.compactMap(\.credentialSlot) {
            credentials[slot] = secrets.load(slot)
        }
        let created = makeManager(effective, credentials)
        manager = created
        return created
    }

    private func publish(_ rows: [SmartDevice], hardwareIds: [String: [String]] = [:]) {
        devices = rows
        home?.setAdapterDevices(rows, hardwareIds: hardwareIds)
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        backgroundTasks[id] = Task { [weak self] in
            await work()
            self?.backgroundTasks[id] = nil
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        switch error as? TVBridgeError {
        case .binaryMismatch:
            return L10n.tr("mbh-tv-bridge 校验值不匹配，已拒绝启动", "mbh-tv-bridge failed its SHA-256 check and was not started")
        case .manifestMismatch:
            return L10n.tr("插件清单校验失败，已拒绝启动", "The plugin manifest failed verification")
        case .rpcError(_, let message):
            return L10n.format("电视返回错误：%@", "The TV reported an error: %@", message)
        case .unsupportedCommand:
            return L10n.tr("该电视不支持此操作", "This TV doesn't support that action")
        default:
            return L10n.tr("无法启动或连接 mbh-tv-bridge，请检查二进制路径与电视网络", "Couldn't start or reach mbh-tv-bridge. Check the binary path and the TV's network")
        }
    }
}
