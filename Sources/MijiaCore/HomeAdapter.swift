/// The in-process contract for a built-in source. HomeStore owns write authorization.
protocol HomeAdapter: Sendable {
    var id: HomeAdapterID { get async }
    var capabilities: Set<HomeProviderCapability> { get }
    /// The last published snapshot for the current configuration, when available.
    func snapshot() async -> SynthesizedHome?
    /// The host's single event stream for this connection.
    func events() -> AsyncStream<HomeAdapterEvent>
    func execute(command: DeviceCommand) async -> AdapterWriteResult
}

struct HomeAdapterID: Equatable, Sendable {
    let backend: HomeBackend
    let scope: String
}

enum AdapterWriteResult: Equatable, Sendable {
    case acknowledged
    case failed(AdapterErrorCode)
}

enum HomeAdapterEvent: Sendable {
    case statusChanged(ConnectionStatus)
    case snapshotUpdated(SynthesizedHome)
    case localNetworkPermissionChanged(Set<LocalNetworkBlockedFeature>)
    case doorbellRang(DoorbellRing)
    case haTypePruneChanged(MiotTypePruneReport)

    var providerEvent: HomeProviderEvent {
        switch self {
        case .statusChanged(let status): return .statusChanged(status)
        case .snapshotUpdated(let home): return .snapshotUpdated(home)
        case .localNetworkPermissionChanged(let blocked): return .localNetworkPermissionChanged(blocked)
        case .doorbellRang(let ring): return .doorbellRang(ring)
        case .haTypePruneChanged(let report): return .haTypePruneChanged(report)
        }
    }
}

final class HAHomeAdapter: HomeAdapter {
    let provider: HAWebSocketProvider

    init(provider: HAWebSocketProvider) {
        self.provider = provider
    }

    var id: HomeAdapterID {
        get async {
            let url = await provider.currentBaseURLString
            return HomeAdapterID(backend: .homeAssistant, scope: ConnectionRemovalStore.haScope(serverURL: url))
        }
    }
    var capabilities: Set<HomeProviderCapability> { HAWebSocketProvider.capabilities }

    func snapshot() async -> SynthesizedHome? {
        await provider.latestSnapshot
    }

    func events() -> AsyncStream<HomeAdapterEvent> {
        provider.eventStream { $0 }
    }

    func execute(command: DeviceCommand) async -> AdapterWriteResult {
        do {
            try await execute(command)
            return .acknowledged
        } catch {
            switch command {
            case .setMiotProperty, .callMiotAction: return .failed(.unsupported)
            default: return .failed(AdapterErrorCode(classifying: error))
            }
        }
    }
}

// The existing host path preserves the original error for control feedback and diagnostics.
extension HAHomeAdapter: HomeProvider {
    func events() -> AsyncStream<HomeProviderEvent> {
        provider.events()
    }

    func execute(_ command: DeviceCommand) async throws {
        try await provider.execute(command)
    }

    func refreshNow() async {
        await provider.refreshNow()
    }

    func setPollingContext(_ context: PollingContext) async {
        await provider.setPollingContext(context)
    }

    func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        try await provider.resolveCameraStream(for: device)
    }

    func shutdown() async {
        await provider.shutdown()
    }
}

extension HomeProvider {
    var haWebSocketProvider: HAWebSocketProvider? {
        (self as? HAHomeAdapter)?.provider ?? self as? HAWebSocketProvider
    }
}
