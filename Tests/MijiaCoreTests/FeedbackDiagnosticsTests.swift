import Foundation
import Testing
@testable import MijiaCore

/// #29: the one-click feedback link prefills a GitHub issue with a block that cannot name a person,
/// a device or a secret, and it stays short enough for a browser to carry whole.
struct FeedbackDiagnosticsTests {
    /// Everything a diagnostics report must never carry, in the shape each value really takes.
    ///
    /// The JWT is assembled from its parts so the repository's secret scan does not read a fixture
    /// as a leaked credential.
    private static let poison = [
        ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiI3MDAxMjM0NTYifQ", "c2lnbmF0dXJl"].joined(separator: "."),
        "Bearer abcdefghijklmnop",
        "sk-abcdefghijklmnop",
        "ghp_abcdefghijklmnopqrst",
        "http://192.168.1.60:8123",
        "192.168.1.60",
        "AA:BB:CC:DD:EE:FF",
        "zhangsan@example.com",
        "miot:123456789:2",
        "700123456",
    ]

    private static func poisonedDiagnostics() -> FeedbackDiagnostics {
        FeedbackDiagnostics(
            appVersion: "1.5.0 " + poison.joined(separator: " "),
            osVersion: "Version 27.2.1 " + poison.joined(separator: " "),
            platform: "macOS",
            backends: [
                FeedbackBackendCount(label: "米家云端直连 " + poison.joined(separator: " "), deviceCount: 12, onlineDeviceCount: 9),
                FeedbackBackendCount(label: "Home Assistant", deviceCount: 4, onlineDeviceCount: 4),
            ],
            signals: [
                FeedbackSignal(code: .errors, count: 3),
                FeedbackSignal(code: .lanCooldown, count: 2),
            ],
            backendOption: FeedbackBackendOption.dual
        )
    }

    @Test("A diagnostics source full of secrets, identifiers and contacts leaks none of them")
    func diagnosticSourceLeaksNothing() throws {
        let diagnostics = Self.poisonedDiagnostics()
        let block = diagnostics.text
        let url = try #require(diagnostics.issueURL())
        let decodedQuery = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        ).removingPercentEncoding ?? ""

        for secret in Self.poison {
            #expect(!block.contains(secret), "block leaked \(secret)")
            #expect(!url.absoluteString.contains(secret), "URL leaked \(secret)")
            #expect(!decodedQuery.contains(secret), "prefilled query leaked \(secret)")
        }
        #expect(block.contains("1.5.0"))
        #expect(block.contains("12"))
        #expect(block.contains("ERRORSx3"))
    }

    @Test("The link targets the bug form and prefills every field it can answer")
    func linkPrefillsTheBugForm() throws {
        let diagnostics = FeedbackDiagnostics(
            appVersion: "1.5.0",
            osVersion: "Version 27.2.1 (Build 26B131)",
            platform: "macOS",
            backends: [FeedbackBackendCount(label: HomeBackend.xiaomiCloud.title, deviceCount: 7, onlineDeviceCount: 6)],
            signals: [FeedbackSignal(code: .errors, count: 2)],
            backendOption: FeedbackBackendOption.mi
        )
        let url = try #require(diagnostics.issueURL())
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(url.absoluteString.hasPrefix("https://github.com/jryang2026-code/MenuBarHome/issues/new?"))
        #expect(fields["template"] == "bug_report.yml")
        #expect(fields["platform"] == "macOS")
        #expect(fields["app-version"] == "1.5.0")
        #expect(fields["os-version"] == "Version 27.2.1 (Build 26B131)")
        #expect(fields["backend"] == FeedbackBackendOption.mi)
        #expect(fields["title"]?.contains("1.5.0") == true)
        let block = try #require(fields["diagnostics"])
        #expect(block.contains("1.5.0"))
        #expect(block.contains("26B131"))
        #expect(block.contains(HomeBackend.xiaomiCloud.title))
        #expect(block.contains("7"))
        #expect(block.contains("ERRORSx2"))
    }

    @Test("A plus sign survives the form decode as a plus")
    func plusSignIsEscaped() throws {
        let diagnostics = FeedbackDiagnostics(
            appVersion: "1.5.0+build",
            osVersion: "Version 27.2.1",
            platform: "macOS"
        )
        let url = try #require(diagnostics.issueURL())
        #expect(url.absoluteString.contains("%2B"))
        let version = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "app-version" }?.value
        #expect(version == "1.5.0+build")
    }

    @Test("An oversized block is truncated to keep the link under the ceiling")
    func oversizedBlockIsTruncated() throws {
        let backends = (0..<400).map { index in
            FeedbackBackendCount(
                label: "数据源\(index)名称用于撑爆链接长度上限",
                deviceCount: index,
                onlineDeviceCount: index
            )
        }
        let diagnostics = FeedbackDiagnostics(
            appVersion: "1.5.0",
            osVersion: "Version 27.2.1 (Build 26B131)",
            platform: "macOS",
            backends: backends,
            signals: [FeedbackSignal(code: .errors, count: 3)]
        )
        let url = try #require(diagnostics.issueURL())
        #expect(url.absoluteString.count <= FeedbackDiagnostics.maxURLLength)

        let block = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "diagnostics" }?.value
        )
        #expect(block.contains("1.5.0"), "the first line is the last thing to go")
        #expect(block.contains("…"), "a truncated block says so")
    }

    @Test("The backend dropdown matches a template option only when the sources name one")
    func backendOptionResolution() {
        #expect(FeedbackBackendOption.resolve(hasMiSource: true, hasHomeAssistantSource: false, isDemo: false)
            == FeedbackBackendOption.mi)
        #expect(FeedbackBackendOption.resolve(hasMiSource: false, hasHomeAssistantSource: true, isDemo: false)
            == FeedbackBackendOption.homeAssistant)
        #expect(FeedbackBackendOption.resolve(hasMiSource: true, hasHomeAssistantSource: true, isDemo: false)
            == FeedbackBackendOption.dual)
        #expect(FeedbackBackendOption.resolve(hasMiSource: false, hasHomeAssistantSource: false, isDemo: true)
            == FeedbackBackendOption.demo)
        #expect(FeedbackBackendOption.resolve(hasMiSource: false, hasHomeAssistantSource: false, isDemo: false)
            == nil)
    }

    @Test("Signals with a zero count stay out of the block")
    func zeroCountSignalsAreDropped() {
        let diagnostics = FeedbackDiagnostics(
            appVersion: "1.5.0",
            osVersion: "Version 27.2.1",
            platform: "macOS",
            signals: [FeedbackSignal(code: .cloudFallback, count: 0)]
        )
        #expect(!diagnostics.text.contains("CLOUD_FALLBACK"))
        #expect(diagnostics.text.contains("- "))
    }
}
