import Foundation

struct TranscriptTurn: Identifiable, Hashable {
    let id: String
    let messages: [ChatMessage]
    let userMessages: [ChatMessage]
    let processMessages: [ChatMessage]
    let resultMessages: [ChatMessage]
    let state: TranscriptMessageSemantics.State
    var isComplete: Bool { [.completed, .interrupted, .failed].contains(state) }
    var hasConfirmedResult: Bool { state == .completed && !resultMessages.isEmpty }
    var canCollapseProcess: Bool { isComplete && !processMessages.isEmpty }
    var defaultCollapsed: Bool { canCollapseProcess }
    var actionMessageID: String? { resultMessages.last { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.id }
}

enum TranscriptPresentation {
    /// No session status or array position can promote an intermediate message to final.
    static func group(_ messages: [ChatMessage]) -> [TranscriptTurn] {
        var order: [String] = [], buckets: [String: [ChatMessage]] = [:], current: String?
        // A guided input is appended into an already-running turn. It keeps its
        // chronological position as its own bubble, and the turn continues after it.
        var continuations: [String: String] = [:]
        for message in messages {
            let explicit = message.transcript?.turnID.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if let explicit, !explicit.isEmpty {
                let base = "turn:" + explicit
                if message.role == .user, buckets[base] != nil {
                    key = base + ":guided:" + message.id
                    let continuation = base + "#after:" + message.id
                    continuations[base] = continuation
                    order.append(key); buckets[key] = [message]; current = key
                    continue
                }
                key = continuations[base] ?? base
            }
            else if message.role == .user { key = "legacy:user:" + message.id }
            else { key = current ?? "legacy:message:" + message.id }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(message); current = key
        }
        return order.map { key in
            let values = buckets[key] ?? [], states = Set(values.compactMap { $0.transcript?.state })
            let state: TranscriptMessageSemantics.State = states.contains(.running) ? .running : states.contains(.failed) ? .failed : states.contains(.interrupted) ? .interrupted : states.contains(.completed) ? .completed : .unknown
            var users: [ChatMessage] = [], process: [ChatMessage] = [], results: [ChatMessage] = []
            for message in values {
                if message.role == .user { users.append(message); continue }
                let hasVisibleResult = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty || !message.changes.isEmpty
                let result = hasVisibleResult && state == .completed && message.transcript?.role == .finalAnswer && message.role == .assistant && !message.isStreaming && !message.steps.contains { $0.status == .running || $0.status == .waiting }
                guard result else { process.append(message); continue }
                if message.reasoning?.isEmpty == false || !message.steps.isEmpty {
                    var work = message; work.id = "transcript-process:" + message.id
                    work.text = ""; work.attachments = []; work.changes = []; work.forkTarget = nil; work.feedback = 0
                    work.transcript?.role = .process; process.append(work)
                }
                var answer = message; answer.reasoning = nil; answer.steps = []; answer.elapsed = nil
                results.append(answer)
            }
            return .init(id: key, messages: values, userMessages: users, processMessages: process, resultMessages: results, state: state)
        }
    }
}
