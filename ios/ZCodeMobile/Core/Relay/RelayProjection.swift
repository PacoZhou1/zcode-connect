import Foundation

public struct RelayConversationProjection: Sendable, Equatable {
    public let raw: RelayJSON
    public var sessionID: String { raw["sessionId"].string! }
    public var logEpoch: String { raw["logEpoch"].string! }
    public var sequence: Int { raw["seq"].integer! }
    public var revision: Int { raw["revision"].integer! }
    public var rows: [RelayJSON] { raw["rows"]["window"].array ?? [] }
    public var title: String { raw["meta"]["title"].string ?? "" }
    public var config: RelayJSON { raw["config"] }
    public var canStop: Bool { raw["control"]["canStop"].bool ?? false }
    public var phase: String { raw["control"]["phase"].string ?? "unknown" }
    public var pendingInteractions: [RelayPendingInteraction] { (raw["pendingInteractions"].array ?? []).map { .init(raw: $0) } }
    public init(raw: RelayJSON) throws {
        guard raw["protocolVersion"].integer == 1 else { throw RelayFailure.invalid("Unsupported conversation projection version.") }
        _ = try raw.requiringString("sessionId"); _ = try raw.requiringString("logEpoch")
        _ = try raw.requiringInt("seq"); _ = try raw.requiringInt("revision")
        guard let rows = raw["rows"]["window"].array, rows.count <= 10_000 else { throw RelayFailure.invalid("Invalid projection row window.") }
        var ids = Set<Int>()
        for row in rows { let id = try row.requiringInt("rowId"); guard ids.insert(id).inserted else { throw RelayFailure.invalid("Duplicate projection row ID.") } }
        self.raw = raw
    }
}

/// Applies an entire validated logical frame atomically. A failed delta never changes the prior projection.
public struct RelayProjectionReducer: Sendable {
    public private(set) var projection: RelayConversationProjection?
    public init(projection: RelayConversationProjection? = nil) { self.projection = projection }

    /// Historical rows join the same reducer so later upserts, truncations and
    /// text deltas update them. An HTTP/UI page must not maintain a second copy.
    public mutating func prependRows(_ page: RelayJSON, beforeRowID: Int, expectedLogEpoch: String) throws {
        guard let current = projection, current.logEpoch == expectedLogEpoch,
              page["atLogEpoch"].string == current.logEpoch,
              current.rows.first?["rowId"].integer == beforeRowID else {
            throw RelayFailure("relay_history_changed", "The task history changed. Reload the task before requesting older messages.")
        }
        // A stale page could undo a row edit already delivered in the stream.
        guard page["atSeq"].integer == current.sequence else {
            throw RelayFailure("relay_history_changed", "The task advanced while loading history. Retry from its current history cursor.")
        }
        guard let older = page["rows"].array, older.count <= 200, let hasMore = page["hasMore"].bool,
              !older.isEmpty || !hasMore else { throw RelayFailure.invalid("Invalid historical row page.") }
        var previous = -1
        for row in older {
            let id = try row.requiringInt("rowId")
            guard id > previous, id < beforeRowID else { throw RelayFailure.invalid("Historical rows must precede the current window in ascending order.") }
            previous = id
        }
        if older.isEmpty, let first = current.raw["rows"]["firstRowId"].integer, beforeRowID > first {
            throw RelayFailure("relay_history_changed", "The desktop history cursor no longer matches its row range.")
        }
        guard older.count + current.rows.count <= 10_000 else { throw RelayFailure("relay_history_limit", "This task reached the local history limit of 10,000 rows.") }
        var raw = try current.raw.requiringObject(), rows = try current.raw["rows"].requiringObject()
        rows["window"] = .array(older + current.rows); raw["rows"] = .object(rows)
        let next = try RelayConversationProjection(raw: .object(raw))
        guard try next.raw.data().count <= RelayWire.maxMessage else { throw RelayFailure("relay_history_limit", "This task reached the local history limit of 16 MiB.") }
        projection = next
    }

