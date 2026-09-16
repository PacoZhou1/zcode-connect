import Foundation

/// Keep a multi-call operation bound to its original workspace across actor suspension points.
public enum RelayWorkspaceOperation {
    @TaskLocal public static var expectedBridge: RelayBridge?
}

public struct RelayWorkspaceState: Sendable {
    public let raw: RelayJSON
    public var settings: RelayJSON { raw["settings"] }
    public var model: RelayJSON { settings["model"]["current"] }
    public var models: [RelayJSON] { settings["model"]["available"].array ?? [] }
    public var thoughtLevel: String? { settings["thoughtLevel"]["current"].string }
    public var mode: String? { settings["mode"]["current"].string }
    init(raw: RelayJSON) throws {
        _ = try raw["settings"]["model"]["current"].requiringString("providerId")
        _ = try raw["settings"]["model"]["current"].requiringString("modelId")
        guard raw["settings"]["model"]["available"].array != nil else { throw RelayFailure.invalid("The desktop omitted its model catalog.") }
        self.raw = raw
    }
}

public struct RelayWorkspaceFile: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let kind: String
    public let size: Int
    public var id: String { path }
}

public struct RelayWorkspaceFiles: Sendable {
    public let files: [RelayWorkspaceFile]
    public let truncated: Bool
    public let searchComplete: Bool
    public let scannedEntries: Int
}

public enum RelayWorkspacePath {
    public static func validate(_ path: String, allowEmpty: Bool = false) throws {
        guard path.utf8.count <= 2048, allowEmpty || !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !path.contains(":"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty || path.isEmpty }) else { throw RelayFailure("invalid_path", "Use a relative path within the selected project.") }
        let pattern = "^(?:id_(?:rsa|ed25519|ecdsa)|credentials(?:\\..*)?|secrets?(?:\\..*)?|pairing-token|.*\\.(?:pem|p12|pfx|key|keychain|sqlite(?:-shm|-wal)?|db(?:-shm|-wal)?))$"
        for part in path.split(separator: "/") {
            guard !part.hasPrefix("."), !["node_modules", "vendor", "DerivedData", "build", "Pods"].contains(String(part)), part.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil else { throw RelayFailure("file_restricted", "Hidden, credential, database, and generated paths are not exposed.") }
        }
    }
}

public extension RelayClient {
    func readWorkspaceState() async throws -> RelayWorkspaceState {
        try await RelayWorkspaceState(raw: rpc("zcode-session", "readWorkspaceState"))
    }
    func listModels() async throws -> [RelayJSON] { try await readWorkspaceState().models }

    /// Persist this envelope, submit it, persist the ACK/sessionId, then configure and read the empty task.
    /// No firstInput is allowed: the official create handler can silently retain defaults after a config error.
    func makeCreateSessionCommand(commandID: String) throws -> RelayCommandEnvelope {
        guard let bridge else { throw RelayFailure("relay_no_workspace", "Select a desktop workspace first.") }
        return .init(commandId: commandID, clientId: clientID, sessionId: nil, type: "createSession", payload: .object(["workspaceId": .string(bridge.workspaceKey)]))
    }
    func createSession(command: RelayCommandEnvelope, explicitUserAction: Bool) async throws -> RelayCommandAck {
        guard command.type == "createSession" else { throw RelayFailure.invalid("Expected a create-session command.") }
        let ack = try await submit(command, explicitUserAction: explicitUserAction)
        if ack.admitted, ack.result?["type"].string != "createSession" || ack.result?["sessionId"].string?.isEmpty != false { throw RelayFailure("relay_creation_uncertain", "Reconcile the original creation command before creating another task.", outcomeUncertain: true) }
        return ack
    }

