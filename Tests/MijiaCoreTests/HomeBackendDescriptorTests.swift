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

    @Test("All 12 combinations of homeBackend, hasHASource, and hasMiSource resolve expected activeBackends")
    @MainActor
    func activeBackendsExhaustiveMatrix() {
        let suite = "test.backend.descriptor.matrix.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])),
            defaultsSuiteName: suite
        )

        for backend in HomeBackend.allCases {
            for hasHA in [false, true] {
                for hasMi in [false, true] {
                    store.homeBackend = backend
                    store.hasHASource = hasHA
                    store.miSessionMaskedUserId = hasMi ? "100***01" : nil

                    let expected: Set<HomeBackend>
                    if backend == .demo {
                        expected = [.demo]
                    } else if hasHA && hasMi {
                        expected = [.homeAssistant, .xiaomiCloud]
                    } else if hasHA {
                        expected = [.homeAssistant]
                    } else if hasMi {
                        expected = [.xiaomiCloud]
                    } else {
                        expected = [backend]
                    }

                    let computed = HomeBackendDescriptor.activeBackends(
                        homeBackend: backend,
                        hasHASource: hasHA,
                        hasMiSource: hasMi
                    )
                    #expect(computed == expected)
                    #expect(store.activeBackends == expected)
                }
            }
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
        #expect(haProvider is HAWebSocketProvider)
        #expect(miProvider is MiAccountsProvider)
        #expect(demoProvider is DemoHomeProvider)
        await haProvider.shutdown()
        await miProvider.shutdown()
        await demoProvider.shutdown()
    }
}
