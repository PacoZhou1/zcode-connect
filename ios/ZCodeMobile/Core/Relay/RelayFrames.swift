import Foundation
import CryptoKit

public struct RelayFrameIdentity: Codable, Sendable, Equatable {
    public let bridgeSessionId: String
    public let bridgeGeneration: Int?
    public let recoveryId: String?
    public init(bridgeSessionId: String, bridgeGeneration: Int? = nil, recoveryId: String? = nil) {
        self.bridgeSessionId = bridgeSessionId; self.bridgeGeneration = bridgeGeneration; self.recoveryId = recoveryId
    }
    func validate() throws {
        guard RelayWire.validID(bridgeSessionId), recoveryId.map(RelayWire.validID) ?? true,
              bridgeGeneration.map({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }) ?? true else { throw RelayFailure.invalid("Invalid bridge identity.") }
    }
    var fields: [String: RelayJSON] {
        var v: [String: RelayJSON] = ["bridgeSessionId": .string(bridgeSessionId)]
        if let bridgeGeneration { v["bridgeGeneration"] = .int(bridgeGeneration) }
        if let recoveryId { v["recoveryId"] = .string(recoveryId) }; return v
    }
    func matches(_ value: RelayJSON) -> Bool {
        value["bridgeSessionId"].string == bridgeSessionId && value["bridgeGeneration"].integer == bridgeGeneration && value["recoveryId"].string == recoveryId
    }
}

public struct RelayFrameReception: Sendable { public let message: Data?; public let acknowledgement: RelayJSON? }

/// One instance belongs to one bridge identity and direction pair; never reuse it for a new bridge.
public struct RelayFrameTransport: Sendable {
    public let identity: RelayFrameIdentity
    private var nextPhysical = 1, nextMessage = 1, expectedPhysical = 1, expectedMessage = 1
    private var failed = false
    private struct Batch: Sendable { let frames: [RelayJSON]; let bytes: Int; let created: TimeInterval }
    private var outbox: [Int: Batch] = [:]
    private var outboxBytes = 0
    private var seen: [Int: Data] = [:]
    private struct Assembly: Sendable {
        let created: TimeInterval; let count: Int; let size: Int; let checksum: String
        var chunks: [Data] = []; var bytes = 0
    }
    private var active: Assembly?

    public init(identity: RelayFrameIdentity) throws { try identity.validate(); self.identity = identity }

