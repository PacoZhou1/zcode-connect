import Foundation

/// Local cursor extension over the original host's complete task metadata arrays.
/// Frozen DTO snapshots avoid skipped/duplicated tasks when live sorting changes.
struct RelaySessionPages: Sendable {
    private struct Snapshot: Sendable {
        let id: String
        let at: TimeInterval
        let filters: RelayJSON
        let limit: Int
        let records: [RelayJSON]
        let total: Int
        let truncated: Bool
    }
    private var snapshots: [String: Snapshot] = [:]
    private var order: [String] = []

    mutating func page(records: [RelayJSON]? = nil, filters: RelayJSON, limit: Int, cursor: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> RelayJSON {
        guard (1...1000).contains(limit) else { throw RelayFailure.invalid("Task list limit must be from 1 to 1000.") }
        order.removeAll { id in
            guard let snapshot = snapshots[id], now - snapshot.at <= 300 else { snapshots.removeValue(forKey: id); return true }
            return false
        }
        let snapshot: Snapshot
        var offset = 0
        if let cursor {
            let pieces = cursor.split(separator: ".", omittingEmptySubsequences: false)
            guard cursor.utf8.count <= 128, pieces.count == 2, UUID(uuidString: String(pieces[0])) != nil, let position = Int(pieces[1]), position >= 0 else { throw RelayFailure.invalid("Invalid task-list cursor.") }
            guard let existing = snapshots[String(pieces[0])] else { throw RelayFailure("session_cursor_expired", "Reload the task list to obtain a current cursor.") }
            guard existing.filters == filters, existing.limit == limit else { throw RelayFailure("session_cursor_mismatch", "Restart the task list after changing its filters.") }
            guard position < existing.records.count else { throw RelayFailure.invalid("Task-list cursor is outside its snapshot.") }
            snapshot = existing; offset = position
        } else {
            guard let records else { throw RelayFailure.invalid("A new task-list snapshot needs host metadata.") }
            var retained: [RelayJSON] = [], bytes = 0
            for record in records {
                let size = try record.data().count
                guard retained.count < 5000, bytes + size <= 16 * 1024 * 1024 else { break }
                retained.append(record); bytes += size
            }
            while order.count >= 4 { snapshots.removeValue(forKey: order.removeFirst()) }
            snapshot = Snapshot(id: UUID().uuidString.lowercased(), at: now, filters: filters, limit: limit, records: retained, total: records.count, truncated: retained.count < records.count)
            snapshots[snapshot.id] = snapshot; order.append(snapshot.id)
        }
        let end = min(offset + limit, snapshot.records.count), hasMore = end < snapshot.records.count
        return .object(["sessions": .array(Array(snapshot.records[offset..<end])), "pagination": .object([
            "snapshotId": .string(snapshot.id), "total": .int(snapshot.total), "hasMore": .bool(hasMore),
            "nextCursor": hasMore ? .string(snapshot.id + "." + String(end)) : .null, "truncated": .bool(snapshot.truncated)
        ])])
    }
}