    @discardableResult public mutating func apply(_ frame: RelayJSON, expectedSessionID: String) throws -> Bool {
        guard frame["topic"].string == "conversation/\(expectedSessionID)" else { throw RelayFailure.invalid("Wrong conversation topic.") }
        let from = try frame.requiringInt("fromSeq"), to = try frame.requiringInt("toSeq")
        guard to >= from else { throw RelayFailure.invalid("Conversation sequence went backwards.") }
        let payload = frame["payload"]
        if payload["kind"].string == "snapshot" {
            var raw = try payload["snapshot"].requiringObject(); raw["seq"] = .int(to)
            let next = try RelayConversationProjection(raw: .object(raw))
            guard next.sessionID == expectedSessionID else { throw RelayFailure.invalid("Wrong snapshot session.") }
            if let current = projection, next.logEpoch == current.logEpoch, to < current.sequence { return false }
            projection = next; return true
        }
        guard payload["kind"].string == "deltas", let deltas = payload["deltas"].array, deltas.count <= 10_000 else { throw RelayFailure.invalid("Invalid conversation delta.") }
        guard let current = projection else { throw RelayFailure("relay_projection_gap", "A snapshot is required before deltas.") }
        if to <= current.sequence { return false }
        // The official store uses fromSeq == current.seq, not current.seq + 1.
        guard from == current.sequence else { throw RelayFailure("relay_projection_gap", "The conversation needs a fresh snapshot.") }
        var raw = try current.raw.requiringObject(), rowsObject = try current.raw["rows"].requiringObject(), rows = current.rows
        for delta in deltas {
            switch delta["op"].string {
            case "row.appended":
                let row = delta["row"], id = try row.requiringInt("rowId")
                guard rows.count < 10_000, !rows.contains(where: { $0["rowId"].integer == id }) else { throw RelayFailure.invalid("Duplicate or excessive conversation rows.") }
                rows.append(row); rowsObject["totalCount"] = .int((rowsObject["totalCount"]?.integer ?? rows.count - 1) + 1)
                if rowsObject["firstRowId"] == nil || rowsObject["firstRowId"] == .null { rowsObject["firstRowId"] = .int(id) }
            case "row.upserted":
                let row = delta["row"], id = try row.requiringInt("rowId")
                if let index = rows.firstIndex(where: { $0["rowId"].integer == id }) { rows[index] = row }
            case "row.removed":
                let first = try delta.requiringInt("fromRowId"), before = rows.count
                rows.removeAll { ($0["rowId"].integer ?? Int.max) >= first }
                let cleared = rowsObject["firstRowId"]?.integer.map { first <= $0 } ?? false
                rowsObject["totalCount"] = .int(cleared ? 0 : max(0, (rowsObject["totalCount"]?.integer ?? before) - (before - rows.count)))
                if cleared { rowsObject["firstRowId"] = .null }
            case "row.delta":
                let id = try delta.requiringInt("rowId"), path = try delta.requiringString("path")
                guard let append = delta["append"].string, append.utf8.count <= RelayWire.maxMessage else { throw RelayFailure.invalid("Invalid row append.") }
                guard ["text", "inputText", "output.text", "summaryText"].contains(path) else { throw RelayFailure.invalid("Unsupported row delta path.") }
                if let index = rows.firstIndex(where: { $0["rowId"].integer == id }) {
                    var row = try rows[index].requiringObject(); let kind = row["kind"]?.string
                    if path == "text", kind == "assistantText" || kind == "reasoning" { row[path] = .string((row[path]?.string ?? "") + append) }
                    if path == "inputText", kind == "toolCall" { row[path] = .string((row[path]?.string ?? "") + append) }
                    if path == "summaryText", kind == "subagent" { row[path] = .string((row[path]?.string ?? "") + append) }
                    if path == "output.text", kind == "toolCall", var output = row["output"]?.object { output["text"] = .string((output["text"]?.string ?? "") + append); row["output"] = .object(output) }
                    rows[index] = .object(row)
                }
            case "state.updated":
                let patch = try delta["patch"].requiringObject()
                guard !patch.keys.contains(where: { ["sessionId", "logEpoch", "seq", "rows", "protocolVersion"].contains($0) }) else { throw RelayFailure.invalid("Invalid projection state patch.") }
                raw.merge(patch) { _, new in new }
            default: throw RelayFailure.invalid("Unsupported conversation delta operation.")
            }
        }
        rowsObject["window"] = .array(rows); raw["rows"] = .object(rowsObject); raw["seq"] = .int(to)
        let next = try RelayConversationProjection(raw: .object(raw))
        guard try next.raw.data().count <= RelayWire.maxMessage else { throw RelayFailure.invalid("Conversation projection exceeds 16 MiB.") }
        projection = next; return true
    }
}

/// The inner conversation wire uses version 3 and up to 1,024 fragments, independently of outer RPC framing.
public struct RelayConversationAssembler: Sendable {
    private struct Assembly: Sendable {
        let route: String, id: String, topic: String, subscription: String, delivery: String, checksum: String
        let ordinal: Int, count: Int, size: Int
        let started: TimeInterval
        var chunks: [Int: Data] = [:]
        var bytes = 0
    }
    private struct Settled: Sendable { let ordinal: Int; let id: String }
    private var assemblies: [String: Assembly] = [:]
    private var settled: [String: Settled] = [:]
    private var stagedBytes = 0
    public init() {}

