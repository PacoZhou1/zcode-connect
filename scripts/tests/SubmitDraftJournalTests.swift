import Foundation

private struct AssertionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor final class JournalTrace {
    var actions: [String] = []
}

/// Counts the real journal write, or throws before it to model an unavailable disk.
@MainActor final class RecordingJournal {
    let real: SubmissionJournal
    let trace: JournalTrace
    var writes = 0
    var failWrites: Set<Int> = []
    var snapshots: [[String: PendingSubmission]] = []

    init(directory: URL, trace: JournalTrace) {
        real = SubmissionJournal(directory: directory)
        self.trace = trace
    }

    func write(_ values: [String: PendingSubmission], scope: String) throws {
        writes += 1
        trace.actions.append("write:\(writes)")
        snapshots.append(values)
        if failWrites.contains(writes) { throw CocoaError(.fileWriteNoPermission) }
        try real.write(values, scope: scope)
    }
}

struct JournalTestOptions {
    var isPlanMode = false
    var permission: PermissionMode = .ask
}

struct JournalTestConnection { var isOnline = true }

@MainActor final class SubmitDraftHarness {
    enum Outcome { case accepted, unknown, rejected }
    struct Sent {
        var text: String
        var sessionID: String
        var inputID: String
        var attachments: [Attachment]
        var durable: [String: PendingSubmission]
    }
    let trace = JournalTrace()
    let submissionJournal: RecordingJournal
    let persistenceScope = "isolated-test-host"
    var connectionEpoch = 1
    var connection = JournalTestConnection()
    var client: Bool? = true
    var isReferenceMode = false
    var errorMessage: String?
    var pendingSubmissions: [String: PendingSubmission] = [:]
    var uploadedAttachments: [String: String] = [:]
    var rejectedSubmissionIDs: Set<String> = []
    var selectedProjectID: String? = "isolated-project"
    var options = JournalTestOptions()
    var newModelSelection: ModelSelection?
    var outcome: Outcome = .accepted
    var createdID: String? = "created-session"
    var creations: [[String: JSONValue]?] = []
    var creationJournals: [[String: PendingSubmission]] = []
    var sends: [Sent] = []
    var uploadReceipts: [String: String] = [:]

    init(directory: URL) { submissionJournal = RecordingJournal(directory: directory, trace: trace) }
    func messageLengthError(_ text: String) -> String? { nil }
    func reconcilePendingSubmissions(_ id: String) async {}
    func seed(_ entry: PendingSubmission) throws {
        pendingSubmissions[entry.draftKey] = entry
        try submissionJournal.real.write(pendingSubmissions, scope: persistenceScope)
    }
    func durable() throws -> [String: PendingSubmission] {
        try submissionJournal.real.read(scope: persistenceScope)
    }
    func createSession(text: String, persistedBody: [String: JSONValue]? = nil) async -> String? {
        trace.actions.append("create")
        creations.append(persistedBody)
        creationJournals.append((try? durable()) ?? [:])
        return createdID
    }
    func send(_ text: String, to id: String, inputID: String = UUID().uuidString,
              attachments: [Attachment] = []) async -> Bool {
        trace.actions.append("send")
        sends.append(Sent(text: text, sessionID: id, inputID: inputID, attachments: attachments,
                          durable: (try? durable()) ?? [:]))
        for (attachmentID, remoteID) in uploadReceipts { uploadedAttachments["\(id):\(attachmentID)"] = remoteID }
        if outcome == .rejected { rejectedSubmissionIDs.insert(inputID) }
        return outcome == .accepted
    }
}

