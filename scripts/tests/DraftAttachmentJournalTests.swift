import Foundation
import CryptoKit

struct JournalTestFailure: Error { let message: String }
struct JournalTestResult: Codable { let name: String; let passed: Bool; let detail: String }

@main struct DraftAttachmentJournalTests {
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func file(_ directory: URL, scope: String = "A|https://a.invalid", key: String = "new:P") -> URL {
        directory.appendingPathComponent(digest(scope)).appendingPathComponent(digest(key) + ".json")
    }
    static func attachment(_ id: String = "one", count: Int = 4) -> Attachment {
        Attachment(id: id, name: "测试-\(id).txt", data: Data(repeating: 65, count: count), mimeType: "text/plain")
    }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw JournalTestFailure(message: message) } }
    static func expectError(_ expected: DraftAttachmentJournalFailure? = nil, _ action: @Sendable () async throws -> Void) async throws {
        do { try await action(); throw JournalTestFailure(message: "operation unexpectedly succeeded") }
        catch let error as JournalTestFailure { throw error }
        catch { if let expected { try check(error as? DraftAttachmentJournalFailure == expected, "unexpected error: \(error)") } }
    }
    static func replaceJSON(_ path: URL, _ mutation: (inout [String: Any]) -> Void) throws {
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        mutation(&record)
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: path)
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var results: [JournalTestResult] = []
        let cases: [(String, (URL, DraftAttachmentJournal) async throws -> Void)] = [
            ("missing draft reads empty without creating files", { dir, journal in
                try check(try await journal.read(scope: "A", draftKey: "P").isEmpty, "missing draft not empty")
                try check(!FileManager.default.fileExists(atPath: dir.path), "read created a directory")
            }),
            ("round trip and new journal instance preserve IDs, names, bytes and MIME", { dir, journal in
                let values = [attachment(), attachment("two", count: 1024)]
                try await journal.write(values, scope: "A|https://a.invalid", draftKey: "new:P")
                let reopened = DraftAttachmentJournal(directory: dir)
                try check(try await reopened.read(scope: "A|https://a.invalid", draftKey: "new:P") == values, "reopen changed attachments")
            }),
            ("host scope and draft key each isolate attachment bytes", { _, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                try check(try await journal.read(scope: "A|https://b.invalid", draftKey: "new:P").isEmpty, "URL scope collision")
                try check(try await journal.read(scope: "B|https://a.invalid", draftKey: "new:P").isEmpty, "profile scope collision")
                try check(try await journal.read(scope: "A|https://a.invalid", draftKey: "new:Q").isEmpty, "draft key collision")
            }),
            ("editing one draft never rewrites another draft file", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                let before = try Data(contentsOf: file(dir))
                try await journal.write([attachment("two")], scope: "A|https://a.invalid", draftKey: "new:Q")
                try check(try Data(contentsOf: file(dir)) == before, "unrelated draft rewritten")
            }),
            ("empty array clears only its valid record", { _, journal in
                try await journal.write([attachment()], scope: "A", draftKey: "P")
                try await journal.write([attachment("two")], scope: "A", draftKey: "Q")
                try await journal.write([], scope: "A", draftKey: "P")
                try check(try await journal.read(scope: "A", draftKey: "P").isEmpty, "clear failed")
                try check(try await journal.read(scope: "A", draftKey: "Q") == [attachment("two")], "clear affected another draft")
            }),
            ("record and directory are excluded from backup", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                for url in [dir, file(dir).deletingLastPathComponent(), file(dir)] {
                    try check(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "backup flag not set")
                }
            }),
            ("malformed JSON throws and survives read and attempted clear", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                let damaged = Data("{broken".utf8); try damaged.write(to: file(dir))
                try await expectError(.corruptRecord) { _ = try await journal.read(scope: "A|https://a.invalid", draftKey: "new:P") }
                try await expectError(.corruptRecord) { try await journal.write([], scope: "A|https://a.invalid", draftKey: "new:P") }
                try check(try Data(contentsOf: file(dir)) == damaged, "damaged record changed")
            }),
            ("future schema version is preserved", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                try replaceJSON(file(dir)) { $0["version"] = 999 }
                let before = try Data(contentsOf: file(dir))
                try await expectError(.unsupportedVersion(999)) { try await journal.write([attachment("two")], scope: "A|https://a.invalid", draftKey: "new:P") }
                try check(try Data(contentsOf: file(dir)) == before, "future record overwritten")
            }),
            ("record copied to another scope is rejected", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                try replaceJSON(file(dir)) { $0["scopeDigest"] = digest("B") }
                try await expectError(.scopeMismatch) { _ = try await journal.read(scope: "A|https://a.invalid", draftKey: "new:P") }
            }),
            ("path-like scope and draft never become filesystem paths", { dir, journal in
                try await journal.write([attachment()], scope: "../../host/raw-secret", draftKey: "../../other/draft")
                let scopes = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                try check(scopes.count == 1 && scopes[0].lastPathComponent == digest("../../host/raw-secret"), "scope appeared in path")
                let records = try FileManager.default.contentsOfDirectory(at: scopes[0], includingPropertiesForKeys: nil)
                try check(records.count == 1 && records[0].lastPathComponent == digest("../../other/draft") + ".json", "draft appeared in path")
                let content = try String(contentsOf: records[0], encoding: .utf8)
                try check(!content.contains("raw-secret"), "raw scope leaked into record")
            }),
            ("duplicate IDs, empty bytes and excessive counts cannot overwrite good data", { dir, journal in
                let original = [attachment()]
                try await journal.write(original, scope: "A|https://a.invalid", draftKey: "new:P")
                let before = try Data(contentsOf: file(dir))
                for invalid in [[attachment(), attachment()], [attachment(count: 0)], (0..<7).map { attachment(String($0)) }] {
                    try await expectError(.invalidAttachments) { try await journal.write(invalid, scope: "A|https://a.invalid", draftKey: "new:P") }
                    try check(try Data(contentsOf: file(dir)) == before, "validation failure modified good record")
                }
            }),
            ("single-file 8 MiB boundary is accepted and excess is rejected", { _, journal in
                let boundary = attachment(count: 8 * 1024 * 1024)
                try await journal.write([boundary], scope: "A", draftKey: "P")
                try check(try await journal.read(scope: "A", draftKey: "P") == [boundary], "boundary changed bytes")
                try await expectError(.invalidAttachments) { try await journal.write([attachment(count: 8 * 1024 * 1024 + 1)], scope: "A", draftKey: "P") }
            }),
            ("oversized on-disk record is preserved without decoding", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                let handle = try FileHandle(forWritingTo: file(dir)); try handle.truncate(atOffset: 70 * 1024 * 1024); try handle.close()
                try await expectError(.oversizedRecord) { _ = try await journal.read(scope: "A|https://a.invalid", draftKey: "new:P") }
                try await expectError(.oversizedRecord) { try await journal.write([], scope: "A|https://a.invalid", draftKey: "new:P") }
                try check(try file(dir).resourceValues(forKeys: [.fileSizeKey]).fileSize == 70 * 1024 * 1024, "oversized record changed")
            }),
            ("directory or symlink record is rejected without modifying the target", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                try FileManager.default.removeItem(at: file(dir))
                let target = dir.appendingPathComponent("target.txt"); let content = Data("untouched".utf8); try content.write(to: target)
                try FileManager.default.createSymbolicLink(at: file(dir), withDestinationURL: target)
                try await expectError(.corruptRecord) { try await journal.write([], scope: "A|https://a.invalid", draftKey: "new:P") }
                try check(try Data(contentsOf: target) == content, "symlink target changed")
            }),
            ("atomic replacements are always a complete old or new JSON record", { dir, journal in
                try await journal.write([attachment()], scope: "A|https://a.invalid", draftKey: "new:P")
                let path = file(dir)
                let reader = Task.detached {
                    for _ in 0..<250 {
                        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
                        guard let attachments = value["attachments"] as? [[String: Any]], attachments.count == 1,
                              ["one", "two"].contains(attachments[0]["id"] as? String ?? "") else { throw JournalTestFailure(message: "reader observed partial record") }
                    }
                }
                for i in 0..<30 { try await journal.write([attachment(i.isMultiple(of: 2) ? "two" : "one")], scope: "A|https://a.invalid", draftKey: "new:P") }
                try await reader.value
            }),
            ("concurrent independent drafts retain every record", { _, journal in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for i in 0..<20 { group.addTask { try await journal.write([attachment(String(i))], scope: "A", draftKey: "draft-\(i)") } }
                    try await group.waitForAll()
                }
                for i in 0..<20 { try check(try await journal.read(scope: "A", draftKey: "draft-\(i)") == [attachment(String(i))], "concurrent draft lost") }
            })
        ]
        for (name, body) in cases {
            let dir = root.appendingPathComponent(UUID().uuidString)
            do { try await body(dir, DraftAttachmentJournal(directory: dir)); results.append(.init(name: name, passed: true, detail: "passed")); print("PASS \(name)") }
            catch { let message = (error as? JournalTestFailure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: message)); print("FAIL \(name): \(message)") }
        }
        let output = try JSONEncoder().encode(results)
        try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; Foundation temporary files only")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
