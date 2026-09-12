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
    public let raw: RelayJSON
    public var id: String { childSessionID }
    init?(_ raw: RelayJSON) {
        guard let id = raw["childSessionId"].string, !id.isEmpty else { return nil }
        self.raw = raw; childSessionID = id; agentID = raw["agentId"].string; toolCallID = raw["toolCallId"].string
        subagentType = raw["subagentType"].string ?? ""; title = raw["title"].string ?? ""
        summary = raw["summary"].string; status = raw["status"].string ?? "unknown"; startedAt = raw["startedAt"].number
    }
}

public struct RelayHostAgents: Sendable, Equatable {
    public let revision: Int
    public let childSessionIDs: [String]
    public let running: [RelayHostAgent]
    public let endedTotal: Int
    /// A host record with no children and no live/history count does not activate an agent entry point.
    public var isVisible: Bool { !childSessionIDs.isEmpty || !running.isEmpty || endedTotal > 0 }
    public var runningCount: Int { running.count }
    init?(projection: RelayJSON) {
        let value = projection["subagents"]; guard value.object != nil else { return nil }
        revision = value["revision"].integer ?? 0; childSessionIDs = value["childSessionIds"].array?.compactMap(\.string) ?? []
        running = value["running"].array?.compactMap(RelayHostAgent.init) ?? []; endedTotal = max(0, value["endedTotal"].integer ?? 0)
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
