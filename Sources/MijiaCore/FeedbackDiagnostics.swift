import Foundation

/// One data source as the feedback block may describe it: a label from a closed set and two counts.
///
/// The label is a `HomeBackend.title` string, never a host, a home name or a device name. The counts
/// are numbers this app produced.
public struct FeedbackBackendCount: Equatable, Sendable {
    public var label: String
    public var deviceCount: Int
    public var onlineDeviceCount: Int

    public init(label: String, deviceCount: Int, onlineDeviceCount: Int) {
        self.label = label
        self.deviceCount = deviceCount
        self.onlineDeviceCount = onlineDeviceCount
    }
}

/// A failure marker the feedback block may carry, with how many of them the app saw.
///
/// Codes are ASCII so a maintainer can grep an issue, and each one names a condition the app tracks
/// as a typed value, not text a person typed: no error message ever reaches the URL.
public struct FeedbackSignal: Equatable, Sendable {
    public enum Code: String, CaseIterable, Sendable {
        /// Errors the app counted in its local ring buffer. The buffer stores no message (#17).
        case errors = "ERRORS"
        /// Local crash reports the app counted inside the reporting window.
        case crashes = "CRASHES"
        /// macOS denied Local Network access, which hides every LAN-only device.
        case localNetworkBlocked = "TCC_LOCAL_NETWORK"
        /// Devices that answered over the cloud because the LAN route cooled down.
        case lanCooldown = "LAN_COOLDOWN"
        /// Devices that fell back to the cloud route.
        case cloudFallback = "CLOUD_FALLBACK"
        /// Devices whose LAN route was refused by a local-network block.
        case permissionBlocked = "DEVICE_PERMISSION"
    }

    public var code: Code
    public var count: Int

    public init(code: Code, count: Int) {
        self.code = code
        self.count = count
    }
}

/// The option texts `bug_report.yml` offers for its backend dropdown.
///
/// GitHub selects a form option by its text alone, so these strings must stay identical to the
/// template, which is Chinese. They do not follow the interface language for that reason — an
/// English option would match nothing and leave the required field empty.
public enum FeedbackBackendOption {
    public static let mi = "小米云（扫码登录）"
    public static let homeAssistant = "Home Assistant"
    public static let dual = "小米云 + Home Assistant（双源）"
    public static let demo = "演示模式"
    public static let none = "不适用"

    /// The one option the current sources satisfy, or `nil` when the account state names no source.
    public static func resolve(hasMiSource: Bool, hasHomeAssistantSource: Bool, isDemo: Bool) -> String? {
        if isDemo { return demo }
        switch (hasMiSource, hasHomeAssistantSource) {
        case (true, true): return dual
        case (true, false): return mi
        case (false, true): return homeAssistant
        case (false, false): return nil
        }
    }
}

/// The redacted block that a one-click feedback link carries into a GitHub issue (#29).
///
/// Privacy contract, deliberately narrower than `DiagnosticsReportBuilder`: every value here is a
/// count this app made or a label from a closed set, so no did, token, host, device name, home name,
/// account id, IP, MAC or email can reach the URL. `sanitized(_:)` still runs over the few string
/// fields on the way out, so a future caller that widens one of them cannot leak a secret either.
public struct FeedbackDiagnostics: Equatable, Sendable {
    /// The ceiling GitHub's issue URL survives in every browser the app can open.
    public static let maxURLLength = 6000
    /// The issue form the link prefills. Its field ids are the only place this value appears.
    public static let template = "bug_report.yml"

    public var appVersion: String
    public var osVersion: String
    public var platform: String
    public var backends: [FeedbackBackendCount]
    public var signals: [FeedbackSignal]
    /// The `backend` dropdown value, when the sources make one answer exact.
    public var backendOption: String?

    public init(
        appVersion: String,
        osVersion: String,
        platform: String,
        backends: [FeedbackBackendCount] = [],
        signals: [FeedbackSignal] = [],
        backendOption: String? = nil
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.platform = platform
        self.backends = backends
        self.signals = signals
        self.backendOption = backendOption
    }

    /// The block the issue shows under "诊断信息", one fact per line, most useful first.
    public var text: String {
        var lines: [String] = []
        lines.append("- \(L10n.tr("版本", "Version")): \(Self.sanitized(appVersion))")
        lines.append("- \(L10n.tr("系统", "OS")): \(Self.sanitized(osVersion))")

        let labels = backends.map { Self.sanitized($0.label) }.filter { !$0.isEmpty }
        if !labels.isEmpty {
            lines.append("- \(L10n.tr("数据源", "Backends")): \(labels.joined(separator: " + "))")
        }
        for backend in backends {
            let label = Self.sanitized(backend.label)
            guard !label.isEmpty else { continue }
            lines.append(
                "  - \(label): \(backend.deviceCount) \(L10n.tr("台设备", "devices"))"
                    + " (\(L10n.tr("在线", "online")) \(backend.onlineDeviceCount))"
            )
        }

        let codes = signals
            .filter { $0.count > 0 }
            .map { "\($0.code.rawValue)x\($0.count)" }
        lines.append(
            "- \(L10n.tr("错误码", "Error codes")): "
                + (codes.isEmpty ? L10n.tr("无", "none") : codes.joined(separator: " · "))
        )
        return lines.joined(separator: "\n")
    }

