import Foundation
import Testing
@testable import MijiaCore

/// Item #8 of `docs/research/2026-11-23-deep-dive/00-SUMMARY.md`: a coverage baseline for the
/// deterministic command parser (R14).
///
/// 只跑不判 — every utterance in `Tests/Fixtures/intent_coverage_corpus.json` is pushed through the
/// same entry point the command bar uses and its fate is recorded. A miss is data, never a
/// failure: the only assertions are corpus hygiene (it loads, totals add up, every category is
/// declared). Set `RECORD_INTENT_COVERAGE=1` to rewrite
/// `docs/research/2026-11-23-deep-dive/intent-coverage-baseline.md`.
struct IntentCoverageBaselineTests {
    // MARK: - Corpus

    private struct Corpus: Decodable {
        let meta: Meta
        let devices: [GoldenCorpusTests.CorpusDevice]
        let scenes: [Scene]
        let utterances: [Utterance]

        enum CodingKeys: String, CodingKey {
            case meta = "_meta"
            case devices, scenes, utterances
        }

        struct Meta: Decodable {
            let title: String
            let categories: [String]
        }

        struct Scene: Decodable {
            let id: String
            let name: String
            let entityId: String

            func toHomeScene() -> HomeScene {
                HomeScene(id: id, name: name, entityId: entityId)
            }
        }

        struct Utterance: Decodable {
            let category: String
            let text: String
        }
    }

    /// Where a spoken command ends up, mirroring the stage order of `HomeStore.runAssistantCommand`:
    /// timer cancel → voice undo → spoken delay → local parser → model.
    private enum Outcome: String, CaseIterable {
        /// `LocalIntentParser` answered (after any spoken delay was stripped). Zero network.
        case local
        /// Nothing local answered, so the assistant would send it to the LLM.
        case model
        /// Nothing local answered and no model request is made either: the earlier pre-stage owns
        /// the sentence (timer cancel / voice undo), so neither path can answer it.
        case none
    }

    private struct Row {
        let category: String
        let text: String
        let outcome: Outcome
    }

    private static func classify(_ text: String, devices: [SmartDevice], scenes: [HomeScene]) -> Outcome {
        if DelayPhrase.isCancel(text) || UndoPhrase.isUndo(text) { return .none }
        let utterance = DelayPhrase.extract(text)?.remainder ?? text
        return LocalIntentParser.parse(utterance, devices: devices, scenes: scenes) == nil ? .model : .local
    }

    private static func loadCorpus() throws -> Corpus {
        let url = try GoldenCorpusTests.locateGoldenFixture("Tests/Fixtures/intent_coverage_corpus.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    // MARK: - Test

    @Test("Chinese command corpus loads, totals add up, and records where each utterance goes")
    func coverageBaseline() throws {
        let corpus = try Self.loadCorpus()
        let devices = corpus.devices.map { $0.toSmartDevice() }
        let scenes = corpus.scenes.map { $0.toHomeScene() }

        #expect(!devices.isEmpty, "the corpus needs a fixed home to parse against")
        #expect(!scenes.isEmpty, "the corpus needs scenes for the scene category")
        #expect((150...300).contains(corpus.utterances.count), "corpus size is outside the 150–300 brief")

        // Hygiene: no duplicated sentences (a duplicate would silently weight a category) and no
        // category the fixture header forgot to declare.
        #expect(Set(corpus.utterances.map(\.text)).count == corpus.utterances.count, "duplicate utterances in the corpus")
        let declared = corpus.meta.categories
        #expect(Set(declared).count == declared.count, "duplicate category in _meta.categories")
        let used = Set(corpus.utterances.map(\.category))
        #expect(used == Set(declared), "a category is used but not declared in _meta.categories, or vice versa")

        let rows = corpus.utterances.map { item in
            Row(category: item.category, text: item.text, outcome: Self.classify(item.text, devices: devices, scenes: scenes))
        }

        // Totals must add up — the one invariant a recording-only test can still assert.
        let buckets = Outcome.allCases.map { outcome in rows.filter { $0.outcome == outcome }.count }
        #expect(buckets.reduce(0, +) == rows.count, "every utterance lands in exactly one bucket")

        let report = Report(rows: rows, categories: declared, home: devices)
        print(report.consoleTable)

        if ProcessInfo.processInfo.environment["RECORD_INTENT_COVERAGE"] == "1" {
            let url = try Self.baselineURL()
            try report.markdown.write(to: url, atomically: true, encoding: .utf8)
            print("Recorded intent coverage baseline to \(url.path)")
        }
    }

    /// `Tests/Fixtures/…` → repository root.
    private static func baselineURL() throws -> URL {
        let fixture = try GoldenCorpusTests.locateGoldenFixture("Tests/Fixtures/intent_coverage_corpus.json")
        let root = fixture.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("docs/research/2026-11-23-deep-dive")
        guard FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileNoSuchFile) }
        return directory.appendingPathComponent("intent-coverage-baseline.md")
    }

    // MARK: - Report

