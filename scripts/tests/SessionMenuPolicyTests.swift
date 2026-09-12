import Foundation

@main struct SessionMenuPolicyTests {
    struct Failure: Error { let message: String }
    struct Result: Codable { let name: String; let passed: Bool; let detail: String }
    @MainActor static var results: [Result] = []
    @MainActor static var assertions = 0
    static let all: [SessionMenuActionID] = [.pin, .rename, .unread, .copyID, .archive]

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? Failure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    static func session(source: String = "bridge", archived: Bool = false, send: Bool = true,
                        capabilities: [String: Bool] = [:]) throws -> RemoteSession {
        let required = ["read": true, "send": send, "stop": false, "approve": false, "changes": true]
        let wire: [String: Any] = ["id": "S", "title": "Task", "projectId": "P", "projectName": "Project",
            "status": "idle", "updatedAt": "2026-09-13T02:00:00Z", "source": source, "archived": archived,
            "capabilities": required.merging(capabilities) { _, new in new }]
        return try JSONDecoder().decode(BridgeSession.self, from: JSONSerialization.data(withJSONObject: wire)).local
    }
    static func items(_ session: RemoteSession, reference: Bool = false, relay: Bool = false,
                      online: Bool = true, unread: Bool = false) -> [SessionMenuItem] {
        SessionMenuPolicy.items(for: session, isReferenceMode: reference, isRelay: relay, isOnline: online, isUnread: unread)
    }
    @MainActor static func main() throws {
        run("legacy owned payload keeps all actions when metadata flags are absent") {
            let value = try session()
            try check(value.canRename == nil && value.canPin == nil && value.canArchive == nil, "Absent optional capabilities did not stay nil")
            try check(items(value).map(\.id) == all, "Legacy owned actions were disabled by missing flags")
            try check(items(value).allSatisfy(\.isEnabled), "Online legacy metadata became disabled")
        }
        run("explicit metadata flags survive production decoding and filter each action") {
            let value = try session(capabilities: ["rename": false, "pin": true, "archive": false, "markUnread": true])
            try check(value.canRename == false && value.canPin == true && value.canArchive == false, "Production DTO lost metadata flags")
            try check(items(value).map(\.id) == [.pin, .unread, .copyID], "Explicit false metadata remained actionable")
            try check(items(value).first(where: { $0.id == .unread })?.title == "标记为未读", "Host-synced unread was labeled local")
        }
        run("desktop mirror exposes only local unread and copy for both unread states") {
            let value = try session(source: "desktop", send: false, capabilities: ["markUnread": false])
            for unread in [false, true] {
                let result = items(value, unread: unread)
                try check(result.map(\.id) == [.unread, .copyID], "Desktop mirror exposed host metadata mutation")
                try check(result.first?.title == (unread ? "标记为已读（仅此手机）" : "标记为未读（仅此手机）"), "Local unread scope was hidden")
                try check(result.allSatisfy(\.isEnabled), "Local actions were unusable")
            }
        }
        run("HTTP and Relay subagents remain read-only even with inconsistent metadata flags") {
            for source in ["bridge-subagent", "official-relay-subagent", "desktop", "unknown"] {
                let value = try session(source: source, send: false, capabilities: ["rename": true, "pin": true, "archive": true, "markUnread": false])
                let result = items(value, relay: source.hasPrefix("official-relay"))
                try check(result.map(\.id) == [.unread, .copyID], "A non-owned source inherited metadata write actions")
                try check(result.first?.title.contains("仅此手机") == true, "Explicit false unread was overridden by Relay fallback")
            }
        }
        run("official Relay metadata is available while explicitly unsupported providers are filtered") {
            let supported = try session(source: "official-relay", capabilities: ["rename": true, "pin": true, "archive": true, "markUnread": true])
            try check(items(supported, relay: true).map(\.id) == all, "Official Relay lost supported metadata")
            let unsupported = try session(source: "official-relay", send: false, capabilities: ["rename": false, "pin": false, "archive": false, "markUnread": false])
            try check(items(unsupported, relay: true).map(\.id) == [.unread, .copyID], "Explicit false Relay flags were ignored")
            try check(items(unsupported, relay: true).first?.title.contains("仅此手机") == true, "Readonly Relay unread was presented as remote")
        }
        run("archived owned and Relay sessions preserve restore independently of send") {
            for source in ["bridge", "official-relay"] {
                let value = try session(source: source, archived: true, send: false, capabilities: ["rename": true, "pin": true, "archive": true, "markUnread": true])
                let result = items(value, relay: source == "official-relay")
                try check(!value.canControl && result.map(\.id) == all, "Send capability incorrectly removed metadata or restore")
                let restore = result.first { $0.id == .archive }
                try check(restore?.title == "取消归档" && restore?.isEnabled == true && restore?.destructive == false, "Archived task cannot restore or has wrong role")
            }
        }
        run("offline remote actions are disabled while local unread and copy remain available") {
            let remote = try session(capabilities: ["markUnread": true])
            let remoteItems = items(remote, online: false)
            try check(remoteItems.map(\.id) == all, "Offline temporarily erased supported capabilities")
            try check(remoteItems.filter(\.isEnabled).map(\.id) == [.copyID], "Offline remote action remained enabled")
            let local = try session(source: "desktop", send: false, capabilities: ["markUnread": false])
            try check(items(local, online: false).filter(\.isEnabled).map(\.id) == [.unread, .copyID], "Offline local functionality was disabled")
        }
        run("reference mode preserves all demonstration actions despite source or connection flags") {
            let value = try session(source: "desktop", capabilities: ["rename": false, "pin": false, "archive": false, "markUnread": false])
            let result = items(value, reference: true, online: false)
            try check(result.map(\.id) == all && result.allSatisfy(\.isEnabled), "Reference actions regressed")
            try check(result.first(where: { $0.id == .unread })?.title == "标记为未读", "Reference menu unnecessarily changed its label")
        }
        run("legacy unread scope fallback matches existing host versus local behavior") {
            var value = try session()
            value.unreadScope = "bridge"
            try check(items(value, online: false).first(where: { $0.id == .unread })?.isEnabled == false, "Legacy bridge unread no longer routes remotely")
            value.unreadScope = "desktop"
            try check(items(value, relay: true).first(where: { $0.id == .unread })?.title == "标记为未读", "Legacy Relay unread fallback changed")
            try check(items(value).first(where: { $0.id == .unread })?.title == "标记为未读（仅此手机）", "Legacy local unread fallback changed")
        }
        run("complete menu item equality invalidates changed scope labels and action targets") {
            var value = try session(capabilities: ["markUnread": false])
            let localUnread = items(value).first { $0.id == .unread }!
            value.canMarkUnread = true
            try check(!items(value).contains(localUnread), "A local-only unread action survived a change to host sync")
            let unpinned = items(value).first { $0.id == .pin }!
            value.isPinned = true
            try check(!items(value).contains(unpinned), "Old pin target survived its label change")
            let archive = items(value).first { $0.id == .archive }!
            value.isArchived = true
            try check(!items(value).contains(archive), "Old archive target survived the switch to restore")
            try check(items(value) != items(value, online: false), "Online actions remained equal after disconnect")
        }
        run("old persisted RemoteSession JSON decodes without new fields") {
            let original = try session()
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            for key in ["canRename", "canPin", "canArchive"] { json.removeValue(forKey: key) }
            let restored = try JSONDecoder().decode(RemoteSession.self, from: JSONSerialization.data(withJSONObject: json))
            try check(restored.canRename == nil && restored.canPin == nil && restored.canArchive == nil, "Legacy local model failed optional decoding")
            try check(items(restored).map(\.id) == all, "Restored old owned session lost actions")
        }
        run("AX unread identity changes after ACK without recreating unrelated actions") {
            let value = try session(capabilities: ["markUnread": true])
            let before = items(value, unread: false).map { SessionContextAction(item: $0, perform: {}) }
            let after = items(value, unread: true).map { SessionContextAction(item: $0, perform: {}) }
            let oldUnread = before.first { $0.id == .unread }!, newUnread = after.first { $0.id == .unread }!
            try check(oldUnread.id == newUnread.id, "Fixture lost the stable action kind that caused the stale AX entry")
            try check(oldUnread.accessibilityIdentity != newUnread.accessibilityIdentity, "AX unread kept its old identity after its label/target changed")
            try check(newUnread.item.title == "标记为已读", "Updated AX action has the wrong label")
            for old in before where old.id != .unread {
                try check(after.first(where: { $0.id == old.id })?.accessibilityIdentity == old.accessibilityIdentity, "Unrelated AX action identity changed")
            }
        }
        run("AX identity covers complete presentation state and stays stable for equal values") {
            let base = SessionMenuItem(id: .unread, title: "标记为未读（仅此手机）", symbol: "circle.fill")
            let original = SessionContextAction(item: base, perform: {}).accessibilityIdentity
            try check(original == SessionContextAction(item: base, perform: {}).accessibilityIdentity, "Equal AX descriptors gained unstable identities")
            var changes: [SessionMenuItem] = []
            var item = base; item.title = "标记为未读"; changes.append(item)
            item = base; item.symbol = "circle"; changes.append(item)
            item = base; item.destructive = true; changes.append(item)
            item = base; item.isEnabled = false; changes.append(item)
            item = base; item.id = .copyID; changes.append(item)
            for changed in changes {
                try check(original != SessionContextAction(item: changed, perform: {}).accessibilityIdentity, "Changed AX presentation retained its old identity")
            }
        }
        run("AX owner signature changes only for menu semantics while the session ID stays stable") {
            var value = try session(capabilities: ["markUnread": true])
            func signature(_ value: RemoteSession, unread: Bool = false, online: Bool = true) -> [SessionContextAction.AccessibilityIdentity] {
                items(value, online: online, unread: unread).map { SessionContextAction(item: $0, perform: {}).accessibilityIdentity }
            }
            let originalID = value.id, original = signature(value)
            value.updatedAt = Date(timeIntervalSince1970: 123); value.title = "Refreshed title"; value.additions = 10; value.status = .running
            try check(signature(value) == original, "Unrelated row data recreated the AX owner")
            try check(signature(value, unread: true) != original, "Unread label change did not recreate its AX owner")
            try check(signature(value, online: false) != original, "Disabled remote menu retained its AX owner")
            value.canRename = false
            try check(signature(value) != original, "Removed action retained its AX owner")
            try check(value.id == originalID, "Menu signature changed the outer session identity")
        }
        struct Report: Codable { var cases: Int; var passed: Int; var assertions: Int; var results: [Result] }
        let report = Report(cases: results.count, passed: results.filter(\.passed).count, assertions: assertions, results: results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(report.passed)/\(report.cases) passed; \(assertions) assertions; actual production Models/BridgeSession policy, no UI or network")
        if report.passed != report.cases { exit(1) }
    }
}