    /// A GitHub "new issue" URL that prefills `bug_report.yml` with this block.
    ///
    /// The user still presses "Submit" in the browser; nothing is sent from here. A block that would
    /// push the URL past `maxLength` loses its least useful trailing lines, because a browser or a
    /// proxy quietly cutting an 8 KB URL is worse than a short one that arrives whole.
    public func issueURL(
        repository: String = "jryang2026-code/MenuBarHome",
        maxLength: Int = FeedbackDiagnostics.maxURLLength
    ) -> URL? {
        let allLines = text.components(separatedBy: "\n")
        for kept in stride(from: allLines.count, through: 1, by: -1) {
            let truncated = kept < allLines.count
            guard let url = Self.compose(
                diagnostics: allLines.prefix(kept).joined(separator: "\n"),
                truncated: truncated,
                platform: platform,
                version: appVersion,
                os: osVersion,
                backendOption: backendOption,
                repository: repository
            ) else { continue }
            if url.absoluteString.count <= maxLength { return url }
        }
        return nil
    }

    // MARK: - URL

    private static func compose(
        diagnostics: String,
        truncated: Bool,
        platform: String,
        version: String,
        os: String,
        backendOption: String?,
        repository: String
    ) -> URL? {
        var block = diagnostics
        if truncated {
            block += "\n" + L10n.tr(
                "…（诊断已按链接长度截断，完整内容请用「复制排障信息」）",
                "… (diagnostics truncated to fit the link; use Copy Diagnostics for the full block)"
            )
        }
        let cleanPlatform = sanitized(platform)
        let cleanVersion = sanitized(version)
        let cleanOS = sanitized(os)

        var items: [URLQueryItem] = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(
                name: "title",
                value: L10n.tr(
                    "[问题] MenuBarHome \(cleanVersion) (\(cleanPlatform))",
                    "[Bug] MenuBarHome \(cleanVersion) (\(cleanPlatform))"
                )
            ),
            URLQueryItem(name: "platform", value: cleanPlatform),
            URLQueryItem(name: "os-version", value: cleanOS),
            URLQueryItem(name: "app-version", value: cleanVersion),
        ]
        if let backendOption, !backendOption.isEmpty {
            items.append(URLQueryItem(name: "backend", value: sanitized(backendOption)))
        }
        items.append(URLQueryItem(name: "diagnostics", value: block))

        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = items
        // URLComponents keeps a literal "+" in a value, but form-urlencoded decoders (GitHub's
        // included) read it as a space, so escape it explicitly.
        if let encodedQuery = components?.percentEncodedQuery {
            components?.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%2B")
        }
        return components?.url
    }

    // MARK: - Redaction

    /// Replace anything that could identify a person, a device or a secret with a marker.
    ///
    /// The block is built from counts alone, so this is a backstop for a caller that widens a field,
    /// not the mechanism that makes the block safe. Patterns mirror the Windows implementation
    /// (`redactSensitiveText` in `diagnosticsAndScanner.ts`) so both platforms leak the same nothing.
    static func sanitized(_ raw: String) -> String {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (pattern, replacement) in redactionPatterns {
            out = out.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    private static let redactionPatterns: [(String, String)] = [
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*)?"#, "[redacted-jwt]"),
        (#"\b(?:Bearer\s+[A-Za-z0-9._~+/=-]{8,}|sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,})\b"#, "[redacted-token]"),
        (#"\b(?:https?|wss?|rtsp|rtsps)://[^\s)`"'>]+"#, "[redacted-url]"),
        (#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, "[redacted-mac]"),
        (#"\b(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}\b"#, "[redacted-ip]"),
        (#"\b(?:fe80|fc[0-9a-f]{2}|fd[0-9a-f]{2}):[0-9a-f:]+"#, "[redacted-ip]"),
        (#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "[redacted-email]"),
        (#"\b(?:miot(?:-action)?:|blt\.|group\.\d{4,})[^\s)`"'>]*"#, "[redacted-did]"),
        (#"\b\d{6,}(?:\.s\d+)?\b"#, "[redacted-id]"),
        (#"\b[A-Za-z0-9+/=_-]{32,}\b"#, "[redacted-token]"),
    ]
}
