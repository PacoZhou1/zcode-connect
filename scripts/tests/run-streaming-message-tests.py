#!/usr/bin/env python3
"""Run the actual streaming parser/state and typecheck its unchanged iOS text layout."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / "ios/ZCodeMobile/Features/MessageView.swift"
models = root / "ios/ZCodeMobile/Core/Models.swift"
tests = Path(__file__).with_name("StreamingMessageTextTests.swift")
contents = {p: p.read_bytes() for p in (source, models, tests)}
text = contents[source].decode()
worker = text[text.index("enum MessageTextBlock:"):text.index("struct RichMessageText:")]
adapters = r'''
import SwiftUI
import Observation
@MainActor @Observable final class AppStore {
    var localFeedback: [String: Int] = [:]
    var isReferenceMode = false
    var showTimestamps = true
    var sheet: AppSheet?
    func copy(_ value: String) {}
    func session(_ id: String) -> RemoteSession? { nil }
    func toggleLocalFeedback(_ value: Int, messageID: String, sessionID: String) {}
    func forkSession(_ id: String, target: MessageForkTarget? = nil) {}
    func isForking(_ id: String) -> Bool { false }
}
enum ZTheme {
    static let userBubble = Color.purple
    static let userText = Color.primary
    static let separator = Color.gray
}
struct MessageAttachmentView: View {
    let attachment: MessageAttachment
    var body: some View { EmptyView() }
}
struct ChangeCount: View {
    let additions: Int
    let deletions: Int
    var body: some View { Text("counts") }
}
struct BranchShareGlyph: Shape { func path(in rect: CGRect) -> Path { Path(rect) } }
'''
started = datetime.now(timezone.utc).isoformat()
compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
ios_sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
report = {}
output = ""
status = 0
with tempfile.TemporaryDirectory(prefix="zcode-streaming-message-") as raw:
    temp = Path(raw)
    combined = temp / "StreamingTests.swift"
    combined.write_text("import Foundation\nimport Observation\n" + worker + "\n" + contents[tests].decode())
    common = [compiler, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-module-cache-path", str(temp / "cache")]
    binary = temp / "tests"
    build = subprocess.run(common + ["-sdk", sdk, "-parse-as-library", "-O", str(combined), "-o", str(binary)], capture_output=True, text=True)
    output += build.stdout + build.stderr
    status = build.returncode
    if status == 0:
        result = subprocess.run([str(binary), str(temp / "report.json")], capture_output=True, text=True, timeout=60)
        output += result.stdout + result.stderr
        status = result.returncode
        if (temp / "report.json").exists():
            report = json.loads((temp / "report.json").read_text())
    for p in (source, models):
        (temp / p.name).write_bytes(contents[p])
    (temp / "Adapters.swift").write_text(adapters)
    checked = subprocess.run(common + ["-typecheck", "-sdk", ios_sdk, "-target", "arm64-apple-ios26.0-simulator", str(temp / source.name), str(temp / models.name), str(temp / "Adapters.swift")], capture_output=True, text=True)
    output += checked.stdout + checked.stderr
    report["iOSStrictConcurrencyTypecheckExit"] = checked.returncode
    if checked.returncode == 0:
        output += "PASS production MessageView + Models iOS26 Swift6 strict concurrency typecheck; inert UI-edge adapters\n"
    status = status or checked.returncode
report.update(startedAt=started, completedAt=datetime.now(timezone.utc).isoformat(), compiler=compiler, sdk=sdk, iosSDK=ios_sdk,
              sourceSHA256={str(p.relative_to(root)): hashlib.sha256(value).hexdigest() for p, value in contents.items()}, processExit=status)
audit = root / "docs/audit"
(audit / "STREAMING_MESSAGE_TEST_RESULTS.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
(audit / "STREAMING_MESSAGE_TEST_OUTPUT.txt").write_text(output)
print(output, end="")
raise SystemExit(status)