    private struct Report {
        let rows: [Row]
        let categories: [String]
        let home: [SmartDevice]

        private func count(_ category: String, _ outcome: Outcome) -> Int {
            rows.filter { $0.category == category && $0.outcome == outcome }.count
        }

        private func total(_ category: String) -> Int {
            rows.filter { $0.category == category }.count
        }

        private func count(_ outcome: Outcome) -> Int {
            rows.filter { $0.outcome == outcome }.count
        }

        private func percent(_ part: Int, of whole: Int) -> String {
            guard whole > 0 else { return "—" }
            // Integer math on purpose: the rounded number in the baseline must not wobble between runs.
            let tenths = (part * 1000 + whole / 2) / whole
            return "\(tenths / 10).\(tenths % 10)%"
        }

        /// Fixed-width so the `swift test` output stays readable without a markdown renderer.
        var consoleTable: String {
            let nameWidth = max(categories.map(\.count).max() ?? 0, 8)
            func pad(_ text: String, _ width: Int, rightAligned: Bool = false) -> String {
                let missing = max(0, width - text.count)
                return rightAligned ? String(repeating: " ", count: missing) + text : text + String(repeating: " ", count: missing)
            }
            var lines = [
                "intent coverage — \(rows.count) utterances, \(home.count) devices",
                "\(pad("category", nameWidth))  \(pad("local", 5, rightAligned: true))  \(pad("model", 5, rightAligned: true))  \(pad("none", 4, rightAligned: true))  \(pad("total", 5, rightAligned: true))  local%"
            ]
            for category in categories {
                lines.append(
                    "\(pad(category, nameWidth))  \(pad("\(count(category, .local))", 5, rightAligned: true))  \(pad("\(count(category, .model))", 5, rightAligned: true))  \(pad("\(count(category, .none))", 4, rightAligned: true))  \(pad("\(total(category))", 5, rightAligned: true))  \(percent(count(category, .local), of: total(category)))"
                )
            }
            let all = rows.count
            lines.append(
                "\(pad("合计", nameWidth))  \(pad("\(count(.local))", 5, rightAligned: true))  \(pad("\(count(.model))", 5, rightAligned: true))  \(pad("\(count(.none))", 4, rightAligned: true))  \(pad("\(all)", 5, rightAligned: true))  \(percent(count(.local), of: all))"
            )
            return lines.joined(separator: "\n")
        }

        var markdown: String {
            let stamp = ISO8601DateFormatter().string(from: Date())
            var out = """
            # 口令覆盖率基线（local / model / none）

            > 本文件由测试生成，请勿手工编辑。
            > 语料 `Tests/Fixtures/intent_coverage_corpus.json`：\(rows.count) 条中文口令，\(categories.count) 类，\(home.count) 台设备的固定虚构家庭。
            > 重录：`RECORD_INTENT_COVERAGE=1 swift test --filter IntentCoverageBaseline`
            > 生成时间：\(stamp)

            ## 口径

            按 `HomeStore.runAssistantCommand` 的阶段顺序判：定时取消 → 语音撤销 → 口语延后（“10分钟后”）→ `LocalIntentParser` → 模型。

            - **local**：`LocalIntentParser` 给出了指令（已剥掉口语延后前缀）。零网络、可复现。
            - **model**：本地解析器拒答，助手会把这句话交给大模型；成功率取决于模型，不在这张表里。表里不分原因：句式没覆盖、设备不支持该参数、目标有歧义，都会落到这一格。
            - **none**：本地无解，而且在流水线里也不会发模型请求——句子被更早的专门阶段接走了（「取消定时」「撤销」）。

            只跑不判：表里没有“期望值”，也还没有对错。这些数字是基线，不是门槛。
            面板房间（`panelRoom`）留空，所以“打开灯”这类裸类别句按全屋判定。

            ## 汇总

            | 类别 | local | model | none | 合计 | local 占比 |
            | --- | ---: | ---: | ---: | ---: | ---: |

            """
            for category in categories {
                out += "| `\(category)` | \(count(category, .local)) | \(count(category, .model)) | \(count(category, .none)) | \(total(category)) | \(percent(count(category, .local), of: total(category))) |\n"
            }
            out += "| **合计** | **\(count(.local))** | **\(count(.model))** | **\(count(.none))** | **\(rows.count)** | **\(percent(count(.local), of: rows.count))** |\n"
            out += """

            ## 固定家庭

            | 设备 | 房间 | 类型 |
            | --- | --- | --- |

            """
            for device in home {
                out += "| \(device.name) | \(device.roomName) | `\(IntentDeviceCategory(device).rawValue)` |\n"
            }
            out += "| 回家模式 / 观影模式 / 睡眠模式 | — | 场景 |\n"
            out += "\n\n## 逐句去向\n\n| 类别 | 口令 | 去向 |\n| --- | --- | --- |\n"
            for row in rows {
                out += "| `\(row.category)` | \(row.text) | \(row.outcome.rawValue) |\n"
            }
            return out
        }
    }
}
