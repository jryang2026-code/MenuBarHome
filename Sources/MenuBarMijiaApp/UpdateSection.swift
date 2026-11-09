import AppKit
import MijiaCore
import SwiftUI

struct UpdateSection: View {
    let store: HomeStore
    @State private var isVisible = false

    var body: some View {
        let _ = store.effectiveLanguage
        let badgeRelease = store.updateState.badgeRelease
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let release = badgeRelease {
                        HStack(spacing: 6) {
                            Text(L10n.tr("发现新版本 v\(release.version)", "New Version v\(release.version)"))
                                .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                            Text(L10n.tr("当前 v\(UpdateChecker.bundleVersion)", "Current v\(UpdateChecker.bundleVersion)"))
                                .font(.system(size: DesignTokens.TypeSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L10n.tr("版本 \(UpdateChecker.bundleVersion)", "Version \(UpdateChecker.bundleVersion)"))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    }
                    Text(statusSubtitle)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(store.updateState.isFailure ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                actionButtons
            }

            if case .downloading(_, let progress) = store.updateState {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .controlSize(.regular)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                }
            }

            if let release = store.updateState.associatedRelease {
                let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notes.isEmpty {
                    releaseNotes(notes, pageURL: release.pageURL)
                }
            }

            Divider().overlay(Color.primary.opacity(0.06))

            HStack {
                Text(L10n.tr("自动检查更新", "Check for Updates Automatically"))
                    .font(.system(size: DesignTokens.TypeSize.body))
                Spacer()
                Toggle(
                    L10n.tr("自动检查更新", "Check for Updates Automatically"),
                    isOn: Binding(
                        get: { store.automaticallyChecksForUpdates },
                        set: { store.automaticallyChecksForUpdates = $0 }
                    )
                )
                .labelsHidden()
                .glassLabelHidden()
                .toggleStyle(.glass)
                .controlSize(.regular)
            }
        }
        .padding(12)
        .glassTile(isActive: badgeRelease != nil, cornerRadius: DesignTokens.Radius.card)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private var statusSubtitle: String {
        switch store.updateState {
        case .idle:
            return L10n.tr("MenuBarHome 更新发布在 GitHub Releases", "MenuBarHome updates are published on GitHub Releases")
        case .checking:
            return L10n.tr("正在查看 GitHub 上的最新版本…", "Checking GitHub for the latest release…")
        case .upToDate:
            return L10n.tr("已是最新版本", "You're up to date")
        case .available(let release):
            if release.packageAsset != nil {
                return L10n.tr(
                    "发现新版本 v\(release.version)，可直接下载并安装",
                    "Version v\(release.version) is available to download and install"
                )
            }
            return L10n.tr(
                "有新版本 v\(release.version)，请前往发布页下载",
                "New version v\(release.version) available on GitHub Releases"
            )
        case .downloading(let release, let progress):
            return L10n.tr(
                "正在下载 v\(release.version)… \(progress.formattedSummary)",
                "Downloading v\(release.version)… \(progress.formattedSummary)"
            )
        case .verifying(let release):
            return L10n.tr(
                "正在校验 v\(release.version) 签名与完整性…",
                "Verifying v\(release.version) signature and integrity…"
            )
        case .readyToRelaunch(let staged):
            return L10n.tr(
                "v\(staged.release.version) 已就绪，重启应用即可完成更新",
                "v\(staged.release.version) is ready; relaunch to complete update"
            )
        case .installing(let release):
            return L10n.tr(
                "正在替换应用并重启至 v\(release.version)…",
                "Installing v\(release.version) and relaunching…"
            )
        case .failed(let failure):
            return failure.message
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch store.updateState {
        case .idle, .upToDate:
            Button(L10n.tr("检查更新", "Check for Updates")) {
                Task { await store.checkForUpdates() }
            }
            .buttonStyle(PillActionButtonStyle())

        case .checking:
            Button(L10n.tr("检查中…", "Checking…")) {}
                .buttonStyle(PillActionButtonStyle())
                .disabled(true)

        case .available(let release):
            if release.packageAsset != nil {
                Button(L10n.tr("立即更新", "Update Now")) {
                    startInstallAndRelaunchIfVisible()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
            Button(L10n.tr("手动下载", "Manual Download")) {
                NSWorkspace.shared.open(release.pageURL)
            }
            .buttonStyle(PillActionButtonStyle())

        case .downloading, .verifying:
            Button(L10n.tr("取消", "Cancel")) {
                store.cancelUpdateInstallation()
            }
            .buttonStyle(PillActionButtonStyle())

        case .readyToRelaunch:
            Button(L10n.tr("立即重启并更新", "Relaunch & Update")) {
                store.confirmRelaunchForUpdate()
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .green))
            Button(L10n.tr("稍后", "Later")) {
                store.cancelUpdateInstallation()
            }
            .buttonStyle(PillActionButtonStyle())

        case .installing:
            Button(L10n.tr("正在重启…", "Relaunching…")) {}
                .buttonStyle(PillActionButtonStyle())
                .disabled(true)

        case .failed(let failure):
            if failure.canRetryInstall {
                Button(L10n.tr("重试", "Retry")) {
                    startInstallAndRelaunchIfVisible()
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            } else {
                Button(L10n.tr("重试", "Retry")) {
                    Task { await store.checkForUpdates() }
                }
                .buttonStyle(PillActionButtonStyle())
            }
            Button(L10n.tr("手动下载", "Manual Download")) {
                NSWorkspace.shared.open(failure.fallbackURL)
            }
            .buttonStyle(PillActionButtonStyle())
        }
    }

    private func releaseNotes(_ notes: String, pageURL: URL) -> some View {
        let titles = ReleaseNotesDigest.titles(in: notes)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                    Text(ReleaseNotesDigest.render(title))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Link(destination: pageURL) {
                Text(ReleaseNotesDigest.readMoreTitle)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous))
    }

    private func startInstallAndRelaunchIfVisible() {
        Task {
            await store.startUpdateInstallation()
            if isVisible, store.updateState.isReadyToRelaunch {
                store.confirmRelaunchForUpdate()
            }
        }
    }
}

enum ReleaseNotesDigest {
    static let maximumLeadIns = 5
    static let maximumLeadInLength = 160

    static var readMoreTitle: String {
        L10n.tr("查看完整更新记录 →", "See the full release notes →")
    }

    static func titles(in notes: String) -> [String] {
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var sections: [[String]] = [[]]
        for line in lines {
            if isHeading(line) {
                sections.append([])
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        let first = sections.first { section in section.contains(where: isBullet) } ?? []
        var titles: [String] = []
        for line in first {
            guard titles.count < maximumLeadIns, let title = bulletTitle(line) else { continue }
            titles.append(title)
        }
        if !titles.isEmpty { return titles }
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !isHeading(line) && !isBareMarker(line) }
            .prefix(maximumLeadIns)
            .map { capped(String($0)) }
    }

    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnly,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            let plain = String(parsed.characters)
            if !plain.contains("**"), !plain.contains("](") {
                return style(parsed)
            }
        }
        return style(AttributedString(plainFallback(markdown)))
    }

    private static func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return false }
        let marks = trimmed[..<space]
        return marks.count >= 1 && marks.count <= 6 && marks.allSatisfy { $0 == "#" }
    }

