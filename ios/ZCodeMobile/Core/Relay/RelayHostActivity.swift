import Foundation

/// Presence comes from the desktop projection. It is never created from a local draft.
public struct RelayHostGoal: Sendable, Equatable {
    public let raw: RelayJSON
    public let targetID: String
    public let objective: String
    public let summaryTitle: String?
    public let status: String
    public let timeUsedSeconds: Int
    public let activeRunStartedAtMs: Double?
    public let iteration: Int
    public let pauseAvailable: Bool
    public let resumeAvailable: Bool
    public let pauseUnavailableReason: String?
    public let resumeUnavailableReason: String?
    public let removeAvailable = false
    public var isActive: Bool { ["active", "verifying", "notSatisfied"].contains(status) }
    public var verifications: [RelayJSON] { raw["verifications"].array ?? [] }
    public var iterations: [RelayJSON] { raw["iterations"].array ?? [] }
    /// Same calculation as the public desktop UI. Use a host-adjusted time if clock skew is known.
    public func elapsedSeconds(atUnixMilliseconds now: Double) -> Int {
        guard isActive, let start = activeRunStartedAtMs, now.isFinite, start.isFinite else { return timeUsedSeconds }
        // Stay inside the protocol's exact integer range even for a corrupt/skewed clock.
        return timeUsedSeconds + Int(min(Double(9_007_199_254_740_991 - timeUsedSeconds), max(0, floor((now - start) / 1000))))
    }
    init?(projection: RelayJSON) {
        let goal = projection["goal"]
        guard goal.object != nil, let objective = goal["objective"].string, !objective.isEmpty,
              let status = goal["status"].string else { return nil }
        raw = goal; targetID = goal["targetId"].string ?? ""; self.objective = objective; self.status = status
        summaryTitle = goal["summaryTitle"].string; timeUsedSeconds = max(0, goal["timeUsedSeconds"].integer ?? 0)
        activeRunStartedAtMs = goal["activeRunStartedAtMs"].number; iteration = goal["iteration"].integer ?? 0
        pauseAvailable = projection["availability"]["pauseGoal"]["allowed"].bool == true
        resumeAvailable = projection["availability"]["resumeGoal"]["allowed"].bool == true
        pauseUnavailableReason = projection["availability"]["pauseGoal"]["reasonCode"].string
        resumeUnavailableReason = projection["availability"]["resumeGoal"]["reasonCode"].string
    }
}

public struct RelayHostAgent: Sendable, Equatable, Identifiable {
    public let childSessionID: String
    public let agentID: String?
    public let toolCallID: String?
    public let subagentType: String
    public let title: String
    public let summary: String?
    public let status: String
    public let startedAt: Double?
    public let endedAt: Double?
    public let raw: RelayJSON
    public var id: String { childSessionID }
    init?(_ raw: RelayJSON) {
        guard let id = raw["childSessionId"].string, !id.isEmpty else { return nil }
        self.raw = raw; childSessionID = id; agentID = raw["agentId"].string; toolCallID = raw["toolCallId"].string
        subagentType = raw["subagentType"].string ?? ""; title = raw["title"].string ?? ""
        summary = raw["summary"].string ?? raw["summaryText"].string; status = raw["status"].string ?? "unknown"; startedAt = raw["startedAt"].number
        endedAt = raw["endedAt"].number
    }
}

public struct RelayHostAgents: Sendable, Equatable {
    public let revision: Int
    public let childSessionIDs: [String]
    public let running: [RelayHostAgent]
    public let ended: [RelayHostAgent]
    public let endedTotal: Int
    public let nextEndedCursor: String?
    public let directoryError: String?
    /// A host record with no children and no live/history count does not activate an agent entry point.
    public var isVisible: Bool { !childSessionIDs.isEmpty || !running.isEmpty || endedTotal > 0 }
    public var runningCount: Int { running.count }
    init?(projection: RelayJSON) {
        let value = projection["subagents"]; guard value.object != nil else { return nil }
        revision = value["revision"].integer ?? 0; childSessionIDs = value["childSessionIds"].array?.compactMap(\.string) ?? []
        running = value["running"].array?.compactMap(RelayHostAgent.init) ?? []
        ended = value["ended"]["items"].array?.compactMap(RelayHostAgent.init) ?? []
        endedTotal = max(0, value["ended"]["total"].integer ?? value["endedTotal"].integer ?? 0)
        nextEndedCursor = value["ended"]["nextCursor"].string; directoryError = value["directoryError"].string
    }
}

/// This is the official parent-scoped directory, independent of the transcript row window.
public struct RelaySubagentDirectory: Sendable, Equatable {
    public let raw: RelayJSON
    public let revision: Int
    public let childSessionIDs: [String]
    public let running: [RelayHostAgent]
    public let ended: [RelayHostAgent]
    public let endedTotal: Int
    public let nextCursor: String?
    public init(raw: RelayJSON) throws {
        guard let revision = raw["revision"].integer, revision >= 0,
              let ids = raw["childSessionIds"].array, ids.count <= 10_000,
              let running = raw["running"].array, let ended = raw["ended"]["items"].array,
              let total = raw["ended"]["total"].integer, total >= ended.count,
              running.count <= 10_000, ended.count <= 10_000,
              ids.allSatisfy({ $0.string.map(RelayWire.validID) == true }),
              Set(ids.compactMap(\.string)).count == ids.count,
              (running + ended).allSatisfy({ $0["childSessionId"].string.map(RelayWire.validID) == true && $0["title"].string != nil && $0["status"].string != nil }),
              raw["ended"]["nextCursor"] == .null || (raw["ended"]["nextCursor"].string?.utf8.count ?? 0) > 0 && (raw["ended"]["nextCursor"].string?.utf8.count ?? 0) <= 8192 else {
            throw RelayFailure.invalid("The desktop returned an invalid subagent directory.")
        }
        self.raw = raw; self.revision = revision; childSessionIDs = ids.compactMap(\.string)
        self.running = running.compactMap(RelayHostAgent.init); self.ended = ended.compactMap(RelayHostAgent.init)
        endedTotal = total; nextCursor = raw["ended"]["nextCursor"].string
        let permitted = Set(childSessionIDs)
        guard (self.running + self.ended).allSatisfy({ permitted.contains($0.childSessionID) }) else { throw RelayFailure.invalid("The subagent directory contains an unlisted child.") }
    }
}

public extension RelayConversationProjection {
    var referencedSubagentIDs: Set<String> {
        Set((hostAgents?.childSessionIDs ?? []) + (hostAgents?.running.map(\.childSessionID) ?? []) + rows.filter { $0["kind"].string == "subagent" }.compactMap { $0["childSessionId"].string })
    }
    var hostGoal: RelayHostGoal? { .init(projection: raw) }
    var hostAgents: RelayHostAgents? { .init(projection: raw) }
    var showsHostGoal: Bool { hostGoal != nil }
    var showsHostAgents: Bool { hostAgents?.isVisible == true }
    /// Bash/background work is a different host collection, not a fabricated agent list.
    var backgroundWorks: [RelayJSON] { raw["backgroundWorks"].array ?? [] }
}
