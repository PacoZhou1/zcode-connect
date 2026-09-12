import Foundation

/// Official v3 row action identity. It is not a transcript index or a share link.
public struct RelayRowTarget: Codable, Sendable, Equatable {
    public let rowId: Int
    public let entityId: String
    public init(rowId: Int, entityId: String) throws {
        guard rowId >= 0, rowId <= 9_007_199_254_740_991, !entityId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entityId.utf8.count <= 4096 else { throw RelayFailure.invalid("Invalid host row target.") }
        self.rowId = rowId; self.entityId = entityId
    }
    public init(wire: RelayJSON) throws {
        let fields = try wire.requiringObject()
        guard Set(fields.keys) == ["rowId", "entityId"], let row = wire["rowId"].integer, let entity = wire["entityId"].string else { throw RelayFailure.invalid("A fork target needs the exact host rowId and entityId.") }
        try self.init(rowId: row, entityId: entity)
    }
    public var wire: RelayJSON { .object(["rowId": .int(rowId), "entityId": .string(entityId)]) }
}

public extension RelayConversationProjection {
    var forkTargets: [RelayRowTarget] {
        guard raw["availability"]["fork"]["allowed"].bool == true else { return [] }
        return rows.compactMap { row in
            guard row["kind"].string == "assistantText", row["state"].string == "complete", row["actions"]["canFork"].bool == true,
                  let id = row["rowId"].integer, let entity = row["entityId"].string else { return nil }
            return try? RelayRowTarget(rowId: id, entityId: entity)
        }.sorted { $0.rowId < $1.rowId }
    }
}
