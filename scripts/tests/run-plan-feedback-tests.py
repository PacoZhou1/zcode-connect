#!/usr/bin/env python3
"""Compile and run actual Card submission code with inert UI/transport adapters.

This extracts the unchanged production validation properties and submit function,
not a parallel implementation of their rules. No Xcode build, simulator or network.
"""
from datetime import datetime, timezone
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline-ref", help="read only the Card from a historical Git commit; write separate baseline evidence")
args = parser.parse_args()
card = root / "ios/ZCodeMobile/Features/InteractionRequestCard.swift"
bridge = root / "ios/ZCodeMobile/Core/BridgeClient.swift"
tests = Path(__file__).with_name("PlanFeedbackBoundaryTests.swift")
runner = Path(__file__).resolve()
contents = {path: path.read_bytes() for path in (card, bridge, tests, runner)}
baseline_commit = None
if args.baseline_ref:
    baseline_commit = subprocess.check_output(["git", "rev-parse", "--verify", args.baseline_ref + "^{commit}"],
                                              cwd=root, text=True).strip()
    contents[card] = subprocess.check_output(["git", "show", baseline_commit + ":" + str(card.relative_to(root))], cwd=root)
source = contents[card].decode()
bridge_source = contents[bridge].decode()
properties = source[source.index("    private var isPermission:"):source.index("    var body: some View {")]
submit = source[source.index("    private func submit(accept: Bool) {"):source.rindex("\n}")]
json_value = bridge_source[bridge_source.index("enum JSONValue:"):bridge_source.index("\nstruct RemoteModel:")]
interaction = bridge_source[bridge_source.index("struct PendingInteraction:"):bridge_source.index("\nstruct ConversationHistory:")]
production = "import Foundation\n" + json_value + "\n" + interaction + "\n"
production += "@MainActor extension InteractionRequestSubmissionHarness {\n" + properties + "\n" + submit
production += "\n    var submitEnabled: Bool { canAnswer }\n"
production += "    func send(accept: Bool) { submit(accept: accept) }\n}\n"

started = datetime.now(timezone.utc).isoformat()
compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
report, output, status = {}, "", 0
with tempfile.TemporaryDirectory(prefix="zcode-plan-feedback-") as directory:
    temp = Path(directory)
    (temp / "ProductionSubmission.swift").write_text(production)
    (temp / tests.name).write_bytes(contents[tests])
    binary = temp / "tests"
    built = subprocess.run([compiler, "-swift-version", "6", "-strict-concurrency=complete",
        "-warnings-as-errors", "-sdk", sdk, "-module-cache-path", str(temp / "cache"),
        "-parse-as-library", "-O", str(temp / "ProductionSubmission.swift"), str(temp / tests.name),
        "-o", str(binary)], capture_output=True, text=True)
    output += built.stdout + built.stderr
    status = built.returncode
    if status == 0:
        run = subprocess.run([str(binary), str(temp / "results.json")], capture_output=True, text=True, timeout=30)
        output += run.stdout + run.stderr
        status = run.returncode
        if (temp / "results.json").exists():
            report = json.loads((temp / "results.json").read_text())
report.update(startedAt=started, completedAt=datetime.now(timezone.utc).isoformat(),
    compiler=compiler, sdk=sdk, swiftVersion="6", strictConcurrency="complete", warningsAsErrors=True,
    extraction="actual Card validation properties and submit(accept:), actual JSONValue and PendingInteraction",
    limits="inert state/transport adapters; no SwiftUI rendering, Xcode build, simulator or network",
    baselineCommit=baseline_commit,
    sourceSHA256={str(path.relative_to(root)): hashlib.sha256(value).hexdigest() for path, value in contents.items()},
    extractedSHA256=hashlib.sha256(production.encode()).hexdigest(), processExit=status)
audit = root / "docs/audit"
audit.mkdir(parents=True, exist_ok=True)
prefix = "PLAN_FEEDBACK_BOUNDARY_BASELINE" if baseline_commit else "PLAN_FEEDBACK_BOUNDARY"
(audit / (prefix + "_TEST_RESULTS.json")).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
(audit / (prefix + "_TEST_OUTPUT.txt")).write_text(output)
print(output, end="")
raise SystemExit(status)
