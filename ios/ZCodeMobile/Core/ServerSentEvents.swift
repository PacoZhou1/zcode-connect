import Foundation

struct ServerSentEvent: Equatable, Sendable {
    var id: String?
    var event: String?
    var data: String
}

struct ServerSentEventsDecoder: Sendable {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventID: String?
    private var eventName: String?
    private var accumulatedBytes = 0
    private var previousWasCR = false
    private var isFirstLine = true
    static let maximumEventBytes = 4 * 1024 * 1024

    mutating func append(_ byte: UInt8) throws -> ServerSentEvent? {
        if previousWasCR {
            previousWasCR = false
            if byte == 10 { return nil }
        }
        if byte != 10 && byte != 13 {
            line.append(byte)
            guard retainedBytes + line.count <= Self.maximumEventBytes else {
                throw BridgeFailure(message: "实时消息过大，请重新载入会话。", code: "event_too_large")
            }
            return nil
        }
        previousWasCR = byte == 13
        guard String(data: line, encoding: .utf8) != nil else {
            throw BridgeFailure(message: "实时消息格式无效，请重新连接。", code: "event_invalid_utf8")
        }
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            defer {
                dataLines.removeAll(keepingCapacity: true)
                eventName = nil
                accumulatedBytes = 0
            }
            guard !dataLines.isEmpty else { return nil }
            return ServerSentEvent(id: eventID, event: eventName, data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data":
            dataLines.append(value)
            accumulatedBytes += value.utf8.count + 1
        case "event": eventName = value
        case "id": if !value.contains("\0") { eventID = value }
        default: break
        }
        guard retainedBytes <= Self.maximumEventBytes else {
            throw BridgeFailure(message: "实时消息过大，请重新载入会话。", code: "event_too_large")
        }
        return nil
    }

    private var retainedBytes: Int {
        accumulatedBytes + (eventID?.utf8.count ?? 0) + (eventName?.utf8.count ?? 0)
    }
}
