import Foundation
import Observation
import MijiaCore

/// One external monitor as the panel shows it: what the transport reported plus the last state read
/// back (or written) over DDC/CI.
struct ExternalDisplayEntry: Identifiable, Equatable {
    let descriptor: DDCCIDisplayDescriptor
    var brightnessPercent: Int?
    var inputSource: DDCCIInputSource?
    var inputSources: [DDCCIInputSource]
    var volumePercent: Int?
    var isMuted: Bool?

    var id: String { descriptor.id }
    var isRedmiOrXiaomi: Bool { descriptor.isRedmiOrXiaomiMonitor }
    var supportsVolume: Bool { volumePercent != nil }

    /// Redmi G27U-class monitors often omit the capabilities string; offer their usual ports.
    static let redmiDefaultInputs: [DDCCIInputSource] = [.dp1, .dp2, .hdmi1, .hdmi2, .usbC]

    init(descriptor: DDCCIDisplayDescriptor, state: DDCCIDisplayState?) {
        self.descriptor = descriptor
        brightnessPercent = state?.brightnessPercent
        inputSource = state?.inputSource
        let reported = state?.supportedInputSources ?? []
        inputSources = !reported.isEmpty ? reported
            : descriptor.isRedmiOrXiaomiMonitor ? Self.redmiDefaultInputs : []
        volumePercent = state?.volumePercent
        isMuted = state?.isMuted
    }
}

extension DDCCIInputSource {
    var displayTitle: String {
        switch self {
        case .dp1: "DP 1"
        case .dp2: "DP 2"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .usbC: "USB-C"
        case .custom(let raw): String(format: "0x%02X", raw)
        }
    }
}

/// Optional external-monitor control over DDC/CI (Redmi G27U and other DDC/CI displays).
///
/// Off by default. While off it never touches the transport: no enumeration, no I²C, no timers.
/// When on it reads only when the panel opens or the user asks for a refresh — never on a schedule.
/// Slider writes are coalesced so a drag sends at most one write per control per interval.
/// Power (VCP 0xD6) is deliberately not offered; `DDCCIVCPGuard` rejects it in the core as well.
@MainActor
@Observable
final class ExternalDisplayStore {
    static let enabledKey = "external_display_ddc_enabled"
    static let shared = ExternalDisplayStore()

