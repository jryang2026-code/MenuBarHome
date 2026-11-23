import Foundation

public struct HomeBackendDescriptor: Sendable {
    public let backend: HomeBackend
    private let titleProvider: @Sendable () -> String
    public let isConfigured: @MainActor @Sendable (HomeStore) -> Bool
    public let primaryScopeIdentifier: @MainActor @Sendable (HomeStore) -> String?
    public let activeScopeIdentifiers: @MainActor @Sendable (HomeStore) -> Set<String>
    public let makeProvider: @MainActor @Sendable (HomeStore) -> any HomeProvider

    public var title: String { titleProvider() }

    public init(
        backend: HomeBackend,
        titleProvider: @escaping @Sendable () -> String,
        isConfigured: @escaping @MainActor @Sendable (HomeStore) -> Bool,
        primaryScopeIdentifier: @escaping @MainActor @Sendable (HomeStore) -> String?,
        activeScopeIdentifiers: @escaping @MainActor @Sendable (HomeStore) -> Set<String>,
        makeProvider: @escaping @MainActor @Sendable (HomeStore) -> any HomeProvider
    ) {
        self.backend = backend
        self.titleProvider = titleProvider
        self.isConfigured = isConfigured
        self.primaryScopeIdentifier = primaryScopeIdentifier
        self.activeScopeIdentifiers = activeScopeIdentifiers
        self.makeProvider = makeProvider
    }

    public static func activeBackends(
        homeBackend: HomeBackend,
        configuredSources: Set<HomeBackend>,
        disabledSources: Set<HomeBackend> = []
    ) -> Set<HomeBackend> {
        if homeBackend == .demo {
            return [.demo]
        }
        let liveSources = configuredSources.subtracting([.demo])
        let candidates = liveSources.isEmpty ? [homeBackend] : liveSources
        return candidates.subtracting(disabledSources)
    }
}

extension HomeBackend {
    public var descriptor: HomeBackendDescriptor {
        switch self {
        case .homeAssistant:
            return HomeBackendDescriptor(
                backend: .homeAssistant,
                titleProvider: { "Home Assistant" },
                isConfigured: { $0.hasHASource && $0.isHAConnectionEnabled },
                primaryScopeIdentifier: { $0.isHAConnectionEnabled ? $0.homeAssistantScopeIdentifier : nil },
                activeScopeIdentifiers: { ($0.hasHASource && $0.isHAConnectionEnabled) ? [$0.homeAssistantScopeIdentifier] : [] },
                makeProvider: { $0.makeHAProvider(baseURLString: $0.serverURLString, token: $0.loadHAToken()) }
            )
        case .xiaomiCloud:
            return HomeBackendDescriptor(
                backend: .xiaomiCloud,
                titleProvider: { L10n.tr("米家云端直连", "Xiaomi Cloud Direct") },
                isConfigured: { $0.hasMiSource },
                primaryScopeIdentifier: {
                    if $0.miAccounts.isEmpty {
                        return $0.hasEnabledMiSource ? $0.miSessionScopeIdentifier : nil
                    }
                    return $0.enabledMiAccounts.first?.session.historyScopeIdentifier
                },
                activeScopeIdentifiers: {
                    if $0.miAccounts.isEmpty {
                        return ($0.hasMiSource && $0.hasEnabledMiSource)
                            ? Set([$0.miSessionScopeIdentifier].compactMap { $0 })
                            : []
                    }
                    return Set($0.enabledMiAccounts.map(\.id))
                },
                makeProvider: { $0.makeMiAccountsProvider() }
            )
        case .demo:
            return HomeBackendDescriptor(
                backend: .demo,
                titleProvider: { L10n.tr("演示模式", "Demo Mode") },
                isConfigured: { $0.homeBackend == .demo },
                primaryScopeIdentifier: { _ in "demo" },
                activeScopeIdentifiers: { _ in ["demo"] },
                makeProvider: { _ in DemoHomeProvider() }
            )
        }
    }
}

extension HomeStore {
    public var activeBackends: Set<HomeBackend> {
        let configuredSources: Set<HomeBackend> = Set([
            hasHASource ? .homeAssistant : nil,
            hasMiSource ? .xiaomiCloud : nil,
        ].compactMap { $0 })
        let isMiEnabled = hasMiSource ? hasEnabledMiSource : isMiOnboardingBackendEnabled
        let disabledSources: Set<HomeBackend> = Set([
            isHAConnectionEnabled ? nil : .homeAssistant,
            isMiEnabled ? nil : .xiaomiCloud,
        ].compactMap { $0 })
        return HomeBackendDescriptor.activeBackends(
            homeBackend: homeBackend,
            configuredSources: configuredSources,
            disabledSources: disabledSources
        )
    }
}