    private static func isBullet(_ line: String) -> Bool {
        bulletBody(line) != nil
    }

    private static func bulletTitle(_ line: String) -> String? {
        guard let body = bulletBody(line) else { return nil }
        let title = titleBeforeDescription(body)
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : capped(trimmed)
    }

    private static func capped(_ title: String) -> String {
        guard title.count > maximumLeadInLength else { return title }
        return String(title.prefix(maximumLeadInLength - 1)) + "…"
    }

    private static func bulletBody(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerLength = bulletMarkerLength(in: trimmed) else { return nil }
        let body = String(trimmed.dropFirst(markerLength)).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private static func bulletMarkerLength(in line: String) -> Int? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return marker.count }
        let digitCount = line.prefix { $0.isNumber }.count
        guard (1...3).contains(digitCount) else { return nil }
        let afterDigits = line.index(line.startIndex, offsetBy: digitCount)
        return line[afterDigits...].hasPrefix(". ") ? digitCount + 2 : nil
    }

    private static func isBareMarker(_ line: String) -> Bool {
        if ["-", "*", "+"].contains(line) { return true }
        let digits = line.hasSuffix(".") ? String(line.dropLast()) : line
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    private static func titleBeforeDescription(_ body: String) -> String {
        var bold = false
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "*",
               let next = body.index(index, offsetBy: 2, limitedBy: body.endIndex),
               body[body.index(after: index)] == "*" {
                bold.toggle()
                index = next
                continue
            }
            if body[index] == "[", let linkEnd = endOfLink(in: body, from: index) {
                index = linkEnd
                continue
            }
            if !bold, body[index] == "：" {
                return String(body[..<index])
            }
            if !bold, body[index] == ":",
               let next = body.index(index, offsetBy: 1, limitedBy: body.endIndex),
               next < body.endIndex, body[next] == " " {
                return String(body[..<index])
            }
            index = body.index(after: index)
        }
        return body
    }

    private static func endOfLink(in text: String, from start: String.Index) -> String.Index? {
        guard text[start] == "[" else { return nil }
        guard let labelEnd = text[start...].firstIndex(of: "]") else { return nil }
        let paren = text.index(after: labelEnd)
        guard paren < text.endIndex, text[paren] == "(" else { return nil }
        var depth = 0
        var index = paren
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func plainFallback(_ markdown: String) -> String {
        var result = ""
        var index = markdown.startIndex
        while index < markdown.endIndex {
            if markdown[index] == "*",
               let next = markdown.index(index, offsetBy: 2, limitedBy: markdown.endIndex),
               markdown[markdown.index(after: index)] == "*" {
                index = next
                continue
            }
            if markdown[index] == "[", let labelEnd = markdown[index...].firstIndex(of: "]") {
                let afterLabel = markdown.index(after: labelEnd)
                if afterLabel < markdown.endIndex, markdown[afterLabel] == "(" {
                    let labelStart = markdown.index(after: index)
                    result += markdown[labelStart..<labelEnd]
                    if let linkEnd = endOfLink(in: markdown, from: index) {
                        index = linkEnd
                    } else {
                        var end = markdown.index(after: afterLabel)
                        while end < markdown.endIndex, !markdown[end].isWhitespace {
                            end = markdown.index(after: end)
                        }
                        index = end
                    }
                    continue
                }
            }
            result.append(markdown[index])
            index = markdown.index(after: index)
        }
        return result
    }

    private static func style(_ source: AttributedString) -> AttributedString {
        var text = source
        for run in Array(text.runs) {
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            var attributes = AttributeContainer()
            attributes.font = .system(
                size: DesignTokens.TypeSize.caption,
                weight: strong ? .semibold : .regular
            )
            if let link = run.link, link.scheme?.lowercased() == "https" {
                attributes.foregroundColor = Color.accentColor
            } else {
                attributes.foregroundColor = Color.secondary
                text[run.range].link = nil
            }
            text[run.range].mergeAttributes(attributes)
        }
        return text
    }
}
