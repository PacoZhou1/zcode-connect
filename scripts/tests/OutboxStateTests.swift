import Foundation
import CryptoKit

// These inert adapters replace only platform side effects. No credential is read/written.
@MainActor final class UIPasteboard { static let general = UIPasteboard(); var string: String? }
@MainActor final class UISelectionFeedbackGenerator { func selectionChanged() {} }
@MainActor enum CredentialStore {
    static func read(_ id: String) -> String? { "synthetic-test-token" }
    static func save(_ value: String, id: String) throws {}
    static func remove(_ id: String) {}
}
@MainActor enum OutboxTestSandbox { static var directory = URL(fileURLWithPath: "/invalid-unconfigured-test-directory") }

struct TestRequest: Sendable {
    let host: String
    let method: String
    let path: String
    let body: [String: JSONValue]
}
struct TestEvent: Sendable { let envelope: BridgeEnvelope; let delivered: CheckedContinuation<Void, Never> }

@MainActor enum TestTransport {
    static var requests: [TestRequest] = []
    static var handler: (@MainActor (TestRequest) async throws -> JSONValue?)?
    static var subscribers: [String: AsyncStream<TestEvent>.Continuation] = [:]
    static var eventSubscriptions: [String: Int] = [:]
    static var status = "idle"
    static var title = "Synthetic task"
    static var created = 0
    static var uploaded = 0
    static var drafts: [String: String] = [:]
    static func reset() { requests = []; handler = nil; subscribers = [:]; eventSubscriptions = [:]; status = "idle"; title = "Synthetic task"; created = 0; uploaded = 0; drafts = [:] }
    static func session(_ id: String = "S", status: String? = nil, title: String? = nil) -> JSONValue {
        .object(["id": .string(id), "title": .string(title ?? self.title), "projectId": .string("P"),
                 "projectName": .string("Synthetic project"), "status": .string(status ?? self.status),
                 "updatedAt": .string("2026-09-12T00:00:00Z"), "source": .string("bridge"),
                 "capabilities": .object(["read": .bool(true), "send": .bool(true), "stop": .bool(true), "approve": .bool(true), "changes": .bool(true)])])
    }
    static func message(_ text: String) -> JSONValue {
        .object(["id": .string("M"), "role": .string("assistant"), "text": .string(text), "createdAt": .string("2026-09-12T00:00:00Z"), "isStreaming": .bool(true)])
    }
    static func detail(_ text: String? = nil, status: String? = nil) -> JSONValue {
        .object(["session": session(status: status), "messages": .array(text.map { [message($0)] } ?? []), "pendingInteractions": .array([])])
    }
    static func request(_ request: TestRequest) async throws -> JSONValue {
        requests.append(request)
        if let result = try await handler?(request) { return result }
        if request.path == "v1/status" { return .object(["hostName": .string(request.host), "connectionStatus": .string("connected")]) }
        if request.path == "v1/projects" { return .object(["projects": .array([.object(["id": .string("P"), "name": .string("Synthetic project"), "path": .string("/synthetic/P")]), .object(["id": .string("Q"), "name": .string("Second project"), "path": .string("/synthetic/Q")])])]) }
        if request.path == "v1/models" { return .object(["models": .array([])]) }
        if request.path.hasPrefix("v1/sessions?") { return .object(["sessions": .array([session()])]) }
        if request.path == "v1/sessions", request.method == "POST" {
            let key = request.body["clientDraftId"]?.stringValue ?? UUID().uuidString
            let id: String
            if let prior = drafts[key] { id = prior }
            else { created += 1; id = "created-\(created)"; drafts[key] = id }
            return .object(["session": session(id)])
        }
        if request.path.hasSuffix("/attachments") {
            uploaded += 1
            return .object(["attachment": .object(["id": .string("uploaded-\(uploaded)")])])
        }
        if request.path.hasSuffix("/messages") { return .object(["accepted": .bool(true)]) }
        if request.path.hasPrefix("v1/sessions/") { return detail() }
        throw TestFailure(message: "Unexpected synthetic request \(request.method) \(request.path)")
    }
    static func emit(_ payload: [String: JSONValue], host: String = "a.invalid", type: String = "message.updated") async throws {
        for _ in 0..<100 where subscribers[host] == nil { await Task.yield() }
        guard let subscriber = subscribers[host] else { throw TestFailure(message: "No synthetic SSE subscriber") }
        let value = JSONValue.object(["id": .string(UUID().uuidString), "type": .string(type), "sessionId": .string("S"), "data": .object(payload)])
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: JSONEncoder().encode(value))
        await withCheckedContinuation { delivered in subscriber.yield(TestEvent(envelope: envelope, delivered: delivered)) }
    }
}

