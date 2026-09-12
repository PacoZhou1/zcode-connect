import Foundation

// Dependency seam only: matches BridgeClient.swift's error type.
// The production ServerSentEvents.swift is compiled unchanged, not reimplemented.
struct BridgeFailure: LocalizedError {
    let message: String
    let code: String
    var errorDescription: String? { message }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private final class Checks {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        count += 1
        if !condition() { throw Failure(description: message) }
    }
    func events(_ actual: [ServerSentEvent], _ expected: [ServerSentEvent], _ label: String) throws {
        try expect(actual.count == expected.count, "\(label): expected \(expected.count) event(s), got \(actual.count)")
        for (i, pair) in zip(actual, expected).enumerated() {
            try expect(pair.0.id == pair.1.id, "\(label): event \(i) ID mismatch")
            try expect(pair.0.event == pair.1.event, "\(label): event \(i) type mismatch")
            try expect(pair.0.data == pair.1.data,
                       "\(label): event \(i) data mismatch (expected \(pair.1.data.utf8.count) bytes, got \(pair.0.data.utf8.count))")
        }
    }
    func error(_ code: String, _ label: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch let failure as BridgeFailure {
            try expect(failure.code == code, "\(label): expected \(code), got \(failure.code)")
            return
        }
        catch { throw Failure(description: "\(label): unexpected error \(error)") }
        count += 1
        throw Failure(description: "\(label): expected \(code), decoder accepted the input")
    }
}

private func event(_ data: String, id: String? = nil, type: String? = nil) -> ServerSentEvent {
    ServerSentEvent(id: id, event: type, data: data)
}

// Preserve the production decoder between simulated delivery chunks.
private func feed(_ bytes: [UInt8], into decoder: inout ServerSentEventsDecoder,
                  chunks: [Int] = [4096]) throws -> [ServerSentEvent] {
    precondition(!chunks.isEmpty && chunks.allSatisfy { $0 > 0 })
    var offset = 0, chunkIndex = 0
    var records: [ServerSentEvent] = []
    while offset < bytes.count {
        let end = min(bytes.count, offset + chunks[chunkIndex % chunks.count])
        for index in offset..<end {
            if let record = try decoder.append(bytes[index]) { records.append(record) }
        }
        offset = end
        chunkIndex += 1
    }
    return records
}

private func decode(_ bytes: [UInt8], chunks: [Int] = [4096]) throws -> [ServerSentEvent] {
    var decoder = ServerSentEventsDecoder()
    return try feed(bytes, into: &decoder, chunks: chunks)
}
private func decode(_ text: String, chunks: [Int] = [4096]) throws -> [ServerSentEvent] {
    try decode(Array(text.utf8), chunks: chunks)
}

private struct TestCase {
    let name: String
    let group: String
    let body: (Checks) throws -> Void
}

