import Foundation

// UI storage and transport are inert. The runner inserts the production computed
// properties and submit(accept:) unchanged into an extension of this harness.
@MainActor
final class InteractionRequestSubmissionHarness {
    let store = SubmissionStoreSpy()
    let interaction: PendingInteraction
    var busy = false
    var feedback: String
    var selections: [String: Set<String>] = [:]
    var otherAnswers: [String: String] = [:]
    let draftScope = "host-a"
    let draftKey = "answer:session-a:interaction-a"

    init(feedback: String, kind: String = "userInput", toolName: String? = "ExitPlanMode") {
        self.feedback = feedback
        interaction = PendingInteraction(id: "interaction-a", sessionId: "session-a", kind: kind,
            title: "确认方案", reason: nil, toolName: toolName, questions: nil, input: nil, hookReview: nil)
        store.drafts[draftKey] = "saved-feedback-draft"
    }

    func settle() async throws {
        // Production submit creates a main-actor task without returning its handle.
        // Yield only until that task completes; no networking or UI is involved.
        for _ in 0..<1_000 {
            await Task.yield()
            if !busy { return }
        }
        throw BoundaryFailure(message: "production submission task did not finish")
    }
}

@MainActor
final class SubmissionStoreSpy {
    struct AnswerCall: Equatable {
        let content: JSONValue?
        let decline: Bool
    }
    var drafts: [String: String] = [:]
    var answers: [AnswerCall] = []
    var permissions: [Bool] = []
    func respond(_ interaction: PendingInteraction, allow: Bool) async {
        permissions.append(allow)
    }
    func answer(_ interaction: PendingInteraction, content: JSONValue?, decline: Bool) async -> Bool {
        answers.append(AnswerCall(content: content, decline: decline))
        return true
    }
    func setDraft(_ text: String, for key: String) { drafts[key] = text }
}

// Only satisfies the unused hook DTO dependency in the actual PendingInteraction.
struct RelayHookReviewRequest: Decodable, Sendable {}
struct BoundaryFailure: Error { let message: String }

@main
struct PlanFeedbackBoundaryTests {
    @MainActor static var assertionCount = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertionCount += 1
        if !condition() { throw BoundaryFailure(message: message) }
    }

    @MainActor static func expectAnswer(_ harness: InteractionRequestSubmissionHarness,
                                        text: String?, decline: Bool = false) async throws {
        try await harness.settle()
        let expected = text.map { JSONValue.object(["answer": .string($0)]) }
        try check(harness.store.answers == [.init(content: expected, decline: decline)],
                  "unexpected transport payload: \(harness.store.answers)")
        try check(harness.store.permissions.isEmpty, "answer crossed into permission route")
    }

    @MainActor static func main() async throws {
        var results: [[String: Any]] = []
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("exact and whitespace-wrapped approve cannot send, even with direct submit", {
                for text in ["approve", " approve ", "\tapprove\r\n", "\u{00A0}approve\u{3000}"] {
                    let harness = InteractionRequestSubmissionHarness(feedback: text)
                    try check(!harness.submitEnabled, "reserved feedback enabled: \(text.debugDescription)")
                    harness.send(accept: true)
                    try check(!harness.busy, "blocked input started submission")
                    // Directly call the actual submit function despite its disabled UI.
                    for _ in 0..<8 { await Task.yield() }
                    try check(harness.store.answers.isEmpty && harness.store.permissions.isEmpty,
                              "reserved feedback reached transport")
                    try check(harness.store.drafts[harness.draftKey] == "saved-feedback-draft",
                              "blocked feedback cleared the persisted draft")
                }
            }),
            ("case variants and longer words remain feedback", {
                for text in ["Approve", "APPROVE", "aPprove", "approved", "approve please", "approve\n请调整接口"] {
                    let harness = InteractionRequestSubmissionHarness(feedback: text)
                    try check(harness.submitEnabled, "ordinary feedback disabled: \(text)")
                    harness.send(accept: true)
                    try await expectAnswer(harness, text: text)
                }
            }),
            ("ordinary feedback is trimmed but otherwise preserved", {
                let harness = InteractionRequestSubmissionHarness(feedback: "  请先调整接口，再补测试。\n")
                try check(harness.submitEnabled, "specific feedback disabled")
                harness.send(accept: true)
                try await expectAnswer(harness, text: "请先调整接口，再补测试。")
                try check(harness.store.drafts[harness.draftKey] == "", "successful feedback did not clear draft")
            }),
            ("empty and whitespace-only input keep explicit approval semantics", {
                for text in ["", " \t\r\n", "\u{00A0}\u{3000}"] {
                    let harness = InteractionRequestSubmissionHarness(feedback: text)
                    try check(harness.submitEnabled, "empty explicit approval disabled")
                    harness.send(accept: true)
                    try await expectAnswer(harness, text: "approve")
                }
            }),
            ("decline always sends no answer, including reserved feedback", {
                for text in ["approve", "  approve\n", "", "请调整方案"] {
                    let harness = InteractionRequestSubmissionHarness(feedback: text)
                    harness.send(accept: false)
                    try await expectAnswer(harness, text: nil, decline: true)
                }
            }),
            ("non-plan free answers do not acquire the reserved-word restriction", {
                let harness = InteractionRequestSubmissionHarness(feedback: " approve ", toolName: "AskUserQuestion")
                try check(harness.submitEnabled, "ordinary question answer incorrectly blocked")
                harness.send(accept: true)
                try await expectAnswer(harness, text: "approve")
            }),
            ("permission approve and decline keep their original route", {
                for accept in [true, false] {
                    let harness = InteractionRequestSubmissionHarness(feedback: "approve", kind: "permission", toolName: "Shell")
                    try check(harness.submitEnabled, "permission action incorrectly disabled")
                    harness.send(accept: accept)
                    try await harness.settle()
                    try check(harness.store.permissions == [accept], "permission route changed")
                    try check(harness.store.answers.isEmpty, "permission sent a user-input answer")
                }
            }),
            ("queued submit uses the validated click-time feedback", {
                let harness = InteractionRequestSubmissionHarness(feedback: "请保留计划模式")
                harness.send(accept: true)
                // No suspension has occurred: the production Task has not started.
                harness.feedback = "approve"
                try await expectAnswer(harness, text: "请保留计划模式")
            })
        ]
        for (name, operation) in cases {
            let before = assertionCount
            do {
                try await operation()
                results.append(["name": name, "passed": true, "assertions": assertionCount - before])
                print("PASS \(name)")
            } catch {
                results.append(["name": name, "passed": false, "assertions": assertionCount - before,
                                "failure": String(describing: error)])
                print("FAIL \(name): \(error)")
            }
        }
        let failures = results.filter { $0["passed"] as? Bool == false }.count
        let report: [String: Any] = ["cases": results, "passed": results.count - failures,
                                    "failed": failures, "assertions": assertionCount]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("\(results.count - failures)/\(results.count) groups passed; \(assertionCount) assertions")
        if failures > 0 { exit(1) }
    }
}
