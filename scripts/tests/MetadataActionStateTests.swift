import Foundation

@main struct MetadataActionStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        TestTransport.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do {
            try await body()
            results.append(TestResult(name: name, passed: true, detail: "all assertions passed"))
            print("PASS \(name)")
        } catch {
            let detail = (error as? TestFailure)?.message ?? String(describing: error)
            results.append(TestResult(name: name, passed: false, detail: detail))
            print("FAIL \(name): \(detail)")
        }
    }
    @MainActor static func drainActor() async { for _ in 0..<100 { await Task.yield() } }

    @MainActor static func main() async throws {
        let actions: [(String, [String: JSONValue], @MainActor (AppStore) -> Void)] = [
            ("rename", ["title": .string("Intent captured on A")], { $0.rename("S", title: "Intent captured on A") }),
            ("togglePin", ["pinned": .bool(true)], { $0.togglePin("S") }),
            ("archive", ["archived": .bool(true)], { $0.archive("S") })
        ]
        for (name, expected, perform) in actions {
            await run("\(name) queued on A cannot start against same-ID B; fresh B action still works") {
                let f = Fixture(); defer { f.close() }
                var stateB = TestTransport.session(title: "B original").objectValue!
                stateB["pinned"] = .bool(false)
                stateB["archived"] = .bool(false)
                TestTransport.handler = { request in
                    if request.host == "b.invalid", request.path.hasPrefix("v1/sessions?") {
                        return .object(["sessions": .array([.object(stateB)])])
                    }
                    if request.method == "PATCH" {
                        var fields = request.host == "b.invalid" ? stateB : TestTransport.session().objectValue!
                        fields.merge(request.body) { _, new in new }
                        if request.host == "b.invalid" { stateB = fields }
                        return .object(["session": .object(fields)])
                    }
                    return nil
                }
                await f.connect()
                try check(f.store.session("S")?.source == "bridge", "A must be a remote metadata target")
                TestTransport.requests.removeAll()

                // Both calls begin on the same MainActor turn, without an intervening
                // yield. connect changes the epoch/client before its index await lets
                // the unstructured metadata Task run. No executor or production
                // private state is replaced by this test.
                perform(f.store)
                await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
                await drainActor()

                try check(f.store.activeProfileID == "B" && f.store.session("S") != nil, "Same-ID destination B was not loaded")
                let writes = TestTransport.requests.filter { $0.method == "PATCH" }
                let destinations = writes.map { "\($0.host) \($0.path) \($0.body)" }.joined(separator: "; ")
                try check(writes.isEmpty, "A menu intent was transmitted after host switch: \(destinations)")
                try check(f.store.session("S")?.title == "B original" && f.store.session("S")?.isPinned == false && f.store.session("S")?.isArchived == false, "Queued A action changed B state")
                try check(f.store.errorMessage == nil && f.store.toast == nil, "Discarded old action emitted an error or success toast")

                TestTransport.requests.removeAll()
                perform(f.store)
                await drainActor()
                let freshWrites = TestTransport.requests.filter { $0.method == "PATCH" }
                try check(freshWrites.count == 1 && freshWrites[0].host == "b.invalid" && freshWrites[0].body == expected, "Fresh current-host intent did not send exactly its requested metadata")
                switch name {
                case "rename": try check(f.store.session("S")?.title == "Intent captured on A", "Current-host rename ACK was not applied")
                case "togglePin": try check(f.store.session("S")?.isPinned == true, "Current-host pin ACK was not applied")
                default: try check(f.store.session("S")?.isArchived == true && f.store.toast == "已归档", "Current-host archive ACK was not applied")
                }
            }
        }
        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no network, Simulator, Keychain or service access")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