    /// Original host setters resolve credentials; setMode may also persist the host project permission preference.
    func setSessionConfiguration(sessionID: String, model: RelayJSON? = nil, thoughtLevel: String? = nil, mode: String? = nil, explicitUserAction: Bool, confirmFullAccess: Bool = false, registerCreatedTask: Bool = false) async throws -> RelaySessionSnapshot {
        try RelayWire.requireAction(explicitUserAction)
        if let mode {
            guard ["build", "edit", "plan", "yolo"].contains(mode) else { throw RelayFailure("mode_unsupported", "This collaboration mode is not supported.") }
            if mode == "yolo", !confirmFullAccess { throw RelayFailure("full_access_confirmation_required", "Confirm full access for this request.") }
        }
        var snapshot = try await readSession(sessionID, messageLimit: 1)
        let changesModel = model.map { $0 != snapshot.model } ?? false
        let changesThought = thoughtLevel.map { $0 != snapshot.thoughtLevel } ?? false
        if changesModel || changesThought || registerCreatedTask {
            guard snapshot.activeTurnID == nil, !["running", "waiting"].contains(snapshot.status) else {
                throw RelayFailure("session_busy", "任务进行中，请结束当前轮次后更改模型或思考强度。批准方式可以随时调整。")
            }
        }
        if registerCreatedTask, model == nil { throw RelayFailure.invalid("Registering a newly created task requires its exact selected model.") }
        // The host session service's setModel path calls ensureSessionSubscription and syncSnapshotAndBroadcast.
        // A raw v4 create/read alone does not run the task service's index registration path.
        if let model, model != snapshot.model || registerCreatedTask {
            guard model.object.map({ Set($0.keys).isSubset(of: ["providerId", "modelId", "variant"]) }) == true,
                  try await listModels().contains(where: { $0["ref"] == model && $0["disabledReason"].string == nil }) else { throw RelayFailure("model_unavailable", "Choose an available model returned by this desktop.") }
            snapshot = try await RelaySessionSnapshot(raw: rpc("zcode-session", "setModel", ["sessionId": .string(sessionID), "model": model, "persistAsWorkspaceLastUsed": .bool(false)]))
        }
        if let thoughtLevel, thoughtLevel != snapshot.thoughtLevel {
            let levels = snapshot.raw["settings"]["thoughtLevel"]["available"].array?.compactMap { $0["value"].string ?? $0.string } ?? []
            guard levels.contains(thoughtLevel) else { throw RelayFailure("thought_level_unsupported", "The selected model does not offer this reasoning level.") }
            snapshot = try await RelaySessionSnapshot(raw: rpc("zcode-session", "setThoughtLevel", ["sessionId": .string(sessionID), "thoughtLevel": .string(thoughtLevel), "persistAsWorkspaceLastUsed": .bool(false)]))
        }
        if let mode, mode != snapshot.mode { snapshot = try await RelaySessionSnapshot(raw: rpc("zcode-session", "setMode", ["sessionId": .string(sessionID), "mode": .string(mode)])) }
        let verified = try await readSession(sessionID, messageLimit: 1)
        guard model.map({ $0 == verified.model }) ?? true, thoughtLevel.map({ $0 == verified.thoughtLevel }) ?? true, mode.map({ $0 == verified.mode }) ?? true else { throw RelayFailure("relay_configuration_not_applied", "The desktop did not apply the requested task settings. The task ID is preserved; do not recreate it.") }
        return verified
    }

