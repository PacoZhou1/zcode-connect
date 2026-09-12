import Foundation
import CryptoKit

struct RelayAdapterCommandRecord: Codable, Sendable {
    let intentHash: String
    let envelope: RelayCommandEnvelope
    var context: RelayJSON?
    var attempted = false
    var acknowledgement: RelayCommandAck?
}

/// Caller-owned actor confinement; commits the file before changing the in-memory journal.
final class RelayAdapterJournal {
    struct State: Codable {
        var version = 1
        var commands: [String: RelayAdapterCommandRecord] = [:]
        var attachments: [String: RelayAttachment] = [:]
        var permissionModes: [String: String] = [:]
    }
    let url: URL
    private(set) var state: State
    init(scope: String, directory: URL?) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ZCodeRelay/Outbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = base.appending(path: relayDigest(Data(scope.utf8)) + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count <= 64 * 1024 * 1024 else { throw RelayFailure("relay_journal_too_large", "The saved relay outbox exceeds its size limit.") }
            state = try JSONDecoder().decode(State.self, from: data)
            guard state.version == 1 else { throw RelayFailure("relay_journal_version", "This relay outbox version is unsupported.") }
        } else { state = State() }
    }
    func commit(_ change: (inout State) -> Void) throws {
        var next = state; change(&next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(next)
        guard data.count <= 64 * 1024 * 1024 else { throw RelayFailure("relay_journal_full", "The relay outbox is full; its pending records have been preserved.") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var resource = url; var values = URLResourceValues(); values.isExcludedFromBackup = true; try resource.setResourceValues(values)
        state = next
    }
}

func relayDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func relayBridgeFailure(_ error: any Error) -> BridgeFailure {
    if let error = error as? BridgeFailure { return error }
    if let error = error as? RelayFailure { return .init(message: error.message, code: error.code) }
    if error is CancellationError { return .init(message: "操作已取消，原请求仍保留。", code: "cancelled") }
    return .init(message: "电脑连接或本地请求日志暂时不可用。", code: "relay_transport_error")
}
