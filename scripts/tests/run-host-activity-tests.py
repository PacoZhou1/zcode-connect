#!/usr/bin/env python3
"""Run captured production activity state/mapping in an isolated Foundation executable.

No network, Simulator, project build, Keychain, or live app storage is used. The
shared inert HTTP/platform harness is copied from OutboxStateTests before its @main.
Only UIKit and journal construction are redirected in the temporary AppStore copy.
Relay connection side effects use in-memory adapters with no sockets or real account.
"""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
core = root / "ios/ZCodeMobile/Core"
audit = root / "docs/audit"
production = [core / n for n in ("AppStore.swift", "PendingSubmission.swift", "PendingGoal.swift", "Models.swift", "BridgeClient.swift", "ReferenceData.swift", "RemoteTransport.swift", "DraftAttachmentJournal.swift")]
production += [core / "Relay" / n for n in ("RelayTypes.swift", "RelayFrames.swift", "RelayProjection.swift", "RelayHostActivity.swift", "RelayCodec.swift", "RelayHookReview.swift", "RelayFork.swift")]
if (core / "Relay/RelayTranscriptSemantics.swift").exists():
    production.append(core / "Relay/RelayTranscriptSemantics.swift")
production += [core / "RelayAdapter/RelayBridgeMapping.swift"]
inspection = [root / "ios/ZCodeMobile/Features/ConversationControls.swift", core / "RelayAdapter/RelayRemoteTransport.swift"]
tests = [root / "scripts/tests/OutboxStateTests.swift", root / "scripts/tests/HostActivityStateTests.swift", root / "scripts/tests/RelayWorkspaceRecoveryAdapters.swift"]
contents = {p: p.read_bytes() for p in production + inspection + tests}
manifest = {str(p.relative_to(root)): hashlib.sha256(data).hexdigest() for p, data in contents.items()}
started = datetime.now(timezone.utc).isoformat()

with tempfile.TemporaryDirectory(prefix="zcode-host-activity-tests-") as raw:
    temp = Path(raw)
    inputs = []
    for source in production:
        text = contents[source].decode()
        if source.name == "AppStore.swift":
            assert text.count("import UIKit") == 1
            assert text.count("private let submissionJournal = SubmissionJournal()") == 1
            text = text.replace("import UIKit", "// Inert test-only platform adapters.")
            text = text.replace("private let submissionJournal = SubmissionJournal()", "private let submissionJournal = SubmissionJournal(directory: OutboxTestSandbox.directory)")
            text = text.replace("DraftAttachmentJournal()", 'DraftAttachmentJournal(directory: OutboxTestSandbox.directory.appendingPathComponent("draft-attachments"))')
            text = text.replace("GoalSubmissionJournal()", 'GoalSubmissionJournal(directory: OutboxTestSandbox.directory.appendingPathComponent("pending-goals"))')
        elif source.name == "BridgeClient.swift":
            text = text.split("struct BridgeClient: Sendable {", 1)[0] + "\nextension Date {" + text.split("extension Date {", 1)[1].split("enum CredentialStore {", 1)[0]
        target = temp / source.name
        target.write_text(text)
        inputs.append(str(target))
    shared = contents[tests[0]].decode().split("@main struct OutboxStateTests {", 1)
    assert len(shared) == 2
    harness = temp / "InertStateHarness.swift"
    harness.write_text(shared[0])
    inputs.append(str(harness))
    target = temp / tests[1].name
    target.write_bytes(contents[tests[1]])
    inputs.append(str(target))
    relay = temp / tests[2].name
    relay.write_bytes(contents[tests[2]])
    inputs.append(str(relay))
    compiler = subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True, text=True, check=True).stdout.strip()
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    version = subprocess.run([compiler, "--version"], capture_output=True, text=True, check=True).stdout.strip()
    build = subprocess.run([compiler, "-sdk", sdk, "-swift-version", "6", "-DHOST_ACTIVITY_STATE_TESTS", "-parse-as-library", "-O", "-module-cache-path", str(temp / "module-cache"), *inputs, "-o", str(temp / "activity-tests")], capture_output=True, text=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(build.returncode)
    run = subprocess.run([str(temp / "activity-tests"), str(temp / "state"), str(temp / "results.json")], capture_output=True, text=True, timeout=45)
    output = run.stdout + run.stderr
    print(output, end="")
    report = json.loads((temp / "results.json").read_text()) if (temp / "results.json").exists() else {"harnessError": output}
    report.update(startedAt=started, completedAt=datetime.now(timezone.utc).isoformat(), compiler=compiler, sdk=sdk, swiftVersion=version, sourceSHA256=manifest, processExit=run.returncode, boundary="Production AppStore/RelayHostActivity/RelayBridgeMapping; in-memory transport. ConversationControls inspected, not executed.")
    audit.mkdir(exist_ok=True)
    (audit / "HOST_ACTIVITY_TEST_RESULTS.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    (audit / "HOST_ACTIVITY_TEST_OUTPUT.txt").write_text(output)
    sys.exit(run.returncode)