private func cases() -> [TestCase] {
    let maximum = ServerSentEventsDecoder.maximumEventBytes
    return [
        TestCase(name: "lf_multiple_events", group: "required") { c in
            try c.events(decode("data: one\n\ndata: two\n\n"), [event("one"), event("two")], "LF")
        },
        TestCase(name: "crlf_split_between_cr_and_lf", group: "required") { c in
            try c.events(decode("id: 7\r\nevent: delta\r\ndata: 你好\r\n\r\n", chunks: [1]),
                         [event("你好", id: "7", type: "delta")], "bytewise CRLF")
        },
        TestCase(name: "mixed_lf_and_crlf", group: "required") { c in
            try c.events(decode("data: alpha\r\ndata: beta\n\r\ndata: gamma\n\n", chunks: [3, 1, 2]),
                         [event("alpha\nbeta"), event("gamma")], "mixed LF/CRLF")
        },
        TestCase(name: "utf8_every_two_chunk_split", group: "required") { c in
            let text = "id: 中文-🧪\nevent: 更新\ndata: 你好，👩🏽‍💻 café e\u{301} مرحبا\n\n"
            let bytes = Array(text.utf8)
            let expected = [event("你好，👩🏽‍💻 café e\u{301} مرحبا", id: "中文-🧪", type: "更新")]
            try c.events(decode(bytes, chunks: [1]), expected, "bytewise")
            for split in 1..<bytes.count {
                try c.events(decode(bytes, chunks: [split, bytes.count - split]), expected, "split \(split)")
            }
        },
        TestCase(name: "utf8_seeded_chunk_schedules", group: "required") { c in
            let text = "data: 甲乙丙🙂\ndata: 零\u{0}é𝄞\n\ndata: 完成✅\n\n"
            let expected = [event("甲乙丙🙂\n零\u{0}é𝄞"), event("完成✅")]
            var state: UInt64 = 0x5EED_2026_0912
            for schedule in 0..<256 {
                var sizes: [Int] = []
                for _ in 0..<12 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    sizes.append(Int((state >> 32) % 13) + 1)
                }
                try c.events(decode(text, chunks: sizes), expected, "seeded schedule \(schedule)")
            }
        },
        TestCase(name: "multiline_data_preserves_empty_lines", group: "required") { c in
            try c.events(decode("data: first\ndata:\ndata: third\n\n"), [event("first\n\nthird")], "multiline")
        },
        TestCase(name: "multiline_json_with_colons", group: "required") { c in
            let records = try decode("data: {\"url\":\"https://example.invalid/a:b\",\ndata: \"value\":2}\n\n")
            try c.events(records, [event("{\"url\":\"https://example.invalid/a:b\",\n\"value\":2}")], "JSON lines")
            let value = try JSONSerialization.jsonObject(with: Data(records[0].data.utf8)) as? [String: Any]
            try c.expect(value?["value"] as? Int == 2, "joined data must remain valid JSON")
        },
        TestCase(name: "comments_and_unknown_fields", group: "required") { c in
            let text = ": heartbeat\n\nretry: 2000\nunknown: ignored\nData: case-sensitive\n data: ignored\n\ndata: kept\n: between\n\n"
            try c.events(decode(text), [event("kept")], "ignored fields")
        },
        TestCase(name: "single_optional_space_only", group: "required") { c in
            try c.events(decode("data:  leading and trailing \ndata:\ttab\n\n"),
                         [event(" leading and trailing \n\ttab")], "whitespace")
        },
        TestCase(name: "data_without_colon_is_empty_event", group: "required") { c in
            try c.events(decode("data\n\ndata:\n\n"), [event(""), event("")], "empty data fields")
        },
        TestCase(name: "empty_stream_and_blank_blocks", group: "required") { c in
            try c.events(decode(""), [], "empty stream")
            try c.events(decode("\n\r\n\n: comment\n\n"), [], "blank blocks")
        },
        TestCase(name: "event_name_last_wins_and_resets", group: "required") { c in
            try c.events(decode("event: first\nevent: last\ndata: a\n\ndata: b\n\n"),
                         [event("a", type: "last"), event("b")], "event names")
        },
        TestCase(name: "metadata_only_block_does_not_dispatch", group: "required") { c in
            try c.events(decode("event: unused\nid: cursor\n\ndata: next\n\n"),
                         [event("next", id: "cursor")], "metadata block")
        },
        TestCase(name: "id_persists_until_reset", group: "required") { c in
            try c.events(decode("id: cursor-1\ndata: a\n\ndata: b\n\nid:\ndata: c\n\ndata: d\n\n"),
                         [event("a", id: "cursor-1"), event("b", id: "cursor-1"), event("c", id: ""), event("d", id: "")], "ID persistence")
        },
        TestCase(name: "id_null_ignored_and_last_valid_wins", group: "required") { c in
            try c.events(decode("id: first\nid: last\nid: bad\u{0}value\ndata: a\n\n"),
                         [event("a", id: "last")], "NUL ID")
        },
        TestCase(name: "id_without_colon_resets", group: "required") { c in
            try c.events(decode("id: old\n\nid\n\ndata: a\n\n"), [event("a", id: "")], "bare id")
        },
        TestCase(name: "truncated_event_all_prefixes_not_dispatched", group: "required") { c in
            let bytes = Array("id: 12\ndata: 中文🙂\n\n".utf8)
            for length in 0..<bytes.count {
                try c.events(decode(Array(bytes.prefix(length)), chunks: [1]), [], "EOF at byte \(length)")
            }
            try c.events(decode(bytes), [event("中文🙂", id: "12")], "complete boundary")
        },
        TestCase(name: "complete_event_survives_truncated_followup", group: "required") { c in
            let first = Array("data: complete\n\n".utf8)
            let tail = Array("id: next\ndata: 半个🙂\n\n".utf8)
            for length in 0..<tail.count {
                try c.events(decode(first + tail.prefix(length), chunks: [2, 1, 4]),
                             [event("complete")], "truncated followup \(length)")
            }
        },
        TestCase(name: "incomplete_utf8_resumes_across_chunks", group: "required") { c in
            var decoder = ServerSentEventsDecoder()
            let bytes = Array("data: 你🙂\n\n".utf8)
            let split = Array("data: ".utf8).count + 1
            try c.events(feed(Array(bytes.prefix(split)), into: &decoder), [], "partial UTF-8")
            try c.events(feed(Array(bytes.dropFirst(split)), into: &decoder, chunks: [1]),
                         [event("你🙂")], "resumed UTF-8")
        },
        TestCase(name: "invalid_completed_utf8_rejected", group: "strict_utf8_policy") { c in
            let invalid: [[UInt8]] = [[0xFF], [0xC0, 0xAF], [0xE4, 0xBD], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]
            for (i, body) in invalid.enumerated() {
                try c.error("event_invalid_utf8", "invalid UTF-8 vector \(i)") {
                    _ = try decode(Array("data: ".utf8) + body + [10, 10], chunks: [1])
                }
            }
        },
        TestCase(name: "leading_utf8_bom_is_ignored", group: "standard_compatibility") { c in
            let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("data: first\n\n".utf8)
            try c.events(decode(bytes, chunks: [1]), [event("first")], "leading BOM")
        },
        TestCase(name: "interior_bom_is_payload", group: "standard_compatibility") { c in
            try c.events(decode("data: \u{FEFF}inside\n\n"), [event("\u{FEFF}inside")], "payload BOM")
        },
        TestCase(name: "bom_is_only_stripped_at_stream_start", group: "standard_compatibility") { c in
            // A BOM at a later line is part of its field name, not a new stream BOM.
            try c.events(decode("data: first\n\n\u{FEFF}data: ignored\n\n", chunks: [1]),
                         [event("first")], "noninitial BOM field")
        },
        TestCase(name: "bare_cr_line_endings", group: "standard_compatibility") { c in
            try c.events(decode("id: 7\rdata: alpha\rdata: beta\r\r", chunks: [1]),
                         [event("alpha\nbeta", id: "7")], "bare CR")
        },
        TestCase(name: "mixed_cr_lf_crlf_boundaries", group: "standard_compatibility") { c in
            try c.events(decode("data: a\r\ndata: b\n\rdata: c\r\r", chunks: [1, 2, 3]),
                         [event("a\nb"), event("c")], "all legal line endings")
        },
        TestCase(name: "maximum_line_boundary", group: "limits") { c in
            // Existing budget includes the current prefix; this is not a promise
            // that a complete 4 MiB data payload is accepted.
            let value = String(repeating: "x", count: maximum - 5)
            try c.events(decode("data:" + value + "\n\n"), [event(value)], "exact maximum line")
        },
        TestCase(name: "overlong_line_rejected", group: "limits") { c in
            try c.error("event_too_large", "line over limit") {
                _ = try decode("data:" + String(repeating: "x", count: maximum - 4) + "\n\n")
            }
        },
        TestCase(name: "multiline_aggregate_over_limit_rejected", group: "limits") { c in
            let half = String(repeating: "x", count: maximum / 2)
            try c.error("event_too_large", "multiline data over limit") {
                _ = try decode("data:" + half + "\ndata:" + half + "\n\n")
            }
        },
        TestCase(name: "utf8_limit_counts_bytes", group: "limits") { c in
            let value = String(repeating: "界", count: maximum / 3 + 1)
            try c.error("event_too_large", "UTF-8 bytes over limit") {
                _ = try decode("data:" + value + "\n\n")
            }
        },
        TestCase(name: "size_budget_resets_between_events", group: "limits") { c in
            let value = String(repeating: "x", count: maximum / 2 + 64)
            let body = "data:" + value + "\n\n"
            try c.events(decode(body + body), [event(value), event(value)], "per-event reset")
        },
        TestCase(name: "heartbeat_traffic_not_connection_size_limited", group: "limits") { c in
            let comments = String(repeating: ":" + String(repeating: "h", count: 4096) + "\n", count: 1025)
            try c.expect(comments.utf8.count > maximum, "fixture must exceed connection-wide limit")
            try c.events(decode(comments + "data: alive\n\n"), [event("alive")], "discarded comments")
        },
        TestCase(name: "retained_metadata_counts_toward_event_limit", group: "limit_policy") { c in
            // Proposed invariant: retained id + event name + data fits the budget.
            // SSE sets no size limit; failure identifies the app's budget ambiguity.
            let half = String(repeating: "m", count: maximum / 2)
            try c.error("event_too_large", "retained metadata + payload over limit") {
                _ = try decode("id:" + half + "\nevent:" + half + "\ndata:ok\n\n")
            }
        }
    ]
}