    public mutating func accept(_ wire: RelayJSON, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> RelayJSON? {
        guard wire["wireVersion"].integer == 3 else { throw RelayFailure.invalid("Unsupported conversation wire version.") }
        let topic = try wire.requiringString("topic"), subscription = try wire.requiringString("subscriptionId"), id = try wire.requiringString("logicalFrameId")
        let ordinal = try wire.requiringInt("logicalFrameOrdinal", minimum: 1), delivery = try wire.requiringString("deliveryKind")
        guard topic.hasPrefix("conversation/"), topic.utf8.count <= 2048, subscription.utf8.count <= 1024, id.utf8.count <= 1024,
              ["initial", "online", "recovery"].contains(delivery), try wire.data().count <= RelayWire.maxFrame else { throw RelayFailure.invalid("Invalid conversation wire metadata.") }
        let route = topic + "\0" + subscription
        if let previous = settled[route] {
            if ordinal < previous.ordinal { return nil }
            if ordinal == previous.ordinal {
                guard id == previous.id else { throw RelayFailure.invalid("Conflicting logical frame ordinal.") }; return nil
            }
        }
        if wire["kind"].string == "complete" {
            let frame = wire["frame"]; try validate(frame, topic: topic, subscription: subscription)
            settle(route: route, id: id, ordinal: ordinal); return frame
        }
        guard wire["kind"].string == "fragment" else { throw RelayFailure.invalid("Unknown conversation wire kind.") }
        let count = try wire.requiringInt("fragmentCount", minimum: 1, maximum: 1024), index = try wire.requiringInt("fragmentIndex", maximum: count - 1)
        let size = try wire.requiringInt("logicalBytes", minimum: 1, maximum: RelayWire.maxMessage), checksum = try wire["checksum"].requiringString("value")
        guard count <= size, wire["checksum"]["algorithm"].string == "crc32", checksum.count == 8 else { throw RelayFailure.invalid("Invalid conversation checksum metadata.") }
        let bytes = try RelayWire.base64(wire.requiringString("dataBase64")), key = route + "\0" + id
        guard !bytes.isEmpty, bytes.count <= size else { throw RelayFailure.invalid("Invalid conversation fragment length.") }
        var a = assemblies[key] ?? Assembly(route: route, id: id, topic: topic, subscription: subscription, delivery: delivery, checksum: checksum, ordinal: ordinal, count: count, size: size, started: now)
        guard a.count == count, a.size == size, a.checksum == checksum, a.ordinal == ordinal, a.delivery == delivery, now - a.started <= 30 else { throw RelayFailure.invalid("Conversation fragment metadata changed or expired.") }
        if let previous = a.chunks[index] { guard previous == bytes else { throw RelayFailure.invalid("Conflicting conversation fragment replay.") }; return nil }
        guard (assemblies[key] != nil || assemblies.count < 32), stagedBytes + bytes.count <= 32 * 1024 * 1024, a.bytes + bytes.count <= size else { throw RelayFailure.invalid("Conversation assembly memory limit exceeded.") }
        a.chunks[index] = bytes; a.bytes += bytes.count; stagedBytes += bytes.count; assemblies[key] = a
        guard a.chunks.count == count else { return nil }
        var complete = Data(); complete.reserveCapacity(size)
        for index in 0..<count { guard let chunk = a.chunks[index] else { throw RelayFailure.invalid("Missing conversation fragment.") }; complete.append(chunk) }
        guard complete.count == size, RelayChecksum.crc32(complete) == checksum, String(data: complete, encoding: .utf8) != nil else { throw RelayFailure.invalid("Conversation checksum or UTF-8 mismatch.") }
        let frame = try RelayJSON(data: complete); try validate(frame, topic: topic, subscription: subscription)
        settle(route: route, id: id, ordinal: ordinal); return frame
    }
    private func validate(_ frame: RelayJSON, topic: String, subscription: String) throws {
        guard frame["topic"].string == topic, frame["subscriptionId"].string == subscription, frame["payload"].object != nil else { throw RelayFailure.invalid("Logical frame identity mismatch.") }
        _ = try frame.requiringInt("fromSeq"); _ = try frame.requiringInt("toSeq")
    }
    private mutating func settle(route: String, id: String, ordinal: Int) {
        settled[route] = Settled(ordinal: ordinal, id: id)
        for key in assemblies.keys.filter({ assemblies[$0]!.route == route && assemblies[$0]!.ordinal <= ordinal }) { stagedBytes -= assemblies.removeValue(forKey: key)!.bytes }
    }
    public mutating func discard(subscriptionID: String) {
        for key in assemblies.keys.filter({ assemblies[$0]!.subscription == subscriptionID }) { stagedBytes -= assemblies.removeValue(forKey: key)!.bytes }
        for key in settled.keys.filter({ $0.hasSuffix("\0" + subscriptionID) }) { settled.removeValue(forKey: key) }
    }
    public mutating func expire(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String] {
        var subscriptions = Set<String>()
        for key in assemblies.keys.filter({ now - assemblies[$0]!.started > 30 }) { let a = assemblies.removeValue(forKey: key)!; stagedBytes -= a.bytes; subscriptions.insert(a.subscription) }
        return Array(subscriptions)
    }
}
