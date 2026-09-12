import Foundation

protocol RemoteTransport: Sendable {
    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T
    func mutate<T: Decodable & Sendable>(_ path: String, method: String, body: [String: JSONValue], as type: T.Type) async throws -> T
    func events(after cursor: String?, onEvent: @Sendable (BridgeEnvelope) async -> Void) async throws
}

extension RemoteTransport {
    func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        try await get(path, as: T.self)
    }
    func mutate<T: Decodable & Sendable>(_ path: String, method: String = "POST", body: [String: JSONValue]) async throws -> T {
        try await mutate(path, method: method, body: body, as: T.self)
    }
    func post<T: Decodable & Sendable>(_ path: String, body: [String: String]) async throws -> T {
        try await mutate(path, method: "POST", body: body.mapValues(JSONValue.string), as: T.self)
    }
}

extension BridgeClient: RemoteTransport {}