private struct CaseResult: Codable {
    let name: String
    let group: String
    let passed: Bool
    let checks: Int
    let milliseconds: Double
    let detail: String?
}
private struct Report: Codable {
    let startedAt: String
    let completedAt: String
    let sourcePath: String
    let sourceSHA256: String
    let swiftVersion: String
    let operatingSystem: String
    let seed: String
    let maximumEventBytes: Int
    let total: Int
    let passed: Int
    let failed: Int
    let checks: Int
    let results: [CaseResult]
}

@main
private struct TestMain {
    static func main() {
        var selected: Set<String> = []
        var reportPath: String?
        var sourcePath = "", sourceSHA = "", swiftVersion = ""
        var listOnly = false, index = 1
        let args = CommandLine.arguments
        while index < args.count {
            let option = args[index]
            if option == "--list" { listOnly = true; index += 1; continue }
            guard index + 1 < args.count else { print("Missing value for \(option)"); exit(2) }
            let value = args[index + 1]
            switch option {
            case "--case": selected.insert(value)
            case "--report": reportPath = value
            case "--source": sourcePath = value
            case "--source-sha": sourceSHA = value
            case "--swift-version": swiftVersion = value
            default: print("Unknown option: \(option)"); exit(2)
            }
            index += 2
        }
        let all = cases()
        if listOnly { all.forEach { print("\($0.name) [\($0.group)]") }; return }
        let unknown = selected.subtracting(Set(all.map(\.name)))
        guard unknown.isEmpty else { print("Unknown cases: \(unknown.sorted())"); exit(2) }
        let running = all.filter { selected.isEmpty || selected.contains($0.name) }
        let formatter = ISO8601DateFormatter(), started = Date()
        var results: [CaseResult] = []
        for test in running {
            let checks = Checks(), start = Date()
            var detail: String?
            do { try test.body(checks) } catch { detail = String(describing: error) }
            let result = CaseResult(name: test.name, group: test.group, passed: detail == nil,
                                    checks: checks.count, milliseconds: Date().timeIntervalSince(start) * 1000,
                                    detail: detail)
            results.append(result)
            print("\(result.passed ? "PASS" : "FAIL") [\(test.group)] \(test.name) (\(checks.count) checks)")
            if let detail { print("  \(detail)") }
        }
        let passed = results.filter(\.passed).count
        let report = Report(startedAt: formatter.string(from: started), completedAt: formatter.string(from: Date()),
                            sourcePath: sourcePath, sourceSHA256: sourceSHA, swiftVersion: swiftVersion,
                            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            seed: "0x5EED20260912", maximumEventBytes: ServerSentEventsDecoder.maximumEventBytes,
                            total: results.count, passed: passed, failed: results.count - passed,
                            checks: results.reduce(0) { $0 + $1.checks }, results: results)
        if let reportPath {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(report).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            } catch { print("Cannot write JSON report: \(error)"); exit(2) }
        }
        print("RESULT: \(report.passed)/\(report.total) passed, \(report.failed) failed, \(report.checks) checks")
        exit(report.failed == 0 ? 0 : 1)
    }
}