    func directory(relativePath: String = "") async throws -> RelayWorkspaceFiles {
        let root = try fileRoot(); try await validateFileComponents(relativePath, root: root, directory: true)
        let entries = try await readDirectory(relativePath, root: root)
        let selected = Array(entries.prefix(500))
        let sized = try await sizeFiles(selected, root: root)
        return .init(files: sized, truncated: entries.count > selected.count, searchComplete: entries.count <= selected.count, scannedEntries: entries.count)
    }
    func searchFiles(_ query: String, limit: Int = 200) async throws -> RelayWorkspaceFiles {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 200, (1...200).contains(limit) else { throw RelayFailure.invalid("Search requires 1–200 characters and at most 200 results.") }
        let root = try fileRoot(), start = ProcessInfo.processInfo.systemUptime
        var queue = [""], index = 0, scanned = 0, matches: [RelayWorkspaceFile] = [], complete = true
        while index < queue.count {
            try Task.checkCancellation()
            if index >= 512 || scanned >= 50_000 || ProcessInfo.processInfo.systemUptime - start > 30 || matches.count >= limit { complete = false; break }
            let path = queue[index]; index += 1
            try await validateFileComponents(path, root: root, directory: true)
            for entry in try await readDirectory(path, root: root) {
                scanned += 1
                if scanned > 50_000 || matches.count >= limit { complete = false; break }
                if entry.kind == "directory" { queue.append(entry.path) }
                else if entry.path.localizedCaseInsensitiveContains(query) { matches.append(entry) }
            }
            if !complete { break }
        }
        let sized = try await sizeFiles(matches.sorted { $0.path < $1.path }, root: root)
        return .init(files: sized, truncated: !complete, searchComplete: complete, scannedEntries: scanned)
    }
    func readFile(relativePath: String) async throws -> RelayJSON {
        let root = try fileRoot(); try await validateFileComponents(relativePath, root: root, directory: false)
        let absolute = root + "/" + relativePath
        let stat = try await rpc("file", "stat", ["path": .string(absolute)])
        guard stat["type"].string == "file", let size = stat["size"].integer, (0...(512 * 1024)).contains(size) else { throw RelayFailure("file_too_large", "Text preview is limited to 512 KiB regular files.") }
        let file = try await rpc("file", "readTextFile", ["path": .string(absolute), "offset": .int(0), "length": .int(512 * 1024)])
        guard file["path"].string == absolute, file["isBinary"].bool == false, file["truncated"].bool == false, file["totalBytes"].integer == size, file["bytesRead"].integer == size,
              let content = file["content"].string, !content.contains("\0"), !content.contains("\u{FFFD}") else { throw RelayFailure("file_preview_unavailable", "The file is binary, changed during reading, or is not valid UTF-8 text.") }
        try await validateFileComponents(relativePath, root: root, directory: false)
        return .object(["path": .string(relativePath), "content": .string(content), "encoding": .string("utf-8"), "size": .int(size), "truncated": .bool(false)])
    }
    func workspaceChanges(source: String = "unstaged") async throws -> RelayJSON {
        guard ["unstaged", "staged"].contains(source) else { throw RelayFailure.invalid("Choose staged or unstaged changes.") }
        return try await rpc("git", "getChanges", ["sourceId": .string(source)])
    }
    func workspaceDiff(path: String, source: String = "unstaged") async throws -> RelayJSON {
        try RelayWorkspacePath.validate(path)
        guard ["unstaged", "staged"].contains(source) else { throw RelayFailure.invalid("Choose staged or unstaged changes.") }
        let root = try fileRoot()
        try await validateDiffComponents(path, root: root)
        let result = try await rpc("git", "getDiff", ["path": .string(path), "sourceId": .string(source)])
        try await validateDiffComponents(path, root: root)
        return result
    }
    func conversationFileChanges(sessionID: String, rowID: Int, entityID: String) async throws -> RelayJSON {
        guard rowID >= 0, !entityID.isEmpty, let projection = currentProjection(sessionID: sessionID) else { throw RelayFailure("projection_required", "Read the current conversation before requesting its file changes.") }
        return try await rpc("zcode-agent", "conversationFileChangesV4", ["sessionId": .string(sessionID), "target": .object(["rowId": .int(rowID), "entityId": .string(entityID)]), "baseRevision": .int(projection.revision), "baseLogEpoch": .string(projection.logEpoch)])
    }
}

