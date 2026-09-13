import Foundation
import CryptoKit

/// Standalone wire value; deliberately independent of the HTTP bridge's JSONValue.
public enum RelayJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([RelayJSON]), object([String: RelayJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([RelayJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: RelayJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> RelayJSON { object?[key] ?? .null }
    public var object: [String: RelayJSON]? { if case .object(let v) = self { v } else { nil } }
    public var array: [RelayJSON]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var integer: Int? {
        guard let v = number, v.isFinite, abs(v) <= 9_007_199_254_740_991, v.rounded(.towardZero) == v else { return nil }
        return Int(v)
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public init(data: Data) throws { self = try JSONDecoder().decode(Self.self, from: data) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: data()) }
    static func int(_ v: Int) -> Self { .number(Double(v)) }
    func requiringObject() throws -> [String: RelayJSON] {
        guard let v = object else { throw RelayFailure.invalid("Expected a JSON object.") }; return v
    }
    func requiringString(_ key: String) throws -> String {
        guard let v = self[key].string, !v.isEmpty else { throw RelayFailure.invalid("Missing \(key).") }; return v
    }
    func requiringInt(_ key: String, minimum: Int = 0, maximum: Int = 9_007_199_254_740_991) throws -> Int {
        guard let v = self[key].integer, v >= minimum, v <= maximum else { throw RelayFailure.invalid("Invalid \(key).") }; return v
    }
}

public struct RelayFailure: Error, LocalizedError, Sendable, Equatable {
    public let code: String
    public let message: String
    public let outcomeUncertain: Bool
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String, outcomeUncertain: Bool = false) {
        self.code = code; self.message = message; self.outcomeUncertain = outcomeUncertain
    }
    static func invalid(_ message: String) -> Self { .init("relay_invalid_frame", message) }
    static func closed() -> Self { .init("relay_disconnected", "The desktop relay is disconnected.", outcomeUncertain: true) }
    static func rejected(code: String?, paired: Bool) -> Self {
        if code == "KICKED" {
            return .init("controller_replaced", "另一台手机已接管连接，请关闭旧页面后重新连接。", outcomeUncertain: paired)
        }
        // Keep only a bounded protocol code, never server text that could echo
        // pairing material, URLs or other remote content into the interface.
        let safeCode = code.flatMap { value in
            value.range(of: #"\A[A-Z][A-Z0-9_]{0,63}\z"#, options: .regularExpression) != nil ? value : nil
        }
        let detail = safeCode.map { "（\($0)）" } ?? ""
        return .init("relay_rejected", "远程服务拒绝了连接\(detail)。请保留此错误代码以便排查。", outcomeUncertain: paired)
    }
}

/// Sensitive pairing material is never included in either printable description.
public struct RelayPairing: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let officialServiceID = "wss://zcode.z.ai/ws"
    public static let officialProfileURL = "https://zcode.z.ai/remote/v4"
    public let deviceID: String
    public let deviceName: String
    public let appVersion: String
    public let relayURL: URL
    /// Public service identity excludes pairing credentials and device routing queries.
    public let serviceID: String
    public let profileURL: URL
    public let isSelfHosted: Bool
    private let passHash: String
    public var description: String { "RelayPairing(credential: redacted)" }
    public var debugDescription: String { description }

    /// Plain URLs retain the original official-only contract.
    public init(scannedURL: String) throws {
        try self.init(pairingURL: scannedURL, customRelayURL: nil)
    }

    /// A custom service requires this explicit transport envelope; it cannot redirect
    /// an ordinary official QR or borrow the HTTP bridge's URL/token parser.
    public init(payload: String) throws {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first != "{" { try self.init(scannedURL: text); return }
        guard text.utf8.count <= 16_384, let data = text.data(using: .utf8),
              let object = try? RelayJSON(data: data).object,
              Set(object.keys) == Set(["transport", "url", "relayURL"]),
              object["transport"]?.string == "zcode-relay",
              let url = object["url"]?.string, let relayURL = object["relayURL"]?.string else {
            throw RelayFailure("relay_invalid_pairing", "自建 Relay 连接信息无效，请使用中转服务导出的完整连接信息。")
        }
        try self.init(pairingURL: url, customRelayURL: relayURL)
    }

    private init(pairingURL: String, customRelayURL: String?) throws {
        guard pairingURL.utf8.count <= 8192, var page = URLComponents(string: pairingURL),
              page.scheme == "https", let host = Self.canonicalHost(page.host),
              page.user == nil, page.password == nil, page.fragment == nil,
              Self.validPort(page.port) else {
            throw RelayFailure("relay_invalid_pairing", "连接信息必须包含有效的加密配对地址。")
        }
        let custom = customRelayURL != nil
        var relay: URLComponents
        if let customRelayURL {
            guard customRelayURL.utf8.count <= 2048, var endpoint = URLComponents(string: customRelayURL),
                  endpoint.scheme == "wss", let endpointHost = Self.canonicalHost(endpoint.host),
                  host != "zcode.z.ai", endpointHost != "zcode.z.ai", host == endpointHost,
                  (page.port ?? 443) == (endpoint.port ?? 443), Self.validPort(endpoint.port),
                  ["/zcode/remote/v4", "/zcode/remote/v4/"].contains(page.path), page.percentEncodedPath == page.path,
                  endpoint.path == "/zcode/ws", endpoint.percentEncodedPath == endpoint.path,
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
                throw RelayFailure("relay_invalid_pairing", "自建 Relay 的配对地址与加密中转必须属于同一服务，且不能转发官方配对凭据。")
            }
            endpoint.host = endpointHost; if endpoint.port == 443 { endpoint.port = nil }
            relay = endpoint
        } else {
            guard page.host == "zcode.z.ai", page.port == nil || page.port == 443,
                  ["/remote/v4", "/remote/v4/"].contains(page.path) else {
                throw RelayFailure("relay_invalid_pairing", "Scan an official ZCode Remote Control v4 QR.")
            }
            relay = URLComponents(string: Self.officialServiceID)!
        }
        let items = page.queryItems ?? []
        let fields = ["sid", "hash", "mid", "name", "app_version", "t"]
        for key in fields where items.filter({ $0.name == key }).count > 1 {
            throw RelayFailure("relay_invalid_pairing", "The pairing QR contains duplicate fields.")
        }
        if custom, items.contains(where: { !fields.contains($0.name) }) {
            throw RelayFailure("relay_invalid_pairing", "自建 Relay 配对地址包含不支持的字段。")
        }
        func field(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let sid = field("sid"), RelayWire.validID(sid), let hash = field("hash"),
              (32...512).contains(hash.utf8.count), hash.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw RelayFailure("relay_invalid_pairing", "The pairing QR is missing its credential.")
        }
        guard let serviceURL = relay.url else { throw RelayFailure.invalid("Invalid relay endpoint.") }
        serviceID = serviceURL.absoluteString
        if let mid = field("mid"), !mid.isEmpty {
            guard mid.utf8.count <= 512, mid.rangeOfCharacter(from: .controlCharacters) == nil else { throw RelayFailure.invalid("Invalid relay device routing ID.") }
            relay.queryItems = [URLQueryItem(name: "mid", value: mid)]
        }
        page.query = nil; page.host = host; if page.port == 443 { page.port = nil }
        if page.path.hasSuffix("/") { page.path.removeLast() }
        guard let publicURL = page.url, let endpoint = relay.url else { throw RelayFailure.invalid("Invalid relay endpoint.") }
        deviceID = sid; passHash = hash
        deviceName = String((field("name") ?? "ZCode Desktop").prefix(200))
        appVersion = String((field("app_version") ?? "unknown").prefix(100))
        relayURL = endpoint; profileURL = publicURL; isSelfHosted = custom
    }

    private static func canonicalHost(_ value: String?) -> String? {
        guard var host = value?.lowercased(), !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
    private static func validPort(_ value: Int?) -> Bool { value == nil || (1...65535).contains(value!) }

    /// Only old official profiles may omit the newly stored service identity.
    public static func legacyServiceID(profileURL: String) -> String? {
        guard let page = URLComponents(string: profileURL), page.scheme == "https", page.host == "zcode.z.ai",
              page.port == nil || page.port == 443, ["/remote/v4", "/remote/v4/"].contains(page.path),
              page.user == nil, page.password == nil, page.query == nil, page.fragment == nil else { return nil }
        return officialServiceID
    }

    public func challengeProof(nonce: String) throws -> String {
        guard !nonce.isEmpty, nonce.utf8.count <= 4096 else { throw RelayFailure.invalid("Invalid relay challenge.") }
        let value = HMAC<SHA256>.authenticationCode(for: Data("\(nonce)|terminal|\(deviceID)".utf8), using: SymmetricKey(data: Data(passHash.utf8)))
        return Data(value).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct RelayWorkspace: Codable, Sendable, Equatable, Identifiable {
    public let kind: String
    public let workspacePath: String
    public let workspaceIdentity: String?
    public let remoteSessionId: String?
    public let connectionState: String?
    public let lastConnectionError: String?
    public var id: String { workspaceIdentity?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? workspacePath }
    public var canAttach: Bool { kind != "remote" || workspaceIdentity?.nilIfEmpty != nil && remoteSessionId?.nilIfEmpty != nil }
}

public struct RelayTaskMetadata: Codable, Sendable, Equatable, Identifiable {
    public let taskId: String
    public let title: String
    public let workspacePath: String
    public let workspaceIdentity: String?
    public let createdAt: Double?
    public let updatedAt: Double?
    public let mode: String?
    /// Legacy task engine, not the model provider ID.
    public let provider: String?
    public let model: String?
    public let thoughtLevel: String?
    public let status: String?
    public let displayStatus: String?
    public let pinned: Bool?
    public let archived: Bool?
    /// Original host Unix milliseconds; preserve exactly for compare-and-clear.
    public let unreadAt: Double?
    public var id: String { taskId }
}

public struct RelayBootstrap: Decodable, Sendable {
    public let windowControlSessionId: String?
    public let workspaces: [RelayWorkspace]
    public let tasks: [RelayTaskMetadata]?
    public let initialViewState: RelayJSON?
    public let mobileViewState: RelayJSON?
    public let activeWorkspaceKey: String?
    public let activeTaskId: String?
}

public struct RelayBridge: Codable, Sendable, Equatable {
    public let bridgeSessionId: String
    public let bridgeGeneration: Int?
    public let recoveryId: String?
    public let kind: String
    public let workspaceKey: String
    public let workspacePath: String
    public let workspaceIdentity: String?
    public let remoteSessionId: String?
    public let initialTaskId: String?
    public var identity: RelayFrameIdentity { .init(bridgeSessionId: bridgeSessionId, bridgeGeneration: bridgeGeneration, recoveryId: recoveryId) }
    var scope: [String: RelayJSON] {
        var v: [String: RelayJSON] = ["workspacePath": .string(workspacePath)]
        if let workspaceIdentity { v["workspaceIdentity"] = .string(workspaceIdentity) }; return v
    }
}

public struct RelaySessionSnapshot: Sendable, Equatable {
    public let raw: RelayJSON
    public var sessionID: String { raw["session"]["sessionId"].string ?? "" }
    public var title: String { raw["session"]["title"].string ?? "" }
    public var status: String { raw["session"]["status"].string ?? "unknown" }
    public var model: RelayJSON { raw["settings"]["model"]["current"] }
    public var thoughtLevel: String? { raw["settings"]["thoughtLevel"]["current"].string }
    public var mode: String? { raw["settings"]["mode"]["current"].string }
    public var messages: [RelayJSON] { raw["messages"].array ?? [] }
    public var activeTurnID: String? { raw["runtime"]["activeTurnId"].string }
    public init(raw: RelayJSON) throws { _ = try raw["session"].requiringString("sessionId"); self.raw = raw }
    func supports(_ flag: String) -> Bool {
        let options = raw["settings"]["model"]["available"].array ?? []
        return options.first { $0["ref"] == model }?[flag].bool == true
    }
}

public struct RelayCommandEnvelope: Codable, Sendable, Equatable {
    public let commandId: String
    public let clientId: String
    public let sessionId: String?
    public let type: String
    public let payload: RelayJSON
    public let issuedAt: Double
    public let baseRevision: Int?
    public let baseLogEpoch: String?
    public init(commandId: String, clientId: String, sessionId: String?, type: String, payload: RelayJSON, baseRevision: Int? = nil, baseLogEpoch: String? = nil, issuedAt: Double = Date().timeIntervalSince1970 * 1000) {
        self.commandId = commandId; self.clientId = clientId; self.sessionId = sessionId; self.type = type; self.payload = payload
        self.baseRevision = baseRevision; self.baseLogEpoch = baseLogEpoch; self.issuedAt = issuedAt
    }
    public func json() throws -> RelayJSON {
        var value = try RelayJSON(data: JSONEncoder().encode(self)).requiringObject()
        // The official creation schema requires explicit null, not a missing sessionId.
        if sessionId == nil { value["sessionId"] = .null }; return .object(value)
    }
}

public struct RelayCommandAck: Codable, Sendable, Equatable {
    public let commandId: String
    public let status: String
    public let revisionAtDecision: Int
    public let reasonCode: String?
    public let message: String?
    public let result: RelayJSON?
    public var admitted: Bool { ["accepted", "noop", "duplicate"].contains(status) }
}

public struct RelayCommandKey: Codable, Sendable, Equatable {
    public let sessionId: String?
    public let commandId: String
    public init(sessionId: String?, commandId: String) { self.sessionId = sessionId; self.commandId = commandId }
}

public struct RelaySubscription: Codable, Sendable, Equatable {
    public let subscriptionId: String
    public let mode: String
    public let logEpoch: String
    public let openTiming: RelayJSON?
}

public struct RelayAttachment: Codable, Sendable, Equatable {
    public let sessionID: String
    public let ref: String
    public let fileName: String
    public let mime: String
    public let bytes: Int
    public let previewRef: String?
    public var wire: RelayJSON {
        var v: [String: RelayJSON] = ["ref": .string(ref), "fileName": .string(fileName), "mime": .string(mime), "bytes": .int(bytes)]
        if let previewRef { v["previewRef"] = .string(previewRef) }; return .object(v)
    }
}

public struct RelayPendingInteraction: Sendable, Equatable, Identifiable {
    public let raw: RelayJSON
    public var id: String { raw["interactionId"].string ?? "" }
    public var kind: String { raw["kind"].string ?? "unknown" }
    public var payload: RelayJSON { raw["payload"] }
    public var questions: [RelayJSON] { payload["questions"].array ?? [] }
    public var oneTimeOptions: [RelayJSON] {
        (payload["options"].array ?? []).filter { option in
            if kind != "permission" { return true }
            return ["allowOnce", "deny"].contains(option["kind"].string ?? "") && option["response"]["permissionUpdates"] == .null
        }
    }
}

public enum RelayInteractionAnswer: Sendable, Equatable {
    case option(String), questions([String: RelayJSON]), freeText(String), decline, cancel
    var wire: RelayJSON {
        switch self {
        case .option(let id): .object(["optionId": .string(id)])
        case .questions(let answers): .object(["action": .string("accept"), "content": .object(["answers": .object(answers)])])
        case .freeText(let text): .object(["action": .string("accept"), "content": .object(["answer": .string(text)])])
        case .decline: .object(["action": .string("decline")])
        case .cancel: .object(["action": .string("cancel")])
        }
    }
}

public enum RelayClientState: Sendable, Equatable { case idle, connecting, authenticating, waiting, paired, attached(RelayBridge), disconnected, replaced }
public enum RelayEvent: Sendable {
    case state(RelayClientState)
    case workspaces(RelayBootstrap)
    case projection(RelayConversationProjection)
    case command(RelayCommandAck)
    case commandUncertain(RelayCommandKey)
    case attachmentProgress(uploadID: String, sent: Int, total: Int)
    case resyncRequired(sessionID: String, reason: String)
    case failure(RelayFailure)
}

enum RelayWire {
    static let maxMessage = 16 * 1024 * 1024
    static let maxFrame = 1024 * 1024
    static func validID(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46, 95, 126, 45].contains($0) }
    }
    static func base64(_ text: String) throws -> Data {
        guard text.utf8.count <= maxMessage * 2, let data = Data(base64Encoded: text), data.base64EncodedString() == text else { throw RelayFailure.invalid("Noncanonical base64.") }; return data
    }
    static func requireAction(_ allowed: Bool) throws {
        guard allowed else { throw RelayFailure("explicit_action_required", "A desktop change requires an explicit user action.") }
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
