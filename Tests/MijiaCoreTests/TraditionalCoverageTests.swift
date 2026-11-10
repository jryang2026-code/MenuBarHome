import Foundation
import Testing
@testable import MijiaCore

/// Assistant settings sentences are the Simplified strings a person reads on that card.
/// Traditional Chinese is the `zh-Hant.json` entry for that sentence. The `**` pattern
/// would otherwise echo Simplified and hide a missing entry.
struct TraditionalCoverageTests {
    @Test("Every assistant settings sentence has a Traditional translation")
    func assistantSettingsSentencesHaveTraditionalChinese() throws {
        let root = try repoRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/MenuBarMijiaApp/AssistantCommandBar.swift"),
            encoding: .utf8
        )
        let sentences = try assistantSettingsSentences(in: source)
        #expect(sentences.count >= 20)
        let table = try traditionalTable(in: root)
        let missing = sentences.filter { table[$0] == nil }.sorted()
        #expect(missing.isEmpty, "missing Traditional entries: \(missing.joined(separator: " | "))")
        guard missing.isEmpty else { return }
        L10n.$overrideLanguage.withValue(.zhHant) {
            for sentence in sentences {
                let translated = L10n.tr(sentence, "English")
                #expect(translated == table[sentence], "\(sentence)")
            }
        }
    }
}

private func repoRoot() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        let marker = directory.appendingPathComponent(
            "Sources/MijiaCore/Resources/Localizations/zh-Hant.json"
        )
        if FileManager.default.fileExists(atPath: marker.path) { return directory }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func traditionalTable(in root: URL) throws -> [String: String] {
    let url = root.appendingPathComponent("Sources/MijiaCore/Resources/Localizations/zh-Hant.json")
    let data = try Data(contentsOf: url)
    let file = try JSONDecoder().decode(TableFile.self, from: data)
    return file.strings ?? [:]
}

private struct TableFile: Decodable {
    var strings: [String: String]?
}

private func assistantSettingsSentences(in source: String) throws -> [String] {
    guard let start = source.range(of: "enum AssistantSettingsCopy") else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let tail = source[start.upperBound...]
    var end = tail.endIndex
    for marker in ["\nenum ", "\nstruct ", "\nclass ", "\nactor ", "\nextension "] {
        if let found = tail.range(of: marker), found.lowerBound < end {
            end = found.lowerBound
        }
    }
    return try simplifiedLiterals(in: String(tail[..<end]))
}

private func simplifiedLiterals(in body: String) throws -> [String] {
    var sentences: [String] = []
    var index = body.startIndex
    while index < body.endIndex {
        guard let found = nextCall(in: body, from: index) else { break }
        var cursor = found.upperBound
        while cursor < body.endIndex, body[cursor].isWhitespace {
            cursor = body.index(after: cursor)
        }
        guard cursor < body.endIndex, body[cursor] == "\"" else {
            index = found.upperBound
            continue
        }
        let parsed = try parseSwiftString(body, openingQuote: cursor)
        sentences.append(parsed.text)
        index = parsed.end
    }
    return sentences
}

private func nextCall(in body: String, from index: String.Index) -> Range<String.Index>? {
    let tr = body.range(of: "L10n.tr(", range: index..<body.endIndex)
    let format = body.range(of: "L10n.format(", range: index..<body.endIndex)
    switch (tr, format) {
    case let (tr?, format?):
        return tr.lowerBound < format.lowerBound ? tr : format
    case let (tr?, nil):
        return tr
    case let (nil, format?):
        return format
    case (nil, nil):
        return nil
    }
}

private func parseSwiftString(
    _ body: String,
    openingQuote: String.Index
) throws -> (text: String, end: String.Index) {
    var cursor = body.index(after: openingQuote)
    var text = ""
    while cursor < body.endIndex {
        let character = body[cursor]
        if character == "\\" {
            let next = body.index(after: cursor)
            guard next < body.endIndex else { break }
            if body[next] == "(" {
                cursor = body.index(after: next)
                var depth = 1
                while cursor < body.endIndex, depth > 0 {
                    if body[cursor] == "(" { depth += 1 }
                    if body[cursor] == ")" { depth -= 1 }
                    cursor = body.index(after: cursor)
                }
                text.append("*")
                continue
            }
            switch body[next] {
            case "n": text.append("\n")
            case "t": text.append("\t")
            case "\"": text.append("\"")
            case "\\": text.append("\\")
            default: text.append(body[next])
            }
            cursor = body.index(after: next)
            continue
        }
        if character == "\"" {
            return (text, body.index(after: cursor))
        }
        text.append(character)
        cursor = body.index(after: cursor)
    }
    throw CocoaError(.fileReadCorruptFile)
}