struct BridgeClient: Sendable {
    let baseURL: URL
    init(baseURL: URL, token: String, certificateSHA256: String? = nil) { self.baseURL = baseURL }
    @MainActor func get<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self) async throws -> T { try await request(path, method: "GET", body: [:], as: T.self) }
    @MainActor func post<T: Decodable & Sendable>(_ path: String, body: [String: String], as: T.Type = T.self) async throws -> T { try await request(path, method: "POST", body: body.mapValues(JSONValue.string), as: T.self) }
    @MainActor func mutate<T: Decodable & Sendable>(_ path: String, method: String = "POST", body: [String: JSONValue], as: T.Type = T.self) async throws -> T { try await request(path, method: method, body: body, as: T.self) }
    @MainActor private func request<T: Decodable & Sendable>(_ path: String, method: String, body: [String: JSONValue], as: T.Type) async throws -> T {
        let value = try await TestTransport.request(TestRequest(host: baseURL.host!, method: method, path: path, body: body))
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    @MainActor func events(after cursor: String?, onEvent: @Sendable (BridgeEnvelope) async -> Void) async throws {
        TestTransport.eventSubscriptions[baseURL.host!, default: 0] += 1
        let stream = AsyncStream<TestEvent> { TestTransport.subscribers[baseURL.host!] = $0 }
        for await event in stream { await onEvent(event.envelope); event.delivered.resume() }
    }
}

