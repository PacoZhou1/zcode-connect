#!/usr/bin/env python3
"""Test the actual SwiftUI row's equality without mounting UI; strict iOS typecheck."""
from pathlib import Path
from datetime import datetime, timezone
import ast
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / "ios/ZCodeMobile/Features/MessageView.swift"
models = root / "ios/ZCodeMobile/Core/Models.swift"
tests = Path(__file__).with_name("MessageTextBlockRowTests.swift")
shared_runner = Path(__file__).with_name("run-streaming-message-tests.py")
runner = Path(__file__).resolve()
contents = {p: p.read_bytes() for p in (source, models, tests, runner, shared_runner)}
text = contents[source].decode()
worker = text[text.index("enum MessageTextBlock:"):text.index("struct RichMessageText:")]
row = text[text.index("private struct MessageTextBlockRow:"):text.index("\nstruct CodeBlockView:")]
mac_edges = """
enum ZTheme { static let userText = Color.primary }
struct CodeBlockView: View { let code: String; var body: some View { Text(code) } }
"""
# Reuse existing inert AppStore/UI boundaries without executing another runner
# or overwriting the previous streaming parser test evidence.
adapters = next(ast.literal_eval(node.value) for node in ast.parse(contents[shared_runner].decode()).body
                if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "adapters" for target in node.targets))
started = datetime.now(timezone.utc).isoformat()
compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
ios_sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
report, output, status = {}, "", 0
with tempfile.TemporaryDirectory(prefix="zcode-message-block-row-") as raw:
    temp = Path(raw)
    combined = temp / "RowTests.swift"
    combined.write_text("import Foundation\nimport Observation\nimport SwiftUI\n" + worker + "\n" + row + "\n" + mac_edges + "\n" + contents[tests].decode())
    common = [compiler, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-module-cache-path", str(temp / "cache")]
    binary = temp / "tests"
    built = subprocess.run(common + ["-sdk", sdk, "-parse-as-library", "-O", str(combined), "-o", str(binary)], capture_output=True, text=True)
    output += built.stdout + built.stderr
    status = built.returncode
    if status == 0:
        result = subprocess.run([str(binary), str(temp / "report.json")], capture_output=True, text=True, timeout=30)
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
(audit / "MESSAGE_BLOCK_ROW_TEST_RESULTS.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
(audit / "MESSAGE_BLOCK_ROW_TEST_OUTPUT.txt").write_text(output)
print(output, end="")
raise SystemExit(status)