    public static func fragment(_ bytes: Data, identity: RelayFrameIdentity, firstSequence: Int = 1, messageSequence: Int = 1, chunkSize: Int = 512 * 1024) throws -> [RelayJSON] {
        try identity.validate()
        guard !bytes.isEmpty, bytes.count <= RelayWire.maxMessage, (1...(512 * 1024)).contains(chunkSize),
              firstSequence > 0, firstSequence < 9_007_199_254_740_927, messageSequence > 0, messageSequence < 9_007_199_254_740_991 else { throw RelayFailure.invalid("Invalid relay message bounds.") }
        let count = (bytes.count + chunkSize - 1) / chunkSize
        guard count <= 64 else { throw RelayFailure.invalid("Relay message requires too many fragments.") }
        let checksum: RelayJSON = .object(["algorithm": .string("crc32"), "value": .string(RelayChecksum.crc32(bytes))])
        return (0..<count).map { index in
            var v = identity.fields
            v.merge(["zcode_type": .string("rpc-frame"), "seq": .int(firstSequence + index), "messageSeq": .int(messageSequence), "fragmentIndex": .int(index), "fragmentCount": .int(count), "messageBytes": .int(bytes.count), "checksum": checksum,
                     "dataBase64": .string(bytes.subdata(in: (index * chunkSize)..<min((index + 1) * chunkSize, bytes.count)).base64EncodedString())]) { _, new in new }
            return .object(v)
        }
    }
    public mutating func enqueue(_ bytes: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> [RelayJSON] {
        try checkDeadline(now: now)
        let frames = try Self.fragment(bytes, identity: identity, firstSequence: nextPhysical, messageSequence: nextMessage)
        let cost = try frames.reduce(0) { try $0 + $1.data().count }
        guard outboxBytes + cost <= 8 * 1024 * 1024 else { throw RelayFailure("relay_outbox_full", "The unacknowledged relay buffer is full.", outcomeUncertain: true) }
        outbox[nextMessage] = Batch(frames: frames, bytes: cost, created: now); outboxBytes += cost
        nextPhysical += frames.count; nextMessage += 1; return frames
    }
    public func replayFrames(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> [RelayJSON] {
        try checkDeadline(now: now); return outbox.keys.sorted().flatMap { outbox[$0]!.frames }
    }
    public func checkDeadline(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard !failed else { throw RelayFailure.invalid("The relay transport is degraded.") }
        if let active, now - active.created > 30 { throw RelayFailure("relay_assembly_timeout", "An incomplete RPC message expired.") }
        if let oldest = outbox.values.map(\.created).min(), now - oldest > 45 { throw RelayFailure("relay_ack_timeout", "The relay did not acknowledge a message.", outcomeUncertain: true) }
    }
    public mutating func accept(_ frame: RelayJSON, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> RelayFrameReception {
        guard identity.matches(frame) else { return .init(message: nil, acknowledgement: nil) }
        do { return try acceptValidated(frame, now: now) }
        catch { failed = true; active = nil; outbox.removeAll(); outboxBytes = 0; throw error }
    }
    private mutating func acceptValidated(_ frame: RelayJSON, now: TimeInterval) throws -> RelayFrameReception {
        try checkDeadline(now: now)
        if frame["zcode_type"].string == "rpc-frame-ack" {
            let ack = try frame.requiringInt("ackMessageSeq", minimum: 1)
            guard ack < nextMessage else { throw RelayFailure.invalid("Acknowledgement references an unsent message.") }
            for key in outbox.keys.filter({ $0 <= ack }) { outboxBytes -= outbox.removeValue(forKey: key)!.bytes }
            return .init(message: nil, acknowledgement: nil)
        }
        guard frame["zcode_type"].string == "rpc-frame", try frame.data().count <= RelayWire.maxFrame else { throw RelayFailure.invalid("Invalid RPC frame type or size.") }
        let sequence = try frame.requiringInt("seq", minimum: 1), messageSequence = try frame.requiringInt("messageSeq", minimum: 1)
        let count = try frame.requiringInt("fragmentCount", minimum: 1, maximum: 64), index = try frame.requiringInt("fragmentIndex", maximum: count - 1)
        let size = try frame.requiringInt("messageBytes", minimum: 1, maximum: RelayWire.maxMessage), checksum = try frame["checksum"].requiringString("value")
        guard frame["checksum"]["algorithm"].string == "crc32", checksum.count == 8, checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RelayFailure.invalid("Invalid CRC metadata.") }
        let bytes = try RelayWire.base64(frame.requiringString("dataBase64"))
        guard !bytes.isEmpty, bytes.count <= size else { throw RelayFailure.invalid("Invalid fragment length.") }
        let fingerprint = Data(SHA256.hash(data: try frame.data()))
        if let previous = seen[sequence], previous != fingerprint { throw RelayFailure.invalid("Conflicting RPC replay.") }
        if sequence < expectedPhysical { return .init(message: nil, acknowledgement: expectedMessage > 1 ? ack(expectedMessage - 1) : nil) }
        guard sequence == expectedPhysical, messageSequence == expectedMessage, index == (active?.chunks.count ?? 0) else { throw RelayFailure.invalid("RPC sequence gap.") }
        if active == nil { active = Assembly(created: now, count: count, size: size, checksum: checksum) }
        guard var a = active, a.count == count, a.size == size, a.checksum == checksum, a.bytes + bytes.count <= size else { throw RelayFailure.invalid("Conflicting RPC fragment metadata.") }
        a.chunks.append(bytes); a.bytes += bytes.count; expectedPhysical += 1; seen[sequence] = fingerprint
        if a.chunks.count == a.count {
            let message = a.chunks.reduce(into: Data()) { $0.append($1) }
            guard message.count == size, RelayChecksum.crc32(message) == checksum else { throw RelayFailure.invalid("RPC checksum mismatch.") }
            active = nil; expectedMessage += 1
            for key in seen.keys.sorted().prefix(max(0, seen.count - 128)) { seen.removeValue(forKey: key) }
            return .init(message: message, acknowledgement: ack(messageSequence))
        }
        active = a; return .init(message: nil, acknowledgement: nil)
    }
    private func ack(_ sequence: Int) -> RelayJSON {
        var v = identity.fields; v["zcode_type"] = .string("rpc-frame-ack"); v["ackMessageSeq"] = .int(sequence); return .object(v)
    }
}