struct TestFailure: Error { let message: String }
@MainActor final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async throws {
        for _ in 0..<10000 { if entered { return }; await Task.yield() }
        throw TestFailure(message: "Timed out waiting for synthetic request gate")
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class Fixture {
    let suite = "dev.paco.outbox-tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let profile = ConnectionProfile(id: "A", name: "Synthetic A", baseURL: "https://a.invalid")
    let store: AppStore
    init() { defaults = UserDefaults(suiteName: suite)!; store = AppStore(defaults: defaults) }
    func connect() async { await store.connect(profile, token: "synthetic-test-token") }
    func close() { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
}

struct TestResult: Codable { let name: String; let passed: Bool; let detail: String }
@main struct OutboxStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1; if try condition() == false { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        TestTransport.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do { try await body(); results.append(TestResult(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(TestResult(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    @MainActor static func main() async throws {
        await run("journal round-trip preserves immutable text, bytes, creation and upload IDs") {
            let journal = SubmissionJournal(directory: OutboxTestSandbox.directory)
            let attachment = Attachment(name: "test.txt", data: Data("test".utf8), mimeType: "text/plain")
            var entry = PendingSubmission(draftKey: "new:P", creation: ["projectId": .string("P"), "clientDraftId": .string("stable")], text: "unchanged", attachments: [attachment])
            entry.uploadedIDs[attachment.id] = "remote"
            try journal.write([entry.draftKey: entry], scope: "A|https://a.invalid")
            try check(try journal.read(scope: "A|https://a.invalid") == [entry.draftKey: entry], "journal changed request data")
            try check(try journal.read(scope: "A|https://b.invalid").isEmpty, "URL scopes collided")
            try check(try journal.read(scope: "B|https://a.invalid").isEmpty, "profile scopes collided")
        }
        await run("relaunch retry preserves input ID and avoids reuploading acknowledged attachment") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let attachment = Attachment(name: "test.txt", data: Data("bytes".utf8), mimeType: "text/plain")
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic transport failure", code: "offline") }; return nil }
            _ = await f.store.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S")
            let prior = f.store.pendingSubmissions["S"]!
            try check(prior.uploadedIDs[attachment.id] == "uploaded-1", "uploaded ID was not saved")
            f.store.disconnect()
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            await reopened.connect(f.profile)
            try check(reopened.pendingSubmissions["S"]?.id == prior.id, "input ID changed on relaunch")
            TestTransport.handler = nil
            let result = await reopened.submitDraft("", attachments: [], draftKey: "S", sessionID: "S", retryPending: true)
            try check(result == "S", "retry not acknowledged")
            try check(TestTransport.uploaded == 1, "acknowledged attachment uploaded twice")
            let inputs = TestTransport.requests.filter { $0.path.hasSuffix("/messages") }.map { $0.body["inputId"] }
            try check(inputs == [.string(prior.id), .string(prior.id)], "retry changed input ID")
            try check(reopened.pendingSubmissions.isEmpty, "successful entry remained pending")
        }
        await run("edited draft remains separate while retry sends the original request") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic transport failure", code: "offline") }; return nil }
            _ = await f.store.submitDraft("original", attachments: [], draftKey: "S", sessionID: "S")
            f.store.setDraft("edited", for: "S")
            let blocked = await f.store.submitDraft("edited", attachments: [], draftKey: "S", sessionID: "S")
            try check(blocked == nil, "changed payload reused original request")
            TestTransport.handler = nil
            _ = await f.store.submitDraft("edited", attachments: [], draftKey: "S", sessionID: "S", retryPending: true)
            try check(f.store.drafts["S"] == "edited", "new draft was cleared")
            try check(TestTransport.requests.last(where: { $0.path.hasSuffix("/messages") })?.body["text"] == .string("original"), "retry sent edited text")
        }
        await run("lost ACK is recoverable while the accepted task is still running") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { TestTransport.status = "running"; throw BridgeFailure(message: "synthetic lost ACK", code: "offline") }; return nil }
            _ = await f.store.submitDraft("once", attachments: [], draftKey: "S", sessionID: "S")
            TestTransport.handler = nil
            let result = await f.store.submitDraft("once", attachments: [], draftKey: "S", sessionID: "S", retryPending: true)
            let count = TestTransport.requests.filter { $0.path.hasSuffix("/messages") }.count
            try check(result == "S" && count == 2, "same-ID retry was blocked before transport; message requests=\(count), pending=\(f.store.pendingSubmissions.count)")
        }
        await run("disconnect during message request preserves only original host journal") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let gate = Gate()
            TestTransport.handler = { r in if r.host == "a.invalid", r.path.hasSuffix("/messages") { await gate.hold() }; return nil }
            let task = Task { await f.store.submitDraft("A text", attachments: [], draftKey: "S", sessionID: "S") }
            try await gate.waitUntilEntered()
            await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
            gate.release(); let result = await task.value
            try check(result == nil, "old operation reported success in new epoch")
            try check(f.store.pendingSubmissions.isEmpty, "old entry leaked into new host")
            let journal = SubmissionJournal(directory: OutboxTestSandbox.directory)
            try check(try journal.read(scope: "A|https://a.invalid")["S"]?.text == "A text", "old request recovery was lost")
            try check(try journal.read(scope: "B|https://b.invalid").isEmpty, "old request was written into B journal")
        }
        await run("new-task retry persists creation body even after project selection changes") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { r in if r.path == "v1/sessions", r.method == "POST" { throw BridgeFailure(message: "synthetic create lost ACK", code: "offline") }; return nil }
            _ = await f.store.submitDraft("new", attachments: [], draftKey: "new:P", sessionID: nil)
            let original = f.store.pendingSubmissions["new:P"]!
            f.store.selectedProjectID = "Q"
            TestTransport.handler = nil
            _ = await f.store.submitDraft("new", attachments: [], draftKey: "new:P", sessionID: nil, retryPending: true)
            let creates = TestTransport.requests.filter { $0.path == "v1/sessions" && $0.method == "POST" }
            try check(creates.count == 2 && creates[0].body == creates[1].body, "project/settings changed on retry")
            try check(creates[1].body["clientDraftId"] == original.creation?["clientDraftId"], "creation identity changed")
        }
        await run("failed journal preflight prevents network creation on every retry") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try FileManager.default.createDirectory(at: OutboxTestSandbox.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("blocking file".utf8).write(to: OutboxTestSandbox.directory)
            _ = await f.store.submitDraft("new", attachments: [], draftKey: "new:P", sessionID: nil)
            try check(TestTransport.created == 0, "initial journal failure transmitted a request")
            _ = await f.store.submitDraft("new", attachments: [], draftKey: "new:P", sessionID: nil, retryPending: true)
            try check(TestTransport.created == 0, "retry created \(TestTransport.created) task before durable journal write")
        }
        await run("journal read failure cannot expose prior host pending after refresh") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic failure", code: "offline") }; return nil }
            _ = await f.store.submitDraft("private A request", attachments: [], draftKey: "S", sessionID: "S")
            let scope = "B|https://b.invalid"
            let file = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
            try Data("corrupt test journal".utf8).write(to: OutboxTestSandbox.directory.appendingPathComponent(file))
            TestTransport.handler = nil
            await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
            await f.store.refresh()
            _ = await f.store.submitDraft("", attachments: [], draftKey: "S", sessionID: "S", retryPending: true)
            let cross = TestTransport.requests.filter { $0.host == "b.invalid" && $0.path.hasSuffix("/messages") }
            try check(cross.isEmpty, "B received A pending payload after failed journal load + refresh")
        }
        await run("relaunch can inspect pending attachments while status endpoint is offline") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let attachment = Attachment(name: "test.txt", data: Data("bytes".utf8), mimeType: "text/plain")
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic failure", code: "offline") }; return nil }
            _ = await f.store.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S")
            f.store.disconnect()
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            TestTransport.handler = { _ in throw BridgeFailure(message: "synthetic host offline", code: "offline") }
            await reopened.start()
            try check(reopened.pendingSubmissions["S"]?.attachments == [attachment], "offline relaunch did not load the existing journal")
        }
        await run("definitive attachment rejection allows a corrected draft to progress") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let attachment = Attachment(name: "empty.txt", data: Data(), mimeType: "text/plain")
            TestTransport.handler = { r in if r.path.hasSuffix("/attachments") { throw BridgeFailure(message: "1 byte minimum", code: "attachment_too_large") }; return nil }
            _ = await f.store.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S")
            TestTransport.handler = nil
            let result = await f.store.submitDraft("corrected", attachments: [], draftKey: "S", sessionID: "S")
            try check(result == "S", "definitively unsent invalid attachment remains immutable and blocks corrected input")
        }
        let rejectedBeforeMessage = ["invalid_attachment", "attachment_too_large", "attachment_type_unsupported", "invalid_file_name", "attachment_type_mismatch"]
        let rejectedDuringMessageValidation = ["attachment_not_found", "attachment_changed", "model_does_not_support_images", "model_does_not_support_pdf"]
        for code in rejectedBeforeMessage + rejectedDuringMessageValidation {
            await run("definitive rejection code \(code) unlocks correction and preserves draft") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                let attachment = Attachment(name: "test.txt", data: Data("bytes".utf8), mimeType: "text/plain")
                f.store.setDraft("original", for: "S")
                let endpoint = rejectedBeforeMessage.contains(code) ? "/attachments" : "/messages"
                TestTransport.handler = { r in if r.path.hasSuffix(endpoint) { throw BridgeFailure(message: "synthetic definite rejection", code: code) }; return nil }
                _ = await f.store.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S")
                try check(f.store.pendingSubmissions["S"] == nil, "\(code) still locks the old pending")
                try check(f.store.drafts["S"] == "original", "\(code) discarded editable draft")
                TestTransport.handler = nil
                let result = await f.store.submitDraft("corrected", attachments: [], draftKey: "S", sessionID: "S")
                try check(result == "S", "\(code) blocked corrected input")
            }
        }
        for code in ["input_pending", "input_conflict", "runtime_timeout", "runtime_unavailable", "offline"] {
            await run("uncertain or conflicting \(code) preserves identity and original payload") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic uncertainty", code: code) }; return nil }
                _ = await f.store.submitDraft("original", attachments: [], draftKey: "S", sessionID: "S")
                guard let entry = f.store.pendingSubmissions["S"] else { throw TestFailure(message: "\(code) discarded uncertain request") }
                _ = await f.store.submitDraft("edited", attachments: [], draftKey: "S", sessionID: "S")
                _ = await f.store.submitDraft("original", attachments: [], draftKey: "S", sessionID: "S", retryPending: true)
                try check(f.store.pendingSubmissions["S"]?.id == entry.id, "\(code) changed uncertain request identity")
                let sends = TestTransport.requests.filter { $0.path.hasSuffix("/messages") }
                try check(sends.count == 2 && sends.allSatisfy { $0.body["inputId"] == .string(entry.id) && $0.body["text"] == .string("original") }, "\(code) resent with changed identity/content")
            }
        }
        await run("draft_uncertain preserves original creation identity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { r in if r.path == "v1/sessions", r.method == "POST" { throw BridgeFailure(message: "synthetic uncertain creation", code: "draft_uncertain") }; return nil }
            _ = await f.store.submitDraft("original", attachments: [], draftKey: "new:P", sessionID: nil)
            guard let entry = f.store.pendingSubmissions["new:P"] else { throw TestFailure(message: "uncertain creation discarded") }
            _ = await f.store.submitDraft("original", attachments: [], draftKey: "new:P", sessionID: nil, retryPending: true)
            try check(f.store.pendingSubmissions["new:P"]?.creation == entry.creation, "uncertain creation changed clientDraftId/body")
        }
        for code in ["attachment_not_found", "attachment_changed"] {
            await run("\(code) allows retained original bytes to upload with a new remote ID") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                let attachment = Attachment(name: "test.txt", data: Data("bytes".utf8), mimeType: "text/plain")
                TestTransport.handler = { r in
                    if r.path.hasSuffix("/messages"), r.body["attachmentIds"] == .array([.string("uploaded-1")]) { throw BridgeFailure(message: "synthetic stale reference", code: code) }
                    return nil
                }
                _ = await f.store.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S")
                let result = await f.store.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S")
                try check(result == "S" && TestTransport.uploaded == 2, "retained bytes reused a rejected remote ID; uploads=\(TestTransport.uploaded), accepted=\(result != nil)")
            }
        }
        await run("pending attachment fallback survives definitive rejection and another relaunch") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let attachment = Attachment(name: "camera.jpg", data: Data("synthetic camera bytes".utf8), mimeType: "image/jpeg")
            f.store.setDraft("original", for: "S")
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic lost response", code: "offline") }; return nil }
            _ = await f.store.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S")
            f.store.disconnect()
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            await reopened.connect(f.profile)
            await reopened.loadDraftAttachments(for: "S")
            try check(reopened.draftAttachments["S"] == [attachment], "pending fallback did not load")
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic permanent rejection", code: "model_does_not_support_images") }; return nil }
            _ = await reopened.submitDraft("original", attachments: [attachment], draftKey: "S", sessionID: "S", retryPending: true)
            try check(reopened.pendingSubmissions.isEmpty, "definite rejection did not release pending")
            reopened.disconnect()
            let twice = AppStore(defaults: f.defaults); defer { twice.disconnect() }
            await twice.connect(f.profile)
            await twice.loadDraftAttachments(for: "S")
            try check(twice.draftAttachments["S"] == [attachment], "clearing rejected pending removed the only persisted attachment bytes")
        }
        await run("SSE message and state received during a delayed transcript win") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let gate = Gate()
            TestTransport.handler = { r in if r.path == "v1/sessions/S", r.method == "GET" { let old = TestTransport.detail("old", status: "running"); await gate.hold(); return old }; return nil }
            let task = Task { await f.store.loadTranscript("S") }
            try await gate.waitUntilEntered()
            try await TestTransport.emit(["message": TestTransport.message("latest"), "session": TestTransport.session(status: "completed")])
            gate.release(); await task.value
            try check(f.store.messages("S").first?.text == "latest", "old snapshot replaced newer SSE message")
            try check(f.store.session("S")?.status == .completed, "old snapshot replaced newer SSE state")
        }
        await run("older index response cannot overwrite a newer transcript session snapshot") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let gate = Gate()
            TestTransport.handler = { r in
                if r.path.hasPrefix("v1/sessions?") { let old = JSONValue.object(["sessions": .array([TestTransport.session(status: "idle", title: "old")])]); await gate.hold(); return old }
                if r.path == "v1/sessions/S" { return TestTransport.detail("latest", status: "completed") }
                return nil
            }
            let task = Task { await f.store.refresh() }
            try await gate.waitUntilEntered()
            await f.store.loadTranscript("S")
            try check(f.store.session("S")?.status == .completed, "fresh detail setup failed")
            gate.release(); await task.value
            try check(f.store.session("S")?.status == .completed, "delayed older index replaced newer detail with idle")
        }
        let lengthCases: [(String, Bool, String, Bool)] = [
            ("HTTP accepts 32000 ASCII UTF-16 units", false, String(repeating: "a", count: 32_000), true),
            ("HTTP rejects 32001 ASCII UTF-16 units before task creation", false, String(repeating: "a", count: 32_001), false),
            ("HTTP accepts 16000 emoji at 32000 UTF-16 units", false, String(repeating: "🙂", count: 16_000), true),
            ("HTTP rejects emoji beyond 32000 UTF-16 units before task creation", false, String(repeating: "🙂", count: 16_001), false),
            ("Relay accepts 128000 ASCII UTF-8 bytes", true, String(repeating: "a", count: 128_000), true),
            ("Relay rejects 128001 ASCII UTF-8 bytes before task creation", true, String(repeating: "a", count: 128_001), false),
            ("Relay accepts 32000 emoji at 128000 UTF-8 bytes", true, String(repeating: "🙂", count: 32_000), true),
            ("Relay rejects emoji beyond 128000 UTF-8 bytes before task creation", true, String(repeating: "🙂", count: 32_001), false)
        ]
        for (name, relay, text, valid) in lengthCases {
            await run(name) {
                let f = Fixture(); defer { f.close() }; await f.connect()
                // Only the production validation policy uses the relay profile
                // flag. Transport remains the in-memory HTTP test adapter.
                if relay { f.store.profiles[0].relayDeviceID = "synthetic-policy-device" }
                let key = valid ? "S" : "new:P"
                f.store.setDraft(text, for: key)
                let value = await f.store.submitDraft(text, attachments: [], draftKey: key, sessionID: valid ? "S" : nil)
                let inputs = TestTransport.requests.filter { $0.path.hasSuffix("/messages") }
                if valid {
                    try check(value == "S" && inputs.count == 1, "exact maximum was rejected")
                    try check(inputs.first?.body["text"] == .string(text), "boundary message changed")
                } else {
                    try check(value == nil && inputs.isEmpty && TestTransport.created == 0, "oversized text reached a remote mutation")
                    try check(f.store.pendingSubmissions.isEmpty && f.store.drafts[key] == text, "oversized draft was locked or discarded")
                }
            }
        }
        await run("legacy oversized pending input is released without sending and edited draft remains usable") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let entry = PendingSubmission(draftKey: "S", sessionID: "S", text: String(repeating: "a", count: 32_001), attachments: [])
            f.store.pendingSubmissions["S"] = entry
            try SubmissionJournal(directory: OutboxTestSandbox.directory).write(["S": entry], scope: "A|https://a.invalid")
            f.store.setDraft("short corrected text", for: "S")
            let rejected = await f.store.submitDraft("short corrected text", attachments: [], draftKey: "S", sessionID: "S", retryPending: true)
            try check(rejected == nil && f.store.pendingSubmissions.isEmpty, "invalid saved payload stayed locked")
            try check(!TestTransport.requests.contains { $0.path.hasSuffix("/messages") } && f.store.drafts["S"] == "short corrected text", "legacy payload was sent or edited draft lost")
            let accepted = await f.store.submitDraft("short corrected text", attachments: [], draftKey: "S", sessionID: "S")
            try check(accepted == "S", "corrected draft could not be sent after local rejection")
        }
        await run("definitive invalid request releases pending for corrected input") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            f.store.setDraft("correctable", for: "S")
            TestTransport.handler = { r in if r.path.hasSuffix("/messages") { throw BridgeFailure(message: "synthetic structural rejection", code: "invalid_request") }; return nil }
            _ = await f.store.submitDraft("correctable", attachments: [], draftKey: "S", sessionID: "S")
            try check(f.store.pendingSubmissions.isEmpty && f.store.drafts["S"] == "correctable", "definitive rejection locked or deleted draft")
            TestTransport.handler = nil
            let accepted = await f.store.submitDraft("corrected", attachments: [], draftKey: "S", sessionID: "S")
            try check(accepted == "S", "corrected payload stayed blocked")
        }
        await run("waiting task blocks new input while explicit stop preserves typed draft") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.status = "waiting"; await f.store.loadTranscript("S")
            f.store.setDraft("keep for after stop", for: "S")
            let sent = await f.store.send("new input", to: "S")
            try check(!sent && !TestTransport.requests.contains { $0.path.hasSuffix("/messages") }, "new input escaped while host awaited approval")
            TestTransport.handler = { r in
                if r.path.hasSuffix("/stop") { TestTransport.status = "idle"; return .object(["stopped": .bool(true)]) }
                return nil
            }
            await f.store.stop("S")
            try check(TestTransport.requests.filter { $0.path.hasSuffix("/stop") }.count == 1 && f.store.session("S")?.status == .idle, "waiting stop did not use host confirmation")
            try check(f.store.drafts["S"] == "keep for after stop" && f.store.stoppingSessions.isEmpty, "stop erased composer draft or stayed pending")
        }
        await run("waiting task allows exact pending retry after a lost message ACK") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { r in
                if r.path.hasSuffix("/messages") { TestTransport.status = "waiting"; throw BridgeFailure(message: "synthetic lost ACK", code: "offline") }
                return nil
            }
            _ = await f.store.submitDraft("original", attachments: [], draftKey: "S", sessionID: "S")
            let original = f.store.pendingSubmissions["S"]!
            TestTransport.handler = nil
            let value = await f.store.submitDraft("original", attachments: [], draftKey: "S", sessionID: "S", retryPending: true)
            let ids = TestTransport.requests.filter { $0.path.hasSuffix("/messages") }.map { $0.body["inputId"] }
            try check(value == "S" && ids == [.string(original.id), .string(original.id)], "waiting guard blocked exact retry or changed identity")
        }
        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no network, Simulator, Keychain or service access")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
