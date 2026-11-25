import Darwin
import Foundation
import KeychainTestSupport
import PreferencesTestSupport
import StateTestSupport
import Testing
@testable import MenuBarMijiaApp
@testable import MijiaCore

private final class LockedHooksState: @unchecked Sendable {
    private let lock = NSLock()
    private var _failFullFsync = true

    var failFullFsync: Bool {
        get { lock.withLock { _failFullFsync } }
        set { lock.withLock { _failFullFsync = newValue } }
    }
}

@MainActor
@Suite("Connection removal quarantine recovery UI guidance", .timeLimit(.minutes(1)))
struct ConnectionRemovalRecoveryUITests {
    private static let sessionA = MiSession(
        userId: "10001",
        cUserId: "c1",
        ssecurity: "sec-a",
        serviceToken: "tok-a",
        region: "cn",
        expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
    )

    @Test("Guidance distinguishes F_FULLFSYNC-unsupported volumes from transient/verification failures in zhHans and en")
    func guidanceDistinguishesFailureKinds() {
        let fullFsyncDefault = ConnectionRemovalQuarantineFailure(
            kind: .fullFsyncUnsupported,
            directoryPath: "/Volumes/NetworkHome/Application Support/MenuBarMijia-ConnectionRemovalQuarantine",
            errorCode: ENOTSUP,
            usedAlternateDirectory: false
        )
        let fullFsyncAlternate = ConnectionRemovalQuarantineFailure(
            kind: .fullFsyncUnsupported,
            directoryPath: "/Volumes/ExternalExFAT/MenuBarMijia-ConnectionRemovalQuarantine",
            errorCode: ENOTSUP,
            usedAlternateDirectory: true
        )
        let transient = ConnectionRemovalQuarantineFailure(
            kind: .transientOrVerificationFailed,
            directoryPath: "/tmp/quarantine",
            errorCode: EIO,
            usedAlternateDirectory: false
        )

        L10n.$overrideLanguage.withValue(.zhHans) {
            let copyDefault = CorruptRemovalRecoveryGuidance.resolve(failure: fullFsyncDefault)
            let copyAlt = CorruptRemovalRecoveryGuidance.resolve(failure: fullFsyncAlternate)
            let copyTransient = CorruptRemovalRecoveryGuidance.resolve(failure: transient)

            #expect(copyDefault.title.contains("无法安全保存数据"))
            #expect(!copyDefault.title.contains("F_FULLFSYNC"))
            #expect(copyDefault.detail.contains("NetworkHome"))
            #expect(copyDefault.detail.contains("换到 Mac 内置磁盘上的文件夹再试"))
            #expect(copyDefault.steps.count == 2)
            #expect(copyDefault.actions.primaryRetryTitle == "重试原位置")
            #expect(copyDefault.actions.showsChooseAlternateFolderButton)
            #expect(copyDefault.actions.chooseAlternateFolderTitle == "选择本地文件夹并重试…")

            #expect(copyAlt.title.contains("所选文件夹"))
            #expect(copyAlt.detail.contains("ExternalExFAT"))

            #expect(copyTransient.title != copyDefault.title)
            #expect(!copyTransient.title.contains("无法安全保存数据"))
            #expect(copyTransient.detail.contains("回读校验"))
            #expect(copyTransient.actions.primaryRetryTitle == "重试放弃记录")
            #expect(copyTransient.actions.showsChooseAlternateFolderButton)
        }

        L10n.$overrideLanguage.withValue(.en) {
            let copyDefault = CorruptRemovalRecoveryGuidance.resolve(failure: fullFsyncDefault)
            let copyAlt = CorruptRemovalRecoveryGuidance.resolve(failure: fullFsyncAlternate)
            let copyTransient = CorruptRemovalRecoveryGuidance.resolve(failure: transient)

            #expect(copyDefault.title.contains("cannot save data safely"))
            #expect(copyDefault.detail.contains("NetworkHome"))
            #expect(copyDefault.actions.primaryRetryTitle == "Retry Default Location")
            #expect(copyDefault.actions.chooseAlternateFolderTitle == "Choose Local Folder & Retry…")

            #expect(copyAlt.title.contains("selected folder"))
            #expect(copyTransient.title != copyDefault.title)
            #expect(copyTransient.detail.contains("read-back"))
            #expect(copyTransient.actions.primaryRetryTitle == "Retry Discard")
        }
    }

    @Test("HomeStore exposes F_FULLFSYNC recovery state without touching real Application Support and clears it once recovered")
    func storeDrivesRecoveryGuidanceAndAlternateFolderCleanup() async throws {
        let mem = MemoryVaultStorage()
        let vault = CredentialVault(storage: mem.storage)
        let defaults = InMemoryUserDefaults()
        #expect(MiSessionStore.saveAccounts([MiAccount(session: Self.sessionA)], defaults: defaults, vault: vault))
        let corrupt = Data("{broken-removal-json".utf8)
        defaults.set(corrupt, forKey: ConnectionRemovalStore.storageKey)

        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("ui-recovery-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let injectedDefault = root.appendingPathComponent("fake-app-support-quarantine", isDirectory: true)
        let localParent = root.appendingPathComponent("local-apfs-parent", isDirectory: true)
        try files.createDirectory(at: localParent, withIntermediateDirectories: false)

        let state = LockedHooksState()
        let store = HomeStore(
            credentialVault: vault,
            miAccountsProviderFactory: { accounts in
                MiAccountsProvider(accounts: accounts, localClientFactory: { nil }, pollInterval: .seconds(3600), followUpDelay: .seconds(3600))
            },
            haProviderFactory: { _, _ in MockHomeProvider() },
            defaults: defaults
        )
        store.toastAutoDismissInterval = nil
        store.corruptRemovalQuarantineHooks = ConnectionRemovalStore.QuarantinePersistenceHooks(
            defaultDirectory: { injectedDefault },
            syncFD: { fd, _ in fsync(fd) == 0 ? 0 : errno },
            fullFsync: { fd, destination in
                if state.failFullFsync && destination.standardizedFileURL == injectedDefault.standardizedFileURL {
                    return ENOTSUP
                }
                return fcntl(fd, F_FULLFSYNC) == 0 ? 0 : errno
            },
            readBack: { handle, _ in try? (handle.readToEnd() ?? Data()) }
        )

        #expect(store.canDiscardCorruptConnectionRemovalRecord)
        #expect(store.corruptRemovalDiscardFailure == nil)
        #expect(!store.discardCorruptConnectionRemovalRecord())

        let failure = try #require(store.corruptRemovalDiscardFailure)
        #expect(failure.kind == .fullFsyncUnsupported)
        let guidance = CorruptRemovalRecoveryGuidance.resolve(failure: failure)
        #expect(guidance.actions.showsChooseAlternateFolderButton)
        #expect(store.hasCorruptConnectionRemovalState)
        #expect(defaults.data(forKey: ConnectionRemovalStore.storageKey) == corrupt)

        #expect(store.discardCorruptConnectionRemovalRecord(inAlternateParentDirectory: localParent))
        try await awaitState { !store.isIdentityUncertain && store.miAccounts.count == 1 }
        #expect(store.corruptRemovalDiscardFailure == nil)
        #expect(!store.hasCorruptConnectionRemovalState)
        #expect(defaults.object(forKey: ConnectionRemovalStore.storageKey) == nil)
    }
}
