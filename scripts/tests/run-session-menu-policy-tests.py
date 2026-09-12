#!/usr/bin/env python3
"""Test production session-menu policy/DTOs, then typecheck actual Home and UIKit menu."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
models = root / "ios/ZCodeMobile/Core/Models.swift"
bridge = root / "ios/ZCodeMobile/Core/BridgeClient.swift"
home = root / "ios/ZCodeMobile/Features/HomeView.swift"
context = root / "ios/ZCodeMobile/Design/SessionContextInteraction.swift"
tests = Path(__file__).with_name("SessionMenuPolicyTests.swift")
runner = Path(__file__).resolve()
contents = {p: p.read_bytes() for p in (models, bridge, home, context, tests, runner)}
bridge_text = contents[bridge].decode()
dto = bridge_text[bridge_text.index("struct BridgeSession:"):bridge_text.index("\nstruct BridgeMessage:")]
dates = bridge_text[bridge_text.index("extension Date {"):bridge_text.index("\nenum CredentialStore {")]
context_text = contents[context].decode()
action = context_text[context_text.index("struct SessionContextAction:"):context_text.index("\n/// UIKit owns")]
home_text = contents[home].decode()
assert "let actions = sessionActions(for: session)" in home_text
assert "actions: actions, open:" in home_text
assert ".accessibilityActions {\n            ForEach(actions, id: \\.accessibilityIdentity)" in home_text
assert ".accessibilityAction(named:" not in home_text
assert ".id(actions.map(\\.accessibilityIdentity))" in home_text
assert 'Text("菜单动作："' not in home_text
assert "ForEach(group.sessions) { session in\n                            sessionRow(session)" in home_text
adapters = r'''
import SwiftUI
import Observation
@MainActor @Observable final class AppStore {
    var isReferenceMode = false
    var activeProfileID: String?
    var activeProfile: ConnectionProfile?
    var profiles: [ConnectionProfile] = []
    var sessions: [RemoteSession] = []
    var showArchived = false
    var sortOrder = SortOrder.recent
    var connection = ConnectionState.disconnected
    var streamConnected = false
    var sessionListTruncated = false
    var referenceReview = false
    var hostName = "Test host"
    var errorMessage: String?
    var path: [AppRoute] = []
    var sheet: AppSheet?
    func session(_ id: String) -> RemoteSession? { sessions.first { $0.id == id } }
    func isUnread(_ id: String) -> Bool { false }
    func setUnread(_ value: Bool, sessionID: String) {}
    func setPinned(_ value: Bool, sessionID: String) {}
    func rename(_ id: String, title: String) {}
    func archive(_ id: String, archived: Bool = true) {}
    func copy(_ value: String) {}
    func connect(_ profile: ConnectionProfile, confirmedControllerReplacement: Bool = false) async {}
    func switchComputer(_ profile: ConnectionProfile, confirmedControllerReplacement: Bool = false) async {}
    func refresh() async {}
    func leaveReferenceMode() {}
    func enterReferenceMode() {}
    func messages(_ id: String) -> [ChatMessage] { [] }
    func previewMessages(_ id: String) async throws -> [ChatMessage] { [] }
}
enum ZTheme {
    static let background = Color.white
    static let accent = Color.purple
    static let listSecondary = Color.gray
}
struct EmptyGlyph: Shape { func path(in rect: CGRect) -> Path { Path(rect) } }
typealias MenuLinesGlyph = EmptyGlyph
typealias VoiceBarsGlyph = EmptyGlyph
typealias ComposeGlyph = EmptyGlyph
typealias ChatGlyph = EmptyGlyph
typealias FolderGlyph = EmptyGlyph
struct InlineNotice: View { var symbol: String; var text: String; var body: some View { Text(text) } }
struct StatusDot: View { var status: SessionStatus; var body: some View { Circle() } }
struct ChangeCount: View { var additions: Int; var deletions: Int; var body: some View { Text("changes") } }
struct MessageView: View { var message: ChatMessage; var sessionID: String; var body: some View { Text(message.text) } }
struct GlassSearchField: View { @Binding var text: String; var placeholder: String; var body: some View { TextField(placeholder, text: $text) } }
struct NativeGlassButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label } }
extension View { func measureLayout(_ name: String) -> some View { self } }
@MainActor final class MotionPerformanceProbe {
    static let shared = MotionPerformanceProbe()
    var isRunning = false
    func setStage(_ value: String) {}
}
'''
started = datetime.now(timezone.utc).isoformat()
compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
ios_sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
report, output, status = {}, "", 0
with tempfile.TemporaryDirectory(prefix="zcode-session-menu-") as raw:
    temp = Path(raw)
    for p in (models, home, context, tests):
        (temp / p.name).write_bytes(contents[p])
    (temp / "SessionDTO.swift").write_text("import Foundation\n" + dto + "\n" + dates)
    (temp / "ActionDescription.swift").write_text("import Foundation\n" + action)
    common = [compiler, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-module-cache-path", str(temp / "cache")]
    binary = temp / "tests"
    built = subprocess.run(common + ["-sdk", sdk, "-parse-as-library", "-O", str(temp / models.name), str(temp / "SessionDTO.swift"), str(temp / "ActionDescription.swift"), str(temp / tests.name), "-o", str(binary)], capture_output=True, text=True)
    output += built.stdout + built.stderr
    status = built.returncode
    if status == 0:
        result = subprocess.run([str(binary), str(temp / "report.json")], capture_output=True, text=True, timeout=30)
        output += result.stdout + result.stderr
        status = result.returncode
        if (temp / "report.json").exists(): report = json.loads((temp / "report.json").read_text())
    (temp / "Adapters.swift").write_text(adapters)
    checked = subprocess.run(common + ["-D", "DEBUG", "-typecheck", "-sdk", ios_sdk, "-target", "arm64-apple-ios26.0-simulator", str(temp / models.name), str(temp / home.name), str(temp / context.name), str(temp / "Adapters.swift")], capture_output=True, text=True)
    output += checked.stdout + checked.stderr
    report["iOSStrictConcurrencyTypecheckExit"] = checked.returncode
    if checked.returncode == 0:
        output += "PASS production HomeView + SessionContextInteraction + Models iOS26 Swift6 strict typecheck; inert UI-edge adapters\n"
    status = status or checked.returncode
report.update(startedAt=started, completedAt=datetime.now(timezone.utc).isoformat(), compiler=compiler, sdk=sdk, iosSDK=ios_sdk,
              sharedUIKitAXActionArraySourceCheck=True,
              sourceSHA256={str(p.relative_to(root)): hashlib.sha256(value).hexdigest() for p, value in contents.items()}, processExit=status)
audit = root / "docs/audit"
(audit / "SESSION_MENU_POLICY_TEST_RESULTS.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
(audit / "SESSION_MENU_POLICY_TEST_OUTPUT.txt").write_text(output)
print(output, end="")
raise SystemExit(status)
