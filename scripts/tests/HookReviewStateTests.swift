import Foundation

@main struct HookReviewStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1; if try !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        TestTransport.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do { try await body(); results.append(TestResult(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(TestResult(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    static func review(expired: Bool = false, generation: Int = 1) throws -> RelayHookReviewRequest {
        let now = Date.now.timeIntervalSince1970 * 1000
        let raw = """
        {"kind":"workspaceHookReview","reviewFlowId":"flow","generation":\(generation),"interactionId":"I",
        "sessionId":"S","taskId":"T","runId":"R","workspaceIdentity":"W","workspaceLabel":"Synthetic workspace",
        "bundleDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","createdAt":\(now-2000),"deadlineAt":\(expired ? now-1000 : now+600000),
        "sourceFiles":[{"path":"/synthetic/hooks.json","displayPath":"hooks.json","editable":true}],
        "summary":{"eventCount":1,"hookCount":2,"pendingCount":1},"items":[
        {"reviewItemId":"P","event":"Stop","type":"command","displayName":"Pending","displayCommand":"synthetic-only","sourcePath":"hooks.json","resolvedTimeoutMs":1000,"resolvedMaxOutputBytes":1000,"executionMode":"foreground","configuredEnabled":true,"editable":true,"trustState":"pending_trust"},
        {"reviewItemId":"T","event":"Stop","type":"command","displayName":"Trusted","displayCommand":"synthetic-only","sourcePath":"hooks.json","resolvedTimeoutMs":1000,"resolvedMaxOutputBytes":1000,"executionMode":"foreground","configuredEnabled":true,"editable":true,"trustState":"trusted_persistent"}],"warningCode":"workspace_hooks_execute_code"}
        """
        return try JSONDecoder().decode(RelayHookReviewRequest.self, from: Data(raw.utf8))
    }
    @MainActor static func fixture(_ review: RelayHookReviewRequest) async -> Fixture {
        let f = Fixture(); await f.connect()
        f.store.sessions[0].source = "official-relay"
        f.store.pendingInteractions["S"] = [PendingInteraction(id: "I", sessionId: "S", kind: "workspaceHookReview", title: "Synthetic", hookReview: review)]
        TestTransport.requests.removeAll()
        return f
    }
    static func success(_ id: String = "S") -> JSONValue { .object(["accepted": .bool(true), "sessionId": .string(id)]) }
    @MainActor static func main() async throws {
        let operations: [(WorkspaceHookReviewAction, String, RelayHookReviewOperation)] = [
            (.trust(["P"]), "respond", .trustSelected(itemIDs: ["P"])),
            (.revoke(["T"]), "revoke", .revokeSelected(itemIDs: ["T"])),
            (.setEnabled("P", false), "toggle", .setEnabled(itemID: "P", enabled: false))
        ]
        for (action, route, operation) in operations {
            await run("\(route) sends exact immutable review and operation-specific confirmation") {
                let r = try review(), f = await fixture(r); defer { f.close() }
                TestTransport.handler = { req in req.path.contains("/hooks/review/") ? success() : nil }
                let accepted = await f.store.performHookReview(r, action: action, expectedGeneration: f.store.hookReviewGeneration)
                try check(accepted, "Matching host ACK was not accepted")
                let writes = TestTransport.requests.filter { $0.path.contains("/hooks/review/") }
                try check(writes.count == 1 && writes[0].path == "v1/sessions/S/hooks/review/\(route)", "Wrong or duplicate route")
                let body = writes[0].body
                let sent = try JSONDecoder().decode(RelayHookReviewRequest.self, from: JSONEncoder().encode(body["request"]))
                try check(sent == r, "Displayed immutable request changed")
                let confirmation = try JSONDecoder().decode(RelayHookReviewConfirmation.self, from: JSONEncoder().encode(body["confirmation"]))
                try r.validateConfirmation(confirmation, operation: operation)
                try check(body["clientCommandId"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil, "Missing command UUID")
                try check(!TestTransport.requests.contains { $0.path.contains("/interactions/") }, "Hook used generic one-time answer route")
            }
        }
        await run("stale generation and expired requests cannot leave the AppStore") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            f.store.pendingInteractions["S"] = [PendingInteraction(id: "I", sessionId: "S", kind: "workspaceHookReview", title: "Updated", hookReview: try review(generation: 2))]
            let stale = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(!stale && TestTransport.requests.isEmpty, "Stale review reached transport")
            let expired = try review(expired: true)
            f.store.pendingInteractions["S"] = [PendingInteraction(id: "I", sessionId: "S", kind: "workspaceHookReview", title: "Expired", hookReview: expired)]
            let result = await f.store.performHookReview(expired, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(!result && TestTransport.requests.isEmpty, "Expired review reached transport")
        }
        await run("HTTP and reference modes never simulate a persistent host grant") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            f.store.sessions[0].source = "bridge"
            let http = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(!http && TestTransport.requests.isEmpty, "Unsupported HTTP hook was sent")
            f.store.isReferenceMode = true
            let reference = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(!reference && TestTransport.requests.isEmpty, "Reference fixture granted trust")
        }
        await run("HTTP requires explicit host hook capability before routing an operation") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            f.store.sessions[0].source = "bridge"
            f.store.sessions[0].canReviewHooks = true
            TestTransport.handler = { req in req.path.contains("/hooks/review/") ? success() : nil }
            let accepted = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(accepted && TestTransport.requests.filter { $0.path.contains("/hooks/review/respond") }.count == 1, "Advertised HTTP hook capability was ignored")
        }
        await run("unknown result and mismatched session ACK cannot claim success") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            TestTransport.handler = { req in if req.path.contains("/hooks/review/") { throw BridgeFailure(message: "Synthetic uncertain hook", code: "hook_uncertain") }; return nil }
            let uncertain = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(!uncertain && f.store.errorMessage?.contains("uncertain") == true, "Unknown grant claimed success")
            TestTransport.handler = { req in req.path.contains("/hooks/review/") ? success("other") : nil }
            let mismatch = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(!mismatch, "Another session's ACK was accepted")
        }
        await run("sheet failures remain local without presenting the global alert") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            f.store.isReferenceMode = true
            var localError: String?
            let accepted = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration) { localError = $0 }
            try check(!accepted && localError != nil, "Sheet did not receive failure")
            try check(f.store.errorMessage == nil && TestTransport.requests.isEmpty, "Reference failure escaped sheet or reached host")
        }
        await run("accepted operation stays accepted when transcript refresh fails locally") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            TestTransport.handler = { req in
                if req.path.contains("/hooks/review/") { return success() }
                if req.path == "v1/sessions/S" { throw BridgeFailure(message: "Synthetic refresh failure", code: "refresh_failed") }
                return nil
            }
            var localError: String?
            let accepted = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration) { localError = $0 }
            try check(accepted && localError?.contains("refresh failure") == true, "Refresh failure lost ACK or local error")
            try check(f.store.errorMessage == nil, "Refresh failure presented global alert")
            try check(TestTransport.requests.filter { $0.path.contains("/hooks/review/") }.count == 1, "Refresh retried mutation")
        }
        await run("double tap is gated and late A result cannot affect B") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            let gate = Gate()
            TestTransport.handler = { req in
                if req.path.contains("/hooks/review/") { await gate.hold(); return success() }
                return nil
            }
            let first = Task { @MainActor in await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration) }
            try await gate.waitUntilEntered()
            let duplicate = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(!duplicate && TestTransport.requests.filter { $0.path.contains("/hooks/review/") }.count == 1, "Double tap created another operation")
            await f.store.connect(ConnectionProfile(id: "B", name: "B", baseURL: "https://b.invalid"), token: "synthetic")
            gate.release(); let accepted = await first.value
            try check(!accepted && f.store.activeProfileID == "B" && f.store.errorMessage == nil, "Late A grant changed B state")
        }
        await run("queued confirmation is invalid after reconnect even with identical review IDs") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            let previousGeneration = f.store.hookReviewGeneration
            await f.store.connect(f.profile, token: "synthetic")
            f.store.sessions[0].source = "official-relay"
            f.store.pendingInteractions["S"] = [PendingInteraction(id: "I", sessionId: "S", kind: "workspaceHookReview", title: "Synthetic", hookReview: r)]
            TestTransport.requests.removeAll()
            let accepted = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: previousGeneration)
            try check(!accepted && TestTransport.requests.isEmpty, "Queued confirmation survived connection replacement")
        }
        await run("fresh confirmation after same-host reconnect is not blocked by the old operation") {
            let r = try review(), f = await fixture(r); defer { f.close() }
            let gate = Gate(); var submitted = 0
            TestTransport.handler = { req in
                if req.path.contains("/hooks/review/") {
                    submitted += 1
                    if submitted == 1 { await gate.hold() }
                    return success()
                }
                return nil
            }
            let generation = f.store.hookReviewGeneration
            let first = Task { @MainActor in await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: generation) }
            try await gate.waitUntilEntered()
            await f.store.connect(f.profile, token: "synthetic")
            f.store.sessions[0].source = "official-relay"
            f.store.pendingInteractions["S"] = [PendingInteraction(id: "I", sessionId: "S", kind: "workspaceHookReview", title: "Synthetic", hookReview: r)]
            let second = await f.store.performHookReview(r, action: .trust(["P"]), expectedGeneration: f.store.hookReviewGeneration)
            try check(second && submitted == 2, "Old connection's in-flight gate blocked a fresh explicit retry")
            gate.release(); let oldAccepted = await first.value
            try check(!oldAccepted, "Old connection's late result was reported as current")
        }
        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no actual trust grant or network")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