@MainActor @main struct SubmitDraftJournalTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw AssertionFailure(message: message) }
    }
    static func pending(sessionID: String? = "existing-session") -> PendingSubmission {
        PendingSubmission(id: "frozen-input", draftKey: "draft", sessionID: sessionID,
            creation: sessionID == nil ? ["clientDraftId": .string("frozen-create"), "projectId": .string("isolated-project")] : nil,
            text: "original text", attachments: [Attachment(id: "attachment", name: "tiny.txt", data: Data("frozen".utf8), mimeType: "text/plain")],
            uploadedIDs: ["attachment": "remote-attachment"])
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var results: [[String: Any]] = []
        let tests: [(String, @MainActor (SubmitDraftHarness) async throws -> Void)] = [
            ("new input to existing task: one preflight and one result write", { h in
                let result = await h.submitDraft("hello", attachments: [], draftKey: "draft", sessionID: "existing-session")
                try expect(h.trace.actions == ["write:1", "send", "write:2"], "Actual order: \(h.trace.actions)")
                try expect(result == "existing-session" && h.sends.count == 1 && h.creations.isEmpty, "Send must occur once without creation")
                try expect(h.sends[0].durable["draft"]?.id == h.sends[0].inputID, "Input ID must be durable before send")
                let final = try h.durable()
                try expect(final.isEmpty && h.pendingSubmissions.isEmpty, "Accepted result must clear the durable entry")
            }),
            ("retry keeps frozen payload and uses one preflight", { h in
                let entry = pending(); try h.seed(entry)
                let result = await h.submitDraft("edited current draft", attachments: [], draftKey: "draft", sessionID: "unrelated", retryPending: true)
                try expect(h.trace.actions == ["write:1", "send", "write:2"], "Actual retry order: \(h.trace.actions)")
                try expect(result == entry.sessionID && h.sends.count == 1 && h.creations.isEmpty, "Retry must use existing task")
                try expect(h.sends[0].inputID == entry.id && h.sends[0].text == entry.text && h.sends[0].attachments == entry.attachments, "Retry must retain frozen ID/body/attachment")
                try expect(h.uploadedAttachments["existing-session:attachment"] == "remote-attachment", "Upload receipt must be reused")
                try expect(h.sends[0].durable["draft"] == entry, "Retry preflight must persist exact original entry")
            }),
            ("new task: one pre-create, one post-create, one result write", { h in
                let result = await h.submitDraft("create once", attachments: [], draftKey: "draft", sessionID: nil)
                try expect(h.trace.actions == ["write:1", "create", "write:2", "send", "write:3"], "Actual creation order: \(h.trace.actions)")
                try expect(result == "created-session" && h.creations.count == 1 && h.sends.count == 1, "Create and send must each occur once")
                let atCreate = h.creationJournals[0]["draft"]
                try expect(atCreate?.sessionID == nil && atCreate?.creation == h.creations[0], "Original create body must be durable before creation")
                try expect(atCreate?.creation?["clientDraftId"]?.stringValue?.isEmpty == false, "Create idempotency ID must be present")
                let atSend = h.sends[0].durable["draft"]
                try expect(atSend?.sessionID == "created-session" && atSend?.id == atCreate?.id, "Returned session ID must be durable before send")
                try expect(atSend?.creation == atCreate?.creation, "Create envelope must remain frozen")
            }),
            ("existing task preflight failure causes zero network calls", { h in
                h.submissionJournal.failWrites = [1]
                let result = await h.submitDraft("hello", attachments: [], draftKey: "draft", sessionID: "existing-session")
                try expect(result == nil && h.trace.actions == ["write:1"], "Failed preflight must return before network")
                try expect(h.sends.isEmpty && h.creations.isEmpty, "No network after failed durable preflight")
                try expect(h.pendingSubmissions["draft"] != nil && h.errorMessage != nil, "Pending in-memory draft and visible error must remain")
            }),
            ("retry preflight failure causes zero network calls", { h in
                let entry = pending(); try h.seed(entry); h.submissionJournal.failWrites = [1]
                let result = await h.submitDraft(entry.text, attachments: entry.attachments, draftKey: "draft", sessionID: entry.sessionID)
                try expect(result == nil && h.trace.actions == ["write:1"], "Retry must stop at failed preflight")
                try expect(h.sends.isEmpty && h.creations.isEmpty, "Retry failure must cause zero network")
                let durable = try h.durable()
                try expect(durable["draft"] == entry && h.pendingSubmissions["draft"] == entry, "Original retry must survive failure")
            }),
            ("new task preflight failure cannot create or send", { h in
                h.submissionJournal.failWrites = [1]
                let result = await h.submitDraft("new task", attachments: [], draftKey: "draft", sessionID: nil)
                try expect(result == nil && h.trace.actions == ["write:1"], "Creation preflight must be the first barrier")
                try expect(h.creations.isEmpty && h.sends.isEmpty, "Neither network mutation is allowed")
            }),
            ("post-create write failure prevents send; explicit retry reuses task", { h in
                h.submissionJournal.failWrites = [2]
                let result = await h.submitDraft("new task", attachments: [], draftKey: "draft", sessionID: nil)
                try expect(result == nil && h.trace.actions == ["write:1", "create", "write:2"], "Failure must occur after one creation and before send: \(h.trace.actions)")
                try expect(h.creations.count == 1 && h.sends.isEmpty, "Do not send after failed post-create barrier")
                let entry = h.pendingSubmissions["draft"]!
                try expect(entry.sessionID == "created-session", "Retain returned session ID in memory for retry")
                let previous = try h.durable()["draft"]
                try expect(previous?.id == entry.id && previous?.sessionID == nil, "Previous durable create ID/input ID remain recoverable after crash")
                h.submissionJournal.failWrites = []
                let retry = await h.submitDraft("changed draft", attachments: [], draftKey: "draft", sessionID: nil, retryPending: true)
                try expect(retry == "created-session" && h.creations.count == 1 && h.sends.count == 1, "Retry must not create a second task")
                try expect(h.trace.actions == ["write:1", "create", "write:2", "write:3", "send", "write:4"], "Retry has exactly one successful preflight")
                try expect(h.sends[0].inputID == entry.id && h.sends[0].durable["draft"]?.sessionID == "created-session", "Retry persists original input and returned task before send")
            }),
            ("existing-task result write failure retains durable original ID", { h in
                h.submissionJournal.failWrites = [2]
                let result = await h.submitDraft("hello", attachments: [], draftKey: "draft", sessionID: "existing-session")
                try expect(h.trace.actions == ["write:1", "send", "write:2"], "Final result write is required, with no extra mutation")
                try expect(result == "existing-session" && h.sends.count == 1, "Known successful send remains acknowledged")
                let durable = try h.durable()["draft"]
                try expect(durable?.id == h.sends[0].inputID, "Failed deletion leaves original durable input for restart")
                try expect(h.errorMessage?.contains("发送记录保存失败") == true, "Result persistence failure must be surfaced")
            }),
            ("new-task result write failure retains returned session and input", { h in
                h.submissionJournal.failWrites = [3]
                let result = await h.submitDraft("new task", attachments: [], draftKey: "draft", sessionID: nil)
                try expect(h.trace.actions == ["write:1", "create", "write:2", "send", "write:3"], "Result failure must not skip create/send barriers")
                try expect(result == "created-session" && h.creations.count == 1 && h.sends.count == 1, "No extra network after result persistence failure")
                let durable = try h.durable()["draft"]
                try expect(durable?.sessionID == "created-session" && durable?.id == h.sends[0].inputID, "Restart must reuse created task and original input ID")
            }),
            ("uncertain send result persists immutable request and upload receipts", { h in
                let entry = pending(); try h.seed(entry); h.outcome = .unknown
                h.uploadReceipts = ["attachment": "confirmed-upload"]
                let result = await h.submitDraft(entry.text, attachments: entry.attachments, draftKey: "draft", sessionID: entry.sessionID)
                try expect(result == nil && h.trace.actions == ["write:1", "send", "write:2"], "Unknown result must still be journaled")
                let durable = try h.durable()["draft"]
                try expect(durable?.id == entry.id && durable?.text == entry.text && durable?.attachments == entry.attachments, "Unknown must retain exact send intent")
                try expect(durable?.uploadedIDs["attachment"] == "confirmed-upload", "Post-send durable record keeps returned upload receipt")
            }),
            ("definite rejection persists cleared journal without additional network", { h in
                let entry = pending(); try h.seed(entry); h.outcome = .rejected
                let result = await h.submitDraft(entry.text, attachments: entry.attachments, draftKey: "draft", sessionID: entry.sessionID)
                try expect(result == nil && h.trace.actions == ["write:1", "send", "write:2"], "Rejected outcome must retain final write")
                let durable = try h.durable()
                try expect(durable.isEmpty && h.pendingSubmissions.isEmpty && h.rejectedSubmissionIDs.isEmpty, "Definite rejection is terminal for this journal entry")
            })
        ]
        for (index, test) in tests.enumerated() {
            let harness = SubmitDraftHarness(directory: root.appendingPathComponent("case-\(index)"))
            let before = assertions
            do {
                try await test.1(harness)
                print("PASS \(test.0)")
                results.append(["name": test.0, "passed": true, "assertions": assertions - before, "trace": harness.trace.actions])
            } catch {
                print("FAIL \(test.0): \(error.localizedDescription)")
                results.append(["name": test.0, "passed": false, "assertions": assertions - before,
                                "error": error.localizedDescription, "trace": harness.trace.actions])
            }
        }
        let passed = results.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["passed": passed, "total": tests.count, "assertions": assertions,
                                     "realNetworkCalls": 0, "tests": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(passed)/\(tests.count) tests passed; \(assertions) assertions; real network calls: 0")
        if passed != tests.count { exit(1) }
    }
}
