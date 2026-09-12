#!/usr/bin/env python3
"""Typecheck production FilesView and Models against iOS with inert UI-edge adapters."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
paths = [root / "ios/ZCodeMobile/Features/FilesView.swift", root / "ios/ZCodeMobile/Core/Models.swift"]
contents = {p: p.read_bytes() for p in paths}
stub = r'''
import SwiftUI
import Observation
struct BridgeFile { var local: RemoteFile }
struct BridgeFileListing { var files: [BridgeFile]; var truncated: Bool?; var searchComplete: Bool? }
struct BridgeChanges { var files: [FileChange]; var source: String?; var truncated: Bool? }
@MainActor @Observable final class AppStore {
    var isReferenceMode = false
    var fileListingGeneration = UUID()
    var connection = ConnectionState.disconnected
    func session(_ id: String) -> RemoteSession? { nil }
    func fileListing(projectID: String, path: String = "") async throws -> RemoteFileListing { .init(files: []) }
    func searchFiles(projectID: String, query: String) async throws -> BridgeFileListing { .init(files: [], truncated: false, searchComplete: true) }
    func changeSummary(_ id: String) async throws -> BridgeChanges { .init(files: [], source: nil, truncated: false) }
    func fileContent(projectID: String, path: String) async throws -> String { "" }
    func copy(_ value: String) {}
}
struct NativeGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct GlassSearchField: View {
    @Binding var text: String
    var placeholder: String
    var body: some View { TextField(placeholder, text: $text) }
}
struct FolderGlyph: Shape { func path(in rect: CGRect) -> Path { Path(rect) } }
struct ChangeCount: View { var additions: Int; var deletions: Int; var body: some View { Text("counts") } }
'''
started = datetime.now(timezone.utc).isoformat()
compiler = subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True, text=True, check=True).stdout.strip()
sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
with tempfile.TemporaryDirectory(prefix="zcode-files-view-typecheck-") as raw:
    temp = Path(raw)
    inputs = []
    for p, data in contents.items():
        target = temp / p.name
        target.write_bytes(data)
        inputs.append(str(target))
    (temp / "Adapters.swift").write_text(stub)
    result = subprocess.run([compiler, "-typecheck", "-sdk", sdk, "-target", "arm64-apple-ios26.0-simulator", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-module-cache-path", str(temp / "module-cache"), *inputs, str(temp / "Adapters.swift")], capture_output=True, text=True)
output = result.stdout + result.stderr
if result.returncode == 0:
    output += "PASS production FilesView/Models iOS 26 Swift 6 strict-concurrency typecheck; inert UI-edge adapters; no main App build\n"
print(output, end="")
report = {"startedAt": started, "completedAt": datetime.now(timezone.utc).isoformat(), "compiler": compiler, "sdk": sdk, "sourceSHA256": {str(p.relative_to(root)): hashlib.sha256(data).hexdigest() for p, data in contents.items()}, "processExit": result.returncode}
(root / "docs/audit/FILE_LISTING_TYPECHECK.json").write_text(json.dumps(report, indent=2) + "\n")
(root / "docs/audit/FILE_LISTING_TYPECHECK.txt").write_text(output)
raise SystemExit(result.returncode)
