import Foundation
import Security
import CryptoKit

struct BridgeFailure: LocalizedError {
    let message: String
    let code: String
    var errorDescription: String? { message }
}

enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let x = try? value.decode(Bool.self) { self = .bool(x) }
        else if let x = try? value.decode(String.self) { self = .string(x) }
        else if let x = try? value.decode(Double.self) { self = .number(x) }
        else if let x = try? value.decode([String: JSONValue].self) { self = .object(x) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .object(let x): try value.encode(x)
        case .null: try value.encodeNil()
        }
    }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var formatted: String {
        if case .string(let value) = self { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct RemoteModel: Identifiable, Decodable, Sendable, Hashable {
    var id: String { "\(providerId):\(modelId)" }
    var providerId: String
    var providerName: String
    var modelId: String
    var name: String
    var available: Bool
    var unavailableReason: String?
    var supportsImages: Bool
    var supportsPDF: Bool?
    var thoughtLevels: [String]
    var defaultThoughtLevel: String?
}

struct ModelSelection: Codable, Sendable, Hashable {
    var providerId: String
    var modelId: String
    var thoughtLevel: String?
    var json: JSONValue {
        var value: [String: JSONValue] = ["providerId": .string(providerId), "modelId": .string(modelId)]
        if let thoughtLevel { value["thoughtLevel"] = .string(thoughtLevel) }
        return .object(value)
    }
}

struct RemoteSettings: Decodable, Sendable {
    var sessionId: String
    var model: ModelSelection
    var mode: String
    var permissionMode: String?
    var thoughtLevels: [String]
    var modes: [String]
    var mutable: Bool
}

struct RemoteProjectSettings: Decodable, Sendable {
    var projectId: String
    var model: ModelSelection
    var mode: String
}

struct BridgeFile: Decodable, Sendable {
    var name: String
    var path: String
    var kind: String
    var size: Int
    var local: RemoteFile { RemoteFile(name: name, path: path, isDirectory: kind == "directory") }
}

struct BridgeFileListing: Decodable, Sendable {
    var files: [BridgeFile]
    var truncated: Bool?
    var searchComplete: Bool?
}

struct BridgeChanges: Decodable, Sendable {
    var files: [FileChange]
    var source: String?
    var truncated: Bool?
}

private struct BridgeErrorBody: Decodable {
    struct Detail: Decodable { var code: String; var message: String }
    var error: Detail
}

struct BridgeStatus: Decodable, Sendable {
    var hostName: String
    var connectionStatus: String
    var zcodeVersion: String?
    var cliVersion: String?
    var limitations: [String]?
}

struct BridgeSession: Decodable, Sendable {
    struct Capabilities: Decodable, Sendable {
        var read: Bool
        var send: Bool
        var stop: Bool
        var approve: Bool
        var changes: Bool
        var markUnread: Bool?
    }
    var id: String
    var title: String
    var projectId: String
    var projectName: String
    var status: String
    var updatedAt: String
    var source: String
    var capabilities: Capabilities
    var model: String?
    var thoughtLevel: String?
    var providerId: String?
    var pinned: Bool?
    var archived: Bool?
    var unread: Bool?
    var unreadAt: Double?
    var unreadScope: String?

    var local: RemoteSession {
        RemoteSession(id: id, title: title, projectID: projectId, projectName: projectName,
                      updatedAt: Date.fromBridge(updatedAt), status: SessionStatus(rawValue: status) ?? (status == "error" ? .failed : .idle),
                      isPinned: pinned ?? false, isArchived: archived ?? false,
                      canControl: capabilities.send, source: source, unread: unread, unreadAt: unreadAt, unreadScope: unreadScope, canMarkUnread: capabilities.markUnread)
    }
}

struct BridgeMessage: Decodable, Sendable {
    struct Tool: Decodable, Sendable {
        var id: String
        var name: String
        var status: String
        var output: String?
        var input: JSONValue?
    }
    var id: String
    var role: String
    var text: String
    var createdAt: String
    var isStreaming: Bool
    var toolCalls: [Tool]?
    var reasoning: String?
    var attachments: [MessageAttachment]?
    var local: ChatMessage {
        ChatMessage(id: id, role: ChatMessage.Role(rawValue: role) ?? .system,
                    text: text, createdAt: Date.fromBridge(createdAt),
                    steps: (toolCalls ?? []).map {
                        ToolStep(id: $0.id, title: $0.name,
                                 detail: [$0.input.map { "输入\n\($0.formatted)" }, $0.output.map { "输出\n\($0)" }].compactMap { $0 }.joined(separator: "\n\n"),
                                 status: ["running", "in_progress"].contains($0.status) ? .running :
                                    (["error", "failed", "rejected"].contains($0.status) ? .failed : .completed))
                    },
                    isStreaming: isStreaming, reasoning: reasoning, attachments: attachments ?? [])
    }
}

struct PendingInteraction: Identifiable, Decodable, Sendable {
    struct Question: Decodable, Sendable, Identifiable {
        struct Option: Decodable, Sendable, Identifiable {
            var id: String { value ?? label }
            var label: String
            var value: String?
            var description: String?
        }
        var id: String { question }
        var question: String
        var header: String?
        var options: [Option]?
        var multiSelect: Bool?
    }
    var id: String
    var sessionId: String
    var kind: String
    var title: String
    var reason: String?
    var toolName: String?
    var questions: [Question]?
    var input: JSONValue?
}

struct ConversationHistory: Decodable, Sendable, Equatable {
    var hasMore: Bool
    var beforeRowId: Int?
    var firstRowId: Int?
    var logEpoch: String
    var atSeq: Int
    var loadedRowCount: Int
    var totalRowCount: Int
}

struct BridgeHistoryPage: Decodable, Sendable {
    var messages: [BridgeMessage]
    var history: ConversationHistory
}

struct BridgeDetail: Decodable, Sendable {
    var session: BridgeSession
    var messages: [BridgeMessage]
    var pendingInteractions: [PendingInteraction]
    var hostActivity: JSONValue?
    var history: ConversationHistory? = nil
}

struct BridgeEnvelope: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        var message: BridgeMessage?
        var session: BridgeSession?
        var interaction: PendingInteraction?
        var interactionId: String?
        var connectionStatus: String?
        var hostActivity: JSONValue?
    }
    var id: String?
    var type: String
    var sessionId: String?
    var data: Payload?
}

