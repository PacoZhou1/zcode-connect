import Foundation
import Security

/// Only the official origin receives account credentials. Custom relays have a separate contract.
enum OfficialRelay {
    static let origin = URL(string: "https://zcode.z.ai")!
    static let serviceID = "wss://zcode.z.ai/api/v1/remote/ws2"
    static func failure(_ code: String) -> RelayFailure {
        let text: String
        switch code {
        case "account_login_required": text = L10n.tr("请先登录与电脑相同的账号。")
        case "account_expired": text = L10n.tr("登录已过期，请重新登录。")
        case "account_mismatch": text = L10n.tr("请切换到这台电脑所属的账号。")
        case "account_login_expired": text = L10n.tr("本次登录已过期，请重新开始。")
        case "account_login_failed": text = L10n.tr("登录未完成，请重试。")
        case "account_offline": text = L10n.tr("电脑尚未开启远程控制，请在电脑上登录同一账号并开启。")
        case "account_storage": text = L10n.tr("无法安全读取或保存登录，请解锁设备后重试。")
        case "account_network": text = L10n.tr("暂时无法连接登录服务，请检查网络后重试。")
        default: text = L10n.tr("服务返回了无法识别的连接信息，请稍后重试。")
        }
        return RelayFailure(code, text)
    }
}

enum RelayAccountProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case zai, bigmodel
    var id: String { rawValue }
    var title: String { self == .zai ? "Z.ai" : "BigModel" }
}

struct RelayAccountIdentity: Codable, Sendable, Equatable {
    let provider: RelayAccountProvider
    let userID: String
    let name: String
    var scope: String { provider.rawValue + ":" + userID }
}

struct RelayAccountSession: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identity: RelayAccountIdentity
    let jwt: String
    let expiresAt: Date?
    var isExpired: Bool { expiresAt.map { $0.timeIntervalSinceNow <= 15 } ?? false }
    var description: String { "RelayAccountSession(credential: redacted)" }
    var debugDescription: String { description }
}

struct RelayLoginFlow: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let provider: RelayAccountProvider
    let id: String
    let pollToken: String
    let authorizationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
    var description: String { "RelayLoginFlow(credential: redacted)" }
    var debugDescription: String { description }
}

struct RelayAccountDevice: Sendable, Identifiable, Equatable {
    let id: String
    let machineID: String
    let name: String
    let platform: String
    let version: String
    let online: Bool
    let createdAt: Date
    func pairingURL() -> String {
        var url = URLComponents(url: OfficialRelay.origin.appending(path: "remote/v4"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "sid", value: id), URLQueryItem(name: "mid", value: machineID),
                          URLQueryItem(name: "name", value: name), URLQueryItem(name: "app_version", value: version)]
        return url.url!.absoluteString
    }
}

struct RelayAccountComputer: Sendable, Identifiable {
    let id: String
    let connections: [RelayAccountDevice]
    var onlineConnections: [RelayAccountDevice] { connections.filter(\.online) }
    var name: String { (onlineConnections.first ?? connections.first)?.name ?? L10n.tr("我的电脑") }
    static func group(_ devices: [RelayAccountDevice]) -> [Self] {
        Dictionary(grouping: devices, by: \.machineID).map { key, value in
            Self(id: key, connections: value.sorted { $0.createdAt > $1.createdAt })
        }.sorted {
            if $0.onlineConnections.isEmpty != $1.onlineConnections.isEmpty { return !$0.onlineConnections.isEmpty }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct RelayHTTPReply: Sendable { let status: Int; let body: Data }
protocol RelayHTTPTransport: Sendable {
    func send(_ request: URLRequest, limit: Int) async throws -> RelayHTTPReply
}

final class RelayHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OfficialRelayHTTPTransport: RelayHTTPTransport {
    func send(_ request: URLRequest, limit: Int) async throws -> RelayHTTPReply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: RelayHTTPRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw OfficialRelay.failure("account_invalid_response") }
        guard response.expectedContentLength <= Int64(limit) else { throw OfficialRelay.failure("account_invalid_response") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw OfficialRelay.failure("account_invalid_response") }
            data.append(byte)
        }
        return .init(status: response.statusCode, body: data)
    }
}

/// Implements the official CLI's browser + polling authorization, without reading browser cookies
/// or desktop credentials, and without relying on an unregistered native callback domain.
struct OfficialRelayAPI: Sendable {
    let http: any RelayHTTPTransport
    init(http: any RelayHTTPTransport = OfficialRelayHTTPTransport()) { self.http = http }

    private func request(_ path: String, method: String = "GET", bearer: String, body: RelayJSON? = nil,
                         limit: Int = 65_536) async throws -> RelayJSON {
        guard path.hasPrefix("/api/v1/"), !path.contains("?"), !path.contains("#"),
              !bearer.isEmpty, !bearer.contains("\r"), !bearer.contains("\n") else {
            throw OfficialRelay.failure("account_invalid_response")
        }
        var request = URLRequest(url: OfficialRelay.origin.appending(path: String(path.dropFirst())))
        request.httpMethod = method; request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try body.data(); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: RelayHTTPReply
        do { response = try await http.send(request, limit: limit) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as RelayFailure { throw failure }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw OfficialRelay.failure("account_network")
        }
        try Task.checkCancellation()
        guard response.status != 401 else { throw OfficialRelay.failure("account_expired") }
        guard (200...299).contains(response.status), response.body.count <= limit else { throw OfficialRelay.failure("account_network") }
        guard let envelope = try? RelayJSON(data: response.body), let code = envelope["code"].integer else {
            throw OfficialRelay.failure("account_invalid_response")
        }
        guard code == 0 else { throw OfficialRelay.failure(code == 3004 ? "account_login_expired" : "account_invalid_response") }
        return envelope["data"]
    }

