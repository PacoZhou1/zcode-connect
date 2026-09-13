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

/// Host-reported window usage. Breakdown percentages use the desktop's character
/// shares; category token counts are not exposed by the official protocol.
public struct RelayContextUsage: Sendable, Equatable {
    public struct Breakdown: Sendable, Equatable {
        public let source: String
        public let chars: Int
        public let percent: Double
    }
    public struct Compaction: Sendable, Equatable {
        public let id: String
        public let status: String
        public let origin: String
        public let tokensBefore: Int?
        public let tokensAfter: Int?
    }
    public let usedTokens: Int?
    public let maxTokens: Int?
    public let autoCompactThresholdTokens: Int?
    public let breakdown: [Breakdown]
    public let compacting: Bool
    public let latestCompaction: Compaction?
    public var available: Bool { usedTokens != nil && maxTokens != nil }
    public var usedPercent: Double? {
        guard let usedTokens, let maxTokens else { return nil }
        return min(100, max(0, Double(usedTokens) / Double(maxTokens) * 100))
    }

    public init(projection: RelayConversationProjection?, snapshot: RelaySessionSnapshot? = nil) {
        let window: RelayJSON
        // An explicit null is a current host observation, not permission to revive
        // older runtime counts (especially after compaction/model changes).
        if let value = projection?.raw["usage"].object?["contextWindow"] {
            window = value
        } else {
            let runtime = snapshot?.raw["runtime"]["contextUsage"] ?? .null
            window = .object(["usedTokens": runtime["used"], "maxTokens": runtime["size"], "breakdown": runtime["breakdown"]])
        }
        let used = Self.count(window["usedTokens"]), maximum = Self.count(window["maxTokens"])
        if let used, let maximum, maximum > 0 {
            usedTokens = used; maxTokens = maximum
            autoCompactThresholdTokens = Self.count(window["autoCompactThresholdTokens"])
            breakdown = Self.shares(window["breakdown"])
        } else {
            usedTokens = nil; maxTokens = nil; autoCompactThresholdTokens = nil; breakdown = []
        }
        if let projection {
            // Current work state wins over a historical running marker.
            compacting = projection.raw["control"]["activeWorks"].array?.contains { $0["kind"].string == "compact" } == true
            latestCompaction = projection.rows.filter { $0["kind"].string == "timelineMarker" && $0["marker"]["type"].string == "compact" }.sorted { ($0["rowId"].integer ?? -1) > ($1["rowId"].integer ?? -1) }.lazy.compactMap { row -> Compaction? in
                guard row["kind"].string == "timelineMarker", row["marker"]["type"].string == "compact", let rowID = row["rowId"].integer,
                      let status = row["marker"]["status"].string, ["running", "success", "failed", "noop", "cancelled"].contains(status),
                      let origin = row["marker"]["origin"].string, ["manual", "auto"].contains(origin) else { return nil }
                return .init(id: "compact:\(projection.sessionID):\(projection.logEpoch):\(rowID)", status: status, origin: origin,
                             tokensBefore: Self.count(row["marker"]["tokensBefore"]), tokensAfter: Self.count(row["marker"]["tokensAfter"]))
            }.first
        } else {
            compacting = snapshot?.raw["runtime"]["activeTurnKind"].string == "compact"
            latestCompaction = nil
        }
    }

    private static func count(_ value: RelayJSON) -> Int? { value.integer.flatMap { $0 >= 0 ? $0 : nil } }
    private static let sources = ["messages", "system_prompt", "meta_user_context", "skills", "tool_prompt", "system_tool_schemas", "mcp_tool_schemas"]
    private static func shares(_ value: RelayJSON) -> [Breakdown] {
        guard let items = value.array, items.count <= 1024 else { return [] }
        var totals: [String: Int] = [:]
        for item in items {
            guard let source = item["source"].string, sources.contains(source), let chars = count(item["chars"]) else { return [] }
            if chars > 0 {
                let (sum, overflow) = (totals[source] ?? 0).addingReportingOverflow(chars)
                guard !overflow else { return [] }; totals[source] = sum
            }
        }
        let total = totals.values.reduce(0.0) { $0 + Double($1) }
        guard total > 0, total.isFinite else { return [] }
        return totals.map { Breakdown(source: $0.key, chars: $0.value, percent: Double($0.value) / total * 100) }.sorted {
            if $0.chars != $1.chars { return $0.chars > $1.chars }
            return sources.firstIndex(of: $0.source)! < sources.firstIndex(of: $1.source)!
        }
    }

    public var wire: RelayJSON {
        var value: [String: RelayJSON] = ["available": .bool(available), "breakdownBasis": .string("characters"),
            "breakdown": .array(breakdown.map { .object(["source": .string($0.source), "chars": .int($0.chars), "percent": .number($0.percent)]) })]
        if let usedTokens { value["usedTokens"] = .int(usedTokens) }
        if let maxTokens { value["maxTokens"] = .int(maxTokens) }
        if let usedPercent { value["usedPercent"] = .number(usedPercent) }
        if let autoCompactThresholdTokens { value["autoCompactThresholdTokens"] = .int(autoCompactThresholdTokens) }
        var compact: [String: RelayJSON] = ["active": .bool(compacting)]
        if let latest = latestCompaction {
            var marker: [String: RelayJSON] = ["id": .string(latest.id), "status": .string(latest.status), "origin": .string(latest.origin)]
            if let before = latest.tokensBefore { marker["tokensBefore"] = .int(before) }
            if let after = latest.tokensAfter { marker["tokensAfter"] = .int(after) }
            compact["latest"] = .object(marker)
        }
        value["compaction"] = .object(compact)
        return .object(value)
    }
}
