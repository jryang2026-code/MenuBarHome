import Foundation

/// Models that expose a second lens through go2rtc's Xiaomi `channel` query.
///
/// go2rtc treats every non-zero channel as the second lens. The value itself is not a
/// lens index; it only tells the camera to start its second video stream. Keep this list
/// evidence-based: an unlisted model without a dual-lens name stays single-lens instead of
/// showing a switch that silently returns the same picture.
public enum CameraLensCatalog {
    private static let secondLensModels: Set<String> = [
        "isa.camera.500dh",
        "isa.camera.hlmax",
        "chuangmi.camera.72ac1",
        "xiaomi.camera.082ac1",
    ]

    public static func lenses(for model: String, name: String = "") -> [CameraLens] {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard secondLensModels.contains(normalized) || nameSelectsSecondLens(name) else { return [] }
        return [
            CameraLens(role: .main, channel: 0),
            CameraLens(role: .secondary, channel: 1),
        ]
    }

    /// A dual-lens name is a whole word or a known phrase. `Individual` contains the
    /// letters of "dual", and `不是双摄` contains `双摄`, but neither camera has a second lens.
    static func nameSelectsSecondLens(_ name: String) -> Bool {
        containsAffirmedPhrase(name, phrase: "双镜头")
            || containsAffirmedPhrase(name, phrase: "雙鏡頭")
            || containsAffirmedPhrase(name, phrase: "双摄")
            || containsAffirmedPhrase(name, phrase: "雙攝")
            || containsAffirmedWord(name, word: "dual")
    }

    private static let negationMarkers = ["不是", "没有", "不要", "并非", "非", "无", "not ", "not-", "non-", "non ", "no ", "n't "]

    private static func containsAffirmedPhrase(_ name: String, phrase: String) -> Bool {
        var rest = Substring(name)
        while let range = rest.range(of: phrase) {
            if !isNegated(rest[..<range.lowerBound]) { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }

    private static func containsAffirmedWord(_ name: String, word: String) -> Bool {
        let haystack = name.lowercased()
        let needle = word.lowercased()
        var search = haystack.startIndex
        while let range = haystack.range(of: needle, range: search..<haystack.endIndex) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !isAsciiWord(haystack[haystack.index(before: range.lowerBound)])
            let afterOK = range.upperBound == haystack.endIndex
                || !isAsciiWord(haystack[range.upperBound])
            if beforeOK, afterOK, !isNegated(haystack[..<range.lowerBound]) { return true }
            search = range.upperBound
        }
        return false
    }

    private static func isNegated(_ prefix: Substring) -> Bool {
        let text = prefix.lowercased()
        return negationMarkers.contains { text.hasSuffix($0) }
    }

    private static func isAsciiWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