    private enum Control: Hashable { case brightness, volume }
    private struct PendingKey: Hashable { let displayId: String; let control: Control }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeController: () -> DDCCIDisplayController?
    @ObservationIgnored private var controller: DDCCIDisplayController?
    /// `nil` writes immediately (tests); the app coalesces drags into one write per 150 ms.
    @ObservationIgnored private let writeInterval: Duration?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingValues: [PendingKey: Int] = [:]
    @ObservationIgnored private var writeTasks: [PendingKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var oneShotTasks: [UUID: Task<Void, Never>] = [:]
    /// Bumped on every disable so a read that was already in flight cannot repopulate the list.
    @ObservationIgnored private var generation = 0

    private(set) var isEnabled: Bool
    private(set) var displays: [ExternalDisplayEntry] = []
    private(set) var isRefreshing = false
    private(set) var hasScanned = false
    private(set) var errorMessage: String?

    var showsPanelCard: Bool { isEnabled && !displays.isEmpty }

    init(
        defaults: UserDefaults = .standard,
        writeInterval: Duration? = .milliseconds(150),
        makeController: @escaping () -> DDCCIDisplayController? = ExternalDisplayStore.liveController
    ) {
        self.defaults = defaults
        self.writeInterval = writeInterval
        self.makeController = makeController
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    convenience init(defaults: UserDefaults, writeInterval: Duration? = nil, transport: any DDCCITransport) {
        self.init(defaults: defaults, writeInterval: writeInterval) {
            DDCCIDisplayController(transport: transport)
        }
    }

    nonisolated static func liveController() -> DDCCIDisplayController? {
        #if os(macOS)
        DDCCIDisplayController(transport: MacOSDDCCITransport())
        #else
        nil
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { reset() }
    }

    /// Called whenever the panel is shown. A no-op while the feature is off.
    func panelDidOpen() {
        guard isEnabled, refreshTask == nil else { return }
        refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        if let refreshTask { return refreshTask }
        guard let controller = resolvedController() else {
            errorMessage = Self.unavailableMessage
            hasScanned = true
            return nil
        }
        let token = generation
        isRefreshing = true
        let task = Task { [weak self] in
            let result: Result<[ExternalDisplayEntry], Error>
            do {
                let found = try await controller.listDisplays()
                var entries: [ExternalDisplayEntry] = []
                for descriptor in found {
                    let state = try? await controller.readState(displayId: descriptor.id)
                    entries.append(ExternalDisplayEntry(descriptor: descriptor, state: state))
                }
                result = .success(entries)
            } catch {
                result = .failure(error)
            }
            self?.finishRefresh(result, token: token)
        }
        refreshTask = task
        return task
    }

    private func finishRefresh(_ result: Result<[ExternalDisplayEntry], Error>, token: Int) {
        guard token == generation else { return }
        refreshTask = nil
        isRefreshing = false
        hasScanned = true
        switch result {
        case .success(let entries):
            displays = entries
            errorMessage = nil
        case .failure(let error):
            displays = []
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    // MARK: - Writes

    func setBrightness(displayId: String, percent: Int) {
        let value = min(max(percent, 0), 100)
        update(displayId) { $0.brightnessPercent = value }
        schedule(PendingKey(displayId: displayId, control: .brightness), value: value)
    }

    func setVolume(displayId: String, percent: Int) {
        let value = min(max(percent, 0), 100)
        update(displayId) { $0.volumePercent = value }
        schedule(PendingKey(displayId: displayId, control: .volume), value: value)
    }

    func setInputSource(displayId: String, source: DDCCIInputSource) {
        update(displayId) { $0.inputSource = source }
        send { try await $0.setInputSource(displayId: displayId, source: source) }
    }

    func setMute(displayId: String, muted: Bool) {
        update(displayId) { $0.isMuted = muted }
        send { try await $0.setMute(displayId: displayId, muted: muted) }
    }

    /// Lets tests (and teardown) wait for every queued write without sleeping on the interval.
    func waitForPendingWrites() async {
        while let task = writeTasks.values.first ?? oneShotTasks.values.first {
            await task.value
        }
        await refreshTask?.value
    }

    private func schedule(_ key: PendingKey, value: Int) {
        guard isEnabled else { return }
        pendingValues[key] = value
        guard writeTasks[key] == nil else { return }
        let interval = writeInterval
        writeTasks[key] = Task { [weak self] in
            if let interval { try? await Task.sleep(for: interval) }
            await self?.flush(key)
        }
    }

    private func flush(_ key: PendingKey) async {
        defer { writeTasks[key] = nil }
        guard isEnabled, let value = pendingValues.removeValue(forKey: key),
              let controller = resolvedController() else { return }
        do {
            switch key.control {
            case .brightness: try await controller.setBrightness(displayId: key.displayId, percent: value)
            case .volume: try await controller.setVolume(displayId: key.displayId, percent: value)
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    private func send(_ write: @escaping @Sendable (DDCCIDisplayController) async throws -> Void) {
        guard isEnabled, let controller = resolvedController() else { return }
        let id = UUID()
        let token = generation
        oneShotTasks[id] = Task { [weak self] in
            let failure: Error?
            do { try await write(controller); failure = nil } catch { failure = error }
            guard let self else { return }
            oneShotTasks[id] = nil
            guard token == generation else { return }
            errorMessage = failure.map(Self.friendlyMessage(for:))
        }
    }

    private func update(_ displayId: String, _ change: (inout ExternalDisplayEntry) -> Void) {
        guard let index = displays.firstIndex(where: { $0.id == displayId }) else { return }
        change(&displays[index])
    }

    private func resolvedController() -> DDCCIDisplayController? {
        if controller == nil { controller = makeController() }
        return controller
    }

    private func reset() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        writeTasks.values.forEach { $0.cancel() }
        writeTasks = [:]
        oneShotTasks = [:]
        pendingValues = [:]
        displays = []
        isRefreshing = false
        hasScanned = false
        errorMessage = nil
        controller = nil
    }

    // MARK: - Copy

    static var unavailableMessage: String {
        L10n.tr("此 Mac 不支持 DDC/CI 外接显示器控制", "DDC/CI display control isn't available on this Mac")
    }

    static func friendlyMessage(for error: Error) -> String {
        if case DDCCIError.transportUnavailable = error { return unavailableMessage }
        if case DDCCIError.forbiddenVCPCode = error {
            return L10n.tr("出于安全考虑，不提供显示器电源控制", "Monitor power control is not offered for safety")
        }
        return L10n.tr(
            "显示器没有响应。请在显示器 OSD 菜单中开启 DDC/CI，或尝试 USB-C/DP 直连",
            "The monitor didn't respond. Turn on DDC/CI in its on-screen menu, or connect over USB-C/DP"
        )
    }
}
