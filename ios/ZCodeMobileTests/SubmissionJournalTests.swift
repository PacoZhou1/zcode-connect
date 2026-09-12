import XCTest
@testable import ZCodeMobile

final class SubmissionJournalTests: XCTestCase {
    func testReloadKeepsExactRequestAndUploadedAttachmentIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SubmissionJournal(directory: directory)
        let attachment = Attachment(id: "local-file", name: "验收.txt", data: Data("你好".utf8), mimeType: "text/plain")
        var pending = PendingSubmission(draftKey: "new:project", creation: [
            "clientDraftId": .string("stable-create"), "projectId": .string("project")
        ], text: "测试\n原文", attachments: [attachment])
        pending.sessionID = "session-created-before-crash"
        pending.uploadedIDs = [attachment.id: "attachment-uploaded-before-crash"]
        try journal.write([pending.draftKey: pending], scope: "host-A")
        let restored = try XCTUnwrap(journal.read(scope: "host-A")[pending.draftKey])
        XCTAssertEqual(restored, pending)
        XCTAssertEqual(restored.id, pending.id)
        XCTAssertTrue(restored.matches(text: "测试\n原文", attachments: [attachment]))
        XCTAssertFalse(restored.matches(text: "修改后的草稿", attachments: [attachment]))
    }

    func testHostScopesRemainIsolatedAndAcknowledgmentRemovesOnlyItsEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SubmissionJournal(directory: directory)
        let first = PendingSubmission(draftKey: "same-session-id", text: "A", attachments: [])
        let second = PendingSubmission(draftKey: "same-session-id", text: "B", attachments: [])
        try journal.write([first.draftKey: first], scope: "host-A|https://a")
        try journal.write([second.draftKey: second], scope: "host-B|https://b")
        try journal.write([:], scope: "host-A|https://a")
        XCTAssertTrue(try journal.read(scope: "host-A|https://a").isEmpty)
        XCTAssertEqual(try journal.read(scope: "host-B|https://b")[second.draftKey], second)
        XCTAssertTrue(try journal.read(scope: "unseen-host").isEmpty)
    }

    func testCorruptJournalIsReportedInsteadOfDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SubmissionJournal(directory: directory)
        try journal.write([:], scope: "host")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("truncated {".utf8).write(to: file)
        XCTAssertThrowsError(try journal.read(scope: "host"))
        XCTAssertEqual(try Data(contentsOf: file), Data("truncated {".utf8))
    }
}