    func beginLogin(provider: RelayAccountProvider) async throws -> RelayLoginFlow {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OfficialRelay.failure("account_login_failed")
        }
        let pollToken = bytes.map { String(format: "%02x", $0) }.joined()
        let data = try await request("/api/v1/oauth/cli/init", method: "POST", bearer: pollToken,
                                     body: .object(["provider": .string(provider.rawValue)]))
        guard let id = data["flow_id"].string, validID(id),
              let raw = data["authorize_url"].string, raw.utf8.count <= 8192,
              let url = URLComponents(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil,
              let host = url.host, ["chat.z.ai", "zcode.z.ai", "bigmodel.cn", "open.bigmodel.cn"].contains(host),
              let authorizationURL = url.url,
              let expires = data["expires_at"].number, expires.isFinite,
              let interval = data["poll_interval_sec"].number, (1...30).contains(interval) else {
            throw OfficialRelay.failure("account_invalid_response")
        }
        let expiry = min(Date(timeIntervalSince1970: expires), Date().addingTimeInterval(300))
        guard expiry > Date() else { throw OfficialRelay.failure("account_login_expired") }
        return .init(provider: provider, id: id, pollToken: pollToken, authorizationURL: authorizationURL, expiresAt: expiry, interval: interval)
    }

    func poll(_ flow: RelayLoginFlow) async throws -> RelayAccountSession? {
        guard Date() < flow.expiresAt, validID(flow.id) else { throw OfficialRelay.failure("account_login_expired") }
        let data = try await request("/api/v1/oauth/cli/poll/" + flow.id, bearer: flow.pollToken)
        if data["status"].string == "pending" { return nil }
        guard data["status"].string == "ready" else { throw OfficialRelay.failure("account_login_failed") }
        guard let jwt = data["token"].string, !jwt.isEmpty, jwt.utf8.count <= 32_768,
              jwt.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let id = data["user"]["user_id"].string, !id.isEmpty, id.utf8.count <= 512,
              let providerAccess = data[flow.provider.rawValue]["access_token"].string ?? data[flow.provider.rawValue]["accessToken"].string,
              !providerAccess.isEmpty else {
            throw OfficialRelay.failure("account_invalid_response")
        }
        let name = data["user"]["name"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = RelayAccountIdentity(provider: flow.provider, userID: id,
                                            name: String((name?.isEmpty == false ? name! : flow.provider.title).prefix(200)))
        // Provider access/refresh tokens returned by CLI OAuth are unnecessary for remote control.
        // Discard them rather than persisting model access in the phone app.
        return .init(identity: identity, jwt: jwt, expiresAt: jwtExpiry(jwt))
    }

    func devices(session: RelayAccountSession) async throws -> [RelayAccountDevice] {
        guard !session.isExpired else { throw OfficialRelay.failure("account_expired") }
        let data = try await request("/api/v1/remote/device", bearer: session.jwt, limit: 1_048_576)
        guard let rows = data.array, rows.count <= 5000 else { throw OfficialRelay.failure("account_invalid_response") }
        var devices: [RelayAccountDevice] = []; var seen = Set<String>()
        for row in rows {
            guard let sid = row["device_sid"].string, Self.validDeviceID(sid), seen.insert(sid).inserted,
                  let mid = row["device_mid"].string, Self.validDeviceID(mid), let online = row["online"].bool,
                  let created = row["created_at"].integer, created >= 0,
                  let meta = row["meta"].object else { throw OfficialRelay.failure("account_invalid_response") }
            for key in ["name", "platform", "version"] where meta[key] != nil {
                guard meta[key]?.string != nil else { throw OfficialRelay.failure("account_invalid_response") }
            }
            let label = meta["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            devices.append(.init(id: sid, machineID: mid, name: String((label?.isEmpty == false ? label! : L10n.tr("我的电脑")).prefix(200)),
                                 platform: String((meta["platform"]?.string ?? "").prefix(100)), version: String((meta["version"]?.string ?? "unknown").prefix(100)), online: online,
                                 createdAt: Date(timeIntervalSince1970: Double(created))))
        }
        return devices.sorted { $0.online != $1.online ? $0.online : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func terminalToken(session: RelayAccountSession) async throws -> String {
        guard !session.isExpired else { throw OfficialRelay.failure("account_expired") }
        let data = try await request("/api/v1/remote/token", method: "POST", bearer: session.jwt,
                                     body: .object(["role": .string("terminal")]))
        guard let token = data["token"].string, Self.validOneTimeToken(token),
              let expires = data["expires_in"].integer, expires > 0 else { throw OfficialRelay.failure("account_invalid_response") }
        return token
    }

    static func validDeviceID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    static func validOneTimeToken(_ value: String) -> Bool {
        value.utf8.count == 22 && value.range(of: #"\A[A-Za-z0-9_-]{22}\z"#, options: .regularExpression) != nil
    }
    private func validID(_ value: String) -> Bool {
        (1...200).contains(value.utf8.count) && value.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
    }
    private func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: "."); guard parts.count == 3 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let bytes = Data(base64Encoded: text), let json = try? RelayJSON(data: bytes),
              let seconds = json["exp"].number, seconds.isFinite else { return nil }
        // This is only a local expiry hint. Authorization is always verified by the official server.
        return Date(timeIntervalSince1970: seconds)
    }
}
