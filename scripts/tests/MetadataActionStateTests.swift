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
        for (name, _, perform) in actions {
            await run("explicit metadata capability rejects \(name) without optimistic state or network") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                guard let index = f.store.sessions.firstIndex(where: { $0.id == "S" }) else { throw TestFailure(message: "missing fixture task") }
                f.store.sessions[index].canRename = false
                f.store.sessions[index].canPin = false
                f.store.sessions[index].canArchive = false
                let before = f.store.sessions[index]
                TestTransport.requests = []
                perform(f.store); await drainActor()
                try check(!TestTransport.requests.contains { $0.method == "PATCH" }, "unsupported action reached host")
                let after = f.store.session("S")!
                try check(after.title == before.title && after.isPinned == before.isPinned && after.isArchived == before.isArchived, "unsupported action changed visible state")
                try check(f.store.errorMessage != nil, "unsupported action did not explain refusal")
            }
        }
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
        let relayActions: [(String, Bool, Bool, [String: JSONValue], @MainActor (AppStore) -> Void)] = [
            ("rename", false, false, ["title": .string("Relay renamed")], { $0.rename("S", title: "Relay renamed") }),
            ("pin", false, false, ["pinned": .bool(true)], { $0.togglePin("S") }),
            ("archive", false, false, ["archived": .bool(true)], { $0.archive("S") }),
            ("restore", false, true, ["archived": .bool(false)], { $0.archive("S", archived: false) })
        ]
        for (name, pinned, archived, expected, perform) in relayActions {
            await run("official-relay \(name) waits for remote ACK and ignores stale local metadata") {
                let f = Fixture(); defer { f.close() }
                f.defaults.set(try JSONEncoder().encode(["S": "Stale local title"]), forKey: "A|https://a.invalid|titles")
                f.defaults.set(["S"], forKey: "A|https://a.invalid|pins")
                f.defaults.set(["S"], forKey: "A|https://a.invalid|archives")
                var fields = TestTransport.session(title: "Relay original").objectValue!
                fields["source"] = .string("official-relay")
                fields["pinned"] = .bool(pinned); fields["archived"] = .bool(archived)
                let original = JSONValue.object(fields)
                TestTransport.handler = { request in
                    request.path.hasPrefix("v1/sessions?") ? .object(["sessions": .array([original])]) : nil
                }
                await f.connect()
                try check(f.store.session("S")?.source == "official-relay" && f.store.session("S")?.title == "Relay original" && f.store.session("S")?.isPinned == pinned && f.store.session("S")?.isArchived == archived, "Local fallback metadata overrode host-authoritative data")
                let before = f.store.session("S")
                TestTransport.requests.removeAll()
                let gate = Gate(); defer { gate.release() }
                TestTransport.handler = { request in
                    guard request.method == "PATCH" else { return nil }
                    await gate.hold()
                    var updated = fields; updated.merge(request.body) { _, new in new }
                    return .object(["session": .object(updated)])
                }
                perform(f.store)
                try check(f.store.session("S") == before, "Relay metadata changed optimistically")
                try await gate.waitUntilEntered()
                try check(TestTransport.requests.first { $0.method == "PATCH" }?.body == expected, "Relay metadata did not send the expected remote mutation")
                try check(f.store.session("S") == before, "Relay metadata changed before its ACK")
                gate.release(); await drainActor()
                let current = f.store.session("S")
                try check(current?.title == (expected["title"]?.stringValue ?? "Relay original") && current?.isPinned == (name == "pin" ? true : pinned) && current?.isArchived == (name == "archive" ? true : name == "restore" ? false : archived), "Relay ACK was lost or overridden by local preferences")
            }
        }
        for (name, _, perform) in actions {
            await run("desktop read-only \(name) is rejected without changing host values or saved preferences") {
                let f = Fixture(); defer { f.close() }
                let titleKey = "A|https://a.invalid|titles", pinsKey = "A|https://a.invalid|pins", archivesKey = "A|https://a.invalid|archives"
                let oldTitles = try JSONEncoder().encode(["S": "Historical phone title"])
                f.defaults.set(oldTitles, forKey: titleKey)
                f.defaults.set(["S"], forKey: pinsKey); f.defaults.set(["S"], forKey: archivesKey)
                var fields = TestTransport.session(title: "Desktop host title").objectValue!
                fields["source"] = .string("desktop")
                fields["pinned"] = .bool(false); fields["archived"] = .bool(false)
                var capabilities = fields["capabilities"]!.objectValue!
                capabilities["send"] = .bool(false); fields["capabilities"] = .object(capabilities)
                let remote = JSONValue.object(fields)
                TestTransport.handler = { request in request.path.hasPrefix("v1/sessions?") ? .object(["sessions": .array([remote])]) : nil }
                await f.connect(); TestTransport.requests.removeAll()
                let before = f.store.session("S")
                try check(before?.title == "Desktop host title" && before?.isPinned == false && before?.isArchived == false, "Old phone preferences hid the desktop's real metadata")
                perform(f.store); await drainActor()
                try check(f.store.session("S") == before && TestTransport.requests.isEmpty, "Read-only action modified local state or sent a mutation")
                try check(f.store.errorMessage?.contains("远程连接") == true, "Read-only action did not explain the required official connection")
                try check(f.defaults.data(forKey: titleKey) == oldTitles && f.defaults.stringArray(forKey: pinsKey) == ["S"] && f.defaults.stringArray(forKey: archivesKey) == ["S"], "Read-only rejection rewrote or deleted historical preferences")
            }
        }
        await run("reference mode keeps rename pin archive and restore available without remote I/O") {
            let f = Fixture(); defer { f.close() }; f.store.enterReferenceMode()
            let id = ReferenceData.conversationID, oldPinned = f.store.session(ReferenceData.conversationID)!.isPinned
            f.store.rename(id, title: "Reference rename")
            try check(f.store.session(id)?.title == "Reference rename", "Reference rename was rejected")
            f.store.togglePin(id)
            try check(f.store.session(id)?.isPinned == !oldPinned, "Reference pin was rejected")
            f.store.archive(id)
            try check(f.store.session(id)?.isArchived == true, "Reference archive was rejected")
            f.store.archive(id, archived: false)
            try check(f.store.session(id)?.isArchived == false && TestTransport.requests.isEmpty && f.store.errorMessage == nil, "Reference restore failed or performed real I/O")
        }
        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no network, Simulator, Keychain or service access")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
