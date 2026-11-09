import CryptoKit
import Foundation
import Testing
@testable import MijiaCore

struct UpdateCheckerTests {
    @Test("A release page outside github.com falls back to the project's releases page")
    func foreignReleasePageFallsBack() async throws {
        let json = #"{"tag_name":"v1.1.0","html_url":"https://evil.example/releases/v1.1.0"}"#
        let result = try await Self.checker(status: 200, body: json).checkRelease()
        #expect(result?.pageURL == UpdateChecker.releasesPage)
    }

    @Test("Versions compare numerically, ignoring a leading v")
    func versionCompare() {
        #expect(AppVersion("v1.10.0")! > AppVersion("1.9.3")!)
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("2.0.0-beta")! > AppVersion("1.9")!)
        #expect(AppVersion("abc") == nil)
    }

    static func checker(status: Int, body: String) -> UpdateChecker {
        UpdateChecker(currentVersion: "1.0.0", transport: { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/jryang2026-code/MenuBarHome/releases/latest")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
    }

    @Test("A newer release is reported with its download page")
    func newerRelease() async throws {
        let json = #"{"tag_name":"v1.1.0","html_url":"https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.1.0","body":"新功能"}"#
        let result = try await Self.checker(status: 200, body: json).checkRelease()
        #expect(
            result == AppRelease(
                version: "1.1.0",
                pageURL: URL(string: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.1.0")!,
                notes: "新功能",
                packageAsset: nil
            )
        )
    }

    @Test("Same version or no releases yet means up to date")
    func upToDate() async throws {
        let same = #"{"tag_name":"v1.0.0","html_url":"https://github.com/x"}"#
        #expect(try await Self.checker(status: 200, body: same).checkRelease() == nil)
        #expect(try await Self.checker(status: 404, body: "{}").checkRelease() == nil)
    }

    @Test("Server errors surface as a thrown error")
    func serverError() async {
        await #expect(throws: UpdateChecker.CheckError.self) {
            _ = try await Self.checker(status: 500, body: "").checkRelease()
        }
    }

    @Test("SHA256Digest parses GitHub inline digest and sidecar lines and streams file verification")
    func sha256DigestParsingAndFileMatching() throws {
        let payload = Data(repeating: 0x5A, count: 140 * 1024)
        let expectedHex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let fromInline = SHA256Digest(parsing: "sha256:\(expectedHex.uppercased())")
        let fromSidecar = SHA256Digest(parsing: "\(expectedHex)  MenuBarHome-1.2.0.dmg\n")
        #expect(fromInline?.hex == expectedHex)
        #expect(fromSidecar == fromInline)
        #expect(SHA256Digest(parsing: "sha256:1234") == nil)
        #expect(SHA256Digest(parsing: String(repeating: "z", count: 64)) == nil)
        #expect(SHA256Digest.hash(payload) == fromInline)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("digest-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try payload.write(to: tempFile)
        #expect(try SHA256Digest.hashFile(at: tempFile) == fromInline)
    }

    @Test("checkRelease selects the DMG only when the update manifest is listed")
    func checkReleaseSelectsDMGWhenManifestIsListed() async throws {
        let zipOnly = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.2.0",
          "body": "支持应用内更新",
          "assets": [
            {
              "name": "MenuBarHome-1.2.0.zip",
              "browser_download_url": "https://example.com/MenuBarHome-1.2.0.zip",
              "size": 1024,
              "digest": "sha256:\(String(repeating: "a", count: 64))"
            },
            {
              "name": "MenuBarHome-1.2.0.update.json",
              "browser_download_url": "https://example.com/MenuBarHome-1.2.0.update.json"
            }
          ]
        }
        """
        let withoutDMG = try await Self.checker(status: 200, body: zipOnly).checkRelease()
        #expect(withoutDMG?.version == "1.2.0")
        #expect(withoutDMG?.packageAsset == nil)

        let digestOnly = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.2.0",
          "assets": [
            {
              "name": "MenuBarHome-1.2.0.dmg",
              "browser_download_url": "https://example.com/MenuBarHome-1.2.0.dmg",
              "size": 2048,
              "digest": "sha256:\(String(repeating: "a", count: 64))"
            }
          ]
        }
        """
        #expect(try await Self.checker(status: 200, body: digestOnly).checkRelease()?.packageAsset == nil)

        let listed = """
        {
          "tag_name": "v1.3.0",
          "html_url": "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.3.0",
          "body": "清单在场",
          "assets": [
            {
              "name": "MenuBarHome-1.3.0.zip",
              "browser_download_url": "https://example.com/MenuBarHome-1.3.0.zip",
              "digest": "sha256:\(String(repeating: "b", count: 64))"
            },
            {
              "name": "MenuBarHome-1.3.0.dmg",
              "browser_download_url": "https://example.com/MenuBarHome-1.3.0.dmg",
              "size": 4096
            },
            {
              "name": "MenuBarHome-1.3.0.update.json",
              "size": 526
            }
          ]
        }
        """
        let release = try await Self.checker(status: 200, body: listed).checkRelease()
        #expect(release?.notes == "清单在场")
        #expect(release?.packageAsset?.kind == .dmg)
        #expect(release?.packageAsset?.name == "MenuBarHome-1.3.0.dmg")
        #expect(release?.packageAsset?.sizeBytes == 4096)
        #expect(release?.packageAsset?.downloadURL == UpdateChecker.releaseAssetURL(
            version: "1.3.0",
            fileName: "MenuBarHome-1.3.0.dmg"
        ))
        #expect(UpdateChecker.releaseAssetURL(version: "1.2", fileName: "MenuBarHome-1.2.dmg") == nil)
        #expect(UpdateChecker.releaseAssetURL(version: "v1.2.0", fileName: "MenuBarHome-1.2.0.dmg") == nil)
        #expect(UpdateChecker.releaseAssetURL(version: "1.2.0", fileName: "MenuBarHome-1.2.0.zip") == nil)
    }

    private static func makeFakeAppBundle(
        in directory: URL,
        bundleID: String = AppUpdater.expectedBundleIdentifier,
        shortVersion: String = "1.2.0"
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("MenuBarHome.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": shortVersion,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    @Test("AppUpdater stages verified bundle and rejects checksum, bundle ID, signature, or codesign failures")
    func appUpdaterStageAndRejections() async throws {
        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("updater-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let targetAppURL = try Self.makeFakeAppBundle(in: rootDir, shortVersion: "1.0.0")
        let stagingParent = rootDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true)

        let archiveBytes = Data("verified-dmg-content".utf8)
        let signingKey = Curve25519.Signing.PrivateKey()
        let signingPublicKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let signed = try signedUpdateManifest(version: "1.2.0", package: archiveBytes, signingKey: signingKey)
        let packageURL = try #require(UpdateChecker.releaseAssetURL(version: "1.2.0", fileName: "MenuBarHome-1.2.0.dmg"))
        let release = AppRelease(
            version: "1.2.0",
            pageURL: URL(string: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.2.0")!,
            notes: "Release notes",
            packageAsset: .init(
                name: "MenuBarHome-1.2.0.dmg",
                downloadURL: packageURL,
                sizeBytes: Int64(archiveBytes.count),
                kind: .dmg
            )
        )

        func makeUpdater(driver: UpdateSystemDriver) -> AppUpdater {
            AppUpdater(
                currentVersion: "1.0.0",
                targetBundleURL: targetAppURL,
                stagingBaseDirectory: stagingParent,
                updateSigningPublicKeysBase64: [signingPublicKey],
                driver: driver
            )
        }

        let happyDriver = UpdateSystemDriver(
            downloadFile: { url, destination, onProgress in
                #expect(url == packageURL)
                try archiveBytes.write(to: destination)
                onProgress(DownloadProgress(receivedBytes: Int64(archiveBytes.count), totalBytes: Int64(archiveBytes.count)))
            },
            fetchData: { req in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let path = req.url?.path ?? ""
                if path.hasSuffix(".update.json.ed25519.sig") {
                    #expect(req.url == UpdateChecker.releaseAssetURL(
                        version: "1.2.0",
                        fileName: "MenuBarHome-1.2.0.update.json.ed25519.sig"
                    ))
                    return (Data(signed.signatureText.utf8), resp)
                }
                if path.hasSuffix(".update.json") {
                    return (signed.bytes, resp)
                }
                Issue.record("unexpected update fetch \(req.url?.absoluteString ?? "")")
                return (Data(), resp)
            },
            unpackArchive: { _, _, destinationDir in
                try Self.makeFakeAppBundle(in: destinationDir, shortVersion: "1.2.0")
            },
            verifyCodeSignature: { _, _ in },
            launchDetachedSwapAndRelaunch: { _, _, _ in }
        )

        let staleDir = stagingParent.appendingPathComponent("com.jryang1997.MenuBarMijia.update-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)

        let updater = makeUpdater(driver: happyDriver)
        let staged = try await updater.stageUpdate(for: release) { _ in }
        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
        #expect(FileManager.default.fileExists(atPath: staged.stagedBundleURL.path))
        updater.cleanupStagedApp(staged)
        #expect(!FileManager.default.fileExists(atPath: staged.stagingRootURL.path))

        var symlinkDriver = happyDriver
        symlinkDriver.unpackArchive = { _, _, destinationDir in
            let symlinkURL = destinationDir.appendingPathComponent("MenuBarHome.app")
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetAppURL)
            return symlinkURL
        }
        await #expect(throws: UpdateInstallError.unpackFailed("App bundle cannot be a symbolic link")) {
            _ = try await makeUpdater(driver: symlinkDriver).stageUpdate(for: release) { _ in }
        }

        var corruptedDriver = happyDriver
        corruptedDriver.downloadFile = { _, destination, _ in
            try Data("tampered-dmg-content".utf8).write(to: destination)
        }
        await #expect(throws: UpdateInstallError.self) {
            _ = try await makeUpdater(driver: corruptedDriver).stageUpdate(for: release) { _ in }
        }
        let remainingAfterChecksumFail = try FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
        #expect(remainingAfterChecksumFail.isEmpty)

        var wrongBundleDriver = happyDriver
        wrongBundleDriver.unpackArchive = { _, _, destinationDir in
            try Self.makeFakeAppBundle(in: destinationDir, bundleID: "com.evil.Replacement", shortVersion: "1.2.0")
        }
        await #expect(throws: UpdateInstallError.bundleIdentifierMismatch(found: "com.evil.Replacement")) {
            _ = try await makeUpdater(driver: wrongBundleDriver).stageUpdate(for: release) { _ in }
        }

        var invalidSigDriver = happyDriver
        invalidSigDriver.verifyCodeSignature = { _, _ in
            throw UpdateInstallError.codeSignatureInvalid("a sealed resource is missing or invalid")
        }
        await #expect(throws: UpdateInstallError.codeSignatureInvalid("a sealed resource is missing or invalid")) {
            _ = try await makeUpdater(driver: invalidSigDriver).stageUpdate(for: release) { _ in }
        }

        let tamperedBytes = Data("tampered-dmg-content".utf8)
        var tamperedDriver = happyDriver
        tamperedDriver.downloadFile = { _, destination, _ in
            try tamperedBytes.write(to: destination)
        }
        await #expect(throws: UpdateInstallError.checksumMismatch(
            expected: SHA256Digest.hash(archiveBytes).hex,
            actual: SHA256Digest.hash(tamperedBytes).hex
        )) {
            _ = try await makeUpdater(driver: tamperedDriver).stageUpdate(for: release) { _ in }
        }

        var missingSignatureDriver = happyDriver
        missingSignatureDriver.fetchData = { req in
            if req.url?.path.hasSuffix(".update.json.ed25519.sig") == true {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (signed.bytes, resp)
        }
        await #expect(throws: UpdateInstallError.updateSignatureMissing) {
            _ = try await makeUpdater(driver: missingSignatureDriver).stageUpdate(for: release) { _ in }
        }

        var malformedSignatureDriver = happyDriver
        malformedSignatureDriver.fetchData = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if req.url?.path.hasSuffix(".update.json.ed25519.sig") == true {
                return (Data("not-base64".utf8), resp)
            }
            return (signed.bytes, resp)
        }
        await #expect(throws: UpdateInstallError.updateSignatureInvalid("signature does not match the manifest")) {
            _ = try await makeUpdater(driver: malformedSignatureDriver).stageUpdate(for: release) { _ in }
        }
    }

    @Test("stageUpdate rejects an older signed manifest before unpacking")
    func stageUpdateRejectsReplayBeforeUnpack() async throws {
        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("replay-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }
        let targetAppURL = try Self.makeFakeAppBundle(in: rootDir, shortVersion: "1.1.5")
        let signed = try signedUpdateManifest(version: "1.1.6", package: Data("old-dmg".utf8))
        let release = AppRelease(
            version: "1.1.8",
            pageURL: URL(string: "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.1.8")!,
            notes: "replay",
            packageAsset: .init(
                name: "MenuBarHome-1.1.8.dmg",
                downloadURL: try #require(UpdateChecker.releaseAssetURL(version: "1.1.8", fileName: "MenuBarHome-1.1.8.dmg")),
                sizeBytes: 7,
                kind: .dmg
            )
        )
        final class UnpackProbe: @unchecked Sendable {
            var didRun = false
        }
        let unpacked = UnpackProbe()
        let driver = UpdateSystemDriver(
            downloadFile: { _, destination, _ in
                try Data("old-dmg".utf8).write(to: destination)
            },
            fetchData: { req in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if req.url?.path.hasSuffix(".update.json.ed25519.sig") == true {
                    return (Data(signed.signatureText.utf8), resp)
                }
                return (signed.bytes, resp)
            },
            unpackArchive: { _, _, destinationDir in
                unpacked.didRun = true
                return try Self.makeFakeAppBundle(in: destinationDir, shortVersion: "1.1.8")
            },
            verifyCodeSignature: { _, _ in },
            launchDetachedSwapAndRelaunch: { _, _, _ in }
        )
        let updater = AppUpdater(
            currentVersion: "1.1.5",
            targetBundleURL: targetAppURL,
            stagingBaseDirectory: rootDir,
            updateSigningPublicKeysBase64: [signed.publicKey],
            driver: driver
        )
        await #expect(throws: UpdateInstallError.updateSignatureInvalid("update manifest is signed for a different version")) {
            _ = try await updater.stageUpdate(for: release) { _ in }
        }
        #expect(unpacked.didRun == false)
    }

    @Test("Ed25519 update signatures round-trip and reject tampered data, keys, or signatures")
    func ed25519SignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("update-package-bytes".utf8)
        let signature = try key.signature(for: data).base64EncodedString()
        #expect(UpdateSignature.verify(signatureBase64: signature, publicKeyBase64: publicKey, data: data))
        #expect(!UpdateSignature.verify(signatureBase64: signature, publicKeyBase64: publicKey, data: Data("tampered".utf8)))

        let otherKey = Curve25519.Signing.PrivateKey()
        #expect(!UpdateSignature.verify(
            signatureBase64: signature,
            publicKeyBase64: otherKey.publicKey.rawRepresentation.base64EncodedString(),
            data: data
        ))
        let otherSignature = try otherKey.signature(for: data).base64EncodedString()
        #expect(!UpdateSignature.verify(signatureBase64: otherSignature, publicKeyBase64: publicKey, data: data))
        #expect(!UpdateSignature.verify(signatureBase64: "not-base64", publicKeyBase64: publicKey, data: data))
        #expect(!UpdateSignature.verify(signatureBase64: signature, publicKeyBase64: "AAAA", data: data))
        #expect(Data(base64Encoded: UpdateChecker.updateSigningPublicKeyBase64)?.count == 32)
        #expect(UpdateChecker.updateSigningPublicKeysBase64.first == UpdateChecker.updateSigningPublicKeyBase64)
        if !UpdateChecker.updateSigningOverlapPublicKeyBase64.isEmpty {
            #expect(Data(base64Encoded: UpdateChecker.updateSigningOverlapPublicKeyBase64)?.count == 32)
            #expect(UpdateChecker.updateSigningPublicKeysBase64.count == 2)
        } else {
            #expect(UpdateChecker.updateSigningPublicKeysBase64.count == 1)
        }
    }


    @MainActor
    @Test("HomeStore orchestrates throttling, staging, cancellation, retry, and relaunch")
    func homeStoreUpdateStateMachine() async throws {
        let suite = "com.jryang1997.MenuBarMijia.update-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("store-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let targetAppURL = try Self.makeFakeAppBundle(in: rootDir, shortVersion: "1.0.0")
        let archiveBytes = Data("release-binary".utf8)
        let signingKey = Curve25519.Signing.PrivateKey()
        let signingPublicKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let signed = try signedUpdateManifest(version: "1.4.0", package: archiveBytes, signingKey: signingKey)
        let releaseJSON = """
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.4.0",
          "body": "支持状态栏气泡提醒",
          "assets": [
            {
              "name": "MenuBarHome-1.4.0.dmg",
              "size": \(archiveBytes.count)
            },
            {
              "name": "MenuBarHome-1.4.0.update.json",
              "size": \(signed.bytes.count)
            }
          ]
        }
        """

        final class Probe: @unchecked Sendable {
            var checkCallCount = 0
            var shouldFailUnpack = false
            var shouldBlockDownloadForCancel = false
            var swappedTargetURL: URL?
        }
        let probe = Probe()

        let makeUpdater = { () -> AppUpdater in
            let driver = UpdateSystemDriver(
                downloadFile: { _, destination, onProgress in
                    if probe.shouldBlockDownloadForCancel {
                        try await Task.sleep(for: .seconds(10))
                    }
                    try archiveBytes.write(to: destination)
                    onProgress(DownloadProgress(receivedBytes: Int64(archiveBytes.count), totalBytes: Int64(archiveBytes.count)))
                },
                fetchData: { req in
                    probe.checkCallCount += 1
                    let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    let path = req.url?.path ?? ""
                    if path.hasSuffix(".update.json.ed25519.sig") {
                        return (Data(signed.signatureText.utf8), resp)
                    }
                    if path.hasSuffix(".update.json") {
                        return (signed.bytes, resp)
                    }
                    return (Data(releaseJSON.utf8), resp)
                },
                unpackArchive: { _, _, destinationDir in
                    if probe.shouldFailUnpack {
                        throw UpdateInstallError.unpackFailed("Simulated mount error")
                    }
                    return try Self.makeFakeAppBundle(in: destinationDir, shortVersion: "1.4.0")
                },
                verifyCodeSignature: { _, _ in },
                launchDetachedSwapAndRelaunch: { _, targetURL, _ in
                    probe.swappedTargetURL = targetURL
                }
            )
            return AppUpdater(
                currentVersion: "1.0.0",
                targetBundleURL: targetAppURL,
                stagingBaseDirectory: rootDir,
                updateSigningPublicKeysBase64: [signingPublicKey],
                driver: driver
            )
        }

        let store = HomeStore(
            provider: MockHomeProvider(),
            defaultsSuiteName: suite,
            updater: makeUpdater()
        )
        var didTerminate = false
        store.onTerminateForUpdate = { didTerminate = true }

        store.automaticallyChecksForUpdates = false
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await store.checkForUpdatesIfNeeded(now: t0)
        #expect(probe.checkCallCount == 0)
        #expect(store.updateState == .idle)

        store.automaticallyChecksForUpdates = true
        await store.checkForUpdatesIfNeeded(now: t0)
        #expect(probe.checkCallCount == 1)
        #expect(store.updateState.badgeRelease?.version == "1.4.0")

        store.updater = AppUpdater(
            currentVersion: "1.4.0",
            targetBundleURL: targetAppURL,
            stagingBaseDirectory: rootDir,
            updateSigningPublicKeysBase64: [signingPublicKey],
            driver: UpdateSystemDriver(
                downloadFile: { _, _, _ in },
                fetchData: { req in
                    probe.checkCallCount += 1
                    let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(releaseJSON.utf8), resp)
                },
                unpackArchive: { _, _, dir in dir },
                verifyCodeSignature: { _, _ in },
                launchDetachedSwapAndRelaunch: { _, _, _ in }
            )
        )
        await store.checkForUpdates(now: t0)
        #expect(store.updateState == .upToDate(checkedAt: t0))
        let countAfterManual = probe.checkCallCount

        await store.checkForUpdatesIfNeeded(now: t0.addingTimeInterval(3600))
        #expect(probe.checkCallCount == countAfterManual)

        store.updater = makeUpdater()
        await store.checkForUpdatesIfNeeded(now: t0.addingTimeInterval(6 * 3600 + 1))
        #expect(probe.checkCallCount == countAfterManual + 1)
        #expect(store.updateState.associatedRelease?.version == "1.4.0")

        probe.shouldBlockDownloadForCancel = true
        let installTask = Task { await store.startUpdateInstallation() }
        try await Task.sleep(for: .milliseconds(40))
        store.cancelUpdateInstallation()
        await installTask.value
        #expect(store.updateState.associatedRelease?.version == "1.4.0")
        if case .available(let release) = store.updateState {
            #expect(release.version == "1.4.0")
        } else {
            Issue.record("Expected .available after cancelling installation, got \(store.updateState)")
        }
        probe.shouldBlockDownloadForCancel = false

        probe.shouldFailUnpack = true
        await store.startUpdateInstallation()
        if case .failed(let failure) = store.updateState {
            #expect(failure.canRetryInstall)
            #expect(failure.fallbackURL.absoluteString == "https://github.com/jryang2026-code/MenuBarHome/releases/tag/v1.4.0")
        } else {
            Issue.record("Expected .failed state on unpack error, got \(store.updateState)")
        }

        probe.shouldFailUnpack = false
        await store.startUpdateInstallation()
        #expect(store.updateState.isReadyToRelaunch)

        store.confirmRelaunchForUpdate()
        #expect(probe.swappedTargetURL == targetAppURL)
        #expect(didTerminate)
    }

    #if os(macOS)
    @Test("A DMG attach busy for longer than a couple of seconds still succeeds, and a real failure surfaces")
    func dmgAttachRidesOutBusyBursts() async throws {
        var attempts = 0
        var waited: Duration = .zero
        let recovered = try await UpdateSystemDriver.retryingAttach(
            { attempts += 1; return attempts > 6 },
            succeeded: { $0 },
            sleep: { waited += $0 }
        )
        #expect(recovered)
        #expect(waited > .seconds(5), "the old five tries gave up after 2.5 s of busy attaches")

        attempts = 0
        waited = .zero
        let failed = try await UpdateSystemDriver.retryingAttach({ attempts += 1; return false }, succeeded: { $0 }, sleep: { waited += $0 })
        #expect(!failed)
        #expect(attempts == UpdateSystemDriver.dmgAttachBackoff.count + 1)
        #expect(waited < .seconds(20), "an update install never stalls long on a broken image")
    }

    private static func runTool(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw UpdateInstallError.unpackFailed("\(executable) exited \(process.terminationStatus): \(errText)")
        }
    }

    private static func runToolOutput(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return process.terminationStatus == 0 ? data : nil
    }

    /// Serializes the attach work inside this process: Swift Testing runs test cases and their
    /// repetitions in parallel, and two attaches at once are what `hdiutil` answers with
    /// "Resource temporarily unavailable".
    private final class HdiutilGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isBusy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !isBusy {
                    isBusy = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            if waiters.isEmpty {
                isBusy = false
                lock.unlock()
            } else {
                let next = waiters.removeFirst()
                lock.unlock()
                next.resume()
            }
        }
    }

    private static let hdiutilGate = HdiutilGate()

    /// A machine-wide lock around the attach work. Two checkouts on this Mac share one mount
    /// table, and attaches at the same time are what it answers with "Resource temporarily
    /// unavailable". `flock` releases on process death, so an interrupted run cannot leave it
    /// held.
    private final class CrossProcessLock: @unchecked Sendable {
        private let path: String
        private var descriptor: Int32?

        init(name: String) {
            path = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        }

        /// False when another process held the lock for the whole wait; the caller runs anyway and
        /// lets the attach retries decide.
        func acquire(timeout: Duration = .seconds(120)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while true {
                let fd = open(path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else { return false }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    descriptor = fd
                    return true
                }
                close(fd)
                guard ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        func release() {
            guard let descriptor else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            self.descriptor = nil
        }
    }

    private static let hdiutilLock = CrossProcessLock(name: "MenuBarHome-live-driver.lock")

    /// Whole-image device entries (`/dev/diskN`) of attached images whose `image-path` satisfies
    /// `matches`. Reading `hdiutil info` keeps this test from detaching a volume another checkout
    /// is still using.
    private static func imageDevices(where matches: (String) -> Bool) -> [String] {
        guard let data = runToolOutput("/usr/bin/hdiutil", ["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        var devices: [String] = []
        for image in images {
            guard let path = image["image-path"] as? String, matches(path),
                  let entities = image["system-entities"] as? [[String: Any]],
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).first else { continue }
            devices.append(device)
        }
        return devices
    }

    private static func detach(_ devices: [String]) {
        for device in devices {
            try? runTool("/usr/bin/hdiutil", ["detach", device, "-force"])
        }
    }

    /// Detaches only the images this run created: their `image-path` is inside `rootDir`.
    private static func detachImages(beneath rootDir: URL) {
        let root = rootDir.resolvingSymlinksInPath().path
        detach(imageDevices { path in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root)
        })
    }

    /// An interrupted earlier run leaves its image attached and counts against the system mount
    /// limit. A live checkout still holds a DMG created seconds ago, so only images this test's
    /// own `live-driver-*` naming owns that are old — or whose file is already gone — are
    /// detached. A concurrent run is never touched.
    private static func detachStaleLiveDriverImages() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-10 * 60)
        let stale = imageDevices { path in
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().lastPathComponent.hasPrefix("live-driver-"),
                  url.lastPathComponent.hasPrefix("MenuBarHome-") else { return false }
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { return true }
            return modified < cutoff
        }
        detach(stale)
    }

    private static func makeSignedMachOAppBundle(
        in directory: URL,
        bundleID: String = AppUpdater.expectedBundleIdentifier,
        shortVersion: String = "1.5.0"
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("MenuBarHome.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let executableURL = macOSURL.appendingPathComponent("MenuBarMijiaApp")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableURL)
        let plist: [String: Any] = [
            "CFBundleExecutable": "MenuBarMijiaApp",
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": shortVersion,
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID, appURL.path])
        return appURL
    }

    @Test("UpdateSystemDriver.live unpacks ZIP and DMG, enforces the codesign requirement, and swaps bundle")
    func liveDriverUnpacksAndVerifiesSignedBundles() async throws {
        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("live-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        // One attach at a time in this process and on this Mac, and detach this run's image
        // whatever happens: a leaked image counts against the system mount limit and makes the
        // next attach fail.
        await Self.hdiutilGate.acquire()
        let locked = await Self.hdiutilLock.acquire()
        defer {
            Self.detachImages(beneath: rootDir)
            Self.hdiutilLock.release()
            Self.hdiutilGate.release()
            try? FileManager.default.removeItem(at: rootDir)
        }
        #expect(locked, "another checkout held the hdiutil lock for two minutes")
        Self.detachStaleLiveDriverImages()

        let missingPinRequirement = AppUpdater.codeSigningRequirement(
            bundleIdentifier: AppUpdater.expectedBundleIdentifier,
            certificateSHA1: nil
        )
        let pinnedRequirement = AppUpdater.codeSigningRequirement(
            bundleIdentifier: AppUpdater.expectedBundleIdentifier,
            certificateSHA1: String(repeating: "a", count: 40)
        )
        let buildDir = rootDir.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let signedAppURL = try Self.makeSignedMachOAppBundle(in: buildDir, shortVersion: "1.5.0")

        let zipURL = rootDir.appendingPathComponent("MenuBarHome-1.5.0.zip")
        try Self.runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", signedAppURL.path, zipURL.path])

        let zipDest = rootDir.appendingPathComponent("zip-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: zipDest, withIntermediateDirectories: true)
        let unpackedFromZip = try await UpdateSystemDriver.live.unpackArchive(zipURL, .zip, zipDest)
        #expect(unpackedFromZip.lastPathComponent == "MenuBarHome.app")
        try await UpdateSystemDriver.live.stripQuarantine(unpackedFromZip)
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(unpackedFromZip, missingPinRequirement)
        }
        // 同 Bundle ID 的 ad-hoc 包必须被钉住证书的 requirement 拒绝。
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(unpackedFromZip, pinnedRequirement)
        }

        let dmgSrcDir = rootDir.appendingPathComponent("dmg-src", isDirectory: true)
        try FileManager.default.createDirectory(at: dmgSrcDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: signedAppURL,
            to: dmgSrcDir.appendingPathComponent("MenuBarHome.app", isDirectory: true)
        )
        let dmgURL = rootDir.appendingPathComponent("MenuBarHome-1.5.0.dmg")
        // A volume name another checkout still has mounted makes `hdiutil create` answer
        // "Resource busy"; the suffix keeps two checkouts out of each other's way.
        let volumeName = "MenuBarHome 1.5.0 \(UUID().uuidString.prefix(8))"
        try Self.runTool(
            "/usr/bin/hdiutil",
            ["create", "-volname", volumeName, "-srcfolder", dmgSrcDir.path, "-ov", "-format", "UDZO", dmgURL.path]
        )

        let dmgDest = rootDir.appendingPathComponent("dmg-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dmgDest, withIntermediateDirectories: true)
        let unpackedFromDmg = try await UpdateSystemDriver.live.unpackArchive(dmgURL, .dmg, dmgDest)
        #expect(unpackedFromDmg.lastPathComponent == "MenuBarHome.app")
        #expect(!FileManager.default.fileExists(atPath: dmgDest.appendingPathComponent("mnt").path))
        try await UpdateSystemDriver.live.stripQuarantine(unpackedFromDmg)
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(unpackedFromDmg, missingPinRequirement)
        }

        let evilDir = rootDir.appendingPathComponent("evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evilDir, withIntermediateDirectories: true)
        let evilAppURL = try Self.makeSignedMachOAppBundle(in: evilDir, bundleID: "com.evil.Other", shortVersion: "1.5.0")
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateSystemDriver.live.verifyCodeSignature(evilAppURL, pinnedRequirement)
        }
    }
    #endif
}
