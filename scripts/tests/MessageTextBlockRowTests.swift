import Foundation

@main struct MessageTextBlockRowTests {
    struct Failure: Error { let message: String }
    struct Result: Codable { let name: String; let passed: Bool; let detail: String }
    @MainActor static var results: [Result] = []
    @MainActor static var assertions = 0

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? Failure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    @MainActor static func main() throws {
        run("equal independently parsed blocks compare equal for each role") {
            let text = "固定 **粗体**\n| 名称 | 值 |\n|---|---|\n| A | 1 |\n```swift\nlet x = 1\n```"
            let first = MessageTextCache.parse(text: text, user: false)
            let second = MessageTextCache.parse(text: text, user: false)
            try check(first.count == second.count && first.count >= 3, "Expected independently parsed prose, code and table")
            for user in [false, true] {
                for (a, b) in zip(first, second) {
                    try check(MessageTextBlockRow(block: a, user: user) == MessageTextBlockRow(block: b, user: user), "Equal block values failed equality")
                }
            }
        }
        run("same ID cannot hide rewritten prose, code, or table cells") {
            let pairs: [(MessageTextBlock, MessageTextBlock)] = [
                (.prose(0, AttributedString("旧答案")), .prose(0, AttributedString("新答案"))),
                (.code(1, "let x = 1"), .code(1, "let x = 2")),
                (.table(2, [["A", "1"]]), .table(2, [["A", "2"]])),
                (.table(2, [["A", "1"]]), .table(2, [["A", "1"], ["B", "2"]]))
            ]
            for (before, after) in pairs {
                try check(MessageTextBlockRow(block: before, user: false) != MessageTextBlockRow(block: after, user: false), "Changed content was hidden behind the stable ID")
            }
        }
        run("attribute-only Markdown changes remain visible") {
            for pair in [("value", "**value**"), ("[value](https://first.invalid)", "[value](https://second.invalid)")] {
                let a = try AttributedString(markdown: pair.0, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                let b = try AttributedString(markdown: pair.1, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                try check(String(a.characters) == String(b.characters), "Fixture must change attributes only")
                try check(MessageTextBlockRow(block: .prose(0, a), user: false) != MessageTextBlockRow(block: .prose(0, b), user: false), "Formatting or link change was ignored")
            }
        }
        run("role, block kind, and identity all participate in equality") {
            let prose = MessageTextBlock.prose(0, AttributedString("value"))
            let row = MessageTextBlockRow(block: prose, user: false)
            try check(row != MessageTextBlockRow(block: prose, user: true), "Role-dependent styling was skipped")
            try check(row != MessageTextBlockRow(block: .code(0, "value"), user: false), "Changed block kind was skipped")
            try check(row != MessageTextBlockRow(block: .prose(1, AttributedString("value")), user: false), "Changed identity was skipped")
        }
        run("empty tails can become visible without changing ID") {
            try check(MessageTextBlockRow(block: .prose(0, AttributedString()), user: false) != MessageTextBlockRow(block: .prose(0, AttributedString("正文")), user: false), "Empty prose stayed hidden")
            try check(MessageTextBlockRow(block: .table(0, []), user: false) != MessageTextBlockRow(block: .table(0, [["值"]]), user: false), "Empty table stayed hidden")
        }
        run("actual append parsing keeps stable prefix rows equal and updates the tail") {
            let text = "固定 **已完成** 段\n\n| 项目 | 值 |\n|---|---|\n| A | 1 |\n\n```swift\nlet x = 1\n```\n\n流式尾部"
            let before = MessageTextCache.parse(text: text, user: false)
            let after = MessageTextCache.parse(text: text + "继续", user: false)
            try check(before.count == after.count && before.count >= 4, "Fixture lost its sealed prefix and mutable tail")
            for (a, b) in zip(before.dropLast(), after.dropLast()) {
                try check(MessageTextBlockRow(block: a, user: false) == MessageTextBlockRow(block: b, user: false), "Unchanged parsed prefix was invalidated")
            }
            try check(MessageTextBlockRow(block: before.last!, user: false) != MessageTextBlockRow(block: after.last!, user: false), "Appended tail was not updated")
        }
        run("layout projection omits only empty prose and preserves original identities") {
            let blocks: [MessageTextBlock] = [
                .prose(0, AttributedString()), .prose(1, AttributedString(" ")),
                .prose(2, AttributedString("正文")), .code(3, ""), .table(4, []), .prose(5, AttributedString())
            ]
            let projected = MessageTextBlock.layoutBlocks(blocks)
            try check(projected.map(\.id) == [1, 2, 3, 4], "Empty prose occupied a row or identities were renumbered")
            try check(projected == Array(blocks[1...4]), "Whitespace, empty code/table, or payload changed")
            try check(MessageTextBlock.layoutBlocks([]).isEmpty, "Empty list gained a row")
            try check(MessageTextBlock.layoutBlocks([blocks[0], blocks[5]]).isEmpty, "Empty prose gained stack spacing")
        }
        run("actual parsed empty tail becomes a row without shifting stable block IDs") {
            let text = "固定正文\n\n| 项目 | 值 |\n|---|---|\n| A | 1 |\n\n```swift\nlet x = 1\n```\n\n"
            let before = MessageTextBlock.layoutBlocks(MessageTextCache.parse(text: text, user: false))
            let after = MessageTextBlock.layoutBlocks(MessageTextCache.parse(text: text + "新尾部", user: false))
            try check(before.map(\.id) == [0, 1, 2], "Empty prose before or after code became a layout row")
            try check(after.map(\.id) == [0, 1, 2, 3], "Appended tail changed stable prefix identities")
            try check(Array(after.dropLast()) == before, "Stable prefix content changed")
            for (a, b) in zip(before, after) {
                try check(MessageTextBlockRow(block: a, user: false) == MessageTextBlockRow(block: b, user: false), "Layout filtering invalidated an unchanged prefix")
            }
        }
        let report: [String: Any] = ["cases": results.count, "passed": results.filter(\.passed).count, "assertions": assertions,
                                     "results": results.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; actual production row equality, no UI or network")
        if results.contains(where: { !$0.passed }) { throw Failure(message: "Row equality regression") }
    }
}
