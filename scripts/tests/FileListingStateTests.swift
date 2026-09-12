import Foundation

@main struct FileListingStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    static let profileB = ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid")
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        TestTransport.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do { try await body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    static func file(_ name: String, directory: Bool = false) -> JSONValue {
        .object(["name": .string(name), "path": .string(name), "kind": .string(directory ? "directory" : "file"), "size": .number(0)])
    }
    static func listing(_ name: String, truncated: Bool = false) -> JSONValue {
        .object(["files": .array([file(name)]), "truncated": .bool(truncated)])
    }
    enum Read: String, CaseIterable {
        case root, child, search, changes, content
        var path: String {
            switch self {
            case .root: "v1/projects/P/files?path="
            case .child: "v1/projects/P/files?path=folder"
            case .search: "v1/projects/P/files?search=needle"
            case .changes: "v1/sessions/S/changes"
            case .content: "v1/projects/P/file?path=notes.txt"
            }
        }
        func response(_ label: String) -> JSONValue {
            switch self {
            case .changes: .object(["files": .array([.object(["path": .string(label), "additions": .number(1), "deletions": .number(0), "diff": .string("+test")])])])
            case .content: .object(["content": .string(label)])
            default: FileListingStateTests.listing(label, truncated: true)
            }
        }
        @MainActor func read(_ store: AppStore) async throws -> String {
            switch self {
            case .root: return try await store.fileListing(projectID: "P").files.first?.name ?? "empty"
            case .child: return try await store.fileListing(projectID: "P", path: "folder").files.first?.name ?? "empty"
            case .search: return try await store.searchFiles(projectID: "P", query: "needle").files.first?.name ?? "empty"
            case .changes: return try await store.changeSummary("S").files.first?.path ?? "empty"
            case .content: return try await store.fileContent(projectID: "P", path: "notes.txt")
            }
        }
        @MainActor func outcome(_ store: AppStore) async -> String {
            do { return try await read(store) }
            catch is CancellationError { return "cancelled" }
            catch { return "error:\(error.localizedDescription)" }
        }
    }

    @MainActor static func main() async throws {
        await run("root listing retains truncated metadata and file mapping") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { request in request.path == Read.root.path ? .object(["files": .array([file("Folder", directory: true), file("notes.txt")]), "truncated": .bool(true)]) : nil }
            let result = try await f.store.fileListing(projectID: "P")
            try check(result.truncated && result.files.count == 2, "Root completeness or files were discarded")
            try check(result.files[0].isDirectory && !result.files[1].isDirectory, "Directory mapping changed")
        }
        await run("child path is escaped and incomplete search metadata survives an empty directory") {
            let f = Fixture(); defer { f.close() }; await f.connect(); TestTransport.requests = []
            TestTransport.handler = { _ in .object(["files": .array([]), "truncated": .bool(false), "searchComplete": .bool(false)]) }
            let result = try await f.store.fileListing(projectID: "P", path: "Folder &+#?")
            try check(result.files.isEmpty && result.truncated, "Empty partial child was mistaken for a complete empty folder")
            try check(TestTransport.requests.last?.path == "v1/projects/P/files?path=Folder%20%26%2B%23%3F", "Directory path changed query structure")
        }
        await run("empty truncated root remains distinct from an actually empty legacy response") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            TestTransport.handler = { _ in .object(["files": .array([]), "truncated": .bool(true)]) }
            let partial = try await f.store.fileListing(projectID: "P")
            TestTransport.handler = { _ in .object(["files": .array([])]) }
            let legacy = try await f.store.fileListing(projectID: "P")
            try check(partial.files.isEmpty && partial.truncated, "Empty partial root lost its flag")
            try check(legacy.files.isEmpty && !legacy.truncated, "Legacy no-flag response stopped decoding")
        }
        await run("remote filename search preserves query encoding and incomplete status") {
            let f = Fixture(); defer { f.close() }; await f.connect(); TestTransport.requests = []
            TestTransport.handler = { _ in .object(["files": .array([]), "truncated": .bool(true), "searchComplete": .bool(false)]) }
            let result = try await f.store.searchFiles(projectID: "P", query: "a &+#?")
            try check(result.files.isEmpty && result.truncated == true && result.searchComplete == false, "Search completeness disappeared")
            try check(TestTransport.requests.last?.path == "v1/projects/P/files?search=a%20%26%2B%23%3F", "Search query was not escaped")
        }
        for operation in Read.allCases {
            await run("late A \(operation.rawValue) response is cancelled after B replaces its connection") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                let gate = Gate(); defer { gate.release() }
                TestTransport.handler = { request in
                    guard request.path == operation.path else { return nil }
                    if request.host == "a.invalid" { await gate.hold(); return operation.response("A private result") }
                    return operation.response("B result")
                }
                let task = Task { await operation.outcome(f.store) }
                try await gate.waitUntilEntered()
                let before = f.store.fileListingGeneration
                await f.store.connect(profileB, token: "synthetic")
                gate.release()
                let outcome = await task.value
                try check(outcome == "cancelled", "Old host result escaped its read guard: \(outcome)")
                try check(before != f.store.fileListingGeneration && f.store.activeProfileID == "B", "File browser identity did not change")
                let fresh = try await operation.read(f.store)
                try check(fresh == "B result", "Fresh current-host read failed")
            }
        }
        await run("late old-host failure becomes cancellation instead of a current-host error") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let gate = Gate(); defer { gate.release() }
            TestTransport.handler = { request in
                if request.path == Read.root.path { await gate.hold(); throw BridgeFailure(message: "A read denied", code: "file_restricted") }
                return nil
            }
            let task = Task { await Read.root.outcome(f.store) }; try await gate.waitUntilEntered()
            await f.store.connect(profileB, token: "synthetic"); gate.release()
            let outcome = await task.value
            try check(outcome == "cancelled" && f.store.errorMessage == nil, "Old-host failure leaked into B")
        }
        await run("cancelled current-host request rejects a transport that still returns success") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let gate = Gate(); defer { gate.release() }
            TestTransport.handler = { request in
                if request.path == Read.child.path { await gate.hold(); return listing("late child") }; return nil
            }
            let task = Task { await Read.child.outcome(f.store) }; try await gate.waitUntilEntered()
            task.cancel(); gate.release()
            let outcome = await task.value
            try check(outcome == "cancelled", "Cancelled directory task returned data")
        }
        await run("same-host reconnect rejects an old read even though project and profile match") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let gate = Gate(); defer { gate.release() }
            TestTransport.handler = { request in
                if request.path == Read.root.path { await gate.hold(); return listing("old epoch") }; return nil
            }
            let task = Task { await Read.root.outcome(f.store) }; try await gate.waitUntilEntered()
            await f.store.connect(f.profile, token: "synthetic"); gate.release()
            let outcome = await task.value
            try check(outcome == "cancelled", "Same-host reconnect reused a stale result")
        }
        await run("reference listing retains its nested fixture without network I/O") {
            let f = Fixture(); defer { f.close() }; f.store.enterReferenceMode()
            let result = try await f.store.fileListing(projectID: "reference")
            try check(result.files == ReferenceData.files && !result.truncated && TestTransport.requests.isEmpty, "Reference nested file data changed")
        }
        await run("collapsed tree never asks for cached descendants; expansion visits only open branches") {
            let root = RemoteFile(name: "root", path: "root", isDirectory: true)
            let branch = RemoteFile(name: "branch", path: "root/branch", isDirectory: true)
            var reads: [String] = []
            let childLookup: (RemoteFile) -> [RemoteFile] = { file in reads.append(file.path); return file.path == "root" ? [branch] : [] }
            let closed = FileTreeProjection.rows(roots: [root], expanded: [], search: "", children: childLookup)
            try check(closed.map(\.id) == ["root"] && reads.isEmpty, "Collapsed nodes still traverse descendants")
            let open = FileTreeProjection.rows(roots: [root], expanded: ["root"], search: "", children: childLookup)
            try check(open.map(\.id) == ["root", "root/branch"] && reads == ["root"], "Closed grandchildren were visited")
        }
        await run("reference search keeps matching descendants and ancestors through folded folders") {
            let target = RemoteFile(name: "needle.swift", path: "r/b/needle.swift", isDirectory: false)
            let branch = RemoteFile(name: "branch", path: "r/b", isDirectory: true, children: [target])
            let root = RemoteFile(name: "root", path: "r", isDirectory: true, children: [RemoteFile(name: "noise", path: "r/noise", isDirectory: false), branch])
            let rows = FileTreeProjection.rows(roots: [root], expanded: [], search: "needle") { $0.children ?? [] }
            try check(rows.map(\.id) == ["r", "r/b", "r/b/needle.swift"] && rows.map(\.depth) == [0, 1, 2], "Search lost ancestors or kept unrelated leaves")
        }
        await run("duplicate or cyclic cached paths cannot recurse forever or create duplicate row IDs") {
            let root = RemoteFile(name: "root", path: "r", isDirectory: true)
            let rows = FileTreeProjection.rows(roots: [root, root], expanded: ["r"], search: "") { _ in [root] }
            try check(rows.map(\.id) == ["r"], "Cycle or duplicate row escaped identity deduplication")
        }
        await run("subagent browser identity keeps its parent project but prohibits the changes filter") {
            var child = FileBrowserIdentity(generation: UUID(), sessionID: "child", projectID: "parent-project", reference: false, online: true, sessionSource: "bridge-subagent")
            try check(!child.supportsChanges && child.projectID == "parent-project", "Subagent browsing exposed unsupported changes")
            child.sessionSource = "official-relay-subagent"
            try check(!child.supportsChanges, "Official child exposed unsupported changes")
            let previous = child; child.sessionSource = "official-relay"
            try check(child.supportsChanges && child != previous, "Source change did not invalidate the browser context")
        }
        var report: [String: Any] = ["cases": results.count, "passed": results.filter(\.passed).count, "failed": results.filter { !$0.passed }.count, "assertions": assertions]
        report["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; real AppStore and tree helper, no real network or Simulator")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
