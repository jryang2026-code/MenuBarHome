import Foundation
import Testing
@testable import MijiaCore

struct HomeBackendDescriptorTests {
    @Test("Every HomeBackend case has a matching descriptor and localized title")
    func descriptorIdentityAndTitles() {
        let languages: [AppLanguage] = [.zhHans, .zhHant, .en]
        for backend in HomeBackend.allCases {
            let descriptor = backend.descriptor
            #expect(descriptor.backend == backend)
            for lang in languages {
                L10n.$overrideLanguage.withValue(lang) {
                    #expect(descriptor.title == backend.title)
                    #expect(!descriptor.title.isEmpty)
                }
            }
        }
    }

    @Test("Zero, one, and two configured sources preserve backend selection")
    @MainActor
    func activeBackendsExhaustiveMatrix() {
        let suite = "test.backend.descriptor.matrix.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])),
            defaultsSuiteName: suite
        )

        let sourceSets: [Set<HomeBackend>] = [
            [], [.homeAssistant], [.xiaomiCloud], [.homeAssistant, .xiaomiCloud],
        ]
        for backend in HomeBackend.allCases {
            for configured in sourceSets {
                store.homeBackend = backend
                store.hasHASource = configured.contains(.homeAssistant)
                store.miSessionMaskedUserId = configured.contains(.xiaomiCloud) ? "100***01" : nil

                let expected = backend == .demo || configured.isEmpty ? [backend] : configured
                #expect(store.activeBackends == expected)
                for disabled in sourceSets {
                    let computed = HomeBackendDescriptor.activeBackends(
                        homeBackend: backend,
                        configuredSources: configured,
                        disabledSources: disabled
                    )
                    #expect(computed == (backend == .demo ? expected : expected.subtracting(disabled)))
                }
            }
        }
    }

    @Test("Built-in providers declare their capabilities")
    func providerCapabilities() {
        #expect(HAWebSocketProvider.capabilities == [.readSnapshot, .pushEvents, .control, .scenes, .cameras])
        #expect(MiCloudProvider.capabilities == [.readSnapshot, .control, .scenes, .cameras])
        #expect(MiAccountsProvider.capabilities == MiCloudProvider.capabilities)
    }

    @Test("Adapter codes classify errors from both providers")
    func adapterErrorCodes() {
        let cases: [(any Error, AdapterErrorCode)] = [
            (HomeProviderError.unauthorized, .authExpired),
            (HomeProviderError.serviceCallFailed(429, "slow down"), .rateLimited),
            (HomeProviderError.serviceCallFailed(501, "unsupported camera"), .unsupported),
            (HomeProviderError.serviceCallFailed(500, "unrecognized failure"), .unknown),
            (MiCloudError.sessionExpired, .authExpired),
            (MiCloudError.http(429), .rateLimited),
            (MiCloudError.http(501), .unsupported),
            (MiCloudError.deviceError(code: ControlFailure.deviceOfflineMiotCode, message: "offline"), .deviceOffline),
            (MiCloudError.api(code: ControlFailure.deviceOfflineMiotCode, message: "envelope error"), .unknown),
            (MiotCommandError.unsupported("power"), .unsupported),
            (URLError(.cannotConnectToHost), .unreachable),
        ]
        for (error, code) in cases {
            #expect(AdapterErrorCode(classifying: error) == code)
        }
    }

    @Test("Descriptor configuration, scopes, and provider factories match HomeStore connection scopes")
    @MainActor
    func descriptorConfigurationScopesAndFactories() async {
        let suite = "test.backend.descriptor.scopes.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])),
            defaultsSuiteName: suite
        )
        store.serverURLString = "http://192.0.2.10:8123"

        let cnAccount = MiAccount(session: MiSession(
            userId: "10010001", cUserId: "c-cn", ssecurity: "ssec-cn", serviceToken: "tok-cn", region: "cn"
        ))
        let deAccount = MiAccount(session: MiSession(
            userId: "20020002", cUserId: "c-de", ssecurity: "ssec-de", serviceToken: "tok-de", region: "de"
        ))

        store.homeBackend = .demo
        store.hasHASource = false
        store.miAccounts = []
        store.miSessionMaskedUserId = nil
        store.miSessionScopeIdentifier = nil
        #expect(HomeBackend.demo.descriptor.isConfigured(store))
        #expect(!HomeBackend.homeAssistant.descriptor.isConfigured(store))
        #expect(!HomeBackend.xiaomiCloud.descriptor.isConfigured(store))
        #expect(HomeBackend.demo.descriptor.primaryScopeIdentifier(store) == "demo")
        #expect(HomeBackend.demo.descriptor.activeScopeIdentifiers(store) == ["demo"])
        #expect(store.connectionScopeIdentifier == "demo")
        #expect(store.activeConnectionScopes == ["demo"])

        store.homeBackend = .homeAssistant
        #expect(!HomeBackend.demo.descriptor.isConfigured(store))
        #expect(!HomeBackend.homeAssistant.descriptor.isConfigured(store))
        #expect(HomeBackend.homeAssistant.descriptor.primaryScopeIdentifier(store) == "ha:http://192.0.2.10:8123")
        #expect(HomeBackend.homeAssistant.descriptor.activeScopeIdentifiers(store).isEmpty)
        #expect(store.connectionScopeIdentifier == "ha:http://192.0.2.10:8123")
        #expect(store.activeConnectionScopes == ["ha:http://192.0.2.10:8123"])

        store.homeBackend = .xiaomiCloud
        #expect(HomeBackend.xiaomiCloud.descriptor.primaryScopeIdentifier(store) == nil)
        #expect(HomeBackend.xiaomiCloud.descriptor.activeScopeIdentifiers(store).isEmpty)
        #expect(store.connectionScopeIdentifier == nil)
        #expect(store.activeConnectionScopes.isEmpty)

        store.hasHASource = true
        store.miAccounts = [cnAccount, deAccount]
        store.miSessionMaskedUserId = cnAccount.maskedUserId
        store.miSessionScopeIdentifier = cnAccount.session.historyScopeIdentifier
        #expect(HomeBackend.homeAssistant.descriptor.isConfigured(store))
        #expect(HomeBackend.xiaomiCloud.descriptor.isConfigured(store))
        #expect(HomeBackend.homeAssistant.descriptor.primaryScopeIdentifier(store) == "ha:http://192.0.2.10:8123")
        #expect(HomeBackend.xiaomiCloud.descriptor.primaryScopeIdentifier(store) == cnAccount.session.historyScopeIdentifier)
        #expect(HomeBackend.homeAssistant.descriptor.activeScopeIdentifiers(store) == ["ha:http://192.0.2.10:8123"])
        #expect(HomeBackend.xiaomiCloud.descriptor.activeScopeIdentifiers(store) == [cnAccount.id, deAccount.id])
        #expect(store.connectionScopeIdentifier == "ha:http://192.0.2.10:8123")
        #expect(store.activeConnectionScopes == ["ha:http://192.0.2.10:8123", cnAccount.id, deAccount.id])

        store.hasHASource = false
        #expect(store.connectionScopeIdentifier == cnAccount.session.historyScopeIdentifier)
        #expect(store.activeConnectionScopes == [cnAccount.id, deAccount.id])

        let haProvider = HomeBackend.homeAssistant.descriptor.makeProvider(store)
        let miProvider = HomeBackend.xiaomiCloud.descriptor.makeProvider(store)
        let demoProvider = HomeBackend.demo.descriptor.makeProvider(store)
        #expect(haProvider is HAHomeAdapter)
        #expect(miProvider is MiAccountsProvider)
        #expect(demoProvider is DemoHomeProvider)
        await haProvider.shutdown()
        await miProvider.shutdown()
        await demoProvider.shutdown()
    }
}