struct BridgeClient: Sendable {
    let baseURL: URL
    let token: String
    private let session: URLSession
    private let transportDelegate: BridgeTransportDelegate

    init(baseURL: URL, token: String, certificateSHA256: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = BridgeTransportDelegate(origin: baseURL, certificateSHA256: certificateSHA256)
        transportDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func get<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try await request(path, method: "GET", body: nil, as: T.self)
    }

    func post<T: Decodable & Sendable>(_ path: String, body: [String: String], as: T.Type = T.self) async throws -> T {
        try await request(path, method: "POST", body: JSONEncoder().encode(body), as: T.self)
    }

    func mutate<T: Decodable & Sendable>(_ path: String, method: String = "POST", body: [String: JSONValue], as: T.Type = T.self) async throws -> T {
        try await request(path, method: method, body: JSONEncoder().encode(body), as: T.self)
    }

    func request<T: Decodable & Sendable>(_ path: String, method: String, body: Data?, as: T.Type) async throws -> T {
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var components = URLComponents(url: baseURL.appending(path: String(pieces[0])), resolvingAgainstBaseURL: false)!
        if pieces.count == 2 { components.percentEncodedQuery = String(pieces[1]) }
        guard let url = components.url else { throw BridgeFailure(message: "连接地址无效。", code: "invalid_url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request, delegate: transportDelegate)
        guard let response = response as? HTTPURLResponse else {
            throw BridgeFailure(message: "电脑没有返回可识别的响应。", code: "invalid_response")
        }
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? JSONDecoder().decode(BridgeErrorBody.self, from: data)
            let message: String
            switch response.statusCode {
            case 401: message = "连接密钥不正确或已失效，请重新连接。"
            case 409: message = failure?.error.code == "session_read_only"
                ? "这个任务由电脑上的 ZCode 管理，当前连接只能查看。"
                : "任务状态已改变，请刷新后重试。"
            case 503: message = "电脑上的 ZCode 尚未就绪，请检查后重试。"
            case 504: message = "电脑响应超时，请先确认任务状态再重试。"
            default: message = failure?.error.message ?? "连接失败（\(response.statusCode)）。"
            }
            throw BridgeFailure(message: message, code: failure?.error.code ?? "http_\(response.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func events(after cursor: String?, onEvent: @Sendable (BridgeEnvelope) async -> Void) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let cursor { request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID") }
        request.timeoutInterval = 60 * 60
        let (bytes, response) = try await session.bytes(for: request, delegate: transportDelegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BridgeFailure(message: "实时连接已断开。", code: "stream_failed")
        }
        var decoder = ServerSentEventsDecoder()
        for try await byte in bytes {
            if let record = try decoder.append(byte) {
                try Task.checkCancellation()
                guard let data = record.data.data(using: .utf8) else { continue }
                var event = try JSONDecoder().decode(BridgeEnvelope.self, from: data)
                if event.id == nil { event.id = record.id }
                await onEvent(event)
            }
        }
    }
}

final class BridgeTransportDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let certificateSHA256: String?
    init(origin: URL, certificateSHA256: String?) {
        self.origin = origin
        self.certificateSHA256 = certificateSHA256?.lowercased()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let pin = certificateSHA256 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.host.caseInsensitiveCompare(origin.host ?? "") == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == pin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // The scanned leaf is trusted only for this connection. SSL policy still verifies
        // its hostname and validity, and no global trust store or other connection changes.
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, origin.host as CFString?))
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Pairing credentials are scoped to one origin; the bridge does not need redirects.
        completionHandler(nil)
    }
}

extension Date {
    static func fromBridge(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
}

enum CredentialStore {
    private static let service = "dev.paco.zcode.mobile.connection"
    static func read(_ id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw BridgeFailure(message: "无法安全更新连接密钥。", code: "keychain_\(updated)")
        }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BridgeFailure(message: "无法安全保存连接密钥。", code: "keychain_\(status)")
        }
    }
    static func remove(_ id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: id] as CFDictionary)
    }
}
