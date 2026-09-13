import Foundation

/// Explicit transcript evidence. A completed text segment alone is not a finished turn.
public struct TranscriptMessageSemantics: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case unknown, running, completed, interrupted, failed }
    public enum Role: String, Codable, Sendable { case unknown, input, process, finalAnswer }
    public var turnID: String
    public var state: State
    public var role: Role
    public init(turnID: String, state: State, role: Role) { self.turnID = turnID; self.state = state; self.role = role }
    enum CodingKeys: String, CodingKey { case turnID = "turnId", state, role }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try values.decode(String.self, forKey: .turnID)
        state = State(rawValue: try values.decodeIfPresent(String.self, forKey: .state) ?? "") ?? .unknown
        role = Role(rawValue: try values.decodeIfPresent(String.self, forKey: .role) ?? "") ?? .unknown
    }
    var wire: RelayJSON { .object(["turnId": .string(turnID), "state": .string(state.rawValue), "role": .string(role.rawValue)]) }
}

enum RelayTranscriptSemantics {
    static func rows(_ rows: [RelayJSON], sessionID: String) -> [Int: TranscriptMessageSemantics] {
        let byTurn = Dictionary(grouping: rows) { $0["productTurnId"].string ?? $0["turnId"].string ?? "" }
        var result: [Int: TranscriptMessageSemantics] = [:]
        for (turnID, values) in byTurn where !turnID.isEmpty && turnID != "turn-unknown" {
            let ordered = values.sorted { ($0["rowId"].integer ?? 0) < ($1["rowId"].integer ?? 0) }
            let header = ordered.last { $0["kind"].string == "turnHeader" }
            let work = ordered.filter { ["assistantText", "reasoning", "toolCall", "subagent"].contains($0["kind"].string ?? "") }
            var state: TranscriptMessageSemantics.State
            switch header?["state"].string {
            case "running": state = .running
            case "completedSuccess": state = .completed
            case "completedInterrupted": state = .interrupted
            case "failed": state = .failed
            default: state = .unknown
            }
            // canFork is materialized by the host only for a stable successful turn boundary.
            // It can preserve that evidence when paging has not loaded the earlier turn header.
            let boundary = work.last
            if state == .unknown, header == nil, boundary?["actions"]["canFork"].bool == true { state = .completed }
            let finalRow: Int? = state == .completed && boundary?["kind"].string == "assistantText" && boundary?["state"].string == "complete" && boundary?["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? boundary?["rowId"].integer : nil
            for row in ordered {
                guard let rowID = row["rowId"].integer else { continue }
                let role: TranscriptMessageSemantics.Role = row["kind"].string == "userInput" && row["origin"].string == "realUser" ? .input : rowID == finalRow ? .finalAnswer : .process
                result[rowID] = .init(turnID: "relay:\(sessionID):turn:\(turnID)", state: state, role: role)
            }
        }
        return result
    }

    /// A persisted product-turn boundary is stronger evidence than finish/last-position guesses.
    static func snapshot(_ rows: [RelayJSON], sessionID: String?) -> [String: TranscriptMessageSemantics] {
        var result: [String: TranscriptMessageSemantics] = [:]
        let byID = Dictionary(rows.compactMap { row -> (String, RelayJSON)? in
            (row["info"]["messageId"].string ?? row["info"]["id"].string).map { ($0, row) }
        }, uniquingKeysWith: { _, new in new })
        for row in rows {
            let info = row["info"], anchor = info["anchor"]
            guard info["role"].string == "assistant", let id = info["messageId"].string ?? info["id"].string,
                  let product = anchor["productTurnId"].string, !product.isEmpty,
                  anchor["boundaryMessageId"].string == id, let ordered = anchor["orderedMessageIds"].array?.compactMap(\.string),
                  ordered.last == id, Set(ordered).count == ordered.count, info["error"] == .null,
                  info["time"]["completed"].number != nil else { continue }
            let key = "snapshot:\(sessionID ?? info["sessionID"].string ?? "original"):turn:\(product)"
            for messageID in ordered {
                guard let original = byID[messageID] else { continue }
                let role: TranscriptMessageSemantics.Role = original["info"]["role"].string == "user" ? .input : messageID == id ? .finalAnswer : .process
                result[messageID] = .init(turnID: key, state: .completed, role: role)
            }
        }
        return result
    }
}