private extension RelayClient {
    func validateDiffComponents(_ relative: String, root: String) async throws {
        let pieces = relative.split(separator: "/").map(String.init), parent = pieces.dropLast().joined(separator: "/")
        try await validateFileComponents(parent, root: root, directory: true)
        let absolute = parent.isEmpty ? root : root + "/" + parent
        let entries = try await rpc("file", "readdir", ["path": .string(absolute), "includeHidden": .bool(false)])
        guard let values = entries.array, values.count <= 50_000 else { throw RelayFailure.invalid("Invalid desktop directory response.") }
        if let entry = values.first(where: { $0["name"].string == pieces.last }) {
            guard entry["path"].string == root + "/" + relative, entry["isSymbolicLink"].bool == false, entry["type"].string == "file" else { throw RelayFailure("file_restricted", "A symbolic link or non-file diff is not exposed.") }
        }
        // A missing final component is a deleted tracked file; Git may still return its old text.
    }
    func fileRoot() throws -> String {
        guard let bridge else { throw RelayFailure.closed() }
        guard bridge.workspacePath.hasPrefix("/"), bridge.workspacePath != "/", !bridge.workspacePath.contains("\\") else { throw RelayFailure("relay_files_unsupported_root", "Native file browsing currently supports non-root POSIX workspace paths only.") }
        return bridge.workspacePath.hasSuffix("/") ? String(bridge.workspacePath.dropLast()) : bridge.workspacePath
    }
    func readDirectory(_ relative: String, root: String) async throws -> [RelayWorkspaceFile] {
        try RelayWorkspacePath.validate(relative, allowEmpty: true)
        let absolute = relative.isEmpty ? root : root + "/" + relative
        let value = try await rpc("file", "readdir", ["path": .string(absolute), "includeHidden": .bool(false)])
        guard let entries = value.array, entries.count <= 50_000 else { throw RelayFailure.invalid("The desktop directory response is too large.") }
        return entries.compactMap { item in
            guard let name = item["name"].string, !name.isEmpty, !name.contains("/"), item["path"].string == absolute + "/" + name, item["isSymbolicLink"].bool == false, let kind = item["type"].string, ["directory", "file"].contains(kind) else { return nil }
            let path = relative.isEmpty ? name : relative + "/" + name
            guard (try? RelayWorkspacePath.validate(path)) != nil else { return nil }
            return .init(name: name, path: path, kind: kind, size: 0)
        }.sorted { $0.kind == $1.kind ? $0.path < $1.path : $0.kind == "directory" }
    }
    func validateFileComponents(_ relative: String, root: String, directory: Bool) async throws {
        try RelayWorkspacePath.validate(relative, allowEmpty: directory)
        var parent = ""
        let components = relative.split(separator: "/").map(String.init)
        for (index, part) in components.enumerated() {
            guard let entry = try await readDirectory(parent, root: root).first(where: { $0.name == part }), entry.kind == (index < components.count - 1 || directory ? "directory" : "file") else { throw RelayFailure("file_restricted", "The path is missing, filtered, or contains a symbolic link.") }
            parent = entry.path
        }
    }
    func sizeFiles(_ entries: [RelayWorkspaceFile], root: String) async throws -> [RelayWorkspaceFile] {
        var result: [RelayWorkspaceFile] = []
        for offset in stride(from: 0, to: entries.count, by: 8) {
            let batch = Array(entries[offset..<min(offset + 8, entries.count)])
            result += try await withThrowingTaskGroup(of: RelayWorkspaceFile.self) { group in
                for entry in batch { group.addTask {
                    if entry.kind == "directory" { return entry }
                    let stat = try await self.rpc("file", "stat", ["path": .string(root + "/" + entry.path)])
                    guard stat["type"].string == "file", let size = stat["size"].integer, size >= 0 else { throw RelayFailure("file_changed", "A project file changed while listing it.") }
                    return .init(name: entry.name, path: entry.path, kind: entry.kind, size: size)
                } }
                var files: [RelayWorkspaceFile] = []; for try await file in group { files.append(file) }; return files
            }
        }
        return result.sorted { $0.kind == $1.kind ? $0.path < $1.path : $0.kind == "directory" }
    }
}
